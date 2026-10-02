# Discipline armor sets

Two collections of nine five-piece sets use the existing head, chest, hands, legs and feet slots. They are themed for each discipline, but any class can equip them; changing class never strands worn gear. Each set has its own color, accent, head ornament and five matching vector inventory icons. The hero's existing body-region shader colors worn chest, hands, legs and feet. Ascended gear adds a second crown rim and a brighter material glow. The Reliquary counts pieces within each specific set.

| Discipline | First set | Ascended set | Stat focus |
| --- | --- | --- | --- |
| Gravecaller | Gravecall | Epitaph Sovereign | INT, VIT |
| Grave Warden | Lamplight | Nightwatch Beacon | VIT, STR |
| Bell Monk | Bellwake | Last Toll | STR, AGI |
| Ossuary | Ivory Reliquary | Marrow Regent | INT, VIT |
| Mourner | Widowveil | Pale Requiem | INT, AGI |
| Carrion Witch | Carrionbloom | Thorn Covenant | INT, VIT |
| Rotweaver | Blightweave | Virulent Choir | INT, VIT |
| Hollow Knight | Hollow Oath | Oathbreaker | STR, VIT |
| Veilwalker | Threshold | Umbral Crossing | AGI, INT |

Every class has the same drop progression: uncommon crowns and grips in the Hollow Graves, rare vestments in the Marrow Ossuary, rare legguards in the Drowned Nave, and epic treads in the Bell Sanctum. The Plague Cloister and Cinder Pyre can also drop the three later pieces. All five pieces enter normal area loot and boss rolls; item chance, elite bonus and wave modifiers still apply. There is no class restriction; set bonuses are described below.

The ascended collection continues that path for every class: rare crowns and grips in the Bell Sanctum, epic vestments and legguards in the Plague Cloister, and epic treads in the Cinder Pyre. The Cinder Pyre can also drop the ascended Cloister pieces. Each ascended part grants more of the same two stats than its first-set counterpart, so gear upgrades remain legible. The later collection has distinct IDs and can displace first-set gear through the normal equip flow.

The catalog lives in `src/content/armorSets.ts`. Run `node tools/generate-armor-assets.mjs` after changing it to regenerate 90 SVG icons and both additive migrations: `011-class-armor.sql` for the first collection and `012-ascended-armor.sql` for the second. Apply both in order to the **Death Muffin database** after a backup and before publishing a client that can drop these IDs. The server's item rows supply real stats and equipment slots; the offline catalog reads the same manifest. Run `npm run build:server-rules` after changing area loot.


## Set bonuses

Wear 2, 4 or 5 pieces of the **same** set (the first and ascended collections count separately) for a bonus. Bonuses stack: five pieces gives the 2, 4 and 5 piece lines together. Two sets at two pieces each give both first bonuses. Numbers live in `src/content/setBonuses.ts`; the Reliquary tooltip, the Character sheet, the Codex "Armor sets" tab and this table are generated or checked against it.

The four necromancer sets use the levers their discipline already has: **Ossuary** (thrall health, ward per thrall, Black Litany barrier, health), **Gravecaller** (thrall damage and attack speed, +1 thrall cap at five), **Mourner** (essence regeneration, corpse healing, wraith damage), **Rotweaver** (Miasma radius, maximum Withered stacks). The ascended sets are a step up at every tier. The other five disciplines have no thralls or rites to scale, so their sets give flat STR/AGI/INT/VIT and maximum health or essence regeneration. Any class may wear any set; lines a class cannot use (thrall and rite effects on a non-necromancer) are shown as "no effect for your class" and are not counted in its gear score.

