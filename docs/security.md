# Security

zish is meant to be handed to an agent. That changes the threat model: the
thing typing commands is fast, literal, occasionally wrong, and sometimes acting
on text it read from the internet. This document says what zish does about that,
and — more usefully — what it does not.

## Threat model

**In scope**

- A command line reaching the shell that the user did not intend to run:
  from a paste, from a completion, from an agent that misread something.
- A bug in zish itself — a bad index, an overflow, a stale pointer — being
  reachable from ordinary input.
- An agent doing exactly what it was told, in a directory it should not have
  been told to touch.

**Out of scope**

- A hostile local user. zish is not a privilege boundary between accounts, and
  is not setuid.
- Network isolation. `--profile` restricts the filesystem; a sandboxed session
  can still open sockets.
- A malicious binary you install and run. zish executes what you ask it to;
  a restriction profile bounds what that binary may write, nothing more.
- Anything that runs *after* the restricted session ends. A profile grants
  write access to directories that hold executable configuration — `.git/hooks`,
  `Makefile`, `package.json`, `.envrc`, an agent's own hook settings — and all
  of those run unrestricted the next time you invoke git, make or the harness.
  Granting write access is granting deferred code execution. See
  [agents.md](agents.md).

## What is enforced

### Safety checks are on in the shipped build

Releases build with `--release=safe`. Zig's bounds, overflow and alignment
checks turn the bug classes they cover into an immediate abort instead of a
corrupted heap. This costs roughly 10% of throughput against `--release=fast`,
which is a trade worth making here.

`zish --version` prints the mode, so this is checkable rather than assumed:

```
$ zish --version
zish 0.16.1 (ReleaseSafe)
```

That output exists because the checks were once silently absent: `build.zig`
set `preferred_optimize_mode = .ReleaseFast`, which makes `standardOptimizeOption`
ignore `--release=safe` entirely. Every build path had been asking for safety
checks and receiving none — the two binaries were byte-identical. If you are
ever unsure which one you are running, ask it.

### `--profile` — kernel-enforced filesystem restriction

```sh
zish --profile readonly -c 'make test'
zish --profile workdir  -c 'make build'
```

