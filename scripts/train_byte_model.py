#!/usr/bin/env python3
"""Train a byte-level shell completion model.

No BPE tokenizer — each input byte is a token (vocab_size=256).
Uses the same architecture as nanochat (no layernorm, ReLU² MLP, RoPE)
so the existing GGUF inference engine works unchanged.

Usage:
    python scripts/train_byte_model.py --data /tmp/clean_context.jsonl
    python scripts/train_byte_model.py --data /tmp/clean_context.jsonl --export ~/.zish/models/shell_completion.gguf
"""

import argparse
import json
import math
import struct
import time
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader

# ---------- Model (nanochat-compatible: no layernorm, ReLU² MLP, RoPE) ----------

class RoPE(nn.Module):
    def __init__(self, dim, max_len=256):
        super().__init__()
        inv_freq = 1.0 / (10000 ** (torch.arange(0, dim, 2).float() / dim))
        t = torch.arange(max_len).float()
        freqs = torch.outer(t, inv_freq)
        self.register_buffer('cos', freqs.cos())
        self.register_buffer('sin', freqs.sin())

    def forward(self, x, offset=0):
        seq_len = x.shape[-2]
        cos = self.cos[offset:offset+seq_len].unsqueeze(0).unsqueeze(0)
        sin = self.sin[offset:offset+seq_len].unsqueeze(0).unsqueeze(0)
        x1, x2 = x[..., ::2], x[..., 1::2]
        return torch.cat([x1 * cos - x2 * sin, x1 * sin + x2 * cos], dim=-1)


class Attention(nn.Module):
    def __init__(self, dim, n_head):
        super().__init__()
        self.n_head = n_head
        self.head_dim = dim // n_head
        self.c_q = nn.Linear(dim, dim, bias=False)
        self.c_k = nn.Linear(dim, dim, bias=False)
        self.c_v = nn.Linear(dim, dim, bias=False)
        self.c_proj = nn.Linear(dim, dim, bias=False)
        self.rope = RoPE(self.head_dim)

    def forward(self, x, mask=None):
        B, T, C = x.shape
        q = self.c_q(x).view(B, T, self.n_head, self.head_dim).transpose(1, 2)
        k = self.c_k(x).view(B, T, self.n_head, self.head_dim).transpose(1, 2)
        v = self.c_v(x).view(B, T, self.n_head, self.head_dim).transpose(1, 2)
        q = self.rope(q)
        k = self.rope(k)
        attn = (q @ k.transpose(-2, -1)) / math.sqrt(self.head_dim)
        if mask is not None:
            attn = attn + mask[:T, :T]
        attn = F.softmax(attn, dim=-1)
        out = (attn @ v).transpose(1, 2).contiguous().view(B, T, C)
        return self.c_proj(out)


class MLP(nn.Module):
    """ReLU² MLP (no gate, no layernorm): up → relu² → down"""
    def __init__(self, dim, hidden_dim):
        super().__init__()
        self.c_fc = nn.Linear(dim, hidden_dim, bias=False)
        self.c_proj = nn.Linear(hidden_dim, dim, bias=False)

    def forward(self, x):
        h = self.c_fc(x)
        h = F.relu(h) ** 2  # ReLU²
        return self.c_proj(h)


class Block(nn.Module):
    """nanochat block: no layernorm, just attention + MLP residual"""
    def __init__(self, dim, n_head, hidden_dim):
        super().__init__()
        self.attn = Attention(dim, n_head)
        self.mlp = MLP(dim, hidden_dim)

    def forward(self, x, mask=None):
        x = x + self.attn(x, mask=mask)
        x = x + self.mlp(x)
        return x


class ByteGPT(nn.Module):
    def __init__(self, vocab_size=256, dim=256, n_layer=6, n_head=4, max_len=256):
        super().__init__()
        self.wte = nn.Embedding(vocab_size, dim)
        self.blocks = nn.ModuleList([
            Block(dim, n_head, dim * 4) for _ in range(n_layer)
        ])
        self.lm_head = nn.Linear(dim, vocab_size, bias=False)
        # Causal mask
        mask = torch.full((max_len, max_len), float('-inf'))
        mask = torch.triu(mask, diagonal=1)
        self.register_buffer('mask', mask)
        self.dim = dim
        self.n_layer = n_layer
        self.n_head = n_head
        self.max_len = max_len
        self.vocab_size = vocab_size

    def forward(self, idx):
        x = self.wte(idx)
        for block in self.blocks:
            x = block(x, mask=self.mask)
        return self.lm_head(x)


