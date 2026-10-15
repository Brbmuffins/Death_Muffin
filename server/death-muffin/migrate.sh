#!/usr/bin/env bash
# Backend migration runner: applies every backend/migrations/NNN-*.sql the database has not recorded in `schema_migrations`, in name order,
# one file at a time, and records each (name, sha256, rev) right after it succeeds. deploy-release.sh runs it; it also runs by hand.
#
#   migrate.sh <migrations-dir> [rev]                 apply what is pending
#   migrate.sh --pending <migrations-dir>             print the pending names (nothing applied); exit 0 either way
#   migrate.sh --baseline-through NNN <migrations-dir>  record files up to NNN as applied WITHOUT running them (one-time, for an existing DB)
#
# A recorded file whose content changed since it was applied is reported, never re-run. A failing file stops the run (it is not recorded);
# the files before it stay recorded. Uses `sudo mysql` (root socket auth) like the rest of the deploy tools. DB: DM_DB (default death_muffin).
set -euo pipefail
DB="${DM_DB:-death_muffin}"
MODE=apply; THROUGH=""
case "${1:-}" in
  --pending) MODE=pending; shift ;;
  --baseline-through) MODE=baseline; THROUGH="$2"; shift 2 ;;
esac
DIR="${1:?usage: migrate.sh [--pending|--baseline-through NNN] <migrations-dir> [rev]}"
REV="${2:-}"
sql() { sudo mysql -N -B "$DB" "$@"; }
esc() { printf %s "$1" | sed "s/'/''/g"; }

[ -f "$DIR/055-schema-migrations.sql" ] || { echo "migrate: $DIR has no 055-schema-migrations.sql" >&2; exit 1; }
HAS_TABLE=$(sql -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'schema_migrations'")
if [ "$HAS_TABLE" = 0 ]; then
  # Without the table every file would look pending, 001 onwards: refuse instead of replaying the whole history on an existing database.
  [ "$MODE" = pending ] && { echo "(schema_migrations missing: run --baseline-through NNN first)"; exit 0; }
  if [ "$MODE" = apply ] && [ -z "${MIGRATE_FRESH:-}" ]; then
    echo "migrate: $DB has no schema_migrations table. Record what is already applied with --baseline-through NNN first (MIGRATE_FRESH=1 only for an empty database)." >&2
    exit 1
  fi
  sql < "$DIR/055-schema-migrations.sql"
fi
declare -A DONE=()
while IFS=$'\t' read -r n h; do [ -n "$n" ] && DONE["$n"]="$h"; done < <(sql -e "SELECT name, sha256 FROM schema_migrations")

APPLIED=0
for f in $(ls "$DIR" | grep -E '^[0-9]{3}-.+\.sql$' | sort); do
  h=$(sha256sum "$DIR/$f" | cut -d' ' -f1)
  if [ -n "${DONE[$f]:-}" ]; then
    [ "${DONE[$f]}" = "$h" ] || echo "migrate: WARNING $f changed after it was applied (not re-run; add a new file instead)" >&2
    continue
  fi
  case "$MODE" in
    pending) echo "$f" ;;
    baseline)
      [ "$((10#${f%%-*}))" -le "$((10#$THROUGH))" ] || continue
      sql -e "INSERT INTO schema_migrations (name, sha256, rev) VALUES ('$(esc "$f")', '$h', 'baseline')"
      echo "migrate: recorded $f (baseline, not run)" ;;
    apply)
      echo "== Migration $f"
      sql < "$DIR/$f"
      sql -e "INSERT INTO schema_migrations (name, sha256, rev) VALUES ('$(esc "$f")', '$h', '$(esc "$REV")')"
      APPLIED=$((APPLIED + 1)) ;;
  esac
done
[ "$MODE" = apply ] && echo "migrate: $APPLIED applied"
exit 0
