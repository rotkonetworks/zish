#!/usr/bin/env python3
"""Export Qwen3-ASR to GGUF for zish inference engine.

Packs both audio encoder and text decoder into a single GGUF file.
Encoder tensors use 'encoder.*' prefix, decoder uses standard 'blk.*' naming.

Usage:
    python export_asr_gguf.py --model Qwen/Qwen3-ASR-0.6B --output qwen3_asr.gguf [--dtype f16|f32|q8_0]
"""

import argparse
import json
import struct
import numpy as np
from pathlib import Path


# GGUF constants
GGUF_MAGIC = 0x46475547  # "GGUF"
GGUF_VERSION = 3

# GGML types
GGML_TYPE_F32 = 0
GGML_TYPE_F16 = 1
GGML_TYPE_Q8_0 = 8

# GGUF metadata value types
GGUF_TYPE_UINT32 = 4
GGUF_TYPE_FLOAT32 = 6
GGUF_TYPE_STRING = 8
GGUF_TYPE_ARRAY = 9


def write_string(f, s):
    b = s.encode('utf-8')
    f.write(struct.pack('<Q', len(b)))
    f.write(b)


def write_kv_string(f, key, val):
    write_string(f, key)
    f.write(struct.pack('<I', GGUF_TYPE_STRING))
    write_string(f, val)


def write_kv_uint32(f, key, val):
    write_string(f, key)
    f.write(struct.pack('<I', GGUF_TYPE_UINT32))
    f.write(struct.pack('<I', val))


def write_kv_float32(f, key, val):
    write_string(f, key)
    f.write(struct.pack('<I', GGUF_TYPE_FLOAT32))
    f.write(struct.pack('<f', val))


def write_kv_string_array(f, key, vals):
    write_string(f, key)
    f.write(struct.pack('<I', GGUF_TYPE_ARRAY))
    f.write(struct.pack('<I', GGUF_TYPE_STRING))
    f.write(struct.pack('<Q', len(vals)))
    for v in vals:
        write_string(f, v)


def quantize_q8_0(data):
    """Quantize f32 array to Q8_0 blocks (32 elements each)."""
    assert data.ndim == 1
    n = len(data)
    assert n % 32 == 0, f"Length {n} not divisible by 32"
    n_blocks = n // 32
    blocks = bytearray(n_blocks * 34)  # 2 bytes scale + 32 bytes weights

    for i in range(n_blocks):
        block = data[i*32:(i+1)*32]
        amax = np.max(np.abs(block))
        scale = amax / 127.0
        scale_f16 = np.float16(scale)

        if scale == 0:
            quant = np.zeros(32, dtype=np.int8)
        else:
            quant = np.clip(np.round(block / scale), -128, 127).astype(np.int8)

        offset = i * 34
        struct.pack_into('<e', blocks, offset, float(scale_f16))
        blocks[offset+2:offset+34] = quant.tobytes()

    return bytes(blocks)


def get_ggml_type(dtype_str):
    return {'f32': GGML_TYPE_F32, 'f16': GGML_TYPE_F16, 'q8_0': GGML_TYPE_Q8_0}[dtype_str]


def convert_tensor(tensor, dtype_str):
    """Convert tensor to target dtype, return (bytes, ggml_type)."""
    data = tensor.float().numpy().flatten()

    if dtype_str == 'f32':
        return data.tobytes(), GGML_TYPE_F32
    elif dtype_str == 'f16':
        return data.astype(np.float16).tobytes(), GGML_TYPE_F16
    elif dtype_str == 'q8_0':
        # Pad to multiple of 32 if needed
        if len(data) % 32 != 0:
            pad = 32 - (len(data) % 32)
            data = np.concatenate([data, np.zeros(pad, dtype=np.float32)])
        return quantize_q8_0(data), GGML_TYPE_Q8_0
    else:
        raise ValueError(f"Unknown dtype: {dtype_str}")


