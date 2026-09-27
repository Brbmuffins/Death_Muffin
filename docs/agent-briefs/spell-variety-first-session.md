# Brief: spell variety, dev access, Binbun VFX runtime, first-session readability

Written 2026-09-27 on the workstation for the **cloud code agent**. It is self-contained: read it, `CLAUDE.md` and
`HANDOFF.md`, then build. The workstation (the only machine with `.ai-keys.local` and the raw Godot packs in
`art-src/`) has already produced every file this brief needs. **Don't make stand-in art.** If something is missing,
add a checklist line to §9 and move on.

## 0. What the owner asked for (2026-09-27)

1. "Let's add those spell variety we were discussing. I just see the same 4 spells and idk where to swap them out."
2. "brbmuffins, the dev account should have full access to everything."
3. "Don't forget there is Godot VFX in there somewhere": the BinbunVFX library (`docs/BINBUN-VFX-PORT.md`).
4. "If there are any world effects or additional ones that could be used, please do."
5. "Consider ways we can make the altar, for example, easier to know to interact with — those types of items in game —
   easy for the first-time player to learn the ropes."

**Why the owner sees only 4 spells.** The Grimoire already exists (key **L**, plus an unlabelled open-book icon among
seven icons under the minimap). Every alternative rite is level-gated (Wailing Skull 3, Grave Step 5, Grave Frost 7,
Bone Mantle 12), and the only pointer to the Grimoire is a toast and one counsel tip. Fix discoverability first (§2);
more rites alone won't help if nobody finds the swap screen.

## 1. Ground rules

- Git: the cloud agent commits and pushes (it has no GitHub Desktop). Start from the latest `claude/adoring-knuth-hd1uox`
  (it has `82a80e0` Acre gathering fixes and `1d5674e` movable Covenant counsel on top of master) and **merge
  `origin/master` first**: the workstation's art and VFX (§8) reach GitHub through the owner's GitHub Desktop push to
  master. If `public/fx/binbun/rally_area.json` isn't there after the merge, the push hasn't happened yet. Ask the
  owner, and don't regenerate anything.
- Never edit the original shared Crossworlds REST server. The **Death Muffin** backend (`server/death-muffin/`) is in
  scope where noted; its changes only go live when the owner deploys.
- Keep host authority: **Intent → WorldSim → SimEvent → VFX/audio**. Client-resolved hits (like Marrow Spear, Grave
  Frost) stay client-resolved; anything that consumes corpses or touches thralls goes through the host.
- Follow `CLAUDE.md`'s help rule. Every new mechanic ships with a Covenant counsel tip (`src/ui/Onboarding.ts`), a Codex
  entry (`src/content/codex.ts`: `CODEX_RITES` + `riteSwatch`), a spell card (`src/ui/spellTooltip.ts`), a Settings key
  list line (`src/ui/MiscPanels.ts`) and README text.
- Colours carry meaning (`SPELL_FX` in `src/content/abilities.ts`): bone ivory/amber, marrow ember/crimson, spirit
  jade/teal, rot chartreuse/olive, Mourner cold blue, violet reserved for rituals, bronze for enemy bells.
- Green gate: `npm run typecheck && npm test && npm run test:server && npm run test:vfx && npm run build`.
- Ship in the order of §2 → §7. Each section is a reviewable commit. §2 and §3 alone answer the owner's first two asks.

## 2. Dev access for `brbmuffins` (do this first; it's small)

**Goal:** the owner's account sees and can use everything, *without* changing their saved level, progress or
leaderboard entry. This is a runtime overlay, never a save mutation.

1. `src/gameplay/devAccess.ts`:
   - `hasDevAccess(character: Character, token = getToken())` returns true when either:
     - `character.gm_enabled === true`. The Death Muffin `/character` response already carries `gm_enabled`,
       `gm_level` and `gm_permissions` (`formatCharacter` in `server/death-muffin/backend/server.js`). Add them as
       optional fields to `Character` in `src/net/types.ts`.
     - **or** the JWT payload's `username` (decode the middle base64url segment of `getToken()`, no verification) is
       in `DEV_ACCOUNTS = ['brbmuffins']`, compared case-insensitively. The DEV offline mock issues `offline:<name>`
       tokens, so accept that form too, which lets `?offline` QA log in as `brbmuffins`.
   - A Settings toggle, **"Dev access (preview as a normal player when off)"**, stored per character in localStorage
     and default on. It only shows for dev accounts.
