# The draw budget

The 3D draw calls of a Full Party, counted from data. The performance controls: [README.md](README.md).

The 3D draw calls of the Graves' Full Party fight (72 enemies, 32 thralls, the camera over the middle of the room, Ultra's moon with two cascades), counted from data so a test can hold them
(`tests/draw_budget.gd`: a draw call is what the budget counts and a headless run draws nothing) and checked against a rendered run (`client/tools/draw_measure.gd`). `DmDrawModel` (`next/perf/dm_draw_model.gd`) is the
count, `DmDrawScene` (`next/perf/dm_draw_scene.gd`) the scene both build: the room's area scene, the game's camera, the Ultra preset's moon, the combat core with four necromancers' thralls and 72 enemies; no hero, HUD or effects.

**What Forward+ draws,** measured with the engine's own counters (`Viewport.get_render_info`, the main pass and the shadow passes; Forward+ on lavapipe, 2026-10-17) and found again in Helix's benchmark runs:
- An instance is an *object* in the main pass when its bounds meet the camera's frustum, and in a shadow pass once for each moon cascade whose volume its bounds meet, when it casts. A *draw call* is one surface of an object.
  The Ultra preset has two cascades (0 to 8 m from the camera, 8 to 80 m: the first holds nothing but air at this camera, and still draws every MultiMesh that casts, whose bounds are the whole area).
- **Identical meshes are instanced by the renderer:** the instances of one mesh, surface and material that a pass meets are ONE draw call. The Graves' 130 props as prefab instances cost 33 draw calls (15 in the main pass, 18 in the shadow
  passes); a mesh that stands once costs its surfaces, and so does a mesh that merges many props.
- **A MultiMesh with no instance costs its draw calls all the same:** one in the main pass and one in each cascade it meets when it casts (+1 draw call in the main pass and +2 in the shadow passes when it casts, whether it holds 0 or 4 instances). A MultiMesh is never merged with another.
- Occlusion culling (the Graves' occluders), the sky and the lights' own work are not counted: the model runs a few draws under the engine (the Graves' world from the camera's middle: 75 against 84 rendered; with the merged cell meshes that were tried and dropped ("Static batching is not in the areas" below) it was 105 against 107), so a budget is set a little over the model's number.

**The benchmark's rows** follow from those rules; they overlap (hiding the world takes its shadow draws too, and the Shadows row is every shadow draw, the crowd's too). With every group drawn, the roster's 202 groups (41 models x levels of detail x with and without shadows)
cost the crowd 396 draw calls of which the Graves' party used 15 groups: 187 were drawn empty, 396 draw calls for 41 that mattered.

**The crowd draws what is in view, not what is registered.** `DmCrowd.set_group_nodes` (dmcore 0.14; `CrowdView` calls it for every model) hands the crowd the `MultiMeshInstance3D` of each group: the nodes start hidden, a group is shown
the frame its first instance is written and hidden once it has held none for half a second (a body crossing a level of detail back and forth does not rebuild the instance every few frames). The party's draws no longer grow with the roster:
the crowd of the Full Party costs 41 draw calls (17 main, 24 shadow) in the rendered run, 396 with every group shown (Helix's PC, the Bell Sanctum's Full Party: 27, 41 and 48 draw calls for the creatures on Low, High and Ultra, client/crowd/README.md "Crowd cost"). A model's first appearance
shows a group the frame it is needed; the models share the crowd's shader, so that costs a material's uniform set and no compile (the warm-up draws every model once all the same).

**Static batching is not in the areas** (measured 2026-10-17): merging a cell's repeated props into one mesh was no saving in draw calls, because the instances it replaced were already one draw call per mesh and a cell mesh is unique.
The Graves' world from the camera's middle and four places round it, rendered (`tools/draw_measure.gd --compare=<another version of the room's scene>`): 107, 112, 112, 93 and 116 draw calls merged, 84, 94, 91, 80 and 99 as prefab
instances (13 to 23 more merged; +30 on Helix's PC); the props alone 56 against 33; the merge saved objects (171 in the main and shadow passes to 129). The lightmap does not change the count (110 with it, 109 with it hidden). What cuts the
world's draws further is fewer distinct meshes and materials, which is a matter of the art.

**A body that is not solid draws through its model's fade group** (client/crowd/README.md "The alpha path"): a sinking body or a shrouded elite is written to a third MultiMesh of its model and level, drawn with the alpha shader in the
main pass only (no shadow pass), so a fight with nothing fading costs what it did and a crowd of bodies sinking together costs one draw call a model and level. The Full Party with 24 of its robbers and hounds sinking and three shrouded elites
standing among them: 27 instances in 2 fade groups, 24 draw calls for the crowd where the standing party's are 22 (`BUDGET_FADE`, 8, is what the budget allows the fade groups on top of the others).

**The test** (`tests/draw_budget.gd`, 50 s, bakes twelve crowd models into a scratch folder) builds the scene, lets the party fight for two seconds and counts: the crowd's groups (a group that holds instances is shown, at most two empty ones are shown, most
groups are idle), the crowd's, the world's and the whole's draw calls against `BUDGET_CROWD` (30), `BUDGET_WORLD` (85) and `BUDGET_TOTAL` (110; the model counts 22, 75 and 97), and that the model sees a crowd with every group shown (120 draws with only
twelve models; 396 with the roster). A change that adds draw calls fails here and not on Helix's PC; raising a budget is a decision. Rows by group are printed.

**The measurement** (`client/tools/draw_measure.gd`, rendered, about 200 s on the VPS; the command and its options are in the file's header) writes JSON lines: the world from five camera places and each group of its geometry hidden alone, the same for
another version of the scene (`--compare`), a MultiMesh with and without instances, and the crowd as the crowd shows it, with every group shown and hidden, each beside the model's number for the same frame.
