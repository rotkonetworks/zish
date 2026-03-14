#!/usr/bin/env python3
"""Mine Linux man pages (sections 1 and 8) for shell training data.

Parses roff/groff format to extract command names, synopses, and options,
then generates JSONL training pairs for shell command prediction.

Usage:
    python scripts/mine_manpages.py > manpage_training.jsonl
"""

import gzip
import json
import re
import sys
from pathlib import Path


# Intent templates for natural language -> command mappings
INTENT_TEMPLATES = [
    "Translate this intent to a shell command. Reply with ONLY the command on the first line, then explain.\nIntent: {intent}\n$ {cmd}",
    "What command would you run to {intent_lower}?\n$ {cmd}",
    "Shell command for: {intent}\n$ {cmd}",
    "How do I {intent_lower} in the terminal?\n$ {cmd}",
    "{intent}.\n$ {cmd}",
]

# Well-known command intents (command -> list of natural language descriptions)
KNOWN_INTENTS = {
    "ls": ["list files", "show directory contents", "list directory", "show files in current directory"],
    "ls -la": ["list all files with details", "show hidden files", "list files with permissions"],
    "ls -lh": ["list files with human readable sizes", "show file sizes"],
    "ls -lt": ["list files sorted by time", "show newest files first"],
    "ls -R": ["list files recursively", "show all files in subdirectories"],
    "cd": ["change directory", "go to home directory"],
    "pwd": ["print working directory", "show current directory", "where am I"],
    "cat": ["print file contents", "show file", "display file"],
    "head": ["show first lines of file", "print beginning of file"],
    "head -n 20": ["show first 20 lines", "print top 20 lines of file"],
    "tail": ["show last lines of file", "print end of file"],
    "tail -f": ["follow log file", "watch file for changes", "stream log output"],
    "tail -n 50": ["show last 50 lines", "print bottom 50 lines"],
    "grep": ["search for pattern", "find text in files", "search file contents"],
    "grep -r": ["search recursively", "find text in all files", "recursive grep"],
    "grep -i": ["case insensitive search", "search ignoring case"],
    "grep -n": ["search with line numbers", "find text showing line numbers"],
    "grep -c": ["count matches", "count matching lines"],
    "grep -l": ["list files with matches", "which files contain pattern"],
    "grep -v": ["show non-matching lines", "inverse grep", "exclude pattern"],
    "grep -E": ["extended regex search", "egrep pattern"],
    "find": ["find files", "search for files", "locate files"],
    "find . -name": ["find files by name", "search for file by name"],
    "find . -type f": ["find only files", "list all files recursively"],
    "find . -type d": ["find only directories", "list all directories"],
    "find . -mtime -1": ["find files modified today", "find recently modified files"],
    "find . -size +100M": ["find large files", "find files bigger than 100MB"],
    "find . -name '*.log' -delete": ["delete all log files", "remove log files recursively"],
    "cp": ["copy file", "duplicate file"],
    "cp -r": ["copy directory", "copy folder recursively"],
    "cp -a": ["copy preserving attributes", "archive copy"],
    "mv": ["move file", "rename file"],
    "rm": ["remove file", "delete file"],
    "rm -rf": ["force remove directory", "delete directory and contents"],
    "rm -i": ["remove with confirmation", "interactive delete"],
    "mkdir": ["create directory", "make folder", "make directory"],
    "mkdir -p": ["create nested directories", "make parent directories"],
    "rmdir": ["remove empty directory", "delete empty folder"],
    "touch": ["create empty file", "update file timestamp"],
    "chmod": ["change file permissions", "set permissions"],
    "chmod +x": ["make file executable", "add execute permission"],
    "chmod 755": ["set rwxr-xr-x permissions", "standard directory permissions"],
    "chmod 644": ["set rw-r--r-- permissions", "standard file permissions"],
    "chown": ["change file owner", "change ownership"],
    "chown -R": ["change owner recursively", "recursive chown"],
    "ln -s": ["create symbolic link", "make symlink"],
    "tar -czf": ["create compressed archive", "make tarball", "compress directory"],
    "tar -xzf": ["extract compressed archive", "unpack tarball", "decompress archive"],
    "tar -tf": ["list archive contents", "view tarball contents"],
    "tar -xjf": ["extract bzip2 archive", "decompress bz2 tarball"],
    "zip": ["create zip archive", "compress files to zip"],
    "unzip": ["extract zip archive", "decompress zip file"],
    "unzip -l": ["list zip contents", "view zip file contents"],
    "gzip": ["compress file", "gzip a file"],
    "gunzip": ["decompress file", "ungzip a file"],
    "df -h": ["show disk usage", "check disk space", "show free space"],
    "du -sh": ["show directory size", "check folder size"],
    "du -sh *": ["show size of each item", "list sizes in current directory"],
    "free -h": ["show memory usage", "check RAM", "show free memory"],
    "top": ["show running processes", "system monitor", "process viewer"],
    "htop": ["interactive process viewer", "system monitor"],
    "ps aux": ["list all processes", "show running processes"],
    "ps -ef": ["list all processes full format", "show process tree"],
    "kill": ["kill process", "terminate process", "stop process"],
    "kill -9": ["force kill process", "SIGKILL process"],
    "killall": ["kill processes by name", "kill all instances"],
    "pkill": ["kill process by pattern", "signal processes by name"],
    "pgrep": ["find process by name", "search running processes"],
    "whoami": ["show current user", "who am I"],
    "id": ["show user ID and groups", "check user identity"],
    "groups": ["show user groups", "list my groups"],
    "w": ["show who is logged in", "list logged in users"],
    "last": ["show login history", "who logged in recently"],
    "uname -a": ["show system info", "check kernel version", "system information"],
    "uptime": ["show system uptime", "how long has system been running"],
    "date": ["show current date and time", "what time is it", "print date"],
    "cal": ["show calendar", "display calendar"],
    "echo": ["print text", "display message", "output string"],
    "printf": ["formatted print", "print with format string"],
    "wc -l": ["count lines", "how many lines in file"],
    "wc -w": ["count words", "how many words in file"],
    "wc -c": ["count bytes", "file size in bytes"],
    "sort": ["sort lines", "sort file contents"],
    "sort -n": ["sort numerically", "numeric sort"],
    "sort -r": ["sort in reverse", "reverse sort"],
    "sort -u": ["sort unique", "sort and deduplicate"],
    "sort -k2": ["sort by second column", "sort by field"],
    "uniq": ["remove duplicate lines", "show unique lines"],
    "uniq -c": ["count duplicates", "count occurrences of each line"],
    "cut -d' ' -f1": ["extract first field", "cut first column"],
    "cut": ["extract columns", "cut fields from text"],
    "tr": ["translate characters", "replace characters"],
    "tr '[:upper:]' '[:lower:]'": ["convert to lowercase", "lowercase text"],
    "tr -d": ["delete characters", "remove specific characters"],
    "sed": ["stream editor", "find and replace in file"],
    "sed 's/old/new/g'": ["replace text in file", "global find and replace"],
    "sed -i": ["edit file in place", "modify file with sed"],
    "sed -n": ["suppress output", "print only matching lines with sed"],
    "awk": ["text processing", "extract fields", "pattern scanning"],
    "awk '{print $1}'": ["print first column", "extract first field"],
    "awk -F:": ["set field separator", "split on colon"],
    "diff": ["compare files", "show file differences"],
    "diff -u": ["unified diff", "show context diff"],
    "patch": ["apply patch", "apply diff"],
    "wget": ["download file", "fetch URL"],
    "wget -O": ["download to specific file", "save download as"],
    "wget -r": ["download recursively", "mirror website"],
    "curl": ["transfer data from URL", "make HTTP request", "download from URL"],
    "curl -o": ["download and save", "save curl output to file"],
    "curl -s": ["silent curl", "quiet HTTP request"],
    "curl -I": ["show HTTP headers", "head request"],
    "curl -X POST": ["POST request", "send POST with curl"],
    "ssh": ["remote login", "connect to server", "secure shell"],
    "ssh -p": ["SSH on custom port", "connect to non-standard SSH port"],
    "ssh -L": ["SSH port forwarding", "local port forward"],
    "scp": ["copy file to remote", "secure copy", "transfer file over SSH"],
    "rsync -av": ["sync files verbosely", "synchronize directories"],
    "rsync": ["sync files", "synchronize directories", "incremental file transfer"],
    "rsync -avz": ["sync with compression", "compressed rsync"],
    "ping": ["check host connectivity", "test network connection"],
    "ping -c 5": ["ping 5 times", "send 5 ping packets"],
    "traceroute": ["trace network path", "show route to host"],
    "netstat -tlnp": ["show listening ports", "list open TCP ports"],
    "netstat": ["show network connections", "list open ports"],
    "ss -tlnp": ["show listening ports", "list TCP listeners"],
    "ss": ["show socket statistics", "list network connections"],
    "ip addr": ["show IP address", "check network interface", "show network config"],
    "ip route": ["show routing table", "check default gateway"],
    "ip link": ["show network interfaces", "list network devices"],
    "ifconfig": ["show network interfaces", "check IP address"],
    "dig": ["DNS lookup", "query DNS", "resolve domain"],
    "nslookup": ["DNS lookup", "resolve hostname"],
    "host": ["DNS lookup", "resolve domain name"],
    "mount": ["mount filesystem", "attach drive"],
    "umount": ["unmount filesystem", "detach drive"],
    "fdisk -l": ["list disk partitions", "show drives"],
    "lsblk": ["list block devices", "show disks and partitions"],
    "blkid": ["show block device IDs", "list filesystem UUIDs"],
    "systemctl status": ["check service status", "is service running"],
    "systemctl start": ["start service", "start daemon"],
    "systemctl stop": ["stop service", "stop daemon"],
    "systemctl restart": ["restart service", "restart daemon"],
    "systemctl enable": ["enable service at boot", "auto-start service"],
    "systemctl disable": ["disable service at boot", "prevent auto-start"],
    "systemctl list-units": ["list all services", "show running services"],
    "journalctl": ["view system logs", "check systemd logs"],
    "journalctl -f": ["follow system logs", "tail system log"],
    "journalctl -u": ["view service logs", "check specific service log"],
    "journalctl --since today": ["today's logs", "show logs from today"],
    "dmesg": ["show kernel messages", "check boot messages", "kernel log"],
    "dmesg -T": ["kernel log with timestamps", "human readable dmesg"],
    "git status": ["check git status", "show changed files"],
    "git log": ["show git history", "view commits", "git log"],
    "git log --oneline": ["compact git log", "one line per commit"],
    "git log --graph": ["visual git log", "show branch graph"],
    "git diff": ["show changes", "view uncommitted changes"],
    "git diff --staged": ["show staged changes", "view changes to be committed"],
    "git add": ["stage files", "add files to git"],
    "git add -A": ["stage all changes", "add everything to git"],
    "git commit -m": ["commit with message", "save changes to git"],
    "git commit": ["commit changes", "save changes to git"],
    "git push": ["push to remote", "upload commits"],
    "git push -u origin": ["push and set upstream", "first push to remote"],
    "git pull": ["pull from remote", "download changes"],
    "git pull --rebase": ["pull with rebase", "rebase on remote changes"],
    "git clone": ["clone repository", "download git repo"],
    "git branch": ["list branches", "show git branches"],
    "git branch -d": ["delete branch", "remove git branch"],
    "git checkout": ["switch branch", "checkout branch"],
    "git checkout -b": ["create and switch branch", "new branch"],
    "git merge": ["merge branches", "combine branches"],
    "git rebase": ["rebase branch", "replay commits"],
    "git stash": ["stash changes", "save work in progress"],
    "git stash pop": ["restore stashed changes", "apply and drop stash"],
    "git reset --hard HEAD": ["discard all changes", "reset to last commit"],
    "git remote -v": ["show remotes", "list git remote URLs"],
    "git tag": ["list tags", "show git tags"],
    "git cherry-pick": ["cherry-pick commit", "apply specific commit"],
    "git blame": ["show line authorship", "who changed this line"],
    "docker ps": ["list running containers", "show docker containers"],
    "docker ps -a": ["list all containers", "show stopped containers too"],
    "docker images": ["list docker images", "show available images"],
    "docker run": ["run docker container", "start container"],
    "docker run -it": ["run interactive container", "start container with terminal"],
    "docker run -d": ["run container in background", "detached container"],
    "docker build -t": ["build and tag docker image", "create docker image"],
    "docker build": ["build docker image", "create docker image"],
    "docker stop": ["stop docker container", "stop container"],
    "docker rm": ["remove container", "delete docker container"],
    "docker rmi": ["remove image", "delete docker image"],
    "docker logs -f": ["follow container logs", "tail docker output"],
    "docker logs": ["view container logs", "show docker output"],
    "docker exec -it": ["exec into container", "run command in container"],
    "docker-compose up": ["start compose services", "docker compose up"],
    "docker-compose down": ["stop compose services", "docker compose down"],
    "apt update": ["update package list", "refresh package index"],
    "apt upgrade": ["upgrade packages", "update all packages"],
    "apt install": ["install package", "install software"],
    "apt remove": ["uninstall package", "remove software"],
    "apt search": ["search for package", "find package"],
    "apt list --installed": ["list installed packages", "show installed software"],
    "dpkg -l": ["list installed packages", "show all installed debs"],
    "pacman -S": ["install package", "install software with pacman"],
    "pacman -Syu": ["update system", "upgrade all packages"],
    "pacman -Ss": ["search for package", "find package"],
    "pacman -R": ["remove package", "uninstall with pacman"],
    "pacman -Q": ["list installed packages", "query installed packages"],
    "pip install": ["install Python package", "install pip package"],
    "pip install -r requirements.txt": ["install from requirements", "install Python dependencies"],
    "pip list": ["list installed pip packages", "show Python packages"],
    "pip freeze": ["freeze pip packages", "export Python dependencies"],
    "npm install": ["install Node package", "install npm package"],
    "npm run": ["run npm script", "execute package script"],
    "npm init": ["initialize npm project", "create package.json"],
    "make": ["build project", "compile with make", "run makefile"],
    "make clean": ["clean build", "remove build artifacts"],
    "make install": ["install built software", "make install"],
    "gcc -o": ["compile C program", "build C code with output name"],
    "gcc": ["compile C program", "build C code"],
    "python3": ["run Python 3 script", "start Python 3"],
    "python": ["run Python script", "start Python"],
    "node": ["run JavaScript", "start Node.js"],
    "man": ["read manual", "show help for command", "view man page"],
    "which": ["find command location", "where is command"],
    "whereis": ["locate binary and man page", "find command files"],
    "type": ["show command type", "what type of command"],
    "alias": ["show aliases", "list command aliases"],
    "history": ["show command history", "list previous commands"],
    "history | grep": ["search command history", "find previous command"],
    "env": ["show environment variables", "list env vars"],
    "export": ["set environment variable", "export variable"],
    "xargs": ["build commands from input", "pipe to arguments"],
    "tee": ["pipe and save to file", "output to file and stdout"],
    "nohup": ["run command immune to hangup", "keep running after logout"],
    "screen": ["terminal multiplexer", "create persistent terminal"],
    "tmux": ["terminal multiplexer", "split terminal", "create terminal session"],
    "tmux new -s": ["create named session", "new tmux session with name"],
    "tmux attach": ["attach to session", "reattach tmux"],
    "tmux ls": ["list sessions", "show tmux sessions"],
    "crontab -l": ["list cron jobs", "show scheduled tasks"],
    "crontab -e": ["edit cron jobs", "schedule tasks"],
    "at": ["schedule one-time task", "run command later"],
    "lsof": ["list open files", "show what files are open"],
    "lsof -i": ["list network files", "show network connections"],
    "strace": ["trace system calls", "debug process"],
    "ltrace": ["trace library calls", "debug shared library calls"],
    "file": ["determine file type", "what type of file"],
    "stat": ["show file details", "file statistics"],
    "md5sum": ["calculate MD5 hash", "checksum file"],
    "sha256sum": ["calculate SHA256 hash", "verify file integrity"],
    "base64": ["encode/decode base64", "base64 encode"],
    "xxd": ["hex dump", "view file in hex"],
    "strings": ["extract text from binary", "show strings in binary file"],
    "nm": ["list symbols", "show symbol table"],
    "readelf": ["read ELF file", "show ELF headers"],
    "objdump -d": ["disassemble binary", "show assembly"],
    "watch": ["run command periodically", "repeat command every N seconds"],
    "watch -n 1": ["run command every second", "watch with 1 second interval"],
    "yes": ["repeat string", "output yes repeatedly"],
    "seq": ["generate number sequence", "print numbers"],
    "shuf": ["shuffle lines", "randomize order"],
    "paste": ["merge lines", "join files side by side"],
    "column -t": ["format as table", "align columns"],
    "jq": ["parse JSON", "query JSON", "format JSON"],
    "jq '.'": ["pretty print JSON", "format JSON output"],
    "less": ["view file with pager", "scroll through file"],
    "more": ["view file page by page", "simple pager"],
    "bc": ["calculator", "command line calculator"],
    "expr": ["evaluate expression", "arithmetic in shell"],
    "basename": ["get filename from path", "strip directory from path"],
    "dirname": ["get directory from path", "strip filename from path"],
    "realpath": ["resolve path", "get absolute path"],
    "readlink -f": ["resolve symlink", "get real path"],
    "tput": ["terminal control", "set terminal attributes"],
    "reset": ["reset terminal", "fix garbled terminal"],
    "clear": ["clear screen", "clear terminal"],
    "time": ["measure execution time", "time a command"],
    "timeout 30": ["run with timeout", "kill after 30 seconds"],
    "nice -n 10": ["run with low priority", "nice a process"],
    "renice": ["change process priority", "adjust niceness"],
    "nproc": ["show CPU count", "how many CPUs"],
    "lscpu": ["show CPU info", "CPU information"],
    "lsmod": ["list kernel modules", "show loaded modules"],
    "lspci": ["list PCI devices", "show hardware"],
    "lsusb": ["list USB devices", "show USB hardware"],
    "hdparm": ["disk parameters", "check disk speed"],
    "iotop": ["IO monitor", "show disk IO by process"],
    "iostat": ["IO statistics", "disk IO stats"],
    "vmstat": ["virtual memory stats", "system performance"],
    "sar": ["system activity report", "historical performance data"],
    "nc": ["netcat", "network Swiss army knife"],
    "nmap": ["network scanner", "port scan", "scan network"],
    "tcpdump": ["packet capture", "network sniffer", "capture traffic"],
    "iptables -L": ["list firewall rules", "show iptables rules"],
    "useradd": ["create user", "add new user"],
    "userdel": ["delete user", "remove user account"],
    "usermod": ["modify user", "change user settings"],
    "passwd": ["change password", "set user password"],
    "su": ["switch user", "become another user"],
    "sudo": ["run as root", "execute as superuser"],
    "visudo": ["edit sudoers", "configure sudo"],
    "cmp": ["compare files byte by byte", "binary file comparison"],
    "comm": ["compare sorted files", "find common lines"],
    "join": ["join files on common field", "relational join"],
    "split": ["split file", "split file into pieces"],
    "csplit": ["context split", "split file by pattern"],
    "iconv": ["convert encoding", "change character encoding"],
    "hexdump": ["hex dump file", "show file in hexadecimal"],
    "od": ["octal dump", "dump file in various formats"],
    "sync": ["flush filesystem", "sync disk buffers"],
    "dd": ["disk dump", "copy and convert data", "create disk image"],
    "mkfs": ["create filesystem", "format disk"],
    "fsck": ["filesystem check", "repair filesystem"],
    "parted": ["partition editor", "manage disk partitions"],
    "wipefs": ["wipe filesystem signatures", "clean disk signatures"],
}

