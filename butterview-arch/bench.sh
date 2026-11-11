#!/usr/bin/env bash
# bench.sh — is butterview still the quickest to open, and still light?
#
#   ./bench.sh <image> [runs]
#
# Opens the image in butterview and in every other viewer that is installed,
# RUNS times each (default 5), and reports the median time from launch to a
# window existing, plus memory after the image has settled. Windows will
# flash on screen while it runs. Needs mango (it asks mmsg when a window
# appears), so it is a tool for this desktop, not a general one.
set -euo pipefail

img=${1:?usage: bench.sh <image> [runs]}
runs=${2:-5}
img=$(readlink -f "$img")
command -v mmsg >/dev/null || { echo "bench.sh needs mango's mmsg" >&2; exit 1; }

clients() {
    mmsg get all-clients | python3 -c '
import json, sys
print(" ".join("%d:%d" % (c["id"], c["pid"]) for c in json.load(sys.stdin)["clients"]))'
}

# launch, wait for a client that was not there before; prints "ms pid"
open_once() {
    local before new="" t0 t1 e i
    before=" $(clients) "
    t0=$(date +%s%N)
    setsid -f "$@" >/dev/null 2>&1
    for i in $(seq 1 400); do
        for e in $(clients); do
            case "$before" in *" $e "*) ;; *) new=$e ;; esac
        done
        [ -n "$new" ] && break
        sleep 0.01
    done
    t1=$(date +%s%N)
    [ -n "$new" ] || { echo "0 0"; return; }
    echo "$(( (t1 - t0) / 1000000 )) ${new#*:}"
}

median() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

bench() {
    local name=$1; shift
    local times=() ms pid rss=0 pss=0 i
    for i in $(seq 1 "$runs"); do
        read -r ms pid < <(open_once "$@")
        [ "$pid" = 0 ] && { printf '%-11s no window\n' "$name"; return; }
        times+=("$ms")
        if [ "$i" = "$runs" ]; then
            sleep 3
            rss=$(awk '/^Rss:/{print int($2/1024)}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo 0)
            pss=$(awk '/^Pss:/{print int($2/1024)}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo 0)
        else
            sleep 0.4
        fi
        kill "$pid" 2>/dev/null || true
        sleep 0.5
    done
    printf '%-11s %4d ms to window (median of %d: %s) | %4d MB RSS | %4d MB PSS\n' \
        "$name" "$(printf '%s\n' "${times[@]}" | median)" "$runs" "${times[*]}" "$rss" "$pss"
}

here=$(dirname "$(readlink -f "$0")")
bench butterview "$here/zig-out/bin/butterview" "$img"
for v in qimgv swayimg feh imv lximage-qt gthumb eog loupe; do
    command -v "$v" >/dev/null && bench "$v" "$v" "$img"
done
