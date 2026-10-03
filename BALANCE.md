# Crossworlds — Balance targets & current numbers

## Necro pressure pass (3 Oct 2026, `claude/necro-pressure-balance`): re-measure, no tuning needed

Brief: re-check the three ROADMAP P3 findings on current master (8bb1bd3) before touching numbers. Four necromancers x nine grounds x `intended,push,max`, kit `none`, medium, **8 seeds, 3 sim-minutes** (`BALANCE_AREAS=graves,warren,ossuary,coliseum,nave,sanctum,cloister,pyre,fen BALANCE_DISCIPLINES=1,2,3,4 BALANCE_SEEDS=8 BALANCE_BANDS=intended,push,max npm run balance`).
Result: **all three findings are already closed by the 2 Oct "Necro pass" above (the ROADMAP bullets list them as findings "as measured" before that fix). Nothing is still true, so no number was changed** and there is no "after" column: the table is master as it stands.

| Finding | Re-measured on master | Verdict |
|---|---|---|
| (a) Ossuary dies most at max Wave Speed | deaths / 3 min at max: Ossuary **2.10**, Gravecaller 2.11, Rotweaver 2.04, Mourner 1.66 (the old numbers were 8-11.5). Ossuary still earns most (148 kills/min vs 93-105). Worst single Ossuary rows: Coliseum 3.3, Nave 2.6, Sanctum 2.6 (target 2-4) | closed |
| (b) Coliseum / Sanctum spike at arrival level, Mourner dies at the intended band | intended deaths: Coliseum Mourner **0.3** (was 1.8-2.5), Sanctum Mourner 0.4; Coliseum mean 0.53, Sanctum 0.38 against an all-ground mean of 0.28. Highest intended rows: Pyre Gravecaller 1.1, Cloister Gravecaller 1.0 (not Coliseum/Sanctum), Coliseum Ossuary 0.8 | closed |
| (c) Tiers 6-8 should pay more, not less | max vs intended, mean of 36 rows: kills 1.17x, gold 2.31x, XP 1.71x; push (tier 6): 1.24x / 1.92x / 1.55x. Max beats push on gold (+20%) and XP (+10%); kills/min are 6% under push (112 vs 119) because deaths rise 1.5 -> 2.0 | closed (see note) |

Band means (kills / gold / XP per minute, deaths per 3 min): intended 96 / 1,740 / 4,177 / 0.28; push 119 / 3,349 / 6,471 / 1.49; max 112 / 4,012 / 7,139 / 1.98. Max deaths by ground: Graves 0.3, Warren 1.0, Ossuary 2.3, Coliseum 2.5, Nave 2.4, Sanctum 2.3, Cloister 2.4, Pyre 2.4, Fen 2.2. Intended deaths by ground: 0.0 / 0.0 / 0.2 / 0.5 / 0.2 / 0.4 / 0.4 / 0.7 / 0.3. These match the 2 Oct figures within seed noise (max 1.15x / 2.29x / 1.69x / 1.99 deaths then).

Note on (c): kills/min dip slightly from tier 6 to tier 8 while gold and XP climb. That is by design from the necro pass (density levels off past tier 3, rewards keep rising); I did not retune because the pay still rises where it counts and the bot (no dodging, no flasks) over-dies there. A human playtest of tiers 6-8 remains the open question, as before.

Checks: `npx tsc --noEmit` clean; `npm test` 1,153 tests green (`runes.test.ts` needs `npm ci --prefix server/realtime` first or it fails on a missing `dotenv`). No server-mirrored file changed, so no `build:server-rules` or `test:server` run was required.

## New Blood leveling audit (2026-10-03, branch `claude/newblood-leveling-audit`, harness only, not deployed)

