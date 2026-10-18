#!/usr/bin/env bash
# The game's (client/) test suites, one line each (what tools/godot/run-all-tests.sh is for godot/). Run client/setup.sh and
# client/tools/bake_crowd.sh first (the combat core, the import, the crowd's baked models).
#   tools/rebuild/run-client-tests.sh [--jobs N] [--only a,b]
# A suite passes with exit 0, a PASS line and no SCRIPT ERROR in its log. Each suite gets its own user folders (XDG_*), so they can run side by
# side. Up to three failing suites run once more, alone: one that failed under load passes there; a real failure fails again. Exit 1 if any failed.
# Env: GODOT (default /home/ubuntu/tools/godot/godot), KEEP_LOGS=<dir> (keep every suite's log there).
set -uo pipefail
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-/home/ubuntu/tools/godot/godot}"
JOBS=1
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) JOBS="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    *) echo "usage: $0 [--jobs N] [--only a,b]" >&2; exit 2 ;;
  esac
  shift
done
# Every suite, in the order the core comes first. PACED suites play game time faster than real time (`--fixed-fps 60`); the rest run in real time.
SUITES="core_smoke core_api core_enemies core_status core_corpses core_thralls core_affixes core_coop code_load areas crowd_bake crowd_view game_scene rites boss hud front coop
benchmark social presets rewards value fx_motes panels world core_kinds gathering counsel sound depths auto_combat draw_budget dressing fx_decals threads coop_bosses core_boss
boss_abbess boss_congregation boss_prelate boss_saint boss_regent boss_mire boss_meta"
PACED=" front hud coop value panels world gathering counsel sound depths boss_abbess boss_congregation boss_prelate boss_saint boss_regent boss_mire boss_meta dressing coop_bosses "
[ -z "$ONLY" ] || SUITES="${ONLY//,/ }"
for s in $SUITES; do [ -f "client/tests/$s.gd" ] || { echo "no suite client/tests/$s.gd" >&2; exit 2; }; done
LOG="${KEEP_LOGS:-$(mktemp -d)}"
mkdir -p "$LOG"

run_one() {
  local name="$1" ff="" t0 rc errs res
  case "$PACED" in *" $name "*) ff="--fixed-fps 60" ;; esac
  local home="$LOG/.xdg-$name"
  rm -rf "$home"
  mkdir -p "$home/data" "$home/config" "$home/cache"
  t0=$(date +%s)
  XDG_DATA_HOME="$home/data" XDG_CONFIG_HOME="$home/config" XDG_CACHE_HOME="$home/cache" \
    timeout 900 nice -n 10 "$GODOT" --headless $ff --path client --script "res://tests/$name.gd" >"$LOG/$name.log" 2>&1
  rc=$?
  errs=$(grep -c "SCRIPT ERROR" "$LOG/$name.log")
  res=$(grep -E '^(PASS|FAIL|SKIP)' "$LOG/$name.log" | tail -1 | cut -c1-90)
  if [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] && [[ "$res" == PASS* ]]; then
    echo "ok   $name $(( $(date +%s) - t0 ))s $res"
  else
    echo "FAIL $name exit=$rc script_errors=$errs $(( $(date +%s) - t0 ))s ${res:-no result line}"
  fi
}
export -f run_one
export GODOT LOG PACED

OUT="$LOG/summary.txt"
printf "%s\n" $SUITES | xargs -P "$JOBS" -I{} bash -c 'run_one {}' | tee "$OUT"
FAILED=$(awk '$1 == "FAIL" {print $2}' "$OUT")
if [ -n "$FAILED" ] && [ "$(echo "$FAILED" | wc -l)" -le 3 ]; then
  echo "== re-running alone: $(echo $FAILED)"
  STILL=""
  for s in $FAILED; do
    line=$(run_one "$s")
    echo "$line"
    [[ "$line" == ok* ]] || STILL="$STILL $s"
  done
  FAILED="${STILL# }"
fi
total=$(echo $SUITES | wc -w)
if [ -n "$FAILED" ]; then
  for s in $FAILED; do
    echo "---- $s (last lines)"
    grep -E "FAIL|SCRIPT ERROR|ERROR" "$LOG/$s.log" | head -15
    echo "::error title=client suite $s failed::$(grep -E 'FAIL' "$LOG/$s.log" | head -1 | cut -c1-200)"
  done
  echo "CLIENT TESTS: $total suites, FAILED: $FAILED"
  exit 1
fi
echo "CLIENT TESTS: $total suites, all passed"
