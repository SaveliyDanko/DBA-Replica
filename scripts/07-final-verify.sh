#!/usr/bin/env bash
# Финальная проверка после восстановления:
# - Топология вернулась к исходной (A primary, B sync, C async)
# - Все данные на месте, в том числе те, что были записаны после failover
# - Клиенты могут читать и писать
set -euo pipefail
cd "$(dirname "$0")/.."

bar() { printf '\n--- %s ---\n' "$*"; }
PGPOOL_URI='host=pgpool port=9999 user=postgres password=postgres dbname=labdb'

bar "Топология"
docker exec pg-a psql -U postgres -tAc "SELECT 'A: in_recovery=' || pg_is_in_recovery()::text;"
docker exec pg-b psql -U postgres -tAc "SELECT 'B: in_recovery=' || pg_is_in_recovery()::text;"
docker exec pg-c psql -U postgres -tAc "SELECT 'C: in_recovery=' || pg_is_in_recovery()::text;"

bar "pg_stat_replication на A"
docker exec pg-a psql -U postgres -c \
  "SELECT application_name, state, sync_state, replay_lag
     FROM pg_stat_replication ORDER BY application_name;"

bar "pgpool SHOW POOL_NODES"
docker exec pg-client psql "$PGPOOL_URI" -c "SHOW POOL_NODES;"

bar "Контрольные данные (должны включать всё, что добавили после failover)"
for n in pg-a pg-b pg-c; do
    echo "[$n]"
    docker exec "$n" psql -U postgres -d labdb -c \
      "SELECT count(*) AS orders FROM orders;
       SELECT id, product, status FROM orders ORDER BY id DESC LIMIT 5;"
done

bar "Финальная демонстрация R/W через pgpool"
docker exec pg-client psql "$PGPOOL_URI" -c \
  "INSERT INTO orders (customer_id, product, quantity, amount, status)
     VALUES (1, 'after-recovery', 1, 9.99, 'final') RETURNING id, product, created_at;"

docker exec pg-client psql "$PGPOOL_URI" -c \
  "SELECT id, product, status FROM orders WHERE product='after-recovery';"
