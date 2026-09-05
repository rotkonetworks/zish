# a textbook version bump: only pkgver + checksums move
pkgname=hello
pkgver=2.12.1
pkgrel=1
pkgdesc="GNU hello, the canonical example package"
arch=('x86_64')
url="https://www.gnu.org/software/hello/"
license=('GPL3')
depends=('glibc')
source=("https://ftp.gnu.org/gnu/hello/hello-$pkgver.tar.gz")
sha256sums=('8d99142afd92576f30b0cd7cb42a8dc6809998bc5d607d88761f512e26c7db20')

build() {
  cd "hello-$pkgver"
  ./configure --prefix=/usr
  make
}

package() {
  cd "hello-$pkgver"
  make DESTDIR="$pkgdir" install
}
