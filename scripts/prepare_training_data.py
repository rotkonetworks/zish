#!/usr/bin/env python3
"""Prepare CTM training data from zish completion logs and shell history.

Reads:
  ~/.zish/completion_log.jsonl  — tab completion pairs (context, prefix, completion)

Outputs:
  training_data.jsonl — formatted for nanochat CTM training
  Format: {"input": "partial command", "target": "full command"}

Usage:
    python prepare_training_data.py [--output training_data.jsonl] [--min-length 3]
"""

import argparse
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path


def load_completion_log(path):
    """Load completion log entries."""
    entries = []
    if not path.exists():
        return entries
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                entries.append(entry)
            except json.JSONDecodeError:
                continue
    return entries


def generate_pairs_from_completions(entries, min_prefix_len=2):
    """Generate (input, target) pairs from completion log entries.

    Each entry has: ctx (text before), pfx (typed prefix), cmp (full completion).
    We generate: input = ctx + pfx, target = ctx + cmp
    """
    pairs = []
    for entry in entries:
        ctx = entry.get('ctx', '')
        pfx = entry.get('pfx', '')
        cmp = entry.get('cmp', '')

        if len(pfx) < min_prefix_len:
            continue
        if not cmp or cmp == pfx:
            continue

        input_text = ctx + pfx
        target_text = ctx + cmp

        if len(input_text) < 2 or len(target_text) < 3:
            continue

        source = entry.get('src', 'tab')
        pairs.append({
            'input': input_text.strip(),
            'target': target_text.strip(),
            'type': f'completion_{source}' if source != 'tab' else 'completion',
        })

    return pairs


def generate_prefix_pairs(entries, min_prefix_len=3):
    """Generate incremental prefix pairs from completed commands.

    For a command like "git commit -m 'fix bug'", generate:
      git -> git commit -m 'fix bug'
      git c -> git commit -m 'fix bug'
      git co -> git commit -m 'fix bug'
      git com -> git commit -m 'fix bug'
      ...
    """
    pairs = []
    # collect unique completed commands from entries where cmp has ctx
    commands = set()
    for entry in entries:
        ctx = entry.get('ctx', '')
        cmp = entry.get('cmp', '')
        full = (ctx + cmp).strip()
        if len(full) > min_prefix_len:
            commands.add(full)

    for cmd in commands:
        # generate prefix pairs at word boundaries and every 2 chars
        for i in range(min_prefix_len, len(cmd)):
            # at word boundaries (after space)
            if cmd[i-1] == ' ' or i % 2 == 0:
                prefix = cmd[:i]
                pairs.append({
                    'input': prefix,
                    'target': cmd,
                    'type': 'prefix'
                })

    return pairs


def deduplicate(pairs):
    """Remove duplicate (input, target) pairs, keeping the first."""
    seen = set()
    result = []
    for pair in pairs:
        key = (pair['input'], pair['target'])
        if key not in seen:
            seen.add(key)
            result.append(pair)
    return result


def load_translate_log(path):
    """Load ? translate query/result pairs."""
    pairs = []
    if not path.exists():
        return pairs
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                query = entry.get('query', '')
                cmd = entry.get('cmd', '')
                if query and cmd:
                    pairs.append({
                        'input': f'? {query}',
                        'target': cmd,
                        'type': 'translate',
                    })
            except json.JSONDecodeError:
                continue
    return pairs


def load_command_log(path):
    """Load executed commands from command_log.jsonl."""
    commands = []
    if not path.exists():
        return commands
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                cmd = entry.get('cmd', '')
                exit_code = entry.get('exit', 0)
                # Only use successful commands for training
                if cmd and exit_code == 0 and len(cmd) >= 3:
                    commands.append(cmd)
            except json.JSONDecodeError:
                continue
    return commands


def load_shell_history():
    """Load commands from bash/zsh history files."""
    commands = []
    # zsh history: lines like ": timestamp:0;command" or plain commands
    zsh_hist = Path.home() / '.zsh_history'
    if zsh_hist.exists():
        try:
            with open(zsh_hist, 'rb') as f:
                for raw_line in f:
                    try:
                        line = raw_line.decode('utf-8', errors='ignore').strip()
                    except:
                        continue
                    if not line:
                        continue
                    # zsh extended history format
                    if line.startswith(': ') and ';' in line:
                        cmd = line.split(';', 1)[1]
                    else:
                        cmd = line
                    cmd = cmd.strip()
                    if len(cmd) >= 3 and not cmd.startswith('#'):
                        commands.append(cmd)
        except:
            pass

    # bash history: plain lines
    bash_hist = Path.home() / '.bash_history'
    if bash_hist.exists():
        try:
            with open(bash_hist, 'r', errors='ignore') as f:
                for line in f:
                    cmd = line.strip()
                    if len(cmd) >= 3 and not cmd.startswith('#'):
                        commands.append(cmd)
        except:
            pass

    return commands


