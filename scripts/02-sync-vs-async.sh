#!/usr/bin/env bash
# Этап 1 (продолжение). Демонстрация разницы sync vs async на пути ЗАПИСИ:
#   - Отключаем async-реплику (pg-c) от сети: INSERT на pg-a проходит мгновенно
#     (async не в критическом пути COMMIT).
#   - Отключаем sync-реплику  (pg-b) от сети: INSERT на pg-a зависает на SyncRep
#     до восстановления связи с pg-b.
#
# Тесты идут НАПРЯМУЮ к pg-a, минуя pgpool: если бы шли через pgpool, он бы
# увидел недоступность standby как degenerate_backend и эффект был бы
# замаскирован.
#
# В конце скрипт возвращает узлы в сеть и перезапускает pgpool, чтобы кластер
# вернулся в состояние, ожидаемое последующими скриптами (03+).
set -uo pipefail
cd "$(dirname "$0")/.."

bar() { printf '\n--- %s ---\n' "$*"; }

NET=rshd-lab3-net
PG_B_IP=172.28.0.11
PG_C_IP=172.28.0.12

DIRECT_A='host=pg-a port=5432 user=postgres password=postgres dbname=labdb'
PGPOOL_URI='host=pgpool port=9999 user=postgres password=postgres dbname=postgres'

cleanup() {
    bar "CLEANUP: возвращаем узлы в сеть и перезапускаем pgpool"
    docker network connect "$NET" pg-b --ip "$PG_B_IP" 2>/dev/null || true
    docker network connect "$NET" pg-c --ip "$PG_C_IP" 2>/dev/null || true
    sleep 3
    # После disconnect pgpool успевает пометить standby как down.
    # Самый надёжный способ вернуть его в строй -- рестарт pgpool: при старте
    # он заново опросит все бэкенды и выстроит pool_nodes.
    docker restart pgpool >/dev/null 2>&1 || true
    for i in $(seq 1 30); do
        if docker exec pg-client psql "$PGPOOL_URI" -tAc "SELECT 1" >/dev/null 2>&1; then
            echo "pgpool снова отвечает (через ${i}с)."
            break
        fi
        sleep 1
    done
}
trap cleanup EXIT

count_rows() {
    for n in pg-a pg-b pg-c; do
        printf '  %s: ' "$n"
        docker exec "$n" psql -U postgres -d labdb -tAc \
            "SELECT count(*) FROM orders;" 2>/dev/null || echo "(недоступен)"
    done
}

bar "Исходное количество строк в orders"
count_rows

bar "Карта репликации на pg-a (sync_state)"
docker exec pg-a psql -U postgres -c \
  "SELECT application_name, sync_state, state
     FROM pg_stat_replication ORDER BY application_name;"

# ─── Тест 1: ASYNC ────────────────────────────────────────────────────────
bar "ТЕСТ 1 (async). Отключаем pg-c от сети"
docker network disconnect "$NET" pg-c
echo "pg-c вне сети. INSERT на pg-a (напрямую), замеряем время:"

START=$(date +%s%N)
docker exec pg-client psql "$DIRECT_A" -c \
  "INSERT INTO orders (customer_id, product, quantity, amount, status)
     VALUES (1, 'async-test', 1, 1.00, 'new');" >/dev/null
END=$(date +%s%N)
echo ">>> INSERT завершён за $(( (END-START)/1000000 )) мс."
echo "    Async-реплика недоступна, но primary НЕ ждёт её — запись прошла мгновенно."

bar "Возвращаем pg-c в сеть, ждём, пока догонит"
docker network connect "$NET" pg-c --ip "$PG_C_IP"
sleep 3
echo "Строк на узлах после ТЕСТА 1:"
count_rows

# ─── Тест 2: SYNC ─────────────────────────────────────────────────────────
bar "ТЕСТ 2 (sync). Отключаем pg-b от сети"
docker network disconnect "$NET" pg-b
echo "pg-b вне сети. Запускаем INSERT на pg-a в фоне:"

docker exec pg-client psql "$DIRECT_A" -c \
  "INSERT INTO orders (customer_id, product, quantity, amount, status)
     VALUES (1, 'sync-test', 1, 1.00, 'new');" >/tmp/sync-insert.log 2>&1 &
INSERT_PID=$!

# Даём бэкенду войти в фазу COMMIT и встать на SyncRep
sleep 5

bar "Бэкенды на pg-a: ждём ли мы на wait_event=SyncRep?"
docker exec pg-a psql -U postgres -c \
  "SELECT pid, state, wait_event_type, wait_event,
          left(query, 70) AS query
     FROM pg_stat_activity
     WHERE backend_type = 'client backend'
       AND state IS NOT NULL
     ORDER BY wait_event NULLS LAST;"

if kill -0 "$INSERT_PID" 2>/dev/null; then
    echo ">>> INSERT всё ещё висит (PID $INSERT_PID)."
    echo "    Sync-реплика недоступна → COMMIT на primary заблокирован на SyncRep."
else
    echo ">>> [!!] INSERT уже завершился до восстановления pg-b — это неожиданно."
    cat /tmp/sync-insert.log || true
fi

bar "Возвращаем pg-b в сеть → COMMIT должен разблокироваться"
docker network connect "$NET" pg-b --ip "$PG_B_IP"

UNBLOCK_AT=""
for i in $(seq 1 30); do
    if ! kill -0 "$INSERT_PID" 2>/dev/null; then
        UNBLOCK_AT="$i"
        break
    fi
    sleep 1
done
wait "$INSERT_PID" 2>/dev/null || true

if [ -n "$UNBLOCK_AT" ]; then
    echo ">>> INSERT завершился через ~${UNBLOCK_AT}с после восстановления pg-b."
else
    echo ">>> [!!] INSERT не завершился за 30с после восстановления pg-b."
fi

bar "Финальное состояние строк (даём pg-c догнать)"
sleep 3
count_rows

bar "pg_stat_replication: должны снова быть pg-b=sync, pg-c=async"
docker exec pg-a psql -U postgres -c \
  "SELECT application_name, state, sync_state, replay_lag
     FROM pg_stat_replication ORDER BY application_name;"

bar "Итог"
cat <<'EOF'
Тест 1 (async): pg-c отключён — INSERT на primary прошёл мгновенно (~10–50мс).
Тест 2 (sync):  pg-b отключён — INSERT на primary завис на wait_event=SyncRep
                и завершился только после восстановления связи с pg-b.

Это и есть фактическое различие синхронной и асинхронной репликации:
у sync-реплики приоритет в критическом пути COMMIT, у async — нет.
EOF
