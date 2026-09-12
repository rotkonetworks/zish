#!/usr/bin/env bash
# reviewer benchmark — score a PKGBUILD reviewer against labeled ground truth.
#
# A "reviewer" is `agent --judge <rubric> <pkgbuild>` on some model. This harness
# runs it over benchmark/pkgbuilds/*.PKGBUILD, compares each verdict to
# benchmark/labels.jsonl, and reports ACCURACY plus the confusion breakdown. The
# number it prints is what would feed reputation: trust earned by measured
# accuracy against hidden ground truth can't be faked by spinning up more keys.
#
# The dangerous error is a FALSE NEGATIVE — malware labeled `fail` that the
# reviewer passes. Any false negative fails the benchmark (nonzero exit): a
# reviewer that greenlights an attack is worse than useless.
#
# Modes:
#   ./run.sh              deterministic mock run (perfect reviewer -> 100%, exit 0)
#   ./run.sh --selftest   prove the harness itself: green run, then a flipped
#                         verdict is caught as a false negative (RED->GREEN)
#   ZISH_BENCH_LIVE=1 ./run.sh                 live, using ~/.zish/openrouter.key
#   ZISH_AGENT_BACKEND=ollama ZISH_AGENT_MODEL=qwen3:1.7b ./run.sh   live, local
#
# Env: ZISH_BENCH_RUBRIC overrides the rubric path; ZISH_AGENT_* pass through to
# the agent (backend, model, timeout) in live mode.
set -u
cd "$(dirname "$0")/.."

RUBRIC="${ZISH_BENCH_RUBRIC:-feats/aur/rubrics/pkgbuild-review-v1.toml}"
CORPUS="benchmark/pkgbuilds"
LABELS="benchmark/labels.jsonl"
AGENT=/tmp/agent-bench

selftest=0
live=0
[ "${1:-}" = "--selftest" ] && selftest=1
[ "${1:-}" = "--live" ] && live=1
[ -n "${ZISH_BENCH_LIVE:-}" ] && live=1
[ -n "${ZISH_AGENT_BACKEND:-}" ] && live=1

command -v python3 >/dev/null 2>&1 || { echo "benchmark: python3 required"; exit 2; }
[ -f "$RUBRIC" ] || { echo "benchmark: rubric not found: $RUBRIC"; exit 2; }

echo "using the agent feat built by zig build..."
cp "${FEAT_BIN:-$PWD/zig-out/share/zish/feats/standard}/agent/bin/agent" "$AGENT" || {
    echo "benchmark: agent not built — run: zig build -Dfeats=all"; exit 2; }

T=$(mktemp -d /tmp/bench-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.zish"
H="$T/home"

opposite() { [ "$1" = "pass" ] && echo fail || echo pass; }

# emit a mock completion whose verdict word is $1 into file $2
mkmock() {
    python3 - "$1" "$2" <<'PY'
import json, sys
word = sys.argv[1]
aud = "blob" if word == "pass" else "source"
verdict = {"analysis": "benchmark mock (%s)" % word,
           "scores": {"safety": 9, "provenance": 9, "change_intent": 9, "transparency": 9},
           "verdict": word, "auditability": aud}
completion = {"choices": [{"message": {"content": json.dumps(verdict)}}]}
open(sys.argv[2], "w").write(json.dumps({"status": 200, "body": json.dumps(completion)}) + "\n")
PY
}

# run one review; echo the verdict word (pass|fail|unknown)
verdict_of() {
    local pkgbuild="$1" mockfile="$2" out
    if [ -n "$mockfile" ]; then
        out=$(HOME="$H" "$AGENT" --judge --mock "$mockfile" "$RUBRIC" "$pkgbuild" 2>/dev/null)
    else
        out=$(HOME="$H" ZISH_AGENT_BACKEND="${ZISH_AGENT_BACKEND:-}" \
              ZISH_AGENT_MODEL="${ZISH_AGENT_MODEL:-}" ZISH_AGENT_TIMEOUT="${ZISH_AGENT_TIMEOUT:-}" \
              "$AGENT" --judge "$RUBRIC" "$pkgbuild" 2>/dev/null)
    fi
    printf '%s' "$out" | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read() or "{}"); print(d.get("verdict","unknown") if isinstance(d,dict) else "unknown")
except Exception:
    print("unknown")'
}