# ---------- Dataset ----------

class ByteDataset(Dataset):
    def __init__(self, data_tensor):
        """data_tensor: (N, seq_len) long tensor of byte values"""
        self.data = data_tensor

    def __len__(self):
        return self.data.shape[0]

    def __getitem__(self, idx):
        x = self.data[idx]
        return x[:-1], x[1:]

    @staticmethod
    def from_texts(texts, seq_len=256):
        """Build dataset from list of text strings."""
        data = torch.zeros(len(texts), seq_len, dtype=torch.long)
        kept = 0
        for text in texts:
            b = text.encode('utf-8', errors='replace')
            if len(b) >= 8:
                n = min(len(b), seq_len)
                data[kept, :n] = torch.tensor(list(b[:n]), dtype=torch.long)
                kept += 1
        return ByteDataset(data[:kept])


# ---------- GGUF Export ----------

GGUF_MAGIC = 0x46554747
GGUF_VERSION = 3
GGUF_TYPE_UINT32 = 4
GGUF_TYPE_FLOAT32 = 6
GGUF_TYPE_STRING = 8
GGUF_TYPE_ARRAY = 9
GGML_TYPE_F32 = 0
GGML_TYPE_F16 = 1

def write_string(f, s):
    b = s.encode('utf-8') if isinstance(s, str) else s
    f.write(struct.pack('<Q', len(b)))
    f.write(b)

def write_kv_string(f, k, v):
    write_string(f, k)
    f.write(struct.pack('<I', GGUF_TYPE_STRING))
    write_string(f, v)

def write_kv_uint32(f, k, v):
    write_string(f, k)
    f.write(struct.pack('<I', GGUF_TYPE_UINT32))
    f.write(struct.pack('<I', v))

def write_kv_float32(f, k, v):
    write_string(f, k)
    f.write(struct.pack('<I', GGUF_TYPE_FLOAT32))
    f.write(struct.pack('<f', v))

def write_kv_string_array(f, k, strings):
    write_string(f, k)
    f.write(struct.pack('<I', GGUF_TYPE_ARRAY))
    f.write(struct.pack('<I', GGUF_TYPE_STRING))
    f.write(struct.pack('<Q', len(strings)))
    for s in strings:
        b = s.encode('utf-8', errors='replace') if isinstance(s, str) else s
        f.write(struct.pack('<Q', len(b)))
        f.write(b)

def write_kv_float_array(f, k, values):
    write_string(f, k)
    f.write(struct.pack('<I', GGUF_TYPE_ARRAY))
    f.write(struct.pack('<I', GGUF_TYPE_FLOAT32))
    f.write(struct.pack('<Q', len(values)))
    for v in values:
        f.write(struct.pack('<f', v))

def align_offset(offset, alignment=32):
    return (offset + alignment - 1) & ~(alignment - 1)

