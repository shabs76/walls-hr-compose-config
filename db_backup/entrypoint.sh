#!/bin/bash
set -e

LOG_FILE="/var/log/db_backup.log"
SUCCESS_MARKER="/var/run/last_backup_success"
touch "$LOG_FILE"

# Seed the marker so a freshly deployed container starts healthy; the healthcheck
# then turns unhealthy if no backup succeeds within the window (see docker-compose.yaml)
touch "$SUCCESS_MARKER"

# Schedule backup twice daily: 02:00 UTC and 14:00 UTC (override with BACKUP_CRON)
BACKUP_CRON="${BACKUP_CRON:-0 2,14 * * *}"
echo "${BACKUP_CRON} /usr/local/bin/backup.sh >> ${LOG_FILE} 2>&1" | crontab -

echo "[$(date '+%Y-%m-%d %H:%M:%S')] MariaDB backup cron scheduled: ${BACKUP_CRON} (container TZ: $(date +%Z))"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting cron daemon..."

# Tail the log so container output stays visible, then run crond
crond -f -l 2 &
CROND_PID=$!

# Stream logs to stdout
tail -F "$LOG_FILE" &

wait "$CROND_PID"
