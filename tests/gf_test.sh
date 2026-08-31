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

# ---- install ledger --------------------------------------------------------
L="$T/feats/ledger.jsonl"
if [ -f "$L" ] && grep -q '"t":"install","name":"gfdemo","sha256":"[0-9a-f]\{64\}"' "$L"; then
    ok "install attested in the ledger (name + content sha256)"
else
    bad "ledger missing or malformed: $(cat "$L" 2>/dev/null)"
fi
n=$(wc -l < "$L" 2>/dev/null || echo 0)
[ "$n" -eq 1 ] && ok "refused installs leave no ledger entries" \
    || bad "expected 1 ledger line after refusals, got $n"

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