# Common pipe patterns for well-known commands
PIPE_PATTERNS = {
    "ls": [
        "ls -la | grep pattern",
        "ls -1 | wc -l",
        "ls -lt | head -10",
        "ls -la | awk '{print $5, $9}'",
        "ls -R | grep '.py$'",
    ],
    "cat": [
        "cat file | grep pattern",
        "cat file | wc -l",
        "cat file | sort | uniq",
        "cat file | head -20",
        "cat file | tail -5",
    ],
    "grep": [
        "grep -r pattern . | head -20",
        "grep -c pattern file",
        "grep pattern file | cut -d: -f1",
        "grep -l pattern *.txt",
    ],
    "find": [
        "find . -name '*.py' | xargs grep pattern",
        "find . -type f -name '*.log' | xargs rm",
        "find . -type f | wc -l",
        "find . -size +100M -exec ls -lh {} \\;",
        "find . -mtime -7 -type f",
    ],
    "ps": [
        "ps aux | grep process",
        "ps aux | sort -k3 -r | head",
        "ps aux | awk '{print $1, $11}'",
        "ps -ef | grep -v grep | grep name",
    ],
    "sort": [
        "sort file | uniq -c | sort -rn",
        "sort -t, -k2 -n file",
    ],
    "cut": [
        "cut -d: -f1 /etc/passwd",
        "cut -d' ' -f1,3 file",
    ],
    "history": [
        "history | grep command",
        "history | tail -20",
        "history | awk '{print $2}' | sort | uniq -c | sort -rn | head",
    ],
    "du": [
        "du -sh * | sort -rh | head",
        "du -sh */ | sort -rh",
    ],
    "curl": [
        "curl -s url | jq '.'",
        "curl -s url | grep pattern",
        "curl -sI url | head",
    ],
    "docker": [
        "docker ps -q | xargs docker stop",
        "docker images -q | xargs docker rmi",
        "docker logs container 2>&1 | tail -50",
    ],
    "git": [
        "git log --oneline | head -20",
        "git branch -a | grep feature",
        "git diff --name-only",
        "git log --format='%H %s' | head",
        "git stash list",
    ],
    "awk": [
        "awk '{print $NF}' file",
        "awk -F: '{print $1}' /etc/passwd",
        "awk '{sum+=$1} END {print sum}' file",
    ],
    "sed": [
        "sed -n '10,20p' file",
        "sed 's/old/new/g' file",
        "sed '/pattern/d' file",
        "sed -i 's/foo/bar/g' *.txt",
    ],
    "tar": [
        "tar -czf archive.tar.gz directory/",
        "tar -xzf archive.tar.gz",
        "tar -tf archive.tar.gz | head",
        "tar -czf - directory/ | ssh host 'cat > backup.tar.gz'",
    ],
    "systemctl": [
        "systemctl list-units --type=service --state=running",
        "systemctl is-active service",
        "systemctl --failed",
    ],
    "journalctl": [
        "journalctl -u service --since '1 hour ago'",
        "journalctl -p err -b",
        "journalctl --disk-usage",
    ],
    "ip": [
        "ip addr show",
        "ip route show",
        "ip link show",
        "ip -s link",
        "ip neigh show",
    ],
    "ss": [
        "ss -tlnp",
        "ss -ulnp",
        "ss -s",
    ],
    "xargs": [
        "echo 'a b c' | xargs -n1",
        "find . -name '*.bak' | xargs rm",
        "cat urls.txt | xargs -P4 -I{} curl -sO {}",
    ],
    "wc": [
        "wc -l *.py",
        "find . -name '*.py' | xargs wc -l | tail -1",
    ],
    "chmod": [
        "chmod +x script.sh",
        "chmod -R 755 directory/",
        "find . -type f -name '*.sh' | xargs chmod +x",
    ],
}

