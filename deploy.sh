#!/usr/bin/env bash
# Деплой / первичный запуск продакшн-стенда
# Запускать с самого сервера 192.168.2.122 из директории репозитория

set -euo pipefail

cd "$(dirname "$0")"

# --- проверки до любых действий ---

if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker не установлен. См. README.md → установка."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "❌ Docker Compose v2 не найден. См. README.md → установка."
    exit 1
fi

if [ ! -f .env ]; then
    echo "❌ .env не найден. Скопируй .env.example в .env и заполни."
    echo "   cp .env.example .env && \${EDITOR:-nano} .env"
    exit 1
fi

# --- подгружаем .env чтобы убедиться, что всё задано ---

set -a
# shellcheck disable=SC1091
source .env
set +a

: "${GHCR_OWNER:?не задан в .env}"
: "${DB_PASSWORD:?не задан в .env}"
: "${API_TOKEN:?не задан в .env}"
: "${MAX_BOT_TOKEN:?не задан в .env}"

if [ "$DB_PASSWORD" = "CHANGE_ME" ] || [ "$API_TOKEN" = "CHANGE_ME" ] || [ "$MAX_BOT_TOKEN" = "CHANGE_ME" ]; then
    echo "❌ В .env остались значения CHANGE_ME. Подставь реальные секреты."
    exit 1
fi

# --- логин в GHCR (если образы приватные) ---

if [ -n "${GHCR_TOKEN:-}" ] && [ -n "${GHCR_USER:-}" ]; then
    echo "→ Логин в ghcr.io..."
    echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
fi

# --- собственно деплой ---

echo "→ Пулл новых образов..."
docker compose pull

echo "→ Запуск/перезапуск сервисов..."
docker compose up -d

echo "→ Очистка образов без тегов..."
docker image prune -f >/dev/null

# --- health check ---

echo "→ Проверка health..."
sleep 5
for i in {1..6}; do
    if curl -fsS http://localhost:8080/api/health >/dev/null 2>&1; then
        echo "  ✓ api-gateway отвечает"
        break
    fi
    if [ "$i" = "6" ]; then
        echo "  ✗ api-gateway не отвечает после 30 сек"
        docker compose logs api-gateway --tail=50
        exit 1
    fi
    sleep 5
done

# проверка, что бот не упал и тоже в running
if [ "$(docker inspect -f '{{.State.Status}}' medkvadrat-max-bot 2>/dev/null)" != "running" ]; then
    echo "  ✗ max-bot не в состоянии running"
    docker compose logs max-bot --tail=50
    exit 1
fi
echo "  ✓ max-bot в running"

echo ""
echo "✓ Деплой завершён"
echo ""
docker compose ps
