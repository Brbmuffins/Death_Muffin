#!/usr/bin/env bash
# The game's (client/) test suites. Run tools/check/prep.sh first (the combat core, the import, the crowd's baked models, the lobby's packages).
#   tools/rebuild/run-client-tests.sh [--jobs N] [--only a,b] [--shard I/N] [--list] [--times <out.tsv>]
#   --jobs N        suites at once (default $DM_TEST_JOBS or 8; 1 = one after another, in list order, no retries). Off GitHub the count is capped by
#                   the free cores (half of them, at least 2), so a run never piles onto a busy VPS (live game servers share it).
#   --only a,b      just those suites.  --list  print the selected suites and run nothing.
#   --shard I/N     this machine's share when N machines split the suites (CI's game jobs): the suites, slowest first by suite-times.tsv,
#                   each go to the share with the least time so far, so every share takes about as long; every machine computes the same split.
#   --times <file>  also write each suite's time (seconds <tab> suite, slowest first): refresh tools/rebuild/suite-times.tsv with a full run's file
#                   after adding or reshaping suites (the pool's start order and the time limits come from it).
# A suite is a file client/tests/<name>.gd, a folder client/tests/<name>/run.gd (its parts and fixtures beside it), or one runner of a folder,
# <folder>/<runner> for client/tests/<folder>/<runner>.gd (a folder with several runners). One line per suite as it finishes, never interleaved:
#   <suite> <script> exit=<code>  <seconds>s <result line>        (exit=0: passed; the Discord agent's check counts and reads these lines)
# A suite passes with exit 0, a PASS line and no SCRIPT ERROR in its log. A suite that skips (`coop: SKIPPED (...)`) fails, and its line says why.
# Side by side (--jobs > 1): the pool starts the slowest suites first (suite-times.tsv; a suite missing from it counts as the slowest), so the
# longest no longer start last and decide the total. The LANE suites (real sockets and child processes that wait in real time: the lobby, the
# relay, sessions) run one after another beside the pool, so they never race each other for time; the socket-waiting ones at normal priority. A suite that fails is run once more, alone, at
# the end (at most 5 of them): only the retry's line counts, and the first failure is noted on a line without `exit=`, so nothing is counted
# twice. A time-out is not retried (load does not turn 20 s into 4 min). Each suite's time limit comes from its usual time in suite-times.tsv (10x,
# at least 4 min, at most 30; 15 min without one): a wait that never ends fails fast instead of holding the run.
# Each suite gets its own user folders (XDG_*), so suites never share user:// files. Suites under --fixed-fps get DM_SYNC_NAV=1 (the navigation
# merges in step with game time, client/world/world_builder.gd). Exit 1 if any failed.
# Env: GODOT (default /home/ubuntu/tools/godot/godot), DM_TEST_JOBS, KEEP_LOGS=<dir> (keep every suite's log and summary.txt there).
set -uo pipefail
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
JOBS="${DM_TEST_JOBS:-8}"
ONLY=""
SHARD=""
LIST=""
TIMES_OUT=""
usage() { echo "usage: $0 [--jobs N] [--only a,b] [--shard I/N] [--list] [--times <out.tsv>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) [ $# -ge 2 ] || usage; JOBS="$2"; shift ;;
    --only) [ $# -ge 2 ] || usage; ONLY="$2"; shift ;;
    --shard) [ $# -ge 2 ] || usage; SHARD="$2"; shift ;;
    --list) LIST=1 ;;
    --times) [ $# -ge 2 ] || usage; TIMES_OUT="$2"; shift ;;
    *) usage ;;
  esac
  shift
