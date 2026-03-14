#!/usr/bin/env python3
"""Mine --help output from common CLI tools to generate training data.

Extracts flags, subcommands, and their descriptions from help text,
then generates JSONL training examples for shell completion.

Usage: python3 mine_help_flags.py > help_training.jsonl
"""

import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field

COMMANDS = [
    # Version control
    "git", "svn", "hg", "fossil",
    # Containers & orchestration
    "docker", "podman", "docker-compose", "kubectl", "helm", "minikube",
    "kind", "k3s", "crictl", "ctr", "nerdctl", "skopeo", "buildah",
    # Systemd
    "systemctl", "journalctl", "loginctl", "timedatectl", "hostnamectl",
    "localectl", "coredumpctl", "networkctl", "resolvectl", "busctl",
    "machinectl", "portablectl",
    # Networking tools
    "curl", "wget", "httpie", "http", "ssh", "scp", "sftp", "rsync",
    "ip", "ss", "netstat", "nmap", "dig", "nslookup", "host", "ping",
    "traceroute", "tracepath", "mtr", "iptables", "ip6tables", "nft",
    "ufw", "firewall-cmd", "tcpdump", "socat", "nc", "ncat", "aria2c",
    "ab", "wrk", "vegeta",
    # File operations
    "find", "fd", "grep", "rg", "ag", "sed", "awk", "gawk",
    "tar", "zip", "unzip", "gzip", "gunzip", "bzip2", "xz", "zstd",
    "lz4", "7z", "rar", "unrar",
    "cat", "bat", "head", "tail", "sort", "uniq", "wc", "cut", "tr",
    "paste", "join", "comm", "diff", "patch", "colordiff",
    "cp", "mv", "rm", "mkdir", "rmdir", "touch", "install",
    "ln", "readlink", "realpath", "basename", "dirname",
    "file", "stat", "ls", "exa", "eza", "lsd", "tree",
    "tee", "xargs", "parallel",
    # Build tools
    "make", "cmake", "ninja", "meson", "autoconf", "automake", "libtool",
    "pkg-config", "m4",
    # Compilers & runtimes
    "gcc", "g++", "clang", "clang++", "cc",
    "rustc", "cargo", "rustup",
    "go", "gofmt", "goimports",
    "python3", "python", "pip", "pip3", "pipx", "poetry", "uv",
    "node", "npm", "npx", "yarn", "pnpm", "deno", "bun",
    "java", "javac", "jar", "mvn", "gradle",
    "ruby", "gem", "bundle",
    "perl", "cpan",
    "lua", "luarocks",
    "zig", "zls",
    "ghc", "cabal", "stack",
    "dotnet",
    "elixir", "mix", "iex",
    "swift", "swiftc",
    "julia",
    "R", "Rscript",
    # Editors
    "vim", "nvim", "nano", "emacs", "code", "subl", "micro", "helix",
    # Pagers & info
    "less", "more", "man", "info", "which", "whereis", "type", "whatis",
    "apropos",
    # System monitoring
    "df", "du", "free", "top", "htop", "btop", "iotop", "iftop",
    "vmstat", "iostat", "mpstat", "sar", "dstat", "nmon",
    "lsof", "fuser",
    # Process management
    "ps", "kill", "pkill", "pgrep", "killall",
    "nice", "renice", "nohup", "timeout",
    "bg", "fg", "jobs", "wait",
    "at", "batch", "crontab",
    "screen", "tmux", "byobu",
    # Debugging & profiling
    "strace", "ltrace", "perf", "gdb", "lldb", "valgrind",
    "objdump", "nm", "ldd", "strip", "ar", "ld", "as",
    "readelf", "strings", "hexdump", "xxd", "od",
    # Disk & filesystems
    "mount", "umount", "fdisk", "gdisk", "parted", "mkfs", "fsck",
    "lsblk", "blkid", "findmnt", "dd", "sync",
    "lvm", "pvs", "vgs", "lvs",
    "btrfs", "zfs", "zpool",
    # Hardware info
    "lsusb", "lspci", "lscpu", "lsmem", "lshw", "dmidecode", "hwinfo",
    "sensors", "acpi",
    # User & group management
    "useradd", "userdel", "usermod", "groupadd", "groupdel", "groupmod",
    "passwd", "chpasswd", "su", "sudo",
    "chown", "chmod", "chgrp", "umask",
    "id", "whoami", "who", "w", "last", "lastlog", "finger",
    # Package managers
    "apt", "apt-get", "apt-cache", "dpkg",
    "yum", "dnf", "rpm",
    "pacman", "yay", "paru", "makepkg",
    "zypper",
    "apk", "snap", "flatpak", "nix", "nix-env", "brew",
    # IaC & DevOps
    "terraform", "ansible", "ansible-playbook", "vagrant", "packer",
    "pulumi",
    # Cloud CLIs
    "aws", "gcloud", "az",
    # Misc
    "env", "printenv",
    "date", "cal", "bc", "dc",
    "jq", "yq", "fx",
    "fzf", "sk",
    "openssl", "gpg", "age", "ssh-keygen",
    "iconv", "dos2unix", "unix2dos",
    "watch", "entr",
    "sysctl", "dmesg", "modprobe", "lsmod", "modinfo",
    "systemd-analyze", "systemd-run", "systemd-cat",
    "ip", "tc", "ethtool", "iwconfig", "nmcli",
    "cfdisk", "wipefs",
    "chroot", "unshare", "nsenter",
    "setfacl", "getfacl",
    "rsyslog", "logger",
    "column", "fmt", "fold", "expand", "unexpand",
    "yes", "seq", "shuf", "factor",
    "base64", "md5sum", "sha256sum", "sha1sum",
    "uptime", "hostname", "uname",
    "wall", "mesg", "write",
    "cmp", "tsort", "look",
]

# Remove duplicates while preserving order
seen = set()
COMMANDS_DEDUP = []
for c in COMMANDS:
    if c not in seen:
        seen.add(c)
        COMMANDS_DEDUP.append(c)
COMMANDS = COMMANDS_DEDUP


