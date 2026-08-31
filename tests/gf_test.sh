#!/usr/bin/env bash
# gf feat-fetcher tests: install from file:// tarballs into a private feat
# root. The archive is adversarial input, so most cases here are refusals —
# a tier escape in the name, a symlinked binary, a shadowing name — plus the
# happy path proving the quarantine actually holds (manifest rewritten to
# extra, stripped env observable at run time).
set -u
cd "$(dirname "$0")/.."

ZISH=${ZISH:-./zig-out/bin/zish}
T=$(mktemp -d /tmp/gf-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/feats"

echo "building gf..."
zig build-exe -lc feats/gf/main.zig -femit-bin="$T/gf" >/dev/null 2>&1 || {
    echo "FAIL: gf does not compile"; exit 1; }

GF() { HOME="$T/home" ZISH_FEAT_PATH="$T/feats" "$T/gf" "$@"; }
ZC() { HOME="$T/home" ZISH_FEAT_PATH="$T/feats" ZISH_BYPASS_PASSWORD=1 "$ZISH" -c "$@"; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# helper: build a tarball from a staging dir (feat.toml + bin/ at top level)
pack() { # $1 = staging dir, $2 = out tarball
    tar -czf "$2" -C "$1" .
}

# ---- happy path: install, quarantine, run ---------------------------------
S="$T/stage1"; mkdir -p "$S/bin"
cat > "$S/feat.toml" <<'EOF'
name = "gfdemo"
tier = "standard"
bin = "gfdemo"
EOF
cat > "$S/bin/gfdemo" <<'EOF'
#!/bin/sh
echo "demo-ran secret=${GF_SECRET:-none}"
EOF
pack "$S" "$T/gfdemo.tar.gz"

if GF "file://$T/gfdemo.tar.gz" >"$T/out1" 2>&1; then
    ok "install from file:// url"
else
    bad "install from file:// url: $(cat "$T/out1")"
fi

[ -x "$T/feats/extra/gfdemo/bin/gfdemo" ] \
    && ok "lands in the extra tier" || bad "not in extra tier"

grep -q 'tier = "extra"' "$T/feats/extra/gfdemo/feat.toml" \
    && ok "manifest tier rewritten to extra (tarball claimed standard)" \
    || bad "manifest still claims its own tier"

grep -q "mv .*extra/gfdemo .*standard" "$T/out1" \
    && ok "install message shows the promotion step" \
    || bad "no promotion hint in install output"

out=$(GF_SECRET=leaked ZC gfdemo)
case "$out" in
    *"demo-ran secret=none"*) ok "extra tier strips the environment at run time" ;;
    *"demo-ran"*)             bad "feat ran but saw the parent env: $out" ;;
    *)                        bad "installed feat did not run: $out" ;;
esac

# ---- refusal: double install ----------------------------------------------
GF "file://$T/gfdemo.tar.gz" >"$T/out2" 2>&1 \
    && bad "second install of same feat was allowed" \
    || ok "double install refused"

# ---- refusal: name is a path escape ---------------------------------------
S="$T/stage2"; mkdir -p "$S/bin"
printf 'name = "../standard/evil"\nbin = "x"\n' > "$S/feat.toml"
echo '#!/bin/sh' > "$S/bin/x"
pack "$S" "$T/evil.tar.gz"
GF "file://$T/evil.tar.gz" >/dev/null 2>&1 \
    && bad "tier-escape name was allowed" || ok "path-escape name refused"
[ -e "$T/feats/standard/evil" ] && bad "tier escape actually landed" || true

# ---- refusal: symlink in bin/ ---------------------------------------------
S="$T/stage3"; mkdir -p "$S/bin"
printf 'name = "symfeat"\nbin = "symfeat"\n' > "$S/feat.toml"
ln -s /etc/passwd "$S/bin/symfeat"
pack "$S" "$T/sym.tar.gz"
GF "file://$T/sym.tar.gz" >/dev/null 2>&1 \
    && bad "symlinked bin was allowed" || ok "symlink member refused"

# ---- refusal: stray file outside feat.toml + bin/ -------------------------
S="$T/stage4"; mkdir -p "$S/bin"
printf 'name = "strayfeat"\nbin = "strayfeat"\n' > "$S/feat.toml"
echo '#!/bin/sh' > "$S/bin/strayfeat"
echo x > "$S/extra-file"
pack "$S" "$T/stray.tar.gz"
GF "file://$T/stray.tar.gz" >/dev/null 2>&1 \
    && bad "stray top-level file was allowed" || ok "stray file refused"

