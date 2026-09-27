# Brief G1: gathering nodes in the world + the gathering loop → branch `cloud/professions-g1`

Read `CLAUDE.md`, `HANDOFF.md`, **`docs/PROFESSIONS-ROADMAP.md`** (§1, §7 are the spec), then
`src/gameplay/sim/WorldSim.ts` (corpses: add/remove/expire, snapshot), `sim/snapshot.ts`, `sim/types.ts`,
`src/scenes/WorldScene.ts` (`onPrimaryClick`, `pendingInteract`, `tickCombat`, auto combat, `hover`),
`src/gameplay/autoCombat.ts`, `src/gameplay/Player.ts`, `src/graphics/EntityViews.ts`, and
`src/gameplay/progression.ts` (the optimistic-apply + flush pattern). If G0 hasn't landed, stub
`gather()` behind the contract in the roadmap §8 and `gatheringRules.ts` types.

1. **Nodes in the sim**: `WorldSim.nodes: Map<id, { id, type, x, z, area, remaining, respawnAt, rich }>`,
   seeded from `layout` node placements (G2 provides them; use a small test set until then). Host-authoritative
   depletion and respawn, `node`/`nodeGone`/`nodeBack` events, snapshot sync (bounded like corpses),
   and a `gather` intent `{ nodeId }` (add it to `server/realtime/server.js` validation, then run
   `node tools/embed-realtime.mjs`).
2. **The loop** (`src/gameplay/Gathering.ts`, called from WorldScene): hover tooltip data, click →
   walk to the node's ring → face → loop the `dig`/`cast` gesture → per-cycle progress → local success
   roll for feel → queue actions → flush to `/api/gather` every ~10s → reconcile inventory and skills
   from the reply (server wins). `+XP` floating text (new `skill` kind), item pop, SFX hooks
   (`chop`, `pick`, `splash`, `shovel`; add procedural recipes to `src/audio/Audio.ts`).
3. **Auto**: when the node depletes, walk to the nearest same-kind usable node in the same area. Stop on
   movement input, panels, a full bag or damage, reusing the rules auto combat already follows. Never leave
   the area, and never pick a node above the player's level. Pure decision function + unit tests, like
   `autoCombat.ts`.
4. Views: `EntityViews` shows a node's live/depleted prop (stand-in meshes until G3's GLBs:
   code-built trunk/rock/mound shapes), a hover ring, and a progress arc under the hero.
5. Tests: sim (depletion/respawn/snapshot round trip, co-op: two gatherers deplete one node), auto-gather
   decisions, flush/reconcile with a mocked API.

Do NOT edit `src/content/areas.ts`/`layout.ts` (G2), `src/ui/**` panels (G4), or backend files (G0).
Keep checks green (`typecheck`, `test`, `test:server`, `build`). Browser-QA with `?offline` +
`__cwDebug` (add `nodes()` and `gatherAt(type)` debug hooks). Commit on `cloud/professions-g1`; no PR.
Report: files, the WorldScene hook points you added, test results, a short QA log.