# Common usage patterns for well-known commands (manually curated)
# These supplement auto-extracted data and ensure coverage for commands
# whose --help output is hard to parse
MANUAL_PATTERNS: dict[str, list[str]] = {
    "ssh": [
        "$ ssh user@host",
        "$ ssh -p 22 user@host",
        "$ ssh -i ~/.ssh/id_rsa user@host",
        "$ ssh -L 8080:localhost:80 user@host",
        "$ ssh -R 8080:localhost:80 user@host",
        "$ ssh -D 1080 user@host",
        "$ ssh -N -f user@host",
        "$ ssh -o StrictHostKeyChecking=no user@host",
        "$ ssh -A user@host",
        "$ ssh -X user@host",
        "$ ssh -t user@host",
        "$ ssh -v user@host",
        "$ ssh -q user@host",
        "$ ssh -C user@host",
        "$ ssh -J jumphost user@host",
        "$ ssh user@host command",
    ],
    "scp": [
        "$ scp file user@host:/path",
        "$ scp user@host:/path file",
        "$ scp -r dir user@host:/path",
        "$ scp -P 22 file user@host:/path",
        "$ scp -i ~/.ssh/id_rsa file user@host:/path",
        "$ scp -C file user@host:/path",
        "$ scp -p file user@host:/path",
        "$ scp -q file user@host:/path",
        "$ scp -v file user@host:/path",
        "$ scp -3 host1:/path host2:/path",
    ],
    "sftp": [
        "$ sftp user@host",
        "$ sftp -P 22 user@host",
        "$ sftp -i ~/.ssh/id_rsa user@host",
        "$ sftp -b batchfile user@host",
        "$ sftp -r user@host",
    ],
    "rsync": [
        "$ rsync -avz src/ dest/",
        "$ rsync -avz src/ user@host:/dest/",
        "$ rsync -avz user@host:/src/ dest/",
        "$ rsync -avz --delete src/ dest/",
        "$ rsync -avz --progress src/ dest/",
        "$ rsync -avz --exclude='*.log' src/ dest/",
        "$ rsync -avz --include='*.txt' --exclude='*' src/ dest/",
        "$ rsync -avz --dry-run src/ dest/",
        "$ rsync -avz -e 'ssh -p 22' src/ user@host:/dest/",
        "$ rsync -avz --partial --progress src/ dest/",
        "$ rsync -avz --compress src/ dest/",
        "$ rsync -avz --bwlimit=1000 src/ dest/",
        "$ rsync -avz --checksum src/ dest/",
        "$ rsync --archive src/ dest/",
        "$ rsync --verbose src/ dest/",
        "$ rsync --recursive src/ dest/",
        "$ rsync --links src/ dest/",
        "$ rsync --perms src/ dest/",
        "$ rsync --times src/ dest/",
        "$ rsync --human-readable src/ dest/",
    ],
    "ip": [
        "$ ip addr",
        "$ ip addr show",
        "$ ip addr add 192.168.1.1/24 dev eth0",
        "$ ip addr del 192.168.1.1/24 dev eth0",
        "$ ip link",
        "$ ip link show",
        "$ ip link set eth0 up",
        "$ ip link set eth0 down",
        "$ ip route",
        "$ ip route show",
        "$ ip route add default via 192.168.1.1",
        "$ ip route del default",
        "$ ip route get 8.8.8.8",
        "$ ip neigh",
        "$ ip neigh show",
        "$ ip -4 addr",
        "$ ip -6 addr",
        "$ ip -s link",
        "$ ip -j addr",
        "$ ip -br addr",
        "$ ip -c addr",
        "$ ip rule",
        "$ ip rule show",
        "$ ip tunnel",
        "$ ip maddr",
        "$ ip monitor",
        "$ ip netns",
        "$ ip netns list",
        "$ ip netns add ns1",
        "$ ip netns exec ns1 ip addr",
    ],
    "dig": [
        "$ dig example.com",
        "$ dig example.com A",
        "$ dig example.com AAAA",
        "$ dig example.com MX",
        "$ dig example.com NS",
        "$ dig example.com TXT",
        "$ dig example.com SOA",
        "$ dig example.com CNAME",
        "$ dig @8.8.8.8 example.com",
        "$ dig +short example.com",
        "$ dig +trace example.com",
        "$ dig +noall +answer example.com",
        "$ dig -x 8.8.8.8",
        "$ dig example.com ANY",
    ],
    "nslookup": [
        "$ nslookup example.com",
        "$ nslookup example.com 8.8.8.8",
        "$ nslookup -type=MX example.com",
        "$ nslookup -type=NS example.com",
        "$ nslookup -type=TXT example.com",
        "$ nslookup -type=A example.com",
        "$ nslookup -type=AAAA example.com",
    ],
    "host": [
        "$ host example.com",
        "$ host -t MX example.com",
        "$ host -t NS example.com",
        "$ host -t TXT example.com",
        "$ host -a example.com",
        "$ host 8.8.8.8",
    ],
    "nmap": [
        "$ nmap host",
        "$ nmap -sS host",
        "$ nmap -sT host",
        "$ nmap -sU host",
        "$ nmap -sV host",
        "$ nmap -O host",
        "$ nmap -A host",
        "$ nmap -p 80,443 host",
        "$ nmap -p- host",
        "$ nmap -Pn host",
        "$ nmap -sn 192.168.1.0/24",
        "$ nmap --top-ports 100 host",
        "$ nmap -oN output.txt host",
        "$ nmap -oX output.xml host",
        "$ nmap -v host",
        "$ nmap -T4 host",
        "$ nmap --script vuln host",
    ],
    "tcpdump": [
        "$ tcpdump -i eth0",
        "$ tcpdump -i any",
        "$ tcpdump -n",
        "$ tcpdump -nn",
        "$ tcpdump -v",
        "$ tcpdump -vv",
        "$ tcpdump -w capture.pcap",
        "$ tcpdump -r capture.pcap",
        "$ tcpdump -c 100",
        "$ tcpdump port 80",
        "$ tcpdump host 192.168.1.1",
        "$ tcpdump src host 192.168.1.1",
        "$ tcpdump dst port 443",
        "$ tcpdump -A",
        "$ tcpdump -X",
        "$ tcpdump -s 0",
        "$ tcpdump -i eth0 -w capture.pcap",
    ],
    "socat": [
        "$ socat TCP-LISTEN:8080,fork TCP:localhost:80",
        "$ socat - TCP:host:port",
        "$ socat TCP-LISTEN:8080,reuseaddr,fork -",
        "$ socat UNIX-LISTEN:/tmp/sock,fork TCP:localhost:80",
        "$ socat TCP-LISTEN:8080 EXEC:/bin/sh",
        "$ socat - UNIX-CONNECT:/tmp/sock",
        "$ socat -v TCP-LISTEN:8080,fork TCP:localhost:80",
        "$ socat -d -d TCP-LISTEN:8080,fork TCP:localhost:80",
    ],
    "nc": [
        "$ nc -l 8080",
        "$ nc host port",
        "$ nc -z host port",
        "$ nc -zv host 1-1024",
        "$ nc -u host port",
        "$ nc -w 5 host port",
        "$ nc -l -p 8080",
        "$ nc -v host port",
        "$ nc -k -l 8080",
    ],
    "python3": [
        "$ python3 script.py",
        "$ python3 -c 'print(1)'",
        "$ python3 -m module",
        "$ python3 -m venv .venv",
        "$ python3 -m http.server",
        "$ python3 -m http.server 8080",
        "$ python3 -m json.tool file.json",
        "$ python3 -m pytest",
        "$ python3 -m pip install package",
        "$ python3 -i script.py",
        "$ python3 -u script.py",
        "$ python3 -O script.py",
        "$ python3 -B script.py",
        "$ python3 -v",
        "$ python3 --version",
        "$ python3 -W all script.py",
        "$ python3 -X dev script.py",
    ],
    "npm": [
        "$ npm init",
        "$ npm init -y",
        "$ npm install",
        "$ npm install package",
        "$ npm install --save-dev package",
        "$ npm install -g package",
        "$ npm install --save-exact package",
        "$ npm uninstall package",
        "$ npm update",
        "$ npm update package",
        "$ npm run script",
        "$ npm start",
        "$ npm test",
        "$ npm run build",
        "$ npm publish",
        "$ npm pack",
        "$ npm link",
        "$ npm link package",
        "$ npm ls",
        "$ npm ls --depth=0",
        "$ npm outdated",
        "$ npm audit",
        "$ npm audit fix",
        "$ npm cache clean --force",
        "$ npm config list",
        "$ npm config set key value",
        "$ npm version patch",
        "$ npm version minor",
        "$ npm version major",
        "$ npm ci",
        "$ npm exec package",
        "$ npm search query",
        "$ npm info package",
        "$ npm view package",
        "$ npm view package versions",
    ],
    "cargo": [
        "$ cargo new project",
        "$ cargo new --lib project",
        "$ cargo init",
        "$ cargo build",
        "$ cargo build --release",
        "$ cargo run",
        "$ cargo run --release",
        "$ cargo test",
        "$ cargo test test_name",
        "$ cargo test -- --nocapture",
        "$ cargo bench",
        "$ cargo check",
        "$ cargo clippy",
        "$ cargo fmt",
        "$ cargo doc",
        "$ cargo doc --open",
        "$ cargo publish",
        "$ cargo install package",
        "$ cargo uninstall package",
        "$ cargo update",
        "$ cargo clean",
        "$ cargo add package",
        "$ cargo remove package",
        "$ cargo tree",
        "$ cargo fix",
        "$ cargo audit",
        "$ cargo expand",
        "$ cargo watch -x run",
    ],
    "rustc": [
        "$ rustc file.rs",
        "$ rustc -o output file.rs",
        "$ rustc --edition 2021 file.rs",
        "$ rustc --emit asm file.rs",
        "$ rustc --emit llvm-ir file.rs",
        "$ rustc --target x86_64-unknown-linux-gnu file.rs",
        "$ rustc -C opt-level=3 file.rs",
        "$ rustc -C lto file.rs",
        "$ rustc --version",
        "$ rustc --explain E0308",
    ],
    "openssl": [
        "$ openssl version",
        "$ openssl genrsa -out key.pem 4096",
        "$ openssl req -new -key key.pem -out csr.pem",
        "$ openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365",
        "$ openssl x509 -in cert.pem -text -noout",
        "$ openssl s_client -connect host:443",
        "$ openssl enc -aes-256-cbc -in file -out file.enc",
        "$ openssl dgst -sha256 file",
        "$ openssl rand -hex 32",
        "$ openssl rand -base64 32",
        "$ openssl rsa -in key.pem -pubout -out pub.pem",
        "$ openssl pkcs12 -export -in cert.pem -inkey key.pem -out bundle.p12",
        "$ openssl verify cert.pem",
        "$ openssl ciphers -v",
    ],
    "ssh-keygen": [
        "$ ssh-keygen",
        "$ ssh-keygen -t ed25519",
        "$ ssh-keygen -t rsa -b 4096",
        "$ ssh-keygen -t ecdsa",
        "$ ssh-keygen -f ~/.ssh/mykey",
        "$ ssh-keygen -C 'comment'",
        "$ ssh-keygen -p",
        "$ ssh-keygen -l -f ~/.ssh/id_rsa.pub",
        "$ ssh-keygen -R hostname",
        "$ ssh-keygen -y -f ~/.ssh/id_rsa",
        "$ ssh-keygen -A",
    ],
    "ps": [
        "$ ps",
        "$ ps aux",
        "$ ps -ef",
        "$ ps -eo pid,ppid,cmd,%mem,%cpu",
        "$ ps -eo pid,user,comm --sort=-%mem",
        "$ ps -eo pid,user,comm --sort=-%cpu",
        "$ ps -p 1234",
        "$ ps -u username",
        "$ ps -C process_name",
        "$ ps --forest",
        "$ ps -efl",
        "$ ps axjf",
        "$ ps -T -p 1234",
    ],
    "traceroute": [
        "$ traceroute host",
        "$ traceroute -n host",
        "$ traceroute -m 30 host",
        "$ traceroute -w 3 host",
        "$ traceroute -q 3 host",
        "$ traceroute -I host",
        "$ traceroute -T host",
        "$ traceroute -p 80 host",
    ],
    "netstat": [
        "$ netstat -tulpn",
        "$ netstat -an",
        "$ netstat -rn",
        "$ netstat -i",
        "$ netstat -s",
        "$ netstat -t",
        "$ netstat -u",
        "$ netstat -l",
        "$ netstat -p",
        "$ netstat -e",
        "$ netstat -c",
    ],
    "lspci": [
        "$ lspci",
        "$ lspci -v",
        "$ lspci -vv",
        "$ lspci -k",
        "$ lspci -nn",
        "$ lspci -t",
        "$ lspci -s 00:02.0",
        "$ lspci -d 8086:1234",
    ],
    "pacman": [
        "$ pacman -S package",
        "$ pacman -Syu",
        "$ pacman -Ss query",
        "$ pacman -Si package",
        "$ pacman -Qi package",
        "$ pacman -Ql package",
        "$ pacman -Qo /path/to/file",
        "$ pacman -R package",
        "$ pacman -Rs package",
        "$ pacman -Rns package",
        "$ pacman -Sc",
        "$ pacman -Scc",
        "$ pacman -Qe",
        "$ pacman -Qm",
        "$ pacman -Qn",
        "$ pacman -Qdt",
        "$ pacman -F filename",
        "$ pacman -Fy",
        "$ pacman -U package.pkg.tar.zst",
    ],
    "go": [
        "$ go build",
        "$ go build -o output",
        "$ go run main.go",
        "$ go test",
        "$ go test ./...",
        "$ go test -v",
        "$ go test -run TestName",
        "$ go test -bench .",
        "$ go test -cover",
        "$ go mod init module",
        "$ go mod tidy",
        "$ go mod download",
        "$ go mod vendor",
        "$ go mod verify",
        "$ go get package",
        "$ go get -u package",
        "$ go install package@latest",
        "$ go fmt ./...",
        "$ go vet ./...",
        "$ go generate ./...",
        "$ go clean",
        "$ go clean -cache",
        "$ go doc package",
        "$ go env",
        "$ go env GOPATH",
        "$ go version",
        "$ go list ./...",
        "$ go work init",
        "$ go work use ./module",
    ],
    "tmux": [
        "$ tmux",
        "$ tmux new",
        "$ tmux new -s name",
        "$ tmux attach",
        "$ tmux attach -t name",
        "$ tmux detach",
        "$ tmux ls",
        "$ tmux list-sessions",
        "$ tmux kill-session -t name",
        "$ tmux kill-server",
        "$ tmux new-window",
        "$ tmux split-window",
        "$ tmux split-window -h",
        "$ tmux select-pane -t 0",
        "$ tmux resize-pane -D 5",
        "$ tmux source-file ~/.tmux.conf",
        "$ tmux send-keys 'command' Enter",
        "$ tmux capture-pane -p",
        "$ tmux set -g mouse on",
        "$ tmux set-option -g history-limit 10000",
        "$ tmux list-keys",
        "$ tmux display-message",
        "$ tmux rename-session name",
        "$ tmux rename-window name",
        "$ tmux swap-window -t 0",
        "$ tmux pipe-pane 'cat > log.txt'",
    ],
    "screen": [
        "$ screen",
        "$ screen -S name",
        "$ screen -r",
        "$ screen -r name",
        "$ screen -d -r name",
        "$ screen -ls",
        "$ screen -X quit",
        "$ screen -d name",
        "$ screen -dm command",
        "$ screen -dmS name command",
    ],
    "find": [
        "$ find . -name '*.txt'",
        "$ find . -iname '*.txt'",
        "$ find . -type f",
        "$ find . -type d",
        "$ find . -type l",
        "$ find . -size +10M",
        "$ find . -size -1k",
        "$ find . -mtime -7",
        "$ find . -mtime +30",
        "$ find . -mmin -60",
        "$ find . -newer file",
        "$ find . -empty",
        "$ find . -name '*.log' -delete",
        "$ find . -name '*.txt' -exec cat {} \\;",
        "$ find . -name '*.txt' -exec grep 'pattern' {} +",
        "$ find . -name '*.py' -print0 | xargs -0 wc -l",
        "$ find . -maxdepth 1 -type f",
        "$ find . -mindepth 2 -type f",
        "$ find . -perm 644",
        "$ find . -user root",
        "$ find . -group staff",
        "$ find . -not -name '*.txt'",
        "$ find . -name '*.txt' -o -name '*.md'",
        "$ find . -path '*/test/*'",
        "$ find . -regex '.*\\.py$'",
        "$ find / -xdev -name '*.conf'",
        "$ find . -type f -printf '%T@ %p\\n' | sort -n",
    ],
    "awk": [
        "$ awk '{print $1}' file",
        "$ awk '{print $1, $2}' file",
        "$ awk -F: '{print $1}' /etc/passwd",
        "$ awk -F, '{print $1}' file.csv",
        "$ awk '/pattern/ {print}' file",
        "$ awk 'NR==1' file",
        "$ awk 'NR>1' file",
        "$ awk 'END {print NR}' file",
        "$ awk '{sum+=$1} END {print sum}' file",
        "$ awk '{print NR, $0}' file",
        "$ awk '!seen[$0]++' file",
        "$ awk '{print length, $0}' file | sort -n",
        "$ awk 'BEGIN {OFS=\"\\t\"} {print $1, $2}' file",
        "$ awk -v var=value '{print var, $0}' file",
    ],
    "sed": [
        "$ sed 's/old/new/' file",
        "$ sed 's/old/new/g' file",
        "$ sed -i 's/old/new/g' file",
        "$ sed -i.bak 's/old/new/g' file",
        "$ sed -n '5p' file",
        "$ sed -n '5,10p' file",
        "$ sed '5d' file",
        "$ sed '/pattern/d' file",
        "$ sed -n '/pattern/p' file",
        "$ sed 's/old/new/gI' file",
        "$ sed '1i\\header' file",
        "$ sed '$a\\footer' file",
        "$ sed -e 's/a/b/' -e 's/c/d/' file",
        "$ sed '/start/,/end/d' file",
        "$ sed '=' file | sed 'N;s/\\n/\\t/'",
    ],
    "dd": [
        "$ dd if=/dev/sda of=disk.img bs=4M status=progress",
        "$ dd if=disk.img of=/dev/sda bs=4M status=progress",
        "$ dd if=/dev/zero of=file bs=1M count=100",
        "$ dd if=/dev/urandom of=file bs=1M count=100",
        "$ dd if=/dev/sda of=/dev/sdb bs=64K conv=noerror,sync status=progress",
        "$ dd if=file.iso of=/dev/sdb bs=4M status=progress",
    ],
    "tc": [
        "$ tc qdisc show",
        "$ tc qdisc show dev eth0",
        "$ tc qdisc add dev eth0 root netem delay 100ms",
        "$ tc qdisc del dev eth0 root",
        "$ tc class show dev eth0",
        "$ tc filter show dev eth0",
        "$ tc -s qdisc show dev eth0",
    ],
    "strace": [
        "$ strace command",
        "$ strace -p 1234",
        "$ strace -f command",
        "$ strace -e trace=open,read,write command",
        "$ strace -e trace=network command",
        "$ strace -e trace=file command",
        "$ strace -c command",
        "$ strace -o output.txt command",
        "$ strace -t command",
        "$ strace -T command",
        "$ strace -s 1024 command",
    ],
    "valgrind": [
        "$ valgrind ./program",
        "$ valgrind --leak-check=full ./program",
        "$ valgrind --tool=callgrind ./program",
        "$ valgrind --tool=cachegrind ./program",
        "$ valgrind --tool=massif ./program",
        "$ valgrind --track-origins=yes ./program",
        "$ valgrind --show-leak-kinds=all ./program",
        "$ valgrind -v ./program",
    ],
    "gdb": [
        "$ gdb ./program",
        "$ gdb -p 1234",
        "$ gdb --args ./program arg1 arg2",
        "$ gdb -batch -ex 'bt' -ex 'quit' core",
        "$ gdb -tui ./program",
        "$ gdb -x script.gdb ./program",
    ],
    "perf": [
        "$ perf stat command",
        "$ perf record command",
        "$ perf report",
        "$ perf top",
        "$ perf annotate",
        "$ perf list",
        "$ perf stat -e cycles,instructions command",
        "$ perf record -g command",
        "$ perf diff perf.data.old perf.data",
    ],
    # Git extended patterns
    "git": [
        "$ git init",
        "$ git clone url",
        "$ git clone --depth 1 url",
        "$ git clone --branch branch url",
        "$ git add .",
        "$ git add -p",
        "$ git add -A",
        "$ git add file",
        "$ git commit -m 'message'",
        "$ git commit -am 'message'",
        "$ git commit --amend",
        "$ git commit --amend --no-edit",
        "$ git commit --fixup HEAD",
        "$ git push",
        "$ git push origin branch",
        "$ git push -u origin branch",
        "$ git push --force-with-lease",
        "$ git push --tags",
        "$ git push origin --delete branch",
        "$ git pull",
        "$ git pull --rebase",
        "$ git pull origin branch",
        "$ git fetch",
        "$ git fetch --all",
        "$ git fetch --prune",
        "$ git fetch origin branch",
        "$ git branch",
        "$ git branch -a",
        "$ git branch -d branch",
        "$ git branch -D branch",
        "$ git branch -m old new",
        "$ git branch --merged",
        "$ git branch --no-merged",
        "$ git checkout branch",
        "$ git checkout -b branch",
        "$ git checkout -- file",
        "$ git checkout -B branch",
        "$ git switch branch",
        "$ git switch -c branch",
        "$ git switch -",
        "$ git merge branch",
        "$ git merge --no-ff branch",
        "$ git merge --squash branch",
        "$ git merge --abort",
        "$ git rebase branch",
        "$ git rebase -i HEAD~3",
        "$ git rebase --abort",
        "$ git rebase --continue",
        "$ git rebase --onto target base branch",
        "$ git cherry-pick commit",
        "$ git cherry-pick --abort",
        "$ git cherry-pick --continue",
        "$ git stash",
        "$ git stash push -m 'message'",
        "$ git stash pop",
        "$ git stash apply",
        "$ git stash list",
        "$ git stash drop",
        "$ git stash show -p",
        "$ git status",
        "$ git status -s",
        "$ git status --short",
        "$ git diff",
        "$ git diff --cached",
        "$ git diff --staged",
        "$ git diff --stat",
        "$ git diff --name-only",
        "$ git diff HEAD~1",
        "$ git diff branch1..branch2",
        "$ git diff branch1...branch2",
        "$ git log",
        "$ git log --oneline",
        "$ git log --graph",
        "$ git log --graph --oneline --all",
        "$ git log -n 10",
        "$ git log --author='name'",
        "$ git log --since='2024-01-01'",
        "$ git log --follow file",
        "$ git log -p file",
        "$ git log --stat",
        "$ git log --format='%H %s'",
        "$ git show commit",
        "$ git show HEAD:file",
        "$ git blame file",
        "$ git blame -L 10,20 file",
        "$ git bisect start",
        "$ git bisect bad",
        "$ git bisect good commit",
        "$ git bisect reset",
        "$ git tag",
        "$ git tag -a v1.0 -m 'message'",
        "$ git tag -d v1.0",
        "$ git tag -l 'v*'",
        "$ git remote",
        "$ git remote -v",
        "$ git remote add name url",
        "$ git remote remove name",
        "$ git remote rename old new",
        "$ git remote set-url origin url",
        "$ git reset HEAD file",
        "$ git reset --soft HEAD~1",
        "$ git reset --hard HEAD~1",
        "$ git reset --mixed HEAD~1",
        "$ git restore file",
        "$ git restore --staged file",
        "$ git restore --source=HEAD~1 file",
        "$ git clean -fd",
        "$ git clean -fdn",
        "$ git reflog",
        "$ git rev-parse HEAD",
        "$ git rev-parse --short HEAD",
        "$ git worktree add path branch",
        "$ git worktree list",
        "$ git worktree remove path",
        "$ git submodule add url",
        "$ git submodule update --init",
        "$ git submodule update --init --recursive",
        "$ git config --global user.name 'name'",
        "$ git config --global user.email 'email'",
        "$ git config --list",
        "$ git config --local key value",
    ],
    # Docker extended patterns
    "docker": [
        "$ docker run -it image bash",
        "$ docker run -d image",
        "$ docker run --rm image",
        "$ docker run -p 8080:80 image",
        "$ docker run -v /host:/container image",
        "$ docker run --name name image",
        "$ docker run -e VAR=value image",
        "$ docker run --env-file .env image",
        "$ docker run --network host image",
        "$ docker run --restart always image",
        "$ docker run --memory 512m image",
        "$ docker run --cpus 2 image",
        "$ docker build -t name .",
        "$ docker build -f Dockerfile .",
        "$ docker build --no-cache .",
        "$ docker build --target stage .",
        "$ docker build --build-arg KEY=value .",
        "$ docker ps",
        "$ docker ps -a",
        "$ docker ps -q",
        "$ docker stop container",
        "$ docker start container",
        "$ docker restart container",
        "$ docker rm container",
        "$ docker rm -f container",
        "$ docker rmi image",
        "$ docker images",
        "$ docker images -q",
        "$ docker pull image",
        "$ docker push image",
        "$ docker tag source target",
        "$ docker exec -it container bash",
        "$ docker exec container command",
        "$ docker logs container",
        "$ docker logs -f container",
        "$ docker logs --tail 100 container",
        "$ docker inspect container",
        "$ docker cp container:/path /local",
        "$ docker cp /local container:/path",
        "$ docker compose up",
        "$ docker compose up -d",
        "$ docker compose down",
        "$ docker compose build",
        "$ docker compose logs",
        "$ docker compose ps",
        "$ docker compose exec service bash",
        "$ docker compose run service command",
        "$ docker network ls",
        "$ docker network create name",
        "$ docker network inspect name",
        "$ docker volume ls",
        "$ docker volume create name",
        "$ docker volume rm name",
        "$ docker system prune",
        "$ docker system prune -a",
        "$ docker system df",
        "$ docker login",
        "$ docker logout",
        "$ docker save image > image.tar",
        "$ docker load < image.tar",
        "$ docker stats",
        "$ docker top container",
        "$ docker diff container",
        "$ docker commit container image",
        "$ docker history image",
        "$ docker port container",
    ],
    # Kubectl patterns
    "kubectl": [
        "$ kubectl get pods",
        "$ kubectl get pods -n namespace",
        "$ kubectl get pods -A",
        "$ kubectl get pods -o wide",
        "$ kubectl get pods -o yaml",
        "$ kubectl get pods -o json",
        "$ kubectl get pods -w",
        "$ kubectl get pods --show-labels",
        "$ kubectl get pods -l app=name",
        "$ kubectl get svc",
        "$ kubectl get deploy",
        "$ kubectl get nodes",
        "$ kubectl get ns",
        "$ kubectl get all",
        "$ kubectl get all -n namespace",
        "$ kubectl get configmap",
        "$ kubectl get secret",
        "$ kubectl get ingress",
        "$ kubectl get pv",
        "$ kubectl get pvc",
        "$ kubectl get events",
        "$ kubectl get events --sort-by=.metadata.creationTimestamp",
        "$ kubectl describe pod name",
        "$ kubectl describe node name",
        "$ kubectl describe svc name",
        "$ kubectl logs pod",
        "$ kubectl logs -f pod",
        "$ kubectl logs pod -c container",
        "$ kubectl logs --tail=100 pod",
        "$ kubectl logs --previous pod",
        "$ kubectl exec -it pod -- bash",
        "$ kubectl exec pod -- command",
        "$ kubectl apply -f file.yaml",
        "$ kubectl apply -f dir/",
        "$ kubectl apply -k dir/",
        "$ kubectl delete -f file.yaml",
        "$ kubectl delete pod name",
        "$ kubectl delete deploy name",
        "$ kubectl delete ns name",
        "$ kubectl create ns name",
        "$ kubectl create deploy name --image=image",
        "$ kubectl create secret generic name --from-literal=key=value",
        "$ kubectl create configmap name --from-file=file",
        "$ kubectl scale deploy name --replicas=3",
        "$ kubectl rollout status deploy name",
        "$ kubectl rollout history deploy name",
        "$ kubectl rollout undo deploy name",
        "$ kubectl rollout restart deploy name",
        "$ kubectl port-forward pod 8080:80",
        "$ kubectl port-forward svc/name 8080:80",
        "$ kubectl cp pod:/path /local",
        "$ kubectl top pods",
        "$ kubectl top nodes",
        "$ kubectl cordon node",
        "$ kubectl uncordon node",
        "$ kubectl drain node",
        "$ kubectl taint node name key=value:NoSchedule",
        "$ kubectl label pod name key=value",
        "$ kubectl annotate pod name key=value",
        "$ kubectl edit deploy name",
        "$ kubectl patch deploy name -p '{}'",
        "$ kubectl config view",
        "$ kubectl config use-context name",
        "$ kubectl config get-contexts",
        "$ kubectl config current-context",
        "$ kubectl config set-context name --namespace=ns",
        "$ kubectl cluster-info",
        "$ kubectl api-resources",
        "$ kubectl api-versions",
        "$ kubectl explain pod.spec",
        "$ kubectl run name --image=image",
        "$ kubectl attach pod",
        "$ kubectl debug pod --image=busybox",
        "$ kubectl wait --for=condition=ready pod name",
        "$ kubectl auth can-i create pods",
    ],
    # Curl extended patterns
    "curl": [
        "$ curl url",
        "$ curl -o file url",
        "$ curl -O url",
        "$ curl -L url",
        "$ curl -I url",
        "$ curl -v url",
        "$ curl -s url",
        "$ curl -S url",
        "$ curl -f url",
        "$ curl -X POST url",
        "$ curl -X PUT url",
        "$ curl -X DELETE url",
        "$ curl -X PATCH url",
        "$ curl -d 'data' url",
        "$ curl -d @file url",
        "$ curl --data-raw 'data' url",
        "$ curl --json '{\"key\":\"value\"}' url",
        "$ curl -H 'Content-Type: application/json' url",
        "$ curl -H 'Authorization: Bearer token' url",
        "$ curl -u user:password url",
        "$ curl -b cookies.txt url",
        "$ curl -c cookies.txt url",
        "$ curl -k url",
        "$ curl --cert cert.pem url",
        "$ curl --key key.pem url",
        "$ curl -x proxy:port url",
        "$ curl --socks5 proxy:port url",
        "$ curl -w '%{http_code}' url",
        "$ curl -w '%{time_total}' url",
        "$ curl --max-time 10 url",
        "$ curl --connect-timeout 5 url",
        "$ curl --retry 3 url",
        "$ curl -C - -O url",
        "$ curl -F 'file=@path' url",
        "$ curl --compressed url",
        "$ curl -A 'User-Agent' url",
        "$ curl -e 'referer' url",
        "$ curl -T file url",
        "$ curl --http2 url",
        "$ curl -4 url",
        "$ curl -6 url",
    ],
    # Wget patterns
    "wget": [
        "$ wget url",
        "$ wget -O file url",
        "$ wget -P dir url",
        "$ wget -c url",
        "$ wget -q url",
        "$ wget -r url",
        "$ wget -m url",
        "$ wget --mirror url",
        "$ wget --no-check-certificate url",
        "$ wget --user user --password pass url",
        "$ wget --header 'Accept: text/html' url",
        "$ wget -b url",
        "$ wget --limit-rate=200k url",
        "$ wget -i urls.txt",
        "$ wget --spider url",
        "$ wget --recursive --no-parent url",
        "$ wget --convert-links url",
        "$ wget --page-requisites url",
    ],
    # Helm patterns
    "helm": [
        "$ helm install name chart",
        "$ helm install name chart -f values.yaml",
        "$ helm install name chart --set key=value",
        "$ helm install name chart --namespace ns",
        "$ helm install name chart --create-namespace",
        "$ helm upgrade name chart",
        "$ helm upgrade --install name chart",
        "$ helm uninstall name",
        "$ helm list",
        "$ helm list -A",
        "$ helm list -n namespace",
        "$ helm repo add name url",
        "$ helm repo update",
        "$ helm repo list",
        "$ helm repo remove name",
        "$ helm search repo query",
        "$ helm search hub query",
        "$ helm show values chart",
        "$ helm show chart chart",
        "$ helm template name chart",
        "$ helm template name chart -f values.yaml",
        "$ helm get values name",
        "$ helm get manifest name",
        "$ helm history name",
        "$ helm rollback name revision",
        "$ helm status name",
        "$ helm lint chart/",
        "$ helm package chart/",
        "$ helm create name",
        "$ helm dependency update chart/",
        "$ helm pull chart --untar",
        "$ helm diff upgrade name chart",
    ],
    # Terraform patterns
    "terraform": [
        "$ terraform init",
        "$ terraform init -upgrade",
        "$ terraform plan",
        "$ terraform plan -out=plan.tfplan",
        "$ terraform plan -var 'key=value'",
        "$ terraform plan -var-file=vars.tfvars",
        "$ terraform apply",
        "$ terraform apply plan.tfplan",
        "$ terraform apply -auto-approve",
        "$ terraform apply -target=resource",
        "$ terraform destroy",
        "$ terraform destroy -auto-approve",
        "$ terraform destroy -target=resource",
        "$ terraform validate",
        "$ terraform fmt",
        "$ terraform fmt -check",
        "$ terraform output",
        "$ terraform output name",
        "$ terraform state list",
        "$ terraform state show resource",
        "$ terraform state mv source dest",
        "$ terraform state rm resource",
        "$ terraform state pull",
        "$ terraform state push",
        "$ terraform import resource id",
        "$ terraform workspace list",
        "$ terraform workspace new name",
        "$ terraform workspace select name",
        "$ terraform workspace delete name",
        "$ terraform refresh",
        "$ terraform taint resource",
        "$ terraform untaint resource",
        "$ terraform graph",
        "$ terraform providers",
        "$ terraform version",
    ],
    # Ansible patterns
    "ansible": [
        "$ ansible all -m ping",
        "$ ansible all -m shell -a 'command'",
        "$ ansible all -m copy -a 'src=file dest=/path'",
        "$ ansible host -m setup",
        "$ ansible all -i inventory -m ping",
        "$ ansible all --list-hosts",
        "$ ansible-playbook playbook.yml",
        "$ ansible-playbook playbook.yml -i inventory",
        "$ ansible-playbook playbook.yml --check",
        "$ ansible-playbook playbook.yml --diff",
        "$ ansible-playbook playbook.yml -v",
        "$ ansible-playbook playbook.yml -vvv",
        "$ ansible-playbook playbook.yml --limit host",
        "$ ansible-playbook playbook.yml --tags tag",
        "$ ansible-playbook playbook.yml --skip-tags tag",
        "$ ansible-playbook playbook.yml -e 'var=value'",
        "$ ansible-playbook playbook.yml --ask-become-pass",
        "$ ansible-galaxy install role",
        "$ ansible-galaxy collection install collection",
        "$ ansible-galaxy init role",
        "$ ansible-vault encrypt file",
        "$ ansible-vault decrypt file",
        "$ ansible-vault edit file",
        "$ ansible-vault create file",
    ],
    # AWS CLI patterns
    "aws": [
        "$ aws configure",
        "$ aws configure list",
        "$ aws sts get-caller-identity",
        "$ aws s3 ls",
        "$ aws s3 ls s3://bucket",
        "$ aws s3 cp file s3://bucket/",
        "$ aws s3 cp s3://bucket/file .",
        "$ aws s3 sync dir s3://bucket/",
        "$ aws s3 sync s3://bucket/ dir",
        "$ aws s3 rm s3://bucket/file",
        "$ aws s3 mb s3://bucket",
        "$ aws s3 rb s3://bucket",
        "$ aws s3api get-object --bucket name --key key file",
        "$ aws ec2 describe-instances",
        "$ aws ec2 describe-instances --filters 'Name=tag:Name,Values=*'",
        "$ aws ec2 start-instances --instance-ids i-1234",
        "$ aws ec2 stop-instances --instance-ids i-1234",
        "$ aws ec2 terminate-instances --instance-ids i-1234",
        "$ aws ec2 describe-security-groups",
        "$ aws ec2 describe-vpcs",
        "$ aws ec2 describe-subnets",
        "$ aws ecs list-clusters",
        "$ aws ecs list-services --cluster name",
        "$ aws ecs list-tasks --cluster name",
        "$ aws ecs describe-tasks --cluster name --tasks arn",
        "$ aws lambda list-functions",
        "$ aws lambda invoke --function-name name output.json",
        "$ aws logs describe-log-groups",
        "$ aws logs tail /aws/lambda/name --follow",
        "$ aws iam list-users",
        "$ aws iam list-roles",
        "$ aws rds describe-db-instances",
        "$ aws cloudformation list-stacks",
        "$ aws cloudformation deploy --template-file template.yaml --stack-name name",
        "$ aws ecr get-login-password | docker login --username AWS --password-stdin url",
        "$ aws ssm start-session --target i-1234",
        "$ aws --region us-east-1 s3 ls",
        "$ aws --profile prod s3 ls",
        "$ aws --output json ec2 describe-instances",
        "$ aws --output table ec2 describe-instances",
    ],
    # Systemctl extended
    "systemctl": [
        "$ systemctl start service",
        "$ systemctl stop service",
        "$ systemctl restart service",
        "$ systemctl reload service",
        "$ systemctl status service",
        "$ systemctl enable service",
        "$ systemctl disable service",
        "$ systemctl enable --now service",
        "$ systemctl is-active service",
        "$ systemctl is-enabled service",
        "$ systemctl is-failed service",
        "$ systemctl list-units",
        "$ systemctl list-units --type=service",
        "$ systemctl list-units --state=failed",
        "$ systemctl list-unit-files",
        "$ systemctl list-timers",
        "$ systemctl daemon-reload",
        "$ systemctl mask service",
        "$ systemctl unmask service",
        "$ systemctl edit service",
        "$ systemctl cat service",
        "$ systemctl show service",
        "$ systemctl show -p ActiveState service",
        "$ systemctl --user start service",
        "$ systemctl --user enable service",
        "$ systemctl poweroff",
        "$ systemctl reboot",
        "$ systemctl suspend",
        "$ systemctl hibernate",
    ],
    # Journalctl extended
    "journalctl": [
        "$ journalctl",
        "$ journalctl -f",
        "$ journalctl -u service",
        "$ journalctl -u service -f",
        "$ journalctl -u service --since '1 hour ago'",
        "$ journalctl -u service --since today",
        "$ journalctl -u service --since '2024-01-01'",
        "$ journalctl -u service -n 100",
        "$ journalctl -u service --no-pager",
        "$ journalctl -p err",
        "$ journalctl -p warning",
        "$ journalctl -b",
        "$ journalctl -b -1",
        "$ journalctl --list-boots",
        "$ journalctl -k",
        "$ journalctl --disk-usage",
        "$ journalctl --vacuum-size=500M",
        "$ journalctl --vacuum-time=2weeks",
        "$ journalctl _PID=1234",
        "$ journalctl _UID=1000",
        "$ journalctl -o json",
        "$ journalctl -o json-pretty",
        "$ journalctl -o short-iso",
        "$ journalctl --user",
        "$ journalctl -xe",
    ],
    # Grep extended
    "grep": [
        "$ grep pattern file",
        "$ grep -r pattern .",
        "$ grep -rn pattern .",
        "$ grep -ri pattern .",
        "$ grep -rl pattern .",
        "$ grep -rn --include='*.py' pattern .",
        "$ grep -rn --exclude='*.log' pattern .",
        "$ grep -rn --exclude-dir=node_modules pattern .",
        "$ grep -c pattern file",
        "$ grep -v pattern file",
        "$ grep -w pattern file",
        "$ grep -l pattern files",
        "$ grep -L pattern files",
        "$ grep -A 3 pattern file",
        "$ grep -B 3 pattern file",
        "$ grep -C 3 pattern file",
        "$ grep -E 'pattern1|pattern2' file",
        "$ grep -P '\\d+' file",
        "$ grep -o pattern file",
        "$ grep -q pattern file",
        "$ grep -f patterns.txt file",
        "$ grep --color=always pattern file",
    ],
    # Tar extended
    "tar": [
        "$ tar -czf archive.tar.gz dir/",
        "$ tar -cjf archive.tar.bz2 dir/",
        "$ tar -cJf archive.tar.xz dir/",
        "$ tar -cf archive.tar dir/",
        "$ tar -xzf archive.tar.gz",
        "$ tar -xzf archive.tar.gz -C /dest",
        "$ tar -xjf archive.tar.bz2",
        "$ tar -xJf archive.tar.xz",
        "$ tar -xf archive.tar",
        "$ tar -tzf archive.tar.gz",
        "$ tar -tf archive.tar",
        "$ tar -czf archive.tar.gz --exclude='*.log' dir/",
        "$ tar -czf archive.tar.gz -C /parent dir",
        "$ tar -xzf archive.tar.gz file.txt",
        "$ tar --zstd -cf archive.tar.zst dir/",
        "$ tar --zstd -xf archive.tar.zst",
    ],
    # Jq patterns
    "jq": [
        "$ jq '.' file.json",
        "$ jq '.key' file.json",
        "$ jq '.key.nested' file.json",
        "$ jq '.[]' file.json",
        "$ jq '.[0]' file.json",
        "$ jq '.[] | .name' file.json",
        "$ jq 'length' file.json",
        "$ jq 'keys' file.json",
        "$ jq 'select(.key == \"value\")' file.json",
        "$ jq 'map(.key)' file.json",
        "$ jq -r '.key' file.json",
        "$ jq -c '.' file.json",
        "$ jq -s '.' file1.json file2.json",
        "$ jq --arg name value '.key == $name' file.json",
        "$ jq 'to_entries' file.json",
        "$ jq 'from_entries' file.json",
        "$ jq 'group_by(.key)' file.json",
        "$ jq 'sort_by(.key)' file.json",
        "$ jq 'unique_by(.key)' file.json",
        "$ jq '{key: .value}' file.json",
        "$ jq 'if .key then .value else empty end' file.json",
        "$ jq -e '.key' file.json",
        "$ jq --slurp '.' file.json",
        "$ jq -n '{key: \"value\"}'",
    ],
    # Xargs extended
    "xargs": [
        "$ find . -name '*.txt' | xargs grep pattern",
        "$ find . -name '*.txt' -print0 | xargs -0 grep pattern",
        "$ echo 'a b c' | xargs -n 1",
        "$ cat urls.txt | xargs -P 4 -I {} curl {}",
        "$ find . -name '*.log' | xargs rm",
        "$ ls | xargs -I {} mv {} {}.bak",
        "$ seq 10 | xargs -P 4 -I {} sh -c 'echo {}'",
        "$ find . -type f | xargs wc -l",
    ],
    # Common pipe patterns (not command-specific)
    "_pipes": [
        "$ cat file | sort | uniq -c | sort -rn",
        "$ cat file | sort | uniq -c | sort -rn | head -20",
        "$ ps aux | grep process",
        "$ ps aux | grep -v grep | grep process",
        "$ history | grep command",
        "$ ls -la | grep pattern",
        "$ find . -name '*.py' | wc -l",
        "$ find . -type f -name '*.py' | xargs wc -l | tail -1",
        "$ du -sh * | sort -hr",
        "$ du -sh * | sort -hr | head -20",
        "$ cat /etc/passwd | cut -d: -f1",
        "$ cat /etc/passwd | awk -F: '{print $1}'",
        "$ df -h | grep /dev/sd",
        "$ ip addr | grep inet",
        "$ ss -tulpn | grep :80",
        "$ lsblk -o NAME,SIZE,TYPE,MOUNTPOINT",
        "$ journalctl -u nginx --since '1 hour ago' | tail -50",
        "$ dmesg | tail -20",
        "$ dmesg | grep -i error",
        "$ cat access.log | awk '{print $1}' | sort | uniq -c | sort -rn | head -20",
        "$ grep -rn TODO . | wc -l",
        "$ find . -name '*.log' -mtime +30 -delete",
        "$ tar czf - dir/ | ssh user@host 'cat > backup.tar.gz'",
        "$ curl -s url | jq '.'",
        "$ echo 'string' | base64",
        "$ echo 'encoded' | base64 -d",
        "$ echo 'text' | md5sum",
        "$ echo 'text' | sha256sum",
        "$ ls -1 | while read f; do echo $f; done",
        "$ for f in *.txt; do echo $f; done",
        "$ while read line; do echo $line; done < file",
        "$ diff <(ls dir1) <(ls dir2)",
        "$ comm -23 <(sort file1) <(sort file2)",
        "$ paste file1 file2 | column -t",
        "$ column -t -s, file.csv",
        "$ tr '[:lower:]' '[:upper:]' < file",
        "$ tr -d '\\n' < file",
        "$ tr -s ' ' < file",
        "$ rev file",
        "$ tac file",
        "$ nl file",
        "$ fmt -w 80 file",
        "$ fold -w 80 file",
        "$ expand file",
        "$ unexpand file",
        "$ iconv -f iso-8859-1 -t utf-8 file",
    ],
    # Common compound commands and redirections
    "_redirections": [
        "$ command > file",
        "$ command >> file",
        "$ command 2> /dev/null",
        "$ command 2>&1",
        "$ command > file 2>&1",
        "$ command &> file",
        "$ command < file",
        "$ command <<< 'string'",
        "$ command | tee file",
        "$ command | tee -a file",
        "$ command1 && command2",
        "$ command1 || command2",
        "$ command1 ; command2",
        "$ command &",
        "$ nohup command &",
        "$ nohup command > /dev/null 2>&1 &",
        "$ command1 | command2 | command3",
        "$ (command1; command2)",
        "$ { command1; command2; }",
        "$ $(command)",
        "$ `command`",
    ],
    # Shell builtins and control flow
    "_shell": [
        "$ export VAR=value",
        "$ unset VAR",
        "$ echo $VAR",
        "$ echo ${VAR:-default}",
        "$ echo ${VAR:=default}",
        "$ echo ${VAR:+alt}",
        "$ echo ${#VAR}",
        "$ echo ${VAR%%pattern}",
        "$ echo ${VAR##pattern}",
        "$ echo ${VAR/old/new}",
        "$ echo ${VAR//old/new}",
        "$ alias name='command'",
        "$ unalias name",
        "$ source file",
        "$ . file",
        "$ eval 'command'",
        "$ exec command",
        "$ trap 'command' EXIT",
        "$ trap 'command' INT",
        "$ set -e",
        "$ set -x",
        "$ set -u",
        "$ set -o pipefail",
        "$ set -euo pipefail",
        "$ read -p 'prompt: ' var",
        "$ read -r line",
        "$ read -s password",
        "$ test -f file",
        "$ test -d dir",
        "$ test -z string",
        "$ test -n string",
        "$ [ -f file ]",
        "$ [[ -f file ]]",
        "$ [[ string =~ pattern ]]",
        "$ if [ condition ]; then command; fi",
        "$ for i in 1 2 3; do echo $i; done",
        "$ for f in *.txt; do echo $f; done",
        "$ while true; do command; sleep 1; done",
        "$ case $var in pattern) command;; esac",
        "$ select opt in options; do command; done",
        "$ pushd dir",
        "$ popd",
        "$ dirs",
        "$ cd -",
        "$ cd ~",
        "$ pwd",
        "$ type command",
        "$ which command",
        "$ command -v command",
        "$ hash -r",
        "$ ulimit -n",
        "$ ulimit -a",
        "$ umask 022",
        "$ times",
        "$ getopts 'abc:' opt",
        "$ shift",
        "$ shift 2",
        "$ return 0",
        "$ exit 0",
        "$ exit 1",
    ],
}


