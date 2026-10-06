#!/usr/bin/env bash
# Run every Godot port test suite headless and print one result line per suite. Exit non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")/../.."
G="${GODOT:-/home/ubuntu/tools/godot/godot}"
"$G" --headless --path godot --import >/dev/null 2>&1
# user:// (progress / guidance / loadout / settings files keyed by character id) is shared by every Godot run of this user, so suites running in
# parallel in other worktrees read and overwrote each other's state (a rare "stair never opens" in game/depths_run). Give this run its own.
XDG_DATA_HOME=$(mktemp -d -t dm-tests-userdata.XXXXXX); export XDG_DATA_HOME
trap 'rm -rf "$XDG_DATA_HOME"' EXIT
rc=0
for d in godot/tests/*/; do
  t=$(basename "$d")
  for r in "$d"run.gd "$d"adapter_run.gd "$d"*_run.gd; do
    [ -f "$r" ] || continue
    case " ${seen:-} " in *" $r "*) continue;; esac; seen="${seen:-} $r"
    out=$(timeout 1800 nice "$G" --headless --path godot --script "res://${r#godot/}" 2>&1); code=$?
    line=$(echo "$out" | grep -iE '[0-9]+ (/ [0-9]+ )?passed' | tail -1)
    [ $code -ne 0 ] && rc=1
    printf '%-18s %-16s exit=%d  %s\n' "$t" "$(basename "$r")" "$code" "${line:-$(echo "$out" | grep -iE 'error|missing|skip' | head -1)}"
    # A failing suite names its failing checks (the summary line alone hid every flaky check), plus the load at the time.
    if [ $code -ne 0 ]; then
      echo "$out" | grep -E '^FAIL' | head -8 | sed 's/^/    /'
      echo "    (load: $(cut -d' ' -f1-3 /proc/loadavg))"
    fi
  done
done
exit $rc
