#!/usr/bin/env bash
# ============================================================
# stream_at_home — idempotent installer for Debian / Ubuntu / Mint
#
# Usage:
#   ./install.sh                        # sudo prompts on the terminal
#   SUDO_PASS=... ./install.sh          # non-interactive (SSH, cloud-init)
#   MEDIA_ROOT=/mnt/media ./install.sh  # custom data root
#
# The installer detects the invoking user and writes that user's
# UID/GID into .env, so it is not tied to UID 1000 or to a fixed
# account name. The sudo password is never written to disk, .env,
# logs or git.
# ============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# MEDIA_ROOT=/path ./install.sh — overrides the value from .env / the template.
REQUESTED_MEDIA_ROOT="${MEDIA_ROOT:-}"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m!\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------
# 1. Target user — whoever invoked the installer
# ------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  # sudo ./install.sh keeps the caller in SUDO_UID/SUDO_GID.
  if [ -n "${SUDO_UID:-}" ] && [ "${SUDO_UID:-0}" -ne 0 ]; then
    TARGET_UID="$SUDO_UID"
    TARGET_GID="${SUDO_GID:-$(id -g "$SUDO_UID" 2>/dev/null || echo "$SUDO_UID")}"
    TARGET_USER="${SUDO_USER:-uid-${TARGET_UID}}"
  else
    # Plain root (su -, root shell): use the owner of the checkout.
    REPO_OWNER_UID="$(stat -c '%u' "$REPO_DIR" 2>/dev/null || echo 0)"
    REPO_OWNER_GID="$(stat -c '%g' "$REPO_DIR" 2>/dev/null || echo 0)"
    if [ "$REPO_OWNER_UID" -ne 0 ]; then
      TARGET_UID="$REPO_OWNER_UID"
      TARGET_GID="$REPO_OWNER_GID"
      TARGET_USER="$(id -un "$TARGET_UID" 2>/dev/null || echo "uid-${TARGET_UID}")"
    else
      TARGET_UID=0
      TARGET_GID=0
      TARGET_USER=root
    fi
  fi
else
  TARGET_UID="$(id -u)"
  TARGET_GID="$(id -g)"
  TARGET_USER="$(id -un 2>/dev/null || echo "uid-${TARGET_UID}")"
fi

# Remember whether the target user has a passwd entry (needed for usermod).
if getent passwd "$TARGET_USER" >/dev/null 2>&1; then
  HAS_PASSWD_ENTRY=1
else
  HAS_PASSWD_ENTRY=0
fi

if [ "$TARGET_UID" -eq 0 ]; then
  warn "Running as root: the stack will write files as root. A normal user with sudo is recommended."
fi

log "User: ${TARGET_USER} (UID:GID ${TARGET_UID}:${TARGET_GID})"

# ------------------------------------------------------------
# 2. sudo (or direct execution when already root)
# ------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  sudo_cmd() { "$@"; }
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required (or run the installer as root)."
  if [ -n "${SUDO_PASS:-}" ]; then
    # Without a tty sudo cannot cache the password, so pass it per call.
    sudo_cmd() { printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"; }
  else
    sudo -v || die "sudo privileges are required to install Docker."
    sudo_cmd() { sudo "$@"; }
  fi
fi

# ------------------------------------------------------------
# 3. Operating system + Docker repository family
# ------------------------------------------------------------
[ -r /etc/os-release ] || die "Cannot read /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release

case " ${ID:-} ${ID_LIKE:-} " in
  *debian*|*ubuntu*) ;;
  *) die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. Debian, Ubuntu or Linux Mint is required." ;;
esac

case "${ID:-}" in
  debian)
    DOCKER_REPO="debian"
    CODENAME="${VERSION_CODENAME:-}"
    ;;
  *)
    DOCKER_REPO="ubuntu"
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    ;;
esac

[ -n "$CODENAME" ] || die "Cannot determine the release codename (VERSION_CODENAME / UBUNTU_CODENAME)."
log "System: ${PRETTY_NAME:-$ID} (Docker repo: ${DOCKER_REPO}/${CODENAME})"

APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=120)
apt_update()  { sudo_cmd env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -qq -o DPkg::Lock::Timeout=120; }
apt_install() { sudo_cmd env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "${APT_OPTS[@]}" install "$@"; }

# ------------------------------------------------------------
# 4. Docker CE + Compose plugin (installed when missing)
# ------------------------------------------------------------
DOCKER_READY=0
if command -v docker >/dev/null 2>&1 && sudo_cmd docker compose version >/dev/null 2>&1; then
  DOCKER_READY=1
fi

