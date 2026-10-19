# In-game HUD (`client/ui/hud/`)

The in-game HUD controls. Built on the ui-kit (`DmUi` tokens, `dm_theme.tres`, `DmToast`, `DmBanner`, `DmFloatingNumber`, `DmCorners`, `DmUi.new_pip`).
It knows nothing about the world: `DmGameUi` feeds it a view-model, built in the game by `DmNextHudVm` (`client/next/hud/`) from the combat core. How the HUD is drawn in a handful of draw calls (one atlas, z layers, triangle meshes, a pool of floating numbers), what it costs and
where each readout reads from: client/README.md "The HUD on the core" and "The HUD's budget".

```gdscript
var hud := DmHud.new()          # full-rect, mouse-transparent Control; add it to the HUD CanvasLayer
add_child(hud)
hud.apply(vm)                   # state, every frame or on change (cheap: only rebuilds children when a list changes)
hud.toast("Level 31 reached", "good")        # one-shots: toast / loot_toast / banner / float_text / chat_line / hit_flash / slot_flash
hud.cast.connect(...)                         # intent out: signals (below)
```

Gallery: `godot --path client res://ui/hud/hud_gallery.tscn -- --page=combat|boss|calm|death|events --out=/x.png` (the pages are the mock view-models of `dm_hud_mock.gd`; "events" fires the one-shot calls).
Tests: `client/tests/hud.gd` (the HUD on the core). The game-side feed is `DmNextHudVm` (`client/next/hud/README.md`).

## View-model (`apply(vm: Dictionary)`)

Every key is optional; missing = zero / hidden. Units: HP in HP, cooldown in ms. `null` hides a readout.

| key | type | notes |
|---|---|---|
| `hp`, `max_hp`, `barrier` | number | orb fill = hp/max; bone barrier ring alpha = min(.9, barrier/max*3); vignette goes "low" under 30% (and hp>0) |
| `essence`, `max_essence` | number | right orb |
| `resource_label` | String | default "Grave Essence"; shown small-caps under the orb |
| `resource_color` | "#rrggbb" or "" | "" = necromancer violet; otherwise the family's resource colour restains the orb |
| `beat_pulse` | bool | gold ring on the resource orb (Monk beat) |
| `level`, `xp`, `xp_next` | number | level badge + XP bar with "x / y" |
| `dev` | bool | the DEV chip |
| `primary` | `{icon, key="LMB", rune_icon?}` | left-click socket; icon is a `res://` texture path |
| `slots` | Array of slot dicts | see below. Row rebuilds when the count or any `alt` flag changes |
| `grimoire_new` | bool | NEW pip on the "Spellbook" button |
| `souls`, `souls_max` | number | Soul Harvest meter; full -> "HARVEST" + jade. `soul_bag: true` (the Reaper) hides it: her bag is the energy orb (`essence` / `max_essence` carry the souls, slot `cost` is in souls) |
| `thralls`, `thrall_cap`, `raises_thralls`, `thrall_hurt` | number, number, bool, number | pips + chip appear when `raises_thralls` or `thralls > 0`; `thrall_hurt` = how many living thralls are under a third of their health (their pips are red) |
| `gold`, `shards` | number | currency row; `gold` also drives the buy buttons' enabled state |
| `damage` | `{tier, pct, cost}` | `cost: null` = max tier ("Max"). Bar/gems use the max tier from `data/content/upgrades.json` |
| `wave` | `{owned, active, pct, cost}` | same; the dial shows "Tier active / owned" and the milestone line (Elite Vanguard / Restless Crypts / Nightfall) |
| `area_name`, `area_progress` | String | `area_progress` may carry `<b>` (shown in spell-300) |
| `ward` | `{pct, thralls, per_thrall}` or null | Bone Ward chip; hidden at 0% |
| `brews` | Array | `{slot:"heal"|"elixir"|"tonic", key, label, glyph, color:int|"#hex", active, left (s), frac, count, empty, tip}` |
| `save` | `{text, warn}` | |
| `target` | `{name, elite, affixes:[{id,name}], hp, max_hp, statuses:[{icon(path), label, n}], blurb}` or null | hidden while `boss` is set |
| `boss` | `{name, phase (1-based), hp, max_hp, phases?:[String]}` or null | ticks at 60% / 30% |
| `party` | Array `{id, name, discipline, portrait(path), hp_frac}` | first 4 shown |
| `omen` | `{name, icon(path), blurb, visible}` or null | `visible:false` = hidden in safe areas |
| `depth` | `{depth, kills, need, open, chest}` or null | Catacomb Depths readout under the minimap |
| `chain` | `{count, name, bonus (0..1), frac, tier (0..5)}` or null | Kill Chain |
| `minimap` | see below | |
| `next` | String or null | the "Next" suggestion (its X emits `dismiss_next`) |
| `prompt` | String (`<kbd>`/`<b>` markup) or null | interaction prompt above the hint |
| `hint` | String | faint line above the altar |
| `death` | `{show, sub}` | "You have fallen" wash, fades 0.8 s |
| `auto_combat` | `{on, available, visible}` | the Auto button under the menu |
| `reveal` | `{id: bool}` | progressive HUD: `hud.upgrades hud.dial hud.shards hud.spells menu.atlas menu.skills`. **Absent id = revealed** (list only what is still held back) |
| `new` | `{id: bool}` | NEW pip + gold glow on the same ids (+ `hud.omen`); a click/hover on a NEW button emits `cue_used(id)` |

