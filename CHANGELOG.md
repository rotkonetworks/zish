# changelog

## v0.22.0

Feats now ship with zish, and gf is a real package manager. Rolls up 0.21.x.

### added
- **Feats ship with the shell.** The core set — the zero-dep utilities `cnt pk
  frq snf jls calc para` plus `gf` — installs beside the binary and resolves out
  of the box (a second, read-only system tier alongside `~/.zish/feats`). The
  heavier feats (`agent team web aur budget verify ask`) install on demand.
  Selectable with `-Dfeats=core|all`; Nix exposes `zish` and `zish-full`.
- **`gf` — the feat package manager.** `gf install <name>` / `gf setup` / `gf
  list` / `gf remove` / `gf settings`, against a signed, sha-pinned index.
  ZFS-style CLI: booleans, get/set, exit codes 0/1/2. Untrusted installs are
  quarantined, and the AUR build-script hole is closed (recipes are data, not
  code). Feat binaries are static musl, so they run anywhere, NixOS included.
- **`agent edit`** — a stdin→stdout region filter for editors; the captain
  conversation reads a piped message, so it composes as a filter too.

### fixed
- First `gf install` on a fresh system (no `~/.zish` yet) failed — `mkdir -p` is
  now recursive.
- AUR publish failed on host-key verification: ssh read `/root/.ssh` (getpwuid)
  while the workflow wrote `$HOME/.ssh`. Pinned by absolute path now, via
  `GIT_SSH_COMMAND`.
- CI: `OLDPWD` unbound in `regress.sh` under `set -u`; removed the macOS builds.

## v0.20.1

Correctness fix release over 0.20.0. Recommended for everyone: two of these
are glob bugs that silently returned the wrong thing.

### fixed
- **glob with a wildcard before the last `/` never expanded.** `*/main.zig`,
  `src/*/x.zig`, `*/`, `[ab]*/file` all came back as the literal pattern,
  because expansion split at the last slash and tried to open the directory
  half literally — there is no directory called `*`. Patterns now expand one
  component at a time. A trailing `/` keeps directories only and a leading
  `//` is preserved, as in bash.
- **`**/name` never matched.** The recursive walker kept the `/` on its
  suffix and compared `/name` against filenames.
- **`-` builtin printed garbage.** It changed to `$OLDPWD` correctly but
  printed the path after the buffer it pointed into had been freed
  (use-after-free; the bytes were whatever the allocator did next).

Regression cases for all three are in `tests/regress.sh`, differential
against bash where bash pins the answer.

## v0.16.1

Correctness fix release. Recommended for anyone on 0.16.0.

### fixed
- **`$(( ))` silently evaluated `$var` to 0.** The arithmetic parser had no
  case for `$`, so it raised a syntax error that was converted to 0 without
  any message. `$((x * 2))` was correct but `$(($x * 2))` was 0, and every
  positional parameter in arithmetic was 0 — so
  `double() { echo $(($1 * 2)); }` returned zeros for every argument. It only
  ever worked because an earlier expansion pass usually substituted the
  variable first; for a word containing `*` that pass is skipped.
- feats could not be invoked as ordinary commands: `feat run calc 2+2` worked,
  `calc 2+2` was "command not found"
- the pipeline fast path exec'd without checking PATH, so `echo 1+1 | calc`
  failed with 127 while `calc 1+1` worked
- `compat.posix.fstat` asserted `unreachable` on EBADF, which made probing a
  possibly-unopened descriptor a panic

### added
- **`calc` feat** — float arithmetic, which `$(( ))` cannot do at all
  (`$((3/2))` is 1, `$((2**0.5))` is a syntax error). f64 throughout, real
  division, `sqrt`/`ln`/`log(base,x)`/trig, hex and binary literals. Errors
  exit non-zero with nothing on stdout, so `x=$(calc ...)` is a number or
  empty, never a wrong number.
- feats now resolve as plain commands, as a fallback after builtins, functions
  and PATH — a feat can never shadow a real binary
- **session trace on fd 3** — one JSON record per top-level command
  (`zish -c 'make test' 3>trace.jsonl`), so a program driving zish never has to
  parse ANSI escapes to learn what happened
