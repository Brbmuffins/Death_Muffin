#!/usr/bin/env bash
# The deploy helper (NOT the AI): runs only after an approver's check, from the runner. All inputs are environment variables set by
# the runner. Takes the global deploy lock (shared with deploy-release.sh), merges the branch onto the current base branch (BASE_BRANCH, default
# main), re-gates and re-tests the merged tree, pushes it, runs the deploy, and prints machine-readable lines:
#   RESULT: <live|live-already|conflict|head-moved|gate|tests-failed|master-moved|backup-failed|deploy-failed|lock-timeout> ...      ("master-moved" = BASE_BRANCH moved)
# PUBLISH_ONLY=1 PUBLISH_SHA=<sha> (godot only; the retry after a failed client publish): no merge/tests/push. Publishes that already-tested, already-
# pushed commit with a fresh rollback, or prints "RESULT: live-already" when the live client already contains it (never publishes an older client).
# The Godot publish itself is tried up to 3 times (PUBLISH_RETRY_SLEEPS, default "30 90") before deploy-failed: one-off Godot import crashes heal by themselves.
# MODE=web (default): deploy-release.sh, then the best-effort mobile step. MODE=godot: check-godot.sh, and the Godot client is published with
# publish-godot-client.sh after a ROLLBACK.sh for the revision that is live now has been written (see the godot block below). No mobile step.
set -uo pipefail
: "${REPO:?}" "${WT_ROOT:?}" "${JOBID:?}" "${LOCK:?}" "${TOOLS:?}" "${CONFIG:?}"
PUBLISH_ONLY="${PUBLISH_ONLY:-}"
[ -n "$PUBLISH_ONLY" ] || : "${BRANCH:?}" "${EXPECT_HEAD:?}" "${MAX_TIER:?}"
MIGRATIONS="${MIGRATIONS:-}"
BASE_BRANCH="${BASE_BRANCH:-main}"
MODE="${MODE:-web}"
# These reach git as refs and refspecs: same rules as loadConfig (plain ref characters, nothing git could read as an option or a range).
[[ "$BASE_BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$BASE_BRANCH" != -* && "$BASE_BRANCH" != *..* ]] || { echo "RESULT: bad-config base branch"; exit 2; }
[ "$MODE" = web ] || [ "$MODE" = godot ] || { echo "RESULT: bad-config mode"; exit 2; }
[ -z "$PUBLISH_ONLY" ] || [ "$MODE" = godot ] || { echo "RESULT: bad-config publish-only is godot mode only"; exit 2; }
[ -z "$PUBLISH_ONLY" ] || [[ "${PUBLISH_SHA:-}" =~ ^[0-9a-f]{7,40}$ ]] || { echo "RESULT: bad-config PUBLISH_SHA"; exit 2; }
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
OLD=$(g -C "$REPO" rev-parse "origin/$BASE_BRANCH")
if [ -n "$PUBLISH_ONLY" ]; then
  SHA=$(g -C "$REPO" rev-parse -q --verify "$PUBLISH_SHA^{commit}") || { echo "RESULT: head-moved $PUBLISH_SHA is not in the repo"; exit 5; }
  # only something the ship really pushed: the commit must be on the base branch
  g -C "$REPO" merge-base --is-ancestor "$SHA" "$OLD" || { echo "RESULT: head-moved ${SHA:0:12} is not on $BASE_BRANCH"; exit 5; }
else
HEAD_NOW=$(g -C "$REPO" rev-parse "refs/heads/$BRANCH") || { echo "RESULT: head-moved branch missing"; exit 5; }
[ "$HEAD_NOW" = "$EXPECT_HEAD" ] || { echo "RESULT: head-moved $HEAD_NOW"; exit 5; }
g -C "$REPO" worktree add -q --detach "$SW" "$OLD" || { echo "RESULT: worktree-failed"; exit 6; }
cd "$SW"
for rel in node_modules; do [ -d "$REPO/$rel" ] && ln -s "$REPO/$rel" "$SW/$rel"; done

say "merging $BRANCH onto $BASE_BRANCH ${OLD:0:7}"
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
CHECK="$TOOLS/check.sh"; [ "$MODE" = godot ] && CHECK="$TOOLS/check-godot.sh"
if ! "$CHECK" >"$TOOLS/state/ship-$JOBID.tests.log" 2>&1; then tail -25 "$TOOLS/state/ship-$JOBID.tests.log"; echo "RESULT: tests-failed"; exit 9; fi
fi   # (end of the normal ship's merge/gate/tests; PUBLISH_ONLY skips them: that commit was tested and pushed by the ship that failed to publish)

