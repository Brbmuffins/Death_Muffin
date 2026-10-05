#!/usr/bin/env bash
# Copies the game's audio from public/audio into godot/assets/audio/ in formats Godot imports.
#  - esm/*.opus  -> esm/*.wav   (Godot cannot import Opus. WAV, mono 16-bit, imported QOA-compressed: starting an Ogg Vorbis
#                                playback sets up a decoder, ~0.6 ms a clip, and a kill plays 2-4 clips; a QOA clip starts for free)
#  - ambience/*.ogg, world/amb_*.ogg, combat/boss_toll_*.ogg -> copied as-is (already Vorbis)
#  - music/*.mp3 -> copied as-is (Godot imports MP3; no generation loss)
# Then run: godot --headless --path godot --import   (the .import files are committed)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/public/audio"; DST="$ROOT/godot/assets/audio"
mkdir -p "$DST"/{esm,ambience,world,combat,music}
for f in "$SRC"/esm/*.opus; do
  out="$DST/esm/$(basename "${f%.opus}").wav"
  [ -f "$out" ] || ffmpeg -nostdin -loglevel error -y -i "$f" -ac 1 -ar 44100 -c:a pcm_s16le "$out"
done
cp -u "$SRC"/ambience/*.ogg "$DST/ambience/"
cp -u "$SRC"/world/amb_*.ogg "$DST/world/"
cp -u "$SRC"/combat/boss_toll_*.ogg "$DST/combat/"
cp -u "$SRC"/music/*.mp3 "$DST/music/"
du -sh "$DST"/*
