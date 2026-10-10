# godot/fx: Vfx, the visual effects runtime

Autoload `Vfx` (`project.godot`: `Vfx="*res://fx/dm_fx.gd"`, script class `DmFxRuntime`). Two layers:
- **Binbun scenes**: 64 native Godot scenes in `assets/fx/binbun/<id>.tscn` (GPUParticles3D, ShaderMaterial, AnimationPlayer), played with
  spawn colours, pooled per id. `fx/dm_fx_binbun.gd`; `dm_fx_controller.gd` / `dm_fx_light.gd` / `dm_fx_rect.gd` replace the vendor scripts.
- **Procedural primitives and motifs**: rings of motes, decals, flashes, orbits, beams, projectiles, spikes, hands (`dm_fx_prims.gd`,
  `dm_fx_ring.gd`, `dm_fx_motes.gd`, `dm_fx_layer.gd`) and the necromantic motifs (`dm_fx_motifs.gd`).
Tables (spell colours, presets, caps, catalog) are in `assets/fx/fx_data.json`, read through `DmFxData`.

## Wiring
- Callers: `DmRiteFx`, `next/enemy_fx`, `next/bosses/dm_boss_fx.gd`, `next/corpses`, `next/thralls`, `next/affixes`, `next/status` and others call `Vfx.*`.
- Quality is set by `next/perf/dm_next_perf.gd` from the graphics preset: `Vfx.quality = "high"|"low"` (Low: no Binbun, bursts thinned to 75 %,
  motifs off), `Vfx.binbun.enabled`. Also `Vfx.reduced_motion` and `Vfx.hitstop_scale`.
- A Camera3D must exist: loopers are culled by distance (40 m + camera height) and frustum.
- Effects are emission-heavy; the world uses a WorldEnvironment with glow. `Vfx.binbun.gain = 0.5` tones down blown cores.
- Decal render order = `render_priority` (friendly 2, hero 3, danger 4, particles 5, sprites/Binbun/beams 6). Do not give world transparent materials above 1.
- After adding a `class_name`, run `godot --headless --path godot --import` once.
- Regenerating Binbun scenes: `tools/godot/fx-binbun-rebuild.ts`, `fx-sync-models.mjs` (needs the private vendor packs, not in git).

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
- `Vfx.decal({tex:"disc", color, x, z, r, y, rot, duration, opacity, fadeIn, fadeOut, growFrom, spin, blending:"add"|"mix", sx, sz, anchor, follow, pulse, delay, persistent, danger, hero, other})` (camelCase keys)
- `Vfx.danger(func(): ...)`
- `Vfx.flash({x,y,z,color,size,duration,tex,rise,opacity})` / `Vfx.orbit({tex,color,count,radius,y,size,duration,speed,follow})`
- `Vfx.beam(a: Vector3 | Callable, b: Callable, color, width, duration)`
- `Vfx.projectile({from, to: Callable, speed, color, kind:"needle"|"orb"|"sprite", tex, size, arc, on_arrive: Callable(Vector3), on_trail: Callable(Vector3)})` -> ref with `pos()` (null once landed)
- `spike_ring(x,z,r,count,life)`, `spike_line(x,z,dx,dz,len,width,seq)`, `grave_hands(x,z,r,count,dur)`, `bone_orbit({..., fallbackTex, fallbackColor, funnel})`
- `Vfx.light_flash(Vector3, Color, intensity, life)` (one shared OmniLight3D; Binbun one-shots call it for their first light)
- `Vfx.particle_scale`, `Vfx.role` ("self"|"other"), `transient_load()`, `active_hand_fields()`
- `Vfx.motifs.bone_splinters(x, y, z, {n, speed, color, origin})`, `grave_dirt`, `soul_motes`, `rot_spores`, `mist_whisper`, `skull_wisps`, `skull_ring`, `spirit_wisps`, `spectral_hands`, `cracked_ground`, `slash_mark` (`origin:"thrall"` quiets them; budgets and Low / reduced-motion gates apply)

Colours: `DmFxData.spell("miasma", "rot")` is `SPELL_FX.miasma.rot` (from `assets/fx/fx_data.json`);
`DmFxData.spell_group("miasma")` returns the whole group; `DmFxData.preset(id)` the FX_PRESETS entry.

## Caps and budgets (pinned by `tests/fx/run.gd`)
24 live one-shots (oldest evicted), 32 loopers (extras dropped), 160 combat transients (persistent decals excluded), 3500 additive + 900 smoke
motes, 1 shared flash light, pool of 4 built instances per id, Low = 0.75 of every burst and no Binbun/motifs, motif budget 240 particles +
14 sprites, partner effects at 0.35 alpha / 0.75 scale.

## Mote rings
- Additive ring (3500): `DmFxRing` over `DmFxMotes`, simulated in the vertex shader. The CPU writes a mote once, at spawn (velocity, gravity, drag,
  shrink, size, life and spawn clock packed in its 16-float instance slot); the shader evaluates drag / gravity as the closed form of the mote's age
  (the continuous limit of the web's per-step update), so there is no per-frame loop; a frame costs a clock uniform plus, in frames that spawned, one
  upload of the slots in use. Order does not matter when adding. Smoke ring (900, normal blend): CPU ring, oldest drawn first, as before; its
  instance buffer is sized to the live motes (256-steps) and only that slice is uploaded.
- `set_limit` / `DmFxPrims.set_mote_share`: graphics preset `motes` share of the caps (Low 0.4, Medium 0.7, High / Ultra 1.0), set by `DmNextPerf.apply`.
- Probes: `tests/perf/fx_particles_probe.gd` (ms and upload bytes at 500 / 2000 / 3500 live), `tests/perf/fx_mote_shot.gd` (seeded rendered fight).

## Native vs approximated
- Binbun scenes are real Godot resources (original ParticleProcessMaterials, meshes, curves, AnimationPlayer libraries, gdshaders). Two hooks
  are injected at the end of every spatial fragment shader that writes ALPHA: `dm_fade` and `dm_gain`.
- Motes/billboards are MultiMesh billboards. Pack OmniLight3Ds, AudioStreamPlayer3D and shadow-only emitters are dropped. World kits
  (`world_*` .tres/.tscn in `assets/fx/binbun/`) are resources only, not spawnable.

## gl_compatibility limits
All effects compile and render on `gl_compatibility`. Known: no stencil, so portals (`area_gate`, `waystone_portal`, `recall_portal`) draw as a
clipped quad; GPUParticles3D trails/sub-emitters are unsupported (fire sparks render as plain streaks); the pack's glow assumes Forward+
tonemapping; float uniforms must be written as floats (an int Variant reads as 0).

## Gallery and tests
- `godot --path godot res://fx/gallery.tscn` (Left/Right page, R replay). `fx/shoot.sh <page> <out.png> <t1,t2> [--kind=prims] [--ids=a,b]` captures at a fixed 30 fps.
- Test: `godot --headless --path godot --script res://tests/fx/run.gd` (effects instantiate, lengths match the converted JSON, caps hold, rings, roles, motif budget).
- Effect cost evaluation of the vendor packs: `EVAL.md`.

## Known gaps
- No depth soft-particles, no stencil portal window; dithered alpha reads noisy at 1080p on hero effects (`EVAL.md`).
- `tests/fx/` has leftover `load_all.gd.uid` / `smoke_tmp.gd.uid` with no script.