@dataclass
class Flag:
    short: str | None = None  # e.g. "-v"
    long: str | None = None   # e.g. "--verbose"
    takes_arg: bool = False
    arg_name: str = ""
    description: str = ""


@dataclass
class Subcommand:
    name: str = ""
    description: str = ""
    flags: list[Flag] = field(default_factory=list)


@dataclass
class CommandInfo:
    name: str = ""
    flags: list[Flag] = field(default_factory=list)
    subcommands: list[Subcommand] = field(default_factory=list)


def run_help_raw(argv: list[str]) -> str | None:
    try:
        r = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=3,
            stdin=subprocess.DEVNULL,
            env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                 "HOME": "/tmp", "TERM": "dumb", "LC_ALL": "C"},
        )
        out = r.stdout + r.stderr
        return out if len(out.strip()) >= 20 else None
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError, OSError):
        return None


def looks_like_help(text: str) -> bool:
    """Heuristic: does this look like help output?"""
    lower = text.lower()
    indicators = ["usage:", "options:", "--", "commands:", "synopsis:",
                  "arguments:", "flags:", "description:", "help:"]
    return any(i in lower for i in indicators)


def try_help_variants(cmd: str, args: list[str] | None = None) -> str | None:
    """Try --help, then -h, then help subcommand."""
    argv_base = [cmd] + (args or [])

    # Try --help
    out = run_help_raw(argv_base + ["--help"])
    if out and looks_like_help(out):
        return out

    # Try -h
    out = run_help_raw(argv_base + ["-h"])
    if out and looks_like_help(out):
        return out

    # Try 'help' subcommand (for git, docker, etc.)
    if not args:
        out = run_help_raw(argv_base + ["help"])
        if out and looks_like_help(out):
            return out

    return None


