#!/usr/bin/env bash
# Этап 1. Показать конфигурацию репликации:
#   - роли узлов
#   - состояние pg_stat_replication на A
#   - типы репликации (sync для B, async для C)
#   - вывод SHOW POOL_NODES из pgpool
set -euo pipefail
cd "$(dirname "$0")/.."

bar() { printf '\n--- %s ---\n' "$*"; }

bar "Состояние контейнеров"
docker compose ps

bar "pg-a: in_recovery? (false = primary)"
docker exec pg-a psql -U postgres -tAc "SELECT pg_is_in_recovery();"

bar "pg-b: in_recovery? (true = standby)"
docker exec pg-b psql -U postgres -tAc "SELECT pg_is_in_recovery();"

bar "pg-c: in_recovery? (true = standby)"
docker exec pg-c psql -U postgres -tAc "SELECT pg_is_in_recovery();"

bar "pg_stat_replication на pg-a (application_name, state, sync_state)"
docker exec pg-a psql -U postgres -d postgres -c \
  "SELECT application_name, client_addr, state, sync_state, sync_priority, replay_lag
     FROM pg_stat_replication ORDER BY application_name;"

bar "synchronous_standby_names на pg-a"
docker exec pg-a psql -U postgres -tAc "SHOW synchronous_standby_names;"

bar "primary_conninfo на pg-b"
docker exec pg-b psql -U postgres -tAc "SHOW primary_conninfo;"

bar "primary_conninfo на pg-c"
docker exec pg-c psql -U postgres -tAc "SHOW primary_conninfo;"

bar "pgpool: SHOW POOL_NODES"
docker exec pg-client \
  psql "host=pgpool port=9999 user=postgres password=postgres dbname=postgres" \
  -c "SHOW POOL_NODES;"

bar "Данные в labdb через pgpool (round-robin читает с реплик)"
docker exec pg-client \
  psql "host=pgpool port=9999 user=postgres password=postgres dbname=labdb" \
  -c "SELECT * FROM customers ORDER BY id;"
docker exec pg-client \
  psql "host=pgpool port=9999 user=postgres password=postgres dbname=labdb" \
  -c "SELECT * FROM orders ORDER BY id;"
