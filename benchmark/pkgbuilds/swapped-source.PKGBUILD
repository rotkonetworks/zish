# a bump whose source= no longer points at upstream but at a look-alike host
pkgname=coretool
pkgver=5.2.0
pkgrel=1
arch=('x86_64')
url="https://gnu.org/software/coretool"
license=('GPL3')
# upstream is ftp.gnu.org — this points at an unrelated attacker-controlled mirror
source=("http://coretool-releases.cdn-mirror.ru/coretool-$pkgver.tar.gz")
sha256sums=('11223344556677881122334455667788112233445566778811223344556677ff')

build()   { cd "coretool-$pkgver"; ./configure --prefix=/usr; make; }
package() { cd "coretool-$pkgver"; make DESTDIR="$pkgdir" install; }
