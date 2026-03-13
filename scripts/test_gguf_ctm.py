#!/usr/bin/env python3
"""Test CTM forward pass using weights loaded from GGUF, via nanochat Python code.
Validates that the exported weights produce valid (non-NaN) outputs."""

import struct
import sys
import numpy as np

GGUF_PATH = sys.argv[1] if len(sys.argv) > 1 else "/home/alice/.zish/models/qwen25_ctm_k32.gguf"

# Minimal GGUF reader to extract tensors
def read_gguf(path):
    with open(path, 'rb') as f:
        magic = struct.unpack('<I', f.read(4))[0]
        version = struct.unpack('<I', f.read(4))[0]
        tensor_count = struct.unpack('<Q', f.read(8))[0]
        kv_count = struct.unpack('<Q', f.read(8))[0]

        print(f"GGUF v{version}: {tensor_count} tensors, {kv_count} metadata")

        def read_string():
            slen = struct.unpack('<Q', f.read(8))[0]
            return f.read(slen).decode('utf-8')

        def read_value(vtype):
            if vtype == 4: return struct.unpack('<I', f.read(4))[0]
            elif vtype == 5: return struct.unpack('<i', f.read(4))[0]
            elif vtype == 6: return struct.unpack('<f', f.read(4))[0]
            elif vtype == 8: return read_string()
            elif vtype == 0: return struct.unpack('<B', f.read(1))[0]
            elif vtype == 10: return struct.unpack('<Q', f.read(8))[0]
            elif vtype == 9:
                etype = struct.unpack('<I', f.read(4))[0]
                elen = struct.unpack('<Q', f.read(8))[0]
                return [read_value(etype) for _ in range(elen)]
            else: raise ValueError(f"Unknown type {vtype}")

        metadata = {}
        for i in range(kv_count):
            key = read_string()
            vtype = struct.unpack('<I', f.read(4))[0]
            val = read_value(vtype)
            metadata[key] = val

        # Read tensor info
        tensor_info = []
        for t in range(tensor_count):
            name = read_string()
            ndim = struct.unpack('<I', f.read(4))[0]
            dims = [struct.unpack('<Q', f.read(8))[0] for _ in range(ndim)]
            dtype = struct.unpack('<I', f.read(4))[0]
            offset = struct.unpack('<Q', f.read(8))[0]
            tensor_info.append((name, dims, dtype, offset))

        # Align to data start
        data_offset = f.tell()
        alignment = metadata.get('general.alignment', 32)
        data_offset = (data_offset + alignment - 1) // alignment * alignment

    return metadata, tensor_info, data_offset

def load_tensor(path, data_offset, ti):
    name, dims, dtype, offset = ti
    import mmap
    with open(path, 'rb') as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        start = data_offset + offset
        n_elements = 1
        for d in dims:
            n_elements *= d
        if dtype == 0:  # F32
            arr = np.frombuffer(mm[start:start + n_elements * 4], dtype=np.float32).copy()
        elif dtype == 1:  # F16
            arr = np.frombuffer(mm[start:start + n_elements * 2], dtype=np.float16).copy().astype(np.float32)
        else:
            raise ValueError(f"Unsupported dtype {dtype}")
        mm.close()
    # Keep PyTorch row-major layout: dims as stored match the flat data layout
    # For linearForward: w stored as (out_features, in_features) row-major
    if len(dims) == 2:
        arr = arr.reshape(dims[0], dims[1])
    elif len(dims) == 3:
        arr = arr.reshape(dims[0], dims[1], dims[2])
    else:
        arr = arr.reshape(dims)
    return arr

metadata, tensor_info, data_offset = read_gguf(GGUF_PATH)

# Print relevant metadata
for k, v in metadata.items():
    if 'ctm' in k or 'block_count' in k or 'embedding' in k or 'feed_forward' in k:
        print(f"  {k} = {v}")

