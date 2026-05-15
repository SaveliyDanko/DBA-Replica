#!/usr/bin/env bash
# Этап 2.2 / 2.3.
# Симуляция программной ошибки на основном узле (pkill -9 postgres)
# и демонстрация автоматического failover через pgpool.
# NB: при сбое часть docker exec в pg-a ожидаемо падают,
# поэтому errexit отключён.
set -uo pipefail
cd "$(dirname "$0")/.."

bar() { printf '\n--- %s ---\n' "$*"; }
PGPOOL_URI='host=pgpool port=9999 user=postgres password=postgres dbname=labdb'

bar "До сбоя: SHOW POOL_NODES"
docker exec pg-client psql "$PGPOOL_URI" -c "SHOW POOL_NODES;"

bar "До сбоя: вставляем маркерную запись через pgpool"
docker exec pg-client psql "$PGPOOL_URI" -c \
  "INSERT INTO orders (customer_id, product, quantity, amount, status)
     VALUES (1, 'before-failure', 1, 42.00, 'pre-failure') RETURNING id, product, created_at;"

bar "СИМУЛЯЦИЯ СБОЯ: pkill -9 postgres на pg-a"
docker exec pg-a bash -c "pkill -9 postgres || true"
echo "pkill отправлен. Postgres-процессы на pg-a:"
docker exec pg-a bash -c "ps -ef | grep -E 'postgres' | grep -v grep || echo '(нет процессов postgres)'"

# Контейнер pg-a по умолчанию остановится, потому что postgres был PID 1.
# Это OK - имитирует мёртвый узел.

bar "Ждём, пока pgpool обнаружит сбой и выполнит failover (до 60с)"
for i in $(seq 1 30); do
    sleep 2
    if docker exec pg-client psql "$PGPOOL_URI" -tAc \
         "SELECT 1" >/dev/null 2>&1; then
        if docker exec pg-b psql -U postgres -tAc "SELECT NOT pg_is_in_recovery();" 2>/dev/null | grep -q 't'; then
            echo "[OK] pg-b промоутирован в primary (попытка $i)."
            break
        fi
    fi
    echo "  попытка $i: ждём..."
done

bar "Логи failover pgpool (последние строки)"
docker exec pgpool tail -n 50 /var/log/pgpool/failover.log 2>/dev/null || echo "(лог пока пуст)"

bar "Логи pgpool с релевантными сообщениями"
docker logs pgpool 2>&1 | grep -E "(failover|degenerate|promote|find_primary|DOWN|primary)" | tail -n 30 || true

bar "Логи pg-a (последние ошибки перед смертью)"
docker logs pg-a 2>&1 | tail -n 30 || true

bar "Состояние после failover: SHOW POOL_NODES"
docker exec pg-client psql "$PGPOOL_URI" -c "SHOW POOL_NODES;" || true

bar "pg-b в роли primary?"
docker exec pg-b psql -U postgres -tAc "SELECT pg_is_in_recovery();"

bar "Состояние репликации на новом primary (pg-b)"
docker exec pg-b psql -U postgres -c \
  "SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication;"
