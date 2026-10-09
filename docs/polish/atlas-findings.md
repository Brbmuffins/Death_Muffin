# Gear Atlas: data findings (2026-10-03)

Found while building `src/gameplay/atlas.ts` (every number in the Atlas and in `docs/LOOT-TABLES.md` is computed from the live tables). **Nothing here was changed except the two trivial icon fixes below**; balance is wt/polish-loot's. Re-run `npm run gen:loot` and the atlas tests after any loot change.

## Checked and clean

- Every loot-table entry (all 9 hunting grounds, every boss) is a known item id, and appears in the Atlas with ordinary, elite and Grave Surge odds that add up to the area's `itemChance` (x0.5 ordinary, x6 elite).
- No item is unobtainable: each of the 304 catalogue ids has a drop, a gathering find, a harvest, a recipe or a salvage source (legendary pieces drop from bosses and elites).
- **Capes and pets (checked for the owner's question on legendary capes):** there are 10 capes and 5 pets and no legendary or other rarity on capes at all; every cape has an obtainable requirement (level 99 in one of the 7 skills, or total level 100 / 300 / 693 of a possible 693), and every pet charm drops from its skill's gathering nodes (the Shroud Moth's also from Mourning Bed harvests). No cape is without a source. Capes are pure cosmetics, not items, so they cannot drop, be crafted or bought.
- No recipe references a missing item; every recipe ingredient has a source or a recipe of its own.
- The Atlas percentages were checked against 100k-600k rolls of the real `rollKill` / `rollBoss` / `rollFirstKillItem` / `rollBossRune` / `rollEliteRune` / `rollSurgeItem` / `rollGather` / Depths `rollChest` (`src/gameplay/__tests__/atlas.test.ts`).

## Fixed (trivial)

- `sapling_oak` and `sapling_yew` pointed at `art/items/sapling_oak.webp` / `sapling_yew.webp`, which do not exist; the art is `sapling_coffin_oak.webp` and `sapling_churchyard_yew.webp`. Icons set in `server/rules/content/items.ts`.

## Open: for the owner or wt/polish-loot

1. **The gear score ranks INT/VIT sets above every STR/AGI set, for every discipline.** For a Hollow Knight at the reference hero, a Gravecall (INT/VIT) chest adds +11.6% power and the knight's own Hollow Oath (STR/VIT) chest only +5.9%; a Bell Monk (STR/AGI) chest adds +3.0%, a Veilwalker (AGI/INT) +5.4%. The Atlas reports what `gearPower` says, so its "Fit" badges mark the non-necromancer sets Okay or Poor for their own wearers. STR and AGI are valued as "a little spell power" (`STAT_EFFECTS`). This is a balance question (the non-necromancer set stats, or the STR/AGI weights), not an Atlas bug. See `fitTable()` in `atlas.ts`.
2. **Key choice: F is reserved for throwables (README), and every other letter is taken**, so the Atlas is on `.` (period). Easy to change: one line in `WorldScene` (`k === '.'`), the HUD title, the counsel tip, the Codex text and the Settings key list.
3. **First-kill "rare relic" is often a material.** `rollFirstKillItem` draws from the area table until a rare or epic, and rare materials (Gold Ore, gems) count. Gear share of the guaranteed drop: Gravedigger 100% (always the Gold-Tempered Helm: the Hollow Graves table has no rare entry, so the historical fallback fires), Abbess 100%, Congregation 71%, Plague Saint 57%, Cinder Regent 55%, Mire Mother 40%. The toast says "a rare relic".
4. **Legendary armor also drops from elites on Depths floors 15 and deeper** (they roll the Cloister/Pyre/Fen table, which is level-scaled), 0.3% per elite like the scaled grounds. README, the Codex and the counsel tip list only "the Cloister, Pyre and Fen". Doc drift, not a bug; the Atlas and LOOT-TABLES.md include it.
5. **Sell-only materials** (nothing uses them): Tin Ingot, Bronze Ingot, Reliquary Fragment, Covenant Seal, Grave Garnet, Bone Opal, Void Sapphire. Probably intended as vendor trash; worth confirming.
6. **Gear only reachable by crafting**: Oak Shortbow (a bow with no class that uses it), Copper Plate and Copper Sword (crafted, never dropped).
7. **Missing art (shows the type glyph in the Atlas and Reliquary, no error):** `charm_tithe_bat`, `charm_grave_rat`, `charm_drowned_pup`, `charm_wee_thrall`, `charm_shroud_moth` and `ichor_mire` (Mire Ichor; the other six ichors have SVGs). Needs art, not code.
8. **Legendary odds are low by design but steep:** 0.98% per boss kill for one specific own-set piece (about 1 in 102 boss kills), 0.14% for a piece of another set; 20 pieces overall. Check against the owner's intent when the Depths and elites are tuned.