Implemented with [Landlock](https://docs.kernel.org/userspace-api/landlock.html),
which needs no root, no container and no `LD_PRELOAD`. Applied once at startup;
Landlock restrictions are inherited and cannot be lifted, so the limit binds
every descendant process **and zish itself**.

That last part is the reason it is session-scoped rather than per-command. A
per-command sandbox would be more flexible, but it would leave zish's own
parser, expander and completion engine running unrestricted — and those are
exactly the components that take untrusted input. The kernel does not care
which process has the bug.

`--allow-write` adds writable roots (`:`-separated) so the profile can be made
usable without being made pointless; see [agents.md](agents.md) for the
wrapping recipes.

It fails closed. An unknown profile name exits 2; a kernel that cannot enforce
the request exits 1. Neither degrades to running unrestricted, because a
sandbox that silently turns itself off is worse than no sandbox — you stop
watching.

Write-only device sinks (`/dev/null`, `/dev/zero`, `/dev/tty`, ...) stay
writable under every profile. `cat x >/dev/null` is a write, and the first
version of this broke it; that case is now in the regression suite.

### Syscall restriction (the "pledge" half)

Landlock is Cosmopolitan's `unveil` — it bounds files. Every restrictive
profile also installs a seccomp-BPF filter, the `pledge` half, bounding
syscalls. It is a small curated *denylist*, not an allowlist: a shell execs
arbitrary programs (a compiler, git, python) and the filter is inherited across
exec, so an allowlist would kill legitimate tools and rot with every kernel
release. The denylist is `ptrace`, `process_vm_readv`/`writev` and `kexec` —
things a shell's children have no legitimate need for. Denied calls return
`EPERM` (fail gracefully), except a non-native syscall ABI, which is killed
(the arch guard that stops a number-keyed filter being bypassed via x32/compat).

Deliberately *not* in the denylist: `socket` (the agent must reach its model),
`unshare`/`mount` (rootless containers, `nix build`), `bpf` (observability),
`memfd`/`execveat` (glibc, CPython, Wayland use them, and anonymous exec is
still Landlock-write-bounded). Those belong to explicit named profiles, not a
silent default. See [agents.md](agents.md) for the network design.

### Structured output instead of screen-scraping

With fd 3 open, zish writes one JSON record per submitted command. A harness
that reads exit status from a JSON field cannot be fooled by a command that
prints something resembling a prompt. See the README section.

## What has been found and fixed

The interesting ones, most severe first.

**Tab completion executed the word you were typing.** To offer flag
completions, zish probed `<word> --help` by building a string and handing it to
`/bin/sh -c`. Any shell metacharacter in the word ran — on TAB, before Enter.
A pasted line was enough; you never had to submit it. Fixed by spawning argv
directly with no shell, merging stdout and stderr over a single pipe, and
allowlisting probe names. Regression cases live in `tests/regress.sh`.

**Out-of-bounds write in the lexer.** A word longer than `MAX_TOKEN_LENGTH`
followed by a backslash escape wrote past the token buffer. Found by
`zig build fuzz`, not by review.

**Heap corruption after fork.** Forked children switched allocator while
holding a heap inherited from the parent; the first builtin to free a pre-fork
pointer corrupted it. Now an arena whose `free` is a no-op for foreign
pointers.

**Crashes on adversarial arithmetic.** `$(( minInt / -1 ))` and 19-digit
literals aborted safe builds. Both are now checked.

**Unbounded GGUF parsing.** Lengths and counts read from a model file reached
the allocator unchecked. Fixed, and then made moot: the inference engine has
since been removed entirely — about 7,700 lines of parsing, mmap and tensor
math, gone. Deleting an attack surface beats hardening one.

**Forgeable session trace.** With fd 3 open, zish writes a JSON record per
command — and a harness is meant to trust those records to know what ran. But
the raw descriptor was inherited by every forked child, so any command (`echo
… >&3`) could write its own records, letting a hostile agent describe a clean
session over a dirty one. The descriptor is now relocated to a high number with
close-on-exec, so only zish's own process can reach it; children see fd 3
closed. Regression: "trace cannot be forged by a child".

## Attacking the sandbox

The `--profile` restriction was red-teamed directly. What held, and what did
not:

**Held** (Landlock enforced it, verified by trying):

- `/proc/self/mem` and `/proc/<pid>/mem` writes — denied.
- `/proc/self/root` and `/proc/self/fd/<n>` re-anchoring — denied; Landlock
  re-checks the reopened path.
- Reopening a read-only fd as write via `/proc/self/fd` — denied.
- A symlink inside a granted root pointing out of it — denied; the target is
  resolved and checked.
- Hardlinking a file into a granted root — denied by the `refer` restriction
  (surfaces as `EXDEV`).
- A child dropping `no_new_privs` or lifting the ruleset — refused by the
  kernel; rulesets only ever intersect.
- `ptrace`/`process_vm_readv`/`process_vm_writev` — denied by the seccomp
  filter every restrictive profile installs (see below). This closed the one
  escape that Landlock alone could not: with yama `ptrace_scope=0` a restricted
  process could otherwise attach to an unrestricted one and act through it.

**Did not hold** — and these are the honest limits, not bugs to be fixed in
zish:

- **Inherited writable descriptors.** Landlock restricts `open()`, not writes
  to descriptors already open when it was applied. If the process that launches
  zish leaves a writable fd open — and `stderr` pointed at a real log file is
  the common case — a sandboxed command can write to it regardless of profile.
  Verified: a harness whose `stderr` was a file outside every granted root had
  that file written from inside the sandbox. Mitigation is on the launcher:
  don't pass writable fds into a sandboxed zish (`O_CLOEXEC`, or redirect
  through a pipe you own).
- **In-memory execution.** `memfd_create` + `execve` runs code that never
  touched disk. This is not a filesystem escape — the code is still bound by
  the profile — but any monitoring that assumes executables appear on disk will
  miss it.
- **Deferred execution through granted roots** and **unrestricted reads /
  network**, both covered in [agents.md](agents.md): the sandbox bounds writes
  to a blast radius, it does not prevent reading secrets or sending them.

The takeaway is the same one the docs lead with: this is filesystem-write
containment for a process tree, enforced by the kernel. It is not a jail, and
the boundary is only as good as the fds and roots the launcher hands it.

## Testing

```sh
./tests/regress.sh          # end-to-end, differential against bash
python3 tests/pty_test.py   # interactive: line editor, job control, signals
zig build test              # unit tests + randomized sweeps
zig build fuzz              # parser, lexer, arithmetic, glob
```

Every case in `tests/regress.sh` is a bug that was once real, including the
completion RCE. The pty suite exists because `zish -c` never enters the
interactive code paths — and that is precisely where the RCE lived.

## Reporting

Open an issue at <https://github.com/rotkonetworks/zish/issues>. If you would
rather not do that in public, mail hq@rotko.net.