# Redirect patterns
REDIRECT_PATTERNS = [
    "{cmd} > output.txt",
    "{cmd} >> output.txt",
    "{cmd} 2>&1",
    "{cmd} 2>/dev/null",
    "{cmd} > /dev/null 2>&1",
    "{cmd} | tee output.txt",
    "{cmd} 2>&1 | tee log.txt",
]


def log(msg):
    """Print progress to stderr."""
    print(msg, file=sys.stderr)


def read_manpage(path):
    """Read a man page, handling .gz compression and encoding errors."""
    try:
        if str(path).endswith(".gz"):
            with gzip.open(path, "rt", encoding="utf-8", errors="replace") as f:
                return f.read()
        else:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
    except Exception:
        return None


def strip_roff(text):
    """Strip roff/groff formatting to get plain text."""
    # Remove font changes: \fB, \fI, \fR, \fP, etc
    text = re.sub(r"\\f[BIPRCS\[][\w]*\]?", "", text)
    # Remove \, escapes for special chars
    text = re.sub(r"\\\,", "", text)
    text = re.sub(r"\/\\f", "", text)
    # Remove \(xx character escapes
    text = re.sub(r"\\\([a-zA-Z]{2}", "", text)
    # Remove \*[xx] string interpolation
    text = re.sub(r"\\\*\[[^\]]*\]", "", text)
    text = re.sub(r"\\\*\(?..", "", text)
    # Remove docbook &. escapes
    text = re.sub(r"\\&\.", ".", text)
    text = re.sub(r"\\&", "", text)
    # Remove \m[...] color escapes
    text = re.sub(r"\\m\[[^\]]*\]", "", text)
    # Remove \s+N \s-N size changes
    text = re.sub(r"\\s[+-]?\d+", "", text)
    # Remove \u \d super/subscript
    text = re.sub(r"\\[ud]", "", text)
    # Remove \X'...' device control
    text = re.sub(r"\\X'[^']*'", "", text)
    # Remove \n register references
    text = re.sub(r"\\n\([a-zA-Z.]{2}", "", text)
    text = re.sub(r"\\n\[[^\]]*\]", "", text)
    # Remove remaining backslash escapes
    text = re.sub(r"\\-", "-", text)
    text = re.sub(r"\\~", " ", text)
    text = re.sub(r"\\e", r"\\", text)
    text = re.sub(r"\\`", "`", text)
    text = re.sub(r"\\'", "'", text)
    text = re.sub(r'\\".*', "", text)  # comments
    # Clean up
    text = re.sub(r"  +", " ", text)
    return text.strip()


