# a prebuilt binary from the OFFICIAL upstream, checksum pinned.
# auditability = blob: the payload is closed, but packaging + provenance are
# clean, so this PASSES (unverifiable != insecure).
pkgname=ripgrep-bin
pkgver=14.1.0
pkgrel=1
pkgdesc="Prebuilt ripgrep binary from the upstream release"
arch=('x86_64')
url="https://github.com/BurntSushi/ripgrep"
license=('MIT')
provides=('ripgrep')
conflicts=('ripgrep')
source=("https://github.com/BurntSushi/ripgrep/releases/download/$pkgver/ripgrep-$pkgver-x86_64-unknown-linux-musl.tar.gz")
sha256sums=('4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e')

package() {
  cd "ripgrep-$pkgver-x86_64-unknown-linux-musl"
  install -Dm755 rg "$pkgdir/usr/bin/rg"
  install -Dm644 doc/rg.1 "$pkgdir/usr/share/man/man1/rg.1"
}