def get_man_text(cmd: str) -> str | None:
    """Try to get man page as plain text (fallback for commands without --help)."""
    try:
        r = subprocess.run(
            ["man", "--no-justification", "--no-hyphenation", cmd],
            capture_output=True,
            text=True,
            timeout=5,
            stdin=subprocess.DEVNULL,
            env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                 "HOME": "/tmp", "TERM": "dumb", "LC_ALL": "C",
                 "MANPAGER": "cat", "PAGER": "cat", "MAN_KEEP_FORMATTING": "0",
                 "COLUMNS": "200"},
        )
        # Strip backspace-based bold/underline from man output
        text = re.sub(r'.\x08', '', r.stdout)
        if len(text.strip()) >= 50:
            return text
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError, OSError):
        pass
    return None


# Regex patterns for parsing flags
FLAG_PATTERN = re.compile(
    r'^\s+'
    r'(?:(-[a-zA-Z0-9]),?\s*)?'       # optional short flag
    r'(--[a-zA-Z0-9][-a-zA-Z0-9_]*)'  # long flag
    r'(?:[=\s][\[<]?([a-zA-Z0-9_.-]+)[\]>]?)?'  # optional argument (no < > in capture)
    r'\s{2,}(.+)',                       # description (after 2+ spaces)
    re.MULTILINE,
)