done
case "$JOBS" in ''|*[!0-9]*|0) echo "bad --jobs: $JOBS" >&2; exit 2 ;; esac
[ -z "$TIMES_OUT" ] || [[ "$TIMES_OUT" == /* ]] || TIMES_OUT="$PWD/$TIMES_OUT"
cd "$(dirname "$0")/../.."
# Every suite, in the order the core comes first. PACED suites play game time faster than real time (`--fixed-fps 60`); the rest run in real time.
SUITES="core_smoke core_api core_enemies core_status core_corpses core_thralls core_affixes core_coop code_load areas crowd_bake crowd_view game_scene rites spells boss hud front coop
benchmark benchmark_rooms benchmark_classes benchmark_launch benchmark_flags social presets rewards value fx_motes panels world core_kinds gathering counsel sound depths auto_combat draw_budget dressing fx_decals threads coop_bosses core_boss crash_note qa_shots
boss_abbess boss_congregation boss_prelate boss_saint boss_regent boss_mire boss_meta surge play_report warm_coverage
rules-combat rules-core rules-gathering rules-loot rules-progression data dialogue gear sim audio loot_view panels_a bosses onboarding fx world_builder world_fx game_ui ui ui_parity gear_look
next_online_gate session relay relay/udp_run backend chapterhouse next_bag next_loot next_hero_look next_front next_polish perf/first_frame_run next_progress
next_boss_meta next_hud audio_wire next_playtest status game/units_run game/anim_run game/autocombat_run game/regress_run next_perfctl next_autocombat next_feel next_spawn_aggro
next_lobby next_lobby/ui_run next_lobby/proc_run next_meta next_hud_counsel next_brews_affix next_runes next_clarity next_combat_odds next_glue next_affixes interp enemy_fx"
# game_scene, rites, boss, presets and benchmark are paced too (2026-10-19: 147 -> 28 s, 175 -> 51 s, 64 -> 40 s, 287 -> 180 s on the VPS).
# The suites after `warm_coverage` came from the first game's tests (B57). ui, chapterhouse, audio_wire, next_autocombat, next_feel, next_affixes and interp keep real time
# (they measure it), and so do session, relay and next_lobby (real sockets and child processes).
PACED=" game_scene rites spells boss presets benchmark benchmark_rooms benchmark_classes benchmark_launch benchmark_flags front hud coop value panels world gathering counsel sound depths boss_abbess boss_congregation boss_prelate boss_saint boss_regent boss_mire boss_meta dressing coop_bosses qa_shots surge warm_coverage \
 rules-combat rules-core rules-gathering rules-loot rules-progression data dialogue gear sim audio loot_view panels_a bosses onboarding fx world_builder world_fx game_ui ui_parity gear_look \
 next_online_gate backend next_bag next_loot next_hero_look next_front next_polish perf/first_frame_run next_progress next_boss_meta next_hud next_playtest \
 status game/units_run game/anim_run game/autocombat_run game/regress_run next_perfctl next_spawn_aggro next_meta next_hud_counsel next_brews_affix next_runes next_clarity next_combat_odds next_glue enemy_fx "
# LANE: the suites that wait on real sockets and child processes in real time (session, relay and next_lobby talk to peers and the lobby;
# coop, coop_bosses and social start the real lobby service, node, and wait for it). One after another beside the pool.
LANE=" session relay relay/udp_run next_lobby next_lobby/ui_run next_lobby/proc_run coop coop_bosses social "
# Of those, the ones that mostly wait on sockets keep normal priority (the rest of a run is at nice 10), so a busy machine does not starve their
# real-time waits (2026-10-19: next_lobby failed at load 20 at nice 10 and passed alone; coop, coop_bosses and social wait on the real lobby too).
WAITING=" session relay relay/udp_run next_lobby next_lobby/ui_run next_lobby/proc_run coop coop_bosses social "
TIMES_FILE=tools/rebuild/suite-times.tsv
[ -z "$ONLY" ] || SUITES="${ONLY//,/ }"
# The script of a suite, under client/tests: <name>.gd, else <name>/run.gd; a name with a slash is one runner of a folder (<folder>/<runner>.gd).
script_of() {
  case "$1" in
    */*) echo "$1.gd" ;;
    *) if [ -f "client/tests/$1.gd" ]; then echo "$1.gd"; else echo "$1/run.gd"; fi ;;
  esac
}
for s in $SUITES; do [ -f "client/tests/$(script_of "$s")" ] || { echo "no suite client/tests/$(script_of "$s")" >&2; exit 2; }; done
if [ -n "$SHARD" ]; then
  [[ "$SHARD" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] || { echo "bad --shard: $SHARD (I/N, 1 <= I <= N)" >&2; exit 2; }
  SUITES=$(for s in $SUITES; do t=$(awk -F'\t' -v s="$s" '$2 == s { print $1; exit }' "$TIMES_FILE" 2>/dev/null); echo "${t:-9999} $s"; done |
    sort -k1,1nr -k2,2 | awk -v i="${BASH_REMATCH[1]}" -v n="${BASH_REMATCH[2]}" '{ b = 1; for (k = 2; k <= n; k++) if (tot[k] < tot[b]) b = k; tot[b] += $1; if (b == i) print $2 }' | tr '\n' ' ')
fi
if [ -n "$LIST" ]; then printf '%s\n' $SUITES; exit 0; fi
LOG="${KEEP_LOGS:-$(mktemp -d)}"
mkdir -p "$LOG"
[ -n "${KEEP_LOGS:-}" ] || trap 'rm -rf "$LOG"' EXIT
rm -f "$LOG/summary.txt" "$LOG/.retry" "$LOG/.times"

if [ "$JOBS" -gt 1 ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
  free=$(awk -v n="$(nproc)" '{ f = int(n - $1); print (f < 0 ? 0 : f) }' /proc/loadavg)
  cap=$(( free / 2 )); [ "$cap" -lt 2 ] && cap=2
  if [ "$JOBS" -gt "$cap" ]; then echo "(load $(cut -d' ' -f1 /proc/loadavg) on $(nproc) cores: $cap suites at once instead of $JOBS)"; JOBS=$cap; fi
fi

usual_of() { awk -F'\t' -v s="$1" '$2 == s { print $1; exit }' "$TIMES_FILE" 2>/dev/null; }

# run_one <suite> [defer]: run one suite in its own user folders, then print its line in one locked write. With `defer` a failure (not a
# time-out) is queued to run again alone at the end instead (at most 5), and only noted here.
run_one() {
  local name="$1" defer="${2:-}" tag="${1//\//_}" script ff="" sync="" niceness=10 usual limit t0 rc secs errs res code
  script=$(script_of "$name")
  case "$PACED" in *" $name "*) ff="--fixed-fps 60"; sync=1 ;; esac
  case "$WAITING" in *" $name "*) niceness=0 ;; esac
  local home="$LOG/.xdg-$tag"
  rm -rf "$home"
  mkdir -p "$home/data" "$home/config" "$home/cache"
  usual=$(usual_of "$name")
  if [ -n "$usual" ]; then limit=$(awk -v u="$usual" 'BEGIN { l = int(u * 10); if (l < 240) l = 240; if (l > 1800) l = 1800; print l }'); else limit=900; fi
  t0=$(date +%s.%N)
  DM_SYNC_NAV="$sync" XDG_DATA_HOME="$home/data" XDG_CONFIG_HOME="$home/config" XDG_CACHE_HOME="$home/cache" \
    timeout -k 10 "$limit" nice -n "$niceness" "$GODOT" --headless $ff --path client --script "res://tests/$script" >"$LOG/$tag.log" 2>&1
  rc=$?
  secs=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%d", b - a + 0.5 }')
  rm -rf "$home"
  errs=$(grep -c "SCRIPT ERROR" "$LOG/$tag.log")
  res=$(grep -E '^(PASS|FAIL|SKIP)' "$LOG/$tag.log" | tail -1 | cut -c1-90)
  [ -n "$res" ] || res=$(grep -m1 -E 'SKIPPED' "$LOG/$tag.log" | sed 's/^/SKIP /' | cut -c1-90)
  code=$rc
  if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [[ "$res" == PASS* ]]; then code=0; elif [ "$code" -eq 0 ]; then code=1; fi
  [ "$rc" -eq 124 ] && res="timed out after ${limit}s (usually ${usual:-?}s): a wait in the suite never ended"
  {
    flock 9
    if [ "$code" -ne 0 ] && [ "$rc" -ne 124 ] && [ -n "$defer" ] && [ "$(cat "$LOG/.retry" 2>/dev/null | wc -l)" -lt 5 ]; then
      echo "$name" >> "$LOG/.retry"
      echo "($name failed beside other suites at load $(cut -d' ' -f1 /proc/loadavg), runs again alone at the end: ${res:-no result line})"
    else
      printf '%s\t%s\n' "$secs" "$name" >> "$LOG/.times"
      printf '%-18s %-16s exit=%d  %ss %s%s\n' "$name" "$script" "$code" "$secs" "${res:-no result line}" "$([ "$errs" -gt 0 ] && echo " script_errors=$errs")" | tee -a "$LOG/summary.txt"
    fi
  } 9>"$LOG/.lock"
}