# run the full corpus. args: <mode: mock|live>  <flip-name-or-empty>
# returns 0 iff no false negatives; prints the report + a machine summary line.
bench_run() {
    local mode="$1" flip="${2:-}"
    local reviewer total=0 correct=0 fneg=0 fpos=0 unrev=0
    if [ "$mode" = live ]; then
        reviewer="${ZISH_AGENT_MODEL:-openrouter-default}"
    else
        reviewer="mock:perfect"; [ -n "$flip" ] && reviewer="mock:flip($flip)"
    fi

    printf '\n  %-22s %-8s %-8s %s\n' "case" "expect" "verdict" "result"
    printf '  %s\n' "-------------------------------------------------------------"
    while IFS=$'\t' read -r name expect note; do
        [ -z "$name" ] && continue
        local pkgbuild="$CORPUS/$name.PKGBUILD" got
        if [ ! -f "$pkgbuild" ]; then echo "  MISSING $pkgbuild"; continue; fi
        total=$((total+1))
        if [ "$mode" = mock ]; then
            local want="$expect"
            [ "$name" = "$flip" ] && want=$(opposite "$expect")
            local mf="$T/mock-$name.jsonl"; mkmock "$want" "$mf"
            got=$(verdict_of "$pkgbuild" "$mf")
        else
            got=$(verdict_of "$pkgbuild" "")
        fi

        local res col
        if [ "$got" = "$expect" ]; then
            correct=$((correct+1)); res="ok"; col=$'\033[32m'
        elif [ "$got" = "unknown" ]; then
            unrev=$((unrev+1)); res="UNREVIEWED"; col=$'\033[33m'
        elif [ "$expect" = fail ] && [ "$got" = pass ]; then
            fneg=$((fneg+1)); res="FALSE-NEG!"; col=$'\033[31m'   # malware passed — dangerous
        else
            fpos=$((fpos+1)); res="false-pos"; col=$'\033[33m'    # clean blocked — annoying
        fi
        printf '  %-22s %-8s %-8s %s%s\033[0m\n' "$name" "$expect" "$got" "$col" "$res"
    done < <(python3 -c 'import json,sys
for l in open("'"$LABELS"'"):
    l=l.strip()
    if not l: continue
    d=json.loads(l); print("%s\t%s\t%s" % (d["name"], d["expect"], d.get("note","")))')

    local acc
    acc=$(python3 -c "print('%.3f' % (($correct)/($total) if $total else 0))")
    echo
    printf '  reviewer=%s  cases=%d  correct=%d  accuracy=%s\n' "$reviewer" "$total" "$correct" "$acc"
    printf '  \033[31mfalse_neg=%d\033[0m (malware passed)   false_pos=%d (clean blocked)   unreviewed=%d\n' \
        "$fneg" "$fpos" "$unrev"
    local gate=true; [ "$fneg" -gt 0 ] && gate=false
    # machine-readable summary — this line is the reputation-feeding score
    printf '{"reviewer":"%s","cases":%d,"correct":%d,"accuracy":%s,"false_neg":%d,"false_pos":%d,"unreviewed":%d,"pass_gate":%s}\n' \
        "$reviewer" "$total" "$correct" "$acc" "$fneg" "$fpos" "$unrev" "$gate"
    [ "$fneg" -eq 0 ]
}

if [ "$selftest" -eq 1 ]; then
    echo "== self-test: green run (perfect reviewer) should score 100% and pass =="
    bench_run mock ""; g=$?
    echo
    echo "== self-test: flip one malicious case to PASS -> must be caught as false-neg =="
    bench_run mock "curl-pipe-sh"; r=$?
    echo
    if [ "$g" -eq 0 ] && [ "$r" -ne 0 ]; then
        printf '\033[32mSELFTEST OK\033[0m — perfect run passes; a lying verdict is caught (false-neg gate fires)\n'
        exit 0
    fi
    printf '\033[31mSELFTEST FAILED\033[0m — green rc=%d (want 0), flipped rc=%d (want nonzero)\n' "$g" "$r"
    exit 1
fi

if [ "$live" -eq 1 ]; then
    echo "== live reviewer benchmark =="
    bench_run live ""
    exit $?
fi

echo "== deterministic (mock) reviewer benchmark =="
bench_run mock ""
exit $?
