#!/usr/bin/env python3
# WARNING: The Q4_K nibble packing layout in this script is broken.
# The low/high nibble assignment in the weight bytes does not match the
# llama.cpp / GGML reference implementation. Models quantized with this
# script will produce garbage when loaded by conforming GGUF readers.
# Do not use for production models until the nibble layout is fixed.
"""Quantize a byte-level shell completion model to Q4_K GGUF.

Q4_K format (per block of 256 elements):
  - d (f16): block scale
  - dmin (f16): block min scale
  - scales[12]: packed 6-bit scale/min per 32-element sub-block
  - weights[128]: 4-bit quantized weights (2 per byte)

Usage:
    python scripts/quantize_gguf.py
"""

import struct
import numpy as np
import torch
import sys
from pathlib import Path

sys.path.insert(0, '.')
from scripts.train_byte_model import ByteGPT

QK_K = 256  # elements per Q4_K block

def float_to_f16_bytes(f):
    """Convert float to f16 stored as u16."""
    return np.float16(f).view(np.uint16).item()

def quantize_q4k_block(data):
    """Quantize 256 floats to one Q4_K block (144 bytes).

    Split into 8 sub-blocks of 32 elements each.
    Each sub-block has its own scale and min.
    Scales are packed into 12 bytes (6 bits each).
    Weights are 4-bit (0-15) packed 2 per byte.
    """
    assert len(data) == QK_K

    n_sub = 8  # 8 sub-blocks of 32
    sub_size = 32

    scales = np.zeros(n_sub, dtype=np.float32)
    mins = np.zeros(n_sub, dtype=np.float32)

    # Compute per-sub-block scales and mins
    for j in range(n_sub):
        sub = data[j*sub_size : (j+1)*sub_size]
        sub_min = sub.min()
        sub_max = sub.max()
        mins[j] = sub_min
        d = sub_max - sub_min
        scales[j] = d / 15.0 if d > 0 else 0  # 4-bit: 0-15 range

    # Find global d and dmin
    max_scale = np.max(np.abs(scales))
    max_min = np.max(np.abs(mins))

    if max_scale > 0:
        d = max_scale / 63.0  # 6-bit quantization of scales
    else:
        d = 0

    if max_min > 0:
        dmin = max_min / 63.0
    else:
        dmin = 0

    # Quantize scales and mins to 6-bit integers
    iscales = np.zeros(n_sub, dtype=np.uint8)
    imins = np.zeros(n_sub, dtype=np.uint8)
    for j in range(n_sub):
        if d > 0:
            iscales[j] = min(63, int(round(scales[j] / d)))
        if dmin > 0:
            imins[j] = min(63, int(round(-mins[j] / dmin)))

    # Pack scales into 12 bytes
    # Format: first 4 scales in bytes 0-3 (low 6 bits), first 4 mins in bytes 4-7 (low 6 bits)
    # scales 4-7 in bytes 8-11 (combined with high bits from 0-3)
    scale_bytes = bytearray(12)
    for j in range(4):
        scale_bytes[j] = (iscales[j] & 0x3f) | ((iscales[j+4] & 0x03) << 6)
        scale_bytes[j+4] = (imins[j] & 0x3f) | ((imins[j+4] & 0x03) << 6)
    for j in range(4):
        scale_bytes[j+8] = ((iscales[j+4] >> 2) & 0x0f) | (((imins[j+4] >> 2) & 0x0f) << 4)

    # Quantize weights to 4-bit using the scales
    # GGML Q4_K layout: process 64 elements at a time (2 sub-blocks).
    # Bytes 0-31 hold: low nibble = elements 0-31, high nibble = elements 32-63.
    # Then bytes 32-63 for elements 64-127, etc.
    quants = np.zeros(QK_K, dtype=np.uint8)
    for j in range(n_sub):
        sc = d * iscales[j]
        mn = dmin * imins[j]
        for k in range(sub_size):
            idx = j * sub_size + k
            x = data[idx]
            if sc > 0:
                q = int(round((x + mn) / sc))
                q = max(0, min(15, q))
            else:
                q = 0
            quants[idx] = q

    weights = bytearray(128)
    for jj in range(4):  # 4 pairs of sub-blocks (64 elements each)
        base_elem = jj * 64
        for l in range(32):
            lo = quants[base_elem + l] & 0x0f       # elements 0-31
            hi = quants[base_elem + 32 + l] & 0x0f  # elements 32-63
            weights[jj * 32 + l] = lo | (hi << 4)

    # Build block: d(u16) + dmin(u16) + scales[12] + weights[128] = 144 bytes
    block = struct.pack('<HH', float_to_f16_bytes(d), float_to_f16_bytes(dmin))
    block += bytes(scale_bytes) + bytes(weights)
    assert len(block) == 144
    return block


