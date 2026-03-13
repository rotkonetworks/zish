# zish

fast, opinionated shell written in zig. for the brave.

## features

- hybrid vim/emacs editing (vim text objects + emacs keys + arrows)
- git prompt (`set git_prompt on`)
- syntax highlighting
- tab completion with ghost text prediction
- persistent history
- aliases & functions
- `${VAR:-default}` parameter expansion
- `[[ ]]` test expressions
- pipes, redirects, `&&`, `||`
- `$(cmd)` and `$((math))`
- builtins: `cd`, `-`, `..`, `...`, `local`, `export`

## agent

embedded LLM agent with tool use, recursive subagents, and local inference.

```
agent                    # interactive mode
agent <query>            # one-shot
agent -m opus <query>    # model override (opus/sonnet/haiku)
agent continue           # re-enter session
agent attach [id]        # attach to running session (like screen)
agent sessions           # list sessions
agent log [id]           # view conversation with markdown rendering
```

### tools

bash, read, edit, write, glob, grep, agent (recursive subagents), webfetch, websearch. plugin tools via `~/.zish/agent-tools.json`.

### interactive mode

bottom-anchored TUI with scroll regions, markdown rendering, and vi mode input.

| key | action |
|-----|--------|
| `Enter` | submit query |
| `Ctrl+J` / `Alt+Enter` | insert newline |
| `PageUp` / `PageDown` | scroll history |
| `Esc` | vi normal mode |
| `Ctrl+D` | exit |

commands: `/compact`, `/cost`, `/model`, `/diff`, `/commit`, `/review`, `/undo`, `/plan`, `/spawn`, `/queue`, `/agents`, `/tasks`, `/search`, `/help`

### subagents

recursive spawning up to 3 levels deep, 8 per level. workers get full tools, read-only subagents get bash/read/glob/grep. autonomous task queue (16 slots) for background work.

### query router

classifies queries before dispatch: local patterns (70% zero-cost) → local GGUF inference → haiku API call. routes to shell (bypass LLM), or selects model tier (haiku/sonnet/opus).

### local inference

pure-zig GGUF inference engine. fork-based process isolation, continuous inference between requests. supports F32, F16, Q8_0, Q4_K, Q6_K quantization. SIMD matmul, sliding window attention, CTM (continuous thinking model) with online plasticity.

## architecture

follows "your server as a function" (eriksen/finagle): services, filters, composable pipelines.

```
RouterFilter → LoggingFilter → TokenTrackingFilter → RetryFilter → ToolLoopService
```

| module | role |
|--------|------|
| `agent_service.zig` | request/response types, comptime `Stack()` composer |
| `agent_filters.zig` | router, logging, token tracking, retry filters |
| `agent_tools.zig` | tool dispatch with `ToolContext` |
| `agent_drain.zig` | comptime drain handler for message output |
| `agent_commands.zig` | table-driven slash command dispatch |
| `agent_router.zig` | query classification pipeline |
| `agent.zig` | agent thread, API calls, SSE parsing, markdown renderer |

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

methodology: `./bench.sh` runs from `/bin/sh` with hyperfine. all shells use `--norc --noprofile` / `--no-rcs`.

## build

```
zig build --release=fast
./zig-out/bin/zish
```

## config

```
cp example.zishrc ~/.zishrc
```

agent config: `~/.zish/agent.json`. credentials: `~/.claude/.credentials.json` (auto-loaded from claude code) or `api_key`/`api_key_cmd` in config.

## vim mode

see `man zish` for full vim mode documentation, or the tables below.

### normal mode

| key | action |
|-----|--------|
| `i/a/A/I/o/O` | enter insert mode |
| `h/j/k/l` | movement |
| `w/W/b/B/e/E` | word motions |
| `0/^/$` | line position |
| `gg/G` | buffer start/end |
| `d/c/y` | operators (combine with motions) |
| `dd/cc/yy/Y` | line operations |
| `x/X` | delete char |
| `r` | replace char |
| `~` | toggle case |
| `J` | join lines |
| `p/P` | paste after/before |
| `v/V` | visual / visual line |
| `di"/ci(/da[` | text objects |

## platform

linux only. uses linux-specific syscalls. PRs welcome for portability.

## man page

```
man zish
```
