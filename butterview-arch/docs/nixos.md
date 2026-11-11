# Adding butterview to your NixOS flake

By [ddubs](https://gitlab.com/dwilliam62/ddubsos), who runs butterview from this flake in his own NixOS configuration. The short version is in the README under Nix; this is the whole story.

## What the flake provides

| Output                         | Value                          |
| ------------------------------ | ------------------------------ |
| `packages.<system>.butterview` | the package                    |
| `packages.<system>.default`    | the same thing as `butterview` |

`<system>` is `x86_64-linux` or `aarch64-linux`. There is no `overlays`
output and no NixOS or Home Manager module, so you wire it in yourself —
two ways are below.

The derivation builds from the flake's own source tree (`src = ./.`) and
installs the binary, the man page, the `.desktop` file and the icons. The
binary is wrapped so `fc-match`, `wl-copy`/`xclip`, `xdg-open` and `gio` are
on its `PATH` at runtime.

## Requirements

- Flakes enabled: `experimental-features = nix-command flakes`.
- A nixpkgs that carries `zig_0_16`, `sdl3`, `sdl3-image` and `sdl3-ttf`.
  That means a reasonably current unstable; a stable channel older than those
  attributes will fail to evaluate.

The build's inputs, for reference:

| Kind                         | Packages                                                                 |
| ---------------------------- | ------------------------------------------------------------------------ |
| build                        | `zig_0_16` (hook), `pkg-config`, `makeWrapper`, `imagemagick`, `librsvg` |
| link                         | `sdl3`, `sdl3-image`, `sdl3-ttf`, `libjpeg_turbo`, `dbus`                |
| runtime, wrapped onto `PATH` | `fontconfig`, `wl-clipboard`, `xclip`, `xdg-utils`, `glib`               |

## 1. Add the input

The project lives on its own Forgejo, not GitHub, so the URL is a
`git+https` one rather than `github:owner/repo`.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    butterview = {
      url = "git+https://justaguy.dev/drew/butterview";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

Useful URL forms:

| Want                     | URL                                                          |
| ------------------------ | ------------------------------------------------------------ |
| track the default branch | `git+https://justaguy.dev/drew/butterview`                   |
| pin a release tag        | `git+https://justaguy.dev/drew/butterview?ref=v0.4.1`        |
| pin a revision           | `git+https://justaguy.dev/drew/butterview?rev=<40-char-sha>` |

Then lock it:

```bash
nix flake lock     # writes the resolved revision into your flake.lock
```

### Why `inputs.nixpkgs.follows`

Upstream pins `nixpkgs` to `nixos-unstable`. Following your own `nixpkgs`
builds butterview against the same SDL3, Zig and glibc as the rest of your
system: one nixpkgs in the closure instead of two, and no chance of two
copies of SDL3 being linked in. That is the setting you want almost always.

The trade-off is that the build then depends on _your_ nixpkgs carrying
`zig_0_16` and the `sdl3*` attributes. If yours is a stable release that
predates them, drop the `follows` line and let upstream's own `nixos-unstable`
pin build it.

## 2. Put it where you want it

### Option A — an overlay (recommended)

Expose it as `pkgs.butterview` once, and every module can use it without
knowing anything about flake inputs:

```nix
# modules/overlays.nix
{ inputs, ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      butterview = inputs.butterview.packages.${final.stdenv.hostPlatform.system}.butterview;
    })
  ];
}
```

```nix
# anywhere else
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.butterview ];
}
```

Use `${final.stdenv.hostPlatform.system}` rather than a hardcoded
`"x86_64-linux"`, so the overlay keeps working if you ever build for another
system.

### Option B — reference the input directly

Fine for a one-liner, at the cost of handing `inputs` to every module that
wants the package:

```nix
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.butterview.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
```

### Option C — Home Manager

The same package, per user, when you do not want it system-wide:

```nix
{ inputs, pkgs, ... }:
{
  home.packages = [
    inputs.butterview.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
```

### Option D — no flake change at all

For a try-out, a shell, or a machine you do not manage declaratively:

```bash
nix run   git+https://justaguy.dev/drew/butterview            # run it once
nix shell git+https://justaguy.dev/drew/butterview            # put it on PATH
nix profile install git+https://justaguy.dev/drew/butterview  # install for your user
```

All three use `packages.<system>.default`, which is `butterview`.

## 3. Build and verify

```bash
nix build git+https://justaguy.dev/drew/butterview   # -> ./result/bin/butterview
```

Or from a checkout you already have on disk:

```bash
nix build /path/to/butterview#butterview
```

And after wiring it into your configuration:

```bash
nh os test                                  # build, do not switch
sudo nixos-rebuild switch --flake .#<host>  # or zcli rebuild
```

## Updating

```bash
nix flake update butterview   # move only this input
nix flake update              # move everything
```

To try a branch or a newer tag without touching your lock file:

```bash
sudo nixos-rebuild switch --flake .#<host> \
  --override-input butterview git+https://justaguy.dev/drew/butterview?ref=main
```

## Caveats worth knowing

- **No `flake.lock` upstream.** Deliberate for a package flake: you pin the
  revision in _your_ lock file, and `nix flake update butterview` is what
  moves it.
- **Packages only.** There is no `overlays.default` and no module, so there
  is no `imports = [ inputs.butterview.nixosModules.default ]`. Options A, B
  and C above are the whole integration story.
- **It builds from the source tree** (`src = ./.`). As an input, Nix copies
  the git tree into the store, so only committed (or `git add`ed) files are
  built. Fork it, add a file, forget to stage it, and the build will not see
  it.
- **Zig 0.16 specifically.** `zig_0_16` from nixpkgs, not `zig`. If your
  nixpkgs carries only another `zig`, the build fails in the hook — bump
  nixpkgs, or override `zig_0_16`.
- **Wayland and X11 both work**, chosen at runtime with no flags to set.
  `wl-clipboard` and `xclip` are both wrapped in, so clipboard copy works on
  either session.
- **`aarch64-linux` is declared** in `systems`, but upstream work is on
  `x86_64-linux`; treat aarch64 as untested.

### Building from a release tarball instead

Because `package.nix` reads its version through `finalAttrs`, an
`overrideAttrs` bump updates both the derivation and the `-Dversion` handed
to Zig:

```nix
pkgs.butterview.overrideAttrs (old: {
  version = "0.5.0";
  src = pkgs.fetchzip {
    url = "https://justaguy.dev/drew/butterview/archive/v0.5.0.tar.gz";
    hash = "sha256-...";   # nix-prefetch-url --unpack <url>
  };
})
```

## Removing it

Drop the input and the overlay entry, then re-lock so the unused input is
pruned from `flake.lock`:

```bash
nix flake lock     # prune the input that is no longer referenced
zcli rebuild       # or: nh os switch, or sudo nixos-rebuild switch --flake .#<host>
```

## Links

- Project and README: <https://justaguy.dev/drew/butterview>
- Tags: <https://justaguy.dev/drew/butterview/tags>
- Source tarball: <https://justaguy.dev/drew/butterview/archive/v0.4.1.tar.gz>
- License: GPL-3.0-or-later
