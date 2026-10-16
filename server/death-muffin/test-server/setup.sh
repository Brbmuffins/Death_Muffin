#!/usr/bin/env bash
# One-time setup of the test backend (DECISIONS B38): database death_muffin_test with its own user, ~/death-muffin/backend-test/.env,
# the systemd unit death-muffin-auth-test (127.0.0.1:5194). Safe to run again: it never overwrites an existing .env or user.
# The nginx location (/death-muffin/test-api/ -> 5194) is added by hand like the live ones (server/death-muffin/nginx-locations.conf).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIVE=/home/ubuntu/death-muffin/backend
TEST=/home/ubuntu/death-muffin/backend-test
DB=death_muffin_test
mkdir -p "$TEST"
if [ ! -f "$TEST/.env" ]; then
  pass=$(openssl rand -hex 24)
  sudo mysql -e "CREATE DATABASE IF NOT EXISTS $DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS 'dm_test'@'localhost' IDENTIFIED BY '$pass';
    ALTER USER 'dm_test'@'localhost' IDENTIFIED BY '$pass';
    GRANT ALL PRIVILEGES ON $DB.* TO 'dm_test'@'localhost'; FLUSH PRIVILEGES;"
  # The live .env minus its database, port and signing key: the test backend never shares the live database or tokens.
  sudo grep -v -E '^(DB_NAME|DB_USER|DB_PASS|PORT|JWT_SECRET)=' "$LIVE/.env" > "$TEST/.env.new"
  { echo "DB_NAME=$DB"; echo "DB_USER=dm_test"; echo "DB_PASS=$pass"; echo "PORT=5194"; echo "JWT_SECRET=$(openssl rand -hex 32)"; } >> "$TEST/.env.new"
  chmod 600 "$TEST/.env.new" && mv "$TEST/.env.new" "$TEST/.env"
  echo "created $TEST/.env and database $DB"
fi
sudo install -m 644 "$HERE/death-muffin-auth-test.service" /etc/systemd/system/death-muffin-auth-test.service
sudo systemctl daemon-reload
sudo systemctl enable death-muffin-auth-test.service >/dev/null
echo "unit installed; next: copy-team.sh, then sync.sh"
