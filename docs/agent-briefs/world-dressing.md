# Brief: world dressing — give every room its own look (10 new props)

Written 2026-09-27 (evening) on the workstation for the **cloud code agent**. Small and self-contained: layout data,
plus `WorldView` registration. It can go at any point in the queue. Ground rules as in
[`spell-variety-first-session.md`](spell-variety-first-session.md) §1.

**Why:** all five combat rooms are dressed from the same 16 props (tombstones, pillars, braziers, candles, statues…),
so the Graves, Ossuary, Nave and Sanctum read as one room in different lighting. Two or three signature props per room
fixes that cheaply.

| Room | Props (`public/models/props/*.glb`) | Placement idea |
|---|---|---|
| Hollow Graves | `coffin_stack`, `gibbet_cage`, `grave_lantern` | Coffin stacks beside the mausoleums; 2–3 gibbets along the paths; lantern posts at forks and by the doors, as wayfinding |
| Marrow Ossuary | `bone_candelabrum`, `skull_wall` | Low skull walls line the corridors and make half-cover lanes; candelabra flank the arena (the Abbess's niches, see `area-bosses.md`) |
| Drowned Nave | `drowned_statue`, `stained_glass`, `sunken_bell` (+ `church_pew` from the bosses brief) | Statues along the aisle in the water, broken windows against the side walls, one sunken bell as a landmark mid-nave |
| Bell Sanctum | `bell_frame`, `organ_pipes` | Organ pipes behind the Sundered Bell's dais; bell frames at the corners |

- **Register** each in `layout.ts` `PROPS` (height + collider). Measure the GLBs; first guesses:

  | Prop | Height | Collider |
  |---|---|---|
  | coffin_stack | 1.6 | box hw 1.0 hd 0.6 |
  | gibbet_cage | 3.4 | circle r 0.4, on the post |
  | grave_lantern | 2.4 | circle r 0.25 |
  | bone_candelabrum | 2.2 | circle r 0.4 |
  | skull_wall | 1.1 | box hw 1.6 hd 0.35 |
  | drowned_statue | 2.6 | circle r 0.6 |
  | stained_glass | 3.6 | box hw 1.1 hd 0.3 |
  | sunken_bell | 1.8 | circle r 1.3 |
  | bell_frame | 3.0 | box hw 1.4 hd 0.5 |
  | organ_pipes | 4.2 | box hw 1.8 hd 0.6 |

- **Keep nav and waves working.** Colliders must not block doors, breaches, crypt surge spots, gathering nodes or the
  boss arenas. Re-run the walker/nav tests; every node and door stays reachable.
- **Lights:** `grave_lantern` and `bone_candelabrum` get a warm `lightPool` decal (no PointLights); the Binbun
  `brazier_fire` / `chapterhouse_candle` flames can sit on them once the VFX runtime is wired (high quality only).
- **Performance:** props batch per area already (`WorldView`); keep each new prop under ~12 instances per room.
  Compare draw calls and triangles before and after with `__cwDebug.perf()` at 40 enemies, and note the numbers in
  PHASE_REPORTS.
- **Records:** `art-manifest/gemini-jobs/world-props-v2.json`, `art-manifest/tripo-specs/prop_*.json`, `art-manifest/tripo/*`.
- Update `docs/ART-BACKLOG.md` (→ live), `HANDOFF.md`, `PHASE_REPORTS.md` and this brief's row in `docs/agent-briefs/README.md`.
