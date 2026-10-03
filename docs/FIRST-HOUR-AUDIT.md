# First-hour audit (2 Oct 2026, branch `dm/first-hour`)

Goal from the owner: **immersive but not overwhelming**, direction that is optional ("up to the player, but some direction would be nice"), necromancer first, everything easy to find.
This is a play-through of a brand-new offline character, what appeared when, what collided, and what was changed. Numbers are game seconds.

## How it was played (and the limits)

- `tools/qa/first-hour-audit.cjs` (phases A-H) drives a fresh offline Ossuary through `window.__cwDebug`: the Sexton's Acre, the Chapterhouse and the Prior, the Hollow Graves, the
  panels (I, J, L, K, P), the Marrow Ossuary, the Alchemist's Wing and the Apothecary, the Acre with a filling bag. Gravecaller, Mourner and Rotweaver were each played through the
  Acre, the Chapterhouse and about 80 s of the Graves. Chromium/swiftshader at 1280x800; the smoke also checks 1920x1080.
- Game time is stepped with `advance()`, and the page's own timers (counsel cards, toasts, banners) run on a virtual clock stepped with it
  (`tools/qa/lib/first-hour-lib.cjs`), so a card ages with game seconds, not with how slow the VPS is. A recorder logs every counsel card, conversation, banner, toast, panel and the
  Next line as it appears and disappears, and flags any two HUD pieces whose boxes overlap.
- **What is real and what is compressed.** Real: the first ~7 minutes (Acre, Chapterhouse, ~155 s of fighting to level 4, then panel visits). Compressed with debug helpers, not
  played: "minute 12" (`xp(1500)`, 150 Graves kills, two gear drops) and "minute 20" (160 more kills, the Ossuary seal, 3 shards). The Marrow Ossuary was fought for real
  (~2.5 minutes, plus a forced elite wraith, golem and censer spawn), the Wing visited with 6 Grave Dust, the Acre revisited with 36 items in the bag. So the "first hour" here is the
  state a player would reach in about an hour, seen at the moments it matters; it is not 60 continuous minutes, and the bot (face the nearest enemy, strike, cycle rites 1-4,
  "drink a flask" under a third health) is not a human: it never stops fighting, never walks away from a pack and died a few times.
- Screenshots were taken at every new popup and every two minutes or so (about 150 frames over the runs), each one looked at. The ones that carry a finding are named below;
  three cropped shots of the polished flow are in `docs/screenshots/first-hour-*.webp` and the README.

## Timeline before the changes (Ossuary, 1280x800)

| When | Where | What appeared |
|---|---|---|
| 0.5 | Acre | Area banner (3 s); **Next**: "Walk north into the Hollow Graves and fight your first dead"; area text under the minimap: "Click a glowing node to gather · Walk east to the Chapterhouse for combat"; the E prompt for the Sexton; the offline hint line; the Omen chip, the Bone Ward readout; a gold **!** on the Sexton |
| 2.5-40.5 | Acre | Card 1 "The Sexton's Acre" (welcome, 38 s): no enemies, click a node, **east** to the Chapterhouse then **north** |
| 41.5-87.6 | Chapterhouse, then the Graves | Card 2, also titled "The Sexton's Acre" (the Acre card, 46 s) - still on screen 40 s into the first fight |
| 90.6-128.6 | Graves | Card 3 "Walk among the dead" (how to fight): **45 s after the first enemy**, queued behind the two above |
| 131.6-174.6 | Graves, mid-surge | Card 4 "People of the Covenant" (43 s) in the middle of a Grave Surge fight |
| 178-205 | Graves/Chapterhouse | Card 5 "The Week's Omen" |
| 206-230 | Chapterhouse | Card "Tithe Bats" (a spawn in the next hall, 40 m away); later "A corpse lies near" (exhume) while standing in the Chapterhouse |
| 285-307 | Graves | "Hurt?" (flask / T / Wave Speed) sat over the pack for 21 s; the core necromancer lesson, "A corpse lies near" (raise a thrall), came after 6 other cards |
| 341-384 | Graves, in combat | "Reagents" (43 s) in the middle of a fight; "Shroud Moth", "Kill Chain" (25 s) |

