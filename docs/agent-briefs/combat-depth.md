# Brief — Combat depth pack → branch `cloud/combat-depth`

Read `CLAUDE.md`, `HANDOFF.md`, `FUTURE_CONTENT.md`, and skim `src/gameplay/sim/WorldSim.ts`,
`src/gameplay/sim/types.ts`, `src/gameplay/AbilitySystem.ts`, `server/rules/content/enemies.ts`,
`src/content/abilities.ts` (incl. `SPELL_FX`), `src/graphics/EntityViews.ts`, and
`src/scenes/WorldScene.ts` (handleEvent, castSlot, bindInput).

Implement host-authoritatively through the existing Intent → WorldSim → SimEvent pattern
(clients send Intents; WorldSim applies them and emits SimEvents; WorldScene.handleEvent turns
events into VFX/audio/rewards; the realtime server relays them unchanged):

1. **Corpse Explosion** on RIGHT-CLICK (bind pointer button 2 in WorldScene.bindInput; the canvas
   already suppresses the context menu). Targets the corpse nearest the cursor (reuse
   AbilitySystem.pickCorpse). New intent `{ t: 'detonate', by, corpseId, dmg }` → WorldSim removes
   the corpse (reason 'burst') and deals area damage (radius 3, `dmg` = caster spell power × 1.8,
   clamped in the sim). Resonant corpses ×1.6 radius; toxic corpses leave a *friendly* rot zone;
   elite corpses ×2 damage. 15 essence, 0.6 s cooldown. Add to `ABILITIES` as `corpse_explosion`
   (slot 5; icon may reuse `art/abilities/necro-litany.png` until a new one is generated) with an
   ember/marrow colour identity from SPELL_FX — **not violet**. HUD hint for right-click.
   VFX: ember-crimson burst + bone shrapnel via Effects.emit/decal; audio `audio.play('burst', x, z)`.
2. **Elite affixes** rolled on elite spawn: `bellTolled` (every 6 s a stun-ring telegraph r=3 →
   'hurt' events), `hungering` (eats a corpse within 5 m every 4 s to heal 15% max HP — new
   corpseGone reason 'devoured'), `shrouded` (50% less damage unless inside a player's miasma),
   `vengeful` (on death spawns 3 Risen). Add `affix?: EliteAffix` to Enemy; append it to the
   snapshot EnemyRow and update WorldMirror (`src/gameplay/sim/snapshot.ts`); show the affix in the
   HUD target frame (WorldScene.updateHud builds `target`); give each affix a readable visual in
   EntityViews (bronze ring pulse / olive drool / dim semi-transparent / ember cracks).
3. **Grave Surges**: every 90–150 s while a player is in a non-safe unlocked area, emit
   `{ t: 'surge', area, x, z, durationMs }` at a breach, then 3 rapid waves over 20 s from that point;
   if ≥80% of surge spawns die before it ends emit `{ t: 'surgeCleared', area, x, z }` and
   WorldScene rewards a guaranteed item (loot.rollItem) + bonus gold via LootView; banner text.
4. **Soul Harvest meter** (client-side): each kill credited to the local player or their thralls
   adds 1 soul; at 50 the next Marrow Spear / Miasma / Black Litany is free and 50% larger. Small
   skull meter above the hotbar (src/ui/HUD.ts + ui.css, `.hud-*` token style).
5. Tests in `src/gameplay/__tests__/sim.test.ts` for detonate, each affix, and the surge lifecycle.

Constraints: no REST changes, no new item ids (test-enforced). Keep realtime in sync — add
'detonate' to INTENT_TYPES in `server/realtime/server.js` with clamped validation + a test in
`server/realtime/server.test.js`, then `node tools/embed-realtime.mjs`. Colour language:
bone=ivory/amber, marrow=ember/crimson, spirit=jade/teal, rot=chartreuse/olive, ritual=violet
(reserved), enemy bell=bronze. Do not edit `src/graphics/WorldView.ts`, `src/content/layout.ts`,
README.md, or assets. Commit on `cloud/combat-depth` and push; no PR, no merge. Report: branch,
commit, files, test results, what needs in-browser QA.
