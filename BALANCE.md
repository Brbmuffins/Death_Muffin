# Crossworlds — Balance targets & current numbers

## Gear pass (2026-10-02, 8 seeds, 3 sim-minutes)

The harness used to wear no gear (only the `gearStats` stand-in: stat points for "ordinary gear"), so item stats, armor sets, the necromancer weapon line
and the new item-level affixes had never been checked against the power curve. This pass teaches the bot to wear **kits**, measures what gear does
to every necromancer in every hunting ground and band, and retunes the numbers it can.

### Headline
1. **Gear is dominated by the base stats printed on the items, not by the parts this pass can tune.** Switching off set bonuses, the weapon line and affixes
   leaves ~90% of the lift (table 4). A full first set is 36 stat points (24 INT, 12 VIT) against a stand-in of ~10 per stat at the Sanctum, so a typical
   kit multiplies spell power by 1.6 to 2.0 on its own. Armor and weapon stats are rows in the Death Muffin database (migrations 011/012 and the weapon
   line), so they were **not changed here**; table 5 says what scaling them would do.
2. **Targets met:** intended band with last area's gear, geared band with a completed first set, random drops that are felt but bounded, no mandatory
   affix or set. **Targets missed (too strong):** push and max Wave Speed with a typical or ascended kit. The "reckless" bands are nearly safe once
   a kit is worn (deaths 2.0 -> 0.3 with a typical kit, -> 0.05 with an ascended one). See "Targets" below.
3. **Levers are small next to INT.** One point of INT is worth about as much clear rate as +20% thrall damage. The old affix ranges made a stat affix worth
   7-10% of power and a necromancer lever worth 0.5-2%; both were retuned (table 6).

### Reproduce
```bash
npm run balance:gear                      # tab-separated rows per area x band x discipline x kit (GEAR_AREAS, GEAR_BANDS, GEAR_KITS, GEAR_SEEDS=8 ...)
GEAR_KITS=none,typical GEAR_AREAS=pyre GEAR_BANDS=max npm run balance:gear
BALANCE_KIT=auto BALANCE_DISCIPLINES=1,2,3,4 npm run balance      # the classic report with each band wearing its kit (intended=progress, geared/push=typical, max=ascended)
npm run balance:lever                     # what one number is worth: folds one effect on top of a kit (LEVER_KIT, LEVER_SCALE)
npm run balance:score                     # does the up/down arrow rank like the harness (SCORE_AREA, SCORE_BAND)
GEAR_STRIP=sets,weapon,affixes ...        # decomposition: keep base stats, switch effects off      GEAR_STAT_SCALE=0.55  what-if on base stats
GEAR_SET=witch GEAR_WEAPON=wand:grimoire GEAR_TIER=gold ...   # swap the set or weapon pair a kit wears      GEAR_NO_RITES=1  the pre-pass bot
```

### The kits (data: `src/gameplay/balance/kits.ts`)
A kit is a list of real catalogue items plus affixes at a quality `q` (0 = weakest roll of the item level, 1 = best). The harness turns it into inventory rows and
runs the same `deriveStats` / `withSetBonuses` / `resolveWeaponLoadout` as the game. A kit **replaces** the share of the `gearStats` stand-in its slots cover (the
stand-in is ordinary gear in all nine slots), so a kit is judged against the gear it displaces, not stacked on it.

| Kit | Wears |
|---|---|
| none | nothing (the historical harness; every "x" below is relative to this, same seeds) |
| progress | what dropped in *earlier* grounds: the discipline's own set pieces and the weapon tier of those areas, one lever affix (q 0.5). Graves has no earlier ground, so it is `none` there |
| typical | the whole first set + a weapon pair of the area's tier + two lever affixes (q 0.5, weapon and chest) |
| rolled | the `typical` items with affixes rolled by the real loot rules (`rollInstance`, item rarity, one drop in three an elite), seeded per run |
| ascended | the ascended set + moon-tier weapon pair + one lever per piece (q 0.75) rotating through the discipline's levers |
| bis | as ascended with the three best levers (q 1.0) on every piece: stacks one multiplier seven times, a ceiling nobody will reach |

Weapon pairs: Ossuary staff; Gravecaller sickle + skull focus; Mourner wand + mourning bell; Rotweaver sickle + grimoire. The weapon matrix (table 7) shows every
pair within about 8% of the others except the scythe (the staff is 4-8% behind for the three non-Ossuary disciplines), so the choice is not load-bearing. Lever preference: Ossuary ward > thrall health; Gravecaller thrall damage >
thrall health; Mourner essence regeneration > thrall damage; Rotweaver Miasma > Withered.

### Harness fidelity changes (the bot got better at being a necromancer)
The weapon line is now played (staff reach and pierce, scythe arc, wand cadence, sickle Withered + Exhume refund, grimoire rite cooldowns, bell heals), and the bot
applies the **corpse heal** and **Black Litany barrier** its disciplines already had (it ignored both, so the 2026-10-02 necro pass tuned the Mourner's corpse heal in a harness that could not see it, and the Ossuary's Black Litany barrier was never exercised). It also reports the legion size (`avgThralls`: 82-93% of the cap alive at the intended band, 64-85% at max Wave Speed).
Effect on the kit-less baseline (Ossuary and Mourner are the only disciplines whose numbers move; `GEAR_NO_RITES=1` reproduces the old bot):

| Discipline | Band | kills/min old bot -> new bot | deaths / 3 min old -> new | damage taken %/min old -> new |
|---|---|---|---|---|
| Mourner | intended | 87.1 -> 88.0 | 0.53 -> 0.36 | 57 -> 63 |
| Mourner | geared | 113.7 -> 115.7 | 0.39 -> 0.24 | 58 -> 62 |
| Mourner | push | 95.1 -> 98.1 | 1.63 -> 1.20 | 119 -> 137 |
| Mourner | max | 94.2 -> 96.2 | 2.00 -> 1.64 | 136 -> 163 |
| Ossuary | intended | 110.7 -> 111.3 | 0.18 -> 0.15 | 35 -> 31 |
| Ossuary | geared | 162.7 -> 163.5 | 0.29 -> 0.27 | 40 -> 35 |
| Ossuary | push | 150.6 -> 152.9 | 1.61 -> 1.53 | 107 -> 105 |
| Ossuary | max | 143.4 -> 145.0 | 2.20 -> 2.16 | 128 -> 126 |

Baseline (no kit, mean of 9 areas x 4 necromancers):

| Band | kills/min | gold/min | XP/min | hurt %/min | deaths / 3 min |
|---|---|---|---|---|---|
| intended | 96.8 | 1736 | 4178 | 48 | 0.30 |
| geared | 132.8 | 3708 | 7641 | 53 | 0.30 |
| push | 115.3 | 3303 | 6347 | 121 | 1.60 |
| max | 111.5 | 3978 | 7068 | 139 | 1.99 |

