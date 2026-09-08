# Agent cloud — design notes

Vision: a Hetzner-like service where users run **clusters of agents** on self-hosted
metal — agents that spawn other agents recursively, contained, metered, and bounded
so a tree can't exceed what it was granted. This is the forward design; it builds on
what's already shipped in zish (execution + containment + review/reputation) and in
`~/rotko/hwpay` (payments). Payment integration is deferred — captured here, not built.

Status legend: **[built]** exists today · **[design]** planned · **[steal]** an idea
to borrow from a named system.

---

## 1. Why not the Cloudflare/Workers model

Cloudflare Agents (Durable Objects + V8 isolates) and `@cloudflare/shell` run
**bytecode in an isolate with a *virtual* filesystem** — TypeScript, not native
binaries. That cannot run `pacman`, `makepkg`, `git`: the actual build/AUR workload.
Isolation at the language-runtime layer only holds memory-safe bytecode with no
arbitrary syscalls. A shell's job is `fork+exec` of native code, which **only the
kernel can contain**. Cloudflare themselves shipped *Containers* precisely because
isolates can't run native code — the strongest evidence there's no shortcut.

So the isolation model is dictated by *what* is isolated:

| Tier | Mechanism | When |
|------|-----------|------|
| confinement (per-process) | Landlock + seccomp **[built:** `--profile`**]** | always — the leash on every agent |
| separation (tenant ⊥ tenant) | Unix users → namespaces → **microVM** | by threat model |
| fairness (noisy neighbor) | cgroups v2 | always |

- **Semi-trusted** tenants (own agents): Unix users + zish `--profile` + cgroups.
- **Untrusted/public**: **Firecracker microVM per session**, zish's profile *inside*
  it as defense-in-depth. LLM-driven execution is prompt-injectable, so public =
  microVM.

This mirrors what the incumbents do: Anthropic's Claude Code runs local tools under
**bubblewrap+seccomp** on Linux plus a network-allowlist proxy, the same family as
zish's Landlock+seccomp; their hosted code-exec moves to containers. Nobody found a
shortcut around the kernel boundary for native code.

---

## 2. Execution substrate

- **Tenant = microVM** (Firecracker). Hard kernel boundary; cgroups for fairness.
- **Inside the VM, zish orchestrates.** Agents are processes (fork/exec — the
  single-threaded, process-level-concurrency invariant). Each confined by a
  Landlock/seccomp profile, attested by the unforgeable fd-3 trace. **[built]**
- **Agent-spawns-agent** already exists in embryo: session feats + the run-child FIFO
  routing (agent-to-agent through a shared file). The cluster is that, recursively.
  **[built primitive → design at scale]**
- **Image**: zish + feats compile to **static musl** binaries → image-agnostic, inject
  anywhere. The base image follows the *workload's tools*, not the shell:
  - lean general base — distroless/Alpine-static + static zish + curl; read-only
    rootfs, tmpfs workdir, **no runtime package manager**, digest-pinned.
  - **Arch** base for the AUR/build workload (Alpine literally can't `makepkg`);
    `base-devel` + git + a non-root build user. Heavier boot → use only where needed.
  - musl-vs-glibc is the source-vs-blob split again: static tools love musl; prebuilt
    glibc blobs need a glibc base.

---

## 3. The conservation model (the distinctive primitive)

Recursive agent spawning is a **fork bomb with a credit card** unless one rule holds:

> **Spawning is subdivision, not creation.** A child gets a *slice of its parent's*
> allocation, never a fresh one. Resources are conserved down the tree.

That single rule makes an arbitrarily deep/wide tree safe by construction — total
consumption is bounded by the **root grant**, regardless of depth or fan-out. Three
quantities flow down, split not multiplied:

1. **Token budget** (dominant cost) — children share the parent's *remaining*; the
   root caps the whole subtree's LLM spend.
2. **Compute** — a child runs in a **sub-cgroup carved from the parent's**.
3. **Capability** — a child's Landlock/seccomp profile is **equal-or-narrower** than
   the parent's (attenuation, never amplification). **zish already enforces narrow-only
   inheritance across exec.** **[built]**

Plus a coarse depth/fan-out cap as a dumb backstop. **This is the thing neither
Cloudflare nor Anthropic ships**: a self-subdividing native-execution agent tree that
can't exceed its root grant. Build & prove it as a *local* primitive first (on one box,
with the session feats we have); the cloud is then replication + billing.

---

## 4. Cost/scale patterns to steal

- **[steal: Cloudflare DO] Hibernate idle.** DOs cost nothing when idle. Analog:
  **Firecracker snapshot/restore** — an idle agent is a *paused snapshot*, not a running
  VM. Cost scales with active work, not fleet size. This is the other half of the
  conservation model (conserve budget **and** hibernate idle).
