#!/usr/bin/env bash
# The bug-report agent's only way to run code: the Godot client's tests (godot-next). Copied from the Discord agent's check-godot.sh.
# Runs in fresh user/network/mount namespaces (sandbox-lib.sh, installed beside this script, outside every worktree): no network (loopback
# only), the WHOLE filesystem read-only (Godot binary, node_modules and the repo's .git stay readable), a private /tmp, only the worktree
# writable. HOME and the XDG dirs are a fresh temp dir, so Godot's user:// (saves, settings) never touches the real home. Hard limit 40 min.
# Inside: tools/godot/gen-fixtures.sh (golden fixtures are gitignored, generated from the frozen TS game via the node_modules symlink the runner
# makes), then tools/godot/run-all-tests.sh (godot --import, then every suite under godot/tests/, one line per suite). The generator also
# rewrites the COMMITTED godot/data/loot/content.json and .git is read-only, so that file is snapshotted and restored. Prints per-suite lines and
# a final "GODOT TESTS: ..." line; exit 1 if any suite or step fails. Takes 10 to 20 minutes; run it in the foreground, one at a time.
# Run from the worktree root (the agent's cwd). Env: GODOT (default /home/ubuntu/tools/godot/godot).
set -uo pipefail
TOP=$(git rev-parse --show-toplevel) || exit 2
NM=$(readlink -f "$TOP/node_modules" 2>/dev/null || true)
[ -n "$NM" ] && { mkdir -p "$NM/.vite" 2>/dev/null || true; }   # vitest keeps its results cache here; the sandbox puts a scratch tmpfs over it
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
timeout -k 30 2400 nice -n 10 unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
rc=$?
if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then echo "GODOT TESTS: timed out after 40 minutes"; fi
exit $rc
