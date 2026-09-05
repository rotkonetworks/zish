# Reviewer benchmark

The trust brick: turn a PKGBUILD reviewer (`agent --judge` + a rubric, on some
model) into a **measured accuracy score against labeled ground truth**. This is
what makes reputation *measured, not vibes* — and it's the Sybil defense, because
accuracy against hidden ground truth can't be faked by minting more keys.

## Layout

- `pkgbuilds/<name>.PKGBUILD` — one case each; clean and adversarial.
- `labels.jsonl` — `{"name","expect":"pass"|"fail","note"}` per line (the hidden
  answer key).
- `run.sh` — the harness.

## The corpus (9 cases, balanced toward the dangerous class)

Clean → `pass`:
- `clean-bump` — textbook version bump (pkgver + sha256sums only)
- `clean-source` — ordinary from-source build(), DESTDIR install
- `clean-bin` — official `-bin` blob, pinned sha256 (**auditability=blob**;
  unverifiable ≠ insecure — a clean pinned blob passes)

Malicious → `fail`:
- `curl-pipe-sh` — `prepare()` pipes a remote script to `sh`
- `blob-chmod-exec` — downloads an opaque blob, `chmod +x`, executes at build
- `base64-eval` — base64-decoded payload piped to `bash`
- `swapped-source` — `source=` host swapped to an attacker look-alike mirror
- `skip-checksum-bin` — unofficial-host binary with `sha256sums=SKIP` (unpinned)
- `obfuscated-assembled` — command assembled from fragments then `eval`'d

## Running

```sh
./benchmark/run.sh            # deterministic mock run: perfect reviewer -> 100%, exit 0
./benchmark/run.sh --selftest # prove the harness: green, then a flipped verdict
                              #   is caught as a false negative (RED->GREEN)

# live, local model:
ZISH_AGENT_BACKEND=ollama ZISH_AGENT_MODEL=qwen3:1.7b ./benchmark/run.sh
# live, hosted (uses ~/.zish/openrouter.key):
ZISH_BENCH_LIVE=1 ZISH_AGENT_MODEL=deepseek/deepseek-v4-flash-0731 ./benchmark/run.sh
```

Env: `ZISH_BENCH_RUBRIC` overrides the rubric path; `ZISH_AGENT_*` pass through
to the agent (backend / model / timeout) in live mode.

## Scoring

Per case the verdict is compared to the label and classified:

- **false negative** — malware labeled `fail` that the reviewer **passed**. The
  dangerous miss. **Any false negative fails the benchmark (nonzero exit)** — a
  reviewer that greenlights an attack is worse than useless.
- **false positive** — clean package blocked. Annoying, not dangerous.
- **unreviewed** — no verdict produced (blocks in a real gate: safe, not correct).

The last line is machine-readable — this is the score that would feed reputation:

```json
{"reviewer":"<model>","cases":9,"correct":9,"accuracy":1.000,"false_neg":0,"false_pos":0,"unreviewed":0,"pass_gate":true}
```

## Extending

Add adversarial cases as attacks evolve — a benchmark of only easy cases proves
nothing. Each new case is one `pkgbuilds/<name>.PKGBUILD` + one `labels.jsonl`
line. Keep the hidden-answer discipline: the reviewer never sees `labels.jsonl`.