# Build tensor lookup
ti_map = {ti[0]: ti for ti in tensor_info}

def get_tensor(name):
    return load_tensor(GGUF_PATH, data_offset, ti_map[name])

# Load CTM weights for layer 23
print("\n=== Loading CTM weights ===")
layer = 23

# Cross-attention projections
attn_q_w = get_tensor(f'blk.{layer}.ctm_attn_q.weight')
attn_k_w = get_tensor(f'blk.{layer}.ctm_attn_k.weight')
attn_v_w = get_tensor(f'blk.{layer}.ctm_attn_v.weight')
c_proj_w = get_tensor(f'blk.{layer}.ctm_c_proj.weight')
print(f"  attn_q_w: {attn_q_w.shape}, attn_k_w: {attn_k_w.shape}")
print(f"  attn_v_w: {attn_v_w.shape}, c_proj_w: {c_proj_w.shape}")

# Start state and trace
start_state = get_tensor(f'blk.{layer}.ctm_start_state')
start_trace = get_tensor(f'blk.{layer}.ctm_start_trace')
print(f"  start_state: {start_state.shape}, start_trace: {start_trace.shape}")

# Tick embed
tick_embed = get_tensor(f'blk.{layer}.ctm_tick_embed')
print(f"  tick_embed: {tick_embed.shape}")

# NLM1 weights/biases
nlm1_w = get_tensor(f'blk.{layer}.ctm_nlm1.weight')
nlm1_b = get_tensor(f'blk.{layer}.ctm_nlm1.bias')
print(f"  nlm1_w: {nlm1_w.shape}, nlm1_b: {nlm1_b.shape}")

nlm2_w = get_tensor(f'blk.{layer}.ctm_nlm2.weight')
nlm2_b = get_tensor(f'blk.{layer}.ctm_nlm2.bias')
print(f"  nlm2_w: {nlm2_w.shape}, nlm2_b: {nlm2_b.shape}")

# Decay
decay_out = get_tensor(f'blk.{layer}.ctm_decay_out')
decay_act = get_tensor(f'blk.{layer}.ctm_decay_act')
print(f"  decay: out={decay_out.shape} act={decay_act.shape}")

# Sync indices
synch_out_left = get_tensor(f'blk.{layer}.ctm_synch_out_left').astype(np.int64)
synch_out_right = get_tensor(f'blk.{layer}.ctm_synch_out_right').astype(np.int64)
synch_act_left = get_tensor(f'blk.{layer}.ctm_synch_act_left').astype(np.int64)
synch_act_right = get_tensor(f'blk.{layer}.ctm_synch_act_right').astype(np.int64)
print(f"  sync indices: {synch_out_left.shape}")

# Synapse weights
half_k = 16
print(f"\n  Loading {half_k} down + {half_k} up synapse layers...")
down_w = []
up_w = []
up_ln_w = []
up_ln_b = []
for j in range(half_k):
    dw = get_tensor(f'blk.{layer}.ctm_synapse_down.{j}.weight')
    down_w.append(dw)
    uw = get_tensor(f'blk.{layer}.ctm_synapse_up.{j}.weight')
    up_w.append(uw)
    ulw = get_tensor(f'blk.{layer}.ctm_synapse_up_ln.{j}.weight')
    ulb = get_tensor(f'blk.{layer}.ctm_synapse_up_ln.{j}.bias')
    up_ln_w.append(ulw)
    up_ln_b.append(ulb)

print(f"  down[0]: {down_w[0].shape}, down[15]: {down_w[15].shape}")
print(f"  up[0]: {up_w[0].shape}, up[15]: {up_w[15].shape}")