# ---- refusal: name shadows a real binary ----------------------------------
S="$T/stage5"; mkdir -p "$S/bin"
printf 'name = "ls"\nbin = "ls"\n' > "$S/feat.toml"
echo '#!/bin/sh' > "$S/bin/ls"
pack "$S" "$T/shadow.tar.gz"
GF "file://$T/shadow.tar.gz" >/dev/null 2>&1 \
    && bad "shadowing name 'ls' was allowed" || ok "shadowing name refused"

# ---- source package: gf builds it locally ---------------------------------
S="$T/stage_src"; mkdir -p "$S/src"
cat > "$S/feat.toml" <<'EOF'
name = "srcdemo"
tier = "standard"
bin = "srcdemo"
lang = "c"
src = "main.c"
EOF
cat > "$S/src/main.c" <<'EOF'
#include <stdio.h>
int main(void){ printf("built-from-source\n"); return 0; }
EOF
pack "$S" "$T/srcdemo.tar.gz"

if GF "file://$T/srcdemo.tar.gz" >"$T/outsrc" 2>&1; then
    ok "source package installs (gf compiled it)"
else
    bad "source package failed: $(cat "$T/outsrc")"
fi
out=$(ZC srcdemo 2>&1)
[ "$out" = "built-from-source" ] \
    && ok "locally-built binary runs" || bad "built binary bad output: $out"
[ -f "$T/feats/extra/srcdemo/src/main.c" ] \
    && ok "source ships alongside for review/audit" || bad "source not retained"

# refusal: source filename tries to escape src/
S="$T/stage_srcesc"; mkdir -p "$S/src"
printf 'name = "esc"\nbin = "esc"\nlang = "c"\nsrc = "../evil.c"\n' > "$S/feat.toml"
echo 'int main(){return 0;}' > "$S/src/x.c"
pack "$S" "$T/srcesc.tar.gz"
GF "file://$T/srcesc.tar.gz" >/dev/null 2>&1 \
    && bad "src path-escape allowed" || ok "src path-escape refused"

# ---- install ledger --------------------------------------------------------
L="$T/feats/ledger.jsonl"
if [ -f "$L" ] && grep -q '"t":"install","name":"gfdemo","sha256":"[0-9a-f]\{64\}"' "$L"; then
    ok "install attested in the ledger (name + content sha256)"
else
    bad "ledger missing or malformed: $(cat "$L" 2>/dev/null)"
fi
# two successful installs so far (gfdemo binary + srcdemo source); every
# refusal between them must have written nothing
n=$(wc -l < "$L" 2>/dev/null || echo 0)
[ "$n" -eq 2 ] && ok "refused installs leave no ledger entries" \
    || bad "expected 2 ledger lines (gfdemo+srcdemo), got $n"
grep -q '"name":"srcdemo"' "$L" && ok "source install also attested" \
    || bad "source install missing from ledger"

# ---- review-on-install -----------------------------------------------------
# Stage the REAL agent feat (built with mock transport) so gf can exec it as
# the reviewer, plus the rubric and a mock verdict. Then a source install must
# gain a review record joined to its install by sha256.
echo "building agent feat for review tests..."
mkdir -p "$T/feats/standard/agent/bin" "$T/rubrics"
if zig build-exe -lc feats/agent/main.zig -femit-bin="$T/feats/standard/agent/bin/agent" >/dev/null 2>&1; then
    printf 'name = "agent"\ntier = "standard"\nkind = "session"\nbin = "agent"\n' > "$T/feats/standard/agent/feat.toml"
    cp -f rubrics/feat-review-v1.toml "$T/rubrics/feat-review-v1.toml"
    # mock verdict: content is a JSON verdict; wrap as an OpenRouter completion
    python3 - "$T/verdict-mock.jsonl" <<'PY'
import json, sys
verdict = {"analysis": "single-file C tool, does what the manifest claims, no unsafe ops",
           "scores": {"safety": 9, "fidelity": 9, "correctness": 8, "quality": 8},
           "verdict": "pass"}
