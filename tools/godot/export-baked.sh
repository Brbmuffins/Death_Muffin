#!/usr/bin/env bash
# One Godot export with the shaders baked in (publish-godot-client.sh and assets-pack.sh):
#   tools/godot/export-baked.sh <project dir> <release|pack> <preset> <out> [godot]
# Godot bakes the build's shaders into the pack (`shader_baker/enabled` in client/export_presets.cfg; res://.godot/shader_cache/ entries) only when
# the export runs with a renderer: with them, a player's PC compiles no shader from source at first start or first use (ROADMAP Phase 1,
# first-use stutters; the warm-up still builds the GPU pipelines on the loading screen). This VPS has no GPU, so the export runs on the software
# Vulkan driver (lavapipe) on a virtual screen, one renderer on the machine at a time (the shared qa-browser.lock). Run that way the editor
# rewrites project.godot (comments, setting order), so it is put back from git right after; the export has read it by then. Without the driver,
# or when that export fails, the export runs headless, without baked shaders, and says so: a release never fails for want of baking.
# Prints "baked shaders: yes|no (...)". Env: DM_RENDER_LOCK (default /home/ubuntu/death-muffin/qa-browser.lock), DM_QA_ICD (the lavapipe ICD file).
set -uo pipefail
PROJ="${1:?usage: export-baked.sh <project dir> <release|pack> <preset> <out> [godot]}"; MODE="${2:?}"; PRESET="${3:?}"; OUT="${4:?}"
GODOT="${5:-${GODOT:-/home/ubuntu/tools/godot/godot}}"
case "$MODE" in release|pack) ;; *) echo "export-baked.sh: mode must be release or pack" >&2; exit 2;; esac
ICD="${DM_QA_ICD:-/usr/share/vulkan/icd.d/lvp_icd.x86_64.json}"
LOCK="${DM_RENDER_LOCK:-/home/ubuntu/death-muffin/qa-browser.lock}"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
restore() { for f in project.godot export_presets.cfg; do git -C "$PROJ" ls-files --error-unmatch "$f" >/dev/null 2>&1 && git -C "$PROJ" checkout -q -- "$f"; done; }
if [ -f "$ICD" ] && command -v xvfb-run >/dev/null; then
  exec 7>>"$LOCK"
  if flock -w 1800 7; then
    VK_ICD_FILENAMES="$ICD" nice -n 10 xvfb-run -a -s "-screen 0 1280x800x24" "$GODOT" --rendering-driver vulkan --path "$PROJ" "--export-$MODE" "$PRESET" "$OUT" >"$LOG" 2>&1
    rc=$?
    flock -u 7
    restore
    if [ $rc -eq 0 ]; then
      steps=$(grep -o 'Baking shaders ([0-9]* steps)' "$LOG" | grep -o '[0-9]*' | head -1)
      if grep -q 'DONE.*baking_shaders' "$LOG"; then echo "baked shaders: yes (${steps:-?} steps)"; else echo "baked shaders: no (the export did not bake: check shader_baker/enabled in the preset)"; fi
      exit 0
    fi
    echo "baked shaders: no (the export with a renderer failed, exit $rc: exporting headless)"; tail -5 "$LOG"
  else
    echo "baked shaders: no (the renderer stayed busy for 30 minutes: exporting headless)"
  fi
else
  echo "baked shaders: no (no software Vulkan driver or xvfb-run here: exporting headless)"
fi
"$GODOT" --headless --path "$PROJ" "--export-$MODE" "$PRESET" "$OUT" >"$LOG" 2>&1 || { tail -30 "$LOG" >&2; echo "godot export failed" >&2; exit 1; }
