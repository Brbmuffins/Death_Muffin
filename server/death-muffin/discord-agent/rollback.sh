#!/usr/bin/env bash
# Run a deploy backup's ROLLBACK.sh under the global deploy lock. rollback.sh <path/to/ROLLBACK.sh>
# (the runner only passes paths it has validated to be <deployDir>/backup-pre-release-*/ROLLBACK.sh)
set -uo pipefail
: "${LOCK:?}"
exec 9>"$LOCK"
flock -w "${LOCK_WAIT:-600}" 9 || { echo "RESULT: lock-timeout"; exit 3; }
export DEPLOY_LOCK_HELD=1
if [ -n "${ROLLBACK_CMD:-}" ]; then bash -c "$ROLLBACK_CMD" rollback "$1"; else bash "$1"; fi
RC=$?
[ $RC -eq 0 ] && echo "RESULT: rolled-back" || echo "RESULT: rollback-failed"
exit $RC
