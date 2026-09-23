# Running the harness against a local model

The short version:

```sh
$ ./bonsai "what is a landlock ruleset"     # one-shot, from the loaded server
$ ./bonsai agent "count the TODOs under src/"   # tool loop, sandboxed
$ ./bonsai bg "...long job..."              # detached; reports to the bus

$ eval "$(./bonsai env)"                    # or point the whole shell at it
$ agent solo "summarize ~/notes/today.md"
```

Now `agent`, `team`, `verify` and the captain all talk to a model on
`127.0.0.1`. Nothing in the loop speaks to the network.

This directory is a worked example, not a shipped feat: `bonsai` is a bash
script wrapping one specific local model (Ternary-Bonsai-2-27B on a PrismML
llama.cpp fork). The parts worth copying are the seam and the shape, not the
paths.

## The seam

`agent` reads three environment variables. That is the entire integration:

```sh
ZISH_AGENT_ENDPOINT=http://127.0.0.1:8080/v1/chat/completions
ZISH_AGENT_MODEL=bonsai
ZISH_AGENT_TIMEOUT=900
```

Any OpenAI-compatible server works — `llama-server`, ollama's `/v1`, vllm.
`ZISH_AGENT_BACKEND=ollama` is a shorthand for the ollama case; a raw
`ZISH_AGENT_ENDPOINT` overrides the URL outright.

`ZISH_AGENT_TIMEOUT` is not optional here. It defaults to 120 seconds, which is
a cloud-latency number. A 27B model at 2.6 tok/s spends minutes on one call and
every turn dies mid-generation without it.

## What the model gets as tools

One tool, `run_command`, defined in `feats/agent/main.zig`:

```json
{"name": "run_command", "description": "Run a shell command in the user's live
 zish session and return its stdout and exit code."}
```

That is the whole tool set, and it is why this works at all: every feat you
install is immediately reachable, because the model can type `cnt`, `snf`, `gf`
into a shell. No tool schema to regenerate, no harness rebuild. The cost is that
policy lives at the `sh -c` boundary — you can allow or deny "run a command",
not allow `cnt` and deny `curl`.

## Two executors, and the one that bites

The same tool schema is sent either way; what differs is who runs the command.

| invocation | executor | gate |
|---|---|---|
| `agent <query>` | the **session host** (zish) executes the tool and returns the result over the frame protocol | the host can refuse |
| `agent solo <query>` | the agent process forks `sh -c` itself | none in the agent: a bounded output read and a 3×-repeat loop guard. Contain it with `--profile`, below |
| `agent --ask <query>` | no tools at all, one-shot text | n/a |

Run `agent <query>` standalone and it emits `{"t":"run","cmd":"..."}` to nobody,
waits, and gives up with *"a command could not run (denied or session ended)"*.
That is not a bug — it is the mode that requires zish to be hosting the session.
Anything detached (a background job, a cron) must use `solo`.

`solo` is a bare token, not a flag. `--solo` is silently ignored.

## Containing it

An unsupervised model calling `sh -c` is exactly what `--profile` is for, so
`bonsai` turns it on by default rather than offering it:

```sh
$ bonsai run sh -c 'echo x > ./inside.txt'     # under $PWD
$ bonsai run sh -c 'echo x > $HOME/ROOTED'
/usr/bin/sh: line 1: /home/alice/ROOTED: Permission denied
```

That is the kernel refusing, not the script checking. What it expands to:

```sh
zish --profile workdir --allow-write "$HOME/.zish:/tmp" -c '<the agent>'
```

- `workdir` — write beneath `$PWD`, read anywhere. Inherited by the agent, by
  the `sh -c` it forks, and by everything those spawn.
- `$HOME/.zish` must be writable: `agent` writes its curl config and request
  body there with mode 0600, so the API key is never a process argument.
- Landlock does not restrict the network, so the loopback request to the model
  is unaffected. Which is also the honest caveat — see
  [what it does not stop](../../README.md#what-it-does-not-stop). The reason
  that caveat bites less here is that the model *is* local: there is no remote
  endpoint in the loop to disclose to.

`BONSAI_PROFILE=none` opts out, `BONSAI_ALLOW_WRITE` adds roots. Opt-out rather
than opt-in, because the default should be the safe one.

## Getting an answer back from a detached job

A local 27B is slow enough that the useful mode is fire-and-forget:

```sh
$ ./bonsai bg "count the lines in /etc/hostname"
20260920-194113-1652347

$ ./bonsai jobs
20260920-194113-1652347  running  rc=-  count the lines in /etc/hostname

$ bus read bonsai --follow
1789908115  bonsai  20260920-194113-1652347 rc=0 :: The file /etc/hostname contains 1 line (per `wc -l`).
```

The `bus` feat is the return channel — a durable append-only log that outlives
you not being at the terminal. `bonsai jobs` / `out <id>` / `wait <id>` read the
job files under `$XDG_RUNTIME_DIR`, which is tmpfs; the bus is what survives a
reboot.

## Adapting it

Change the constants block at the top of `bonsai` — that is the only part that
knows about a particular model:

```sh
readonly PRISM_BIN="${BONSAI_BIN:-$HOME/src/prism-llama.cpp/build/bin}"
readonly MODEL="$MODEL_DIR/Ternary-Bonsai-2-27B-PQ2_0.gguf"
readonly NGL="${BONSAI_NGL:-56}"
readonly PORT="${BONSAI_PORT:-8080}"
```

Everything below it is model-agnostic lifecycle: background the server, poll
`/health`, port-scoped pidfile, refuse to kill a server you did not start,
detached jobs that report to the bus.

`HOST` is deliberately `127.0.0.1` with no override. The property this example
exists to demonstrate is that the prompts never leave the machine, and an
invariant you can turn off with an environment variable is not one.

## Honest limits

- **`solo` has no gatekeeper of its own.** The model forks `sh -c` with nothing
  in between, which is what the sandbox above is for. If you want a human in
  the loop rather than a blast radius, host the session instead: `agent
  <query>` under zish, where every `run` frame is something you can refuse.
- **`agent` sends `~/.zish/openrouter.key` as a bearer header to whatever
  endpoint it is given.** A local `llama-server` ignores it, but your cloud key
  does reach a local socket.
- **`runSolo` strips every argv token equal to `solo`**, so a query containing
  that bare word loses it.
- **Speed.** Measured on the machine this was written on: 37 tok/s prompt,
  2.6 tok/s generation, CPU-only (`-ngl 0`), 27B at 2.13 bpw. A one-line
  question takes about four minutes end to end. Offload changes this; the
  ergonomics of `bg` + `bus` are the answer either way.
