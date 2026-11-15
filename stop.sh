#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

STOPPED=0
for name in tunnel server ffmpeg; do
  f="run/$name.pid"
  [ -f "$f" ] || continue
  pid="$(cat "$f" 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null || true
    STOPPED=1
  fi
  rm -f "$f"
done

rm -f stream/hls/*.ts stream/hls/*.m3u8 2>/dev/null || true

if [ "$STOPPED" = 1 ]; then
  echo "Stream zastaven."
else
  echo "Nic neběželo."
fi