def generate_pairs_from_history(commands, min_prefix_len=3):
    """Generate (input, target) pairs from shell history.

    For each unique command, generate prefix pairs at word boundaries.
    This teaches the model to complete partial commands.
    """
    pairs = []
    # count frequency for weighting
    freq = Counter(commands)
    seen_cmds = set()

    for cmd, count in freq.most_common():
        if cmd in seen_cmds:
            continue
        seen_cmds.add(cmd)
        if len(cmd) < min_prefix_len + 2:
            continue

        # generate pairs at word boundaries and every few chars
        words = cmd.split()
        if not words:
            continue

        # pair at each word boundary
        pos = 0
        for i, word in enumerate(words):
            pos = cmd.index(word, pos)
            if pos >= min_prefix_len and pos < len(cmd):
                pairs.append({
                    'input': cmd[:pos].rstrip(),
                    'target': cmd,
                    'type': 'history',
                    'freq': count,
                })
            pos += len(word)

        # also at mid-word positions for the first 2 words
        pos = 0
        for i, word in enumerate(words[:2]):
            pos = cmd.index(word, pos)
            for j in range(min_prefix_len, pos + len(word)):
                if j > pos and j < len(cmd) and j % 3 == 0:
                    pairs.append({
                        'input': cmd[:j],
                        'target': cmd,
                        'type': 'history_prefix',
                    })
            pos += len(word) + 1

    return pairs


