# In-game HUD (`godot/ui/hud/`)

The in-game HUD controls. Built on the ui-kit (`DmUi` tokens, `dm_theme.tres`, `DmToast`, `DmBanner`, `DmFloatingNumber`, `DmCorners`, `DmUi.new_pip`).
It knows nothing about the world: `DmGameUi` feeds it a view-model, built in the game by `DmNextHudVm` (`next/hud/`).

```gdscript
var hud := DmHud.new()          # full-rect, mouse-transparent Control; add it to the HUD CanvasLayer
add_child(hud)
hud.apply(vm)                   # state, every frame or on change (cheap: only rebuilds children when a list changes)
hud.toast("Level 31 reached", "good")        # one-shots: toast / loot_toast / banner / float_text / chat_line / hit_flash / slot_flash
hud.cast.connect(...)                         # intent out: signals (below)
```

Gallery: `ui/hud/shoot.sh combat|boss|calm|death|events [out.png] [WxH]` (renderer lock + Xvfb; screenshots land in the gitignored `shots/hud/`).
Tests: `godot --headless --path godot --script res://tests/ui/run.gd (hud_part)`. The game-side feed is `DmNextHudVm` (`next/hud/README.md`).

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
| `souls`, `souls_max` | number | Soul Harvest meter; full -> "HARVEST" + jade |
| `thralls`, `thrall_cap`, `raises_thralls` | number, number, bool | pips + chip appear when `raises_thralls` or `thralls > 0` |
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
| `reveal` | `{id: bool}` | progressive HUD: `hud.upgrades hud.dial hud.shards hud.spells menu.spells menu.atlas menu.skills`. **Absent id = revealed** (list only what is still held back) |
| `new` | `{id: bool}` | NEW pip + gold glow on the same ids (+ `hud.omen`); a click/hover on a NEW button emits `cue_used(id)` |

### slot dict (`slots[]`, and `primary`)
`{icon, key, cost, left_ms, total_ms, affordable, empowered, locked, unlock_level (10), alt, rune_icon, swap}`.
Cooldown sweep = clockwise shade from 12 o'clock of `round(left/total*100)` %, number = `ceil(s)` or one decimal under 1 s.
`affordable:false` dims it; `empowered` pulses jade (cost struck-through colour); `locked` greys it and prints `unlock_level`;
`alt` = the right-click action (ember accent + left rule); `swap` shows the swap arrows on the key cap (swap-ready).

### minimap dict
`{px, pz, facing, areas:[{rect:{x0,z0,x1,z1}, safe, unlocked, instance?}], doors:[{rect, open}], enemies:[{x,z,elite}], thralls, allies, corpses, boss:{x,z}|null,
waystones, stairs, npcs:[{x,z,fresh}], ping:{x,z}|null, destination:{x,z}|null, depths:{rooms,doors,up,down,chest}|null}`.
`areas`/`doors` come from the world data (`AREAS`, `DOORS`); `unlocked`/`open` are the sim's gate state. 2.1 px per world unit, north-up,
click on walkable ground emits `navigate(x, z)`. `DmNextHudVm` reuses the dot dictionaries between refreshes (rewritten in place), so a consumer must not keep them.
Drawing: colours are constants, the edge vignette is a static child layer, a sealed area's hatch is cached per area size, and anything outside the disc is skipped.

## Events (methods)
`toast(text, kind)` kind `""|"good"|"err"|"new"` (dedupes the same line, 3 at most, newest 2 under a boss/target plate; hold = max(6 s, 2 s + 0.4 s/word)),
`loot_toast(name, qty, rarity)` (merges repeats to "Name x3", 3.5 s for common/uncommon, 8 s + gold edge for rare+, 4 stacked at most),
`banner(title, sub, ms)`, `float_text(screen_pos, text, kind, color?)` (kinds of `DmFloatingNumber`; the caller projects world to screen),
`hit_flash()`, `slot_flash(n)` (0 = LMB), `chat_line(text)`, `focus_chat()`, `banner_active()`.

## Signals (intent out)
`cast(slot)` (click on a slot icon, 0 = LMB primary, 1..N hotbar; key / right-click casting stays in the scene), `swap_slot(index)` (key cap click while `swap`), `buy_damage`, `buy_wave`, `dial_wave(delta)`,
`open_panel(id)` (inventory forge professions map grimoire atlas codex settings), `open_grimoire(select)`, `chat_sent(text)`, `toggle_auto_combat`,
`dismiss_next`, `report_bug`, `belt_clicked(slot)`, `navigate(x, z)`, `cue_used(id)`.

## Counsel-tip anchors
`tip_anchor_rect(tip_id) -> Rect2` returns the global rect of the HUD part a tip is about (`TIP_ANCHOR` ids: `minimap belt brew wave chain omen prelate grimoire atlas codex relic gather`;
`Rect2()` when hidden/unknown) so the integrator can draw the glow; `tip_default_position()` is the card's default spot (18, 70, or under the party list).

## Notes
- Cost: `apply` skips a section (`SECTIONS` in `dm_hud.gd`: vitals, economy, upgrades, left readouts, target, column, misc) when the view-model keys it reads hash the same as at the last apply; `DmHudSlot.apply` skips an unchanged slot dict. Slots run `_process` only while empowered or flashing, orbs only while visible, the minimap only while a guidance ping pulses. A new readout should read its inputs through a section so it is covered.
- Hover: ability slots show no tooltip or spell card (owner request: spell info lives in the Grimoire; the card code behind `hud.spell_card` is kept but not wired to hover). Belt chips, the omen chip, Bone Ward, souls etc. keep native tooltips. The belt picker lives in `game_ui/dm_belt_picker.gd` (belt chips emit `belt_clicked`). `hud.node_tip(html, x, y)` draws the node tip (the game feeds it from the node under the cursor).
- Toasts take an `on_click` Callable (`hud.toast(text, kind, on_click)`): a NEW cue toast opens its panel when clicked.
- Slots emit `cast` on click but there is no drag; keyboard casting lives in `DmNextInput`, not the HUD. Slot dicts may carry a `tooltip` string.
- Rune badges, the Grimoire button pulse (6 s) and the glows are drawn rings; text `letter-spacing` is rounded to whole pixels (FontVariation).
- Chrome glyphs are SVGs in `art/`; ability / omen / portrait art in `art/` is a small copy for the gallery only (the game passes real paths).