def is_clean_example(text):
    """Check if a training example is clean (no roff artifacts)."""
    if not text:
        return False
    # Must start with $ or be an intent template
    first_line = text.split("\n")[0]
    if not (first_line.startswith("$") or
            first_line.startswith("Translate") or
            first_line.startswith("What command") or
            first_line.startswith("Shell command") or
            first_line.startswith("How do I") or
            any(first_line.endswith(c) for c in [".", "?"])):
        return False
    # Check for roff artifacts anywhere in text
    if re.search(r"\\f[BIPRCS(0-9]", text):
        return False
    if "\\f" in text:
        return False
    if ".\\|." in text or "\\|" in text:
        return False
    if re.search(r"\.[A-Z]{2}\s", text):  # .TP, .PP, .IP etc
        return False
    if "\\(" in text and not text.startswith("$ find"):  # \( is valid in find
        return False
    if "\\m[" in text or "\\s-" in text or "\\s+" in text:
        return False
    # Check that $ lines look like actual commands
    for line in text.split("\n"):
        if line.startswith("$ "):
            cmd_part = line[2:].strip()
            if not cmd_part:
                return False
            # Should start with a valid command character
            if not re.match(r"^[a-zA-Z0-9/~._]", cmd_part):
                return False
            # No lines that are just roff garbage
            if len(cmd_part) < 2:
                return False
            # No lines that are obviously not commands
            if cmd_part.endswith(":"):
                return False
    return True