### slot dict (`slots[]`, and `primary`)
`{icon, key, cost, left_ms, total_ms, affordable, empowered, locked, unlock_level (10), alt, rune_icon, swap}`.
Cooldown sweep = clockwise shade from 12 o'clock of `round(left/total*100)` %, number = `ceil(s)` or one decimal under 1 s.
`affordable:false` dims it; `empowered` pulses jade (cost struck-through colour); `locked` greys it and prints `unlock_level`
(the greyed icons are baked into the HUD atlas on loading, and when a rite is put on the bar: `DmNextHudVm.warm_icons`, never in a fight);
`alt` = the right-click action (ember accent + left rule); `swap` shows the swap arrows on the key cap (swap-ready).

### minimap dict
`{px, pz, facing, areas:[{rect:{x0,z0,x1,z1}, safe, unlocked, instance?}], doors:[{rect, open}], enemies:[{x,z,elite}], thralls, allies, corpses, boss:{x,z}|null,
waystones, stairs, npcs:[{x,z,fresh}], ping:{x,z}|null, destination:{x,z}|null, depths:{rooms,doors,up,down,chest}|null}`.
`areas`/`doors` come from the world data (`AREAS`, `DOORS`); `unlocked`/`open` are the world's gate state. 2.1 px per world unit, north-up,
click on walkable ground emits `navigate(x, z)`. `DmNextHudVm` reuses the dot dictionaries between refreshes (rewritten in place), so a consumer must not keep them.
Drawing: colours are constants, the edge vignette is a static child layer, a sealed area's hatch is cached per area size, anything outside the disc is skipped, and the dots are one MultiMesh fed from the core's flat arrays.

## Events (methods)
`toast(text, kind)` kind `""|"good"|"err"|"new"` (dedupes the same line, 3 at most, newest 2 under a boss/target plate; hold = max(6 s, 2 s + 0.4 s/word)),
`loot_toast(name, qty, rarity)` (merges repeats to "Name x3", 3.5 s for common/uncommon, 8 s + gold edge for rare+, 4 stacked at most),
`banner(title, sub, ms)`, `float_text(screen_pos, text, kind, color?)` (kinds of `DmFloatingNumber`; the caller projects world to screen),
`hit_flash()`, `slot_flash(n)` (0 = LMB), `chat_line(text)`, `focus_chat()`, `banner_active()`.

## Signals (intent out)
`cast(slot)` (click on a slot icon, 0 = LMB primary, 1..N hotbar; key / right-click casting stays in the scene), `swap_slot(index)` (key cap click while `swap`), `buy_damage`, `buy_wave`, `dial_wave(delta)`,
`open_panel(id)` (inventory forge professions map grimoire atlas codex settings), `open_grimoire(select)`, `chat_sent(text)`, `toggle_auto_combat`,
`dismiss_next`, `report_bug`, `belt_clicked(slot)`, `navigate(x, z)`, `cue_used(id)`, `brew_dropped(slot, item_id)` (a brew dragged from the Reliquary onto a belt chip).

