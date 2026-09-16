# Maintainer: delarosa1312 <65927195+delarosa1312@users.noreply.github.com>
pkgname=mdrctl
pkgver=1.1.3
pkgrel=4
pkgdesc="Control Sony MDR headphones (WH-1000XM5, WF-1000XM5) from Linux, with an Omarchy bar widget"
arch=('x86_64' 'aarch64')
url="https://github.com/delarosa1312/omarchy-sony-xm5"
license=('MIT')
# Arch started shipping mpris-proxy.service in bluez-utils 5.79-1.
depends=('python' 'bluez' 'bluez-utils>=5.79' 'dbus')
makedepends=('cmake' 'ninja' 'git' 'gcc')
optdepends=('omarchy: the bar widget this daemon drives')
install=mdrctl.install
options=('!debug')

# The upstream library is built here rather than vendored. The timer patch
# keeps ACK deadlines on monotonic wall time even while the daemon sleeps.
#
# Spelled out in the source array rather than passed through $_mdrcommit: a
# variable is resolved by makepkg, not by whoever is reading the file to decide
# whether it is safe. _mdrcommit stays as the canonical copy and scripts/test
# holds every other occurrence against it. Our own repo is fetched by tag
# because a commit cannot name itself from inside its own tree.
_mdrcommit=965c458116d40827494726447de5f07eb50efcb8
source=(
  "$pkgname::git+https://github.com/delarosa1312/omarchy-sony-xm5.git#tag=v$pkgver"
  "git+https://github.com/mos9527/SonyHeadphonesClient.git#commit=965c458116d40827494726447de5f07eb50efcb8"
  # The released tag predates the connection-poll fix.
  "fix-connection-poll.patch"
  "fix-mdr-wall-clock.patch"
)
sha256sums=('SKIP' 'SKIP'
  'e6e2ca32eb0ff2abf370ecb257cfe83f918813c6a6b49b8542779f348b4f21e1'
  '45e1ea523c094374979db213d7a643ba42737ca2bcf252cb77aac78e67f79e8d')

prepare() {
  patch -d "$srcdir/$pkgname" -Np1 < "$srcdir/fix-connection-poll.patch"
  # Upstream has trailing spaces on the replaced clock() line.
  patch -d "$srcdir/SonyHeadphonesClient" -lNp1 < "$srcdir/fix-mdr-wall-clock.patch"
}

build() {
  # MDR_BUILD_CLIENT=OFF skips the GLFW/ImGui GUI: only the protocol and the
  # Bluetooth transport are wanted, as shared objects for ctypes to load.
  cmake -S "$srcdir/SonyHeadphonesClient" -B "$srcdir/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DMDR_BUILD_CLIENT=OFF \
    -DBUILD_SHARED_LIBS=ON
  # Ninja otherwise uses every CPU, which can exhaust memory while compiling
  # the generated protocol sources. Allow an explicit override for builders.
  cmake --build "$srcdir/build" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
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

  # bluez-utils>=5.79 owns mpris-proxy.service. Shipping our own copy makes
  # pacman reject the transaction with a conflicting-files error.
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
