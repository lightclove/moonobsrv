#!/usr/bin/env bash
# Состояние прода на Arch: compose ps + хвост логов бота.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
COMPOSE="docker compose"
$COMPOSE version >/dev/null 2>&1 || COMPOSE="docker-compose"
FILES="-f docker-compose.yml"
[ -f docker-compose.prod.yml ] && FILES="$FILES -f docker-compose.prod.yml"
$COMPOSE $FILES ps
echo '--- последние логи бота ---'
$COMPOSE logs --tail 20 bot || true