def export_gguf(model, output_path, fp16=True):
    """Export ByteGPT to GGUF format compatible with zish inference."""
    import numpy as np

    state = model.state_dict()
    dim = model.dim
    n_layer = model.n_layer
    n_head = model.n_head
    vocab_size = model.vocab_size

    # Map weight names to GGUF names
    tensor_map = {}
    tensor_map['token_embd.weight'] = state['wte.weight'].float()
    tensor_map['output.weight'] = state['lm_head.weight'].float()

    for i in range(n_layer):
        p = f'blocks.{i}'
        tensor_map[f'blk.{i}.attn_q.weight'] = state[f'{p}.attn.c_q.weight'].float()
        tensor_map[f'blk.{i}.attn_k.weight'] = state[f'{p}.attn.c_k.weight'].float()
        tensor_map[f'blk.{i}.attn_v.weight'] = state[f'{p}.attn.c_v.weight'].float()
        tensor_map[f'blk.{i}.attn_output.weight'] = state[f'{p}.attn.c_proj.weight'].float()
        tensor_map[f'blk.{i}.ffn_up.weight'] = state[f'{p}.mlp.c_fc.weight'].float()
        tensor_map[f'blk.{i}.ffn_down.weight'] = state[f'{p}.mlp.c_proj.weight'].float()

    # Convert to fp16
    if fp16:
        for k in tensor_map:
            if tensor_map[k].numel() > 256:
                tensor_map[k] = tensor_map[k].half()

    # Build tensor infos
    tensor_infos = []
    for name, tensor in tensor_map.items():
        data = tensor.numpy() if tensor.dtype == torch.float32 else tensor.numpy().view(np.uint16)
        t_type = GGML_TYPE_F32 if tensor.dtype == torch.float32 else GGML_TYPE_F16
        tensor_infos.append((name, tensor.shape, t_type, data.tobytes()))

    # Byte-level tokenizer: 256 tokens, each is the single byte it represents
    vocab_tokens = [bytes([i]) for i in range(256)]
    vocab_scores = [float(i) for i in range(256)]  # rank = byte value

    n_kv = 12  # metadata + tokenizer

    out = Path(output_path).expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)

    with open(out, 'wb') as f:
        f.write(struct.pack('<I', GGUF_MAGIC))
        f.write(struct.pack('<I', GGUF_VERSION))
        f.write(struct.pack('<Q', len(tensor_infos)))
        f.write(struct.pack('<Q', n_kv))

        # Metadata
        write_kv_string(f, 'general.architecture', 'nanochat')
        write_kv_string(f, 'general.name', 'shell-completion-byte')
        write_kv_uint32(f, 'nanochat.context_length', model.max_len)
        write_kv_uint32(f, 'nanochat.embedding_length', dim)
        write_kv_uint32(f, 'nanochat.block_count', n_layer)
        write_kv_uint32(f, 'nanochat.attention.head_count', n_head)
        write_kv_uint32(f, 'nanochat.attention.head_count_kv', n_head)
        write_kv_uint32(f, 'nanochat.vocab_size', vocab_size)
        write_kv_uint32(f, 'nanochat.feed_forward_length', dim * 4)
        write_kv_string(f, 'nanochat.activation', 'relu_squared')

        # Tokenizer (byte-level: no merges needed, just 256 single bytes)
        write_kv_string_array(f, 'tokenizer.ggml.tokens', [bytes([i]).decode('latin-1') for i in range(256)])
        write_kv_float_array(f, 'tokenizer.ggml.scores', vocab_scores)

        # Tensor infos
        data_offset = 0
        for name, shape, t_type, data_bytes in tensor_infos:
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
        for name, shape, t_type, data_bytes in tensor_infos:
            f.write(data_bytes)
            current = f.tell()
            aligned = align_offset(current)
            if aligned > current:
                f.write(b'\x00' * (aligned - current))

    total_size = out.stat().st_size
    print(f"Saved GGUF: {out} ({total_size / 1024 / 1024:.1f} MB)")
    print(f"Tensors: {len(tensor_infos)}, Type: {'f16' if fp16 else 'f32'}")


