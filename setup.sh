#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
umask 077

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'CHYBA: %s\n' "$*" >&2; exit 1; }

DEPS_ONLY=0
case "${1:-}" in
  '') ;;
  --deps-only) DEPS_ONLY=1 ;;
  *) die "Neznámý argument: $1 (použijte --deps-only)" ;;
esac

[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die 'Setup podporuje pouze Linux x86_64.'
for command in curl tar git python3; do
  command -v "$command" >/dev/null 2>&1 || die "Chybí příkaz: $command"
done

if [[ -f config.env ]]; then
  # shellcheck disable=SC1091
  source config.env
fi
: "${VIDEO_DEVICE:=/dev/video0}"
: "${GIT_BRANCH:=main}"
: "${REMOTE:=origin}"

mkdir -p bin docs stream logs run
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

if [[ ! -x bin/ffmpeg || ! -x bin/ffprobe ]]; then
  log 'Stahuji statický FFmpeg...'
  curl --fail --location --show-error --silent --retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
    -o "$TMP/ffmpeg.tar.xz" 'https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz'
  tar -xJf "$TMP/ffmpeg.tar.xz" -C "$TMP"
  mapfile -t FFMPEG_DIRS < <(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'ffmpeg-*-static' -print)
  (( ${#FFMPEG_DIRS[@]} == 1 )) || die 'Stažený FFmpeg archiv nemá očekávanou strukturu.'
  [[ -x "${FFMPEG_DIRS[0]}/ffmpeg" && -x "${FFMPEG_DIRS[0]}/ffprobe" ]] || die 'V archivu chybí ffmpeg nebo ffprobe.'
  install -m 0755 "${FFMPEG_DIRS[0]}/ffmpeg" "$TMP/ffmpeg"
  install -m 0755 "${FFMPEG_DIRS[0]}/ffprobe" "$TMP/ffprobe"
  mv -f "$TMP/ffmpeg" bin/ffmpeg
  mv -f "$TMP/ffprobe" bin/ffprobe
  bin/ffmpeg -version >/dev/null
  log 'FFmpeg nainstalován.'
fi

if [[ ! -x bin/cloudflared ]]; then
  log 'Stahuji cloudflared...'
  curl --fail --location --show-error --silent --retry 3 --retry-all-errors --connect-timeout 15 --max-time 180 \
    -o "$TMP/cloudflared" 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64'
  [[ -s "$TMP/cloudflared" ]] || die 'Stažený cloudflared je prázdný.'
  install -m 0755 "$TMP/cloudflared" "$TMP/cloudflared-ready"
  "$TMP/cloudflared-ready" --version >/dev/null
  mv -f "$TMP/cloudflared-ready" bin/cloudflared
  log 'cloudflared nainstalován.'
fi

chmod +x run.sh stop.sh setup.sh
if (( DEPS_ONLY )); then
  log 'Závislosti jsou připravené.'
  exit 0
fi

if [[ ! -e "$VIDEO_DEVICE" ]]; then
  log "VAROVÁNÍ: kamera $VIDEO_DEVICE neexistuje; nastavte VIDEO_DEVICE v config.env."
elif [[ ! -r "$VIDEO_DEVICE" ]]; then
  die "Kamera $VIDEO_DEVICE není čitelná uživatelem $(id -un)."
else
  log "Kamera nalezena: $VIDEO_DEVICE"
fi

[[ "$GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die 'GIT_BRANCH obsahuje nepovolené znaky.'
[[ "$REMOTE" =~ ^[A-Za-z0-9._-]+$ ]] || die 'REMOTE obsahuje nepovolené znaky.'
if [[ ! -d .git ]]; then
  git init -b "$GIT_BRANCH"
fi
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  if [[ "$REMOTE" != origin ]]; then die "Git remote $REMOTE neexistuje."; fi
  git remote add origin 'https://github.com/simonbalog/launch.git'
fi
if ! git diff --cached --quiet; then
  die 'Git index obsahuje staged změny; nejprve je commitněte nebo odstageujte.'
fi

# Stage only project files; never add downloaded binaries, PID files, logs,
# camera captures, or arbitrary untracked files from the checkout.
git add -A -- .gitignore README.md config.env run.sh setup.sh stop.sh stream docs
if ! git diff --cached --quiet; then
  git commit -m 'Camera live stream via GitHub Pages and Cloudflare tunnel'
fi
log "Pushuji větev $GIT_BRANCH na remote $REMOTE..."
git push -u "$REMOTE" "HEAD:$GIT_BRANCH"

cat <<EOF

Hotovo.
  GitHub Pages zapněte v Settings → Pages → Deploy from a branch → $GIT_BRANCH /docs.
  Pages: https://simonbalog.github.io/launch/
  Start: ./run.sh
  Stop:  ./stop.sh
EOF
