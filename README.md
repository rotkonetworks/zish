# zish

A POSIX/bash-compatible interactive shell written in Zig. Linux only.

Your bash scripts and habits keep working. It runs shell code 1.2–1.8x faster
than bash, and it can lock a session down with Landlock and seccomp, which is
useful when the thing typing commands is an agent.

## Install

```sh
paru -S zish                                    # Arch (AUR)
nix profile install github:rotkonetworks/zish   # Nix
sudo apt install ./zish_*_amd64.deb             # Debian/Ubuntu/Proxmox, from the releases page
```

Or `sh install.sh` (it checks the release checksum), or build from source with
Zig 0.16: `zig build --release=safe`.

## Use

```sh
zish                 # interactive
zish -c 'echo hi'    # one command
man zish             # full docs, including the keymap
cp example.zishrc ~/.zishrc
```

You get pipes, redirects, `$(…)`, `$((…))`, `${v:-x}`, `${v//a/b}`, `[[ ]]`,
arrays, functions, job control, globs, heredocs and process substitution.
Interactively: vim and emacs keys at the same time (`Esc` for vim), syntax
highlighting, a git prompt, completion that reads `--help`, and history
suggestions shown as grey text (`Right` accepts, `ctrl+o` toggles).

Not supported: `typeset`/associative arrays, zsh expansion flags like `${(k)a}`,
glob qualifiers, `zle`/`compsys`. Arrays are 0-based like bash. A zsh script
that indexes arrays will silently get different values.

## Speed

| | vs bash |
|---|---|
| command substitution | 1.8x |
| conditionals, case, arithmetic, loops, functions | 1.4x |
| pipelines | 1.2x |

That's the shipped `--release=safe` build, with runs varying ±0.3x. Pipelines
gain least because their cost is fork/exec, not the shell. `./bench.sh`
reproduces this and checks every result against bash before timing it.

## Feats

Feats are small commands that ship with zish, so you don't need Python for
everyday arithmetic or counting:

```sh
calc '2^0.5'          # 1.4142135623730951
cnt file.txt          # line count, as one integer
frq access.log        # field frequencies
pk -t 5 build.log     # last 5 lines
jls events.jsonl      # count records or pull a key per line
ls *.log | para grep ERROR {}   # run in parallel, grouped output
```

A feat runs only when no real command has that name, so installing one can't
change what an existing script does. `feat list` shows what you have. More
install with `gf install <name>`. Each feat is a separate binary; see
[docs/feat-spec.md](docs/feat-spec.md).

| tier | feats |
|---|---|
| core (shipped) | `cnt pk frq snf jls jget calc rand para gf` |
| tooling | `jevx mcpc web verify` |
| agents | `agent team budget bus ask` |

## Sandboxing

```sh
zish --profile readonly -c 'make test'     # writes denied
zish --profile workdir  -c 'make build'    # writes only under $PWD
zish --profile workdir --allow-write "$HOME/.claude:/tmp" -c claude
```

The kernel enforces this, not the shell: zish sets up Landlock and a seccomp
filter once at startup, and every child process inherits them. It fails closed:
if the kernel lacks Landlock, zish exits instead of running unrestricted.

Reads and network access are not restricted. Anything left writable (git hooks,
Makefiles) can still run later outside the sandbox. Details are in
[docs/security.md](docs/security.md), and recipes for wrapping agents are in
[docs/agents.md](docs/agents.md).

With fd 3 open, zish writes one JSON line per command, so a program driving it
doesn't have to scrape the terminal:

```sh
$ zish -c 'make test' 3>trace.jsonl
$ cat trace.jsonl
{"ts":1786246738163,"cmd":"make test","cwd":"/src","exit":0,"ms":842,"sandbox":"none"}
```

## Tests

```sh
./tests/regress.sh          # end-to-end, compared against bash
python3 tests/pty_test.py   # line editor, job control, signals
zig build test
```

Every regress case is a bug that once existed. Patches welcome: keep the
suites green and add a case for what you fixed.

MIT, see [LICENSE](LICENSE).
