#!/usr/bin/env python3
"""Simple training script for shell completion model.

Fine-tunes a small HF model on shell command data.
No nanoctm dependency — just PyTorch + transformers.

Usage:
    python scripts/train_simple.py
"""

import json
import torch
from torch.utils.data import Dataset, DataLoader
from transformers import AutoTokenizer, AutoModelForCausalLM, get_cosine_schedule_with_warmup
from pathlib import Path

class ShellDataset(Dataset):
    def __init__(self, texts, tokenizer, max_len=64):
        self.examples = []
        for text in texts:
            ids = tokenizer.encode(text, add_special_tokens=True, truncation=True, max_length=max_len)
            if len(ids) >= 4:  # skip very short
                # Pad to max_len
                ids = ids + [tokenizer.pad_token_id or 0] * (max_len - len(ids))
                self.examples.append(torch.tensor(ids[:max_len]))

    def __len__(self):
        return len(self.examples)

    def __getitem__(self, idx):
        x = self.examples[idx]
        return x[:-1], x[1:]  # input, target (shifted by 1)

def main():
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Device: {device}")

    # Load training data
    data_path = Path(__file__).parent / "shell_training_data.jsonl"
    texts = []
    with open(data_path) as f:
        for line in f:
            try:
                d = json.loads(line.strip())
                t = d.get("text", "")
                if t and len(t) > 3:
                    texts.append(t)
            except:
                pass
    print(f"Loaded {len(texts)} training examples")

    # Use small model that fits in 8GB GPU for training
    model_name = "HuggingFaceTB/SmolLM2-135M"
    print(f"Loading {model_name}...")
    tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        model_name,
        dtype=torch.bfloat16,
    ).to(device)

    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    # Freeze most layers, only train last 4 + lm_head
    total_params = sum(p.numel() for p in model.parameters())
    for param in model.parameters():
        param.requires_grad = False

    # Unfreeze last 4 layers + lm_head
    n_layers = model.config.num_hidden_layers
    for i in range(max(0, n_layers - 4), n_layers):
        for param in model.model.layers[i].parameters():
            param.requires_grad = True
    for param in model.lm_head.parameters():
        param.requires_grad = True

    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"Total params: {total_params:,}, Trainable: {trainable:,} ({100*trainable/total_params:.1f}%)")

    # Dataset
    dataset = ShellDataset(texts, tokenizer, max_len=64)
    print(f"Dataset: {len(dataset)} examples")

    loader = DataLoader(dataset, batch_size=32, shuffle=True, drop_last=True)

    # Optimizer
    optimizer = torch.optim.AdamW(
        [p for p in model.parameters() if p.requires_grad],
        lr=1e-4, weight_decay=0.01
    )
    scheduler = get_cosine_schedule_with_warmup(
        optimizer, num_warmup_steps=100, num_training_steps=len(loader) * 3
    )

    # Train
    model.train()
    for epoch in range(3):
        total_loss = 0
        for step, (inputs, targets) in enumerate(loader):
            inputs, targets = inputs.to(device), targets.to(device)

            outputs = model(input_ids=inputs, labels=targets)
            loss = outputs.loss

            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            scheduler.step()
            optimizer.zero_grad()

            total_loss += loss.item()

            if step % 100 == 0:
                avg = total_loss / (step + 1)
                print(f"Epoch {epoch+1}/3, Step {step}/{len(loader)}, Loss: {loss.item():.4f}, Avg: {avg:.4f}")

        avg_loss = total_loss / len(loader)
        print(f"Epoch {epoch+1} done. Avg loss: {avg_loss:.4f}")

    # Save
    out_dir = Path.home() / ".zish" / "models" / "shell_completion"
    out_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(out_dir)
    tokenizer.save_pretrained(out_dir)
    print(f"Saved to {out_dir}")
    print(f"Next: convert to GGUF with scripts/export_ctm_gguf.py")

if __name__ == "__main__":
    main()
