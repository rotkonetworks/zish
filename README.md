# zish

**A fast, familiar shell written in Zig — built to be handed to an agent.**

[![release](https://img.shields.io/github/v/release/rotkonetworks/zish?style=for-the-badge&logo=github&label=GitHub&color=24292e)](https://github.com/rotkonetworks/zish/releases/latest)
[![AUR](https://img.shields.io/aur/version/zish?style=for-the-badge&logo=archlinux&label=AUR&color=1793d1)](https://aur.archlinux.org/packages/zish)
[![Nix](https://img.shields.io/badge/Nix-flake-5277C3?style=for-the-badge&logo=nixos&logoColor=white)](https://github.com/rotkonetworks/zish#install)
[![license](https://img.shields.io/github/license/rotkonetworks/zish?style=for-the-badge&color=green)](LICENSE)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/rotkonetworks/zish/main/install.sh | sh
```

Detects your platform, uses your package manager if zish is packaged for it,
otherwise installs a release binary — and refuses to install one whose checksum
it can't verify.

<details>
<summary>Prefer not to pipe curl into sh? (you're right)</summary>

Piping a script from the network into a shell runs code you never saw. It's the
convenient option, not the safe one, and this project spends a lot of effort on
not executing things you didn't ask for — so here's the honest version:

```sh
curl -fsSLO https://raw.githubusercontent.com/rotkonetworks/zish/main/install.sh
less install.sh          # ~170 lines, readable in a minute
sh install.sh
```

Or skip the script entirely:

```sh
paru -S zish                                       # Arch (AUR)
nix profile install github:rotkonetworks/zish      # Nix / NixOS
zig build --release=safe                           # from source
```
</details>

Your muscle memory and your POSIX/bash scripts keep working. It's a single
binary with no interpreter startup, so it starts and runs quicker —
**roughly 1.2–1.8x faster than bash**:

| benchmark | vs bash |
|---|---|
| command substitution | 1.8x ± 0.3 |
| conditionals | 1.5x ± 0.3 |
| case | 1.4x ± 0.3 |
| arithmetic | 1.4x ± 0.3 |
| nested loops | 1.4x ± 0.3 |
| for + function call | 1.4x ± 0.3 |
| variables | 1.4x ± 0.3 |
| functions | 1.4x ± 0.3 |
| pipelines | 1.2x ± 0.1 |

Measured on the **`--release=safe`** binary, which is what ships. Unchecked
(`--release=fast`) is roughly 1.3–2.0x instead — the difference buys bounds,
overflow and alignment checks, which is a trade worth making in a shell an
agent drives.

Reproduce with `./bench.sh` (hyperfine; all shells run `--norc`/`--no-rcs`
from `/bin/sh`). The error bars are wide relative to the gaps, and numbers move
5–10% between runs on the same machine, so treat these as "consistently faster,
not dramatically faster" rather than precise figures. Pipelines are the weakest
case, because the cost there is `fork`/`exec` and the kernel, not the shell.

`bench.sh` validates every result against bash *before* timing, so a
wrong-but-fast answer fails instead of scoring well. That check is what caught
a real arithmetic bug in 0.16.0, which is the main reason it exists.

Linux only. macOS is a preview — see below.

## Try it

```sh
zish                 # interactive
zish -c 'echo hi'    # one-shot
zish --version       # prints the build mode too: zish 0.16.1 (ReleaseSafe)
man zish             # full documentation
```

To make it yours:

```sh
cp example.zishrc ~/.zishrc
```

## What works

Everything you'd expect from a POSIX shell: pipes, redirects, `&&`/`||`,
`$(cmd)`, `$((math))`, `${VAR:-default}`, `[[ ]]`, functions, job control,
globbing, heredocs.

Interactively you also get hybrid vim/emacs editing (vim text objects with
emacs keys still bound), syntax highlighting, a git-aware prompt, tab
completion that reads `--help` and man pages, and persistent history.

Vim mode is always on — press `Esc`. `man zish` has the full keymap.

## Compatibility

zish targets the shell people actually type, not all of zsh. Concretely, from
a differential run against real `zsh` and `bash`:

**Works** — `${#v}`, `${v/a/b}`, `${v//a/b}`, `${v#pat}`/`${v%pat}`,
`${v:-default}`, `[[ $v = pre* ]]`, `[[ $v = *sub* ]]`, arrays with `a+=(x)`
and `${#a[@]}`, `(( ))` with unprefixed variables, `[[ -o opt ]]`, `{1..3}`,
functions, `local`, `$@`/`$#`/`shift`/`return`, job control, globbing,
heredocs, here-strings, process substitution.

**Not implemented** — `typeset`, and therefore associative arrays; zsh
parameter-expansion flags `${(k)}`, `${(v)}`, `${(P)}`, `${(kv)}`; zsh string
indexing `${v[2]}` and `${v[2,4]}`; `${a[(Ie)val]}`; glob qualifiers like
`*(N)`; `zle` widgets and `compsys`.

**One difference to know about:** zish arrays are **0-based, like bash**. zsh's
are 1-based.

```sh
a=(x y z)
${a[0]}   # zish/bash: x     zsh: (empty)
${a[1]}   # zish/bash: y     zsh: x
```

`${#a[@]}` agrees everywhere, so this is silent — a zsh script that indexes
arrays will compute the wrong values without an error. If you are porting from
zsh, that is the first thing to check.

## Feats

Feats are small standalone binaries that answer one question each, so you don't
reach for Python to do arithmetic or count something.

Install them once, then just use them like any other command:

```sh
make feats          # builds and stages into ~/.zish/feats/standard
```

```sh
$ calc '2^0.5'                 # bash can't: $(( )) is integer-only
1.4142135623730951
$ calc 3/2
1.5
$ echo 1+1 | calc
2
$ cnt file.txt                 # a single number
128
$ frq access.log               # field frequency table
$ pk -t 5 build.log            # last 5 lines
$ snf src/                     # size, lines, ext, magic per file
$ jls events.jsonl             # select/tally JSONL fields
```

They resolve as ordinary commands, but only as a **fallback** — a feat can
never shadow a real binary, so installing one can't change what an existing
script means. `feat list` shows what you have, `feat help <name>` explains one,
and `feat run <name>` is the explicit form if you want it.

A feat is just a binary zish `exec`s: no plugin ABI, no dynamic loading, no
in-process hooks. See [docs/feat-spec.md](docs/feat-spec.md) for the contract.

## Driving zish from a program

A shell an agent drives has two jobs a shell you drive doesn't: report what
happened in a form a program can read, and be containable when the agent is
wrong.

### Structured output on fd 3

Open file descriptor 3 and zish writes one JSON record per command, so a
harness never has to parse ANSI escapes or prompt redraws to find out what
happened:

```sh
$ zish -c 'make test' 3>trace.jsonl
$ cat trace.jsonl
{"ts":1786246738163,"cmd":"make test","cwd":"/src","exit":0,"ms":842}
```

It's off unless fd 3 is open — no flag, no config. stdout stays exactly as the
command left it, and internals (rc sourcing, command substitution) are not
recorded, only what you actually submitted. Use `ZISH_TRACE_FD` for a
different descriptor.

### Restricting what a session may touch

```sh
zish --profile readonly -c 'make test'    # may read; writes are denied
zish --profile workdir  -c 'make build'   # may write under $PWD, read elsewhere
zish --profile none                       # the default
```

`--allow-write` adds writable roots, `:`-separated like `PATH`. That is what
makes it possible to wrap an agent, which needs its own state directory:

```sh
zish --profile workdir --allow-write "$HOME/.claude:/tmp" -c 'claude'
```

Backed by [Landlock](https://docs.kernel.org/userspace-api/landlock.html), the
kernel's unprivileged sandbox — no root, no container, no `LD_PRELOAD` tricks.
The restriction is applied once at startup and is **inherited and irrevocable**,
so it holds for every child process too:

```sh
$ zish --profile readonly -c '/bin/sh -c "echo x > /tmp/f"'
/bin/sh: line 1: /tmp/f: Permission denied
```

Session-scoped rather than per-command, deliberately. Because the kernel is
enforcing it against the whole process tree, it also bounds **zish itself** — a
bug in zish's own parser can't write outside the profile either. That is the
point. Zig's safety checks (on in the shipped build) turn the bugs they cover
into a clean abort, but no in-process check covers everything, so zish should
not be the only thing standing between an agent and your filesystem.

It **fails closed**. An unknown profile name, or a kernel without Landlock,
exits non-zero rather than quietly running unrestricted — a sandbox that
silently degrades to no sandbox is worse than none, because you stop watching.
Write-only device sinks (`/dev/null`, `/dev/tty`, ...) stay writable under every
profile; `cat x >/dev/null` is a write, and a "sandbox" that breaks it is just a
broken shell.

Network access is not restricted — Landlock's network rules cover TCP
connect/bind only, so treat this as filesystem containment, not isolation.

**You do not have to swap the agent's shell for this to work.** Claude Code
drives `bash` with no option to change it, and Python's `shell=True` is
hardcoded to `/bin/sh` — but none of that matters, because the restriction is
inherited by every descendant whatever shell they use. Wrapping Claude Code
this way was verified end to end: it runs normally, and with `Bash` allowed it
cannot write outside the roots you granted. Recipes for that and for other
harnesses are in [docs/agents.md](docs/agents.md).

## Ghost text

As you type, zish suggests the rest of the command from your history and from
completion candidates — shown ahead of the cursor in a dimmer colour, so a
suggestion never reads as something you typed. `ctrl+o` toggles it, `alt+e`
accepts one character, `Right`/`End` accept the whole thing.

There is no model involved. zish used to ship a GGUF inference engine for this;
it was removed in favour of history matching, which is where the useful
suggestions came from anyway.

## macOS (preview)

zish builds and runs on macOS. CI exercises it on every push: 25 behaviours
non-interactively (subshells, arithmetic, pipelines, functions, globs,
background jobs, redirects, heredocs, and every file-test operator checked
against bash on the same machine) plus a 13-case interactive suite over a real
pty covering ctrl-Z suspend, `jobs`, `bg`, terminal handover and tab
completion.

Still called a preview because no human has used it as a daily shell, and
because there are no prebuilt macOS binaries — shipping one would imply support
that hasn't been earned yet. Build from source:

```sh
brew install zig
zig build --release=safe && ./zig-out/bin/zish
```

Reports of what breaks are more useful than patches right now.

## Tests

```sh
./tests/regress.sh     # end-to-end, incl. differential tests against bash
python3 tests/pty_test.py  # interactive: line editor, job control, signals
zig build test         # unit tests + randomized sweeps
zig build fuzz         # fuzz targets on parser/lexer/arithmetic/glob
```

`tests/regress.sh` is the one to run before sending a patch. Every case in it
is a bug that was once real, so a red case means a regression.

See [docs/security.md](docs/security.md) for the threat model and what's
already been found and fixed.

## Contributing

Patches welcome, especially portability beyond Linux. Please make sure
`./tests/regress.sh` and `zig build test` are green, and add a case for
whatever you fixed.

## License

See [LICENSE](LICENSE).
