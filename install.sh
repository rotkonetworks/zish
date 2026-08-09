#!/bin/sh
#
# zish installer.
#
#   sh install.sh              install the latest release
#   sh install.sh v0.16.0      install a specific version
#   PREFIX=/usr/local sh install.sh
#
# Prefers your system package manager when zish is packaged for it, otherwise
# downloads the release binary and verifies it against the published
# SHA256SUMS, otherwise builds from source.
#
# A note on `curl ... | sh`: piping a script straight from the network into a
# shell means you run whatever the server sends, and you never see it. This
# script is small on purpose — download it, read it, then run it. It verifies
# checksums for the same reason.

set -eu

REPO="rotkonetworks/zish"
VERSION="${1:-latest}"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

os=$(uname -s)
arch=$(uname -m)

macos_preview=0
case "$os" in
    Linux) ;;
    Darwin)
        # macOS builds and passes a 16-case smoke test in CI (basic execution,
        # subshells, arithmetic, pipelines, functions, globs, background jobs,
        # redirects, heredocs). Interactive job control is NOT exercised there,
        # and a few file-test operators are still Linux-only. So: buildable,
        # not supported. There are no prebuilt macOS binaries for that reason —
        # shipping one would imply a promise we cannot keep yet.
        macos_preview=1
        if ! have zig; then
            die "macOS support is a preview and needs to be built from source.

There are no prebuilt macOS binaries yet: zish builds and passes a basic smoke
test on macOS, but interactive job control is untested there.

Install Zig 0.16 and re-run:
  brew install zig
  sh install.sh"
        fi
        ;;
    *)
        die "unsupported OS: $os (zish targets Linux; macOS is a preview)"
        ;;
esac

os_suffix=linux
[ "$os" = "Darwin" ] && os_suffix=macos
case "$arch" in
    x86_64|amd64)  target="x86_64-$os_suffix" ;;
    aarch64|arm64) target="aarch64-$os_suffix" ;;
    *) die "unsupported architecture: $arch" ;;
esac

# ---------------------------------------------------------------------------
# Prefer a real package manager — it gets you upgrades
# ---------------------------------------------------------------------------

if have nix && [ "${ZISH_FORCE_BINARY:-}" != "1" ]; then
    say "nix detected. The flake gives you upgrades and rollback:"
    say ""
    say "    nix profile install github:$REPO"
    say ""
    say "Continuing with the plain binary install in 3s (ctrl-c to stop)..."
    sleep 3
fi

if have pacman && [ "${ZISH_FORCE_BINARY:-}" != "1" ]; then
    say "Arch detected. zish is on the AUR:"
    say ""
    say "    paru -S zish     # or: yay -S zish"
    say ""
    say "Continuing with the plain binary install in 3s (ctrl-c to stop)..."
    sleep 3
fi

# ---------------------------------------------------------------------------
# Download + verify
# ---------------------------------------------------------------------------

if have curl; then
    fetch() { curl -fsSL "$1" -o "$2"; }
elif have wget; then
    fetch() { wget -qO "$2" "$1"; }
else
    die "need curl or wget"
fi

if [ "$VERSION" = "latest" ]; then
    base="https://github.com/$REPO/releases/latest/download"
else
    base="https://github.com/$REPO/releases/download/$VERSION"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

if [ "$macos_preview" = "1" ]; then
    say "macOS preview: no prebuilt binary, building from source..."
else
    say "Downloading zish-$target ($VERSION)..."
fi
if [ "$macos_preview" = "1" ] || ! fetch "$base/zish-$target" "$tmp/zish"; then
    [ "$macos_preview" = "1" ] || warn "No release binary for $target."
    if have zig; then
        [ "$macos_preview" = "1" ] || say "Zig found — building from source instead."
        src="$tmp/src"
        mkdir -p "$src"
        ref=$([ "$VERSION" = "latest" ] && echo main || echo "$VERSION")
        fetch "https://github.com/$REPO/archive/$ref.tar.gz" "$tmp/src.tar.gz" \
            || die "could not download source"
        tar -xzf "$tmp/src.tar.gz" -C "$src" --strip-components=1
        (cd "$src" && zig build --release=fast) || die "build failed"
        cp "$src/zig-out/bin/zish" "$tmp/zish"
    else
        die "no release binary for $target and no zig to build from source"
    fi
else
    # Verify against the published checksums. A download that cannot be
    # verified is not installed.
    if fetch "$base/SHA256SUMS-$target" "$tmp/SHA256SUMS" 2>/dev/null; then
        if have sha256sum; then
            want=$(grep " zish-$target\$" "$tmp/SHA256SUMS" | cut -d' ' -f1)
            got=$(sha256sum "$tmp/zish" | cut -d' ' -f1)
        elif have shasum; then
            want=$(grep " zish-$target\$" "$tmp/SHA256SUMS" | cut -d' ' -f1)
            got=$(shasum -a 256 "$tmp/zish" | cut -d' ' -f1)
        else
            want=""; got=""
            warn "no sha256sum/shasum available — cannot verify download"
        fi

        if [ -n "$want" ]; then
            [ "$want" = "$got" ] || die "checksum mismatch for zish-$target
  expected: $want
  got:      $got
Refusing to install."
            say "Checksum verified."
        fi
    else
        warn "SHA256SUMS not published for this release — cannot verify download."
        warn "Set ZISH_INSECURE=1 to install anyway."
        [ "${ZISH_INSECURE:-}" = "1" ] || die "refusing to install an unverified binary"
    fi
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

mkdir -p "$BINDIR"
install -m 755 "$tmp/zish" "$BINDIR/zish"
say "Installed $BINDIR/zish"

"$BINDIR/zish" --version >/dev/null 2>&1 || die "installed binary does not run"

case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *)
        say ""
        say "$BINDIR is not on your PATH. Add it:"
        say "    echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.profile"
        ;;
esac

say ""
say "Done. Try it:    zish"
say "Make it default: chsh -s $BINDIR/zish"
say ""
say "chsh needs zish listed in /etc/shells first:"
say "    echo $BINDIR/zish | sudo tee -a /etc/shells"
