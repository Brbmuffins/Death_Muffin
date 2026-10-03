# Combat and necromancer polish pass (branch `dm/polish-combat`, 3 Oct 2026)

Scope: the four necromancer disciplines end to end (rites and runes, weapon lines, thralls, corpses, enemy telegraphs, elites,
bosses, hit feedback, death, wave flow, Easy auto). Content is frozen; this pass fixes what lies, sticks or is silent.
Nothing is deployed. No migration. No server change.

How it was audited: the real `WorldSim` driven headlessly (thrall behaviour probes across nine grounds with the real prop and
wall colliders, telegraph timing probes for every telegraphed enemy, boss telegraph vs resolve geometry), a read of
`AbilitySystem`, `WorldSim`, `BossBrain`, `autoCombat`, the rune tuning and every rite's tooltip against its constants, the
balance harness before and after, and a browser pass (see the end). Each fix has a regression test in
`src/gameplay/__tests__/polish-combat.test.ts` that fails on the old code.

## Findings

Severity: **H** you lose to it or it misleads every fight, **M** you notice it, **L** polish.

| # | Issue | Sev | Evidence | Status / commit |
|---|---|---|---|---|
| 1 | Elite casters and hazards wound up 15% faster than their telegraph filled (hex, scream, dust, flask, ember, pulse, cone, slam, curse, deacon channel): the ring said 1.1 s, the blow landed at 0.94 s | H | probe: 10 of 10 elite variants failed "telegraph ms == time to release" | fixed `2fad3eb` |
| 2 | Thralls kept swinging at a Barrow Ghoul that had dug in (blows refused by the host), and could pick targets in the next hall | M | read + test | fixed `bb6efd1` |
| 3 | Thrall formation seats folded two thralls onto one spot once a neighbour fell (seat = slot number, slots have gaps) | M | test: two thralls 0.9 m apart for good | fixed `bb6efd1` |
| 4 | Thralls wedged between two props (a 0.2 m gap) pushed at them for 3 s to forever | H | probe: stalls of 6 s+ in the Graves and Warren; none after the fix | fixed `12aaa0f` (sidestep everywhere, then a rate-limited grid path after 0.5 s stalled) |
| 5 | Exhume and Corpse Explosion could take a corpse behind a wall: a thrall raised there was stranded, a blast hit the next hall | H | read + test | fixed `21356a2` (client pick and host check the hall) |
| 6 | Command: Rend leapt the whole legion through a wall into the next hall | M | read + test | fixed `84b26ae` |
| 7 | Rites drew damage numbers on an underground ghoul; the host refuses those blows | L | read | fixed `432b54b` |
| 8 | Damage numbers ignored Fracture, Sanctified and Shrouded: a Shrouded elite took half of the "100" you saw | M | test against `damageEnemy` | fixed (`damageNumbers` commit) |
| 9 | A hit fully absorbed by a Litany or Mantle barrier made no number at all | M | read | fixed `ba42ab0` ("Warded -N") |
| 10 | Thrall hit numbers on a boss showed the bare hit (rally and Fracture left out) | L | test | fixed `129c7d5` |
| 11 | Penitent cone drew 7.5 m but struck to 7.9 m | M | read | fixed `43efa87` (the picture draws it all) |
| 12 | Bell-Tolled ring struck a body-width past the drawn ring | M | test | fixed `cbbf93f` (centre in the ring, like every other ground ring) |
| 13 | Boss cones (sweep, maul, swing, cleave, grasp) struck 0.3 m past the red; boss rings (toll, slam, rain, rot rain, coals) 0.4 m; Mire surface 0.3 m; hands and grasp 0.2 m | H | read of `BossBrain.resolve` vs `areaBossEvent` | fixed `54f07a3`, `dfa72b8` (drawn bigger, sim untouched, so difficulty is unchanged) |
| 14 | Drowned Sexton hook line struck 0.6 m longer and 0.3 m wider than drawn | L | read | fixed `416234c` |
| 15 | HUD "Wave Speed +96%" at tier 8; waves really come 69% sooner | M | `waveModifiers` | fixed `e558cc7` (label = real wave rate; tiers 1-3 unchanged) |
| 16 | A thrall that was killed made no sound | L | read | fixed `60d6f94` (soft crack, mixer thins a rush) |
| 17 | Tooltips: Bone Fan gave "+3 per sliver" but caps at 6; Ossuary said "up to 60%" Bone Ward where the usual three thralls give 30% | L | read | fixed `b6956c0` |

## Left open (and why)