### Table 1. What a kit does (mean of 9 areas x 4 necromancers; ratios to the same rows with no kit; "before" = before this pass's retune)
| Band | Kit | Kills/min | Gold/min | Damage taken | Deaths / 3 min (no kit -> kit) |
|---|---|---|---|---|---|
| intended | progress | 1.11x -> **1.11x** | 1.14x -> 1.15x | 0.53x -> 0.49x | 0.30 -> 0.03 -> **0.01** |
| intended | typical | 1.12x -> **1.12x** | 1.15x -> 1.16x | 0.39x -> 0.36x | 0.30 -> 0.02 -> **0.03** |
| intended | rolled | n/a -> **1.13x** | n/a -> 1.17x | n/a -> 0.31x | 0.30 -> n/a -> **0.01** |
| intended | ascended | 1.16x -> **1.16x** | 1.20x -> 1.20x | 0.24x -> 0.17x | 0.30 -> 0.01 -> **0.00** |
| intended | bis | 1.16x -> **1.17x** | 1.21x -> 1.22x | 0.21x -> 0.17x | 0.30 -> 0.00 -> **0.00** |
| geared | progress | 1.15x -> **1.15x** | 1.17x -> 1.17x | 0.58x -> 0.57x | 0.30 -> 0.04 -> **0.04** |
| geared | typical | 1.19x -> **1.19x** | 1.21x -> 1.22x | 0.48x -> 0.43x | 0.30 -> 0.06 -> **0.03** |
| geared | rolled | n/a -> **1.21x** | n/a -> 1.24x | n/a -> 0.39x | 0.30 -> n/a -> **0.02** |
| geared | ascended | 1.25x -> **1.27x** | 1.29x -> 1.31x | 0.33x -> 0.25x | 0.30 -> 0.00 -> **0.01** |
| geared | bis | 1.29x -> **1.29x** | 1.33x -> 1.33x | 0.29x -> 0.21x | 0.30 -> 0.00 -> **0.00** |
| push | progress | 1.37x -> **1.40x** | 1.55x -> 1.58x | 0.58x -> 0.52x | 1.60 -> 0.33 -> **0.24** |
| push | typical | 1.49x -> **1.50x** | 1.67x -> 1.71x | 0.43x -> 0.37x | 1.60 -> 0.24 -> **0.18** |
| push | rolled | n/a -> **1.52x** | n/a -> 1.72x | n/a -> 0.34x | 1.60 -> n/a -> **0.17** |
| push | ascended | 1.66x -> **1.68x** | 1.89x -> 1.91x | 0.28x -> 0.20x | 1.60 -> 0.06 -> **0.03** |
| push | bis | 1.72x -> **1.76x** | 1.98x -> 1.99x | 0.22x -> 0.18x | 1.60 -> 0.02 -> **0.01** |
| max | progress | 1.40x -> **1.44x** | 1.59x -> 1.66x | 0.67x -> 0.60x | 1.99 -> 0.63 -> **0.51** |
| max | typical | 1.56x -> **1.59x** | 1.79x -> 1.85x | 0.44x -> 0.37x | 1.99 -> 0.35 -> **0.27** |
| max | rolled | n/a -> **1.61x** | n/a -> 1.88x | n/a -> 0.36x | 1.99 -> n/a -> **0.24** |
| max | ascended | 1.78x -> **1.81x** | 2.11x -> 2.15x | 0.25x -> 0.19x | 1.99 -> 0.10 -> **0.05** |
| max | bis | 1.87x -> **1.92x** | 2.23x -> 2.28x | 0.21x -> 0.16x | 1.99 -> 0.03 -> **0.01** |

Deaths read "no kit -> kit before retune -> **kit after retune**". Kills/min saturate at the wave supply at the intended band (a bot that already clears everything cannot clear more),
so the intended and geared bands show their lift in damage taken and time-to-kill (0.5-0.7x), not in kills.

### Table 2. By hunting ground, with the kit each band is meant to wear (kills x . damage taken x . deaths no kit -> kit)
| Area (level) | intended + progress | geared + typical | push + typical | max + ascended |
|---|---|---|---|---|
| graves (1) | 1.00x · 1.00x · 0.0->0.0 | 1.16x · 0.51x · 0.0->0.0 | 1.38x · 0.38x · 0.1->0.0 | 1.68x · 0.16x · 0.3->0.0 |
| warren (4) | 1.01x · 0.90x · 0.0->0.0 | 1.10x · 0.59x · 0.0->0.0 | 1.36x · 0.37x · 0.7->0.0 | 1.68x · 0.25x · 1.3->0.0 |
| ossuary (5) | 1.01x · 0.75x · 0.2->0.0 | 1.02x · 0.39x · 0.1->0.0 | 1.41x · 0.21x · 1.7->0.0 | 1.62x · 0.16x · 2.2->0.0 |
| coliseum (11) | 1.30x · 0.37x · 0.8->0.0 | 1.48x · 0.23x · 0.8->0.0 | 1.64x · 0.32x · 2.2->0.1 | 2.21x · 0.11x · 2.4->0.0 |
| nave (9) | 1.15x · 0.32x · 0.1->0.0 | 1.24x · 0.27x · 0.1->0.0 | 1.79x · 0.12x · 2.2->0.0 | 1.97x · 0.08x · 2.3->0.0 |
| sanctum (13) | 1.08x · 0.21x · 0.3->0.0 | 1.08x · 0.18x · 0.2->0.0 | 1.80x · 0.13x · 2.1->0.0 | 2.15x · 0.06x · 2.3->0.0 |
| cloister (20) | 1.15x · 0.33x · 0.4->0.0 | 1.32x · 0.44x · 0.5->0.0 | 1.47x · 0.43x · 1.7->0.1 | 1.77x · 0.24x · 2.3->0.1 |
| pyre (30) | 1.18x · 0.26x · 0.7->0.1 | 1.28x · 0.45x · 0.6->0.1 | 1.49x · 0.62x · 2.1->0.6 | 1.66x · 0.32x · 2.4->0.2 |
| fen (45) | 1.11x · 0.27x · 0.3->0.0 | 1.06x · 0.84x · 0.4->0.2 | 1.15x · 0.78x · 1.7->0.9 | 1.52x · 0.37x · 2.2->0.2 |

The ascended kit at the Nave is not a real player (its feet drop in the Pyre); read the late columns in the late grounds. The lift **shrinks with level**: base gear stats are flat, the rest
of a character scales with level and Damage tiers, so the Fen (level 45) is barely touched by a first-set kit (1.06x, 0.84x damage) while the Nave and Sanctum are halved.

### Table 3. By discipline
| Discipline | geared + typical (Nave to Pyre) | push + typical (Cloister to Fen) | max + ascended (Cloister to Fen) |
|---|---|---|---|
| Ossuary | 1.02x · 0.15x · 0.3->0.0 | 1.32x · 0.35x · 1.6->0.4 | 1.62x · 0.15x · 2.4->0.2 |
| Gravecaller | 1.23x · 0.38x · 0.4->0.0 | 1.44x · 0.60x · 2.3->0.7 | 1.75x · 0.26x · 2.5->0.1 |
| Mourner | 1.33x · 0.49x · 0.3->0.0 | 1.22x · 0.89x · 1.3->0.6 | 1.51x · 0.46x · 1.8->0.1 |
| Rotweaver | 1.33x · 0.32x · 0.4->0.0 | 1.49x · 0.59x · 2.1->0.5 | 1.72x · 0.37x · 2.5->0.2 |

Ossuary is already at the wave-supply ceiling at the geared band (1.02x), so its lift is all survival. Mourner has the smallest survival lift (its set has AGI instead of VIT).

### Table 4. Where the lift comes from (measured before the retune; Nave, Sanctum and Pyre; kills x . deaths per 3 min)
| Kit and band | no kit | full kit | base stats only | set bonuses off | weapon line off | affixes off |
|---|---|---|---|---|---|---|
| push + typical | 2.13 deaths | 1.67x · 0.22 | 1.60x · 0.37 | 1.68x · 0.26 | 1.61x · 0.38 | 1.69x · 0.29 |
| max + typical | 2.37 deaths | 1.68x · 0.32 | 1.61x · 0.59 | 1.70x · 0.34 | 1.59x · 0.55 | 1.70x · 0.39 |
| max + ascended | 2.37 deaths | 1.89x · 0.17 | 1.81x · 0.32 | 1.88x · 0.24 | 1.85x · 0.25 | 1.88x · 0.20 |

Base item stats alone give 1.60x and cut max-band deaths from 2.4 to 0.6. Everything this pass can tune (set bonuses + weapon line + affixes) is the last step from 0.6 to 0.3 deaths
and +5% kills, which is the "-30-50% deaths, a little clear" a typical kit should add on top of its stats.