def tensor_name_map(hf_name):
    """Map HuggingFace tensor name to GGUF tensor name."""
    # Audio encoder
    if hf_name.startswith('thinker.audio_tower.'):
        rest = hf_name[len('thinker.audio_tower.'):]
        # Conv frontend
        if rest.startswith('conv2d'):
            return f'encoder.{rest}'
        if rest == 'conv_out.weight':
            return 'encoder.conv_out.weight'
        # Encoder layers
        if rest.startswith('layers.'):
            parts = rest.split('.')
            layer_idx = parts[1]
            remainder = '.'.join(parts[2:])
            # Map attention
            remap = {
                'self_attn.q_proj.weight': 'attn_q.weight',
                'self_attn.q_proj.bias': 'attn_q.bias',
                'self_attn.k_proj.weight': 'attn_k.weight',
                'self_attn.k_proj.bias': 'attn_k.bias',
                'self_attn.v_proj.weight': 'attn_v.weight',
                'self_attn.v_proj.bias': 'attn_v.bias',
                'self_attn.out_proj.weight': 'attn_output.weight',
                'self_attn.out_proj.bias': 'attn_output.bias',
                'self_attn_layer_norm.weight': 'attn_norm.weight',
                'self_attn_layer_norm.bias': 'attn_norm.bias',
                'fc1.weight': 'ffn_up.weight',
                'fc1.bias': 'ffn_up.bias',
                'fc2.weight': 'ffn_down.weight',
                'fc2.bias': 'ffn_down.bias',
                'final_layer_norm.weight': 'ffn_norm.weight',
                'final_layer_norm.bias': 'ffn_norm.bias',
            }
            if remainder in remap:
                return f'encoder.blk.{layer_idx}.{remap[remainder]}'
            return f'encoder.blk.{layer_idx}.{remainder}'
        # Post-norm and projections
        if rest.startswith('ln_post'):
            return f'encoder.{rest}'
        if rest.startswith('proj1'):
            return f'encoder.{rest}'
        if rest.startswith('proj2'):
            return f'encoder.{rest}'
        return f'encoder.{rest}'

    # Text decoder
    if hf_name.startswith('thinker.model.'):
        rest = hf_name[len('thinker.model.'):]
        if rest == 'embed_tokens.weight':
            return 'token_embd.weight'
        if rest == 'norm.weight':
            return 'output_norm.weight'
        if rest.startswith('layers.'):
            parts = rest.split('.')
            layer_idx = parts[1]
            remainder = '.'.join(parts[2:])
            remap = {
                'self_attn.q_proj.weight': 'attn_q.weight',
                'self_attn.k_proj.weight': 'attn_k.weight',
                'self_attn.v_proj.weight': 'attn_v.weight',
                'self_attn.o_proj.weight': 'attn_output.weight',
                'self_attn.q_norm.weight': 'attn_q_norm.weight',
                'self_attn.k_norm.weight': 'attn_k_norm.weight',
                'mlp.gate_proj.weight': 'ffn_gate.weight',
                'mlp.up_proj.weight': 'ffn_up.weight',
                'mlp.down_proj.weight': 'ffn_down.weight',
                'input_layernorm.weight': 'attn_norm.weight',
                'post_attention_layernorm.weight': 'ffn_norm.weight',
            }
            if remainder in remap:
                return f'blk.{layer_idx}.{remap[remainder]}'
            return f'blk.{layer_idx}.{remainder}'
        return rest

    if hf_name == 'thinker.lm_head.weight':
        return 'output.weight'

    return hf_name


