# zish feat — boundary contract

Status: draft v0.1
Scope: the **only** interface between zish and a feat. Anything not specified here
does not exist. Any feat that relies on unspecified behavior is a bug in the feat.

## 0. Principle

A **feat is not a plugin**. It is a standalone, statically-linked binary that zish
discovers in a directory and `exec`s. The boundary between zish and a feat is:

    fork + exec + argv + stdio + exit status

There is **no dynamic loading, no in-process hook, no registration ABI, no IPC**.
If you find yourself designing one of those, stop: the tier already encodes the
trust decision, and the process boundary is the sandbox.

The three tiers exist to assign **trust and capability**, not to organize files.

## 1. Tiers

### 1.1 core
- Compiled into the zish binary. Always present. Cannot be removed.
- In-process, privileged, and therefore **hand-reviewed**.
- Policy: pure Zig, zero external dependencies, essential shell operation only.
- Rule: **no feat (standard or extra) may ever run in-process.** The in-process
  surface is the shell, and only the shell.

### 1.2 standard
- Separate static Zig binary, shipped with zish, installed by default into the
  registry under `standard/`.
- Present by default, **omit-able** in a minimal build (`-Dno-standard-feats`).
- Trusted-ish: authored and shipped by you, exec'd (so a bug is contained).
- This is where Python-replacement shell/harness tooling lives.

### 1.3 extra
- User/community-installed. Not shipped.
- **Explicitly untrusted.** A feat in this tier is treated as hostile input.
- Separate process, never auto-run, never auto-used by scripts, never run as
  root without warning, executed with a stripped environment.
- Only invoked by an explicit `zish feat run extra/<name> ...`.

## 2. Registry layout

`$ZISH_FEAT_PATH`, defaulting to `~/.zish/feats`. A directory **is** the registry;
there is no index file to keep in sync.

    $ZISH_FEAT_PATH/
      core/        (reserved; core is in-binary, this dir is unused today)
      standard/
        <name>/
          feat.toml        # manifest
          bin/             # the executable (name = "bin" field)
      extra/
        <name>/
          feat.toml
          bin/

Discovery is a **filename walk**: list `standard/*` and `extra/*`, read one
manifest per directory. No database, no glob cache.

## 3. Manifest (`feat.toml`)

The manifest is **data from a possibly-hostile source**. zish reads **only**:

    name        (string, required)  must match the parent directory name
    tier        (string, required)  one of "core"|"standard"|"extra"
    version     (string, required)  semver, pinned
    help        (string, required)  one-line description
    kind        (string, optional)  "oneshot" (default) | "session", see §0
    usage       (string, optional)  one invocation line, for `help` and catalogs
    summary     (string, optional)  a few words; the prose-free form of `help`
    bin         (string, optional)  executable name; default = <name>
    completion  (array, optional)   CLI hints, see §6

Every other field is **ignored, unconditionally**. Do not parse more. A malformed
or over-large manifest is rejected as invalid; it is never silently defaulted.

## 4. The `feat` builtin

Wired into `builtins.zig` via `isBuiltin`/`dispatch` under the name `feat`.

    zish feat list [-n] [--json[=brief|full]]
                          list installed feats, ordered by tier then name so a
                          program can diff or cache the result. `-n` prints
                          names only; `--json` prints one JSON object per line
                          with no prose (name, tier, kind, summary), which is
                          the cheapest structured form; `--json=full` adds
                          version, bin, usage, and help. A harness renders its
                          own tool schema from the JSONL form, so a newly
                          installed feat is callable with no harness change.
    zish feat help <name> print the feat's `help` line
    zish feat run <name> [args...]
                          resolve <name> in the registry, exec its bin with args
    zish feat install <src>     install an extra tier feat (copies dir into extra/)
    zish feat uninstall <name>  remove an extra feat (refuses core/standard)

Resolution order: `standard` before `extra` on name collision; an explicit
`standard/name` or `extra/name` qualified path always wins.

`feat run` sets the exit status to the feat's exit status. Signals pass through.

## 5. Invocation/runtime contract

- **argv[0]**  = the feat's `bin` (not `zish`).
- **stdin/stdout/stderr** are inherited. A feat must be a normal Unix program:
  read stdin, write stdout, exit 0 on success non-zero on failure. It must be
  directly executable on PATH and stand alone in a pipeline — `zish feat run
  standard/jsonlstats | jq '.total'` must work.
- **environment** for standard: inherited. For **extra**: stripped — `PATH` (to
  bin dir), `HOME`, locale, and nothing else, unless the user explicitly opts in.
- **resources**: no promises. Do not depend on timing.
- **exit codes**: 0 success; non-zero failure. Feats should follow the regular
  convention (1 general error, 2 usage error) but zish does not interpret them.

## 6. Completion protocol

The `completion.hints` array supplies per-feat Tab-completion to `completion.zig`.
Each entry is a literal token the shell should offer. Tokens beginning with `-`
are offered when the user types `-`; any other token is offered at position 0.

    completion = ["-k|--key", "-p|--prefix", "-o|--output"]

`|` separates aliases of the same option (all offered). The shell offers the
hints verbatim; it does no parsing of their meaning. Feats that need richer
completion (dynamic values) do it themselves: they may read stdin on a special
request, but that is out of this contract and must not be relied upon.

## 7. Security notes (minimal, non-negotiable)

1. **extra is untrusted.** Exec it in a stripped environment, never as root by
   default, and only via explicit `feat run`.
