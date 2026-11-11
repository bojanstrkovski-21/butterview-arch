#!/bin/bash
# How screenshot/butterview.webp was recorded: butterview floated at 1600x900
# on a bspwm X11 session, driven by xdotool, captured with ffmpeg x11grab,
# then (animated WebP: a quarter of the GIF's size, every forge shows it):
#       ffmpeg -i rec.mkv -vf "fps=12,scale=1280:-1:flags=lanczos" -loop 0 \
#           -c:v libwebp_anim -quality 80 -compression_level 6 butterview.webp
# The window is floated at X/Y WWxHH; the capture covers the whole screen
# (CAP*), so the desktop shows around it. Adjust and the pauses to taste.
export DISPLAY=:0
DIR=~/.config/suckless/wallpaper
X=480; Y=270; WW=1600; HH=900
read -r CAPW CAPH < <(xdpyinfo | awk '/dimensions/{split($2,a,"x"); print a[1], a[2]}')
CAPX=0; CAPY=0
trap 'xdotool keyup Right Left i r R x 0 q Escape plus 2>/dev/null; pkill -f "x11grab" 2>/dev/null' EXIT
k() { xdotool search --class butterview | grep -qx "$W" || { echo "window gone before $1"; exit 1; }; xdotool key --window "$W" "$@"; }
(butterview "$DIR/bluemountain.jpg" >/dev/null 2>&1 &)
sleep 1.5
W=$(xdotool search --class butterview | tail -1); [ -z "$W" ] && { echo no window; exit 1; }
xprop -id "$W" WM_CLASS
bspc node "$W" -t floating; sleep 0.3
xdotool windowsize "$W" $WW $HH; xdotool windowmove "$W" $X $Y; sleep 0.8
eval "$(xdotool getwindowgeometry --shell "$W")"; echo "window $WIDTH x $HEIGHT at $X,$Y"
# first frame of the recording: the viewer in place, strip filled
ffmpeg -loglevel error -y -f x11grab -framerate 25 -video_size "${CAPW}x${CAPH}" -i ":0.0+${CAPX},${CAPY}" -c:v libx264 -preset ultrafast -qp 0 -pix_fmt yuv444p "${OUT:-$HOME/rec.mkv}" &
REC=$!
sleep 1.2
cx=$((X+WIDTH/2)); cy=$((Y+HEIGHT/2))
# step through the folder
for _ in 1 2 3; do k Right; sleep 0.9; done
# click a thumbnail further along the strip
xdotool mousemove $((X+WIDTH*3/4)) $((Y+46)); sleep 0.5; xdotool click 1; sleep 1.4
# info panel
k i; sleep 2.2; k i; sleep 0.6
# zoom at the pointer, pan, fit
xdotool mousemove $((cx+150)) $((cy+40)); sleep 0.3
for _ in 1 2 3 4; do xdotool click 4; sleep 0.25; done; sleep 0.8
xdotool mousedown 1; for _ in 1 2 3 4 5 6 7 8; do xdotool mousemove_relative -- -30 -12; sleep 0.05; done; xdotool mouseup 1; sleep 0.8
k 0; sleep 1.0
# rotate (toast), and back
k r; sleep 1.6; k R; sleep 0.8
# the menu
xdotool mousemove $((cx-100)) $((cy-60)); sleep 0.3; xdotool click 3; sleep 0.6
xdotool mousemove $((cx-60)) $((cy+20)); sleep 0.6; xdotool mousemove $((cx-60)) $((cy+80)); sleep 0.9; k Escape; sleep 0.6
# one more wallpaper, then out
k Right; sleep 1.2
k q; sleep 0.8
kill -INT $REC; wait $REC 2>/dev/null
ls -la "${OUT:-$HOME/rec.mkv}"
