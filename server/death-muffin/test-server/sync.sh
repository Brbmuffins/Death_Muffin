#!/usr/bin/env bash
# Puts the live backend's installed code on the test backend, applies pending migrations to the test database and restarts it.
# deploy-release.sh runs it after every live deploy (best effort: a failure here never fails the live deploy).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIVE=/home/ubuntu/death-muffin/backend
TEST=/home/ubuntu/death-muffin/backend-test
[ -f "$TEST/.env" ] || { echo "test backend not set up (test-server/setup.sh)" >&2; exit 1; }
rsync -a --delete --exclude '.env' --exclude '.env.*' "$LIVE/" "$TEST/"
# Migrations come from the repository at the deployed revision, like deploy-release.sh (the installed backend does not keep every file).
#   sync.sh [rev]      default origin/main; deploy-release.sh passes the revision it just deployed
REV="${1:-origin/main}"
MIG=$(mktemp -d); trap 'rm -rf "$MIG"' EXIT
git -C /home/ubuntu/vps-handoffs/DeathMuffin/game archive "$REV" server/death-muffin/backend/migrations | tar -x -C "$MIG"
MIG="$MIG/server/death-muffin/backend/migrations"
DM_DB=death_muffin_test bash "$HERE/../migrate.sh" "$MIG"
sudo systemctl restart death-muffin-auth-test.service
curl --silent --show-error --fail --retry 10 --retry-delay 1 --retry-all-errors http://127.0.0.1:5194/health >/dev/null
echo "test backend synced and healthy on :5194"
