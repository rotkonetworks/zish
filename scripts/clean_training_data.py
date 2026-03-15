#!/usr/bin/env python3
"""Clean shell training data using Claude Haiku to extract pure commands.

Filters and converts mixed-format training data to clean completion-only format:
  Input:  "Translate: list files\n$ ls -la"  or  "Shell command for: ..."
  Output: {"text": "$ ls -la"}

Only keeps entries that are valid shell commands prefixed with "$ ".
Runs Haiku in batches to clean ambiguous entries.

Usage:
    python scripts/clean_training_data.py < data.jsonl > clean.jsonl
    python scripts/clean_training_data.py --input scripts/shell_training_data.jsonl --output /tmp/clean.jsonl
"""

import json
import sys
import os
import re
import argparse
from pathlib import Path


def is_clean_command(text):
    """Check if text is already a clean '$ command' entry."""
    text = text.strip()
    if not text.startswith('$ '):
        return False
    cmd = text[2:]
    # Must be a single command (no newlines, no descriptions)
    if '\n' in cmd:
        return False
    # Must not contain training artifacts
    bad_patterns = [
        'Translate', 'translate', 'Intent:', 'intent:',
        'Shell command', 'shell command', 'Complete:', 'complete:',
        'How do I', 'how do i', 'What command', 'what command',
        'Useful for', 'useful for', 'Reply with', 'reply with',
    ]
    for bad in bad_patterns:
        if bad in cmd:
            return False
    # Must look like a real command (starts with alphanum or ./ or ~/)
    if len(cmd) < 2:
        return False
    if not (cmd[0].isalpha() or cmd[0] in '.~/'):
        return False
    return True


def extract_command(text):
    """Try to extract a clean command from mixed-format text."""
    text = text.strip()

    # Already clean
    if is_clean_command(text):
        return text

    # "$ command" somewhere in the text — extract it
    lines = text.split('\n')
    for line in lines:
        line = line.strip()
        if line.startswith('$ ') and is_clean_command(line):
            return line

    # "Complete: $ partial\n$ full" — take the full command
    if 'Complete:' in text or 'complete:' in text:
        for line in reversed(lines):
            line = line.strip()
            if line.startswith('$ '):
                cmd = line
                if is_clean_command(cmd):
                    return cmd

    return None


def call_haiku_batch(texts, api_key):
    """Call Haiku to extract shell commands from messy text."""
    import urllib.request

    prompt = "Extract the shell command from each line below. Output ONLY the command prefixed with '$ '. One per line. If no valid command, output SKIP.\n\n"
    for i, t in enumerate(texts):
        prompt += f"{i+1}. {t[:200]}\n"

    body = json.dumps({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 2048,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    # Load OAuth credentials
    creds_path = Path.home() / ".claude" / ".credentials.json"
    headers = {
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
    }

    if creds_path.exists():
        with open(creds_path) as f:
            creds = json.load(f)
        if isinstance(creds, list) and len(creds) > 0:
            token = creds[0].get("oauth_token", "")
            if token:
                headers["Authorization"] = f"Bearer {token}"

    if "Authorization" not in headers and api_key:
        headers["x-api-key"] = api_key

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        headers=headers,
    )

    try:
        resp = urllib.request.urlopen(req, timeout=30)
        data = json.loads(resp.read())
        content = data["content"][0]["text"]
        results = []
        for line in content.strip().split('\n'):
            line = line.strip()
            # Remove numbering like "1. $ cmd"
            line = re.sub(r'^\d+\.\s*', '', line)
            if line.startswith('$ ') and 'SKIP' not in line:
                results.append(line)
            else:
                results.append(None)
        return results
    except Exception as e:
        print(f"Haiku call failed: {e}", file=sys.stderr)
        return [None] * len(texts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', default=None, help='input JSONL file (default: stdin)')
    parser.add_argument('--output', default=None, help='output JSONL file (default: stdout)')
    parser.add_argument('--batch-size', type=int, default=20, help='Haiku batch size')
    parser.add_argument('--max-haiku-calls', type=int, default=500, help='max Haiku API calls')
    args = parser.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")

    inp = open(args.input) if args.input else sys.stdin
    out = open(args.output, 'w') if args.output else sys.stdout

    clean_count = 0
    haiku_count = 0
    skip_count = 0
    haiku_calls = 0
    seen = set()
    haiku_batch = []

    for line_num, line in enumerate(inp):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            text = d.get('text', '')
        except:
            continue

        if len(text) < 4 or len(text) > 300:
            skip_count += 1
            continue

        # Try direct extraction first (no API call needed)
        cmd = extract_command(text)
        if cmd and cmd not in seen:
            seen.add(cmd)
            out.write(json.dumps({"text": cmd}) + '\n')
            clean_count += 1
            continue

        # Queue for Haiku cleaning
        if haiku_calls < args.max_haiku_calls:
            haiku_batch.append(text)
            if len(haiku_batch) >= args.batch_size:
                results = call_haiku_batch(haiku_batch, api_key)
                haiku_calls += 1
                for r in results:
                    if r and r not in seen:
                        seen.add(r)
                        out.write(json.dumps({"text": r}) + '\n')
                        haiku_count += 1
                haiku_batch = []
        else:
            skip_count += 1

        if (line_num + 1) % 10000 == 0:
            print(f"  [{line_num+1}] clean={clean_count} haiku={haiku_count} skip={skip_count} api_calls={haiku_calls}", file=sys.stderr)

    # Flush remaining batch
    if haiku_batch and haiku_calls < args.max_haiku_calls:
        results = call_haiku_batch(haiku_batch, api_key)
        for r in results:
            if r and r not in seen:
                seen.add(r)
                out.write(json.dumps({"text": r}) + '\n')
                haiku_count += 1

    print(f"Done: {clean_count} direct + {haiku_count} via Haiku = {clean_count + haiku_count} total, {skip_count} skipped, {haiku_calls} API calls", file=sys.stderr)

    if args.input:
        inp.close()
    if args.output:
        out.close()


if __name__ == "__main__":
    main()
