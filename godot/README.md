# Death Muffin: Godot slice (foundation track)

A native Godot 4.7 build of the first two rooms (Chapterhouse, Hollow Graves, the door between) to compare with the web build
(performance and feel). Conventions for the parallel tracks: `PORTING.md`.

## Run
```
/home/ubuntu/tools/godot/godot --path godot            # needs a GPU/display; or open godot/project.godot in the editor
# scripted QA run with screenshots (VPS: software GL, ONE renderer at a time):
flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice xvfb-run -a -s "-screen 0 1280x800x24" \
  /home/ubuntu/tools/godot/godot --path godot --rendering-driver opengl3 -- --qa --shots=/abs/dir
```
Controls: WASD or click to move; LMB on an enemy = chase + Bone Needle; Shift+LMB = fire at the cursor; **1** = Exhume the corpse nearest
the cursor as a thrall (cap 3); wheel = zoom; **F3** = performance overlay.

## Data and assets flow (nothing hand-copied)
1. `npx vite-node tools/godot/export-slice.ts` imports the real TS modules (areas, `generateLayout()`, enemies, disciplines, abilities,
   `deriveStats`, items) and writes `godot/data/slice/{world,enemies,hero}.json` + `assets_used.json` (which GLBs/textures the slice uses).
2. `node tools/godot/sync-slice-assets.mjs` copies exactly those files from `public/` to `godot/assets/slice/`. GLBs are **dequantized**
   on the way: the web models use `KHR_mesh_quantization`, which Godot's glTF importer rejects. (WebP textures import natively.)
   ~11 MB, committed (with the `.import` files) so a fresh checkout opens without the TS toolchain.
3. First open needs an import: `godot --headless --path godot --import`.
Scripts: `godot/world/` (data loader, model normalisation, world builder, enemy, thrall, bolt, fx), `godot/main/` (main, hero, camera,
HUD, perf overlay, QA autoload `Qa`, inactive without `--qa`).

## Export
Presets in `godot/export_presets.cfg` (Windows Desktop x86_64, Linux). Templates are in `~/.local/share/godot/export_templates/4.7.2.stable/`.
```
godot --headless --path godot --export-release "Windows Desktop" build/win64/DeathMuffin-godot-slice.exe
godot --headless --path godot --export-release "Linux" build/linux/DeathMuffin-godot-slice.x86_64
(cd godot/build/win64 && zip -j ../DeathMuffin-godot-slice-win64.zip *.exe *.pck README.txt)
```
`godot/build/` is gitignored. Renderer is `gl_compatibility` (OpenGL 3, good for the low-end question).

## Real vs placeholder
Real (from exported TS data): area rects, door, walls, every prop placement + collider + model + height + light, rich gathering nodes, floor
paths, area ambient colours, camera numbers (fov 40, dist 22, pitch, follow rate), enemy hp/speed/damage/range/windup/cooldown/radius/scale/corpse
kind, wave size/interval/cap/breach spawn points/weights, hero level-1 derived stats and thrall hp/damage/speed (Ossuary shieldbearer), Bone
Needle (cooldown, range, radius, power, +6 essence per hit), Exhume (cost, range, radius, cooldown), thrall cap, Bone Ward, loot table + chance.
Placeholder:
- Hero base stats are 5/5/5/5 at level 1 (no character/server).
- Enemy AI: all walk to the nearest target (hero slightly preferred) and strike after the windup; no flank, Ghoul burrow, Sac hazard,
  Penitent cone shape, elites, packs; Moth/Bat (static flapping meshes) are not in the slice roster.
- Thralls: simple follow slots and nearest-enemy fighting; no Shieldbearer aggro pull; rise = scale-up.
- Hero death = hp reset; no XP/levels, loot is floating text only; HUD is minimal; no audio, no gates/seal logic (other doors are plain walls).
- Lighting is an approximation (Filmic tonemap instead of ACES, ambient colour instead of a hemisphere light, FogExp2 approximated by Godot's
  exponential fog); prop lights only enabled within 26 m of the hero; flames are small glow spheres; rain puddles/cracks/blood decals/windows/silhouettes skipped.
- Animation: loops idle/walk/run, root travel removed from walk/run; playback speed is not stride-matched (web uses stride speeds).
- THRALL_BASE (WorldSim) and the node model heights (NodeViews) are module-private in TS and mirrored in export-slice.ts (marked "keep in sync").

## Comparison checklist for Helix (same PC, web build vs this build)
1. Open F3 in both (web: F3 overlay; here: F3). Note fps, avg/p50/worst frame ms, hitches per second, draw calls, in the Chapterhouse and in the Graves.
2. Stand in the Graves ~30 s as the wave spawns (28 enemies cap): note the worst frame and hitches. Compare the same two numbers in both.
3. Fight: Bone Needle on a crowd, Exhume 3 thralls; does the frame time spike when thralls/enemies appear (first-use hitches)?
4. Feel: click-to-move responsiveness, camera follow, how soon an input shows on screen (the Godot build has no frame-rate cap logic: check vsync/monitor Hz).
5. Resolution/quality: both at the same window size; note GPU model, driver and whether the web build was on the "Low" graphics setting.
6. Load time: launch to controllable hero. Memory (Task Manager) after 2 minutes.
7. Report the F3 lines as text/screenshot. Only numbers from a real GPU count: the VPS (llvmpipe, software GL) runs this at ~7 fps and says nothing about real hardware.