completion = {"choices": [{"message": {"content": json.dumps(verdict)}}]}
open(sys.argv[1], "w").write(json.dumps({"status": 200, "body": json.dumps(completion)}) + "\n")
PY
    GFR() { HOME="$T/home" ZISH_FEAT_PATH="$T/feats" \
            ZISH_RUBRIC_DIR="$T/rubrics" ZISH_JUDGE_MOCK="$T/verdict-mock.jsonl" \
            "$T/gf" "$@"; }

    # a fresh source package so this install is the one that gets reviewed
    S="$T/stage_rev"; mkdir -p "$S/src"
    printf 'name = "revdemo"\ntier = "standard"\nbin = "revdemo"\nlang = "c"\nsrc = "main.c"\n' > "$S/feat.toml"
    echo 'int main(void){return 0;}' > "$S/src/main.c"
    pack "$S" "$T/revdemo.tar.gz"

    if GFR "file://$T/revdemo.tar.gz" >"$T/outrev" 2>&1; then
        ok "source install with agent staged triggers review"
    else
        bad "review install failed: $(cat "$T/outrev")"
    fi
    grep -q "verdict pass" "$T/outrev" \
        && ok "install output reports the review verdict" \
        || bad "no verdict in output: $(cat "$T/outrev")"
    # the ledger now has an install AND a review record for revdemo's sha
    revsha=$(grep '"name":"revdemo"' "$L" | sed 's/.*"sha256":"\([0-9a-f]*\)".*/\1/')
    if grep '"t":"review"' "$L" | grep -q "\"sha256\":\"$revsha\""; then
        ok "review verdict recorded in ledger, joined by sha256"
    else
        bad "no review record joined to the install sha"
    fi
    grep '"t":"review"' "$L" | grep -q '"verdict":"pass"' \
        && ok "bare pass/fail lifted to top level for greppability" \
        || bad "verdict word not lifted"

    # decoupling: with the agent binary gone, a source install still succeeds
    # and simply notes it is unreviewed — no review record, no failure
    mv "$T/feats/standard/agent/bin/agent" "$T/agent.bak"
    S="$T/stage_norev"; mkdir -p "$S/src"
    printf 'name = "norevdemo"\ntier = "standard"\nbin = "norevdemo"\nlang = "c"\nsrc = "main.c"\n' > "$S/feat.toml"
    echo 'int main(void){return 0;}' > "$S/src/main.c"
    pack "$S" "$T/norevdemo.tar.gz"
    if GFR "file://$T/norevdemo.tar.gz" >"$T/outnorev" 2>&1 \
        && [ -x "$T/feats/extra/norevdemo/bin/norevdemo" ]; then
        ok "install succeeds even when review cannot run (decoupled)"
    else
        bad "review failure broke the install: $(cat "$T/outnorev")"
    fi
    norevsha=$(grep '"name":"norevdemo"' "$L" | sed 's/.*"sha256":"\([0-9a-f]*\)".*/\1/')
    grep '"t":"review"' "$L" | grep -q "$norevsha" \
        && bad "a review record appeared without a reviewer" \
        || ok "no reviewer means no verdict record (install stands unreviewed)"
    mv "$T/agent.bak" "$T/feats/standard/agent/bin/agent"
else
    printf '  \033[33mSKIP\033[0m review tests (agent feat did not build)\n'
fi

# ---- gf status: the read-side fold ----------------------------------------
# Agent rendering (--json) must be parseable and carry the review verdict;
# human rendering must show the feat and a verdict word.
sj=$(GF status --json 2>/dev/null)
if echo "$sj" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'feats' in d; assert any(f['name']=='revdemo' and f['reviews'] and f['reviews'][0]['verdict']=='pass' for f in d['feats'])" 2>/dev/null; then
    ok "status --json is valid, agent-parseable, carries the verdict"
else
    bad "status --json bad: $sj"
fi
sh=$(GF status revdemo 2>/dev/null)
case "$sh" in
    *revdemo*pass*) ok "status <feat> human view shows verdict" ;;
    *) bad "human status missing verdict: $sh" ;;
esac
GF status norevdemo 2>/dev/null | grep -q "unreviewed" \
    && ok "unreviewed feat shown as unreviewed (not hidden, not faked)" \
    || bad "unreviewed feat not surfaced honestly"

# ---- no temp debris left behind -------------------------------------------
leftovers=$(find "$T/feats" -maxdepth 1 -name '.gf-tmp-*' | wc -l)
[ "$leftovers" -eq 0 ] && ok "no temp dirs left after refusals" \
    || bad "$leftovers temp dirs left behind"

# ---- the distribution loop: dist-agent tarball installs -------------------
if make dist-agent >/dev/null 2>&1 && ls dist/agent-*.tar.gz >/dev/null 2>&1; then
    AGT=$(ls dist/agent-*.tar.gz | head -1)
    if GF "file://$PWD/$AGT" >/dev/null 2>&1 \
        && [ -x "$T/feats/extra/agent/bin/agent" ]; then
        ok "dist-agent tarball installs via gf"
    else
        bad "dist-agent tarball failed to install"
    fi
else
    bad "make dist-agent produced no tarball"
fi

echo
total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
fi
printf '\033[31mRED\033[0m — %d/%d failed\n' "$fail" "$total"; exit 1
