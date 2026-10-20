#!/usr/bin/env bash
# Rebuilds the files the game derives from its sources, so a change commits them with the edit that needs them (DECISIONS B65):
#   node tools/generate-armor-assets.mjs        the armor and legendary sets' client data copies, the content manifest, the item icons, the new migration
#   npm run build:server-rules                  server/rules/*.ts -> the backend's *-rules.cjs bundles
#   UPDATE_LOOT_PARITY=1 vitest run server/rules/gameplay/__tests__/    the loot rules' tests, rewriting the recorded answers the Godot suite rules_loot replays
# The Discord agent's one command for generated files (PROMPT-godot.md); also fine by hand. Run from the worktree root. The same sandbox as check-godot.sh
# (sandbox-lib.sh): no network, the whole filesystem read-only but the worktree, a private /tmp and HOME, no keys. Every step runs even when one before it
# failed; the end lists what changed (git status). Exit 1 when a step failed. CI checks that all of it is current, so a stale file never ships.
set -euo pipefail
TOP=$(git rev-parse --show-toplevel)
NM=$(readlink -f "$TOP/node_modules" 2>/dev/null || true)
[ -n "$NM" ] && { mkdir -p "$NM/.vite" 2>/dev/null || true; }   # vitest keeps its results cache here; the sandbox puts a scratch tmpfs over it
export TOP NM
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
export DM_PAYLOAD='
  set -uo pipefail
  SCR=$(mktemp -d /tmp/dmregen.XXXXXX)    # inside the private /tmp: gone when the sandbox exits
  export HOME="$SCR/home" XDG_CACHE_HOME="$SCR/cache" npm_config_cache="$SCR/npm"; mkdir -p "$HOME" "$XDG_CACHE_HOME"
  cd "$TOP"; rc=0
  step() { local name="$1"; shift; echo "== $name"; if timeout 600 "$@" >"$SCR/step.log" 2>&1; then tail -n 5 "$SCR/step.log"; else rc=1; tail -n 25 "$SCR/step.log"; echo "FAILED: $name"; fi; }
  step "armor sets (node tools/generate-armor-assets.mjs)" node tools/generate-armor-assets.mjs
  step "server rules (npm run build:server-rules)" npm run -s build:server-rules
  step "loot rules tests, recorded answers rewritten (UPDATE_LOOT_PARITY=1 vitest run server/rules/gameplay/__tests__/)" env UPDATE_LOOT_PARITY=1 node_modules/.bin/vitest run --reporter=dot server/rules/gameplay/__tests__/
  exit $rc
'   # the sandboxed work; run by dm_sandbox_run inside the nested namespace (sandbox-lib.sh)
rc=0
unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run' || rc=$?
echo "== changed files (commit what your change needs; .import files for new icons come from check-godot.sh --rerun code_load):"
git -C "$TOP" --no-optional-locks status --porcelain
exit "$rc"
