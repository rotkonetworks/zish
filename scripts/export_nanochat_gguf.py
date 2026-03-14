#!/usr/bin/env python3
"""Export nanochat checkpoint to GGUF for zish inference engine.

Usage:
    python scripts/export_nanochat_gguf.py \
        --checkpoint /root/.cache/nanochat/base_checkpoints/d4/model_008000.pt \
        --tokenizer /root/.cache/nanochat/tokenizer \
        --output ~/.zish/models/shell_completion.gguf
"""

import argparse
import struct
import torch
import numpy as np
from pathlib import Path

# GGUF constants
GGUF_MAGIC = 0x46554747  # "GGUF"
GGUF_VERSION = 3

# GGUF value types
GGUF_TYPE_UINT32 = 4
GGUF_TYPE_INT32 = 5
GGUF_TYPE_FLOAT32 = 6
GGUF_TYPE_STRING = 8
GGUF_TYPE_UINT64 = 10

# GGML tensor types
GGML_TYPE_F32 = 0
GGML_TYPE_F16 = 1


def write_string(f, s):
    encoded = s.encode('utf-8')
    f.write(struct.pack('<Q', len(encoded)))
    f.write(encoded)


def write_kv_string(f, key, value):
    write_string(f, key)
    f.write(struct.pack('<I', GGUF_TYPE_STRING))
    write_string(f, value)


def write_kv_uint32(f, key, value):
    write_string(f, key)
    f.write(struct.pack('<I', GGUF_TYPE_UINT32))
    f.write(struct.pack('<I', value))


def write_kv_int32(f, key, value):
    write_string(f, key)
    f.write(struct.pack('<I', GGUF_TYPE_INT32))
    f.write(struct.pack('<i', value))


def write_kv_float32(f, key, value):
    write_string(f, key)
    f.write(struct.pack('<I', GGUF_TYPE_FLOAT32))
    f.write(struct.pack('<f', value))


GGUF_TYPE_ARRAY = 9


def write_kv_string_array(f, key, strings):
    """Write array of strings as GGUF KV pair."""
    write_string(f, key)
    f.write(struct.pack('<I', GGUF_TYPE_ARRAY))
    f.write(struct.pack('<I', GGUF_TYPE_STRING))  # element type
    f.write(struct.pack('<Q', len(strings)))  # count
    for s in strings:
        encoded = s.encode('utf-8', errors='replace')
        f.write(struct.pack('<Q', len(encoded)))
        f.write(encoded)


def write_kv_float_array(f, key, values):
    """Write array of f32 as GGUF KV pair."""
    write_string(f, key)
    f.write(struct.pack('<I', GGUF_TYPE_ARRAY))
    f.write(struct.pack('<I', GGUF_TYPE_FLOAT32))  # element type
    f.write(struct.pack('<Q', len(values)))
    for v in values:
        f.write(struct.pack('<f', v))


