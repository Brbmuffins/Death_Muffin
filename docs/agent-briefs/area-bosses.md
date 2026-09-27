# Brief: a boss for every area — Gravedigger King, Bone Abbess, Drowned Congregation

Written 2026-09-27 (evening) on the workstation for the **cloud code agent**. The owner picked this from a design
brainstorm ("area bosses" + "build depth"; the second is [`build-depth-aspects-runes.md`](build-depth-aspects-runes.md)).
Ground rules as in [`spell-variety-first-session.md`](spell-variety-first-session.md) §1: merge `origin/master` first,
host authority, help for every new mechanic, green gate incl. `npm run test:vfx`, stage-don't-commit is for the
workstation only (cloud commits + pushes its branch).

**Order:** finish the in-flight spell-variety brief, then the mobs brief (the Gravedigger King summons Barrow Ghouls),
then this. If the ghoul isn't built yet, §3.1 falls back to Grave Robbers.

## 1. Why

The loop has no mid-game milestone: the only boss is the Bell-Sworn Prelate at the far end, so a player farms the
Graves, Ossuary and Nave for hours with nothing to aim at. `FUTURE_CONTENT.md` → "More bosses" already names one per
area, and **all of their art is paid for and unused**: animated models and portraits since the roadmap batch, and
(new today) their summoning objects and arena props. Bosses also become the home of the relic-rune drops from the
build-depth brief, which gives each fight a reason to repeat.

## 2. Engine: from one Prelate to four bosses

Today everything assumes one boss: `BossBrain` (`sim/BossBrain.ts`) with a fixed `BOSS_ARENA` in the Sanctum, a single
`BossState` in snapshots, `hit.boss: true` with no id, `this.prelate` in `WorldScene`, and `summonBoss` with no
argument.

1. **`content/bosses.ts`**: `BossId = 'prelate' | 'gravedigger' | 'abbess' | 'congregation'` and a `BOSSES` table:

   | Field | Notes |
   |---|---|
   | `name`, `title` | HUD boss bar, banner |
   | `area`, `arena {x, z, r}` | see §2.5 |
   | `summonId` | the interactable that summons it |
   | `shards` | Gravedigger 2, Abbess 3, Congregation 4, Prelate 5 (unchanged) |
   | `baseHp` | Gravedigger 9 000, Abbess 14 000, Congregation 19 000, Prelate 26 000 (unchanged) |
   | `modelSlug`, `portrait` | `boss_gravedigger_king`, `boss_bone_abbess`, `boss_drowned_congregation`, `prelate`; `art/portraits/boss_*.webp` |
   | `colors` | enemy language only (see each boss) |
   | `phases` | names for phase 2 / 3 (HUD `data-bphase`) |

   Level = the area's `level` + ascension levels; HP scaling stays `BossBrain.awaken`'s formula (`enemyHpScale`, party
   × (1 + 0.8·(n−1)), difficulty).
2. **Brains.** Keep the Prelate's behaviour byte-for-byte: move it into `PrelateBrain extends BossBrain`, pull shared
   parts (awaken, damage/fracture/withered, pending telegraphed attacks, phase thresholds at 60% / 30%, defeat) into the
   base class, and add `GravediggerBrain`, `AbbessBrain`, `CongregationBrain`. The existing boss tests must pass
   unchanged; `npm run balance:boss` must reproduce today's Prelate numbers.
3. **One awake boss per world** (v1). `BossState` gains `id: BossId`; snapshots carry it (older snapshots → `'prelate'`).
   `hit.boss: true` still means "the awake boss". If another boss is awake, the summon object answers with a
   player-readable toast: *"The Bone Abbess already stirs in the Marrow Ossuary."*
4. **Intents & realtime.** `summonBoss` gains `boss: BossId`; `server/realtime/server.js` validates it against the four
   ids (missing → `'prelate'` for old clients), re-embed with `node tools/embed-realtime.mjs`, extend the realtime tests.
   New boss events ride the existing `boss` event (`kind` gets the new attack names below) — check the relay has no
   kind whitelist.