### Table 5. What-if: scale the worn items' base stat points (not applied; measured before the retune; kills x . damage taken x . deaths)
| Kit and band | no kit | stats x1.0 (today) | x0.7 | x0.55 | x0.4 |
|---|---|---|---|---|---|
| geared + typical | 0.30 deaths | 1.20x · 0.35x · 0.06 | 1.15x · 0.47x · 0.11 | 1.13x · 0.62x · 0.17 | 1.10x · 0.67x · 0.19 |
| push + typical | 2.13 deaths | 1.67x · 0.34x · 0.22 | 1.54x · 0.45x · 0.44 | 1.46x · 0.56x · 0.63 | 1.38x · 0.66x · 0.94 |
| max + typical | 2.37 deaths | 1.68x · 0.40x · 0.32 | 1.56x · 0.54x · 0.64 | 1.48x · 0.62x · 0.85 | 1.30x · 0.83x · 1.33 |
| max + ascended | 2.37 deaths | 1.89x · 0.24x · 0.17 | 1.78x · 0.33x · 0.24 | 1.70x · 0.38x · 0.36 | 1.55x · 0.53x · 0.60 |

At 0.4x the typical kit lands inside the proposed band at max Wave Speed (+30% kills, deaths 2.4 -> 1.3, i.e. -44%). The ascended kit still cuts deaths by 75% at 0.4x. A decision for the owner:
trim set and weapon stats (a migration, plus the catalogue in `armorSets.ts` / `necroWeapons.ts`), or accept strong gear and raise late Wave Speed pressure.

### What one number is worth (kit-less bot, max Wave Speed, Nave/Pyre/Fen, 16 seeds, mean of 12 contexts; `npm run balance:lever`)
| Effect (x3 step) | kills/min |
|---|---|
| +15 INT | +17.9% |
| +15 STR / +15 VIT / +15 AGI | +5.5% / +2.8% / +2.3% |
| max health +30% | +3.0% (damage taken -15%) |
| thrall health / attack speed / damage +30% | +2.6% / +2.3% / +1.7% |
| Miasma +30% wider | +2.7% (Rotweaver +8%) |
| Withered +3 stacks | +2.2% |
| ward +3% less damage per thrall | +1.8% |
| essence regeneration +30% | +1.6% |
| thrall cap +3 | +0.1% (noise; the set comparison later found +1 cap worth ~4% for the three-thrall disciplines) |
| Litany barrier +3% per corpse / corpse heal +3% | -0.4% / +1.7% (healing keeps the bot in fights: damage taken rises) |

Removing thrall damage entirely costs a Gravecaller 12-29% of its kills/min and the others 0-19%, which is what `THRALL_DAMAGE_SHARE = 0.15` encodes.

### Targets (proposed) and what was measured (final numbers)
| # | Target | Measured | Verdict |
|---|---|---|---|
| 1 | Intended band, last area's gear (progress): clear +5..+20%, damage taken -35..-65%, no extra deaths | 1.11x, 0.49x, deaths 0.30 -> 0.01 | met |
| 2 | Geared band, completed first set (typical): clear +10..+30%, damage taken -45..-70% (or deaths -30..-50%) | 1.19x, 0.43x, deaths 0.30 -> 0.03 | met |
| 3 | Random drops (rolled) land within 5% of a chosen kit, so affixes are a felt but bounded part | geared 1.21x vs 1.19x; max 1.61x vs 1.59x | met |
| 4 | Push band, typical kit: clear +15..+35% or deaths -30..-50% | 1.50x, deaths 1.60 -> 0.18 (-89%) | **missed, too strong** (stats; table 5) |
| 5 | Max band, ascended kit does not trivialise it: >= 0.5 deaths per 3 min and clear <= +50% | 1.81x, 0.05 deaths (Pyre 1.66x / 0.22, Fen 1.52x / 0.16) | **missed, too strong** (stats) |
| 6 | No single affix mandatory: median roll of any affix <= 1.6x the best stat affix; a max roll < 9% of power | <= 1.3x everywhere (tests) | met |
| 7 | Randomly rolled gear: affixes add 4-16% of power on average, < 26% at the 90th percentile | 7-14%, p90 10-21% (was 10-26%, p90 17-42%) | met |
| 8 | Each necromancer's own set is its best set (power score, both collections, margin >= 1.5 points) | margins 2.1-7.3 points | met by the score; **not confirmed by the harness** for Mourner and Rotweaver (below) |
| 9 | The up/down arrow ranks like the harness | structural swaps rho 0.87, weapons 0.42, single affixes unresolvable | partly (below) |

### Tuning: every number changed and why
**Table 6. Affix ranges** (`affixRules.ts`; whole numbers stored as before, ids unchanged; `loot_instances` held 0 rows when this was measured, so no stored roll can fall outside a range):

| Affix | unit | ilvl 10 old -> new | ilvl 22 old -> new | ilvl 47 old -> new |
| str (all 8 stat affixes) | stat | 3-5 -> 1-2 | 5-10 -> 2-3 | 11-20 -> 3-5 |
| agi (all 8 stat affixes) | stat | 3-5 -> 1-2 | 5-10 -> 2-3 | 11-20 -> 3-5 |
| int (all 8 stat affixes) | stat | 3-5 -> 1-2 | 5-10 -> 2-3 | 11-20 -> 3-5 |
| vit (all 8 stat affixes) | stat | 3-5 -> 1-2 | 5-10 -> 2-3 | 11-20 -> 3-5 |
| p_thrall_dmg | pct | 2.6-4.8% -> 5.3-9.8% | 4.4-8.2% -> 6.9-12.9% | 8.3-15% -> 10.4-19.4% |
| s_thrall_hp | pct | 3.4-6.2% -> 10.1-18.7% | 5.7-10.6% -> 13.3-24.6% | 10.6-19.7% -> 19.9-37% |
| p_essence_regen | pct | 3.1-5.9% -> 9.9-18.5% | 5.3-9.8% -> 13.5-25% | 9.6-15% -> 20.8-38.7% |
| s_miasma | pct | 4.6-8.5% -> 5.2-9.6% | 7.5-13.9% -> 7-13.1% | 13.6-25% -> 10.9-20.2% |
| p_withered | count | 1-1 -> 1-3 | 1-2 -> 1-5 | 1-4 -> 1-6 |
| s_ward | wardPct | 0.2-0.3% -> 1.1-2.1% | 0.3-0.5% -> 1.7-3.2% | 0.5-0.8% -> 2.9-5.4% |

Why: a stat affix at item level 22 was +5..+10 INT, worth ~7-10% of power on its own, more than a necromancer's whole 2-piece bonus, so INT affixes were mandatory and levers were traps
(a median lever was 0.5-2%). Stat ranges are now `0.8 + 0.07 x ilvl` (was `1 + 0.3 x ilvl`, cap 14); lever centres were raised so a median lever for the discipline that uses it matches a
stat affix (2-3% of power) and the rest are about a third of that. Withered stacks `1..2+floor(ilvl/7)` (was `1..1+floor(ilvl/12)`, 4 at most; the sim clamps to 12 anyway). Affix
odds, counts per rarity and drop-source weights are unchanged (6 levers of 14 groups is 47% of the weight, which is fine now that a lever is competitive).

**Set bonuses** (`setBonuses.ts`; only the lines that changed). Ivory Reliquary and Widowveil were worth 4 and 3 points of power to their own disciplines against 8-9 for Carrionbloom's flat stat lines, so the flat
lines on the other sets were worth more than whole necromancer sets. Mourner and Rotweaver lines also pay back what their sets' stats lack (no VIT; no HP).