SHORT_ONLY_PATTERN = re.compile(
    r'^\s+'
    r'(-[a-zA-Z0-9])'                 # short flag only
    r'(?:\s+[\[<]?([a-zA-Z0-9_.-]+)[\]>]?)?'
    r'\s{2,}(.+)',
    re.MULTILINE,
)

# Man page flag pattern: handles .BR/.B formatting artifacts
MAN_FLAG_PATTERN = re.compile(
    r'^\s{2,}'
    r'(?:(-[a-zA-Z0-9]),?\s*)?'
    r'(--[a-zA-Z0-9][-a-zA-Z0-9_]*)'
    r'(?:[=\s][\[<]?([a-zA-Z0-9_.-]+)[\]>]?)?'
    r'(?:\s{2,}(.+))?$',
    re.MULTILINE,
)

SUBCOMMAND_PATTERN = re.compile(
    r'^\s{2,4}([a-z][-a-z0-9_]+)\s{2,}(\S.+)$',
    re.MULTILINE,
)


def clean_arg_name(arg: str) -> str:
    """Strip stray angle brackets / square brackets from captured arg names."""
    return arg.strip("<>[]") if arg else ""


def parse_flags(text: str) -> list[Flag]:
    """Extract flags from help text."""
    flags = []
    seen = set()

    for m in FLAG_PATTERN.finditer(text):
        short, long, arg, desc = m.groups()
        key = long or short
        if key in seen:
            continue
        seen.add(key)
        flags.append(Flag(
            short=short,
            long=long,
            takes_arg=bool(arg),
            arg_name=clean_arg_name(arg),
            description=desc.strip(),
        ))

    for m in SHORT_ONLY_PATTERN.finditer(text):
        short, arg, desc = m.groups()
        if short in seen:
            continue
        seen.add(short)
        # Skip if description starts with a flag-like pattern (misparse)
        if desc.strip().startswith("-"):
            continue
        flags.append(Flag(
            short=short,
            long=None,
            takes_arg=bool(arg),
            arg_name=clean_arg_name(arg),
            description=desc.strip(),
        ))

    return flags


