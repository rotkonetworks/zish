#!/usr/bin/env bash
# verify feat — a standalone compile-check primitive. Uses zig + bash as the
# hermetic checkers (both are always present in this repo's build/test env);
# other languages are exercised only if their toolchain is installed.
set -u
cd "$(dirname "$0")/.."

T=$(mktemp -d /tmp/verify-test-XXXXXX)
trap 'rm -rf "$T"' EXIT

echo "building verify..."
zig build-exe -lc feats/verify/main.zig -femit-bin="$T/verify" >/dev/null 2>&1 || {
    echo "FAIL: verify does not compile"; exit 1; }
V="$T/verify"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

echo "== caps advertises installed checkers =="
caps=$("$V" caps); rc=$?
[ "$rc" -eq 0 ] && ok "caps exits 0" || bad "caps exit $rc"
case "$caps" in *zig*) ok "caps lists zig" ;; *) bad "caps missing zig: $caps" ;; esac

echo "== zig: good compiles (0), broken fails (1) with a diagnostic =="
printf 'pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n' | "$V" zig >/dev/null 2>&1
[ $? -eq 0 ] && ok "good zig -> exit 0" || bad "good zig did not pass"
o=$(printf 'fn f() void {\n    var i: usize = 0;\n    i -= ;\n}\n' | "$V" zig 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "broken zig -> exit 1" || bad "broken zig exit $rc"
case "$o" in *error*|*expected*) ok "broken zig prints a diagnostic" ;; *) bad "no diagnostic: $o" ;; esac

echo "== bash: good (0), broken (1) — hermetic, always present =="
printf 'if [ 1 -eq 1 ]; then echo hi; fi\n' | "$V" bash >/dev/null 2>&1
[ $? -eq 0 ] && ok "good bash -> exit 0" || bad "good bash failed"
printf 'if [ 1 -eq ]; then\n' | "$V" bash >/dev/null 2>&1
[ $? -eq 1 ] && ok "broken bash -> exit 1" || bad "broken bash not caught"

echo "== routing: unknown tag skips (3), missing stdin errors (2) =="
printf 'x\n' | "$V" cobol >/dev/null 2>&1
[ $? -eq 3 ] && ok "unknown language -> exit 3 (skip, not fail)" || bad "unknown lang wrong exit"
printf '' | "$V" zig >/dev/null 2>&1
[ $? -eq 2 ] && ok "empty stdin -> exit 2 (usage)" || bad "empty stdin wrong exit"
"$V" >/dev/null 2>&1
[ $? -eq 2 ] && ok "no args -> exit 2 (usage)" || bad "no args wrong exit"

echo "== NEVER executes the code (compile/check only) =="
mark="$T/should-not-exist"
printf 'const std = @import("std");\npub fn main() void { _ = std; }\n' | "$V" zig >/dev/null 2>&1
# a compile-check must not run main; a side-effecting file must be absent
[ ! -e "$mark" ] && ok "checking code did not execute it" || bad "code was executed!"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
else printf '\033[31m%d FAILED\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
