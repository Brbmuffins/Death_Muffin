#!/usr/bin/env bash
# The bug-report agent's only way to run code: typecheck + client tests + server tests. Runs in fresh user/network/mount
# namespaces: no network, and everything the agent must not be able to change (the WHOLE filesystem: home, the repo's .git, the agent's own
# tooling, /var/www, /opt, /game, the live runtime; see sandbox-lib.sh) is remounted read-only, so test code it writes cannot phone out or plant anything.
# Run from the worktree root (the agent's cwd).
set -euo pipefail
TOP=$(git rev-parse --show-toplevel)
COMMON=$(cd "$TOP" && git rev-parse --path-format=absolute --git-common-dir)
export TOP COMMON
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
export DM_PAYLOAD='
  set -euo pipefail
  cd "$TOP"
  npx tsc --noEmit -p .
  npx vitest run --reporter=dot --no-cache
  npm run -s test:server > /tmp/bug-agent-server-tests.$$ 2>&1 || { tail -40 /tmp/bug-agent-server-tests.$$; exit 1; }
  grep -E "^# (tests|pass|fail)" /tmp/bug-agent-server-tests.$$
'   # the sandboxed work; run by dm_sandbox_run inside the nested namespace (sandbox-lib.sh)
[ -n "${NM:-}" ] && { mkdir -p "$NM/.vite" 2>/dev/null || true; }   # the sandbox mounts a scratch tmpfs over it
exec unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
