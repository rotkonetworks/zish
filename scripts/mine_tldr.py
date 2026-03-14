#!/usr/bin/env python3
"""Mine tldr pages for shell training data.

Parses tldr markdown pages and generates JSONL training examples:
  - Raw command examples: {"text": "$ command --flag argument"}
  - Intent-to-command pairs: {"text": "Translate: description\\n$ command"}
  - Prefix completions: {"text": "Complete: $ cmd --fl\\n$ cmd --flag arg"}

Usage:
    python scripts/mine_tldr.py > train_tldr.jsonl
"""

import json
import os
import re
import sys
from pathlib import Path


# Common tldr cache locations
TLDR_SEARCH_PATHS = [
    Path.home() / ".cache" / "tealdeer" / "tldr-pages" / "pages.en",
    Path.home() / ".local" / "share" / "tldr" / "pages",
    Path.home() / ".tldr" / "cache" / "pages",
    Path("/usr/share/tldr/pages"),
    Path("/var/cache/tldr/pages"),
]

# Platforms relevant for shell training (skip windows, dos, android, cisco-ios)
RELEVANT_PLATFORMS = {"common", "linux", "osx", "freebsd", "netbsd", "openbsd", "sunos"}


def find_tldr_root() -> Path | None:
    """Find the tldr pages cache directory."""
    for p in TLDR_SEARCH_PATHS:
        if p.is_dir():
            # Check if it has md files or platform subdirs
            has_pages = any(p.rglob("*.md"))
            if has_pages:
                return p
    # Fallback: search more broadly
    for candidate in [Path.home() / ".cache", Path.home() / ".local"]:
        if not candidate.exists():
            continue
        for md in candidate.rglob("*.md"):
            if "tldr" in str(md).lower():
                # Walk up to find the pages root
                parts = md.parts
                for i, part in enumerate(parts):
                    if part in ("pages", "pages.en"):
                        return Path(*parts[: i + 1])
    return None


def clean_command(cmd: str) -> str:
    """Clean tldr command template placeholders.

    Converts {{placeholder}} to realistic values and strips markup.
    """
    # Remove [-flag|--long-flag] alternatives: keep the long form
    def pick_long(m):
        options = m.group(1).split("|")
        # Prefer long flag if available
        for opt in options:
            opt = opt.strip()
            if opt.startswith("--"):
                return opt
        return options[-1].strip()

    cmd = re.sub(r"\{\{?\[([^\]]+)\]\}?\}", pick_long, cmd)

    # Replace {{value}} placeholders with the content (strip braces)
    cmd = re.sub(r"\{\{([^}]*)\}\}", r"\1", cmd)

    # Handle any remaining single braces
    cmd = cmd.replace("{", "").replace("}", "")

    return cmd.strip()


def split_prefix_completions(cmd: str, min_prefix: int = 4) -> list[tuple[str, str]]:
    """Generate prefix->full command completion pairs.

    Split at word boundaries, flag boundaries, and mid-token points.
    """
    pairs = []
    if len(cmd) < min_prefix + 2:
        return pairs

    # Split points: after spaces, after -, after /, at various fractions
    split_indices = set()

    # After each space (word boundary)
    for i, c in enumerate(cmd):
        if c == " " and min_prefix <= i < len(cmd) - 2:
            split_indices.add(i + 1)

    # After flags (e.g., "cmd --fl" completions)
    for m in re.finditer(r"--?\w+", cmd):
        start = m.start()
        end = m.end()
        flag = m.group()
        if len(flag) > 3:
            # Split mid-flag
            for frac in (0.5, 0.75):
                idx = start + max(2, int(len(flag) * frac))
                if min_prefix <= idx < len(cmd) - 1:
                    split_indices.add(idx)

    # Fractional splits of overall command
    for frac in (0.3, 0.5, 0.7):
        idx = int(len(cmd) * frac)
        if min_prefix <= idx < len(cmd) - 1:
            split_indices.add(idx)

    for idx in sorted(split_indices):
        prefix = cmd[:idx]
        pairs.append((prefix, cmd))

    return pairs