BASE_PKGS=()
command -v curl >/dev/null 2>&1 || BASE_PKGS+=(curl)
command -v gpg >/dev/null 2>&1 || BASE_PKGS+=(gnupg)
command -v openssl >/dev/null 2>&1 || BASE_PKGS+=(openssl)
[ -f /etc/ssl/certs/ca-certificates.crt ] || BASE_PKGS+=(ca-certificates)

if [ "$DOCKER_READY" -eq 0 ]; then
  log "Installing Docker CE + Compose plugin..."
  apt_update
  apt_install ca-certificates curl gnupg openssl

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  curl -fsSL --retry 3 "https://download.docker.com/linux/${DOCKER_REPO}/gpg" -o "$TMP_DIR/docker.asc"
  sudo_cmd install -m 0755 -d /etc/apt/keyrings
  sudo_cmd install -m 0644 "$TMP_DIR/docker.asc" /etc/apt/keyrings/docker.asc

  ARCH="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$ARCH" "$DOCKER_REPO" "$CODENAME" > "$TMP_DIR/docker.list"
  sudo_cmd install -m 0644 "$TMP_DIR/docker.list" /etc/apt/sources.list.d/docker.list

  apt_update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  log "Docker is already installed: $(sudo_cmd docker --version)"
  if [ "${#BASE_PKGS[@]}" -gt 0 ]; then
    log "Installing missing base packages: ${BASE_PKGS[*]}"
    apt_update
    apt_install "${BASE_PKGS[@]}"
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  sudo_cmd systemctl enable --now docker >/dev/null 2>&1 || warn "Could not enable/start the Docker service automatically."
fi

sudo_cmd docker compose version >/dev/null 2>&1 \
  || die "Docker Compose is not available after installation."

# Add the invoking user to the docker group (takes effect in a new session).
ADDED_TO_DOCKER=0
if [ "$TARGET_UID" -ne 0 ] && [ "$HAS_PASSWD_ENTRY" -eq 1 ] && getent group docker >/dev/null 2>&1; then
  if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    sudo_cmd usermod -aG docker "$TARGET_USER"
    ADDED_TO_DOCKER=1
  fi
fi

# ------------------------------------------------------------
# 5. .env — generated once, with the detected user and timezone
# ------------------------------------------------------------
detect_timezone() {
  local tz=""
  if command -v timedatectl >/dev/null 2>&1; then
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
  if [ -z "$tz" ] && [ -r /etc/timezone ]; then
    tz="$(head -n 1 /etc/timezone | tr -d '[:space:]')"
  fi
  printf '%s' "${tz:-UTC}"
}

if [ ! -f .env ]; then
  [ -f .env.example ] || die ".env.example is missing from ${REPO_DIR}."
  [ -w "$REPO_DIR" ] || die "Cannot write .env in ${REPO_DIR}. Clone the repository as ${TARGET_USER} or fix the permissions."
  cp .env.example .env
  DB_PASS="$(openssl rand -hex 24)"
  TZ_VALUE="$(detect_timezone)"
  sed -i \
    -e "s|^PUID=.*|PUID=${TARGET_UID}|" \
    -e "s|^PGID=.*|PGID=${TARGET_GID}|" \
    -e "s|^TZ=.*|TZ=${TZ_VALUE}|" \
    -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" \
    .env
  unset DB_PASS
  log ".env created (PUID:PGID ${TARGET_UID}:${TARGET_GID}, TZ ${TZ_VALUE}, random DB_PASSWORD)"
else
  log ".env already exists — keeping it"
fi

if [ -f .env ] && [ ! -w .env ] && [ "$(id -u)" -ne 0 ]; then
  die "Cannot write .env (owned by $(stat -c '%U' .env)). Run the installer as that user or with sudo."
fi

if [ -n "$REQUESTED_MEDIA_ROOT" ]; then
  sed -i "s|^MEDIA_ROOT=.*|MEDIA_ROOT=${REQUESTED_MEDIA_ROOT}|" .env
  log "MEDIA_ROOT overridden: ${REQUESTED_MEDIA_ROOT}"
fi

chmod 600 .env
[ -r .env ] || die ".env is not readable by the current process."
# If the installer ran through sudo, hand .env back to the target user.
if [ "$(id -u)" -eq 0 ] && [ "$TARGET_UID" -ne 0 ]; then
  chown "$TARGET_UID:$TARGET_GID" .env
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${MEDIA_ROOT:?MEDIA_ROOT is not set in .env}"
[[ "$PUID" =~ ^[0-9]+$ ]] || die "PUID in .env is not numeric: $PUID"
[[ "$PGID" =~ ^[0-9]+$ ]] || die "PGID in .env is not numeric: $PGID"