- **[steal: Cloudflare Code Mode] Agent writes a script, not N tool calls.** Instead of
  N tool-call round-trips (N LLM invocations), the agent emits **one shell script** (one
  invocation) that orchestrates many commands. Cloudflare needed a JS sandbox for this;
  **zish runs it natively** — biggest token win here, near-zero impedance. Compounds
  with local models (§7) and the review cache (§7).
- **[steal: Cloudflare sub-agents-as-tools]** child agent invoked *as a tool*, output
  streaming into the parent's timeline; typed parent lookup; nested routing. Borrow the
  protocol shape for recursive spawn. Plus **workflows w/ human-in-the-loop approval** =
  the manual/auto gate, formalized.

---

## 5. Collaboration modes & team structure

Each user runs **multiple simultaneous agents** driven from one chat interface — modeled
on Grok Heavy (Grok 4.20 Multi-Agent), but persistent and collaborative. Two modes, one
substrate; don't conflate them:

**(A) Swarm-on-one-task (the Grok Heavy shape).** Ephemeral, converges to one answer. A
**Captain** decomposes the prompt → **N specialized agents run in parallel** (retrieve /
compute / alternative-framing) → a **debate/critic pass** flags contradictions (where
hallucinations die) → the Captain **synthesizes** only what survives cross-agent scrutiny.
Spun up per hard task, torn down after. A *correctness computation*, not an org.

**(B) Standing team (multi-task).** Persistent agents with roles + a shared **blackboard**,
working a *portfolio* of tasks; the user chats with the **team lead**. An *org*, not a
computation — and a team *spawns* (A)-swarms for individual hard problems. B is the
structure; A is a move B makes.

**Roles** (just agents with different prompts / rubrics / profiles):
- **Captain / lead** — decompose, delegate, synthesize; owns the team's root budget and
  subdivides it (§3).
- **Workers** — specialized producers.
- **Critic — MANDATORY.** Its job is to *refute* the others' output, not produce.

**Substrate (mostly built):**
- **Collaboration medium** — agents already talk agent-to-agent through a shared file / the
  run-child FIFO. **[built]** A team blackboard is a structured version of it.
- **Chat control plane** — `session list / answer / kill` works from *any* process via the
  control FIFO. **[built]** That *is* "drive N agents on different tasks from one interface."
- **UI shape** — sub-agents-as-tools with **streaming child timelines**: the user talks to
  the lead; children's work streams into the timeline. [steal: Cloudflare]
- **Governed by conservation (§3)** — a team can't exceed its root grant; fan-out
  subdivides budget/cgroup/profile, never multiplies.

**Fan-out efficiency — shared prefix/KV cache.** When N agents fan out on the **same
context**, run them against **one local model instance with a shared prompt prefix** → pay
the shared context **once**, hitting Grok's ~**1.5–2.5×-not-N×** curve. *More* achievable
for us than for xAI: we control the local Ollama/llama.cpp instance and prefix caching is
native. Stacks multiplicatively with local-model judging and the review cache (§7).

**The non-negotiable (micay): the critic is load-bearing.** Collaboration *without*
adversarial cross-check is an echo chamber that **amplifies** errors — N agents confidently
agreeing on garbage. Same failure mode as "upvotes amplify bad reviews," same fix as
adversarial-verify in the review pipeline: at least one agent per team whose job is to
attack. Never ship worker-only teams.

---

## 6. Metering & payments (deferred — grounded in hwpay)

**Layering — only one layer is contested, and the internal one needs no standard:**

1. **Internal budget = your own signed-voucher ledger. No payment protocol.** You own
   both sides (proxy + agents), so it's *accounting*, not a payment between untrusted
   parties. Escrow = root grant, signed voucher = per-call debit, net = settlement.
   Denominated in **abstract credits** (funding asset converted at deposit time — insulates
   the agent economy from crypto volatility). Every primitive already exists from the
   review work: **ed25519 signing, nonces, content-hash binding — a budget voucher is the
   same shape as a signed review verdict.** **[design, but primitives built]**
2. **Top-up (fiat→credits)** — a boring processor. Stripe. Swappable.
3. **Agent-pays-external** — the only place the standards war (x402 / MPP / ACP / AP2)
   lives. Abstract behind an adapter; probably unneeded in v1.

**The membrane = `~/rotko/hwpay`** (a *hardware-secured payment processor*, Rust). It
already implements most of layers 2–3:

- **TPM 2.0-sealed vault** — master keys hardware-bound (unsealable only on the same
  machine+boot), Argon2id+ChaCha20 fallback. Stronger than "key never in argv/env": the
  key never leaves hardware. `vault.rs`/`tpm.rs`/`crypto.rs`.
- **Rails already present**: `stripe.rs` (TPM-secured keys), `x402.rs` (HTTP-402 over
  EIP-3009 USDC `transferWithAuthorization`), Penumbra (shielded USDC), Polkadot AssetHub
  (USDC/USDT via smoldot light client), **`zcash` module scaffolded** (feature-gated).
