# Brief: two new mobs — the Barrow Ghoul (Hollow Graves) and the Lich Acolyte (Nave, Sanctum)

Written 2026-09-27 (evening) on the workstation for the **cloud code agent**. The owner asked to "keep building out
game variety — maybe a new mob type in another room". Build this **after** (or alongside, if you can keep the diffs
apart) [`spell-variety-first-session.md`](spell-variety-first-session.md). Same ground rules as that brief (§1 there):
merge `origin/master` first, host authority, help for every new mechanic, green gate incl. `npm run test:vfx`.

Both follow the enemy variety pack's recipe (2026-09-27, `PHASE_REPORTS.md`): **a shipped behaviour plus one new
twist**, a first-sight counsel tip, a Codex entry, a model with a fallback, and a procession.

## 1. Why these two

- **The Hollow Graves** is where every new player spends their first ten minutes, and it only fields the four starter
  dead (robber, hound, penitent, sac); every newer mob went to the Ossuary, Nave and Sanctum. The Ghoul gives the first
  room a new silhouette and a gentle first lesson in "step out of the ring".
- **The Lich Acolyte** is the last unbuilt archetype from `FUTURE_CONTENT.md` → "New enemy archetypes", and its
  model has sat unused since the roadmap batch (`public/models/lich_acolyte/character.glb`: idle, walk, cast, hurt,
  death). It punishes the late rooms' thrall-heavy play without touching the corpse economy the Deacon already
  contests.

## 2. Barrow Ghoul (`ghoul`) — new model, Hollow Graves

**Art (done on the workstation):** `public/models/barrow_ghoul/character.glb` + `clips.json` (Tripo, clips idle, walk,
run, attack (slash), dig, hurt, death), concept `art-src/concepts/barrow_ghoul.png` (workstation only), records
`art-manifest/tripo/barrow_ghoul.json`, spec `art-manifest/tripo-specs/barrow_ghoul.json`, job
`art-manifest/gemini-jobs/enemies-v3.json`. Register it in `modelPaths.ts` `CREATURE_MODELS`
(`barrow_ghoul`, world height ≈ 1.9), `EntityViews.ENEMY_SLUG` (`ghoul: 'barrow_ghoul'`) and `ENEMY_FALLBACK`
(`ghoul: 'grave_robber'`).

**Definition** (`content/enemies.ts`; starting numbers, tune with `npm run balance`):

| Field | Value | Note |
|---|---|---|
| name | Barrow Ghoul | |
| behavior / rig | `melee` / `humanoid` | + new `burrow: true` field on `EnemyDef` |
| hp / speed | 60 / 2.4 (4.2 while burrowed) | |
| damage / range | 12 / 1.3 | eruption hits for 1.4× |
| windupMs / cooldownMs | 420 / 1400 | |
| xp / gold | 5 / [2, 6] | |
| corpse / scale | `normal` / 1.05 | a normal corpse keeps early Exhume fed |
| blurb | "Tunnels under the churchyard toward the living. When the ground splits in a ring, step out — then finish it before it digs back down." | |

**The twist — burrow and erupt** (host, `WorldSim`):
1. A ghoul **climbs out burrowed**: new `EnemyState` `'burrow'`, **appended** to `E_STATES` in `sim/snapshot.ts`
   (append-only so old snapshots still decode). Burrowed ghouls move at 4.2 toward their target (player or thrall),
   are **untargetable and immune** (the host ignores `hit` ids in `'burrow'`; clients skip them in picking, auto-combat,
   Spear/Frost/Cleave shapes, like `'rising'`), and thralls don't aggro them.
