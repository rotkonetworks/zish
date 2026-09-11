# changelog

## v0.23.1

Two ways the shell was quietly wrong, and the feats actually reaching a fresh
install. 0.23.0 shipped a catalog a machine could not read, a lexer that
rewrote words across a continuation, and an AUR package with no feats in it.

### fixed
- **A line continuation rewrote the word before it.** The lexer's double buffer
  was rotated once per *scan*, so a scan that emitted no token — a continuation,
  a comment — consumed a rotation for nothing, and `buf_idx` came back around to
  the buffer still holding the last *emitted* token. The parser holds one token
  of lookahead, so those bytes were still live, and the next word's leading
  bytes landed on top of them:

      echo 'xaa' \
        "A"

  printed `Aaa A`; bash prints `xaa A`. It needed a *quoted* word directly
  before the continuation — an unquoted word is a slice of the input, not the
  buffer — which is why it survived this long, and why it read as a `printf`
  bug at first. Rotation now happens per emitted token, so two consecutive
  emitted tokens never share a buffer. This silently corrupted multi-line
  commands, and a harness that routes its commands through `zish -c` writes
  printf formats, sed and jq filters across lines with quotes.
- **`feat list --json` emitted `"summary":""`** for every feat that declared
  only `help` — 19 of the 20 shipped ones — so the machine-readable catalog an
  agent picks tools from was a list of names with blank descriptions.
  `summary` now falls back to `help`: a manifest may still curate a terser
  phrase, and a blank entry now means the feat genuinely describes nothing.
- **`feat -h` / `feat list -h`, and every error path, print the usage line**, so
  the natural mistake `feat --json=full` — the flag belongs to `list` — is
  corrected rather than answered with `unknown subcommand`.

### changed
- **The AUR package ships the standard feat set.** It installed only the binary,
  so a fresh install had an empty `feat list` and no way out of it: `gf`, the
  feat that installs feats, is itself one of them. The feats now install to
  `<prefix>/share/zish/feats/standard` — the path the shell derives from its own
  location, searched after `~/.zish/feats`, so a user feat still shadows a
  shipped one. The PKGBUILD builds them through the repo's own `make feats`,
  which already owns which feats exist and which need libc.
- `make feats` takes `ZISH_RUBRIC_DIR`, so a package build stages rubrics in the
  build tree instead of writing into the builder's `$HOME`.

## v0.23.0

The shell stops disagreeing with bash in ways nobody asked about, feats stop
linking libc, and an agent can finally see what its workers cost. Everything
here came out of running zish under real work for a day rather than auditing it.

### added
- **`feats/lib/feat.zig`** — a primitives-only shared library (env, slurp,
  terse output, JSON escaping, atomic publish, exit-code constants). Feats no
  longer each re-implement the same six helpers, which is where the conventions
  drifted. Imports go through a per-feat relative symlink, because Zig confines
  an import to the root file's own directory tree.
- **`bus`** — a durable message log between agents. One message is one file
  created `O_EXCL`, so publishing is atomic with no locking and a reader never
  sees a partial record; names are zero-padded microseconds, so lexicographic
  order is chronological and a cursor is just the last name seen. A subscriber
  that was not connected still gets the history. Threads are a record field,
  never part of the channel name.
- **`feat list -n | --json | --json=full`** — a machine-readable catalog,
  ordered by tier then name, so a harness can render its own tool schema from
  the shell instead of hardcoding one.
- **`session list --json`**, and a **`usage` frame**: a hosted agent reports
  per-turn token spend, the host keeps the running totals in `.meta`, and the
  transcript records per-turn deltas with the cumulative totals on `end`. A
  finished session now keeps its registry record (with its cost) for an hour
  instead of vanishing.
- **`zish --version --json`** — a capability probe (version, build mode, frame
  protocol, feature list), so a harness can tell "this binary predates the
  feature" from "the feature is broken".
- **`agent --turns N`** — the turn budget is the caller's to set, via the flag
  or `ZISH_AGENT_MAX_TURNS`. It was a hardcoded constant that a commander could
  not raise, which killed a real run mid-collection.

### fixed
- **argv is sized to the command.** It was a 256-slot stack array: a longer
  expansion silently *dropped* the tail of the argument list, and the other
  path printed its error to **stdout**, so `ls big-glob | wc -l` counted the
  message as data and reported 1 with exit 0.
- **Parser limits derive from the input**, not from constants. `MAX_ARGS_COUNT
  = 256` and `max_nodes = 1024` refused ordinary programs — a 300-argument
  command and a 401-line script — long before any adversarial input.
- **A case arm may be empty** (`a) ;;` is a legal no-op in bash and dash; zish
  failed the whole script with `EmptyError`).
- **`printf` `*` takes its width and precision from the arguments.** It was
  parsed as the unknown conversion `*` plus a literal `s`, so
  `printf '[%*s]' 5 x` printed `[s][s]` — on the padding idiom, in a builtin.
- **Eight feats no longer link libc.** They linked it only because Zig 0.16
  removed `std.posix.getenv`; `FEAT_LIBC` is now `para` alone, which genuinely
  needs `execvp`. `feat.env` reads `/proc/self/environ` instead.
- **Feats restore SIGPIPE.** Full `std.process.Init` installs a no-op handler
  for its io layer, so a feat whose reader went away exited 0 instead of 141.
- **`web fetch` reports a failed fetch** (it discarded curl's exit status, so a
  DNS failure or timeout looked like an empty page with exit 0).
- **`budget tree` no longer drops accounts** whose id overflowed a fixed 512-byte
  row buffer — the row was appended as *nothing*, with exit 0.

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