| Set | 2 pieces | 4 pieces | 5 pieces |
|---|---|---|---|
| Gravecall | Thralls hit +4% harder -> Thralls hit +8% harder | Thralls attack +8% faster -> Thralls attack +10% faster | **Legion Call**: Thralls hit +5% harder · +1 thrall cap -> **Legion Call**: Thralls hit +14% harder · +1 thrall cap |
| Ivory Reliquary | Thralls have +5% health -> +2% maximum health · Thralls have +20% health | Thralls have +5% health · 1.5% less damage taken per thrall -> Thralls have +10% health · 5% less damage taken per thrall | **Reliquary Bulwark**: +5% maximum health · Black Litany barrier +2% max health per corpse -> **Reliquary Bulwark**: +10% maximum health · Black Litany barrier +4% max health per corpse |
| Widowveil | +5% essence regeneration -> +6% maximum health · +30% essence regeneration | Thralls have +5% health · Consumed corpses heal +2% max health -> +5% maximum health · Thralls have +20% health · Consumed corpses heal +3% max health | **Widow’s Chorus**: +8% essence regeneration · Thralls hit +8% harder -> **Widow’s Chorus**: +4% maximum health · +20% essence regeneration · Thralls hit +20% harder |
| Carrionbloom | +3 INT -> +2 INT | +6% essence regeneration (unchanged) | **Thorn Bloom**: +3 INT · +4% maximum health -> **Thorn Bloom**: +2 INT · +4% maximum health |
| Blightweave | Miasma is +5% wider -> Miasma is +12% wider | Miasma is +5% wider · +1 max Withered stacks -> Miasma is +8% wider · +2 max Withered stacks | **Blight Bloom**: Miasma is +10% wider · +1 max Withered stacks -> **Blight Bloom**: +3% maximum health · Miasma is +12% wider · +1 max Withered stacks |
| Threshold | +3 AGI (unchanged) | +3 INT -> +2 INT | **Edge of Worlds**: +3 AGI · +6% essence regeneration (unchanged) |
| Epitaph Sovereign (asc.) | Thralls hit +6% harder -> Thralls hit +14% harder | Thralls hit +4% harder · Thralls attack +10% faster -> Thralls hit +4% harder · Thralls attack +14% faster | **Sovereign Legion**: Thralls hit +8% harder · Thralls attack +5% faster · +1 thrall cap -> **Sovereign Legion**: Thralls hit +14% harder · Thralls attack +6% faster · +1 thrall cap |
| Marrow Regent (asc.) | Thralls have +7% health -> +3% maximum health · Thralls have +30% health | Thralls have +6% health · 2% less damage taken per thrall -> Thralls have +12% health · 6.5% less damage taken per thrall | **Regent’s Ossuary**: +8% maximum health · Black Litany barrier +3% max health per corpse -> **Regent’s Ossuary**: +14% maximum health · Black Litany barrier +6% max health per corpse |
| Pale Requiem (asc.) | +7% essence regeneration -> +12% maximum health · +45% essence regeneration | Thralls have +6% health · Consumed corpses heal +3% max health -> +8% maximum health · Thralls have +30% health · Consumed corpses heal +5% max health | **Requiem Hush**: +10% essence regeneration · Thralls hit +10% harder · Consumed corpses heal +1% max health -> **Requiem Hush**: +7% maximum health · +30% essence regeneration · Thralls hit +20% harder · Consumed corpses heal +2% max health |
| Thorn Covenant (asc.) | +4 INT -> +3 INT | +8% essence regeneration (unchanged) | **Rootbound Covenant**: +4 INT · +6% maximum health -> **Rootbound Covenant**: +3 INT · +6% maximum health |
| Virulent Choir (asc.) | Miasma is +7% wider -> Miasma is +16% wider | Miasma is +5% wider · +2 max Withered stacks -> Miasma is +10% wider · +3 max Withered stacks | **Plague Song**: +5% maximum health · Miasma is +12% wider · +1 max Withered stacks -> **Plague Song**: +5% maximum health · Miasma is +16% wider · +1 max Withered stacks |
| Umbral Crossing (asc.) | +4 AGI (unchanged) | +4 INT -> +3 INT | **Shadowless**: +4 AGI · +8% essence regeneration (unchanged) |

**Power score** (`gearStats.ts`, so the arrow and the stat priority list agree with the harness): `THRALL_DAMAGE_SHARE` 0.15 (new; was an implicit 1: five thralls counted as five extra
casters); `THRALL_UPTIME` 0.7 (new; the legion is 65-90% of its cap, calibrated together with the share); `EXTRA_THRALL_VALUE` 1; `REGEN_HORIZON_S` 25 (new; essence regeneration is judged over a fight, +10% regen was worth 0.06% and is now ~0.7%);
`SET_VALUE`: ward x `wardScale` 0.4, `litanyPer1pct` 0.4 -> 0.1, `corpseHealPer1pct` 0.5 -> 0.25, `witheredPerStack` 1.5 -> 0.65, `miasmaPer1pct` 0.4 -> 0.09 (x2.5 for the Rotweaver);
`LOADOUT_VALUE`: `reap` 6 -> 2, `pierce` 3 -> 2, `primaryShare` 0.4 -> 0.8, `riteShare` 0.45 -> 0.2, `bell` 2 -> 1. Why: each was set from table "what one number is worth" and the weapon matrix.

**Harness / docs / tests:** `balance/kits.ts`, `bands.ts`, `gearReport.ts`, `leverReport.ts`, `gearScoreReport.ts`, `harness.ts`, `report.ts` (kit column, `BALANCE_KIT`); `docs/ARMOR-SETS.md` table regenerated; README set sentence;
`affix-rules.cjs` regenerated; tests `gear-balance.test.ts` (new) and updated expectations in `setBonuses`, `gearStats`, `affixes`.

### Own set best, no set mandatory (32 seeds, base stats only: weapon and affixes switched off, Nave/Sanctum/Pyre push and max)
| Wearer | Collection | own set: kills/min (rank of 5) | best set | worst set | own vs best |
|---|---|---|---|---|---|
| Ossuary | first | 202 (1) | Ossuary 202 | Blightweave 198 | +0.0% |
| Gravecaller | first | 160 (2) | Widowveil 161 | Blightweave 155 | -1.1% |
| Mourner | first | 138 (2) | Gravecall 142 | Ossuary 130 | -3.0% |
| Rotweaver | first | 147 (5) | Gravecall 150 | Blightweave 147 | -1.9% |
| Ossuary | ascended | 208 (1) | Marrow Regent 208 | Thorn Covenant 204 | +0.0% |
| Gravecaller | ascended | 177 (1) | Epitaph Sovereign 177 | Virulent Choir 171 | +0.0% |
| Mourner | ascended | 159 (3) | Epitaph Sovereign 165 | Marrow Regent 155 | -4.0% |
| Rotweaver | ascended | 168 (4) | Pale Requiem 170 | Marrow Regent 166 | -1.2% |

All five INT/VIT sets are within about 5% of each other; the STR/AGI sets (Bellwake, Hollow Oath, Lamplight) are 14-20% behind for a necromancer and Threshold (AGI/INT) 5-12% (8 seeds, earlier numbers), so none of the necromancer sets is mandatory and the
off-class sets are not a trap worth worrying about. The harness reads Ossuary and Gravecaller as wearing their own set best (or tied); Mourner and Rotweaver read 1-4% behind the Gravecall /
Epitaph Sovereign line (one to one and a half standard errors, so not a finding either way). The reason is visible: the Gravecall five-piece is +1 thrall cap, and for a three-thrall discipline
that is +33% legion. The power score agrees with that (it ranks Gravecall second for Mourner and Rotweaver) but still puts the wearer's own set first by 2.1 points or more, because it values each
set's own levers a little higher than the 32-seed harness does. Not chased further: below this size the harness is noise.

### Items: one affix swapped in, pooled over Sanctum/Pyre/Fen max (4 necromancers, 8 seeds)
Replacing the chest's lever with another affix at maximum roll moves kills/min by -3.1% to +3.2% and the power score by -0.9% to +1.5% for every affix. That is the harness noise floor,
so no affix is mandatory and none is a trap, and the arrow's ordering among single affixes cannot be validated with this bot (rank correlation -0.05).

