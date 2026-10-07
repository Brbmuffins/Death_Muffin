#!/usr/bin/env bash
# Headless playtest for the four necromancer disciplines (Gravecaller 2, Ossuary 1, Mourner 3, Rotweaver 4), two at a time under nice.
# usage: tools/godot/playtest-all.sh [--next] [extra playtest.sh args]   -> godot/tests/playtest/out/[n]d<N>_h/{A,B}.json ; summary on stdout
# (--next = the rebuild; then compare with tools/godot/playtest-compare.py)
cd "$(dirname "$0")/../.."
for pair in "2 1" "3 4"; do
  for d in $pair; do nice -n 10 tools/godot/playtest.sh --disc=$d "$@" > /dev/null 2>&1 & done
  wait
done
python3 - <<'PY'
import json,glob,os
for f in sorted(glob.glob('godot/tests/playtest/out/*d[0-9]_h/[AB].json')):
    r=json.load(open(f)); print(f.split('out/')[1], 'findings', len(r['findings']), r['frame'].get('p50_ms'), r['frame'].get('p95_ms'))
    for x in r['findings']: print('  ', x['sev'], x['title'][:110])
PY
