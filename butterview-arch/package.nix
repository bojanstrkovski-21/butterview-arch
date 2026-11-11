{ lib, stdenv, zig_0_16, pkg-config, makeWrapper
, sdl3, sdl3-image, sdl3-ttf, libjpeg_turbo, dbus
, fontconfig, wl-clipboard, xclip, xdg-utils, glib
, imagemagick, librsvg }:

stdenv.mkDerivation (finalAttrs: {
  pname = "butterview";
  version = "0.4.5";

  # When used outside this checkout, replace with:
  # src = fetchzip { url = "https://justaguy.dev/drew/butterview/archive/v${finalAttrs.version}.tar.gz"; hash = ""; };
  src = ./.;

  nativeBuildInputs = [ zig_0_16.hook pkg-config makeWrapper imagemagick librsvg ];
  buildInputs = [ sdl3 sdl3-image sdl3-ttf libjpeg_turbo dbus ];

  # zig.hook already passes -Dcpu=baseline and --prefix $out.
  zigBuildFlags = [ "-Doptimize=ReleaseSafe" "-Dversion=${finalAttrs.version}" ];

  postInstall = ''
    install -Dm644 data/butterview.1 $out/share/man/man1/butterview.1
    install -Dm644 data/butterview.desktop $out/share/applications/butterview.desktop
    install -Dm644 data/butterview.svg $out/share/icons/hicolor/scalable/apps/butterview.svg
    for s in 48 128 256; do
      mkdir -p $out/share/icons/hicolor/''${s}x''${s}/apps
      magick -background none -density 300 data/butterview.svg -resize ''${s}x''${s} \
        $out/share/icons/hicolor/''${s}x''${s}/apps/butterview.png
    done
    install -Dm644 README.md $out/share/doc/butterview/README.md
    install -Dm644 data/butterview.conf.example $out/share/doc/butterview/butterview.conf.example

    # Spawned at runtime: fc-match for the font, wl-copy/xclip for the
    # clipboard, xdg-open and gio for "show in folder"/trash.
    wrapProgram $out/bin/butterview \
      --prefix PATH : ${lib.makeBinPath [ fontconfig wl-clipboard xclip xdg-utils glib ]}
  '';

  meta = {
    description = "Small, fast image viewer on SDL3";
    homepage = "https://justaguy.dev/drew/butterview";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "butterview";
  };
})