### Power score versus the harness (`npm run balance:score`; 25 swaps x 4 disciplines at Sanctum, Pyre and Fen max, 8 seeds, pooled; Spearman against kills/min)
| Swaps | before | after |
|---|---|---|
| structural (drop a piece or the weapon, break a set, ascended mix, whole ascended set), n=32 | 0.76 | **0.87** (0.94 against deaths) |
| weapon kind (staff, scythe, wand, sickle with each off-hand), n=20 | 0.17 | 0.42 |
| one affix swapped in, n=44 | 0.51 | -0.05 (below the noise floor, see above) |
| everything, n=96 | 0.61 | 0.56 |
| swaps where the score moves by 5% or more | 0.76 (n=48) | 0.64 (n=35; sign agrees in 33 of 35) |

Overall agreement did not improve, because most swaps are tiny and the bot cannot rank them; the large ones agree in sign 94% of the time and the score no longer calls a scythe a gain
of 6 points. Known disagreement: the **scythe** loses 10-30% kills/min and takes 40-90% more damage with this bot (a 3 m arc means standing in the pack, and the bot never kites); the score keeps it
neutral-to-slightly-positive (`reap` 2) because a human kites. Treat that as the harness's weakness, and playtest it.

### Weapon matrix (table 7; typical set, gold tier, Nave and Sanctum, geared and push, 8 seeds; kills x . damage taken x versus no kit)
| Weapon (gold tier, typical set) | Ossuary | Gravecaller | Mourner | Rotweaver |
|---|---|---|---|---|
| staff | 1.23x · 0.09x | 1.46x · 0.17x | 1.49x · 0.19x | 1.47x · 0.13x |
| scythe | 1.16x · 1.06x | 1.11x · 1.60x | 1.43x · 1.88x | 1.24x · 1.44x |
| wand | 1.23x · 0.18x | 1.48x · 0.27x | 1.56x · 0.38x | 1.49x · 0.29x |
| wand + skull_focus | 1.23x · 0.15x | 1.51x · 0.26x | 1.60x · 0.29x | 1.53x · 0.21x |
| wand + grimoire | 1.22x · 0.19x | 1.52x · 0.20x | 1.63x · 0.35x | 1.55x · 0.24x |
| wand + mourning_bell | 1.24x · 0.15x | 1.54x · 0.25x | 1.58x · 0.34x | 1.54x · 0.27x |
| sickle | 1.23x · 0.17x | 1.50x · 0.22x | 1.58x · 0.31x | 1.52x · 0.22x |
| sickle + skull_focus | 1.22x · 0.14x | 1.53x · 0.17x | 1.62x · 0.26x | 1.58x · 0.16x |
| sickle + grimoire | 1.25x · 0.15x | 1.52x · 0.21x | 1.60x · 0.29x | 1.55x · 0.19x |
| sickle + mourning_bell | 1.25x · 0.16x | 1.50x · 0.24x | 1.59x · 0.33x | 1.59x · 0.23x |

### Unfinished / caveats
- **Base stats (table 5) are the decision this pass could not take**: today a first set + weapon is ~36 + 15 stat points against a stand-in of ~10 per stat. Either trim `armorSets.ts` / `necroWeapons.ts` stats (~0.4-0.55x, with a
  migration for the live rows) or raise late Wave Speed pressure. Everything else here is tuned to sit on top of whichever you choose; rerun `GEAR_KITS=none,typical,ascended npm run balance:gear` after.
- The bot never dodges, drinks flasks or kites, and thralls only matter as far as the sim lets them: lever values are measured, not played. A human pass on a Gravecaller with +20% thrall damage and on the
  scythe is still needed. Corpse heal is deliberately small in the sets (Exhume has a 0.5 s cooldown, so a big per-corpse heal is a self-heal exploit).
- `typical` assumes the Sanctum feet in the Nave and Pyre; `progress` is the realistic early kit. Kits are tuned on the four necromancers only; the other five disciplines were not run with kits.
- Mourner and Rotweaver own-set leadership is established by the power score, not by the harness (above).
- Essence regeneration affixes multiply (x1.4 at three pieces of +14% each); there is no cap beyond the cooldowns. Withered stacks past 12 are clamped by the sim.
- Affix ids and the server bundle are unchanged in shape; `server/death-muffin/backend/gathering/affix-rules.cjs` was regenerated and must ship with the client (not deployed).


## Easy auto combat browser pass (2026-09-28, undeployed)

The owner wants Easy to be an automated, powerful farming mode. Easy auto now engages enemies across the current combat area, dodges nearby windups, uses every equipped New Blood rite and signature when useful, drinks flasks, and recovers 2% max HP/s while under attack. Hollow Knight and Veilwalker auto gain 30% ward between their defensive abilities. Veilwalker phases under pressure instead of draining its meter against every lone enemy. Easy enemies deal 0.3× Medium damage (previously 0.6×); Medium and Hard enemy damage is unchanged. Manual movement, targets, menus, and gathering still take control.

The offline browser drove the **real scene and auto policy**, starting fresh level-1 characters in the Graves with Easy auto on for three minutes (`tools/qa/easy-auto-balance.cjs`, browser random seed 43). These are one-run samples, not a statistical guarantee:

| Class | Kills / 3 min | Deaths | Healing flasks used | End HP |
|---|---:|---:|---:|---:|
| Ossuary necromancer | 291 | 0 | 0 | 190/190 |
| Grave Warden | 138 | 0 | 1 | 101/128 |
| Bell Monk | 122 | 0 | 0 | 111/128 |
| Carrion Witch | 109 | 0 | 0 | 111/128 |
| Hollow Knight | 119 | 0 | 0 | 128/128 |
| Veilwalker | 72 | 0 | 0 | 114/114 |

The Knight row is a repeat after its guard change; the Veilwalker row is a repeat after its ward and phase policy changes. The other rows ran before those class-specific changes. A second final Veilwalker run (seed 44) made 69 kills with zero deaths and zero flasks. One earlier run with the old Veilwalker policy died at 141 seconds. These short, level-1 Graves samples do not establish later-area or long-session survival. The headless Medium numbers below use a different scripted bot, so they should not be compared directly with the Easy browser rows.

## New Blood simulation (2026-09-28)

The report includes discipline indices 5–9. The updated bot uses the real `Player` resource and damage rules, class arcs, Witch crows, Veil form, and available defensive rites. **Graves / intended / 3 minutes / seeds 42–44** produced:

| Class | Kills/min | Mean deaths | Earliest first death |
|---|---:|---:|---:|
| Grave Warden | 27.6 | 6.7 | 13 s |
| Bell Monk | 23.7 | 7.0 | 8 s |
| Carrion Witch | 26.9 | 4.7 | 17 s |
| Hollow Knight | 12.9 | 8.3 | 12 s |
| Veilwalker | 29.1 | 1.7 | 23 s |

The established Ossuary necromancer bot made 96.9 kills/min with no deaths under the same settings. That comparison exposes a large solo farming gap, but the policies differ: the necromancer fights behind thralls, while the new-family bot walks into range and never dodges, drinks flasks, or retreats from packs. Its level-1 melee classes cannot use their later defensive rites. The 3-seed geared Graves and Ossuary runs also showed repeated new-class deaths. These are release risk signals, not calibrated player outcomes; a human combat pass and a bot with movement and defensive timing are needed before tuning damage or enemy health from this table.

The full **medium / 3-minute / seeds 42–44** run on 2026-09-28 covered all four areas and all four bands (`BALANCE_SEEDS=3 npm run balance`). Intended-band results below are **kills per minute / mean deaths**. The four necromancer disciplines made 70.6–126.7 kills/min and averaged 0–1.3 deaths across these areas.

| Class | Graves | Ossuary | Nave | Sanctum |
|---|---:|---:|---:|---:|
| Grave Warden | 27.6 / 6.7 | 35.0 / 6.7 | 25.4 / 8.7 | 21.3 / 8.3 |
| Bell Monk | 23.7 / 7.0 | 25.6 / 8.3 | 19.6 / 10.0 | 14.3 / 9.3 |
| Carrion Witch | 26.9 / 4.7 | 22.1 / 7.3 | 11.2 / 11.3 | 16.0 / 7.7 |
| Hollow Knight | 12.9 / 8.3 | 14.0 / 7.7 | 9.1 / 10.0 | 6.6 / 9.0 |
| Veilwalker | 29.1 / 1.7 | 19.0 / 6.3 | 16.1 / 7.7 | 13.6 / 6.7 |

