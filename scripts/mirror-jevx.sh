#!/bin/sh
# Publish feats/jevx as a standalone repo: the read-only jevx mirror.
#
# zish is where jevx is developed; the mirror is that directory made to stand
# alone, for people who want jevx without zish. It is a SNAPSHOT mirror, not a
# `git subtree split`: feats/jevx/lib/feat.zig is a symlink to
# ../../lib/feat.zig, which a split would carry over pointing at nothing, so
# each sync copies the tree with that link resolved to the real file. History
# is kept as one mirror commit per sync, naming the zish commit and listing
# the jevx commits it brings in.
#
#   scripts/mirror-jevx.sh [options] [MIRROR_DIR]
#
#   MIRROR_DIR     a git checkout of the mirror (default ../jevex, or
#                  $JEVX_MIRROR); an empty directory is initialised
#   --rev REV      the zish commit to publish (default HEAD)
#   --worktree     publish the working tree instead of a commit — for trying
#                  the mirror out before committing; never for a real sync
#   --no-commit    stage the sync in the mirror but do not commit it
#   --no-check     skip building and testing the snapshot first
#
# It never pushes. Pushing the mirror is a separate, deliberate step.
set -eu

ZISH=$(cd "$(dirname "$0")/.." && pwd)
mirror=${JEVX_MIRROR:-$ZISH/../jevex}
rev=HEAD
worktree=0
commit=1
check=1
while [ $# -gt 0 ]; do
    case $1 in
        --rev) rev=$2; shift 2 ;;
        --worktree) worktree=1; shift ;;
        --no-commit) commit=0; shift ;;
        --no-check) check=0; shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        -*) echo "mirror-jevx: unknown option $1" >&2; exit 2 ;;
        *) mirror=$1; shift ;;
    esac
done

die() { echo "mirror-jevx: $*" >&2; exit 1; }
cd "$ZISH"

# --- the files that make up the mirror, from one source -------------------
FILES="feats/jevx feats/lib/feat.zig tests/jevx_test.sh LICENSE"
snap=$(mktemp -d "${TMPDIR:-/tmp}/jevx-mirror-XXXXXX")
trap 'rm -rf "$snap"' EXIT
mkdir -p "$snap/src"

if [ "$worktree" = 1 ]; then
    sha=$(git rev-parse HEAD)
    label="zish worktree (on $(git rev-parse --short HEAD), uncommitted)"
    # tar keeps symlinks as symlinks, like git archive does
    tar -cf - $FILES | tar -xf - -C "$snap/src"
else
    sha=$(git rev-parse --verify "$rev^{commit}") || die "no such commit: $rev"
    git cat-file -e "$sha:feats/jevx/main.zig" 2>/dev/null \
        || die "feats/jevx is not in $(git rev-parse --short "$sha") — commit it first (or try --worktree)"
    label="zish@$(git rev-parse --short "$sha")"
    git archive "$sha" $FILES | tar -xf - -C "$snap/src"
fi

# --- lay it out as a standalone repo --------------------------------------
out="$snap/out"
mkdir -p "$out/tests"
( cd "$snap/src/feats/jevx" && tar -cf - --exclude=zig-out --exclude=.zig-cache . ) | tar -xf - -C "$out"
rm -f "$out/lib/feat.zig"
cp "$snap/src/feats/lib/feat.zig" "$out/lib/feat.zig"      # the symlink, resolved
cp "$snap/src/tests/jevx_test.sh" "$out/tests/jevx_test.sh"
cp "$snap/src/LICENSE" "$out/LICENSE"
printf 'zig-out/\n.zig-cache/\n' > "$out/.gitignore"
# The mirror's own CI. Generated here because a sync replaces every file.
mkdir -p "$out/.github/workflows"
cat > "$out/.github/workflows/ci.yaml" <<'YAML'
name: ci
on: [push, pull_request, workflow_dispatch]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1
        with:
          version: 0.16.0
      - run: zig build test
      - run: zig build suite
