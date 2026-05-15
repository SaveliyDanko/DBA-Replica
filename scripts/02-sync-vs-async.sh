#!/usr/bin/env bash
# Этап 1 (продолжение). Демонстрация:
#   - На pg-c приостанавливаем применение WAL (имитируем сетевую задержку).
#   - Через pgpool делаем INSERT на A.
#   - На pg-b данные появляются мгновенно (sync).
#   - На pg-c данных нет, пока пауза не снята (async + задержка).
#   - Снимаем паузу, данные доезжают до C.
set -euo pipefail
cd "$(dirname "$0")/.."

bar() { printf '\n--- %s ---\n' "$*"; }

PSQL_POOL='psql -tAX host=pgpool port=9999 user=postgres password=postgres dbname=labdb'
PSQL_B='psql -tAX -U postgres -d labdb'
PSQL_C='psql -tAX -U postgres -d labdb'

bar "До эксперимента: количество строк в orders на каждом узле"
docker exec pg-a $PSQL_B -c "SELECT 'A',count(*) FROM orders;"
docker exec pg-b $PSQL_B -c "SELECT 'B',count(*) FROM orders;"
docker exec pg-c $PSQL_C -c "SELECT 'C',count(*) FROM orders;"

bar "Приостанавливаем применение WAL на pg-c (pg_wal_replay_pause)"
docker exec pg-c psql -U postgres -d postgres -c "SELECT pg_wal_replay_pause();"
docker exec pg-c psql -U postgres -d postgres -tAc "SELECT pg_is_wal_replay_paused();"

bar "Запись через pgpool: 5 новых заказов (через A, sync->B, async->C-в очереди)"
docker exec pg-client \
  psql "host=pgpool port=9999 user=postgres password=postgres dbname=labdb" \
  -c "INSERT INTO orders (customer_id, product, quantity, amount, status)
       SELECT 1, 'demo-async-' || g, 1, 1.00, 'new'
       FROM generate_series(1,5) AS g;"

bar "Сразу после INSERT: проверяем количество строк"
docker exec pg-a psql -U postgres -d labdb -tAc "SELECT 'A',count(*) FROM orders;"
docker exec pg-b psql -U postgres -d labdb -tAc "SELECT 'B (sync, должно совпасть с A)',count(*) FROM orders;"
docker exec pg-c psql -U postgres -d labdb -tAc "SELECT 'C (async + пауза, должно быть меньше)',count(*) FROM orders;"

bar "Состояние репликации на A: replay_lag для C должен расти"
docker exec pg-a psql -U postgres -c \
  "SELECT application_name, sync_state, write_lag, flush_lag, replay_lag
     FROM pg_stat_replication ORDER BY application_name;"

bar "Снимаем паузу на pg-c"
docker exec pg-c psql -U postgres -d postgres -c "SELECT pg_wal_replay_resume();"

sleep 3

bar "После возобновления: данные должны быть на всех трёх узлах"
docker exec pg-a psql -U postgres -d labdb -tAc "SELECT 'A',count(*) FROM orders;"
docker exec pg-b psql -U postgres -d labdb -tAc "SELECT 'B',count(*) FROM orders;"
docker exec pg-c psql -U postgres -d labdb -tAc "SELECT 'C',count(*) FROM orders;"

bar "Sync_state в pg_stat_replication"
docker exec pg-a psql -U postgres -c \
  "SELECT application_name, sync_state FROM pg_stat_replication ORDER BY application_name;"
