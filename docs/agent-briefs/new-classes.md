# Brief: finish the five new class heroes (Release 0.3 "New Blood")

Written 2026-09-27 (evening) on the workstation for the **cloud code agent**. The owner: "look at finishing the class
heroes if those are already paid." They are — models, portraits, and now weapons, icons and sprites. What's left is
code: a class framework, then one class at a time. Ground rules as in
[`spell-variety-first-session.md`](spell-variety-first-session.md) §1. Queue position: after build-depth (or in
parallel on its own branch if the owner prefers — the framework touches `AbilitySystem`, `Player`, `HUD`, `WorldScene`).

## 0b. Status (2026-09-28)

**Framework: done.** `ClassFamily` + `Discipline.family`, per-family resource rules
(`gameplay/resources.ts`), per-family kits (`content/kits.ts`), the HUD orb following the family, the
server accepting `discipline_index` 5–9, and realtime validation for the new `sig` kinds. The four
necromantic disciplines are pinned unchanged by `__tests__/resources.test.ts` and
`__tests__/kits.test.ts`.

**Hollow Knight: done** (`__tests__/knight.test.ts`, 19 tests). Rage, all seven rites, the sword and
shield attached to the rig, Codex + counsel + spell cards + README.

Deviations from §2/§3 below, all deliberate:
- **No per-family `gameplay/kits/<family>.ts` dispatch module.** `AbilitySystem.cast` is already a
  flat switch over `AbilityId` and the Knight's seven cases sit in it. Splitting the file is worth
  doing when the *second* family lands and the necromancer file would otherwise balloon — with one
  family it would have been indirection with nothing on the other side.
- **`Player.essence` kept as a getter/setter alias** for `resource.value` rather than renamed across
  ~20 call sites. Behaviour is identical and the necromancer diff stays near zero.
- **Shield Bash does not stagger a boss.** `BossBrain` has no interrupt hook; §3 asks for 0.2s.
  Faking one was worse than leaving it out — it needs a real stagger API first.
- **Leaderboard index 5 is ambiguous**: legacy `class_index` 5 (Necromancer) and the Grave Warden's
  `discipline_index`. Nothing reaches 5 yet, so it still reads 'Necromancer'. **Resolve before the
  Grave Warden ships.**
- Numbers §3 left open (bash/slam power, most cooldowns) are first passes, not design decisions.

Next: Grave Warden, Bell Monk, Carrion Witch, then Veilwalker last (§3).

## 1. What exists (all paid for, all in the repo)

| Class | Model (8 clips: idle walk run attack cast dig hurt death) | Portrait | Weapons (`models/props/`) | Icons (`art/abilities/`) |
|---|---|---|---|---|
| Hollow Knight | `hero_hollow_knight` | ✅ | `gear_knight_sword` (R hand), `gear_knight_shield` (L forearm) | `knight-*.png` ×7 |
| Grave Warden | `hero_grave_warden` | ✅ | `gear_warden_flail` (R), `gear_warden_lantern` (L) | `warden-*.png` ×7 |
| Bell Monk | `hero_bell_monk` | ✅ | `gear_monk_bell_staff` (R) | `monk-*.png` ×7 |
| Carrion Witch | `hero_carrion_witch` | ✅ | `gear_witch_hook` (R) | `witch-*.png` ×7 |
| Veilwalker | `hero_veilwalker` | ✅ | none — fights barehanded; spirit light in the palms (code glow) | `veil-*.png` ×7 |

Tintable sprites (`art/fx/`): `crow`, `hook-chain`, `sound-ring`, `lantern-cone` (cone mask), `veil-rift`, plus the
Binbun library (fire effects for the Warden, `bell_toll_ring`/`choir_scream` for the Monk, `toxic_*` / `curse_bolt`
for the Witch, `grave_step_smoke`/`veil_step_trail` for the Veilwalker, `rend_impact`/`wall_raise` for the Knight).
Records: `art-manifest/gemini-jobs/classes-v1.json`, `art-manifest/tripo-specs/prop_gear_*.json`. The heroes' hands are
empty by design (T-pose concepts); weapons attach with `Creature.attach(bone, obj)`, which auto-calibrates orientation
like the necromancer staffs — measure grip offsets per weapon.

## 2. Framework (build first, with no class-visible change)

1. **Server (Death Muffin backend, owner-authorised):** `discipline.cjs` accepts 1–4 today → accept **5–9**
   (5 Grave Warden, 6 Bell Monk, 7 Carrion Witch, 8 Hollow Knight, 9 Veilwalker). Update `CLASS_NAMES`, the leaderboard
   and tests. The nullable `discipline_index` column already exists — no migration. Deploy note in
   `server/death-muffin/`.
