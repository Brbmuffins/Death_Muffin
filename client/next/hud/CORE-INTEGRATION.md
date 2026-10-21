# The HUD on the core

Where each HUD piece reads from on the combat core, a guest's window and the pieces. The adapter and panels: [README.md](README.md); the HUD's draw calls: [ui/hud/PERFORMANCE.md](../../ui/hud/PERFORMANCE.md).

The HUD and panels run in the game scene (`opts.hud = true`; DECISIONS B46): `DmGameUi` (`game_ui/dm_game_ui.gd`) with every panel, on the
host-contract adapter `DmNextUiHost` (`next/hud/dm_next_ui_host.gd`), whose view-model is `DmNextHudVm` (`next/hud/dm_next_hud_vm.gd`: it reads the core's
arrays). `DmGameUi` applies the view-model every 50 ms (`HUD_INTERVAL_MS`) to `DmHud` (orbs, hotbar with cooldowns and the cast state, target frame, minimap, thrall pips, XP and
level, area line, banners, toasts, floating numbers, death veil). The adapter hears the core host instead of each enemy (`_watch_core`). Nothing runs per creature per frame:

| piece | where it reads |
|---|---|
| view-model refresh | `DmGameUi`'s 50 ms of wall time (`ui_host.hud_state()`): ~0.4 ms hot with a Full Party crowd and the panels' own keys merged (`tests/hud.gd`), about 0.9 ms in the fight with the caches cold; [The HUD's budget](../../ui/hud/PERFORMANCE.md) (CPU) says what that costs a frame |
| orbs, XP, level, area | the hero body (`hp`, `resource`), the character, `DmContent` |
| hotbar, cooldowns, cast state | the hero's `DmRiteCaster` (`cooldown_left`, essence, souls); the player's loadout (`DmLoadout`, the Grimoire's) |
| "no corpse" / "no legion" dimming | one `core.corpses_in_radius` (13 m around the hero) and `core.thrall_count` per refresh |
| target frame | `core.enemy_info(id)`, `core.statuses(id)` (4 bytes a status: id, stacks, tenths of a second) for the one enemy under the cursor or last aimed at (held 4 s, `ui_host.target_id()`); chips from its affix list |
| minimap dots | `enemy_ids / enemy_positions / enemy_states`, `thrall_positions / thrall_states`, `corpse_positions`: flat arrays, filtered in one pass into the packed lists the minimap takes; an elite is flagged from `enemy_spawned` |
| thrall count, pips, red pips | `core.thrall_places`, `thrall_owners / thrall_hp / thrall_states` (under 35 % health) |
| floating numbers | the caster's `hit_number` (the rites' own events, with the impact point), the core host's `enemy_damaged` of a thrall and `status_dot`, the hero's `hurt`; `DmFloatBudget` caps them (14 hit, 5 dot, 6 thrall, 22 in all, a crit 4 past); a guest's window below |
| boss plate, minimap dot | `g.bosses.active_boss()` (name, phase, hp; the King's dot on the map) |
| notices | `DmAreaFlow` (an area's first entry, a themed wave), a refused cast (an "info" number over the hero), the boss fx's banners and the summon refusals: all `DmNextGame.game_event`, which reaches `DmGameUi` |

**A guest's window.** In a party the HUD hears the same events from what reaches the guest. The numbers of both heroes' rites (crits too) are `hit_number` on every peer, from the rites' events the host broadcasts; an enemy's hit flash is the crowd's, from the
puppet core's `damaged` events (derived from the snapshots' health); a DoT's lumps are `status_dot` (they ride the reliable batches). The guest's own hero's hurt is the fall in the vitals the host sends at 20 Hz: `DmHeroBody.apply_vitals` emits `hurt` for the health a
body that was alive lost while its maximum stayed the same, once per message (blows within 50 ms are one number with the sum; a blow that killed is the health it took, where the host's counts the overkill; a heal, a respawn and a new maximum are none), and the HUD binds it as
it binds the host's own: a number over the hero, the red flash, the hurt sound, the low-health sound under 30 %, the counsel's hurt flag and tip. An enemy's drag of the guest's hero is told by `DmNextNet.hero_effect` ("Dragged!" and the camera shake; a chill and a root are
statuses, which replicate). No work per frame: all of it is events. A thrall's blow is a number over its enemy on a guest's window as on the host's: the puppet's `damaged` has no source, so the host lists each blow a thrall lands (`DmNextNet._on_enemy_damaged`: enemy id and damage, in the vitals message, at most `BLOWS_MAX` = 32 a message) and the guest's HUD floats them (`DmNextUiHost._on_thrall_blows`; the guest ignores its own derived events for this). In the Full Party fight that is about 27 blows a second, 0.2 KB/s and no extra packet. `tests/coop.gd` ("the guest's window") counts each of these on both HUDs and `tests/coop_bosses.gd` the guest's hurt in every boss fight.

The upgrades box (Empower, Quicken and the wave dial), the belt (Q, Z, X), the Kill Chain, the Omen, the save chip and the pickup lines come with value ([Value on the server](../rewards/AUTHORITY.md)); the menu row, the
panels and the Social window with `DmGameUi`. Not in the game scene yet, each with its system: the Altar (DECISIONS B36). The hub's prompts (the Chapterhouse node's hover and nearby lines) and the Depths readout, minimap floor and area line are in. The Acre ledger's panels (Skills, Garden, Laborers, Contracts) and the node and laborer cards are in ([Gathering and the Acre](../gathering/README.md#gathering-and-the-acre)). The HUD's suites, `hud_feeds.gd` among them: [README.md](README.md) "Tests".

**Pieces (DECISIONS B40).** Every readout group is a Control of its own with its own anchors and offsets, listed in `DmHud.pieces` (`party omen ward chain belt target boss map toasts banner prompt hint chat xp altar
upgrades`). `set_piece(id, offset, scale)` moves one by `offset` logical pixels and scales it (0.5 to 2) around the corner its anchor holds (a piece anchored to the top right grows left and down, the hotbar up and
sideways); `set_layout({id: {offset, scale}})` applies a saved layout (a piece it does not name goes home); `show_piece(id, false)` hides one for good; `set_hud_scale(0.75 to 1.3)` scales them all at once (Settings' HUD size sets it through `DmGameUi`).
Nothing calls `set_piece`, `set_layout` or `show_piece` yet: there is no editor, and this is the structure it will need.