- gguf: metadata nesting depth is bounded and `general.alignment` validated;
  both were crashes reachable from a downloaded model file

### changed
- README benchmark claim corrected from "3-7x" to the measured **1.5-2x**
- docs no longer describe the removed LLM agent
- CI now runs `tests/regress.sh` and `bench.sh` and cross-builds for
  aarch64-linux

## v0.16.0

security and correctness release. upgrading is recommended for all users.

### security
- **tab completion no longer runs a shell.** completion probed `<word> --help`
  by building a `/bin/sh -c` string, so shell metacharacters in a typed or
  pasted word executed on TAB — before you pressed enter. now spawned as argv
  with stdout/stderr merged over one pipe, plus a strict allowlist on probe
  names. affected `--help` and man-page lookups.
- gguf model files are now parsed defensively: lengths and counts read from the
  file are bounded against the file size before reaching an allocator, tensor
  offsets are validated against the mapping, and `numElements` saturates
  instead of overflowing. a malicious model could previously crash the parser.
- lexer: fixed an out-of-bounds write when a word longer than
  `MAX_TOKEN_LENGTH` was followed by a backslash escape.
- crypto: password buffers are wiped on the stack and before being freed.

### fixed
- `( a; b )`, `cmd | { a; b; }` and `( a; b ) &` ran only the first command and
  silently discarded the rest
- forked children corrupted the heap by freeing inherited allocations with a
  different allocator (`( cd / )` was enough to trigger it)
- here strings deadlocked above ~64 KiB and leaked a descriptor on write
  failure; they now use a temp file, as heredocs already did
- `$(( minInt / -1 ))` and 19-digit integer literals crashed safe builds and
  produced wrong answers in release builds
- `tcsetpgrp` asserted `unreachable` on recoverable errno values, crashing the
  shell on a job-control race
- job notifications (`[1] 1234`) went to stdout in non-interactive mode,
  corrupting the output of scripts using `&`; now stderr, interactive only
- cursor-shape and bracketed-paste escapes were written to a non-tty stderr
- glob: missing length guard on directory entry names

### added
- ghost text is now two-tone: the part completing the token you are typing is
  cyan, the rest is italic gray, so a suggestion never reads as committed input
- committed flags render in their own color instead of ghost gray
- `ctrl+o` toggles ghost autosuggestion, `alt+e` accepts one character of it
- `feat` builtin, and `make feats` to build and stage the standard feats
- `flake.nix` — NixOS package, NixOS module and dev shell
- `install.sh` — detects the platform, prefers your package manager, and
  verifies the release binary against published checksums before installing
- release builds now publish `SHA256SUMS-<target>` alongside each binary
- `tests/regress.sh` — end-to-end regression suite, including differential
  tests against bash and interactive tests for the completion attack surface
- `zig build fuzz` — fuzz targets for the parser, lexer, arithmetic evaluator,
  glob matcher and gguf parser, driven by both a randomized sweep and
  `std.testing.fuzz`
- `docs/security.md` — threat model and audit results
- `LICENSE` (MIT, matching what the package metadata already declared)

## v0.7.0

production ready release.

### changed
- vim mode is now always-on hybrid: vim text objects + emacs keys (ctrl+a/e/u/w) + arrow keys
- removed `set vim on/off` toggle - vim is always available
- removed ctrl+t vim toggle keybind
- ctrl+right/left now use WORD boundary (stop at whitespace)

### added
- ctrl+w deletes word backward in insert mode

### fixed
- completion menu cursor positioning (no longer jumps to bottom)
- completion cycling display (proper redraw instead of garbled output)
- bracketed paste escape codes now go to stderr (no longer captured by redirects)

### removed
- ~710 lines of dead code (highlight.zig, bookmark feature)
- duplicate builtins list (completion now uses keywords.zig)

## v0.6.4

- fix completion display bugs
- add ctrl+backspace for word delete

## v0.6.3

- escape sequence handling fixes
- aur package release

## v0.6.0

- initial public release
- vim modal editing with text objects
- git prompt integration
- tab completion
- persistent history
