# The game client

The Death Muffin client: its own Godot 4.7.2 project, the game since launch day (2026-10-18; DECISIONS B34-B50 record how it was built and launched). `publish-godot-client.sh` publishes it to everyone; the
launcher's Test build channel keeps its last test build. The first Godot game, the old game, is kept as the tag `archive/old-game` (B57): nothing is copied from it, and this project owns all its files
([next/ARCHITECTURE.md](next/ARCHITECTURE.md)).

- Renderer: Forward+ (`project.godot`), Compatibility only as the automatic fallback, the Mobile renderer for phones (B35). Textures also
  import in phone formats (B40).
- Its `user://` folder is named after `config/name`, "Death Muffin (rebuild)" (KNOWN-GAPS "Leftovers from the web era").
- It plays on the **live server** and never reaches the test server ([The API rule](net/README.md)).
- The combat core is a C++ GDExtension built from [native/](../native/README.md) into `bin/` (built files are not committed;
  `bin/dmcore.gdextension` is).
- Crowds are drawn from baked vertex-animation textures, one MultiMesh per creature model and level of detail, driven by the combat core through `CrowdView`:
  [crowd/README.md](crowd/README.md).

This file is the client's index. Find the feature or the task below, then read that one guide and the code it names; do not read every guide.
In one line: `main/` boots, `front/` signs in, `next/` is the game scene and its systems, `core/` and `crowd/` host and draw the combat
core, `rules/` and `data/` hold the game's rules and content, `ui/` and `game_ui/` the interface, `tests/` the suites (every folder:
[next/ARCHITECTURE.md](next/ARCHITECTURE.md)).

## System guides

One short README per system folder (`<folder>/README.md`): how the system works and its known gaps (the combat core, with its affixes, corpses and thralls, is [native/README.md](../native/README.md); guides that span systems are in "Guides by task" below).
- The game scene and its parts: `next/` (the scene's nodes and seams), `next/spawn/`, `next/areas/`, `next/chapterhouse/`, `next/depths/`, `next/bosses/` with the brains in `sim/bosses/`, `next/rites/`, `next/feel/`, `next/hero/`, `next/status/`, `next/enemy_fx/`.
- Value and the player's account: `next/rewards/` (with the loot node), `next/progress/`, `next/meta/`, `next/gathering/`, `next/party/` (friends, the lobby, a guest's own account).
- What the player sees and hears: `next/hud/`, `ui/hud/`, `ui/onboarding/`, `game/` (creatures, gear look, settings), `fx/`, `world_fx/`, `audio/`, `next/perf/` (graphics controls, the warm-up, the benchmark, the play reports, the F3 overlay), `next/look/` (colours and the exposure lift).
- The server, the world and the data: `front/`, `net/`, `world/` (the area scenes), `data/`, `sim/`.

**Where features live.** Start here for a request, then read the system's README. One row per feature; paths are from `client/`, the backend side is under `server/death-muffin/backend/`.

| Feature | In the client | Backend |
|---|---|---|
| Bags, inventory, take / deposit, drag between slots | `game_ui/dm_ui_inventory.gd`, `game_ui/dm_ui_panels_b.gd`, `ui/widgets/dm_item_slot.gd`, `game/dm_inventory.gd`; rules `rules/inventory/vault_rules.gd` | `vault.cjs`, `bag-store.cjs` |
| Vault window | `ui/panels_b/dm_vault_panel.gd` | `vault.cjs` |
| Gear, Reliquary, equipping | `ui/panels/dm_reliquary_panel.gd`, `game/dm_loadout.gd`, `game/dm_gear_models.gd`; rules and data `rules/gear/`, `data/combat/armor.json`, `data/combat/necro_weapons.json` | `inventory-save.cjs`, `loadouts.cjs` |
| Abilities, rites, Reaper kit | `next/rites/`, `game_ui/dm_rites.gd`, `game_ui/dm_spell_tooltip.gd`; rules and data `rules/combat/dm_abilities.gd`, `data/combat/abilities.json`, `data/combat/disciplines.json` | `discipline.cjs` |
| Grimoire, loadouts, keybinds | `ui/panels_a/dm_grimoire_window.gd`, `game_ui/dm_loadout_presets.gd`, `game_ui/dm_ui_binds.gd`, `next/next_input.gd` | `loadouts.cjs` |
| HUD, action bar, orbs, minimap, tips | `ui/hud/`, `next/hud/`, `game_ui/dm_hud_reveal.gd`, `game_ui/dm_hud_tips.gd` | |
| Settings, logout, switch character | `ui/panels/dm_settings_panel.gd`, `game_ui/dm_ui_settings.gd` | |
| Loot drops, item cards, tooltips, dropped gear | `next/rewards/`, `loot_view/`, `ui/widgets/dm_item_card.gd`, `ui/widgets/dm_item_tooltip.gd`, `game_ui/dm_ui_inventory.gd` (Drop); rules and data `rules/loot/`, `data/content/` | `loot.cjs`, `loot-instances.cjs`, `ground.cjs` |
| Enemies, bosses, Grave Surges | the combat core ([native/README.md](../native/README.md)), `next/spawn/`, `next/areas/` (the surges), `next/bosses/`, `game/dm_boss_view.gd`, `crowd/`; data `data/combat/enemies.json`, `sim/` | `kills.cjs`, `boss-key.cjs` |
| Hero body, avatar, death pose | `next/hero/dm_hero_body.gd`, `game/dm_avatar.gd` | |
| Thralls, corpses, affixes | the combat core (native/README.md "Affixes, corpses and thralls"), `core/dm_core_legion.gd`, `core/dm_core_corpses.gd`, `core/dm_affix_roll.gd`; the Mourning Bell's heal and a fallen plague bearer's pool `next/rites/dm_legion_events.gd` | |
| Co-op party, friends, Social window | `session/`, `net/relay/`, `next/party/`, `next/next_net.gd`, `ui/panels/dm_social_window.gd`, `game_ui/dm_ui_social.gd` | `party-sessions.cjs`, `friends.cjs` (and the lobby, `server/death-muffin/lobby/`) |
| Crafting, gathering, garden, labor | `ui/panels_b/`, `next/gathering/`; rules and data `rules/gathering/`, `data/gathering/` | `gathering/`, `garden.cjs`, `labor.cjs` |
| F3 performance overlay | `main/perf_overlay.gd`, `next/perf/` | |
| Play reports (what a session sends when it ends) | `next/perf/dm_play_report.gd`, `next/perf/dm_play_report_queue.gd`, `main/main.gd` | the play-reports route |
| Bug report window, automatic crash reports | `game_ui/dm_bug_report_view.gd`, `main/dm_crash_watch.gd`, `main/main.gd` | `bug-reports.cjs` |
| API calls (one function per route), offline mock | `net/dm_api.gd`, `net/dm_mock_backend.gd` | the route's `.cjs` |

