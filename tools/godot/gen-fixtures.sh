#!/usr/bin/env bash
# FROZEN (2026-10): the Godot suites rules-*/gear/dialogue/ui_parity/bosses now read COMMITTED, trimmed answer keys
# (godot/tests/<suite>/fixtures, built by tools/godot/trim-fixtures.py). Godot is the source of truth; the TS game (src/) is being retired.
# Do NOT run this to refresh them casually: it would write the full ~100 MB sets over the committed ones. Regenerate only deliberately,
# then re-run trim-fixtures.py. (sim/ and game/ fixtures, for the old-path suites, are still generated here and stay gitignored.)
# Regenerate every Godot port golden-fixture set from the frozen TypeScript game (deterministic).
# Run from the repo root (node_modules must be present or symlinked). Large fixture folders are gitignored.
set -euo pipefail
cd "$(dirname "$0")/../.."
for f in tools/godot/fixtures-*.ts; do echo "== $f"; npx vite-node "$f"; done
# godot/sim caster fixtures: the real AbilitySystem needs vitest's module mocks (godot/tests/sim/fixtures/cast_*.json)
echo "== tools/godot/sim-cast.fixture.ts"; npx vitest run --config tools/godot/vitest.sim.config.ts
