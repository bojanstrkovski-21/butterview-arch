# Project memory

## Session 4: Arch package, folder view on an empty launch

2026-11-11.

**Done:**

- Root `PKGBUILD` builds butterview 0.4.5. `makepkg -s` from the repo root. It creates `build/` if missing and sets `BUILDDIR`, `PKGDEST`, and `SRCDEST` there. `/build/` is gitignored. Do not leave a `.pkg.tar.zst` in the repo.
- `build()` runs `ensure-zig.install`. That installs pacman package `mise` when it is missing, then Zig 0.16.0 through mise only when this tree does not already have it. Arch `extra/zig` (0.17) is not used. Zig is not a runtime dependency. `mise` is a makedepend.
- `mise which zig` has to run from the repo root (`mise.toml`). `mise exec -- command -v zig` fails because `command` is a shell builtin.
- A launch with no real path opens the folder view on `$HOME` (expanded). `.`, `./`, and an unexpanded `%f` count as no path. A missing path does not exit. Open with a real image still opens that image. Checked headless: no args, `.`, and a bad path showed the folder view; `screenshot/butterview.webp` showed that image.
- Installed `/usr/bin/butterview` is the package. The desktop `Icon=butterview` matches the hicolor icons. A blank launcher icon was a stale Quickshell lookup; a Quickshell reload showed it.
- User committed `6a5e2cb` ("builder completed"): `.gitignore`, `PKGBUILD`, `ensure-zig.install`, and the `main.zig` launch change. Local `main` matches the recorded `origin/main`. This session did not push.

**Open:**

- The five files in `drafts/issues/` are not sent upstream.
- No sync script. License remains GPL-3.0-or-later.
- User commits and pushes. Do not run `push.sh` or contact the remote.

## Session 3: ten review fixes, ReleaseSafe build green

2026-11-11.

**Done:**

- The ten items in `to-do.txt` are in `butterview-arch/` and checked off. Not sent upstream. No commit.
- `bash install-scripts/zig_build.sh` (`mise exec -- zig build -Doptimize=ReleaseSafe`) exited 0. Binary `butterview-arch/zig-out/bin/butterview`.
- Save-name check uses `std.c.access` and `std.c.errno`. Zig 0.16's `std.c.stat` does not compile (`c.private` has no `stat`). A missing name is free. Any other error refuses the save. Names through `-99` are not overwritten.
- Headless `--shot` of `screenshot/butterview.webp` wrote a 1280×800 PNG. Status line read `butterview.webp  2/3  1280×720  94%`.
- A throwaway `zig run` called `exif.parse` on a short APP1 and a truncated APP1 (neither set `found`) and `theme.fromCss` on `rgb(400, -20, 10)` (background came out 255, 0, 10). That file was deleted.
- Issues to send are five files in `drafts/issues/`, grouped because the forge allows five uploads: thumbnails and paths, GIF frames, crash on bad input, save names and folders, quit. Each file starts with the title and the text to paste, then the diffs.

**Not checked in the window:** folder-view `q`, GIF save of the frame on screen, portal join at quit, sibling stepping, thumbnail replacement. No CI, no independent review.

**Open:**

- User sends the change. Do not `git init`, commit, or push unless asked.
- No sync script. License remains upstream GPL-3.0-or-later.

## Session 2: split our tree from the upstream clone

2026-11-11.

**Done:**

- Moved the app into `butterview/`, later renamed `butterview-arch/`. That tree has no `.git`. It is the copy to edit.
- Left `CLAUDE.md` and `memory/` at the workspace root. Nothing else belonged there. Install scripts stay a later decision.
- Cloned `https://justaguy.dev/drew/butterview.git` into `upstream/` (`main` tracking `origin/main`). Read-only reference, same idea as `dwm-titus/` in dwm-quickshell. No sync script yet.
- Upstream HEAD is still `4c247056f0cd8989975dd5e3683564993da614f7`. Our tree matches that commit. Zero commits are ahead.
- Arch names checked with `pacman` and `pkg-config`. Needed to link and open pictures: `sdl3`, `sdl3_image`, `sdl3_ttf`, `libjpeg-turbo`, `dbus`. `fontconfig` is needed for on-screen text (`fc-match`). Copy, trash, and "open folder" need `wl-clipboard` or `xclip`, `glib2` (`gio`), and `xdg-utils`, and the app still runs without them. `pkgconf` is build-only. pkg-config names on Arch are `sdl3`, `sdl3-image`, `sdl3-ttf`, `libturbojpeg`, `dbus-1`. `build.zig` asks for `SDL3`, `SDL3_image`, `SDL3_ttf`, `turbojpeg`, `dbus-1`. Only `dbus-1` matches. The `.so` names match the `build.zig` strings except that pkg-config itself does not.

**Open:**

- Review fixes landed in session 3. See that section.
- `install-scripts/zig_build.sh` builds `butterview-arch` with `mise exec -- zig build -Doptimize=ReleaseSafe`.
- No sync script. No `mise.toml`.
- `install-scripts/deps.sh` installs missing Arch packages after a yes, including `mise`. Zig is checked only after `mise` is on PATH. A yes there runs `mise use --pin zig@0.16.0` and writes `mise.toml` at the workspace root. `extra/zig` is not installed. The script has not been run with yes since this change.
- No remote of our own. Do not `git init` unless asked.
- License remains upstream GPL-3.0-or-later.

## Session 1: adopt the tree, drop upstream git, add memory

2026-11-11. First session in `/home/bojanstrko/Projects/butterview`.

**Done:**

- Checked memory. `~/.agents` is the shared source (skills, `memory/`, session commands). `~/.grok/skills/*` are symlinks into `~/.agents/skills`. Grok's own store is `~/.grok/memory-v2/`. This session has that store on. Global topics were empty. This workspace (`butterview-388e1c07`) had no topics.
- The directory was a clean clone of `https://justaguy.dev/drew/butterview.git`, branch `main` at `4c247056f0cd8989975dd5e3683564993da614f7` (Drew, 2026-11-06, "consistent readme footer"), 56 commits, tracking `origin/main`.
- Removed `.git` on request. This directory is not a git repository. Do not `git init` unless asked.
- Added `CLAUDE.md`, this file, `~/.agents/memory/project-butterview.md`, and the Grok workspace topic `butterview.md`.

**Open:**

- Source review finished the same day. Checked against the files. Highest: thumbnails can be decoded twice and the first texture leaked (`main.zig` `plan` never sets `thumb_state` to loading); a one-frame GIF keeps a 5 ms wake; saving a GIF uses `IMG_Load` instead of the frame on screen; a short JPEG APP1 segment can panic in `exif.zig`; save names past `-99` overwrite; folder-dialog and appearance threads are detached across `SDL_Quit`. Also: hidden-only folders are stepped into, `rgb()` channels are not clamped, paths are kept for the process lifetime, and `q` closes the folder view instead of quitting.
- Remote is `git@github.com:bojanstrkovski-21/butterview-arch.git`. `push.sh` and `set-git-cred.sh` are at the workspace root. `upstream/` is gitignored and is not part of that repo.
- License remains upstream GPL-3.0-or-later.
