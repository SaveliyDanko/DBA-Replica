#!/usr/bin/env bash
# Этап 2.1. Несколько клиентских сессий через pgpool, чтение и запись,
# демонстрация транзакций.
set -euo pipefail
cd "$(dirname "$0")/.."

bar() { printf '\n--- %s ---\n' "$*"; }
PGPOOL_URI='host=pgpool port=9999 user=postgres password=postgres dbname=labdb'

bar "Клиент №1 (запись): добавляем нового клиента в транзакции"
docker exec -i pg-client psql "$PGPOOL_URI" <<'SQL'
BEGIN;
INSERT INTO customers (username, email, full_name)
     VALUES ('dave', 'dave@example.com', 'Dave Davis')
     ON CONFLICT (username) DO UPDATE SET full_name = EXCLUDED.full_name
     RETURNING id, username;
INSERT INTO orders (customer_id, product, quantity, amount, status)
  VALUES ((SELECT id FROM customers WHERE username='dave'), 'Headphones', 1, 199.99, 'paid')
  RETURNING id, product, amount;
COMMIT;
SELECT 'after-commit', count(*) AS customers FROM customers;
SQL

bar "Клиент №2 (чтение): читаем последние заказы (запрос уйдёт на реплику)"
docker exec pg-client psql "$PGPOOL_URI" -c \
  "SELECT id, customer_id, product, amount, status, created_at FROM orders ORDER BY id DESC LIMIT 5;"

bar "Клиент №3 (запись с rollback): транзакция должна быть отменена"
docker exec -i pg-client psql "$PGPOOL_URI" <<'SQL'
BEGIN;
UPDATE orders SET status = 'cancelled' WHERE id IN (1, 2);
SELECT id, status FROM orders WHERE id IN (1,2);
ROLLBACK;
-- Проверка: статусы должны вернуться к исходным
SELECT id, status FROM orders WHERE id IN (1,2);
SQL

bar "Клиент №4 (запись): пакетная вставка"
docker exec pg-client psql "$PGPOOL_URI" -c \
  "INSERT INTO orders (customer_id, product, quantity, amount, status)
     SELECT 1+(g%3), 'demo-rw-' || g, 1, g*1.5, 'new'
     FROM generate_series(1,5) AS g;"

bar "Клиент №5 (чтение, явное LB): SELECT через pgpool на каждый узел"
for i in 1 2 3 4 5 6; do
  docker exec pg-client psql "$PGPOOL_URI" -tAc \
    "SELECT inet_server_addr() || ' ' || pg_is_in_recovery()::text AS who;"
done

bar "Активные клиентские подключения, видимые на узлах"
for n in pg-a pg-b pg-c; do
  echo "[$n]"
  docker exec "$n" psql -U postgres -tAc \
    "SELECT pid, usename, application_name, client_addr, state
       FROM pg_stat_activity WHERE backend_type='client backend';"
done

bar "Содержимое таблиц после всех операций"
docker exec pg-client psql "$PGPOOL_URI" -c "SELECT count(*) AS customers FROM customers;"
docker exec pg-client psql "$PGPOOL_URI" -c "SELECT count(*) AS orders FROM orders;"
