#!/usr/bin/env bash
#
# Pgpool-II failover script.
# Called by pgpool when a backend node fails.
# Args (passed by pgpool):
#   $1 = failed node id (%d)
#   $2 = failed node hostname (%h)
#   $3 = failed node port (%p)
#   $4 = failed node data dir (%D)
#   $5 = new main node id (%m)
#   $6 = new main node hostname (%H)
#   $7 = old main node id (%M)
#   $8 = old primary node id (%P)
#   $9 = new main port (%r)
#   $10 = new main data dir (%R)
#
set -euo pipefail

FAILED_NODE_ID="${1:-}"
FAILED_HOST="${2:-}"
FAILED_PORT="${3:-}"
FAILED_PGDATA="${4:-}"
NEW_MAIN_ID="${5:-}"
NEW_MAIN_HOST="${6:-}"
OLD_MAIN_ID="${7:-}"
OLD_PRIMARY_ID="${8:-}"
NEW_MAIN_PORT="${9:-5432}"
NEW_MAIN_PGDATA="${10:-}"

LOG=/var/log/pgpool/failover.log
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "==== Failover triggered ===="
log "Failed:      id=$FAILED_NODE_ID host=$FAILED_HOST port=$FAILED_PORT pgdata=$FAILED_PGDATA"
log "New main:    id=$NEW_MAIN_ID host=$NEW_MAIN_HOST port=$NEW_MAIN_PORT pgdata=$NEW_MAIN_PGDATA"
log "Old main:    id=$OLD_MAIN_ID  old_primary=$OLD_PRIMARY_ID"

# Only promote when the failed node was the primary.
if [ "$FAILED_NODE_ID" != "$OLD_PRIMARY_ID" ]; then
    log "Failed node is not the primary, no promotion required."
    exit 0
fi

if [ -z "$NEW_MAIN_HOST" ] || [ "$NEW_MAIN_HOST" = "$FAILED_HOST" ]; then
    log "No valid new main candidate to promote."
    exit 0
fi

log "Promoting $NEW_MAIN_HOST to primary via pg_promote()..."
# Use the postgres superuser; .pgpass would be cleaner, but inline env var is fine for the lab.
ATTEMPTS=0
until PGPASSWORD=postgres psql -h "$NEW_MAIN_HOST" -p "$NEW_MAIN_PORT" -U postgres -d postgres \
        -tAc "SELECT pg_promote(wait => true, wait_seconds => 30);" 2>>"$LOG" | tee -a "$LOG" | grep -q 't'; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -ge 5 ]; then
        log "ERROR: pg_promote on $NEW_MAIN_HOST failed after $ATTEMPTS attempts."
        exit 1
    fi
    log "pg_promote attempt $ATTEMPTS failed, retrying in 2s..."
    sleep 2
done

log "Successfully promoted $NEW_MAIN_HOST."

# Ensure the new primary doesn't block on absent synchronous standby names
log "Clearing synchronous_standby_names on $NEW_MAIN_HOST..."
PGPASSWORD=postgres psql -h "$NEW_MAIN_HOST" -p "$NEW_MAIN_PORT" -U postgres -d postgres \
    -c "ALTER SYSTEM SET synchronous_standby_names = '';" >>"$LOG" 2>&1 || true
PGPASSWORD=postgres psql -h "$NEW_MAIN_HOST" -p "$NEW_MAIN_PORT" -U postgres -d postgres \
    -c "SELECT pg_reload_conf();" >>"$LOG" 2>&1 || true

log "Failover complete."
exit 0
