# Maintainer: delarosa1312 <65927195+delarosa1312@users.noreply.github.com>
pkgname=mdrctl
pkgver=1.0.3
pkgrel=1
pkgdesc="Control Sony MDR headphones (WH-1000XM5, WF-1000XM5) from Linux, with an Omarchy bar widget"
arch=('x86_64' 'aarch64')
url="https://github.com/delarosa1312/omarchy-sony-xm5"
license=('MIT')
depends=('python' 'bluez' 'bluez-utils' 'dbus')
makedepends=('cmake' 'ninja' 'git' 'gcc')
optdepends=('omarchy: the bar widget this daemon drives')
install=mdrctl.install
options=('!debug')

# The upstream library is built here rather than vendored: nothing in it is
# modified, so there is no fork to keep up with -- only a commit to pin.
_mdrcommit=965c458116d40827494726447de5f07eb50efcb8
source=(
  "$pkgname::git+https://github.com/delarosa1312/omarchy-sony-xm5.git#tag=v$pkgver"
  "git+https://github.com/mos9527/SonyHeadphonesClient.git#commit=$_mdrcommit"
)
sha256sums=('SKIP' 'SKIP')

build() {
  # MDR_BUILD_CLIENT=OFF skips the GLFW/ImGui GUI: only the protocol and the
  # Bluetooth transport are wanted, as shared objects for ctypes to load.
  cmake -S "$srcdir/SonyHeadphonesClient" -B "$srcdir/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DMDR_BUILD_CLIENT=OFF \
    -DBUILD_SHARED_LIBS=ON
  cmake --build "$srcdir/build"
}

package() {
  cd "$srcdir"

  # The two shared objects, flat. lib/mdr.py looks here when it is not running
  # out of a checkout.
  install -Dm755 build/libmdr/src/libmdr-shared.so \
    "$pkgdir/usr/lib/mdrctl/libmdr-shared.so"
  install -Dm755 build/libmdr-bt/src/libmdr-bt-shared.so \
    "$pkgdir/usr/lib/mdrctl/libmdr-bt-shared.so"

  install -Dm644 "$pkgname/daemon/lib/mdr.py" "$pkgdir/usr/lib/mdrctl/mdr.py"
  install -Dm755 "$pkgname/daemon/bin/mdrctl" "$pkgdir/usr/bin/mdrctl"
  install -Dm755 "$pkgname/daemon/bin/mdrctld" "$pkgdir/usr/bin/mdrctld"

  install -Dm644 "$pkgname/daemon/systemd-user/mpris-proxy.service" \
    "$pkgdir/usr/lib/systemd/user/mpris-proxy.service"
  # The unit template carries @PYTHON@/@MDRCTLD@/@ARGS@ so a checkout can point
  # them at itself. Installed, both are fixed absolute paths and libmdr is found
  # at /usr/lib/mdrctl without being told, so there are no arguments to pass.
  sed -e "s|@PYTHON@|/usr/bin/python3|" \
      -e "s|@MDRCTLD@|/usr/bin/mdrctld|" \
      -e "s|@ARGS@||" "$pkgname/daemon/systemd-user/mdrctld.service" \
    > mdrctld.service.packaged
  install -Dm644 mdrctld.service.packaged \
    "$pkgdir/usr/lib/systemd/user/mdrctld.service"

  install -Dm644 "$pkgname/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 "$pkgname/README.md" "$pkgdir/usr/share/doc/$pkgname/README.md"
}
