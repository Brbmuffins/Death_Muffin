# Combat clarity (necromancer)

What the clarity pass (2026-10-07) added to DmNextGame so combat reads without new content. Audit tools: `tests/next_clarity/audit.gd` (cue count per
rite in the first 0.25 s and 4 s), `shoot.gd` (rendered Ossuary fight). The cue lock is `tests/next_clarity/cues_run.gd`.

## What exists
- **Cast cue**: every one of the 25 rites gives >= 3 visual calls and a sound within 0.25 s (locked by `cues_run.gd`). Marrow Spear plays the existing
  `needleCast` whoosh at 0.9 on the press, because its own sound is the landing (`next/rites/rite_marrow_spear.gd`).
- **Slot needs**: a rite that cannot fire dims lightly and says "no corpse" / "no legion". `DmNextHudVm.NEEDS` maps exhume, corpse_explosion,
  grave_offering, grave_step, carrion_seed to corpse and rally_dead, command_rend to legion; the test reads every `rite_*.gd` for `"no_corpse"` / `"no_thralls"`
  so a new rite cannot be forgotten. Slot rendering: `ui/hud/dm_hud_slot.gd`.
- **Thrall health**: a thrall under 35 % health wears a larger pulsing red ground ring until it is back above 50 % (`DmThrall.LOW_HP_ENTER` / `LOW_HP_LEAVE`);
  thrall pips under a third turn red (`ui/hud/dm_hud_parts.gd`, `thrall_hurt` in `dm_hud.gd`).
- **Damage-number cap**: `DmFloatBudget` (`next/hud/dm_float_budget.gd`, used by `DmNextUiHost.float_text`): hits + crits 14 (a crit gets +4), dot 5,
  thrall 6, hard total 22; hurt / gold / heal / info are never limited.
- Cost: needs pass 6 us per HUD build, float `allow()` 1.9 us per call, low-hp ring two compares per thrall per frame.

## Open
1. At 1280 x 800 the Damage / Wave Speed upgrade panel (bottom right, 300 px) overlaps the essence orb. Shared HUD layout, not changed.
2. The float caps are judgement numbers; loosen if a crit-heavy build feels muted.
3. Corpse marks inside the hero's reach are not brighter than others (would need a per-frame distance test).
4. No boss-fight screenshot review of telegraph vs hero effect hues on real hardware.