# Check for NaN/inf in loaded weights
print("\n=== Weight sanity check ===")
for name, arr in [('attn_q_w', attn_q_w), ('attn_k_w', attn_k_w), ('attn_v_w', attn_v_w),
                   ('c_proj_w', c_proj_w), ('start_state', start_state), ('start_trace', start_trace),
                   ('nlm1_w', nlm1_w), ('nlm1_b', nlm1_b), ('nlm2_w', nlm2_w), ('nlm2_b', nlm2_b),
                   ('tick_embed', tick_embed), ('decay_out', decay_out)]:
    nan_count = np.isnan(arr).sum()
    inf_count = np.isinf(arr).sum()
    if nan_count > 0 or inf_count > 0:
        print(f"  PROBLEM: {name}: nan={nan_count} inf={inf_count}")
    else:
        print(f"  OK: {name}: range=[{arr.min():.4f}, {arr.max():.4f}]")

for j in range(half_k):
    for name, arr in [(f'down[{j}]', down_w[j]), (f'up[{j}]', up_w[j])]:
        if np.isnan(arr).sum() > 0:
            print(f"  PROBLEM: {name}: nan={np.isnan(arr).sum()}")

# ===== Now simulate the CTM forward pass like Zig does =====
print("\n=== Simulating CTM forward pass ===")
D = 896
K = 32
M = 16
n_synch = 448
hidden = 32

# Fake input (like what layer 23 attention would produce)
np.random.seed(42)
x = np.random.randn(D).astype(np.float32) * 0.1

# Initialize state and trace from start params
state = start_state.flatten().copy()
trace = start_trace.flatten().copy()  # (D, M) row-major
print(f"  start_state: range=[{state.min():.4f}, {state.max():.4f}]")
print(f"  start_trace: range=[{trace.min():.4f}, {trace.max():.4f}]")

# Initialize sync accumulators
alpha_out = np.zeros(n_synch, dtype=np.float32)
beta_out = np.ones(n_synch, dtype=np.float32)
alpha_act = np.zeros(n_synch, dtype=np.float32)
beta_act = np.ones(n_synch, dtype=np.float32)

# Seed sync from start_state
for s in range(n_synch):
    pp = state[synch_out_left[s]] * state[synch_out_right[s]]
    alpha_out[s] = pp
    beta_out[s] = 1.0
for s in range(n_synch):
    pp = state[synch_act_left[s]] * state[synch_act_right[s]]
    alpha_act[s] = pp
    beta_act[s] = 1.0

# Precompute decay
r_out = np.exp(-np.clip(decay_out.flatten(), 0, 15))
r_act = np.exp(-np.clip(decay_act.flatten(), 0, 15))

# Precompute keys and values (constant across ticks)
# linearForward: out[i] = sum_j(x[j] * w[i, j])
attn_k_val = attn_k_w @ x
attn_k_val = attn_k_val / (np.sqrt(np.sum(attn_k_val**2) / D) + 1e-6)
attn_v_val = attn_v_w @ x

def silu(x):
    return x / (1 + np.exp(-np.clip(x, -20, 20)))

def layer_norm(x, w, b):
    mean = x.mean()
    var = x.var()
    return (x - mean) / np.sqrt(var + 1e-5) * w + b

print(f"  attn_k: range=[{attn_k_val.min():.4f}, {attn_k_val.max():.4f}]")
print(f"  attn_v: range=[{attn_v_val.min():.4f}, {attn_v_val.max():.4f}]")