2. Route every unlock gate through one helper: `riteLevel()` returns `Infinity` when dev access is on, else
   `character.level`. Gates to cover:
   - `AbilitySystem.unlocked`, and `AbilitySystem.signature`'s own `p.stats.level < SIGNATURE_LEVEL` check.
   - `sanitizeLoadout`/`loadLoadout` (WorldScene passes the level) and `WorldScene.assignRite`/`grimoireUnlocked`.
   - `GrimoirePanel` state, HUD slot lock state and the `spellTooltip` lock line.
   - `Onboarding.keyFor`, and the `autoCombat` readiness filter.
3. **Areas:** `Progression.isUnlocked(area)` answers true for dev accounts through an overlay flag. Never push to
   `local.unlocked`, never save, and don't grant kills, shards or XP. Doors, waystones and recall then work everywhere.
4. **Professions:** open the client-side tier gates in `ProfessionsPanel` and `Gathering` the same way. The server still
   checks skill level in `server/death-muffin/backend/gathering/gathering-routes.cjs`. Make the matching server change
   (`req.gmFields.gm_enabled` skips the level check, not the rate or time budget) with a test. Note in
   `server/death-muffin/GATHERING_DEPLOY.md` that it needs a deploy, and that `brbmuffins` needs `accounts.role = 'admin'`
   (or `gm_enabled = 1`) in the `death_muffin` DB for the server side. The client username fallback covers everything else.
5. A small **DEV** chip beside the level badge (`hud-level`) whenever the overlay is active, so screenshots never pass for
   a normal player's view.
6. Tests: devAccess token parsing (JWT, offline form, other names, malformed); a dev loadout sanitises with every rite;
   a non-dev account stays level-gated.

## 3. Make the Grimoire impossible to miss, and add the primary (left-click) choice

1. **Hotbar button.** Add a labelled "Grimoire · L" button at the right end of `.hud-slots-wrap` (HUD.ts), in the
   `.cw-plate` style. When a learned rite has never been placed or viewed, show a glowing "NEW" pip. Keep a
   per-character "seen" set in localStorage beside `dm_loadout_v1_<id>`. The minimap-menu icon stays.
2. **Slots open it.** Right-clicking a HUD slot 1–4 (`contextmenu` on the button; `preventDefault`) opens the Grimoire
   with that key preselected. The spell card footer becomes "Right-click or L to swap · Codex (K)".
3. **Grimoire UX.**
   - Click a socket in the top bar to select a key, then click a rite card to place it. Keep the per-rite 1–4 buttons.
   - Add role chips (All · Damage · Corpse · Control · Survival · Legion); tag each rite with a role in `abilities.ts`.
   - Show a "NEW" tag on unseen rites. Locked rites show "Level N" and stay visible, so players see what's coming.
4. **Primary choice.** Add an **LMB socket** to the Grimoire, with choices Bone Needle / Bone Fan / Rot Lance (§4).
   - Loadout storage becomes v2 `{ primary, keys: [4] }` under `dm_loadout_v2_<id>`, migrating a v1 array.
     `sanitizeLoadout` validates the primary as well.
   - Replace every hard-coded `'bone_needle'` primary: `WorldScene` (~l.888, 890, 1916, 1920), `autoCombat.ts`
     (l.54–55, 146) and the balance `harness.ts` (keep Needle as the harness default, with an option to pick).
   - Show the equipped primary as a small LMB socket at the left of the hotbar. Cast on click, as today.
5. **Clickable toasts.** The level-up "joins your Grimoire" toast opens the Grimoire on click.
6. **Faster first new toy.** The new unlock levels in §4 put a choice at level 2, so the first swap happens in the first
   minutes. The existing `grimoire` tip should fire then, pointing at the new hotbar button (pulse it for 6s).
7. Tests: v1 → v2 migration, primary sanitising, swap keeps cooldowns (they belong to the rite), dev loadout.

## 4. Seven new rites (reconciles `docs/SPELL-VARIETY-PLAN.md` with the shipped Grimoire)

**Skipped from the plan, and why:** Soul Chain (Wailing Skull already chains), Frost Wake (Grave Frost ships), Bone
Mantle (ships). Mark those in `SPELL-VARIETY-PLAN.md` as reconciled.

