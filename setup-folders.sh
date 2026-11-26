#!/usr/bin/env bash
# Create the data tree under MEDIA_ROOT.
# Called by install.sh, but safe to run standalone as well.
set -euo pipefail
umask 002

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

# Fall back to the invoking user; when run via sudo, use the caller.
if [ -z "${PUID:-}" ] || [ -z "${PGID:-}" ]; then
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_UID:-}" ] && [ "${SUDO_UID:-0}" -ne 0 ]; then
    PUID="${PUID:-$SUDO_UID}"
    PGID="${PGID:-${SUDO_GID:-$SUDO_UID}}"
  else
    PUID="${PUID:-$(id -u)}"
    PGID="${PGID:-$(id -g)}"
  fi
fi

MEDIA_ROOT="${MEDIA_ROOT:-/srv/stream-at-home}"

printf 'Data root: %s (owner %s:%s)\n' "$MEDIA_ROOT" "$PUID" "$PGID"

if [ "$(id -u)" -ne 0 ]; then
  if [ "$(id -u)" -ne "$PUID" ] || [ "$(id -g)" -ne "$PGID" ]; then
    printf 'ERROR: PUID:PGID %s:%s does not match the current user (%s:%s).\n' \
      "$PUID" "$PGID" "$(id -u)" "$(id -g)" >&2
    printf 'Run this script with sudo, or set PUID/PGID to the current user.\n' >&2
    exit 1
  fi
fi

if [ ! -d "$MEDIA_ROOT" ]; then
  mkdir -p "$MEDIA_ROOT"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$PUID:$PGID" "$MEDIA_ROOT"
    chmod 2775 "$MEDIA_ROOT"
  fi
fi

# Create only missing directories, already with the target ownership.
# Existing directories are left untouched so running containers keep theirs
# (for example the Immich Postgres data directory owned by the postgres user).
create_dir() {
  local dir="$1"
  [ -d "$dir" ] && return 0
  if [ "$(id -u)" -eq 0 ]; then
    install -d -m 2775 -o "$PUID" -g "$PGID" "$dir"
  else
    mkdir -p "$dir"
  fi
}

create_dir "$MEDIA_ROOT/appdata"
create_dir "$MEDIA_ROOT/appdata/sonarr"
create_dir "$MEDIA_ROOT/appdata/radarr"
create_dir "$MEDIA_ROOT/appdata/prowlarr"
create_dir "$MEDIA_ROOT/appdata/qbittorrent"
create_dir "$MEDIA_ROOT/appdata/jellyfin"
create_dir "$MEDIA_ROOT/media"
create_dir "$MEDIA_ROOT/media/Movies"
create_dir "$MEDIA_ROOT/media/TV Shows"
create_dir "$MEDIA_ROOT/torrents"
create_dir "$MEDIA_ROOT/torrents/completed"
create_dir "$MEDIA_ROOT/torrents/incomplete"
create_dir "$MEDIA_ROOT/immich"
create_dir "$MEDIA_ROOT/immich/library"
create_dir "$MEDIA_ROOT/immich/postgres"
create_dir "$MEDIA_ROOT/immich/model-cache"

# Only the four top-level directories are adjusted. A recursive chown is
# deliberately avoided: containers write their own files as PUID:PGID, and
# databases (Immich Postgres) manage their own permissions.
if [ "$(id -u)" -eq 0 ]; then
  chown "$PUID:$PGID" \
    "$MEDIA_ROOT/appdata" \
    "$MEDIA_ROOT/media" \
    "$MEDIA_ROOT/torrents" \
    "$MEDIA_ROOT/immich"
  chmod 2775 \
    "$MEDIA_ROOT/appdata" \
    "$MEDIA_ROOT/media" \
    "$MEDIA_ROOT/torrents" \
    "$MEDIA_ROOT/immich"
fi

printf 'Directories are ready.\n'
