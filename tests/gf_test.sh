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
    cp -f feats/gf/rubrics/feat-review-v1.toml "$T/rubrics/feat-review-v1.toml"
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

# ---- install-by-name: the feat index (crates.io-for-feats, minimal) --------
# A static JSONL index maps name -> {url, sha256}. `gf install <name>` resolves
# against it and PINS the sha: the index is the trust root, gf refuses any bytes
# that don't match. No server — just a file:// URL here.
IS="$T/stage-idx"; mkdir -p "$IS/bin"
cat > "$IS/feat.toml" <<'EOF'
name = "idxdemo"
tier = "standard"
bin = "idxdemo"
EOF
printf '#!/bin/sh\necho idxdemo-ran\n' > "$IS/bin/idxdemo"
pack "$IS" "$T/idxdemo.tar.gz"
IDX_SHA=$(sha256sum "$T/idxdemo.tar.gz" | cut -d' ' -f1)

# a good index (correct sha) and a tampered one (wrong sha)
printf '{"name":"idxdemo","url":"file://%s/idxdemo.tar.gz","sha256":"%s","version":"0.1.0"}\n' "$T" "$IDX_SHA" > "$T/index.jsonl"
printf '{"name":"idxdemo","url":"file://%s/idxdemo.tar.gz","sha256":"%s","version":"0.1.0"}\n' "$T" "0000000000000000000000000000000000000000000000000000000000000000" > "$T/index-bad.jsonl"

IGF() { HOME="$T/home" ZISH_FEAT_PATH="$T/feats" ZISH_FEAT_INDEX="file://$1" "$T/gf" "${@:2}"; }

if IGF "$T/index.jsonl" install idxdemo >"$T/oi1" 2>&1 && [ -x "$T/feats/extra/idxdemo/bin/idxdemo" ]; then
    ok "gf install <name> resolves the index and installs"
else
    bad "install-by-name failed: $(cat "$T/oi1")"
fi

# the ledger records it under the same content hash the index pinned
if grep -q "\"sha256\":\"$IDX_SHA\"" "$T/feats/ledger.jsonl" 2>/dev/null; then
    ok "install-by-name attested under the index's sha256"
else
    bad "ledger missing the pinned sha: $(cat "$T/feats/ledger.jsonl" 2>/dev/null)"
fi

# tampered index (wrong sha) must be refused, nothing staged
rm -rf "$T/feats/extra/idxdemo"
if IGF "$T/index-bad.jsonl" install idxdemo >"$T/oi2" 2>&1; then
    bad "sha mismatch was NOT refused"
else
    grep -q "mismatch" "$T/oi2" && ok "sha mismatch refused (index is the trust root)" || bad "wrong error: $(cat "$T/oi2")"
    [ ! -e "$T/feats/extra/idxdemo" ] && ok "nothing staged on a mismatch" || bad "feat staged despite mismatch"
fi

# unknown name -> a clear miss, not a crash
if IGF "$T/index.jsonl" install nope >"$T/oi3" 2>&1; then
    bad "unknown name unexpectedly succeeded"
else
    grep -q "not found in the feat index" "$T/oi3" && ok "unknown name reports an index miss" || bad "wrong miss error: $(cat "$T/oi3")"
fi

# no ZISH_FEAT_INDEX set -> fall back to the built-in default index (zero-config,
# the smooth path), not an error. The test fixture name is not in the default
# index (and with no release the default URL 404s), so this misses against the
# DEFAULT url whether the fetch fails offline or returns and misses online — the
# miss message names the default index either way.
if HOME="$T/home" ZISH_FEAT_PATH="$T/feats" "$T/gf" install idxdemo >"$T/oi4" 2>&1; then
    bad "test fixture unexpectedly resolved against the default index"
else
    grep -q "github.com/rotkonetworks/zish" "$T/oi4" && ok "no index set -> uses the built-in default index (zero-config)" || bad "default index not used: $(cat "$T/oi4")"
fi