| Issue | Why left |
|---|---|
| ~~Bone Needle runes (Splinters, Marrow-Tap, Volley) do nothing under a scythe's reaping arc~~ | Closed 3 Oct 2026 (owner decision 1): Marrow-Tap and Splinters ride the arc once per swing; the Volley stays needle-only |
| ~~Legion kit and Damage upgrades only reach thralls raised after the change~~ | Closed 3 Oct 2026 (owner decision 2) for Damage and Reinforce tiers: standing thralls get a one-time bump at purchase. A kit *piece* swap still reaches only the next thralls raised, and the Legion panel says so |
| Hostile ground pools (`z.r + player radius`) and the Plague Doctor flask etc. use different body rules (centre vs body) | Small (0.45 m), pools are damage-over-time not one-shot telegraphs |
| ~~Easy auto does not dodge boss telegraph rings or hymn cones~~ | Closed 3 Oct 2026 (owner decision 3): see `src/gameplay/autoDodge.ts`. Still true: Easy auto never walks up to a boss by itself and ignores Hymn cover (pews) |
| Withered ticks and Miasma slow can still kill / affect a ghoul while it is burrowed | Intended per the code comments? unclear; leave until a playtest says it matters |
| Command: Rend multiplies by legion size (five thralls on one clump cleave it five times at 2.5x) | Reads as the design ("your whole legion"); the harness shows no outlier |
| ~~Boss bots never use the staff / scythe / wand play-style, Litany barrier or Fen open-water mechanics~~ | Done 2026-10-03 on `claude/boss-bot-coverage` (BALANCE.md "Boss bot coverage"). New finding for the owner: the scythe is 10-90% slower than the staff on every boss and a careful scythe Mourner wipes 7 of 8 at the Prelate with the progress kit. Still not modelled: the Mire Mother's phase-3 rite |

## Balance

Harness before and after the sim changes (3 seeds, 3 sim-minutes, Graves and Nave, intended and push, four necromancers, 16 rows):
kills per minute 112.3 -> 113.5, damage taken per minute 66.8% -> 65.3% of max health, deaths 0.53 -> 0.47. All inside seed noise
(a single row moves up to 10%); no number was tuned. See BALANCE.md.

## Performance

`DM_QA_AREAS=graves,nave node tools/qa/fixed-fight-perf.cjs` (software GL, loaded VPS: judge calls and tris; ms is noise, it swings both ways), a3081d6 -> this branch:

| Quality / area | calls | tris | updateMs |
|---|---|---|---|
| high graves | 167 -> 140 | 315,516 -> 275,699 | 2.19 -> 1.91 |
| high nave | 140 -> 140 | 263,946 -> 259,216 | 1.70 -> 2.87 |
| low graves | 75 -> 76 | 114,740 -> 118,645 | 6.27 -> 1.95 |
| low nave | 83 -> 79 | 93,062 -> 92,614 | 2.49 -> 2.78 |

Scene content differs run to run (skinned counts moved), so the small calls/tris differences are the scene, not the code. By construction
nothing here adds draw calls, materials or effect variants: telegraph changes are larger decal radii on existing decals, plus one
floating-text call for absorbed blows and one `audio.play` for a killed thrall. Sim cost: a thrall's seat rank is a plain loop (no array),
a damage number does one pass over the enemy map (only when a number is spawned, not per frame), and a stalled thrall may run one grid
search at most every 1.5 s.

## Owner decisions

Decided 3 Oct 2026 and **implemented** on branch `claude/combat-owner-decisions` (not deployed; no migration; the realtime relay needs its one-line whitelist change deployed before or with the client, an older relay just drops the new intent):

1. **Bone Needle runes ride the scythe arc: done.** Marrow-Tap and Splinters trigger once per reaping swing, not once per enemy hit. Marrow-Tap: the swing hits 30% softer (the rune's existing cost) and returns its +4 essence once, only if the swing landed. Splinters: one shard per swing, from the nearest enemy struck to the nearest enemy the arc missed, for 30% of the swing's damage (never at a foe the same swing hit; no shard off a boss-only swing, like the needle). The Volley stays needle-only. Codex rune text, the rune lines in the Grimoire, and the README no longer say the runes skip the scythe. `AbilitySystem.reap`, mirrored by the balance harness.
2. **Damage and Reinforce purchases refresh standing thralls: done.** New `refreshThralls` intent (`new / old` multipliers for health, damage and attack speed, host-clamped to 1..1.25; health scales with its fraction kept, so it is never a heal). The scene sends it only when the buyer has living thralls, pulses each one, and the toast says how many were strengthened. HUD Damage tooltip, both toasts, the Legion panel and its Reinforce tooltip, the Covenant tip, Codex and README were reworded. Kit piece swaps are *not* refreshed (not asked): the Legion panel says so.
3. **Easy auto dodges boss telegraphs: done.** `autoDodge.ts` turns each boss `telegraph` event (the same events the renderer draws; the host's `resolve` geometry with its pads) into a ring, cone, spoke, grave or burning-floor shape, adds hostile ground pools from the sim's zones, and `selectAutoCombatMovement` steps to the nearest safe point (rings of candidates, most room first, nav line clear, inside the hall), commits to it while it stays safe (no wobble between two equal exits), never walks back into a shape (holds position and keeps attacking), and drops each shape when its blow lands. Conflagration: runs to the nearest ash circle. Easy-auto gating (dev accounts, server side) is untouched.

Still open:

4. ~~(3 Oct, boss bot) Scythe against bosses~~ **Decided 3 Oct 2026 (owner: "give the scythe more reach at bosses"): done.** `NECRO_WEAPON_TUNING.scythe.bossReach` = 4 m (normal arc 3 m) for the range check and the boss hit (`abilityRange(..., boss)`, `reapTargets(..., reach)`); past the normal arc the crescent is drawn at the boss's body. Boss bot, 8 seeds, Prelate/Saint/Congregation/Mire x 4 necromancers x intended+geared, dodging: wipes 12 -> 5, damage taken -24%, kill time -5% (4.5 m measured: no further gain). Still true: a scythe Mourner at the Prelate (intended, progress kit) wipes 3/8 (was 7/8); the scythe stays the slower, riskier boss style by design.