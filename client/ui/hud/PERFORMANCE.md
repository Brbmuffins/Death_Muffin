# The HUD's budget

What the HUD costs in draw calls and frame time, and how it is kept down. The HUD's view-model and pieces: [README.md](README.md); where each piece reads from: [next/hud/CORE-INTEGRATION.md](../../next/hud/CORE-INTEGRATION.md).

DECISIONS B39: the HUD at most 0.5 ms and 150 draw calls on Helix's PC. The old game's HUD was about 550 draw calls (its benchmark on Compatibility, DECISIONS B50). In Godot 4.7's canvas renderer
(`RendererCanvasRenderRD`) consecutive commands that share a texture and a kind are ONE draw call, and a rendered run measured what is not (Forward+ on lavapipe, 2026-10-16; `tools/hud_measure.gd --micro`):

| drawn with | draw calls |
|---|---|
| rectangles (`draw_rect` filled), any number, in any items; lines (`draw_line`, thick or anti-aliased too) | 1 together |
| icons of one texture or of regions of one atlas, with any colour; 9-patches (`StyleBoxTexture`) of one texture, other regions and colours | 1 together (a different texture, or a rectangle between icons of another texture, starts a new one) |
| glyphs of one font and size, with or without a shadow; a Label with an outline: its outline and its fill | 1 together; 2 for every outlined label (the outline has an atlas of its own) |
| `StyleBoxFlat` panel (fill, border, radius, shadow: any) | 1 each |
| `draw_circle`, `draw_colored_polygon`, `draw_polyline` (3 when anti-aliased), `draw_arc` (3), `draw_rect(filled = false)`, a RichTextLabel, an item with `clip_contents` | 1 each |
| `clip_children` (the minimap's disc) | +2 and its inside as above |
| items with different `z_index` | sorted by z first, then tree order: the same kinds of drawing on one z layer batch even when their controls are far apart in the tree |

What the HUD does with that (`ui/hud/dm_hud_kit.gd` has the layers, `next/hud/dm_hud_atlas.gd` the atlases; the layout, colours, fonts and numbers are unchanged by it):
- **Layers.** Panels (9-patches) z 0, rectangles and icons 1, vector art 2, rectangles over the art 3, text from 4 up (one layer for each font and size), toasts, banner and prompt +100, the floating numbers 200.
  A HUD label is put on its layer when it is made; `DmHudKit.layer_tree` does the rest of a subtree.
- **One atlas.** A runtime atlas holds every icon (ability art is kept at 128 px, shown at 62), a white block (any rectangle), the bars' gradients and, on a page of its own, every panel's 9-patch (`DmHudKit.plate`
  makes a `StyleBoxTexture` of the picture of a `StyleBoxFlat`; `style` still gives the StyleBoxFlat the panels ask for). A greyed slot icon is a baked variant, not a shader.
- **One mesh per widget.** The orbs (2 draws), cooldown sweeps (5 triangles at most), thrall pips and gems (one mesh for the row), the level badge, the minimap's frame, disc and edge fade, its marks and arrow, and the
  death veil are triangle bags (`DmHudMesh`); the minimap's dots are one MultiMesh.
- **Floating numbers are a pool** (`DmHudFloats`): 48 entries of two canvas items made once; a frame only moves them; the numbers of a kind are two draw calls.
- **What drawing it this way changes** is a few pixels, where a shape is drawn another way. Panels and borders are pictures of the same fill, border and rounded corners (`DmHudAtlas.nine`, 16 samples a pixel) instead of `StyleBoxFlat` geometry: identical at the design size, and at other UI scales the 1 px borders and the 2 and 3 px corners
  are filtered a little differently (the hotbar's plate keeps its soft shadow, still a `StyleBoxFlat`). Icons are scaled once, to at most twice the size they are shown at (ability art 256 to 128 px for a 62 px slot, portraits 480x640 to 96x128), with a Lanczos filter. The orbs' liquid body has 20 steps along its arc (0.2 px off the circle) and the surface ripple is a 2 px ribbon with a half pixel feather,
  redrawn 15 times a second while it moves. Cooldown sweeps are exact to the slot's square (a fan of at most five triangles). The minimap's dots are 14-point discs; the area fills, edges and doors are drawn first and the hatching of a sealed area after them; a dead enemy is not a dot while the core still holds its body (4 s); loaded areas count as unlocked and the doors between two loaded areas as open.
  Floating numbers have no 1 px shadow under their 3 px outline (the outline covers it), overlapping numbers draw in pool order rather than oldest first, the thrall and DoT numbers come from the core's damage and DoT events at the enemy's position that tick, and the caps (14 hit, 5 dot, 6 thrall, 22 in all) count in real milliseconds. The target frame reads the core's status bytes (a Withered pile past 255 stacks is read from `status_stacks`;
  a status the HUD has no icon for is not listed). "N slain here" counts every enemy that died in the area this run.

*Measuring.* `client/tools/hud_measure.gd` starts the game scene with the full HUD in a Full Party-like crowd (72 enemies, 32 thralls, numbers kept at their caps), reads
`RenderingServer.get_rendering_info(RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)` and the canvas share of it with the HUD hidden and shown, as the game scene shows it and with every piece on, prints the HUD's CPU cost, and
(`--micro`, `--fidelity`, the breakdown) the cost of each drawing primitive, the pixel difference of each replacement against the original, and each piece alone. It writes one JSON line per measurement as it goes:
```
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1600x900x24" \
  timeout 55 /home/ubuntu/tools/godot/godot --path client --rendering-driver vulkan --resolution 1280x720 --fixed-fps 60 --script res://tools/hud_measure.gd -- --out=<file.jsonl> [--shot=<png>] [--micro] [--fidelity] [--3d]
```
**Status (2026-10-17): measured on Helix's PC** (RTX 4070 SUPER, 2560x1440, the benchmark's render breakdown, the Bell Sanctum's Full Party with the panels in): the HUD row draws 120, 120 and 117 calls on Low, High
and Ultra for 0.03 to 0.05 ms of GPU, and the HUD's share of the main thread is 0.07 ms (eight on/off rounds). The model's 63 to 81 counts the HUD alone; the rendered row also holds the panels' pieces. On this VPS a Forward+ process needs ~21 s to reach its first script line and then ~23 s inside the first main-loop iteration (software
Vulkan pipelines; it does not shrink with drawing switched off), so a 55 s run has about ten seconds left: the table above comes from a bare scene, and the harness runs with a longer limit (`timeout 180 ... --budget=170`) for a look at single widgets.

