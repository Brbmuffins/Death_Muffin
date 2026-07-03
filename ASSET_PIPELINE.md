# Asset Pipeline — 3D Characters & Models

How to take a character from nothing → animated in-game. Follow in order; every
gotcha here has already cost credits or debugging time once.

## 0. Before generating ANYTHING

- **Check `art-src/tripo/<slug>/` first.** If the model was already generated, the raw
  outputs and task-ID JSONs are there — regeneration wastes ~30+ Tripo credits.
- Keys live in `.ai-keys.local` (gitignored). Load per-invocation:
  `export TRIPO_API_KEY=$(grep '^TRIPO_API_KEY=' .ai-keys.local | cut -d= -f2 | tr -d '\r')`
- Credits (June 2026): generation ~30, rig ~25 (+25/retry), retarget ~10/clip.
  A full character ≈ 95 credits (~$10).

## 1. Generate (Tripo skill pipeline)

Run from this project directory:

```bash
python ~/.claude/skills/threejs-3d-generator/scripts/threejs_3d_asset.py character-pipeline \
  --prompt "<design>, strict full-body T-pose, arms straight out horizontal away from body, \
legs apart and separated, front facing, symmetric, complete body head to feet, no props, \
clean topology, PBR materials, readable silhouette" \
  --animations preset:idle,preset:walk,preset:run,preset:hurt,preset:slash \
  --out-dir art-src/tripo/<slug>
```

- **`--out-dir` must be `art-src/tripo/<slug>`** — never `public/` (raw files are 60MB+ each).
- Humanoids route to the v1.0 anatomical rig automatically; one FBX per animation.
- Attack presets: `preset:slash` (melee) or `preset:shoot` (ranged) — there is no `preset:attack`.
- Creatures (like the slime) get one locomotion preset max; animate extra motion procedurally.
- Adding a clip to an EXISTING character: find the rig task ID in
  `art-src/tripo/<slug>/rig/*.json`, then a single `postprocess --type animate_retarget`
  (10 credits) — do not re-run the whole pipeline. v1.0 rigs: ONE animation per retarget
  task, `--out-format fbx`, omit `--model-version`.

## 2. Build web assets

1. Add/extend the slug entry in `CHARACTERS` at the top of `tools/build-models.mjs`
   (list the animation dir names that exist under `art-src/tripo/<slug>/`).
2. `node tools/build-models.mjs <slug>` (no args = all).

Output: `public/models/<slug>/rig.glb` (~2.4MB) + `<anim>.glb` (~0.1MB each).
Expected log: rig ~60MB → ~2.4MB, anims ~67MB → ~0.1MB. If the rig stays large,
simplify/textureCompress failed — investigate before shipping.

**Why the script does what it does (do not "simplify" these away):**
- `rig.glb` is built from the **idle FBX**, not Tripo's GLB rig. The GLB rig's rest
  space differs from the FBX clips (Tripo v1.0 is FBX-native) — mixing them renders
  the character **lying prone**.
- Animation GLBs have geometry/materials/skins stripped; clips drive the rig's bones
  by node name.
- Each converted clip file contains the take twice; the loader picks the variant with
  the fewest `|` segments (the deep one binds wrong).

## 3. Register in code

- `src/graphics/modelPaths.ts` — add to `MODEL_PATHS` via `charPaths('<slug>', 'slash'|'shoot')`.
- If it's a playable class: add to `CLASS_TO_MODEL` using **server** indices:
  `0=Engineer (no model), 1=Guardian, 2=Shadowblade (bogar), 3=Cleric (brandolf), 4=Arcanist`.
  These come from CLASS_NAMES in `/opt/rod-auth/server.js` — do NOT renumber.
- Enemies/props: reference `MODEL_PATHS.<slug>.rig` directly.

`src/graphics/CharacterModel.ts` handles the rest automatically: bounds-based scale
normalization to 1.8 units (never hardcode a scale — quantize rebakes node scales),
feet grounded at y=0, horizontal-only `Root.position` root-motion strip, crossfades,
capsule fallback if loading fails.

## 4. Verify (QA bar before calling it done)

- `npx tsc --noEmit`
- Dev server (`npm run dev`, port 5188), login with an account from
  `TEST_ACCOUNTS.local.md`, check the model in the hub.
- **preview screenshots time out on this app.** QA numerically via the dev hook
  `window.__cwDebug` (HubScene, DEV only): bounding box ≈ 1.8 tall / minY 0
  (a z-depth ≥ ~1.5 means prone — rig/clip mismatch), clip list complete,
  no `THREE.PropertyBinding` warnings, WebGL `readPixels` shows the character's
  palette at screen center.

## Current model inventory (2026-07-03)

| slug | maps to | clips | note |
|---|---|---|---|
| guardian | class 1 | idle walk run hurt slash | verified in hub |
| bogar | class 2 (Shadowblade) | idle walk run hurt slash | |
| brandolf | class 3 (Cleric) | idle walk run hurt | **attack retarget pending** (rig task ID in `art-src/tripo/brandolf/rig/*.json`) |
| arcanist | class 4 | idle walk run hurt shoot | |
| slime | enemy (unwired) | none — static | animate procedurally in `enemies.ts` |
