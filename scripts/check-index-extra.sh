#!/bin/sh
# Validate feats/index-extra.jsonl: the feats that live in OTHER repos (e.g.
# rotko-feats) but are published in zish's gf index. gf installs entries from
# its own default index into the standard tier, callable at once, so every
# line here is a trust decision and is held to the shape `make dist-all`
# itself emits:
#   - one JSON object per line, with name/version/arch/tier/url/sha256/desc
#   - url is an IMMUTABLE release asset (…/releases/download/<tag>/…), never
#     a rolling `latest` pointer, a branch, or plain http
#   - sha256 is 64 lowercase hex: the pin gf verifies the tarball against
#   - name is a feat name and does not shadow a feat this repo builds
# Usage: scripts/check-index-extra.sh [FILE] [BUILT_NAMES...]
set -eu
f=${1:-feats/index-extra.jsonl}
shift 2>/dev/null || true
[ -f "$f" ] || { echo "index-extra: $f missing" >&2; exit 1; }
n=0; bad=0
while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -z "$line" ] && continue
    field() { printf '%s' "$line" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
    name=$(field name); url=$(field url); sha=$(field sha256); arch=$(field arch); ver=$(field version); tier=$(field tier)
    err=""
    printf '%s' "$line" | grep -Eq '^\{.*\}$' || err="not a JSON object"
    printf '%s' "$name" | grep -Eq '^[a-z][a-z0-9_-]{0,31}$' || err="${err:+$err; }bad name '$name'"
    [ -n "$ver" ] || err="${err:+$err; }no version"
    [ -n "$arch" ] || err="${err:+$err; }no arch"
    [ "$tier" = standard ] || err="${err:+$err; }tier must be standard"
    printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$' || err="${err:+$err; }sha256 must be 64 lowercase hex"
    printf '%s' "$url" | grep -Eq '^https://github\.com/[^/]+/[^/]+/releases/download/[^/]+/[^/]+\.tar\.gz$' \
        || err="${err:+$err; }url must be an immutable https release asset"
    case "$url" in */latest/*) err="${err:+$err; }url must not be a rolling latest pointer" ;; esac
    for b in "$@"; do [ "$b" = "$name" ] && err="${err:+$err; }'$name' shadows a feat built here"; done
    if [ -n "$err" ]; then echo "index-extra:$n: $err" >&2; bad=$((bad + 1)); fi
done < "$f"
[ "$bad" -eq 0 ] || exit 1
