#!/usr/bin/env bash
# Deploy the versions in versions.env. Runs on the server, normally from GitHub Actions:
#   ssh deploy@server /opt/viweb/scripts/deploy.sh
# Safe to run again: Compose only replaces containers whose image or settings changed.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

if [[ ! -f .env ]]; then
  echo "Missing $ROOT/.env. Copy .env.example and fill it in first." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source ./versions.env
# shellcheck disable=SC1091
source ./.env
set +a

compose() { docker compose --env-file versions.env --env-file .env "$@"; }

echo "==> Deploying frontend=$FRONTEND_TAG api=$API_TAG db=$DB_TAG inference=$INFERENCE_TAG"
mkdir -p models backups

echo "==> Pulling images"
compose pull --quiet

if compose ps --status running --services 2>/dev/null | grep -qx postgres; then
  echo "==> Backing up the database before migrations"
  "$ROOT/scripts/backup.sh"
fi

echo "==> Starting (migrations run first; the API waits for them)"
if ! compose up -d --remove-orphans --wait --wait-timeout 300; then
  echo "!! Deploy failed. Recent logs:" >&2
  compose ps -a >&2
  compose logs --tail 60 migrate api inference >&2
  exit 1
fi

echo "==> Checking https://$DOMAIN/health/live"
for attempt in $(seq 1 30); do
  if curl -fsS --max-time 5 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/health/live" >/dev/null; then
    break
  fi
  if [[ $attempt == 30 ]]; then
    echo "!! The site did not answer over HTTPS. Check: docker compose logs web" >&2
    exit 1
  fi
  sleep 2
done

echo "$(date -u +%FT%TZ) frontend=$FRONTEND_TAG api=$API_TAG db=$DB_TAG inference=$INFERENCE_TAG" \
  >> deployments.log
docker image prune -f --filter "until=168h" >/dev/null
echo "==> Deployed."