In the first 160 s of play a counsel card was on screen for **152 s (95 %)**; during the first fight (45-160 s) for **110 of 115 s (96 %)**, and for most of it the card was the stale Acre card.

## Findings, worst first

1. **Five cards back to back at the start.** `welcome`, `move`, `omen`, `acre` and `people` all fired in the first 3 seconds (delays 0.9-2.6 s) and the queue played them one after another,
   25-46 s each (25 s floor, 0.6 s per word), 170 s in all. Nothing deferred, nothing expired, nothing yielded to a fight.
2. **The same thing three times, and two different routes.** From the Acre: the welcome card said east then north; the Acre card (a second card, same title, nearly the same words) said
   it again; the area text said east to the Chapterhouse; the Next line said "Walk north into the Hollow Graves" (north of the Acre is not the way). In the Chapterhouse the area text, the
   Next line and the Prior's answer each said "north to the Graves". In the Graves the area text and the Next line both counted the same seal ("Slay 0/300 to unseal the Marrow Ossuary" /
   "Hollow Graves: 0 / 300 to open the Marrow Ossuary"); the first-fight card arrived last.
3. **Stale cards.** The Acre card was on screen during a Bell-Tolled elite fight in the Graves. First-sight cards for enemies 30-40 m away in the next hall ("Tithe Bats", "A corpse lies near")
   appeared while the hero stood in the Chapterhouse. Every card ran 21-46 s regardless of a fight; "Hurt?" waited behind other cards and then sat for 21 s over the fight.
4. **HUD collisions at 1280x800** (all measured by the recorder, all seen in screenshots): the Damage / Wave Speed panel over the Grave Essence orb (98x80 px) and over the offline hint line
   (which was cut off mid-sentence: "...click swap below"); the XP bar and the chat input under the Health orb (156x44); the counsel card (18-398 x 100-370) on top of the Omen chip, the
   Kill Chain readout and the Bone Ward readout; the counsel card **behind** every panel (Reliquary, Grimoire, Codex), so a panel's own advice was half hidden; the card 38 px over the
   conversation card; the level-up **banner printed over the "new rites join your Grimoire" toast** (unreadable: "...Skull joins your Grimoire. Click here, press L LEVEL 3"); the same toast
   over the elite's name frame; the gold counter over the right orb once gold passed four digits.
