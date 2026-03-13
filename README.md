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
agent -m large <query>   # model override (small/medium/large)
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

commands: `/compact`, `/cost`, `/model`, `/diff`, `/commit`, `/review`, `/undo`, `/plan`, `/spawn`, `/queue`, `/tree`, `/agents`, `/tasks`, `/search`, `/help`

### subagents

recursive spawning up to 3 levels deep, 8 per level. workers get full tools, read-only subagents get bash/read/glob/grep. autonomous task queue (16 slots) for background work.

### tree view (`/tree`)

vim-navigable agent tree with live bulletin feed. shows all agents, subagents, and tasks in a hierarchical view.

| key | action |
|-----|--------|
| `j/k` | move cursor |
| `l` / `Enter` | view agent output |
| `h` / `Esc` | back / exit |
| `g/G` | top / bottom |
| `r` | refresh tree |
| `q` | quit tree view |

### bulletin board

shared broadcast log — the commons. any agent (main, subagent, worker) can post. no hierarchy, no central authority. all agents see all posts.

post types: discovery (findings), escalate (override parent), request_peer (ask for help), claim/release (resource locking), vote (consensus).

agents automatically broadcast: spawn/completion events, file edit/write claims. visible in tree view bulletin feed.

### query router

classifies queries before dispatch: local patterns (70% zero-cost) → local GGUF inference → small-tier API call. selects model tier (small/medium/large). shell commands use `!` prefix for deterministic bypass.

### local GGUF inference engine

pure-zig inference engine in `src/inference/` — zero external dependencies, no python, no llama.cpp.

- **GGUF v3 parser**: mmap-based, reads metadata, tensor info, alignment
- **transformer forward pass**: RoPE, RMSNorm, SwiGLU MLP, grouped-query attention, KV cache
- **quantization**: F32, F16, Q8_0 (SIMD matmul), Q4_K (fused dot), Q6_K (fused dot)
- **SIMD math**: fused quantized dot products, multi-threaded matmul (up to 8 cores)
- **sliding window attention**: for mistral-family models, O(T×W) instead of O(T²)
- **fork-based process isolation**: child loads model via mmap, parent sends queries via pipes
- **continuous inference**: child self-feeds tokens between requests, keeps KV cache and CTM state warm
- **BPE tokenizer**: built from GGUF metadata, SentencePiece compatible

#### CTM (continuous thinking model)

additive thinking blocks on top of standard MLP — preserves all pretrained knowledge. includes SuperLinear layers, SynapseUNET, dual sync accumulators.

#### CTM plasticity (breathing architecture)

online learning without gradients:
- **dopamine gating**: surprise-based neuromodulation, clamped [0.5, 1.0]
- **hebbian learning**: weight updates from sync patterns, novelty gating + homeostasis
- **replay buffer**: 64-entry ring of token sequences with surprise scores
- **breathing loop**: inhale (generate with dopamine tracking) → exhale (compact weights, persist state)
- **persistence**: `.ctmstate`, `.plastic`, `.replay` files alongside the GGUF model

```
~/.zish/agent.json: "router_local_model": "~/.zish/models/qwen25_ctm_k32.gguf"
```

| module | role |
|--------|------|
| `inference/root.zig` | ForkServer (fork+pipes), InferenceContext, continuous child loop |
| `inference/gguf.zig` | GGUF v3 parser: mmap, metadata KV, tensor info |
| `inference/model.zig` | transformer forward pass, KV cache, attention |
| `inference/math.zig` | SIMD math, fused quantized dot products, parallel matmul |
| `inference/tokenizer.zig` | BPE tokenizer from GGUF metadata |
| `inference/ctm.zig` | CTM blocks, SuperLinear, SynapseUNET, plasticity |

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
| `agent_commands.zig` | table-driven slash command dispatch, tree view |
| `agent_router.zig` | query classification pipeline |
| `agent_queue.zig` | SPSC ring buffer, MPSC bulletin board (the commons) |
| `agent.zig` | agent thread, API calls, SSE parsing, markdown renderer |

## plugins

contribute without recompiling. drop files in `~/.zish/` directories.

### tools (`~/.zish/tools/*.json`)

one JSON file per tool (or array of tools). agent gets them as callable functions.

```json
{
  "name": "GitBlame",
  "description": "Show git blame for a file",
  "command": "git blame --date=short {file_path}",
  "parameters": {
    "file_path": { "type": "string", "description": "Path to file" }
  }
}
```

also loads legacy `~/.zish/agent-tools.json`. see `contrib/tools/` for examples.

### router patterns (`~/.zish/patterns/*.txt`)

teach the router new keywords. zero-cost local classification. tiers: small (simple), medium (code), large (complex).

```
# agent keywords — route to LLM with tier selection
type: agent
tier: medium
scaffold
bootstrap

type: agent
tier: large
threat model
root cause
```

see `contrib/patterns/` for examples.

### install from contrib

```sh
cp contrib/tools/kubectl.json ~/.zish/tools/
cp contrib/patterns/devops.txt ~/.zish/patterns/
```

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
