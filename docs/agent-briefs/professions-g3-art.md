# Brief G3: gathering-node art → **done on the workstation (2026-09-27)**; wired where the code was ready

The pipeline part of G3 needs the workstation's `.ai-keys.local`, so it was run there, not in a cloud
container, with the owner's approved Tripo spend. The professions build (`fa43c9c`) already loads pipeline
props by name through `src/graphics/NodeViews.ts` (`MODEL` table, HEAD-checked, stand-ins as fallback) and
`layout.ts` (`prop_node_bone_kiln`), so most of this art is **live**. The full list of what's generated
but not yet used is in [`docs/ART-BACKLOG.md`](../ART-BACKLOG.md).

## Live now

| Art | Files | Loaded by |
|---|---|---|
| Trees + stump | `public/models/props/prop_node_{coffin_oak,hangman_elm,bleeding_willow,churchyard_yew,blackthorn,ghostwood,bone_elder,stump}.glb` | `NodeViews` `MODEL` (Blackthorn and Ghostwood `live` added 2026-09-27) |
| Mining | `prop_node_{ore_seam,ore_geode,ore_spent}.glb` | `NodeViews` (vein colour = emissive crystal overlay per ore) |
| Gravedigging | `prop_node_{burial_mound,dug_grave,crypt_collapse,barrow_tomb}.glb` | `NodeViews` (`grave_crypt` and `grave_barrow_king` added 2026-09-27) |
| Bone Kiln station | `prop_node_bone_kiln.glb` | `layout.ts` `PROPS` |
| Item icons for the §4 ids | `public/art/items/<id>.png` | InventoryPanel/LootView load `art/items/<id>.png` by name, so they appear as soon as the id exists |

**Naming rule:** node props keep their prefix (`models/props/prop_node_<model>.glb`, which is what the
code loads). `tools/build-characters.mjs` strips `prop_` from every other prop. Rebuild with
`node tools/build-characters.mjs prop_node_<model>`.

## Generated, waiting for code (see ART-BACKLOG §1)

- Stations: `prop_node_{sawpit,alchemy_table,sexton_vault,cook_cauldron,grave_anvil,compost_heap}.glb` for G6/G7.
- Grave Gardening: `prop_node_{garden_plot,garden_sprouts,herb_patch,sapling}.glb` for G5.
- Fishing: `prop_node_black_water_pool.glb`, a stone well/pool marker. The code's pools are ripples on water.
- Hand tools: `models/props/tool_{pickaxe,hatchet,spade,fishing_rod}.glb`. Attach them to the hero while
  gathering, and use the hero's new `attack` swing clip for chopping and mining.
- Optional per-ore seam bakes: `prop_node_ore_seam_{copper,tin,iron,bronze,silver,gold,steel}.glb` and
  `prop_node_ore_geode_{moon,hell}.glb` (`tools/tint-variants.mjs`), an alternative to the crystal overlay.
- Icons for herbs, seeds, saplings, planks, meals, bone meal, tool tiers, finds, contracts and skills.

## Next Tripo batch

None pending for professions. Any further profession art goes through the workstation session (ask the
owner for Tripo spend). Code agents should never generate stand-in art for something already listed in
ART-BACKLOG.
