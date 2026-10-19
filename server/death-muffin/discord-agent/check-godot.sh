#!/usr/bin/env bash
# Godot-mode counterpart of check.sh: the agent's only way to run the Godot client's tests, and what the runner / ship.sh run before a
# proposal and before a deploy. Same sandbox as check.sh (sandbox-lib.sh): fresh user/network/mount namespaces, no network (loopback only), the WHOLE
# filesystem read-only (Godot binary, node_modules, the repo's .git stay readable), a private /tmp, only the worktree writable. HOME and the XDG dirs are a fresh temp dir, so Godot's
# user:// (saves, settings) can never touch the real home. Hard limit 85 minutes for the whole run (the full suite outgrew 40 min on 2026-10-09).
# Inside: the repo hygiene check (tools/hygiene/check.mjs = npm run hygiene, also on docs-only changes), the model check on the models the change adds or edits
# (tools/assets/check-models.mjs), the game's build products (the combat core, the import, the crowd's bakes, the lobby's packages; tools/check/prep.sh: `--warm` of the base revision outside the sandbox fills the shared cache from approved code only, `--read-only` inside copies it in and builds only what the change touched),
# then tools/rebuild/run-client-tests.sh (one line per suite: the game's suites,
# client/tests). Prints per-suite lines and a final "GODOT TESTS: ..." line; exit 1 if any suite or step fails.
# Two modes. QUICK (default; the runner before a proposal): hygiene + only the suites the change can affect
# (tools/rebuild/affected-suites.mjs: changed suites, suites referencing a changed file, a small smoke set; ALL when the change is too central or too wide),
# run through `tools/rebuild/run-client-tests.sh --only` (side by side, 8 by default; DM_TEST_JOBS overrides). FULL (`--full`; ship.sh for a sensitive change): hygiene + every suite. Summary line:
# "GODOT TESTS: quick (14 suites) — 14 passed" / "GODOT TESTS: full (101 suites) — 101 passed" (", N FAILED" appended on failure).
# RERUN (`--rerun a,b`; the runner and ship.sh, once, for the few suites a check just failed; the agent, the only way it may run the check, for the
# suites it needs): hygiene + exactly those suites, one at a time. A suite that fails under load (another ship's client export) passes here and costs no
# agent turn; a real failure fails again. Names are suites of client/tests (`rites`, `next_front`, `relay/udp_run`): letters, digits, `_`, `-`, `/`.
# Run from the worktree root (the agent's cwd). Env: GODOT (default /home/ubuntu/tools/godot/godot), DM_TEST_JOBS (optional: passed as --jobs N), DM_BUILD_CACHE (prep.sh),
# DM_PREP (tests: a stand-in for prep.sh).
set -uo pipefail
MODE=quick
RERUN=""
while [ $# -gt 0 ]; do case "$1" in --full) MODE=full;; --quick) MODE=quick;;
  --rerun) [[ "${2:-}" =~ ^[A-Za-z0-9_/-]+(,[A-Za-z0-9_/-]+)*$ ]] || { echo "usage: check-godot.sh --rerun suite[,suite...]" >&2; exit 2; }; MODE=rerun; RERUN="$2"; shift;;
  *) echo "usage: check-godot.sh [--quick|--full|--rerun a,b]" >&2; exit 2;; esac; shift; done
export MODE RERUN
TOP=$(git rev-parse --show-toplevel) || exit 2
NM=$(readlink -f "$TOP/node_modules" 2>/dev/null || true)
[ -n "$NM" ] && { mkdir -p "$NM/.vite" 2>/dev/null || true; }   # vitest keeps its results cache here; the sandbox puts a scratch tmpfs over it
# A change that only touches Markdown files cannot affect the game: skip the suites (owner 2026-10-09: a docs-only audit branch timed
# out the 40-min suite three times and never got proposed), but still run the hygiene check (broken links and stale paths live in docs).
# Compares the working tree (committed + uncommitted + untracked) with where the branch left the base branch; any other file, or a base
# that cannot be found, runs the full suites.
BASE_REF="origin/${BASE_BRANCH:-main}"
DOCS_ONLY=
MB=$(git -C "$TOP" merge-base HEAD "$BASE_REF" 2>/dev/null) || MB=
if [ -n "$MB" ]; then
  CHANGED=$( { git -C "$TOP" diff --name-only "$MB"; git -C "$TOP" ls-files --others --exclude-standard; } | sort -u | grep -v '^node_modules$')
  if [ -n "$CHANGED" ] && ! grep -qvE '\.md$' <<<"$CHANGED"; then
    echo "$CHANGED" | sed 's/^/  docs: /'
    DOCS_ONLY=$(wc -l <<<"$CHANGED")
  fi
fi
export DOCS_ONLY MB
# The game's build products: the shared cache is filled outside the sandbox for the base revision (approved code: a job can never plant a
# library, an import or a bake that another job then loads); the copy, and whatever this change rebuilt, inside (prep.sh --read-only).
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DM_PREP="${DM_PREP:-$TOOLS/prep.sh}"
if [ -z "$DOCS_ONLY" ] && [ -n "$MB" ]; then
  if ! PREP=$(bash "$DM_PREP" --warm "$MB" "$TOP" 2>&1); then echo "$PREP" | tail -20; echo "GODOT TESTS: preparing the game FAILED (prep.sh --warm)"; exit 1; fi
  echo "$PREP" | tail -1