KNOWN_COMMANDS = {
    # core unix
    'ls', 'cd', 'cp', 'mv', 'rm', 'mkdir', 'rmdir', 'cat', 'head', 'tail',
    'less', 'more', 'wc', 'sort', 'uniq', 'tr', 'cut', 'paste', 'tee',
    'find', 'locate', 'which', 'whereis', 'file', 'stat', 'touch', 'ln',
    'chmod', 'chown', 'chgrp', 'umask', 'df', 'du', 'mount', 'umount',
    'dd', 'tar', 'gzip', 'gunzip', 'bzip2', 'xz', 'unzip', 'zip', '7z',
    'echo', 'printf', 'read', 'test', 'true', 'false', 'yes', 'env', 'export',
    'source', 'alias', 'unalias', 'type', 'hash', 'eval', 'exec', 'set',
    'unset', 'trap', 'wait', 'kill', 'killall', 'pkill', 'pgrep', 'nohup',
    'nice', 'renice', 'time', 'timeout', 'watch', 'xargs', 'parallel',
    'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'sed', 'awk', 'perl',
    'diff', 'patch', 'comm', 'cmp', 'md5sum', 'sha256sum', 'sha1sum',
    'ps', 'top', 'htop', 'btop', 'free', 'uptime', 'uname', 'hostname',
    'whoami', 'id', 'groups', 'who', 'w', 'last', 'finger', 'su', 'sudo',
    'doas', 'passwd', 'useradd', 'userdel', 'usermod', 'groupadd',
    'date', 'cal', 'sleep', 'at', 'crontab', 'batch',
    'man', 'info', 'help', 'whatis', 'apropos',
    'clear', 'reset', 'tput', 'stty',
    'lsblk', 'blkid', 'fdisk', 'parted', 'mkfs', 'fsck', 'swapon', 'swapoff',
    'lsof', 'fuser', 'strace', 'ltrace', 'gdb', 'valgrind',
    'dmesg', 'journalctl', 'logger', 'syslog',
    'lspci', 'lsusb', 'lscpu', 'lsmod', 'modprobe', 'modinfo', 'insmod', 'rmmod',
    'ip', 'ifconfig', 'route', 'iptables', 'nftables', 'netstat', 'ss',
    'ping', 'traceroute', 'mtr', 'dig', 'nslookup', 'host', 'whois',
    'curl', 'wget', 'ssh', 'scp', 'rsync', 'sftp', 'ftp', 'nc', 'ncat',
    'socat', 'telnet', 'nmap', 'tcpdump', 'wireshark', 'tshark',
    'nmcli', 'iwctl', 'iwlist', 'wpa_supplicant', 'networkctl', 'resolvectl',
    # editors
    'vi', 'vim', 'nvim', 'nano', 'emacs', 'code', 'hx', 'helix', 'kakoune',
    'ed', 'ex', 'view',
    # dev tools
    'git', 'gh', 'hub', 'svn', 'hg',
    'make', 'cmake', 'ninja', 'meson', 'autoconf', 'automake',
    'gcc', 'g++', 'clang', 'clang++', 'cc', 'ld', 'ar', 'nm', 'objdump',
    'python', 'python3', 'pip', 'pip3', 'pipx', 'conda', 'venv',
    'node', 'npm', 'npx', 'yarn', 'pnpm', 'bun', 'deno',
    'cargo', 'rustc', 'rustup', 'rust-analyzer',
    'go', 'zig', 'java', 'javac', 'kotlin', 'scala', 'sbt', 'gradle', 'mvn',
    'ruby', 'gem', 'bundle', 'irb', 'rails',
    'php', 'composer', 'lua', 'luarocks',
    'dotnet', 'swift', 'swiftc',
    'gdb', 'lldb', 'perf', 'valgrind', 'callgrind', 'cachegrind',
    # containers & virt
    'docker', 'podman', 'kubectl', 'k9s', 'helm', 'minikube', 'kind',
    'vagrant', 'terraform', 'ansible', 'ansible-playbook',
    'qemu', 'virsh', 'virt-install', 'lxc', 'lxd', 'systemd-nspawn',
    # package managers
    'pacman', 'yay', 'paru', 'apt', 'apt-get', 'dpkg', 'dnf', 'yum', 'rpm',
    'zypper', 'emerge', 'brew', 'nix', 'snap', 'flatpak', 'pkg',
    'makepkg', 'pikaur', 'trizen',
    # system
    'systemctl', 'loginctl', 'timedatectl', 'localectl', 'hostnamectl',
    'service', 'chkconfig', 'update-rc.d',
    'reboot', 'shutdown', 'poweroff', 'halt', 'init',
    'sysctl', 'ulimit', 'cgroups',
    # desktop
    'xdg-open', 'xdg-mime', 'xclip', 'xsel', 'wl-copy', 'wl-paste',
    'xrandr', 'arandr', 'xdpyinfo', 'xev', 'xprop', 'xwininfo',
    'xdotool', 'xeyes', 'xclock',
    'alacritty', 'kitty', 'wezterm', 'foot', 'st', 'urxvt', 'xterm',
    'firefox', 'chromium', 'brave', 'qutebrowser',
    'mpv', 'vlc', 'ffmpeg', 'ffprobe', 'ffplay',
    'feh', 'sxiv', 'imv', 'gimp', 'inkscape', 'imagemagick', 'convert',
    'pavucontrol', 'pactl', 'amixer', 'alsamixer',
    'sway', 'i3', 'bspwm', 'dwm', 'hyprland', 'waybar', 'polybar',
    'rofi', 'dmenu', 'wofi', 'bemenu', 'fzf',
    'dunst', 'mako', 'notify-send',
    'ncspot', 'spotify', 'cmus', 'mpd', 'mpc',
    # file managers & tools
    'ranger', 'nnn', 'lf', 'vifm', 'mc',
    'tree', 'ncdu', 'dust', 'duf', 'exa', 'eza', 'lsd', 'bat', 'fd',
    'jq', 'yq', 'xq', 'fx', 'gron',
    'tmux', 'screen', 'zellij', 'byobu',
    'htop', 'btop', 'gotop', 'glances', 'nmon', 'iotop', 'nethogs',
    'ripgrep', 'sd', 'procs', 'bandwhich', 'grex', 'hyperfine', 'tokei',
    # crypto & blockchain
    'pcli', 'zcash-cli', 'bitcoin-cli', 'solana', 'polkadot',
    'subxt', 'subkey',
    # misc tools
    'inv', 'invoke', 'task', 'just', 'earthly',
    'act', 'tilt',
    'age', 'gpg', 'gpg2', 'openssl', 'ssh-keygen', 'ssh-add', 'ssh-agent',
    'pass', 'gopass', 'bitwarden-cli',
    'rclone', 'restic', 'borg', 'borgmatic',
    'hugo', 'jekyll', 'zola', 'mdbook',
    'asciinema', 'svg-term',
}


