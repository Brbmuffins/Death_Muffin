#!/usr/bin/env bash
# The deploy helper (NOT the AI): runs only after an approver's check, from the runner. All inputs are environment variables set by
# the runner. Takes the global deploy lock (shared with deploy-release.sh), merges the branch onto the current base branch (BASE_BRANCH, default
# main), re-gates and re-tests the merged tree, pushes it, runs the deploy, and prints machine-readable lines:
#   RESULT: <live|live-already|merged|docs|conflict|head-moved|gate|sync-failed|tests-failed|master-moved|backup-failed|deploy-failed|lock-timeout> ...      ("master-moved" = BASE_BRANCH moved)
# DEFER_PUBLISH=1 (godot; the runner sets it when another approved ship waits): merge, gate, test and push, but no client publish ("RESULT: merged
# <sha>"); the next ship's client carries it (one publish and one notice for a backlog). The runner publishes it alone if nothing else ships.
# A godot change that touches only documents (Markdown files, docs/) is pushed and stops there: no backend or lobby deploy, no client publish, no
# release notice ("RESULT: docs <sha>"; a roadmap line from Discord used to send every player an update notice).
# PUBLISH_ONLY=1 PUBLISH_SHA=<sha> (godot only; the retry after a failed client publish): no merge/tests/push. Publishes that already-tested, already-
# pushed commit with a fresh rollback, or prints "RESULT: live-already" when the live client already contains it (never publishes an older client).
# The Godot publish itself is tried up to 3 times (PUBLISH_RETRY_SLEEPS, default "30 90") before deploy-failed: one-off Godot import crashes heal by themselves.
# MODE=web (default): deploy-release.sh, then the best-effort mobile step. MODE=godot: check-godot.sh, and the Godot client is published with
# publish-godot-client.sh after a ROLLBACK.sh for the revision that is live now has been written (see the godot block below). No mobile step.
# CI_GATE=1 (godot; DECISIONS B59): GitHub CI is the test instead of check-godot.sh. The merged tree is CI's verdict on the proposal when it is the
# same files (for a draft, the run its push started); otherwise it is pushed as ship/<job> and CI tests it (CI_SCRIPT, default $TOOLS/ci.sh). The deploy lock is taken only after CI passed,
# so the wait never blocks another deploy, and the base branch must not have moved meanwhile ("RESULT: master-moved"). BATCH (with CI_GATE): more
# approved changes, one "<job> <branch> <head> <max tier>" per line, merged after this one, each gated by its own approver's tier; one CI run and one
# publish for all of them ("BATCH: <job>" for each one the push carried; "RESULT: conflict-batch|gate-batch <job> ..." when one of them stops it).
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

CI_GATE="${CI_GATE:-}"; [ "$MODE" = godot ] && [ -z "$PUBLISH_ONLY" ] || CI_GATE=""
take_lock() {
  exec 9>"$LOCK"
  say "waiting for the deploy lock"
  flock -w "${LOCK_WAIT:-1800}" 9 || { echo "RESULT: lock-timeout"; exit 3; }
  export DEPLOY_LOCK_HELD=1          # deploy-release.sh must not try to take the lock we already hold
}
[ -n "$CI_GATE" ] || take_lock     # with the CI gate: after CI passed (below)
drop_ship_branch() { [ -z "$CI_GATE" ] || g -C "$REPO" push -q origin --delete "ship/$JOBID" >/dev/null 2>&1 || true; }

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
# (The game's build products, the combat core, the import and the crowd's bakes, come with the check: check-godot.sh runs prep.sh.)

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

# the other approved changes of the batch, each merged and gated on its own diff with its own approver's tier
BATCHED=""
if [ -n "$CI_GATE" ] && [ -n "${BATCH:-}" ]; then
  while read -r BID BBR BHEAD BTIER; do
    [ -n "$BID" ] || continue
    [[ "$BID" =~ ^[A-Za-z0-9-]+$ && "$BBR" =~ ^[A-Za-z0-9._/-]+$ && "$BBR" != -* && "$BHEAD" =~ ^[0-9a-f]{40}$ && "$BTIER" =~ ^[a-z]+$ ]] || { echo "RESULT: bad-config batch entry"; exit 2; }
    BNOW=$(g -C "$REPO" rev-parse -q --verify "refs/heads/$BBR") || { echo "RESULT: head-moved $BID branch missing"; exit 5; }
    [ "$BNOW" = "$BHEAD" ] || { echo "RESULT: head-moved $BID $BNOW"; exit 5; }
    PREV=$(g rev-parse HEAD)
    say "merging $BBR ($BID) into the batch"
    if ! g merge -q --no-ff -m "Merge $BBR" "$BHEAD" >/dev/null 2>&1; then
      FILES=$(g diff --name-only --diff-filter=U | head -10 | paste -sd, -); g merge --abort >/dev/null 2>&1
      echo "RESULT: conflict-batch $BID ${FILES}"; exit 7
    fi
    BG=$(node "$TOOLS/runner/ship-gate.cjs" "$CONFIG" "$SW" "$PREV" "$BTIER" 2>&1) || { echo "$BG"; echo "RESULT: gate-batch $BID $(echo "$BG" | tail -1)"; exit 8; }
    BATCHED="$BATCHED $BID"
  done <<<"$BATCH"
  SHA=$(g rev-parse HEAD)
