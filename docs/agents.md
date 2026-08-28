# Running an agent under zish

The short version:

```sh
zish --profile workdir --allow-write "$HOME/.claude:/tmp" -c 'claude'
```

You do not swap the agent's shell. You wrap the agent.

## Why wrapping, not swapping

The obvious idea — "make the agent run its commands through zish" — does not
work, and would not help much if it did.

- **Claude Code** drives `bash` and has no option to use a different shell.
- **Hermes** is Python; `subprocess(..., shell=True)` is hardcoded to `/bin/sh`
  on POSIX. `$SHELL` is not consulted.
- Any harness you did not write is free to `execve` a binary directly and never
  involve a shell at all.

So a shell-level sandbox that only covers commands typed at zish would have a
hole in it the size of the harness.

Landlock closes that by construction. The restriction is a property of the
**process**, it is inherited across `fork` and `exec`, and it cannot be
relaxed. Restrict the process that starts the agent and you have restricted the
agent, every tool it calls, and everything those spawn — without the harness
knowing or cooperating.

Verified four levels deep:

```sh
$ cd /tmp/demo
$ zish --profile workdir -c 'bash -c "make all"'   # make runs: sh -c "echo x > /tmp/PWNED"
sh: line 1: /tmp/PWNED: Permission denied
```

`zish` → `bash` → `make` → `sh`, and the write still fails.

This is also what Claude Code's own `--help` asks for: it describes
`--dangerously-skip-permissions` as "recommended only for sandboxes". This is a
way to be that sandbox without a container image.

## The recipe

```sh
zish --profile workdir --allow-write "<agent state dir>:/tmp" -c '<agent>'
```

- `--profile workdir` — read anywhere, write only beneath the directory you
  started in.
- `--allow-write` — extra writable roots, `:`-separated, like `PATH`. Grants
  are exact: a root does not extend to its parent.

**The agent's own state directory is not optional.** With `workdir` alone, the
harness cannot write its session log, config or cache, and fails in ways that
read as harness bugs rather than sandbox denials. Most also want `/tmp`.

A path that does not exist is refused rather than skipped, and `--allow-write`
without a restrictive `--profile` is an error — a grant nothing enforces is
worse than no grant, because you stop checking.

### Claude Code

```sh
cd /path/to/project
zish --profile workdir --allow-write "$HOME/.claude:/tmp" -c 'claude'
```

Verified: a full `claude -p` run completes normally, and with `Bash` allowed it
cannot escape:

```
$ claude -p "run: echo test > ~/ESCAPED.txt" --allowedTools Bash
It did not work. The command failed with a permission error:
  permission denied: /home/alice/ESCAPED.txt
```

No file was created. Note that the agent *reported* the denial rather than
being killed by it — a sandbox the model can observe and describe is one it can
work around correctly, instead of retrying blindly.

### Hermes

```sh
cd /path/to/project
zish --profile workdir --allow-write "$HOME/.hermes:/tmp" -c 'hermes'
```

`$HERMES_HOME` overrides the state directory if you have set it; grant whatever
it points at.

### Anything else

The shape is harness-agnostic, because the kernel does the work:

```sh
zish --profile workdir --allow-write "<state>:/tmp" -c '<command>'
```

If you do not know what a harness writes, run it once unsandboxed under
`strace -f -e trace=%file` and look at what it opens for writing, or run it
sandboxed and read the denials.

## What this does and does not buy you

**Does**

- Bounds the whole process tree to a directory, enforced by the kernel.
- Needs no root, no container, no image, no `LD_PRELOAD`.
- Bounds zish itself, so a bug in the shell is contained by the same limit.
- Denies `ptrace`/`process_vm_*` (and `kexec`) via a seccomp filter, so a
  sandboxed process can't attach to or read another process's memory — closing
  the yama-`ptrace_scope=0` escape below regardless of the sysctl.
- Costs nothing at runtime — a one-time syscall at startup, inherited across
  exec.

**Does not**

- Restrict the network. A sandboxed agent can still make requests, and
  exfiltrate anything it is allowed to read. That's a design choice, not an
  oversight — the agent needs to reach its model. See "Network" below.
- Restrict reads. Every profile can read the whole filesystem, credentials
  included. This bounds damage, not disclosure.
