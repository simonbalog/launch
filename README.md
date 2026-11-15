# Launch – živý přenos z kamery na GitHub Pages

Tento projekt vezme obraz z webkamery tohoto počítače, zabalí ho do HLS a vystaví
přes Cloudflare tunel. GitHub Pages slouží jako veřejná stránka s přehrávačem.
Nepotřebuješ VPS ani veřejnou IP.

## Jak to funguje

```
kamera (/dev/video0)
      │  ffmpeg (H.264 + HLS)
      ▼
stream/hls/  ──►  lokální HTTP server (CORS, :8080)
                        │
                        ▼
              cloudflared quick tunnel  ──►  https://<nahodne>.trycloudflare.com
                        │
                        ▼
GitHub Pages (docs/index.html)  ──►  přehrávač hls.js
```

`run.sh` po startu zjistí veřejnou URL tunelu, zapíše ji do `docs/stream.json`
a commitne/pushne na GitHub. Stránka na GitHub Pages si ji načte a přehraje.

## Požadavky

- Linux x86_64, přístup ke kameře (`/dev/video0`)
- `python3`, `git`, `curl`
- Účet na GitHubu s právem push do `simonbalog/launch`

`setup.sh` automaticky stáhne statický `ffmpeg` a `cloudflared` do `bin/`,
takže není potřeba `sudo` ani instalace balíčků.

## První nastavení

```bash
./setup.sh
```

Skript:

1. stáhne `ffmpeg` a `cloudflared` do `bin/`,
2. ověří kameru,
3. založí git repo (pokud není) a nastaví remote,
4. pushne soubory na GitHub,
5. zkusí zapnout GitHub Pages (`main` / `docs`).

Pokud se Pages nezapnou automaticky, udělej to ručně:
**Settings → Pages → Deploy from a branch → main / `docs`**.

Stránka pak běží na `https://simonbalog.github.io/launch/`.

## Spuštění streamu

```bash
./run.sh
```

Výstup obsahuje veřejnou URL streamu a odkaz na GitHub Pages. Stream běží na
pozadí.

## Zastavení

```bash
./stop.sh
```

## Konfigurace

Uprav `config.env`:

| Proměnná | Výchozí | Význam |
| --- | --- | --- |
| `VIDEO_DEVICE` | `/dev/video0` | kamera |
| `VIDEO_SIZE` | `1280x720` | rozlišení |
| `FRAMERATE` | `30` | FPS |
| `BITRATE` | `1500k` | datový tok videa |
| `BUFSIZE` | `3000k` | buffer encodéru |
| `HLS_TIME` | `1` | délka segmentu (s) |
| `HLS_LIST_SIZE` | `4` | počet segmentů v playlistu |
| `PORT` | `8080` | lokální port HLS serveru |

Nižší zpoždění: sniž `HLS_LIST_SIZE` (např. na `3`) a `HLS_TIME` nech `1`.
Vyšší kvalita: zvyš `BITRATE` a `VIDEO_SIZE`.

## Omezení

- **GitHub Pages neumí přijímat živý stream.** Proto se používá tunel; Pages
  hostí jen přehrávač.
- URL z `trycloudflare` je **náhodná při každém spuštění**. `run.sh` ji
  automaticky publikuje. Pro stálou adresu použij Cloudflare Named Tunnel
  s vlastní doménou, nebo klasický VPS s MediaMTX.
- Zpoždění je cca **3–8 s** (HLS + tunel).
- Po startu může trvat **30–90 s**, než GitHub Pages rebuildne a nová URL se
  objeví na stránce.
- Free účet GitHub Pages má soft limit ~10 buildů za hodinu. URL se proto
  publikuje jen při změně.

## Bezpečnost

Po spuštění je obraz z kamery **veřejně dostupný** komukoli, kdo zná URL tunelu.
Nesdílej odkaz, pokud nechceš, aby přenos viděl kdokoli. Zastavením `./stop.sh`
stream okamžitě zmizí (tunel i lokální server se vypnou).

## Řešení problémů

- **Kamera nejde otevřít** – zkontroluj `ls -l /dev/video0` a `VIDEO_DEVICE`.
  Uživatel musí mít právo čtení (ACL nebo skupina `video`).
- **Prázdný/rozbitý obraz** – podívej se do `logs/ffmpeg.log`.
- **Stránka nic nepřehrává** – otevři `docs/stream.json` a zkontroluj `url`.
  Zkus URL ručně: `<url>/health` a `<url>/index.m3u8`.
- **Tunel se nespustí** – viz `logs/tunnel.log`; někdy pomůže jiná síť nebo
  `--protocol http2`.
- **Zaseknutý stav** – `./stop.sh && ./run.sh`.
