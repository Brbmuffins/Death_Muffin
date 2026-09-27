# Brief G3: gathering-node art through the pipeline → branch `cloud/professions-g3`

**Needs the owner's Tripo OK first** (roadmap §10 / §12 q5: all 14 props ≈ 700 credits, or the P1
subset ≈ 450). Needs the workstation with `.ai-keys.local`; a cloud container can't run it.

Read `CLAUDE.md`, **`ASSET_PIPELINE.md`**, **`docs/PROFESSIONS-ROADMAP.md`** §10, and the memory
notes on Tripo spend. Concepts are already generated (`art-manifest/gemini-jobs/gathering-nodes.json`;
raw PNGs in `art-src/concepts/props/node_*.png`; a preview is in `docs/professions/node-concepts.webp`).
Specs are written: `art-manifest/tripo-specs/prop_node_*.json`.

1. `node tools/ai/tripo.mjs balance`, then for each approved prop do a dry run and then run
   `node tools/ai/tripo.mjs run art-manifest/tripo-specs/prop_node_<id>.json --yes`, then
   `node tools/build-characters.mjs prop_node_<id>` → `public/models/props/prop_node_<id>.glb`. Report the
   credits used per prop.
2. Register each prop in `src/content/layout.ts` `PROPS` (target height + collider). Trees are 3.5–6 m
   tall, the seam ~1.2 m, the geode ~1.5 m, the mound ~0.6 m, the plot ~0.5 m, the kiln ~2.2 m.
   Emissive boosts ≤0.15 (Tripo materials are mostly metallic).
3. **Ore tints**: one seam model serves copper → steel. Add a vein-tint approach that doesn't
   recolour the whole baked texture, such as a material mask from the texture's saturated pixels or
   a small emissive overlay mesh. Document it in `ASSET_PIPELINE.md`.
4. Gemini (cheap, no approval needed): concepts for Blackthorn, Ghostwood, Sawpit, Alchemy table and
   Sexton's Vault in the same prompt style, plus **item icons** for every new item id in G0's migration
   (`public/art/items/<id>.png`, `icons-v3.json` style), and wire them into `items.ts`.
5. Update the `ASSET_PIPELINE.md` inventory table.

Do NOT edit gameplay/sim/UI code beyond `PROPS` and `items.ts` icons. Keep checks green. Commit on
`cloud/professions-g3` (GLBs and icons included; raw `art-src/` stays out). Report: credits, files,
triangle counts, and a screenshot of the props in the Acre (or a lineup via `__cwDebug.lineup`).
