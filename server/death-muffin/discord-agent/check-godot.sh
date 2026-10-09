#!/usr/bin/env bash
# Godot-mode counterpart of check.sh: the agent's only way to run the Godot client's tests, and what the runner / ship.sh run before a
# proposal and before a deploy. Same sandbox as check.sh (sandbox-lib.sh): fresh user/network/mount namespaces, no network (loopback only), the WHOLE
# filesystem read-only (Godot binary, node_modules, the repo's .git stay readable), a private /tmp, only the worktree writable. HOME and the XDG dirs are a fresh temp dir, so Godot's
# user:// (saves, settings) can never touch the real home. Hard limit 85 minutes for the whole run (the full suite outgrew 40 min on 2026-10-09).
# Inside: gen-fixtures.sh (the golden fixtures are gitignored and are generated deterministically from the frozen TS game; node_modules is
# symlinked into the worktree by the runner), then tools/godot/run-all-tests.sh (one line per suite). The generator also rewrites the COMMITTED
# godot/data/loot/content.json and .git is read-only, so that file is snapshotted first and put back afterwards: the tests run against the
# version the branch actually commits. Prints per-suite lines and a final "GODOT TESTS: ..." line; exit 1 if any suite or step fails.
# Run from the worktree root (the agent's cwd). Env: GODOT (default /home/ubuntu/tools/godot/godot).
set -uo pipefail
TOP=$(git rev-parse --show-toplevel) || exit 2
NM=$(readlink -f "$TOP/node_modules" 2>/dev/null || true)
[ -n "$NM" ] && { mkdir -p "$NM/.vite" 2>/dev/null || true; }   # vitest keeps its results cache here; the sandbox puts a scratch tmpfs over it
# A change that only touches Markdown files cannot affect the game: skip the suites (owner 2026-10-09: a docs-only audit branch timed
# out the 40-min suite three times and never got proposed). Compares the working tree (committed + uncommitted + untracked) with
# where the branch left the base branch; any other file, or a base that cannot be found, runs the full suites as before.
BASE_REF="origin/${BASE_BRANCH:-godot-next}"
if MB=$(git -C "$TOP" merge-base HEAD "$BASE_REF" 2>/dev/null); then
  CHANGED=$( { git -C "$TOP" diff --name-only "$MB"; git -C "$TOP" ls-files --others --exclude-standard; } | sort -u | grep -v '^node_modules$')
  if [ -n "$CHANGED" ] && ! grep -qvE '\.md$' <<<"$CHANGED"; then
    echo "$CHANGED" | sed 's/^/  docs: /'
    echo "GODOT TESTS: skipped, docs-only change ($(wc -l <<<"$CHANGED") Markdown files)"; exit 0
  fi
fi
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
export TOP NM GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
export DM_PAYLOAD='
  set -uo pipefail
  SCR=$(mktemp -d /tmp/dmgodot.XXXXXX)    # inside the private /tmp: gone when the sandbox exits
  export HOME="$SCR/home" XDG_DATA_HOME="$SCR/data" XDG_CONFIG_HOME="$SCR/config" XDG_CACHE_HOME="$SCR/cache"
  mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
  cd "$TOP"
  LOOT=godot/data/loot/content.json
  if [ -f "$LOOT" ]; then cp -p "$LOOT" "$SCR/content.json.snap"; fi
  restore() { if [ -f "$SCR/content.json.snap" ]; then cp -p "$SCR/content.json.snap" "$LOOT"; fi; }
  trap restore EXIT
  echo "== generating golden fixtures"
  if ! bash tools/godot/gen-fixtures.sh > "$SCR/gen.log" 2>&1; then tail -30 "$SCR/gen.log"; restore; echo "GODOT TESTS: fixture generation FAILED"; exit 1; fi
  restore
  echo "== running Godot test suites"
  bash tools/godot/run-all-tests.sh > "$SCR/suites.log" 2>&1; rc=$?
  cat "$SCR/suites.log"
  total=$(grep -cE " exit=[0-9]+" "$SCR/suites.log" || true)
  bad=$(grep -cE " exit=[1-9][0-9]*" "$SCR/suites.log" || true)
  if [ "$total" -eq 0 ]; then echo "GODOT TESTS: no suites ran"; exit 1; fi
  if [ "$rc" -ne 0 ] || [ "$bad" -gt 0 ]; then echo "GODOT TESTS: $total suites, $((total - bad)) passed, $bad FAILED"; exit 1; fi
  echo "GODOT TESTS: $total suites, $total passed, 0 failed"
'   # the sandboxed work; run by dm_sandbox_run inside the nested namespace (sandbox-lib.sh)
timeout -k 30 5100 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
rc=$?
if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then echo "GODOT TESTS: timed out after 85 minutes"; fi
exit $rc
