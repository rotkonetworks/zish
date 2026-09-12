#!/usr/bin/env bash
# team tests — the Captain/worker/critic/synth swarm, bounded by the budget
# conservation primitive. Both `agent` and `budget` are stubbed as fake feats,
# so the whole orchestration is exercised offline and deterministically.
set -u
cd "$(dirname "$0")/.."

T=$(mktemp -d /tmp/team-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.zish" \
         "$T/feats/standard/agent/bin" \
         "$T/feats/standard/budget/bin" \
         "$T/feats/standard/verify/bin" \
         "$T/state"

FEAT_BIN=${FEAT_BIN:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/share/zish/feats/standard}
cp "$FEAT_BIN/team/bin/team" "$T/team" || { echo "FAIL: $FEAT_BIN/team not built — run: zig build -Dfeats=all"; exit 1; }
# the REAL verify feat (team execs it as the compiler gate)
mkdir -p "$T/feats/standard/verify/bin"
cp "$FEAT_BIN/verify/bin/verify" "$T/feats/standard/verify/bin/verify" \
    || { echo "FAIL: $FEAT_BIN/verify not built — run: zig build -Dfeats=all"; exit 1; }

# ---- fake agent: detects its role from the prompt (last arg) and logs it -----
cat > "$T/feats/standard/agent/bin/agent" <<'SH'
#!/bin/sh
prompt=""
for a in "$@"; do prompt="$a"; done   # prompt is the last arg
role=captain
case "$prompt" in
  *"COMPILER ERROR"*) role=repair ;;  # verify repair round — match BEFORE the others
  *SYNTHESIZE*)  role=synth ;;
  *CRITIC*)      role=critic ;;
  *"org's"*)     role=expert ;;   # "You are the org's <name> expert:"
  *WORKER*)      role=worker ;;
  *CAPTAIN*)     role=captain ;;
esac
echo "$role" >> "$AGENT_LOG"
[ -n "${PROMPT_LOG:-}" ] && printf '%s\n' "$prompt" >> "$PROMPT_LOG"
case "$role" in
  captain) printf 'subtask one\nsubtask two\nsubtask three\n' ;;
  worker)  printf 'worker result ok\n'
           # FAKE_WORKER_BTW=<name> makes the worker consult that expert
           [ -n "${FAKE_WORKER_BTW:-}" ] && printf 'BTW-ASK %s: is this safe?\n' "$FAKE_WORKER_BTW" ;;
  critic)  printf 'no contradictions found\n' ;;
  synth)   # FAKE_SYNTH_CODE=zig|rust emits BROKEN code of that lang (verifier gate)
           case "${FAKE_SYNTH_CODE:-}" in
             zig)  printf 'Final code:\n```zig\nfn f() void {\n    var idx: usize = 0;\n    idx -= ;\n}\n```\n' ;;
             rust) printf 'Final code:\n```rust\npub fn f(mut idx: usize) -> usize {\n    idx -= ;\n    idx\n}\n```\n' ;;
             *)    printf 'FINAL: synthesized answer\n' ;;
           esac ;;
  repair)  # the verifier fed us the real compiler error — return code that compiles.
           # (match on "rust code" from the repair prompt; avoid backticks in the pattern)
           case "$prompt" in
             *"rust code"*) printf 'Fixed:\n```rust\npub fn f(mut idx: usize) -> usize {\n    idx -= 1;\n    idx\n}\n```\n' ;;
             *)             printf 'Fixed:\n```zig\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n```\n' ;;
           esac ;;
  expert)  printf 'expert says: proceed, with care\n' ;;
esac
SH
chmod +x "$T/feats/standard/agent/bin/agent"

# ---- fake budget: conserved credits in $BUDGET_DIR, debits logged -------------
#  spend amounts -> $SPEND_LOG (the real consumption), splits -> $SPLIT_LOG.
#  FAKE_BUDGET_SPLIT_FAIL forces every split to fail (insufficient), to test
#  graceful degradation. Balances never go negative (fail closed).
cat > "$T/feats/standard/budget/bin/budget" <<'SH'
#!/bin/sh
cmd="$1"
case "$cmd" in
  new)     printf '%s\n' "$3" > "$BUDGET_DIR/$2" ;;
  split)
    [ -n "${FAKE_BUDGET_SPLIT_FAIL:-}" ] && exit 3
    pbal=$(cat "$BUDGET_DIR/$2" 2>/dev/null || echo 0); amt="$4"
    if [ "$pbal" -ge "$amt" ]; then
      printf '%s\n' "$((pbal - amt))" > "$BUDGET_DIR/$2"
      printf '%s\n' "$amt" > "$BUDGET_DIR/$3"
      printf '%s\n' "$amt" >> "$SPLIT_LOG"; exit 0
    fi; exit 1 ;;
  spend)
    bal=$(cat "$BUDGET_DIR/$2" 2>/dev/null || echo 0); amt="$3"
    if [ "$bal" -ge "$amt" ]; then
      printf '%s\n' "$((bal - amt))" > "$BUDGET_DIR/$2"
      printf '%s\n' "$amt" >> "$SPEND_LOG"; exit 0
    fi; exit 1 ;;
  balance) cat "$BUDGET_DIR/$2" 2>/dev/null || echo 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$T/feats/standard/budget/bin/budget"

