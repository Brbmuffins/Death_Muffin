#!/usr/bin/env bash
# Runner-only (never in the agent's allowedTools, and the agent has no shell to reach it): generate ONE approved model.
#   art-run.sh <id>        run from the job's worktree
# Env (set by the runner for this one child, never written anywhere): TRIPO_API_KEY, GEMINI_API_KEY, DM_ART_TOOLS (trusted copies of tools/ai/*.mjs, installed
# outside every worktree), DM_ART_LOCK (flock file: one Tripo run at a time, across runner restarts too).
# The specs it runs were validated and rewritten by the runner from its own stored copy right before this starts. It never runs a tool from the worktree:
# the agent can edit those, and these processes hold the keys. Order: lock -> read the Tripo balance (refuse to spend blind) -> Gemini concept ->
# Tripo (resumable; a rerun never pays twice) -> balance again. The balance lines are printed even when a step fails, so the runner can ledger the real spend.
set -uo pipefail
ID=${1:-}
[[ "$ID" =~ ^[a-z0-9_]{3,40}$ ]] || { echo "RESULT: bad-id"; exit 2; }
TOP=$(pwd -P)
ART=${DM_ART_TOOLS:-}; LOCK=${DM_ART_LOCK:-}
[ -n "$ART" ] && [ -n "$LOCK" ] || { echo "RESULT: no-config"; exit 2; }
for t in common gemini tripo; do [ -f "$ART/tools/ai/$t.mjs" ] || { echo "RESULT: no-tools"; exit 2; }; done
[ -n "${TRIPO_API_KEY:-}" ] && [ -n "${GEMINI_API_KEY:-}" ] || { echo "RESULT: no-keys"; exit 2; }
[ -f "art-manifest/gemini-jobs/$ID.json" ] && [ -f "art-manifest/tripo-specs/$ID.json" ] || { echo "RESULT: no-specs"; exit 2; }
exec 9>"$LOCK" || { echo "RESULT: no-lock"; exit 2; }
flock -w "${DM_ART_LOCK_WAIT:-1800}" 9 || { echo "RESULT: busy"; exit 3; }
export DM_ART_ROOT="$TOP"
bal() { node "$ART/tools/ai/tripo.mjs" balance 2>&1 | sed -n 's/.*balance:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1; }
B0=$(bal)
echo "BALANCE_BEFORE: ${B0:-unknown}"
[ -n "$B0" ] || { echo "RESULT: no-balance"; exit 6; }
after() { B1=$(bal); echo "BALANCE_AFTER: ${B1:-unknown}"; }
trap after EXIT
node "$ART/tools/ai/gemini.mjs" "art-manifest/gemini-jobs/$ID.json" 2>&1
[ -s "art-src/concepts/$ID.png" ] || { echo "RESULT: no-concept"; exit 4; }
node "$ART/tools/ai/tripo.mjs" run "art-manifest/tripo-specs/$ID.json" --yes 2>&1
rc=$?
[ $rc -eq 0 ] || { echo "RESULT: tripo-failed $rc"; exit 5; }
echo "RESULT: ok"
