# Security

## Threat model

A shell runs whatever you tell it to, so "it executed a command" isn't a
vulnerability. These are:

**1. Code running before you asked for it.** Completion, ghost text and the
prompt all inspect what you've typed *while* you type it. Nothing on that path
may execute the text. Pasting a command to read it before running it must be
safe — including a command you pasted from somewhere untrusted.

**2. Untrusted data treated as code.** Model output, a downloaded `.gguf`, a
`--help` string from some binary — none of it is trusted input, and none of it
should reach a shell interpreter or an unchecked allocation.

**3. Memory safety.** Release builds ship with safety checks off, so an
out-of-bounds write is a real write, not a panic. Any input-length arithmetic
in the lexer, parser or editor is security-relevant.

This matters more than usual for zish, because it's designed to be driven by
an LLM agent. Text arriving from a model is untrusted input in the same way
text from the network is.

## Rules

- **Never build a shell command by string interpolation.** Spawn with an argv
  array. If you need `2>&1`, hand the child one pipe as both stdout and stderr
  — that's what `captureMerged()` in `completion.zig` is for.
- **Never fuzz the executor.** Fuzz targets live on pure surfaces only (lexer,
  parser, arithmetic, glob, GGUF). A coverage-guided fuzzer optimises for
  reaching new code, and the new code behind `evaluateCommand` is `execvpeZ`.
- **Bound every length that came from outside.** A count read from a file can't
  exceed the file; check it before it reaches an allocator.
- **No `unreachable` or `assert` on external input.** A corrupt file or a lost
  terminal is an error to return, not an invariant to assert.

## Found and fixed

The 0.16.0 audit, kept here because each one is now a regression test:

| Issue | Impact |
|---|---|
| Tab completion built `sh -c "<typed word> --help"` | **Arbitrary code execution on TAB**, before Enter |
| Forked children reused one "exec in place" flag | `( a; b )`, `x \| { a; b; }`, `( a; b ) &` silently dropped everything after the first command |
| Forked children swapped allocator with a live heap | GPA pointers freed by `page_allocator` — heap corruption |
| `switchToBuf` `@memcpy` unbounded | Out-of-bounds write from a >1024-char word plus an escape |
| GGUF lengths used unchecked | Crash / wild allocation from a malicious model file |
| `minInt / -1`, 19-digit literals | Panic in safe builds, wrong answers in release |
| Here strings written into a pipe | Deadlock above ~64 KiB; leaked fd on write failure |
| `tcsetpgrp` asserted `unreachable` on errno | Shell crash on a recoverable job-control race |

Two were found by fuzzing; the rest by review. Both fuzz findings came from
hand-written structured generators rather than random bytes, which is the
useful lesson: if you add a parser, add a generator that produces *nearly
valid* input for it.

## Reporting

Please report suspected vulnerabilities privately rather than opening a public
issue. A proof of concept as a `tests/regress.sh` case is ideal — that's the
form the fix will take anyway.
