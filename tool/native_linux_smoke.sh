#!/usr/bin/env bash
set -euo pipefail
shiori_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
shiori_binary="$shiori_root/build/linux/x64/release/bundle/shiori"
shiori_output="$shiori_root/build/native-validation"
test -x "$shiori_binary"
mkdir -p "$shiori_output"

xvfb-run -a -s '-screen 0 1440x1100x24 -nolisten tcp' \
  env LIBGL_ALWAYS_SOFTWARE=1 GDK_BACKEND=x11 GSETTINGS_BACKEND=memory \
  bash -s -- "$shiori_binary" "$shiori_output" <<'SHIORI_SMOKE'
set -euo pipefail
shiori_binary=$1
shiori_output=$2
"$shiori_binary" >"$shiori_output/application.log" 2>&1 &
shiori_app_pid=$!
shiori_cleanup() {
  kill "$shiori_app_pid" 2>/dev/null || true
  wait "$shiori_app_pid" 2>/dev/null || true
}
trap shiori_cleanup EXIT
shiori_window=""
for shiori_attempt in $(seq 1 20); do
  if ! kill -0 "$shiori_app_pid" 2>/dev/null; then
    cat "$shiori_output/application.log"
    exit 1
  fi
  shiori_window=$(xdotool search --onlyvisible --name '^shiori$' 2>/dev/null | head -1) || true
  if [ -n "$shiori_window" ]; then break; fi
  sleep 1
done
test -n "$shiori_window"
xdotool windowsize "$shiori_window" 1440 1100
sleep 3
scrot --overwrite "$shiori_output/screenshot-linux.png"
xdotool getwindowname "$shiori_window" >"$shiori_output/window-title.txt"
kill -0 "$shiori_app_pid"
echo 'PASS: native Linux release process stayed alive and rendered a GTK window.'
SHIORI_SMOKE