## Pieces
Every readout group is a Control of its own with its own anchors and offsets, listed in `DmHud.pieces` (`party omen ward chain belt target boss map toasts banner prompt hint chat xp altar upgrades`). `set_piece(id, offset, scale)` moves one by `offset` logical pixels and scales it (0.5 to 2)
around the corner its anchor holds; `set_layout({id: {offset, scale}})` applies a saved layout (a piece it does not name goes home); `show_piece(id, false)` hides one for good; `set_hud_scale(0.75 to 1.3)` scales them all at once (Settings' HUD size calls it through `DmGameUi`). Nothing calls `set_piece`, `set_layout` or `show_piece` yet: there is no editor,
and this is the structure it will need (DECISIONS B40).

## Counsel-tip anchors
`tip_anchor_rect(tip_id) -> Rect2` returns the global rect of the HUD part a tip is about (`TIP_ANCHOR` ids: `minimap belt brew wave chain omen prelate grimoire atlas codex relic gather`;
`Rect2()` when hidden/unknown) so the integrator can draw the glow; `tip_default_position()` is the card's default spot (18, 70, or under the party list).

## Notes
- Cost: `apply` skips a section (`SECTIONS` in `dm_hud.gd`: flags, vitals, souls, economy, upgrades, ward, chain, brews, omen, party, target, column, misc) when the view-model keys it reads hash the same as at the last apply; `DmHudSlot.apply` skips an unchanged slot dict
  (a rite on cooldown changes its seconds and sweep only). Slots run `_process` only while empowered or flashing, orbs only while visible, the minimap only while a guidance ping pulses. A new readout should read its inputs through a section so it is covered; the Kill Chain meter has a
  section of its own because it moves with every refresh while a chain runs.
- Draw cost: panels are 9-patches of one atlas (`DmHudAtlas.nine`), icons regions of it, rectangles its white block, text one z layer per (font, size), the orbs, cooldown sweeps, thrall pips, minimap frame and death veil triangle meshes (`DmHudMesh`), the floating numbers a pool of 48 (`DmHudFloats`).
  A new control must be put on its layer when it is made (`DmHudKit.layer_tree`), or it breaks a batch; `client/tests/hud.gd` counts the draw calls against the 150 budget (client/README.md "The HUD's budget").
- Orbs: the dish (rings, bowl), the liquid body and the gloss are triangle bags; the dish and gloss are built once, the body only while the shown fill eases or the palette really changes (`use_*_palette` / `set_resource_color` ignore an unchanged colour); the surface ripple is redrawn 15 times a second while it moves.
- The adapter caches what never changes per refresh: `DmNextHudVm._rite(id)` (icon path, unlock level, costs, base cooldown), the current area definition, `DmAbilities.unlock_level` (memo), and `DmNextBelt` tip sentences (rebuilt only when the flask, count or vow changes).
- Hover: ability slots show no tooltip or spell card (owner request: spell info lives in the Grimoire; the card code behind `hud.spell_card` is kept but not wired to hover). Belt chips, the omen chip, Bone Ward, souls etc. keep native tooltips. The belt picker lives in `client/game_ui/dm_belt_picker.gd` (belt chips emit `belt_clicked`). `hud.node_tip(html, x, y)` draws the node tip (the game feeds it from the node under the cursor).
- Toasts take an `on_click` Callable (`hud.toast(text, kind, on_click)`): a NEW cue toast opens its panel when clicked.
- Slots emit `cast` on click but there is no drag; keyboard casting lives in `DmNextInput`, not the HUD. Slot dicts may carry a `tooltip` string.
- Rune badges, the Grimoire button pulse (6 s) and the glows are drawn rings; text `letter-spacing` is rounded to whole pixels (FontVariation).
- Chrome glyphs are SVGs in `art/`; ability / omen / portrait art in `art/` is a small copy for the gallery only (the game passes real paths).
