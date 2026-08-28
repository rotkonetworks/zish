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
- Costs nothing at runtime — it is a one-time syscall at startup.

**Does not**

- Restrict the network. A sandboxed agent can still make requests, and
  exfiltrate anything it is allowed to read. Landlock can restrict TCP
  connect/bind; zish does not use that yet.
- Restrict reads. Every profile can read the whole filesystem, credentials
  included. This bounds damage, not disclosure.
- Restrict process creation, signals, or `ptrace`.
- Replace the harness's own permission prompts. It is the layer beneath them,
  for when they are bypassed, misconfigured, or skipped outright.

Treat it as a blast radius, not a jail.

## Reading what happened

Restriction bounds the damage. Tracing tells you what ran — but note carefully
what "ran" means in a wrapper.

Open fd 3 and zish writes one JSON record per command **submitted to that zish
process**. In the wrapper shape, that is one command: the agent itself.

```sh
$ zish --profile workdir --allow-write /tmp -c 'bash -c "echo one; echo two"' 3>trace.jsonl
$ cat trace.jsonl
{"ts":1787935251419,"cmd":"bash -c \"echo one; echo two\"","cwd":"/tmp/demo","exit":0,"ms":1}
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