2. **Client identity:** extend `content/disciplines.ts` (presentation) and `gameplay/classes.ts`; a `family:
   'necromancer' | 'warden' | 'monk' | 'witch' | 'knight' | 'veil'`. The four necromancer disciplines keep everything
   they have (Grimoire, essence, thralls). Character select + the Settings class panel show nine cards (portraits exist).
3. **Kits:** `content/kits/<family>.ts` — each kit lists `primary`, `rites` (its own Grimoire list for keys 1–4),
   `rmb` (corpse action), `signature` (level 10). `AbilityId` gains the new ids; `AbilitySystem.cast` dispatches to
   per-family modules (`gameplay/kits/<family>.ts`) so the necromancer file doesn't balloon. Grimoire/loadout, dev
   access, spell cards and Codex read the active kit instead of the necromancer constants.
4. **Resource:** generalise `Player.essence` into `resource { kind, value, max }` + per-family rules (below). The HUD's
   right orb recolours and relabels per kind; keep the necromancer path byte-identical (tests).
5. **Host shape:** reuse `hit` (with its existing fields) for client-resolved damage; host-shaped moves ride
   `signature` with new `sig` kinds, validated in `server/realtime/server.js` (then `node tools/embed-realtime.mjs`).
6. **Auto combat:** per-family rule modules (same decision rules as today: stationary, no chase, conserve resource).

## 3. The five kits (starting numbers; tune with the harness)

Colour families (add to `SPELL_FX`): Knight = cold steel `0xb8c0cc` + oath crimson `0x8a1f2c`; Warden = lantern gold
`0xf2b84b` + fire `0xff7a2a`; Monk = pale gold `0xe8d9a0` + sound white `0xf6f1e3`; Witch = crow black `0x1a1418` +
blood `0x9a1b2a` + hex green `0xa6b04a`; Veilwalker = spectral cyan `0xbff3ff` + mist `0xdfe9ee`. Never enemy bronze.
Every class **produces or consumes corpses**, so co-op parties negotiate the corpse field (FUTURE_CONTENT goal).

### Hollow Knight — build this class first (fewest new systems)
Resource **Rage** 0–100: +1 per 1% max HP lost, +4 per Hollow Cut hit, +15 on a perfect block; −4/s after 4 s out of
combat.

| Slot | Rite | Effect |
|---|---|---|
| LMB | **Hollow Cut** | 2.4 m, 110° sword arc, 0.55 s, power 1.1 |
| 1 | **Shield Bash** | dash 3 m; first enemy hit stunned 0.8 s (boss 0.2 s); cd 6 s |
| 2 | **Grave Slam** | leap ≤ 8 m to the cursor (nav-valid, like Veil Step), slam r 3, power 2.2; 30 rage |
| 3 | **Bulwark** (lvl 3) | hold ≤ 2 s: −60% damage from the front 120°; a hit in the first 0.25 s is a perfect block (reflect 50%, +15 rage) |
| 4 | **Corpse Vigil** (lvl 5) | stand on a corpse: consume it (host), regenerate 3% max HP/s for 4 s |
| RMB | **Grave Brand** | brand a corpse; the next enemy within 1.5 m of it is rooted 1.5 s (corpse consumed) |
| R | **Oath Unbroken** (lvl 10) | 6 s: can't drop below 1 HP, +30% damage, rage refills; cd 60 s |

### Grave Warden
Resource **Oil** 0–100: regenerates 3/s; +20 per corpse burned.

| Slot | Rite | Effect |
|---|---|---|
| LMB | **Flail Swing** | 3 m, 140° arc, power 1.0 |
| 1 | **Lantern Cone** | 7 m cone (`lantern-cone` sprite): damage, strips Shrouded, stuns wraiths 1.5 s; 20 oil |
| 2 | **Chain Pull** | yank one enemy ≤ 10 m to your feet (host displacement, nav-clamped; boss immune); 10 oil |
| 3 | **Burn the Dead** (lvl 3) | ignite ≤ 3 corpses within r 4 of the cursor into fire zones (5 s), +20 oil each — denies Deacons and Acolytes |
| 4 | **Watchman's Ward** (lvl 5) | plant a lantern post (r 5, 8 s): allies inside take −20% damage, enemies slowed 25% |
| RMB | **Cremate** | one corpse becomes a 3 s fire pillar (Binbun `bonfire`) |
| R | **Last Light** (lvl 10) | a 12 m flare: enemies stunned 1 s, Shrouded removed, allies healed 10% |

