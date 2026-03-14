#!/usr/bin/env python3
"""Train a tiny CTM model for shell command completion using nanoctm.

Architecture: 4M params, character-level, CTM K=4
- 4 transformer layers, dim=128, 4 heads
- CTM block on last layer with K=4 iterations
- Character-level tokenizer (256 vocab, no BPE overhead)
- Trained on shell command pairs from zish history

Usage:
    # 1. Export training data
    python scripts/export_shell_training.py > /tmp/shell_train.jsonl

    # 2. Train (requires nanoctm from ~/rotko/ctm/nanochat)
    python scripts/train_shell_ctm.py

    # 3. Export to GGUF
    python scripts/export_ctm_gguf.py --model checkpoints/shell_ctm --output ~/.zish/models/shell_ctm.gguf

    # 4. Configure zish
    # Set completion_model in ~/.zish/agent.json to the GGUF path
"""

import os
import sys
import json

def generate_config():
    """Generate nanoctm training config for shell completion."""
    return {
        "model": {
            "n_layer": 4,
            "n_head": 4,
            "n_embd": 128,
            "vocab_size": 256,  # character-level (raw bytes)
            "block_size": 128,  # max sequence length (shell commands are short)
            "bias": False,
            "dropout": 0.0,
        },
        "ctm": {
            "enabled": True,
            "layers": "last",  # CTM on last layer only
            "iterations": 4,   # K=4 thinking iterations
            "synapse_depth": 8, # smaller synapse for tiny model
            "memory_length": 8,
            "n_synch": 64,     # dim/2
            "memory_hidden": 16,
            "lr_scale": 0.1,   # scaled down LR for CTM layers
        },
        "training": {
            "batch_size": 32,
            "learning_rate": 3e-4,
            "max_iters": 5000,
            "warmup_iters": 100,
            "weight_decay": 0.01,
            "grad_clip": 1.0,
            "eval_interval": 500,
            "eval_iters": 50,
            "log_interval": 100,
            "compile": False,  # CTM loop breaks torch.compile
        },
        "data": {
            "train_file": "/tmp/shell_train.jsonl",
            "tokenizer": "char",  # character-level, no BPE
        },
        "output": {
            "out_dir": "checkpoints/shell_ctm",
        },
    }

def main():
    config = generate_config()

    # Check if nanoctm is available
    nanoctm_path = os.path.expanduser("~/rotko/ctm/nanochat")
    if not os.path.exists(nanoctm_path):
        print(f"Error: nanoctm not found at {nanoctm_path}")
        sys.exit(1)

    # Check training data
    train_file = "/tmp/shell_train.jsonl"
    if not os.path.exists(train_file):
        print("Generating training data...")
        os.system("python3 scripts/export_shell_training.py > /tmp/shell_train.jsonl")

    n_lines = sum(1 for _ in open(train_file))
    print(f"Training data: {n_lines} examples")

    # Estimate model size
    d = config["model"]["n_embd"]
    n = config["model"]["n_layer"]
    v = config["model"]["vocab_size"]
    # Rough param count: embeddings + attention + MLP + CTM
    params = v * d  # token embeddings
    params += n * (4 * d * d + 2 * d)  # attention (Q,K,V,O) + norms
    params += n * (4 * d * (4*d) + 2 * (4*d))  # MLP (gate, up, down)
    # CTM adds ~20% for synapse + NLM
    ctm_params = int(params * 0.2)
    total = params + ctm_params
    print(f"Estimated params: {total:,} ({total/1e6:.1f}M)")
    print(f"  Transformer: {params:,}")
    print(f"  CTM: {ctm_params:,}")

    # Write config
    config_path = "/tmp/shell_ctm_config.json"
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    print(f"Config written to {config_path}")

    print(f"""
To train:
    cd {nanoctm_path}
    python train.py --config {config_path}

To export GGUF:
    python scripts/export_ctm_gguf.py \\
        --model checkpoints/shell_ctm \\
        --output ~/.zish/models/shell_ctm.gguf \\
        --dtype q8_0

To use in zish:
    Edit ~/.zish/agent.json: "completion_model": "~/.zish/models/shell_ctm.gguf"

The model will recursively improve as you use zish:
    1. You type commands → history grows
    2. Re-export training data → retrain
    3. Better completions → you type faster
    4. Repeat
""")

if __name__ == "__main__":
    main()