2. **Manifest is hostile input** for extra; read only the five fields, reject
   the rest.
3. **Never elevate.** zish does not grant a feat privileges beyond the user; a
   feat gets exactly the user's ambient permissions.
4. **Version pinning only** — no auto-update. Updating is an explicit
   `feat install` again.

## 8. Out of scope (and why)

- **ML / numeric.** numpy/scipy/torch are not replaceable in Zig. The project's
  model training + HF→GGUF export pipeline remains an **external Python stage**
  whose `.gguf` output zish's pure-Zig `src/inference/` engine consumes. feats
  replace Python for shell and harness scripting; they do not replace it.
  This carve-out is part of this spec.
- **Dynamic loading**, **IPC**, **in-process hooks**: deliberately absent, §0.
- **A general-purpose scripting language inside zish**: absent. The "language"
  is the shell pipeline; feats are the leaf atoms.

---

## 9. Token economy (design principle)

zish is a shell for **agents**. The token budget is what the shell echoes and
emits, not what it does internally. Therefore, as a first-class property:

- **Terse by default.** Feats emit only the useful bytes. No banners, version
  lines, decorative headers, or progress. One record per line. Machine-parseable
  delimiters (tab, `\0`, single space). A `-v` flag is the *only* way to get
  verbosity, and `-v` is never the default.
- **One feat, one question.** A feat answers a single question in a single call
  and stops. No modes-that-do-things commands. If you need two behaviors, two
  feats (or two named subcommands with terse output).
- **Short names, right defaults.** Names are short so the invocation line is
  short; defaults are chosen so flags are rarely needed. Paying tokens to pass
  flags is a spec bug, not a user error.
- **Deterministic, greppable.** Same input → same bytes. Output is stable across
  runs so an agent can regex it without re-reading it.
- **No reflected noise.** When zish itself runs feats in a script/agent context
  it does not echo commands or add framing. The pipeline's stdout is the only
  token cost.

## 10. Seed standard set (first batch)

The first feats are chosen by the heuristic: **"the operations an agent
habitually does in Python to read stuff, but made terse."** Each row is a Python
idiom killed.

| feat | replaces (Python idiom) | behavior (terse) |
|------|--------------------------|--------------------|
| `pk`  | `open(f).read().splitlines()[:N]` | print first N lines; `path:N:line` when multiple files |
| `fq`  | `os.walk` + `find` + splitext | list paths matching name/glob/ext, newline- or `\0`-delimited |
| `cnt` | `len(..)` / `sum(..)` / `wc -l` | single integer: count of lines/bytes/glob/pattern matches |
| `frq` | Python `Counter` over fields | `count<TAB>value`, sorted desc, top-K default |
| `jls` | `json.loads` per `.jsonl` line | stream JSONL: select/tally fields, one line per record |
| `snf` | `getsize`+header+magic (multi-call) | one line per file: `path<TAB>size<TAB>lines<TAB>ext<TAB>magic` |
| `rg`  | Python `re` tree scan | recursive substring/regex match, `path:line:text`, ignore dirs |

These seven are literally the operations I used Python for this session.

## 11. Build/host contract for seed feats

- Feats live under `feats/<name>/` in the repo: `main.zig`, its `feat.toml`, and
  any data it owns under `rubrics/`.
- **`build.zig` is the only thing that compiles a feat.** One list decides which
  feats exist, whether each links libc, and where it installs — `-Dfeats` takes
  `core` (default), `all`, or an explicit comma-separated list, and
  `-Dfeat-layout` selects the install shape. There is no Makefile loop and no
  per-suite `zig build-exe`: a second build site is a second answer to "what is
  a feat", and those answers had already drifted apart.
- The registry tree the shell reads is
  `<prefix>/share/zish/feats/standard/<name>/{bin/<name>,feat.toml}`, and
  `-Dfeat-layout=registry` writes the same thing rooted at the prefix instead —
  so `feat list`/`run` reflect the shipped set either way.

### 11.1 Shared code — `feats/lib/feat.zig`

Feats do not share a process, but they may share *source*: `feats/lib/feat.zig`
is a primitives-only library (env, slurp stdin, terse output, JSON escaping,
atomic publish, exit-code constants). Sharing it does not touch the
`fork + exec + argv + stdio` boundary — the coupling the tier system forbids is
*in-process plugin* coupling, not a statically-linked module.

Primitives only, and no policy: a helper that makes a decision on the caller's
behalf belongs in the caller.

**Importing it.** Zig confines an import to the root file's own directory tree,
so `@import("../lib/feat.zig")` does not compile — no `..` form does, in any mode
(local, `-lc`, `-target x86_64-linux-musl`) or under `zig test`. So each feat
carries a relative symlink and imports through it:

    feats/<name>/lib/feat.zig -> ../../lib/feat.zig
    const feat = @import("lib/feat.zig");

Keep the name exactly `lib/feat.zig`. The module form (`-Mroot` / `--dep`) is
also viable now that `build.zig` is the only build site — it would delete the
sixteen symlinks — but it is a migration to make deliberately, not a
prerequisite for anything here.

**Zero libc.** Zig 0.16 removed `std.posix.getenv` and
`std.process.getEnvVarOwned`, which is why feats used to link libc for one
lookup; `feat.env` reads `/proc/self/environ`. The `feat_libc` list in
`build.zig` names only the feats that still need libc for something real
(`para`, for `execvp`), with the reason noted there. A feat that newly needs
libc is a change to that list *and* to its justification — not a quiet `-lc`.
