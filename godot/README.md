# godot/: the Death Muffin client

Godot 4.7.2 project, renderer `gl_compatibility`. Run, test, export, publish: root [README.md](../README.md). Agent rules: [CLAUDE.md](../CLAUDE.md).
Decisions: [DECISIONS.md](../DECISIONS.md). Gaps: [KNOWN-GAPS.md](../KNOWN-GAPS.md).

## Folders

| Folder | Contents |
|---|---|
| `main/` | `DmMain` (entry scene, launch args, backend choice), camera rig, F3 perf overlay, QA driver (`-- --qa`) |
| `front/` | Login, discipline select, online gate; `DmFrontFlow` leads into the game. Settings has Logout (clears the token, login screen) and Switch character (final save, party left, select screen on the same token; login only if the server refuses it). One character per account: a discipline card selects the account's main character and switches its discipline (server `POST /character`); only an account with no character gets a new one |
| `next/` | `DmNextGame` and the game systems; one README per system folder (`next/README.md` has the overview) |
| `rules/<domain>/` | Pure game rules (no nodes): combat, core, dialogue, gathering, gear, inventory, loot, progression |
| `data/` | JSON content, read through `DmDb` / `DmData`; see `data/README.md` |
| `session/`, `net/` | `DmSession` (host/join, party of 4), REST client `DmApi`, `net/relay/` lobby client and `DmRelayPeer`, `net/offline/` and `DmMockBackend` (dev/test backend) |
| `enemies/`, `sim/`, `game/`, `world/`, `world_fx/`, `fx/`, `audio/` | Enemy scenes, shared sim data and boss brains, shared game classes (creatures, avatars, inventory, settings), world builder, effects, audio |
| `ui/`, `game_ui/`, `loot_view/` | Theme, panels, HUD, loot display |
| `assets/` | Imported models, audio and art (synced from `public/`, see [ASSET_PIPELINE.md](../ASSET_PIPELINE.md)) |
| `tests/<name>/` | Headless suites (`run.gd`, `*_run.gd`), picked up by `tools/godot/run-all-tests.sh` (parallel: each suite gets its own `user://` dirs and random ports from `tests/common/dm_test_ports.gd`; suites run with `--fixed-fps 60` except the real-time groups `REALTIME_GROUP` / `PACED_GROUP` in the script; slowest first by `tools/godot/suite-times.tsv`); `tests/common` holds helpers, `tests/playtest` the bot |

## Where features live

Start here for a request, then read the system's README. One row per feature; the backend side is under `server/death-muffin/backend/`.

| Feature | Client | Rules / data | Backend |
|---|---|---|---|
| Bags, inventory, Take / deposit, drag between slots | `game_ui/dm_ui_inventory.gd`, `game_ui/dm_ui_panels_b.gd`, `ui/widgets/dm_item_slot.gd`, `game/dm_inventory.gd` | `rules/inventory/vault_rules.gd` (port of `server/rules/gameplay/vaultRules.ts`) | `vault.cjs`, `bag-store.cjs` |
| Vault window | `ui/panels_b/dm_vault_panel.gd` | same | `vault.cjs` |
| Gear, Reliquary, equipping | `ui/panels/dm_reliquary_panel.gd`, `game/dm_loadout.gd`, `game/dm_gear_models.gd` | `rules/gear/`, `data/combat/armor.json`, `data/combat/necro_weapons.json` | `inventory-save.cjs`, `loadouts.cjs` |
| Abilities, rites, Reaper kit | `next/rites/` (`dm_rite_registry.gd`, `dm_reaper_rites.gd`, `rite_*.gd`), `game_ui/dm_rites.gd`, `game_ui/dm_spell_tooltip.gd` | `rules/combat/dm_abilities.gd`, `data/combat/abilities.json`, `data/combat/disciplines.json` | `discipline.cjs` |
| Grimoire, loadouts, keybinds | `ui/panels_a/dm_grimoire_window.gd`, `game_ui/dm_loadout_presets.gd`, `game_ui/dm_ui_binds.gd`, `next/next_input.gd` | `data/combat/abilities.json` | `loadouts.cjs` |
| HUD, action bar, orbs, minimap, tips | `ui/hud/` (`dm_hud.gd`, `dm_hud_slot.gd`, `dm_hud_minimap.gd`), `next/hud/`, `game_ui/dm_hud_reveal.gd`, `game_ui/dm_hud_tips.gd` | | |
| Settings, logout, switch character | `ui/panels/dm_settings_panel.gd`, `game_ui/dm_ui_settings.gd` | | |
| Loot drops, item cards, tooltips, dropped gear | `next/rewards/`, `loot_view/`, `ui/widgets/dm_item_card.gd`, `ui/widgets/dm_item_tooltip.gd`, `game_ui/dm_ui_inventory.gd` (Drop) | `rules/loot/`, `data/content/` | `loot.cjs`, `loot-instances.cjs`, `ground.cjs` |
| Enemies, bosses | `enemies/`, `next/spawn/`, `next/bosses/`, `game/dm_boss_view.gd` | `data/combat/enemies.json`, `sim/` | `kills.cjs`, `boss-key.cjs` |
| Hero body, avatar, death pose | `next/hero/dm_hero_body.gd`, `game/dm_avatar.gd` | | |
| Thralls, corpses | `next/thralls/`, `next/corpses/` | | |
| Co-op party, friends, Social window | `session/`, `net/relay/`, `next/party/`, `next/next_net.gd`, `ui/panels/dm_social_window.gd`, `game_ui/dm_ui_social.gd` | | `party-sessions.cjs`, `friends.cjs` (+ `server/death-muffin/lobby/`) |
| Crafting, gathering, garden, labor | `ui/panels_b/` (forge, salvage, garden, labor, professions), `next/gathering/` | `rules/gathering/`, `data/gathering/` | `gathering/`, `garden.cjs`, `labor.cjs` |
| F3 performance overlay | `main/perf_overlay.gd`, `next/perf/` | | |
| Bug report window | `game_ui/dm_bug_report_view.gd` | | `bug-reports.cjs` |
| API calls (one function per route), offline mock | `net/dm_api.gd`, `net/dm_mock_backend.gd` | | the route's `.cjs` |

## Conventions

- GDScript, typed. Files snake_case; `class_name` PascalCase with a `Dm` prefix.
- Rules are pure (`RefCounted` / static functions) so they test without nodes. Content comes from `godot/data`, not retyped.
- Rule suites check against committed golden fixtures in `tests/*/fixtures/`. Do not regenerate them without a reason.
- New autoloads and input actions are registered in `project.godot` by whoever integrates; `DmNextInput.ensure_actions()` adds the game's actions at runtime.
- Anything that renders (xvfb + llvmpipe) runs one at a time:
  `flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice xvfb-run -a -s "-screen 0 1280x800x24" godot --path godot --rendering-driver opengl3 -- --dev-offline --class=2 --qa --shots=/abs/dir`.
  UI shot plans: `godot/main/qa_ui_shots.gd` (`--shot-plan=<json>`; parsing test `tests/qa/run.gd`). World tour: `tests/world/tour.sh`.