### Bell Monk
Resource **Resonance** 0–100: +8 per hit, −5/s after 2 s idle. **The beat:** a global toll every 1.2 s (the HUD
pulses; a soft tick sound). Hits landing within ±0.15 s of the beat deal +40% and +4 resonance.

| Slot | Rite | Effect |
|---|---|---|
| LMB | **Palm Strike** | 1.8 m, fast (0.4 s), sound-ring impact |
| 1 | **Toll** | r 4 around you: damage + interrupts casters; spend 25 resonance for a 0.6 s stun |
| 2 | **Resonant Step** | dash 5 m through enemies, damaging along the path |
| 3 | **Knell** (lvl 3) | mark a target: its next 3 beats deal +60% damage to it |
| 4 | **Choir of One** (lvl 5) | 6 s: every beat emits a small toll ring (r 2.5) |
| RMB | **Sound the Corpse** | strike a corpse: it becomes resonant and rings (r 3); Tolls near resonant corpses are 1.5× each |
| R | **Great Toll** (lvl 10) | r 9 toll; damage scales with resonance spent; silences 3 s |

### Carrion Witch
Resource **Offal** 0–100: only from corpses.

| Slot | Rite | Effect |
|---|---|---|
| LMB | **Hook Throw** | 8 m hook projectile (`hook-chain`), bleeds |
| 1 | **Harvest** | consume a corpse (host): +30 offal, 3 crows orbit you and peck adjacent enemies for 6 s |
| 2 | **Crow Swarm** | crows descend on the cursor: DoT r 3 for 5 s (`crow` sprites); 30 offal |
| 3 | **Hook Pull** (lvl 3) | drag an enemy ≤ 8 m to you (shares Chain Pull's host displacement) |
| 4 | **Hex Charm** (lvl 5) | curse a target: −25% damage dealt; when it dies the hex jumps to 2 neighbours |
| RMB | **Butcher** | carve a corpse into 3 offal charms on the ground that heal allies 5% on pickup |
| R | **Murder of Crows** (lvl 10) | an 8 s swarm follows the cursor |

### Veilwalker — build last (a form toggle touches damage, targeting and rendering)
Resource **Veil** 0–100: drains 12/s while in Veil form, refills 8/s in Life form. **Form toggle** (its own rite on a
key): in Veil form you take no damage from enemy attacks, move +20%, deal spirit damage only (−30%), and see **echo
corpses** — spectral copies (client-side markers, host-validated for use) that only Veilwalkers can spend.

| Slot | Rite | Effect |
|---|---|---|
| LMB | **Spirit Bolt** | 11 m bolt from the palm |
| 1 | **Veil Form** | toggle (above) |
| 2 | **Echo** | raise an echo corpse as a spectral ally for 10 s (counts as a thrall of yours) |
| 3 | **Veil Tear** (lvl 3) | a rift at the cursor pulls enemies in (r 3) for 2 s (`veil-rift`) |
| 4 | **Crossing** (lvl 5) | blink to an echo corpse ≤ 12 m |
| RMB | **Lay to Rest** | consume a corpse: heal 6%; 2 echo corpses appear nearby |
| R | **Between Worlds** (lvl 10) | 5 s: both forms at once — full damage and no damage taken |

## 4. Help, tests, docs

Per class: a counsel tip on first entering the world as it; a Codex Disciplines entry (portrait, resource, kit); spell
cards from the kit data; README class section; Settings keys only if a class adds one (Veil Form sits on key 1, so
none). Tests per kit mirror `spell-variety.test.ts` (target limits, resource spent once, failed casts spend nothing,
corpse consumption exactly once, host sig validation) plus the resource abstraction's necromancer regression. Balance
harness: add each family before tuning; report in `BALANCE.md`. Update `FUTURE_CONTENT.md` (Release 0.3),
`HANDOFF.md`, `PHASE_REPORTS.md`, `docs/ART-BACKLOG.md`, this brief's row in `docs/agent-briefs/README.md`.

## 5. Open art requests (the workstation fills these)

- [ ] **Monk bell staff:** Tripo modelled the small bell as a separate floating island beside the crook
  (`models/props/gear_monk_bell_staff.glb`). In code, hide that mesh island and hang a small code-built bell on the crook; or have
  the workstation regenerate it once credits are topped up (50 credits; balance is 20 after this batch).

- [ ] (if needed) a Veilwalker palm-glow sprite or a spectral tint texture for Veil form.
- [ ] (if needed) per-class resource orb liquid colours — CSS first.