def extract_sections(content):
    """Extract named sections from roff source."""
    sections = {}
    current_section = None
    current_lines = []

    for line in content.split("\n"):
        stripped = line.strip()
        # Match .SH "SECTION" or .SH SECTION
        m = re.match(r'^\.SH\s+"?([^"]*)"?\s*$', stripped)
        if m:
            if current_section is not None:
                sections[current_section] = "\n".join(current_lines)
            current_section = m.group(1).strip().upper()
            current_lines = []
            continue
        if current_section is not None:
            current_lines.append(line)

    if current_section is not None:
        sections[current_section] = "\n".join(current_lines)

    return sections


def parse_name(sections):
    """Extract command name and description from NAME section."""
    name_text = sections.get("NAME", "")
    if not name_text:
        return None, None

    name_text = strip_roff(name_text)
    m = re.match(r"^\s*(\S+)\s+(?:\\?-+\s+)?(.+)", name_text.strip())
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return None, None


def parse_synopsis(sections):
    """Extract synopsis patterns from SYNOPSIS section."""
    syn_text = sections.get("SYNOPSIS", "")
    if not syn_text:
        return []

    results = []
    for line in syn_text.split("\n"):
        stripped = line.strip()
        if stripped in (".nf", ".fi"):
            continue
        if stripped.startswith(".") and not stripped.startswith(".."):
            if stripped.startswith((".B ", ".BI ", ".BR ")):
                clean = strip_roff(stripped[3:])
                if clean:
                    results.append(clean)
            continue
        if stripped:
            clean = strip_roff(stripped)
            if clean and len(clean) > 1:
                results.append(clean)

    return results


