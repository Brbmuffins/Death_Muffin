#!/usr/bin/env bash
# Run the Godot port test suites headless; print one result line per suite as it finishes. Exit non-zero if any fails (2 on bad usage).
#   run-all-tests.sh [--jobs N] [--only <selectors>] [--list] [--times <out.tsv>]
#   --jobs N        suites run at once (default $DM_TEST_JOBS or 8; 1 = strictly one after another, in directory order). Keep N <= 8: the VPS
#                   is shared with live game servers.
#   --only <list>   comma/space separated selectors: a directory under godot/tests (enemies = every runner file in it) or one runner file
#                   (enemies/kinds_run.gd). Default: all. An unknown selector exits 2.
#   --list          print the selected suite files and exit.
#   --times <file>  also write each suite's wall time (seconds <tab> runner file, slowest first) to <file>. Refresh
#                   tools/godot/suite-times.tsv with it after adding or reshaping suites (the pool's start order comes from that file).
# Speed (owner, 2026-10-10): suites run with --fixed-fps 60 (no real-time pacing: every frame steps 1/60 s and runs as fast as the CPU
# allows), except REALTIME_GROUP and PACED_GROUP. With --jobs > 1 the pool starts the slowest suites first (suite-times.tsv; a suite missing from it counts as
# slow), so the longest ones no longer start last and decide the total.
# With --jobs > 1: the job count is capped by the machine's free cores (24 cores, load 20 -> 2 jobs), so a run never piles onto a busy
# machine (check-godot.sh also lets only one check run at a time); a suite that fails in the pool is run once more alone at the end and only
# its retry counts (child-process timeouts trip under load). Lines appear in completion order (each suite's line plus any FAIL detail is
# printed whole, never interleaved).
# Every running suite gets its own XDG_DATA_HOME/CONFIG/CACHE, so user:// (progress, loadout and settings files keyed by character id) is
# never shared between suites or runs. Network ports come from godot/tests/common/dm_test_ports.gd (random, probed free).
set -uo pipefail
cd "$(dirname "$0")/../.."
G="${GODOT:-/home/ubuntu/tools/godot/godot}"

# REALTIME_GROUP: selectors (same syntax as --only) that talk to other processes (the lobby service, relay peers, ENet peers in child
# processes) and wait on them in real time. They keep real-time pacing (no --fixed-fps) and normal priority while the rest of the pool runs
# at nice 10, so a busy CPU does not starve their timeouts. They start first and overlap the pool (until 2026-10-10 they were a serial
# phase before it, ~2.5 min of a ~7.5 min run). (Tests never assert wall-clock time.)
REALTIME_GROUP=(session relay next_lobby)
# PACED_GROUP: pool suites that keep real-time pacing (no --fixed-fps) because the game code they test measures real time (cooldowns and
# timers on the OS clock, frame-timing checks); measured 2026-10-10: they fail under --fixed-fps. A new suite gets --fixed-fps; add it here
# if it only passes in real time. Fixed-fps suites get DM_SYNC_NAV=1 (navigation merges in step with game time, world_builder.gd); that
# took next_depths, rites and world off this list.
PACED_GROUP=(audio_wire chapterhouse interp next_affixes next_autocombat next_feel ui)
TIMES_FILE=tools/godot/suite-times.tsv

jobs="${DM_TEST_JOBS:-8}"; only=""; list=0; times_out=""
usage() { echo "usage: $0 [--jobs N] [--only <dir|dir/file_run.gd>,...] [--list] [--times <out.tsv>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) [ $# -ge 2 ] || usage; jobs="$2"; shift 2;;
    --jobs=*) jobs="${1#*=}"; shift;;
    --only) [ $# -ge 2 ] || usage; only="$2"; shift 2;;
    --only=*) only="${1#*=}"; shift;;
    --list) list=1; shift;;
    --times) [ $# -ge 2 ] || usage; times_out="$2"; shift 2;;
    --times=*) times_out="${1#*=}"; shift;;
    *) usage;;
  esac
done
case "$jobs" in ''|*[!0-9]*|0) echo "bad --jobs: $jobs" >&2; exit 2;; esac

# Every runner file, in directory order.
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
rtgroup=$(expand "${REALTIME_GROUP[*]}")
is_realtime() { case $'\n'"$rtgroup"$'\n' in *$'\n'"$1"$'\n'*) return 0;; esac; return 1; }
pacedgroup=$(expand "${PACED_GROUP[*]}")
is_paced() { case $'\n'"$pacedgroup"$'\n' in *$'\n'"$1"$'\n'*) return 0;; esac; return 1; }

