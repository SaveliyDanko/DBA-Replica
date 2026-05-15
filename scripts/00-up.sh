#!/usr/bin/env bash
# Этап 0. Поднять кластер с нуля.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== [00] Очистка предыдущих ресурсов ==="
docker compose down -v --remove-orphans 2>/dev/null || true

echo "=== [00] Сборка образов (skip если уже собраны) ==="
need_build=0
for img in rshd-lab3-postgres:latest rshd-lab3-pgpool:latest; do
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        need_build=1
    fi
done
if [ "$need_build" = "1" ]; then
    docker compose build
else
    echo "  образы уже есть, пропускаем"
fi

echo "=== [00] Запуск сервисов ==="
docker compose up -d

echo "=== [00] Ждём health для всех узлов ==="
for c in pg-a pg-b pg-c; do
    for i in $(seq 1 60); do
        status=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo "starting")
        if [ "$status" = "healthy" ]; then
            echo "  $c: healthy"
            break
        fi
        sleep 2
    done
done

echo "=== [00] Ждём pgpool (порт 9999) ==="
for i in $(seq 1 30); do
    if docker exec pg-client pg_isready -h pgpool -p 9999 -U postgres >/dev/null 2>&1; then
        echo "  pgpool: ready"
        break
    fi
    sleep 2
done

echo "=== [00] Готово. Запустите дальнейшие скрипты по порядку 01..07 ==="
