#!/usr/bin/env bash
# Этап "Восстановление". Возвращаем кластер в исходную конфигурацию:
#   A = primary, B = sync replica, C = async replica.
#
# Алгоритм:
#   1) Полностью убираем старый pg-a (его data устарела).
#   2) Поднимаем pg-a как обычный standby pg-b (текущего primary).
#   3) Ждём, пока pg-a догонит pg-b.
#   4) Контролируемое переключение pg-b -> pg-a:
#        - чисто гасим pg-b
#        - на pg-a выполняем pg_promote()
#        - возвращаем synchronous_standby_names = 'pg-b-sync'
#   5) Пересоздаём pg-b и pg-c с чистыми data, они подцепятся к pg-a.
#   6) Перезапускаем pgpool, чтобы он переоценил топологию.
set -euo pipefail
cd "$(dirname "$0")/.."

bar() { printf '\n=== %s ===\n' "$*"; }

# -----------------------------------------------------------
bar "0. Определяем имена docker-volume"
VOL_A=$(docker volume ls --format '{{.Name}}' | grep -E '_pg-a-data$' | head -n1 || true)
VOL_B=$(docker volume ls --format '{{.Name}}' | grep -E '_pg-b-data$' | head -n1 || true)
VOL_C=$(docker volume ls --format '{{.Name}}' | grep -E '_pg-c-data$' | head -n1 || true)
echo "  VOL_A=$VOL_A"
echo "  VOL_B=$VOL_B"
echo "  VOL_C=$VOL_C"
[ -z "$VOL_A$VOL_B$VOL_C" ] && { echo "Не нашли volumes, прерываю."; exit 1; }

wipe_volume() {
    local vol="$1"
    [ -z "$vol" ] && return 0
    # используем уже скачанный postgres:16, чтобы не тянуть alpine
    docker run --rm --entrypoint /bin/sh -v "${vol}:/data" postgres:16 \
        -c 'rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true'
}

# -----------------------------------------------------------
bar "1. Останавливаем и удаляем pg-a, стираем его data"
docker compose stop pg-a >/dev/null 2>&1 || true
docker compose rm -f pg-a >/dev/null 2>&1 || true
wipe_volume "$VOL_A"

bar "2. Запускаем pg-a как standby текущего primary (pg-b)"
docker compose -f docker-compose.yml -f docker-compose.recover.yml \
    up -d --no-deps --force-recreate pg-a

bar "3. Ждём pg-a -> standby и подключения к pg-b"
for i in $(seq 1 60); do
    if docker exec pg-a pg_isready -U postgres >/dev/null 2>&1 \
       && docker exec pg-a psql -U postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q 't' \
       && docker exec pg-b psql -U postgres -tAc \
            "SELECT count(*) FROM pg_stat_replication WHERE application_name='pg-a-recover';" 2>/dev/null \
            | grep -q '^1$'; then
        echo "  pg-a поднят и реплицируется с pg-b (через $((i*2))с)."
        break
    fi
    sleep 2
done

bar "4. Ждём, пока LSN pg-a сравняется с pg-b"
for i in $(seq 1 60); do
    PRIMARY_LSN=$(docker exec pg-b psql -U postgres -tAc "SELECT pg_current_wal_lsn()::text;" 2>/dev/null || echo "")
    REPLAY_LSN=$(docker exec pg-a psql -U postgres -tAc "SELECT pg_last_wal_replay_lsn()::text;" 2>/dev/null || echo "")
    echo "  pg-b LSN=$PRIMARY_LSN, pg-a replay_LSN=$REPLAY_LSN"
    if [ -n "$PRIMARY_LSN" ] && [ "$PRIMARY_LSN" = "$REPLAY_LSN" ]; then
        echo "  pg-a догнал pg-b."
        break
    fi
    sleep 1
done

bar "5. Контролируемое переключение pg-b -> pg-a"
echo "5.1 Чистое завершение pg-b (pg_ctl stop -m fast)..."
docker exec pg-b su postgres -c "pg_ctl -D /var/lib/postgresql/data -w -t 30 -m fast stop" || true

echo "5.2 Промоутим pg-a..."
docker exec pg-a psql -U postgres -d postgres -c "SELECT pg_promote(true, 60);"

echo "5.3 Восстанавливаем synchronous_standby_names='pg-b-sync' на pg-a..."
docker exec pg-a psql -U postgres -c "ALTER SYSTEM SET synchronous_standby_names = '\"pg-b-sync\"';"
docker exec pg-a psql -U postgres -c "SELECT pg_reload_conf();"

echo "5.4 Возвращаем pg-a в исходный env (NODE_ROLE=primary)..."
docker compose stop pg-a >/dev/null
docker compose up -d --no-deps pg-a
for i in $(seq 1 30); do
    if docker exec pg-a pg_isready -U postgres >/dev/null 2>&1 \
       && docker exec pg-a psql -U postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q 'f'; then
        echo "  pg-a снова primary."
        break
    fi
    sleep 1
done

# -----------------------------------------------------------
bar "6. Пересоздаём pg-b как sync-standby pg-a"
docker compose stop pg-b >/dev/null 2>&1 || true
docker compose rm -f pg-b >/dev/null 2>&1 || true
wipe_volume "$VOL_B"
docker compose up -d --no-deps --force-recreate pg-b

bar "7. Пересоздаём pg-c как async-standby pg-a"
docker compose stop pg-c >/dev/null 2>&1 || true
docker compose rm -f pg-c >/dev/null 2>&1 || true
wipe_volume "$VOL_C"
docker compose up -d --no-deps --force-recreate pg-c

bar "8. Полностью пересоздаём pgpool (чтобы он забыл failover-статус)"
# pgpool хранит pgpool_status в /var/log/pgpool/pgpool_status и при рестарте
# принимает оттуда роли узлов. После failover он запомнил pg-a=DOWN.
# rm контейнера убирает и его tmpfs, и при следующем запуске статус собирается
# с нуля.
docker compose stop pgpool >/dev/null 2>&1 || true
docker compose rm -f pgpool >/dev/null 2>&1 || true
docker compose up -d --no-deps --force-recreate pgpool

echo "Ждём 10с, пока всё догонит/инициализируется..."
sleep 10

bar "Финальное состояние:"
docker exec pg-a psql -U postgres -tAc "SELECT 'A in_recovery? ' || pg_is_in_recovery()::text;"
docker exec pg-b psql -U postgres -tAc "SELECT 'B in_recovery? ' || pg_is_in_recovery()::text;" || true
docker exec pg-c psql -U postgres -tAc "SELECT 'C in_recovery? ' || pg_is_in_recovery()::text;" || true

docker exec pg-a psql -U postgres -c \
  "SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication ORDER BY application_name;"

docker exec pg-client \
  psql "host=pgpool port=9999 user=postgres password=postgres dbname=postgres" \
  -c "SHOW POOL_NODES;" || true
