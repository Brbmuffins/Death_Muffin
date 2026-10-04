#!/usr/bin/env bash
# Regenerate every Godot port golden-fixture set from the frozen TypeScript game (deterministic).
# Run from the repo root (node_modules must be present or symlinked). Large fixture folders are gitignored.
set -euo pipefail
cd "$(dirname "$0")/../.."
for f in tools/godot/fixtures-*.ts; do echo "== $f"; npx vite-node "$f"; done