def parse_options(sections):
    """Extract flags and their descriptions from OPTIONS/DESCRIPTION section."""
    options = []

    for section_name in ["OPTIONS", "DESCRIPTION", "COMMANDS",
                         "COMMAND OPTIONS", "COMMON OPTIONS",
                         "GLOBAL OPTIONS", "PRIMARY OPTIONS"]:
        opt_text = sections.get(section_name, "")
        if not opt_text:
            continue

        lines = opt_text.split("\n")
        current_flag = None
        current_desc_lines = []

        for line in lines:
            stripped = line.strip()

            if stripped == ".TP":
                if current_flag:
                    desc = " ".join(current_desc_lines).strip()
                    desc = strip_roff(desc)
                    if desc:
                        options.append((current_flag, desc))
                current_flag = None
                current_desc_lines = []
                continue

            if current_flag is None and not stripped.startswith(".") and stripped:
                candidate = strip_roff(stripped)
                if candidate and (candidate.startswith("-") or candidate.startswith("+")):
                    current_flag = candidate
                    continue

            if stripped.startswith((".PP", ".IP", ".RE", ".RS")):
                if current_flag:
                    desc = " ".join(current_desc_lines).strip()
                    desc = strip_roff(desc)
                    if desc:
                        options.append((current_flag, desc))
                    current_flag = None
                    current_desc_lines = []

                m = re.match(r'\.IP\s+"([^"]+)"', stripped)
                if m:
                    candidate = strip_roff(m.group(1))
                    if candidate.startswith("-"):
                        current_flag = candidate
                continue

            if current_flag is not None:
                if stripped.startswith(".") and not stripped.startswith(".."):
                    if stripped.startswith((".B ", ".I ", ".BI ", ".IR ", ".BR ")):
                        current_desc_lines.append(strip_roff(stripped[3:]))
                    continue
                if stripped:
                    current_desc_lines.append(stripped)

        if current_flag:
            desc = " ".join(current_desc_lines).strip()
            desc = strip_roff(desc)
            if desc:
                options.append((current_flag, desc))

    return options


def extract_flags_from_option(opt_text):
    """Extract individual flags from an option string like '-a, --all'."""
    flags = []
    parts = re.split(r",\s*|\s+", opt_text)
    for p in parts:
        p = p.strip()
        if p.startswith("-"):
            flag = re.split(r"[=\[<\s{]", p)[0]
            flag = flag.rstrip(",")
            if flag and len(flag) >= 2 and len(flag) <= 30:
                flags.append(flag)
    return flags


def extract_subcommands(sections):
    """Try to extract subcommands from COMMANDS or DESCRIPTION sections."""
    subcommands = []

    for section_name in ["COMMANDS", "DESCRIPTION", "GIT COMMANDS",
                         "SUBCOMMANDS", "MODES", "ACTIONS"]:
        text = sections.get(section_name, "")
        if not text:
            continue

        lines = text.split("\n")
        after_tp = False
        for line in lines:
            stripped = line.strip()
            if stripped == ".TP":
                after_tp = True
                continue
            if after_tp and not stripped.startswith(".") and stripped:
                candidate = strip_roff(stripped)
                if (candidate and not candidate.startswith("-")
                        and re.match(r"^[a-z][a-z0-9_-]*$", candidate)
                        and len(candidate) <= 30):
                    subcommands.append(candidate)
                after_tp = False

    return subcommands


def extract_examples_section(sections):
    """Extract example commands from EXAMPLES section."""
    examples_text = sections.get("EXAMPLES", "")
    if not examples_text:
        examples_text = sections.get("EXAMPLE", "")
    if not examples_text:
        return []

    results = []
    in_nf = False
    for line in examples_text.split("\n"):
        stripped = line.strip()
        if stripped == ".nf":
            in_nf = True
            continue
        if stripped == ".fi":
            in_nf = False
            continue
        if stripped.startswith(".") and not stripped.startswith(".."):
            continue
        if stripped:
            clean = strip_roff(stripped)
            # Look for lines that look like shell commands
            if clean and re.match(r"^[a-zA-Z/$~]", clean) and len(clean) < 200:
                # Skip prose sentences (they usually have many words)
                words = clean.split()
                if len(words) <= 15:  # Commands are usually short
                    results.append(clean)

    return results


