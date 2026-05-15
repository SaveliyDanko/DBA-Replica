#!/usr/bin/env bash
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
NODE_ROLE="${NODE_ROLE:-primary}"
NODE_APPNAME="${NODE_APPNAME:-pg-node}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
REPL_USER="${REPL_USER:-replicator}"
REPL_PASSWORD="${REPL_PASSWORD:-replpass}"
PRIMARY_HOST="${PRIMARY_HOST:-pg-a}"
SYNC_STANDBY_NAMES="${SYNC_STANDBY_NAMES:-pg-b-sync}"

# Ensure data dir exists and is owned by postgres
mkdir -p "$PGDATA"
chown -R postgres:postgres "$PGDATA"
chmod 0700 "$PGDATA"

write_pg_hba() {
    cat > "$PGDATA/pg_hba.conf" <<EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
host    all             all             172.28.0.0/16           md5
host    replication     ${REPL_USER}    172.28.0.0/16           md5
host    replication     ${REPL_USER}    127.0.0.1/32            md5
EOF
}

write_primary_base_conf() {
    # Базовый конфиг без synchronous_standby_names — иначе CREATE ROLE при
    # инициализации зависнет в ожидании ещё не существующего sync-standby.
    cat >> "$PGDATA/postgresql.conf" <<EOF

# --- replication settings (primary, base) ---
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
wal_log_hints = on
archive_mode = off
log_replication_commands = on
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql.log'
log_min_messages = info
log_connections = on
log_disconnections = on
EOF
}

enable_primary_sync() {
    cat >> "$PGDATA/postgresql.conf" <<EOF

# --- enable synchronous replication (applied after init) ---
synchronous_commit = on
synchronous_standby_names = '"${SYNC_STANDBY_NAMES}"'
EOF
}

write_standby_conf() {
    cat >> "$PGDATA/postgresql.conf" <<EOF

# --- replication settings (standby) ---
listen_addresses = '*'
hot_standby = on
wal_log_hints = on
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
primary_conninfo = 'host=${PRIMARY_HOST} port=5432 user=${REPL_USER} password=${REPL_PASSWORD} application_name=${NODE_APPNAME}'
# Если этот standby станет primary через pg_promote() -- не требовать sync-реплик,
# чтобы failover не подвисал. Реальные sync-имена восстанавливаются скриптом recovery.
synchronous_standby_names = ''
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql.log'
log_min_messages = info
log_connections = on
log_disconnections = on
EOF
}

init_primary() {
    echo "[entrypoint] Initializing primary node ($NODE_APPNAME)..."
    su postgres -c "initdb -D '$PGDATA' --auth=md5 --pwfile=<(echo \"$POSTGRES_PASSWORD\")"

    write_pg_hba
    write_primary_base_conf

    # Start temporarily to create user/db and apply schema (sync ещё не включён)
    su postgres -c "pg_ctl -D '$PGDATA' -w -t 60 -o '-c listen_addresses=localhost' start"

    su postgres -c "psql -v ON_ERROR_STOP=1 -c \"CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN PASSWORD '${REPL_PASSWORD}';\""
    su postgres -c "psql -v ON_ERROR_STOP=1 -c \"CREATE DATABASE labdb OWNER postgres;\""

    if [ -f /init/01-schema.sql ]; then
        su postgres -c "psql -v ON_ERROR_STOP=1 -d labdb -f /init/01-schema.sql"
    fi

    su postgres -c "pg_ctl -D '$PGDATA' -w -t 60 stop"

    # Теперь дописываем synchronous_standby_names — на следующем запуске
    # postgres подхватит sync-репликацию, а pg-b уже сможет к этому моменту
    # подключиться.
    enable_primary_sync
    echo "[entrypoint] Primary initialization complete."
}

init_standby() {
    echo "[entrypoint] Initializing standby node ($NODE_APPNAME) from $PRIMARY_HOST..."

    # Wait for primary to accept replication connections
    until PGPASSWORD="$REPL_PASSWORD" psql -h "$PRIMARY_HOST" -U "$REPL_USER" -d postgres -c "SELECT 1" >/dev/null 2>&1; do
        echo "[entrypoint] Waiting for primary $PRIMARY_HOST..."
        sleep 2
    done

    rm -rf "$PGDATA"/* "$PGDATA"/.* 2>/dev/null || true
    su postgres -c "PGPASSWORD='${REPL_PASSWORD}' pg_basebackup -h '$PRIMARY_HOST' -D '$PGDATA' -U '$REPL_USER' -Fp -Xs -P -R"

    # pg_basebackup -R writes primary_conninfo with default app_name; override with our APPNAME
    # Remove auto-written primary_conninfo line and add our own
    if [ -f "$PGDATA/postgresql.auto.conf" ]; then
        sed -i '/^primary_conninfo/d' "$PGDATA/postgresql.auto.conf"
    fi

    # Belt-and-suspenders: гарантируем, что standby.signal есть.
    # На некоторых рестартах pg_basebackup -R почему-то его не создаёт.
    su postgres -c "touch '$PGDATA/standby.signal'"

    write_standby_conf
    write_pg_hba

    chown -R postgres:postgres "$PGDATA"
    chmod 0700 "$PGDATA"
    echo "[entrypoint] Standby initialization complete."
}

# Initialize cluster if not already initialized
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    case "$NODE_ROLE" in
        primary)
            init_primary
            ;;
        standby)
            init_standby
            ;;
        *)
            echo "Unknown NODE_ROLE: $NODE_ROLE" >&2
            exit 1
            ;;
    esac
else
    echo "[entrypoint] Data directory already initialized, skipping init."
fi

chown -R postgres:postgres "$PGDATA"
chmod 0700 "$PGDATA"

echo "[entrypoint] Starting postgres..."
exec su postgres -c "postgres -D '$PGDATA'"
