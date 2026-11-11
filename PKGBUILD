# Maintainer: bojanstrkovski-21 <bojanstrkovski.21@gmail.com>
# Local Arch package of butterview-arch. From the repository root:
#   makepkg -s
# makepkg requires this file to stay in the root. Sources, the package
# tree, and the finished package go in build/. makepkg reads those three
# paths after this file is sourced, so the directory has to exist here.
# build() runs ensure-zig.install. That installs mise when it is missing,
# then Zig 0.16.0 through mise when this tree does not already have it.
# Arch extra/zig is 0.17 and is not used. Zig is not a runtime dependency.
if [[ -z ${startdir} ]]; then
  echo "PKGBUILD: run makepkg from the repository root" >&2
  exit 1
fi
if [[ ! -d ${startdir}/build ]]; then
  mkdir -p "${startdir}/build"
fi
BUILDDIR="${startdir}/build"
PKGDEST="${startdir}/build"
SRCDEST="${startdir}/build"

pkgname=butterview
pkgver=0.4.5
pkgrel=2
pkgdesc="Small, fast image viewer on SDL3"
arch=('x86_64')
url="https://justaguy.dev/drew/butterview"
license=('GPL-3.0-or-later')
depends=(
  'sdl3'
  'sdl3_image'
  'sdl3_ttf'
  'libjpeg-turbo'
  'dbus'
  'fontconfig'
)
makedepends=(
  'mise'
  'pkgconf'
  'imagemagick'
  'librsvg'
)
optdepends=(
  'wl-clipboard: copy an image on Wayland'
  'xclip: copy an image on X11'
  'glib2: gio trash'
  'xdg-utils: show a file in the folder'
)
options=('!debug' '!lto')

prepare() {
  mkdir -p "$srcdir/$pkgname"
  tar -C "$startdir/butterview-arch" \
    --exclude zig-out --exclude .zig-cache --exclude .deps \
    -cf - . | tar -C "$srcdir/$pkgname" -xf -
}

build() {
  local zig ver
  bash "$startdir/ensure-zig.install" "$startdir"
  zig="$(cd "$startdir" && mise which zig)"
  ver="$("$zig" version)"
  case "$ver" in
    0.16.*) ;;
    *)
      echo "butterview needs Zig 0.16, found ${ver:-nothing}" >&2
      return 1
      ;;
  esac
  cd "$srcdir/$pkgname"
  "$zig" build \
    -Doptimize=ReleaseSafe \
    -Dversion="$pkgver" \
    --prefix "$srcdir/stage/usr"
}

package() {
  cd "$srcdir/$pkgname"
  cp -a "$srcdir/stage/usr/." "$pkgdir/usr/"
  install -Dm644 data/butterview.1 "$pkgdir/usr/share/man/man1/butterview.1"
  install -Dm644 data/butterview.desktop "$pkgdir/usr/share/applications/butterview.desktop"
  install -Dm644 data/butterview.svg "$pkgdir/usr/share/icons/hicolor/scalable/apps/butterview.svg"
  local s
  for s in 48 128 256; do
    install -d "$pkgdir/usr/share/icons/hicolor/${s}x${s}/apps"
    magick -background none -density 300 data/butterview.svg -resize "${s}x${s}" \
      "$pkgdir/usr/share/icons/hicolor/${s}x${s}/apps/butterview.png"
  done
  install -Dm644 README.md "$pkgdir/usr/share/doc/butterview/README.md"
  install -Dm644 data/butterview.conf.example "$pkgdir/usr/share/doc/butterview/butterview.conf.example"
}
