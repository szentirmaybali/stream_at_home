#!/usr/bin/env bash
# ============================================================
# stream_at_home — idempotent telepítő Linux Mint 21/22-re
#
# Használat:
#   ./install.sh                       # interaktív sudo
#   SUDO_PASS=... ./install.sh         # nem interaktív (pl. SSH)
#
# A jelszó NEM kerül se a repo-ba, se a .env-be, se logba.
# ============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m!\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[1;31mHIBA:\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------
# 1. Sudo / jogosultságok
# ------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  sudo_cmd() { "$@"; }
else
  command -v sudo >/dev/null 2>&1 || die "A sudo nincs telepítve."
  if [ -n "${SUDO_PASS:-}" ]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' -v >/dev/null 2>&1 \
      || die "A megadott SUDO_PASS érvénytelen."
    unset SUDO_PASS
  else
    sudo -v || die "Sudo jogosultság szükséges a Docker telepítéséhez."
  fi
  sudo_cmd() { sudo "$@"; }
fi

# ------------------------------------------------------------
# 2. Rendszer ellenőrzése
# ------------------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release
case "${ID_LIKE:-}" in
  *ubuntu*|*debian*) ;;
  *) die "Ez a telepítő Ubuntu/Debian alapú rendszerre való (jelenleg: ${ID:-ismeretlen})." ;;
esac
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
log "Rendszer: ${PRETTY_NAME:-$ID} (Docker repo: $CODENAME)"

# ------------------------------------------------------------
# 3. Docker CE + Compose plugin
# ------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && sudo_cmd docker compose version >/dev/null 2>&1; then
  log "Docker és Compose plugin már telepítve: $(sudo_cmd docker --version)"
else
  log "Docker CE telepítése ($CODENAME)..."
  sudo_cmd apt-get update -qq
  sudo_cmd apt-get install -y -qq ca-certificates curl gnupg
  sudo_cmd install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo_cmd tee /etc/apt/keyrings/docker.asc >/dev/null
  sudo_cmd chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$CODENAME" \
    | sudo_cmd tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo_cmd apt-get update -qq
  sudo_cmd apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  log "Docker kész: $(sudo_cmd docker --version)"
fi

if ! id -nG "$(id -un)" | grep -qw docker; then
  sudo_cmd usermod -aG docker "$(id -un)"
  warn "A felhasználó fel lett véve a docker csoportba."
  warn "A következő terminálban érvényesül (vagy: newgrp docker)."
fi

# ------------------------------------------------------------
# 4. .env — titok generálása, csak ha még nincs
# ------------------------------------------------------------
if [ ! -f .env ]; then
  cp .env.example .env
  DB_PASS="$(openssl rand -hex 24)"
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
  unset DB_PASS
  log ".env létrehozva, DB_PASSWORD véletlenszerűen generálva"
else
  log ".env már létezik — nem módosítom"
fi
chmod 600 .env

set -a
# shellcheck disable=SC1091
. ./.env
set +a
: "${MEDIA_ROOT:?A MEDIA_ROOT nincs beállítva a .env-ben}"

# ------------------------------------------------------------
# 5. Könyvtárak a befűzött meghajtón
# ------------------------------------------------------------
log "Adatkönyvtárak előkészítése..."
bash "$REPO_DIR/setup-folders.sh"

# ------------------------------------------------------------
# 6. Indítás
# ------------------------------------------------------------
log "Image-ek letöltése (pinelt digestek)..."
sudo_cmd docker compose pull

log "Stack indítása..."
sudo_cmd docker compose up -d --remove-orphans

# ------------------------------------------------------------
# 7. Várakozás a HTTP végpontokra
# ------------------------------------------------------------
log "Várakozás a szolgáltatásokra (ez eltarthat egy-két percig)..."

wait_http() {
  local port="$1" path="$2" name="$3" code="" i
  for i in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
      "http://127.0.0.1:${port}${path}" 2>/dev/null || true)"
    case "$code" in
      200|301|302|303|401|403)
        printf '  OK   %-14s http://127.0.0.1:%s%s\n' "$name" "$port" "$path"
        return 0
        ;;
    esac
    sleep 2
  done
  printf '  FAIL %-14s http://127.0.0.1:%s%s (utolsó kód: %s)\n' \
    "$name" "$port" "$path" "${code:-nincs válasz}"
  return 1
}

FAILED=0
wait_http 8989  /ping                     Sonarr        || FAILED=1
wait_http 7878  /ping                     Radarr        || FAILED=1
wait_http 9696  /ping                     Prowlarr      || FAILED=1
wait_http 8080  /                         qBittorrent   || FAILED=1
wait_http 8096  /health                   Jellyfin      || FAILED=1
wait_http 2283  /api/server-info/ping     Immich        || FAILED=1

# ------------------------------------------------------------
# 8. Összefoglaló
# ------------------------------------------------------------
VM_IP="$(hostname -I | awk '{print $1}')"

log "Konténerek:"
sudo_cmd docker compose ps

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '\033[1;32mTelepítés kész.\033[0m\n'
else
  printf '\033[1;33mA telepítés fut, de egyes végpontok még nem válaszolnak.\033[0m\n'
  printf 'Logok: sudo docker compose logs --tail=100 <szerviz>\n'
fi

cat <<EOF

Elérhetőségek (LAN):
  Sonarr       http://${VM_IP}:8989
  Radarr       http://${VM_IP}:7878
  Prowlarr     http://${VM_IP}:9696
  qBittorrent  http://${VM_IP}:8080
  Jellyfin     http://${VM_IP}:8096
  Immich       http://${VM_IP}:2283

Adatok:        ${MEDIA_ROOT}
Konfig:        ${REPO_DIR}/.env (chmod 600, gitignored)

Első lépések:
  1. Sonarr/Radarr: Settings > General > API Key
  2. Prowlarr: indexerek > Settings > Apps > Sonarr/Radarr sync
  3. qBittorrent: alapértelmezett admin/admin jelszó CSERÉLJE KI!
     Letöltési útvonal: /torrents/completed
  4. Jellyfin: könyvtárak hozzáadása /data/media/Movies és /data/media/TV Shows
  5. Immich: admin fiók létrehozása a http://${VM_IP}:2283 oldalon

Frissítés:     szeresd az image sort, majd docker compose pull && docker compose up -d
Mentés:        lásd a README.md „Mentés” szakaszát
EOF