def is_clean_command(cmd):
    """Filter out garbage: typos, code snippets, URLs, keyboard mashing."""
    if len(cmd) < 3 or len(cmd) > 200:
        return False

    words = cmd.split()
    if not words:
        return False
    first = words[0]

    # Must start with a plausible command
    if len(first) < 2:
        return False

    # No code snippets
    if first.startswith(('(', '{', '"', '$_', 'Box::')):
        return False
    if '::' in first and not first.startswith(('systemctl', 'journalctl')):
        return False

    # No bare paths as commands (but allow ~/bin style)
    if first.startswith(('/home/', '/tmp/', '/var/', '/etc/', '/sys/', '/proc/')):
        return False

    # No bare URLs or long hashes
    if first.startswith(('http://', 'https://', 'ftp://')):
        return False
    if '://' in first:
        return False

    # Skip URLs with OAuth tokens, verification codes, API keys in args
    if any(s in cmd for s in ['oauth?code=', 'verify-email/', 'token=', 'access_token=',
                               'api_key=', 'apikey=', 'secret=']):
        return False

    # Skip commands containing long hex/alnum strings (tokens, hashes, keys, addresses)
    if re.search(r'[0-9a-f]{32,}', cmd.lower()):
        return False
    # Also catch mixed-case long tokens (crypto addresses, etc)
    if any(len(w) > 40 and sum(c.isalnum() for c in w) > 35 for w in words):
        return False

    # Strip ~/.cargo/bin/ etc for first-word check
    check_word = first
    if first.startswith(('~/.', './')):
        check_word = first.rsplit('/', 1)[-1]

    # Env var prefix: FOO=bar cmd... — check the actual command
    if '=' in check_word and check_word[0].isupper():
        if len(words) > 1:
            check_word = words[1]
            if check_word.startswith(('~/.', './')):
                check_word = check_word.rsplit('/', 1)[-1]

    # Validate first word is a known command or looks like one
    if check_word.lower() not in KNOWN_COMMANDS:
        # Allow paths (./foo, /usr/bin/foo)
        if check_word.startswith(('./', '/')):
            pass
        # Allow known patterns: ending in ctl, -cli, etc
        elif any(check_word.endswith(s) for s in ('ctl', '-cli')):
            pass
        # Allow if it contains a hyphen (likely a real tool: rust-analyzer, etc)
        elif '-' in check_word and len(check_word) > 3:
            pass
        # For unknown short words (< 8 chars), reject — likely typos
        elif len(check_word) < 8:
            return False
        # Unknown long words — check for gibberish
        elif check_word.isalpha():
            vowels = sum(1 for c in check_word.lower() if c in 'aeiou')
            if vowels / len(check_word) < 0.2:
                return False
            if len(set(check_word)) < len(check_word) * 0.4:
                return False

    # Skip trailing backslash continuation lines (partial)
    if cmd.endswith('\\'):
        return False

    # Skip keyboard mashing: lots of repeated chars or no spaces in long strings
    if len(cmd) > 30 and ' ' not in cmd and '/' not in cmd and '|' not in cmd:
        return False

    # Skip natural language (words with no special chars suggest prose, not commands)
    if len(words) > 3 and not any(c in cmd for c in '|;>&/=-~'):
        return False
    # Long commands with lots of lowercase words and few special chars
    if len(words) > 6:
        alpha_words = sum(1 for w in words if w.isalpha() and w.islower())
        if alpha_words > len(words) * 0.7:
            return False

    # Skip prompts pasted from terminal (starts with [X] user@host)
    if cmd.startswith('[') and '@' in cmd[:30]:
        return False

    # Skip typos: commands ending with ] or other junk chars
    if first[-1] in ']})>.':
        return False

    # Skip very short commands that aren't useful for training
    if len(cmd) < 5:
        return False

    # Skip 2-char args to known commands (cd lr, rg ed — too specific)
    if len(words) == 2 and len(words[1]) <= 2 and words[1].isalpha():
        return False

    # Skip commands with /home/user/ paths (too user-specific for training)
    if '/home/' in cmd and '/home/alice/' in cmd:
        # Keep if it's a common pattern like ssh-add, cat, etc
        # but skip overly specific paths
        if cmd.count('/') > 5:
            return False

    # Skip math expressions
    if re.match(r'^[\d+\-*/().]+$', cmd):
        return False

    return True


def normalize_command(cmd):
    """Normalize command for training: strip home dir paths, clean up."""
    # Strip ~/.cargo/bin/ prefix
    cmd = re.sub(r'~/\.cargo/bin/', '', cmd)
    # Strip ~/.local/bin/ prefix
    cmd = re.sub(r'~/\.local/bin/', '', cmd)
    return cmd


