# changelog

## v0.25.3

### added
- `.deb` for Debian, Ubuntu and Proxmox (amd64, arm64), built and install-tested
  in CI and attached to each release.
- `jevx` feat: typed decisions from a model, one line each.
- `gf` runs a jev screen before the agent review on install.

### changed
- Release binaries are static musl, so they run on any Linux distro.
- Feats are tiered: `core` (ships with the shell), `tooling`, `all`. Select with
  `-Dfeats=`.
- `pen` and `aur` moved to the rotko-feats repo and install through `gf`.
- README rewritten to be shorter.

## v0.25.2

### fixed
- Words after a redirection (`echo a 2>/dev/null b`) and redirect-only commands
  (`>file`) were parse errors.
- `printf -- fmt` strips the `--`.
- `echo $x` field-splits and globs the unquoted expansion.
- `$$` is the shell's pid, fixed at startup, so it is the same in subshells and
  command substitution.

## v0.25.0

### added
- `# zish-deps: web calc` in a script's header names the feats it needs. If one
  is missing, zish refuses to run the script (status 127) and says which.
  `feat deps <file>` checks statically, and `feat need <name>` checks at runtime.

### fixed
- `$(( ))` evaluated `${x:-0}`, `${x}${x}`, `$(cmd)` and backticks to 0 without
  an error. The expression text is now expanded first, then evaluated, as in
  bash, so `x="1+2"; $(( $x * 2 ))` is 5.
- Arithmetic errors were silent. They now print bash's message, and they're
  fatal in a non-interactive shell, as in bash.
- `a=b; b=a; $(( a ))` segfaulted. It now stops at depth 1024 with bash's
  "expression recursion level exceeded".
- A literal wider than 64 bits panicked. It now wraps, as in bash.
- An array subscript is an arithmetic expression: `${a[i+1]}`,
  `${a[${#a[@]}-1]}` and `${a[-1]}` work.
- `x=$((1+2))$((3+4))` assigned 3 instead of 37.

## v0.24.0

### added
- A file without a shebang runs as a script (POSIX ENOEXEC behaviour).
- `set -f` / `set -o noglob`, and `$-`.
- Binary files are refused with 126 instead of being parsed.

### fixed
- Seven feats leaked their argv, and `cnt` leaked the file it counted.

### changed
- `build.zig` is the only place that compiles feats. The Makefile and test
  suites had their own lists, and those had drifted.
- Feat rubrics are compiled into the feat binary.
- The nix build uses `--release=safe` (it was `fast`).

## v0.23.1

### fixed
- A line continuation after a quoted word corrupted that word
  (`echo 'xaa' \` then `"A"` printed `Aaa A`).
- `feat list --json` had empty summaries.
- `feat` errors print the usage line.

### changed
- The AUR package ships the standard feats in `/usr/share/zish/feats`.

## v0.23.0

### added
- `feats/lib/feat.zig`, a shared helper library for feats.
- `bus` feat: a durable message log between agents.
- `feat list --json`, `session list --json`, `zish --version --json`.
- `agent --turns N`.

### fixed
- Commands with more than 256 arguments lost the extra arguments.
- The parser refused commands over 256 arguments and scripts over about 400 lines.
- An empty case arm (`a) ;;`) was a parse error.
- `printf '%*s'` ignored the `*` width.
- Feats exited 0 instead of 141 on SIGPIPE.
- `web fetch` hid curl failures.
- `budget tree` dropped long account ids.

## v0.22.0

### added
- Core feats ship with the shell; more install on demand.
- `gf`, the feat package manager, using a sha-pinned index.
- `agent edit`, a stdin-to-stdout filter for editors.

### fixed
- The first `gf install` on a fresh system failed.
- AUR publishing failed on ssh host-key verification.

## v0.20.1

### fixed
- Globs with a wildcard before the last `/` (`*/main.zig`) did not expand.
- `**/name` never matched.
- `cd -` printed garbage (use-after-free).

## v0.16.1

### fixed
- `$(($x * 2))` and `$(($1 * 2))` evaluated to 0.
- Feats could not be run by name (`calc 2+2`), only through `feat run`.
- A crash when probing a closed file descriptor.

### added
- `calc` feat for floating-point arithmetic.
- fd 3 trace: one JSON line per command.

## v0.16.0

### security
- Tab completion ran a shell to probe `--help`, so metacharacters in a typed
  word executed on TAB. It now uses argv with an allowlist.
- Lexer out-of-bounds write on long words followed by a backslash.
- Password buffers are wiped.

### fixed
- `( a; b )`, `cmd | { a; b; }` and `( a; b ) &` ran only the first command.
- Heap corruption in forked children (`( cd / )`).
- Here-strings over 64 KiB deadlocked.
- `$(( minInt / -1 ))` crashed.
- A job-control race crashed the shell.
- Job notices went to stdout in scripts.

### added
- Two-tone ghost text, `ctrl+o` to toggle it, `alt+e` to accept one character.
- `feat` builtin, `flake.nix`, `install.sh` with checksum checks.
- `tests/regress.sh`, `zig build fuzz`, `docs/security.md`, MIT `LICENSE`.

## v0.7.0

### changed
- Vim mode is always on, alongside emacs keys.
- `ctrl+left`/`ctrl+right` move by whitespace-separated word.

### added
- `ctrl+w` deletes the previous word.

### fixed
- Completion menu cursor and redraw.
- Bracketed-paste escapes no longer get captured by redirects.

## v0.6.4

- Completion display fixes, `ctrl+backspace`.

## v0.6.3

- Escape-sequence fixes, AUR package.

## v0.6.0

- First public release: vim editing, git prompt, completion, history.