def generate_examples(cmd_name, description, synopsis_lines, options,
                      subcommands, section, example_cmds):
    """Generate training examples for a single command."""
    examples = []

    def emit(text):
        if is_clean_example(text):
            examples.append({"text": text})

    # 1. Bare command
    emit(f"$ {cmd_name}")

    # 2. Command with --help and -h
    emit(f"$ {cmd_name} --help")
    emit(f"$ {cmd_name} -h")

    # 3. Man page lookup
    emit(f"$ man {cmd_name}")

    # 4. Each flag individually
    seen_flags = set()
    for opt_text, desc in options:
        flags = extract_flags_from_option(opt_text)
        for flag in flags:
            if flag in seen_flags:
                continue
            seen_flags.add(flag)
            emit(f"$ {cmd_name} {flag}")

    # 5. Common flag combinations (2-flag and 3-flag combos)
    flag_list = sorted(seen_flags)
    short_flags = [f for f in flag_list if len(f) == 2 and f.startswith("-") and not f.startswith("--")]
    if len(short_flags) >= 2:
        # 2-flag combos
        combos = []
        for i in range(min(len(short_flags), 12)):
            for j in range(i + 1, min(len(short_flags), 12)):
                combos.append(f"-{short_flags[i][1]}{short_flags[j][1]}")
        for combo in combos[:20]:
            emit(f"$ {cmd_name} {combo}")

        # 3-flag combos
        if len(short_flags) >= 3:
            combos3 = []
            for i in range(min(len(short_flags), 8)):
                for j in range(i + 1, min(len(short_flags), 8)):
                    for k in range(j + 1, min(len(short_flags), 8)):
                        combos3.append(f"-{short_flags[i][1]}{short_flags[j][1]}{short_flags[k][1]}")
            for combo in combos3[:20]:
                emit(f"$ {cmd_name} {combo}")

    # 6. Synopsis patterns
    for syn in synopsis_lines[:8]:
        clean = syn.strip()
        if clean and clean != cmd_name and len(clean) < 200:
            emit(f"$ {clean}")

    # 7. Subcommands
    for sub in subcommands[:30]:
        emit(f"$ {cmd_name} {sub}")
        emit(f"$ {cmd_name} {sub} --help")

    # 8. Natural language intent pairs from NAME description
    if description and len(description) > 3:
        desc_clean = description.rstrip(".")
        for tmpl in INTENT_TEMPLATES:
            emit(tmpl.format(
                intent=desc_clean,
                intent_lower=desc_clean[0].lower() + desc_clean[1:] if desc_clean else desc_clean,
                cmd=cmd_name,
            ))

    # 9. Known intents for common commands
    for cmd_pattern, intents in KNOWN_INTENTS.items():
        base = cmd_pattern.split()[0]
        if base == cmd_name:
            for intent in intents:
                for tmpl in INTENT_TEMPLATES:
                    emit(tmpl.format(
                        intent=intent,
                        intent_lower=intent,
                        cmd=cmd_pattern,
                    ))

    # 10. Flag + description intent pairs (ALL flags, not just top 20)
    for opt_text, desc in options:
        flags = extract_flags_from_option(opt_text)
        if not flags or not desc or len(desc) < 5:
            continue
        flag = flags[0]
        short_desc = desc[:120].rstrip(".")
        if short_desc and len(short_desc) > 5:
            # Full intent template
            emit(INTENT_TEMPLATES[0].format(
                intent=f"{short_desc} ({cmd_name})",
                intent_lower=short_desc[0].lower() + short_desc[1:],
                cmd=f"{cmd_name} {flag}",
            ))
            # Short template
            emit(INTENT_TEMPLATES[2].format(
                intent=f"{short_desc}",
                intent_lower=short_desc[0].lower() + short_desc[1:],
                cmd=f"{cmd_name} {flag}",
            ))

    # 11. Section 8 commands often need sudo
    if section == "8":
        emit(f"$ sudo {cmd_name}")
        for flag in list(seen_flags)[:15]:
            emit(f"$ sudo {cmd_name} {flag}")
        for sub in subcommands[:10]:
            emit(f"$ sudo {cmd_name} {sub}")

    # 12. Pipe patterns
    base_name = cmd_name.split("-")[0] if "-" in cmd_name else cmd_name
    if base_name in PIPE_PATTERNS:
        for pattern in PIPE_PATTERNS[base_name]:
            emit(f"$ {pattern}")

    # 13. Redirect patterns for common commands
    if cmd_name in REDIRECT_PATTERNS or len(options) > 3:
        for pattern in REDIRECT_PATTERNS[:4]:
            emit(f"$ {pattern.format(cmd=cmd_name)}")

    # 14. Examples from EXAMPLES section
    for ex_cmd in example_cmds[:15]:
        emit(f"$ {ex_cmd}")

    # 15. Command with common argument placeholders
    if description:
        desc_lower = description.lower()
        if any(w in desc_lower for w in ["file", "copy", "move", "remove", "read", "write", "edit"]):
            emit(f"$ {cmd_name} file.txt")
            emit(f"$ {cmd_name} *.txt")
        if any(w in desc_lower for w in ["directory", "folder", "dir"]):
            emit(f"$ {cmd_name} /path/to/dir")
            emit(f"$ {cmd_name} .")
        if any(w in desc_lower for w in ["search", "find", "pattern", "grep", "match"]):
            emit(f"$ {cmd_name} pattern")
            emit(f"$ {cmd_name} 'pattern' file.txt")
        if any(w in desc_lower for w in ["process", "pid", "kill", "signal"]):
            emit(f"$ {cmd_name} 1234")
        if any(w in desc_lower for w in ["network", "host", "connect", "remote", "server"]):
            emit(f"$ {cmd_name} hostname")
            emit(f"$ {cmd_name} 192.168.1.1")
        if any(w in desc_lower for w in ["url", "http", "download", "fetch", "web"]):
            emit(f"$ {cmd_name} https://example.com")
        if any(w in desc_lower for w in ["user", "account", "login"]):
            emit(f"$ {cmd_name} username")
        if any(w in desc_lower for w in ["package", "install"]):
            emit(f"$ {cmd_name} package-name")

    # 16. Whatis-style entries
    if description and len(description) > 3:
        emit(f"$ whatis {cmd_name}")

    # 17. Flag pairs (long flag with common args)
    long_flags = [f for f in flag_list if f.startswith("--") and len(f) <= 20]
    for lf in long_flags[:15]:
        for other in ["--verbose", "--force", "--recursive", "--dry-run",
                      "--quiet", "--help", "--version", "--debug", "--all"]:
            if other in seen_flags and other != lf:
                emit(f"$ {cmd_name} {lf} {other}")

    # 18. Short + long flag combinations
    for sf in short_flags[:8]:
        for lf in long_flags[:8]:
            emit(f"$ {cmd_name} {sf} {lf}")

    # 19. Type/which/command -v lookups
    emit(f"$ type {cmd_name}")
    emit(f"$ which {cmd_name}")
    emit(f"$ command -v {cmd_name}")

    # 20. Version check patterns
    emit(f"$ {cmd_name} --version")
    emit(f"$ {cmd_name} -V")
    emit(f"$ {cmd_name} -v")

    # 21. Abbreviation/alias training - first 1-3 chars as prefix
    if len(cmd_name) > 4:
        emit(f"$ {cmd_name}")  # full name reinforcement

    # 22. All intent templates for all flag descriptions (expanded)
    for opt_text, desc in options:
        flags = extract_flags_from_option(opt_text)
        if not flags or not desc or len(desc) < 8:
            continue
        flag = flags[0]
        short_desc = desc[:120].rstrip(".")
        if short_desc and len(short_desc) > 8:
            # Additional templates beyond what we did in step 10
            emit(INTENT_TEMPLATES[1].format(
                intent=f"{short_desc}",
                intent_lower=short_desc[0].lower() + short_desc[1:],
                cmd=f"{cmd_name} {flag}",
            ))
            emit(INTENT_TEMPLATES[3].format(
                intent=f"{short_desc}",
                intent_lower=short_desc[0].lower() + short_desc[1:],
                cmd=f"{cmd_name} {flag}",
            ))

    # 23. Subcommand + flag combinations
    for sub in subcommands[:10]:
        for flag in list(seen_flags)[:5]:
            emit(f"$ {cmd_name} {sub} {flag}")

    # 24. Environment variable patterns
    if any(f in seen_flags for f in ["--verbose", "-v"]):
        emit(f"$ VERBOSE=1 {cmd_name}")
    if any(f in seen_flags for f in ["--debug", "-d"]):
        emit(f"$ DEBUG=1 {cmd_name}")

    # 25. Backgrounding and job control
    emit(f"$ {cmd_name} &")
    emit(f"$ nohup {cmd_name} &")

    # 26. Command substitution patterns
    if description:
        desc_lower = description.lower()
        if any(w in desc_lower for w in ["print", "show", "display", "list", "output", "get"]):
            emit(f"$ echo $({cmd_name})")
            emit(f"$ result=$({cmd_name})")

    # 27. Conditional execution
    emit(f"$ {cmd_name} && echo done")
    emit(f"$ {cmd_name} || echo failed")

    return examples


