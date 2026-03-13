#!/usr/bin/env python3
"""Export Qwen2.5+CTM model to GGUF format for zish inference engine.

Usage:
    # Export HuggingFace backbone + CTM checkpoint to GGUF
    python export_ctm_gguf.py --backbone Qwen/Qwen2.5-0.5B \
        --ctm-checkpoint data/checkpoints/qwen_ctm_k32/ctm_005000.pt \
        --output model.gguf --quantize f16

    # Export backbone only (no CTM)
    python export_ctm_gguf.py --backbone Qwen/Qwen2.5-0.5B \
        --output model.gguf

    # Import GGUF back to PyTorch checkpoint (round-trip for continued training)
    python export_ctm_gguf.py --import-gguf model.gguf \
        --output ctm_weights.pt

Converts to GGUF v3 with:
  - Standard transformer tensors (embeddings, attention, MLP)
  - CTM-specific tensors (synapses, NLMs, sync indices, decay params)
  - Tokenizer from HuggingFace tokenizer

Quantization options:
  - f32: fully lossless (2x size)
  - f16: effectively lossless (backbone trains in BF16, same mantissa bits)
  - q8_0: ~2x compression, slight quality loss, NOT suitable for continued training
"""

import argparse
import struct
import sys
import json
from pathlib import Path

import numpy as np
import torch

# GGUF constants
GGUF_MAGIC = 0x46475547  # 'GGUF'
GGUF_VERSION = 3
ALIGNMENT = 32

# GGML types
GGML_TYPE_F32 = 0
GGML_TYPE_F16 = 1
GGML_TYPE_Q8_0 = 8
GGML_TYPE_Q4_K = 12

# GGUF metadata types
GGUF_TYPE_UINT32 = 4
GGUF_TYPE_FLOAT32 = 6
GGUF_TYPE_STRING = 8
GGUF_TYPE_ARRAY = 9


def write_string(f, s):
    encoded = s.encode('utf-8')
    f.write(struct.pack('<Q', len(encoded)))
    f.write(encoded)


def write_metadata_kv(f, key, value_type, value):
    write_string(f, key)
    f.write(struct.pack('<I', value_type))
    if value_type == GGUF_TYPE_UINT32:
        f.write(struct.pack('<I', value))
    elif value_type == GGUF_TYPE_FLOAT32:
        f.write(struct.pack('<f', value))
    elif value_type == GGUF_TYPE_STRING:
        write_string(f, value)
    elif value_type == GGUF_TYPE_ARRAY:
        elem_type, elements = value
        f.write(struct.pack('<I', elem_type))
        f.write(struct.pack('<Q', len(elements)))
        for elem in elements:
            if elem_type == GGUF_TYPE_STRING:
                write_string(f, elem)
            elif elem_type == GGUF_TYPE_FLOAT32:
                f.write(struct.pack('<f', elem))
            elif elem_type == GGUF_TYPE_UINT32:
                f.write(struct.pack('<I', elem))


def quantize_q8_0(tensor):
    """Quantize f32 tensor to Q8_0 blocks (32 elements each)."""
    flat = tensor.flatten().astype(np.float32)
    n = len(flat)
    # Pad to multiple of 32 if needed
    if n % 32 != 0:
        pad = 32 - (n % 32)
        flat = np.concatenate([flat, np.zeros(pad, dtype=np.float32)])
        n = len(flat)
    n_blocks = n // 32

    blocks = bytearray()
    for i in range(n_blocks):
        block = flat[i * 32:(i + 1) * 32]
        amax = np.max(np.abs(block))
        scale = amax / 127.0 if amax > 0 else 0.0
        scale_f16 = np.float16(scale)

        if scale > 0:
            inv_scale = 1.0 / scale
            quantized = np.clip(np.round(block * inv_scale), -128, 127).astype(np.int8)
        else:
            quantized = np.zeros(32, dtype=np.int8)

        blocks += struct.pack('<H', scale_f16.view(np.uint16).item())
        blocks += quantized.tobytes()

    return bytes(blocks)


