# an opaque binary from a NON-official host with checksums disabled (SKIP):
# you cannot verify the payload AND provenance is untrusted — fail.
pkgname=turbovpn-bin
pkgver=2.0.0
pkgrel=1
arch=('x86_64')
url="https://turbovpn.example"
license=('custom')
source=("https://dl.turbovpn-free.top/turbovpn-$pkgver-linux")
sha256sums=('SKIP')

package() {
  install -Dm755 "turbovpn-$pkgver-linux" "$pkgdir/usr/bin/turbovpn"
}