**Unlock ladder** (the existing four keep their levels). Put this in the README, the Settings key list and the Codex:

| Lvl | Rite | Role |
|---|---|---|
| 2 | Bone Fan (primary), Grave Offering | pack basic · corpse → essence/heal |
| 3 | Wailing Skull | (existing) |
| 4 | Ivory Cleave, Veil Step | close Fracture arc · dash |
| 5 | Grave Step | (existing) |
| 6 | Rot Lance (primary), Rally the Dead | poison basic · legion buff |
| 7 | Grave Frost | (existing) |
| 8 | Carrion Seed | corpse trap |
| 12 | Bone Mantle | (existing) |

All numbers below are starting points for `npm run balance` and playtests. Every icon already exists in
`public/art/abilities/` (Gemini, `art-manifest/gemini-jobs/future-2d.json`). Sprites in `public/art/fx/` are
white-on-alpha, meant to be tinted in code through `fxImages.ts`; add their keys there. Binbun ids are in
`public/fx/binbun/` (§5). Each rite also needs a `CAST_FLOW` entry (`src/content/combatFlow.ts`; the `Record` type will
force it).

### Primaries (the left-click slot, 0 essence)

**Bone Fan** `bone_fan`, lvl 2. Icon `necro-bone-fan.png`, colours `SPELL_FX.needle`.
- Targeting `enemy`, range 8, cooldown 520ms, power 0.55 per sliver.
- Three slivers fan out (−12°, 0°, +12°) toward the target. Each homes to a **distinct** living enemy within a 30° cone
  and 8m, preferring the clicked target. Slivers with no enemy fly straight and fizzle at 8m.
- The boss counts as one target, so at most one sliver hits it: this is a pack-clear sidegrade, weaker on single
  targets.
- +3 essence per landed sliver, capped at `NEEDLE_ESSENCE` (6) per cast.
- Visuals: three `kind:'needle'` projectiles, plus Binbun `bone_fan_hit` at each impact (scale ~0.5).
- Audio: `needleCast` / `needleHit`. Gesture: CAST_FLOW like Needle (60ms / 0.22s).
- Auto: aim at the densest target within range; never walk closer.

**Rot Lance** `rot_lance`, lvl 6. Icon `necro-rot-lance.png`. Add `SPELL_FX.lance = { rot: 0xc7e04a, deep: 0x6f8f22,
spore: 0x2b3317 }`.
- Targeting `enemy`, range 14, cooldown 700ms, power 0.8.
- Pierces the first two enemies in a 0.5m-wide lane to 14m. Each hit adds **1 Withered stack**.
- +4 essence on the first hit.
- Add `withered?: number` (0..1) and `witheredCap?: number` (1..12, default `DETONATE.rotWitheredCap`) to the `hit`
  intent. The host applies the stacks with `WITHERED.dpsPerStack × dmg`-scaled dps and credits `witheredOwner`,
  mirroring how zones apply Withered in `WorldSim`. Rotweaver passes `mods.witheredMaxStacks` as the cap (a free synergy).
- The realtime server sanitises both fields (§4.9).
- Visuals: an `orb`/`needle` projectile carrying Binbun `rot_lance_projectile` (follow the projectile), plus a small
  `toxic_stink` puff at impact (0.6s).

### Keys 1–4

**Grave Offering** `grave_offering`, lvl 2, role Corpse. Icon `necro-grave-offering.png`, colours `SPELL_FX.exhume`.
- Targeting `corpse` (`pickCorpse`), range 13, cost 0, cooldown 2000ms.
- Consumes one corpse for **+16 essence** (+8 resonant, ×2 elite) and **heals 4% max HP**. Mourner's `corpseHeal` adds
  its usual share. No corpse means `no_corpse`, with nothing spent.
- Host: extend `RiteKind` with `'offering'` and send `{t:'signature', sig:'offering', x, z}` at the corpse. The host takes
  the corpse nearest (x, z) within 0.9m in the caster's area, emits `corpseGone {reason:'consumed', by}` and a new event
  `{t:'offering', by, ok, x, z, corpseKind, elite}`. The caster applies essence and heal on the event, as Bone Mantle
  does its barrier.
- Visuals: a jade wisp (sprite `wisp`) flies **corpse → caster**, the reverse of Exhume's beam, so the two read
  differently. Binbun `grave_offering_ripple` at the corpse and `grave_offering_orb` at the caster.
