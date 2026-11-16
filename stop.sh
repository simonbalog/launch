#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
umask 077

stopped=0
process_matches() {
  local name="$1" pid="$2" exe args
  [[ -r "/proc/$pid/cmdline" && -e "/proc/$pid/exe" ]] || return 1
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  args="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$name" in
    ffmpeg) [[ "$exe" == "$ROOT/bin/ffmpeg" ]] ;;
    tunnel) [[ "$exe" == "$ROOT/bin/cloudflared" && "$args" == *' tunnel --url http://127.0.0.1:'* ]] ;;
    server) [[ "$args" == *"$ROOT/stream/hls_server.py"* || "$args" == *'stream/hls_server.py'* ]] ;;
    *) return 1 ;;
  esac
}

for name in tunnel server ffmpeg; do
  file="run/$name.pid"
  [[ -f "$file" ]] || continue
  pid="$(cat "$file" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && process_matches "$name" "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..50}; do
      process_matches "$name" "$pid" || break
      sleep 0.1
    done
    if process_matches "$name" "$pid"; then
      printf 'Proces %s (PID %s) nereagoval na TERM; posílám KILL.\n' "$name" "$pid" >&2
      kill -KILL "$pid" 2>/dev/null || true
    fi
    stopped=1
  elif [[ -n "$pid" ]]; then
    printf 'Neukončuji PID %s z %s: proces již neběží nebo neodpovídá očekávané aplikaci.\n' "$pid" "$file" >&2
  fi
  rm -f -- "$file"
done

rm -f stream/hls/*.ts stream/hls/*.m3u8 2>/dev/null || true

# Best-effort removal of the now-dead public URL, avoiding interference with a
# user's existing staged changes. Failure does not prevent local shutdown.
if [[ -f docs/stream.json ]] && command -v python3 >/dev/null 2>&1; then
  tmp="$(mktemp docs/.stream.json.XXXXXX)"
  printf '{\n  "url": "",\n  "updated": "%s"\n}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
  mv -f "$tmp" docs/stream.json
  if git rev-parse --git-dir >/dev/null 2>&1 && git diff --cached --quiet; then
    if ! git diff --quiet -- docs/stream.json; then
      git add -- docs/stream.json
      git commit -m 'stream: clear live URL' -- docs/stream.json >/dev/null 2>&1 || true
      git push "${REMOTE:-origin}" "HEAD:${GIT_BRANCH:-main}" >/dev/null 2>&1 || \
        printf 'VAROVÁNÍ: stream je zastaven, ale offline stav se nepodařilo pushnout.\n' >&2
    fi
  fi
fi

if (( stopped )); then
  printf 'Stream zastaven.\n'
else
  printf 'Žádný odpovídající stream proces neběžel.\n'
fi
