# Necromancer weapon line

Seven kinds (staff, scythe, wand, ritual sickle; skull focus, grimoire, mourning bell) in five tiers (bone, iron, gold, hell, moon) = 35 items.
Phase N1 of [ALCHEMY-AND-WORLDS-PLAN.md](ALCHEMY-AND-WORLDS-PLAN.md). Player-facing rules are in the README and the Codex (K, Weapons).

## One source of truth

`src/content/necroWeapons.ts` holds the catalogue, `NECRO_WEAPON_TUNING` (every number), drop zones, Workbench recipes and the in-hand model spec.
`src/gameplay/weaponLine.ts` turns worn gear into a `WeaponLoadout` (pure); `Player.loadout` is set by `WorldScene.refreshStats`.

| Kind | Where it acts |
|---|---|
| Staff | `abilityRange` (+25% needle reach), `AbilitySystem.pierceBeyond` (one more enemy, 80%), `deriveStats` (+10% Spell power, thralls excluded) |
| Scythe | `AbilitySystem.reap`: the LMB is a client-resolved arc (the caster's client picks targets and sends ONE `hit` intent, so a relayed cast cannot double-hit; same model as Ivory Cleave). Bonus soul on a kill the arc delivered: `reapedSouls`, read by `WorldScene.onKill` |
| Wand | `abilityCooldownMs` / `abilityLockMs` (cadence 1.3x) and the needle's damage multiplier (0.85) |
| Sickle | needle `hit` intent carries `withered: 1, witheredCap` (the host clamps and owns the duration); Exhume essence refund in `AbilitySystem.cast` |
| Skull focus | thrall cap +1 at gold and above: `WorldScene.applyBoons` (the cap travels in the `exhume` intent) |
| Grimoire | `abilityCooldownMs` on every non-primary rite |
| Mourning bell | `exhume` intent `allyHeal` (host clamps to 3%) is stored on the wraith; each wraith hit emits `heal` events with `frac`, so every nearby player is healed for a share of their own max health |

Only `bone_needle` changes; Bone Fan and Rot Lance keep their own rules. Only the four necromancer disciplines get effects.

## Server and migration

`node tools/generate-necro-weapons.mjs` writes `server/death-muffin/backend/migrations/013-necro-weapons.sql` (35 `INSERT IGNORE` item rows with `two_handed`, plus 35 recipes) and 35 icons in `public/art/items/`;
`--check` (run by the tests) fails if either is stale. **Apply 013 to the Death Muffin database after a backup and before publishing a client that can drop these ids.**
The server needs no code change: `POST /api/inventory/equip` already displaces the off-hand for a two-handed weapon and a two-hander for an off-hand.
Items have no level column (armor has none either), so the level on each tier is a recommendation shown in the tooltip.

## Models

`public/models/props/gear_<kind>.glb` are static Tripo props (Gemini concept in a neutral pale material, then Tripo P1, 50 credits each), baked by
`node tools/build-necro-weapon-glbs.mjs` (+Y long axis, grip on the origin, yaw, WebP textures). One mesh covers five tiers: `gearProps.tintModel`
replaces colour, metal, rough and glow per tier. The procedural builders in `gearProps.ts` stay as the fallback while a GLB loads or if it fails.
Specs and records: `art-manifest/tripo-specs/prop_gear_necro_*.json`, `art-manifest/tripo/`, `art-manifest/gemini-jobs/necro-weapons.json`; raw files in `art-src/necro-weapons/`.
