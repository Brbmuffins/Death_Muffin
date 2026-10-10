#!/usr/bin/env bash
# Registers the repo's custom git merge drivers in this clone's .git/config (shared by every worktree of the clone).
# .gitattributes says which files use them; without this step git falls back to a normal text merge.
set -euo pipefail
cd "$(dirname "$0")/../.."
git config merge.patchnotes.name "PATCH_NOTES.json entries (tools/git/merge-patch-notes.mjs)"
# Run from the worktree being merged; a checkout that predates the driver has no script and keeps the normal conflict.
git config merge.patchnotes.driver 'f=tools/git/merge-patch-notes.mjs; [ -f "$f" ] && node "$f" %O %A %B'
echo "merge drivers installed: $(git config --get merge.patchnotes.driver)"