# ---- arch gate: an index entry naming an arch must match this host ----------
HARCH=$(uname -m)  # x86_64 / aarch64 — the strings gf's HOST_ARCH uses
case "$HARCH" in aarch64) WARCH=x86_64;; *) WARCH=aarch64;; esac
rm -rf "$T/feats/extra/idxdemo"
# a wrong-arch-only entry is filtered out -> install misses
printf '{"name":"idxdemo","arch":"%s","url":"file://%s/idxdemo.tar.gz","sha256":"%s","version":"0.1.0"}\n' "$WARCH" "$T" "$IDX_SHA" > "$T/index-wrongarch.jsonl"
if IGF "$T/index-wrongarch.jsonl" install idxdemo >"$T/oa1" 2>&1; then
    bad "wrong-arch entry was installed"
else
    grep -q "not found in the feat index" "$T/oa1" && ok "wrong-arch entry is filtered (arch gate)" || bad "wrong-arch wrong error: $(cat "$T/oa1")"
fi
# a matching-arch entry installs
printf '{"name":"idxdemo","arch":"%s","url":"file://%s/idxdemo.tar.gz","sha256":"%s","version":"0.1.0"}\n' "$HARCH" "$T" "$IDX_SHA" > "$T/index-arch.jsonl"
if IGF "$T/index-arch.jsonl" install idxdemo >"$T/oa2" 2>&1 && [ -x "$T/feats/extra/idxdemo/bin/idxdemo" ]; then
    ok "matching-arch entry installs (arch gate)"
else
    bad "matching-arch install failed: $(cat "$T/oa2")"
fi

# ---- gf list folds the index into a readable catalog -----------------------
if IGF "$T/index.jsonl" list >"$T/ol1" 2>&1 && grep -q "idxdemo" "$T/ol1"; then
    ok "gf list shows feats from the index"
else
    bad "gf list failed: $(cat "$T/ol1")"
fi

# ---- gf remove uninstalls a feat -------------------------------------------
IGF "$T/index.jsonl" install idxdemo >/dev/null 2>&1  # ensure it is installed
if HOME="$T/home" ZISH_FEAT_PATH="$T/feats" "$T/gf" remove idxdemo >"$T/orm1" 2>&1 && [ ! -e "$T/feats/extra/idxdemo" ]; then
    ok "gf remove uninstalls a feat"
else
    bad "gf remove failed: $(cat "$T/orm1")"
fi
# removing something that is not installed -> a clear error, not a crash
if HOME="$T/home" ZISH_FEAT_PATH="$T/feats" "$T/gf" remove nope >"$T/orm2" 2>&1; then
    bad "remove of a missing feat unexpectedly succeeded"
else
    grep -q "not installed" "$T/orm2" && ok "remove of a missing feat is a clear error" || bad "wrong remove error: $(cat "$T/orm2")"
fi
# a name with a path escape is refused (gf builds the path, never the caller)
if HOME="$T/home" ZISH_FEAT_PATH="$T/feats" "$T/gf" remove ../../etc >"$T/orm3" 2>&1; then
    bad "remove accepted a path-escaping name"
else
    grep -q "invalid feat name" "$T/orm3" && ok "remove refuses a path-escaping name" || bad "wrong escape error: $(cat "$T/orm3")"
fi

# ---- install from a git user-repo (the publish model: git + a pinned ref) --
# A user publishes a feat as a git repo (feat.toml + src/); the index maps the
# name to {git, ref}. gf clones at the ref, builds via the source-package path
# (no publisher script is ever run), and installs. The ref is the trust root.
G="$T/repo-hello"; mkdir -p "$G/src"
cat > "$G/feat.toml" <<'EOF'
name = "hellofeat"
tier = "standard"
bin = "hellofeat"
src = "main.zig"
lang = "zig"
EOF
printf 'pub fn main() void {}\n' > "$G/src/main.zig"
git -C "$G" init -q
git -C "$G" add -A
git -C "$G" -c user.name=t -c user.email=t@t commit -qm init
git -C "$G" tag v0.1.0

printf '{"name":"hellofeat","git":"file://%s","ref":"v0.1.0"}\n' "$G" > "$T/index-git.jsonl"
printf '{"name":"hellofeat","git":"file://%s","ref":"v9.9.9"}\n' "$G" > "$T/index-git-bad.jsonl"

if IGF "$T/index-git.jsonl" install hellofeat >"$T/og1" 2>&1 && [ -x "$T/feats/extra/hellofeat/bin/hellofeat" ]; then
    ok "gf install <name> clones a git user-repo at its ref and builds it"
