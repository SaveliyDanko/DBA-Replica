#!/usr/bin/env bash
# Этап 2.3 (продолжение). После failover клиенты продолжают работать через pgpool:
# демонстрируем чтение и запись, проверяем, что данные дошли до C (нового реплика).
set -euo pipefail
cd "$(dirname "$0")/.."

bar() { printf '\n--- %s ---\n' "$*"; }
PGPOOL_URI='host=pgpool port=9999 user=postgres password=postgres dbname=labdb'

bar "Запись через pgpool после failover (новый primary = pg-b)"
docker exec pg-client psql "$PGPOOL_URI" -c \
  "INSERT INTO orders (customer_id, product, quantity, amount, status)
     SELECT 1, 'after-failover-' || g, 1, 100+g, 'post-failover'
     FROM generate_series(1,5) AS g
     RETURNING id, product;"

bar "Транзакция через pgpool (новый клиент)"
docker exec -i pg-client psql "$PGPOOL_URI" <<'SQL'
BEGIN;
INSERT INTO customers (username, email, full_name) VALUES ('eve', 'eve@example.com', 'Eve Edwards');
INSERT INTO orders (customer_id, product, quantity, amount, status)
  VALUES ((SELECT id FROM customers WHERE username='eve'), 'Camera', 1, 850.00, 'post-failover');
COMMIT;
SQL

bar "Чтение через pgpool: последние заказы"
docker exec pg-client psql "$PGPOOL_URI" -c \
  "SELECT id, customer_id, product, status, created_at FROM orders ORDER BY id DESC LIMIT 8;"

bar "Кол-во записей на узлах (pg-a недоступен)"
docker exec pg-b psql -U postgres -d labdb -tAc "SELECT 'B (new primary)',count(*) FROM orders;" || true
docker exec pg-c psql -U postgres -d labdb -tAc "SELECT 'C (standby)',count(*) FROM orders;" || true

bar "Реплицируется ли pg-c со старого pg-a или уже с pg-b?"
docker exec pg-c psql -U postgres -tAc "SHOW primary_conninfo;" || true
docker exec pg-b psql -U postgres -c \
  "SELECT application_name, state, sync_state FROM pg_stat_replication;" || true

bar "SHOW POOL_NODES (после записи)"
docker exec pg-client psql "$PGPOOL_URI" -c "SHOW POOL_NODES;"
