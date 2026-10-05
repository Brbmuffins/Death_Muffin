#!/usr/bin/env bash
# Build one Godot eval project per extracted BinbunVFX pack under godot/vendor_eval/ (gitignored), symlinking the private pack sources
# (/home/ubuntu/death-muffin/private/binbun/<Pack>/assets). Packs overlap with differing shared/ files, so each pack gets its own project.
# usage: tools/godot/fx-eval-setup.sh [Pack ...]      then import (headless, no renderer needed).
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=/home/ubuntu/death-muffin/private/binbun
DST=godot/vendor_eval
GODOT=/home/ubuntu/tools/godot/godot
packs=("$@"); [ ${#packs[@]} -eq 0 ] && packs=($(ls "$SRC"))
for p in "${packs[@]}"; do
  d="$DST/$p"; mkdir -p "$d"
  [ -e "$d/assets" ] || ln -s "$SRC/$p/assets" "$d/assets"
  # Hologram / Triplanar / Underscored-source packs keep their assets one level deeper; link any nested assets dir instead
  if [ ! -d "$SRC/$p/assets" ]; then rm -f "$d/assets"; n=$(find "$SRC/$p" -maxdepth 3 -type d -name assets | head -1); if [ -n "$n" ]; then ln -s "$n" "$d/assets"; else ln -s "$SRC/$p" "$d/assets"; fi; fi
  cp godot/fx/eval/eval_fx.gd "$d/eval_fx.gd"
  cat > "$d/project.godot" <<P
config_version=5
[application]
config/name="fx-eval $p"
config/features=PackedStringArray("4.7", "GL Compatibility")
[display]
window/size/viewport_width=800
window/size/viewport_height=450
[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
textures/vram_compression/import_etc2_astc=false
P
  echo "importing $p"
  nice -n 10 timeout 900 "$GODOT" --headless --path "$d" --import >"$d/import.log" 2>&1 || echo "  import exit $? ($p)"
done
