# Brief G2: the Sexton's Acre (non-combat gathering zone) → branch `cloud/professions-g2`

Read `CLAUDE.md`, `HANDOFF.md`, **`docs/PROFESSIONS-ROADMAP.md`** (§6 is the spec, §4 the node list),
then `src/content/areas.ts`, `src/content/layout.ts`, `src/gameplay/nav.ts`, `src/graphics/WorldView.ts`,
`src/graphics/Atmosphere.ts`, `src/ui/Minimap.ts`, and `docs/agent-briefs/environment.md` (perf rules).

1. **Area** `'acre'` ("The Sexton's Acre" / subtitle "Where the Covenant's dead are tended"):
   `rect { x0: -62, z0: 6, x1: -20, z1: 38 }`, `safe: true`, no enemies, waves, surges or breaches, and
   a waystone interactable. Door `chapter_acre` `{ x0: -20, z0: 17, x1: -13, z1: 23 }`, `axis: 'x'`,
   **always open** (no `unlock`). Make sure nav, doors, minimap, waystones, the area banner/ambience,
   `AREA_ORDER`-driven UI and `necroRules`/progression (areas list, unlock kills) all accept the new
   id. If `necroRules.ts` changes, run `npm run build:server-rules`.
2. **Theme `'acre'`**: walled cemetery garden, overcast dusk (cooler than the Graves), gravel paths,
   low stone walls, falling leaves and crows (Atmosphere), a pond surface (reuse `graphics/Water.ts`).
3. **Layout** (deterministic, in `layout.ts`): `nodes: { type, x, z, rich? }[]` placements per §6's
   sketch. Every tier of every gathering node appears here, with the higher tiers further from the door
   and a single Bone Elder at the far end. Add 2–4 *rich* placements per hunting ground as §6 describes.
   Colliders for trees and rocks, clear walking lanes, and nothing placed on door corridors.
4. Station placements (Bone Kiln, Sawpit, cooking fire = existing brazier prop) as `interactables`
   with new kinds (`kiln`, `sawpit`, `fire`); G4 builds their panels. Use stand-in props until G3.
5. Tests: layout (nodes inside their area rect, no overlap with doors/interactables, deterministic),
   nav (acre reachable from the Chapterhouse spawn, and the dead never path into it).

Do NOT edit `src/scenes/WorldScene.ts` (describe any one-line hook in your report), `src/gameplay/sim/**`
(G1) or backend files. Perf: nodes use prop batches/instancing; stay within the environment brief's
budgets. Keep checks green. Commit on `cloud/professions-g2`; no PR. Report: files, screenshots
(`__cwShot`), the draw-call delta, and test results.