def parse_flags_from_man(text: str) -> list[Flag]:
    """Extract flags from man page text."""
    flags = []
    seen = set()

    for m in MAN_FLAG_PATTERN.finditer(text):
        short, long, arg, desc = m.groups()
        key = long or short
        if key in seen:
            continue
        seen.add(key)
        flags.append(Flag(
            short=short,
            long=long,
            takes_arg=bool(arg),
            arg_name=clean_arg_name(arg),
            description=(desc or "").strip(),
        ))

    for m in SHORT_ONLY_PATTERN.finditer(text):
        short, arg, desc = m.groups()
        if short in seen:
            continue
        seen.add(short)
        if desc.strip().startswith("-"):
            continue
        flags.append(Flag(
            short=short,
            long=None,
            takes_arg=bool(arg),
            arg_name=clean_arg_name(arg),
            description=desc.strip(),
        ))

    return flags


def parse_subcommands(text: str, cmd: str) -> list[str]:
    """Extract subcommand names from help text."""
    subcommands = []
    seen = set()

    in_commands_section = False
    noise_words = {
        "the", "a", "an", "is", "are", "was", "were", "if", "or", "and",
        "to", "for", "in", "on", "at", "by", "see", "use", "run", "set",
        "all", "not", "no", "yes", "can", "may", "will", "has", "have",
        "this", "that", "with", "from", "into", "also", "each", "any",
        "but", "its", "you", "your", "be", "do", "it", "of", "up",
        "http", "https", "example", "note", "warning", "error", "info",
    }

    for line in text.split("\n"):
        stripped = line.strip().lower()

        # Detect command sections
        if re.match(r'^(available\s+)?(commands?|subcommands?|actions?)\s*:', stripped, re.I):
            in_commands_section = True
            continue
        if re.match(r'^(options?|flags?|arguments?|description|usage|synopsis|examples?|environment)\s*:', stripped, re.I):
            in_commands_section = False
            continue

        if not stripped:
            continue

        if in_commands_section:
            m = re.match(r'^\s{2,8}([a-z][-a-z0-9_:]*)\s{2,}', line)
            if m:
                name = m.group(1)
                if name not in seen and name not in noise_words and len(name) > 1:
                    seen.add(name)
                    subcommands.append(name)

    if not subcommands:
        for m in SUBCOMMAND_PATTERN.finditer(text):
            name = m.group(1)
            if name not in seen and name not in noise_words and len(name) > 1:
                seen.add(name)
                subcommands.append(name)

    return subcommands