- **Custody & settlement**: tiered hot→medium→cold wallets, keyless proxies w/ time
  delays (`proxy.rs`), `sweep.rs`, deposit listeners + `DepositCallback`, per-user HD
  deposit addresses with rotation.

**Mapping to the cluster:**
- hwpay = money-in + custody + **verified settlement**; the internal voucher ledger =
  budget accounting + metering. The membrane is hwpay's listener crediting the internal
  escrow *after finality*.
- **Security-critical (micay): verify settlement finality BEFORE crediting escrow** —
  "credit before confirm" is free money for an attacker. hwpay's listener/`DepositCallback`
  is exactly that gate; don't bypass it.
- **Chosen external target = MPP** (Machine Payments Protocol, Tempo+Stripe, IETF draft):
  rail-agnostic, standard `WWW-Authenticate: Payment` semantics, **x402-compatible**
  (mppx runs both), and its **session model — escrow deposit + signed off-chain vouchers +
  net settlement — is our conservation design, already specified.** Its request-digest
  binding == our content-hash binding; its voucher == our signed-review shape. Adopt at the
  edge later; hwpay's `x402.rs`+`stripe.rs` become MPP *methods*. Caveat: still an unratified
  draft — target it behind the adapter, don't hard-wire.
- **Payment options wanted: ZEC + Tempo/MPP.** ZEC = the **privacy rail** (scaffolded in
  hwpay's `zcash`; consistent with the Penumbra/shielded direction); Tempo = the **stable,
  predictable rail**. Both are just MPP *methods* on one endpoint. Both are *funding* rails
  (fund the escrow once) — ZEC's on-chain latency never touches the per-call hot path, which
  is the internal voucher ledger. **Sequence stablecoin/Tempo first (turnkey), add ZEC after.**

---

## 7. Token-efficiency & privacy throughlines

- **Local models cut cost to zero at the leaf.** `agent` now runs on **Ollama**
  (`ZISH_AGENT_BACKEND=ollama`, no key; `ZISH_AGENT_TIMEOUT` for slow big models). A 27B
  produced a sharper PKGBUILD verdict than a hosted flash model, ~6 min on CPU. **[built]**
- **The review/reputation cache is a cluster cost feature.** An agent that reuses a
  trusted signed verdict instead of re-judging **spends zero of its budget slice**. The
  "peers don't burn tokens" economy is the same mechanism that makes clusters viable.
  Local reputation (earn trust by agreement, then reuse) is **[built]** in `aur`.
- **Privacy throughline**: shielded payments (ZEC/Penumbra) **now** + ZK reputation
  (UniRep/Semaphore/Penumbra-style — prove reputation ≥ X without revealing identity)
  **deferred** = the private agent economy. Rotation-costs-reputation (Sybil defense) and
  privacy-via-rotation are the same coin; ZK removes the linkage tax later. Shielded-by-default
  is the principle to hold **now** (publishing opt-in, pseudonymous, metadata-minimal).

---

## 8. Comparison

| | zish agent cloud | Anthropic (hosted) | Cloudflare Agents |
|---|---|---|---|
| execution | native binaries in microVM | sandboxed containers | **V8 isolate, virtual FS** (no native) |
| confinement | Landlock+seccomp (fd-3 attested) | bubblewrap+proxy | isolate boundary |
| state/idle | VM snapshot/restore (design) | — | Durable Objects (hibernate) |
| metering | conserved subdivision + signed vouchers | — | per-call (x402) |
| distinctive | **root-bounded self-subdividing native tree** | managed sandbox | edge-native JS agents |

---

## 9. Sequencing (next bricks)

1. **Conservation primitive, local**: spawn = subdivide {token budget, sub-cgroup,
   narrowed profile}, metered through one proxy, on a single box with the session feats.
   If subdivision holds locally, the cloud is replication + billing.
2. **Team orchestration** (§5): Captain / worker / **critic** roles over the agent-to-agent
   FIFO + a shared blackboard; wire the session control plane (`list/answer/kill`) to a chat
   front-end; shared-prefix fan-out for cheap swarms. Builds directly on (1).
3. **Firecracker fleet + snapshot/restore** (hibernation).
4. **Reviewer benchmark** (the deferred trust brick — see review-trust notes): the O(1)
   reputation number that lets an agent skip its own review safely; also gates any
   auto-install autonomy.
5. **Payments**: internal voucher ledger (abstract credits) → hwpay membrane (finality
   → credit) → MPP method wrapping x402/stripe → ZEC privacy rail.

Nothing here couples the core to an unratified standard or a specific chain. The internal
ledger is accounting you own; hwpay is the membrane; MPP/ZEC/Tempo live at the edge.