# ---- fake ask: echoes $FAKE_ASK_ANSWER (the chosen option text) -------------
mkdir -p "$T/feats/standard/ask/bin"
cat > "$T/feats/standard/ask/bin/ask" <<'SH'
#!/bin/sh
printf '%s\n' "${FAKE_ASK_ANSWER:-Proceed}"
SH
chmod +x "$T/feats/standard/ask/bin/ask"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# SIGPIPE regression: a filter must die (141) when the reader of its stdout is
# gone, not swallow EPIPE and exit 0. A pipe whose read end is closed *before*
# exec fails the first write deterministically; `| head -c1` does not for output
# under the 64 KiB pipe buffer — the write lands before the reader exits.
sigpipe_status() {
    python3 -c 'import os,sys
r, w = os.pipe(); os.close(r)
os.dup2(w, 1); os.close(w)
os.execvp(sys.argv[1], sys.argv[1:])' "$@" 2>/dev/null
}

# fresh logs per run
reset_logs() { : > "$T/agent.log"; : > "$T/spend.log"; : > "$T/split.log"; rm -f "$T/state"/*; }
sumlog() { awk '{s+=$1} END{print s+0}' "$1"; }
countlog() { wc -l < "$1" 2>/dev/null | tr -d ' \n'; }

TEAM() { HOME="$T/home" ZISH_FEAT_PATH="$T/feats" \
         AGENT_LOG="$T/agent.log" SPEND_LOG="$T/spend.log" SPLIT_LOG="$T/split.log" \
         BUDGET_DIR="$T/state" "$T/team" "$@"; }

echo "== full swarm: all four phases run =="
reset_logs
o=$(TEAM run 6 "improve the widget latency"); rc=$?
[ "$rc" -eq 0 ] && ok "run exits 0" || bad "exit was $rc: $o"
grep -q '^captain$' "$T/agent.log" && ok "CAPTAIN (decompose) ran" || bad "no captain phase"
grep -q '^worker$'  "$T/agent.log" && ok "WORKERS fanned out" || bad "no worker phase"
grep -q '^critic$'  "$T/agent.log" && ok "CRITIC ran (mandatory)" || bad "no critic phase"
grep -q '^synth$'   "$T/agent.log" && ok "SYNTHESIS ran" || bad "no synth phase"
case "$o" in *"FINAL: synthesized answer"*) ok "prints the synthesized answer" ;; *) bad "no final answer: $o" ;; esac

echo "== verifier: broken code is caught and repaired against a REAL compiler =="
reset_logs
# synth emits broken zig -> verifier runs `zig ast-check` (real) -> fails ->
# ONE repair round against the true error -> repaired code compiles.
o=$(FAKE_SYNTH_CODE=zig TEAM run 8 "write a zig add function"); rc=$?
[ "$rc" -eq 0 ] && ok "run with a code answer exits 0" || bad "exit was $rc: $o"
grep -q '^repair$' "$T/agent.log" && ok "broken code triggered a repair round" || bad "verifier did not repair broken code"
case "$o" in *"repaired, now compiles"*) ok "repaired code passes real zig ast-check" ;; *) bad "no successful repair in output: $o" ;; esac
# a prose (no-code) answer must NOT be gated — the verifier is a no-op there
reset_logs
o=$(TEAM run 6 "explain the latency")
case "$o" in *"DOES NOT COMPILE"*|*"[verify]"*) bad "prose answer wrongly gated: $o" ;; *) ok "prose answer is not gated (verifier no-op)" ;; esac
# generalization: the verifier is language-agnostic — same red→green with rustc,
# the language that motivated this. Probe rustc UNDER THE TEST'S HOME first: a
# rustup shim needs a resolvable toolchain (the "pinned environment" case), which
# the isolated test HOME lacks — so skip cleanly there rather than flake.
rust_ok=0
if command -v rustc >/dev/null 2>&1; then
  printf 'pub fn p() -> u8 { 0 }\n' > "$T/probe.rs"
  HOME="$T/home" rustc --edition 2021 --crate-type lib --emit=metadata -o "$T/probe.rmeta" "$T/probe.rs" >/dev/null 2>&1 && rust_ok=1
fi
if [ "$rust_ok" -eq 1 ]; then
  reset_logs
  o=$(FAKE_SYNTH_CODE=rust TEAM run 8 "write a rust function"); rc=$?
  case "$o" in *"repaired, now compiles"*) ok "rust: broken code repaired against real rustc" ;; *) bad "rust verify/repair failed: $o" ;; esac
else
  ok "rust check skipped (no usable rustc toolchain under the test HOME)"
fi

echo "== human checkpoint (opt-in): Abort stops before fan-out; Proceed continues =="
reset_logs
o=$(ZISH_TEAM_CONFIRM=1 FAKE_ASK_ANSWER=Abort TEAM run 8 "a task"); rc=$?
[ "$rc" -eq 0 ] && ok "aborted run exits 0" || bad "abort exit $rc"
grep -q '^worker$' "$T/agent.log" && bad "workers ran despite Abort" || ok "Abort stopped before fan-out (no workers spawned)"
reset_logs
o=$(ZISH_TEAM_CONFIRM=1 FAKE_ASK_ANSWER=Proceed TEAM run 8 "a task")
grep -q '^worker$' "$T/agent.log" && ok "Proceed continues to fan-out" || bad "Proceed did not run workers"
reset_logs
o=$(TEAM run 8 "a task")   # no ZISH_TEAM_CONFIRM -> never asks
grep -q '^worker$' "$T/agent.log" && ok "no checkpoint by default (opt-in only)" || bad "default run regressed"

echo "== conservation: total spent never exceeds the root grant =="
reset_logs
o=$(TEAM run 5 "task alpha"); rc=$?
[ "$rc" -eq 0 ] && ok "run exits 0" || bad "exit $rc: $o"
spent=$(sumlog "$T/spend.log"); workers=$(countlog "$T/split.log")
[ "$spent" -le 5 ] && ok "total spent ($spent) <= root budget (5)" || bad "OVERSPENT: $spent > 5"
# captain + workers + critic + synth = 3 + workers; with R=5 that is exactly 5
[ "$spent" -eq $((3 + workers)) ] && ok "every credit spent flows from the root ($workers workers + 3 fixed)" || bad "accounting off: spent=$spent workers=$workers"
[ "$workers" -ge 1 ] && ok "fan-out actually spawned workers ($workers)" || bad "no workers spawned"
root_file=$(ls "$T"/state/ 2>/dev/null | grep -E '^team-[0-9]+$' | head -1)
root_final=$(cat "$T/state/$root_file" 2>/dev/null)
[ -n "$root_final" ] && [ "$root_final" -ge 0 ] && ok "root balance never went negative (final $root_final)" || bad "root negative/missing: $root_final"

echo "== graceful degradation: budget split fails -> no worker, no overspend =="
reset_logs
o=$(FAKE_BUDGET_SPLIT_FAIL=1 TEAM run 6 "task beta"); rc=$?
[ "$rc" -eq 0 ] && ok "run still exits 0 (degrades, not crashes)" || bad "exit $rc: $o"
if grep -q '^worker$' "$T/agent.log"; then bad "spawned a worker despite split failure"; else ok "no worker spawned when split fails"; fi
[ "$(countlog "$T/split.log")" -eq 0 ] && ok "no successful splits recorded" || bad "a split leaked through"
spent=$(sumlog "$T/spend.log")
[ "$spent" -le 6 ] && ok "still within root budget ($spent <= 6)" || bad "overspent under degradation: $spent"

echo "== the critic is mandatory (never an echo chamber) =="
# even with zero workers (all splits failed above), the critic must have run
grep -q '^critic$' "$T/agent.log" && ok "critic ran even with zero workers" || bad "worker-only run — critic skipped (bug)"
grep -q '^synth$'  "$T/agent.log" && ok "synthesis ran after the critic" || bad "no synth after degraded run"

echo "== fail closed: a budget too small to critique refuses to start =="
reset_logs
o=$(TEAM run 2 "task gamma" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "root budget < 3 refused (nonzero exit)" || bad "ran an un-critiquable team: $o"
case "$o" in *"too small"*) ok "explains why it refused" ;; *) bad "unclear refusal: $o" ;; esac
[ "$(countlog "$T/agent.log")" -eq 0 ] && ok "no agent spawned on refusal" || bad "spawned agents before refusing"

echo "== persona lenses (data-driven, fail-open) =="
cat > "$T/lenses.toml" <<'EOF'
[[lens]]
role = "captain"
name = "CAPTAINLENS"
style = "keep the structure coherent"
[[lens]]
role = "worker"
name = "WORKERLENS"
style = "trace every path, not the happy one"
[[lens]]
role = "critic"
name = "CRITICLENS"
style = "assume adversarial input"
EOF
reset_logs; : > "$T/prompt.log"
o=$(PROMPT_LOG="$T/prompt.log" ZISH_RUBRIC_DIR="$T" TEAM run 6 "task delta"); rc=$?
[ "$rc" -eq 0 ] && ok "lensed run exits 0" || bad "exit $rc: $o"
grep -q 'You approach this like CAPTAINLENS' "$T/prompt.log" && ok "captain prompt carries its lens" || bad "no captain lens injected"
grep -q 'You approach this like WORKERLENS' "$T/prompt.log" && ok "worker prompt carries its lens" || bad "no worker lens injected"
grep -q 'You approach this like CRITICLENS' "$T/prompt.log" && ok "critic prompt carries its lens" || bad "no critic lens injected"
grep -q '^worker$' "$T/agent.log" && ok "role detection still works with a lens prepended" || bad "lens broke role detection"

# fail-open: an override directory that lacks lenses.toml must NOT inject anything
# (an explicit override is explicit — it does not fall back to the default)
reset_logs; : > "$T/prompt2.log"
o=$(PROMPT_LOG="$T/prompt2.log" ZISH_RUBRIC_DIR="$T/no-such-rubrics" TEAM run 6 "task epsilon")
if grep -q 'You approach this like' "$T/prompt2.log"; then bad "injected a lens with no file (should fail-open)"; else ok "no lens file -> plain prompts (fail-open)"; fi

echo "== org experts: a worker consults a specialist (BTW-ASK, lateral edge) =="
cat > "$T/experts.toml" <<'EOF'
[[expert]]
name = "security"
style = "assume adversarial input"
[[expert]]
name = "git"
style = "worktrees and branches"
EOF
reset_logs; : > "$T/prompt3.log"
o=$(FAKE_WORKER_BTW=security PROMPT_LOG="$T/prompt3.log" ZISH_RUBRIC_DIR="$T" TEAM run 12 "ship a feature"); rc=$?
[ "$rc" -eq 0 ] && ok "run with consults exits 0" || bad "exit $rc: $o"
grep -q '^expert$' "$T/agent.log" && ok "a worker's BTW-ASK reached an expert" || bad "no expert was consulted"
grep -q "org's security expert" "$T/prompt3.log" && ok "consult routed to the NAMED expert (security)" || bad "wrong/no expert routed"
grep -q 'emit ONE line' "$T/prompt3.log" && ok "workers are offered the consult (experts exist)" || bad "worker brief missing the consult offer"
spent=$(sumlog "$T/spend.log")
[ "$spent" -le 12 ] && ok "org-funded consults stay within the root grant (spent $spent <= 12)" || bad "OVERSPENT via consults: $spent"

# unknown expert -> graceful, no consult, conservation intact
reset_logs
o=$(FAKE_WORKER_BTW=ghost ZISH_RUBRIC_DIR="$T" TEAM run 12 "ship a feature")
if grep -q '^expert$' "$T/agent.log"; then bad "consulted a non-existent expert"; else ok "unknown expert -> no consult (graceful)"; fi

# no experts file -> workers are not offered consults at all (fail-open)
reset_logs; : > "$T/prompt4.log"
o=$(FAKE_WORKER_BTW=security PROMPT_LOG="$T/prompt4.log" ZISH_RUBRIC_DIR="$T/no-such-rubrics" TEAM run 12 "x")
if grep -q 'emit ONE line' "$T/prompt4.log"; then bad "offered a consult with no experts file"; else ok "no experts file -> no consult offer (fail-open)"; fi

echo "== SIGPIPE: stdout closed on us kills the process (141), not a quiet 0 =="
if command -v python3 >/dev/null 2>&1; then
    sigpipe_status env HOME="$T/home" ZISH_FEAT_PATH="$T/feats" "$T/team" prompts; rc=$?
    [ "$rc" -eq 141 ] && ok "prompts with the stdout reader gone -> exit 141" || bad "closed stdout exit $rc (want 141)"
else
    printf '  \033[33mSKIP\033[0m SIGPIPE case (no python3)\n'
fi

echo
total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
fi
printf '\033[31mRED\033[0m — %d/%d failed\n' "$fail" "$total"; exit 1
