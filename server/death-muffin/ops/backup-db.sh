#!/usr/bin/env bash
# Nightly backup of the live Death Muffin database (MySQL `death_muffin`). Run by death-muffin-db-backup.timer.
#
#   backup-db.sh            dump, verify, rotate
#
# Writes $DEST/daily/death_muffin-<UTC stamp>.sql.gz (mode 600). Keeps the newest 14 daily dumps; the first dump of each ISO week
# is also kept in weekly/ (newest 8) and the first of each month in monthly/ (newest 12). A dump is kept only if gzip verifies and
# mysqldump wrote its "Dump completed" footer; otherwise the script exits 1 (the drift report flags a missing or stale backup).
# Restore: gunzip -c <file> | sudo mysql death_muffin   (drops and recreates each table: restore into a scratch DB first if unsure).
set -euo pipefail

DB="${DB:-death_muffin}"
DEST="${DEST:-/home/ubuntu/death-muffin/backups/db}"
KEEP_DAILY="${KEEP_DAILY:-14}" KEEP_WEEKLY="${KEEP_WEEKLY:-8}" KEEP_MONTHLY="${KEEP_MONTHLY:-12}"

umask 077
mkdir -p "$DEST/daily" "$DEST/weekly" "$DEST/monthly"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$DEST/daily/$DB-$STAMP.sql.gz"
TMP="$OUT.partial"
trap 'rm -f "$TMP"' EXIT

sudo mysqldump --single-transaction --routines --triggers --events "$DB" | gzip -9 >"$TMP"
gzip -t "$TMP"
gunzip -c "$TMP" | tail -n 3 | grep -q 'Dump completed' || { echo "backup-db: dump has no completion footer" >&2; exit 1; }
mv "$TMP" "$OUT"

# First dump of the week / month also goes to weekly/ and monthly/ (hard links: no extra space).
WEEK=$(date -u +%G-W%V) MONTH=$(date -u +%Y-%m)
ls "$DEST/weekly" | grep -q -- "-$WEEK\.sql\.gz$" || ln "$OUT" "$DEST/weekly/$DB-$WEEK.sql.gz"
ls "$DEST/monthly" | grep -q -- "-$MONTH\.sql\.gz$" || ln "$OUT" "$DEST/monthly/$DB-$MONTH.sql.gz"

prune() { ls -1t "$1"/*.sql.gz 2>/dev/null | tail -n +"$(($2 + 1))" | while read -r f; do rm -f -- "$f"; done; }
prune "$DEST/daily" "$KEEP_DAILY"
prune "$DEST/weekly" "$KEEP_WEEKLY"
prune "$DEST/monthly" "$KEEP_MONTHLY"

echo "backup-db: $OUT ($(stat -c %s "$OUT") bytes); daily $(ls "$DEST/daily" | wc -l), weekly $(ls "$DEST/weekly" | wc -l), monthly $(ls "$DEST/monthly" | wc -l)"
