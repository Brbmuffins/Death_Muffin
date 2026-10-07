# Combat clarity pass (necromancer), 2026-10-07

Branch `godot/next-clarity` off `godot-next`. Method: a headless cue audit of all 25 rites (`tests/next_clarity/audit.gd`: visual primitives and sounds in the 0.25 s after an
accepted cast, full 4 s as the second column), rendered fights of the Ossuary on the rebuild (`tests/next_clarity/shoot.gd`), and a read of the HUD / fx code both games share.
The HUD, `DmFloatingNumber`, `DmRiteFx`, the boss telegraphs and the corpse marks are the same code in the current game (`DmGame`) and the rebuild, so most things were
already at parity; the changes below are where the rebuild can be *clearer* without new content.

## Checked

| area | finding | action |
|---|---|---|
| Cast cue per rite (25 of 25) | every rite gives >= 3 visual calls inside 0.25 s and a sound; the weakest are the projectile rites (`rot_lance` 3, `marrow_spear` 3, `bone_storm` 3, `carrion_seed` 3: muzzle flash + beam / shot) | locked by `tests/next_clarity/cues_run.gd` |
| Marrow Spear sound | the only silent-at-the-press rite: its sound plays on landing, 0.25 s of flight later (the current game is the same) | the rebuild's cast event now plays the existing `needleCast` whoosh at 0.9 |
| Ready / cooldown / essence on the bar | cooldown sweep + seconds, dim when out of essence, jade pulse when Soul Harvest makes it free, lock + level: all present and fed correctly | none |
| Rite that cannot fire (no corpse / no legion) | the bar looked ready; the press then gave no feedback (`no_corpse` / `no_thralls` are silent refusals) | slot now dims lightly and says "no corpse" / "no legion" (see below) |
| Thrall count | pips + `n/cap` chip, fine | pips of living thralls under a third of their health turn red; the number goes salmon |
| Thrall health | none anywhere: only a teal ring | a thrall under 35 % health wears a larger pulsing red ground ring until it is back above 50 % |
| Corpse visibility | pale marks (capped at `MARKS_MAX`), resonant violet, toxic green, as the current game; readable in the shots (rings distinct from the teal thrall rings and the red low-health ones) | none |
| Bone Ward / Soul Harvest chips | "BONE WARD -N %" and the skull bar with "HARVEST" in jade are shown and fed (`thralls`, `ward`, `souls`) | none |
| Damage-number clutter | **no cap at all** in either game; each number is a Label + 3 tweens, and a legion + Miasma + an area rite spawns dozens per second | `DmFloatBudget` caps what is alive: hits + crits 14 (a crit gets +4 over), dot 5, thrall 6, hard total 22; hurt / gold / heal / info never limited |
| Enemy telegraphs vs hero effects | telegraphs are the shared red/ember `DmEventFxBoss` / `DmBossFx` shapes; hero rites are violet / teal / bone. Distinct hues, so no change. A rendered boss shot was not captured (the arena scene under software GL did not reach a telegraph inside the time box) | open: owner may want a boss screenshot review on real hardware |
| Essence orb at 1280 x 800 | the Damage / Wave Speed upgrade panel (bottom-right, 300 px wide) overlaps the essence orb at the project's default 1280-wide window; same in the current game | open, see below |

## Changed

- `next/hud/dm_next_hud_vm.gd` + `ui/hud/dm_hud_slot.gd`: slot key `needs` ("corpse" / "legion"). Table `DmNextHudVm.NEEDS` (exhume, corpse_explosion, grave_offering, grave_step, carrion_seed ->
  corpse; rally_dead, command_rend -> legion). The test reads every `rite_*.gd` for `"no_corpse"` / `"no_thralls"` so a new rite cannot be forgotten. The note hides while the cooldown number is up and on a locked slot.
- `next/thralls/dm_thrall.gd`: low-health ring (`LOW_HP_ENTER` 0.35, `LOW_HP_LEAVE` 0.5, `_low_hp_check` in `_process`).
- `ui/hud/dm_hud_parts.gd` (Diamonds state 2 = red), `ui/hud/dm_hud.gd` (`thrall_hurt`): backwards compatible, the current game feeds bools.
- `next/hud/dm_float_budget.gd`, used by `DmNextUiHost.float_text`.
- `next/rites/rite_marrow_spear.gd`: the cast-time whoosh.

## Shots (the 1280 x 800 rebuild, Ossuary, rendered under xvfb)

- before: `/home/ubuntu/death-muffin/clarity/before/before-class1-a.png`, `.../before-class1-b.png` (a fight; thralls have only a teal ring, corpse rites show no state)
- after (same scene, different random spawns): `/home/ubuntu/death-muffin/clarity/after/after-class1-a.png`, `.../after-class1-b.png`
- after, the bar on its own (no enemies, no corpses, four thralls, two hurt): `/home/ubuntu/death-muffin/clarity/after/after-bar.png`: red rings on the two hurt thralls, "no corpse" on Exhume and Corpse Explosion, two red pips.
  There is no "before" for this exact scene (the old code has none of these states); the before shots show the unchanged look of the same elements.

## Cost (headless, shared VPS)

| change | cost |
|---|---|
| needs pass (one loop over the corpse field + the legion count, once per 20 Hz HUD build) | 5.7 - 6.3 us per build (the whole `hud_state()` is ~0.65 ms) |
| low-health ring | 2 float compares per living thrall per frame; a decal rebuild only when it flips (once per crossing) |
| float budget `allow()` | 1.9 us per call, only when a number is about to be shown; it removes Labels, so it only ever saves work |
| spear whoosh | one more `play_sfx` per cast |

## Open items for the owner

1. Essence orb vs the upgrades panel at 1280 wide (shared HUD layout, both games). Fix would be to shrink or collapse the upgrades panel below a width, or lift it above the currency row; it is the owner's HUD, so not touched.
2. Float caps (14 / 5 / 6 / 22) are judgement numbers: loosen if a crit-heavy build feels muted.
3. The corpse marks are the current game's (pale, 0.4 opacity). Brighter marks for corpses inside the hero's reach would help the corpse rites, but costs a per-frame distance test or a marks rebuild; not done.
4. A boss-fight screenshot comparison (telegraph vs hero rites) on real hardware.