At geared Wave Speed 3, every new class still averaged at least 5.3 deaths in every area. This bot currently skips Shield Bash, Grave Slam, Resonant Step, Knell, Choir, Chain Pull, Cremate, Hook Pull, Hex Charm, and Echo; it therefore understates several kits' offense and control. It also enters close combat without reacting to telegraphs. The next balance pass should exercise those rites and movement before setting numeric buffs, followed by a human playtest.

## Necro pass (2026-10-02)

Four necromancer disciplines x nine hunting grounds x `intended,geared,push,max`, **8 seeds, 3 sim-minutes**
(`BALANCE_SEEDS=8`; the report now also prints `1st med`, the median seed's first death, because the
min-over-seeds `1st†s` is set by one unlucky seed). "Old" = the code at the start of the pass with only the
harness fix below, so the comparison is like for like.

### What was wrong (measured, not guessed)
1. **A harness bug hid part of the problem.** When an enemy stood exactly on the bot, the back-off step divided
   0 by 0 and the bot's position became NaN for the rest of the run: no kills, no damage, no deaths (seen as
   rows with ~0 kills/min and 0 deaths at max). Fixed in `harness.ts`. The true old max band is *worse*
   than the baseline table in the ROADMAP: mean 7.8 deaths per 3 min (max 12.1).
2. **Past tier ~3 more density is pure danger.** The bot clears about 100 bodies/min and the base wave rate is
   already about that, so at tier 8 (supply 2.9x) the field just sat at the cap (peak 60-72 enemies vs ~40 at
   the intended band). Kills/min do not rise with supply; they fall as deaths climb. Per-enemy HP x1.24,
   damage x1.28 and +6.4% elite chance stacked on top.
3. **Death was a spiral.** After a death the whole mob stayed in the area; the caster walked back in 12 s later
   with no thralls and no corpses into the pile that killed it (lives of 10-20 s, 5-11 deaths).
4. **The second wave landed ~4 s in** at tier 8 (interval 3 s): first deaths at 5-8 s, before a single thrall.
5. XP did not scale with Wave Speed at all, so tier 8 could never out-earn the intended band in XP.

### What changed
| Change | Where | Why |
|---|---|---|
| Density terms (interval, cap, wave size) climb at full rate to tier 3 and at **0.55x** after (`densityTier`) | `upgrades.ts` | tiers 0-3 are unchanged (the healthy rows); past that, extra supply only piles up |
| Per-enemy terms gentler: HP +1.8%/tier (was 3), damage +2.6% (was 3.5), elite +0.4% (was 0.8) | `upgrades.ts` | tier 8: HP x1.14, damage x1.21, elites +3.2% |
| **XP scales with the dial**: +5%/tier, +15% Nightfall (tier 8: x1.55). Gold stays +10%/tier, +25% Nightfall | `upgrades.ts`, `loot.ts` | rewards keep climbing while density levels off: that is the pay for the risk |
| **Ramp**: Wave Speed builds linearly over the first 30 s of a visit (`rampTier`); the arrival wave is a plain greeting; Vanguard/Nightfall appear as the ramp passes their tier | `WorldSim.ts` | first deaths were 5-8 s in, with no legion up yet |
| **Vacant areas crumble**: no living player in an area for 8 s removes its enemies (no loot) and the next arrival gets a fresh greeting wave | `WorldSim.ts` | breaks the death spiral; a death now costs the 12 s respawn plus rebuilding the legion, not the whole run |
| Ossuary: thrall HP x1.6 -> x2.0, Bone Ward 6% -> 10% per thrall (3 thralls: 18% -> 30%) | `disciplines.ts` | the caster is protected for longer after the shieldbearers' first losses |
| Mourner: thrall HP x0.9 -> x1.0, corpse heal 8% -> 10% | `disciplines.ts` | weakest necro in Coliseum/Sanctum at the intended band |
| Coliseum elite chance 16% -> 13% | `areas.ts` | smaller arrival spike; the farm rate and gold are kept |
| `report.ts`: area column widened (the `coliseum` rows ran into the band name and were dropped by greps); `1st med` column | `report.ts` | |
| Guard tests | `__tests__/balance-necro.test.ts` | curve shape, arrival ramp, vacancy, and the target rows |

`necro-rules.cjs` was regenerated (it bundles `areas.ts`; only the Coliseum elite chance changed).

### Results (means over the 4 necromancers x 9 areas, 8 seeds; ratios are to the *intended* band of the same row)
| Band | | kills/min | gold/min | XP/min | deaths / 3 min | median first death |
|---|---|---|---|---|---|---|
| max (tier 8) | old | 0.54x | 1.34x | 0.61x | **7.8** (max row 12.1) | 8-34 s |
| max (tier 8) | **new** | **1.18x** | **2.50x** | **1.84x** | **2.1** (max row 3.4) | 41-161 s |
| push (tier 6) | old | 0.79x | 1.51x | 0.90x | 5.7 | 19-57 s |
| push (tier 6) | new | 1.21x | 2.03x | 1.60x | 1.7 | 47-180 s |
| geared (tier 3) | old | 1.30x | 2.12x | 1.55x | 1.3 | |
| geared (tier 3) | new | 1.41x | 2.13x | 1.80x | 0.4 | |

Per area at max (deaths old -> new): Graves 4.1 -> 0.5, Warren 4.4 -> 1.3, Ossuary 6.1 -> 2.4, Coliseum 10.0 -> 2.8,
Nave 9.7 -> 2.4, Sanctum 9.8 -> 2.5, Cloister 8.9 -> 2.5, Pyre 9.2 -> 2.4, Fen 8.2 -> 2.1.

Target rows (per discipline; kills/min, gold/min, XP/min, deaths, median first death):
| Row | old max | new max | intended (unchanged) |
|---|---|---|---|
| Nave Gravecaller | 30 / 695 / 544 / 9.9 / 7 s | 104 / 2298 / 2772 / 2.5 / 33 s | 107 / 1143 / 1879 |
| Nave Ossuary | 34 / 637 / 512 / 11.8 / 8 s | 150 / 3185 / 3937 / 2.5 / 54 s | 125 / 1384 / 2251 |
| Nave Mourner | 28 / 719 / 566 / 9.6 / 7 s | 111 / 2491 / 3009 / 2.6 / 40 s | 90 / 1018 / 1668 |
| Nave Rotweaver | 45 / 1220 / 940 / 7.4 / 9 s | 100 / 2330 / 2861 / 2.1 / 36 s | 103 / 1147 / 1879 |
| Sanctum Gravecaller | 25 / 1208 / 984 / 9.1 / 21 s | 79 / 3199 / 4209 / 2.8 / 38 s | 80 / 1680 / 2877 |
| Coliseum Ossuary | 47 / 727 / 627 / 12.1 / 12 s | 185 / 2765 / 3614 / 3.4 / 35 s | 178 / 1916 / 3248 |
| Coliseum Mourner | 35 / 802 / 647 / 9.8 / 11 s | 102 / 2207 / 2797 / 2.9 / 25 s | 82 / 1030 / 1717 |

Max by discipline (mean of 9 areas): Ossuary 10.1 -> **2.2** deaths, Gravecaller 7.3 -> 2.2, Mourner 7.2 -> 2.0,
Rotweaver 6.6 -> 2.0. Ossuary is now level with the others rather than the worst; it is still the top earner
(143 kills/min vs ~100) as it was at the intended band (111 vs 87-95).

Intended band (healthy rows): kills/min, gold and XP are within +-10% of the old numbers in every one of the
36 rows (the largest moves are Coliseum Mourner/Rotweaver kills +16%, from fewer spiral deaths). Intended deaths
per 3 min: Coliseum Ossuary 1.9 -> 0.9, Mourner 1.5 -> 1.0, Rotweaver 1.4 -> 0.5; Sanctum Mourner 1.9 -> 0.9,
Gravecaller 1.0 -> 0.3; every row is now at most 1.0.

