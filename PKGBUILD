# Maintainer: delarosa1312 <65927195+delarosa1312@users.noreply.github.com>
pkgname=mdrctl
pkgver=1.1.5
pkgrel=1
pkgdesc="Control Sony MDR headphones (WH-1000XM5, WF-1000XM5) from Linux, with an Omarchy bar widget"
arch=('x86_64' 'aarch64')
url="https://github.com/delarosa1312/omarchy-sony-xm5"
license=('MIT')
# fmt and bluez-libs are what the two shared objects actually link against
# (libfmt.so.12, libbluetooth.so.3); neither is pulled in by bluez or
# bluez-utils, so without them here the package installs and then fails to load
# its own libraries on a machine that happens not to have them.
depends=('python' 'bluez' 'bluez-utils' 'bluez-libs' 'dbus' 'fmt')
makedepends=('cmake' 'ninja' 'git' 'gcc')
optdepends=('omarchy: the bar widget this daemon drives')
install=mdrctl.install
options=('!debug')

# The upstream library is built here rather than vendored: nothing in it is
# modified, so there is no fork to keep up with -- only a commit to pin.
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
)
sha256sums=('SKIP' 'SKIP')

build() {
  # __FILE__ ends up in assertion strings, so without this the objects carry a
  # few thousand copies of whatever directory makepkg happened to build in.
  export CXXFLAGS="$CXXFLAGS -ffile-prefix-map=$srcdir=."
  export CFLAGS="$CFLAGS -ffile-prefix-map=$srcdir=."

  # MDR_BUILD_CLIENT=OFF skips the GLFW/ImGui GUI: only the protocol and the
  # Bluetooth transport are wanted, as shared objects for ctypes to load.
  #
  # SKIP_RPATH because the build tree's own fmt would otherwise be baked in as
  # a RUNPATH: the objects would point at a directory makepkg deletes, and
  # resolve only by falling through to the system copy. Better to depend on
  # the system fmt deliberately -- see depends -- than to work by accident.
  cmake -S "$srcdir/SonyHeadphonesClient" -B "$srcdir/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DMDR_BUILD_CLIENT=OFF \
    -DCMAKE_SKIP_RPATH=ON \
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

  # No mpris-proxy.service here: bluez-utils already ships one at that exact
  # path, and a package may not claim a file another package owns -- pacman
  # refuses the install outright. bluez-utils is a dependency, so the unit is
  # always present; it just needs enabling, which mdrctl.install says.
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
