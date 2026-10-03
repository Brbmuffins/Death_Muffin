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
| Bone Needle runes (Splinters, Marrow-Tap, Volley) do nothing under a scythe's reaping arc | Documented in the Codex rune text as intended; making them work is a design call (see owner decisions) |
| Legion kit and Damage upgrades only reach thralls raised after the change | By design (stated in `legionKit.ts`); the HUD does not say so. A player who buys a tier mid-fight sees nothing change until the next Exhume |
| Hostile ground pools (`z.r + player radius`) and the Plague Doctor flask etc. use different body rules (centre vs body) | Small (0.45 m), pools are damage-over-time not one-shot telegraphs |
| Easy auto does not dodge boss telegraph rings or hymn cones | Needs a movement design; Easy auto only steps away from windups within 4 m |
| Withered ticks and Miasma slow can still kill / affect a ghoul while it is burrowed | Intended per the code comments? unclear; leave until a playtest says it matters |
| Command: Rend multiplies by legion size (five thralls on one clump cleave it five times at 2.5x) | Reads as the design ("your whole legion"); the harness shows no outlier |
| Boss bots never use the staff / scythe / wand play-style, Litany barrier or Fen open-water mechanics | Unchanged from BALANCE.md "Unfinished" |

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

1. Should Bone Needle runes work under a scythe? Marrow-Tap and Splinters could ride the arc (once per swing); the Volley has no
   scythe equivalent.
2. Should buying Damage or a Legion tier refresh the thralls already standing (a one-time stat bump), or keep "applies to the next
   Exhume" and say so on the HUD?
3. Should Easy auto learn to leave boss rings and cones (it would make Easy auto survivable at the Regent and the Congregation)?