def main():
    parser = argparse.ArgumentParser(description='Export Qwen3-ASR to GGUF')
    parser.add_argument('--model', type=str, default='Qwen/Qwen3-ASR-0.6B')
    parser.add_argument('--output', type=str, default='qwen3_asr_0.6b.gguf')
    parser.add_argument('--dtype', type=str, default='f16', choices=['f32', 'f16', 'q8_0'])
    parser.add_argument('--local', type=str, default=None, help='Local model path')
    args = parser.parse_args()

    print(f"Loading model {args.model}...")
    from safetensors import safe_open

    if args.local:
        model_dir = Path(args.local)
    else:
        import huggingface_hub
        model_dir = Path(huggingface_hub.snapshot_download(args.model))

    # Load config
    with open(model_dir / 'config.json') as f:
        config = json.load(f)

    tc = config.get('thinker_config', config)
    ac = tc.get('audio_config', {})
    dc = tc.get('text_config', {})

    # Load tokenizer vocab for GGUF
    tokenizer_path = model_dir / 'tokenizer.json'
    vocab_tokens = []
    vocab_scores = []
    if tokenizer_path.exists():
        with open(tokenizer_path) as f:
            tok = json.load(f)
        vocab = tok.get('model', {}).get('vocab', {})
        # Sort by index
        sorted_vocab = sorted(vocab.items(), key=lambda x: x[1])
        vocab_tokens = [k for k, v in sorted_vocab]
        vocab_scores = [0.0] * len(vocab_tokens)
        print(f"Loaded {len(vocab_tokens)} tokens from tokenizer")

    # Load safetensors
    st_files = sorted(model_dir.glob('*.safetensors'))
    tensors = {}
    for sf in st_files:
        print(f"Loading {sf.name}...")
        f = safe_open(str(sf), framework='pt')
        for key in f.keys():
            tensors[key] = f.get_tensor(key)

    print(f"Loaded {len(tensors)} tensors")

    # Map and convert tensors
    gguf_tensors = []
    for hf_name, tensor in sorted(tensors.items()):
        gguf_name = tensor_name_map(hf_name)
        data, ggml_type = convert_tensor(tensor, args.dtype)
        shape = list(tensor.shape)

        gguf_tensors.append({
            'name': gguf_name,
            'shape': shape,
            'type': ggml_type,
            'data': data,
        })
        print(f"  {hf_name} -> {gguf_name} {shape} {args.dtype}")

    # Build metadata
    metadata = []

    def add_str(k, v): metadata.append(('s', k, v))
    def add_u32(k, v): metadata.append(('u', k, int(v)))
    def add_f32(k, v): metadata.append(('f', k, float(v)))

    # General
    add_str('general.architecture', 'qwen3_asr')
    add_str('general.name', f'Qwen3-ASR-{args.model.split("-")[-1]}')
    add_str('general.file_type', args.dtype)

    # Decoder config (standard llama-family keys)
    add_u32('qwen3_asr.embedding_length', dc.get('hidden_size', 1024))
    add_u32('qwen3_asr.feed_forward_length', dc.get('intermediate_size', 3072))
    add_u32('qwen3_asr.block_count', dc.get('num_hidden_layers', 28))
    add_u32('qwen3_asr.attention.head_count', dc.get('num_attention_heads', 16))
    add_u32('qwen3_asr.attention.head_count_kv', dc.get('num_key_value_heads', 8))
    add_u32('qwen3_asr.context_length', min(dc.get('max_position_embeddings', 65536), 4096))
    add_f32('qwen3_asr.rope.freq_base', dc.get('rope_theta', 1000000))
    add_f32('qwen3_asr.attention.layer_norm_rms_epsilon', dc.get('rms_norm_eps', 1e-6))

    # Encoder config
    add_u32('encoder.block_count', ac.get('encoder_layers', 18))
    add_u32('encoder.embedding_length', ac.get('d_model', 896))
    add_u32('encoder.attention.head_count', ac.get('encoder_attention_heads', 14))
    add_u32('encoder.feed_forward_length', ac.get('encoder_ffn_dim', 3584))
    add_u32('encoder.mel_bins', ac.get('num_mel_bins', 128))
    add_u32('encoder.max_source_positions', ac.get('max_source_positions', 1500))
    add_u32('encoder.output_dim', ac.get('output_dim', 1024))
    add_u32('encoder.downsample_dim', ac.get('downsample_hidden_size', 480))
    add_u32('encoder.conv_chunksize', ac.get('conv_chunksize', 500))
    add_u32('encoder.conv_channels', 480)  # from conv2d shapes

    # Tokenizer
    if vocab_tokens:
        metadata.append(('sa', 'tokenizer.ggml.tokens', vocab_tokens))
        metadata.append(('fa', 'tokenizer.ggml.scores', vocab_scores))
        add_str('tokenizer.ggml.model', 'gpt2')

    # Count metadata and tensors
    n_kv = len(metadata)
    n_tensors = len(gguf_tensors)

    print(f"\nWriting GGUF: {n_kv} metadata, {n_tensors} tensors")

    # Calculate alignment
    ALIGNMENT = 32

    with open(args.output, 'wb') as f:
        # Header
        f.write(struct.pack('<I', GGUF_MAGIC))
        f.write(struct.pack('<I', GGUF_VERSION))
        f.write(struct.pack('<Q', n_tensors))
        f.write(struct.pack('<Q', n_kv))

        # Metadata KV
        for item in metadata:
            if item[0] == 's':
                write_kv_string(f, item[1], item[2])
            elif item[0] == 'u':
                write_kv_uint32(f, item[1], item[2])
            elif item[0] == 'f':
                write_kv_float32(f, item[1], item[2])
            elif item[0] == 'sa':
                write_kv_string_array(f, item[1], item[2])
            elif item[0] == 'fa':
                # Float array
                write_string(f, item[1])
                f.write(struct.pack('<I', GGUF_TYPE_ARRAY))
                f.write(struct.pack('<I', GGUF_TYPE_FLOAT32))
                f.write(struct.pack('<Q', len(item[2])))
                for v in item[2]:
                    f.write(struct.pack('<f', v))

        # Pre-compute tensor data offsets (before writing tensor info)
        offsets = []
        cur_offset = 0
        for t in gguf_tensors:
            offsets.append(cur_offset)
            cur_offset += len(t['data'])
            # Align
            pad = (ALIGNMENT - (cur_offset % ALIGNMENT)) % ALIGNMENT
            cur_offset += pad

        # Tensor info headers (with pre-computed offsets)
        for i, t in enumerate(gguf_tensors):
            write_string(f, t['name'])
            n_dims = len(t['shape'])
            f.write(struct.pack('<I', n_dims))
            for dim in t['shape']:
                f.write(struct.pack('<Q', dim))
            f.write(struct.pack('<I', t['type']))
            f.write(struct.pack('<Q', offsets[i]))

        # Align to ALIGNMENT boundary before tensor data
        pos = f.tell()
        pad = (ALIGNMENT - (pos % ALIGNMENT)) % ALIGNMENT
        f.write(b'\x00' * pad)

        # Write tensor data with alignment
        for t in gguf_tensors:
            f.write(t['data'])
            pos = f.tell()
            pad = (ALIGNMENT - (pos % ALIGNMENT)) % ALIGNMENT
            f.write(b'\x00' * pad)

    file_size = Path(args.output).stat().st_size
    print(f"\nDone! Written {args.output} ({file_size / 1024 / 1024:.1f} MB)")
    print(f"  Encoder: {ac.get('encoder_layers', 18)} layers, d={ac.get('d_model', 896)}")
    print(f"  Decoder: {dc.get('num_hidden_layers', 28)} layers, d={dc.get('hidden_size', 1024)}")


if __name__ == '__main__':
    main()