5. **The conversation card hid the person talking** when they stood up-screen of the hero (the Sexton from the Acre's south side): the card covers the top 370 px of the view.
6. **Stale or contradicting text.** The Next line "Gathering ... feeds the Workbench (P)"; the Apothecary's blurb "Brews for the Covenant at the Workbench, until the Alchemist's Wing is raised";
   the Grave Dust item text "Take it to the Workbench, Alchemy tab"; the Reagents tip, the Apothecary's lines and the Skills panel ("Brew at the Workbench (C)") sent brewing to the Workbench;
   the bag-full tip said the Vault is "in the Chapterhouse" (the Sexton and the key list say Chapterhouse or Acre); the 80 % tip (`bag_filling`) and the 100 % tip (`bag_full`) both explained
   the Vault and the Grinder.
7. **Moments a new player would be lost.** (a) The first 40 s: three sources, two routes (finding 2). (b) The first fight: no instructions until 90 s, no "raise the dead" until minute 4+.
   (c) Level 2: the new-rites toast was covered by the banner, then a 45 s Grimoire card arrived mid-fight. (d) First loot: the "A relic" card is a calm tip; with continuous fighting nothing ever
   told a bot-like player about the Reliquary (a real player will open it; the Next line does not mention it). (e) Death: "You rise again in the Chapterhouse. Nothing was lost." is clear;
   what to do next is only the Next line. (f) Entering a hall with five new kinds of dead at once (the Ossuary): five first-sight cards, one every ~25 s for two minutes.

## What changed

- **Counsel cadence** (`src/ui/counselCadence.ts`, 25 unit tests; `src/ui/Onboarding.ts` draws what it decides). Every tip has a kind:
  - `urgent` (only "Hurt?"): jumps the queue, may replace any card that has been up 5 s.
  - `danger` (fight lessons and enemy telegraphs): shown in a fight; never in a sanctuary, behind a panel, in a conversation or on the death screen; first-sight cards for enemies keep 40 s apart;
    the core lessons (fight, Exhume, Litany, Corpse Explosion, Soul Harvest) wait up to 120 s for their turn and go before enemy telegraphs; a telegraph that cannot be shown in 20 s is dropped
    (it was about something that has moved on) and returns on the next sighting. A fight lesson can replace a calm card, never one the player asked for.
  - `asked` (the player just opened the Vault, placed a rite on a key, hit the essence wall...): shown at once, stays with its panel.
  - `calm` (everything else, incl. the first-loot, thrall, Wave Speed, area and Omen cards): waits for no fight (3+ enemies within 9 m, or a blow in the last 4 s), no conversation, no banner,
    no open panel, 20 s after the last card closed; a tip starved for 90 s by a long fight may use a lull; at most 4 calm tips wait.
  - Tips on one subject (gear, bag, brewing, Acre, road) keep 150 s apart; cards about a place show only there and leave with the hero; a card steps aside for the death screen and comes back.
- **The opening.** One card ("Take your time": controls, "the Next line offers one optional suggestion at a time"), after the banner; it also counts as the Acre card. The Omen card
  waits 2.5 minutes, the People card 45 s. The fight lesson ("Walk among the dead") fires on the first dead seen in a hunting ground, not in the Acre.
- **One thing at a time on the HUD.** From the Acre the Next line says "Walk east to the Chapterhouse, then north to the Hollow Graves"; while it shows, the area text under the minimap says what
  the place is for ("A gathering sanctuary: click a glowing node to work it") and no longer repeats the seal the Next line counts. In the Wing with Grave Dust, brewing is what the Next line offers.
- **Layout (1280x800 and 1920x1080).** Counsel card top-left under the hero frame (above panels, fades for the 3 s banner); the Omen chip beside the hero frame; Kill Chain, Bone Ward and brews
  start lower; toasts step under a banner and are 480 px at most; the Damage / Wave Speed panel lifts above the Grave Essence orb below 1500 px; XP bar, chat and the currency row narrow below
  1500 px; the offline hint is one short line; the conversation card sits 20 px right of centre.
- **Conversation camera.** While someone talks, the camera eases north (by exactly what it takes) so the speaker and the hero stay below the card, and the "Talk to..." prompt hides.
- **Text.** Every brewing direction now points at the Alchemist's Wing (tips, Apothecary, Skills panel, Grave Dust text on the client and in the server's item table, README); the Vault is
  "Chapterhouse or Acre" everywhere; `bag_full` says what is new (nothing fits, gathering stops).

## Timeline after the changes (Ossuary, 1280x800, same bot)

| When | Where | What appeared |
|---|---|---|
| 0.5 | Acre | Banner; **Next**: "Walk east to the Chapterhouse, then north to the Hollow Graves"; area text "A gathering sanctuary: click a glowing node to work it"; the Sexton's **!** |
| 7-31 | Acre | One card, "Take your time" (appears once the banner has gone). Nothing else queued. |
| 42 | Chapterhouse | The Prior, by `E` (the card steps aside for the conversation) |
| 47-69 | Graves | "Walk among the dead" (fight controls), on the first dead met, 22 s |
| 79, 87 | Graves | One enemy card ("Shroud Moth"), then "Hurt?" (jumps the queue) |
| 111-124 | Graves | "A corpse lies near" (Exhume) |
| 133-174 | Graves | "An elite", then "Black Litany": one card, a gap, the next; never two |
| 184-260 | Graves, panels | "Tithe Bats"; the J / I / L / K / P panels open with no card on top of them; "Your Character sheet" (asked) stays with its panel |
| 250-420 | Ossuary | One card per ~25 s while a new hall's dead arrive (Corpse Explosion, Skull-rats, Sanctified, Soul Harvest, Barrow Ghoul, Choir Wraith) - first-sight cards 40 s apart |
| 405-445 | Ossuary, Wing | "Reagents" (calm: it waited for a lull), then the Apothecary by `E`; in the Wing with Grave Dust the Next line offers brewing |