if [ "$JOBS" -eq 1 ]; then
  for s in $SUITES; do run_one "$s"; done
else
  lane=(); pool=()
  for s in $SUITES; do case "$LANE" in *" $s "*) lane+=("$s") ;; *) pool+=("$s") ;; esac; done
  [ ${#lane[@]} -eq 0 ] || ( for s in "${lane[@]}"; do run_one "$s" defer; done ) &
  order=$(for s in ${pool[@]+"${pool[@]}"}; do u=$(usual_of "$s"); printf '%s\t%s\n' "${u:-99999}" "$s"; done | sort -t$'\t' -k1,1 -rn | cut -f2)
  pids=()
  for s in $order; do
    run_one "$s" defer & pids+=($!)
    if [ ${#pids[@]} -ge "$JOBS" ]; then
      wait -n "${pids[@]}"
      live=(); for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && live+=("$p"); done; pids=(${live[@]+"${live[@]}"})
    fi
  done
  wait
  if [ -f "$LOG/.retry" ]; then for s in $(cat "$LOG/.retry"); do run_one "$s"; done; fi
fi
[ -z "$TIMES_OUT" ] || { [ -f "$LOG/.times" ] && sort -t$'\t' -k1,1 -rn "$LOG/.times" > "$TIMES_OUT"; }
FAILED=$(awk '$3 != "exit=0" { print $1 }' "$LOG/summary.txt" 2>/dev/null)
total=$(echo $SUITES | wc -w)
if [ -n "$FAILED" ]; then
  for s in $FAILED; do
    echo "---- $s (last lines)"
    grep -E "FAIL|SCRIPT ERROR|ERROR|SKIPPED" "$LOG/${s//\//_}.log" | head -15
    echo "::error title=client suite $s failed::$(grep -E 'FAIL|SKIPPED' "$LOG/${s//\//_}.log" | head -1 | cut -c1-200)"
  done
  echo "CLIENT TESTS: $total suites, FAILED: $(echo $FAILED)"
  exit 1
fi
echo "CLIENT TESTS: $total suites, all passed"
