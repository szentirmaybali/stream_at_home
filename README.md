# stream_at_home

Kis, **csak LAN-on elérhető** streaming stack Linux Mint VM-en: Sonarr, Radarr,
Prowlarr, qBittorrent, Jellyfin és Immich. Nincs Cloudflare Tunnel, nincs
Tailscale, nincs reverse proxy — minden közvetlenül a VM IP-jén hallgat.

Az adatok a `/home/bali/media` könyvtárba befűzött külön meghajtón vannak
(ugyanaz a szerepe, mint a fő host `/data` könyvtárának). A repository **csak**
a Compose fájlt, a telepítőt és ezt a dokumentációt tartalmazza — titkok,
konfigok és médiák nem kerülnek gitbe.

## Tartalom

| Szolgáltatás | Port | Szerep |
|---|---:|---|
| Sonarr | 8989 | Sorozatok kezelése |
| Radarr | 7878 | Filmek kezelése |
| Prowlarr | 9696 | Indexerek kezelése, Sonarr/Radarr felé szinkron |
| qBittorrent | 8080 | Letöltő (6881 TCP+UDP a torrent forgalomhoz) |
| Jellyfin | 8096 | Streaming |
| Immich | 2283 | Fotók és videók |

Minden image **tag + digest** párosra van rögzítve a
`docker-compose.yml`-ben. A verziók 2026-11-23-as legújabb stabil kiadások:

- Sonarr `4.0.20.3014-ls6`, Radarr `7.0.3.10918-ls328`,
  Prowlarr `3.0.2.5780-ls169`, qBittorrent `5.3.0_v2.1.2-ls488`,
  Jellyfin `12.4ubu2604-ls60`
- Immich `v3.4.2` (+ machine-learning, Postgres 14, Valkey 9)

## Telepítés

Előfeltétel: Linux Mint 21/22 (Ubuntu/Debian alap), x86_64, kb. 4 GB RAM,
a meghajtó `/home/bali/media`-re csatolva, sudo jog.

```bash
git clone https://github.com/szentirmaybali/stream_at_home.git
cd stream_at_home
chmod +x install.sh setup-folders.sh
./install.sh
```

A telepítő idempotens:

1. ellenőrzi a rendszert, és szükség esetén feltelepíti a Docker CE-t +
   Compose plugint a hivatalos Ubuntu repo-ból (Mint 22 → `noble`),
2. felveszi a felhasználót a `docker` csoportba,
3. létrehozza a `.env`-t az `.env.example` alapján, és **véletlenszerű
   `DB_PASSWORD`-t generál**, majd `chmod 600`-t állít be,
4. létrehozza az adatkönyvtárakat a meghajtón (`setup-folders.sh`),
5. letölti a pinelt image-eket, elindítja a stacket,
6. megvárja, hogy mind a hat HTTP végpont válaszoljon, majd kiírja az URL-eket.

Nem interaktív (pl. SSH-s) futtatáshoz:

```bash
SUDO_PASS=jelszo ./install.sh
```

A `SUDO_PASS` csak a sudo hitelesítésre szolgál, nem kerül fájlba, logba vagy
commitba. Interaktív terminálban egyszerűen `./install.sh` — a sudo maga kér
jelszót.

## Adatok

```text
/home/bali/media/
├── appdata/
│   ├── sonarr/
│   ├── radarr/
│   ├── prowlarr/
│   ├── qbittorrent/
│   └── jellyfin/
├── media/
│   ├── Movies/
│   └── TV Shows/
├── torrents/
│   ├── completed/
│   └── incomplete/
└── immich/
    ├── library/        # feltöltött fotók
    ├── postgres/       # Immich adatbázis
    └── model-cache/    # ML modellek
```

A konténerek ezt a gyökeret `/data` néven látják (Sonarr/Radarr),
illetve `/data/media` (Jellyfin), `/torrents` (qBittorrent) és `/data`
(Immich) néven.

