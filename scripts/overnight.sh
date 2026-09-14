#!/usr/bin/env bash
# overnight.sh — run copy (+cutover if copy verifies) unattended.
# Disconnect-safe: relaunches itself detached with nohup; all output to the log.
# Usage (root):  sudo bash overnight.sh
# Progress:      tail -f /volume1/overnight-migrate.log
export PATH=/usr/local/bin:$PATH
LOG=/volume1/overnight-migrate.log
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${DETACHED:-0}" != "1" ]; then
  DETACHED=1 nohup "$0" >> "$LOG" 2>&1 &
  echo "launched detached (pid $!) — progress: tail -f $LOG"
  exit 0
fi

echo "[$(date '+%F %T')] === overnight run starting (VERBOSE, SKIP_SIZE_CHECK) ==="
env VERBOSE=1 SKIP_SIZE_CHECK=1 bash "$DIR/migrate-docker-ext4.sh" copy
rc=$?
echo "[$(date '+%F %T')] copy finished rc=$rc"
state=$(awk '{print $1}' /volume1/@docker-ext4.migration-state 2>/dev/null)
if [ "$state" = "copied" ]; then
  env VERBOSE=1 SKIP_SIZE_CHECK=1 bash "$DIR/migrate-docker-ext4.sh" cutover
  echo "[$(date '+%F %T')] cutover finished rc=$?"
else
  echo "[$(date '+%F %T')] state is '$state' (not 'copied') — NOT attempting cutover. Fix and re-run copy."
fi
echo "[$(date '+%F %T')] === overnight run done; final state: $(awk '{print $1}' /volume1/@docker-ext4.migration-state 2>/dev/null) ==="