Bosses: `npm run balance:boss` (3 seeds) is unchanged for Gravecaller and Rotweaver (dodgers win 166-173 s; non-dodgers
wipe). Ossuary (higher thrall HP and Bone Ward) wins 1 in 6-8 non-dodging intended runs with ~2% boss HP left
(was 0/6); Mourner is unchanged.

Other classes (indices 5-9, 4 seeds, Graves/Ossuary/Nave/Sanctum, intended and max): nothing broke. They
benefit from the same wave/ramp/vacancy rules; max-band deaths fall from 8.8-13.5 to 4.8-8.8 and kills/min roughly
double. Their intended-band gold moved -30% to +30% on 4 seeds (noise; the bot still dies 5-8 times per run, see the
New Blood section above), so these rows are not retuned.

### Closed open issues
- Gravecaller weakest under pressure: gone (all four at 2.0-2.2 deaths at max; the spiral was the cause).
- Ossuary discipline swings hardest: now level with the others (see above).
- Nave at max Wave Speed kills arrival-level bots within ~5 s: median first death 40 s, deaths 9.7 -> 2.4.

### Still open
- Death at max is a smaller spiral, not none; the bot has no flasks/dodging, so a human should land lower.
- Ossuary's win rate against a non-dodging Prelate rose from 0 to ~1 in 6-8.
- A human playtest of tier 6-8 (ramp, vacancy greeting waves, XP) is still needed.
- The vacancy rule means leaving an area for 8+ s and coming back triggers a fresh greeting wave (a small, bounded farm).


`npm run balance` drives the real `WorldSim` with a scripted necromancer bot
(`src/gameplay/balance/harness.ts`) and prints one row per area × level band ×
discipline. The bot is **an upper bound on kill efficiency** (perfect targeting,
instant reactions) but **never dodges telegraphs**, so its damage taken from
penitent cones and Bell-Tolled rings is higher than a careful player's.

```bash
npm run balance                                  # 3 simulated minutes per row, seed 42
BALANCE_SEEDS=3 npm run balance                  # average seeds 42..44 (use this for decisions)
BALANCE_AREAS=nave BALANCE_BANDS=push,max npm run balance
BALANCE_KIT=auto npm run balance                 # each band wears its gear kit (see "Gear pass"); default none = the bot with no gear
```

Columns: `hurt%/m` damage taken per minute as % of max HP · `minHp` lowest HP
reached · `1st†s` seconds to the first death (`-` = survived) · `unlock m`
minutes of kills to open the next area. Deaths model the real respawn: 4 s in
the Chapterhouse plus ~8 s to waystone back.

## Level bands (defined in `bands.ts`)

| Band | Who | Level | Damage tiers | Wave Speed |
|---|---|---|---|---|
| intended | just arrived | area level | ≈0.6 × level | 0 |
| geared | settled in | area level + 3 | ≈0.9 × level | 3 |
| push | greedy | area level | ≈0.6 × level | 6 |
| max | reckless | area level | ≈0.6 × level | 8 |

## Targets

| Band | hurt%/m | minHp | Deaths / 3 min | Feel |
|---|---|---|---|---|
| intended | 10–60 | 30–80 | 0 | Pressure you notice; a mistake costs a flask, not a life. (Graves is the tutorial: low end.) |
| geared | 5–40 | ≥ 25 | 0 (≤ 0.5) | Comfortable farming — you're paying for Wave Speed 3 with levels. |
| push | 50–250 | 0 | 0.5–4 | Dangerous: the bot (no dodging) dies occasionally; a dodging player rarely. |
| max | 150+ | 0 | 3+ | Arrival-level power at max Wave Speed should kill a careless player. Owning tier 8 costs ~14k gold, so real players arrive far stronger. |
| pacing | — | — | — | Bot opens the next area in 3–5 min (humans ≈ 5–8). |

## Current numbers (2026-09-26, 3 seeds, after the first balance pass)

Ranges across the four disciplines:

| Area | intended hurt%/m · minHp | geared hurt%/m | push hurt%/m · deaths | max deaths | unlock (bot) |
|---|---|---|---|---|---|
| Hollow Graves | 4–22 · 51–75 | 4–13 | 47–98 · 0.3–1 | 0–6 | 3.1–3.5 min |
| Marrow Ossuary | 8–20 · 48–81 | 10–58 | 88–271 · 1.3–5 | 2.3–11 | 3.4–3.6 min |
| Drowned Nave | 24–54 · 0–61 | 18–39 | 122–317 · 1.3–6.3 | 8–11 | 3.9–5.3 min |
| Bell Sanctum | 5–26 · 0–80 | 2–9 | 173–202 · 2.7–3.3 | 3.3–8.3 | — |

Before this pass (same harness, 1 seed): intended 0–15 hurt%/m everywhere,
unlock in 2.7–3.7 min, and push/max either harmless (Graves, Sanctum) or a
13–27-death spiral (Ossuary, Nave).

### What changed
- Trash is tougher and hits harder (HP ×1.4, damage ×1.25; penitent cone 16 → 18):
  the Bone Needle was killing a Grave Robber in under a second at 11 m, so nothing ever arrived.
- Denser waves: cap/wave size Graves 28/9, Ossuary 32/10, Nave 34/11, Sanctum 26/8 (interval 7.5 → 6.5 s).
  Nave roster shifted slightly from penitents toward robbers and hounds.
- Wave Speed compounds less: interval +12%/tier (was 16), cap +9% (12), wave size +6% (12),
  enemy damage +3.5% (5). Throughput at tier 8 is ≈2.9× base instead of 4.3×.
- The first-visit arrival wave is a fixed 1.3× greeting that ignores the Wave Speed dial (was 1.6× × dial).
- Unlock thresholds 200/280/360 → 300/420/520 kills (unlocks already earned stay unlocked).

### Open issues (2026-09-26; the first three are closed by the 2026-10-02 necro pass above)
- **Gravecaller is the weakest discipline under pressure** (worst push/max rows in every area):
  warriors with 0.85× HP die fast, and five of them don't ward the caster. Candidates: Bone Ward
  per thrall, or a thrall HP floor.
- **Ossuary discipline swings hardest.** Shieldbearers soak everything until they die, then the
  caster is exposed (0 damage at intended, most deaths at max).
- **Nave at max Wave Speed** still kills arrival-level bots within ~5 s of the greeting wave.
  It's acceptable for the reckless band, but it's the harshest spot in the game.
- A human-played session is still needed to calibrate how far below the bot's efficiency real players land.

## The Bell-Sworn Prelate (`npm run balance:boss`)

`src/gameplay/balance/boss.ts` summons the Prelate with a full legion already raised and fights
until it dies, the bot dies (a solo death resets the boss), or 6 minutes pass. Each discipline
runs twice: **dodging** (steps out of toll/slam/rain circles after a 0.35 s reaction) and **not
dodging**. The bot carries 4 major flasks (70%, 1.5 s cooldown) and drinks below 40% HP.

**Targets:** at arrival level, a careful player wins in 2.5–3.5 min with some HP to spare, and one
who ignores telegraphs dies. Geared players finish in about 2 min and can brute-force it with flasks.

**First pass (2026-09-26):** base HP 4200 → 26000 (solo ≈ 95k at level 13). Party scaling is now
+80% per extra player (was +60%), because four players deal ~4× damage while the Prelate splits its
attacks. Bell Rain uses the sim's seeded RNG (it used `Math.random`), so fights are reproducible.

| Band | Dodge | Result (3 seeds × 4 disciplines) | Kill time | Min HP | Flasks |
|---|---|---|---|---|---|
| intended (lvl 13) | yes | 12/12 wins | 154–175 s | 31–39% | 0.3–1.3 |
| intended | no | 0/12 — wipes with the boss at 3–17% | — | 0 | 4 |
| geared (lvl 16) | yes | 12/12 | 110–122 s | 34–56% | 0–0.7 |
| geared | no | 12/12 | 113–124 s | 29–35% | 3.3–4 |

