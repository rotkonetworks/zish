# zish agent armor — preliminary plan (uncommitted, pre-compaction seed)

> **Naming (2026-08-31, user):** the subsystem is the agent **armor**, not
> "harness". A harness is strapped on to control from outside; armor is what the
> agent *wears* — sandbox, attestation, staging as protective equipment, both
> ways (human shielded from raw capability; agent shielded by attestation).
> "Harness" below survives only where it refers to *other* projects' harnesses.

Status: **planning only, nothing built.** Written before a context compaction so the
next session starts with the map, not a blank page. Release **v0.19.0** is already cut
and pushed (tag `v0.19.0`, CI building artifacts). Do the deep research + design
AFTER compacting; this file is the brief.

## The frame — read first (normative; after two Fable consults + the Finagle lens)

This reorders the priority the 11 decisions below imply. **Three structural
invariants are the top of the design** — enforceable, red→green testable,
CLAUDE.md-grade. Everything else serves them.

1. **One attested executor.** Every action — human keystroke, agent tool-call —
   passes through the single executor under the active sandbox profile and is
   logged to the fd-3 trace. Blind to *identity*, parameterized on execution
   *context* (see #2).
2. **Per-exec capability narrowing.** The agent's jail is strictly inside the
   human's: an extra Landlock ruleset + tighter seccomp applied *between fork and
   exec* (only narrows; fail-closed composes). Agent feat gets network; tool-feats
   don't (see #3).
3. **Session-feats emit intents, never bytes; receive events, never keystrokes.**
   A session-feat cannot write terminal control; zish draws all chrome (the
   render-intent inversion).

**The membrane is EXPLANATORY, not an invariant — it overclaims (Fable).** Good
pedagogy: zish is the reindeer, metabolizing untrusted capability so the human
never eats it raw — capability→sandbox, bytes→intents, actions→attested executor.
But it filters **delivery and authority, not meaning.** What passes through RAW —
the leak list; never let anyone infer "passed the membrane ⇒ contained":
- **Semantics / prompt-injection** — model words, poisoned tool output, a backdoor
  in a beautifully-rendered diff arrive semantically raw. Worse, zish's trusted
  chrome *launders authority* — it vouches for hostile content. → intents MUST
  carry visible **provenance** (which feat, which tier).
- **Outbound to the model API** — everything a tool reads (files, env, secrets)
  flows to the provider unfiltered; Landlock can't see inside HTTPS. Exfiltration
  is the unmetabolized channel.
- **Filesystem side-channel** — bytes the agent writes to disk are read later raw;
  #9 reopens at the file.
- **Command strings** — the run-command tool executes text the model composed; the
  sandbox scopes *where*, not *what*. `sed -i` via run-command bypasses the diff
  gate (#8).
- **Printable spoofing** — Unicode box-drawing can fake chrome even after SGR/OSC
  stripping; mitigate only with non-reproducible chrome regions.
- **`--describe` descriptors** — inject into the model's tool list as text
  (extra-tier feats are hostile per feat-spec §1.3).
Honest one-liner (carries its own caveat): *"The shell is the membrane between
untrusted capability and the human: capability is sandboxed, bytes become intents,
every action is attested — but meaning passes through; the membrane filters
delivery, not truth."* **The reindeer removes the toxin, not the trip. The drinker
still trips.**

**Two-regime rule (caps the render-vocabulary straitjacket — state it explicitly).**
- *Intent regime* — session-feats (agent, picker, git-UI, form) emit the closed
  vocabulary {stream, list, diff, prompt, status, buffer}; zish renders. Styled
  text = a small closed set of *semantic* tags (code-span, emphasis, add/del),
  never raw SGR or feat-chosen color.
- *tty-handover regime* — anything needing cell-level control (vim, htop, ssh,
  curses REPL, a high-rate monitor) is BY DEFINITION not a session-feat; it runs
  as a normal foreground child through `foreground.zig`, exactly as today.
Anything past the catalog goes to the other regime — the structural cap on
vocabulary growth. **Watch the `buffer` intent hardest**: it is the escape hatch
that reopens #9, and its very name is emacs seduction.

**Extension rule (state it before contributors reintroduce the raw mushroom).**
The only extension points are (a) **new feats** and (b) **new intents** (versioned
vocabulary, implemented in zish, hand-reviewed like core). **NEVER** feat-supplied
code, keymaps, or hooks. Framing: *emacs's uniformity of interaction grammar,
Unix's separation of processes* — not "emacs on a sandbox," which licenses in-band
programmability sprawl.

**The compositional spine — Finagle, "Your Server as a Function" (Eriksen 2013).**
feat = **Service** (`Args ⇒ Future[Result]`); a membrane layer = **Filter**
(`(Req, Service) ⇒ Future[Rep]`, composed `andThen`); a forked child awaited on its
pidfd = **Future**; Ctrl-C / ACP-cancel = **Interrupt** (advisory, flows opposite
the data — this is the shape for #7's cancellation state machine). #2's "blind to
identity, parameterized on context" = *different caller → different Filter stack,
same core Service*; write the filters once (`narrowSandbox`, `attest`,
`captureStdio`, `pollableWait`, `sanitizeIntents`) and compose per context. #1's
one-seam symmetry = Finagle's client = server = Service (their 4-line HTTP proxy is
the proof). The runtime is **the kernel**: Finagle:JVM :: emacs:Lisp :: pi:Node ::
**zish:kernel** — same "server as a function," but with the process isolation the
shared-image runtimes structurally can't have. Finagle *predicts the leak list*:
Filters are "application-independent" by design — they scope authority, never
inspect meaning. The membrane filtering delivery-not-truth is not a limitation to
fix; it is what a Filter IS. Honest limits: composition is coarse-grained (a
Future = a `fork`, not a 16-byte heap cell — don't make every sub-step a process);
session-feats are Services-over-a-session (stateful — purity leaks exactly where
meaning does); cancellation gets its *shape* from interrupts, not a finished
machine (Fable's states still need enumerating).

## The task (user's words, paraphrased)

Bring an **agent armor back** to zish, integrated with the shell's own feats and
line editor (vim keys etc.), and improved with ideas taken from
`https://github.com/xai-org/grok-build`. Make it, first-principles (hdevalence),
**better than anyone else's**. Requires tremendous research first.

## Locked decisions (design frame — settled this session)

These resolve the "invariant tension" below rather than just flagging it. The
design work starts from here.

1. **One seam, not two features.** "zish used by an agent" and "an agent used in
   zish" are the same mechanism from opposite ends: one side *drives*, the other
   *executes*, across one small versioned stdio session protocol. Do NOT build a
   separate "agent mode" and "feat mode" — build one seam and let either party
   (human / editor / CI on one end; the agent feat in the middle; zish as
   executor on the other) sit on either end. grok-build's real lesson: one
   protocol, N front-ends — pushed one step further (the driver of the agent and
   the executor of its tools are both just endpoints on the one seam).

2. **Single executor, blind to IDENTITY, parameterized on execution CONTEXT
   (rewritten after Fable consult — the original "blind to caller / same
   foreground path" was a latent contradiction with #7).** The naive version —
   route every command, human or agent, through the same `executeCommandInternal`
   → `foreground.zig` path — DOES NOT WORK: `foreground.Session.reap()` blocks in
   `waitpid(W.UNTRACED)` with SIGINT ignored, so the instant an agent tool-call
   enters it the #7 poll-multiplex ceases to exist (no rendering, no vim nav, no
   Ctrl-C, pipe fills → deadlock). And the foreground tty-handover dance
   (`Session.begin` cooks the tty; `setupChild` `tcsetpgrp`s the terminal to the
   child) is actively WRONG for an agent child: it would cook the terminal out
   from under the user's live vim edit, deliver their keystrokes to the tool-feat,
   and register the tool in the *human's* job table.
   **The real invariant is narrower and true:** every execution — human keystroke,
   agent tool-call — shares the same *parser, evaluator, authority boundary
   (active sandbox profile), and fd-3 attestation*. It does NOT share fd plumbing
   or wait discipline. The executor is blind to *who* asked but explicitly
   parameterized on an **execution context** = {terminal claim, stdio wiring,
   state isolation, wait mode}. This parameterization already exists structurally
   in the code as `is_foreground` / `forked_child` / `ttyFd() == null`.
   - **Human keystroke** = {claims terminal, inherited stdio, blocking wait} → the
     foreground dance, unchanged.
   - **Agent tool-call** = {NO terminal claim, captured stdio into the result
     frame, state-isolated, POLLABLE wait via `pidfd_open`} — a non-terminal child
     waited *in the poll set* (verified: seccomp denylist blocks only
     `pidfd_getfd`, not `pidfd_open`). Agent executions NEVER enter the foreground
     dance and never touch the job table.
   The forbidden thing is still forbidden — the executor must not branch on
   *identity* — but it legitimately dispatches on *context*, and that is not the
   same lie.

3. **Agent is a principal, not an authority — WITH a real mechanism (Fable: the
   original had none).** It can only *request*; zish decides and executes. The gap
   the consult found: `--profile` is applied ONCE at zish startup and inherited by
   everything, so as first stated the agent's jail would *equal* the human's — a
   sentence, not a property. **Mechanism to build:** per-exec capability narrowing
   — stack an additional Landlock ruleset + tighter seccomp filter *between fork
   and exec* of the agent feat and of each tool-feat (both can only NARROW;
   fail-closed composes). Plus a capability ASYMMETRY the single-profile model
   can't express and must: the **agent feat needs outbound network** (model API)
   while **tool-feats emphatically must not** (check kernel floor — Landlock net
   rules need ABI ≥ 4). This is the differentiator done properly: zish is
   simultaneously the sandbox and the tool-runtime, jailing each principal by
   construction — but only once per-exec layering exists.
   **Secrets channel (named here, was missing):** the model API key must reach the
   agent feat and NOTHING else — never via the environment (that leaks into every
   child; the exported-flag audit exists precisely to stop this), invisible to
   tool-feats, and absent from the fd-3 trace. Deliver it via a dedicated inherited
   fd or a key file readable only under the agent feat's Landlock scope.
   **Self-extension bypass to close (applies to the SINGLE agent, not just a swarm):**
   if the agent can author feats (#6 self-extension), its write jail MUST
   structurally exclude the zish binary AND the feat registry / `$ZISH_FEAT_PATH` —
   else "write a new feat" degenerates into editing the membrane itself (hot-patch
   the executor / register a rogue intent) = full bypass. Corollaries: an
   agent-authored feat lands as *proposed* / extra-tier (never auto-run); `feat
   install` is a HUMAN gate; no-shadowing enforced at install (an agent-authored
   feat named `rg` is an attack); its `--describe` descriptor gets extra-tier
   hostile-input treatment. Rule: the agent may *propose* intent/executor changes
   (as a `diff` intent through the review gate) but never *enact* them from inside —
   propose yes, apply never.

4. **ACP: v1 on the wire now, v2-shaped internals, v2 as a versioned upgrade
   (revised after Fable consult — supersedes the earlier "v2-direct" call).** The
   consult's decisive point, grounded in this codebase's own culture: the testing
   bar here is *differential against an external oracle* (`same_as_bash`). A draft
   protocol where WE write both endpoints AND the conformance client has no oracle
   — the tests only check our own reading of a moving spec; we couldn't tell "our
   code is wrong" from "our draft-reading is wrong." **v1 HAS an oracle: Zed.**
   So: ship `protocolVersion: 1` on the wire in v1 (Zed becomes our free protocol
   `same_as_bash`), but build the *internals* session-first / v2-shaped
   (sessions first-class, usage accounting, capability nesting) so the eventual
   upgrade is a thin wire adapter, not a rewrite. Keep the version integer
   negotiable; flip the wire to real v2 only once a second implementation that
   isn't ours exists. The own-built stdio client still ships — but as a SMOKE
   HARNESS, not an oracle (it is not, and the earlier framing wrongly called it
   one).
   **AMENDMENTS (Fable, on the render-intent repositioning — see the frame):**
   (a) ACP moves to the agent feat's OUTWARD edge; the universal zish↔feat seam
   becomes the small zish-native render protocol. Net-better (blast-radius: if the
   v2 draft moves, only a leaf adapter changes, never zish's core). (b) Recover the
   ecosystem-ingress lost by not speaking ACP directly: factor the adapter into a
   generic **`acp-bridge` feat** that adapts ANY ACP agent into a render-intent
   session — "one reusable adapter," not "two protocols welded in one binary," and
   it keeps the third-party-ACP-agent door open. (c) The render seam is now the
   load-bearing protocol and **has no external oracle** (the v1 shim only tests the
   agent's outer face). It needs its own conformance story: per-intent pty coverage
   + versioned golden renders, in the `same_as_bash` spirit. (d) Sequencing tension:
   the repositioning presupposes the render protocol as universal seam, but the
   two-users discipline says don't design that protocol until a second session-feat
   (the picker) forces its shape. Resolution: repositioning is the working BET;
   keep "ACP-at-the-outer-edge" as a live FALLBACK until the picker exists; do NOT
   write "the universal seam" into CLAUDE.md until it has its two users.

5. **Minimalist, not frontier-scale.** Core = a dumb turn loop + a small tool set
   + the ACP core methods (initialize / session-new / prompt / update / cancel /
   request_permission). CUT, explicitly: personas, "meetings," bulletin board,
   `agent bench`, in-process threads + busy-poll drain (old zish); the
   goal-supervisor sprawl, regex-scraping model prose to fight premature stop, and
   protobuf/gRPC/daemon layering (grok-build). Keep old zish's one clean thing:
   the `agent exec [-p] <query>` headless grammar + JSON footer + TTY-aware plain
   mode.

6. **Tools ARE feats — RESOLVED (via `earendil-works/pi`).** The agent's tool
   surface = the shell's capability surface (feats + builtins zish already execs).
   No plugin ABI, no separate tool registry, no bespoke manifest: adding a tool =
   installing a feat, contained by the same sandbox and logged to the same trace.
   pi split cleanly along our invariant: **keep pi's tool *interface shape***
   (`{name, description, JSON-schema params}` → run → `{content, terminate?}`),
   **reject pi's *loading mechanism*** (pi loads extensions as trusted in-process
   TypeScript — the exact opposite of our fail-closed / no-ABI rule). Carry the
   shape over stdio instead of a module boundary: a tool is a feat that reads a
   JSON args frame on stdin and writes a `{content, terminate}` frame on stdout.
   The open sub-question ("how does the agent discover/describe feats to the
   model?") is answered: **the feat self-describes** — a `--describe` convention
   (extend `docs/feat-spec.md`) emits its `{name, description, JSON-schema}`
   descriptor; the agent reads descriptors to build the model's tool list.
   Also steal from pi: the `{content, terminate}` result shape and the
   "stop only when *all* batch results terminate" loop-stop; the context pipeline
   (UI-only message types that never reach the LLM); the compaction recipe
   (reserve tokens + keepRecentTokens tail + summary entry + rebuild). Do NOT
   need pi's userland permission hooks for *containment* — that is the sandbox
   (structural), which is exactly what pi punts to its host. BUT note (Fable): the
   sandbox cannot express "writes to this path are allowed but the human reviews
   them first" — so *mutating* tool-feats do NOT write directly; they route
   through the staging layer in #8. "Tools are feats" holds; a feat that edits
   proposes into staging rather than touching the live tree.
   **AMENDMENT (Fable — write it or the gate silently evaporates): the edit tool
   is PROTOCOL, not PROCESS.** For diff-review to be a *gate* and not a
   retrospective display, the edit path cannot be a feat that writes. It is: agent
   emits proposed edits as a `diff` intent → zish renders → human accepts → **zish
   (the runtime) applies via the executor** — a runtime response transformation,
   not a downstream Service call. Hard caveat: this gate covers only *cooperative*
   edits; the agent can still mutate via the run-command tool (command strings are
   raw model output). **Diff-accept is a UX affordance; the sandbox remains the
   only containment.** Do not mistake the review gate for a security boundary.

7. **Agent = headless feat; zish = the vim-native rendering front-end — DECIDED
   (the keystone).** The agent feat runs the model loop ONLY and speaks ACP (v1
   wire per #4) over stdio; it **never touches the terminal**. zish is the
   front-end: it owns the terminal, renders the agent session (streaming text,
   tool-call cards, diff view) through the hardened single-threaded
   `render_pipeline`, and its EXISTING vim line editor handles the human's input.
   zish's run loop `poll()`s over `{stdin, feat-stdout, tool-child pidfds}` — no
   thread, no busy-poll (that in-process-thread + busy-poll drain was the root
   cause of the old agent's bad rendering; a separate process + single-threaded
   poll-multiplex removes it). NB the poll multiplex only survives contact with
   the executor because of #2's amendment: agent tool-children are POLLABLE
   non-terminal children (`pidfd_open`), NOT blocking foreground `reap()`s.
   **Why a feat and not a standalone TUI binary:** a feat *is* a binary — the SAME
   binary doubles as a standalone CLI for CI / non-zish use (one core, N
   front-ends). But a *standalone TUI* owning the terminal would have to
   reimplement vim and sit outside zish's sandbox — throwing away the two things
   uniquely ours.

   **Product wedge — RE-RANKED after Fable consult (vim-navigation was ~60%
   rationalization).** A standalone vim-bound TUI gets scroll/jump/expand-collapse
   cheaply; "competitors can't do this" was false at the 90% level, and the
   vim-navigable transcript is simultaneously the single most EXPENSIVE line item
   (see cost below) and the one whose flagship gesture depends on #8. So demote
   "vim-navigable" from headline to **corollary**. The actual moat — which *does*
   require this architecture — is three things:
   (a) the **attested, by-construction jail** (tools through the fork/exec
   chokepoint under inherited+narrowed Landlock/seccomp with an unforgeable fd-3
   trace);
   (b) **live shell-state integration** (the agent operating in your REAL session
   — cwd, vars, functions, jobs — not a parallel world);
   (c) **one input grammar** (same editor, keybindings, completion for talking to
   the agent and to the shell — zero mode switch).
   Those are the defensible wedge; the vim-navigable session is a nice corollary on
   top of (c).

   **Cost — honestly re-priced (Fable: underpriced ~2-3×).** "Scroll / jump /
   expand-collapse" means zish owns a **viewport with a retained document model —
   a pager, not a line renderer emitting into scrollback.** Once content scrolls
   into the terminal's native scrollback you cannot collapse or re-render it, so
   the choice is: take the **alternate screen** (and lose the "inside your shell"
   feel + native scrollback + tmux copy-mode) OR maintain a **windowed redraw
   region** (a subsystem on the order of the line editor itself). Plus a named
   **cancellation state machine** (states: idle / streaming / tool-running /
   cancelling / draining) — Ctrl-C in raw mode arrives as 0x03, zish decides:
   send ACP `cancel`, kill the in-flight tool-child pgroup, keep draining
   feat-stdout until the feat acks (cancel is async; queued tokens still arrive),
   render the truncation. This is NOT "the same discipline as a fresh foreground
   child"; enumerate the states or discover them as pty bugs.

8. **Writes go through a zish-owned staging layer — BUILD IT NOW (user decision;
   resolves the #6 ⊥ #7 contradiction Fable found).** A mutating tool-feat cannot
   write to the live tree, because #7's review gate ("accept/reject diff hunks")
   can't reject an already-applied write. So: mutating tool-feats **propose** edits
   into a **zish-owned staging area** (a worktree / overlay); the proposed diff is
   rendered in the front-end; **accept** applies it to the live tree, **reject**
   discards it. The staging owner is zish (not the feat, not the sandbox) — this is
   a deliberate, small userland approval layer that the sandbox structurally cannot
   provide (the sandbox bounds *where* writes may go; staging bounds *when* they
   land). Chosen over "v0 read-only, staging later": the vim-diff-accept gesture
   ships in v1 rather than being deferred. Concrete open choice for design: overlay
   dir vs `git worktree` for the staging tree; must detect mtime drift if the user
   edits a staged file mid-turn (see #11).

9. **Rendered text and feat descriptors are HOSTILE INPUT (named subsystem; was
   missing).** Model output and tool stdout are painted onto the user's terminal —
   unsanitized they carry ANSI/OSC that can clobber the terminal or, worse, **spoof
   zish's own UI chrome** (a forged "hunk accepted" card is a social-engineering
   attack directly on #8's review gate). Escape-sequence sanitization of all
   agent/tool-rendered text is a required subsystem, not polish. Same discipline
   for `--describe` (#6): a feat's descriptor feeds the model's tool list verbatim
   → a prompt-injection channel, and extra-tier feats are "explicitly untrusted"
   (feat-spec §1.3). Apply the spec's "manifest is hostile, read only N fields"
   rule to descriptors: size caps, schema validation, and tier-gating of which
   feats the agent may even *see*.

10. **Agent-feat lifecycle + session/history ownership (named; was missing).** The
    agent feat is a long-lived child unlike anything zish manages today. Decide:
    is it in the job table (probably NOT — see #2)? Who reaps it on a mid-turn
    crash, and is context lost (→ needs incremental persistence)? On shell exit —
    SIGHUP or persist-then-detach? How does a user's own foreground job coexisting
    with an agent tool-child interact with the pgroup story? And **who owns the
    transcript**: ACP `session/resume|list` implies the *feat* persists sessions
    (where, under Landlock?) and zish **re-renders a resumed session by replay** —
    a protocol requirement, not a nicety.

11. **Concurrent mutation (named; was missing).** The agent edits a file the user
    has open in the vim editor; or the user runs commands mid-turn that change cwd
    between the agent's tool-calls. Minimum viable answer: **snapshot cwd/env per
    turn** into the tool execution context, and **detect mtime drift** on staged
    diffs (#8) before applying. Just needs to be designed, not discovered.

## AMENDMENT 2026-08-31 — file/command async surface (supersedes #7's rendering half)

**Decision (user):** the agent surface is **files + an `agent`/`session` command
grammar, async by default** — a shell-like experience — NOT a live interactive
viewport. Rationale: (a) it deletes the plan's single most expensive line item
(#7's retained-viewport/pager — the transcript is a *file*; `tail -f`/`less`/vim
ARE the pager); (b) it makes the armor **natively agent-to-agent drivable** —
every existing harness is interactive-first and needs scraping or a bolted-on
headless flag, while a file/command surface is drivable by anything that can run
commands (plan #1's "either party on either end" made concrete); (c) "one input
grammar" becomes literal: you talk to the agent with shell commands.

**Mental model (user, same day): host/guest.** zish = host, session feat =
guest, the frame vocabulary = the hostcall table (PolkaVM host-functions shape).
`run` is a hypercall into the host's executor (parse→eval→sandbox→fd-3 attest);
`result`/`event` are host returns; the guest holds zero ambient authority — no
tty, no terminal bytes, pipes are the call channel and nothing else. Isolation
boundary is fork+pipes+Landlock/seccomp rather than an ISA, and the hypercalls
land in the user's LIVE shell state (the moat, and the reason the host must
mediate every one).

**Endgame (user, same day): agent-to-agent loops for collaborative goals.**
The design target is not one agent in a shell — it is agents driving agents
(the file/command surface makes every agent drivable by anything that can run
commands), composing toward shared goals under nested jails. Every decision
below is judged against that: does it compose down a delegation tree?

**Hostcall capability mask (decided, user-confirmed): one table, per-session
mask — never tiered tables.** Frame gating and the sandbox govern different
things: the sandbox bounds what a `run` may TOUCH (containment, the only real
security boundary); the mask bounds which CHANNELS to the human/shell the guest
gets at all — claims the sandbox structurally cannot see (`prompt` is human
attention, not a syscall; `diff` is the staging gate, not a file mode).
- One versioned vocabulary for every session; the mask is a field of the
  execution context (plan #2's "parameterized on context" — a Finagle filter
  per caller, not a second protocol). Separate tables = vocabulary drift.
- Mask derives from feat tier + user config; a feat may REQUEST LESS, never
  more (narrowing composes, fail-closed). v1: extra tier → {say,stream,done};
  standard → +run +prompt.
- Denials are LOUD and attested: structured `error` frame back to the guest +
  a transcript line — never a silent drop. The trace can attest what a session
  was allowed, not just what it did.
- Announced at session start: zish sends a `hello` frame ({proto, caps}) so a
  guest knows its world up front and can degrade instead of probing by denial.
- Agent-to-agent payoff: a parent spawning a child session hands it a strictly
  narrower mask — delegation narrows authority monotonically down the tree,
  mirroring Landlock nesting one layer up. (NOT yet wired: v1 derives caps
  from tier only; mask inheritance across nested launches is a later slice.)
- Guard-rail: the mask is a POLICY gate, not containment (same caveat as
  diff-accept). A guest denied `run` still sits inside its Landlock jail; the
  layers back each other up, never substitute.

**Ecosystem decisions (user, same day): `gf` feat-fetcher + agent as own repo.**
- **`gf <git-url|https-url>`** — a feat that fetches and installs feats (the
  extension model extending itself). Non-negotiables, all inherited from plan
  #3's install discipline: a fetched feat lands in the **extra tier** (untrusted
  by default — stripped env, minimal hostcall mask, feat-spec §1.3 hostile
  treatment); promotion to standard is a separate deliberate HUMAN act;
  **no-shadowing enforced at install time** (a fetched feat named `rg` is an
  attack); manifest read as hostile input (N known fields, size caps). Later:
  commit pinning (`gf repo@sha`), signatures.
- **Agent feat splits into its own repository** once the model-loop slice
  starts. The frame protocol becomes the ONLY coupling (enforced by the repo
  boundary itself); the `hello.proto` field is the version seam. The protocol
  spec is normative in the zish repo (extend docs/feat-spec.md); the agent repo
  pins a version and degrades gracefully.
- **The key composition:** the anticipated "agent grows its own plugin system"
  pressure is exactly what plan #6 routes into feats — the agent's tool surface
  IS the feat ecosystem, reached through `run`. gf makes that practical: agent
  needs capability X → *proposes* `gf <repo>` → human gate installs it
  extra-tier → new tool available through the same attested executor. The
  agent repo stays small; extensibility lives in sandboxed feats, never an
  in-process plugin ABI (the pi lesson — that rejection binds the agent too).

**Open idea, NOT locked (user pondering, same day): distro packaging as a
trust channel.** Feats in AUR on top of zish defaults; zish editions as
meta-packages (minimal/agent/full). The interesting part: the channel becomes
the provenance signal — distro-packaged (maintainer-vetted) feats could default
standard tier, gf-fetched default extra; would need a feat search path (system
dir → ~/.zish/feats) replacing the single featRoot. Revisit when gf exists.

**Layering (user, same day):** a rendering front-end is NOT abandoned — it comes
back later as a *view over the files*. The transcript + session state are the
single source of truth; a live follow view / vim pager / full intent renderer
renders FROM them and is optional and replaceable (CI and agent-to-agent run
viewless). Resume/replay (#10) falls out for free: re-rendering IS reading the
file. Build no renderer until the substrate is proven.

Consequences:
- Interactive `status`/`prompt` render intents are DROPPED. `prompt` becomes a
  **pending-question state** on the session + a `session answer` command; agent
  output appends to a **sanitized transcript file** and echoes above the prompt.
- zish sanitizes at transcript-WRITE time (single chokepoint), closing the
  terminal-escape half of the filesystem-side-channel leak (`cat transcript` is
  safe; semantic injection still passes — the membrane filters delivery, not truth).
- Session feats are hosted **async when interactive**: the line editor's input
  poll multiplexes `{stdin} ∪ {session fds}`; frames are serviced between
  keystrokes. Non-interactive (`zish -c`) keeps the blocking host.
- **Known v1 limitations (accepted, named):**
  - Servicing a `run` frame executes the command synchronously inside the input
    loop — prompt/rendering/Ctrl-C are dead until it returns. Fine for fast tool
    calls; a slow command freezes the shell with no escape. The fix is plan #2's
    real design — pidfd-pollable tool-children in the poll set — and is the
    NEXT slice, not optional hardening.
  - `$(session-feat)` inside command substitution while interactive: forced back
    to the sync host when detectable, else documented wart.
  - A hostile feat that closes stdout without exiting is SIGKILLed (done/EOF is
    end-of-session by protocol; fail-closed, never a blocking waitpid in the
    interactive loop). Session `run` children get stdin = /dev/null — an agent
    tool-call NEVER reads the user's terminal (#2: no terminal claim).

## The invariant tension — READ THIS FIRST

CLAUDE.md and project memory **explicitly forbid** re-adding agent / inference /
persona / voice code, GPU shaders, or a plugin ABI. That prohibition was correct and
must not be blindly reversed. It was aimed at a specific mistake: **an LLM + GGUF
model runtime embedded IN the shell process**, which forked constantly while holding
inference threads (fork + live threads = deadlock) and turned the thing that executes
commands with the user's full authority into a model runtime.

**Resolution (the hdevalence line to hold):** the agent comes back as an **external
armor: an external agent the shell wraps and sandboxes — a feat / separate binary**, NOT embedded
inference and NOT threads in the interpreter. This keeps every current invariant:
- single-threaded execution core (concurrency stays process-level: fork/exec)
- capability lives in feats, contained by the sandbox
- shell owns terminal + signal state by construction

If we build it this way we are *extending* the documented model (feats + sandbox),
not violating it. Before writing code, update CLAUDE.md + memory to record the
refined position deliberately, so the next agent doesn't "helpfully" delete it as
forbidden dead code.

## Git archaeology — where the old agent lived, what to salvage

Removal commits (oldest agent → gone):
- `6850931` move --exec to agent subcommand: `agent exec -p persona query`
- `2d817c8` lazy agent thread, ShellDrainHandler, resource monitoring, hardening
- `227c478` `agent -m <path>.gguf` runs local GGUF inference
- `3fe5263` agent: route local/ollama models instead of 404'ing on Anthropic
- `ca321b7` **remove the heavy Claude-API agent (execution layer)** ← main removal
- `038f55d` trim inference to the ghost-text set; drop orphaned router
- `07fcadd` drop inference, audio and dead modules; replace clap with src/cli.zig
- `4ae1e34` trim agent_log to the shared config loader
- `9cf6610` delete personas.zig
- `993b18e` delete dead interactive code incl. agent stragglers
- `ef86a03` delete dead compat/types/git code (inference-era leftovers)

To read the old design: `git show ca321b7`, `git show 6850931`, and
`git log -p --all -- '*agent*' '*persona*'`. **Salvage** the wire/loop shape and the
subcommand UX; **do NOT** salvage embedded GGUF/Vulkan/CTM/router/threads.

Infra that ALREADY exists for exactly this (don't rebuild):
- `3730bca` sandbox `--allow-write` was added **"so an agent harness can be wrapped"**
- `--profile` Landlock (`sandbox.zig`) + seccomp denylist (`seccomp.zig`), inherited
  across exec, fail-closed
- fd-3 structured session trace (`trace.zig`), relocated + CLOEXEC, unforgeable —
  attests what actually ran
- feat spec (`docs/feat-spec.md`): fork+exec+argv+stdio, no plugin ABI

## Ideas worth borrowing from grok-build (Rust TUI coding agent)

- **Decouple agent logic from I/O**: one runtime, three front-ends — interactive TUI,
  headless (scripting/CI), editor-embed via **ACP** (Agent Client Protocol). zish's
  analogue: the agent feat speaks a small stdio protocol; the shell is one front-end,
  `zish -c` / CI is another.
- **Composable tool crates** (terminal, file-edit, search) — map each tool to a
  zish feat or builtin so the agent's tool surface IS the shell's capability surface.
- **Workspace with execution + checkpoints** — persist agent steps for recovery and
  auditability. zish already emits the fd-3 trace; extend it into a checkpoint log.
- **MCP servers** for extensibility — a feat could bridge MCP.

## Why zish can be genuinely better than anyone (the differentiator)

No other agent harness *is the shell that is simultaneously the sandbox and the
tool-runtime*. zish is the fork/exec chokepoint, so it can bound the agent **by
construction**: Landlock inherited across exec, seccomp denylist, an unforgeable fd-3
attestation of every command. The agent runs inside an **attested, capability-scoped
jail it cannot escape**, driving the same vim-key line editor and feats a human uses.
That is the thesis (a Fable red-team earlier this session already converged on
"build the attested capability-scoped agent jail substrate" as the durable idea).
Per-user zish trust levels (different ssh users → different shell capabilities) fit
here too.

## Proposed architecture sketch (to be pressure-tested post-compact)

```
  human / ACP client
        │  stdio protocol (small, versioned)
        ▼
  zish (the shell)  ──fork+exec──►  agent feat (separate binary, sandboxed)
   owns: tty, signals,                owns: LLM API calls, planning loop
   line editor (vim keys),            tools = { run cmd in zish, edit file,
   sandbox profile, fd-3 trace                 search } each via feat/builtin
```
- Agent never embeds a model; it calls a remote API (or a local server it execs).
- Every tool action the agent takes is a command routed back through zish → subject
  to the active `--profile` sandbox + logged to the fd-3 trace.
- The vim-key editor is exposed so the agent can drive interactive edits the way a
  human does, not via a separate code path.

## Research plan (do AFTER compacting)

1. Read grok-build's actual crates (clone or fetch raw files): `xai-grok-shell`
   (leader/stdio/headless entry points), `xai-grok-tools`, `xai-grok-workspace`
   (checkpoints), the ACP integration. Extract the protocol + loop shapes.
2. Read the old zish agent via `git show ca321b7` / `6850931` — recover the
   subcommand UX and wire format worth keeping.
3. Study ACP (Agent Client Protocol) as the editor-embed interface.
4. Fable/hdevalence design pass: model it as states/transitions; define the stdio
   protocol; decide the tool→feat mapping; specify the sandbox posture and the
   checkpoint/trace extension. Adversarial red-team the escape surface.

## Open questions for the user

1. Remote API (Anthropic/xAI) as the default brain, or a local server the feat execs?
   (The old code tried both; embedded GGUF is the part we are NOT bringing back.)
2. ACP support in v1, or stdio-to-zish only first?
3. Scope of v1: read-only "explain/plan" agent, or full edit+exec inside the sandbox?
4. Update CLAUDE.md/memory to record the refined "agent-as-wrapped-feat" position
   before any code — agreed?

## Where things stand in the repo right now

- On `main`, clean tree except untracked: `ask`, `asker`, this file.
- v0.19.0 released. 54 pty / 232 regress / unit all green.
- Fable's Shell.zig architecture review (this session) recommends extracting
  `expand.zig` / `heredoc.zig` / `brace.zig` next — orthogonal to the agent work but
  relevant because a cleaner Shell.zig makes the agent's tool-routing hooks easier.
  (DONE this session: brace/heredoc/expand extracted, Shell.zig 3888 → 1561.)

## Provisional intent-protocol sketch (STRAWMAN — validate with the picker, do NOT lock)

This is the concrete form of the frame's render-intent vocabulary. Per the
two-users rule it is a **strawman to be refined by the second session-feat (the
picker)**, NOT the locked seam — do not write it into CLAUDE.md until it has two
users. Captured here so it survives compaction.

A session-feat never writes terminal bytes: it emits **render intents** (what to
show, never how) on stdout; input returns as **events** (semantic outcomes, never
keystrokes). Two properties do the security work and are *structural*: raw ANSI/OSC
is unrepresentable (no "here are bytes" intent), and keylogging is impossible (a
feat gets interaction *outcomes*, never keys).

Six intents (closed set), each with the events it yields:

| Intent   | Feat sends                              | zish renders                          | Events back |
|----------|-----------------------------------------|---------------------------------------|-------------|
| `stream` | append text chunks to a region          | flowing transcript, reflow on resize  | — |
| `status` | ephemeral state ("thinking…", tokens)   | a status line in zish's chrome        | — |
| `list`   | items + optional schema                 | *the* picker — vim j/k / /, select    | `selected(i)`, `cancelled` |
| `diff`   | proposed edits as hunks                 | review UI — navigate/expand hunks     | `accept(hunk)`, `reject(hunk)`, `accept-all` |
| `prompt` | question + input shape (text/confirm/choice) | input field via the vim editor   | `submitted(text)`, `confirmed`, `denied` |
| `buffer` | a named scrollable text region          | pager viewport, vim motions           | scroll pos, `closed` |

**Extensibility, three tiers** (this is the "how does it grow" answer):
- **Tier 1 — composition (free, no protocol change).** Most new UI is a new *use*
  of existing intents: a git-branch switcher is `list`; a commit editor is
  `prompt`; a tool-call card is `stream` + `status` + a collapsible `buffer`. The
  picker feat and the agent share the same `list` rendering — that IS the "one vim
  grammar across all feats" payoff. (The emacs lesson: one primitive — the buffer —
  composes into most apps.)
- **Tier 2 — semantic styling (constrained markup).** Text carries *semantic* tags
  from a small closed set — `code-span`, `emphasis`, `add-line`/`del-line`,
  `heading` — and zish maps tags→styles per theme. Never SGR, never colors, never
  cursor positioning. This is the line that keeps `buffer` from becoming "a terminal
  with extra steps" (where chrome-spoofing returns).
- **Tier 3 — a new intent (rare, deliberate, expensive on purpose).** Vocabulary
  grows only against real need (two-users rule), implemented IN zish, hand-reviewed
  like core, versioned. **Version negotiation** = a capability list at session
  start: the feat declares which intents it emits, zish which it renders; a feat
  facing an older zish **degrades** (renders its fancy thing as `buffer` text)
  rather than breaking.

**Refused:** no feat-supplied render code, keymaps, hooks, or config language (the
anti-emacs door — in-process authority returning through the UI). The extension
surface is exactly two things: **new feats** (sandboxed processes) and **new
intents** (zish-implemented, versioned). Anything needing cell-level control the
vocabulary can't express is NOT a session-feat — it runs in the tty-handover regime
(vim/htop) through `foreground.zig`. Honest cost: tier-3 iterates slower than "ship
a plugin" — a deliberate trade against spoofing/injection/N-inconsistent-grammars.
