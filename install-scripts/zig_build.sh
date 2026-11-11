#!/bin/bash
# zig_build.sh -- build our tree with the Zig 0.16.0 pinned at the workspace root.
# From the workspace root:
#   bash install-scripts/zig_build.sh
#
# Extra arguments are passed to `zig build` (for example `-Dversion=0.4.5`).
# The binary lands in butterview-arch/zig-out/bin/butterview.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/butterview-arch"

if [ ! -f "$src/build.zig" ]; then
  echo "zig_build.sh: $src/build.zig is missing." >&2
  exit 1
fi
if ! command -v mise >/dev/null 2>&1; then
  echo "zig_build.sh: mise is not on PATH. Run install-scripts/deps.sh first." >&2
  exit 1
fi

cd "$src"
exec mise exec -- zig build -Doptimize=ReleaseSafe "$@"
