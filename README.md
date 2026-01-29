# zish

fast, opinionated shell written in zig. for the brave.

## features

- hybrid vim/emacs editing (vim text objects + emacs keys + arrows)
- git prompt (`set git_prompt on`)
- syntax highlighting
- tab completion with common prefix
- persistent history
- aliases & functions
- `${VAR:-default}` parameter expansion
- `[[ ]]` test expressions
- pipes, redirects, `&&`, `||`
- `$(cmd)` and `$((math))`
- builtins: `cd`, `-`, `..`, `...`, `local`, `export`

## performance

| test | vs bash | vs zsh |
|------|---------|--------|
| command substitution | **7.0x faster** | **7.0x faster** |
| nested loops | **4.0x faster** | **4.4x faster** |
| conditionals | **4.0x faster** | **4.5x faster** |
| arithmetic | **3.8x faster** | **4.3x faster** |
| variables | **3.6x faster** | **3.9x faster** |
| functions | **3.4x faster** | **3.8x faster** |
| pipelines | **1.7x faster** | **1.9x faster** |

methodology: `./bench.sh` runs from `/bin/sh` with hyperfine. all shells use `--norc --noprofile` / `--no-rcs` to skip user config. output correctness is validated against bash before each benchmark.

why it's fast:
- **static binary** - no dynamic linker overhead, no shared libs
- **stack buffers** - echo/test builtins use stack allocation in loops, no malloc
- **minimal init** - no readline/job control setup for `-c` mode

## build

```
zig build --release=fast
./zig-out/bin/zish
```

## config

```
cp example.zishrc ~/.zishrc
```

## vim mode

zish has vim-style modal editing enabled by default.

### modes

| mode | indicator | description |
|------|-----------|-------------|
| insert | `[I]` | normal typing (default) |
| normal | `[N]` | vim commands |
| visual | `[V]` | character selection |
| visual line | `[VL]` | line selection |
| replace | `[R]` | overwrite mode |

### normal mode commands

**mode entry**
| key | action |
|-----|--------|
| `i` | insert at cursor |
| `I` | insert at line start |
| `a` | append after cursor |
| `A` | append at line end |
| `o` | open line below |
| `O` | open line above |
| `s` | substitute char |
| `S` | substitute line |
| `v` | visual mode |
| `V` | visual line mode |
| `R` | replace mode |

**motions**
| key | action |
|-----|--------|
| `h` `l` | left / right |
| `j` `k` | down / up (multiline) |
| `w` `W` | word / WORD forward |
| `b` `B` | word / WORD backward |
| `e` `E` | word / WORD end |
| `0` | line start |
| `^` | first non-blank |
| `$` | line end |
| `G` | buffer end |

**operators** (combine with motions or text objects)
| key | action |
|-----|--------|
| `d` | delete |
| `c` | change (delete + insert) |
| `y` | yank (copy) |

**text objects** (use with `i` inner or `a` around)
| object | description |
|--------|-------------|
| `w` `W` | word / WORD |
| `"` `'` `` ` `` | quoted string |
| `(` `)` `b` | parentheses |
| `[` `]` | brackets |
| `{` `}` `B` | braces |
| `<` `>` | angle brackets |

**common combos**
```
ciw     change inner word
diw     delete inner word
daw     delete around word (includes space)
ci"     change inside quotes
da(     delete around parentheses
yiw     yank inner word
dd      delete line
cc      change line
yy      yank line
3dw     delete 3 words
```

**single char operations**
| key | action |
|-----|--------|
| `x` | delete char under cursor |
| `X` | delete char before cursor |
| `r` | replace single char |
| `C` | change to end of line |
| `D` | delete to end of line |
| `p` | paste after |
| `P` | paste before |

### visual mode

select text then operate:
- `d` / `x` - delete selection
- `c` / `s` - change selection
- `y` - yank selection
- `o` - swap cursor/anchor
- `Esc` - cancel

### insert mode

| key | action |
|-----|--------|
| `Esc` | back to normal |
| `Ctrl-a` | line start |
| `Ctrl-e` | line end |
| `Ctrl-u` | delete to start |
| `Ctrl-w` | delete word back |
| `Ctrl-c` | cancel |

## platform

linux only. no macos support - uses linux-specific syscalls and maintainer has no way to test mac builds. PRs welcome if someone wants to add libc abstraction layer.

## status

v0.10.2 - production ready