def tensor_to_bytes(tensor, ggml_type):
    """Convert tensor to bytes in the specified GGML format."""
    data = tensor.detach().cpu().float().numpy()
    if ggml_type == GGML_TYPE_F32:
        return data.astype(np.float32).tobytes()
    elif ggml_type == GGML_TYPE_F16:
        return data.astype(np.float16).tobytes()
    elif ggml_type == GGML_TYPE_Q8_0:
        return quantize_q8_0(data)
    else:
        raise ValueError(f"Unsupported GGML type: {ggml_type}")


def ggml_type_size(ggml_type, n_elements):
    """Size in bytes for n_elements in given type."""
    if ggml_type == GGML_TYPE_F32:
        return n_elements * 4
    elif ggml_type == GGML_TYPE_F16:
        return n_elements * 2
    elif ggml_type == GGML_TYPE_Q8_0:
        n_padded = ((n_elements + 31) // 32) * 32
        return (n_padded // 32) * 34
    else:
        return n_elements * 4


def align_offset(offset):
    return (offset + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT


def load_hf_tokenizer_data(model_name):
    """Extract tokenizer data from HuggingFace for GGUF embedding."""
    from transformers import AutoTokenizer
    print(f"Loading tokenizer: {model_name}")
    tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)

    # Get vocabulary
    vocab = tokenizer.get_vocab()
    # Sort by token ID
    tokens_by_id = sorted(vocab.items(), key=lambda x: x[1])
    tokens = [t for t, _ in tokens_by_id]

    # Get merges if BPE
    merges = []
    if hasattr(tokenizer, 'backend_tokenizer'):
        bt = tokenizer.backend_tokenizer
        if hasattr(bt, 'model') and hasattr(bt.model, 'get_merges'):
            raw_merges = bt.model.get_merges()
            merges = [f"{a} {b}" for a, b in raw_merges]

    # Special tokens
    bos_id = tokenizer.convert_tokens_to_ids("<|endoftext|>")
    if bos_id is None or bos_id == tokenizer.unk_token_id:
        bos_id = 151643  # Qwen default
    eos_id = tokenizer.eos_token_id or 151645

    print(f"  Vocab size: {len(tokens)}, Merges: {len(merges)}, BOS: {bos_id}, EOS: {eos_id}")
    return {
        'tokens': tokens,
        'merges': merges,
        'bos_id': bos_id,
        'eos_id': eos_id,
    }


def export_model(backbone_name, ctm_checkpoint_path, output_path, quantize='f16'):
    """Export HuggingFace backbone + CTM checkpoint to GGUF."""
    from transformers import AutoModelForCausalLM, AutoConfig

    # Load HF config
    print(f"Loading backbone config: {backbone_name}")
    hf_config = AutoConfig.from_pretrained(backbone_name)

    n_embd = hf_config.hidden_size
    n_layer = hf_config.num_hidden_layers
    n_head = hf_config.num_attention_heads
    n_kv_head = hf_config.num_key_value_heads
    intermediate_size = hf_config.intermediate_size
    vocab_size = hf_config.vocab_size
    seq_len = min(hf_config.max_position_embeddings, 32768)

    # Get rope_theta from rope_scaling dict
    rope_scaling = getattr(hf_config, 'rope_scaling', {}) or {}
    rope_theta = rope_scaling.get('rope_theta', 10000.0)

    print(f"Model: dim={n_embd}, layers={n_layer}, heads={n_head}, kv_heads={n_kv_head}")
    print(f"Vocab: {vocab_size}, seq_len: {seq_len}, rope_theta: {rope_theta}")
    print(f"FFN: {intermediate_size}")

    # Load CTM checkpoint if provided
    use_ctm = ctm_checkpoint_path is not None
    ctm_state = None
    ctm_config = {}
    full_state = {}

    if use_ctm:
        print(f"Loading CTM checkpoint: {ctm_checkpoint_path}")
        ckpt = torch.load(ctm_checkpoint_path, map_location='cpu', weights_only=True)
        ctm_state = ckpt['ctm_state_dict']
        ctm_config = ckpt.get('config', {})
        step = ckpt.get('step', '?')
        val_bpb = ckpt.get('val_bpb', '?')
        print(f"  Step: {step}, Val BPB: {val_bpb}")
        print(f"  CTM tensors: {len(ctm_state)}")
        # Full model state dict may also be in checkpoint (has resid_lambdas, ve_gate, etc.)
        full_state = ckpt.get('model_state_dict', {})

    ctm_iterations = ctm_config.get('ctm_iterations', 32)
    ctm_memory_length = ctm_config.get('ctm_memory_length', 16)
    ctm_n_synch = ctm_config.get('ctm_n_synch', -1)
    if ctm_n_synch == -1:
        ctm_n_synch = n_embd // 2
    ctm_memory_hidden = ctm_config.get('ctm_memory_hidden', 32)
    ctm_synapse_depth = ctm_config.get('ctm_synapse_depth', 32)
    ctm_layers_spec = 'last'  # QwenBackboneGPT always uses last layer

    if use_ctm:
        print(f"CTM: K={ctm_iterations}, M={ctm_memory_length}, n_synch={ctm_n_synch}")
        print(f"  hidden={ctm_memory_hidden}, depth={ctm_synapse_depth}, layers={ctm_layers_spec}")

    # Determine quantization type
    weight_type = GGML_TYPE_F16
    if quantize == 'q8_0':
        weight_type = GGML_TYPE_Q8_0
    elif quantize == 'f32':
        weight_type = GGML_TYPE_F32

    ctm_layer_idx = n_layer - 1  # CTM is additive on top of last layer's MLP

    # Load HuggingFace model weights
    print(f"Loading backbone weights: {backbone_name}")
    backbone = AutoModelForCausalLM.from_pretrained(
        backbone_name, torch_dtype=torch.float32,  # load in f32 for precise export
    )
    hf_state = backbone.state_dict()

    # Collect all tensors to write
    tensors = []  # (name, data_tensor, ggml_type, dimensions)

    def add_tensor(name, tensor, qtype=None):
        if qtype is None:
            qtype = weight_type
        dims = list(tensor.shape)
        tensors.append((name, tensor, qtype, dims))

    # === Map HuggingFace Qwen2 state dict to GGUF ===
    # HF format: model.embed_tokens.weight, model.layers.{i}.*, model.norm.weight, lm_head.weight

    # Token embeddings
    add_tensor('token_embd.weight', hf_state['model.embed_tokens.weight'])

    # Output norm
    add_tensor('output_norm.weight', hf_state['model.norm.weight'], GGML_TYPE_F32)

    # LM head
    if 'lm_head.weight' in hf_state:
        add_tensor('output.weight', hf_state['lm_head.weight'])
    else:
        # Tied embeddings
        add_tensor('output.weight', hf_state['model.embed_tokens.weight'])

    # Transformer layers
    for i in range(n_layer):
        prefix = f'model.layers.{i}'

        # Input layernorm (attention norm)
        add_tensor(f'blk.{i}.attn_norm.weight',
                   hf_state[f'{prefix}.input_layernorm.weight'], GGML_TYPE_F32)

        # Q, K, V projections (separate in Qwen2)
        add_tensor(f'blk.{i}.attn_q.weight', hf_state[f'{prefix}.self_attn.q_proj.weight'])
        add_tensor(f'blk.{i}.attn_k.weight', hf_state[f'{prefix}.self_attn.k_proj.weight'])
        add_tensor(f'blk.{i}.attn_v.weight', hf_state[f'{prefix}.self_attn.v_proj.weight'])

        # Q, K biases (Qwen2 has attention biases)
        if f'{prefix}.self_attn.q_proj.bias' in hf_state:
            add_tensor(f'blk.{i}.attn_q.bias',
                       hf_state[f'{prefix}.self_attn.q_proj.bias'], GGML_TYPE_F32)
        if f'{prefix}.self_attn.k_proj.bias' in hf_state:
            add_tensor(f'blk.{i}.attn_k.bias',
                       hf_state[f'{prefix}.self_attn.k_proj.bias'], GGML_TYPE_F32)
        if f'{prefix}.self_attn.v_proj.bias' in hf_state:
            add_tensor(f'blk.{i}.attn_v.bias',
                       hf_state[f'{prefix}.self_attn.v_proj.bias'], GGML_TYPE_F32)

        # Attention output projection
        add_tensor(f'blk.{i}.attn_output.weight', hf_state[f'{prefix}.self_attn.o_proj.weight'])

        # Post-attention layernorm (FFN norm)
        add_tensor(f'blk.{i}.ffn_norm.weight',
                   hf_state[f'{prefix}.post_attention_layernorm.weight'], GGML_TYPE_F32)

        # Standard MLP (SwiGLU): gate_proj, up_proj, down_proj
        # ALWAYS included — even for CTM layers. CTM is additive, not a replacement.
        # The pretrained MLP captures backbone knowledge; CTM adds thinking on top.
        add_tensor(f'blk.{i}.ffn_gate.weight', hf_state[f'{prefix}.mlp.gate_proj.weight'])
        add_tensor(f'blk.{i}.ffn_up.weight', hf_state[f'{prefix}.mlp.up_proj.weight'])
        add_tensor(f'blk.{i}.ffn_down.weight', hf_state[f'{prefix}.mlp.down_proj.weight'])

        if use_ctm and i == ctm_layer_idx:
            # CTM block tensors (additive on top of MLP)
            # Cross-attention projections
            for src, dst in [
                ('attn_q_proj.weight', 'ctm_attn_q'),
                ('attn_k_proj.weight', 'ctm_attn_k'),
                ('attn_v_proj.weight', 'ctm_attn_v'),
                ('c_proj.weight', 'ctm_c_proj'),
            ]:
                if src in ctm_state:
                    add_tensor(f'blk.{i}.{dst}.weight', ctm_state[src], GGML_TYPE_F32)

            # NLMs (SuperLinear)
            for nlm_name in ['nlm1', 'nlm2']:
                w_key = f'{nlm_name}.w1'
                b_key = f'{nlm_name}.b1'
                if w_key in ctm_state:
                    add_tensor(f'blk.{i}.ctm_{nlm_name}.weight', ctm_state[w_key], GGML_TYPE_F32)
                if b_key in ctm_state:
                    add_tensor(f'blk.{i}.ctm_{nlm_name}.bias', ctm_state[b_key], GGML_TYPE_F32)

            # SynapseUNET layers
            j = 0
            while f'synapses.down_layers.{j}.weight' in ctm_state:
                add_tensor(f'blk.{i}.ctm_synapse_down.{j}.weight',
                           ctm_state[f'synapses.down_layers.{j}.weight'], GGML_TYPE_F32)
                j += 1

            j = 0
            while f'synapses.up_layers.{j}.weight' in ctm_state:
                add_tensor(f'blk.{i}.ctm_synapse_up.{j}.weight',
                           ctm_state[f'synapses.up_layers.{j}.weight'], GGML_TYPE_F32)
                j += 1

            j = 0
            while f'synapses.up_norms.{j}.weight' in ctm_state:
                add_tensor(f'blk.{i}.ctm_synapse_up_ln.{j}.weight',
                           ctm_state[f'synapses.up_norms.{j}.weight'], GGML_TYPE_F32)
                add_tensor(f'blk.{i}.ctm_synapse_up_ln.{j}.bias',
                           ctm_state[f'synapses.up_norms.{j}.bias'], GGML_TYPE_F32)
                j += 1

            # Learnable params
            for param in ['start_state', 'start_trace', 'tick_embed', 'decay_out', 'decay_act']:
                if param in ctm_state:
                    add_tensor(f'blk.{i}.ctm_{param}', ctm_state[param], GGML_TYPE_F32)

            # Sync neuron indices
            for idx_name in ['synch_out_left', 'synch_out_right', 'synch_act_left', 'synch_act_right']:
                if idx_name in ctm_state:
                    add_tensor(f'blk.{i}.ctm_{idx_name}', ctm_state[idx_name].int(), GGML_TYPE_F32)

            # Gate scalar: sigmoid(gate) controls CTM contribution.
            # Init negative → sigmoid ≈ 0 → CTM doesn't disrupt backbone at start.
            if 'gate' in ctm_state:
                add_tensor(f'blk.{i}.ctm_gate', ctm_state['gate'], GGML_TYPE_F32)
            else:
                # Default: -4.0 → sigmoid(-4) ≈ 0.018
                add_tensor(f'blk.{i}.ctm_gate', torch.tensor([-4.0]), GGML_TYPE_F32)

    # Merge CTM full model state dict if available (has resid_lambdas, ve_gate, etc.)
    all_states = dict(hf_state)
    if use_ctm and full_state:
        for k, v in full_state.items():
            if k not in all_states:
                all_states[k] = v

    # Residual scaling lambdas (per-layer scalars)
    for key_prefix in ['', 'transformer.']:
        rl_key = f'{key_prefix}resid_lambdas'
        xl_key = f'{key_prefix}x0_lambdas'
        if rl_key in all_states:
            add_tensor('resid_lambdas', all_states[rl_key], GGML_TYPE_F32)
            break
    for key_prefix in ['', 'transformer.']:
        xl_key = f'{key_prefix}x0_lambdas'
        if xl_key in all_states:
            add_tensor('x0_lambdas', all_states[xl_key], GGML_TYPE_F32)
            break

    # Value Embedding gates and embeddings (alternating layers, ResFormer-style)
    # has_ve(i) = i % 2 == (n_layer - 1) % 2
    ve_parity = (n_layer - 1) % 2
    n_ve_layers = 0
    for i in range(n_layer):
        if i % 2 != ve_parity:
            continue
        # VE gate weight: (n_kv_head, ve_gate_channels)
        # Try multiple naming conventions: HF, nanochat, and CTM full state
        ve_gate_found = False
        for ve_gate_key in [
            f'model.layers.{i}.self_attn.ve_gate.weight',
            f'transformer.h.{i}.attn.ve_gate.weight',
        ]:
            if ve_gate_key in all_states:
                add_tensor(f'blk.{i}.ve_gate.weight', all_states[ve_gate_key], GGML_TYPE_F32)
                n_ve_layers += 1
                ve_gate_found = True
                break

        # Value embedding: (vocab_size, kv_dim)
        ve_embed_key = f'transformer.value_embeds.{i}.weight'
        if ve_embed_key in all_states:
            add_tensor(f'blk.{i}.value_embed.weight', all_states[ve_embed_key])

    if n_ve_layers > 0:
        print(f"VE gate: {n_ve_layers} layers with value embeddings")

    print(f"Collected {len(tensors)} tensors")

    # Build metadata
    metadata = []
    metadata.append(('general.architecture', GGUF_TYPE_STRING, 'qwen2'))
    metadata.append(('general.name', GGUF_TYPE_STRING,
                     f'qwen2.5-ctm-k{ctm_iterations}' if use_ctm else 'qwen2.5'))
    metadata.append(('general.quantization', GGUF_TYPE_STRING, quantize))
    metadata.append(('qwen2.embedding_length', GGUF_TYPE_UINT32, n_embd))
    metadata.append(('qwen2.feed_forward_length', GGUF_TYPE_UINT32, intermediate_size))
    metadata.append(('qwen2.block_count', GGUF_TYPE_UINT32, n_layer))
    metadata.append(('qwen2.attention.head_count', GGUF_TYPE_UINT32, n_head))
    metadata.append(('qwen2.attention.head_count_kv', GGUF_TYPE_UINT32, n_kv_head))
    metadata.append(('qwen2.context_length', GGUF_TYPE_UINT32, seq_len))
    metadata.append(('qwen2.rope.freq_base', GGUF_TYPE_FLOAT32, rope_theta))
    metadata.append(('qwen2.ve_gate_channels', GGUF_TYPE_UINT32, 32))

    # CTM metadata
    if use_ctm:
        metadata.append(('qwen2.ctm.enabled', GGUF_TYPE_UINT32, 1))
        metadata.append(('qwen2.ctm.iterations', GGUF_TYPE_UINT32, ctm_iterations))
        metadata.append(('qwen2.ctm.memory_length', GGUF_TYPE_UINT32, ctm_memory_length))
        metadata.append(('qwen2.ctm.n_synch', GGUF_TYPE_UINT32, ctm_n_synch))
        metadata.append(('qwen2.ctm.memory_hidden', GGUF_TYPE_UINT32, ctm_memory_hidden))
        metadata.append(('qwen2.ctm.synapse_depth', GGUF_TYPE_UINT32, ctm_synapse_depth))
        metadata.append(('qwen2.ctm.layers', GGUF_TYPE_STRING, ctm_layers_spec))
        metadata.append(('qwen2.ctm.layer_idx', GGUF_TYPE_UINT32, ctm_layer_idx))
        if 'step' in (ctm_config or {}):
            metadata.append(('qwen2.ctm.training_step', GGUF_TYPE_UINT32, ctm_config.get('step', 0)))

    # Tokenizer from HuggingFace
    tok_data = load_hf_tokenizer_data(backbone_name)
    metadata.append(('tokenizer.ggml.model', GGUF_TYPE_STRING, 'gpt2'))  # BPE type
    metadata.append(('tokenizer.ggml.tokens', GGUF_TYPE_ARRAY,
                     (GGUF_TYPE_STRING, tok_data['tokens'])))
    if tok_data['merges']:
        metadata.append(('tokenizer.ggml.merges', GGUF_TYPE_ARRAY,
                         (GGUF_TYPE_STRING, tok_data['merges'])))
    metadata.append(('tokenizer.ggml.bos_token_id', GGUF_TYPE_UINT32, tok_data['bos_id']))
    metadata.append(('tokenizer.ggml.eos_token_id', GGUF_TYPE_UINT32, tok_data['eos_id']))

    # Write GGUF file
    write_gguf(output_path, metadata, tensors)

    # Free backbone memory
    del backbone, hf_state
    if use_ctm:
        del ctm_state


def write_gguf(output_path, metadata, tensors):
    """Write GGUF v3 file."""
    print(f"Writing GGUF to: {output_path}")
    with open(output_path, 'wb') as f:
        # Header
        f.write(struct.pack('<I', GGUF_MAGIC))
        f.write(struct.pack('<I', GGUF_VERSION))
        f.write(struct.pack('<Q', len(tensors)))
        f.write(struct.pack('<Q', len(metadata)))

        # Metadata KV pairs
        for key, vtype, value in metadata:
            write_metadata_kv(f, key, vtype, value)

        # Tensor infos
        tensor_data_list = []
        data_offset = 0
        for name, tensor, qtype, dims in tensors:
            n_elements = 1
            for d in dims:
                n_elements *= d
            data_size = ggml_type_size(qtype, n_elements)
            aligned_offset = align_offset(data_offset)

            write_string(f, name)
            f.write(struct.pack('<I', len(dims)))
            for d in dims:
                f.write(struct.pack('<Q', d))
            f.write(struct.pack('<I', qtype))
            f.write(struct.pack('<Q', aligned_offset))

            tensor_data_list.append((tensor, qtype, data_size, aligned_offset))
            data_offset = aligned_offset + data_size

        # Alignment padding before tensor data
        current_pos = f.tell()
        aligned_pos = align_offset(current_pos)
        if aligned_pos > current_pos:
            f.write(b'\x00' * (aligned_pos - current_pos))

        tensor_data_start = f.tell()

        # Write tensor data
        for idx, (tensor, qtype, data_size, aligned_offset) in enumerate(tensor_data_list):
            target_pos = tensor_data_start + aligned_offset
            current = f.tell()
            if target_pos > current:
                f.write(b'\x00' * (target_pos - current))

            data = tensor_to_bytes(tensor, qtype)
            f.write(data)

            if (idx + 1) % 50 == 0:
                print(f"  Written {idx + 1}/{len(tensor_data_list)} tensors...")

    file_size = Path(output_path).stat().st_size
    print(f"Done! {file_size / 1024 / 1024:.1f} MB written ({len(tensor_data_list)} tensors)")


def import_gguf(gguf_path, output_path):
    """Import GGUF back to PyTorch CTM checkpoint for continued training.

    Only extracts CTM tensors (the backbone comes from HuggingFace).
    Produces a .pt file compatible with QwenBackboneGPT.load_ctm_state_dict().
    """
    print(f"Reading GGUF: {gguf_path}")

    with open(gguf_path, 'rb') as f:
        # Header
        magic = struct.unpack('<I', f.read(4))[0]
        assert magic == GGUF_MAGIC, f"Not a GGUF file (magic: {magic:#x})"
        version = struct.unpack('<I', f.read(4))[0]
        assert version == GGUF_VERSION, f"Unsupported GGUF version: {version}"
        n_tensors = struct.unpack('<Q', f.read(8))[0]
        n_kv = struct.unpack('<Q', f.read(8))[0]

        # Read metadata
        metadata = {}
        for _ in range(n_kv):
            key = read_string(f)
            vtype = struct.unpack('<I', f.read(4))[0]
            value = read_metadata_value(f, vtype)
            metadata[key] = value

        # Read tensor infos
        tensor_infos = []
        for _ in range(n_tensors):
            name = read_string(f)
            n_dims = struct.unpack('<I', f.read(4))[0]
            dims = [struct.unpack('<Q', f.read(8))[0] for _ in range(n_dims)]
            qtype = struct.unpack('<I', f.read(4))[0]
            offset = struct.unpack('<Q', f.read(8))[0]
            tensor_infos.append((name, dims, qtype, offset))

        # Align to tensor data start
        current_pos = f.tell()
        tensor_data_start = align_offset(current_pos)
        f.seek(tensor_data_start)

        # Extract CTM tensors
        ctm_state_dict = {}
        ctm_prefix = None

        # Find which layer has CTM
        for name, dims, qtype, offset in tensor_infos:
            if '.ctm_attn_q.' in name:
                # Extract layer index: blk.{i}.ctm_attn_q.weight -> i
                parts = name.split('.')
                ctm_prefix = f'blk.{parts[1]}'
                break

        if ctm_prefix is None:
            print("No CTM tensors found in GGUF file.")
            return

        print(f"Found CTM tensors at {ctm_prefix}")

        # GGUF name -> PyTorch CTM state_dict name mapping
        name_map = {
            'ctm_attn_q.weight': 'attn_q_proj.weight',
            'ctm_attn_k.weight': 'attn_k_proj.weight',
            'ctm_attn_v.weight': 'attn_v_proj.weight',
            'ctm_c_proj.weight': 'c_proj.weight',
        }

        for name, dims, qtype, offset in tensor_infos:
            if not name.startswith(ctm_prefix + '.ctm_'):
                continue

            # Read tensor data
            f.seek(tensor_data_start + offset)
            n_elements = 1
            for d in dims:
                n_elements *= d

            tensor = read_tensor_data(f, qtype, n_elements, dims)

            # Map GGUF name to PyTorch name
            # blk.{i}.ctm_xxx -> xxx
            suffix = name[len(ctm_prefix) + 1:]  # strip "blk.{i}."

            # Check direct mappings
            if suffix in name_map:
                pt_name = name_map[suffix]
            elif suffix.startswith('ctm_nlm'):
                # ctm_nlm1.weight -> nlm1.w1, ctm_nlm1.bias -> nlm1.b1
                parts = suffix.split('.')
                nlm_name = parts[0].replace('ctm_', '')  # nlm1 or nlm2
                param_type = 'w1' if parts[1] == 'weight' else 'b1'
                pt_name = f'{nlm_name}.{param_type}'
            elif suffix.startswith('ctm_synapse_down.'):
                # ctm_synapse_down.{j}.weight -> synapses.down_layers.{j}.weight
                parts = suffix.split('.')
                pt_name = f'synapses.down_layers.{parts[1]}.weight'
            elif suffix.startswith('ctm_synapse_up_ln.'):
                # ctm_synapse_up_ln.{j}.weight -> synapses.up_norms.{j}.weight
                parts = suffix.split('.')
                param_type = parts[2]  # weight or bias
                pt_name = f'synapses.up_norms.{parts[1]}.{param_type}'
            elif suffix.startswith('ctm_synapse_up.'):
                # ctm_synapse_up.{j}.weight -> synapses.up_layers.{j}.weight
                parts = suffix.split('.')
                pt_name = f'synapses.up_layers.{parts[1]}.weight'
            elif suffix.startswith('ctm_synch_'):
                # ctm_synch_out_left -> synch_out_left
                pt_name = suffix.replace('ctm_', '')
            elif suffix.startswith('ctm_'):
                # ctm_start_state -> start_state, ctm_decay_out -> decay_out, etc.
                pt_name = suffix.replace('ctm_', '')
            else:
                print(f"  Skipping unknown CTM tensor: {name}")
                continue

            ctm_state_dict[pt_name] = tensor
            print(f"  {name} -> {pt_name} {list(tensor.shape)}")

        # Build checkpoint
        config = {}
        for key, value in metadata.items():
            if key.startswith('qwen2.ctm.'):
                param = key.replace('qwen2.ctm.', '')
                if param == 'enabled':
                    continue
                config[f'ctm_{param}'] = value

        checkpoint = {
            'ctm_state_dict': ctm_state_dict,
            'config': config,
            'source': str(gguf_path),
        }

        print(f"Saving PyTorch checkpoint: {output_path}")
        torch.save(checkpoint, output_path)
        print(f"  {len(ctm_state_dict)} CTM tensors saved")
        print(f"  Load with: model.load_ctm_state_dict(ckpt['ctm_state_dict'])")


def read_string(f):
    length = struct.unpack('<Q', f.read(8))[0]
    return f.read(length).decode('utf-8')


def read_metadata_value(f, vtype):
    if vtype == GGUF_TYPE_UINT32:
        return struct.unpack('<I', f.read(4))[0]
    elif vtype == GGUF_TYPE_FLOAT32:
        return struct.unpack('<f', f.read(4))[0]
    elif vtype == GGUF_TYPE_STRING:
        return read_string(f)
    elif vtype == GGUF_TYPE_ARRAY:
        elem_type = struct.unpack('<I', f.read(4))[0]
        n_elements = struct.unpack('<Q', f.read(8))[0]
        elements = []
        for _ in range(n_elements):
            elements.append(read_metadata_value(f, elem_type))
        return elements
    else:
        raise ValueError(f"Unknown metadata type: {vtype}")


def read_tensor_data(f, qtype, n_elements, dims):
    """Read tensor data from GGUF and convert to PyTorch tensor."""
    shape = list(dims)

    if qtype == GGML_TYPE_F32:
        data = np.frombuffer(f.read(n_elements * 4), dtype=np.float32).copy()
        return torch.from_numpy(data.reshape(shape))
    elif qtype == GGML_TYPE_F16:
        data = np.frombuffer(f.read(n_elements * 2), dtype=np.float16).copy()
        return torch.from_numpy(data.astype(np.float32).reshape(shape))
    elif qtype == GGML_TYPE_Q8_0:
        # Dequantize Q8_0 blocks
        n_padded = ((n_elements + 31) // 32) * 32
        n_blocks = n_padded // 32
        raw = f.read(n_blocks * 34)
        result = np.zeros(n_padded, dtype=np.float32)
        for i in range(n_blocks):
            block_start = i * 34
            scale = np.frombuffer(raw[block_start:block_start + 2], dtype=np.float16)[0]
            quantized = np.frombuffer(raw[block_start + 2:block_start + 34], dtype=np.int8)
            result[i * 32:(i + 1) * 32] = quantized.astype(np.float32) * float(scale)
        return torch.from_numpy(result[:n_elements].reshape(shape))
    else:
        raise ValueError(f"Unsupported GGML type for import: {qtype}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Export/import Qwen2.5+CTM GGUF')

    # Export mode
    parser.add_argument('--backbone', type=str, default='Qwen/Qwen2.5-0.5B',
                        help='HuggingFace model name (default: Qwen/Qwen2.5-0.5B)')
    parser.add_argument('--ctm-checkpoint', type=str, default=None,
                        help='CTM checkpoint .pt file (omit for backbone-only export)')
    parser.add_argument('--output', '-o', type=str, required=True,
                        help='Output file (.gguf for export, .pt for import)')
    parser.add_argument('--quantize', choices=['f32', 'f16', 'q8_0'], default='f16',
                        help='Weight quantization (default: f16, use f32 for fully lossless)')

    # Import mode
    parser.add_argument('--import-gguf', type=str, default=None,
                        help='Import CTM weights from GGUF back to .pt for continued training')

    args = parser.parse_args()

    if args.import_gguf:
        import_gguf(args.import_gguf, args.output)
    else:
        export_model(args.backbone, args.ctm_checkpoint, args.output, args.quantize)