2. Within 2.5m of the target it stops and **telegraphs an eruption**: new telegraph kind `'erupt'`, radius 1.8,
   **1000ms** in the Graves (it's the first room — generous), 800ms elsewhere. Then it surfaces: 1.4× damage to
   every player and thrall inside the ring (`hurt.from: 'erupt'`), state → `'recover'`, and it fights as a normal melee.
3. **Once per life**, the first time it drops below 50% HP it digs back in: plays `dig` for 0.8s (still hittable —
   the window to finish it), then → `'burrow'`, travels up to 8m to a new target and re-erupts.
4. Elites keep the normal affix rules (a Vengeful ghoul bursts on death, etc.).

**Visuals** (enemy language: grave-dirt brown, not a player colour — add `SPELL_FX.enemy.dirt = 0x6a4a30`):
- Burrowed: no model; a code-built **dirt mound** (flattened low-poly hemisphere, the ground/dirt texture darkened)
  sliding along with small dirt-clod particles every ~0.15s and a faint crack decal trail (`fx.cracks`, 0.8s).
  Keep it cheap: one mound mesh per burrowed ghoul, pooled.
- Telegraph: the existing telegraph ring in dirt brown, cracks decal growing over the windup.
- Eruption: Binbun `surge_eruption` recoloured dirt/bone (`[dirt, 0xe0d6c2, 0x2a1a10]`, scale ~0.7) once the runtime
  exists; until then `Effects.emit` dirt clods + bone flecks + a short shake if the player is inside.
- Dig-in: `dig` clip, dust puff, then the model hides and the mound appears.
- Audio: reuse `slam` (low, short) for the eruption and a soft `dig`-like scrape (procedural) for burrowing; ear-test
  note in HANDOFF.

**Where it spawns:** `areas.ts` → Hollow Graves `{ id: 'ghoul', weight: 12 }` (take it from `robber`: 58 → 48), and
Marrow Ossuary `{ id: 'ghoul', weight: 6 }`. New Graves procession in `WAVE_THEMES`:
`{ id: 'burrows', name: 'The Barrow Opens', blurb: 'Ghouls tunnel in from every side', roster: [{ id: 'ghoul', weight: 70 }, { id: 'robber', weight: 30 }], sizeMult: 0.8 }`.
The procession's ghouls all erupt around the **same** player within ~1s of each other — cap simultaneous eruption
telegraphs on one target at 3 so it stays readable.

**Help:** first-sight tip `ghoul` in `FIRST_SIGHT_TIPS` (WorldScene) + `Onboarding.ts`: *"Barrow Ghouls tunnel toward
you. When the ground cracks in a ring, step out of it — then kill the ghoul before it digs back down."* Codex entry
under "The Dead". README bestiary line.

**Tests:** burrowed = immune + untargetable (host drops hits, auto skips it); eruption damages only inside the ring
and only once; dig-in happens once per life at < 50%; snapshot round-trips `'burrow'`; procession caps concurrent
telegraphs; balance harness still green (add the ghoul to the Graves bot run).

## 3. Lich Acolyte (`acolyte`) — existing model, Drowned Nave + Bell Sanctum

**Art (already in the repo):** `public/models/lich_acolyte/character.glb` (clips cast, death, hurt, idle, walk —
no attack clip, so it's a caster). Register like the ghoul (`lich_acolyte`, height ≈ 1.95; fallback `deacon`;
add to `CASTERS`).

**Definition:**

| Field | Value |
|---|---|
| name | Lich Acolyte |
| behavior / rig | `caster` / `robed`, `attack: 'curse'` (the shipped curse strike: telegraph `'curse'`, `hurt.from: 'curse'`) |
| hp / speed | 92 / 2.0 |
| damage / range | 14 / 8 |
| windupMs / cooldownMs | 900 / 3000 |
| xp / gold | 9 / [5, 10] |
| corpse / scale | `normal` / 1.05 |
| blurb | "A necromancer of the Bell. Any thrall of yours that dies near it rises again — on its side. Kill it before you spend your legion." |

**The twist — Unbinding** (host): when a player's thrall dies (`killThrall(…, 'killed')` — **not** sacrificed or
crumbled) within **7m** of a living acolyte, the acolyte reaches for it: emit `{ t: 'unbind', id: acolyteId, x, z }`,
then 1.0s later spawn a hostile `risen` at that spot at the area's level (reuse the Deacon's raise path). Limits: one
unbinding per acolyte every 4s, at most 4 unbound Risen alive per acolyte. Litany sacrifices and crumbling at the
thrall cap are safe, which quietly teaches "spend thralls deliberately near acolytes".

**Visuals** (enemy curse crimson `SPELL_FX.enemy.curse`, never the player's violet):
- Curse strike: existing curse telegraph; Binbun `curse_bolt` on the windup once the runtime exists.
- Unbinding: a curse-crimson beam acolyte → the dying thrall (`Effects.beam`, 1.0s), `fx.sigil` decal under the
  thrall, then the Risen climbs out with the Deacon's raise effect; Binbun `thrall_rise` recoloured curse crimson.
- A faint crimson ring (`fx.ring`, radius 7, opacity ≤ 0.15) under a living acolyte **only while the player has
  thralls within it**, so the danger zone is visible exactly when it matters.

**Where it spawns:** Drowned Nave `{ id: 'acolyte', weight: 8 }`, Bell Sanctum `{ id: 'acolyte', weight: 12 }`. Add it
to the Sanctum's `procession` theme (weight 15, taking 5 each from penitent/wraith/censer) and a Nave procession
`{ id: 'unbound', name: 'The Unbound', blurb: 'Acolytes lead the risen', roster: [{ id: 'acolyte', weight: 35 }, { id: 'robber', weight: 40 }, { id: 'hound', weight: 25 }], sizeMult: 0.85, lead: 'acolyte' }`.

**Help:** first-sight tip `acolyte`: *"A Lich Acolyte turns your fallen thralls against you. Kill it first, or keep
your legion out of its crimson ring."* Codex entry; README.

**Tests:** unbinding only on `'killed'` within range; cooldown + per-acolyte cap; sacrificed/crumbled thralls never
rise; a dead acolyte cancels a pending unbinding; realtime unaffected (it relays snapshots; confirm no enemy-id
whitelist needs the new ids).

## 4. Shared plumbing

- `EnemyId` union + `ENEMIES` + `FIRST_SIGHT_TIPS` + `TipId` + `codex.ts` "The Dead" + README bestiary.
- `balance/harness.ts`: include both; report the Graves' early danger stays inside `BALANCE.md`'s band for a
  level-1–3 character (the ghoul must not spike deaths for brand-new players).
- `necro-rules.cjs` embeds `areas.ts`; the rosters change, so run `npm run build:server-rules` and note in HANDOFF
  that the VPS copy needs re-installing.
- Update `FUTURE_CONTENT.md` (Lich Acolyte ✅), `PHASE_REPORTS.md`, `HANDOFF.md`, `docs/ART-BACKLOG.md` (Lich Acolyte
  + Barrow Ghoul → live), and this brief's row in `docs/agent-briefs/README.md`.