# ---- godot: get the rollback ready BEFORE anything is pushed or published (a failure here leaves everything as it was) ----
# The Godot client is published by publish-godot-client.sh from the base branch (main), so the copy that is used
# for BOTH the new publish and the rollback is taken fresh from origin/<base branch> now and kept in the backup folder. ROLLBACK.sh republishes the
# revision that is live right now (the `rev` in the client manifest). No manifest = nothing is live yet = nothing to roll back to ("Rollback: none").
BK=""
if [ "$MODE" = godot ]; then
  DEPLOY_DIR="${DEPLOY_DIR:-$(dirname "$LOCK")}"
  MANIFEST="${CLIENT_MANIFEST:-/var/www/death-muffin/client/manifest.json}"
  PUB_REF="${PUBLISH_SRC_REF:-origin/${BASE_BRANCH:-main}}"; PUB_PATH="${PUBLISH_SRC_PATH:-server/death-muffin/publish-godot-client.sh}"
  LIVE_REV=""
  if [ -e "$MANIFEST" ]; then
    LIVE_REV=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rev"])' "$MANIFEST" 2>/dev/null || true)
    [[ "$LIVE_REV" =~ ^[0-9a-f]{7,40}$ ]] || { echo "RESULT: backup-failed live revision in $MANIFEST is unreadable"; exit 12; }
    g -C "$REPO" rev-parse -q --verify "$LIVE_REV^{commit}" >/dev/null || { echo "RESULT: backup-failed live revision ${LIVE_REV:0:12} is not in the repo"; exit 12; }
  fi
  if [ -n "$PUBLISH_ONLY" ] && [ -n "$LIVE_REV" ] && g -C "$REPO" merge-base --is-ancestor "$SHA" "$LIVE_REV"; then
    echo "RESULT: live-already ${SHA:0:12} ${LIVE_REV:0:12}"; exit 0     # a later publish already carries it: never go backwards
  fi
  abandon_backup() { [ -n "$BK" ] && rm -rf "$BK"; }
  # one folder per second: a retry right after a failed ship (whose backup stays) can land in the same second, so wait for the next one
  for _ in 1 2 3; do BK="$DEPLOY_DIR/backup-pre-release-godot-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir "$BK" 2>/dev/null && break; BK=""; sleep 1; done
  [ -n "$BK" ] || { echo "RESULT: backup-failed cannot create a backup folder in $DEPLOY_DIR"; exit 12; }
  if ! g -C "$REPO" show "$PUB_REF:$PUB_PATH" >"$BK/publish-godot-client.sh" 2>/dev/null || [ ! -s "$BK/publish-godot-client.sh" ]; then abandon_backup; echo "RESULT: backup-failed no $PUB_PATH on $PUB_REF"; exit 12; fi
  if [ -n "$LIVE_REV" ]; then
    printf '#!/usr/bin/env bash\n# Roll back to the Godot client revision that was live before %s: republish it with the publish script saved next to this file.\nset -euo pipefail\nexport REPO=%q\nexec bash %q %q\n' "${SHA:0:12}" "$REPO" "$BK/publish-godot-client.sh" "$LIVE_REV" >"$BK/ROLLBACK.sh"
    chmod 755 "$BK/ROLLBACK.sh"
  else
    echo "no client manifest at $MANIFEST: first publish, nothing to roll back to"
  fi
fi

if [ -z "$PUBLISH_ONLY" ]; then
say "pushing $BASE_BRANCH"
if ! g push -q origin "HEAD:refs/heads/$BASE_BRANCH" 2>/tmp/ship-push.$$; then tail -3 /tmp/ship-push.$$; rm -f /tmp/ship-push.$$; [ -n "$BK" ] && abandon_backup; echo "RESULT: master-moved"; exit 10; fi
rm -f /tmp/ship-push.$$
fi

