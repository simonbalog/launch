#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [ -f config.env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./config.env
  set +a
fi

: "${VIDEO_DEVICE:=/dev/video0}"
: "${VIDEO_SIZE:=1280x720}"
: "${FRAMERATE:=30}"
: "${GOP:=15}"
: "${BITRATE:=1500k}"
: "${BUFSIZE:=3000k}"
: "${HLS_TIME:=0.5}"
: "${HLS_LIST_SIZE:=6}"
: "${PORT:=8080}"
: "${GIT_BRANCH:=main}"
: "${PAGES_DIR:=docs}"
: "${REMOTE:=origin}"

mkdir -p run logs stream/hls "$PAGES_DIR"
"$ROOT/stop.sh" >/dev/null 2>&1 || true
rm -f stream/hls/*.ts stream/hls/*.m3u8

if [ ! -x bin/ffmpeg ] || [ ! -x bin/cloudflared ]; then
  echo "Chybí binárky, spouštím setup.sh..." >&2
  "$ROOT/setup.sh" --deps-only
fi

echo "[1/4] Spouštím ffmpeg z $VIDEO_DEVICE..."
bin/ffmpeg -hide_banner -loglevel warning \
  -fflags nobuffer \
  -f v4l2 -framerate "$FRAMERATE" -video_size "$VIDEO_SIZE" -i "$VIDEO_DEVICE" \
  -an -c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -pix_fmt yuv420p \
  -x264-params "rc-lookahead=0:sync-lookahead=0:bframes=0:scenecut=0" \
  -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
  -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BUFSIZE" \
  -force_key_frames "expr:gte(t,n_forced*$HLS_TIME)" \
  -f hls -hls_time "$HLS_TIME" -hls_list_size "$HLS_LIST_SIZE" \
  -hls_flags delete_segments+append_list+omit_endlist+independent_segments+program_date_time \
  -flush_packets 1 \
  -hls_segment_filename "stream/hls/seg_%05d.ts" \
  stream/hls/index.m3u8 \
  >> logs/ffmpeg.log 2>&1 &
echo $! > run/ffmpeg.pid

echo "[2/4] Spouštím HLS server na 127.0.0.1:$PORT..."
python3 stream/hls_server.py --dir stream/hls --host 127.0.0.1 --port "$PORT" \
  >> logs/server.log 2>&1 &
echo $! > run/server.pid

echo "[3/4] Čekám na první HLS segmenty..."
READY_SEG=0
for _ in $(seq 1 30); do
  if [ -s stream/hls/index.m3u8 ] && grep -q '\.ts' stream/hls/index.m3u8; then
    READY_SEG=1
    break
  fi
  if ! kill -0 "$(cat run/ffmpeg.pid)" 2>/dev/null; then
    break
  fi
  sleep 1
done
if [ "$READY_SEG" != 1 ]; then
  echo "CHYBA: ffmpeg nevygeneroval HLS. Viz logs/ffmpeg.log:" >&2
  tail -n 15 logs/ffmpeg.log >&2 || true
  "$ROOT/stop.sh" >/dev/null 2>&1 || true
  exit 1
fi

echo "[4/4] Otevírám veřejný tunel (Cloudflare)..."
bin/cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate \
  > logs/tunnel.log 2>&1 &
echo $! > run/tunnel.pid

URL=""
for _ in $(seq 1 60); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' logs/tunnel.log | head -1 || true)
  [ -n "$URL" ] && break
  if ! kill -0 "$(cat run/tunnel.pid)" 2>/dev/null; then
    break
  fi
  sleep 1
done
if [ -z "$URL" ]; then
  echo "CHYBA: tunel nevydal veřejnou URL. Viz logs/tunnel.log:" >&2
  tail -n 15 logs/tunnel.log >&2 || true
  "$ROOT/stop.sh" >/dev/null 2>&1 || true
  exit 1
fi

echo "Veřejná URL streamu: $URL"
echo "Čekám, až bude URL dostupná..."
PUBLIC_OK=0
for _ in $(seq 1 45); do
  if curl -fsS -m 5 "$URL/health" >/dev/null 2>&1; then
    PUBLIC_OK=1
    break
  fi
  sleep 2
done
if [ "$PUBLIC_OK" = 1 ]; then
  echo "Tunel je dostupný."
else
  echo "Pozor: URL zatím neodpovídá (DNS může chvíli trvat)."
fi

printf '{\n  "url": "%s",\n  "updated": "%s"\n}\n' \
  "$URL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PAGES_DIR/stream.json"

if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git diff --quiet -- "$PAGES_DIR/stream.json" 2>/dev/null; then
    git add "$PAGES_DIR/stream.json"
    git commit -m "stream: update live URL" >/dev/null
    if git push "$REMOTE" "$GIT_BRANCH" >/dev/null 2>&1; then
      echo "URL publikována na GitHub Pages."
    else
      echo "Pozor: push na GitHub selhal, URL je jen lokálně."
    fi
  fi
fi

echo
echo "Hotovo. Stream běží na pozadí."
echo "  Veřejný stream: $URL"
echo "  GitHub Pages:   https://simonbalog.github.io/launch/"
echo "  Zastavení:      $ROOT/stop.sh"
echo "  Logy:           $ROOT/logs/"