# ---------- Training ----------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', required=True, help='Training JSONL (one {"text": "..."} per line)')
    parser.add_argument('--export', default=None, help='Export GGUF path')
    parser.add_argument('--dim', type=int, default=256, help='Model dimension')
    parser.add_argument('--layers', type=int, default=6, help='Number of layers')
    parser.add_argument('--heads', type=int, default=4, help='Number of attention heads')
    parser.add_argument('--seq-len', type=int, default=256, help='Sequence length')
    parser.add_argument('--batch-size', type=int, default=128, help='Batch size')
    parser.add_argument('--lr', type=float, default=3e-4, help='Learning rate')
    parser.add_argument('--epochs', type=int, default=5, help='Training epochs')
    parser.add_argument('--save-every', type=int, default=1000, help='Save checkpoint every N steps')
    args = parser.parse_args()

    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    print(f"Device: {device}")

    # Load data
    texts = []
    with open(args.data) as f:
        for line in f:
            try:
                d = json.loads(line.strip())
                t = d.get('text', '')
                if t and len(t) >= 8:
                    texts.append(t)
            except:
                pass
    print(f"Loaded {len(texts)} examples")

    # Try to load pre-processed tensor (fast), fall back to text processing
    tensor_cache = Path(args.data).with_suffix('.pt')
    if tensor_cache.exists() and tensor_cache.stat().st_mtime > Path(args.data).stat().st_mtime:
        print(f"Loading cached tensor from {tensor_cache}")
        all_data = torch.load(tensor_cache, weights_only=True)
        if all_data.shape[1] != args.seq_len:
            print(f"Seq len mismatch ({all_data.shape[1]} vs {args.seq_len}), rebuilding...")
            all_data = None
    else:
        all_data = None

    if all_data is None:
        print("Building byte tensor from texts...")
        all_data = torch.zeros(len(texts), args.seq_len, dtype=torch.long)
        kept = 0
        for text in texts:
            b = text.encode('utf-8', errors='replace')
            if len(b) >= 8:
                n = min(len(b), args.seq_len)
                all_data[kept, :n] = torch.tensor(list(b[:n]), dtype=torch.long)
                kept += 1
        all_data = all_data[:kept]
        torch.save(all_data, tensor_cache)

    # Split train/val
    val_size = min(all_data.shape[0] // 20, 2000)
    train_ds = ByteDataset(all_data[val_size:])
    val_ds = ByteDataset(all_data[:val_size])
    print(f"Train: {len(train_ds)}, Val: {len(val_ds)}")

    train_loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True, drop_last=True, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False)

    # Model
    model = ByteGPT(
        vocab_size=256,
        dim=args.dim,
        n_layer=args.layers,
        n_head=args.heads,
        max_len=args.seq_len,
    ).to(device)

    n_params = sum(p.numel() for p in model.parameters())
    print(f"Model: {n_params:,} params ({n_params/1e6:.1f}M)")

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs * len(train_loader))

    best_val_loss = float('inf')
    step = 0

    for epoch in range(args.epochs):
        model.train()
        epoch_loss = 0
        t0 = time.time()

        for batch_idx, (inputs, targets) in enumerate(train_loader):
            inputs, targets = inputs.to(device), targets.to(device)
            logits = model(inputs)
            loss = F.cross_entropy(logits.view(-1, 256), targets.view(-1), ignore_index=0)

            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            scheduler.step()
            step += 1

            epoch_loss += loss.item()

            if step % 200 == 0:
                elapsed = time.time() - t0
                avg = epoch_loss / (batch_idx + 1)
                # Bits per byte
                bpb = avg / math.log(2)
                print(f"  step {step:5d} | loss {loss.item():.4f} | avg {avg:.4f} | bpb {bpb:.3f} | {elapsed:.0f}s")

        # Validation
        model.eval()
        val_loss = 0
        n_val = 0
        with torch.no_grad():
            for inputs, targets in val_loader:
                inputs, targets = inputs.to(device), targets.to(device)
                logits = model(inputs)
                loss = F.cross_entropy(logits.view(-1, 256), targets.view(-1), ignore_index=0)
                val_loss += loss.item()
                n_val += 1

        avg_val = val_loss / max(n_val, 1)
        val_bpb = avg_val / math.log(2)
        elapsed = time.time() - t0
        print(f"Epoch {epoch+1}/{args.epochs} | train_loss {epoch_loss/len(train_loader):.4f} | val_loss {avg_val:.4f} | val_bpb {val_bpb:.3f} | {elapsed:.0f}s")

        if avg_val < best_val_loss:
            best_val_loss = avg_val
            torch.save(model.state_dict(), '/tmp/byte_model_best.pt')
            print(f"  New best! Saved checkpoint")

    # Load best and export
    model.load_state_dict(torch.load('/tmp/byte_model_best.pt', weights_only=True))
    model.eval()

    # Generate sample completions
    print("\n--- Sample completions ---")
    prompts = ["$ ls -", "$ docker ", "$ git co", "$ find . -"]
    for prompt in prompts:
        tokens = torch.tensor([list(prompt.encode())], device=device)
        with torch.no_grad():
            for _ in range(30):
                if tokens.shape[1] >= args.seq_len:
                    break
                logits = model(tokens)[:, -1]
                probs = F.softmax(logits / 0.3, dim=-1)
                next_tok = torch.multinomial(probs, 1)
                if next_tok.item() == 10:  # newline
                    break
                tokens = torch.cat([tokens, next_tok], dim=1)
        result = bytes(tokens[0].tolist()).decode('utf-8', errors='replace')
        print(f"  {result}")

    # Export to GGUF
    if args.export:
        export_gguf(model, args.export)
    else:
        export_gguf(model, Path.home() / '.zish' / 'models' / 'shell_completion.gguf')


if __name__ == '__main__':
    main()
