# Working on zish

zish is a fast, POSIX/bash-familiar interactive shell in Zig (Linux, single
process). This file is guidance for anyone — human or agent — changing the code.

## Review lenses

Every substantive change gets read through the relevant lenses below. These are
named after engineers whose style each captures (they were once literally
codified as the shell's agent personas). Pick the lenses the change touches;
security-touching code **always** gets the micay lens, correctness-critical
code the deidrec/redshiftzero lenses.

- **hdevalence — architecture.** Is this at the right altitude? One owner per
  concern, clean interfaces, no special-case bolted onto shared infrastructure.
  Prefer generalizing the mechanism over adding a fifth copy of it.
- **micay — hardening.** Assume adversarial input. Check every boundary, every
  fd, every syscall return. Make the bad state *unrepresentable*, not merely
  *defended by discipline*. Fail closed. Never trust a child process to restore
  state you own.
- **redshiftzero — QA / bug hunt.** Trace every path, not the happy one. What
  breaks under redirected stdin, no controlling tty, EOF, a signal mid-syscall,
  a pipeline, a subshell, a function? A fix without a red→green test is a guess.
- **deidrec — correctness.** State the invariant, then prove the code upholds it
  on every path. Differential against bash where semantics are pinned. Types and
  ordering matter; "usually right" is wrong.
- **rphmeier — systems / protocol.** Model it as states and transitions. Process
  groups, terminal foreground, signal dispositions, job states — get the
  ordering right (e.g. setpgid → tcsetpgrp → reset-signals) and document why.
- **karpathy — measurement.** Don't guess at performance; measure it. A
  wrong-but-fast answer fails; a benchmark that isn't validated against bash
  proves nothing.

## Invariants this codebase holds (don't regress them)

- **The shell owns its terminal and signal state by construction.** It never
  trusts a child to restore raw/cooked mode or signal dispositions. Every
  foreground execution goes through the single owner in `src/foreground.zig`
  (cooked tty → pgroup → tcsetpgrp → child signal reset → UNTRACED wait →
  stopped-job register → reclaim → restore raw). `ensureRawMode()` re-asserts
  raw before each prompt as a backstop. A new fork site MUST route through this,
  not re-implement it.
- **Single-threaded execution core.** Concurrency is process-level (fork/exec),
  not threads — a shell forks constantly and `fork` + live threads is a
  deadlock hazard. Parallelism belongs in a feat (a process orchestrator), not
  the interpreter.
- **Fail-closed containment.** `--profile` applies Landlock (`sandbox.zig`) and
  a seccomp denylist (`seccomp.zig`) once at startup, inherited across exec,
  refusing to run rather than degrading. The fd-3 trace (`trace.zig`) is
  unforgeable (relocated + CLOEXEC) and attests the enforced profile.
- **Feats are the extension model** — standalone binaries the shell execs
  (`fork+exec+argv+stdio`, no plugin ABI). A feat never shadows a real binary;
  its name must not collide with an installed command. See `docs/feat-spec.md`.

## Testing (the bar for a change)

- `./tests/regress.sh` — end-to-end, **differential against bash**; every case
  is a bug that was once real. Use `same_as_bash` when bash pins the semantics.
- `python3 tests/pty_test.py` — the interactive layer (line editor, job control,
  signals, terminal handover) that `zish -c` never exercises.
- `make test` runs regress + `zig build test`; `make test-pty` runs the pty suite.
- Ship builds with `--release=safe` (bounds/overflow/alignment checks on).
- A change to the interactive/job-control layer needs a pty regression that
  fails red on the old binary and passes green on the new one.

## Don't reintroduce

Dead weight from removed subsystems (LLM agent, GGUF inference, audio) was
pruned. Don't re-add agent/persona/inference/voice code, GPU shaders, or a
plugin ABI. Keep the core small; capability moves to feats, contained by the
sandbox.
