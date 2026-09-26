# Agents working with zish

Read `CLAUDE.md` first. It holds the invariants, review lenses and testing bar
for changing the code, and it applies to every agent, not only Claude.

This file adds one duty for any agent that *uses* zish or works on it:
**when zish behaves differently from bash, file a GitHub issue.**

## Report every disparity with bash

zish aims to be bash-familiar, and bash is the reference implementation. Any
difference you hit is either a bug or a deliberate choice, and either way the
maintainers need to hear about it. Workarounds are fine for finishing your task,
but a disparity you work around silently is lost. File it.

This covers:

- **Parse errors** on input bash accepts. The parser is the hardest part of a
  shell and where most real bugs live (`echo a 2>/dev/null b` was a parse error
  through 0.25.1). Report these with extra care.
- **Wrong output or exit status.** Silent wrong output (`printf -- fmt` printing
  `--`) is worse than an error, because nothing tells the user.
- **Missing expansions**: globbing, word splitting, parameter expansion,
  arithmetic, quoting.
- **Performance.** Anything noticeably slower than bash on the same script.
  Measure it (see below); don't eyeball it.
- **Interactive differences**: line editing, job control, signals, terminal
  state.

Not a disparity: features zish documents as intentionally different (the
sandbox, feats, `--profile`). If it's unclear whether a difference is
deliberate, report it and say so.

## Before filing

1. **Minimize.** Cut the failing command down to the smallest input that still
   differs. One line with no external commands is ideal. Say what you ruled out
   ("the `=` is irrelevant; any word after a redirect fails").
2. **Confirm against bash** with the identical string:
   ```sh
   zish -c '<script>'; echo "rc=$?"
   bash -c '<script>'; echo "rc=$?"
   ```
3. **Check the latest build.** Say which one you used: `zish --version`. If you
   can, build `main` (`zig build --release=safe -Dlto=false`) and retest.
4. **Search for duplicates:**
   `gh issue list -R rotkonetworks/zish --state all --search '<keywords>'`.
   If one exists, add your repro as a comment instead of opening a new issue.

## Performance disparities

A performance claim needs numbers, and a fast answer that's wrong doesn't
count. Before filing:

- Check that zish and bash produce **identical output** for the benchmark
  script. A benchmark that isn't validated against bash proves nothing.
- Time both on the same machine, several runs each, and report the median:
  ```sh
  for sh in zish bash; do
    for i in 1 2 3 4 5; do /usr/bin/time -f "$sh %e s" $sh bench.sh >/dev/null; done
  done
  ```
- Say what kind of workload it is: interpreter-bound (loops, arithmetic,
  string ops), fork-bound (an external command per iteration) or I/O-bound
  (`read`, `mapfile`). zish should beat bash on the first and tie on the
  second, so a loss on either is a real finding.

## Filing

One issue per disparity. If you found three, file three and cross-link them.

```sh
gh issue create -R rotkonetworks/zish --label bug \
  --title '<construct>: <what goes wrong>' \
  --body-file issue.md
```

Use `--label bug` for wrong behaviour or parse errors, and `--label
enhancement` for a missing bash feature or a performance gap. Titles should
name the construct: `parser: word after a redirection is a parse error`,
`printf: -- end-of-options not stripped`.

The body:

````markdown
## Repro
```sh
zish -c '<minimal script>'
```

## zish (<version from zish --version>)
<exact output and exit status>

## bash (<bash --version, first line>)
<exact output and exit status>

## Notes
What you ruled out, the workaround you used, and where in the code you think
the fault is, if you know.
````

Don't include secrets, private hostnames or customer data in a repro. Replace
them with placeholders that still reproduce the problem.

## If you fix it yourself

Follow `CLAUDE.md`. Add the repro to `tests/regress.sh` as a `same_as_bash`
case that fails on the old binary and passes on the new one, and reference
the issue in the commit (`fixes #N`).