def find_manpages():
    """Find all man1 and man8 pages."""
    pages = []

    search_dirs = [
        Path("/usr/share/man"),
        Path("/usr/local/share/man"),
        Path("/usr/local/man"),
    ]

    for base in search_dirs:
        for section_dir in ["man1", "man8"]:
            section_path = base / section_dir
            if not section_path.exists():
                continue
            try:
                for entry in sorted(section_path.iterdir()):
                    if entry.is_file() and (entry.name.endswith(".gz") or
                                            re.match(r"\.\d$", entry.suffix)):
                        pages.append((entry, section_dir[-1]))
            except PermissionError:
                continue

    return pages


def extract_cmd_name_from_filename(path):
    """Extract command name from man page filename."""
    name = path.name
    if name.endswith(".gz"):
        name = name[:-3]
    name = re.sub(r"\.\d[a-z]*$", "", name)
    return name


def main():
    pages = find_manpages()
    log(f"Found {len(pages)} man pages to process")

    total_examples = 0
    processed = 0
    skipped = 0
    seen_commands = set()

    for i, (path, section) in enumerate(pages):
        if (i + 1) % 500 == 0:
            log(f"  [{i+1}/{len(pages)}] processed={processed} skipped={skipped} examples={total_examples}")

        cmd_name = extract_cmd_name_from_filename(path)

        # Skip duplicates
        if cmd_name in seen_commands:
            continue
        seen_commands.add(cmd_name)

        # Skip weird/internal pages
        if not cmd_name or len(cmd_name) > 50:
            skipped += 1
            continue
        if not re.match(r"^[a-zA-Z0-9]", cmd_name):
            skipped += 1
            continue

        content = read_manpage(path)
        if not content or len(content) < 50:
            skipped += 1
            continue

        try:
            sections = extract_sections(content)
        except Exception:
            skipped += 1
            continue

        if not sections:
            skipped += 1
            continue

        name_parsed, description = parse_name(sections)
        if not name_parsed:
            name_parsed = cmd_name

        synopsis_lines = parse_synopsis(sections)
        options = parse_options(sections)
        subcommands = extract_subcommands(sections)
        example_cmds = extract_examples_section(sections)

        examples = generate_examples(
            cmd_name, description or "", synopsis_lines, options,
            subcommands, section, example_cmds
        )

        for ex in examples:
            print(json.dumps(ex, ensure_ascii=False))

        total_examples += len(examples)
        processed += 1

    log(f"Done. Processed {processed} commands, skipped {skipped}, generated {total_examples} examples")


if __name__ == "__main__":
    main()
