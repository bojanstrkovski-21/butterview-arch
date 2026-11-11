# butterview

## Overview

Fast folder image viewer: one image, a thumbnail strip, a status line.
Upstream is Drew (justaguylinux), GPL-3.0-or-later. Do not relicense.

The workspace root is `/home/bojanstrko/Projects/butterview`. It is not a
git repository. Do not `git init` it unless asked.

## Layout

- `butterview-arch/` is our working tree. No `.git`. This is the code to edit.
  It started as upstream `4c247056f0cd8989975dd5e3683564993da614f7`
  (2026-11-06, "consistent readme footer").
- `upstream/` is a read-only clone of
  `https://justaguy.dev/drew/butterview.git`, branch `main`, for an
  occasional sync. Same role as `dwm-titus/` in dwm-quickshell. Do not
  edit it. Do not commit there. A root sync script is not written yet.
- `CLAUDE.md`, `memory/`, and `install-scripts/` stay at the workspace root.
  `install-scripts/deps.sh` installs the Arch packages, including `mise`, then pins Zig 0.16.0 in `mise.toml`. It does not install `extra/zig`.

## Stack

- **Language**: Zig 0.16. Root module is `butterview-arch/src/main.zig`.
- **Libraries**: SDL3, SDL3_image, SDL3_ttf, libjpeg-turbo (`turbojpeg`), libdbus. No GTK, no Qt.
- **Other sources**: `butterview-arch/src/exif.zig`, `gif.zig`, `portal.zig`, `theme.zig`.
- **Packaging**: `butterview-arch/flake.nix`, `butterview-arch/package.nix`, `butterview-arch/data/`.

## Conventions

- Project instructions stay in this file. The session log is `memory/PROJECT.md`.
- The cross-project fact is `~/.agents/memory/project-butterview.md`. Grok's note is `~/.grok/memory-v2/workspaces/butterview-388e1c07/topics/butterview.md`.
- Confirm-first, git, and push rules live in `~/.agents`. They are not repeated here.

## Constraints

- License stays GPL-3.0-or-later. See `butterview-arch/LICENSE`.
- Rotate and crop must not overwrite the original. Saves write a new file beside it.
- Do not `git init`, commit, or push unless the user asks.
- Never write credentials into this workspace.

## Frozen Files

`upstream/` is a reference clone. Do not edit it.

## How to Run

```bash
cd ~/Projects/butterview
bash install-scripts/deps.sh
bash install-scripts/zig_build.sh
butterview-arch/zig-out/bin/butterview --shot /tmp/out.png --size 1280x800 path
```

Arch packages for a build and a working window: `mise`, `sdl3`, `sdl3_image`, `sdl3_ttf`, `libjpeg-turbo`, `dbus`, `fontconfig`. The compiler is Zig 0.16.0 from mise, not `extra/zig` (that is 0.17).

## Current state

The latest session is the top entry of `memory/PROJECT.md`.

## Session Workflow

Follow `~/.agents/commands/start-session.md` and `end-session.md`.

- **"start session"**: read `memory/PROJECT.md`, summarize, confirm the goal. Upstream sync is manual until a script exists.
- **"end session"** or **"end-session"**: write the session entry, update this file if a rule changed, and sync `~/.agents/memory/` without asking. Report what was written. Do not commit or push.