def align_offset(offset, alignment=32):
    return (offset + alignment - 1) & ~(alignment - 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--checkpoint', required=True, help='nanochat model checkpoint .pt')
    parser.add_argument('--tokenizer', required=True, help='nanochat tokenizer directory')
    parser.add_argument('--output', required=True, help='output GGUF file')
    parser.add_argument('--fp16', action='store_true', help='convert to f16 (default: f32)')
    args = parser.parse_args()

    print(f"Loading checkpoint: {args.checkpoint}")
    state_dict = torch.load(args.checkpoint, map_location='cpu', weights_only=True)

    # Detect model config from weights
    wte = state_dict['transformer.wte.weight']
    vocab_size, n_embd = wte.shape
    n_layer = 0
    while f'transformer.h.{n_layer}.attn.c_q.weight' in state_dict:
        n_layer += 1
    n_head = n_embd // 128  # head_dim = 128
    n_kv_head = n_head  # no GQA in nanochat base models

    print(f"Model: vocab={vocab_size}, n_embd={n_embd}, n_layer={n_layer}, n_head={n_head}")

    # Load tokenizer vocabulary
    tok_dir = Path(args.tokenizer)
    import sys
    sys.path.insert(0, str(Path(args.checkpoint).parent.parent.parent))
    try:
        from nanochat.tokenizer import get_tokenizer
        tok = get_tokenizer()
        real_vocab_size = tok.get_vocab_size()
        bos_id = tok.get_bos_token_id()
        vocab_tokens = []
        vocab_scores = []
        for i in range(real_vocab_size):
            try:
                t = tok.decode([i])
                vocab_tokens.append(t)
            except:
                vocab_tokens.append('')
            # Score = token length (prefer longer matches in greedy tokenizer)
            vocab_scores.append(float(len(vocab_tokens[-1])))
        print(f"Tokenizer: {real_vocab_size} tokens, BOS={bos_id}")
    except Exception as e:
        print(f"Warning: could not load tokenizer: {e}")
        vocab_tokens = [f'<tok_{i}>' for i in range(vocab_size)]
        vocab_scores = [0.0] * vocab_size
        real_vocab_size = vocab_size
        bos_id = 0

    # Map nanochat tensor names to GGUF standard names
    tensor_map = {}
    # Token embeddings
    tensor_map['token_embd.weight'] = state_dict['transformer.wte.weight'].float()
    # Output head
    tensor_map['output.weight'] = state_dict['lm_head.weight'].float()

    # Per-layer
    for i in range(n_layer):
        prefix = f'transformer.h.{i}'
        # Attention
        tensor_map[f'blk.{i}.attn_q.weight'] = state_dict[f'{prefix}.attn.c_q.weight'].float()
        tensor_map[f'blk.{i}.attn_k.weight'] = state_dict[f'{prefix}.attn.c_k.weight'].float()
        tensor_map[f'blk.{i}.attn_v.weight'] = state_dict[f'{prefix}.attn.c_v.weight'].float()
        tensor_map[f'blk.{i}.attn_output.weight'] = state_dict[f'{prefix}.attn.c_proj.weight'].float()
        # MLP (ReLU²: c_fc [4*dim, dim], c_proj [dim, 4*dim])
        tensor_map[f'blk.{i}.ffn_up.weight'] = state_dict[f'{prefix}.mlp.c_fc.weight'].float()
        tensor_map[f'blk.{i}.ffn_down.weight'] = state_dict[f'{prefix}.mlp.c_proj.weight'].float()
        # Value embeddings (if present)
        ve_key = f'value_embeds.{i}.weight'
        if ve_key in state_dict:
            tensor_map[f'blk.{i}.value_embed.weight'] = state_dict[ve_key].float()
        # VE gate (if present)
        vg_key = f'{prefix}.attn.ve_gate.weight'
        if vg_key in state_dict:
            tensor_map[f'blk.{i}.ve_gate.weight'] = state_dict[vg_key].float()

    # Resid/x0 lambdas
    if 'resid_lambdas' in state_dict:
        tensor_map['resid_lambdas'] = state_dict['resid_lambdas'].float()
    if 'x0_lambdas' in state_dict:
        tensor_map['x0_lambdas'] = state_dict['x0_lambdas'].float()

    # Convert to f16 if requested
    ggml_type = GGML_TYPE_F32
    type_size = 4
    if args.fp16:
        ggml_type = GGML_TYPE_F16
        type_size = 2
        for k in tensor_map:
            if tensor_map[k].numel() > 256:  # don't quantize tiny tensors
                tensor_map[k] = tensor_map[k].half()

    # Prepare tensor info
    tensor_infos = []
    for name, tensor in tensor_map.items():
        data = tensor.numpy() if tensor.dtype == torch.float32 else tensor.numpy().view(np.uint16)
        t_type = GGML_TYPE_F32 if tensor.dtype == torch.float32 else GGML_TYPE_F16
        tensor_infos.append((name, tensor.shape, t_type, data.tobytes()))

    # Count metadata KV pairs
    n_kv = 14  # general metadata + tokenizer (tokens, scores, bos_id)

    # Write GGUF
    output_path = Path(args.output).expanduser()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, 'wb') as f:
        # Header
        f.write(struct.pack('<I', GGUF_MAGIC))
        f.write(struct.pack('<I', GGUF_VERSION))
        f.write(struct.pack('<Q', len(tensor_infos)))  # n_tensors
        f.write(struct.pack('<Q', n_kv))  # n_kv

        # Metadata KV
        write_kv_string(f, 'general.architecture', 'nanochat')
        write_kv_string(f, 'general.name', 'shell-completion-44m')
        write_kv_uint32(f, 'nanochat.context_length', 128)
        write_kv_uint32(f, 'nanochat.embedding_length', n_embd)
        write_kv_uint32(f, 'nanochat.block_count', n_layer)
        write_kv_uint32(f, 'nanochat.attention.head_count', n_head)
        write_kv_uint32(f, 'nanochat.attention.head_count_kv', n_kv_head)
        write_kv_uint32(f, 'nanochat.vocab_size', vocab_size)
        write_kv_uint32(f, 'nanochat.feed_forward_length', n_embd * 4)  # ReLU² MLP: 4*dim hidden
        write_kv_string(f, 'nanochat.activation', 'relu_squared')  # distinguish from SwiGLU
        write_kv_string(f, 'general.file_type', 'f16' if args.fp16 else 'f32')

        # Tokenizer
        write_kv_string_array(f, 'tokenizer.ggml.tokens', vocab_tokens)
        write_kv_float_array(f, 'tokenizer.ggml.scores', vocab_scores)
        write_kv_uint32(f, 'tokenizer.ggml.bos_token_id', bos_id)

        # Tensor infos (name, n_dims, dims, type, offset)
        data_offset = 0
        for name, shape, t_type, data_bytes in tensor_infos:
            write_string(f, name)
            n_dims = len(shape)
            f.write(struct.pack('<I', n_dims))
            for dim in reversed(shape):  # GGUF stores dims in reverse (column-major)
                f.write(struct.pack('<Q', dim))
            f.write(struct.pack('<I', t_type))
            f.write(struct.pack('<Q', data_offset))
            data_offset = align_offset(data_offset + len(data_bytes))

        # Align to 32 bytes before tensor data
        current = f.tell()
        aligned = align_offset(current)
        f.write(b'\x00' * (aligned - current))

        # Tensor data
        for name, shape, t_type, data_bytes in tensor_infos:
            f.write(data_bytes)
            # Pad to alignment
            current = f.tell()
            aligned = align_offset(current)
            if aligned > current:
                f.write(b'\x00' * (aligned - current))

    total_size = output_path.stat().st_size
    print(f"Saved: {output_path} ({total_size / 1024 / 1024:.1f} MB)")
    print(f"Tensors: {len(tensor_infos)}")
    print(f"Type: {'f16' if args.fp16 else 'f32'}")


if __name__ == '__main__':
    main()
