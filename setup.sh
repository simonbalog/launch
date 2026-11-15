#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DEPS_ONLY=0
case "${1:-}" in
  --deps-only) DEPS_ONLY=1 ;;
esac

mkdir -p bin docs stream logs run

if [ ! -x bin/ffmpeg ] || [ ! -x bin/ffprobe ]; then
  echo "Stahuji statický ffmpeg..."
  TMP="$(mktemp -d)"
  curl -fSL -o "$TMP/ffmpeg.tar.xz" \
    "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
  tar -xf "$TMP/ffmpeg.tar.xz" -C "$TMP"
  cp "$TMP"/ffmpeg-*-static/ffmpeg "$TMP"/ffmpeg-*-static/ffprobe bin/
  chmod +x bin/ffmpeg bin/ffprobe
  rm -rf "$TMP"
  echo "ffmpeg nainstalován do bin/."
fi

if [ ! -x bin/cloudflared ]; then
  echo "Stahuji cloudflared..."
  curl -fSL -o bin/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  chmod +x bin/cloudflared
  echo "cloudflared nainstalován do bin/."
fi

chmod +x run.sh stop.sh setup.sh

if [ "$DEPS_ONLY" = 1 ]; then
  exit 0
fi

DEVICE="${VIDEO_DEVICE:-/dev/video0}"
if [ ! -e "$DEVICE" ]; then
  echo "Pozor: kamera $DEVICE neexistuje. Uprav VIDEO_DEVICE v config.env." >&2
else
  echo "Kamera nalezena: $DEVICE"
fi

if [ ! -f docs/stream.json ]; then
  printf '{\n  "url": "",\n  "updated": ""\n}\n' > docs/stream.json
fi

if [ ! -d .git ]; then
  git init -b main
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "https://github.com/simonbalog/launch.git"
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "Camera live stream via GitHub Pages and Cloudflare tunnel"
fi

echo "Nahrávám do GitHubu..."
git push -u origin main

TOKEN=""
CRED="$(GIT_TERMINAL_PROMPT=0 timeout 10 bash -c "printf 'protocol=https\nhost=github.com\n\n' | git credential fill" 2>/dev/null || true)"
if [ -n "$CRED" ]; then
  TOKEN="$(printf '%s\n' "$CRED" | sed -n 's/^password=//p' | head -1)"
fi

PAGES_API="https://api.github.com/repos/simonbalog/launch/pages"
if [ -n "$TOKEN" ]; then
  BODY='{"source":{"branch":"main","path":"/docs"}}'
  RESP="$(mktemp)"
  CODE="$(curl -s -o "$RESP" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$PAGES_API" || echo 000)"

  if [ "$CODE" = "200" ]; then
    CODE="$(curl -s -o "$RESP" -w '%{http_code}' -X PATCH \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$BODY" "$PAGES_API" || echo 000)"
  elif [ "$CODE" = "404" ]; then
    CODE="$(curl -s -o "$RESP" -w '%{http_code}' -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$BODY" "$PAGES_API" || echo 000)"
  fi

  case "$CODE" in
    200|201|204)
      echo "GitHub Pages povoleny (main /docs)."
      ;;
    403|404)
      echo "GitHub Pages nejde zapnout automaticky (token bez opravnění pages:write)."
      echo "Zapni je ručně: Settings > Pages > Deploy from a branch > main /docs."
      ;;
    *)
      echo "GitHub Pages API vrátilo HTTP $CODE. Zkontroluj Settings > Pages."
      ;;
  esac
  rm -f "$RESP"
else
  echo "Token pro GitHub nebyl nalezen. Zapni Pages ručně: Settings > Pages > main /docs."
fi

echo
echo "Hotovo."
echo "  Pages: https://simonbalog.github.io/launch/ (první build trvá ~1 min)"
echo "  Start: ./run.sh"
echo "  Stop:  ./stop.sh"
