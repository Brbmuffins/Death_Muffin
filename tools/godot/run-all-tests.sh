#!/usr/bin/env bash
# Run the Godot port test suites headless; print one result line per suite as it finishes. Exit non-zero if any fails (2 on bad usage).
#   run-all-tests.sh [--jobs N] [--only <selectors>] [--list]
#   --jobs N        suites run at once (default $DM_TEST_JOBS or 6; 1 = strictly one after another, in directory order). Keep N <= 8: the VPS
#                   is shared with live game servers.
#   --only <list>   comma/space separated selectors: a directory under godot/tests (enemies = every runner file in it) or one runner file
#                   (enemies/kinds_run.gd). Default: all. An unknown selector exits 2.
#   --list          print the selected suite files and exit.
# With --jobs > 1: the job count is capped by the machine's free cores (24 cores, load 20 -> 2 jobs), so several checks running at
# once (the Discord agent runs up to 3) share the CPU instead of piling up; a suite that fails in the pool is run once more alone at
# the end and only its retry counts (timing budgets trip under load). Lines appear in completion order (each suite's line plus any FAIL detail is printed whole, never interleaved).
# Every running suite gets its own XDG_DATA_HOME/CONFIG/CACHE, so user:// (progress, loadout and settings files keyed by character id) is
# never shared between suites or runs. Network ports come from godot/tests/common/dm_test_ports.gd (random, probed free).
set -uo pipefail
cd "$(dirname "$0")/../.."
G="${GODOT:-/home/ubuntu/tools/godot/godot}"

# SERIAL_GROUP: selectors (same syntax as --only) run one at a time, with nothing else of ours running, BEFORE the parallel pool (--jobs > 1).
# They assert wall-clock/frame-time budgets or spawn child processes and wait on them with timeouts, and flake when the pool loads the CPU.
SERIAL_GROUP=(perf next_perfctl session relay next_lobby)

jobs="${DM_TEST_JOBS:-6}"; only=""; list=0
usage() { echo "usage: $0 [--jobs N] [--only <dir|dir/file_run.gd>,...] [--list]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) [ $# -ge 2 ] || usage; jobs="$2"; shift 2;;
    --jobs=*) jobs="${1#*=}"; shift;;
    --only) [ $# -ge 2 ] || usage; only="$2"; shift 2;;
    --only=*) only="${1#*=}"; shift;;
    --list) list=1; shift;;
    *) usage;;
  esac
done
case "$jobs" in ''|*[!0-9]*|0) echo "bad --jobs: $jobs" >&2; exit 2;; esac

# Every runner file, in the order the serial run always used.
all=()
for d in godot/tests/*/; do
  for r in "$d"run.gd "$d"adapter_run.gd "$d"*_run.gd; do
    [ -f "$r" ] || continue
    case " ${all[*]:-} " in *" $r "*) continue;; esac
    all+=("$r")
  done
done

# expand <selectors>: print the matching runner files; return 1 on an unknown selector.
expand() {
  local s r hit
  for s in $(echo "$1" | tr ',' ' '); do
    s="${s#godot/tests/}"; s="${s%/}"; hit=0
    for r in "${all[@]}"; do
      case "$r" in "godot/tests/$s"|"godot/tests/$s/"*) echo "$r"; hit=1;; esac
    done
    [ $hit -eq 1 ] || { echo "unknown suite selector: $s (a dir under godot/tests or a dir/file_run.gd)" >&2; return 1; }
  done
}

suites=("${all[@]}")
if [ -n "$only" ]; then
  sel=$(expand "$only") || exit 2
  [ -n "$sel" ] || { echo "--only selected nothing" >&2; exit 2; }
  suites=(); for r in "${all[@]}"; do case $'\n'"$sel"$'\n' in *$'\n'"$r"$'\n'*) suites+=("$r");; esac; done
fi
if [ $list -eq 1 ]; then printf '%s\n' "${suites[@]}"; exit 0; fi

"$G" --headless --path godot --import >/dev/null 2>&1

T=$(mktemp -d -t dm-tests.XXXXXX)
trap 'rm -rf "$T"' EXIT
sgroup=$(expand "${SERIAL_GROUP[*]}")

if [ "$jobs" -gt 1 ]; then
  free=$(awk -v n="$(nproc)" '{f=int(n-$1); print (f<0?0:f)}' /proc/loadavg)
  cap=$(( free / 2 )); [ $cap -lt 2 ] && cap=2
  if [ "$jobs" -gt $cap ]; then echo "(load $(cut -d' ' -f1 /proc/loadavg) on $(nproc) cores: $cap suites at once instead of $jobs)"; jobs=$cap; fi
fi

# run_one <index> <file> <niceness> [defer]: run one suite in its own user dirs, then print its line (+ failure detail) in one locked write.
run_one() {
  local i="$1" r="$2" n="$3" defer="${4:-}" t out code line
  t=$(basename "$(dirname "$r")")
  mkdir -p "$T/$i/data" "$T/$i/config" "$T/$i/cache"
  out=$(XDG_DATA_HOME="$T/$i/data" XDG_CONFIG_HOME="$T/$i/config" XDG_CACHE_HOME="$T/$i/cache" \
        timeout 1800 nice -n "$n" "$G" --headless --path godot --script "res://${r#godot/}" 2>&1); code=$?
  rm -rf "$T/$i"
  line=$(echo "$out" | grep -iE '[0-9]+ (/ [0-9]+ )?passed' | tail -1)
  if [ $code -ne 0 ] && [ -n "$defer" ]; then   # retried alone after the pool; say so, never hide it
    { flock 9; echo "$i" >> "$T/retry"; echo "($t/$(basename "$r") failed in the pool, load $(cut -d' ' -f1 /proc/loadavg): retrying it alone at the end; $(echo "$out" | grep -E '^FAIL' | head -1 | cut -c1-140))"; } 9>"$T/lock"; return
  fi
  [ $code -ne 0 ] && : > "$T/failed"
  [ "$defer" = "" ] && [ -n "${RETRYING:-}" ] && line="${line} (retried alone after failing under load)"
  {
    flock 9
    printf '%-18s %-16s exit=%d  %s\n' "$t" "$(basename "$r")" "$code" "${line:-$(echo "$out" | grep -iE 'error|missing|skip' | head -1)}"
    # A failing suite names its failing checks (the summary line alone hid every flaky check), plus the load at the time.
    if [ $code -ne 0 ]; then
      echo "$out" | grep -E '^FAIL' | head -8 | sed 's/^/    /'
      echo "    (load: $(cut -d' ' -f1-3 /proc/loadavg))"
    fi
  } 9>"$T/lock"
}

if [ "$jobs" -eq 1 ]; then
  for i in "${!suites[@]}"; do run_one "$i" "${suites[$i]}" 0; done
else
  pool=()
  for i in "${!suites[@]}"; do
    case $'\n'"$sgroup"$'\n' in *$'\n'"${suites[$i]}"$'\n'*) run_one "$i" "${suites[$i]}" 0;; *) pool+=("$i");; esac
  done
  running=0
  for i in ${pool[@]+"${pool[@]}"}; do
    run_one "$i" "${suites[$i]}" 10 defer &
    running=$((running+1))
    if [ $running -ge "$jobs" ]; then wait -n; running=$((running-1)); fi
  done
  wait
  if [ -f "$T/retry" ]; then
    RETRYING=1
    for i in $(sort -n "$T/retry"); do run_one "$i" "${suites[$i]}" 0; done
  fi
fi
[ -f "$T/failed" ] && exit 1
exit 0
