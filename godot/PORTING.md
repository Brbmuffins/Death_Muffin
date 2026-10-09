# Death Muffin → Godot 4 port: conventions (read before writing any code)

> **2026-10-05: superseded in part by `godot/REBUILD.md`** (Godot replaces the web client; networking, sessions, enemies/AI, saves and the
> data format are being rebuilt Godot-first). The conventions below still apply to everything REBUILD.md does not list.

The three.js web game (`src/`, live at muffindevelopment.com/death-muffin/) is FROZEN and is the **reference spec**: the port must
reproduce its behaviour, numbers and UI. Port the current game; do not redesign, add, or "fix" gameplay while porting (note any
web bug you find in your report instead).

## Engine
- Godot 4 stable, **GDScript** (typed: `var x: int`, `func f(a: float) -> Array[Dictionary]`), renderer `gl_compatibility`.
- Binary: `/home/ubuntu/tools/godot/godot` (installed by the foundation track; if missing, wait for it: poll every 60 s, do not install
  your own copy; installs are serialized with `flock /home/ubuntu/tools/godot.install.lock`).
- Headless runs: `/home/ubuntu/tools/godot/godot --headless --path godot ...`. Anything that RENDERS (Xvfb + llvmpipe) must run under
  `flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice ...` — one renderer/browser on the whole VPS at a time.

## Layout (each track owns its folder; touch nothing else)
```
godot/project.godot, godot/main/, godot/world/   foundation track ONLY (scenes, autoload registration, input map)
godot/data/                  generated JSON (by tools/godot/*.ts) — never hand-edited
godot/rules/<domain>/        pure game rules ported from src/gameplay + src/content logic (no nodes; RefCounted/static funcs)
godot/net/                   REST/auth/save client for the existing server (server/death-muffin/backend is unchanged)
godot/ui/                    theme + Control scenes for panels/HUD
godot/assets/                imported models/audio/art (sync scripts in tools/godot/)
godot/tests/<track>/         each track's tests + its own run.gd (headless: --script res://tests/<track>/run.gd)
tools/godot/                 Node/TS tools: data export, golden fixtures, asset sync
```
- Need a new autoload or input action? Don't edit project.godot; list it in your report ("autoloads needed") and the integrator wires it.
- File names snake_case; class_name PascalCase prefixed `Dm` (e.g. `class_name DmLootRoll`).

## Fidelity: golden fixtures
- For every ported rule, generate fixtures FROM THE TYPESCRIPT (tools/godot/fixtures-<domain>.ts run with
  `npx vite-node`), e.g. 200+ seeded cases of inputs → outputs, written to godot/tests/<track>/fixtures/*.json.
  The GDScript must reproduce them exactly (floats within 1e-9 unless the TS rounds).
- Randomness: port `src/gameplay/rng.ts` mulberry32 bit-exactly to `godot/rules/core/rng.gd` (`DmRng`; the rules-core owner
  writes it; others depend on it) so seeded rolls match TS. Use 32-bit masking (`& 0xFFFFFFFF`) — GDScript ints are 64-bit.
- Data comes from godot/data JSON exported from the real TS modules (`src/content/*`), never retyped.
- Fixture size: fixture sets are regenerated deterministically by `tools/godot/gen-fixtures.sh` (runs every
  tools/godot/fixtures-*.ts). If your fixtures folder is over ~1 MB, add it to .gitignore instead of committing it, and make your
  run.gd print `fixtures missing: run tools/godot/gen-fixtures.sh` (and exit non-zero) when they are absent.

## Git
- Each track works in its own worktree on its own branch cut from `godot-next` (e.g. `godot/rules-loot`), commits with explicit
  paths (never `git add -A`), plain one-line messages, NEVER a Co-Authored-By or other trailer. Do not push; the integrator merges
  into `godot-next`. Never touch master/mobile, never deploy, never restart services, never touch .env/secrets.

## Report (every track)
What's ported (file list), fixture coverage + pass counts, what's stubbed and why, dependencies on other tracks, autoloads/inputs
needed, and anything in the web code that looked like a bug.
