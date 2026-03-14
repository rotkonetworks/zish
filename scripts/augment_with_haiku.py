#!/usr/bin/env python3
"""Use Claude Haiku to generate synthetic shell completion training data.

Takes real command history and generates plausible prefix → completion pairs,
variations, and common patterns. Cheap (~$0.01 for 1000 commands).

Usage:
    python scripts/augment_with_haiku.py >> /tmp/shell_train.jsonl
"""

import json
import os
import sys
from pathlib import Path

def load_jsonl(path):
    entries = []
    try:
        with open(path) as f:
            for line in f:
                if line.strip():
                    try: entries.append(json.loads(line))
                    except: pass
    except FileNotFoundError: pass
    return entries

def get_unique_commands():
    """Get unique successful commands from zish logs."""
    zish_dir = Path.home() / ".zish"
    commands = set()

    for entry in load_jsonl(zish_dir / "command_log.jsonl"):
        cmd = entry.get("cmd", "")
        if cmd and 3 < len(cmd) < 200 and entry.get("exit", 0) == 0:
            commands.add(cmd)

    for entry in load_jsonl(zish_dir / "completion_log.jsonl"):
        ctx = entry.get("ctx", "")
        cmp = entry.get("cmp", "")
        if ctx and cmp:
            commands.add(ctx + cmp)

    return sorted(commands)

def call_haiku(prompt, api_key):
    """Call Claude Haiku API."""
    import urllib.request
    import urllib.error

    body = json.dumps({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 4096,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    # Try OAuth first, then API key
    headers = {
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
    }
    if api_key.startswith("sk-ant-oat"):
        headers["Authorization"] = f"Bearer {api_key}"
        headers["anthropic-beta"] = "oauth-2025-04-20"
    else:
        headers["x-api-key"] = api_key

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        headers=headers,
    )
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        data = json.loads(resp.read())
        return data["content"][0]["text"]
    except Exception as e:
        print(f"API error: {e}", file=sys.stderr)
        return None

def main():
    # Get API key
    creds_path = Path.home() / ".claude" / ".credentials.json"
    try:
        with open(creds_path) as f:
            creds = json.load(f)
        api_key = creds.get("claudeAiOauth", {}).get("accessToken", "")
    except:
        api_key = os.environ.get("ANTHROPIC_API_KEY", "")

    if not api_key:
        print("No API key found", file=sys.stderr)
        sys.exit(1)

    commands = get_unique_commands()
    print(f"Found {len(commands)} unique commands", file=sys.stderr)

    # Batch commands into groups of 50 for efficiency
    batch_size = 50
    total_generated = 0

    for i in range(0, len(commands), batch_size):
        batch = commands[i:i+batch_size]
        cmd_list = "\n".join(f"- {cmd}" for cmd in batch)

        prompt = f"""Generate shell command completion training data. For each command below, generate 3-5 prefix→completion pairs showing different split points where a user might press Tab or Right-arrow to complete.

Format: one JSON per line, like: {{"text": "$ git sta tus"}}
The text should be the FULL command with a space showing the split point between what the user typed and what was completed.

Actually, just output the full command as a training sequence. Each line should be:
{{"text": "$ <full_command>"}}

Commands:
{cmd_list}

Also generate 2-3 variations for common commands (different flags, paths, etc).
Output ONLY the JSON lines, nothing else."""

        result = call_haiku(prompt, api_key)
        if result:
            for line in result.strip().split("\n"):
                line = line.strip()
                if line.startswith("{") and "text" in line:
                    try:
                        parsed = json.loads(line)
                        if "text" in parsed:
                            print(json.dumps(parsed))
                            total_generated += 1
                    except:
                        pass

        print(f"Batch {i//batch_size + 1}: {total_generated} pairs so far", file=sys.stderr)

    print(f"Total generated: {total_generated} training pairs", file=sys.stderr)

if __name__ == "__main__":
    main()
