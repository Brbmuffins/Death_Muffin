# Making pictures (icons, portraits, loading art, floor and wall textures)

Every flat picture the game shows is one of the kinds in `tools/pictures/kinds.json`: ability, skill, omen, status, item and currency icons, portraits,
loading art, floor and wall textures. A kind sets the folder, the size, the size limit, the style pictures new ones copy and how Godot imports it. You
cannot call Gemini yourself; the runner makes the concepts, and you put the chosen ones in the game. Reuse a picture that fits; make a new one when the
request asks for it or nothing fits. Each ability has its own icon: `tools/pictures/pictures.test.mjs` fails when an ability borrows another one's.

**1. Concepts.** For each picture write `art-manifest/gemini-jobs/<id>.json`, a list with ONE job:
`[{"id": "concept_<id>", "kind": "<kind>", "prompt": "...", "out": "art-src/concepts/<id>.png"}]`. With a kind the prompt says only what to draw: the
subject, its colours (the class's or spell's own, which carry meaning) and what to leave out. The runner puts the kind's recipe in front and adds its style
pictures, so new pictures match the old ones, and takes the shape from the kind (no `aspect`, `size` or `post`). Optional `refs`, up to 2 more: a game
picture under `client/assets/` or a concept in `art-src/concepts/`. To change an existing picture (a recolour, a cleaner version), put it in `refs` and say
what to change. Then write `.dm-concept-request.json` (never commit it):
`{"ids": ["<id>", ...], "note": "one plain sentence"}` (1 to 8 ids a request, 24 concepts a round), stop, and say in one line what you asked for.
People pick from the numbered images; concepts stay in `art-src/concepts/` in later rounds of the same thread.

**2. Into the game, once people pick** (a pick needs no ✅; the proposal is the review). One command per picture, foreground:
`__TOOLS__/build-picture.sh <kind> <name> <concept id>`, with `--replace` as a fourth argument to change a picture that exists. It cuts off a frame the image
model drew, crops to the kind's size, makes floor and wall textures tile, writes `<kind's folder>/<name>.webp`, a new picture's `.import`, and its record
in `art-manifest/images.json`. Name it like its neighbours (`reaper-reap` beside `necro-ivory-cleave`). Then run `__TOOLS__/check-godot.sh --rerun code_load`
(Godot completes the `.import`) and point the game at it: Grep the old picture's path and change every place (an ability's `icon` is in both
`client/data/combat/abilities.json` and `client/data/content/abilities.json`). A picture nothing uses any more is deleted with its `.import` (Grep its
file name first). When an ability gets its own icon, drop it from the borrowed list in `tools/pictures/pictures.test.mjs`.

**3. Show it.** A shot plan (`.dm-guides/screenshots.md`) that shows the picture where players see it: for ability icons, `"discipline"` set to the class and the grimoire open, plus the
whole screen for the hotbar; for an item icon, `give` it and open the bag. Commit the pictures, their `.import` files, `art-manifest/images.json`, the
gemini jobs and the data edits in one commit.

A new kind of picture (a folder the list lacks) is one entry in `tools/pictures/kinds.json`, sized like the pictures already in that folder, in the same
change. Effect sprites (`client/assets/fx/`) are not a kind yet: say so rather than make one. Never edit `tools/ai/`.

**The game's side:** how the client takes in pictures is `client/tools/ASSETS.md`, and the window or system that shows one has its own guide (`client/README.md` names it). In a workspace made before 2026-10-21 `client/tools/ASSETS.md` is not there yet: read only the "Assets" section of `client/README.md` instead.
