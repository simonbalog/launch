#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
umask 077

# config.env is executable shell syntax: only load a file you trust.
if [[ -f config.env ]]; then
  # shellcheck disable=SC1091
  source config.env
fi

: "${VIDEO_DEVICE:=/dev/video0}"
: "${VIDEO_SIZE:=1280x720}"
: "${FRAMERATE:=30}"
: "${GOP:=18}"
: "${BITRATE:=1500k}"
: "${BUFSIZE:=3000k}"
: "${HLS_TIME:=0.6}"
: "${HLS_LIST_SIZE:=6}"
: "${PORT:=8080}"
: "${GIT_BRANCH:=main}"
: "${PAGES_DIR:=docs}"
: "${REMOTE:=origin}"
: "${SEGMENT_WAIT:=30}"
: "${TUNNEL_WAIT:=60}"
: "${PUBLIC_WAIT:=90}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'CHYBA: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Linux ]] || die 'Tento skript vyžaduje Linux.'
for command in python3 curl git flock; do
  command -v "$command" >/dev/null 2>&1 || die "Chybí příkaz: $command"
done
[[ "$VIDEO_SIZE" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || die 'VIDEO_SIZE musí mít formát WIDTHxHEIGHT.'
[[ "$FRAMERATE" =~ ^[1-9][0-9]*$ ]] || die 'FRAMERATE musí být kladné celé číslo.'
[[ "$GOP" =~ ^[1-9][0-9]*$ ]] || die 'GOP musí být kladné celé číslo.'
[[ "$HLS_LIST_SIZE" =~ ^[2-9][0-9]*$ ]] || die 'HLS_LIST_SIZE musí být celé číslo alespoň 2.'
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die 'PORT musí být v rozsahu 1–65535.'
[[ "$HLS_TIME" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v n="$HLS_TIME" 'BEGIN { exit !(n > 0 && n <= 10) }' || die 'HLS_TIME musí být číslo větší než 0 a nejvýše 10.'
[[ "$BITRATE" =~ ^[1-9][0-9]*[kKmM]?$ ]] || die 'Neplatný BITRATE.'
[[ "$BUFSIZE" =~ ^[1-9][0-9]*[kKmM]?$ ]] || die 'Neplatný BUFSIZE.'
[[ "$SEGMENT_WAIT" =~ ^[1-9][0-9]*$ && "$TUNNEL_WAIT" =~ ^[1-9][0-9]*$ && "$PUBLIC_WAIT" =~ ^[1-9][0-9]*$ ]] || die 'Timeouty musí být kladná celá čísla.'
[[ -e "$VIDEO_DEVICE" && -r "$VIDEO_DEVICE" ]] || die "Kamera neexistuje nebo ji nelze číst: $VIDEO_DEVICE"

mkdir -p run logs stream/hls "$PAGES_DIR"
exec 9>run/start.lock
flock -n 9 || die 'Jiný start streamu právě probíhá.'

# Refuse to overwrite a running stream. stop.sh verifies the executable/script
# identity before sending signals, so stale/reused PIDs are not killed blindly.
for name in tunnel server ffmpeg; do
  pidfile="run/$name.pid"
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      die "PID soubor $pidfile ukazuje na běžící proces $pid; nejprve spusťte ./stop.sh."
    fi
    rm -f "$pidfile"
  fi
done

for required in bin/ffmpeg bin/cloudflared; do
  if [[ ! -x "$required" ]]; then
    log "Chybí $required, stahuji závislosti přes setup.sh..."
    ./setup.sh --deps-only
    break
  fi
done
[[ -x bin/ffmpeg && -x bin/cloudflared ]] || die 'Po setupu chybí spustitelné binárky.'
[[ "$(uname -m)" == x86_64 ]] || die 'Stažené binárky jsou určeny pro Linux x86_64.'
bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libx264' || die 'FFmpeg neobsahuje encoder libx264.'

rm -f stream/hls/*.ts stream/hls/*.m3u8
STARTUP_OK=0
cleanup_on_error() {
  rc=$?
  if (( rc != 0 )) && (( STARTUP_OK == 0 )); then
    log 'Start se nezdařil; uklízím spuštěné procesy.'
    ./stop.sh >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_error EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "Spouštím FFmpeg z $VIDEO_DEVICE ($VIDEO_SIZE @ ${FRAMERATE}fps)..."
bin/ffmpeg -hide_banner -loglevel warning \
  -fflags nobuffer \
  -f v4l2 -framerate "$FRAMERATE" -video_size "$VIDEO_SIZE" -i "$VIDEO_DEVICE" \
  -an -c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -pix_fmt yuv420p \
  -x264-params 'rc-lookahead=0:sync-lookahead=0:bframes=0:scenecut=0' \
  -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
  -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BUFSIZE" \
  -force_key_frames "expr:gte(t,n_forced*$HLS_TIME)" \
  -f hls -hls_time "$HLS_TIME" -hls_list_size "$HLS_LIST_SIZE" \
  -hls_flags delete_segments+append_list+omit_endlist+independent_segments+program_date_time \
  -flush_packets 1 -hls_segment_filename 'stream/hls/seg_%05d.ts' stream/hls/index.m3u8 \
  >>logs/ffmpeg.log 2>&1 &
echo "$!" > run/ffmpeg.pid

log "Spouštím HLS server na 127.0.0.1:$PORT..."
python3 stream/hls_server.py --dir stream/hls --host 127.0.0.1 --port "$PORT" \
  >>logs/server.log 2>&1 &
echo "$!" > run/server.pid

log 'Čekám na playlist, segment a health endpoint...'
READY=0
for ((i=0; i<SEGMENT_WAIT; i++)); do
  if ! kill -0 "$(cat run/ffmpeg.pid)" 2>/dev/null; then
    break
  fi
  if curl --silent --show-error --fail --max-time 2 "http://127.0.0.1:$PORT/health" -o /dev/null 2>/dev/null \
      && [[ -s stream/hls/index.m3u8 ]] \
      && grep -Eq '^seg_[0-9]{5}\.ts$' <(sed -n 's|.*/||p' stream/hls/index.m3u8) \
      && compgen -G 'stream/hls/seg_*.ts' >/dev/null; then
    READY=1
    break
  fi
  sleep 1
done
if (( READY == 0 )); then
  tail -n 30 logs/ffmpeg.log >&2 || true
  tail -n 20 logs/server.log >&2 || true
  die 'HLS stream nebyl včas připraven.'
fi

log 'Spouštím Cloudflare Quick Tunnel...'
: > logs/tunnel.log
bin/cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate \
  >logs/tunnel.log 2>&1 &
echo "$!" > run/tunnel.pid
URL=''
for ((i=0; i<TUNNEL_WAIT; i++)); do
  URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' logs/tunnel.log | head -n 1 || true)"
  [[ -n "$URL" ]] && break
  kill -0 "$(cat run/tunnel.pid)" 2>/dev/null || break
  sleep 1
done
[[ "$URL" =~ ^https://[a-z0-9-]+\.trycloudflare\.com$ ]] || {
  tail -n 30 logs/tunnel.log >&2 || true
  die 'Cloudflare tunnel nevydal platnou Quick Tunnel URL.'
}

log "Ověřuji veřejný health endpoint ($URL/health)..."
PUBLIC_OK=0
for ((i=0; i<PUBLIC_WAIT; i+=2)); do
  if curl --silent --show-error --fail --max-time 5 "$URL/health" -o /dev/null 2>/dev/null; then
    PUBLIC_OK=1
    break
  fi
  kill -0 "$(cat run/tunnel.pid)" 2>/dev/null || break
  sleep 2
done
(( PUBLIC_OK == 1 )) || die 'Veřejný tunel neprošel health checkem; URL nezveřejňuji.'

# Write atomically: a page never sees a truncated JSON file.
python3 - "$PAGES_DIR/stream.json" "$URL" <<'PY'
import datetime
import json
import os
import sys
import tempfile

path, url = sys.argv[1:]
parent = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(prefix='.stream.json.', dir=parent, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump({'url': url, 'updated': datetime.datetime.now(datetime.timezone.utc).isoformat()}, stream)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY

# Never commit over another user's staged work.
if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git diff --cached --quiet; then
    log 'Pozor: Git index obsahuje staged změny; stream.json je uložen lokálně, ale publish přeskočen.'
  elif ! git diff --quiet -- "$PAGES_DIR/stream.json"; then
    git add -- "$PAGES_DIR/stream.json"
    git commit -m 'stream: update live URL' -- "$PAGES_DIR/stream.json" >/dev/null
    if git push "$REMOTE" "HEAD:$GIT_BRANCH"; then
      log 'Stream URL publikována na GitHub Pages.'
    else
      log 'VAROVÁNÍ: push selhal; URL zůstala pouze lokálně.'
    fi
  else
    log 'Stream URL se nezměnila; nový Pages build není potřeba.'
  fi
fi

STARTUP_OK=1
trap - EXIT INT TERM
printf '\nStream běží. Veřejná URL: %s\nGitHub Pages: https://simonbalog.github.io/launch/\nZastavení: ./stop.sh\nLogy: logs/\n' "$URL"
