# zish philosophy — does this belong in a shell?

Status: living doc
Scope: the standing test every ambitious addition to zish must pass. An
agent-armor layer has grown *around* zish — but almost none of it is *in* the
shell. The shell core added exactly one thing: a **session-hosting substrate**
(a poll-multiplexed, newline-delimited frame protocol over pipes). Everything
else — the package manager (`gf`), agent inference and review, the reputation
ledger, the eventual economic/chain layer — are **feats** (separate programs
the shell `exec`s) and **text files**. They are extensions, not parts of zish.
That separation *is* the point; this doc is the discipline that preserves it.
The day any of it leaks into the shell binary, it has rotted into an
everything-daemon.

## 0. The question, asked forever

> Considering the Unix philosophy, does this still make sense as an extension
> of a shell?

This is **not a one-time clearance**. It is the McIlroy check every new
capability has to pass, every time:

> Is this a new small program talking text — or am I fattening the one binary?

Ask it on every addition. Keep asking it, and zish stays Unix. Stop asking it,
and it becomes Emacs — the anti-Unix monolith.

## 1. Why a shell is the right host (the reframe)

A shell's **one thing** is composition-of-programs: `exec`, pipe, wait,
compose. Hosting agents is not a *second* thing bolted on — it is the *same*
thing serving a new caller. An agent is something typing commands where a human
used to. By Unix's own definition that is the core job, unchanged, with a wider
set of clients.

The test that this is not squatting: list what the agent layer would have to
**reimplement** if it did not have a shell —

- a command language + evaluator (pipes, globs, redirections, arithmetic)
- fork-based per-call state isolation
- process-group / signal / controlling-terminal management
- a sandbox (Landlock + seccomp), inherited across `exec`, fail-closed
- an event loop multiplexing many child processes without threads
- a language-agnostic extension model

That list *is* a shell. Build the org anywhere else and step one is writing a
worse shell. So the shell is the **cheap** answer, not the arbitrary one.

## 2. The primitives that justify it

The shell earns the execution layer with real, load-bearing primitives:

- **`run` — the universal execution hypercall.** An agent's whole toolbox is
  "run a command through the shell's own parser → evaluator → sandbox → fd-3
  trace." Not "exec a binary" — the full language. One primitive hands the
  agent all of Unix composability. `subprocess.run` cannot give this; you would
  reimplement a shell to get it.
- **Fork-snapshot isolation.** Every `run` forks a child that sees live state
  (cwd, vars, functions) but cannot mutate the parent. Per-call, copy-on-write,
  near-free.
- **The poll-multiplexed event loop.** stdin + session pipes + tool pidfds in
  one loop — single-threaded concurrency without threads (which `fork` forbids).
  The shell already had this to wait for keystrokes; the session host extends it.
- **pidfd-pollable children** — slow tools that do not freeze the prompt.
- **tty / signal / process-group ownership** — the shell owns the terminal by
  construction, so agents-as-processes inherit correct discipline.
- **The sandbox** — Landlock + seccomp, fail-closed, inherited across `exec`,
  plus the unforgeable fd-3 trace. Contained, attested execution as a primitive.
- **Feats as the extension ABI** — `fork + exec + argv + stdio`, no plugin ABI,
  no-shadowing. A capability model that is just "programs on a path."

## 3. The dividing line

The shell provides rich primitives for **execution / containment /
orchestration**, and **essentially nothing** for the reputation / economic /
chain layer. That is the tell that the line is drawn correctly:

- **In the shell (core):** the executor and the poll loop. Spawn, pipe, poll,
  frame, contain, reap.
- **Not in the shell (feats + files + external tools):** LLM inference (a
  wrapped external feat → `curl` → the API, never embedded), reputation (a
  *fold* — a read over text files), the chain (polkagent, called as a tool).

The economic layer does not lean on shell primitives because it does not need
to. It uses the shell as its first execution host and can leave — it is feats
plus an open, package-manager-agnostic protocol. zish is its birthplace and
reference host, not its permanent sole owner.

## 4. The proof-of-extension test

> Delete every agent feat, and zish is still a complete, fast shell.

Nothing in the interpreter depends on the agent layer. That is the difference
between an **extension** and a **mutation**. If deleting the agent feats ever
breaks the shell, the coupling has gone the wrong way and must be undone.

We already **are** more Unix than the mainstream agent frameworks: they are
monolithic in-process objects with tools as function registrations. Ours are
processes; tools are programs; state is text files (`ledger.jsonl` you can
`cat`/`grep`/`jq`); the bus is pipes and `exec`. That is textbook McIlroy.

## 5. The two honest seams (watch these)

Where we are closest to violating the philosophy — named so they are decisions,
not drift:

1. **Protocol creep — not JSON itself.** Newline-delimited JSON (JSONL) is the
   *right* Unix choice for structured agent I/O, not a compromise: it is text,
   it streams one object per line, `grep`/`jq` are its `awk`, and a tool call
   has irreducible structure (command, id, exit code, captured output that can
   itself contain newlines and quotes) that columnar whitespace text could only
   encode fragilely — the quoting-hell that actually violates the spirit. LSP
   (JSON-RPC over stdio) proved the shape. The genuinely un-Unix moves would be
   a *binary* protocol or an *in-process ABI*; we rejected both. The seam to
   watch is therefore not "we used JSON" but the protocol growing baroque:
   dozens of message types, stateful handshakes, ordering dependencies. Keep it
   one greppable object per line and minimal — a protocol that stops being
   line-oriented has started becoming a runtime.

   Evidence it has held: the wire vocabulary is **nine frame types**
   (`hello` / `run` / `say` / `stream` / `prompt` / `done` / `result` /
   `event` / `error`), plus two control-FIFO commands (`answer` / `kill`),
   stable across protocol v0.1 → v0.3. The package manager, agent review, and
   the ledger added **zero** new frame types — `run` is universal, so new
   capability arrives as feats and files, not protocol surface. The day a new
   feature needs a tenth frame type is the day to be suspicious.
2. **Session-hosting-with-capabilities.** "Run a command and wait" is pure
   shell. "Host a long-lived guest, mediate its hostcalls through a capability
   mask" is job control *extended* — the seam where "run and wait" grows into
   "host and mediate." Defensible (an interactive shell already manages
   long-lived `&` jobs it signals and reaps). But it is the piece most likely
   to try to become a *runtime*. If it ever grows logic beyond
   spawn / poll / frame / contain, that is the violation — push it back down.

## 6. The failure mode and the guard

The failure mode is **the monolith**: the day inference, reputation math, or
chain logic is compiled *into* the shell binary, zish is Emacs. It is a live
temptation every time something feels easier to just-put-in-the-core.

The guard is one rule:

> **New capability = a new program + a text file. Never a bigger binary.**

Inference is external. Reputation is a fold over files. The chain is polkagent.
The core stays a shell. Hold that line, keep asking the question in §0, and the
thing stays Unix.
