#!/usr/bin/env bash
# Adatkönyvtárak létrehozása a befűzött meghajtón.
# Az install.sh hívja, de önállóan is futtatható.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

MEDIA_ROOT="${MEDIA_ROOT:-/home/bali/media}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

printf 'Adatgyökér: %s\n' "$MEDIA_ROOT"

mkdir -p \
  "$MEDIA_ROOT/appdata/sonarr" \
  "$MEDIA_ROOT/appdata/radarr" \
  "$MEDIA_ROOT/appdata/prowlarr" \
  "$MEDIA_ROOT/appdata/qbittorrent" \
  "$MEDIA_ROOT/appdata/jellyfin" \
  "$MEDIA_ROOT/media/Movies" \
  "$MEDIA_ROOT/media/TV Shows" \
  "$MEDIA_ROOT/torrents/completed" \
  "$MEDIA_ROOT/torrents/incomplete" \
  "$MEDIA_ROOT/immich/library" \
  "$MEDIA_ROOT/immich/postgres" \
  "$MEDIA_ROOT/immich/model-cache"

chown -R "$PUID:$PGID" \
  "$MEDIA_ROOT/appdata" \
  "$MEDIA_ROOT/media" \
  "$MEDIA_ROOT/torrents" \
  "$MEDIA_ROOT/immich"

printf 'Könyvtárak készen állnak (tulajdonos %s:%s).\n' "$PUID" "$PGID"