fi

if [ -n "$CI_GATE" ]; then
  CIS="${CI_SCRIPT:-$TOOLS/ci.sh}"; TL="$TOOLS/state/ship-$JOBID.tests.log"; : >"$TL"
  if [ -z "$BATCHED" ] && [ "$(g rev-parse HEAD^{tree})" = "$(g rev-parse "$EXPECT_HEAD^{tree}")" ]; then
    CIREV="$EXPECT_HEAD"; say "CI: the merged tree is exactly the proposal's"
  else
    CIREV="$SHA"; say "pushing the merged change for CI (ship/$JOBID)"
    g push -q -f origin "HEAD:refs/heads/ship/$JOBID" >/dev/null 2>&1 || { echo "RESULT: master-moved (ship/$JOBID could not be pushed)"; exit 10; }
  fi
  say "waiting for CI on ${CIREV:0:12}"
  CIOUT=$(bash "$CIS" wait "$CIREV" "${CI_WAIT_MIN:-50}" 2>&1); CIRC=$?
  echo "CI: $(echo "$CIOUT" | tail -1)" | tee -a "$TL"
  if [ $CIRC -eq 1 ]; then
    FAILED=$(bash "$CIS" failed "$CIREV" 2>/dev/null | grep -E '^[A-Za-z0-9_/-]+$' | sort -u || true)
    # 1-3 failing suites get one re-run here (GitHub's machines are shared too), as the runner does before a proposal; anything else stops the ship
    if [ -n "$FAILED" ] && [ "$(echo "$FAILED" | grep -c .)" -le 3 ] && { echo "== re-running $(echo $FAILED) here"; "$TOOLS/check-godot.sh" --rerun "$(echo "$FAILED" | paste -sd, -)"; } >>"$TL" 2>&1; then
      echo "tests: $(echo $FAILED) failed on CI and passed on a re-run here"
    else
      for f in $FAILED; do echo "$f (CI) exit=1"; done
      drop_ship_branch; echo "RESULT: tests-failed CI on ${CIREV:0:12}: $(echo "$CIOUT" | tail -1)"; exit 9
    fi
  elif [ $CIRC -ne 0 ]; then drop_ship_branch; echo "RESULT: ci-unavailable $(echo "$CIOUT" | tail -1)"; exit 9; fi
  take_lock
  g -C "$REPO" fetch -q origin || { drop_ship_branch; echo "RESULT: fetch-failed"; exit 4; }
  [ "$(g -C "$REPO" rev-parse "origin/$BASE_BRANCH")" = "$OLD" ] || { drop_ship_branch; echo "RESULT: master-moved"; exit 10; }
