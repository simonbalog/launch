<https://simonbalog.github.io/launch/>

# Cassiopeia I — Mellotech

Launch stránka pro první start nosné rakety **Cassiopeia I** týmu **Mellotech**
(21. 11. 2026, 14:00–14:15 CET; okno se může kvůli počasí mírně posunout)
s živým přenosem z kamery.

Projekt vezme obraz z webkamery tohoto počítače, zabalí ho do HLS a vystaví
přes Cloudflare Quick Tunnel. GitHub Pages hostí pouze stránku s přehrávačem.
VPS ani veřejná IP nejsou potřeba.

## Jak to funguje

```
kamera (/dev/video0)
      │  ffmpeg (H.264 + HLS)
      ▼
stream/hls/  ──►  loopback HTTP server (:8080)
                         │
                         ▼
               cloudflared Quick Tunnel ──► https://<nahodne>.trycloudflare.com
                         │
                         ▼
GitHub Pages (docs/index.html) ──► hls.js player
```

`run.sh` spustí FFmpeg, lokální server a tunel. Veřejnou URL ověří přes `/health`
a až poté atomicky zapíše do `docs/stream.json`. Pokud se URL změnila a Git index
neobsahuje cizí staged změny, skript provede cílený commit a push pouze tohoto
souboru. `stop.sh` ukončí pouze procesy odpovídající očekávaným binárkám a zkusí
publikovat offline stav.

## Požadavky

- Linux x86_64 a čitelná kamera (výchozí `/dev/video0`)
- `python3`, `git`, `curl`, `tar`, `flock` (obvykle `util-linux`)
- GitHub oprávnění push pro repozitář, pokud se má URL automaticky publikovat

`setup.sh` stáhne statické FFmpeg a `cloudflared` do `bin/`. Stahování používá
TLS, retry, kontrolu struktury/binarity a atomickou instalaci. Jde stále o
binárky stažené od upstream vydavatelů bez lokálně ověřeného checksumu — pro
produkční provoz připni verzi a ověř publikované kontrolní součty.

## První nastavení

```bash
./setup.sh
```

Skript omezuje staging na soubory projektu a nahrává je na nakonfigurovanou větev.
GitHub Pages zapni v **Settings → Pages → Deploy from a branch** a vyber větev
`main` a adresář `/docs` (nebo odpovídající nastavení repozitáře).

> `config.env` je načítán jako Bash skript. Upravuj ho jen tehdy, když mu důvěřuješ;
> nevkládej do něj obsah z nedůvěryhodných zdrojů.

## Spuštění a zastavení

```bash
./run.sh
./stop.sh
```

Logy jsou v `logs/ffmpeg.log`, `logs/server.log` a `logs/tunnel.log`. Procesy
jsou evidovány v `run/*.pid`; dočasné playlisty a segmenty v `stream/hls/`.

Základní testy HLS serveru lze spustit bez dalších Python balíčků:

```bash
python3 -m unittest discover -s stream -p 'test_*.py' -v
```

## Landing page a odpočet

Obsah stránky je v `docs/index.html`, loga v `docs/assets/`. Odpočet se řídí
konstantou `LAUNCH_DATE`:

```js
const LAUNCH_DATE = new Date('2026-11-21T14:00:00+01:00');
```

Cílem odpočtu je začátek startovního okna (14:00 CET).

Zobrazuje se postupně včetně sekund:
`T-06d 01h 08m 42s` → `T-01h 08m 42s` → `T-08m 42s` → `T-42s`.

### Mapa rampy

`docs/rampa.html` zobrazuje satelitní pohled na místo rampy
(49°12'21.4"N 15°46'16.0"E, tj. 49.205949, 15.771099) a odkazy do Google Maps.
Na hlavní stránku je napojený
v navigaci jako „Rampa“ a v liště přehrávače jako „Mapa rampy“.

## Konfigurace

Uprav `config.env`:

| Proměnná | Výchozí | Význam |
| --- | --- | --- |
| `VIDEO_DEVICE` | `/dev/video0` | kamera |
| `VIDEO_SIZE` | `1280x720` | rozlišení |
| `FRAMERATE` | `30` | FPS |
| `GOP` | `18` | interval keyframů (odpovídá `HLS_TIME`) |
| `BITRATE` | `1500k` | datový tok videa |
| `BUFSIZE` | `3000k` | encoder buffer |
| `HLS_TIME` | `0.6` | délka segmentu v sekundách |
| `HLS_LIST_SIZE` | `6` | počet segmentů v playlistu (min. 2) |
| `PORT` | `8080` | lokální port HLS serveru |
| `GIT_BRANCH` | `main` | větev pro publikování |
| `PAGES_DIR` | `docs` | adresář GitHub Pages |
| `REMOTE` | `origin` | Git remote |
| `SEGMENT_WAIT` | `30` | čekání na lokální HLS, sekundy |
| `TUNNEL_WAIT` | `60` | čekání na URL tunelu, sekundy |
| `PUBLIC_WAIT` | `90` | čekání na veřejný health check, sekundy |

## Bezpečnost a provozní omezení

- **Stream je veřejný.** Každý, kdo získá URL tunelu, může sledovat video. Quick Tunnel není přístupová kontrola. Nesdílej odkaz, pokud stream nemá být veřejný; pro soukromý přenos použij autentizovaný relay/Access vrstvu nebo jinou službu s řízeným přístupem.
- Lokální HTTP server odmítá bind mimo loopback a zpřístupňuje jen playlist, očekávané HLS segmenty a `/health`. CORS je otevřené, protože veřejná GitHub Pages stránka načítá stream z jiné domény.
- URL z `trycloudflare.com` je náhodná při každém spuštění. Pro stálou adresu použij Cloudflare Named Tunnel a vlastní doménu.
- HLS + tunnel přidává přibližně 1–3 sekundy zpoždění. GitHub Pages může po změně `stream.json` potřebovat desítky sekund na rebuild.
- Drž `HLS_TIME` alespoň `0.6` (a `GOP` na `FRAMERATE * HLS_TIME`). Kratší segmenty způsobí `#EXT-X-TARGETDURATION:0`, který někteří HLS přehrávače odmítnou.
- `stop.sh` smaže lokální HLS segmenty a pokusí se vymazat publikovanou URL. Pokud push selže, stará URL zůstane na stránce, ale její tunnel je ukončen.

## Řešení problémů

- **Kamera nejde otevřít** – ověř `ls -l /dev/video0`, `VIDEO_DEVICE` a práva uživatele.
- **Prázdný/rozbitý obraz** – zkontroluj `logs/ffmpeg.log`, rozlišení a formát kamery.
- **Stránka nic nepřehrává** – ověř `docs/stream.json`, `<url>/health` a `<url>/index.m3u8`.
- **Tunel se nespustí** – zkontroluj `logs/tunnel.log`; může pomoci jiná síť nebo protokol `http2`.
- **Procesy zůstaly běžet** – `./stop.sh` kontroluje binárku a skript procesu před odesláním signálu; cizí nebo znovu použité PID neukončí.