if [ "$PUID" != "$TARGET_UID" ] || [ "$PGID" != "$TARGET_GID" ]; then
  die "Existing .env is configured for PUID:PGID ${PUID}:${PGID}, but ${TARGET_USER} is ${TARGET_UID}:${TARGET_GID}. Run the installer as the data owner, delete .env to regenerate it for this user, or edit PUID/PGID in .env."
fi

# ------------------------------------------------------------
# 6. Data root and directory tree
# ------------------------------------------------------------
if [ ! -d "$MEDIA_ROOT" ]; then
  log "Creating data root: $MEDIA_ROOT"
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$MEDIA_ROOT"
  else
    mkdir -p "$MEDIA_ROOT" || die "Cannot create ${MEDIA_ROOT}. Create it manually or use MEDIA_ROOT=/path."
  fi
fi

if [ "$(id -u)" -eq 0 ]; then
  # Keep the data root writable for the target UID, even on re-runs.
  chown "$TARGET_UID:$TARGET_GID" "$MEDIA_ROOT"
  chmod 2775 "$MEDIA_ROOT" || warn "Could not set group-writable permissions on ${MEDIA_ROOT}."
elif [ ! -w "$MEDIA_ROOT" ]; then
  die "$MEDIA_ROOT exists but is not writable by $(id -un). Fix it with: sudo chown -R ${TARGET_UID}:${TARGET_GID} ${MEDIA_ROOT}"
fi

log "Preparing data directories..."
MEDIA_ROOT="$MEDIA_ROOT" PUID="$TARGET_UID" PGID="$TARGET_GID" bash "$REPO_DIR/setup-folders.sh"

# ------------------------------------------------------------
# 7. Pull and start
# ------------------------------------------------------------
log "Pulling pinned images..."
sudo_cmd docker compose pull

log "Starting the stack..."
sudo_cmd docker compose up -d --remove-orphans

# ------------------------------------------------------------
# 8. Wait for the HTTP endpoints
# ------------------------------------------------------------
log "Waiting for the services (this can take a few minutes)..."
command -v curl >/dev/null 2>&1 || die "curl is required to wait for the services."

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
  printf '  FAIL %-14s http://127.0.0.1:%s%s (last code: %s)\n' \
    "$name" "$port" "$path" "${code:-no response}"
  return 1
}

FAILED=0
wait_http 8989  /ping                     Sonarr        || FAILED=1
wait_http 7878  /ping                     Radarr        || FAILED=1
wait_http 9696  /ping                     Prowlarr      || FAILED=1
wait_http 8080  /                         qBittorrent   || FAILED=1
wait_http 8096  /health                   Jellyfin      || FAILED=1
wait_http 2283  /ping                     Immich        || FAILED=1

# ------------------------------------------------------------
# 9. Summary
# ------------------------------------------------------------
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -z "$HOST_IP" ] && command -v ip >/dev/null 2>&1; then
  HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
fi
[ -n "$HOST_IP" ] || HOST_IP="<host-ip>"

log "Containers:"
sudo_cmd docker compose ps

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '\033[1;32mInstallation complete.\033[0m\n'
else
  printf '\033[1;33mThe stack is running, but some endpoints did not answer yet.\033[0m\n'
  printf 'Check the logs with: sudo docker compose logs --tail=100 <service>\n'
fi

if [ "$ADDED_TO_DOCKER" -eq 1 ]; then
  printf 'Note: %s was added to the docker group; log out and back in to use docker without sudo.\n' "$TARGET_USER"
fi

cat <<EOF

LAN addresses:
  Sonarr       http://${HOST_IP}:8989
  Radarr       http://${HOST_IP}:7878
  Prowlarr     http://${HOST_IP}:9696
  qBittorrent  http://${HOST_IP}:8080
  Jellyfin     http://${HOST_IP}:8096
  Immich       http://${HOST_IP}:2283

Data:          ${MEDIA_ROOT}
Owner:         ${TARGET_USER} (${TARGET_UID}:${TARGET_GID})
Config:        ${REPO_DIR}/.env (chmod 600, gitignored)

First steps:
  1. Sonarr/Radarr: Settings > General > copy the API key
  2. Prowlarr: add indexers, then Settings > Apps and add Sonarr/Radarr
     using container URLs: http://sonarr:8989 and http://radarr:7878
  3. qBittorrent: change the default admin/admin password immediately!
     Download path: /torrents/completed, incomplete: /torrents/incomplete
  4. Sonarr/Radarr download client: qbittorrent:8080,
     paths /data/torrents/completed and /data/torrents/incomplete
  5. Jellyfin: add libraries /data/media/Movies and /data/media/TV Shows
  6. Immich: create the admin account at http://${HOST_IP}:2283

Update:        edit the image tag@digest in docker-compose.yml, then
               docker compose pull && docker compose up -d
Backup:        see the "Backup" section of README.md
EOF
