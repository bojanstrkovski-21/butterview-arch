#!/bin/bash
# deps.sh -- Arch packages butterview links and the commands it shells out to.
# Arch-only. From the workspace root:
#   bash install-scripts/deps.sh
#
# Looks at what is installed first and only offers what is missing.
# Required packages are the ones the binary links, plus pkgconf to find
# them at build time and fontconfig because the window runs fc-match for
# its text. Optional packages are the commands for copy, trash, and
# "show folder". The viewer still starts without those.
#
# glibc is not in either list. It is already a dependency of the base
# package on every Arch install.
#
# mise is installed with the required packages. Only after that does this
# script look for Zig. The compiler is Zig 0.16.0 from mise, pinned in
# mise.toml at the workspace root. extra/zig is 0.17 and is not installed.
#
# Exit status: 0 = done or nothing missing, 3 = declined, 130 = cancelled.
set -euo pipefail

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  echo "deps.sh: /etc/os-release is missing; this script is for Arch." >&2
  exit 1
fi
if [ "${ID:-}" != arch ]; then
  echo "deps.sh: this machine is ${ID:-unknown}, not Arch." >&2
  exit 1
fi
if ! command -v pacman >/dev/null 2>&1; then
  echo "deps.sh: pacman is not on PATH." >&2
  exit 1
fi

# Linked by butterview-arch/build.zig, plus the build and font tools.
# pkg-config file names differ from these package names:
#   sdl3 -> sdl3.pc
#   sdl3_image -> sdl3-image.pc
#   sdl3_ttf -> sdl3-ttf.pc
#   libjpeg-turbo -> libturbojpeg.pc
#   dbus -> dbus-1.pc
required_pkgs=(
  mise
  pkgconf
  sdl3
  sdl3_image
  sdl3_ttf
  libjpeg-turbo
  dbus
  fontconfig
)

# Commands the running viewer looks up. Not needed to open a picture.
optional_pkgs=(
  wl-clipboard
  xclip
  glib2
  xdg-utils
)

missing_of() {
  local pkg
  local -a missing=()
  for pkg in "$@"; do
    if ! pacman -Q "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf '%s\n' "${missing[@]}"
  fi
}

confirm() {
  local prompt=$1
  local answer
  if [ ! -t 0 ]; then
    echo "deps.sh: no terminal, not installing. Re-run from a terminal to confirm." >&2
    return 3
  fi
  read -r -p "$prompt" answer || return 130
  case $answer in
    y | Y | yes | YES) return 0 ;;
    *) return 3 ;;
  esac
}

install_missing() {
  local label=$1
  shift
  local -a missing=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && missing+=("$line")
  done < <(missing_of "$@")

  if [ "${#missing[@]}" -eq 0 ]; then
    echo "$label: nothing missing."
    return 0
  fi
  echo "$label missing:"
  printf '  %s\n' "${missing[@]}"
  local rc=0
  confirm "Install these ${#missing[@]} packages with pacman? [y/N] " || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "Skipped $label."
    return "$rc"
  fi
  sudo pacman -S --needed --noconfirm -- "${missing[@]}"
}

# mise has to be on PATH before Zig is considered. A zig binary already on
# PATH is not enough: extra/zig is 0.17, and this tree needs 0.16.0.
ensure_zig() {
  if ! command -v mise >/dev/null 2>&1; then
    echo "deps.sh: mise is not installed, so Zig was not checked." >&2
    return 3
  fi
  local root selected
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  selected=$(cd "$root" && mise current zig 2>/dev/null || true)
  if [[ $selected == 0.16.* ]]; then
    echo "Zig $selected is already selected for this project."
    (cd "$root" && mise exec -- zig version)
    return 0
  fi
  echo "Zig 0.16 is not selected here (mise current: ${selected:-none})."
  local rc=0
  confirm "Install Zig 0.16.0 with mise and pin it for this project? [y/N] " || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "Skipped Zig."
    return "$rc"
  fi
  (cd "$root" && MISE_YES=1 mise use --pin zig@0.16.0)
  (cd "$root" && mise exec -- zig version)
}

echo "glibc is part of base ($(pacman -Q glibc | awk '{print $2}')). Not installed by this script."
echo "extra/zig is Zig 0.17 and is not used. Zig 0.16.0 comes from mise, after mise itself is installed."
echo

req_rc=0
install_missing "Required" "${required_pkgs[@]}" || req_rc=$?
echo
zig_rc=0
ensure_zig || zig_rc=$?
echo
opt_rc=0
install_missing "Optional" "${optional_pkgs[@]}" || opt_rc=$?

if [ "$req_rc" -eq 130 ] || [ "$zig_rc" -eq 130 ] || [ "$opt_rc" -eq 130 ]; then
  exit 130
fi
if [ "$req_rc" -ne 0 ]; then
  exit "$req_rc"
fi
if [ "$zig_rc" -ne 0 ]; then
  exit "$zig_rc"
fi
exit 0
