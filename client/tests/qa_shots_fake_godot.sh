#!/usr/bin/env bash
# A stand-in for godot in tests/qa_shots.gd: records how tools/qa_shots.sh started it and answers as a renderer would (nothing is drawn). FAKE_MODE: ok (the shots are taken on whichever
# renderer it was asked for), novulkan (Vulkan cannot start, OpenGL 3 takes them), selffall (godot falls back to OpenGL 3 on its own and takes them), failshot (a shot fails on Vulkan), slow (never ends).
# FAKE_DIR: where it writes what it saw.
echo "$@" >> "$FAKE_DIR/calls.txt"
echo "$VK_ICD_FILENAMES|$XDG_DATA_HOME|$(nice)" >> "$FAKE_DIR/env.txt"
if flock -n "$DM_BROWSER_LOCK" true; then echo free >> "$FAKE_DIR/lock.txt"; else echo held >> "$FAKE_DIR/lock.txt"; fi
out=""
for a in "$@"; do case "$a" in --shots=*) out=${a#--shots=};; esac; done
vulkan=0
case "$*" in *"--rendering-driver vulkan"*) vulkan=1;; esac
case "$FAKE_MODE" in
  slow) sleep 60; exit 0;;
  novulkan) if [ "$vulkan" = 1 ]; then echo "ERROR: Can not create a Vulkan instance"; exit 1; fi;;
esac
if [ "$vulkan" = 1 ] && [ "$FAKE_MODE" != selffall ]; then
  echo "Vulkan 1.3.255 - Forward+ - Using Device #0: Mesa - llvmpipe (LLVM 15.0.7, 256 bits)"
else
  echo "OpenGL API 4.5 (Core Profile) Mesa 22.3.6 - Compatibility - Using Device: Mesa - llvmpipe (LLVM 15.0.7, 256 bits)"
fi
if [ "$FAKE_MODE" = failshot ]; then echo "QA-SHOTS shot FAILED $out/a.png"; exit 1; fi
mkdir -p "$out"
printf '\211PNG\r\n\032\n' > "$out/a.png"
echo "QA-SHOTS shot $out/a.png 5ms"