- Auto: only when essence < 30% **and** the legion is at cap (otherwise Exhume wants the corpse). Keep resonant corpses
  back for Litany.

**Ivory Cleave** `ivory_cleave`, lvl 4, role Damage. Icon `necro-ivory-cleave.png`, colours `SPELL_FX.spear`.
- Targeting `direction`, a 3.6m reach in a 120° arc (half-angle 60°). Cost 14, cooldown 1600ms, power 1.7.
- Applies Fracture 1 and resolves instantly (client-resolved like Grave Frost, no projectile).
- Visuals: ground decal `crescent` (the arc bows away from the caster; place it at caster + dir × 1.5, r ≈ 2.2,
  rotated to the aim), plus bone flecks. Binbun `ivory_cleave_hit` on up to 8 struck enemies.
- Audio: `spear` (short) + `boneHit`. It gives Ossuary-style close play to everyone.

**Veil Step** `veil_step`, lvl 4, role Survival. Icon `necro-veil-step.png`. Add `SPELL_FX.veil = { jade: 0x6fe3c8,
pale: 0xdde8ff, deep: 0x1f8f86 }` (spirit, shape-distinct from Grave Step's crimson).
- Targeting `ground`, range 5.5, cost 0, cooldown 7000ms. Dash toward the cursor.
- Walk the segment in 0.25m steps using the same walkability the Player/nav uses, and stop at the last valid point.
  Never pass sealed doors or leave the area.
- Move over ~0.16s (lerp, not a pop). No invulnerability in this version.
- Visuals: sprite `veil-streak` along the path, Binbun `veil_step_trail` at departure (~0.6s) and a jade ring at arrival.
  Don't clone the skinned hero for afterimages.
- **Manual only**; auto never casts it. The difference from Grave Step: no corpse needed, shorter, no damage.

**Rally the Dead** `rally_dead`, lvl 6, role Legion. Icon `necro-rally-the-dead.png`, colours `SPELL_FX.rend`.
- Targeting `self`, but the cursor names the focus. Cost 20, cooldown 12000ms. Needs at least one thrall
  (`no_thralls`, nothing spent).
- Host (`sig:'rally'`, x/z = cursor): each of the caster's thralls gets `rallyT = 6s` (+2s Gravecaller), meaning +40%
  damage and +30% attack speed. Each is healed 20% of max HP and retargeted to the enemy nearest the cursor.
- Event `{t:'rally', by, x, z, ids:[thrallIds]}`. Add a thrall snapshot flag bit so guests see the aura.
- Visuals: Binbun `rally_area` at the caster, plus `rally_thrall_rim` following each rallied thrall for the duration
  (follow its view position). The sprite `rally-sigil` floats over each rallied thrall. Jade tethers caster → thralls
  on cast.
- Auto: cast when there are 3 or more thralls and an enemy within 8m.

**Carrion Seed** `carrion_seed`, lvl 8, role Control/Corpse. Icon `necro-carrion-seed.png`, colours `SPELL_FX.bloom`.
- Targeting `corpse`, range 13, cost 18, cooldown 6000ms. One live seed per caster: a new one withers the old,
  harmlessly.
- Host (`sig:'seed'`): marks the corpse `{seedOwner, seedDmg = sp × 1.6, armedAt = now + 0.6s,
  seedExpires = min(corpse.expiresAt, now + 20s)}`.
- When a living enemy comes within 2.2m of an armed seed, it **bursts**: a 3m radius takes `seedDmg`, plus 2 Withered
  stacks (cap `witheredMaxStacks` for Rotweaver, else 6). The corpse is consumed (`corpseGone reason:'burst'`) and the
  host emits `{t:'seedBurst', by, x, z, r, targets}`.
- Events `seeded {by, corpseId, x, z, armMs}` and `seedGone {corpseId}`. Put a corpse snapshot flag in so late joiners
  see seeds.
- If another rite consumes a seeded corpse, the seed is simply lost (document it in the Codex tip).
- Visuals: sprite `seed-bud` sits on the corpse, pulsing chartreuse. Binbun `carrion_seed_armed` loops while armed.
  On burst: `carrion_seed_burst` + `toxic_puddle` (1.5s) + existing rot particles.
- Audio: `miasma` on plant, `burst` on pop.
- Auto: plant on the corpse nearest the approaching pack's path when no seed is live.

### 4.9 Plumbing checklist for all seven

- `abilities.ts`: `AbilityId`, `ABILITIES` (with `unlockLevel`), `GRIMOIRE` (keys), a new `PRIMARIES` list, the tuning
  constants block, and `SPELL_FX` additions.
- `AbilitySystem.cast` switch + implementations, following the neighbouring rite each one mirrors (stated above).
- `sim/types.ts`: the intent fields, `RiteKind`/`signature` sig union, the new events and the thrall/corpse flags.
  `WorldSim` handles them, and `snapshot.ts` carries the flag bits.
- `server/realtime/server.js`:
  - `SIGNATURES` += `'offering', 'rally', 'seed'`.
  - Sanitise `hit.withered` (int 0..1) and `hit.witheredCap` (int 1..12).
  - Then run `node tools/embed-realtime.mjs` and extend `server/realtime/server.test.js`.
  - Deploy note: an older realtime drops the new sigs for co-op **guests** (host/solo play works).
- `WorldScene` event routing to the AbilitySystem handlers (`onOffering`, `onRally`, `onSeed…`, beside `onMantle`).
- `autoCombat.ts` rules above; `spellTooltip.ts`, `codex.ts`, `Onboarding.ts` (per-rite counsel shown the first time
  each is placed on a key; WorldScene l.~78 holds that map), README, the MiscPanels key list.
- Tests: target limits (Fan distinct targets, one boss hit), resources spent exactly once, a failed cast spends nothing,
  Offering/Seed corpse consumption exactly once (host), Rally with no thralls, seed arming/burst/expiry, Veil Step
  never crossing a sealed door, and realtime sanitising.

## 5. BinbunVFX runtime (the Godot library), and wiring it

Read `docs/BINBUN-VFX-PORT.md` end to end. Conversion is done, so start at its §4 step 3. The workstation expanded the
selection from 22 to **67 converted entries** (`art-manifest/binbun-effects.json` → `public/fx/binbun/*.json`, 6.6 MB).
`npm run test:vfx` checks them.

**Runtime** (`src/graphics/binbun/BinbunFX.ts`, owned by `Effects` as `effects.binbun`):
- Fetch + cache, non-blocking and fail-open: a missing or broken effect is a silent no-op, and casts never await VFX.
- One InstancedMesh per particle node, simulated on the CPU. Plain Mesh for `MeshInstance3D`.
- A tiny track player for the §3 track list.
- Lights go through `effects.lightFlash`; never PointLights.
- Translate the gdshaders in `public/fx/binbun/shaders/` to GLSL ES 3.00 per BINBUN-VFX-PORT §3. Start with the shared
  `transparent` / `particle` / `glow_fresnel`.
- Recolour from `SPELL_FX` through `primary/secondary/tertiary_color`.
- API: `spawn(id, {x, y, z, scale, rot, colors, follow?, duration?, once?}) → Handle`, capped (~24 live) and pooled.
- **Impacts with no oneshot track:** several entries are "main" with duration 0 or ~1s but are one-off impacts
  (`needle_hit`, `crit_hit`, `rend_impact`, `wall_raise`, `vengeful_burst`, `surge_eruption`, `archer_flash`,
  `bone_fan_hit`, `ivory_cleave_hit`). Play them with `once: true`: emit the one-shot particles and end after the longest
  particle lifetime.
- **Loopers** (need `follow`/`duration` and cull beyond ~40m or off-screen): `interact_rim`, `altar_beacon`,
  `waystone_portal`, `recall_portal`, `brazier_fire`, `bonfire`, `kiln_fire`, `crypt_mist`, `nave_fog`, `toxic_puddle`,
  `toxic_stink`, `soul_orb`, `censer_incense`, `rally_thrall_rim`, `carrion_seed_armed`, `curse_bolt`,
  `rot_lance_projectile`, `sanctify_beam`, `chapterhouse_candle`, `area_gate`, `loot_*`.
- DEV: `__cwDebug.vfx(id, colors?)` and `__cwDebug.vfxGallery()` (a grid of every id). Screenshot each for the owner.

**Wiring, by priority** (additive; keep today's effects as the fallback until each passes gallery + readability +
dense-wave perf QA):

1. **New rites (§4):** `bone_fan_hit`, `rot_lance_projectile`, `ivory_cleave_hit`, `grave_offering_orb`/`_ripple`,
   `rally_area`, `rally_thrall_rim`, `carrion_seed_armed`/`_burst`, `veil_step_trail`.
2. **Interactable beacons (§6):** `interact_rim`, `altar_beacon`, `waystone_portal`, `recall_portal`, `levelup_pillar`.
3. **Existing spells:**

   | Spell | Effect |
   |---|---|
   | Miasma | `miasma_cloud` |
   | Plague Bloom | `plague_bloom_area` |
   | Corpse Explosion | `corpse_explosion` |
   | Grave Frost | `grave_frost_mist` + `frost_shard_hit` on shatter |
   | Dirge | `dirge_area` |
   | Litany | `litany_pulse` |
   | Soul Harvest | `soul_harvest_pillar` |
   | Exhume | `exhume_lift`/`exhume_beam`, then `thrall_rise` as the thrall stands |
   | Grave Step | `grave_step_smoke` |
   | Wailing Skull | `wailing_skull_projectile` |
   | Needle | `needle_hit` (+ `crit_hit` on crits) |
   | Rend | `rend_impact` |
   | Ossuary Wall | `wall_raise` |

4. **Enemies:**

   | Moment | Effect |
   |---|---|
   | Censer aura | `censer_incense` |
   | Vengeful affix | `vengeful_burst` |
   | Grave Surge | `surge_eruption` + `crypt_mist` |
   | Bell-Tolled ring / Prelate toll | `bell_toll_ring` |
   | Choir Wraith scream | `choir_scream` |
   | Caster curse | `curse_bolt` |
   | Prelate rain | `boss_rain_orb` |
   | Prelate slam | `prelate_impact` |
   | Deacon Sanctify | `sanctify_beam` |
   | Breaches | `enemy_breach_rim` |
   | Archer thrall | `archer_flash` |

5. **World ambience** (high quality only, shared material, capped count):

   | Where | Effect |
   |---|---|
   | Chapterhouse / Bell Sanctum braziers | `brazier_fire` |
   | Candles | `chapterhouse_candle` |
   | Cooking Fire | `bonfire` |
   | Bone Kiln | `kiln_fire` |
   | Mausoleums | `crypt_mist` |
   | Drowned Nave | `nave_fog` |
   | Toxic / rot zones | `toxic_puddle` |
   | Toxic corpse before rupture | `toxic_stink` |
   | Shard / relic pickups | `soul_orb` |
   | Loot rarities | `loot_*` |
   | Area exits | `area_gate` |

6. **World shader kits** (entries named `world_*`). These are material roots with no nodes: each JSON carries the
   shader, uniforms and baked or copied textures. Port them individually, as layers behind a quality check:

   | Kit | Use |
   |---|---|
   | `world_water_dirty` | Drowned Nave, into `graphics/Water.ts` |
   | `world_water_basic` | Acre pond |
   | `world_grass` + `world_grass_ground` | instanced grass for the Hollow Graves / Acre (low quality: off) |
   | `world_transition_ridge` / `_blades` | full-screen area-change / recall / death transition |
   | `world_sky_dark` | optional, login `NecroBackdrop` only (the game camera is top-down) |

## 6. Interactables a first-time player can't miss

Today the only affordances are the pointer cursor and a "Click <label>" prompt **while hovering**, and only waystones
appear on the minimap. Interactables live in `AREAS[*].interactables` (`content/areas.ts`, kinds `upgrades` = Altar of
Ascension, `inventory`, `forge`, `professions`, `waystone`, `boss`, `kiln`, `sawpit`, `fire`). Picking and
`INTERACT_RANGE` are in `WorldScene` (~l.694–811, 983, 1954).

1. **Idle beacon under every interactable:** Binbun `interact_rim` (looping), tinted by function:

   | Interactable | Tint |
   |---|---|
   | Altar | bronze `0xd9a441` |
   | Waystone | jade `0x6fe3c8` |
   | Stations (kiln, sawpit, fire, workbench) | ember `0xff6a2a` |
   | Reliquary | bone `0xe8dcc0` |
   | Rite Niches | candle amber `0xe9c98f` |
   | Sundered Bell | toll bronze |

   The fallback until the runtime lands is a slow `Effects.decal` ring pulse.
2. **Nameplates.** A world-space label (HTML overlay projected like `FloatingText`) shows the name + verb, e.g. "Altar
   of Ascension · empower, quicken, ascend". It's shown for the nearest interactable within 10m and fades with distance.
3. **Press E.** **E** uses the nearest interactable within `INTERACT_RANGE + 1`, or walks to it like a click if it's
   within 10m. E is unbound today; check it doesn't collide with WASD handling. The prompt becomes "Click or E ·
   <label>". Add it to Settings, README and the Codex.
4. **Hover highlight.** Brighten or outline the interactable's mesh while hovered (WorldView owns the meshes).
5. **"Something to do" pulses:**
   - The Altar runs `altar_beacon` when an upgrade is affordable or Ascension is available.
   - Waystones swirl (`waystone_portal`) once attuned.
   - Stations glow when the bag holds something they can process.
   - The Sundered Bell glows when shards suffice to summon.
6. **Minimap icons for every interactable**, colour-coded like the beacons (today it's only waystones:
   `Minimap.ts` `waystones`). Add a legend line to the Codex.

## 7. "First Rites": learn the ropes in the first ten minutes

A small, dismissible objective tracker for new characters.
- Where: under the area name at the minimap, in the `cw-plate` style. The cloud branch just made Covenant counsel
  movable (`1d5674e`), so keep them out of each other's way.
- Scope: per-character, persisted like the Codex journal. Shown while level ≤ 5 and not finished. The Settings "Show
  tips" toggle hides it; "Show tips again" resets it.
- Each step completes from existing events. The current step gets a **guide marker**: reuse the amber minimap
  destination marker plus a pulsing `interact_rim` / ground chevron at the target.
- Steps (spawn is at the Acre entrance, -26, 20):
  1. Click the ground to move.
  2. Gather from a glowing node (Acre).
  3. Walk east into the Chapterhouse.
  4. Visit the **Altar of Ascension** (interact once; the counsel explains Damage / Wave Speed).
  5. Head north into the Hollow Graves and fell 5 enemies (left-click / Auto).
  6. Raise a thrall: **2** near a corpse (Exhume).
  7. Cast Miasma (**3**) on a pack.
  8. Reach level 2 and **open the Grimoire** to place a new rite (the §3 button pulses).
  9. Buy one Damage upgrade.
- Finishing it: a toast plus a Codex entry. No new rewards; the server owns progress.
- Re-check the existing just-in-time tips (`welcome`, `move`, `gather`, `acre`, `grimoire`, `station`, …) so the
  tracker and tips don't repeat each other. Tips explain; the tracker directs.

## 8. What the workstation already produced (this commit, staged for the owner's push)

| What | Where |
|---|---|
| Icons for all seven rites (plus Soul Chain / Frost Wake, unused) | `public/art/abilities/necro-{bone-fan,rot-lance,grave-offering,ivory-cleave,veil-step,rally-the-dead,carrion-seed}.png` (earlier batch, `future-2d.json`) |
| Tintable VFX sprites (white on alpha) | `public/art/fx/{crescent,seed-bud,wisp,rally-sigil,veil-streak}.png`; job `art-manifest/gemini-jobs/spells-v5.json`; records in `art-manifest/images.json` |
| 45 new Binbun conversions | new rites (11), interactable beacons (4), world ambience (10), enemies/bosses (9), existing-spell layers (4), world shader kits (7) |
| Selection + schema | `art-manifest/binbun-effects.json` (67 entries; the schema now allows `.tres` material roots) |

Nothing was spent on Tripo; no 3D art is needed for this brief.

## 9. Open art requests (leave lines here; the workstation fills them)

- [ ] Status/buff icons for **Rallied** and **Seeded** if the target frame should show them (`public/art/status/`).
- [ ] A "First Rites" tracker glyph and minimap interactable icons, if CSS/SVG isn't enough.

## 10. Docs to update when done

`README.md` (Grimoire button, primary choice, the new rites, E to interact, First Rites), `HANDOFF.md`,
`PHASE_REPORTS.md`, `docs/ART-BACKLOG.md` (mark wired), `docs/SPELL-VARIETY-PLAN.md` (reconciled), the
`docs/BINBUN-VFX-PORT.md` status line, `BALANCE.md` (new rites in the harness, numbers), and this brief's row in
`docs/agent-briefs/README.md`.