## Első beállítás

1. **Sonarr / Radarr** — `Settings > General`, kimásolod az API kulcsot.
2. **Prowlarr** — felveszed az indexereket, majd `Settings > Apps` menüben
   hozzáadod a Sonarrt és a Radarrt az API kulcsukkal. A szinkron után az
   indexerek a két `*arr`-ben is megjelennek.
3. **qBittorrent** — az alapértelmezett `admin` / `admin` jelszót **azonnal
   cseréld ki**! A letöltési útvonal legyen `/torrents/completed`, a részleges
   letöltéseké `/torrents/incomplete`. A Sonarr/Radarr ennek megfelelően
   `/data/torrents/completed` útvonalat használjon.
4. **Jellyfin** — könyvtárak: `/data/media/Movies` (Filmek) és
   `/data/media/TV Shows` (Sorozatok).
5. **Immich** — első indításkor admin fiók létrehozása a `2283`-as porton.

## Ismert probléma — Prowlarr 3.x és a BitHUmen

A Prowlarr `3.0.2` hibásan értelmezi a BitHUmen **hibrid torrent** kiadásait
(a „sima” és a hibrid release-ek összevont parse-ja miatt). Ha ilyen találatnál
hibát látsz, két lehetőség:

- használd a fő stackben bevált `2.7.0`-t vagy `2.6.5`-öt: szerkeszd a
  `prowlarr` `image:` sorát `lscr.io/linuxserver/prowlarr:2.7.0`-ra, majd
  `docker compose pull && docker compose up -d prowlarr`;
- vagy kerüld a hibrid kiadásokat az indexer szintjén.

A fő `arrstack` ezért fut továbbra is `2.6.5`-ön. Az nCore letöltéseket ez a
probléma nem érinti.

## Frissítés

A digestek miatt a `latest` nem frissít magától. A frissítés szándékos:

```bash
# 1. szerkeszd az image sort (új tag + új digest)
docker buildx imagetools inspect lscr.io/linuxserver/sonarr:4.0.20.3014-ls6
# 2. alkalmazás
docker compose pull
docker compose up -d
```

## Mentés

A konfigok és az adatbázisok a meghajtón vannak, a `.env` pedig a repo mellett:

```bash
# megállítás (adatbázis konzisztencia miatt)
docker compose down

# mentés
tar czf backups/stream-$(date +%F).tar.gz \
  /home/bali/media/appdata /home/bali/media/immich /home/bali/media/media
cp .env backups/

# visszaállítás
docker compose up -d
```

A `backups/` és a `.env` gitignored. A `DB_PASSWORD` elvesztése esetén az
Immich adatbázisa nem olvasható — a `.env`-t külön, biztonságos helyen is
őrizd meg.

## Biztonság

- A stack **csak LAN-on** hallgat; nincs Cloudflare, nincs nyilvános domain.
- A `6881` port TCP+UDP nyitva van a VM-en a torrent forgalomhoz. Ha nem
  kell WAN-elérés, a routeren ne forwardold, illetve a Compose-ban töröld a
  két `6881` sorát.
- Ha később mégis publikussá tennéd valamelyik UI-t, **előbb** tegyél elé
  hitelesítést (Cloudflare Access, Authelia stb.) — ezek az alkalmazások
  alapból nem alkalmasak közvetlen internetre.

## Hibakeresés

```bash
docker compose ps                          # állapot
docker compose logs --tail=100 sonarr      # egy szerviz logja
docker compose logs -f immich-server       # élő log
docker compose restart qbittorrent
sudo ss -tulpn | grep -E '8989|7878|9696|8080|8096|2283'
df -h /home/bali/media                     # meghajtó fogyása
```

Ha a `docker compose` parancs „permission denied”: `newgrp docker`, vagy
jelentkezz ki és vissza a VM-re (a csoporttagság csak új sessionben él).
