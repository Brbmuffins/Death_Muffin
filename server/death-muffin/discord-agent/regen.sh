#!/usr/bin/env bash
# Regenerates the files that are DERIVED from shared game data, so a data change can be committed together with its generated
# server bundles: build:server-rules (server/**/*-rules.cjs). Same sandbox as check.sh: fresh user/network/mount namespaces, loopback only, the whole filesystem read-only (sandbox-lib.sh), the worktree
# (and only it) writable. Run from the worktree root. Prints what changed (git status) afterwards.
set -euo pipefail
TOP=$(git rev-parse --show-toplevel)
export TOP
export DM_SANDBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox-lib.sh"
export DM_PAYLOAD='
  set -euo pipefail
  cd "$TOP"
  npm run -s build:server-rules
'   # the sandboxed work; run by dm_sandbox_run inside the nested namespace (sandbox-lib.sh)
unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'
echo "== regenerated; changed files:"
git -C "$TOP" --no-optional-locks status --porcelain
