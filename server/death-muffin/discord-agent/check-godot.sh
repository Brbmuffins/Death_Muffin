#!/usr/bin/env bash
# Godot-mode counterpart of check.sh: the agent's only way to run the Godot client's tests, and what the runner / ship.sh run before a
# proposal and before a deploy. Same sandbox as check.sh (sandbox-lib.sh): fresh user/network/mount namespaces, no network (loopback only), the WHOLE
# filesystem read-only (Godot binary, node_modules, the repo's .git stay readable), a private /tmp, only the worktree writable. HOME and the XDG dirs are a fresh temp dir, so Godot's
# user:// (saves, settings) can never touch the real home. Hard limit 85 minutes for the whole run (the full suite outgrew 40 min on 2026-10-09).
# Inside: the repo hygiene check (tools/hygiene/check.mjs = npm run hygiene, also on docs-only changes), then tools/godot/run-all-tests.sh (one line per suite) against the committed golden fixtures. An older branch that still has
# tools/godot/gen-fixtures.sh runs it first (it rewrites godot/data/loot/content.json, which is snapshotted and put back). Prints per-suite lines and a final "GODOT TESTS: ..." line; exit 1 if any suite or step fails.
# Two modes. QUICK (default; the agent in-turn and the runner before a proposal): hygiene + only the suites the change can affect
# (tools/godot/affected-suites.mjs: changed suites, suites referencing a changed file, a small smoke set; ALL when the change is too central or too wide),
# run through `run-all-tests.sh --only`. FULL (`--full`; ship.sh before publishing): hygiene + every suite, about 9 minutes. Summary line:
# "GODOT TESTS: quick (14 suites) — 14 passed" / "GODOT TESTS: full (101 suites) — 101 passed" (", N FAILED" appended on failure).
# Run from the worktree root (the agent's cwd). Env: GODOT (default /home/ubuntu/tools/godot/godot), DM_TEST_JOBS (optional: passed as --jobs N).
set -uo pipefail
MODE=quick
for a in "$@"; do case "$a" in --full) MODE=full;; --quick) MODE=quick;; *) echo "usage: check-godot.sh [--quick|--full]" >&2; exit 2;; esac; done
export MODE
TOP=$(git rev-parse --show-toplevel) || exit 2
NM=$(readlink -f "$TOP/node_modules" 2>/dev/null || true)
[ -n "$NM" ] && { mkdir -p "$NM/.vite" 2>/dev/null || true; }   # vitest keeps its results cache here; the sandbox puts a scratch tmpfs over it
# A change that only touches Markdown files cannot affect the game: skip the suites (owner 2026-10-09: a docs-only audit branch timed
# out the 40-min suite three times and never got proposed), but still run the hygiene check (broken links and stale paths live in docs).
# Compares the working tree (committed + uncommitted + untracked) with where the branch left the base branch; any other file, or a base
# that cannot be found, runs the full suites.
BASE_REF="origin/${BASE_BRANCH:-main}"
DOCS_ONLY=
if MB=$(git -C "$TOP" merge-base HEAD "$BASE_REF" 2>/dev/null); then
  CHANGED=$( { git -C "$TOP" diff --name-only "$MB"; git -C "$TOP" ls-files --others --exclude-standard; } | sort -u | grep -v '^node_modules$')
  if [ -n "$CHANGED" ] && ! grep -qvE '\.md$' <<<"$CHANGED"; then
    echo "$CHANGED" | sed 's/^/  docs: /'
    DOCS_ONLY=$(wc -l <<<"$CHANGED")
  fi
fi
export DOCS_ONLY
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
export TOP NM GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
export DM_PAYLOAD='
  set -uo pipefail
  SCR=$(mktemp -d /tmp/dmgodot.XXXXXX)    # inside the private /tmp: gone when the sandbox exits
  export HOME="$SCR/home" XDG_DATA_HOME="$SCR/data" XDG_CONFIG_HOME="$SCR/config" XDG_CACHE_HOME="$SCR/cache"
  mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
  cd "$TOP"
  # Repo hygiene (the same check CI runs first): stale doc links/paths, retired terms, big files. Inside the sandbox: the worktree is agent-written.
  # Skipped only on old revisions that predate it.
  if [ -f tools/hygiene/check.mjs ]; then echo "== repo hygiene"
    if ! node tools/hygiene/check.mjs > "$SCR/hygiene.log" 2>&1; then cat "$SCR/hygiene.log"; echo "GODOT TESTS: repo hygiene FAILED (npm run hygiene)"; exit 1; fi
    cat "$SCR/hygiene.log"; fi
  if [ -n "$DOCS_ONLY" ]; then echo "GODOT TESTS: skipped, docs-only change ($DOCS_ONLY Markdown files)"; exit 0; fi
  LOOT=godot/data/loot/content.json
  if [ -f "$LOOT" ]; then cp -p "$LOOT" "$SCR/content.json.snap"; fi
  restore() { if [ -f "$SCR/content.json.snap" ]; then cp -p "$SCR/content.json.snap" "$LOOT"; fi; }
  trap restore EXIT
  # The golden fixtures are committed since 2026-10-09 (their TS generator left with archive/legacy-web:src/); older branches still generate them.
  if [ -f tools/godot/gen-fixtures.sh ]; then echo "== generating golden fixtures"
  if ! bash tools/godot/gen-fixtures.sh > "$SCR/gen.log" 2>&1; then tail -30 "$SCR/gen.log"; restore; echo "GODOT TESTS: fixture generation FAILED"; exit 1; fi
  restore; fi
  RUNNER=tools/godot/run-all-tests.sh
  ARGS=(); LABEL="$MODE"; NOTE=""
  if [ "$MODE" = quick ]; then
    # Which suites does this change affect? A branch without the selector, or a runner without --only, runs everything.
    if [ -f tools/godot/affected-suites.mjs ] && grep -q -- "--only" "$RUNNER"; then
      SEL=$(node tools/godot/affected-suites.mjs --explain 2> "$SCR/sel.err"); SRC=$?
      cat "$SCR/sel.err"
      if [ "$SRC" -ne 0 ]; then echo "affected-suites failed, running every suite"; SEL=ALL; fi
    else SEL=ALL; echo "no suite selector on this revision, running every suite"; fi
    if [ "$SEL" = ALL ]; then NOTE=", targeting fell back to all"
    elif [ -z "$SEL" ]; then echo "GODOT TESTS: quick (0 suites) — nothing to run for this change"; exit 0
    else ARGS=(--only "$(echo "$SEL" | paste -sd, -)"); echo "suites: $(echo "$SEL" | paste -sd" " -)"; fi
  fi
  [ -n "${DM_TEST_JOBS:-}" ] && ARGS+=(--jobs "$DM_TEST_JOBS")
  echo "== running Godot test suites ($MODE)"
  # Progress for the thread: "<done> <total>" suites in .dm-check-progress (git-ignored, removed when the run ends). Same file list as run-all-tests.sh.
  if [ "${#ARGS[@]}" -gt 0 ] && bash "$RUNNER" "${ARGS[@]}" --list > "$SCR/list.txt" 2>/dev/null; then total=$(grep -c . "$SCR/list.txt" || true)
  else total=$(for d in godot/tests/*/; do for r in "$d"run.gd "$d"adapter_run.gd "$d"*_run.gd; do [ -f "$r" ] && echo "$r"; done; done | sort -u | wc -l); fi
  [ "$total" -gt 0 ] || total=0
  trap "restore; rm -f .dm-check-progress" EXIT
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
timeout -k 30 5100 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
rc=$?
if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then echo "GODOT TESTS: timed out after 85 minutes"; fi
exit $rc