def parse_command(cmd: str) -> CommandInfo:
    """Parse help output for a command."""
    info = CommandInfo(name=cmd)

    text = try_help_variants(cmd)
    used_man = False

    if not text:
        # Fallback to man page
        text = get_man_text(cmd)
        if text:
            used_man = True
        else:
            return info

    if used_man:
        info.flags = parse_flags_from_man(text)
    else:
        info.flags = parse_flags(text)

    subcmd_names = parse_subcommands(text, cmd)

    # For commands with subcommands, try to get flags for each
    for sc_name in subcmd_names[:50]:
        sc = Subcommand(name=sc_name)

        sc_text = try_help_variants(cmd, [sc_name])
        if sc_text and looks_like_help(sc_text):
            sc.flags = parse_flags(sc_text)

        info.subcommands.append(sc)

    return info


def generate_examples(info: CommandInfo) -> list[str]:
    """Generate training text examples from parsed command info."""
    examples = []
    cmd = info.name

    # Command-level flags
    for f in info.flags:
        if f.long:
            if f.takes_arg:
                examples.append(f"$ {cmd} {f.long}=<{f.arg_name}>")
                examples.append(f"$ {cmd} {f.long} <{f.arg_name}>")
            else:
                examples.append(f"$ {cmd} {f.long}")

        if f.short:
            if f.takes_arg:
                examples.append(f"$ {cmd} {f.short} <{f.arg_name}>")
            else:
                examples.append(f"$ {cmd} {f.short}")

        # Combined short+long as a pair with description
        if f.short and f.long:
            desc_short = f.description[:80] if f.description else ""
            if desc_short:
                examples.append(f"$ {cmd} {f.short}, {f.long}  # {desc_short}")

    # Subcommands bare
    for sc in info.subcommands:
        examples.append(f"$ {cmd} {sc.name}")

        # Subcommand flags
        for f in sc.flags:
            if f.long:
                if f.takes_arg:
                    examples.append(f"$ {cmd} {sc.name} {f.long}=<{f.arg_name}>")
                    examples.append(f"$ {cmd} {sc.name} {f.long} <{f.arg_name}>")
                else:
                    examples.append(f"$ {cmd} {sc.name} {f.long}")

            if f.short:
                if f.takes_arg:
                    examples.append(f"$ {cmd} {sc.name} {f.short} <{f.arg_name}>")
                else:
                    examples.append(f"$ {cmd} {sc.name} {f.short}")

    # Generate common flag combinations (2-flag pairs for boolean flags)
    import itertools
    bool_flags = [f for f in info.flags if not f.takes_arg and (f.short or f.long)]
    short_bools = [f.short for f in bool_flags if f.short][:20]
    if len(short_bools) >= 2:
        # Combined short flags (e.g. "ls -la", "tar -xvf")
        for combo in itertools.combinations(short_bools[:12], 2):
            merged = "-" + combo[0][1:] + combo[1][1:]
            examples.append(f"$ {cmd} {merged}")
        # Also some triples
        for combo in itertools.combinations(short_bools[:10], 3):
            merged = "-" + "".join(c[1:] for c in combo)
            examples.append(f"$ {cmd} {merged}")

    # Long flag pairs for commands with many long flags
    long_bools = [f.long for f in bool_flags if f.long][:15]
    if len(long_bools) >= 2:
        for combo in itertools.combinations(long_bools[:8], 2):
            examples.append(f"$ {cmd} {combo[0]} {combo[1]}")

    # Mix short flag with argument-taking long flag
    arg_flags = [f for f in info.flags if f.takes_arg and f.long][:10]
    short_bools_sample = short_bools[:5]
    for sf in short_bools_sample:
        for af in arg_flags[:3]:
            examples.append(f"$ {cmd} {sf} {af.long}=<{af.arg_name}>")

    # Subcommand + top-level flag combinations
    for sc in info.subcommands[:10]:
        for f in bool_flags[:3]:
            flag = f.short or f.long
            if flag:
                examples.append(f"$ {cmd} {flag} {sc.name}")

    return examples


