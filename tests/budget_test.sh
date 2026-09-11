#!/usr/bin/env bash
# budget tests — the conservation primitive: spawn = subdivision, not creation.
# The invariant under test: the sum of live balances in a tree can never exceed
# the root grant, and no split/spend can mint credits — not even under concurrent
# splits of the same parent (the fork-bomb hole).
set -u
cd "$(dirname "$0")/.."

T=$(mktemp -d /tmp/budget-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
export ZISH_BUDGET_DIR="$T/store"

echo "building budget..."
zig build-exe -lc feats/budget/main.zig -femit-bin="$T/budget" >/dev/null 2>&1 || {
    echo "FAIL: budget does not compile"; exit 1; }
B="$T/budget"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
bal() { "$B" balance "$1" 2>/dev/null; }
total() { "$B" tree "$1" 2>/dev/null | awk -F'\t' '$1=="total"{print $2}'; }
fresh() { rm -rf "$ZISH_BUDGET_DIR"; }

echo "== (a) happy path: new / split / spend =="
fresh
"$B" new root 1000 >/dev/null 2>&1 && ok "new root 1000" || bad "new failed"
"$B" split root child 400 >/dev/null 2>&1 && ok "split 400 to child" || bad "split failed"
[ "$(bal root)" = "600" ] && ok "parent debited (root=600)" || bad "root=$(bal root), want 600"
[ "$(bal child)" = "400" ] && ok "child credited (child=400)" || bad "child=$(bal child), want 400"
"$B" spend child 150 >/dev/null 2>&1 && ok "spend 150 from child" || bad "spend failed"
[ "$(bal child)" = "250" ] && ok "spend debited (child=250)" || bad "child=$(bal child), want 250"

echo "== new is exclusive =="
"$B" new root 5 >/dev/null 2>&1 && bad "duplicate new was allowed" || ok "duplicate new refused"

echo "== (b) over-split refused, parent unchanged =="
fresh
"$B" new r 100 >/dev/null 2>&1
before=$(bal r)
if "$B" split r kid 250 >/dev/null 2>&1; then bad "over-split (250 from 100) was allowed"; else ok "over-split refused (exit nonzero)"; fi
[ "$(bal r)" = "$before" ] && ok "parent unchanged after refused split ($before)" || bad "parent mutated: $(bal r) != $before"
"$B" balance kid >/dev/null 2>&1 && bad "child was created despite refusal" || ok "no child created on refusal"

echo "== (c) over-spend refused, balance unchanged =="
fresh
"$B" new r 100 >/dev/null 2>&1
if "$B" spend r 101 >/dev/null 2>&1; then bad "over-spend (101 from 100) was allowed"; else ok "over-spend refused (exit nonzero)"; fi
[ "$(bal r)" = "100" ] && ok "balance unchanged after refused spend (100)" || bad "balance mutated: $(bal r)"
# exact-balance spend is allowed (down to zero)
"$B" spend r 100 >/dev/null 2>&1 && [ "$(bal r)" = "0" ] && ok "spend-to-zero allowed" || bad "spend-to-zero failed: $(bal r)"
if "$B" spend r 1 >/dev/null 2>&1; then bad "spend from empty was allowed"; else ok "spend from empty refused"; fi

echo "== (d) conservation: sum of balances == root grant at every step =="
fresh
GRANT=1000
"$B" new root $GRANT >/dev/null 2>&1
[ "$(total root)" = "$GRANT" ] && ok "fresh root total == grant ($GRANT)" || bad "total=$(total root)"
"$B" split root a 400 >/dev/null 2>&1
[ "$(total root)" = "$GRANT" ] && ok "total conserved after split a (==$GRANT)" || bad "total=$(total root)"
"$B" split root b 300 >/dev/null 2>&1
"$B" split a a1 150 >/dev/null 2>&1
"$B" split a a2 50 >/dev/null 2>&1
"$B" split b b1 100 >/dev/null 2>&1
[ "$(total root)" = "$GRANT" ] && ok "total conserved after deep tree (==$GRANT)" || bad "total=$(total root)"
# spend anywhere in the tree lowers the total (never raises it) and can't exceed the grant
"$B" spend a1 150 >/dev/null 2>&1
t=$(total root)
[ "$t" -le "$GRANT" ] && ok "total never exceeds grant after spend ($t <= $GRANT)" || bad "total=$t > $GRANT"
[ "$t" = "850" ] && ok "spend lowered the tree total to 850" || bad "total=$t, want 850"
# you cannot split/spend your way past the root total: sum of leaf carves is capped
fresh
"$B" new root 100 >/dev/null 2>&1
"$B" split root x 60 >/dev/null 2>&1
"$B" split root y 60 >/dev/null 2>&1 && bad "second 60-split from a 100 pool was allowed (minting!)" || ok "cannot over-allocate past the grant (2nd 60-split refused)"
[ "$(total root)" = "100" ] && ok "grant intact after over-allocation attempt (100)" || bad "total=$(total root)"

echo "== (e) concurrent splits from one parent don't mint credits =="
fresh
POOL=100; CARVE=10; N=20   # at most 10 of 20 can succeed
"$B" new root $POOL >/dev/null 2>&1
succ="$T/succ"; : > "$succ"
for i in $(seq 1 $N); do
    ( "$B" split root "c$i" $CARVE >/dev/null 2>&1 && echo ok >> "$succ" ) &
done
wait
n=$(wc -l < "$succ")
tot=$(total root)
[ "$tot" = "$POOL" ] && ok "total conserved under $N concurrent splits (==$POOL, no minting)" || bad "total=$tot != $POOL (lost update / minted credits)"
[ "$n" -le $((POOL / CARVE)) ] && ok "no more than $((POOL/CARVE)) splits succeeded ($n)" || bad "$n splits succeeded, > $((POOL/CARVE)) — overspent"
rootbal=$(bal root)
[ "$rootbal" = "$((POOL - CARVE * n))" ] && ok "root balance matches successes (root=$rootbal, n=$n)" || bad "root=$rootbal, expected $((POOL - CARVE*n))"

echo "== (f) SIGPIPE: a closed stdout kills budget (141), not a quiet 0 =="
# A filter must die when the reader of its stdout is gone. `tree` is the one
# verb with unbounded output; long ids make 300 accounts clear the 64 KiB pipe
# buffer, so the write that lands after `head -c1` has exited fails. Full
# `std.process.Init` installs a no-op SIGPIPE handler — `feat.restoreSigpipe()`
# puts the default back. Red without it (EPIPE swallowed, exit 0), green (141).
fresh
"$B" new root 1000 >/dev/null 2>&1
pad=$(printf '%*s' 390 ''); pad=${pad// /x}
for i in $(seq 1 300); do
    "$B" split root "acc$i$pad" 1 >/dev/null 2>&1
done
env -i ZISH_BUDGET_DIR="$ZISH_BUDGET_DIR" "$B" tree root 2>/dev/null | head -c1 >/dev/null
rc=${PIPESTATUS[0]}
[ "$rc" -eq 141 ] && ok "budget tree, stdout reader gone -> exit 141 (SIGPIPE)" \
    || bad "budget tree over a closed stdout -> exit $rc (want 141)"

echo
tot=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
fi
printf '\033[31mRED\033[0m — %d/%d failed\n' "$fail" "$tot"; exit 1
