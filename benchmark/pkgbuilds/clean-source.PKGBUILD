# ordinary from-source build; nothing beyond configure/make/install
pkgname=jq
pkgver=1.7.1
pkgrel=1
pkgdesc="Command-line JSON processor"
arch=('x86_64')
url="https://jqlang.github.io/jq/"
license=('MIT')
depends=('oniguruma')
makedepends=('autoconf' 'automake' 'libtool')
source=("https://github.com/jqlang/jq/releases/download/jq-$pkgver/jq-$pkgver.tar.gz")
sha256sums=('478c9ca129fd2e3443fe27314b455e211e0d8c60bc8ff7df703873deeee580c2')

build() {
  cd "jq-$pkgver"
  ./configure --prefix=/usr --disable-maintainer-mode
  make
}

package() {
  cd "jq-$pkgver"
  make DESTDIR="$pkgdir" install
}