5. **Arenas.** Suggested centres (verify against `layout.ts` props, crypts, water and `nav`, and move them to the nearest
   clear circle): Graves `(-14, -22)` r 10, Ossuary `(48, -24)` r 10, Nave `(0, -60)` r 11 (the nave is 30m wide).
   Waves in that area pause while its boss is awake (same as the Prelate's arena), and resume on defeat or wipe.
6. **Views.** Generalise `this.prelate` into a `BossView` keyed by `modelSlug`, lazy-loaded when the boss is summoned
   (non-blocking; fall back to the Prelate model tinted if the GLB fails). The HUD boss bar reads name/phase names from
   `BOSSES`; the portrait shows beside the bar.

## 3. The three bosses

All attacks follow the Prelate's rule: **a physical cause + a telegraph + a counterplay**. Windups are generous in the
Graves and tighten with depth. Numbers are starting points for `npm run balance:boss -- --boss <id>` (add the flag):
target solo kill times at each area's intended band ≈ 90–120 s (Graves), 120–150 s (Ossuary), 150–180 s (Nave).

### 3.1 The Gravedigger King — Hollow Graves (clips: idle, walk, attack, dig, hurt, death)

Colours: grave-dirt brown `SPELL_FX.enemy.dirt` (added by the mobs brief) + lantern amber `0xe0a458`.
Summon: **The King's Grave** (`models/props/kings_grave.glb`, new) at the arena's north edge, 2 shards.

| Phase | Attack | Tell → counterplay |
|---|---|---|
| all | **Spade Sweep** (`attack`) | 100° cone, r 4.5, windup 900 ms → step behind or aside |
| all | **Burial** (`dig`) | a grave outline (sprite `grave-outline`, 1.2 × 2.4 m) under up to 2 players, 1400 ms → leave it. Caught = **Buried**: rooted 2 s (casting allowed) + 0.6× damage. Host emits `{t:'boss', kind:'bury', targets, ms}`; each client roots itself (players are client-simulated). |
| P2 ≥ 60% | **Exhumation** | every 14 s he digs 2 **Barrow Ghouls** (burrowed) up at the arena edge (robbers if the ghoul isn't built); one elite Grave Robber at 45% |
| P3 ≥ 30% | **Open Graves** | 4 pits open at fixed arena points (hazard zones r 1.2 — walking in = Buried); Burial marks every player; Spade Sweep swings twice |

### 3.2 The Bone Abbess — Marrow Ossuary (clips: idle, walk, attack, cast, hurt, death)

Colours: reliquary gold `SPELL_FX.boss.shard` + curse crimson `SPELL_FX.enemy.curse` (never the player's bone ivory —
Ossuary Wall and Bone Mantle own that).
Summon: **The Abbess's Reliquary** (`models/props/abbess_reliquary.glb`, new), 3 shards.

- **Skull niches (the core mechanic).** Four `skull_niche.glb` shrines (new) stand around the arena. While the Abbess
  is awake they are **targetable enemies**: add an `EnemyDef` `niche` (speed 0, radius 0.9, corpse `none`, no XP/gold,
  HP 7% of the Abbess's max, immune to Chill/slow, thralls may attack it). While any niche stands she **regenerates
  0.6% max HP/s**, and every 8 s one niche fires a **Bone Lance** at a random player (line telegraph 1.2 s, then the
  existing `spikeLine` in curse crimson). Each niche destroyed deals 4% of her max HP to her and adds 1 Fracture.
- **Ossuary Chorus** (`cast`): 8 bone-spike spokes radiate 9 m from her; telegraph 1.2 s → stand between spokes.
- **Reliquary Grasp** (`attack`): melee cone r 3.5, 700 ms.
- **P2:** the Chorus casts twice, the second rotated 22.5° (move between the gaps twice).
- **P3:** **Rebuild** — two destroyed niches re-form once. **Bone Communion** (4 s channel): every corpse in the arena
  crawls to her and heals her 1% each. Counterplay is the corpse economy: Exhume, explode or Litany the corpses first.
  Tip text should say so.

### 3.3 The Drowned Congregation — Drowned Nave (clips: idle, walk, attack, cast, hurt, death)

Colours: black nave water + drowned choir blue (the Choir Wraith's pale blue, **not** the player's Chill blue on the
ground; keep telegraphs on the water surface teal-grey `0x5f8f8a`).
Summon: **The Drowned Font** (`models/props/drowned_font.glb`, new), 4 shards.

- **Rising water.** Each phase raises the nave water (cosmetic height in `graphics/Water.ts`; when the spell-variety
  brief's `world_water_dirty` port exists, use it). Sim: outside the dais and the pew footprints, P2 = −15% move,
  P3 = −30% move and **Soaked** (+20% damage from the Flood Hymn).
- **Pews as cover.** Place 6–8 `church_pew.glb` (new) in two ragged rows inside the arena (`layout.ts` `PROPS`, box
  colliders ≈ hw 1.4, hd 0.35). They're also good permanent Nave decoration outside the arena.
- **Flood Hymn** (`cast`, the signature attack): a tide sweeps outward from her across a 120° arc; telegraph 2.2 s with
  `tide-crest` sprites marching out. Players whose segment to her is blocked by a pew collider take nothing; everyone
  else takes 1.8× and Chill 2 s. (Segment-vs-box on the host.)
- **Drowning Grasp** (`cast`): 3–5 rings under players (sprite `drowned-hand` rising), 1300 ms → step out; caught = rooted
  1 s + damage.
- **The Congregation Rises** (phase changes): 4 Choir Wraiths + 2 Penitents climb out of the water (the Prelate's
  procession code).

### 3.4 The Bell-Sworn Prelate

Unchanged, now `BOSSES.prelate` + `PrelateBrain`. Ascension still requires a Prelate kill.

## 4. Rewards & progression

- Defeat pays `rollBoss(...)` as today, with the tier scaled by the boss's area. **First kill per character**: +2 shards
  and a guaranteed rare-or-better item from ids the server knows (`items.ts`).
- **Runes:** each boss owns a rune pool (build-depth brief §3.4); first kill guarantees one rune from its pool, repeats
  roll 35%. Until the rune server work lands, skip this line cleanly (feature flag on rune ids existing in `items.ts`).
- Record first kills in the Codex journal (browser storage, like discoveries): a **Trophies** row in Codex → The Dead
  with the four portraits (sealed until killed). No new server fields — `bossKills` keeps counting all bosses; the
  Prelate-only `prelateKills` stays Prelate-only.

## 5. Art (done on the workstation, staged on master)

| File | Use |
|---|---|
| `public/models/boss_{gravedigger_king,bone_abbess,drowned_congregation}/character.glb` + `art/portraits/boss_*.webp` | the bosses (older batch) |
| `public/models/props/kings_grave.glb` | Gravedigger summon (h ≈ 1.6, box hw 1.5 hd 1.1) |
| `public/models/props/abbess_reliquary.glb` | Abbess summon (h ≈ 1.6, box hw 0.9 hd 0.7) |
| `public/models/props/skull_niche.glb` | Abbess niches (h ≈ 3.4, circle r 0.7) |
| `public/models/props/drowned_font.glb` | Congregation summon (h ≈ 1.7, circle r 0.9) |
| `public/models/props/church_pew.glb` | Nave cover + decoration (h ≈ 1.3, box hw 1.4 hd 0.35) |
| `public/art/fx/{grave-outline,tide-crest,drowned-hand}.png` | tintable telegraph sprites (add to `fxImages.ts`) |
| Binbun (`public/fx/binbun/`): `surge_eruption`, `crypt_mist`, `bell_toll_ring`, `prelate_impact`, `toxic_puddle`, `curse_bolt`, `thrall_rise` | layer on attacks once the runtime exists (recolour per boss) |

Records: `art-manifest/gemini-jobs/bosses-v1.json`, `art-manifest/tripo-specs/prop_{kings_grave,abbess_reliquary,skull_niche,drowned_font,church_pew}.json`,
`art-manifest/tripo/*`. Heights/colliders above are first guesses — measure the GLBs and adjust.

## 6. Help, tests, docs

- Counsel tip per boss the first time its summon object is within 12 m (`boss_gravedigger`, `boss_abbess`,
  `boss_congregation`), stating the shard cost and the one counterplay that matters (graves / niches+corpses / pews).
  Codex entries + Trophies; README "Bosses" section; the `interactables` beacon from the spell-variety brief §6 glows
  bronze on each summon object when shards suffice.
- Tests: Prelate regression (existing), each brain's telegraph → damage timing, Buried root only when inside, niche
  regen stops when all niches die, Communion consumes corpses, pew cover blocks the Hymn, one-awake-boss rule, snapshot
  round-trip with `id`, realtime `summonBoss.boss` validation, balance harness per boss.
- Update `FUTURE_CONTENT.md` (bosses ✅), `BALANCE.md` (per-boss numbers), `PHASE_REPORTS.md`, `HANDOFF.md`,
  `docs/ART-BACKLOG.md`, and this brief's row in `docs/agent-briefs/README.md`. `necro-rules.cjs`: no new persisted
  fields, so no VPS rules change.
