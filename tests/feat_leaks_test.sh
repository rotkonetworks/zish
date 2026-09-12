#!/bin/sh
# Fail if any feat reports a memory leak on a happy path.
#
# ReleaseSafe's default allocator (std.heap.DebugAllocator) tracks allocations
# and prints a report to stderr for any it never saw freed:
#
#     error(DebugAllocator): memory address 0x… leaked:
#
# For a feat that is about to exit this is harmless — the kernel reclaims it —
# so it is NOT a growing leak. It is two other things: multi-line noise on
# stderr that a caller reads as an error, and a real bug in a *session* feat,
# which lives for a whole session rather than one shot.
#
# Seven feats leaked their argv slice (`toSlice(init.gpa)` rather than
# `toSlice(init.arena.allocator())`, see feats/lib/feat.zig) for exactly as long
# as nothing read stderr: the dev staging compiled with -O ReleaseFast, where
# the tracking is compiled out, so only the shipped ReleaseSafe build showed it.
# This case is what makes that visible instead of discoverable by accident.
#
# Usage: tests/feat_leaks_test.sh   (needs: zig build -Dfeats=all first)

set -u

FEAT_BIN=${FEAT_BIN:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/share/zish/feats/standard}

T=$(mktemp -d /tmp/zish-leaks-XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" ZISH_BUDGET_DIR="$T/budget"
mkdir -p "$HOME" "$ZISH_BUDGET_DIR"
printf 'a\nb\nc\n' > "$T/in.txt"
printf '{"k":1}\n{"k":2}\n' > "$T/in.jsonl"

pass=0
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# leak NAME ARGS...  (input, if any, is redirected by the case itself)
leak() {
    name="$1"; shift
    bin="$FEAT_BIN/$name/bin/$name"
    if [ ! -x "$bin" ]; then
        bad "$name: no binary at $bin — run: zig build -Dfeats=all"
        return
    fi
    "$@" >/dev/null 2>"$T/err"
    if grep -q 'leaked' "$T/err"; then
        bad "$name leaks on the happy path"
        sed 's/^/       /' "$T/err" | head -4
    else
        ok "$name: no leak report"
    fi
}

echo "== feats: no leak report on a happy path =="
leak cnt   sh -c "\"$FEAT_BIN/cnt/bin/cnt\" $T/in.txt"
leak pk    sh -c "\"$FEAT_BIN/pk/bin/pk\" -n 1 $T/in.txt"
leak frq   sh -c "\"$FEAT_BIN/frq/bin/frq\" $T/in.txt"
leak snf   sh -c "\"$FEAT_BIN/snf/bin/snf\" $T/in.txt"
leak jls   sh -c "\"$FEAT_BIN/jls/bin/jls\" k < $T/in.jsonl"
leak calc  "$FEAT_BIN/calc/bin/calc" 1+1
leak para  "$FEAT_BIN/para/bin/para" -n 1 /bin/echo '{}' ::: a b
leak gf    "$FEAT_BIN/gf/bin/gf" list
leak budget "$FEAT_BIN/budget/bin/budget" new 5
leak verify "$FEAT_BIN/verify/bin/verify" caps
leak web   "$FEAT_BIN/web/bin/web" --help
leak ask   "$FEAT_BIN/ask/bin/ask" --help
leak bus   "$FEAT_BIN/bus/bin/bus" --help
leak agent "$FEAT_BIN/agent/bin/agent" --help
leak team  "$FEAT_BIN/team/bin/team" --help
leak aur   "$FEAT_BIN/aur/bin/aur" --help

echo
total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
fi
printf '\033[31mRED\033[0m — %d/%d failed\n' "$fail" "$total"; exit 1
