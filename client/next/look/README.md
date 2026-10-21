# The look on Forward+

How the game keeps the old game's look on Forward+: the colour conversions, the exposure lift and what still differs (`client/next/look/`: `DmCompatAlbedo`, the area converter's tint table).

The old game ran the Compatibility renderer; this one runs Forward+. The same scene, lights and numbers look different, and the first test builds looked darker and purpler, with big beige pools under every flame and white blobs of glow, than the old game's blue-lit stone.
The game matches the old look by making Forward+ do what Compatibility did where it shows, so the lights keep their numbers (DECISIONS B48). `client/tools/look_probe.gd` measured the differences (2026-10-17, Ultra, the VPS's software renderers, the same camera in the Chapterhouse, the Hollow Graves and the Ossuary,
plus calibration scenes: a grey plane under one light kind at a time). What it found and what the game does about it:

| What | Compatibility (the old game) | Forward+ | In the game |
|---|---|---|---|
| ambient, moon, rim, prop lights, fog, specular on a plane | the same pixel as Forward+ to within 1 | the same pixel as Compatibility's to within 1 | nothing to change |
| a vertex colour (a light pool's 0.25 / 0.17 / 0.09, a particle's colour, a gear mote) | read as sRGB: the pool's centre (82, 49, 24) | read as linear: (203, 175, 130), 9 times the light | `vertex_color_is_srgb` on the pools (`build_area._light_pools`, `DmWorldBuilder._light_pools`), the gear motes (`DmGearFx`) and the Binbun particles' materials (`DmFxBinbun`): (79, 48, 24) |
| a colour an effect's shader writes to `ALBEDO` (`COLOR.rgb` of the Fx layer, the world mist and particles) | converted from sRGB after the shader multiplied it | taken as linear | the shaders convert it (`dm_srgb` in `DmFxTex`, `DmWfxParticles`, `DmWfxMist`): (191, 155, 114) for Compatibility's (191, 156, 114) |
| a tinted dark texture (every floor, every wall, the gate posts) | tint x texel multiplied in sRGB, the product converted once | each converted, then multiplied: 1.04 to 1.6 times darker | the area converter lifts the tint by the measured ratio (`DmCompatAlbedo`, `client/next/look/`): the Graves' ground tint 0.72 / 0.67 / 0.72 becomes 0.80 / 0.77 / 0.81 |
| the glow of a very bright thing (an HDR quad of albedo 2 and a small emission of energy 6 on a dark plane, the glow part of the probe, 1280x720, red channel every 6 px past the edge) | 247, 189, 103, 41, 15, then the background at 30 px (the quad's edge pixel 62 of 255) | five mips: 255, 255, 251, 232, 213, 191 ... still 88 at 66 px | `DmWfxBloom`: the two finest mips at 0.8 of the web game's strength: 255, 210, 104, 15, nothing at 24 px; threshold 0.85, scale 2 and cap 12 as the web game's |
| a Binbun scene's own shader reading its particle's `COLOR` (`.rgb` as a colour or a mask offset) | the vertex colour converted from sRGB | taken as it is | `DmFxBinbun` reads it through a patched copy of each such shader (`dm_COLOR`: rgb converted, alpha as it is) |
| what a creature's shader writes to `EMISSION` and the tint it multiplies into `ALBEDO` (the hero's accent emissive 0.04 x the accent, the friend rim, the gear tints, a tinted body, the hit flash: all `lin()` of a hex) | `emission = srgb_to_linear(emission)` and the albedo product converted once, in `scene.glsl` (a small glow is a twelfth of itself; the glTF's colour and the texel are read raw) | taken as linear: the accent emissive doubled the hero's robe, the lilac look | `DmCreatureMat` and the crowd's shader multiply in Compatibility's numbers and convert like it (`dm_s2l`, `dm_l2s`): the hero's robe (the Graves, Y of a 24 px box) 59.2 before the fix, 43.2 without the emissive, 33.6 with the lift divided out as well |
| the exposure lift of an area on a thing that is not in the lightmap (a creature, an effect) | none: the plain exposure | the lift multiplies everything the tonemapper sees, 0.8 to 2.1 times | the shaders divide it out (`dm_lift_inv`, a global: 1 / (the lift x the preset's), set with the exposure): the lift is the baked world's calibration, not theirs |
| the beyond the walls | one 420 m field of grave soil under the fog (196 tiles); the background colour past it, (7, 6, 10) | nothing drawn: black, (1, 1, 3) through the tonemapper | the field as one quad (`DmWorldBuilder.build_outside`, the soil's tint lifted by `DmCompatAlbedo`); the background colour past it is never in view (the field reaches 80 m past every area) and stays black |

**The lift of each area** (2026-10-17, on the lighting bake of all twelve areas, e8ce4fd9; Ultra, 1280x720, the mean luminance of the world region, the probe's WSTAT line: x .12 to .78 and y .1 to .72 of the frame, the hero's box left out). One lift for the whole game did not fit: at 1.2 the Chapterhouse was 18 % darker than the old game's,
the Alchemist Wing 29 % darker and the Acre 3 % brighter, because every area's bake carries its own share of the light. So the lift is a number per area (`DmWorldBuilder.AREA_LIFT`, asserted by `tests/presets.gd`), solved from each area's own response: the probe shot every area at lifts of 1.1, 1.5 and 2.0
(`--plan="<area>:lift=1.1,lift=1.5,lift=2.0"`), a curve through the three points in log-log gave the lift that reaches the old game's mean, and a run at the table (`base`, two frames each) measured the result. The response is not one power of the lift: the mean rises as lift^0.75 to lift^0.9 in the dark areas
and lift^0.6 in the bright ones (the Wing and the Coliseum, where the tonemapper presses the highlights).

| area | the old game's mean (the target) | lift | the game's mean at the lift |
|---|---|---|---|
| Chapterhouse | 45.3 | 1.52 | 45.4 (+0.2 %) |
| Acre | 52.0 | 1.11 | 52.1 (+0.2 %) |
| Alchemist Wing | 124.1 | 2.08 | 124.2 (+0.1 %) |
| Graves | 37.4 | 1.35 | 37.6 (+0.5 %) |
| Warren | 34.1 | 1.35 | 34.1 (+0.0 %) |
| Ossuary | 40.5 | 1.38 | 39.0 to 42.2 (-3.7 to +4.2 %, see below) |
| Nave | 36.2 | 1.33 | 36.3 (+0.3 %) |
| Coliseum | 127.8 | 1.80 | 127.6 (-0.2 %) |
| Sanctum | 48.7 | 1.36 | 48.7 (+0.0 %) |
| Cloister | 52.8 | 1.37 | 53.1 (+0.6 %) |
| Pyre | 57.8 | 1.34 | 57.8 (+0.0 %) |
| Fen | 44.5 | 0.80 | 44.7 (+0.4 %) |

Eleven areas are within 0.6 % of the target, inside the noise of the measurement: the old game's own frames repeat to 1.5 % between runs, two frames of one visit differ by 0.3 % at most, and a second visit to the Chapterhouse, the Graves, the
Wing and the Acre (in a different order of visits) repeated the numbers to 0.1 % (the Acre to 1.9 %). The Ossuary is the exception: its ground mist drifts across the frame and is part of the mean, so a visit early in a run read 43.8 at a lift of 1.44 and 37.3 at 1.2, a later one 40.5 at 1.44 (the lift that matches the early visit is 1.33, the late one 1.44); the table's 1.38
centres them (the curve's numbers, not a run at 1.38: 39.0 and 42.2). The numbers are for Ultra on the software renderers; Medium, High and Low share them (`DmGraphicsPreset`'s own factor, 1, Low 0.96, is not measured), and the Depths, which the probe cannot stand in, keep the old 1.2 (`LIFT_DEFAULT`).
A number here is a calibration: measure again with the probe before changing it.

The lift is on top of the exposure (the world's number, the area's easing, the Settings brightness). It is a property of the area, not of the preset: `DmWorldBuilder.set_area` (what the world's `enter_area` calls when the hero crosses into another area) sets the target and eases to it over
0.8 s (`LIFT_BLEND`, smoothstep, together with the area's own exposure easing, so a door is not a pop of brightness; a change of ambient at a door is instant); `_process` runs only during the blend and switches itself off, so a frame outside a blend costs nothing, and the first area is set at once.

**The unbaked things** (the hero, the creatures, the effects) are lit by the real-time lights alone, not by the lightmap, and the first table of the lifts left them 1.3 to 2.5 times the old game's in seven areas and the hero lilac. Two causes, found with the probe's `HSTAT` line (the mean of a 24 x 24 px box on the hero's
robe, the same box on both sides) and its hero variants (`hnoemis`, `noamb`, `nomoon`, `norim`, `noshadow`, `noprops`, `nossao`, `hnolantern`, `hgear`): **the colours** (the table above: Compatibility converts what a shader writes to `EMISSION` and the albedo product once, so the hero's accent emissive,
0.04 of the accent, is a twelfth of itself on Compatibility's side and was most of the robe's brightness here: the Graves' robe 59.2 before the fix, 43.2 with the emissive off, and the lilac gone) and **the lift** (an exposure multiplier calibrated on the baked world is an exposure multiplier on a creature too: the robe falls to 33.6 with the lift divided out of its albedo, specular
and emission; an effect gets the same, `DmFxTex`). The global `dm_lift_inv` is 1 / (the area's lift x the preset's), set by `DmWorldBuilder._apply_exposure`, so it eases with the blend; a shader reads it for nothing per frame. Bloom, ambient occlusion, the moon's shadow and the prop lights were tried and are not the cause (the robe's box without bloom 58.5 against 59.2, without
ambient occlusion 33.8 against 33.6, without the moon's shadow 34.5 against 34.2, with the prop lights off 33.2 against 34.2; the moon is half of the robe's light, the ambient a sixth, the lantern a sixth).

The robe after both changes reads 1.1 to 1.4 times the old game's in the dark areas (the Graves, the Nave, the Warren, the Sanctum; it was 2.0 to 2.5), within 15 % in the Acre and the Fen, and 0.56 to 0.74 of it in the bright ones (the Wing, the Coliseum, the Cloister, the Pyre): the hero is darker there than before and than the old game's. Not explained, and not guessed
at with a table: the box is one pose, the old game's own frames differ by a third between runs (the Graves' box was 23.9, 33.0 and 34.9 in three runs), and the part Compatibility's bloom plays is not here (the old game's box without bloom is 27.3 against 34.9 in the Graves and 58.0 against 85.7 in the Chapterhouse, the game's box without bloom is within 2 %: the glow is calibrated on bright things, `DmWfxBloom`, and not on the halo of a ring and a staff light
on a robe). The crowd is the same material (`crowd_vat.gdshader`) and takes the same two changes; it was not drawn in the probe's frames (a rendered fight on the VPS outran the run's timeout), `tests/crowd_look_smoke.gd` is its check.

**The hero's ring and the contact shadow.** The old game's ring is thin (a half-height width of 4 to 6 px at 1280 x 720) with a peak of 169 to 224 in the dark areas; here it was 8 to 9 px wide and 244 to 255 (white, flat on top) in every area. Not the bloom (the profile without it is the same row for row: 255 against 255, 9 px), not the lift (245 and 8 to 9 px at a
lift of 1.0). `scene.glsl` shows where it comes from: Compatibility writes the exposed scene as `linear_to_srgb(radiance x exposure)` into its buffer before the post effects, so a translucent decal blends in that encoded space (its faint flanks lose most), Forward+ blends in linear light. The decal's own numbers
are unchanged (`tests/fx_decals.gd` holds them float for float), so the hero's decals are drawn at the strength that gives the old peak: the ring decals at `DmHeroLook.RING_K` = 0.4 of their opacity and the contact shadow at `SHADOW_A` = 0.75 (the old 0.5). Measured against the Graves, the Sanctum, the Warren and the Nave in the probe's `ring=K/S` variants (K 0.2 to 0.5, S 0.5 to 0.9): the peak is
195, 190, 203 and 187 against the old game's 195 to 221, 200, 224 and 169, the pool inside the ring (the mean of the 8 to 20 px inside) 44 against 45 to 50 in the Graves; the width stays 7 px against 5 (6 at a fifth of the opacity), which only the blend would change. Every other blended effect keeps its linear blend: wider and whiter than the old game's by the same measure ("Still different" below).

The Fen is the other way round: its baked ground is brighter than the old game's even at a lift of 1.1 (the mean 57.0 against 44.5, the darkest tenth 26 against 15), so the lift that matches the mean is 0.80, which leaves the ground's shadows lighter than the old game's (its hero is 0.87). All of this wants Helix's eye on his PC; what is left is the look pass (KNOWN-GAPS "Look").

**Still different** (the look pass on the ROADMAP's polish list): the Depths' walls keep Forward+'s darker tint (its floor is lifted, `DmWorldBuilder._floor_mat`) and the Depths' lift is 1.2; Low and Medium: the old renderer drew blended effects in sRGB space when bloom is off (an alpha sprite half-way over black: 131, with bloom on 205), Forward+ always blends
in linear light, and at Ultra too the old game's ring is thinner and dimmer than a linear blend of its decal ("The hero's ring and the contact shadow"): only the hero's ring and shadow are scaled to it, every other blended effect (the rites' decals, the telegraphs, the particles) is wider and brighter here than there;
the gear props' emission (`StandardMaterial3D` with an energy: Compatibility converts the colour times the energy, Forward+ the colour) and the Binbun scenes' own shaders that write `EMISSION` are the same class as the creatures' and not converted, and the staff's light sprite takes the lift. The Chapterhouse's floor carries the candles' light in its bake (warm pools by every candle).

The probe starts the real game scene at a fixed spot of each area and shoots variants of its light (`--plan`; `lift=1.5` shoots at that exposure lift in place of the area's, which is how the table above was found; `nodress` takes the world dressing off, `before` is the look of the first test builds: no dressing, a sphere at every light, the five-mip glow;
the hero's box has its own `HSTAT` line and the hero variants are `hnoemis`, `hnogear`, `hnolantern`, `hgear`, `noamb`, `noprops`, `nossao`, `ring=K/S` and `crowd`, see the script's header), the glow part (`--part=glow --glow="name:lv=a/b,int=..;..."`) prints the glow's profile of two bright things under each setting of a list, and the calibration part prints one pixel line per test object. It runs on the VPS
under the renderer lock, one run at a time (the header of the script has the commands; a start takes half a minute). It is not a pass/fail suite: the checked
values are `tests/areas.gd` (the pools' flag, the tint table against its textures) and `tests/presets.gd` (the twelve lifts, the blend, the environment and what the lift leaves alone). `client/tools/compat_albedo.gd` prints the tint
table of `DmCompatAlbedo`.