| Set | Discipline | 2 pieces | 4 pieces | 5 pieces |
| --- | --- | --- | --- | --- |
| Gravecall | Gravecaller | Thralls hit +4% harder | Thralls attack +8% faster | **Legion Call**: Thralls hit +5% harder · +1 thrall cap |
| Lamplight | Grave Warden | +3 VIT | +5% maximum health | **Lamplight Vigil**: +3 STR · +4% maximum health |
| Bellwake | Bell Monk | +3 AGI | +3 STR | **Measured Toll**: +3 AGI · +3 STR |
| Ivory Reliquary | Ossuary | Thralls have +5% health | Thralls have +5% health · 1.5% less damage taken per thrall | **Reliquary Bulwark**: +5% maximum health · Black Litany barrier +2% max health per corpse |
| Widowveil | Mourner | +5% essence regeneration | Thralls have +5% health · Consumed corpses heal +2% max health | **Widow’s Chorus**: +8% essence regeneration · Thralls hit +8% harder |
| Carrionbloom | Carrion Witch | +3 INT | +6% essence regeneration | **Thorn Bloom**: +3 INT · +4% maximum health |
| Blightweave | Rotweaver | Miasma is +5% wider | Miasma is +5% wider · +1 max Withered stacks | **Blight Bloom**: Miasma is +10% wider · +1 max Withered stacks |
| Hollow Oath | Hollow Knight | +3 STR | +5% maximum health | **Broken Vow**: +3 VIT · +3 STR |
| Threshold | Veilwalker | +3 AGI | +3 INT | **Edge of Worlds**: +3 AGI · +6% essence regeneration |
| Epitaph Sovereign (ascended) | Gravecaller | Thralls hit +6% harder | Thralls hit +4% harder · Thralls attack +10% faster | **Sovereign Legion**: Thralls hit +8% harder · Thralls attack +5% faster · +1 thrall cap |
| Nightwatch Beacon (ascended) | Grave Warden | +4 VIT | +7% maximum health | **Last Watch**: +4 STR · +5% maximum health |
| Last Toll (ascended) | Bell Monk | +4 AGI | +4 STR | **Final Note**: +4 AGI · +4 STR |
| Marrow Regent (ascended) | Ossuary | Thralls have +7% health | Thralls have +6% health · 2% less damage taken per thrall | **Regent’s Ossuary**: +8% maximum health · Black Litany barrier +3% max health per corpse |
| Pale Requiem (ascended) | Mourner | +7% essence regeneration | Thralls have +6% health · Consumed corpses heal +3% max health | **Requiem Hush**: +10% essence regeneration · Thralls hit +10% harder · Consumed corpses heal +1% max health |
| Thorn Covenant (ascended) | Carrion Witch | +4 INT | +8% essence regeneration | **Rootbound Covenant**: +4 INT · +6% maximum health |
| Virulent Choir (ascended) | Rotweaver | Miasma is +7% wider | Miasma is +5% wider · +2 max Withered stacks | **Plague Song**: +5% maximum health · Miasma is +12% wider · +1 max Withered stacks |
| Oathbreaker (ascended) | Hollow Knight | +4 STR | +7% maximum health | **Shield Remains**: +4 VIT · +4 STR |
| Umbral Crossing (ascended) | Veilwalker | +4 AGI | +4 INT | **Shadowless**: +4 AGI · +8% essence regeneration |

### How bonuses plug into the game

Nothing new runs in the sim or the ability code. Bonuses are computed client-side from the worn item ids (`src/gameplay/setBonuses.ts`), like the necromancer weapon line, and enter through two pipelines that already exist:

- **Flat stats** are added to the gear totals in `computeStats` (`src/gameplay/stats.ts`), so health, spell power, essence and move speed follow with the normal formulas.
- **Multipliers and additions** (`thrallHpMult`, `thrallDamageMult`, `thrallAttackSpeedMult`, `maxHpMult`, `essenceRegenMult`, `miasmaRadiusMult`; `thrallCap`, `witheredMaxStacks`, `corpseHeal`, `wardPerThrall`, `litanyBarrier`) are folded into the discipline `mods` in `WorldScene.applyBoons`, after Covenant boons and the skull-focus thrall cap. `refreshStats` rebuilds the discipline whenever the set of active bonuses changes. `deriveStats`, the abilities and the HUD read the same `mods` as before.

### Gear score

`gearStats` re-bases the discipline on the outfit it is judging (`withSetBonuses`), so swapping a piece changes the derived numbers exactly as wearing it would. Effects `deriveStats` cannot see (ward per thrall, Litany barrier, corpse healing, Withered stacks, Miasma radius) are valued as a percent of power in `SET_VALUE` (judgment calls, necromancers only). The upgrade arrow and verdict add the set effect: "Upgrade for your Ossuary: +9% (...) — completes Ivory Reliquary 4-piece", "Worse than your Gravecall Crown: −2% — breaks your Gravecall 2-piece".