YAML
# A release for every feat.toml version that has none yet: static musl
# tarballs for x86_64 and aarch64 plus SHA256SUMS, built and smoke-tested here.
cat > "$out/.github/workflows/release.yaml" <<'YAML'
name: release
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: write
concurrency:
  group: release
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - name: version
        id: v
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          ver=$(sed -n 's/^version = "\(.*\)"/\1/p' feat.toml)
          [ -n "$ver" ] || { echo "no version in feat.toml" >&2; exit 1; }
          echo "ver=$ver" >> "$GITHUB_OUTPUT"
          if gh release view "v$ver" >/dev/null 2>&1; then
            echo "v$ver is already released"
            echo "new=0" >> "$GITHUB_OUTPUT"
          else
            echo "new=1" >> "$GITHUB_OUTPUT"
          fi
      - if: steps.v.outputs.new == '1'
        uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1
        with:
          version: 0.16.0
      - name: build
        if: steps.v.outputs.new == '1'
        env:
          VER: ${{ steps.v.outputs.ver }}
        run: |
          zig build test
          zig build suite
          mkdir dist
          for a in x86_64 aarch64; do
            zig build -Doptimize=ReleaseSafe -Dtarget=$a-linux-musl --prefix "out-$a"
            d=jevx-$VER-$a-linux-musl
            mkdir "$d"
            cp "out-$a/bin/jevx" README.md LICENSE "$d/"
            cp -R examples vim "$d/"
            tar -czf "dist/$d.tar.gz" "$d"
          done
          # the shipped x86_64 binary must report the version it is released as
          [ "$(out-x86_64/bin/jevx --version)" = "jevx $VER" ]
          cd dist && sha256sum *.tar.gz > SHA256SUMS
      - name: publish
        if: steps.v.outputs.new == '1'
        env:
          GH_TOKEN: ${{ github.token }}
          VER: ${{ steps.v.outputs.ver }}
        run: |
          cat > notes.md <<EOF
          Static Linux binaries. The only runtime dependency is curl.

          \`\`\`sh
          a=x86_64   # or aarch64
          curl -fsSLO https://github.com/rotkonetworks/jevx/releases/download/v$VER/jevx-$VER-\$a-linux-musl.tar.gz
          curl -fsSLO https://github.com/rotkonetworks/jevx/releases/download/v$VER/SHA256SUMS
          sha256sum -c --ignore-missing SHA256SUMS
          tar -xzf jevx-$VER-\$a-linux-musl.tar.gz
          install -m755 jevx-$VER-\$a-linux-musl/jevx ~/.local/bin/
          \`\`\`

          Changes: https://github.com/rotkonetworks/zish/blob/main/CHANGELOG.md

          Built from $(sed -n 's/^Source: //p' MIRROR). Inside zish: gf install jevx.
          EOF
          gh release create "v$VER" dist/* --title "jevx $VER" --notes-file notes.md --target "$GITHUB_SHA"
YAML
cat > "$out/MIRROR" <<EOF
This repository is generated. It is a read-only mirror of feats/jevx in zish:
  https://github.com/rotkonetworks/zish
Source: $label
Commit: $sha

Do not edit it here: changes made in this repository are overwritten by the
next sync. Send issues and changes to zish.
EOF
find "$out" -type l | grep -q . && die "the snapshot still contains a symlink: $(find "$out" -type l | head -1)"

# --- prove it stands alone --------------------------------------------------
if [ "$check" = 1 ]; then
    echo "mirror-jevx: checking the snapshot builds and passes its tests on its own..."
    ( cd "$out" && zig build >/dev/null && zig build test >/dev/null && zig build suite >"$snap/suite.log" 2>&1 ) \
        || { grep -a -B1 FAIL "$snap/suite.log" 2>/dev/null; tail -20 "$snap/suite.log" 2>/dev/null; die "the snapshot does not build or test cleanly on its own"; }
    tail -1 "$snap/suite.log"
    rm -rf "$out/zig-out" "$out/.zig-cache"
fi

# --- sync into the mirror checkout -----------------------------------------
if [ ! -d "$mirror/.git" ]; then
    mkdir -p "$mirror"
    [ -z "$(ls -A "$mirror")" ] || die "$mirror exists, is not a git repo, and is not empty"
    git -C "$mirror" init -q
    echo "mirror-jevx: initialised $mirror"
fi
[ -z "$(git -C "$mirror" status --porcelain)" ] || die "$mirror has uncommitted changes — the mirror is never edited by hand"

prev=$(sed -n 's/^Commit: //p' "$mirror/MIRROR" 2>/dev/null || true)
git -C "$mirror" ls-files -z | (cd "$mirror" && xargs -0 rm -f --)
( cd "$out" && tar -cf - . ) | tar -xf - -C "$mirror"
git -C "$mirror" add -A
if git -C "$mirror" diff --cached --quiet; then
    echo "mirror-jevx: $mirror is already at $label"
    exit 0
fi

msg="$snap/msg"
{
    echo "sync from $label"
    echo
    if [ -n "$prev" ] && git cat-file -e "$prev^{commit}" 2>/dev/null; then
        git log --format='- %h %s' "$prev..$sha" -- feats/jevx tests/jevx_test.sh
    else
        git log --format='- %h %s' "$sha" -- feats/jevx tests/jevx_test.sh | head -50
    fi
} > "$msg"

if [ "$commit" = 1 ]; then
    git -C "$mirror" commit -q -F "$msg"
    echo "mirror-jevx: committed $(git -C "$mirror" rev-parse --short HEAD) in $mirror ($label)"
    echo "  push when ready:  git -C $mirror push origin HEAD"
else
    echo "mirror-jevx: staged the sync in $mirror (not committed); message would be:"
    sed 's/^/  /' "$msg"
fi
