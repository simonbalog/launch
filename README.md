# Cassiopeia I — Mellotech

Launch stránka pro první start nosné rakety **Cassiopeia I** týmu **Mellotech**
(21. 11. 2026, 14:00 CET) s živým přenosem z kamery.

Projekt vezme obraz z webkamery tohoto počítače, zabalí ho do HLS a vystaví
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

## Landing page a odpočet

Obsah stránky je v `docs/index.html`, loga v `docs/assets/`. Odpočet startu se
řídí konstantou `LAUNCH_DATE` ve skriptu na konci `index.html`:

```js
const LAUNCH_DATE = new Date('2026-11-21T14:00:00+01:00');
```

Odpočet se zobrazuje postupně: `T-06d 01h 08m` → `T-01h 08m` → `T-08m`.

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
| `GOP` | `15` | keyframe každých N snímků (musí odpovídat `HLS_TIME`) |
| `BITRATE` | `1500k` | datový tok videa |
| `BUFSIZE` | `3000k` | buffer encodéru |
| `HLS_TIME` | `0.5` | délka segmentu (s) |
| `HLS_LIST_SIZE` | `6` | počet segmentů v playlistu |
| `PORT` | `8080` | lokální port HLS serveru |

Nižší zpoždění: sniž `HLS_TIME` (např. `0.5`) a `GOP` na `FRAMERATE/2`.
Nižší zpoždění za cenu vyšší zátěže: `GOP=10`, `HLS_TIME=0.333`, `HLS_LIST_SIZE=4`.
Vyšší kvalita: zvyš `BITRATE` a `VIDEO_SIZE`.

## Omezení

- **GitHub Pages neumí přijímat živý stream.** Proto se používá tunel; Pages
  hostí jen přehrávač.
- URL z `trycloudflare` je **náhodná při každém spuštění**. `run.sh` ji
  automaticky publikuje. Pro stálou adresu použij Cloudflare Named Tunnel
  s vlastní doménou, nebo klasický VPS s MediaMTX.
- Zpoždění je cca **1–3 s** (HLS + tunel). Minimum HLS bez LL-HLS je zhruba
  jedna délka segmentu + buffer přehrávače.
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
