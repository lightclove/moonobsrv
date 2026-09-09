#!/usr/bin/env bash
# Бэкап Postgres стека moonobsrv в backups/ (gzip).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p backups
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="backups/sky_${STAMP}.sql.gz"
docker compose exec -T db pg_dump -U moon -d sky | gzip > "$OUT"
echo "готово: $OUT ($(du -h "$OUT" | cut -f1))"