## Guides by task

The detailed guides, beside the code they describe (a backticked path in a client guide is from `client/` unless it says otherwise). Each row also keeps the link of the section of this file it used to be.

| Task | Read |
|---|---|
| <a id="set-up-and-test"></a>Set up a checkout, run or write a test | [TESTING.md](tools/TESTING.md); every suite: [TEST-SUITES.md](tools/TEST-SUITES.md) |
| <a id="how-the-project-is-organised"></a><a id="the-game-scene-and-the-dev-entry"></a>Where things live; the game scene, launch and the dev entry | [ARCHITECTURE.md](next/ARCHITECTURE.md) |
| <a id="screenshots-for-proposals"></a>Screenshots of a proposal, the QA run's flags | [SCREENSHOTS.md](main/SCREENSHOTS.md) |
| <a id="clips-and-tune"></a>Clips of a rite, data overrides (`--tune=`) | [CLIPS.md](main/CLIPS.md) |
| <a id="release-checks"></a>Release checks (boot, stutter, soak) | [RELEASE-CHECKS.md](main/RELEASE-CHECKS.md) |
| <a id="grave-surges"></a>Grave Surges | [SURGES.md](next/areas/SURGES.md) |
| <a id="the-gravecallers-rites"></a>Rites on the combat core | [CORE-INTEGRATION.md](next/rites/CORE-INTEGRATION.md) |
| <a id="the-bosses"></a>Bosses on the combat core | [CORE-INTEGRATION.md](next/bosses/CORE-INTEGRATION.md) |
| <a id="the-benchmark"></a>The benchmark | [BENCHMARK.md](next/perf/BENCHMARK.md); reading its report: [BENCHMARK-REPORT.md](next/perf/BENCHMARK-REPORT.md) |
| <a id="the-draw-budget"></a>3D draw calls | [DRAW-BUDGET.md](next/perf/DRAW-BUDGET.md) |
| <a id="graphics-presets"></a>Graphics presets | [next/perf/](next/perf/README.md#graphics-presets) |
| <a id="the-look-on-forward"></a>Colours, the exposure lift, the old game's look | [next/look/](next/look/README.md) |
| <a id="world-dressing"></a>World dressing | [world_fx/](world_fx/README.md#world-dressing) |
| <a id="the-effects"></a>What the effects cost on the core | [fx/](fx/README.md#the-effects) |
| <a id="the-hud-on-the-core"></a>What the HUD reads, a guest's HUD | [CORE-INTEGRATION.md](next/hud/CORE-INTEGRATION.md) |
| <a id="the-huds-budget"></a>The HUD's draw calls and frame cost | [PERFORMANCE.md](ui/hud/PERFORMANCE.md) |
| <a id="tips-and-onboarding"></a>Tips and onboarding | [ui/onboarding/](ui/onboarding/README.md#tips-and-onboarding) |
| <a id="sound"></a>Which sound plays for which event | [audio/](audio/README.md#sound) |
| <a id="threads"></a>Work off the main thread | [THREADING.md](core/THREADING.md) |
| <a id="value-on-the-server"></a>Value on the server (kills, drops, saves) | [AUTHORITY.md](next/rewards/AUTHORITY.md) |
| <a id="gathering-and-the-acre"></a>Gathering and the Acre | [next/gathering/](next/gathering/README.md#gathering-and-the-acre) |
| <a id="co-op-on-the-core"></a>Co-op: the puppet core, messages, bosses in a party | [CORE-NETWORK.md](next/party/CORE-NETWORK.md); joining and the Social window: [next/party/](next/party/README.md#joining-and-the-social-window); a local trial and its proof: [TESTING.md](next/party/TESTING.md) |
| <a id="the-server-login-and-character-select"></a>Login and character select | [front/](front/README.md) |
| <a id="the-api-rule-decisions-b38-b49"></a>Which server the client talks to (the API rule) | [net/](net/README.md) |
| <a id="assets"></a>Importing art, models and audio | [ASSETS.md](tools/ASSETS.md) |
| <a id="the-depths"></a>A Depths run on the core | [CORE-INTEGRATION.md](next/depths/CORE-INTEGRATION.md) |
| <a id="areas"></a>Area scenes, conversion, lighting | [world/](world/README.md) |
