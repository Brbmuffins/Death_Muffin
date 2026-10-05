#!/usr/bin/env bash
# usage: tools/godot/fx-eval-run.sh static|perf|perfvar|shots|shaders|synth [Pack ...]   (perfvar = lowres meshes + no lights; synth = micro-benchmarks, pass one Pack)
# static runs headless; perf/shots/shaders take the renderer lock and run under xvfb + llvmpipe with a timeout. Output: godot/shots/fx_eval/ (gitignored).
set -uo pipefail
cd "$(dirname "$0")/../../godot"
MODE="$1"; shift
OUT=$PWD/shots/fx_eval; D=$OUT/data; mkdir -p "$D"
GODOT=/home/ubuntu/tools/godot/godot
packs=("$@"); [ ${#packs[@]} -eq 0 ] && packs=($(ls vendor_eval))
for p in "${packs[@]}"; do
  args=(--path "vendor_eval/$p" --script res://eval_fx.gd -- --mode=${MODE%var} --pack=$p --static="$D/${p}_static.json")
  case $MODE in
    static) timeout 300 nice -n 10 $GODOT --headless "${args[@]}" --out="$D/${p}_static.json" >"$D/${p}_static.log" 2>&1 ;;
    perf) flock -w 3600 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 1500 xvfb-run -a -s "-screen 0 800x450x24" $GODOT --rendering-driver opengl3 --fixed-fps 30 --resolution 800x450 "${args[@]}" --out="$D/${p}_perf.json" >"$D/${p}_perf.log" 2>&1 ;;
    shots) flock -w 3600 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 1500 xvfb-run -a -s "-screen 0 1920x1080x24" $GODOT --rendering-driver opengl3 --fixed-fps 30 --resolution 1920x1080 "${args[@]}" --out="$OUT/sheets/$p" >"$D/${p}_shots.log" 2>&1 ;;
    perfvar) flock -w 3600 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 1500 xvfb-run -a -s "-screen 0 800x450x24" $GODOT --rendering-driver opengl3 --fixed-fps 30 --resolution 800x450 "${args[@]}" --variant=lowres --out="$D/${p}_perfvar.json" >"$D/${p}_perfvar.log" 2>&1 ;;
    synth) flock -w 3600 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 900 xvfb-run -a -s "-screen 0 800x450x24" $GODOT --rendering-driver opengl3 --fixed-fps 30 --resolution 800x450 "${args[@]}" --out="$D/synth.json" >"$D/synth.log" 2>&1 ;;
    shaders) flock -w 3600 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 900 xvfb-run -a -s "-screen 0 1920x1080x24" $GODOT --rendering-driver opengl3 --fixed-fps 30 --resolution 1920x1080 "${args[@]}" --out="$OUT/shaders/${p}.json" >"$D/${p}_shaders.log" 2>&1 ;;
  esac
  echo "$p $MODE rc=$?"
done