- Restrict process creation or signals.
- Replace the harness's own permission prompts. It is the layer beneath them,
  for when they are bypassed, misconfigured, or skipped outright.

Treat it as a blast radius, not a jail.

## Nothing has to break Landlock to get out

No userspace bypass of the restriction itself is known, and a child cannot lift
it. But escaping the *restriction* is not the same as escaping the *sandbox's
purpose*, and the recipes above hand over three routes to code running
unrestricted later. All three were verified against the exact command this
document recommends:

```
content-WRITABLE  ~/.claude/settings.json   # contains hooks: shell commands
content-WRITABLE  ./.git/hooks              # runs on your next commit
content-WRITABLE  ./Makefile                # runs on your next `make`
```

(Probed with a real append, not `touch` — see the metadata note below for why
`touch` proves nothing here.)

Write a `SessionStart` hook into `settings.json` and it executes the next time
the harness starts — outside any sandbox, because *you* launched that one.
Same for a git hook, a Makefile target, `package.json` scripts, `.envrc`.

So state the guarantee accurately: **the sandbox protects everything outside
the roots you granted. It cannot protect the roots themselves, and those
contain executable configuration.** Granting write access to a directory is
granting deferred code execution in it.

Two things follow.

**Do not grant the harness's config directory if you can avoid it.** Claude
Code honours `CLAUDE_CONFIG_DIR`, so point it at a throwaway and leave your
real `~/.claude` — hooks and all — unwritable:

```sh
export CLAUDE_CONFIG_DIR=/tmp/claude-scratch
zish --profile workdir --allow-write "$CLAUDE_CONFIG_DIR:/tmp" -c 'claude'
```

**`ptrace_scope` — belt and suspenders.** The classic version of this attack:
with `/proc/sys/kernel/yama/ptrace_scope` at `0`, a process could attach to any
unrestricted process you own and act through it. A restrictive profile now
blocks the `ptrace` syscall outright via seccomp, so this is closed regardless
of the sysctl. Keeping `ptrace_scope >= 1` is still good defence in depth for
everything *not* running under a zish profile:

```sh
cat /proc/sys/kernel/yama/ptrace_scope    # want >= 1
```

**File metadata is not covered.** Landlock restricts a defined set of access
rights, and changing timestamps or permissions is not among them. Both of these
succeed on a file the process cannot write:

```
$ chmod 777 ~/.claude/keybindings.json   # succeeds
$ touch    ~/.claude/keybindings.json    # succeeds
$ printf '' >> ~/.claude/keybindings.json
zish: error executing command: error.AccessDenied     # content still denied
```

This is not an escape — Landlock is enforced independently of file
permissions, so `chmod 777` does not buy the process a write. It is a
sabotage surface: modes and timestamps can be changed filesystem-wide.

It also makes `touch` useless as a probe. If you are testing what a profile
allows, append a byte; a successful `touch` says nothing about content.

## Reading what happened

Restriction bounds the damage. Tracing tells you what ran — but note carefully
what "ran" means in a wrapper.

Open fd 3 and zish writes one JSON record per command **submitted to that zish
process**. In the wrapper shape, that is one command: the agent itself.

```sh
$ zish --profile workdir --allow-write /tmp -c 'bash -c "echo one; echo two"' 3>trace.jsonl
$ cat trace.jsonl
{"ts":1787935251419,"cmd":"bash -c \"echo one; echo two\"","cwd":"/tmp/demo","exit":0,"ms":1,"sandbox":"workdir"}
```

One record, not three. The commands the agent runs internally go through its
own `bash`, never through zish, so they are not traced. Wrapping gives you
containment for the whole tree and observability for the outer command only.

Per-command records would need the harness to invoke `zish -c` for each tool
call, which none of the harnesses above do today. If you are writing the
harness, that is the shape worth adopting: spawn

```sh
zish --profile workdir --allow-write "<state>:/tmp" -c '<the command>' 3>>trace.jsonl
```

per tool call, and read the exit status out of the JSON instead of parsing
output. A harness reading a field cannot be fooled by a command that prints
something resembling a prompt. See `man zish` (TRACING).

Until then, use the harness's own logs for what it ran, and the sandbox for
what it could not do.