def parse_tldr_page(filepath: Path) -> dict | None:
    """Parse a single tldr markdown page.

    Returns dict with keys: name, description, examples [(desc, cmd), ...]
    """
    try:
        text = filepath.read_text(encoding="utf-8", errors="replace")
    except (OSError, UnicodeDecodeError):
        return None

    lines = text.strip().split("\n")
    if not lines:
        return None

    name = None
    description_lines = []
    examples = []

    i = 0
    # Find command name (# header)
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("# "):
            name = line[2:].strip()
            i += 1
            break
        i += 1

    if not name:
        return None

    # Collect description (> prefixed lines)
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("> "):
            desc = line[2:].strip()
            # Skip "More information:" and "See also:" lines
            if not desc.startswith("More information:") and not desc.startswith("See also:"):
                description_lines.append(desc)
        elif line.startswith("- ") or line.startswith("`"):
            break
        i += 1

    # Collect examples (alternating "- description:" and "`command`")
    current_desc = None
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("- "):
            current_desc = line[2:].rstrip(":")
        elif line.startswith("`") and line.endswith("`"):
            cmd = line[1:-1]
            cmd = clean_command(cmd)
            if cmd and current_desc:
                examples.append((current_desc, cmd))
            elif cmd:
                examples.append((None, cmd))
            current_desc = None
        i += 1

    if not examples:
        return None

    description = " ".join(description_lines) if description_lines else None

    return {
        "name": name,
        "description": description,
        "examples": examples,
    }


def generate_examples(page: dict) -> list[dict]:
    """Generate all training examples from a parsed tldr page."""
    results = []
    name = page["name"]
    desc = page["description"]

    for ex_desc, cmd in page["examples"]:
        # 1. Raw command
        results.append({"text": f"$ {cmd}"})

        # 2. Intent -> command (example description)
        if ex_desc:
            results.append({"text": f"Translate: {ex_desc}\n$ {cmd}"})

        # 3. Intent -> command (page description + example)
        if desc and ex_desc:
            results.append({"text": f"Translate: {desc} - {ex_desc}\n$ {cmd}"})

        # 4. Command name context
        if ex_desc:
            results.append({"text": f"Translate: {name}: {ex_desc}\n$ {cmd}"})

        # 5. Prefix completions
        for prefix, full in split_prefix_completions(cmd):
            results.append({"text": f"Complete: $ {prefix}\n$ {full}"})

    return results


def main():
    root = find_tldr_root()
    if root is None:
        print("Error: Could not find tldr pages cache.", file=sys.stderr)
        print("Try running: tldr --update", file=sys.stderr)
        sys.exit(1)

    print(f"Found tldr pages at: {root}", file=sys.stderr)

    # Collect all markdown files from relevant platforms
    md_files = []
    # Check if root has platform subdirs or is itself a platform dir
    subdirs = [d for d in root.iterdir() if d.is_dir() and d.name in RELEVANT_PLATFORMS]
    if subdirs:
        for subdir in sorted(subdirs):
            platform_files = sorted(subdir.glob("*.md"))
            md_files.extend(platform_files)
            print(f"  {subdir.name}: {len(platform_files)} pages", file=sys.stderr)
    else:
        # Flat structure or different layout
        md_files = sorted(root.rglob("*.md"))
        # Filter out LICENSE etc
        md_files = [f for f in md_files if not f.name.startswith("LICENSE")]
        print(f"  Found {len(md_files)} pages", file=sys.stderr)

    if not md_files:
        print("Error: No markdown files found.", file=sys.stderr)
        sys.exit(1)

    total_examples = 0
    total_pages = 0
    failed = 0

    for i, filepath in enumerate(md_files):
        if (i + 1) % 500 == 0:
            print(f"  Processing {i + 1}/{len(md_files)} ({total_examples} examples)...", file=sys.stderr)

        page = parse_tldr_page(filepath)
        if page is None:
            failed += 1
            continue

        examples = generate_examples(page)
        for ex in examples:
            print(json.dumps(ex, ensure_ascii=False))

        total_pages += 1
        total_examples += len(examples)

    print(f"\nDone: {total_pages} pages parsed, {failed} failed, {total_examples} examples generated.", file=sys.stderr)


if __name__ == "__main__":
    main()