else
    bad "git-install failed: $(cat "$T/og1")"
fi

[ ! -e "$T/feats/extra/hellofeat/.git" ] && ok "git install does not stage .git into the tier" || bad ".git leaked into the installed feat"
grep -q '"name":"hellofeat"' "$T/feats/ledger.jsonl" 2>/dev/null && ok "git install attested in the ledger" || bad "git install not in ledger"

# a ref that doesn't exist -> refused, nothing staged
rm -rf "$T/feats/extra/hellofeat"
if IGF "$T/index-git-bad.jsonl" install hellofeat >"$T/og2" 2>&1; then
    bad "bad git ref was NOT refused"
else
    grep -q "checkout" "$T/og2" && ok "unknown git ref refused (ref is the pin)" || bad "wrong error: $(cat "$T/og2")"
    [ ! -e "$T/feats/extra/hellofeat" ] && ok "nothing staged on a bad ref" || bad "feat staged despite bad ref"
fi

# ---- gf publish (cargo-style) + signed-tag verification on install ---------
# A publisher signs a release tag with their ssh key; the index line carries the
# publisher pubkey; gf install verifies the tag against it before building. This
# binds the ref to the publisher cryptographically (not just immutability).
if ! command -v ssh-keygen >/dev/null 2>&1; then
    printf '  \033[33mSKIP\033[0m ssh-keygen not available — publish/verify tests skipped\n'
else
    ssh-keygen -q -t ed25519 -N '' -C 'pub@zish' -f "$T/pubkey" </dev/null
    ssh-keygen -q -t ed25519 -N '' -f "$T/otherkey" </dev/null
    git init -q --bare "$T/origin.git"
    mkdir -p "$T/wf/src"
    cat > "$T/wf/feat.toml" <<'EOF'
name = "signedfeat"
tier = "standard"
bin = "signedfeat"
src = "main.zig"
lang = "zig"
version = "v0.1.0"
EOF
    printf 'pub fn main() void {}\n' > "$T/wf/src/main.zig"
    git -C "$T/wf" init -q
    git -C "$T/wf" config user.email d@e
    git -C "$T/wf" config user.name d
    git -C "$T/wf" add -A
    git -C "$T/wf" commit -qm init
    git -C "$T/wf" remote add origin "file://$T/origin.git"
    git -C "$T/wf" push -q -u origin HEAD

    # publish: sign+push the tag, append the index line to a local index file
    HOME="$T/home" ZISH_FEAT_PATH="$T/feats" ZISH_SIGN_KEY="$T/pubkey" \
        ZISH_FEAT_INDEX="$T/pubindex.jsonl" "$T/gf" publish "$T/wf" >"$T/pub.out" 2>&1
    if grep -q '"publisher":"' "$T/pubindex.jsonl" 2>/dev/null && grep -q '"ref":"v0.1.0"' "$T/pubindex.jsonl" 2>/dev/null; then
        ok "gf publish signs a tag and emits an index line with the publisher key"
    else
        bad "publish did not index: $(cat "$T/pub.out" "$T/pubindex.jsonl" 2>/dev/null)"
    fi

    if IGF "$T/pubindex.jsonl" install signedfeat >"$T/ins.out" 2>&1 && [ -x "$T/feats/extra/signedfeat/bin/signedfeat" ]; then
        ok "gf install verifies the publisher signature and installs"
    else
        bad "signed install failed: $(cat "$T/ins.out")"
    fi
    grep -q "signature verified" "$T/ins.out" && ok "install reports the verified signature" || bad "no verify message: $(cat "$T/ins.out")"

    # tamper: swap the publisher key to a different one -> install must refuse
    rm -rf "$T/feats/extra/signedfeat"
    otherpub=$(cut -d' ' -f1,2 "$T/otherkey.pub")
    python3 - "$T/pubindex.jsonl" "$T/badpub.jsonl" "$otherpub" <<'PY'
import json, sys
out = open(sys.argv[2], "w")
for l in open(sys.argv[1]):
    if not l.strip(): continue
    d = json.loads(l); d["publisher"] = sys.argv[3]
    out.write(json.dumps(d) + "\n")