fi
export TOOLS
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
export TOP NM GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
export DM_PAYLOAD='
  set -uo pipefail
  SCR=$(mktemp -d /tmp/dmgodot.XXXXXX)    # inside the private /tmp: gone when the sandbox exits
  export SCR HOME="$SCR/home" XDG_DATA_HOME="$SCR/data" XDG_CONFIG_HOME="$SCR/config" XDG_CACHE_HOME="$SCR/cache"
  mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
  cd "$TOP"
  # Repo hygiene (the same check CI runs first): stale doc links/paths, retired terms, big files. Inside the sandbox: the worktree is agent-written.
  # Skipped only on old revisions that predate it.
  if [ -f tools/hygiene/check.mjs ]; then echo "== repo hygiene"
    if ! node tools/hygiene/check.mjs > "$SCR/hygiene.log" 2>&1; then cat "$SCR/hygiene.log"; echo "GODOT TESTS: repo hygiene FAILED (npm run hygiene)"; exit 1; fi
    cat "$SCR/hygiene.log"; fi
  if [ -n "$DOCS_ONLY" ]; then echo "GODOT TESTS: skipped, docs-only change ($DOCS_ONLY Markdown files)"; exit 0; fi
  # The models this change adds or edits (tools/assets/check-models.mjs, also in CI over every model): budget, one material, the shared
  # skeleton, the combat clips of a hero body. Skipped on old revisions that predate it, and when the base cannot be found.
  if [ -f tools/assets/check-models.mjs ] && [ -n "$MB" ]; then echo "== model check"
    if ! node tools/assets/check-models.mjs --changed "$MB" > "$SCR/models.log" 2>&1; then cat "$SCR/models.log"; echo "GODOT TESTS: model check FAILED (tools/assets/check-models.mjs)"; exit 1; fi
    cat "$SCR/models.log"; fi
  echo "== build products of the game"
  bash "$DM_PREP" --read-only "$TOP" || { echo "GODOT TESTS: preparing the game FAILED (prep.sh --read-only)"; exit 1; }
  RUNNER=tools/rebuild/run-client-tests.sh
  ARGS=(); LABEL="$MODE"; NOTE=""
  if [ "$MODE" = quick ]; then
    # Which suites does this change affect? A branch without the selector, or a runner without --only, runs everything.
    if [ -f tools/rebuild/affected-suites.mjs ]; then
      SEL=$(node tools/rebuild/affected-suites.mjs --explain 2> "$SCR/sel.err"); SRC=$?
      cat "$SCR/sel.err"
      if [ "$SRC" -ne 0 ]; then echo "affected-suites failed, running every suite"; SEL=ALL; fi
    else SEL=ALL; echo "no suite selector on this revision, running every suite"; fi
    if [ "$SEL" = ALL ]; then NOTE=", targeting fell back to all"
    elif [ -z "$SEL" ]; then echo "GODOT TESTS: quick (0 suites) — nothing to run for this change"; exit 0
    else ARGS=(--only "$(echo "$SEL" | paste -sd, -)"); echo "suites: $(echo "$SEL" | paste -sd" " -)"; fi
  elif [ "$MODE" = rerun ]; then ARGS=(--only "$RERUN" --jobs 1); echo "re-running: ${RERUN//,/ }"
  fi
  [ -n "${DM_TEST_JOBS:-}" ] && [ "$MODE" != rerun ] && ARGS+=(--jobs "$DM_TEST_JOBS")
  echo "== running the test suites of the game ($MODE)"
  # Progress for the thread: "<done> <total>" suites in .dm-check-progress (git-ignored, removed when the run ends), from the list of the runner.
  if bash "$RUNNER" "${ARGS[@]}" --list > "$SCR/list.txt" 2>/dev/null; then total=$(grep -c . "$SCR/list.txt" || true); else total=0; fi
  [ "$total" -gt 0 ] || total=0
  trap "rm -f .dm-check-progress" EXIT
  echo "0 $total" > .dm-check-progress
  bash "$RUNNER" "${ARGS[@]}" 2>&1 | { n=0; while IFS= read -r l; do printf "%s\n" "$l" >> "$SCR/suites.log"; case "$l" in *" exit="[0-9]*) n=$((n+1)); echo "$n $total" > .dm-check-progress;; esac; done; }
  rc=${PIPESTATUS[0]}
  rm -f .dm-check-progress
  cat "$SCR/suites.log"
  total=$(grep -cE " exit=[0-9]+" "$SCR/suites.log" || true)
  bad=$(grep -cE " exit=[1-9][0-9]*" "$SCR/suites.log" || true)
  if [ "$total" -eq 0 ]; then echo "GODOT TESTS: $MODE — no suites ran"; exit 1; fi
  if [ "$rc" -ne 0 ] || [ "$bad" -gt 0 ]; then echo "GODOT TESTS: $LABEL ($total suites$NOTE) — $((total - bad)) passed, $bad FAILED"; exit 1; fi
  echo "GODOT TESTS: $LABEL ($total suites$NOTE) — $total passed"
'   # the sandboxed work; run by dm_sandbox_run inside the nested namespace (sandbox-lib.sh)
# One Godot test run at a time on this VPS (owner, 2026-10-10: three jobs testing at once slowed each other down; one run gets every core).
# The slot is ~/death-muffin/test-slot.lock, shared by the Discord agent's jobs and the ship (install-runner.sh creates it); no file = no waiting.
SLOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-slot.lock"
if [ -f "$SLOT" ] && exec 7<"$SLOT"; then flock -n 7 || { echo "waiting for the test slot (another check is running)"; flock -w 3000 7 || echo "test slot still busy after 50 min; running anyway"; }; fi
timeout -k 30 5100 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
rc=$?
if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then echo "GODOT TESTS: timed out after 85 minutes"; fi
exit $rc
