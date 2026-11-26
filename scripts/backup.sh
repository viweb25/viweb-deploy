#!/usr/bin/env bash
# Dump the database to backups/db-<UTC time>.dump and delete dumps older than
# BACKUP_KEEP_DAYS (default 14). Runs nightly from cron and before every deploy.
#
# Restore into a running stack (this REPLACES current data):
#   docker compose --env-file versions.env --env-file .env exec -T postgres \
#     pg_restore --clean --if-exists -U "$POSTGRES_USER" -d "$POSTGRES_DB" < backups/<file>.dump
#
# These dumps sit on the same disk as the database. Copy them off the server too
# (see docs in README.md, "Backups").
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1091
source ./versions.env
# shellcheck disable=SC1091
source ./.env
set +a

mkdir -p backups
file="backups/db-$(date -u +%Y%m%d-%H%M%S).dump"
docker compose --env-file versions.env --env-file .env exec -T postgres \
  pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB" > "$file.partial"
mv "$file.partial" "$file"
chmod 600 "$file"
find backups -name 'db-*.dump' -mtime "+${BACKUP_KEEP_DAYS:-14}" -delete
echo "Backup written: $file ($(du -h "$file" | cut -f1))"