else
say "running tests on the merged tree"
# Dev build (owner, 2026-10-10: tests were costing too much time): the ship runs the QUICK check (the suites the change can affect plus a smoke
# set) on the merged tree; only a sensitive-tier change (server, net, login/session/save, scripts) gets the FULL suite.
CHECK="$TOOLS/check.sh"; CHECK_ARGS=(); [ "$MODE" = godot ] && { CHECK="$TOOLS/check-godot.sh"; case "$GATE" in *"GATE: ok (sensitive)"*) CHECK_ARGS=(--full);; esac; }
# Nothing new to test: the merged tree is exactly the proposal's (main did not move since), and that passed the same quick check. A sensitive
# change still runs its full suite, and so does a draft (PROPOSAL_UNTESTED: proposed with the CI gate on, which never tested it).
if [ "$MODE" = godot ] && [ ${#CHECK_ARGS[@]} -eq 0 ] && [ -z "${PROPOSAL_UNTESTED:-}" ] && [ "$(g rev-parse HEAD^{tree})" = "$(g rev-parse "$EXPECT_HEAD^{tree}")" ]; then
  echo "tests: skipped, the merged tree is exactly the proposal's, which passed its check" | tee "$TOOLS/state/ship-$JOBID.tests.log"
elif ! "$CHECK" "${CHECK_ARGS[@]}" >"$TOOLS/state/ship-$JOBID.tests.log" 2>&1; then
  # godot: 1-3 failing suites (and nothing failing outside the suites) get one re-run of just those, as the runner does before a proposal
  TL="$TOOLS/state/ship-$JOBID.tests.log"; FLAKY=""
  if [ "$MODE" = godot ] && ! grep -qE 'GODOT TESTS: (repo hygiene|fixture generation|timed out|.*no suites ran)| exit=124 ' "$TL"; then
    FLAKY=$(grep -oE '^[A-Za-z0-9_/-]+ +[^ ]+ +exit=[1-9][0-9]*' "$TL" | awk '{print $1}' | sort -u)
    [ "$(echo "$FLAKY" | grep -c .)" -le 3 ] || FLAKY=""
    # every failure must be one of these lines (the summary's "N FAILED"), or the others' re-run would pass the ship with it still failing
    NF=$(grep -oE 'GODOT TESTS: .* ([0-9]+) FAILED' "$TL" | tail -1 | grep -oE '[0-9]+ FAILED' | grep -oE '[0-9]+')
    [ -z "$NF" ] || [ "$NF" -eq "$(echo "$FLAKY" | grep -c .)" ] || FLAKY=""
  fi
  if [ -n "$FLAKY" ] && { echo "== re-running $(echo $FLAKY)"; "$CHECK" --rerun "$(echo "$FLAKY" | paste -sd, -)"; } >>"$TL" 2>&1; then
    echo "tests: $(echo $FLAKY) failed once and passed on a re-run"
  else grep -vE ' exit=0 ' "$TL" | tail -25; echo "RESULT: tests-failed"; exit 9; fi
fi
fi   # (end of the local check; CI_GATE uses CI's verdict instead)
fi   # (end of the normal ship's merge/gate/tests; PUBLISH_ONLY skips them: that commit was tested and pushed by the ship that failed to publish)

# ---- godot: get the rollback ready BEFORE anything is pushed or published (a failure here leaves everything as it was) ----
# The Godot client is published by publish-godot-client.sh from the base branch (main), so the copy that is used
# for BOTH the new publish and the rollback is taken fresh from origin/<base branch> now and kept in the backup folder. ROLLBACK.sh republishes the
# revision that is live right now (the `rev` in the client manifest). No manifest = nothing is live yet = nothing to roll back to ("Rollback: none").
BK=""
DEFER="${DEFER_PUBLISH:-}"; [ -n "$PUBLISH_ONLY" ] && DEFER=""
DOCS_ONLY=""
if [ "$MODE" = godot ] && [ -z "$PUBLISH_ONLY" ]; then
  CHANGED=$(g diff --name-only "$OLD" "$SHA")
  OTHER=$(printf '%s\n' "$CHANGED" | grep -vE '(\.md$|^docs/)')   # grep reads the whole list: no early exit for pipefail to misread
  [ -n "$CHANGED" ] && [ -z "$OTHER" ] && DOCS_ONLY=1
fi
if [ "$MODE" = godot ] && [ -z "$DEFER" ] && [ -z "$DOCS_ONLY" ]; then
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
if ! g push -q origin "HEAD:refs/heads/$BASE_BRANCH" 2>/tmp/ship-push.$$; then tail -3 /tmp/ship-push.$$; rm -f /tmp/ship-push.$$; [ -n "$BK" ] && abandon_backup; drop_ship_branch; echo "RESULT: master-moved"; exit 10; fi
rm -f /tmp/ship-push.$$
drop_ship_branch
for b in $BATCHED; do echo "BATCH: $b"; done
fi
if [ -n "$DOCS_ONLY" ]; then echo "RESULT: docs ${SHA:0:12}"; exit 0; fi   # documents only: nothing to deploy or publish
if [ "$MODE" = godot ] && [ -n "$DEFER" ]; then echo "RESULT: merged ${SHA:0:12}"; exit 0; fi   # the next ship (or the runner) publishes it

say "deploying ${SHA:0:12}"
LOG="$TOOLS/state/ship-$JOBID.deploy.log"
if [ "$MODE" = godot ]; then
  # The backend first, when the server files this revision installs differ from the installed ones (2026-10-11: two Godot ships published a
  # client that called a route the live server did not have yet). deploy-release.sh --if-changed is a no-op otherwise; it runs its own server
  # tests, DB backup and ROLLBACK.sh, and stays quiet (the client publish below announces the release). Deferred merges get it from the ship that
  # publishes them. Test runs (DEPLOY_CMD set) never reach the real script: BACKEND_DEPLOY_CMD stands in for it, or the step is skipped.
  BRB=""
  if [ -n "${BACKEND_DEPLOY_CMD:-}" ] || [ -z "${DEPLOY_CMD:-}" ]; then
    say "checking the backend for ${SHA:0:12}"
    BLOG="$TOOLS/state/ship-$JOBID.backend.log"
    BSW="$WT_ROOT/backend-$JOBID"
    if [ -n "${BACKEND_DEPLOY_CMD:-}" ]; then bash -c "$BACKEND_DEPLOY_CMD" deploy-backend --if-changed "$SHA" $MIGRATIONS >"$BLOG" 2>&1; BDRC=$?
    else
      # the deploy script of the revision being shipped (PUBLISH_ONLY has no merged worktree of its own)
      [ -n "$PUBLISH_ONLY" ] && { g -C "$REPO" worktree add -q --detach "$BSW" "$SHA" >/dev/null 2>&1 || { echo "RESULT: deploy-failed ${SHA:0:12} backend worktree"; exit 11; }; }
      BDIR="$SW"; [ -n "$PUBLISH_ONLY" ] && BDIR="$BSW"
      # shellcheck disable=SC2086
      NO_ANNOUNCE=1 bash "$BDIR/server/death-muffin/deploy-release.sh" --if-changed "$SHA" $MIGRATIONS >"$BLOG" 2>&1; BDRC=$?
      [ -n "$PUBLISH_ONLY" ] && { g -C "$REPO" worktree remove --force "$BSW" >/dev/null 2>&1; g -C "$REPO" worktree prune >/dev/null 2>&1; }
    fi
    if [ $BDRC -ne 0 ]; then tail -25 "$BLOG"; [ -n "$BK" ] && abandon_backup; echo "RESULT: deploy-failed ${SHA:0:12} backend (the client was not published)"; exit 11; fi
    BRB=$(grep -oE 'Rollback: [^ ]+ROLLBACK\.sh' "$BLOG" | tail -1 | sed 's/^Rollback: //')
    if [ -n "$BRB" ]; then
      echo "Backend: deployed ${SHA:0:12}, rollback $BRB"
      # one ROLLBACK.sh undoes the whole ship: the server code first, then the previous client
      [ -f "$BK/ROLLBACK.sh" ] && sed -i "s|^exec bash |bash $(printf %q "$BRB")\nexec bash |" "$BK/ROLLBACK.sh"
    else echo "Backend: unchanged"; fi
  fi
  # Then the lobby, when the lobby files this revision installs differ from the installed ones (publish-godot-client.sh refuses a client the
  # live lobby is behind). deploy-lobby.sh --if-changed is a no-op otherwise; it runs the lobby tests, backs up and writes a ROLLBACK.sh, and
  # waits up to LOBBY_WAIT_MIN minutes for running parties to end before restarting. Test runs use LOBBY_DEPLOY_CMD or skip it, like the backend.
  if [ -n "${LOBBY_DEPLOY_CMD:-}" ] || [ -z "${DEPLOY_CMD:-}" ]; then
    say "checking the lobby for ${SHA:0:12}"
    LLOG="$TOOLS/state/ship-$JOBID.lobby.log"
    if [ -n "${LOBBY_DEPLOY_CMD:-}" ]; then bash -c "$LOBBY_DEPLOY_CMD" deploy-lobby --if-changed "$SHA" >"$LLOG" 2>&1; LDRC=$?
    else
      LSCRIPT=$(mktemp)
      g -C "$REPO" show "$SHA:server/death-muffin/deploy-lobby.sh" >"$LSCRIPT" 2>/dev/null || { rm -f "$LSCRIPT"; [ -n "$BK" ] && abandon_backup; echo "RESULT: deploy-failed ${SHA:0:12} no deploy-lobby.sh"; exit 11; }
      REPO="$REPO" bash "$LSCRIPT" --if-changed --wait "${LOBBY_WAIT_MIN:-30}" "$SHA" >"$LLOG" 2>&1; LDRC=$?
      rm -f "$LSCRIPT"
    fi
    if [ $LDRC -ne 0 ]; then
      tail -15 "$LLOG"; [ -n "$BK" ] && abandon_backup
      [ $LDRC -eq 3 ] && { echo "RESULT: deploy-failed ${SHA:0:12} lobby busy (parties still running; the client was not published)"; exit 11; }
      echo "RESULT: deploy-failed ${SHA:0:12} lobby (the client was not published)"; exit 11
    fi
    LRB=$(grep -oE 'Rollback: [^ ]+ROLLBACK\.sh' "$LLOG" | tail -1 | sed 's/^Rollback: //')
    if [ -n "$LRB" ]; then
      echo "Lobby: deployed ${SHA:0:12}, rollback $LRB"
      [ -f "$BK/ROLLBACK.sh" ] && sed -i "s|^exec bash |bash $(printf %q "$LRB") --force\nexec bash |" "$BK/ROLLBACK.sh"
    else echo "Lobby: unchanged"; fi
  fi
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
