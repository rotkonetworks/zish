# zish

A fast, zsh-compatible shell written in Zig.

Your `.zshrc`, your scripts and your muscle memory keep working. It's a single
static binary with no interpreter startup, so it runs noticeably quicker —
roughly 3–7x on loops, conditionals, arithmetic and command substitution
(`./bench.sh` to check for yourself).

Linux only, for now.

## Install

```sh
# Arch
paru -S zish

# Nix
nix profile install github:rotkonetworks/zish

# Anything else (downloads a verified release binary, or builds from source)
curl -fsSLO https://raw.githubusercontent.com/rotkonetworks/zish/main/install.sh
less install.sh && sh install.sh

# From source
zig build --release=fast && ./zig-out/bin/zish
```

Read `install.sh` before running it. Piping a script from the network straight
into a shell means running code you never saw — the script is short so you
don't have to take that on faith, and it refuses to install a binary whose
checksum it can't verify.

## Try it

```sh
zish                 # interactive
zish -c 'echo hi'    # one-shot
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

## Feats

Feats are small standalone binaries that answer one question each, so you
don't reach for Python to inspect a file or count something:

```sh
pk <file>       # first N lines
cnt <file>      # a single number: lines/bytes/words
frq <file>      # field frequency table
fq <glob>       # list files recursively
jls <.jsonl>    # select/tally JSONL fields
snf <path>      # size, lines, ext, magic — one line per file
```

They're opt-in and never in the hot path. A feat is just a binary zish
`exec`s — no plugin ABI, no dynamic loading. `zish feat list` to start.

See [docs/feat-spec.md](docs/feat-spec.md) for the boundary contract.

## Driving zish from a program

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

## Ghost text

If you point zish at a local GGUF model, it suggests the rest of the command
as you type — shown ahead of the cursor in a dimmer color, so a suggestion
never reads as something you typed. `ctrl+o` toggles it, `alt+e` accepts one
character.

Inference is pure Zig with no external dependencies, runs in a forked child so
a slow model can't stall the prompt, and is entirely optional — zish works
normally with no model configured.

Config lives in `~/.zish/agent.json` (`completion_model` points at the `.gguf`).

## Tests

```sh
./tests/regress.sh     # end-to-end, incl. differential tests against bash
zig build test         # unit tests + randomized sweeps
zig build fuzz         # fuzz targets on parser/arithmetic/glob/GGUF
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
