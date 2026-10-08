# Death Muffin: Godot port (foundation slice + wave-2 world)

A native Godot 4.7 build of the web game. The foundation slice was two rooms; the world track (wave 2) extends it to the whole connected
world: Chapterhouse, Sexton's Acre, Alchemist's Wing, Hollow Graves, Catacomb Warren, Marrow Ossuary, Drowned Nave, Bone Coliseum, Bell Sanctum,
Plague Cloister, Cinder Pyre, Mourning Fen and the Catacomb Depths (one sample floor), with all doors/gates, props, gathering nodes, NPCs and every
character/enemy/boss model. Conventions for the parallel tracks: `PORTING.md`. (Paths still say `slice`: `godot/data/slice/`, `godot/assets/slice/`.)

## Run
```
/home/ubuntu/tools/godot/godot --path godot            # needs a GPU/display; or open godot/project.godot in the editor
# scripted QA run with screenshots (VPS: software GL, ONE renderer at a time):
flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice xvfb-run -a -s "-screen 0 1280x800x24" \
  /home/ubuntu/tools/godot/godot --path godot --rendering-driver opengl3 -- --qa --shots=/abs/dir
```
World tour (one screenshot per area, all seals broken) and a sealed-gate shot:
`godot/tests/world/tour.sh` -> `godot/shots/world/area_NN_<id>.png`, `tests/world/tour.sh --gate=graves_ossuary`. Headless test: `godot --headless --path godot --script res://tests/world/run.gd`.
Dev: **F9** (or `-- --open-all`) breaks every seal so every area is walkable; real seal state is `DmWorldBuilder.set_unlocked([area ids])` (the web's Nav.setUnlocked).
Controls: WASD or click to move; LMB on an enemy = chase + Bone Needle; Shift+LMB = fire at the cursor; **1** = Exhume the corpse nearest
the cursor as a thrall (cap 3); wheel = zoom; **F3** = performance overlay.

## Data and assets flow (nothing hand-copied)
1. `npx vite-node tools/godot/export-slice.ts` imports the real TS modules (areas, `generateLayout()`, doors, enemies, bosses, NPCs, the Depths floor generator,
   gathering nodes, strides/clip timings, disciplines, abilities, `deriveStats`, items) and writes `godot/data/slice/{world,enemies,npcs,hero}.json` +
   `assets_used.json`. Constants that are module-private in the TS (floor textures, node model map, enemy slugs, light/tonemap numbers) are mirrored in the
   exporter and **verified against the TS source text**, so drift fails the export.
2. `node tools/godot/sync-slice-assets.mjs` copies exactly those files from `public/` to `godot/assets/slice/`. GLBs are **dequantized** on the way
   (`KHR_mesh_quantization` is rejected by Godot's glTF importer). ~74 MB of GLB + the textures Godot extracts on import, committed with the `.import` files.
3. First open needs an import: `godot --headless --path godot --import`.
Scripts: `godot/world/` (data loader, `DmModels` model normalisation, `DmAnimator` stride-matched locomotion/strikes/hurt/death, `DmWorldBuilder`, enemy, thrall, bolt, fx),
`godot/main/` (main, hero, camera, HUD, perf overlay, QA autoload `Qa`, inactive without `--qa`).
World builder: one node per area (streamed by distance), floors per theme, per-area hemisphere (sky-ambient) + fog + moon colour, ACES tonemap exposure 1.2,
MultiMesh props with `StaticBody3D` colliders, floor light pools, the nearest 8 prop lights, gates (posts, bars, seal sigil, collider) per sealed door, and
one navigation region per area and per door corridor joined by `NavigationLink3D`s that switch with `set_unlocked`.

## Export
Presets in `godot/export_presets.cfg` (Windows Desktop x86_64, Linux). Templates are in `~/.local/share/godot/export_templates/4.7.2.stable/`.
```
godot --headless --path godot --export-release "Windows Desktop" build/win64/DeathMuffin-godot-slice.exe
godot --headless --path godot --export-release "Linux" build/linux/DeathMuffin-godot-slice.x86_64
(cd godot/build/win64 && zip -j ../DeathMuffin-godot-slice-win64.zip *.exe *.pck README.txt)
```
`godot/build/` is gitignored. Renderer is `gl_compatibility` (OpenGL 3, good for the low-end question).

## Real vs placeholder
Real (from exported TS data): all 13 areas' rects, themes, ambient palettes and fog multipliers, all 11 doors (sealed ones get a gate: posts, bars, seal sigil, collider;
chapter_graves is always open), every wall / prop placement + collider + model + height + light, every gathering node (GLB live models; herb/pool stand-ins as in the web),
paths, decals (sigils; blood/cracks as soft stains), water/bog/pond rects, Fen hummocks, Alchemist's Wing rugs/stains, the Depths' sample floor (run seed 1337, depth 1),
NPC spots, camera numbers, enemy stats for all 28 enemies + 7 bosses (data only), area rosters/waves/breaches/loot, hero level-1 derived stats, thrall stats, Bone Needle, Exhume.
Lighting follows the web renderer: ACES tonemap (exposure 1.2), hemisphere light (sky ambient: sky colour above, ground colour below), moon + violet rim directionals,
fog that tracks FogExp2 (0.014 x area multiplier) with Godot's depth fog, floor light pools. Animation: stride-matched walk/run (`planLocomotion` golden-tested against the TS),
timed strikes (`strikeTiming`, golden-tested), hurt flinch, death held on the last frame, numbered variety clips.
Placeholder:
- Hero base stats are 5/5/5/5 at level 1 (no character/server). Hero death = hp reset; no XP/levels, loot is floating text only; HUD is minimal; no audio.
- Enemy AI is deliberately simple (the sim track replaces it): walk to the nearest target, strike after the windup; no flank, burrow, hazards, cones, elites, packs, boss brains.
  Static-mesh enemies (moth, bat, wraith, leech, wisp, skull niche) spawn but have no wing flap / bob. Waves spawn in whichever unsafe area the hero stands in.
- Seals/unlocks: no progression yet; the default state is a new character's (always-open halls only). `set_unlocked()` is the hook; F9 breaks all seals.
- The Depths: one generated sample floor, no per-run generation (depthsFloor.ts is not ported), stairs/chest are stand-in discs.
- Not drawn: stained-glass windows, far silhouettes (spires/trees), candle-flame particles (one glow sphere per light), rain puddle mirror shader, water ripples/glint, mist, wing flap.
- Lights: only the nearest 8 prop lights are on at once (Compatibility renderer budget); areas farther than 95 m from the camera focus are hidden.
- THRALL_BASE (WorldSim) is module-private in TS and mirrored in export-slice.ts (marked "keep in sync"); the exporter's other mirrors are verified against the TS source.
- Web quirk: a few Coliseum wall segments are written right-to-left, so their TS collision box has a negative extent (a no-op in the web's nav); the Godot builder orders the corners, so those walls exist.

## Comparison checklist for Helix (same PC, web build vs this build)
1. Open F3 in both (web: F3 overlay; here: F3). Note fps, avg/p50/worst frame ms, hitches per second, draw calls, in the Chapterhouse and in the Graves.
2. Stand in the Graves ~30 s as the wave spawns (28 enemies cap): note the worst frame and hitches. Compare the same two numbers in both.
3. Fight: Bone Needle on a crowd, Exhume 3 thralls; does the frame time spike when thralls/enemies appear (first-use hitches)?
4. Feel: click-to-move responsiveness, camera follow, how soon an input shows on screen (the Godot build has no frame-rate cap logic: check vsync/monitor Hz).
5. Resolution/quality: both at the same window size; note GPU model, driver and whether the web build was on the "Low" graphics setting.
6. Load time: launch to controllable hero. Memory (Task Manager) after 2 minutes.
7. Report the F3 lines as text/screenshot. Only numbers from a real GPU count: the VPS (llvmpipe, software GL) runs this at ~7 fps and says nothing about real hardware.

## Where the frame goes (CPU)
- **F3 rows** (in a running world): `tick X = sim .. (ai ..) + views .. + events .. + rest ..` is the game tick split into systems, `fx` the Vfx autoload,
  `ui` the HUD / counsel, `outside` the remainder of the frame (engine: animation, culling, draw submission, GPU wait). If `outside` dominates in a fight,
  look at `calls` / `objects` and `render cpu`; if `sim` or `views` grow with `enemies`, it is script cost.
- **Headless CPU bench**: `godot --headless --fixed-fps 60 --path godot --script res://tests/perf/combat_bench.gd -- --phase=idle|combat|boss [--area=nave] [--seconds=15]`
  runs the real game loop (DmGame + DmGameUi + autoloads) at a fixed timestep with forced waves and a corpse-raised legion; it prints frame median / p95 / p99, the
  tick sections, the cost per event type, what the slowest 5% of frames are made of (`--spikes=1`), live fx load, and with `--census=1` the render item census.
  Run base and candidate at the same time on separate cores and compare medians (a shared VPS is noisy). The older `combat_perf.gd` / `wave_perf.gd` give per-section views.
