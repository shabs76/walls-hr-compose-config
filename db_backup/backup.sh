#!/bin/bash
set -euo pipefail

DB_HOST="${MYSQL_HOST:-mariadb}"
DB_USER="${MYSQL_USER:-root}"
S3_PREFIX="${S3_PREFIX:-mariadb-backups}"
SUCCESS_MARKER="${SUCCESS_MARKER:-/var/run/last_backup_success}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

# Readable message instead of bash's bare "unbound variable" when config is missing
: "${MYSQL_ROOT_PASSWORD:?not set - check backup_config/.env}"
: "${S3_BUCKET:?not set - check backup_config/.env}"

# Skip rather than pile up a second dump if the previous run is still going
LOCK_DIR="/tmp/db_backup.lock"
mkdir "$LOCK_DIR" 2>/dev/null || fail "previous backup still running ($LOCK_DIR exists); skipping this run"

TMP_FILE=""
cleanup() {
    rc=$?
    if [ -n "$TMP_FILE" ]; then
        rm -f "$TMP_FILE" || true
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] BACKUP FAILED (exit $rc)" >&2
    fi
}
trap cleanup EXIT

# Pass the password via the environment so it stays out of the process list
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"

log "Starting MariaDB backup..."

# Fetch MariaDB server version and sanitize for use in filename
if ! RAW_VERSION=$(mysql -h "$DB_HOST" -u "$DB_USER" \
    -e "SELECT VERSION();" -s --skip-column-names 2>&1); then
    fail "could not connect to MariaDB at ${DB_HOST} as ${DB_USER}: ${RAW_VERSION}"
fi

MARIADB_VERSION=$(printf '%s' "$RAW_VERSION" | tr -d '\r' | sed 's/[^a-zA-Z0-9._-]/-/g')
if [ -z "$MARIADB_VERSION" ]; then
    fail "MariaDB at ${DB_HOST} returned an empty version string"
fi

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
FILENAME="backup_${TIMESTAMP}_mariadb-${MARIADB_VERSION}.sql.gz"
TMP_FILE="/tmp/${FILENAME}"

log "Dumping all databases -> ${FILENAME}"

if ! mysqldump \
    -h "$DB_HOST" \
    -u "$DB_USER" \
    --all-databases \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --quick \
    | gzip > "$TMP_FILE"; then
    fail "mysqldump failed; not uploading a partial dump"
fi

# A truncated dump compresses fine but restores badly - verify before shipping it
gzip -t "$TMP_FILE" || fail "dump failed gzip integrity check"
DUMP_SIZE=$(stat -c %s "$TMP_FILE")
if [ "$DUMP_SIZE" -lt 1024 ]; then
    fail "dump is suspiciously small (${DUMP_SIZE} bytes); refusing to upload"
fi

log "Uploading to s3://${S3_BUCKET}/${S3_PREFIX}/${FILENAME} (${DUMP_SIZE} bytes)"

if ! aws s3 cp "$TMP_FILE" "s3://${S3_BUCKET}/${S3_PREFIX}/${FILENAME}" \
    --storage-class STANDARD_IA; then
    fail "upload to s3://${S3_BUCKET}/${S3_PREFIX}/ failed"
fi

# Touched only on success - the container healthcheck reads this timestamp
touch "$SUCCESS_MARKER"

log "Backup completed successfully: ${FILENAME}"