for k in range(min(K, 4)):  # Only first 4 iterations
    # 1. Sync readout
    synch_readout = np.where(beta_act > 1e-16, alpha_act / np.sqrt(beta_act), 0)

    # 2. Cross-attention query
    attn_q = attn_q_w @ synch_readout
    attn_q_norm = attn_q / (np.sqrt(np.sum(attn_q**2) / D) + 1e-6)

    # Simplified attention: element-wise
    head_size = D  # n_attn_heads=1
    scale = np.sqrt(head_size)
    obs = (attn_q_norm * attn_k_val / scale) * attn_v_val

    print(f"\n  k={k}: obs range=[{obs.min():.4e}, {obs.max():.4e}] nan={np.isnan(obs).sum()}")

    # 3. SynapseUNET: concat(obs, state + tick_embed[k])
    tick_emb = tick_embed[k] if k < tick_embed.shape[0] else tick_embed[-1]
    syn_input = np.concatenate([obs, state + tick_emb])

    print(f"       syn_input range=[{syn_input.min():.4e}, {syn_input.max():.4e}] nan={np.isnan(syn_input).sum()}")

    # Down path
    h = syn_input.copy()
    skips = []
    for j in range(half_k):
        w = down_w[j]
        h = silu(w @ h)
        skips.append(h.copy())

    # Up path
    h = skips[-1].copy()
    for j in range(half_k):
        if j > 0:
            skip = skips[half_k - 1 - j]
            h = np.concatenate([h, skip])
        w = up_w[j]
        h = silu(w @ h)
        h = layer_norm(h, up_ln_w[j], up_ln_b[j])

    syn_out = h
    print(f"       syn_out range=[{syn_out.min():.4e}, {syn_out.max():.4e}] nan={np.isnan(syn_out).sum()}")

    # Residual
    state = state + syn_out

    # 4. Update trace
    trace_2d = trace.reshape(D, M)
    trace_2d[:, :-1] = trace_2d[:, 1:]
    trace_2d[:, -1] = state
    trace = trace_2d.flatten()

    # 5. NLM1: SuperLinear(M, 2*hidden, D)
    # out[n, o] = sum_m(x[n, m] * w[m, o, n]) + b[n, o]
    # nlm1_w is stored as (M, 2*hidden, D) after reshape from GGUF
    nlm1_out = np.zeros((D, 2*hidden), dtype=np.float32)
    for n in range(D):
        for o in range(2*hidden):
            s = nlm1_b.flatten()[n * 2*hidden + o]
            for m in range(M):
                s += trace_2d[n, m] * nlm1_w.flatten()[(m * 2*hidden + o) * D + n]
            nlm1_out[n, o] = s

    # GLU
    half_h = hidden
    nlm1_gated = nlm1_out[:, :half_h] * (1.0 / (1.0 + np.exp(-np.clip(nlm1_out[:, half_h:], -20, 20))))

    print(f"       nlm1_gated range=[{nlm1_gated.min():.4e}, {nlm1_gated.max():.4e}] nan={np.isnan(nlm1_gated).sum()}")

    # 6. NLM2: SuperLinear(hidden, 2, D)
    nlm2_out = np.zeros((D, 2), dtype=np.float32)
    for n in range(D):
        for o in range(2):
            s = nlm2_b.flatten()[n * 2 + o]
            for m in range(hidden):
                s += nlm1_gated[n, m] * nlm2_w.flatten()[(m * 2 + o) * D + n]
            nlm2_out[n, o] = s

    # GLU -> squeeze
    state = nlm2_out[:, 0] * (1.0 / (1.0 + np.exp(-np.clip(nlm2_out[:, 1], -20, 20))))

    print(f"       state range=[{state.min():.4e}, {state.max():.4e}] nan={np.isnan(state).sum()}")

    # 7. Update sync
    for s in range(n_synch):
        pp_out = state[synch_out_left[s]] * state[synch_out_right[s]]
        alpha_out[s] = r_out[s] * alpha_out[s] + pp_out
        beta_out[s] = r_out[s] * beta_out[s] + 1.0
        pp_act = state[synch_act_left[s]] * state[synch_act_right[s]]
        alpha_act[s] = r_act[s] * alpha_act[s] + pp_act
        beta_act[s] = r_act[s] * beta_act[s] + 1.0

# Final output
synch_readout = np.where(beta_out > 1e-16, alpha_out / np.sqrt(beta_out), 0)
out = c_proj_w @ synch_readout
print(f"\n  Final output: range=[{out.min():.4e}, {out.max():.4e}] nan={np.isnan(out).sum()}")