say "deploying ${SHA:0:12}"
LOG="$TOOLS/state/ship-$JOBID.deploy.log"
if [ "$MODE" = godot ]; then
  publish_once() {
    if [ -n "${DEPLOY_CMD:-}" ]; then bash -c "$DEPLOY_CMD" deploy "$SHA"     # test hook only (config.deployCmd): never set in production
    else REPO="$REPO" bash "$BK/publish-godot-client.sh" "$SHA"; fi
  }
  # up to 3 tries: a Godot import/export can crash once (2026-10-08: core dump in --import; the same commit imported fine on the next run)
  : >"$LOG"; DRC=1; TRY=0
  for WAIT in 0 ${PUBLISH_RETRY_SLEEPS-30 90}; do
    TRY=$((TRY + 1))
    if [ "$WAIT" -gt 0 ] 2>/dev/null; then say "client publish failed, retrying in ${WAIT}s (try $TRY)"; sleep "$WAIT"; fi
    echo "=== publish try $TRY $(date -u +%FT%TZ)" >>"$LOG"
    publish_once >>"$LOG" 2>&1; DRC=$?
    [ $DRC -eq 0 ] && break
  done
  [ $DRC -eq 0 ] && [ $TRY -gt 1 ] && echo "PUBLISH-RETRIES: $((TRY - 1))"
  if [ $DRC -ne 0 ]; then tail -25 "$LOG"; echo "RESULT: deploy-failed ${SHA:0:12}"; exit 11; fi
  RB=none; [ -f "$BK/ROLLBACK.sh" ] && RB="$BK/ROLLBACK.sh"
  [ "$RB" = none ] || echo "Rollback: $RB"
  echo "RESULT: live ${SHA:0:12} $RB"
  echo "MOBILE: skipped"
  exit 0
fi
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

# ---- phones + offline edition (best effort; the PC release above is already live and stays live whatever happens here) ----
# Merge the new base branch into the mobile branch in a scratch worktree, test, push, publish. Any trouble -> MOBILE: pending <reason>, mobile untouched
# (until the push; after it a failed publish is reported as pending too). Prints exactly one MOBILE: line.
MB="${MOBILE_BRANCH-mobile}"
MW="$WT_ROOT/mobile-$JOBID"
mobile_cleanup() { g -C "$REPO" worktree remove --force "$MW" >/dev/null 2>&1 || rm -rf "$MW"; g -C "$REPO" worktree prune >/dev/null 2>&1; }
mobile_step() {
  [ -n "$MB" ] || { echo "MOBILE: skipped"; return; }
  g -C "$REPO" fetch -q origin 2>/dev/null || { echo "MOBILE: pending fetch failed"; return; }
  g -C "$REPO" rev-parse -q --verify "refs/remotes/origin/$MB" >/dev/null || { echo "MOBILE: skipped no $MB branch"; return; }
  [ -e "$MW" ] && mobile_cleanup
  g -C "$REPO" worktree add -q --detach "$MW" "origin/$MB" || { echo "MOBILE: pending worktree failed"; return; }
  for rel in node_modules; do [ -d "$REPO/$rel" ] && ln -s "$REPO/$rel" "$MW/$rel"; done
  cd "$MW" || { echo "MOBILE: pending worktree failed"; return; }
  say "merging $BASE_BRANCH ${SHA:0:12} into $MB"
  if ! g merge -q --no-ff -m "Merge $BASE_BRANCH ${SHA:0:12} into $MB" "$SHA" >/dev/null 2>&1; then
    local files; files=$(g diff --name-only --diff-filter=U | head -6 | paste -sd, -)
    g merge --abort >/dev/null 2>&1
    echo "MOBILE: pending merge conflict in ${files:-unknown files}"; return
  fi
  say "running tests on the merged $MB tree"
  "$TOOLS/check.sh" >"$TOOLS/state/ship-$JOBID.mobile-tests.log" 2>&1 || { echo "MOBILE: pending tests failed on $MB (see ship-$JOBID.mobile-tests.log)"; return; }
  local MSHA; MSHA=$(g rev-parse HEAD)
  say "pushing $MB"
  g push -q origin "HEAD:refs/heads/$MB" 2>/dev/null || { echo "MOBILE: pending $MB moved while testing"; return; }
  say "deploying mobile ${MSHA:0:12}"
  local MLOG="$TOOLS/state/ship-$JOBID.mobile-deploy.log" MRC
  if [ -n "${MOBILE_DEPLOY_CMD:-}" ]; then
    # test hook only (config.mobileDeployCmd): never set in production
    bash -c "$MOBILE_DEPLOY_CMD" deploy-mobile "$MSHA" >"$MLOG" 2>&1; MRC=$?
  else
    # deploy-mobile.sh runs from the merged mobile tree; it builds from the committed revision and never touches the PC server.
    bash "$MW/${MOBILE_DEPLOY_SCRIPT:-server/death-muffin/deploy-mobile.sh}" "$MSHA" >"$MLOG" 2>&1; MRC=$?
  fi
  [ $MRC -eq 0 ] || { tail -8 "$MLOG"; echo "MOBILE: pending mobile deploy failed after $MB was updated to ${MSHA:0:12}; re-run deploy-mobile.sh"; return; }
  echo "MOBILE: live ${MSHA:0:12}"
}
( mobile_step ) 2>&1 || true
cd "$SW" 2>/dev/null || true
mobile_cleanup
exit 0
