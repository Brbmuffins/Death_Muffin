# Clips and choices (short videos, "pick one")

Only when the note before the request says a team PC is online. A team PC can record short silent videos of the game, so a question about how something
MOVES or looks in motion (how fast or far a spell travels, how big, how long, which colour) is answered with options people watch and choose from instead of
guessing numbers (Helix, 2026-10-19: War wanted the Haunting Wraith at another speed; "take 3 short videos of the spell at different speeds and ask what he likes best").

When to offer: the request is about how something moves or looks in motion, or you want the requester to choose between a few values, and each value is a
number, text or true/false in the game's data. Do not offer it for a question with one clear answer, for layout (use pictures) or for sound (the videos have none).
A new or changed model (an armor set, a weapon, a helm) always gets a turntable clip (Model previews, below), which is not a question.
With no team PC online, say which value you would pick and ask in words; do not write the file.

What you do (nothing is changed yet; the runner records the options by overriding the game's data):
1. Find what the change itself reads. Open the code that runs the rite or effect, find the `DmDb` data file and the keys it reads (grep `DmDb.` in the files
   that implement it; data files are under `client/data/`, and `combat/abilities` means `client/data/combat/abilities.json`) and read the current values. Only keys that
   already exist can be set: the game refuses an unknown path or key, and the recording fails. A tune follows the file's own nesting from its top
   (`client/data/combat/abilities.json` keeps each rite under `abilities`, so a rite's key is `{"combat/abilities": {"abilities": {"<rite>": {"<key>": value}}}}`).
   Clip plan words: `at` `pack` (enemies bunched 8 m ahead) or `ahead` (a line from 4 m, 2.5 m apart); `camera` `follow`, `wide` (the widest zoom)
   or `turntable`; at most 4 clips, 1 to 8 s, 0 to 12 enemies. Make a clip long enough for the slowest option to finish.
2. Write `.dm-clip.json` in the worktree root (never commit it; the runner reads it and removes it):

```json
{"plan": {"discipline": "reaper",
          "clips": [{"name": "wraith", "area": "graves", "cast": "haunting_wraith", "at": "ahead", "enemies": 6, "seconds": 8, "camera": "follow"}]},
 "variants": [{"label": "slow", "title": "slow (speed 2.0)", "tune": {"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 2.0}}}}},
              {"label": "now", "title": "as it is now (speed 3.5)", "tune": {"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 3.5}}}}},
              {"label": "fast", "title": "fast (speed 6.0)", "tune": {"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 6.0}}}}}]}
```

3. Reply in one or two lines: what the options are and why. Do not ask which one people like: after the videos the runner posts each one numbered
   ("1 · slow (speed 4)") and asks "Which do you like best? Reply with its number." No proposal comes yet.
4. The answer (a number, a name, "the slow one", or other values) arrives as the next message, with a note listing the options' values. Then make the choice a
   NORMAL change: put the chosen values into the data or code the change really reads (a tune only exists for the recording), add the test, commit, PATCH_NOTES, and
   propose as usual (with a shot plan when it is visible). If they want other values, write a new `.dm-clip.json`.

**Model previews (no choice).** For a new or changed model (an armor set, a weapon, a helm) write `.dm-clip.json` with ONE variant (an empty `tune` is fine) and a
turntable clip: the hero stands in the game's own lighting wearing the `equip` items and the camera turns around them. A turntable casts nothing, so it needs no `cast`, `at` or `enemies`.

```json
{"plan": {"discipline": "gravecaller", "equip": ["set_gravecaller_chest", "set_gravecaller_legs", "staff_moon"],
          "clips": [{"name": "set", "camera": "turntable", "seconds": 6}]},
 "variants": [{"label": "set", "title": "the set, turning", "tune": {}}]}
```

With one option nothing is asked: your proposal goes out as usual and the video follows it. `equip` (1 to 12 item ids from `client/data/content`, the same ids the shot plan's `equip` uses)
may sit at the top of the plan, for every clip, or on a clip, where it replaces the plan's list for that clip (one clip for the armor, another for the weapon). Gear that is
not in the game's data yet cannot be worn: a model preview is for pieces already wired in.

**Scripted clips (setup and steps).** The stand-ins normally have 400 times their health and do no damage, the HUD is hidden, the hero's souls or essence are
filled before each cast and the rite is cast again whenever it is off cooldown. When a video must show something else (enemies dying and dropping souls, the HUD,
a resource filling, several rites in order), give the clip a `setup` and `steps`: lists of `{"do": "<word>", ...}` (a step also has `"at"`, seconds into the
clip). The words, their arguments and their ranges are in `client/main/qa_clip_steps.json`: read it first. A clip whose steps cast needs no `cast`. With
`top_up` off a cast must be paid for: a rite the hero cannot afford at its step fails the clip (above, the free Scythe Sweep's kills fill the bag for the Wraith).
The stand-ins stand still where they are put (a pack's middle 8 m ahead, a line from 4 m) unless `fight` sends them at the hero; a melee rite such as
`scythe_sweep` (about 3 m) hits nothing 8 m away, so for melee let them fight, or start them near with `distance`. Check a rite's `range` in its data first.

```json
{"plan": {"discipline": "reaper",
          "clips": [{"name": "souls", "area": "graves", "at": "pack", "enemies": 8, "seconds": 8,
                     "setup": [{"do": "hud", "show": true}, {"do": "stand_ins", "health": 1, "harmless": true, "fight": true, "distance": 6},
                               {"do": "souls", "value": 0}, {"do": "top_up", "on": false}],
                     "steps": [{"at": 0.3, "do": "cast", "rite": "scythe_sweep"}, {"at": 4, "do": "cast", "rite": "haunting_wraith"}]}]},
 "variants": [{"label": "now", "title": "the souls filling the bag", "tune": {}}]}
```

A video needs a word that is not there yet: add it in your change, in three places: its entry in `client/main/qa_clip_steps.json`, its handler in
`client/main/qa_clips.gd` (the `SETUP_WORDS` or `STEP_WORDS` list and the code that carries it out), and a check in `client/tests/qa_shots.gd` (the suite fails
when the file and the recorder disagree). The runner checks a request against your branch's copy of that file, so the new word works in this job's videos at once;
nothing else has to change. A word only sets up or plays the game; it never runs code the plan brings.

The runner reads `.dm-clip.json` after your turn. Do not say the video is queued or on its way: say you asked for it. If the runner refuses the request, the
reason comes back to you to fix.

What the runner checks (a mistake comes back to you to fix, twice): `plan.discipline` is ossuary, gravecaller, mourner, rotweaver or reaper; 1 to 4 clips, each
`{name (lowercase letters, digits, dashes), area (an area id such as graves; the Hollow Graves when left out), cast (the rite's id; a "turntable" clip may leave it out), at ("pack": the cast goes at the dummy enemies,
"ahead": at the ground in front of the hero), enemies (0 to 12), seconds (above 0, at most 8; 5 when left out), camera ("follow" the hero, "wide", or "turntable"), equip (item ids), setup, steps (the words of `client/main/qa_clip_steps.json` in your branch)}` and no other field
(the plan may also carry `equip`); 1 to 4 variants, each `{label (lowercase letters,
digits, dashes, at most 24), title (what people read under the video, at most 60 characters: say the value), tune}`; a tune is `{"<data path>": {<nested keys>: <value>}}` with
numbers, text or true/false only (no lists), at most 64 values, key names of letters, digits and `_ . / -`; the whole file at most 32 KB. Videos show the offline demo
character on this branch; an option that is today's value (an empty `{}` tune is fine too) helps people compare. People can say `!clips` to record the last request again.

**The game's side** (the clip plan's words, the frame writer, `--tune=`): `client/main/CLIPS.md`. In a workspace made before 2026-10-21 that file is not there yet: read only the "Clips and tune" section of `client/README.md` instead.
