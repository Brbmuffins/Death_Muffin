# The look

Death Muffin's art direction: what the game looks like and the few colour and shape rules that keep a fight readable. Every new model, picture,
effect and area is checked against this page (AGENTS.md "Fit the game's look"), and it is the target of the art rebuild (ROADMAP Phase 4). It is
guidance, not a law (DECISIONS B71): an asset may break a line on purpose when the team approves it. Budgets and file rules are the tech art's
(`ASSET_PIPELINE.md`); how to make each kind of asset is in the generation guides.

## The game in one paragraph

A necromancer's crypt-crawl at night: grimy gothic stone, bone and rotted cloth under cold moonlight, seen from above like a painted diorama.
The world is dark, muted and cool. Colour is spent on meaning: magic glows, loot shines, danger warns, and almost nothing else is
saturated. Shapes are realistic in proportion but chunky and worn, so they read at a distance. The quality bar is Gravecrawl
([GRAVECRAWL.md](GRAVECRAWL.md) lesson 5: "Enemy, player and ground must differ in hue and value; violet is for magic, not for the whole world").

## Colour carries meaning

A colour below means one thing everywhere: on the ground, on a model, in the HUD and on the minimap. A new asset uses its family's colour and
does not borrow another family's. Meaning is never shown by colour alone (rarity has marks, warnings have shapes) for colour-blind players.

| Family | Colour | Used for | Where it is set |
|---|---|---|---|
| Magic | violet `#9b5cff`, light `#c6a4ff` | the player's spells, elites' ring, magic UI (hover, spell text) | `client/ui/dm_ui.gd`, `client/assets/fx/fx_data.json` |
| Your undead | jade-teal `#6fe3c8` (deep `#1f8f86`) | thralls' rim and ring, raised souls, the thrall marker | `client/crowd/crowd_looks.json` |
| Reward | gold `#e2c98f`, legendary orange `#ff9a2e` | gold, loot beams, legendary items, champion thralls | `dm_ui.gd`, `crowd_looks.json` |
| Danger | each enemy family's warm colour inside, one shared warning edge (see "Telling things apart") | enemy attacks, boss warnings, damage you take `#e58aa8` | `fx_data.json` group `enemy`, `client/fx/README.md` |
| Rot and plague | chartreuse `#a8c23a` / `#9cc43a` | Miasma, the Cloister, plague enemies | `fx_data.json`, `client/data/content/areas.json` |
| Fire | ember `#ff6a2a` | Corpse Explosion, the Pyre | same |
| Cold and grief | pale blue `#9fc4ff` | frost, dirges, the Mourner | same |
| Blood | crimson `#8a2c3c` / `#c23a48` | bleeding, Grave Step | same |

- **Rarity:** common `#b9b2a4` ·, uncommon `#8fb98a` ◆, rare `#8fa6e8` ◆◆, epic `#c6a4ff` ◆◆◆, legendary `#ff9a2e` ★ (`dm_ui.gd`).
- **Disciplines:** each class owns one accent: Ossuary bone `#d8cfbd`, Gravecaller violet `#9b5cff`, Mourner spirit blue `#8f9ed1`, Rotweaver
  lilac `#b58cc7`, Reaper `#6ee7a0` (`client/data/content/disciplines.json`). Its robes, rites and gear glow use that accent.
- **The world stays out of these colours.** Floors, walls and props have their natural colours (grey stone, brown wood, green-bronze, aged
  bone), dark and low in saturation. Colour in the world comes from light, never from its materials (Helix, 2026-11-01; "Areas" below).

## Areas: palette and light

The world is built in natural colours and coloured by light, in two ways:

- **An area's lighting:** each area adds one mood colour through its light, fog, sky and weather (`client/data/content/areas.json` "ambient")
  over the shared moonlit night (`client/data/slice/world.json` "lighting").
- **Light in a place:** a violet shrine, a green plague pool, a forge's glow, torches. The light is baked into that spot's lightmap, so the
  colour stays where its source is and costs nothing while playing.

The same grey stone wall can be cold blue in the Graves, green in the Cloister and orange beside the Pyre's furnaces. The moodboards in
[art/areas/](art/areas/) show the target feeling for three places.

| Area | Mood colour | Feeling |
|---|---|---|
| Chapterhouse | warm cream candlelight on dark plum | the safe hub: the warmest light in the game |
| Alchemist's Wing | soot and tarnished copper, green fumes | a lit workshop: soot-dark stone, blackened iron, candle-wax ivory |
| Sexton's Acre | grey-green dusk, falling leaves | outdoors and open, lit brighter than the crypts |
| Hollow Graves | grey-lilac | moonlit graveyard, silent bells |
| Marrow Ossuary | bone dust, warm grey | stacked skulls, dry and dusty |
| Drowned Nave, Bell Sanctum | blue-lilac to violet | cathedral gloom, stained light |
| Plague Cloister | chartreuse fog | sickly rot, plague-doctor statues |
| Cinder Pyre | ember orange | heat, soot and sparks |
| Mourning Fen | teal mist | drowned, wet and cold |
| Catacomb Warren, Bone Coliseum, Catacomb Depths | brown-grey earth | low, enclosed, torchlit |

