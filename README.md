# Death Muffin — Player Guide

*A dark fantasy action RPG in your browser, alone or in a shared world of up to 10 players.*

![A fight in the Hollow Graves](docs/screenshots/graves-battle.webp)

The Ossuary Covenant stands in a diocese overrun by the dead. Choose one of nine disciplines, gather and craft in the safety of the Sexton's Acre, then fight through connected hunting grounds. Build your character, open the sealed passages, defeat the Bell-Sworn Prelate, and Ascend for permanent boons and a harder, more rewarding world.

**Play:** [muffindevelopment.com/death-muffin](https://muffindevelopment.com/death-muffin/). Create an account or sign in, then choose a discipline. You can change class later in **Settings** while keeping the same character's level, gold, items, and permanent progress.

**Release status:** This guide matches the live game as of **2 October 2026**: the 48-slot bag, Ossuary Vault and salvage, readable gear with upgrade arrows and the Character sheet, new combat audio, plus everything from 1 October (armor sets, Cinder Pyre and Mourning Fen, necromancer weapons and brews, five swappable rite slots, the Offline Edition). See the **[visual roadmap](ROADMAP.md)** for what is coming next, and [the handoff](HANDOFF.md) for development status.

## ✨ Highlights

Some of the most polished corners of the game right now (updated 2 October 2026):

<table><tr>
<td width="50%"><img src="docs/screenshots/gear-set-tooltip.webp" alt="An item tooltip that says whether it is an upgrade for your discipline and which set bonus it completes" /><br /><sub><b>Gear you can read.</b> Green ▲ / red ▼ on every bag item, a verdict for <i>your</i> discipline, and armor set bonuses that light up as you complete them.</sub></td>
<td width="50%"><img src="docs/screenshots/character-sheet.webp" alt="The Character sheet with what you're looking for and your weakest slots" /><br /><sub><b>Character sheet (J).</b> What your discipline wants, your weakest slots, and where every number comes from.</sub></td>
</tr><tr>
<td><img src="docs/screenshots/laborer-woodcutting.webp" alt="A Grave Laborer chopping a coffin-oak with a hatchet" /><br /><sub><b>Grave Laborers at work.</b> Your thralls chop, mine, dig and fish in the Sexton's Acre.</sub></td>
<td><img src="docs/screenshots/ossuary-vault.webp" alt="The Ossuary Vault beside the 48-slot Reliquary" /><br /><sub><b>Room to breathe.</b> A 48-slot bag and the 120-slot Ossuary Vault shared by your characters.</sub></td>
</tr><tr>
<td><img src="docs/screenshots/apothecary-wing.webp" alt="The Apothecary at her counter in the Alchemist's Wing" /><br /><sub><b>The Alchemist's Wing.</b> A room for brewing, the Great Cauldron and the Apothecary, who tells you what your reagents make.</sub></td>
<td><img src="docs/screenshots/affix-tooltip.webp" alt="A ring with three affixes and an upgrade verdict" /><br /><sub><b>Rolled loot.</b> Item levels and affixes rolled on the server; necromancer affixes marked †, verdicts in plain words.</sub></td>
</tr><tr>
<td><img src="docs/screenshots/zone-polish-gravedigger-sweep.webp" alt="The Gravedigger King's sweep telegraph, outlined in gold" /><br /><sub><b>Readable boss telegraphs.</b> Cones and lines are outlined and bright, so you always know where not to stand.</sub></td>
<td><img src="docs/screenshots/zone-polish-corpse-rings.webp" alt="Fresh corpses marked with faint rings" /><br /><sub><b>Corpses you can find.</b> Every fresh body gets a faint ring, so a necromancer never loses track of their next thrall.</sub></td>
</tr></table>

## Contents

- [Highlights](#-highlights)
- [Your first hour](#your-first-hour)
- [What to explore next](#what-to-explore-next)
- [Finding your way](#finding-your-way)
- [Controls](#controls) (and [on a phone or tablet](#on-a-phone-or-tablet))
- [Choose a discipline](#choose-a-discipline)
- [Combat and corpses](#combat-and-corpses)
- [The world and its bosses](#the-world-and-its-bosses)
- [Gold, gear, and difficulty](#gold-gear-and-difficulty)
- [Gear, stats and the character sheet](#gear-stats-and-the-character-sheet)
- [Gathering and crafting](#gathering-and-crafting)
- [Ascension](#ascension)
- [Playing together and getting help](#playing-together-and-getting-help)
- [Offline play status](#offline-play-status)

## Your first hour

Nothing in the first hour is a quest, and nothing can be failed or missed. This is the route most players take, and what the game says along the way. Skip any of it, in any order.

![The opening: one counsel card, the Next line and the Sexton](docs/screenshots/first-hour-opening.webp)

1. **Minutes 0-2: the Sexton's Acre.** You start in a safe gathering yard with no enemies. One Covenant counsel card ("Take your time") explains the controls, and the **Next** line under the minimap offers a single optional suggestion: *Walk east to the Chapterhouse, then north to the Hollow Graves*. The Sexton (a gold **!** over his head; click him or press **E**) explains gathering, Grave Laborers and the daily Contracts when you ask. To begin a skill, click a Coffin-Oak, Copper or Tin Seam, Still Pool or Pauper's Grave; **P** shows your skills. You can leave gathering for later.
2. **Minutes 2-3: the Chapterhouse.** East of the Acre, a safe hub with the Reliquary for your bag, the Workbench for smelting and tools, the Altar of Ascension, a Waystone and the Prior, who points the way when asked. The east door leads to the **Alchemist's Wing**, where the Apothecary brews. **T** channels a return here whenever you want a break.
3. **Minutes 3-15: the Hollow Graves.** Go north through the Chapterhouse. Move with **WASD** or by clicking the ground, click an enemy for your basic attack, and use **1-4** and **Right-click** for rites. The first dead you meet bring one short fight card ("Walk among the dead"), and the first corpse brings the necromancer's main lesson: **Exhume** raises it as a thrall. A card about one kind of enemy appears the first time you see it, and **Hurt?** appears when your health drops below half. The first levels come quickly (level 4 after a couple of minutes of fighting in our test runs), and each level can unlock a new rite for the **Grimoire (L)**.
4. **Minutes 5-20: loot and the first seal.** Loot goes to the **Reliquary (I)**, a 48-slot bag. A green **▲** on a bag item means it beats what you wear; **J** is the Character sheet. When the bag fills, **Sell all junk**, the **Vault (V)** and the **Bone Grinder** make room. The count under the minimap (and the Next line) tracks your first seal: 300 kills in the Graves open the **Marrow Ossuary**, whose dead are tougher and whose loot is better. Elites carry **soul shards**; two wake the Gravedigger King.
5. **Whenever you like: brewing.** The dead drop **Grave Dust**; four brew a first tonic at the Great Cauldron in the Alchemist's Wing. The Apothecary tells you what to brew and where each reagent falls.
6. **Read what you meet.** Hover a rite for its cost and targeting advice, and open the **Codex (K)** for enemies, rites and professions.

**How the guidance behaves.** It never blocks you and never repeats itself: one Covenant counsel card at a time; a card that only explains a quiet idea waits until a fight is over, no conversation is open and no panel is up; a card about something you just did (opening the Vault, placing a rite on a key) appears at once; the **Hurt?** card jumps the queue; and a card about a place waits until you are there. The Next line and the area text under the minimap never say the same thing. Drag a card by its header to move it. Every card stays reachable through **Settings → Show tips again** and the **Codex (K)**.

![A short fight card in the Hollow Graves](docs/screenshots/first-hour-first-fight.webp)

**Medium** is the default difficulty for each character. The Brbmuffins developer account can use auto combat on **Easy**; it turns on when switching to Easy unless turned off. **G** toggles it; clicking or moving takes manual control. Auto gathering and AFK professions remain available to every player.

## What to explore next

| If you enjoy… | Try this |
|---|---|
| A new fight | Follow the main route through the Plague Cloister to the **Cinder Pyre**. Fire enemies leave burning ground; the Cinder Regent's ash circles are safe during Conflagration. After 800 Pyre kills, enter the **Mourning Fen** from the Drowned Nave's west wall and fight the Mire Mother from the dry hummocks. |
| Finding a build | Collect a five-piece armor set for any discipline. Necromancers can also try a staff, scythe, wand or ritual sickle: each changes the basic attack. Equip a skull focus, grimoire or mourning bell in the off-hand if your weapon leaves that hand free. |
| Gathering and brewing | Dead in the Hollow Graves drop **Grave Dust**. Four dust make a **Grave-Dust Tonic** at the Great Cauldron in the Alchemist's Wing, with no garden required. Forage Rot-cap in the Cloister, Ash-bloom in the Pyre, and bog myrtle or drowned lotus in the Fen for later recipes. |
| A longer goal | Fill Sexton's Contracts, grow herbs in the Acre, send Grave Laborers to work, and unlock capes and companions as your skills rise. The **Codex (K)** lists enemies, weapons, brews, reagents and professions. |

The landing page previews the fire realm and its enemies with a lightweight purple fire glow and drifting embers. **Settings → Reduced motion** tones down effects in game if you prefer a quieter screen.

## Finding your way

<img src="docs/screenshots/prior-dialogue.webp" alt="Talking to the Prior, with the Next line under the minimap" />

Nothing in Death Muffin is a quest, and nothing can be failed or missed. If you would like a nudge, the game gives you three ways to ask for one.

| Who or what | Where | What it tells you |
|---|---|---|
| **The Prior** | The Chapterhouse, near the Altar | Where to hunt next, how the seals and the kings of the dead work, and when the Altar of Ascension is ready. |
| **The Sexton** | The Sexton's Acre, near the Covenant Lectern | Gathering, your Grave Laborers, the Bone Grinder and the Vault, and the day's Contracts. |
| **The Apothecary** | The Alchemist's Wing, at her counter (through the Chapterhouse's east door) | What to brew, where each reagent falls, and how elixirs and tonics work. |
| **The Next line** | Under the minimap | One short suggestion from the same advice, such as *Hollow Graves: 172 / 300 to open the Marrow Ossuary*, *Your laborers are ready in the Acre* or *The Gravedigger King waits at the King's Grave, 2 soul shards*. A gold marker or arrow on the minimap points the way. |

**Talking.** Click a person, or stand close and press **E**. They turn to face you, and a gold **!** over their head means they have something new to say (a seal you have broken, a king you have buried, a full bag, laborers waiting). Every conversation has three or four buttons: *Where should I go next?*, *Tell me about...* and *Goodbye*. Their answers use your real numbers: your level, your kill counts, your shards, your bag. The camera eases north while a conversation card is open, so you and the speaker stay in view below it. Press **Esc**, press **E** again, or walk away to end a conversation.

![Talking to the Sexton: the camera keeps him and you below the card](docs/screenshots/first-hour-sexton-talk.webp)

**The Next line.** It updates as you play and shows only the single best suggestion. Press its **x** to hide the current one; a different suggestion will appear when your situation changes. **Settings** can turn the line off, and turn the minimap marker off separately. The **Codex (K)** has a **People** tab listing who stands where and what to ask them. What you have heard is remembered per character in this browser.

## Controls

| Input | Action |
|---|---|
| **WASD** or arrow keys | Walk directly; a held key takes over from click-to-move |
| Left click ground / enemy / object | Set a walking destination, use your basic attack, interact, or gather |
| Shift + left click | Use your basic attack without moving |
| Click the minimap | Walk to a reachable point; the amber marker is your destination |
| Mouse / wheel | Aim / zoom |
| **1–5** | Use your equipped rites at the cursor; hold to repeat when ready |
| Right click | Also uses your fifth equipped rite, which you can change in the Grimoire |
| **R** or **6** | Use your class's signature rite after level 10 |
| **Q** | Drink a healing flask |
| **Z** / **X** | Drink the elixir / tonic on your belt (**F** is reserved for throwables) |
| **T** | Recall to the Chapterhouse |
| **L** | Open the Grimoire to inspect rites and set all five slots |
| **I** or **B** / **C** / **P** / **O** / **U** / **H** / **N** | Reliquary / Workbench / Skills and AFK gathering / Sexton’s Contracts / Grave Gardening / Grave Laborers / Capes & Pets |
| **J** | Character sheet: your numbers and where each comes from |
| **Y** | Legion (necromancers): spare weapon and armour for your thralls, and Reinforce |
| **M** / **K** | Waystone map / Codex |
| **E** | Talk to the Prior, the Sexton or the Apothecary when you stand beside them |
| **V** | Ossuary Vault, the shared stash (in the Chapterhouse or the Acre) |
| **G** | Toggle auto combat on Easy (Brbmuffins developer account) |
| **Enter** | Chat |
| **Esc** | Close an open panel, then open Settings |

You can also click hotbar icons. Click **swap** below any spell icon to open the Grimoire with that slot selected; right click a hotbar slot also works. In **Settings**, you can change class, difficulty, graphics, frame rate (60 or 30 fps), volume (Master, plus separate **Combat**, **Ambience** and **Interface** sliders), reduced motion, damage numbers, gathering behavior, counsel tips, and the Next suggestion with its minimap marker.

### On a phone or tablet

The HUD rearranges itself for phones (portrait and landscape) and tablets, and every panel fits the screen.

**Battery saver.** New phones and tablets start on Graphics Low and 30 fps (other devices: High and 60 fps), even if an older High was saved, until you change Graphics or Frame rate yourself. Change either in **Settings**; Low + 30 fps uses far less battery. While a full-screen panel covers the world, the 3D view redraws only a few times a second (the game itself keeps running).

| Touch | Action |
|---|---|
| Tap ground / enemy / object | Walk there, attack, talk, or gather |
| Drag a finger | Keep walking toward it |
| Pinch | Zoom |
| Tap a rite | Cast it at the enemy you tapped, or else the nearest enemy |
| Press and hold a rite | Show its spell card (tap anywhere to close it) |
| Flask button on the Health orb | Drink a healing flask |
| Tap a brew on the left | Drink that elixir or tonic |
| **Upgrades** button | Open Damage / Wave Speed (it glows when you can afford one) |
| **‹ Back** on a panel | Return to the panel you came from (Skills → Contracts → Back) |
| Phone Back gesture | Steps back through panels, then closes them; it never leaves the game while a panel is open |
| **☰ Menu** | Big labelled tiles for every panel: Bag, Character, Spells, Craft, Skills, Contracts, Garden, Laborers, Legion, Capes & Pets, Vault, Map, Codex, Settings, plus **Recall home** and Auto combat |
| ⛶ next to the Menu | Full screen (Android; iPhone Safari has no full screen) |

Panels keep their scroll position while AFK gathering updates them.

Double tap and pinch never zoom the page (pinch zooms the camera). Counsel cards, prompts and hints use touch wording ("Tap…", "the Menu") on a phone and keyboard wording on a computer. If your connection drops you keep playing: the game says **Connection lost**, saves retry on their own, and **Back online ✓** appears when it is back.

## Choose a discipline

Every class has a basic attack, five swappable rites on **1–5** (slot 5 also uses right click), and a signature on **R** at level 10. The four necromancers share a larger pool of rites and can choose any five unlocked rites in the Grimoire as they level. The other five classes have their own resource and five rites to rearrange.

| Portrait | Discipline | Resource and style |
|---|---|---|
| <img src="public/art/portraits/ossuary.webp" alt="" width="64" /> | **Ossuary** | Grave Essence. Defensive necromancer: shield-bearing thralls draw attacks, and each active thrall reduces the damage you take. |
| <img src="public/art/portraits/gravecaller.webp" alt="" width="64" /> | **Gravecaller** | Grave Essence. Leads the largest, fastest-attacking legion; sacrifices leave corpses to raise again. |
| <img src="public/art/portraits/mourner.webp" alt="" width="64" /> | **Mourner** | Grave Essence. Ranged wraiths, faster essence recovery, and healing when consuming corpses. |
| <img src="public/art/portraits/rotweaver.webp" alt="" width="64" /> | **Rotweaver** | Grave Essence. Larger Miasma, more Withered stacks, and corpses that burst inside its rot field. |
| <img src="public/art/portraits/grave_warden.webp" alt="" width="64" /> | **Grave Warden** | Oil refills over time and from burning bodies. A flail, lantern, chain, and protective wards support close fighting and allies. |
| <img src="public/art/portraits/bell_monk.webp" alt="" width="64" /> | **Bell Monk** | Build Resonance by landing hits, especially on the beat. Toll and corpse-sounding rites reward timing. |
| <img src="public/art/portraits/carrion_witch.webp" alt="" width="64" /> | **Carrion Witch** | Harvest bodies for Offal; use hooks, crows, and hexes to control a pack. Offal does not refill on its own. |
| <img src="public/art/portraits/hollow_knight.webp" alt="" width="64" /> | **Hollow Knight** | Build Rage by fighting and taking hits, especially with a well-timed block; spend it on a leap and slam. |
| <img src="public/art/portraits/veilwalker.webp" alt="" width="64" /> | **Veilwalker** | Veil refills in Life form and drains in Veil form. Move between forms and make temporary spectral allies from fallen enemies. |

**New player picks:** Ossuary gives you a sturdy front line; Mourner has forgiving sustain; Hollow Knight suits players who want to stand close and time blocks. Any discipline can change later through Settings.

At **level 10**, each discipline unlocks its own signature rite on **R**:

| Discipline | Signature | What it brings |
|---|---|---|
| Ossuary | <img src="public/art/abilities/necro-ossuary-wall.png" alt="" width="36" /> **Ossuary Wall** | Blocks the dead with a wall of bone. |
| Gravecaller | <img src="public/art/abilities/necro-command-rend.png" alt="" width="36" /> **Command: Rend** | Sends the legion leaping into a target area. |
| Mourner | <img src="public/art/abilities/necro-dirge.png" alt="" width="36" /> **Dirge** | Mends allies and silences enemy casters nearby. |
| Rotweaver | <img src="public/art/abilities/necro-plague-bloom.png" alt="" width="36" /> **Plague Bloom** | Starts a rot bloom that spreads through corpses. |
| Grave Warden | <img src="public/art/abilities/warden-last-light.png" alt="" width="36" /> **Last Light** | Stuns nearby enemies and heals allies. |
| Bell Monk | <img src="public/art/abilities/monk-great-toll.png" alt="" width="36" /> **Great Toll** | Spends Resonance on a damaging, silencing toll. |
| Carrion Witch | <img src="public/art/abilities/witch-murder-of-crows.png" alt="" width="36" /> **Murder of Crows** | Sends a moving swarm after enemies. |
| Hollow Knight | <img src="public/art/abilities/knight-oath-unbroken.png" alt="" width="36" /> **Oath Unbroken** | Briefly refuses death and increases damage. |
| Veilwalker | <img src="public/art/abilities/veil-between-worlds.png" alt="" width="36" /> **Between Worlds** | Gains Veil protection with Life-form damage. |

## Combat and corpses

The necromancers begin with this kit. The icons are the same ones used on the hotbar:

| Icon | Input | Rite | Use |
|---|---|---|---|
| <img src="public/art/abilities/necro-needle.png" alt="" width="42" /> | Left click | **Bone Needle** | Free basic attack; hits restore Grave Essence. |
| <img src="public/art/abilities/necro-spear.png" alt="" width="42" /> | **1** | **Marrow Spear** | Pierces a line and applies Fracture, making targets take more damage. |
| <img src="public/art/abilities/necro-exhume.png" alt="" width="42" /> | **2** | **Exhume** | Raises the corpse nearest your cursor as a fighting thrall. |
| <img src="public/art/abilities/necro-miasma.png" alt="" width="42" /> | **3** | **Miasma Circle** | Slows and withers enemies standing in the field. |
| <img src="public/art/abilities/necro-litany.png" alt="" width="42" /> | **4** | **Black Litany** | Sacrifices nearby corpses and thralls for a stronger burst. |
| <img src="public/art/abilities/necro-corpse-explosion.png" alt="" width="42" /> | Right click / **5** | **Corpse Explosion** | Detonates a corpse near the cursor under a pack. |

Your **Grimoire (L)** shows unlock levels, costs, cooldowns, and available alternatives. Click **swap** below a hotbar spell to jump to its socket, then choose an unlocked rite. Necromancers gain new primaries and rites while leveling; put any five unlocked class rites on **1–5**, including right click. Swapping slots does not clear a rite's cooldown. Your loadout is remembered for your character. Other classes can inspect and rearrange their five starting rites.

A corpse is an opportunity, but it will not last forever. Necromancers can raise it, explode it, or save it for Black Litany. The kind of corpse affects the thrall: a Penitent becomes an archer, a Deacon a bone mage, and a Carrion Sac a plague bearer. The other classes have their own corpse rites. **Crypt Deacons** can steal unattended bodies and raise enemies from them, so deal with a Deacon before letting corpses pile up.

Necromancers also fill a **Soul Harvest** meter through kills by themselves or their thralls. When it fills, the next Marrow Spear, Miasma Circle, or Black Litany costs no essence and covers a larger area. Watch the skull meter above the hotbar for the ready state.

![Exhume raises a thrall from a fallen enemy](docs/screenshots/exhume.webp)

**Practical combat habits:**

- Keep using your basic attack between costly rites. For necromancers, Bone Needle restores the essence you spend.
- Put Fracture on a tough target before a large burst. Pull a pack into Miasma or another area effect, then use corpses when the enemies are close.
- Read an elite's tag in the target frame. Soul shards come from elites and pay for boss summons.
- Step out of marked ground before it resolves. Use **Q** for a flask, **T** to recall, or reduce the Wave Speed dial when fights get too dense.
- Death returns you to the Chapterhouse without taking your level, gold, or gear.

## The world and its bosses

The diocese is one connected world. Kill enough enemies in the preceding area to break each seal. The Chapterhouse, the Acre, and the Hollow Graves are open from the start. Waystones can travel among areas you have unlocked.

| Area | Base level | How to open it | What to expect |
|---|---:|---|---|
| **The Chapterhouse** | Safe | Always open | Reliquary, Workbench, Altar, Ossuary Vault, and Waystone. |
| **The Sexton's Acre** | Safe | Always open | Gathering nodes and processing stations; no enemy waves. |
| **The Hollow Graves** | 1 | Always open | Your first waves, corpses, elites, and the Gravedigger King. |
| **The Marrow Ossuary** | 5 | 300 kills in the Graves | Bone-lined halls and Crypt Deacons. |
| **The Drowned Nave** | 9 | 420 kills in the Ossuary | Flooded cathedral and the Drowned Congregation. |
| **The Bell Sanctum** | 13 | 520 kills in the Nave | The Sundered Bell and the Bell-Sworn Prelate. |
| **The Plague Cloister** | 20 minimum | 600 kills in the Sanctum | A scaling hunting ground: its enemies keep pace with the highest-level player inside it. |
| **The Catacomb Warren** | 4 | 150 kills in the Graves | A side dungeon west of the Graves: nine chambers split by tall half-walls. See [Levels to explore](#levels-to-explore). |
| **The Bone Coliseum** | 11 | 350 kills in the Ossuary | A horde pit east of the Ossuary: four gates, fast surges, twice the elites. |
| **The Cinder Pyre** | 30 minimum | 700 kills in the Cloister | A fire realm past the Cloister's east arch, level-scaled the same way. Cinder Husks burst into embers, Pyre Priests hurl coals, Cinderhounds hunt in packs, Slag Brutes slam burning rings: everything here leaves burning ground. |
| **The Mourning Fen** | 45 minimum | 800 kills in the Pyre | A drowned marsh west of the Nave (door on the Nave's west wall), level-scaled. Bog water slows you; dry hummocks do not. Bog Hags hex your thralls, Wisps chill and lure, Leeches swarm, Sextons drag. |

<table><tr>
<td><img src="docs/screenshots/chapterhouse.webp" alt="The Chapterhouse" /><br /><sub>The Chapterhouse</sub></td>
<td><img src="docs/screenshots/marrow-ossuary.webp" alt="The Marrow Ossuary" /><br /><sub>The Marrow Ossuary</sub></td>
<td><img src="docs/screenshots/drowned-nave.webp" alt="The Drowned Nave" /><br /><sub>The Drowned Nave</sub></td>
</tr></table>

Every hunting ground has a boss summon object. Bosses cost **soul shards**, and only one can be active in a shared world at a time. Waves in that boss's area pause during the fight. Their first defeat per character awards extra shards, a rare or better relic, and a Codex trophy.

| Boss | Where and cost | Fight clue |
|---|---|---|
| **Gravedigger King** | King's Grave, Hollow Graves · **2 shards** | Leave the marked burial ground before it roots you; watch for pits later in the fight. |
| **Bone Abbess** | Abbess's Reliquary, Marrow Ossuary · **3 shards** | Break the skull niches that heal her; spend corpses before she draws them in. |
| **Drowned Congregation** | Drowned Font, Drowned Nave · **4 shards** | Use pews to block the Flood Hymn and leave grasping rings. |
| **Bell-Sworn Prelate** | Sundered Bell, Bell Sanctum · **5 shards** | Leave the expanding Toll ring, the frontal Slam, and marked Bell Rain circles. Defeating it unlocks Ascension for the run. |
| **Cinder Regent** | Ember Altar, Cinder Pyre · **6 shards** | When Conflagration starts, run to a grey ash circle and stay on it; the rest of the arena burns. Kill the Pyre Priests early so their coals do not cover the ash. His level scales with the Pyre. |
| **Mire Mother** | Mire Altar, Mourning Fen · **7 shards** | She sinks and resurfaces under a ringed hummock: leave it, then hit her while she is winded. Phase 2 floods the marsh; in phase 3 she raises every corpse in the Fen, so spend yours first. Her level scales with the Fen. |
| **Plague Saint** | Saint's Litter, Plague Cloister · **5 shards** | Move her off rot pools, where she heals, and kill the Plague Doctors that feed her through a green link. Her level scales with the Cloister. |

### Levels to explore

Three levels sit off the main road. Each has its own layout and its own reason to go there.

<table><tr>
<td><img src="docs/screenshots/catacomb-warren.webp" alt="The Catacomb Warren vault" /><br /><sub>The Catacomb Warren: the vault chamber</sub></td>
<td><img src="docs/screenshots/bone-coliseum.webp" alt="A surge in the Bone Coliseum" /><br /><sub>The Bone Coliseum: a surge in the pit</sub></td>
</tr><tr>
<td><img src="docs/screenshots/cinder-pyre.webp" alt="The Cinder Pyre and the Ember Altar" /><br /><sub>The Cinder Pyre: the Regent's arena and the Ember Altar</sub></td>
<td><img src="docs/screenshots/cinder-regent.webp" alt="Conflagration: ash circles in the Regent's arena" /><br /><sub>Conflagration: stand on a white ash circle</sub></td>
</tr></table>

**The Catacomb Warren** (level 4 · open after 150 Graves kills · door on the Graves' west wall).
A chambered dungeon: a three-by-three grid of rooms divided by tall half-walls, with staggered gaps and a lantern beside every gap so the doorways read in the dark. The middle chamber is the vault, a sarcophagus under four candelabra. Walls are solid to more than feet: **cones and blows stop at a wall**, so stepping behind one breaks a Bellbound Penitent's line and funnels the swarm into the gaps. Rats, Barrow Ghouls, bats, sacs and the odd Penitent live here. Good for learning to fight around corners; drops lean toward bones, tin, iron and copper gear.

**The Bone Coliseum** (level 11 · open after 350 Ossuary kills · door on the Ossuary's east wall).
A wide sand pit ringed by pillars with four gates. Surges arrive fast (a wave of 14 every 4.2 seconds, cap 36) and **elites are twice as common** as in the Nave. The only shelter is four low L-shaped skull walls, each with a statue at the elbow, and the pillar ring. The roster mixes fodder (skull rats, hounds, bats) with the newer kinds (Wraiths, Gargoyles, Templars, Acolytes), so it rewards area rites, kiting and holding a wall. Better drops and more XP per minute than the Nave, and a real chance of dying.

**The Cinder Pyre** (level-scaled, never below 30 · open after 700 Cloister kills · east arch of the Cloister).
The fire realm: a scorched garth of black obelisks, funeral pyres and a slag font, under drifting embers and ash. Enemy level follows the highest-level player inside, like the Cloister, and **everything here leaves burning ground**:

| Dead | What it does | What to do |
|---|---|---|
| **Cinder Husk** | Sturdy melee corpse that bursts into an ember pool when it dies | Finish it at range or step back as it falls |
| **Pyre Priest** | Hurls a coal onto where you stand (orange ring), leaving burning ground | Leave the ring, then the embers; close the gap with a blink |
| **Cinderhound** | Fast flankers in packs of two or three; corpses rise as your own hounds | Hold a wall or a Bone Ward, use area rites |
| **Slag Brute** | Slow, heavy slam that cracks a wide ring and leaves it burning; resonant corpse | Leave the ring on the wind-up, kite it in circles |

The Regent waits at the Ember Altar on the arena's north edge. The floor sigil marks the arena; the slag font stands in the east alcove, out of the fight.

**The Mourning Fen** (level-scaled, never below 45 · open after 800 Pyre kills · door on the Nave's west wall).
A drowned graveyard marsh under heavy fog and drifting marsh-lights. The whole floor is **bog water**: wading is slow (-22%), the pale-rimmed **hummocks** and the dry landing by the door are not, so you fight from the islands and cross the water on purpose. Enemy level follows the highest-level player inside, like the Pyre. Bog myrtle and drowned lotus grow here as gathering nodes (Gravedigging 25 and 45) and their seeds plant in the Acre's Mourning Beds (Gardening 55 and 70); both herbs brew into flasks. It drops the ascended armour sets, void sapphires and moon ore.

| Dead | What it does | What to do |
|---|---|---|
| **Bog Hag** | Lays a magenta ring on your thrall knot: inside it they deal 30% less for six seconds (a sigil shows on each) | Kill her first, or walk the legion out of the ring |
| **Mire Leech** | Swarms of four to six, bog-rot bites, no corpse | Miasma and area rites; stay on a hummock |
| **Fen Wisp** | Flies; pulses a teal chilling ring under you, backs away toward the open water | Step out, do not chase it into the bog |
| **Drowned Sexton** | Throws a grave-hook along a brown line and drags you 4.5 m in, then slams; two corpses | Step off the line, then leave the slam ring |
| **Choir Wraith** | Sings rings onto the ground (as in the Nave) | Keep moving |

The **Mire Mother** wakes at the Mire Altar on the marsh's heart. She sinks and resurfaces under a hummock (ripple ring: leave it), and is winded for a moment when she bursts out. Drowned Hands root anyone wading the open water. At 60% the marsh floods (hummocks shrink, the bog drags harder, leeches climb out); at 30% she raises a Risen from every corpse lying in the Fen, so spend your corpses first and the rite fails.

![The Bell-Sworn Prelate in the Bell Sanctum](docs/screenshots/bell-sworn-prelate.webp)

**Grave Surges** occasionally open a special breach in an active hunting area. Clear most of its rapid waves before it closes to earn an item and bonus gold.

## Gold, gear, and difficulty

**Kill Chain.** Kills you land (your thralls' and damage-over-time kills count) within **4 seconds** of each other build a chain, shown on the left edge. Tiers at 5, 12, 25, 45 and 80 (Stirring, Rampage, Slaughter, Massacre, Requiem) add **+5% to +25% XP and gold**, ring a rising chime and warm the readout from bone to red. It breaks when the window runs out or you die; a chain of 10 or more announces its end. Safe areas do not count.

**Weekly Omens.** One omen hangs over the diocese each week, the same for everyone, shown as an icon and name on the left edge (hover it for the rules). It changes every Monday at 00:00 UTC and cycles in order:

| Omen | Effect |
|---|---|
| **Blood Moon** | Elites are much more common in every hunting ground; every kill pays 15% more XP and gold. Red moon. |
| **Drowned Week** | Waves arrive 25% larger and kills pay 20% more; thicker cold mist. |
| **The Tolling** | Elites come Bell-Tolled and drop twice the shards; kills pay 5% more. Bronze moon. |

Omens only act in combat areas. The sky tint is half-way, so each place keeps its own light.

**Milestones.** One-off gold purses for kill counts (100 up to 25,000), kills in each hunting ground (100 up to 2,500) and your best chain (10 up to 100). Each pays once per character in this browser.

Gold and experience come from fighting. Open the **Reliquary (I)** to equip gear, use consumables, and see your inventory: a **48-slot bag** (8 × 6). Click an item's **padlock** to lock it; locked items are skipped by every bulk action. **Sell all junk** sells your unlocked common and uncommon gear after a confirmation that shows the count and the gold. When the bag fills, store things in the **Vault** or grind spare gear at the **Bone Grinder** (see Gathering and crafting). Loot pillars mark better drops; item rarity is shown by color and marks. The **Workbench (C)** turns materials into equipment and tools. Healing flasks are used with **Q**. **Brews** are two slots: one **elixir** (combat: damage, ward, lifesteal, haste, fire/rot resist) and one **tonic** (utility: speed, essence, wisdom, fortune). A new elixir replaces the active one; drinking the same brew extends it (up to twice its length). Right-click a brew in the Reliquary to put it on your belt, then press **Z** (elixir) or **X** (tonic); active brews show with countdowns at the left edge. Lifesteal heals a share of the damage of each hit (at most 3 targets count, and one hit heals at most 1.5% of max health). Brews are local and never sent to other players; cooked meals can be eaten from the bag for healing over time.

Each discipline has two five-piece armor sets with matching icons and visible colors on the hero. The first collection begins in the Hollow Graves and completes in the Bell Sanctum; the stronger ascended collection begins in the Sanctum and completes in the Cinder Pyre. Any class can wear any set. **Set bonuses:** wear 2, 4 or 5 pieces of the same set for a bonus; they stack, and the ascended sets are one step stronger. Necromancer sets scale their rites and thralls (Ossuary: thrall health, ward and maximum health; Gravecaller: thrall damage, attack speed and +1 thrall cap; Mourner: essence regeneration, corpse healing, wraith damage and maximum health; Rotweaver: Miasma radius, Withered stacks and a little health); the other sets give stats, health or essence regeneration. Hover a piece to see its set (green lines are active, grey need more pieces), press **J** for the Set bonuses block (what you have, what is next, which piece you still need and where it drops), and watch the bag arrows: an item that finishes a set says so ("completes Ivory Reliquary 4-piece"), one that breaks a set says that too. Worn pieces of an active set glow faintly on the paper doll. The Codex (**K**, Armor sets tab) lists every bonus. See [the armor set guide](docs/ARMOR-SETS.md) for the full table, names and drop areas.

**Necromancer weapons.** The four necromancer disciplines (Ossuary, Gravecaller, Mourner, Rotweaver) can carry a weapon line that changes what your left click (Bone Needle) does. Other classes wear the same items for their stats only.

| Weapon | Hands | Left click becomes | Passive |
|---|---|---|---|
| **Staff** | Two | Needle reaches 25% farther and pierces one more enemy | +10% spell damage |
| **Scythe** | Two | A close reaping arc (100 degrees, 3 m, up to 3 enemies) | Kills in the arc give +1 soul toward Soul Harvest |
| **Wand** | One | Needle fires 30% faster and strikes 15% softer | none: pair it with an off-hand |
| **Ritual Sickle** | One | Needle leaves one Withered stack | Exhume returns 20% of its essence |
| **Skull Focus** | Off-hand | none | Gold tier and above: +1 thrall cap |
| **Grimoire** | Off-hand | none | Rites recover 10% sooner |
| **Mourning Bell** | Off-hand | none | A Mourner's wraith hits heal allies for 2% of their max health |

Every kind comes in five materials, **Bone, Iron, Gold, Hell and Moon** (recommended levels 1, 15, 30, 45 and 60). They drop by zone (Bone in the Hollow Graves and Bone Warren, Iron in the Ossuary and Coliseum, Gold in the Nave and Sanctum, Hell in the Cloister and Pyre, Moon rarely in the Pyre) and the Workbench crafts them from planks and ingots (Carpentry: staff, wand, grimoire; Smithing: scythe, sickle, skull focus, bell). Two-handed weapons push the off-hand back to your bag. Hover a piece in the Reliquary for its line, or open the Codex (K, Weapons tab). Screenshots: [docs/screenshots/necro-weapons](docs/screenshots/necro-weapons).

Necromancer rites also have distinct casting motions now. A scythe sweeps, wands and sickles flick, and larger rites slam, channel or summon; the four necromancer heroes each use their own animations.

<table><tr>
<td><img src="public/art/items/staff_oak.png" alt="Oak Staff" width="56" /></td>
<td><img src="public/art/items/helm_gold.png" alt="Gold Helm" width="56" /></td>
<td><img src="public/art/items/chest_iron.png" alt="Iron Chestplate" width="56" /></td>
<td><img src="public/art/items/ring_copper.png" alt="Copper Ring" width="56" /></td>
<td><img src="public/art/items/flask_hp_major.png" alt="Major Healing Flask" width="56" /></td>
</tr></table>

The HUD has two gold upgrades:

- **Damage:** each purchased tier adds 8% spell power, up to 25 tiers.
- **Wave Speed:** buy up to 8 tiers, then choose an **active** tier from 0 up to what you own. Higher settings mean faster, larger waves, stronger enemies, more gold, XP and loot chances, and more elites. The pressure builds over the first 30 seconds of a visit, and the wave density levels off after tier 3 while the rewards keep climbing. The diamonds mark added pressure at tiers **3** (Elite Vanguard), **6** (Restless Crypts), and **8** (Nightfall). Lower the active tier when you need room to recover.

![Nightfall at Wave Speed tier 8](docs/screenshots/nightfall.webp)

Choose difficulty in **Settings (Esc)**. **Medium** is the starting balance for each character. **Easy** reduces enemy health and damage and pays less gold and XP; the Brbmuffins developer account can also use auto combat on Easy. **Hard** raises enemy health and damage, adds elites, and pays more gold and XP. In a shared world, the world keeper's difficulty and Ascension rank govern the enemies.

## Gear, stats and the character sheet

<img src="docs/screenshots/character-sheet.webp" alt="Character sheet" width="420" align="right" />

Gear carries four stats. Each one feeds a few numbers you can feel, and the game shows you which:

| Stat | What each point gives you |
|---|---|
| **VIT** (Vitality) | +8 health. Your thralls have 45% of your health, so VIT helps them too |
| **INT** (Intellect) | +1.3 spell power, +2 max essence, +0.1 essence per second |
| **STR** (Strength) | +0.4 spell power |
| **AGI** (Agility) | +0.3% move speed, +0.2 spell power |
| **Each level** | +14 health, +1.6 spell power, +2 max essence |

Your discipline then scales the result (an Ossuary necromancer has extra health, a Mourner regains essence faster), Covenant boons add their own share, **Damage upgrades** raise spell power by 8% per tier, and a necromancer's **staff** adds 10% spell power. A thrall hits for 40% of your spell power, before the staff's boost.

**Reading an item.** Hover a piece, or select it in the Reliquary (**I**). Under each stat is what it does for *your* character, for example `+6 VIT: +48 health (+22 thrall health)`. These numbers already include your discipline, so the same helm can be worth more to one class than another.

**Upgrade arrows.** Every gear item in your bag wears a small **green ▲** if it is better for your discipline than what you wear in that slot (an empty slot always counts as an upgrade), or a **red ▼** if it is worse; nothing means about the same. Hover or select it and the first line says why, for example `Upgrade for your Gravecaller: +12% (more thrall damage)` or `Worse than your Iron Helm: -8% (less health)`. The percentage is the change in one overall power score that weighs your damage (your spells plus your thralls' hits), how tough you and your thralls are, essence, and speed, with the mix set by your discipline: an Ossuary necromancer leans on toughness, a Rotweaver on damage. Necromancer weapon effects have an estimated value in the score (a scythe's reaping arc about 6%, a sickle's Withered about 3%, a grimoire's faster rites about 5%, and so on); the staff's spell damage and a skull focus's extra thrall are counted exactly.

**What you're looking for.** The top of the Character sheet lists your discipline's stats best first (a Gravecaller: INT > VIT > STR > AGI), what each is for, the necromancer weapon kinds that suit you, and your **weakest slots**: empty ones ("Ring: empty. Any ring is an upgrade") and the worn pieces adding least, with a better bag item named when you have one.

**Comparing.** Select a bag item you can wear and the Reliquary shows what changes if you equip it instead of what you wear now: health, spell power, essence, essence per second, move speed, thrall health and thrall damage. **Green** is a gain and **red** is a loss. A two-handed weapon is compared against both your main hand and your off-hand, since both leave your hands. For necromancer weapons it also says what changes about your left click ("Left click becomes a reaping arc").

**Item level and affixes.** Gear you find now drops *rolled*. Each piece has an **item level** (the level of what dropped it, +2 from an elite, +4 from a boss, +5 from a boss's first kill) and up to **three affixes**. The server rolls them the moment the piece drops, so they cannot be edited in a save. Affixes name the item (`Gravebound Iron Helm of the Legion`) and change its colour: one affix is green, two blue, three purple (a rarer base item keeps its own colour). Bosses always leave at least one affix and a first kill at least two. An affix is either a stat (`+6 INT`, as a prefix like *Occult* or a suffix like *of the Seer*) or a **necromancer lever**, marked with a violet **†**: *Gravebound* (thralls hit harder), *of the Legion* (thrall health), *Whispering* (essence regeneration), *of the Rotting Mist* (wider Miasma), *Blighted* (more Withered stacks) and *of the Ossuary Wall* (less damage taken per thrall). The levers work for any class but only matter to the four necromancer disciplines; on another class the tooltip says "no effect for you". Hover a piece to see its item level, every affix and what each one does for *you*. The ▲/▼ arrow, the power score and the Character sheet all count affixes (the sheet has an **Item affixes** block and an "Item affixes" row inside the formulas they feed). Higher item levels and more affixes also sell for more and salvage a little richer (an extra-material chance and more Salvaging XP). **Sell all junk** and **Salvage all below rare** skip any piece with a necromancer affix. The Codex (**K**, Item affixes tab) lists every affix and its range at item levels 10 and 40. Pieces from before this update stay as they are, with their base stats and no item level.

<img src="docs/screenshots/affix-tooltip.webp" alt="An affixed ring tooltip" width="300" />

**Thrall gear: the Legion (Y, or the Legion button under the tool belt).** Necromancers can give spare gear to the dead instead of salvaging it. The Legion has two slots, **Weapon** (any weapon or off-hand) and **Armour** (a helm, chest, legs, boots or gloves), held in reserved inventory slots 120-121 beside the tool belt: they take no bag space, and Sell all junk, Salvage, the Vault and bag saves never touch them. A piece's stat points (STR, AGI, INT and VIT, including flat stat affixes) become thrall bonuses: a **weapon** gives +1% thrall damage and +0.3% attack speed per point, **armour** gives +1.2% thrall health per point (capped at +35% damage, +10% attack speed, +45% health per piece). A Copper Sword (4 points) is +4% damage; a Crypt-Iron Crozier (10) is +10% damage and +3% attack speed; an Iron Chestplate (11) is +13.2% health. *Gravebound*, *of the Legion* and *of the Ossuary Wall* affixes count too, at 60% of their worn strength; other affixes are yours alone. None of it ever changes your own stats. The bonus rides the same thrall multipliers as set bonuses, so it shows on the Character sheet ("Legion kit" and "Legion reinforcement" rows). It applies to thralls you raise after a change; thralls already standing keep what they were raised with. Archers and bone mages carry the kit's bow and staff, and every kit-wearing thrall takes a light wash of the armour's colour. Select a spare in the Reliquary and the detail strip says what it would do for the legion; the Legion panel ranks every spare weapon and armour piece with a green **▲** or red **▼** against what the legion wears now.

<img src="docs/screenshots/thrall-gear/legion-panel.webp" alt="The Legion panel: two kit slots, the legion's bonus, Reinforce and ranked spare gear" width="460" />

Three thralls without the kit (left) and with it (right): the archer's baked bow, the bone mage's staff, a light wash on chest and hands.

<img src="docs/screenshots/thrall-gear/thralls-plain.webp" alt="Thralls without the kit" width="300" /> <img src="docs/screenshots/thrall-gear/thralls-kit.webp" alt="Thralls with the kit" width="300" />

**Reinforce** is the gold sink: twelve tiers, each +3% thrall health and damage and +1% attack speed, for 120 gold at the first tier and 1.65 times more each time (the last costs 29,615; all twelve about 75,000). Like Damage and Wave Speed the tiers reset when you Ascend; the kit pieces stay. On the overall power score (Gravecaller, level 20) a copper kit is worth about +1%, an iron kit +2.6%, an iron kit at tier 6 +7.5%, tier 12 alone +9% and the best kit at tier 12 about +20%; the other necromancers gain 5-16% at the top, since thralls are a smaller part of their power.

**The character sheet (J, or the Sheet button beside the paper doll).** Lists your final Health, Spell power, Max essence, Essence per second, Move speed, Thrall health, Thrall damage and Damage upgrade, plus your STR, AGI, INT and VIT totals. Click any line to open its breakdown: the base, your level, each worn piece, your discipline, boons, Damage tiers and the weapon line. Brews and other timed effects are not included. The Codex (**K**, Stats tab) carries the same table. The Set bonuses block lists each worn set and its bonuses.

## Gathering and crafting

The **Sexton's Acre**, west of the Chapterhouse, contains every tier of the four gathering skills without combat, and the stations that process them (Sawpit, Bone Kiln, Cooking Fire and the Bone Grinder). Click a node to work it; it depletes and later returns. Higher tiers need the matching skill level. Press **P** for your skill levels, next unlocks, and AFK controls. The **Codex (K)** has a Professions tab for node details.

| Skill | Level 1 start | What you collect and make |
|---|---|---|
| **Woodcutting** | Coffin-Oak | Logs; mill them into planks at the **Sawpit**. |
| **Mining** | Copper or Tin Seam | Ore for ingots, equipment, and tools at the **Workbench**. |
| **Fishing** | Still Pool | Fish; cook them into healing meals at the **Cooking Fire**. |
| **Gravedigging** | Pauper's Grave | Bones and occasional finds; grind bones into bone meal at the **Bone Kiln**. |

Carry a matching hatchet, pickaxe, rod, or spade to improve gathering success; the best one you carry counts. Tools can live **on the tool belt**: four slots under the paper doll in the Reliquary (hatchet, pickaxe, rod, spade; reserved inventory slots 110-113). Select a tool and press **Put on belt** (or double-click it); double-click it on the belt to take it off, which needs a free bag slot. A belted tool counts exactly like one in the bag (the best of belt and bag wins, for manual, auto and AFK gathering), takes no bag space, is never sold, salvaged or stored by the bulk buttons, and is what the hero holds while gathering. With an empty belt and tools in your bag, the Reliquary offers once to put your best tools on the belt. **Skills (P)** shows which tool each skill is using. The Workbench crafts stronger tools from ingots and planks. Some hunting grounds also hold richer nodes, but enemy hits interrupt gathering there.

<img src="docs/screenshots/tool-belt.webp" alt="The tool belt under the paper doll" width="460" />

With **Auto gathering** enabled in Settings, clicking a node can continue to another of the same kind. For longer sessions, use **P → choose a node tier → Start AFK** while in the Acre. Your character keeps working while the game is open. A full bag pauses work; movement, casting, or **Pause AFK** stops it. Closing the game ends the session, so it does not earn rewards while offline. When work stops, **the Sexton’s Ledger** shows your finds, their worth, skill gains and personal bests.

**Sexton’s Contracts (O)** offers three delivery orders a day, based on what your skills can make. Deliver from your bag for gold and sometimes an item; completing all three gives a bonus and builds a daily streak. **Grave Gardening (U)** gives you four Mourning Beds and two Coffin Patches. Plant seeds or saplings and return later; plots grow in real time even while you are away, and bone meal makes them grow faster.

**Ossuary Vault (V).** A sarcophagus in the Chapterhouse holds a **120-slot shared stash** (three tabs of 40) for every character on your account. Press **V** in the Chapterhouse or the Acre. Click an item to move its whole stack across; **Deposit materials** stores every unlocked material and consumable, **Deposit all** stores everything unlocked that you are not wearing, and **Sort** merges stacks and orders the Vault by type, rarity and name. Moves stack first, then fill free slots, and a move that will not fit changes nothing. Worn gear and locked items are never stored by the bulk buttons.

<table><tr><td><img src="docs/screenshots/ossuary-vault.webp" alt="Ossuary Vault" /><br /><sub>The Ossuary Vault (V)</sub></td><td><img src="docs/screenshots/bone-grinder.webp" alt="Bone Grinder salvage panel" /><br /><sub>Salvage at the Bone Grinder</sub></td></tr></table>

**Salvaging** is a seventh skill, worked at the **Bone Grinder** beside the Bone Kiln in the Acre. Tick gear in its panel (or press **Salvage** on an item in the Reliquary while you stand at the Grinder) and **Salvage selected**, or use **Salvage all below rare** for every unlocked common and uncommon piece. Each piece gives an ingot by rarity (copper, iron, silver or steel, gold, hell, moon), or a plank from staffs, wands and grimoires (oak, willow, yew or ghostwood, blackthorn, bone elder), plus Grave Dust and, on better gear, Wraith Ectoplasm, Plague Bile, Cinder Ash and bone meal. Every Salvaging level adds a 0.5% chance of one extra material, and it grants a mastery cape at 99. If the yield will not fit your bag, nothing is ground. The **Codex (K → Professions)** lists the yields by rarity.

**Alchemy** is brewed in **the Alchemist's Wing**, through the Chapterhouse's east door: click the **Great Cauldron** (or the Alembic) to brew, and the **Reagent Shelf** to see every herb, reagent and ichor you have found. Each day one brew is the cauldron's pick and gives one extra the first time you make it there. The Workbench's **C → Alchemy** tab still works. Start with four Grave Dust from the Hollow Graves or Catacomb Warren to brew a Grave-Dust Tonic at level 1. Later, Wraith Ectoplasm drops from spirit enemies, Plague Bile from the Cloister, and Cinder Ash from the Pyre. Area bosses always leave an ichor; the Mire Mother’s ichor combines with drowned lotus for a Moonlight Elixir. Forage Rot-cap in the Cloister and Ash-bloom in the Pyre from Gardening level 1, then grow their seeds in the Acre at Gardening 35 and 50. Bog myrtle and drowned lotus grow in the Fen. The **Codex (K → Professions → Reagents)** lists sources, brew effects, recipes and Alchemy levels. Equip an elixir or tonic on your belt in the Reliquary, then use **Z** or **X**.

<table><tr><td><img src="docs/screenshots/alchemist-wing.webp" alt="The Alchemist's Wing and the Great Cauldron" /><br /><sub>The Alchemist's Wing</sub></td><td><img src="docs/screenshots/reagent-shelf.webp" alt="The Reagent Shelf collection" /><br /><sub>The Reagent Shelf</sub></td></tr></table>

**Grave Laborers (H)** gather slowly for up to eight hours while you fight, explore or are away. Collect their work and the Ledger shows what they found. You begin with one laborer and gain another for every 50 total gathering levels, up to four. In the Sexton’s Acre you can **watch them work**: each laborer stands beside a node of its post with a hatchet, pickaxe, spade or fishing rod (chopping, digging or fishing; one that is full rests). A gold check over a laborer means its work is ready; hover it for the post and time, click it to open the Laborers. **Capes & Pets (N)** has a mastery cape for level 99 in each of the seven skills, total-level mantles (the Sexton’s Mantle now needs all seven at 99), and five companions found as rare charms while gathering, from laborers, or from garden harvests. Adopt a charm permanently; other players see your cape and companion.

<table><tr><td><img src="docs/screenshots/laborer-woodcutting.webp" alt="Laborer chopping" /></td><td><img src="docs/screenshots/laborer-mining.webp" alt="Laborer mining" /></td></tr></table>

<table><tr>
<td><img src="docs/screenshots/gathering.webp" alt="Working a gathering node" /><br /><sub>Working a node</sub></td>
<td><img src="docs/screenshots/skills-panel.webp" alt="The Skills panel" /><br /><sub>Skills (P)</sub></td>
<td><img src="docs/screenshots/codex-professions.webp" alt="The Codex Professions tab" /><br /><sub>Codex professions</sub></td>
</tr></table>


**Craft many at once.** Every Workbench and Cauldron recipe has a quantity control: − / +, **×5**, **Max** (as many as your materials and bag room allow) and **Craft ×N**. A batch stops at the first problem and tells you how many were made. In the bag, stacks have **Sell all (N · gold)** with a confirm in place; locked items are never sold.

## Ascension

After defeating the **Bell-Sworn Prelate** during a run, visit the **Altar of Ascension** in the Chapterhouse. Ascending trades your current run for **Ashes** and one Ascension rank. The Altar shows the reward and asks you to confirm the reset.

| Reset on Ascension | Kept on Ascension |
|---|---|
| Damage and Wave Speed tiers, soul shards, area kill counts, and opened seals | Character level and XP, gold, items, profession progress, Ashes, purchased Covenant Boons, and Ascension rank |

Ashes buy permanent **Covenant Boons** at the Altar, including more health, cheaper upgrades, a stronger start, faster seals, and an extra thrall. More Prelate kills, a higher peak Wave Speed, and more kills during a run increase its Ashes reward. Each Ascension rank makes enemies and bosses three levels older and raises gold and XP rewards. The rank cap is **20**.

![The Altar of Ascension and its Covenant Boons](docs/screenshots/altar-of-ascension.webp)

## Playing together and getting help

When co-op is available, joining places you in a world with room for up to **10 players**. Players in the same world share chat, combat, gathering node depletion, and boss activity; each character receives their own finds and progression. Press **Enter** to chat. If the realtime service is unavailable, the game continues as a solo world.

**Covenant counsel** cards appear when you first encounter important systems, one at a time and at a calm moment (see *Your first hour*). You can move them, turn them off in Settings, or choose **Show tips again** there. Hover or focus an ability icon for its cost, target, effects, and combat tip. The **Codex (K)** records rites, enemies, bosses, and professions you have encountered.

![A Covenant counsel tip in game](docs/screenshots/covenant-counsel.webp)

For technical setup and deployment, see [docs/README.md](docs/README.md) and the [VPS handoff](docs/DEATH-MUFFIN-HANDOFF.md).

## Offline play status

The standalone **Death Muffin Offline** edition lives at [muffindevelopment.com/death-muffin/offline/](https://muffindevelopment.com/death-muffin/offline/). Open it while connected, create a local player, then select **Download for offline play**. Wait for “Ready to play without a network” before disconnecting. The download is about 105 MB; your browser may also offer **Install app**. The game and save stay on this device. Clearing site data removes the save, so use a browser profile you keep.

**Moving a save between offline and online.** After reconnecting, open **Sync complete save** in the offline game and sign in with your online Death Muffin account. The panel compares the two characters (level, XP, gold, items, professions, Ascension), then lets you choose:

- **Load offline save online** replaces your online character with the offline one: level, gold, inventory and equipment, professions, necromancer progress, Chronicle, contracts, garden, laborers, capes and pets. The game asks you to confirm first. Both saves must use the same discipline.
- **Load online save on this device** copies your online character into the offline edition as a separate local player, so your existing local save is untouched.

Before anything is replaced, the server keeps a copy of **both** versions. The panel lists your last saved versions, and **Restore** puts any of them back. If the online character changed after you compared (for example, another tab was still playing), the load is refused until you compare again. Close any open online game tab first and reopen it afterwards. Your password is only used to sign in for the sync and is not stored by the offline edition.

Developers can still run `npm run dev` with `?offline` for the browser mock, or run `npm run build:offline` to prepare the standalone edition in `dist-offline/`.
