# Blender jobs (movement and edits on models the game has)

Blender runs here, in your sandbox, for free (no credits, no keys, no approval to spend), in seconds. It is the DEFAULT for anything about how a model
moves or a change to a model that exists; a brand-new model (a new shape) is made from a picture (`.dm-guides/models.md`), never for a move or an edit
Blender can make (DECISIONS B74).
- **A move** a creature lacks or does badly (walk, run, idle, an attack, a flinch or a death, feet that slide, a hitch where a loop restarts): Blender.
- **An edit** to a model: another colour, a bigger or smaller part (head, horns, claws), a part taken off (tail, horn, cape), fewer triangles: Blender.
- **A new model** (`.dm-guides/models.md`): Pixal3D makes its shape and paint on a team PC; Blender builds its game mesh and skeleton
  (`make-model.sh`), then its moves here after `build-art.sh` (a `motion` recipe, library moves, loops, names).
- What Blender cannot do, say plainly and offer the next best thing: a new silhouette or new armour on the body, a new texture design (a recolour is
  not one), facial expressions. Those are a new model (a new picture) or a human animator.

**Which tool for a move.** Run `inspect` first (below): it lists the model's bones and clips.
- Two-legged on the shared Tripo biped skeleton (bones `Hip`, `Waist`, `Spine01`, `L_Upperarm`, ...; heroes, the thrall, ghouls, NPCs): `retarget` moves from
  the free library (`library` lists its 43: sword and punch attacks, spell casts, hits, deaths, rolls, walks, runs, idles). Record it (end of this guide).
  A new two-legged body with no moves (a Pixal model rigged `biped`, `.dm-guides/models.md`) takes the heroes' whole move set in one step:
  `{"kind": "retarget", "from": "hero_gravecaller"}` (every clip of that hero, the `_staff` clips too, at the game's timings).
- Four-legged, many-legged or winged: `motion`, from the model's recipe `tools/blender/recipes/<model>.json`: walk, run and idle cycles, and one-shots (a bite, a
  flinch, a death: type `once`; the bone hound's, cinderhound's and skull rat's recipes have all three). Without a recipe, write it: `docs/BLENDER-PIPELINE.md`
  "`procedural` and recipes" and the closest existing recipe; bone names and positions from `inspect`. When the rig lacks the bones a leg or tail needs,
  add a `rigfix` section ("`rigfix`" there) and run `rigfix` before `motion`.
- A clip that exists but slides, drifts or hitches: `cleanup` (`loop`, `drift`, `footLock`). A walk that drifts wants `drift` and `loop` together.
- Wrong or extra clip names: `clips` (rename, drop). The game plays clips by name (`client/game/README.md`).
- The four discipline heroes (`hero_ossuary`, `hero_gravecaller`, `hero_mourner`, `hero_rotweaver`) play `<clip>_staff` instead of the clips in
  `tools/blender/recipes/staff.json` while they hold a staff (the default staff too). A job that changes one of those clips on them ends with a
  `staff` step for it (`{"kind": "staff", "clips": ["run"]}`), or the game keeps the old move; its preview shows the staff in hand, the plain
  clip above the re-bake, and takes a few minutes. Never drop or rename a `_staff` clip.

**A job.** Read `tools/blender/kinds.json` (every kind, what it does, its parameters and limits) before writing one. Write `.dm-blender.json` in the
worktree root (git ignores it; never commit it):

```json
{"model": "barrow_ghoul", "note": "a sword swing for its third attack, and a walk that stops sliding",
 "steps": [{"kind": "retarget", "clips": {"Sword_Attack": {"name": "attack3"}}},
           {"kind": "cleanup", "clip": "walk", "loop": true, "drift": true}]}
```

`model` is a folder of `client/assets/slice/models/` or `prop_<name>` (a prop: `recolor` and `decimate` only). 1 to 8 steps, done in order on the result
of the one before. Then run `__TOOLS__/blender-job.sh` (no arguments, one call, foreground; about 10 to 60 seconds). A job of only `inspect` or `library`
changes nothing: run one first to read the bones, then write the real job.

**What it prints.** `STEP n kind: ...` per step; `CLIPS` (the model's clips after the job), `STRIDE` (walk/run speed in body heights per second),
`TIMINGS` (`[length, second the blow lands]` for attack and cast clips), `NOTE`s, and `CHANGED`: the files it wrote. It updates the model's rows itself
(`client/game/view_models.json`, `client/data/slice/*.json`: clip list, strides, timings) and records the steps in `art-manifest/blender/<model>.json`
(`build-art.sh` does them again when the model is rebuilt). `FAILED: ...` means nothing was written: read the reason, fix the job, run it again. "bone
... moved in Blender" or "breaks the model rules" means the edit went too far for the model's clips or limits: make it smaller.

**Check it.** The job writes a preview, `.dm-shots/blender-<model>.png`: the clips it touched in motion (six moments each) or, for an edit, the model
before and after from three sides. Read it; the runner posts it in the thread after your turn. Look for feet through the floor, limbs bending the wrong
way, a body that slides, torn or stretched mesh. If it came out wrong, say so plainly and try again (smaller numbers, another library clip) rather than
propose it. With a team PC online, also write a model clip (`.dm-guides/clips.md` "Model clips") so the move is seen in the game's lighting and speed:
the runner builds your branch, so the clip shows the model as you changed it, e.g. a walk across the floor and a turn round:
`{"plan": {"discipline": "gravecaller", "clips": [{"name": "walk", "model": "<id>", "anim": "walk", "move": true}, {"name": "turn", "model": "<id>", "camera": "turntable"}]}, "variants": [{"label": "now", "title": "the new walk", "tune": {}}]}`.

**Commit.** Every file `CHANGED` names (the model's `.glb`, its rows, the record). A recolour renames the texture: the job deletes the old extracted
`.webp` and its `.import`; run `__TOOLS__/check-godot.sh --rerun code_load` so Godot extracts the new one, and commit the new pair and the deletions
(`agit add` the deleted paths). A move from the library: add the model to the "Used for" column of `docs/ANIMATION-SOURCES.md` (its record names each
source clip). A changed model is sent to every player with the next art download and its rows are review-sensitive: put all of a request's model
changes in one proposal, and say in it which creature changed and how it looks or moves now.

Never edit `tools/blender/` or `tools/ai/` for a request; a recipe under `tools/blender/recipes/` is the exception (it is the model's motion source).
**The game's side:** how the client takes in models and clips is `client/tools/ASSETS.md`, and how creatures look and move is `client/game/README.md`.