def quantize_tensor_q4k(tensor_f32):
    """Quantize a flat f32 tensor to Q4_K blocks."""
    data = tensor_f32.numpy().flatten()
    n = len(data)
    # Pad to multiple of QK_K
    if n % QK_K != 0:
        padded = np.zeros(((n + QK_K - 1) // QK_K) * QK_K, dtype=np.float32)
        padded[:n] = data
        data = padded

    n_blocks = len(data) // QK_K
    result = bytearray()
    for i in range(n_blocks):
        block_data = data[i*QK_K : (i+1)*QK_K]
        result.extend(quantize_q4k_block(block_data))
    return bytes(result), n_blocks


# GGUF writing helpers
GGUF_MAGIC = 0x46554747
GGUF_VERSION = 3
GGUF_TYPE_UINT32 = 4
GGUF_TYPE_STRING = 8
GGUF_TYPE_ARRAY = 9
GGUF_TYPE_FLOAT32 = 6
GGML_TYPE_F32 = 0
GGML_TYPE_F16 = 1
GGML_TYPE_Q4_K = 12

def write_string(f, s):
    b = s.encode('utf-8') if isinstance(s, str) else s
    f.write(struct.pack('<Q', len(b)))
    f.write(b)

def write_kv_string(f, k, v):
    write_string(f, k); f.write(struct.pack('<I', GGUF_TYPE_STRING)); write_string(f, v)

def write_kv_uint32(f, k, v):
    write_string(f, k); f.write(struct.pack('<I', GGUF_TYPE_UINT32)); f.write(struct.pack('<I', v))

def write_kv_string_array(f, k, strings):
    write_string(f, k); f.write(struct.pack('<I', GGUF_TYPE_ARRAY))
    f.write(struct.pack('<I', GGUF_TYPE_STRING)); f.write(struct.pack('<Q', len(strings)))
    for s in strings:
        b = s.encode('utf-8', errors='replace') if isinstance(s, str) else s
        f.write(struct.pack('<Q', len(b))); f.write(b)

def write_kv_float_array(f, k, values):
    write_string(f, k); f.write(struct.pack('<I', GGUF_TYPE_ARRAY))
    f.write(struct.pack('<I', GGUF_TYPE_FLOAT32)); f.write(struct.pack('<Q', len(values)))
    for v in values: f.write(struct.pack('<f', v))

def align_offset(offset, alignment=32):
    return (offset + alignment - 1) & ~(alignment - 1)


def main():
    print("Loading model...")
    model = ByteGPT(vocab_size=256, dim=256, n_layer=6, n_head=4, max_len=128)
    model.load_state_dict(torch.load('/tmp/byte_model_best.pt', map_location='cpu', weights_only=True))
    model.eval()

    state = model.state_dict()
    dim = 256
    n_layer = 6
    n_head = 4
    vocab_size = 256

    # Build tensor map: name → (data_bytes, shape, ggml_type)
    tensor_map = {}

    # Embedding and output: keep as f32 (small, need precision)
    emb = state['wte.weight'].float()
    tensor_map['token_embd.weight'] = (emb.numpy().tobytes(), emb.shape, GGML_TYPE_F32)

    out = state['lm_head.weight'].float()
    tensor_map['output.weight'] = (out.numpy().tobytes(), out.shape, GGML_TYPE_F32)

    # Attention and MLP weights: quantize to Q4_K
    for i in range(n_layer):
        p = f'blocks.{i}'
        for name, gguf_name in [
            (f'{p}.attn.c_q.weight', f'blk.{i}.attn_q.weight'),
            (f'{p}.attn.c_k.weight', f'blk.{i}.attn_k.weight'),
            (f'{p}.attn.c_v.weight', f'blk.{i}.attn_v.weight'),
            (f'{p}.attn.c_proj.weight', f'blk.{i}.attn_output.weight'),
            (f'{p}.mlp.c_fc.weight', f'blk.{i}.ffn_up.weight'),
            (f'{p}.mlp.c_proj.weight', f'blk.{i}.ffn_down.weight'),
        ]:
            w = state[name].float()
            q_data, n_blocks = quantize_tensor_q4k(w)
            tensor_map[gguf_name] = (q_data, w.shape, GGML_TYPE_Q4_K)
            print(f"  {gguf_name}: {w.shape} -> {n_blocks} Q4_K blocks ({len(q_data)} bytes)")

    # Tokenizer
    vocab_tokens = [bytes([i]).decode('latin-1') for i in range(256)]
    vocab_scores = [float(i) for i in range(256)]

    n_kv = 12
    tensor_infos = list(tensor_map.items())

    output_path = Path.home() / '.zish' / 'models' / 'shell_completion.gguf'

    with open(output_path, 'wb') as f:
        f.write(struct.pack('<I', GGUF_MAGIC))
        f.write(struct.pack('<I', GGUF_VERSION))
        f.write(struct.pack('<Q', len(tensor_infos)))
        f.write(struct.pack('<Q', n_kv))

        # Metadata
        write_kv_string(f, 'general.architecture', 'nanochat')
        write_kv_string(f, 'general.name', 'shell-completion-byte-q4k')
        write_kv_uint32(f, 'nanochat.context_length', 128)
        write_kv_uint32(f, 'nanochat.embedding_length', dim)
        write_kv_uint32(f, 'nanochat.block_count', n_layer)
        write_kv_uint32(f, 'nanochat.attention.head_count', n_head)
        write_kv_uint32(f, 'nanochat.attention.head_count_kv', n_head)
        write_kv_uint32(f, 'nanochat.vocab_size', vocab_size)
        write_kv_uint32(f, 'nanochat.feed_forward_length', dim * 4)
        write_kv_string(f, 'nanochat.activation', 'relu_squared')
        write_kv_string_array(f, 'tokenizer.ggml.tokens', vocab_tokens)
        write_kv_float_array(f, 'tokenizer.ggml.scores', vocab_scores)

        # Tensor infos
        data_offset = 0
        for name, (data_bytes, shape, t_type) in tensor_infos:
            write_string(f, name)
            f.write(struct.pack('<I', len(shape)))
            for dim_val in reversed(shape):
                f.write(struct.pack('<Q', dim_val))
            f.write(struct.pack('<I', t_type))
            f.write(struct.pack('<Q', data_offset))
            data_offset = align_offset(data_offset + len(data_bytes))

        # Align
        current = f.tell()
        aligned = align_offset(current)
        f.write(b'\x00' * (aligned - current))

        # Tensor data
        for name, (data_bytes, shape, t_type) in tensor_infos:
            f.write(data_bytes)
            current = f.tell()
            aligned = align_offset(current)
            if aligned > current:
                f.write(b'\x00' * (aligned - current))

    total_size = output_path.stat().st_size
    print(f"\nSaved: {output_path} ({total_size / 1024:.1f} KB)")

    # Compare sizes
    f32_size = sum(p.numel() * 4 for p in model.parameters())
    print(f"F32 would be: {f32_size / 1024:.1f} KB")
    print(f"Q4_K ratio: {total_size / f32_size:.2f}x")


if __name__ == '__main__':
    main()