if [ "$jobs" -gt 1 ]; then
  free=$(awk -v n="$(nproc)" '{f=int(n-$1); print (f<0?0:f)}' /proc/loadavg)
  cap=$(( free / 2 )); [ $cap -lt 2 ] && cap=2
  if [ "$jobs" -gt $cap ]; then echo "(load $(cut -d' ' -f1 /proc/loadavg) on $(nproc) cores: $cap suites at once instead of $jobs)"; jobs=$cap; fi
fi

# run_one <index> <file> <niceness> [defer]: run one suite in its own user dirs, then print its line (+ failure detail) in one locked write.
run_one() {
  local i="$1" r="$2" n="$3" defer="${4:-}" t out code line pace=(--fixed-fps 60) t0
  t=$(basename "$(dirname "$r")")
  { is_realtime "$r" || is_paced "$r"; } && pace=()
  mkdir -p "$T/$i/data" "$T/$i/config" "$T/$i/cache"
  t0=$(date +%s.%N)
  local syncnav=1; [ ${#pace[@]} -eq 0 ] && syncnav=""   # DM_SYNC_NAV: the world's navigation merges in step with --fixed-fps (world_builder.gd)
  out=$(DM_SYNC_NAV="$syncnav" XDG_DATA_HOME="$T/$i/data" XDG_CONFIG_HOME="$T/$i/config" XDG_CACHE_HOME="$T/$i/cache" \
        timeout 1800 nice -n "$n" "$G" --headless ${pace[@]+"${pace[@]}"} --path godot --script "res://${r#godot/}" 2>&1); code=$?
  rm -rf "$T/$i"
  line=$(echo "$out" | grep -iE '[0-9]+ (/ [0-9]+ )?passed' | tail -1)
  if [ $code -ne 0 ] && [ -n "$defer" ]; then   # retried alone after the pool; say so, never hide it
    { flock 9; echo "$i" >> "$T/retry"; echo "($t/$(basename "$r") failed in the pool, load $(cut -d' ' -f1 /proc/loadavg): retrying it alone at the end; $(echo "$out" | grep -E '^FAIL' | head -1 | cut -c1-140))"; } 9>"$T/lock"; return
  fi
  [ $code -ne 0 ] && : > "$T/failed"
  [ "$defer" = "" ] && [ -n "${RETRYING:-}" ] && line="${line} (retried alone after failing under load)"
  {
    flock 9
    printf '%.1f\t%s\n' "$(echo "$(date +%s.%N) - $t0" | bc)" "$r" >> "$T/times"
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
  # The real-time group runs one after another in its own lane (normal priority; mostly waiting on sockets, so it does not take a pool slot).
  rt=(); order=$(for i in "${!suites[@]}"; do
    r="${suites[$i]}"; is_realtime "$r" && continue
    s=$(awk -F'\t' -v r="$r" '$2 == r { print $1; exit }' "$TIMES_FILE" 2>/dev/null); [ -n "$s" ] || s=99999
    printf '%s\t%s\n' "$s" "$i"
  done | sort -t$'\t' -k1,1 -rn | cut -f2)
  for i in "${!suites[@]}"; do is_realtime "${suites[$i]}" && rt+=("$i"); done
  if [ ${#rt[@]} -gt 0 ]; then ( for i in "${rt[@]}"; do run_one "$i" "${suites[$i]}" 0 defer; done ) & fi
  # the pool: slowest first by suite-times.tsv (unknown = slowest), at nice 10
  pids=()
  for i in $order; do
    run_one "$i" "${suites[$i]}" 10 defer & pids+=($!)
    if [ ${#pids[@]} -ge "$jobs" ]; then
      wait -n "${pids[@]}"
      live=(); for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && live+=("$p"); done; pids=(${live[@]+"${live[@]}"})
    fi
  done
  wait
  if [ -f "$T/retry" ]; then
    RETRYING=1
    for i in $(sort -n "$T/retry"); do run_one "$i" "${suites[$i]}" 0; done
  fi
fi
[ -n "$times_out" ] && [ -f "$T/times" ] && sort -t$'\t' -k1,1 -rn "$T/times" > "$times_out"
[ -f "$T/failed" ] && exit 1
exit 0