def main():
    total_examples = 0
    total_commands = 0
    total_flags = 0
    total_subcommands = 0
    skipped = []

    for i, cmd in enumerate(COMMANDS):
        # Check if command exists
        if not shutil.which(cmd):
            # Still emit manual patterns if we have them
            if cmd in MANUAL_PATTERNS:
                manual = MANUAL_PATTERNS[cmd]
                for ex in manual:
                    json.dump({"text": ex}, sys.stdout, ensure_ascii=False)
                    sys.stdout.write("\n")
                total_examples += len(manual)
                total_commands += 1
                print(f"[{i+1}/{len(COMMANDS)}] {cmd}... {len(manual)} manual patterns (not installed)",
                      file=sys.stderr)
                continue
            skipped.append(cmd)
            continue

        print(f"[{i+1}/{len(COMMANDS)}] {cmd}...", file=sys.stderr, end="", flush=True)

        info = parse_command(cmd)

        n_flags = len(info.flags)
        n_subs = len(info.subcommands)
        sc_flags = sum(len(sc.flags) for sc in info.subcommands)

        examples = generate_examples(info)

        # Add manual patterns
        if cmd in MANUAL_PATTERNS:
            examples.extend(MANUAL_PATTERNS[cmd])

        # Deduplicate
        examples = list(dict.fromkeys(examples))

        if not examples:
            print(f" no data", file=sys.stderr)
            skipped.append(cmd)
            continue

        for ex in examples:
            json.dump({"text": ex}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")

        total_examples += len(examples)
        total_commands += 1
        total_flags += n_flags
        total_subcommands += n_subs

        print(f" {n_flags} flags, {n_subs} subcmds ({sc_flags} sub-flags), {len(examples)} examples",
              file=sys.stderr)

    # Emit manual-only pattern sets (not real commands, prefixed with _)
    for key, patterns in MANUAL_PATTERNS.items():
        if key.startswith("_"):
            for ex in patterns:
                json.dump({"text": ex}, sys.stdout, ensure_ascii=False)
                sys.stdout.write("\n")
            total_examples += len(patterns)
            print(f"[extra] {key}: {len(patterns)} patterns", file=sys.stderr)

    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Commands processed: {total_commands}/{len(COMMANDS)}", file=sys.stderr)
    print(f"Total flags: {total_flags}", file=sys.stderr)
    print(f"Total subcommands: {total_subcommands}", file=sys.stderr)
    print(f"Total examples: {total_examples}", file=sys.stderr)
    if skipped:
        print(f"Skipped ({len(skipped)}): {', '.join(skipped[:30])}"
              + ("..." if len(skipped) > 30 else ""), file=sys.stderr)


if __name__ == "__main__":
    main()