Before: every row won in 16–30 s. Direct hits (Needle and Marrow Spear, with Fracture) do ~75% of the
damage and Withered ~20%. Adds from the processions barely matter (0–10% of damage taken), which
makes them a candidate for a bigger role later. `src/gameplay/__tests__/balance.test.ts` guards the
intended-band rows.

## Wave Speed milestones

At tier 3 **Elite Vanguard** guarantees an elite in every other regular wave. At tier 6 **Restless Crypts**
multiplies the surge interval by 0.6. At tier 8 **Nightfall** shrouds 50% of common spawns and adds
+0.25 reward / +0.2 item chance. The first draft (an elite in *every* wave, *all* commons shrouded)
pushed the push band to 0.5–8.5 deaths and dropped max-band gold below push. With the softened
version, push is 0.5–9 deaths / 3 min (mostly 1–5) and max stays the reckless band (2–13.5 deaths,
first death in 6–38 s).

## Difficulty (Easy / Medium / Hard)

`content/difficulty.ts`. Medium is everything above. Enemies and the Prelate get HP × and damage ×,
kills/surges/Prelate give gold + XP ×, and Hard adds +2% elite chance. It's picked in Settings. The
world keeper's value runs the sim and rides in snapshots (older hosts → medium), and changes apply to
new spawns. Harness: `BALANCE_DIFFICULTY=easy|hard npm run balance` (also `balance:boss`).

| | HP | Damage | Rewards | Farming (intended band) | Prelate (intended, 3 seeds) |
|---|---|---|---|---|---|
| Easy | 0.75 | 0.6 | 0.75 | Graves 1–11 %HP/min, Nave 18–48; no deaths even at push in the Graves | everyone wins in ~2 min, even without dodging |
| Medium | 1 | 1 | 1 | see tables above | dodgers win in ~2.7 min; non-dodgers die |
| Hard | 1.2 | 1.3 | 1.3 | Nave 56–96 %HP/min, occasional deaths; Sanctum 15–77 | dodgers win in ~3.4 min using every flask; non-dodgers die |

## Ascension

`content/ascension.ts`. Each rank adds +3 levels to every enemy, toxic pool and the Prelate, and +5%
gold/XP. `BALANCE_ASCENSION=N` runs both harnesses with the bands anchored on the aged level. At matching
level, Ascension III plays like the base game: Graves 0–21 %HP/min, Nave 22–36; the Prelate falls in
~2.3 min for dodgers and still kills 3 of 4 disciplines who don't dodge. In practice characters arrive
over-levelled for the early areas of a new run (level, gear and gold persist), which is intended: early
seals go fast, and the aged late areas catch up. Ashes per run: 10 for the first Prelate kill,
+5 per extra kill (max 4), +2 per peak Wave Speed tier, +1 per 300 kills (max 15), ×(1 + 0.25·rank).
Boons are per-character only: stats, costs, thrall cap, Soul Harvest, unlock thresholds.

## Co-op session dashboard (planned)

Easy/Medium/Hard is the first slice of this. The remaining knobs (Wave Speed tier, enemy HP/damage multipliers, density, elite chance, surge
frequency, arrival-wave size, roster weights) should become a **host-side session dashboard for
co-op rooms**. See `FUTURE_CONTENT.md` → "Co-op session dashboard".


## Mourning Fen vs Cinder Pyre (2026-09-30, 8 seeds, 3 sim-minutes, same level in both)

The Fen is a level-scaled area (min 45), so it is compared with the Pyre at equal player levels (45 and 65) rather than at the area floors.
`npx vite-node src/gameplay/balance/fenCompare.ts` reproduces it; the bot also wades the bog at the real slow (x0.78), as a hero would.
Target: danger similar to the Pyre, XP/min about 10-15% higher (enough to reward going there).

    kills = kills/min, xp = XP/min, hurt = damage taken as % of max HP per minute, deaths per 3 min
    L45 Gravecaller intended | pyre kills 90 xp 13219 hurt 46 deaths 0.4 | fen kills 81 xp 14854 hurt 74 deaths 0.9 | xp ratio 1.12
    L45 Gravecaller geared   | pyre kills 128 xp 22953 hurt 67 deaths 0.6 | fen kills 105 xp 23529 hurt 109 deaths 1.5 | xp ratio 1.03
    L45 Ossuary     intended | pyre kills 100 xp 14249 hurt 29 deaths 0.3 | fen kills 96 xp 17853 hurt 44 deaths 0.3 | xp ratio 1.25
    L45 Ossuary     geared   | pyre kills 156 xp 27481 hurt 52 deaths 0.8 | fen kills 144 xp 31917 hurt 99 deaths 0.9 | xp ratio 1.16
    L45 Mourner     intended | pyre kills 79 xp 11689 hurt 72 deaths 1.3 | fen kills 83 xp 14575 hurt 57 deaths 0.4 | xp ratio 1.25
    L45 Mourner     geared   | pyre kills 98 xp 17394 hurt 124 deaths 2.5 | fen kills 110 xp 24673 hurt 93 deaths 0.8 | xp ratio 1.42
    L45 Rotweaver   intended | pyre kills 84 xp 12418 hurt 65 deaths 1.0 | fen kills 84 xp 15909 hurt 70 deaths 0.8 | xp ratio 1.28
    L45 Rotweaver   geared   | pyre kills 106 xp 19097 hurt 106 deaths 1.6 | fen kills 107 xp 25747 hurt 63 deaths 0.5 | xp ratio 1.35
    L65 Gravecaller intended | pyre kills 94 xp 20696 hurt 36 deaths 0.4 | fen kills 88 xp 24397 hurt 36 deaths 0.3 | xp ratio 1.18
    L65 Gravecaller geared   | pyre kills 143 xp 35589 hurt 44 deaths 0.3 | fen kills 122 xp 37817 hurt 62 deaths 0.5 | xp ratio 1.06
    L65 Ossuary     intended | pyre kills 100 xp 20959 hurt 13 deaths 0.1 | fen kills 99 xp 24457 hurt 18 deaths 0.0 | xp ratio 1.17
    L65 Ossuary     geared   | pyre kills 165 xp 40539 hurt 26 deaths 0.1 | fen kills 151 xp 44123 hurt 66 deaths 0.8 | xp ratio 1.09
    L65 Mourner     intended | pyre kills 95 xp 20313 hurt 28 deaths 0.1 | fen kills 88 xp 23236 hurt 53 deaths 0.4 | xp ratio 1.14
    L65 Mourner     geared   | pyre kills 134 xp 33104 hurt 48 deaths 0.4 | fen kills 126 xp 39029 hurt 55 deaths 0.6 | xp ratio 1.18
    L65 Rotweaver   intended | pyre kills 95 xp 19529 hurt 32 deaths 0.3 | fen kills 95 xp 25708 hurt 27 deaths 0.0 | xp ratio 1.32
    L65 Rotweaver   geared   | pyre kills 149 xp 36838 hurt 54 deaths 0.4 | fen kills 125 xp 37682 hurt 47 deaths 0.3 | xp ratio 1.02

Level 65 (the live top band): XP/min is +14% on average (range 1.02-1.32, bot noise is large), hurt%/min is at or below the Pyre at `intended`
and 10-40 points above it when `geared` (wave speed 3 fills the bog with leeches), deaths stay at or under 0.8 per 3 minutes. Level 45 runs
hotter on XP (+23%; the Fen's XP is a flat per-kill table, and the bot's kill rate differs most at lower gear); left as is (it is the
entry band). Tuning that got here: leech 4 dmg / 22 hp / 4.2 speed / 5 XP, hag 12 dmg / 24 XP, wisp 9 dmg / 19 XP, sexton 25 dmg / 54 XP, cap 24.
