#!/usr/bin/env bash
# One-time setup of the TEST lobby and relay (2-player co-op of the rebuilt client): their folders under ~/death-muffin, the two systemd units, and the
# code (sync.sh). It does NOT start anything and does NOT touch nginx or the firewall: coop/README.md "Install" lists those steps for the owner, in order.
# Needs the test backend (test-server/setup.sh) first: both services read its JWT_SECRET. Safe to run again.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TESTENV=/home/ubuntu/death-muffin/backend-test/.env
[ -f "$TESTENV" ] || { echo "the test backend is not set up (test-server/setup.sh): $TESTENV is missing" >&2; exit 1; }
mkdir -p /home/ubuntu/death-muffin/lobby-test /home/ubuntu/death-muffin/relay-test/home
sudo install -m 644 "$HERE/death-muffin-lobby-test.service" /etc/systemd/system/death-muffin-lobby-test.service
sudo install -m 644 "$HERE/death-muffin-relay-test.service" /etc/systemd/system/death-muffin-relay-test.service
sudo systemctl daemon-reload
sudo systemctl enable death-muffin-lobby-test.service death-muffin-relay-test.service >/dev/null
bash "$HERE/sync.sh" "${1:-origin/main}" --no-restart
echo "units installed (enabled, not started); next: the drop-in with the relay address, nginx, the firewall, then 'sudo systemctl start death-muffin-relay-test death-muffin-lobby-test' (coop/README.md)"
