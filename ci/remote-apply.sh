#!/usr/bin/env bash
# Выкат на Arch (идемпотентен): .env → compose up --build -d → ждём бота.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[36m== %s\033[0m\n' "$*"; }

if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        chmod 600 .env
    fi
    log ".env не заполнен: впишите TELEGRAM_TOKEN и TELEGRAM_ACCESS_ID в $ROOT/.env"
    exit 1
fi

token_ok() {
    grep -q '^TELEGRAM_TOKEN=.\+' .env && ! grep -q '^TELEGRAM_TOKEN=$' .env
}
if ! token_ok; then
    log "TELEGRAM_TOKEN пуст в .env — выкат отменён"
    exit 1
fi

docker info >/dev/null 2>&1 || { log "docker недоступен"; exit 1; }

COMPOSE="docker compose"
$COMPOSE version >/dev/null 2>&1 || COMPOSE="docker-compose"

FILES="-f docker-compose.yml"
[ -f docker-compose.prod.yml ] && FILES="$FILES -f docker-compose.prod.yml"

# бэкап БД перед выкатом (не фатален)
mkdir -p backups
if $COMPOSE ps --status running 2>/dev/null | grep -q db; then
    log "бэкап БД"
    $COMPOSE exec -T db pg_dump -U moon -d sky 2>/dev/null | gzip > "backups/sky_$(date +%Y%m%d_%H%M%S).sql.gz" || log "бэкап не удался (не критично)"
fi

mkdir -p data
log "compose up --build -d"
$COMPOSE $FILES up --build -d --remove-orphans

log "жду контейнер бота (до ~5 мин: сборка + бутстрап Tor)"
ok=0
for i in $(seq 1 60); do
    if $COMPOSE ps --format '{{.Name}} {{.State}}' 2>/dev/null | grep -q 'moonobsrv-bot.*running\|bot-1.*running'; then
        ok=1
        break
    fi
    sleep 5
done
$COMPOSE $FILES ps
if [ "$ok" != 1 ]; then
    log "бот не поднялся; последние логи:"
    $COMPOSE logs --tail 40 bot || true
    exit 1
fi
log "готово. Живой срез: /monitor в Telegram"