def main():
    parser = argparse.ArgumentParser(description='Prepare CTM training data from zish logs')
    parser.add_argument('--output', '-o', default='training_data.jsonl',
                        help='Output file path')
    parser.add_argument('--min-length', type=int, default=3,
                        help='Minimum prefix length for training pairs')
    parser.add_argument('--completion-log', default=None,
                        help='Path to completion_log.jsonl (default: ~/.zish/completion_log.jsonl)')
    parser.add_argument('--prefix-pairs', action='store_true',
                        help='Also generate incremental prefix pairs for each command')
    parser.add_argument('--history', action='store_true',
                        help='Also generate pairs from bash/zsh history')
    args = parser.parse_args()

    # Find completion log
    if args.completion_log:
        comp_path = Path(args.completion_log)
    else:
        comp_path = Path.home() / '.zish' / 'completion_log.jsonl'

    print(f"Loading completion log from {comp_path}...")
    entries = load_completion_log(comp_path)
    print(f"  Found {len(entries)} completion entries")

    # Generate pairs
    pairs = generate_pairs_from_completions(entries, args.min_length)
    print(f"  Generated {len(pairs)} completion pairs")

    if args.prefix_pairs:
        prefix_pairs = generate_prefix_pairs(entries, args.min_length)
        pairs.extend(prefix_pairs)
        print(f"  Generated {len(prefix_pairs)} prefix pairs")

    # Shell history pairs
    if args.history:
        print("Loading shell history...")
        history_cmds = load_shell_history()
        print(f"  Found {len(history_cmds)} history entries ({len(set(history_cmds))} unique)")
        history_pairs = generate_pairs_from_history(history_cmds, args.min_length)
        pairs.extend(history_pairs)
        print(f"  Generated {len(history_pairs)} history pairs")

    # Always load translate log and command log (lightweight, no flag needed)
    translate_path = Path.home() / '.zish' / 'translate_log.jsonl'
    translate_pairs = load_translate_log(translate_path)
    if translate_pairs:
        pairs.extend(translate_pairs)
        print(f"  Loaded {len(translate_pairs)} translate pairs from {translate_path}")

    command_path = Path.home() / '.zish' / 'command_log.jsonl'
    cmd_log_cmds = load_command_log(command_path)
    if cmd_log_cmds:
        print(f"  Loaded {len(cmd_log_cmds)} commands from {command_path} ({len(set(cmd_log_cmds))} unique)")
        cmd_log_pairs = generate_pairs_from_history(cmd_log_cmds, args.min_length)
        pairs.extend(cmd_log_pairs)
        print(f"  Generated {len(cmd_log_pairs)} command log pairs")

    # Deduplicate
    pairs = deduplicate(pairs)
    print(f"  {len(pairs)} unique pairs after dedup")

    # Write output in two formats: training pairs and nanochat text format
    output_path = Path(args.output)
    with open(output_path, 'w') as f:
        for pair in pairs:
            f.write(json.dumps(pair, ensure_ascii=False) + '\n')

    # Also write nanochat-compatible format ({"text": "..."})
    nanochat_path = output_path.with_suffix('.nanochat.jsonl')
    with open(nanochat_path, 'w') as f:
        seen = set()
        # Collect commands by frequency
        cmd_freq = Counter()
        for pair in pairs:
            cmd_freq[pair['target']] += 1
        for cmd, _ in cmd_freq.most_common():
            # Filter: skip control chars, too short, or duplicates
            clean = ''.join(c for c in cmd if ord(c) >= 32 or c in '\t').strip()
            if len(clean) < 3 or clean in seen:
                continue
            # Skip lines that are clearly not useful shell commands
            if not is_clean_command(clean):
                continue
            clean = normalize_command(clean)
            if len(clean) < 3 or clean in seen:
                continue
            seen.add(clean)
            f.write(json.dumps({"text": clean}, ensure_ascii=False) + '\n')
    print(f"  Also wrote {len(seen)} unique commands to {nanochat_path}")

    print(f"Wrote {len(pairs)} training pairs to {output_path}")

    # Print stats
    type_counts = Counter(p['type'] for p in pairs)
    for t, count in type_counts.most_common():
        print(f"  {t}: {count}")

    # Print some examples
    if pairs:
        print("\nExamples:")
        for pair in pairs[:5]:
            print(f"  '{pair['input']}' -> '{pair['target']}'")


if __name__ == '__main__':
    main()