Measured on the same two windows: a counsel card on screen for **94 of the first 160 s (59 %)**, and **70 of the first 115 s of fighting (61 %)**, against 95 % and 96 % before, and in the
fight every card is about what is happening. At most **one card at any moment** in every run (the audit and the smoke assert it). Overlaps the recorder still reports at 1280x800: a fight-time
card over the area banner for its 2-3 seconds (on purpose: Hurt? must not vanish), toasts crossing a banner for a fraction of a second while they step down, and panels over the HUD (a panel
is meant to cover it). Nothing else, and nothing at 1920x1080 (`tools/qa/first-hour-smoke.cjs` asserts both sizes).

The other three necromancers (Gravecaller, Mourner, Rotweaver; Acre, Chapterhouse, ~80 s of the Graves): the welcome at 6.5-7 s, the fight card at 53-78 s, "Hurt?" at 52-70 s (they
start with less health than the Ossuary), the Grimoire card at 93-109 s after the first level; no page errors, no overlaps beyond the fight-card-over-banner case above.

Screenshots that show the result: `docs/screenshots/first-hour-opening.webp`, `first-hour-first-fight.webp`, `first-hour-sexton-talk.webp` (also in the README).

## Checked against the owner's note about the Sexton

- **The speaker stays in view.** Standing south of the Sexton, he is at screen row 328 with the card closed, under the card (bottom 370) with the card open - before. After: row 443 (the card's
  bottom is 370), the hero below him (`WorldScene.talkFocus`; the smoke asserts it). When zoomed far in, both cannot fit between the card and the hotbar; then the speaker wins and the hero may
  sit behind the bar. The "Click Talk to..." prompt no longer sits over the hero while the card is open.
- **The spade.** Close-up crops (zoom 0.32, idle and talking) show the spade held in his right hand, shaft up, blade resting near the ground; while he talks the arm lifts and the spade moves with
  the hand. It reads as a gravedigger's spade. (The `07-sexton-spade` frame in `alchemy-wing-smoke` was not touched.)

## Not done / still open

- A person has not played this hour: the bot never walks away from a pack, so "calm" cards only ever appeared in lulls and after the 90 s starvation rule. Whether real play has more calm
  moments than the bot is untested; the thresholds (`counselCadence.ts`: 20 s calm gap, 12 s fight-card gap, 40 s enemy / lesson gap, 90 s starvation) are the numbers to tune.
- Level 5-60 content was not re-audited (areas past the Ossuary: Nave, Sanctum, Cloister, Pyre, Fen); their area-intro cards now wait 4.5 s for the banner and for a lull.
- Co-op: the card starts below the party list when there is one; not tried with ten members.
- Frame time and memory were not measured (loaded VPS); the changes are CSS and a few DOM reads per half second.
- Narrow screens (< 1100 px) only got the existing sanity: the toast / card / panel rules above assume a desktop width.
- A card that is cut short by a more urgent one (for example an Exhume card replaced by Hurt?) returns in full later; that can read as a repeat.


## Owner decisions, 3 Oct 2026 (branch `claude/firsthour-owner-decisions`)

- **Seals (polish item 11, resolved).** One formatter, `formatSealProgress(area, kills, need)` in `src/gameplay/guidance.ts`, writes "Ossuary seal: 0/300 kills" and "Warren seal: 0/150 kills" (the door is the last word of the hall's name). The Next line, the area text under the minimap and the Prior's "The seals" and advice answers all use it.
- **SWAP (item 15, resolved).** No swap control under the hotbar until a Grimoire rite beyond the level-1 kit is learned (`swapReady`, `src/ui/firstHourRules.ts`; derived from level, so it needs no extra save). From then on a small swap icon sits where the text was, and the existing once-per-character "The Grimoire" tip (fixture updated) points at it. Slots under the bar show their key only before that.
- **Class picker.** Gravecaller carries a "Recommended for your first run" badge. The picker is only shown to an account with no character, so the badge is always on in that screen; the in-world Class panel (changing class later) has none. All nine disciplines stay one click away.
- Cost: no per-frame work (the hotbar rebuilds only when the rule flips), no new assets.
