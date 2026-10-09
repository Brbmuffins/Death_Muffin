# godot/: the Death Muffin client

Godot 4.7.2 project, renderer `gl_compatibility`. How to run, test, export and publish is in the root
[README.md](../README.md); rules for agents in [CLAUDE.md](../CLAUDE.md); decisions in [DECISIONS.md](../DECISIONS.md);
what is missing in [KNOWN-GAPS.md](../KNOWN-GAPS.md).

## Folders

| Folder | Contents |
|---|---|
| `main/` | `DmMain` (entry scene, launch args, backend choice), camera rig, F3 perf overlay, QA driver (`-- --qa`) |
| `front/` | Login, discipline select, online gate; `DmFrontFlow` leads into the game |
| `next/` | `DmNextGame` and the game systems; one README per system folder (`next/README.md` has the overview) |
| `rules/<domain>/` | Pure game rules (no nodes): combat, core, dialogue, gathering, gear, inventory, loot, progression |
| `data/` | JSON content, read through `DmDb` / `DmData`; see `data/README.md` |
| `session/`, `net/` | `DmSession` (host/join, party of 4), REST client `DmApi`, `net/relay/` lobby client and `DmRelayPeer`, `net/offline/` and `DmMockBackend` (dev/test backend) |
| `enemies/`, `sim/`, `game/`, `world/`, `world_fx/`, `fx/`, `audio/` | Enemy scenes, shared sim data and boss brains, shared game classes (creatures, avatars, inventory, settings), world builder, effects, audio |
| `ui/`, `game_ui/`, `loot_view/` | Theme, panels, HUD, loot display |
| `assets/` | Imported models, audio and art (synced from `public/`; see ../ASSET_PIPELINE.md) |
| `tests/<name>/` | Headless suites (`run.gd`, `*_run.gd`), picked up by `tools/godot/run-all-tests.sh`; `tests/common` holds helpers, `tests/playtest` the bot |

## Conventions

- GDScript, typed. Files snake_case; `class_name` PascalCase with a `Dm` prefix.
- Rules are pure (`RefCounted` / static functions) so they test without nodes. Content comes from `godot/data`, not retyped.
- Rule suites check against committed golden fixtures in `tests/*/fixtures/`. Do not regenerate them without a reason.
- New autoloads and input actions are registered in `project.godot` by whoever integrates; `DmNextInput.ensure_actions()` adds the game's actions at runtime.
- Anything that renders (xvfb + llvmpipe) runs one at a time:
  `flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice xvfb-run -a -s "-screen 0 1280x800x24" godot --path godot --rendering-driver opengl3 -- --dev-offline --class=2 --qa --shots=/abs/dir`.
  UI shot plans: `godot/main/qa_ui_shots.gd` (`--shot-plan=<json>`; parsing test `tests/qa/run.gd`). World tour: `tests/world/tour.sh`.

## Performance reading

The F3 overlay splits the frame: `tick` is the game tick by system, `fx` the `Vfx` autoload, `ui` the HUD and counsel, `outside`
the rest (engine animation, culling, draw submission, GPU wait). If `outside` dominates, look at `calls` / `objects` and `render
cpu`; if sim or views grow with enemies, it is script cost. Only numbers from a real GPU count: the VPS runs software GL at about
7 fps. Perf probes live in `tests/perf/` and `tests/next/render_probe.gd`; per-system budgets are asserted in the `tests/next*` suites.
