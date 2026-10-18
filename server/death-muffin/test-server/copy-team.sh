#!/usr/bin/env bash
# (Re)fills the test database from live: the live schema, every catalog table, and the team's accounts with their characters and
# everything that belongs to them. Logs and history (audits, bug reports, party sessions, live benchmark runs) stay out. Anything played
# on the test server since the last copy is replaced, except its own benchmark runs, which are kept. Live is only read.
#   copy-team.sh [username ...]      default: the team (Brbmuffins Helix Bogar bogar1 Dravos)
set -euo pipefail
LIVE_DB=death_muffin
DB=death_muffin_test
USERS=("$@"); [ ${#USERS[@]} -gt 0 ] || USERS=(Brbmuffins Helix Bogar bogar1 Dravos)
# Tables copied whole (game content and the migration record) and tables never copied (logs, history, other players' social data).
CATALOG="enemy_templates item_template items loot_tables loot_reforges quest_objectives quests recipe_ingredients recipes talents vendor_stock vendors schema_migrations"
SKIP="agent_audit_log benchmark_runs broadcast_messages bug_reports dashboard_users feedback party_session_members party_sessions progress_audit tickets guilds guild_members guild_chat_log marketplace_listings ground_drops combat_sessions"
q() { sudo mysql -N -B -e "$1"; }
names=$(printf "'%s'," "${USERS[@]}"); names=${names%,}
ACC=$(q "SELECT GROUP_CONCAT(id) FROM $LIVE_DB.accounts WHERE username IN ($names)")
[ -n "$ACC" ] && [ "$ACC" != "NULL" ] || { echo "no such accounts: ${USERS[*]}" >&2; exit 1; }
CHR=$(q "SELECT IFNULL(GROUP_CONCAT(id),'0') FROM $LIVE_DB.characters WHERE account_id IN ($ACC)")
echo "accounts $ACC, characters $CHR"
# The test server's own benchmark runs (the rebuild's results) survive a refill: set aside before the drop, put back after the copy.
BENCH=$(mktemp); trap 'rm -f "$BENCH"' EXIT
if [ "$(q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB' AND table_name='benchmark_runs'")" = 1 ]; then
  sudo mysqldump --no-create-info --skip-triggers "$DB" benchmark_runs > "$BENCH"
fi
sudo systemctl stop death-muffin-auth-test.service 2>/dev/null || true
sudo mysql -e "DROP DATABASE IF EXISTS $DB; CREATE DATABASE $DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysqldump --no-data --skip-triggers "$LIVE_DB" | sudo mysql "$DB"
# Generated columns (e.g. character_necro_progress.ascension) are computed by MySQL and refuse values: copy the other columns only.
copy() {
  local c
  c=$(q "SELECT GROUP_CONCAT(CONCAT('\`',column_name,'\`') ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='$LIVE_DB' AND table_name='$1' AND extra NOT LIKE '%GENERATED%'")
  sudo mysql -e "SET FOREIGN_KEY_CHECKS=0; INSERT INTO $DB.\`$1\` ($c) SELECT $c FROM $LIVE_DB.\`$1\` $2;"
}
for t in $(q "SELECT table_name FROM information_schema.tables WHERE table_schema='$LIVE_DB' AND table_type='BASE TABLE' ORDER BY table_name"); do
  case " $SKIP " in *" $t "*) continue ;; esac
  case " $CATALOG " in *" $t "*) copy "$t" ""; continue ;; esac
  cols=$(q "SELECT GROUP_CONCAT(column_name) FROM information_schema.columns WHERE table_schema='$LIVE_DB' AND table_name='$t'")
  case ",$cols," in
    *,account_lo,*) copy "$t" "WHERE account_lo IN ($ACC) AND account_hi IN ($ACC)" ;;
    *,account_id,*) copy "$t" "WHERE account_id IN ($ACC)" ;;
    *,character_id,*) copy "$t" "WHERE character_id IN ($CHR)" ;;
    *) if [ "$t" = accounts ]; then copy "$t" "WHERE id IN ($ACC)"; else echo "  not copied (no owner column): $t"; fi ;;
  esac
done
[ -s "$BENCH" ] && sudo mysql "$DB" < "$BENCH"
sudo systemctl start death-muffin-auth-test.service 2>/dev/null || true
echo "copied: $(q "SELECT COUNT(*) FROM $DB.accounts") accounts, $(q "SELECT COUNT(*) FROM $DB.characters") characters; kept $(q "SELECT COUNT(*) FROM $DB.benchmark_runs") benchmark runs"
