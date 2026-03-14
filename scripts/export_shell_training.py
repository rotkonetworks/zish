#!/usr/bin/env python3
"""Export zish history + completion logs as training data for shell CTM model.

Generates pairs of: "$ partial_command" → "completion"
Format compatible with nanochat SFT training.

Usage: python export_shell_training.py > data/sft/shell_completions.jsonl
"""

import json
import os
from pathlib import Path
from collections import Counter

def load_jsonl(path):
    entries = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    except FileNotFoundError:
        pass
    return entries

def main():
    zish_dir = Path.home() / ".zish"

    # Load all data sources
    completions = load_jsonl(zish_dir / "completion_log.jsonl")
    history = load_jsonl(zish_dir / "history.jsonl")
    commands = load_jsonl(zish_dir / "command_log.jsonl")

    print(f"# Data sources:", file=__import__('sys').stderr)
    print(f"#   Completions: {len(completions)}", file=__import__('sys').stderr)
    print(f"#   Commands: {len(commands)}", file=__import__('sys').stderr)
    print(f"#   History: {len(history)}", file=__import__('sys').stderr)

    training_pairs = []

    # From completion log: "ctx + pfx" → "cmp"
    for entry in completions:
        ctx = entry.get("ctx", "")
        pfx = entry.get("pfx", "")
        cmp = entry.get("cmp", "")
        if pfx and cmp:
            prompt = f"$ {ctx}{pfx}"
            completion = cmp
            training_pairs.append({"prompt": prompt, "completion": completion})

    # From command_log: real executed commands (best signal — user actually ran these)
    cmd_counter = Counter()
    for entry in commands:
        cmd = entry.get("cmd", "")
        exit_code = entry.get("exit", 0)
        if cmd and len(cmd) > 3 and len(cmd) < 200 and exit_code == 0:
            # Only successful commands (exit 0)
            cmd_counter[cmd] += 1

    # From history: agent queries
    for entry in history:
        q = entry.get("q", "")
        if q and len(q) > 3:
            cmd_counter[q] += 1

    for cmd, freq in cmd_counter.items():
        # Generate multiple split points for each command
        for split in range(2, min(len(cmd), 30)):
            prefix = cmd[:split]
            suffix = cmd[split:]
            if suffix and not suffix.startswith(" "):
                # Only suggest word completions, not mid-word
                continue
            training_pairs.append({
                "prompt": f"$ {prefix}",
                "completion": suffix,
                "weight": freq,
            })

    # Common shell patterns (augmentation)
    common_patterns = [
        ("git ", "status"), ("git ", "commit"), ("git ", "push"),
        ("git ", "pull"), ("git ", "diff"), ("git ", "log"),
        ("git ", "add"), ("git ", "branch"), ("git ", "checkout"),
        ("git commit ", "-m '"), ("git push ", "origin main"),
        ("git log ", "--oneline"), ("git diff ", "--stat"),
        ("ls ", "-la"), ("ls ", "-lh"),
        ("cd ", ".."), ("cd ", "~/"),
        ("cat ", ""), ("grep ", "-rn"),
        ("find ", ". -name"), ("find ", ". -type f"),
        ("docker ", "ps"), ("docker ", "run"), ("docker ", "build"),
        ("docker ", "compose"), ("docker compose ", "up -d"),
        ("zig ", "build"), ("zig ", "test"), ("zig build ", "run"),
        ("cargo ", "build"), ("cargo ", "test"), ("cargo ", "run"),
        ("npm ", "install"), ("npm ", "run"), ("npm ", "test"),
        ("python3 ", "-c"), ("python3 ", "-m"),
        ("ssh ", "-p"), ("scp ", "-P"),
        ("sudo ", "make install"), ("sudo ", "systemctl"),
        ("systemctl ", "status"), ("systemctl ", "restart"),
        ("make ", "install"), ("make ", "clean"), ("make ", "test"),
        ("curl ", "-sS"), ("curl ", "-X POST"),
    ]
    for prefix, suffix in common_patterns:
        for split in range(1, len(prefix)):
            p = prefix[:split]
            s = prefix[split:] + suffix
            training_pairs.append({"prompt": f"$ {p}", "completion": s})

    # Deduplicate
    seen = set()
    unique = []
    for pair in training_pairs:
        key = (pair["prompt"], pair["completion"])
        if key not in seen:
            seen.add(key)
            unique.append(pair)

    # Output as JSONL
    for pair in unique:
        print(json.dumps({"text": f"{pair['prompt']}{pair['completion']}"}))

    print(f"# Generated {len(unique)} training pairs", file=__import__('sys').stderr)
    print(f"#   From completions: {len(completions)}", file=__import__('sys').stderr)
    print(f"#   From history: {len(cmd_counter)} unique commands", file=__import__('sys').stderr)

if __name__ == "__main__":
    main()
