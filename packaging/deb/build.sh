#!/bin/sh
#
# Build zish_<version>-<rev>_<arch>.deb for Debian/Ubuntu/Proxmox.
#
#   packaging/deb/build.sh <x86_64|aarch64> [version] [outdir]
#
# The package carries the STATIC MUSL build, not the glibc-dynamic one the
# release attaches: a static binary has no glibc symbol floor, so one .deb
# installs unchanged on bookworm (Proxmox 8), trixie, 22.04 and 24.04, and
# Depends stays empty. The musl binary passes the same regress + pty suites.
#
# The core feat tier (build.zig's "ships with the shell" set; tooling and the
# agent stack install through gf) ships at <prefix>/share/zish/feats/standard, the
# path the shell derives from /proc/self/exe. Without them the catalog is empty
# and cannot bootstrap (`gf`, which installs feats, is itself one), so an
# empty feat stage is a build failure, never a hollow package.
#
# Needs zig and dpkg-deb. Runs as any user: --root-owner-group sets ownership.

set -eu

arch_in=${1:?usage: build.sh <x86_64|aarch64> [version] [outdir]}
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
version=${2:-$(sed -n 's/^ *\.version *= *"\(.*\)",/\1/p' "$top/build.zig.zon")}
out=${3:-$top/dist}
rev=${DEB_REVISION:-1}

case "$arch_in" in
    x86_64)  deb_arch=amd64 ;;
    aarch64) deb_arch=arm64 ;;
    *) echo "build.sh: unsupported arch '$arch_in'" >&2; exit 2 ;;
esac
[ -n "$version" ] || { echo "build.sh: no version (build.zig.zon unreadable?)" >&2; exit 1; }

target=$arch_in-linux-musl
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root

cd "$top"

# ── binaries ────────────────────────────────────────────────────────────────
zig build --release=safe -Dstrip=true -Dlto=false -Dtarget="$target" \
    --prefix "$work/shell"
zig build install-feats --release=safe -Dstrip=true -Dfeats=core \
    -Dfeat-layout=registry -Dtarget="$target" --prefix "$work/feats"

[ -x "$work/shell/bin/zish" ] || { echo "build.sh: no zish binary built" >&2; exit 1; }
nfeats=$(find "$work/feats/standard" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$nfeats" -gt 0 ] || { echo "build.sh: feat stage is empty for $target" >&2; exit 1; }
[ -x "$work/feats/standard/gf/bin/gf" ] || { echo "build.sh: gf missing from feat stage" >&2; exit 1; }

# ── filesystem tree ─────────────────────────────────────────────────────────
install -Dm755 "$work/shell/bin/zish"   "$root/usr/bin/zish"
install -d "$root/usr/share/man/man1"
gzip -9n < zish.1 > "$root/usr/share/man/man1/zish.1.gz"
chmod 644 "$root/usr/share/man/man1/zish.1.gz"
install -Dm644 README.md "$root/usr/share/doc/zish/README.md"
install -d "$root/usr/share/zish/feats/standard"
cp -R "$work/feats/standard/." "$root/usr/share/zish/feats/standard/"

# Debian machine-readable copyright, carrying the MIT text verbatim.
{
    printf 'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n'
    printf 'Upstream-Name: zish\nSource: https://github.com/rotkonetworks/zish\n\n'
    printf 'Files: *\nCopyright: Rotko Networks\nLicense: MIT\n'
    sed 's/^$/./; s/^/ /' LICENSE
} > "$root/usr/share/doc/zish/copyright"
chmod 644 "$root/usr/share/doc/zish/copyright"

printf 'zish (%s-%s) stable; urgency=medium\n\n  * Upstream release %s, see\n    https://github.com/rotkonetworks/zish/releases/tag/v%s\n\n -- Rotko Networks <hq@rotko.net>  %s\n' \
    "$version" "$rev" "$version" "$version" \
    "$(LC_ALL=C date -R -d "@${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}")" \
    | gzip -9n > "$root/usr/share/doc/zish/changelog.Debian.gz"
chmod 644 "$root/usr/share/doc/zish/changelog.Debian.gz"

# Both deliberate: static musl is what makes one .deb portable, and the feats
# live under share/ because the shell resolves <prefix>/share/zish/feats from
# /proc/self/exe (same layout as the AUR package).
install -d "$root/usr/share/lintian/overrides"
cat > "$root/usr/share/lintian/overrides/zish" <<'EOF'
zish: statically-linked-binary [*]
zish: arch-dependent-file-in-usr-share [usr/share/zish/feats/*]
EOF
chmod 644 "$root/usr/share/lintian/overrides/zish"

find "$root" -type d -exec chmod 755 {} +

# ── control ─────────────────────────────────────────────────────────────────
install -d "$root/DEBIAN"
size=$(du -sk "$root/usr" | cut -f1)
cat > "$root/DEBIAN/control" <<EOF
Package: zish
Version: $version-$rev
Architecture: $deb_arch
Maintainer: Rotko Networks <hq@rotko.net>
Installed-Size: $size
Section: shells
Recommends: curl, ca-certificates
Suggests: git
Priority: optional
Homepage: https://github.com/rotkonetworks/zish
Description: fast, familiar POSIX/bash shell with kernel-enforced sandboxing
 zish is an interactive shell written in Zig: bash-familiar syntax, job
 control and a line editor, with Landlock and seccomp containment profiles
 enforced by the kernel. The core feats (gf, para, calc, ...) ship
 alongside; more install with gf.
EOF

# /etc/shells: add on configure, remove only on real removal (not upgrade).
cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    add-shell /usr/bin/zish
fi
EOF
cat > "$root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = purge ]; then
    if command -v remove-shell >/dev/null 2>&1; then
        remove-shell /usr/bin/zish
    fi
fi
EOF
chmod 755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

mkdir -p "$out"
deb="$out/zish_${version}-${rev}_${deb_arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "$root" "$deb" >/dev/null
echo "$deb"
