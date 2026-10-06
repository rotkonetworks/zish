# zish

A fast shell for Linux. Runs your bash scripts, and can sandbox what it runs.

## Install

```sh
paru -S zish                                    # Arch
nix profile install github:rotkonetworks/zish   # Nix
sudo apt install ./zish_*_amd64.deb             # Debian, Ubuntu, Proxmox
```

The `.deb` and plain binaries are on the [releases page](https://github.com/rotkonetworks/zish/releases).

## Use

```sh
zish                # start it
zish -c 'echo hi'   # run one command
man zish            # everything else
```

Bash syntax works: pipes, `$(…)`, `$((…))`, `[[ ]]`, arrays, functions, job control.

Interactive extras:

- vim and emacs keys together (`Esc` for vim)
- syntax highlighting and a git prompt
- grey suggestions from history (`Right` to accept)

Missing: associative arrays, zsh-only syntax.

## Speed

About 1.2 to 1.8x faster than bash. Check it yourself with `./bench.sh`.

## Feats

Small built-in tools, so you don't reach for Python:

```sh
calc '2^0.5'                 # 1.4142135623730951
cnt file.txt                 # line count
pk -t 5 build.log            # last 5 lines
ls *.log | para grep ERROR {}   # run in parallel
```

`feat list` shows what you have. `gf install <name>` adds more.
A feat never replaces a real command with the same name.

## Sandbox

```sh
zish --profile readonly -c 'make test'   # can't write anything
zish --profile workdir  -c 'make build'  # can only write in this directory
```

The kernel enforces it (Landlock + seccomp), so child programs can't get around it.
It doesn't stop reads or network access. See [docs/security.md](docs/security.md)
and, for running AI agents inside it, [docs/agents.md](docs/agents.md).

## Contributing

```sh
./tests/regress.sh   # must stay green
```

Add a test for whatever you fix.

MIT licensed.
