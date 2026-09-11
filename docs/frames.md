# zish frames — the session-feat hostcall protocol

Status: draft v0.1 (tracks frame protocol v0.3)
Scope: the **complete** wire contract between zish and a **session feat**.
Anything not specified here does not exist. See [feat-spec.md](feat-spec.md)
for what a feat *is* (the `fork + exec + argv + stdio` boundary and the trust
tiers), and [philosophy.md](philosophy.md) for why this lives in a shell.

## 0. Principle — host and guest

A normal feat is a one-shot filter: `fork + exec + argv + stdio`, run to
completion, reap. A **session feat** (`feat.toml` `kind = "session"`) is
long-lived and speaks a terse, newline-delimited JSON protocol with zish over a
pipe pair. The model is **host / guest**:

- **zish is the host.** It owns the terminal, the executor, the sandbox, the
  filesystem — all real authority.
- **the session feat is the guest.** It has *zero ambient authority*. Its
  stdio is pipes, never the terminal. It cannot touch the world except by
  asking the host.
- **frames are the hostcall table.** Each frame the guest emits is an *intent*:
  a request for the host to do something on its behalf.
- **`run` is the universal hypercall.** It executes an arbitrary command
  through zish's own parser → evaluator → sandbox → fd-3 trace. Because `run`
  carries the whole shell surface, the frame vocabulary stays tiny: new
  capability is a new *command* or a new *feat*, never a new frame.

One frame is one JSON object on one line. `t` is the type. Unknown frame types
are ignored (forward-compatible).

**frame vs intent** — do not conflate them. A *frame* is the message unit (a
JSON line, either direction). An *intent* is the semantic role of a
**guest→host** frame: a hostcall request. Intents are the subset the guest
*emits to ask for something* — `run`, `say`, `stream`, `prompt`, `done`. The
host's frames — `hello`, `result`, `event`, `error` — are announcements and
replies, **not** intents. And neither is a *feat*: a feat is the *program*
(see [feat-spec.md](feat-spec.md)); frames are what a session feat *speaks*.

## 1. The vocabulary

Ten wire frames. The original nine are stable across v0.1 → v0.3; `usage` is the
one addition since (v0.4), and it is deliberately an *announcement* rather than a
hostcall, so it needs no capability bit and a guest that never sends it still
works. Direction is host↔guest.

### 1.1 Guest → host (the intents)

| frame | shape | intent |
|-------|-------|--------|
| `run` | `{"t":"run","cmd":"<shell command>"}` | execute `cmd` via zish, capture its stdout; reply is a `result` |
| `say` | `{"t":"say","text":"<text>"}` | display a line to the human (implies a trailing newline) |
| `stream` | `{"t":"stream","text":"<text>"}` | append text with **no** implied newline (token-by-token output) |
| `prompt` | `{"t":"prompt","text":"<question>"}` | ask the human a question; the answer arrives later as an `event` |
| `usage` | `{"t":"usage","in":<int>,"out":<int>}` | report what this turn cost. Not a hostcall — an announcement, so no capability gates it. The host accumulates it and mirrors the running totals into `.meta`, which is the only way a supervisor ever sees what an agent spent: the host never talks to a model. Absent is not an error, so a guest that predates this frame simply never sends it |
| `done` | `{"t":"done"}` | end the session cleanly |

### 1.2 Host → guest

| frame | shape | meaning |
|-------|-------|---------|
| `hello` | `{"t":"hello","proto":0,"caps":["say","stream","done",...]}` | sent **once** at session start: the protocol version + the granted hostcalls. The guest learns its world up front and degrades instead of probing by denial. |
| `result` | `{"t":"result","code":<int>,"out":"<captured stdout>"}` | reply to a `run`. `code` is the command's **real** exit status (128+signal if signaled; 255 if the status was reaped elsewhere, e.g. a user's bare `wait`). |
| `event` | `{"t":"event","kind":"submitted","text":"<answer>"}` or `{"t":"event","kind":"cancelled"}` | reply to a `prompt`: the human's answer, or `cancelled` when nobody can answer (sync host, or the session ended). |
| `error` | `{"t":"error","call":"<name>","reason":"<why>"}` | a hostcall was refused. `reason` ∈ `denied` (masked off — see §2), `busy` (a `run` is already in flight), `failed` (the tool child could not spawn). |

## 2. The capability mask

There is **one** vocabulary, never tiered tables. Each session carries a mask
naming which hostcalls it may use; the rest are refused with a loud `error`
frame. `say` / `stream` / `done` are **always** granted — a guest that cannot
speak or exit cleanly has no useful failure mode.

v1 derivation from the feat's trust tier:

- **standard** tier → all hostcalls (`run`, `prompt`, plus the always-on three).
- **extra** tier (untrusted) → `{say, stream, done}` only, and the guest is
  spawned with a **stripped environment**.

The mask is a **policy gate, not containment**: a guest denied `run` still sits
inside its Landlock/seccomp jail. Denials are loud and attested — a structured
`error` frame **plus** a transcript line — never a silent drop. The mask
*enables* delegation-narrowing (a parent agent hands a child a strictly
narrower mask), though inheritance is not yet wired: today caps derive from
tier alone.

## 3. `run` semantics

The command executes in a **forked subshell child** — the same
parser/evaluator/sandbox/fd-3 trace as everything else, but a **snapshot**: it
sees the shell's live state (cwd, vars, functions) at call time, and its
mutations do **not** propagate back. The child:

