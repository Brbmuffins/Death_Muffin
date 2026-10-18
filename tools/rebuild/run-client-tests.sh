#!/usr/bin/env bash
# The game's (client/) test suites. Run client/setup.sh and client/tools/bake_crowd.sh first (the combat core, the import, the crowd's baked models).
#   tools/rebuild/run-client-tests.sh [--jobs N] [--only a,b] [--list]      --list prints the selected suites and runs nothing
# A suite is a file client/tests/<name>.gd, a folder client/tests/<name>/run.gd (its parts and fixtures beside it), or one runner of a folder,
# <folder>/<runner> for client/tests/<folder>/<runner>.gd (a folder with several runners). One line per suite as it finishes:
#   <suite> <script> exit=<code>  <seconds>s <result line>        (exit=0: passed; the Discord agent's check counts and reads these lines)
# A suite passes with exit 0, a PASS line and no SCRIPT ERROR in its log. Each suite gets its own user folders (XDG_*), so they can run side by
# side. Up to three failing suites run once more, alone: one that failed under load passes there; a real failure fails again. Exit 1 if any failed.
# Env: GODOT (default /home/ubuntu/tools/godot/godot), KEEP_LOGS=<dir> (keep every suite's log there).
set -uo pipefail
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
JOBS=1
ONLY=""
LIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) JOBS="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    --list) LIST=1 ;;
    *) echo "usage: $0 [--jobs N] [--only a,b] [--list]" >&2; exit 2 ;;
  esac
  shift
done
# Every suite, in the order the core comes first. PACED suites play game time faster than real time (`--fixed-fps 60`); the rest run in real time.
SUITES="core_smoke core_api core_enemies core_status core_corpses core_thralls core_affixes core_coop code_load areas crowd_bake crowd_view game_scene rites boss hud front coop
benchmark social presets rewards value fx_motes panels world core_kinds gathering counsel sound depths auto_combat draw_budget dressing fx_decals threads coop_bosses core_boss crash_note qa_shots
boss_abbess boss_congregation boss_prelate boss_saint boss_regent boss_mire boss_meta surge play_report warm_coverage
rules-combat rules-core rules-gathering rules-loot rules-progression data dialogue gear sim audio loot_view panels_a bosses onboarding fx world_builder world_fx game_ui ui ui_parity gear_look
next_online_gate session relay relay/udp_run backend chapterhouse next_bag next_loot next_acre_guide next_gathering next_hero_look next_front next_polish perf/first_frame_run next_progress
next_boss_meta next_hud audio_wire next_playtest status game/units_run game/anim_run game/autocombat_run game/regress_run next_perfctl next_autocombat next_feel next_spawn_aggro
next_lobby next_lobby/ui_run next_lobby/proc_run next_meta next_hud_counsel next_brews_affix next_runes next_clarity next_combat_odds next_glue next_affixes interp enemy_fx"
# The suites after `warm_coverage` came from the first game's tests (B57). ui, chapterhouse, audio_wire, next_autocombat, next_feel, next_affixes and interp keep real time
# (they measure it), and so do session, relay and next_lobby (real sockets and child processes).
PACED=" front hud coop value panels world gathering counsel sound depths boss_abbess boss_congregation boss_prelate boss_saint boss_regent boss_mire boss_meta dressing coop_bosses qa_shots surge warm_coverage \
 rules-combat rules-core rules-gathering rules-loot rules-progression data dialogue gear sim audio loot_view panels_a bosses onboarding fx world_builder world_fx game_ui ui_parity gear_look \
 next_online_gate backend next_bag next_loot next_acre_guide next_gathering next_hero_look next_front next_polish perf/first_frame_run next_progress next_boss_meta next_hud next_playtest \
 status game/units_run game/anim_run game/autocombat_run game/regress_run next_perfctl next_spawn_aggro next_meta next_hud_counsel next_brews_affix next_runes next_clarity next_combat_odds next_glue enemy_fx "
[ -z "$ONLY" ] || SUITES="${ONLY//,/ }"
# The script of a suite, under client/tests: <name>.gd, else <name>/run.gd; a name with a slash is one runner of a folder (<folder>/<runner>.gd).
script_of() {
  case "$1" in
    */*) echo "$1.gd" ;;
    *) if [ -f "client/tests/$1.gd" ]; then echo "$1.gd"; else echo "$1/run.gd"; fi ;;
  esac
}
for s in $SUITES; do [ -f "client/tests/$(script_of "$s")" ] || { echo "no suite client/tests/$(script_of "$s")" >&2; exit 2; }; done
if [ -n "$LIST" ]; then printf '%s\n' $SUITES; exit 0; fi
LOG="${KEEP_LOGS:-$(mktemp -d)}"
mkdir -p "$LOG"

run_one() {
  local name="$1" ff="" t0 rc errs res code script
  local tag="${name//\//_}"
  script=$(script_of "$name")
  case "$PACED" in *" $name "*) ff="--fixed-fps 60" ;; esac
  local home="$LOG/.xdg-$tag"
  rm -rf "$home"
  mkdir -p "$home/data" "$home/config" "$home/cache"
  t0=$(date +%s)
  XDG_DATA_HOME="$home/data" XDG_CONFIG_HOME="$home/config" XDG_CACHE_HOME="$home/cache" \
    timeout 900 nice -n 10 "$GODOT" --headless $ff --path client --script "res://tests/$script" >"$LOG/$tag.log" 2>&1
  rc=$?
  errs=$(grep -c "SCRIPT ERROR" "$LOG/$tag.log")
  res=$(grep -E '^(PASS|FAIL|SKIP)' "$LOG/$tag.log" | tail -1 | cut -c1-90)
  code=$rc
  if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [[ "$res" == PASS* ]]; then code=0; elif [ "$code" -eq 0 ]; then code=1; fi
  printf '%-18s %-16s exit=%d  %ss %s%s\n' "$name" "$script" "$code" "$(( $(date +%s) - t0 ))" "${res:-no result line}" "$([ "$errs" -gt 0 ] && echo " script_errors=$errs")"
}
export -f run_one script_of
export GODOT LOG PACED

OUT="$LOG/summary.txt"
printf "%s\n" $SUITES | xargs -P "$JOBS" -I{} bash -c 'run_one {}' | tee "$OUT"
FAILED=$(awk '$3 != "exit=0" {print $1}' "$OUT")
if [ -n "$FAILED" ] && [ "$(echo "$FAILED" | wc -l)" -le 3 ]; then
  echo "== re-running alone: $(echo $FAILED)"
  STILL=""
  for s in $FAILED; do
    line=$(run_one "$s")
    echo "$line"
    [[ "$line" == *" exit=0 "* ]] || STILL="$STILL $s"
  done
  FAILED="${STILL# }"
fi
total=$(echo $SUITES | wc -w)
if [ -n "$FAILED" ]; then
  for s in $FAILED; do
    echo "---- $s (last lines)"
    grep -E "FAIL|SCRIPT ERROR|ERROR" "$LOG/${s//\//_}.log" | head -15
    echo "::error title=client suite $s failed::$(grep -E 'FAIL' "$LOG/${s//\//_}.log" | head -1 | cut -c1-200)"
  done
  echo "CLIENT TESTS: $total suites, FAILED: $FAILED"
  exit 1
fi
echo "CLIENT TESTS: $total suites, all passed"
