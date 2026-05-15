#!/usr/bin/env bash
set -euo pipefail

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
REPL_USER="${REPL_USER:-replicator}"
REPL_PASSWORD="${REPL_PASSWORD:-replpass}"

# Generate pool_passwd entries (format: user:md5<hex>, where hex = md5(password+user))
pool_passwd_file=/etc/pgpool2/pool_passwd
: > "$pool_passwd_file"
add_pool_user() {
    local user="$1" pass="$2"
    local hash
    hash=$(printf '%s%s' "$pass" "$user" | md5sum | awk '{print $1}')
    echo "${user}:md5${hash}" >> "$pool_passwd_file"
}
add_pool_user "$POSTGRES_USER" "$POSTGRES_PASSWORD"
add_pool_user "$REPL_USER"     "$REPL_PASSWORD"

# Generate pcp.conf (format: user:md5<hex_of_password>)
pcp_file=/etc/pgpool2/pcp.conf
pcp_hash=$(printf '%s' "$POSTGRES_PASSWORD" | md5sum | awk '{print $1}')
echo "${POSTGRES_USER}:${pcp_hash}" > "$pcp_file"
echo "${POSTGRES_USER}:${POSTGRES_PASSWORD}" > /var/lib/postgresql/.pcppass
chmod 600 /var/lib/postgresql/.pcppass
chown postgres:postgres /var/lib/postgresql/.pcppass

# Pgpool node id (single instance)
mkdir -p /etc/pgpool2
echo 0 > /etc/pgpool2/pgpool_node_id

chown postgres:postgres "$pool_passwd_file" "$pcp_file" /etc/pgpool2/pgpool_node_id
chmod 600 "$pool_passwd_file" "$pcp_file"

# Ensure runtime dirs exist
mkdir -p /var/run/pgpool /var/log/pgpool /var/run/postgresql
chown -R postgres:postgres /var/run/pgpool /var/log/pgpool /var/run/postgresql

# Wait for backend nodes
for host in pg-a pg-b pg-c; do
    until nc -z "$host" 5432; do
        echo "[pgpool-entrypoint] Waiting for $host:5432..."
        sleep 2
    done
done

echo "[pgpool-entrypoint] All backends reachable, starting pgpool..."
exec gosu postgres /usr/sbin/pgpool -n -f /etc/pgpool2/pgpool.conf -F /etc/pgpool2/pcp.conf -a /etc/pgpool2/pool_hba.conf
