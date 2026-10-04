#!/usr/bin/env bash
# The deploy helper (NOT the AI): runs only after an approver's check, from the runner. All inputs are environment variables set by
# the runner. Takes the global deploy lock (shared with deploy-release.sh), merges the branch onto current master, re-gates and re-tests the
# merged tree, pushes master, runs the deploy, and prints machine-readable lines:  RESULT: <live|conflict|head-moved|gate|tests-failed|master-moved|deploy-failed|lock-timeout> ...
set -uo pipefail
: "${REPO:?}" "${WT_ROOT:?}" "${BRANCH:?}" "${JOBID:?}" "${EXPECT_HEAD:?}" "${LOCK:?}" "${TOOLS:?}" "${CONFIG:?}" "${MAX_TIER:?}"
MIGRATIONS="${MIGRATIONS:-}"
g() { git -c core.hooksPath=/dev/null "$@"; }
say() { echo "STEP: $*"; }

exec 9>"$LOCK"
say "waiting for the deploy lock"
flock -w "${LOCK_WAIT:-1800}" 9 || { echo "RESULT: lock-timeout"; exit 3; }
export DEPLOY_LOCK_HELD=1          # deploy-release.sh must not try to take the lock we already hold

SW="$WT_ROOT/ship-$JOBID"
cleanup() { g -C "$REPO" worktree remove --force "$SW" >/dev/null 2>&1 || rm -rf "$SW"; g -C "$REPO" worktree prune >/dev/null 2>&1; }
trap cleanup EXIT
[ -e "$SW" ] && cleanup

g -C "$REPO" fetch -q origin || { echo "RESULT: fetch-failed"; exit 4; }
OLD=$(g -C "$REPO" rev-parse origin/master)
HEAD_NOW=$(g -C "$REPO" rev-parse "refs/heads/$BRANCH") || { echo "RESULT: head-moved branch missing"; exit 5; }
[ "$HEAD_NOW" = "$EXPECT_HEAD" ] || { echo "RESULT: head-moved $HEAD_NOW"; exit 5; }
g -C "$REPO" worktree add -q --detach "$SW" "$OLD" || { echo "RESULT: worktree-failed"; exit 6; }
cd "$SW"
for rel in node_modules server/realtime/node_modules; do [ -d "$REPO/$rel" ] && ln -s "$REPO/$rel" "$SW/$rel"; done

say "merging $BRANCH onto master ${OLD:0:7}"
if ! g merge -q --ff-only "$EXPECT_HEAD" >/dev/null 2>&1; then
  if ! g merge -q --no-ff -m "Merge $BRANCH" "$EXPECT_HEAD" >/tmp/ship-merge.$$ 2>&1; then
    FILES=$(g diff --name-only --diff-filter=U | head -10 | paste -sd, -)
    g merge --abort >/dev/null 2>&1
    rm -f /tmp/ship-merge.$$
    echo "RESULT: conflict ${FILES}"; exit 7
  fi
  rm -f /tmp/ship-merge.$$
fi
SHA=$(g rev-parse HEAD)

say "re-checking the merged diff"
GATE=$(node "$TOOLS/runner/ship-gate.cjs" "$CONFIG" "$SW" "$OLD" "$MAX_TIER" 2>&1); GRC=$?
echo "$GATE"
[ $GRC -eq 0 ] || { echo "RESULT: gate $(echo "$GATE" | tail -1)"; exit 8; }

say "running tests on the merged tree"
if ! "$TOOLS/check.sh" >"$TOOLS/state/ship-$JOBID.tests.log" 2>&1; then tail -25 "$TOOLS/state/ship-$JOBID.tests.log"; echo "RESULT: tests-failed"; exit 9; fi

say "pushing master"
if ! g push -q origin "HEAD:refs/heads/master" 2>/tmp/ship-push.$$; then tail -3 /tmp/ship-push.$$; rm -f /tmp/ship-push.$$; echo "RESULT: master-moved"; exit 10; fi
rm -f /tmp/ship-push.$$

say "deploying ${SHA:0:12}"
LOG="$TOOLS/state/ship-$JOBID.deploy.log"
if [ -n "${DEPLOY_CMD:-}" ]; then
  # test hook only (config.deployCmd): never set in production
  bash -c "$DEPLOY_CMD" deploy "$SHA" $MIGRATIONS >"$LOG" 2>&1; DRC=$?
else
  # shellcheck disable=SC2086
  bash "$SW/${DEPLOY_SCRIPT:-server/death-muffin/deploy-release.sh}" "$SHA" $MIGRATIONS >"$LOG" 2>&1; DRC=$?
fi
if [ $DRC -ne 0 ]; then tail -25 "$LOG"; echo "RESULT: deploy-failed ${SHA:0:12}"; exit 11; fi
RB=$(grep -oE 'Rollback: [^ ]+ROLLBACK\.sh' "$LOG" | tail -1 | sed 's/^Rollback: //')
echo "RESULT: live ${SHA:0:12} ${RB:-none}"