PY
    if IGF "$T/badpub.jsonl" install signedfeat >"$T/bad.out" 2>&1; then
        bad "install accepted a wrong publisher key!"
    else
        grep -q "signature check failed" "$T/bad.out" && ok "wrong publisher key refused (fail-closed)" || bad "wrong error: $(cat "$T/bad.out")"
        [ ! -e "$T/feats/extra/signedfeat" ] && ok "nothing staged when the signature fails" || bad "feat staged despite bad signature"
    fi

    so=$(IGF "$T/pubindex.jsonl" search signed 2>&1)
    case "$so" in *"signedfeat"*"[signed]"*) ok "gf search finds the feat and flags it signed" ;; *) bad "search: $so" ;; esac
fi

# ---- fresh HOME: mkdir -p must create ~/.zish/feats from scratch --------------
# The first install on a brand-new system: HOME exists but ~/.zish does not, and
# no ZISH_FEAT_PATH. A non-recursive mkdir would fail here (curl write error).
FRESH="$T/freshhome"; rm -rf "$FRESH"; mkdir -p "$FRESH"
if HOME="$FRESH" "$T/gf" "file://$T/gfdemo.tar.gz" >"$T/ofresh" 2>&1 && [ -x "$FRESH/.zish/feats/extra/gfdemo/bin/gfdemo" ]; then
    ok "install into a fresh HOME creates ~/.zish/feats (mkdir -p)"
else
    bad "fresh-HOME install failed: $(cat "$T/ofresh")"
fi

# ---- gf settings / setup: ZFS-style list/get/set + exit-code discipline -----
SG() { HOME="$T/home" ZISH_FEAT_PATH="$T/feats" "$T/gf" "$@"; }
[ "$(SG settings review)" = "true" ] && ok "settings get: bare value, default true" || bad "settings get: $(SG settings review)"
SG settings | grep -q "review	true	" && ok "settings list is tab-separated (ZFS-style)" || bad "settings list not tabular: $(SG settings | cat -A)"
SG settings review false >/dev/null 2>&1 && [ "$(SG settings review)" = "false" ] && ok "settings set persists (true->false)" || bad "settings set failed"
SG settings review true  >/dev/null 2>&1  # restore
SG settings review >/dev/null 2>&1; [ $? -eq 0 ] && ok "settings get -> exit 0" || bad "settings get exit != 0"
SG settings bogus       >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown setting -> exit 2 (usage)" || bad "unknown setting exit != 2"
SG settings review maybe >/dev/null 2>&1; [ $? -eq 2 ] && ok "bad value -> exit 2 (usage)" || bad "bad value exit != 2"
# setup mirrors the same key true/false shape (installed = boolean)
[ "$(SG setup idxdemo)" = "false" ] && ok "setup get: uninstalled feat is false" || bad "setup get: $(SG setup idxdemo)"
SG setup idxdemo maybe   >/dev/null 2>&1; [ $? -eq 2 ] && ok "setup bad value -> exit 2 (usage)" || bad "setup bad value exit != 2"

# ---- SIGPIPE: a closed stdout kills gf (141), not a quiet 0 -----------------
# gf is a filter, so when the reader of its stdout is gone its next write must
# take SIGPIPE — the disposition every other CLI has. Full `std.process.Init`
# installs a no-op handler instead, which is why `feat.restoreSigpipe()` exists.
# The index here is big enough (5000 entries → ~1 MiB of catalog) that the
# reader has certainly exited before gf fills the 64 KiB pipe buffer, so the
# case is determined, not a race: without the primitive gf swallows EPIPE at
# whatever write lands after `head -c1` is gone and exits 0.
python3 - "$T/bigindex.jsonl" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(5000):
        f.write('{"name":"feat%05d","version":"v1.0.0","url":"file:///dev/null",'
                '"sha256":"%064x","desc":"a feat with a long enough one-line description %d"}\n'
                % (i, i, i))
PY
env -i HOME="$T/home" ZISH_FEAT_INDEX="file://$T/bigindex.jsonl" \
    "$T/gf" list 2>/dev/null | head -c1 >/dev/null
rc=${PIPESTATUS[0]}
[ "$rc" -eq 141 ] && ok "gf list, stdout reader gone -> exit 141 (SIGPIPE)" \
    || bad "gf list over a closed stdout -> exit $rc (want 141)"

echo
total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
fi
printf '\033[31mRED\033[0m — %d/%d failed\n' "$fail" "$total"; exit 1