- runs in its **own process group**, with **no** controlling terminal,
- reads stdin from `/dev/null` — a tool-call **never** reads the user's
  terminal,
- has its stdout captured to an unlinked temp file (returned in `result.out`).

Execution is **lockstep**: one `run` in flight per session. A second `run`
before the first's `result` is refused `busy`. In the async host the child's
`pidfd` joins the input poll set, so the prompt stays live while a tool runs;
`Ctrl-C` at the prompt edits the line and does **not** kill the tool child
(`session kill` is the kill switch).

## 4. Lifecycle

```
host                                  guest
  │  spawn (pipe pair, CLOEXEC)          │
  │ ───────────  hello  ──────────────▶  │   caps announced
  │                                       │
  │ ◀───────────  run  ───────────────   │   intent
  │  fork child, execute, capture         │
  │ ───────────  result  ─────────────▶  │
  │                                       │
  │ ◀───────────  prompt  ────────────   │   intent
  │  park question (state → awaiting)     │
  │ ───────────  event  ──────────────▶  │   human/agent answered
  │                                       │
  │ ◀───────────  say / stream  ──────   │   output (sanitized, §6)
  │ ◀───────────  done  ──────────────   │   end
  │  reap (WNOHANG, then SIGKILL)         │
```

Two hosts, one protocol:

- **async** (interactive shell, stdout is a tty): frames are serviced from the
  line editor's input poll — the prompt stays live between frames. A `prompt`
  parks as a pending question answered with `session answer`.
- **sync** (`zish -c`, scripts, command substitution — stdout not a tty): a
  blocking loop services frames until `done`/EOF. A `prompt` is answered
  `cancelled` — nobody is there to ask.

Discriminator: `shell.running and isatty(stdout)`.

## 5. The control channel (out-of-band)

Frames flow over the session's own pipes. Two commands arrive **out-of-band**,
over a per-session control FIFO (`~/.zish/sessions/<hostpid>-<id>.ctl`), so any
process on the machine can drive a session it did not spawn:

| command | shape | effect |
|---------|-------|--------|
| `answer` | `{"t":"answer","text":"<answer>"}` | deliver the human/agent answer to a parked `prompt` (host emits the `event` to the guest) |
| `kill` | `{"t":"kill"}` | end the session; the host tears down its own table, transcript, and registry record |

These are how `session answer` / `session kill` work from a **separate**
process (a Claude Code / IRC front-end, an agent answering a sibling agent).
The host owns teardown — a remote `kill` *asks* the host, it never signals the
guest pid directly.

## 6. Hostile-input discipline

The guest is untrusted. The host enforces:

- **Every guest byte that reaches the terminal passes through the sanitizer**
  (`sanitize.zig`) — no raw ANSI/OSC ever. Echoed lines carry a zish-drawn dim
  `[id:name]` provenance prefix the feat cannot forge (its own SGR is stripped).
- **Frame lines are capped** (`MAX_FRAME`); an oversized line ends the session.
- **Writes to the guest are bounded** by a poll timeout; a guest that stops
  reading its stdin is killed, never waited on.
- **`done`/EOF is end-of-session by protocol**: the child is reaped `WNOHANG`
  and `SIGKILL`ed if it lingers — never a blocking `waitpid` on an untrusted
  child.
- **Session pipe fds are `CLOEXEC`**; a tool child never inherits a handle it
  could use to forge frames.

## 7. Wire frames vs. transcript events (do not confuse them)

The **wire frames** above are the live protocol. The **transcript** is a
separate, append-only JSONL **event log** per session
(`~/.zish/sessions/<hostpid>-<id>-<name>.jsonl`) — a durable record, not a
protocol. Its event vocabulary is richer and file-only:

    start · say · stream · run · result · prompt · answer · denied · note · usage · end

`usage` records one turn's cost as a **delta** (`{"t":"usage","in":N,"out":N}`),
because an append-only log records what happened and a ledger is the sum of it;
the `end` line carries the session's cumulative totals in the same shape, so a
transcript read after the fact yields the cost without summing. The registry
record survives the session for `ENDED_META_TTL_SECS` with `state: "ended"` and
those totals — otherwise a commander that was not polling at the instant a
worker finished would lose the only pointer to its transcript.

Every value is JSON-escaped, so `cat`-ing a transcript is terminal-safe **for
free** (an ESC control byte is stored as the literal six-character escape
`\u001b`, never a raw ESC byte) — no
sanitizer pass is needed for the file; the sanitizer guards only the live
terminal-echo path. A session **re-renders by replaying its log** (resume). The
registry (`*.meta`) and this log are what make `session list` and transcript
reading work from any process. See the read-side fold in `gf status` and
`session list` for consumers.

## 8. Versioning

`hello.proto` is the version seam. v0.1 = say/run/prompt/done + result/event;
v0.2 added `hello` (capability announcement) + `error`; v0.3 added pidfd tool
children and real exit codes; v0.4 added `usage` and the retained `ended`
registry record. `usage` is additive and ignorable in both directions, so it
needs no proto bump: an old host ignores the frame, and an old guest simply
never sends one. The vocabulary is intended to stay small: if a
new feature needs a **new frame type**, be suspicious — `run` plus a new feat
is almost always the answer instead (see [philosophy.md](philosophy.md) §5).
