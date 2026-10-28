# Screenshots

Pictures come from one of two places, and the message tells you which: a note in square brackets before the request says whether a team PC is online.

**A team PC is online** (the note starts `[A team PC is online right now`; Helix, 2026-10-19: "no need to require !shot"). A team PC (War's, Muffins' or Helix's)
has a real graphics card, so pictures need no `!shot`:
- For every change players can SEE (windows, tooltips, the HUD, the hero's look and gear, how a spell or effect looks, a number shown on screen) write the plan
  to `.dm-shot.json` as described below and do NOT run `__TOOLS__/shot-godot.sh` or render anything yourself. Skip the plan for
  changes nobody can see (logic, data behind the scenes, server work, docs) and for pure Q&A. If someone says to skip pictures, write no plan.
- After your turn the runner builds your branch and a team PC renders the plan: with your proposal (it says "Pictures from a team PC follow"), and also
  when the turn changed nothing ("show me the gate", "a better angle": the open proposal, or the game as it is on your branch). The runner tells the thread
  that pictures are coming or why none came, so never say it yourself and never re-propose to get pictures. Before the thread sees them, a short
  check of yours looks at them against the request: it can ask for one retake with a better plan, and its verdict goes on the pictures (a "✔ Checked"
  or "⚠" line). Still make the plan show exactly the change the first time: the window or hero view that proves it, with `give` / `equip` / `area` set
  up so it appears. Keep it to what the plan format below offers.
- Ask for as few pictures as show the change (Helix, 2026-10-20: "sometimes only 1 high quality screenshot is required"). By default each shot is ONE
  AFTER picture on Ultra, and that is enough for most changes. Ask for more only when it helps people judge the change, or when someone in the thread
  asks for it (words after `!shot` count too):
  - `"before": true` (top of the plan): the unchanged game renders the same plan too, and the thread gets BEFORE and AFTER pairs. Use it when the
    change reworks something that already exists and the difference is easy to miss (a redone window, a new look for existing gear, a resized HUD
    element). Leave it out for something new (a window or item only your change adds cannot be shown BEFORE anyway) and for an obvious change.
  - `"presets": ["low", "ultra"]` (top of the plan; from `low`, `medium`, `high`, `ultra`; default `["ultra"]`): add a lower preset only when the
    change is about lights, shadows, particles or other effects that Low thins out, so people see it still reads there.
- `!shot` still works: with a team PC online the message asks you for a plan only, and the runner sends it for the current change.
- New models and gear: the Blender sheet (`render-model.sh`) is still yours to make and check; their in-game shots are a plan like any other (the pictures
  follow the proposal, so check fit and scale from the sheet).

**No team PC is online** (the note says so): the rules below apply, with the server rendering on request.

Only when asked (Helix, 2026-10-12: "the agent should ask if a screenshot is required before attempting one"). Renders share one renderer on
the VPS and can wait many minutes behind other work, so:
- Do NOT take screenshots by default, not even for visible changes. Propose without them; every proposal without pictures tells people they
  can say `!shot` to get screenshots of the change.
- Take them when the request asks for a picture ("show me", "screenshot", "what does it look like") or someone says `!shot`. If someone says to
  skip screenshots, never take any in that thread.
- When unsure whether a picture is needed for a visible change, do not render: finish, propose, and the `!shot` offer covers it.
- Exception: new models and gear always get their render sheet and in-game shots (`.dm-guides/models.md`, steps 3 and 4).
- Never more than 4 shots, and do not retake them without a reason. Check each with Read and fix what looks wrong.
- A picture is a preview: it shows the offline demo character on this branch (a fixed demo bag), not the live game and not anyone's character.
  Each image has "BRANCH PREVIEW · not live" burned in. Say "preview" when you mention one; never describe it as live or shipped.
- If the change is not visible through the windows below (a world or combat visual), say you could not show it rather than guess.

How: write the plan to `.dm-shot.json` in the worktree root (never commit it, nor `.dm-shots/`), then run exactly `__TOOLS__/shot-godot.sh`
(it reads `.dm-shot.json`; the game renders the way it plays, on a software graphics driver, so it takes about 5 to 10 minutes; one renderer at a
time, so it may wait for another job). PNGs land in `.dm-shots/<name>.png`;
Read them. The plan:

```json
{"shots": [
  {"name": "bag-tooltip", "open": ["bag"], "hover": "item:staff_moon", "clip": "window"},
  {"name": "gear", "open": ["character"], "clip": "window"}
]}
```

- `open`: windows to open, from: bag (also reliquary), character (also gear, sheet), pets, legion, grimoire (also spellbook), vault, forge,
  salvage, shelf, codex, atlas, ascension, map, class, settings, professions, garden, labor, contracts, social (Friends tab), party. Only one window is open at a time, so
  one window per shot (the last one stays open). The vault needs `"area": "chapterhouse"`.
- `hover`: show the item card of `"item:<item id>"` (the first matching bag cell), a bag cell number 0 to 47, or `"worn:<slot>"` / `"belt:<tool>"`.
  The demo bag holds: staff_bone (common), scythe_iron (uncommon), staff_gold (rare, affixed), staff_moon (epic, affixed),
  leg_legion_unburied_chest (legendary), set_gravecaller_head (set piece), helm_gold, tonic_graveluck, meal_crypt_eel, bone_meal, ore_iron (a stack of 40),
  reagent_grave_dust, rune_volley, rune_splinter. Cell order is not guaranteed, so hover by item id.
- `area`: an area id to stand in first (`acre`, `chapterhouse`, `graves`, ...). `wait_ms`: extra settle time (default 300, max 5000).
  `clip`: `"window"` crops to the open window and its tooltip (default is the whole screen).
- `"give": ["item_id", ...]` adds extra items (one each, max 20) to the bag first, e.g. an item your change adds; `"bag": "keep"` skips the demo bag.
  If your change needs something the demo bag cannot show, say what you could not show.
- `"equip": ["item id", ...]` (max 12) adds each item and wears it the way a player equips from the bag (gear gets a real roll), so the hero's look
  updates as in play: held weapon, helm, mantle, the set look at 3+ set pieces (a legendary set swaps the hero body). An unknown or unequippable id
  prints a `QA-SHOTS equip:` line and is skipped. Use real item ids from `client/data/content` (e.g. `set_gravecaller_chest`, `staff_moon`).
- `"discipline"`: `ossuary`, `gravecaller` (default), `mourner`, `rotweaver` or `reaper`, to show a set on another hero (the script launches with `--class=N`).
- Per shot, `"view": "hero"` closes every window, hides the HUD and frames the hero full body from slightly above; `"turn"` is degrees (0 faces the
  camera, 180 shows the back and mantle; default 25, a front three-quarter); `"anim"`: `idle`, `run` or `cast` poses the hero, frozen after a short settle.
  `"view": "game"` is the normal game camera with the HUD hidden. Without `view` the shot is the normal screen, as before.
  `"view": "model"` with `"model": "<row id of client/game/view_models.json>"` shows that creature alone in the game's light, framed by its size
  (`"turn"`, `"anim"` any of its clips, `"anim_at"` 0 to 1 of it, `"height"` metres); for a creature in motion use a model clip (`.dm-guides/clips.md`).
- A plan holds at most 4 shots; for more angles run a second plan (change `.dm-shot.json`, run the script again).
- `"resolutions"` (at the top of the plan, only with a team PC online): the screen sizes the team PC renders every shot at, from `1920x1080`, `2560x1440`, `3840x2160` and
  `3440x1440` (at most 4, each once; without it only the standard 1920x1080 is rendered). For a new window or a change to the HUD's layout (anything that sits against a
  screen edge or scales with the screen) ask for all four; leave it out for a small tweak, for how the hero, gear or a spell looks, and whenever no team PC is online (the
  server renders the standard size only). A list that is not allowed is dropped and the thread says so. Every size multiplies the pictures, so with many shots and sizes
  the team PC renders the highest preset only.
- If a plan error is printed (unknown window and the like), fix the plan and run it again once.

A set worn, seen from the front and the back:

```json
{"discipline": "gravecaller", "bag": "keep",
 "equip": ["set_gravecaller_chest", "set_gravecaller_legs", "set_gravecaller_hands", "helm_gold", "staff_moon"],
 "shots": [{"name": "set-front", "view": "hero", "turn": 0}, {"name": "set-back", "view": "hero", "turn": 180}]}
```

**The game's side** (the QA run's flags, how a plan's set-ups are made on the game scene): `client/main/SCREENSHOTS.md`. In a workspace made before 2026-10-21 that file is not there yet: read only the "Screenshots for proposals" section of `client/README.md` instead.
