# Zone and encounter polish audit (2 Oct 2026, branch `dm/zone-polish`)

ROADMAP P3, round 2. Scope: visuals and readability of the twelve zones and seven area bosses. No timings, damage, HP or spawn numbers were touched.

How it was measured: `node tools/qa/zone-tour.cjs` (offline dev build, Gravecaller, god mode, `unlockAll`, `goto`, a full five-thrall legion, the zone's own roster in rings, twelve-ish corpses, then each boss summoned from the arena rim with one screenshot every 1.4 s). Both High and Low. Perf comes from `__cwDebug.perf()`.
Perf caveat, read this first: the VPS was at load average 20-25 from other jobs and the browser renders with SwiftShader (software), so **frame time is not reported** (it read 70+ ms everywhere and says nothing about a GPU). Draw calls and triangles are real but swing with which enemies/lights are in frame; the CPU `update ms` swings ±2x run to run. Treat differences under about 10% as noise.

Screenshots of the full before/after tours are not committed (about 200 PNGs); the pairs that matter are in `docs/screenshots/zone-polish/`.

## Findings and fixes

| # | Finding | Zones | Fix |
|---|---|---|---|
| 1 | **Boss cones and lines were the least readable thing on the ground.** A single 50% fill with only an arc rim, tinted with the dim enemy colours (`dirt` brown 0x6a4a30, tide teal 0x5f8f8a, curse crimson). The Gravedigger's sweep was a barely visible brown wedge; the Flood Hymn was a faint teal haze lost under the Nave's violet debris; lances and spoke volleys were scaled discs. | Graves, Ossuary, Nave, Sanctum, Cloister, Pyre | `fxTextures`: new `coneEdge` (stroked sector with glow) and `bar` (filled rectangle with bright edges) sprites. `WorldScene.areaBossEvent`: cones and lines are drawn brightened to a minimum channel of 214 (tint kept), fill plus outline. The Penitent's small cone telegraph also gets the outline. Slam/ring/disc telegraphs were already strong and are unchanged. |
| 2 | **Normal corpses are invisible.** A toppled body is dark on dark ground (worst in the Pyre and Warren); only resonant corpses had a ring. Corpses are the necromancer's resource. | all hunting grounds | `EntityViews`: every fresh non-resonant corpse gets a faint pale ring (26 s, fades with the corpse). Capped at 8 alive at once so a wipe cannot add dozens of draw calls. Not visible when a body sinks in Fen water (see "not done"). |
| 3 | **Wisp pulse ring in the Fen was camouflaged** on the hummock rims (same teal, same additive glow). | Fen | Pulse ring is now near-white teal (0xc4fff2) at full opacity. |
| 4 | **Prop clipping, found by a footprint scan of `generateLayout()`** (collider vs collider, vs walls, vs interactables). Real overlaps: a bone pile inside a sarcophagus (Ossuary 52, -35.5); a pillar standing inside the Bell Altar (Sanctum 0, -127.8); the Cloister waystone sharing a spot with an arcade pillar (27.5, -108 vs pillar -108.5). | Ossuary, Sanctum, Cloister | Scatter props near the four Ossuary coffins are lifted out; the Sanctum pillar behind the altar is skipped; the Cloister waystone and its interactable moved to z -111 (between two pillars). The seeded `rand()` stream is unchanged, so nothing else shifts. |
| 5 | Warren pillars and Coliseum statues report as "on a wall" (distance 0). Looked at in the shots: they are corner posts / statues on plinth walls, intended. | Warren, Coliseum | none |
| 6 | Boss-arena sigils are the brightest floor element in the Sanctum (purple, additive, bloom) and compete with telegraphs. | Sanctum, Cloister | sigil opacity 0.5 -> 0.3 (Sanctum) and 0.35 -> 0.26 (Cloister). The bloom still makes the Sanctum sigil bright; the effect is mild. |
| 7 | Ossuary north-west is a black hole in arrival view. | Ossuary | hemisphere sky 0x3a2d55 -> 0x46386a (about +20%); mood kept. |
| 8 | Nave is the heaviest zone: 296 draw calls, 876K triangles, 13 ms CPU update in the busy fight (High). Its boss fight is also the noisiest (violet debris sheet, flood glare). | Nave | **not fixed** (perf work, not polish); listed below. |

## Per-zone audit (before the fixes)

"Legion" = five thralls with cyan ground rings. Enemies carry gold (elite) or affix rings; telegraph rings sit on top of both.

| Zone | Readability | Clutter | Lighting / contrast | Props | Doors / seals | Notes |
|---|---|---|---|---|---|---|
| Chapterhouse | clear; the Prior's lit pool and altar sigil are the focus | pillars hide the hero (dither fade works) | purple/amber, good | nothing floating | East door to the Wing signed in the zone subtitle | fine |
| Sexton's Acre | the node rings are the cue and read well | tree canopy is dense overhead | **darkest zone on arrival**: dead trees against black, only the node rings glow | ok | n/a | candidate for a moonlight lift; left as is, since darkness is the identity |
| Alchemist's Wing | warmest, most legible room | busy: many small stations | warm brown, good | stations clean | n/a | busy but every cluster has a ring |
| Hollow Graves | good; scattered candle pools give depth | fence and tombstone forest is dense but dark | dark blue/black, amber candle pools | fine | the two seals show kills needed in the area line | boss King's sweep was the weakest telegraph (fixed) |
| Catacomb Warren | gold pentagram floor is the loudest thing; enemies on it read well | pillar rows | warm gold on black | pillars on partition walls intended | seal gates readable | fine |
| Marrow Ossuary | skull walls read well | niche walls plus columns hide enemies at the screen edge | NW black (fixed a little) | bone pile in a coffin (fixed) | fine | |
| Bone Coliseum | brightest zone; dark enemies pop against sand | few props, most open | light floor, strongest contrast of all | statues on plinths | big gate with sigil, impossible to miss | easy to read |
| Drowned Nave | enemies blur into violet debris; thralls vs ghosts hard to tell; hymn cone lost | **noisiest zone** (debris, flood sheet, pews, pillars) | blue/violet, low contrast | pews/pillars fine | N gate with sigil clear | Congregation fight worst of all bosses before the fix; heaviest zone for perf |
| Bell Sanctum | huge sigil dominates; candle groups readable | pillar ring | purple on black | pillar inside altar (fixed) | fine | |
| Plague Cloister | green sigil and puddles are the same family as telegraphs; the Saint's cone vanished | cart/garden props moderate | dark green, ok | waystone beside a pillar (fixed) | fine | |
| Cinder Pyre | orange sigil, glowing coal circles stand out; Conflagration is strongest telegraph in game | scorched ground texture is busy but low contrast | red/black, ok | fine | fine | |
| Mourning Fen | hummock rims are the brightest floor feature; hex ring (magenta) clear, pulse ring (teal) was not | open | teal on black, good | fine | fine | |

Bosses (before): Regent, Mire Mother, Prelate and Saint disc/ring telegraphs read well. Gravedigger sweep, Congregation hymn, Abbess grasp cone and Saint cone were weak (all cone/line based).

## Perf (before the fixes, tour numbers)

Real draw calls / triangles; update ms is CPU under heavy shared load.

| Zone | Quality | Arrival calls / tris (K) / update ms | Fight calls / tris (K) / update ms (enemies, 5 thralls) |
|---|---|---|---|
| chapterhouse | high | 188 / 650 / 2.7 | safe zone |
| chapterhouse | low | 145 / 379 / 3.2 | safe zone |
| acre | high | 140 / 557 / 0.9 | safe zone |
| acre | low | 109 / 322 / 2.0 | safe zone |
| alchemist_wing | high | 180 / 605 / 1.4 | safe zone |
| alchemist_wing | low | 149 / 404 / 0.7 | safe zone |
| graves | high | 186 / 637 / 1.8 | 209 / 665 / 6.9 (31) |
| graves | low | 169 / 332 / 2.1 | 168 / 362 / 4.1 (27) |
| warren | high | 200 / 685 / 2.7 | 190 / 742 / 5.1 (25) |
| warren | low | 145 / 366 / 2.4 | 133 / 395 / 7.1 (30) |
| ossuary | high | 248 / 609 / 4.0 | 249 / 651 / 5.0 (39) |
| ossuary | low | 209 / 310 / 3.3 | 189 / 333 / 8.4 (39) |
| coliseum | high | 130 / 237 / 3.7 | 167 / 344 / 4.8 (53) |
| coliseum | low | 118 / 104 / 4.9 | 132 / 185 / 5.2 (54) |
| nave | high | 257 / 739 / 8.2 | 296 / 876 / 13.1 (47) |
| nave | low | 185 / 343 / 2.0 | 230 / 484 / 4.2 (46) |
| sanctum | high | 222 / 514 / 3.8 | 252 / 677 / 5.2 (46) |
| sanctum | low | 112 / 157 / 2.2 | 158 / 313 / 10.5 (46) |
| cloister | high | 179 / 379 / 6.5 | 208 / 533 / 8.9 (39) |
| cloister | low | 108 / 135 / 2.7 | 159 / 237 / 4.2 (39) |
| pyre | high | 177 / 385 / 4.8 | 186 / 357 / 3.8 (28) |
| pyre | low | 155 / 141 / 1.7 | 164 / 191 / 2.8 (28) |
| fen | high | 194 / 531 / 3.9 | 206 / 572 / 4.2 (27) |
| fen | low | 133 / 249 / 3.5 | 154 / 257 / 2.5 (27) |

### Did the fixes cost anything?

Two controlled checks (fixed state: five thralls, the zone roster in rings frozen, 9-14 corpses, median of 3 `perf` reads, High), before vs after. The tour's own before/after pairs differ in random wave content and cannot answer this.

- **Triangles:** unchanged within ±1% wherever enemy counts matched (graves 552,391 -> 552,415; ossuary 440,148 -> 438,038).
- **Draw calls:** only the corpse rings add any: +12 calls (about +6%) in the Graves with 14 corpses at the first cap of 10; the cap is now 8, so at most +8 (about +4% at 200 calls), and 0 with no fresh corpses. Across the other eight zones the before/after call counts differ by up to -40%/+60% because enemy counts differed between runs; two back-to-back runs of the *same* code gave Sanctum 286 and 239. So only the Graves pair (same enemy and corpse counts) is a clean comparison.
- **Update ms:** inside run-to-run noise (Graves 2.07 -> 2.46 and 2.81, Pyre 1.69 -> 2.03 and 2.23).
- **Bosses** (tour, mid-fight read, High): 7 bosses, calls -12% .. +7% and triangles -2% .. +8% between runs (Regent 209 -> 184, Gravedigger 149 -> 160). The telegraph change adds one decal per cone for about 1-2 s.

| Boss | Quality | Before calls / tris (K) / ms | After calls / tris (K) / ms |
|---|---|---|---|
| gravedigger | high | 149 / 696 / 2.1 | 160 / 714 / 1.7 |
| abbess | high | 158 / 546 / 3.5 | 159 / 540 / 3.6 |
| congregation | high | 181 / 714 / 2.6 | 170 / 721 / 3.7 |
| prelate | high | 156 / 520 / 2.9 | 151 / 536 / 2.3 |
| saint | high | 137 / 421 / 1.8 | 119 / 441 / 1.6 |
| regent | high | 209 / 300 / 1.6 | 184 / 325 / 2.2 |
| mire | high | 99 / 502 / 1.8 | 108 / 515 / 1.9 |
| gravedigger | low | 92 / 344 / 2.4 | 96 / 342 / 2.2 |
| abbess | low | 91 / 231 / 2.8 | 111 / 247 / 3.6 |
| congregation | low | 118 / 370 / 2.5 | 134 / 371 / 3.4 |
| prelate | low | 106 / 194 / 5.8 | 108 / 186 / 3.7 |
| saint | low | 54 / 126 / 2.0 | 53 / 119 / 1.9 |
| regent | low | 133 / 105 / 2.6 | 119 / 95 / 2.8 |
| mire | low | 77 / 211 / 1.3 | 74 / 212 / 1.8 |

## Before / after

All on High, same tour. Left = before, right = after.

Boss cones: Gravedigger sweep (top row), Flood Hymn (bottom row).
![cones](screenshots/zone-polish/pair-cones.webp)

Abbess cone (top row) and Plague Saint cone (bottom row).
![cones 2](screenshots/zone-polish/pair-cones2.webp)

Corpse rings in the Pyre (top) and the Graves (bottom).
![corpses](screenshots/zone-polish/pair-corpses.webp)

Sanctum arrival (top; sigil dimmed, effect mild) and Ossuary arrival (bottom; slightly lifted; the right-hand shot also caught an enemy cone telegraph).
![lighting](screenshots/zone-polish/pair-lighting.webp)

## Not done / open

- **Nave perf and noise.** Heaviest zone (296 calls, 876K tris, 13 ms) and the hardest to read; the violet debris sheet and flood glare want a contrast pass and a perf look together. Needs a GPU measurement, not SwiftShader.
- **Thralls vs pale enemies.** In a five-thrall fight the pale lavender bloated enemies and the thralls share a palette; only the cyan ground ring separates them. A clearer thrall silhouette is an art/shader job (`Creature` tint), left alone.
- **Fen corpses** sink below the water surface at some spots and their rings are faint on the teal water.
- **Acre** is very dark on arrival from the orchard; only the node rings glow.
- Frame time on a real GPU was not measured (software renderer on a loaded VPS).
- The generated server bundle (`server/vps-handoff/necro-progress/necro-rules.cjs`) was regenerated because `areas.ts` changed (waystone coordinates and the Ossuary ambient colour). It needs a deploy only if the live server is meant to know the new Cloister waystone spot.
