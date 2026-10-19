#!/usr/bin/env bash
# The team-files folder's clean-up rules, in one place for everything that fills it. Two kinds of build folder sit directly under the root, each with its own rule:
#
#   team-files-prune.sh <team-files root> [keep] [release-days]
#
#   <32 hex>          a preview build for a screenshots job (preview-godot.sh --team): the newest <keep> (default 6) by modification time stay, the rest go.
#   check-<24 hex>    a revision's builds for a team PC's checks (team-check.sh) or gate-<24 hex>, a build for the pre-release check (team-gate.sh): each removes its
#                     own folder when it ends, so only one a killed run left is here; removed once older than <release-days> (default 4) days, whatever else is in
#                     the root. release-<24 hex> and bench-<24 hex>, the names of the release checks' folders before B62, follow the same rule.
#
# tools/ (the team app's video encoder, teamapp/windows/JobPlan.cs Encoder) is never touched. Run by team-check.sh after each check and every night by the ops job death-muffin-team-prune (ops/README.md). Anything else in the root is left alone. Prints nothing; exit 2 for a missing, symlinked or unreadable root or a count that is not a number.
# preview-godot.sh --team still carries its own copy of the first rule (the same find line): it should call this script instead.
set -euo pipefail
ROOT="${1:-}"
KEEP="${2:-6}"
DAYS="${3:-4}"
[ -n "$ROOT" ] && [ -d "$ROOT" ] && [ ! -L "$ROOT" ] || { echo "team-files-prune: $ROOT is not a team-files folder" >&2; exit 2; }
[[ "$KEEP" =~ ^[0-9]+$ ]] && [[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "team-files-prune: keep and release-days must be numbers" >&2; exit 2; }
find "$ROOT" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9a-f]{32}' -printf '%T@ %p\n' | sort -rn | tail -n +"$((KEEP + 1))" | cut -d' ' -f2- | xargs -r -d '\n' rm -rf --
find "$ROOT" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/(release|bench|gate|check)-[0-9a-f]{24}' -mmin +"$((DAYS * 1440))" -printf '%p\n' | xargs -r -d '\n' rm -rf --
