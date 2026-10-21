# client/fx: Vfx, the visual effects runtime

Autoload `Vfx` (`client/project.godot`: `Vfx="*res://fx/dm_fx.gd"`, script class `DmFxRuntime`). Two layers:
- **Binbun scenes**: 64 native Godot scenes in `client/assets/fx/binbun/<id>.tscn` (GPUParticles3D, ShaderMaterial, AnimationPlayer), played with
  spawn colours, pooled per id. `dm_fx_binbun.gd`; `dm_fx_controller.gd` / `dm_fx_light.gd` / `dm_fx_rect.gd` replace the vendor scripts.
- **Procedural primitives and motifs**: rings of motes, decals, flashes, orbits, beams, projectiles, spikes, hands (`dm_fx_prims.gd`,
  `dm_fx_ring.gd`, `dm_fx_layer.gd`) and the necromantic motifs (`dm_fx_motifs.gd`). What grows with the number of effects on screen, the motes and the
  ground decals, is kept in the combat core's C++ (`DmMotes`, `DmDecals`): "The effects" below.
Tables (spell colours, presets, caps, catalog) are in `client/assets/fx/fx_data.json`, read through `DmFxData`.

## Wiring
- Callers: `DmRiteFx` (`client/game/dm_rite_fx.gd`), `DmEnemyFx` (`client/next/enemy_fx/`: the effects of every creature of the core, from the host's events),
  `DmBossFx` (`client/next/bosses/dm_boss_fx.gd`), `DmEventFx` and its boss, telegraph and zone parts, `DmGearFx`, `DmStatusSet` (heroes and bosses) and the hub, Depths and
  Acre code call `Vfx.*`. The core's thralls, corpses and affixes have no node of their own, so no effect call of theirs: `DmEnemyFx` draws them.
- Quality is set by `client/next/perf/dm_next_perf.gd` from the graphics preset (`DmGraphicsPreset`, columns `fx` and `binbun`): `Vfx.quality = "high"|"low"`
  (Low: bursts thinned to 75 %, motifs off) and `Vfx.binbun.enabled` (High and Ultra only: Low and Medium draw no Binbun scene). Also `Vfx.reduced_motion` and `Vfx.hitstop_scale`.
- A Camera3D must exist: loopers are culled by distance (40 m + camera height) and frustum (tested every third frame, 4 m of margin).
- Effects are emission-heavy; the graphics preset owns the bloom (`DmWfxBloom`, client/next/perf/README.md "Graphics presets"). `Vfx.binbun.gain` scales every Binbun shader's
  brightness (`dm_gain`); it stays 1 in the game (the gallery's `--gain` sets it).
- Forward+ reads colours differently from the renderer these effects were built on: the particles' materials, the Fx layer's shaders and each Binbun shader's own `COLOR`
  are converted so the effects keep the look they were built with (client/next/look/README.md).
- Decal render order = `render_priority` (friendly 2, hero 3, danger 4, particles 5, sprites/Binbun/beams 6). Do not give world transparent materials above 1.
- After adding a `class_name`, run `godot --headless --path client --import` once.
- Regenerating Binbun scenes: `tools/godot/fx-binbun-rebuild.ts` rebuilds them from `public/fx/binbun/*.json` (the output of `tools/binbun-port.mjs`, which needs the private vendor packs, not in git) and writes `client/assets/fx/binbun/`;
  `tools/godot/fx-binbun-unlit.ts` rewrites the committed shaders in place.

## API (all on the `Vfx` node)

```gdscript
# Binbun scene (native GPUParticles3D / ShaderMaterial / AnimationPlayer). Returns a DmFxHandle (alive, kill(), move(Vector3), set_alpha(a)).
var h := Vfx.play("miasma_cloud", Vector3(x, 0, z), {
    "scale": r / 3.8, "alpha": 1.0, "rot": yaw, "dir": Vector3(dx, 0, dz),   # dir -> yaw
    "colors": [Color, Color, Color],        # primary, secondary, tertiary; default = FX_PRESETS colours (SPELL_FX), see DmFxData.spell(group, key)
    "follow": func(): return Vector3(...),  # or null to end the effect
    "duration": 4.0,                        # seconds; loopers otherwise run until killed
    "once": true, "y": 1.0, "raw": false,   # once defaults to "is an impact id"; y overrides preset height; raw ignores the preset
})
Vfx.stop(h)            # == h.kill(): fades out over 0.3 s
```
`play` applies `FX_PRESETS[id]` (colours, scale, y, alpha multiply the opts) and, while `Vfx.role == "other"`, the partner dim (alpha x0.35, scale x0.75). A dead handle (`alive == false`) comes back for Low quality, an unknown id, or a dropped looper.

Procedural primitives (option dictionaries; closures are Callables; colours may be `Color` or `0xRRGGBB`;
textures by name: `glow ring disc sigil cone coneEdge bar smoke spark cracks lightPool` and the FX_IMAGES names `skull boneShard crescent wisp frostFan ...`):

- `Vfx.emit({x,y,z,count,color,spread,speed,up,life,size,gravity,drag,shrink,inward})` / `emit_smoke`
- `Vfx.decal({tex:"disc", color, x, z, r, y, rot, duration, opacity, fadeIn, fadeOut, growFrom, spin, blending:"add"|"mix", sx, sz, anchor, follow, follow_body, pulse, delay, persistent, danger, hero, other})` (camelCase keys;
  `follow_body` is the id of a creature of the core, which the crowd places; `follow` is a Callable as before)
- `Vfx.danger(func(): ...)`
- `Vfx.flash({x,y,z,color,size,duration,tex,rise,opacity})` / `Vfx.orbit({tex,color,count,radius,y,size,duration,speed,follow})`
- `Vfx.beam(a: Vector3 | Callable, b: Callable, color, width, duration)`
- `Vfx.projectile({from, to: Callable, speed, color, kind:"needle"|"orb"|"sprite", tex, size, arc, on_arrive: Callable(Vector3), on_trail: Callable(Vector3)})` -> ref with `pos()` (null once landed)
- `spike_ring(x,z,r,count,life)`, `spike_line(x,z,dx,dz,len,width,seq)`, `grave_hands(x,z,r,count,dur)`, `bone_orbit({..., fallbackTex, fallbackColor, funnel})`
- `Vfx.light_flash(Vector3, Color, intensity, life)` (one shared OmniLight3D; Binbun one-shots call it for their first light)
- `Vfx.particle_scale`, `Vfx.role` ("self"|"other"), `transient_load()`, `active_hand_fields()`
- `Vfx.prims.set_crowd(crowd)` (`DmEnemyFx` gives the decals the crowd whose bodies they may follow), `Vfx.prims.warm_shots(at)` (the loading screen, `DmNextWarmup`: one shot of each kind and a beam, so they compile before the first cast)
- `Vfx.motifs.bone_splinters(x, y, z, {n, speed, color, origin})`, `grave_dirt`, `soul_motes`, `rot_spores`, `mist_whisper`, `skull_wisps`, `skull_ring`, `spirit_wisps`, `spectral_hands`, `cracked_ground`, `slash_mark` (`origin:"thrall"` quiets them; budgets and Low / reduced-motion gates apply)

Colours: `DmFxData.spell("miasma", "rot")` is `SPELL_FX.miasma.rot` (from `fx_data.json`);
`DmFxData.spell_group("miasma")` returns the whole group; `DmFxData.preset(id)` the FX_PRESETS entry.

## Flipbook sheets
Animated sprite sheets from a licensed pack (ASSET_PIPELINE.md "Flipbook sheets"): greyscale intensity grids at
`assets/fx/sheets/<id>.png`, **not in git**. `bash tools/godot/fx-sheets-sync.sh` copies them in from `~/death-muffin/private/fx-sheets/` (run it once in a new worktree; client/tools/ASSETS.md); the client publish's prepare step (`server/death-muffin/test-channel/prepare-rebuild.sh`) runs it
and fails if one is missing. A build made without the private folder (CI) has no sheets and draws the plain look.
- Grid, frames, fps, loop: `fx_data.json` `sheets`, read by `DmFxData.sheet(id)`. Use the id as a texture name: `Vfx.flash({"tex": "hit_flash", ...})`
  plays the frames once over the flash's life at full size (fades the last quarter); `Vfx.decal({"tex": "summon_circle", ...})` plays once or,
  for a looping sheet, loops at its fps. Same layers and caps as other textures; the frame is `INSTANCE_CUSTOM.z`; the sheet shaders tint by the
  instance colour and run the brightest pixels to white.
- Callers check `DmFxTex.has_sheet(id)` and keep their old look without it (`DmRiteFx.hit_flash`).
- In use: `hit_flash` (Bone Needle, pierce, Scythe hits), `crit_burst` (crits), `summon_circle` (under an exhumed corpse), `chain_arc`
  (Contagion thread, lying flat between the two bodies), `trail_arc` (the thrown scythe's spin), `crush_slam` (under Soul Burst). Warmed with the other layers on the loading screen.

## Caps and budgets (`fx_data.json` `caps`)
24 live one-shots (oldest evicted), 32 loopers (extras dropped), 160 combat transients (persistent decals excluded; decals and the other kinds count together and the oldest leaves first),
3500 additive + 900 smoke motes, 1 shared flash light, a pool of 8 built instances per id, Low = 0.75 of every burst and no Binbun/motifs, motif budget 240 particles + 14 sprites,
partner effects at 0.35 alpha / 0.75 scale.

## Hot-path notes
- `DmFxRing` owns two MultiMeshes per ring, both allocated once (full size and 256 motes, never resized). While <= 256 motes are live only the small one is drawn and uploaded
  (`MultiMesh.buffer` must be the whole buffer, so the 3500-mote ring cost 224 KB per frame even for a handful of motes); only visibility switches. The motes' random starts and their per-frame loop are
  `DmMotes` (C++).
- Ground decals are records in `DmDecals` (C++): it ages, shapes and places them and writes each layer's instance buffer; `DmFxLayer` keeps the MultiMesh and its node (`show_count`, `grow`). `DmFxLayer.flush` still runs one loop per layer kind for the other kinds.
- `Vfx.binbun` moves an effect's root only when it moved, tests a looping effect against the camera every third frame, and pushes fade and gain to its shaders only when they changed.
- `_update_spikes` returns early (hiding once) when there are none.

## Native vs approximated
- Binbun scenes are real Godot resources (original ParticleProcessMaterials, meshes, curves, AnimationPlayer libraries, gdshaders). Two hooks
  are injected at the end of every spatial fragment shader that writes ALPHA: `dm_fade` and `dm_gain`; a shader that reads its particle's `COLOR` gets a patched copy that reads it
  converted for Forward+ (`dm_COLOR`, one copy a shader).
- Motes/billboards are MultiMesh billboards. Pack OmniLight3Ds, AudioStreamPlayer3D and shadow-only emitters are dropped. World kits
  (`world_*` .tres/.tscn in `client/assets/fx/binbun/`) are resources only, not spawnable.

## Renderer notes
The effects were built and checked on the Compatibility renderer; the game runs Forward+ since 2026-10-18 (Compatibility is only the fallback). Known from the Compatibility days and not re-checked
on Forward+ on a graphics card: the portals (`area_gate`, `waystone_portal`, `recall_portal`) were drawn as a clipped quad because that renderer has no stencil, though their shaders carry stencil writes;
fourteen Binbun shaders fade near surfaces with the depth texture (`proximity_fade`), which that renderer could not give; ten dither their alpha, which read noisy at 1080p on hero effects;
GPUParticles3D trails and sub-emitters were unsupported (fire sparks render as plain streaks); float uniforms must be written as floats (an int Variant reads as 0).

## The effects

The effects are `Vfx` (`fx/`, `DmFxRuntime`): ground decals, the two particle rings, the Binbun scenes, flashes, beams, projectiles. What grows with the number of them on screen is done in C++; the rest is GDScript.

- **Particles** (`DmMotes`, native/README.md "Files"): a ring's motes, the random start of every mote of a burst and the per-frame loop. `DmFxRing.emit` hands the options over; the numbers come from the global generator in a fixed order, so a seeded run gives the same motes. `tests/fx_motes.gd` holds the ring's buffer float for float (bursts in every colour form).
- **Ground decals** (`DmDecals`): a decal is a record in C++, not two GDScript objects. `DmFxPrims.decal` works out what it is made of (its layer, tint, whether it settles into an outline) and hands it over; C++ ages it, shapes it (growth, spin, pulse, fades, the outline that comes up after 0.6 s and the ring a settling disc brings with it, a flipbook's frame), places it (a decal that follows a body gives its id as `follow_body`, which C++ asks the crowd for; one with a `follow` callable calls it as before) and writes each layer's instance buffer and gives it to the RenderingServer. `DmFxLayer` keeps the MultiMesh and its node (`show_count`, `grow`). The cap of 160 combat transients counts decals and the other kinds together and the oldest leaves first. `tests/fx_decals.gd` holds every drawn float, the counts and the handles over two seeded runs and the cap; `tests/rites.gd` checks a decal that follows a thrall by id.
- **Binbun scenes** (`fx/dm_fx_binbun.gd`): an effect's root is moved only when it moved (every move walks the effect's subtree), a looping effect is tested against the camera every third frame (the test keeps 4 m of margin past the frustum) and 8 idle instances per effect are kept (it was 4), so a salvo of bonfires more often finds instances waiting than builds them from the scene.
- **The enemies' effects** (`DmEnemyFx`): the ambient tick (every 0.2 s) reads the bodies' places from one read of the core's bulk arrays (`enemy_ids`, `enemy_positions`) instead of a record each, and the Pyre's colours are read once. `DmCoreHost.foes_in_radius` (every rite's query) takes one call of the core (`DmCore.foes_in_radius`, ten numbers a body) where it took a record and a snapshot each (19 us a body).

Costs on the VPS (headless, cold: one call in the middle of a Full Party frame): the decals' step with 140 alive 0.04 ms (the GDScript it replaced 0.55), the Pyre's whole effects layer 0.40 ms (1.27), the Graves' 0.16 (0.61), the Pyre's ambient tick 0.86 ms every 12th frame (2.7 ms before), a Plague Saint's look at her doctors 0.09 ms a tick (0.3), a rite's query over 40 foes 0.25 ms (0.45 to 0.9).

## Gallery and tests
- `godot --path client res://fx/gallery.tscn` (Left/Right page, R replay). Args after `--`: `--page=N --per=16 --out=file.png --t=0.6[,1.2] --ids=a,b --kind=binbun|prims --gain=1.0`.
- `client/tests/fx_motes.gd` (the particle ring: every float of its buffer) and `client/tests/fx_decals.gd` (the decals: every drawn float, the counts, the handles and the cap of 160);
  `client/tests/dressing.gd` holds the Binbun shaders' colour.

## Known gaps
KNOWN-GAPS.md "Performance" (pooled MultiMeshes with no instance, decals one draw call each, `DmFxBinbun.update` walking every live effect).