A new area picks one mood colour that no neighbour uses. Its light never makes the floor as bright or saturated as a spell.

## Telling things apart

The camera looks down at about 54° from 15 to 32 m away (`world.json` "camera"), so a 1.9 m hero is roughly 90 to 180 pixels tall on a 1080p
screen and a skull rat about 25. Design for the zoomed-out view:

- **Silhouette first.** Each creature reads by its outline alone: a big, simple shape and one or two features (horns, a cape, a weapon) at
  least ~15 cm wide. Detail smaller than that is paint, not shape.
- **Size tells rank.** Crowd enemies 0.5 to 2.1 m, champions and elites a little bigger, bosses 3 m and up (`client/data/slice/enemies.json`).
- **Heroes** wear their discipline accent, stand on a pale ring and are the brightest thing near them.
- **Your thralls** are bone and rag like enemies, so they always carry the jade-teal rim and ground ring; another player's thralls the same
  at less strength, champions in gold.
- **Enemies** never carry jade-teal or a ring of their own except elites (violet ring) and bosses. Their colour comes from their family
  (rot, ember, cold, bronze for bells).
- **Enemy warnings** (ground rings, cones, lines) keep their family colour inside and share one warning edge, so "step out" reads the same in
  every area. The player's own ground effects never use that edge.
- **The ground differs from everything on it** in both colour and brightness: dark and cool under brighter, warmer creatures.

## Models

- **Style:** grimy painted realism, the look of today's concepts (`art-src/concepts/hero_*`, `bone_hound_3d`): real proportions, chunky
  forms, worn and dirty surfaces. Materials are aged bone, black and plum cloth, rusted iron, tarnished bronze and copper, candle-wax ivory.
  Never clean, glossy or toy-like.
- **One accent per model,** from its meaning above (a class's colour, a set's accent, an enemy family). Everything else stays muted.
- **Metal is only metal.** Stone, bone, cloth and skin are not metallic; real metal keeps a dull shine. Glow is faint (emission 0.15 or less)
  and only where it means something (eyes, runes, magic, rarity), or the model whites out under bloom (`ASSET_PIPELINE.md`).
- **Characters and gear:** two body types, male and female, for every class; each is a default body in plain, fitted underclothes (no
  long robes, which stretch between the legs). Worn gear replaces the body region it covers (helm, shoulders, chest, gloves, legs, boots).
  Big pieces (pauldrons, capes, weapons) hang from a bone. A legendary set at 3 pieces swaps to its own full body until the set is rebuilt
  as pieces.
- **Classes look different through what they wear** (Helix, 2026-11-01, DECISIONS B81): each class starts in its own outfit, and every gear
  piece is made once, in the style of the class it is meant for, and fitted to both bodies. Anyone may wear any piece; loot is personal and
  leans to the player's class, so a class mostly looks like itself. Each class keeps its accent colour and one big shape that reads from far
  away (a cape, horns, a mask).
- **The concept is the model.** Pixal3D copies the picture, so a concept is drawn as the finished model: the recipe in
  `server/death-muffin/discord-agent/guides/models.md`, with an existing concept of the same family as a reference picture so it matches.

## Pictures and UI

- **Icons and portraits:** painterly, dramatic and dark: one strong central shape on a near-black background, lit from above or rim-lit,
  readable at 32 px for status icons. Each kind's recipe and its style picture are in `tools/pictures/kinds.json`; a new picture copies its
  kind's style picture.
- **UI:** dark plum-black plates (`#0e0c12`) with a thin bone border and chipped corners, bone text (`#d8cfbd`), violet hover; display text in
  Cormorant Garamond, body in Alegreya Sans, numbers in IBM Plex Sans Condensed (`client/ui/dm_ui.gd`, `client/ui/theme/build_theme.gd`).
  Colour in the UI follows the families above.
- **Effects:** see the colour families; size and brightness limits come with the effects standard (ROADMAP Phase 2, track C).

## Checking an asset

Before a new visual asset ships, show it from the game camera beside existing ones in its area's light, and ask:

1. Does it read at the zoomed-out view by outline alone?
2. Is its accent colour from its own family, and is everything else muted?
3. Can a player tell at a glance whether it is a friend, a foe or the ground?
4. Is it worn and grimy like its neighbours, with no metal or glow where nothing should shine?