*The model.* `tests/hud_cost.gd` is a model of the batching rules in the table; `tests/hud.gd` first checks that it reproduces the 18 numbers the rendered run counted for the same trees, then asks it about the HUD in a Full Party fight
(72 enemies, 12 thralls, casts on cooldown, a target with four statuses, toasts, numbers at their caps): 63 draw calls as the game scene shows it (26 text, 10 vector art, 8 floating numbers, 6 toasts and banner, 3 panels, 1 rectangles
and icons, 1 borders) and 81 with every piece on and fed (41 text, 13 art). The test fails above 150, so a control left on the wrong layer or a new polygon per thing shows up in CI. Asked about logged copies of the old game's widgets in the same
fight the model said about 500 for its HUD (the hotbar 188, the minimap column 160, the floating numbers 104, the target frame 18) and 630 with every piece on; the benchmark counted 544 to 564 for it in Compatibility.

*CPU.* The HUD's work on the main thread is of two kinds. **Per frame:** what animates (the orbs' ripple, 15 times a second, the floating numbers, the counsel's card, the cooldown edges and sweeps) and the panel host's clocks
(counsel, guidance, cues). **Per refresh:** the view-model build and its apply, every 50 ms of **wall** time (`DmGameUi.HUD_INTERVAL_MS`, 20 Hz), so a refresh falls on every 12th frame of the VPS's 4 ms headless frame, every 5th
of a 10 ms frame (Helix's 99 fps) and every 3rd at 60 fps. It costs about 1.5 ms in the Full Party fight (the caches cold: 0.4 ms hot in `tests/hud.gd`), which is 0.12 ms a frame on the VPS, 0.3 on a 10 ms frame and 0.5 at 60 fps:
**the VPS's share leaves most of the refresh out**, and Helix's PC pays it in full (measured there on 2026-10-17: 0.07 to 0.08 ms, DECISIONS B50).

The HUD's share on this VPS in the Full Party fight (2026-10-17; `--benchmark --bench-room=graves --bench-size=full_party --bench-class=2`, headless, `--fixed-fps 60`, a new character with its tips):
the benchmark's own HUD readout is eight rounds of half a second (give or take 0.3 to 0.85 on a busy machine), too coarse to tell 0.45 from 0.55: five runs read **0.15 to 0.67 ms (median 0.51)**. The same on/off rounds, seventy of them, in CPU time with the slowest 3 % of frames left out
(give or take 0.1 to 0.15 each) read **0.42 to 0.57 ms** (four runs; 0.37 to 0.63 over every run of the last three versions on a machine with a load of 5 to 15). The rest of the main thread in the same fight is 3.0 to 3.2 ms (5.7 in one busy minute). `tests/hud.gd` hot (three runs): the
refresh's build 0.36 to 0.48 ms, its apply 0.11 to 0.14, and a headless frame with the HUD 0.21 to 0.41 ms over one without.

The rules that keep it there (every `_process`, `_draw` and the refresh's parts timed in a scratch copy of the project, never committed; a call costs two to four times in the game what it costs in a loop,
because the refresh finds its code and data cold):
- **An animation that only changes an alpha is a layer drawn once and faded by `modulate`:** the NEW glow's halo (three on a new character), a hotbar slot's empowered pulse and its cast flash redrew 24 and 16 rectangles every
  frame (0.15 ms of the fight: 80 us for the glows, 65 for the slots' edges); a frame now sets one property for each, and a layer is drawn when it is shown. Same rings, same strength at every instant. The low-health wash
  processes only while it moves.
- **A rite on cooldown changes its seconds and its sweep and nothing else** (`DmHudSlot.apply` compares the slot with the last one natively and takes a short path when only `left_ms` differs).
- **Static art appended to a mesh is moved to its place once per place** (`DmHudMesh.append`): the orbs' gloss and dish were re-indexed by a loop over 1,150 indices at every redraw.
- **Sections:** `DmHud.apply` hashes each section's keys and applies a section that changed. The Kill Chain meter moves with every refresh while a chain runs, and the belt, omen, party and ward shared its section: they are
  sections of their own now, so a moving meter applies none of them (and redraws no belt chip).
- **The panel host asks nothing it can keep:** `panel_open()` (asked by the counsel and by the combat input a dozen times a second) answers from a flag the windows' own visibility changes set; `area_safe()` per area; the
  Ascension guidance asks the Prelate count before it builds a progression and keeps the Swift Seals share and the parsed trophies until their sources change; the belt's chips count the bag in one pass and only when the bag
  was replaced, a pick changed or the vows did (it was thirty passes, 0.2 ms of every refresh); the view-model looks the hero's caster, soul state and rite level up once a refresh; `DmHudKit.commas` keeps the text of the
  numbers it formats.
- **The counsel (a new character's tips: a card up, ten waiting) costs about 80 us of the frame in this fight, a veteran's with the tips seen about half of that:** the first-thrall card asked `hud_state()` whether a thrall lived, a whole view-model
  (a millisecond) every time the line was looked at; it asks the host's `thralls_now()` now. The line is looked at five times a second: a card on screen is only compared with the urgent and danger tips waiting (the only
  ones that can take its place), the clock waits for the earliest timer instead of scanning them every frame, and the poll reads the bosses' summon sites and the doors' rects once. The card's draining line (24 rectangles
  every frame) is drawn once on a canvas item of its own and squeezed by that item's transform (`DmTipCard.show_timer`).
- `tests/hud.gd` pins these (no redraw per frame for a pulse or the line, the strength at every instant, the short path against a full apply, the kept indices, the sections, the counsel's timers), `tests/panels.gd` the flag
  and the guidance, `tests/value.gd` the belt chips against the bag.

What is left by the same timing (us a frame at the VPS's refresh rate): the refresh 100 (its slots 27, minimap dots 17, target frame and party 10, belt 6) and the minimap's draw 22, the orbs 56 (the ripple's mesh at 15 Hz,
60 to 75 us a build), the counsel 80 of which the card 20, floats 17, the panel host's clocks 25, the pulses 15; and about a third of the A/B share is not in any script callback (text shaping and redraws the refresh
starts, and the caches its working set empties for the rest of the frame). Next in line: the minimap's dots and the hotbar's fill in the core (`enemy_ids / enemy_positions / enemy_states` already are its arrays: about
0.25 ms of every refresh, 0.05 ms a frame on a 10 ms frame), and the orbs' ripple.