Question: why do the New Blood classes (5 Grave Warden, 6 Bell Monk, 7 Carrion Witch, 8 Hollow Knight, 9 Veilwalker) level 4-8x slower than the four necromancers in `npm run balance`? **Answer: mostly a real gameplay gap (the necromancer's thralls), with a harness-bot part that is now fixed.** No class power, XP formula, zone or boss number was changed.

### What was a harness bug (fixed, `src/gameplay/__tests__/balance-newblood.test.ts`)
The New Blood bot under-measured its classes. XP itself is not a cause: `rollKill` takes no class input, the game awards it per kill whoever lands it, and the bot already counted every kill (the game's kill-chain multiplier is modelled for nobody).
1. **Rites cast before they unlock.** Burn the Dead and Veil Tear (level 3) were cast at level 1 (over-credit); every gate read the starting level, not the level reached during the run. Now `character.level` against `unlockLevel(id)`.
2. **Reach measured centre to centre.** The game counts the body's radius (`NewBloodSystem.target`, `hollowCut`). The Hollow Knight approached to 2.6 m but could cut only at 2.4 m, a dead zone that left it idle against any enemy that stopped there: 14.5 -> 26 kills/min at Graves by itself.
3. **Half the kit never cast.** Added Cremate, Resonant Step, Knell, Choir of One, Sound the Corpse, Great Toll, Hex Charm, Murder of Crows, Lay to Rest, Between Worlds, Shield Bash and Grave Slam (all existed in the sim; none had a bug, every cast reports ok). Still skipped: Chain Pull, Hook Pull, Butcher, Echo, Crossing (control or positional).
4. **Never stepped out of a telegraph.** Half of the damage a New Blood bot took came from telegraphed blows (caster cones, dust, eruptions, rings), which a player and the Easy auto brain sidestep. The bot now reads `telegraph` events and sidesteps after a 0.25 s reaction (`BalanceRun.dodge`, default on, New Blood only; the necromancer bot never dodged and its rows are byte-identical to before).
`BalanceResult.casts` now reports casts per ability, so "does the bot use the kit" can be read off a run.

### Numbers (medium, 3 sim-minutes, 8 seeds, kit none; XP/min, mean of the 4 necromancers vs the mean of the 5 New Blood)

| Ground, band | Necromancers XP/min | New Blood before | New Blood after the harness fix | Gap before -> after | NB deaths / 3 min before -> after | Levels per 3 min, necro / NB after |
|---|---|---|---|---|---|---|
| Graves intended | 370 | 82 | 123 | 4.5x -> 3.0x | 6.0 -> 4.0 | 4.0 / 1.9 |
| Ossuary intended | 897 | 141 | 228 | 6.4x -> 3.9x | 6.5 -> 4.8 | 3.6 / 0.8 |
| Nave intended | 1,930 | 204 | 364 | 9.5x -> 5.3x | 7.7 -> 5.2 | 4.6 / 0.7 |
| Sanctum intended | 2,875 | 323 | 576 | 8.9x -> 5.0x | 6.5 -> 4.3 | 5.1 / 0.9 |
| Graves max | 919 | 127 | 179 | 7.2x -> 5.1x | 6.2 -> 4.7 | 6.5 / 2.3 |
| Nave max | 3,256 | 316 | 592 | 10.3x -> 5.5x | 7.7 -> 5.5 | 7.3 / 1.4 |
| Sanctum max | 4,880 | 486 | 859 | 10.0x -> 5.7x | 6.6 -> 4.4 | 8.2 / 1.4 |

(Ossuary max: 1,816 vs 209 -> 330, 8.7x -> 5.5x.) The harness fixes buy +50% to +85% XP/min (Hollow Knight and Bell Monk gain most, Veilwalker least), so the true gap is **3-6x**, not 4-10x. Best fixed class per ground is the Bell Monk or Grave Warden, worst the Veilwalker or Carrion Witch at the deeper grounds.

### What is left is real: where the necromancer's lead comes from
Graves intended and Nave intended, 4 seeds (kills/min, XP/min, deaths per 3 min):

| Row | Graves | Nave |
|---|---|---|
| Necromancers with thralls | 90 / 372 / 0.0 | 110 / 1,983 / 0.1 |
| Necromancers, thrall cap forced to 0 (the needle and the AoE rites alone) | 72 / 300 / 0.1 | 71 / 1,234 / 2.2 |
| New Blood, final bot | 34 / 122 / 4.0 | 28 / 363 / 5.3 |
| New Blood, bot never dodges | 27 / 92 / 5.8 | 21 / 244 / 7.5 |
| New Blood, cannot die (+500 VIT) | 50 / 208 / 0.0 | 49 / 796 / 0.1 |

1. **Thralls are worth about 20-35% of a necromancer's kills and nearly all its survival.** Without them a necromancer still kills 72 a minute (it kites at 11 m, with Corpse Explosion every 0.6 s and Marrow Spear lines) but takes 87-150% HP a minute instead of 18-48%.
2. **A New Blood hero cannot survive its own position.** It fights inside the pack at 1.8-3 m (Monk, Warden, Knight) or 8-11 m with no body in front (Witch, Veilwalker); it takes 190-230% of its HP a minute and dies 4-5 times in 3 minutes, which at 12 s a respawn is about 30% of the run, and each respawn walks back into the same pack (lives last 10-25 s). Immortal, the same bots reach 50 kills/min, so deaths cost about 35-45% of the output, the rest is raw damage.
3. **Raw damage is lower for the same spell power.** All classes share `spellPower`. A necromancer chains AoE (Corpse Explosion 1.8x, Spear 2.1x, Litany 1.5x at level 1) fuelled by every kill's corpse; a level-1 New Blood has one 1.0x single-target or short-arc primary plus two or three rites, several corpse-gated.
4. **XP/min amplifies kill rate**, since XP per kill is flat per enemy and level: kills/min differ 2.6-5.7x and XP/min 3-6x. Enemy XP also scales with the enemy's level, which in the level-scaled grounds follows the hero, so a faster leveller is paid more per kill (not separately measured here).
5. Not modelled for any class, and so not an explanation: the kill-chain XP multiplier (rewards kill rate, which would widen the gap in the live game), healing flasks, the shared cast lock, gear.

### Owner options (nothing applied; the owner asked for a human check before retuning class power)
Measured on the fixed bot (4 seeds x 5 New Blood, XP/min versus necromancer 372 at Graves / 1,983 at Nave, 4.0 / 4.8 necromancer levels per 3 min):

| Option | Graves XP/min (levels/3 min, deaths) | Nave XP/min (levels, deaths) | What it changes |
|---|---|---|---|
| Today | 122 (1.9, 4.0) | 363 (0.7, 5.3) | |
| **A. Survivability:** New Blood +50% max HP (or an equal damage-taken cut), +100% as the upper bound | +50%: 144 (1.9, 2.8); +100%: 164 (2.2, 1.9) | +50%: 419 (0.9, 4.5); +100%: 525 (1.2, 3.5) | Removes deaths but not the slow kills; at Nave even +100% only reaches 27% of the necromancer. Cheapest, least effective alone. |
| **B. Damage:** every New Blood primary and rite x1.5 (x2 as the upper bound) | x1.5: 187 (2.4, 2.6); x2: 244 (3.0, 1.7) | x1.5: 601 (1.3, 4.1); x2: 827 (2.1, 3.3) | The bigger lever: x2 puts Graves at 66% and Nave at 42% of the necromancer, and halves deaths. Touches boss and PvE balance for these classes, so re-run `npm run balance:boss`. |
| **A+B:** +50% HP and x1.5 damage | 218 (2.6, 1.4) | 709 (1.6, 3.3) | Roughly the Option B x2 result with fewer deaths. |
| **C. Pacing only, no combat change:** an XP catch-up multiplier for non-necromancer disciplines for the first ~15 levels (x2-x3, fading to x1) | x2.5 would roughly match the necromancer's XP/min at Graves (122 -> about 300), arithmetic only, not simulated | same | Leaves kit power alone, so a human playtest can judge class feel separately. Cheapest to reverse; does nothing for the 4-5 deaths per 3 minutes. |

Recommendation for a human to confirm: **B at about x1.5 on the primary and the cheap rites, plus C for the early levels**, then a playtest of the Monk, Warden and Knight (the melee three die most). Do not judge the Veilwalker or Witch from this harness: both are ranged with no body in front, and their gap (3.4-5x after the fix) is the largest at depth. A human with flasks, dodge-rolling and gear will close more of it than the bot does, so expect the in-game gap to be smaller than 3-6x; the first thing to check by hand is whether a level-1 Warden, Monk or Knight can survive Graves without help.

Reproduce: `BALANCE_SEEDS=8 BALANCE_AREAS=graves,ossuary,nave,sanctum BALANCE_BANDS=intended,max BALANCE_KIT=none npm run balance`; `dodge: false` in a `runBalance` call reproduces the old standing bot for the New Blood rows.

## Combat owner decisions (2026-10-03, branch `claude/combat-owner-decisions`, not deployed)

Three owner decisions (docs/polish/combat.md): Bone Needle runes ride the scythe arc, Damage and Reinforce purchases refresh standing thralls, Easy auto dodges boss telegraphs.

**Before / after, bands unchanged.** `BALANCE_SEEDS=8 npm run balance` (8 seeds, 3 sim-minutes, 9 classes x 4 grounds x 4 bands, all 144 rows) and `npm run balance:boss` (3 seeds, the Prelate) are **byte-identical** before and after: the harness bot never wields a scythe, never buys a tier mid-run and is not Easy auto, so none of the three changes can move a default row. That is the honest "no regression"; the buffs below are measured separately. (Bands are the BALANCE.md targets above: nothing moved, so none broke.)

**Runes under a scythe** (`RUNE_KIT=typical RUNE_WEAPON=scythe RUNE_SEEDS=8 npm run balance:runes`, kit's main hand swapped for a scythe, 4 necromancers x 8 seeds x 3 sim-minutes; kills per minute versus the same scythe with no rune; before the change a rune under a scythe did nothing, so before = 0.0% by construction):

| Ground, band | Splinters kills / ttk / hurt | Marrow-Tap kills / ttk / hurt | Volley |
|---|---|---|---|
| Nave, push | +2.6% / +9.1% / -1% | -1.7% / +11.3% / -15% | 0.0% (needle-only) |
| Nave, intended | +1.4% / -2.0% / -22% | -0.1% / +2.2% / +3% | 0.0% |

Per discipline the spread is wider (Nave push: Marrow-Tap Gravecaller +14.1%, Rotweaver -13.1%; the bot spends its extra essence on rites, so a softer swing pays only for the builds that cast), which is bot noise at 8 seeds, not a band break. Everything sits inside the "runes add variety, 0-10% either way" target on average, so **no effect was scaled down**. The scythe rules: Marrow-Tap = the swing hits 30% softer and returns +4 essence once per landed swing; Splinters = one 30% shard per swing to the nearest foe the arc missed.

**Thrall refresh** is a one-time bump at the moment of purchase: the largest single step is the first Damage tier (+8% thrall damage) or one Reinforce tier (+3% health and damage, +1% attack speed), applied to thralls that would otherwise lose it until their next Exhume (a legion is re-raised constantly, so the lasting stats were already there). Host-clamped to 1.25x. It cannot move a harness row (no purchases mid-run); the unit tests pin the arithmetic (health keeps its fraction, never a heal; the other player's thralls and dead thralls untouched).

**Easy auto dodge** (dev accounts only, gating untouched): `src/gameplay/__tests__/auto-dodge.test.ts` first runs the real boss brains against the dodge's shapes (16 telegraph kinds across the seven bosses, a 0.55 m grid of bystanders each: who the host hurts is exactly who the shape says), then an end-to-end fight: a hero standing 5 m from each boss for 90 game-seconds across all three phases (2 seeds, blows taken counted from the brain's `hurt` events; pool ticks count per tick):

| Boss | blows taken, standing still | blows taken, Easy auto with the dodge |
|---|---|---|
| Bell-Sworn Prelate | 100 | 0 |
| Gravedigger King | 84 | 0 |
| Bone Abbess | 97 | 0 |
| Drowned Congregation | 92 | 0 |
| Plague Saint | 900 (mostly rot-pool ticks) | 62 |
| Cinder Regent | 1,339 (mostly coal-pool ticks) | 54 |
| Mire Mother | 46 | 0 |

What it still does not do: walk up to a boss on its own (Easy auto only chases enemies), use the Congregation's pews as cover, or dodge things that are not telegraphs (adds' melee, the Fen's leeches, Hags' hexes). Cost: nothing when no boss is awake and no pool is down; otherwise one pass over the live shapes and the zones per frame while Easy auto is on, and a re-plan (about 500 point tests) only when it stands in a shape.

## Catacomb Depths (2026-10-02, `npm run balance:depths`; branch `dm/depths`, not deployed)

The dead on depth *d* are level `max(12, hero level) + d` (content/depths.ts; the plan said `max(20, ...)`, but a level-20 floor is a wall for the level-8 to 12 heroes the Warren admits, so the floor is the Warren's own entry level). Enemy health grows +22% and damage +15% of a level-1 body per level, so +10 depths is about +20% of both at level 40. A floor spawns only what its quota still needs, at most 24 alive, from the chambers nearest the hero. `npm run balance:depths` holds one floor of a depth (a cleared floor re-rolls the same depth) and prints the four necromancers beside the Cinder Pyre and Mourning Fen at the same hero level (`DEPTH_LEVELS`, `DEPTH_DEPTHS`, `DEPTH_BANDS`, `DEPTH_DISCIPLINES`, `BALANCE_SEEDS`, `BALANCE_MINUTES`). Medium difficulty, 4 seeds x 3 sim-minutes, mean of Ossuary / Gravecaller / Mourner / Rotweaver; intended = progress kit, geared = typical kit:

| Hero level, band | Ground (enemy level) | kills/min | XP/min | gold/min | damage taken %HP/min | lowest HP % | deaths / 3 min |
|---|---|---|---|---|---|---|---|
| 20 intended | Pyre (30) | 90 | 8,940 | 4,418 | 59 | 0 | 0.6 |
| | Fen (45) | 84 | 14,617 | 3,550 | 97 | 2 | 0.8 |
| | **depth 1** (21) | 31 | 718 | 389 | 10 | 69 | 0.0 |
| | **depth 10** (30) | 45 | 5,042 | 2,552 | 79 | 0 | 0.5 |
| | **depth 20** (40) | 31 | 5,524 | 2,484 | 201 | 0 | 3.6 |
| 40 intended | Pyre (40) / Fen (45) | 99 / 98 | 12,899 / 17,749 | 6,335 / 4,316 | 14 / 24 | 62 / 40 | 0.1 / 0.1 |
| | **depth 1** (41) | 34 | 1,431 | 735 | 12 | 70 | 0.0 |
| | **depth 10** (50) | 56 | 10,501 | 5,209 | 44 | 14 | 0.4 |
| | **depth 20** (60) | 60 | 17,287 | 7,696 | 134 | 0 | 1.8 |
| 43 geared | Pyre / Fen | 145 / 120 | 25,782 / 28,795 | 14,570 / 8,560 | 30 / 58 | 35 / 2 | 0.1 / 0.1 |
| | **depth 1 / 10 / 20** | 35 / 62 / 70 | 1,776 / 13,233 / 22,720 | 980 / 6,980 / 10,984 | 13 / 36 / 110 | 77 / 45 / 0 | 0.0 / 0.0 / 1.3 |
| 60 intended | Pyre / Fen (60) | 102 / 99 | 19,805 / 22,877 | 9,492 / 5,510 | 20 / 16 | 30 / 63 | 0.0 / 0.0 |
| | **depth 1 / 10 / 20** | 39 / 50 / 74 | 2,463 / 12,813 / 29,136 | 1,256 / 6,238 / 12,997 | 10 / 26 / 101 | 79 / 39 / 0 | 0.0 / 0.1 / 1.1 |
| 63 geared | Pyre / Fen | 152 / 133 | 38,976 / 41,126 | 21,580 / 11,908 | 20 / 34 | 55 / 31 | 0.1 / 0.1 |
| | **depth 1 / 10 / 20** | 39 / 65 / 86 | 2,759 / 18,642 / 37,330 | 1,509 / 9,679 / 17,889 | 8 / 20 / 86 | 84 / 58 / 0 | 0.0 / 0.0 / 0.7 |

Reading it. Depth 1 is a warm-up (nothing dangerous, little pay). Depth 10 is about as dangerous as the Pyre at the same level and pays 50-90% of its XP per minute (the harness bot never walks to the stair and floors hold their pace to what is needed, so kills per minute are 40-65% of the open grounds' on purpose: the Depths are not the XP grind, they are the "one more floor" and the chests). Depth 20 is where it bites: 1-4 deaths per 3 minutes for these bots (a human dodges telegraphs the bot does not), XP/min at or above the Pyre's from level 43. No gear was nerfed to get here ("gear should make you strong"); the curve is the level formula and the elite affix schedule alone. Non-necromancer disciplines are far behind everywhere in the harness (their kits were never tuned) and are not read here.

**Authority peak** (`AREA_PEAK.depths`): `DEPTH_LEVELS=40 DEPTH_DEPTHS=5,10,20 DEPTH_BANDS=max DEPTH_DISCIPLINES=1,2,3,4,5,6,7,8,9 DEPTH_REFERENCE=pyre,fen BALANCE_DIFFICULTY=hard BALANCE_SEEDS=2` (the settings of docs/SERVER-AUTHORITY.md); best column, rescaled to enemy level 50: 27,600 XP, 16,000 gold, 72 kills per minute (Rotweaver on depth 20: 32,802 XP / 18,857 gold / 72 kills at enemy level 60).

**What the harness cannot show.** The bot never walks to the stair (a real descent adds several seconds a floor), does not click chests, and does not weigh a floor's rooms; it fights what it can see and steps through doorways toward the rest. It cannot judge how the walls feel for a human (cones stop at them), how a Hungering plus Shrouded elite reads, or how a depth-20 floor feels at a human's dodge rate. Pacing (a floor takes 20-60 s) is the number a playtest should confirm.

## Relic runes (2026-10-02, `npm run balance:runes`; branch `dm/runes`, not deployed)

Target from the brief: runes add build variety, not raw power, about 0-10% either way. The harness bot (balance/harness.ts) casts each rite the way `AbilitySystem` does with that rune (shared geometry in `gameplay/runeCast.ts`, shared numbers in `content/runes.ts` `RUNE_TUNING`).
`npm run balance:runes` runs the four necromancers with one rune at a time against the same seeds with none (`RUNE_TUNE="ring.damageMult=0.8,..."` tries a number without editing; `RUNE_KIT`, `RUNE_AREA`, `RUNE_BAND`, `RUNE_ONLY`, `RUNE_DISCIPLINES`); `BALANCE_RUNES=bone_needle:rune_volley,exhume:rune_bone_colossus npm run balance` puts runes in the normal report.

**Nave, push band (Wave Speed 6), no gear, 16 seeds x 3 sim-minutes, kills per minute versus no rune** (no rune: Ossuary 152, Gravecaller 112, Mourner 93, Rotweaver 97 kills/min):

| Rune | Ossuary | Gravecaller | Mourner | Rotweaver | Mean kills | Mean gold | Mean time to kill | Mean damage taken |
|---|---|---|---|---|---|---|---|---|
| Splinters | +3.4% | +13.6% | +5.3% | +12.5% | **+8.7%** | +12.3% | +1.8% | -6% |
| Marrow-Tap | +18.5% | -5.2% | -5.5% | -7.9% | **0.0%** | -0.1% | -11.6% | +4% |
| Volley | +4.4% | -2.7% | +8.5% | -2.7% | **+1.9%** | +3.1% | -1.6% | -6% |
| Ossuary Ring | +5.6% | +2.7% | +14.8% | +17.3% | **+10.1%** | +11.6% | -4.7% | -6% |
| Impaling | -0.2% | -11.0% | +9.8% | -5.9% | **-1.8%** | -4.1% | -5.8% | +7% |
| Mass Grave | -4.1% | +4.2% | +7.8% | -0.9% | **+1.8%** | +0.7% | -6.5% | +4% |
| Bone Colossus | -9.6% | -0.9% | +8.8% | -7.4% | **-2.3%** (-1.8% with the final 4.0x / 3.5x, 24 seeds) | -2.8% | +1.6% | +4% |
| Creeping Rot | +0.4% | -3.2% | +1.1% | +3.8% | **+0.5%** | -1.0% | +0.9% | -4% |
| Contagion | +0.7% | +8.0% | +3.6% | +13.7% | **+6.5%** | +8.5% | +9.1% | -5% |
| Hollow Choir | +2.9% | +4.0% | +5.2% | +6.4% | **+4.6%** | +4.8% | +5.1% | -10% |
| Requiem | +7.9% | +1.6% | +9.3% | +8.8% | **+6.9%** | +9.5% | +9.2% | -7% |

Every mean sits between -3% and +10%. The per-discipline spread (for example Marrow-Tap +18.5% on the Ossuary and -5% to -8% on the others) is mostly seed noise plus real discipline differences (the Ossuary bot is essence-starved, so essence runes pay it more); 16 seeds leave about +-4 points per cell.

What the tuning moved (first pass at the spec's numbers, then the shipped ones): Splinters 50% -> 30% of the damage (was +14%), Volley needles 50% -> 40% and the volley returns one needle's essence between the three (it was +12% mostly from tripled essence), Ossuary Ring 100% -> 80% damage and 3.2 -> 3.0 m, Impaling +25% -> +50% damage (the bot now spends it only above 50 essence), Mass Grave 60% -> 75% stats (it was -5%: a pure loss whenever the legion was already at its cap), Contagion reach 5.5 -> 4.5 m, Requiem 2x -> 1.7x radius (was +11%), Bone Colossus 2x -> 3.5x damage, 3.5x -> 4x health, 1.7 s -> 1.2 s swing, 6 s -> 4 s cooldown (was -7% to -15%).

**Gear (typical kit, Bell Sanctum, 12 seeds):** the bot is capped by the wave supply there (165 kills/min, 0 deaths with no rune), so kills/min moves under 1% for every rune except the Colossus (-3.0%); the time-to-kill column carries the signal (Splinters -11%, Ossuary Ring -11%, Colossus +31%, Marrow-Tap +12%). **Four-rune build** (Volley + Colossus + Contagion + Requiem, Nave, 4 seeds, Gravecaller / Rotweaver): intended band 105.5 / 103.9 kills/min against 111.8 / 100.0 with no rune (-6% / +4%), push band 112.8 / 107.3 against 102.8 / 97.9 (+10% / +10%).

**What the harness cannot see.** Enemies never leave a Requiem or a Ring, the bot does not choose targets (Impaling on an elite, the Colossus as a tank for a boss, Creeping Rot into a corner), and nothing here tests the Colossus against the bosses; the Colossus is deliberately a little below parity in kills per minute (it is one big body: strong against elites and bosses, weaker at filling the legion), and that is the one thing a human playtest should confirm. `src/gameplay/__tests__/runes.test.ts` pins the behaviour, not these percentages.

## Polish round 2 (2026-10-02, 8 seeds, 3 sim-minutes; bosses 6 seeds)

Re-audit after the strike timing, run clips, set bonuses, retuned affixes and the gear harness changes of the same day. Nothing in the farming numbers had
drifted; the boss pass found three bosses that were too easy and one harness hole (below).

### 1. Necromancer matrix (4 disciplines x 9 grounds x intended/push/max; kit `none`, and `progress` (intended) / `typical` (push, max))
Means over the 36 area x discipline rows. "Necro pass" = the table above in "Necro pass (2026-10-02)" (kit `none`).

| Band | kit | kills/min | gold/min | XP/min | deaths / 3 min (worst row) | median first death | necro pass deaths |
|---|---|---|---|---|---|---|---|
| intended | none | 97 | 1736 | 4178 | 0.30 (1.1) | 169 s | <= 1.0 per row |
| intended | progress | 107 | 2057 | 4873 | 0.01 (0.1) | 180 s | |
| push | none | 115 (1.19x intended) | 3303 | 6347 | 1.61 (2.9) | 87 s | 1.7 |
| push | typical | 171 | 5465 | 9568 | 0.19 (1.0) | 171 s | |
| max | none | 112 (1.15x) | 3978 (2.29x) | 7068 (1.69x) | **1.99** (2.9) | 65 s | 2.1 (3.4) |
| max | typical | 177 | 7084 | 11411 | 0.27 (1.6) | 161 s | |

Targets from the necro pass: max out-earns intended (kills 1.15x, gold 2.3x, XP 1.7x: held; necro pass 1.18x / 2.50x / 1.84x); deaths 2-4 per 3 min at max without gear
(2.0, worst row 2.9: held); at most 1 per 3 min at intended (0.3; two rows sit at 1.0 and 1.1: Pyre Rotweaver, Coliseum Mourner, within the old seed noise); no zone spike
(max deaths Graves 0.4, Warren 1.3, the other seven 2.2-2.4; the same shape as before). Per discipline at max: Ossuary 2.2, Gravecaller 2.2, Rotweaver 2.0, Mourner 1.7, so the Ossuary
ties for most deaths with the Gravecaller rather than being the outlier it was (10.1 before the necro pass). Ossuary still earns most (145 kills/min vs 96-103 at max).

Drift: max deaths 2.1 -> 2.0, push 1.7 -> 1.6, kills ratio 1.18x -> 1.15x, gold 2.50x -> 2.29x, XP 1.84x -> 1.69x. All within the noise of the 8-seed means; the strike-timing, set-bonus and
affix changes did not move the kit-less bot. The one remaining odd corner is Coliseum, where max earns only 1.02x the intended kills (133 vs 131) because the intended rate there is already high; gold and XP still climb (2.3x / 1.8x).
With a kit the gear-pass picture is unchanged: typical + max pushes deaths to 0.27 (0.0 in seven grounds), but the **Fen (1.4 deaths) and Pyre (0.7)** keep a real edge because the base gear stats are flat
and those grounds are level 30 and 45 (same as table 2 of the gear pass). The remaining "gear trivialises max Wave Speed" gap is the owner decision in ROADMAP (base item stats); not touched.

### 2. Area bosses (`npm run balance:boss`, `BALANCE_BOSS=<id>`, `BALANCE_KIT=none|auto`; 6 seeds x 4 necromancers, intended = arrival level, geared = +3 levels)
The boss harness now wears gear kits (`kit` on `BossRun`; `auto` = progress at intended, typical at geared; set bonuses and the skull-focus thrall bonus are folded as in the farming harness; the staff / scythe / wand
play-style was not modelled in the boss bot at the time; it is now, see "Boss bot coverage"). It also had a hole: the Mire Mother's nav area (Fen) was not unlocked, so the bot never reached her (0 damage dealt or taken, every row a "timeout").

Kit `none`, dodging, intended band (kill time of winning runs, min HP across seeds); "no dodge" = never leaves a telegraph.

| Boss (area level) | before: dodge time / min HP | before: no dodge | after: dodge time / min HP | after: no dodge |
|---|---|---|---|---|
| Gravedigger King (1) | 84-116 s / 65-100% | wins 24/24, 31-37% | **123-164 s** / 65-100% | wins 24/24, 28-35% |
| Bone Abbess (4) | 114-141 s / 75-84% | wins 24/24, 24-33% | **152-207 s** / 64-84% | wins 24/24, 24-33% |
| Drowned Congregation (9) | 134-160 s / 21-30% | 0/24 | unchanged | unchanged |
| Bell-Sworn Prelate (13) | 159-170 s / 27-37% | 1/24 | unchanged | unchanged |
| Plague Saint (20) | 139-156 s / 33-60% | 0/24 | unchanged | unchanged |
| Cinder Regent (30) | 118-129 s / 26-34% | 0/24 | unchanged | unchanged |
| Mire Mother (45) | (unreachable, harness) 108-141 s / 90% once reachable | wins 24/24, 75-89%, 1-3% per minute damage | **143-190 s** / 66-95% | wins 24/24, 20-55%, 130-170%/min |

Changes (all in `src/content/bosses.ts`; `necro-rules.cjs` regenerated since it bundles it):
- Gravedigger King `baseHp` 15500 -> 22000, Bone Abbess 13000 -> 17000: the first two bosses died in 84-141 s to a careful arrival-level bot, against a 150-210 s target. They stay the gentlest bosses (a non-dodger still wins).
- Mire Mother `baseHp` 32000 -> 42000 and damage x1.9 (surface 42 -> 160 with the ring windups unchanged, maul 26 -> 80, hands 15 -> 45). She was by far the easiest boss: 1-3% of max health per minute taken by a dodging bot,
  75-89% minimum health even for a bot that ignores every telegraph, killed in under 2.5 minutes. Now a non-dodger drops to 20-55% and a dodger is still barely touched (the bot only sidesteps the ripple rings; real play also has the open-water hands, the flood and the phase-3 rite, which it does not model, so she is probably harder in practice than the table says).
  A non-dodging bot still wins; it takes about 150%/min. Raising it further only makes the surface ring a one-shot, so it was left here for a human playtest.
- Guard tests: `src/gameplay/__tests__/balance-bosses.test.ts` (every boss: a careful bot wins in 100-300 s through three phases, ignoring telegraphs costs > 60% of max health a minute).

With a typical kit (`BALANCE_KIT=auto`; same seeds): the kits shorten every fight by 25-45% at the intended band and 40-65% at the geared band, e.g. Prelate intended 87-98 s, geared 56-71 s; Saint 80-97 s / 56-75 s; Regent 79-91 s / 53-67 s;
Congregation 83-100 s / 44-56 s. Gravedigger at the geared band with a first set dies in 33-50 s (dps 470-665 vs 140-190 kit-less), the Abbess in 30-54 s. Bosses with real mechanics (Congregation, Saint, Regent, Prelate) still punish a
non-dodger at the intended band with a kit (Saint 0/24, Regent 17/24 wins at 0-34% HP), so they are not trivial, but they are short. This is the same base-stat effect as the gear pass (a first set doubles damage); bosses were **not** inflated to absorb it because
the owner's base-stat decision (ROADMAP) would double-count. If the owner leaves the item stats as they are, the boss HP of Congregation through Regent should rise about +35% to keep the 2.5-3.5 minute target for a geared player.

### 3. Other classes (indices 5-9; Graves, Ossuary, Nave, Sanctum; intended and max; kit none; 4 seeds)
Nothing is broken and nothing moved in a bad direction. Deaths per 3 minutes are 5-9 at both bands (the New Blood bot still never dodges or retreats), down from 8-11 at Nave and Sanctum before the necro pass rules (the vacancy/ramp rules help them too).
Kills/min: 9-31 at the intended band; Hollow Knight stays the slowest (7.5 kills/min at Sanctum max, 9.0 intended, 66-80 minutes of kills to unlock the next ground), Carrion Witch and Grave Warden lead. These are bot-quality figures, not tuning targets; the bot skips most defensive rites (see New Blood simulation).
No numbers changed.

### Reproduce
```bash
BALANCE_SEEDS=8 BALANCE_DISCIPLINES=1,2,3,4 BALANCE_AREAS=graves,ossuary,nave,sanctum,cloister,pyre,warren,coliseum,fen BALANCE_BANDS=intended,push,max BALANCE_KIT=none npm run balance   # then BALANCE_KIT=progress (intended), =typical (push,max)
BALANCE_BOSS=mire BALANCE_SEEDS=6 BALANCE_KIT=auto npm run balance:boss      # every boss id; kit none by default
```

### Unfinished
- Bosses are not rebalanced for gear (waiting on the base-stat decision); see the +35% note above.
- ~~The boss bot does not use the staff / scythe / wand play-style, the Litany barrier or the open-water mechanics of the Fen~~: done 2026-10-03 ("Boss bot coverage" below). Still open: a human playtest of the Mire Mother, the Abbess and a scythe Mourner; the Mire Mother's phase-3 rite is not modelled.
- The Fen with a kit is the only ground that is still comfortably dangerous; that is the base-stat story, not a number to tune here.

## Boss bot coverage (2026-10-03, 8 seeds, solo, Medium, no migration)

Until now the boss bot ignored the necromancer weapon line, the Litany barrier and the Fen's open water, so boss numbers for those builds were unmeasured. The bot (`src/gameplay/balance/boss.ts`) now plays them through the
real code paths (`weaponLine.ts` helpers, the real `Player.takeDamage`, `content/fen.ts` `bogMult`/`FEN_HUMMOCKS`), not copies of the rules:

| What | How the bot does it |
|---|---|
| Staff | Needle reach x1.25, +10% spell power (`deriveStats`), pierces the add behind its target (`pierceTargets`, x0.8). A needle that hits the boss itself does not pierce, as in play. |
| Scythe | The left click is the reaping arc (`reapTargets`, 3 m + body, up to 3 targets, the boss takes one slot, 520 ms swing, +4 essence per target). The scythe bot walks up to the boss and stays there; it dodges telegraphs like any dodger. |
| Wand | Needle cadence x1.3, damage x0.85 (`abilityCooldownMs`). |
| Sickle | Needle withers adds (not the boss, as in play); Exhume refunds essence. |
| Grimoire | Rite cooldowns shortened (`abilityCooldownMs`); skull focus thrall bonus was already folded. |
| Litany barrier | Damage goes through a real `Player` body: Bone Ward (capped), Colossus guard, then the barrier before health; the bot raises barrier per body consumed (as `AbilitySystem.onLitany`) and it melts at 4% max health/s. New `barrierMadePct` / `barrierAbsorbedPct` on `BossResult`, `barrier%` in the report. |
| Open water | Wading slows the bot as in `WorldScene`: the Fen bog (hummocks dry, flood shrinks them and deepens the slow, `bogMult`) and the Congregation's nave water from phase 2. Roots (hands, grasps, burial) stop movement, casting continues. A careful (dodging) bot in the Fen stands on a dry hummock at casting range (or scythe reach) and hops off the one the ripple ring is drawn on; a careless bot wades. `wadingPct`, `rootedS`, `wade%`, `rooted s` report it. |

Not modelled: the Mire Mother's phase-3 rite (the bot spends corpses as it always did, so the rite is usually starved and she staggers), hummock-hopping for a non-dodging bot, Colossus Litany Shatter, off-hand mourning bell heals, essence flasks/brews. The barrier is cast on the bot's old timing (boss within 7 m, 3+ bodies), not ahead of a known telegraph, so a dodger often lets it melt unused (0-11% of max health absorbed); a human who times it will get more.

### Reproduce
```bash
BALANCE_BOSS=all BALANCE_SEEDS=8 BALANCE_KIT=typical BALANCE_WEAPONS=staff,scythe,wand,sickle npm run balance:boss     # every boss x band x discipline x weapon x dodge/no dodge, with a deaths column
BALANCE_BOSS=mire,saint BALANCE_KIT=auto BALANCE_BANDS=intended BALANCE_WEAPONS=staff,scythe BALANCE_DODGE=yes npm run balance:boss   # auto = progress kit at intended, typical at geared
```
`BALANCE_WEAPONS` (`kit` = the discipline's own weapon), `BALANCE_BOSS` (`all`, a list, or `--boss id`) and `BALANCE_DODGE` are new; `deaths` = runs ending in a wipe (a solo death resets the boss). Weapons are worn through `BossRun.kitOverride`, so they need a kit other than `none`; with the
`progress` kit the Graves has no earlier weapon tier, so the Gravedigger rows are identical for every weapon.

### Results: kill time in seconds of winning runs, **after** (before), dodging bot; `(Nd)` = wipes out of 8, `x` = it mostly wipes
Bold = the new bot moved it. "Before" is the same kit and weapon, played the old way (every weapon fought as the plain needle). `progress` kit at the intended band (the band future tuning should target):

| Boss | Discipline | staff | scythe | wand | sickle |
|---|---|---|---|---|---|
| Gravedigger | Ossuary | 156 | 156 | 156 | 156 |
| Gravedigger | Gravecaller | 121 | 121 | 121 | 121 |
| Gravedigger | Mourner | 158 | 158 | 158 | 158 |
| Gravedigger | Rotweaver | 142 | 142 | 142 | 142 |
| Abbess | Ossuary | 122 | **193** (144) | **136** (151) | 151 |
| Abbess | Gravecaller | 109 | **153** (129) | **119** (132) | **131** (132) |
| Abbess | Mourner | 120 | **191** (142) | **130** (144) | 144 |
| Abbess | Rotweaver | 97 | **150** (112) | **100** (110) | **107** (110) |
| Congregation | Ossuary | **87** (94) | **130** (103) | **101** (109) | 110 |
| Congregation | Gravecaller | **73** (77) | **92** (86) | **79** (83) | 85 |
| Congregation | Mourner | **85** (91) | **123** (101) | **93** (99) | 100 |
| Congregation | Rotweaver | **80** (84) | **113** (94) | **85** (91) | **90** (91) |
| Prelate | Ossuary | 93 | **138** (105) | **102** (110) | 109 |
| Prelate | Gravecaller | 77 | **103** (88) | **80** (86) | **86** (87) |
| Prelate | Mourner | **88** (89) | **x (7d)** (101) | **92** (98) | 99 |
| Prelate | Rotweaver | **81** (80) | **112** (91) | **80** (87) | **86** (87) |
| Saint | Ossuary | 92 | **169** (104) | **96** (115) | 111 |
| Saint | Gravecaller | 76 | **117** (85) | **69** (77) | 80 |
| Saint | Mourner | **87** (88) | **165** (96) | **93** (98) | **102** (100) |
| Saint | Rotweaver | 77 | **117** (85) | **73** (84) | **80** (83) |
| Regent | Ossuary | 84 | **140** (94) | **91** (98) | 99 |
| Regent | Gravecaller | 75 | **129** (84) | **73** (78) | 78 |
| Regent | Mourner | 81 | **139** (92) | **84** (91) | 92 |
| Regent | Rotweaver | 72 | **111** (80) | **72** (78) | **77** (79) |
| Mire Mother | Ossuary | **123** (118) | **168** (138) | **124** (141) | 142 |
| Mire Mother | Gravecaller | **72** (80) | **113** (88) | **74** (84) | **77** (84) |
| Mire Mother | Mourner | **120** (118) | **164 (1d)** (134) | **119** (126) | **130 (1d)** (128) |
| Mire Mother | Rotweaver | **93** (92) | **125** (109) | **93** (104) | **100** (106) |

`typical` kit (completed first set + the area's weapon tier) at the geared band:

| Boss | Discipline | staff | scythe | wand | sickle |
|---|---|---|---|---|---|
| Gravedigger | Ossuary | 46 | **62** (52) | **50** (52) | 52 |
| Gravedigger | Gravecaller | 31 | **34** (33) | **31** (33) | 33 |
| Gravedigger | Mourner | 45 | **63** (50) | **47** (50) | 50 |
| Gravedigger | Rotweaver | 39 | **50** (44) | **39** (42) | 42 |
| Abbess | Ossuary | 51 | **72** (57) | **55** (60) | **58** (60) |
| Abbess | Gravecaller | 27 | **40** (30) | **28** (30) | **29** (30) |
| Abbess | Mourner | 49 | **71** (55) | **50** (55) | **53** (55) |
| Abbess | Rotweaver | 38 | **50** (43) | **39** (42) | **41** (42) |
| Congregation | Ossuary | **51** (55) | **78** (63) | **61** (65) | 66 |
| Congregation | Gravecaller | **39** (42) | **44** (47) | **41** (44) | 44 |
| Congregation | Mourner | **48** (52) | **71** (59) | **53** (56) | **56** (57) |
| Congregation | Rotweaver | **42** (44) | **58** (50) | **44** (47) | 47 |
| Prelate | Ossuary | 68 | **95** (77) | **74** (80) | 80 |
| Prelate | Gravecaller | **53** (54) | **54** (59) | **52** (56) | 56 |
| Prelate | Mourner | **64** (65) | **87** (73) | **66** (71) | 72 |
| Prelate | Rotweaver | 55 | **72** (61) | **55** (59) | **58** (59) |
| Saint | Ossuary | 70 | **121** (79) | **75** (82) | 84 |
| Saint | Gravecaller | 54 | **66** (62) | **53** (55) | 57 |
| Saint | Mourner | 67 | **120** (79) | **70** (75) | 77 |
| Saint | Rotweaver | 54 | **82** (61) | **54** (58) | **59** (62) |
| Regent | Ossuary | 62 | **101** (71) | **69** (73) | 75 |
| Regent | Gravecaller | 54 | **81** (60) | **51** (55) | 53 |
| Regent | Mourner | 61 | **101** (68) | **62** (67) | 67 |
| Regent | Rotweaver | 49 | **73** (56) | **49** (53) | **52** (54) |
| Mire Mother | Ossuary | **122** (118) | **169** (136) | **121** (137) | 137 |
| Mire Mother | Gravecaller | **78** (87) | **120** (91) | **90** (97) | **95** (97) |
| Mire Mother | Mourner | **119** (116) | **163 (2d)** (131) | **122** (138) | **137** (138) |
| Mire Mother | Rotweaver | 90 | **115 (3d)** (101) | **93** (103) | **98** (103) |

### What changed and what it says
1. **Staff and sickle are unchanged** (the old bot already got their stat effects; they only add pierce/wither on adds, which barely matter in a boss fight). **Wand gets 5-17% faster** (the cadence was never used) and the grimoire (Rotweaver's off-hand) gains 1-6% from shorter rites.
2. **The scythe is the slowest style on every boss, 10-90% slower than the staff** (Saint Ossuary 92 -> 154 s with the typical kit, Prelate 98 -> 124 s). The scythe's cost is standing in melee (walking after a moving boss, leaving the telegraph and coming back, adds, maul/slam cones) and its needle dps being 16% lower than a staff's (1.15 / 0.52 s vs 1.0 / 0.38 s) with the cleave worth little on one boss. In exchange it takes 2-6x the damage: a careful scythe Mourner now **wipes 7 of 8 at the Prelate** with the progress kit, and 1-3 of 8 at the Mire Mother with the typical kit (geared band: Mourner 2/8, Rotweaver 3/8); the staff, wand and sickle never wipe there. A non-dodging scythe bot wipes at every boss with real mechanics (Gravedigger excepted); that row is a floor, not a player.
3. **The Fen mattered more than the table said.** A dodger at the Mire Mother used to take 0-6% of max health a minute (min HP 62-97%); with wading, hands and hummock-hopping it still wins in about the same time (staff -1 to -8%) but dips to 33-90% (Ossuary 97 -> 50%, Mourner 64 -> 35%, `hurt%/m` 0-6 -> 2-11). The Mire Mother is still the longest fight (113-185 s with the typical kit at the intended band) and the only boss inside the 150-210 s target for the Ossuary and Mourner there; Gravecaller and Rotweaver (sickle line) kill her in 72-135 s.
4. **Out of band (reported, not changed).** With the progress kit and a dodging bot the **Congregation, Prelate, Saint, Regent and the Gravecaller/Rotweaver Mire Mother die in 69-111 s against the 150-210 s target** with a staff, wand or sickle; the Abbess (97-151 s) and Gravedigger (121-158 s) sit at the low edge. This is the gear effect already recorded under "Polish round 2" and the owner's decision not to inflate boss HP against it (see the base-stats note at the end of this file), and it is the same for every weapon, so nothing here is weapon-specific. If the owner does want the progress-kit band at 150-210 s, the multipliers on `baseHp` would be about x1.4 (Abbess), x1.9 (Congregation), x1.9 (Prelate), x2.0 (Saint), x2.1 (Regent) and x1.6 (Mire Mother; Ossuary/Mourner x1.4, Gravecaller/Rotweaver x1.8-2.3) for staff/wand, which is a retune, not a number to nudge here. The scythe lands in or near the target (113-193 s) almost everywhere, because its melee cost is what the other styles lack.
5. **Scythe at the Prelate and the Mire Mother is the one weapon-specific band problem**: lethal for a Mourner (no ward, no barrier, thin health) and for the Rotweaver at the Mire Mother. There is no obvious small number behind it (it is melee exposure to the maul/slam cones plus bog wading on the dodge), so it is an owner decision: let the scythe keep a boss-only advantage (a bigger boss share of the arc, or reach 3 -> 3.5 m, which the Codex text already calls "close"), or accept it as the high-risk style.

Tests: `src/gameplay/__tests__/balance-boss-coverage.test.ts` (weapon styles differ, the scythe stands at the boss and pays for it, the barrier is raised and soaks damage, the Fen bot wades and is rooted when careless and hops when careful).

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


## Owner decision (2026-10-02): gear should make you strong

Base item stats stay as they are. The gear pass measured that an ordinary kit cuts deaths at push/max Wave Speed by ~89% and that an ascended set makes max nearly safe; that is intended. Do not scale item stats down, and do not raise boss HP or late Wave Speed pressure to cancel gear (the "+35% boss HP if base stats stay" note in Polish round 2 is declined). Future tuning should target the no-gear and progress-kit bands.

## Combat polish pass (3 Oct 2026, `dm/polish-combat`)

Sim changes (thrall targeting/pathing, hall-bound corpse rites) measured with 3 seeds, Graves and Nave, intended and push, four necromancers: kills/min 112.3 -> 113.5, damage taken 66.8% -> 65.3%/min, deaths 0.53 -> 0.47. Inside seed noise; nothing tuned. See docs/polish/combat.md.

## Affix tuning (3 Oct 2026, branch `claude/affix-tuning`)

Owner direction: polish, "reduce the loot, keep it valuable". Numbers only: no new affix, item or migration; affix ids, counts per rarity and drop-source odds are unchanged. Instrument: `npm run balance:affix` (new; the power score of an affix roll, a good drop, a rolled kit, a completed armour set and a legendary set, side by side, takes seconds), plus `balance:gear` (kit `rolled` vs `none`), `balance:score` and `balance:lever`. As in the 2 Oct pass, the sim bot cannot resolve a single affix (swaps move kills/min by -3..+3%, the noise floor), so affix values come from the power score, which the lever table calibrates.

### What was measured before (power score, plain typical kit, one median-rolled affix on the chest; mean over the four necromancers)
| Affix | ilvl 12 | 25 | 47 | 70 |
|---|---|---|---|---|
| best stat (INT) | 2.1% | 2.5% | 3.0% | 3.6% |
| Gravebound (thrall damage) | 0.9 | 1.3 | 2.0 | 2.7 |
| of the Legion (thrall health) | 0.9 | 1.1 | 1.5 | 1.6 |
| Whispering (essence regen) | 1.2 | 1.0 | 0.8 | 0.7 |
| of the Rotting Mist (Miasma) | 1.0 | 1.4 | 2.0 | 2.6 |
| Blighted (Withered) | 1.2 | 1.8 | 2.4 | 2.4 |
| of the Ossuary Wall (ward) | 0.7 | 1.0 | 1.7 | 2.1 |
| spread of the six levers (best / worst) | 1.8x | 1.8x | 2.9x | 3.9x |

Findings: (1) the levers grew faster with item level than stats, so at ilvl 70 Gravebound and Miasma were worth 75% of an INT roll on average and 1.4x INT for their home discipline; (2) essence regeneration *fell* with item level (the score divides it by a pool that grows with level: +15% regen is 1.2% at ilvl 12, +38% only 0.8% at 47); (3) a rolled 7-piece kit added 9-14% of power on average, 17-22% at the 90th percentile (Gravecaller highest); (4) legendary full-set bonus lines are worth 24-47% of power, ascended sets 10-19%, first sets 6-13%, so no affix roll can outclass a set; the closest case is three best affixes at ilvl 70 on one Mourner piece (6.7%) against the Mourner first set (6.2%, its flat lines shrink with level).

### What changed (`affixRules.ts`; tenths of a percent for the percentage affixes)
| Affix | centre old -> new (ilvl 12 / 47 / 70) | range at ilvl 47, old -> new |
|---|---|---|
| stat affixes (8) | 0.8+0.07L -> same up to ilvl 25, then 0.045 per level (1.6 / 3.5 / 4.6 points) | 3-5 -> 2-5; ilvl 70: 4-7 -> 3-6; unchanged up to 25 |
| Gravebound | 10(5.5+0.2L) -> 10(6.5+0.1L) | 10.4-19.4% -> 7.8-14.6% |
| of the Legion | 10(10.6+0.38L) -> 10(9.5+0.34L) | 19.9-37% -> 17.8-33.1% |
| Whispering | 10(10+0.42L) -> 10(10+0.5L) | 20.8-38.7% -> 23.4-43.6% |
| of the Rotting Mist | 10(5.2+0.22L) -> 10(5.2+0.12L) | 10.9-20.2% -> 7.6-14.1% |
| Blighted | 1..2+L/7 (cap 6) -> 1..2+L/9 (cap 4) | 1-6 -> 1-4 |
| of the Ossuary Wall | 9+0.7L (cap 60) -> 12+0.55L (cap 55), per mille | 2.9-5.4% -> 2.6-4.9% |

### After (same instrument)
| Affix, mean median value | ilvl 12 | 25 | 47 | 70 |
|---|---|---|---|---|
| best stat (INT) | 2.1% | 2.5% | 3.0% | 3.0% |
| Gravebound | 0.9 | 1.1 | 1.5 | 1.9 |
| of the Legion | 0.8 | 1.0 | 1.3 | 1.5 |
| Whispering | 1.2 | 1.1 | 0.9 | 0.8 |
| of the Rotting Mist | 0.9 | 1.1 | 1.4 | 1.8 |
| Blighted (median stack count unchanged in this table; expected count -17% above ilvl 36) | 1.2 | 1.8 | 1.8 | 1.8 |
| of the Ossuary Wall | 0.7 | 1.0 | 1.5 | 1.8 |
| spread of the levers | 1.8x | 1.8x | 2.0x | 2.4x |

| Item and kit numbers (power score) | before | after |
|---|---|---|
| Good drop, 3 affixes at 90% on one piece (4 necromancers), ilvl 12 / 25 / 47 / 70 | 5.1-5.7 / 5.6-6.7 / 6.6-9.8 / 6.7-11.9% | 5.0-5.8 / 5.9-6.1 / 6.8-8.4 / 6.2-9.0% |
| Good drop, Occult + home lever at 75%, ilvl 70 | 5.3-10.3% | 4.9-7.6% |
| Rolled 7-piece kit, mean / p90, Pyre | 10.0-13.9 / 14.1-21.2% | 9.1-12.4 / 13.0-18.8% |
| Rolled 7-piece kit, mean / p90, Fen | 10.6-13.2 / 15.6-22.1% | 8.7-10.5 / 12.9-16.7% |
| Completed set bonus lines, for comparison | first 6-13%, ascended 10-19%, legendary 24-47% | unchanged |

Reading: a good drop (two or three decent affixes on one slot) is still a 4-9% upgrade, the middle of the 5-15% target at the levels the zones actually drop; the top end (ilvl 70, perfect lever) no longer reaches 12%. Levers are within 2.0x of each other up to ilvl 47 (was 2.9x), and the remaining gap is essence regeneration, which the power score undervalues at high level (the harness lever table has +30% regen at +1.6% kills, between thrall damage and thrall health), so it was raised (slope 0.42 -> 0.5 per level) but not chased to the score. Home levers stay within 1.35x of the best stat affix at every ilvl (test). Three best affixes max-rolled on one piece stay under the whole ascended set's bonus lines at every ilvl (test); full-kit affix power (9-12%) sits at or under one first/ascended set, far under a legendary set.

### Stored items stay valid (no migration)
`affixRange` is now what NEW rolls use. Validation (`instanceProblem`: offline-sync import, the mock backend, forged-roll checks) uses `affixAcceptRange`: the widest of the current range and the previous generation's (`legacy` on each affix), so an item rolled under the 2 Oct ranges is legal after this change. The first build's ranges (4045faa) are not kept: it never stored a roll. Nothing else re-checks a stored roll: bag save only names an `instance_id` (ownership and item match are checked, not the values), and GET/Vault/Salvage read `ilvl` and `affixes` as stored. Tooltips clamp the quality bar at 100% for an old roll above the new range. Tests: `affixes.test.ts` (every old range endpoint legal at every ilvl 1-99), `affix-paths.test.cjs` (server bundle plus bag save), `gear-balance.test.ts` (home lever vs stat, good drop 3-12%, affixes under the ascended set, rolled kit mean < 14% and p90 < 22%).

### Server and client
`gathering/affix-rules.cjs` (and `legion-rules.cjs`, which bundles the same module) were regenerated with `npm run build:server-rules`; `loot.cjs` rolls with the bundle, the client mirrors it through `affixRules.ts`, and the offline mock shares the source. No mismatch found. The server bundle must ship with the client build (deploy copies `gathering/*.cjs`).

### Harness check (`balance:gear`, kit `rolled` vs `none`, Pyre and Fen push, 4 necromancers, 8 seeds, same seeds; base 8bb1bd3 vs this branch)
| | before | after |
|---|---|---|
| kills/min vs no kit (mean of 8 rows) | x1.30 | x1.32 |
| damage taken vs no kit | x0.64 | x0.62 |
| deaths per 3 min with the rolled kit | 0.61 | 0.58 |

Unchanged inside seed noise, as expected: the rolls differ per range, and the bot cannot resolve a 1-3% change. This is a "no regression" check; the sizes above come from the power score. `balance:score` baseline (before): Spearman against kills/min 0.46 over all swaps (the single-affix swaps are below the noise floor, unchanged from the 2 Oct finding).

### Legendary sets, re-measured (`legendaryReport.ts`, kit none, 4 seeds, Nave and Sanctum, intended/push/max, mechanics and set multipliers only, 24 rows)
Mean clear speed **x1.15**, mean damage taken **x0.92** (LEGENDARY-SETS.md quoted x1.17 / x0.86 after the 2 Oct tuning, an earlier pass x1.13). Still true: the full legendary set is nowhere near the +40-80% target in the sim (the power score puts the same bonus lines at +24-47%, a judgment value for mechanics the bot does not use well). By band: intended x1.0-1.1 (survival gains on Mourner/Sanctum), push x1.07-1.41, max x0.86-1.62; the Ossuary reads about flat on clear speed (its mechanics are defensive; its damage taken is noisy). Not retuned here: the task is affix ranges, and raising a legendary is a content/owner call. If the owner wants legendaries to feel like a +40% jump, the lever is `setBonuses.ts` (the mechanic strengths), not affixes. Affix tuning does not touch this: affixes stay far below a legendary set either way.

## Legendary power (3 Oct 2026, owner: polish, no new content or mechanics)
Target: a full legendary set at power (clear speed / damage taken) about 1.4-1.8 per discipline, max/min spread <= 1.15, first < ascended < legendary and 2pc < 4pc < 5pc. Numbers only, in `setBonuses.ts` (mechanic strengths and set multipliers; the mechanics, drop rates and shapes in `legendary.ts` are untouched). Harness wiring checked: the Mourner wisp heal and nova are modelled the same as `AbilitySystem` (3 wisps x 2% max HP/s, nova from wisps and wraith thralls), so no dead wiring was found; the Mourner was simply under-powered (it had no thrall damage or health in the set and a 10% max-health total). The Ossuary legendary lacked the maximum health and per-thrall ward its ascended set has, so it read below that set. `bossReport.ts` now treats `BALANCE_LEGENDARY=0` as off (it was read as on).

`legendaryReport.ts`, kit none, 4 seeds, Nave and Sanctum, intended/push/max (clear-speed x / damage-taken x / power):

| Discipline | Ascended full | Before leg5 | After leg5 |
|---|---|---|---|
| Ossuary | 1.06 / 0.65 / 1.64 | 1.06 / 0.96 / 1.10 | 1.11 / 0.67 / 1.66 |
| Gravecaller | 1.11 / 0.94 / 1.17 | 1.26 / 0.89 / 1.42 | 1.29 / 0.82 / 1.59 |
| Mourner | 1.09 / 0.69 / 1.59 | 1.11 / 0.91 / 1.22 | 1.14 / 0.69 / 1.65 |
| Rotweaver | 1.03 / 1.11 / 0.93 | 1.25 / 0.87 / 1.44 | 1.34 / 0.81 / 1.66 |

Spread max/min 1.31 -> 1.05; mean full set x1.17 clear / x0.91 damage -> x1.22 / x0.74. Clear speed barely moves (spawn-limited, and the Ossuary and Mourner are defensive) so the +40-80% shows as survival: power 1.59-1.66. Changes (full-set totals): Legion thrall damage +25% (kept), attack speed +10%, death burst 100%, Marrow Spear rally 75%, +2 cap; Colossus +50% thrall health/+25% damage/+10% health (2pc), 10% more thrall health + 5% ward per thrall (4pc), 22% guard, +6% health, barrier +5% (5pc); Requiem 12 s wisps, corpses heal 6%, +40% thrall health, +30% thrall damage, +10/+10/+12% max health, nova 300%; Plague Choir +30% Miasma (+10% at 4pc), +10% health, +2 Withered stacks, burst at 6 stacks. Set-tier ordering holds (2pc 0.95-1.16 < 4pc 1.19-1.41 < 5pc 1.59-1.66).

Boss check (`balance:boss`, 8 seeds, abbess/congregation/prelate/saint/regent/mire, kit auto, dodge yes, intended and geared, `BALANCE_LEGENDARY=1` vs `0`): no deaths added, every kill time >= 60% of the non-legendary time (min 0.60, mean 0.90). By discipline (mean / worst): Ossuary 0.99 / 0.95, Gravecaller 0.68 / 0.60, Mourner 0.97 / 0.95, Rotweaver 0.94 / 0.83. Gravecaller is the fast one (thrall damage compounds on a boss); it was 0.55 worst with thrall damage +30% and was trimmed to stay at the floor.

## Scythe boss reach (3 Oct 2026, owner decision)
The scythe's arc reaches **4 m against a boss** (3 m against everything else), so a reaper can fight from the edge of boss rings and cones. The boss bot's Fen stand-off now follows that reach (it hard-coded 3.5 m). `BALANCE_SEEDS=8 BALANCE_BOSS=prelate,mire,saint,congregation BALANCE_KIT=auto BALANCE_WEAPONS=scythe BALANCE_DODGE=yes npm run balance:boss`, 32 rows (4 necromancers x 2 bands):

| Boss reach | wipes (of 256 runs) | sum of boss damage taken (% max HP) | sum of kill times (s) |
|---|---|---|---|
| 3 m (before) | 12 | 3,858 | 3,589 |
| **4 m (shipped)** | **5** | **2,942** | **3,425** |
| 4.5 m | 7 | 2,849 | 3,375 |

Biggest moves: Prelate Mourner (intended) 7/8 -> 3/8 wipes; Mire Mother 5 wipes -> 0; Plague Saint damage taken roughly halved. The scythe is still about 1.4x slower than a staff on every boss: that is the style's trade (souls and essence from the arc), not changed here.

## New Blood catch-up (3 Oct 2026, owner: "apply the 1.5x damage and early xp for new blood")
`src/gameplay/newBloodTuning.ts`: every New Blood primary, rite and signature hits **x1.5** (`NewBloodSystem.power`), and experience is
multiplied **x2 at level 1, fading linearly to x1 at level 15** (`WorldScene.gainXp`; the harness mirrors both). x2.5 was measured first and
overshot: with the damage boost New Blood out-levelled the necromancers at Graves (412-562 XP/min vs ~375), so the start was lowered to x2.
Necromancer rows are byte-identical. `BALANCE_SEEDS=4 BALANCE_AREAS=graves,nave BALANCE_BANDS=intended BALANCE_KIT=none npm run balance`:

| Class (intended) | Graves kills/min | Graves XP/min | Graves deaths/3 min | Nave kills/min | Nave XP/min | Nave deaths/3 min |
|---|---|---|---|---|---|---|
| Necromancers (mean, unchanged) | 91 | 376 | 0.0 | 110 | 1,983 | 0.2 |
| Grave Warden | 37.7 -> 56.6 | 138 -> 434 | 3.8 -> 2.3 | 28.2 -> 46.5 | 384 -> 975 | 5.8 -> 4.0 |
| Bell Monk | 36.8 -> 56.7 | 130 -> 425 | 4.8 -> 3.3 | 31.8 -> 56.1 | 478 -> 1,161 | 6.3 -> 4.8 |
| Carrion Witch | 29.3 -> 57.8 | 112 -> 410 | 3.3 -> 0.3 | 25.0 -> 37.0 | 319 -> 843 | 5.0 -> 3.0 |
| Hollow Knight | 37.3 -> 51.2 | 124 -> 343 | 5.0 -> 3.0 | 28.4 -> 37.0 | 352 -> 711 | 5.3 -> 4.8 |
| Veilwalker | 26.5 -> 45.3 | 100 -> 312 | 2.0 -> 1.5 | 23.9 -> 35.6 | 260 -> 776 | 4.3 -> 1.8 |

Graves (early levels): New Blood now level about as fast as a necromancer. Nave (past the catch-up): the gap closes from about 6x to about 2x
XP/min; the rest is the legion (thralls) and survival, still worth a human playtest of the melee three (Warden, Monk, Knight die most).

