# Gravecrawl: what it taught us

Gravecrawl (gravecrawl.com, "A co-op descent", a free browser co-op gothic ARPG by Majid Manzarpour) is the owner's quality bar. Studied 2026-10-02 as an
ordinary visitor (about 20 short sessions, waves 1-3 only, no mini-boss or boss seen). Nothing from it was copied; only principles are kept here. The
screenshots and the full teardown are in git history (before 2026-10-09).

It is smaller than Death Muffin (4 classes, about 6 enemies) and plainer in a fight. It feels better because of the frame around the fight.

## Lessons

1. **Say what the game is in one sentence, everywhere.** A verb phrase that tells the structure, on every screen, matching the first minute.
2. **Fight within seconds.** About 5 s from Start to wave 1, no account, one tutorial card. First enemy within 20 s of landing.
3. **Every session ends in a number.** A results card (what you reached, kills, gold, time), a personal best, a one-click retry and a share line. A fast
   reward rhythm (60-90 s), not 40 minutes.
4. **A 3-card draft between waves** makes each run different, with a reroll for gold and a ready button.
5. **Restrained palette, readable fight.** Cool neutral floor, one signature accent, warm gold for rewards, red for danger. Enemy, player and ground must differ in
   hue and value; violet is for magic, not for the whole world.
6. **A small HUD.** About 6 groups in a fight. Menus and upgrades collapse until asked for.
7. **Painted 2D art gives the authored look.** Logo, class cards, ability icons and mode thumbnails in one illustrator-grade style; display type loaded before the game.
8. **Small-screen play is first class** (twin-stick, portrait layout). Not a goal for the current PC-first Godot game.
9. **Joining is one link.** A copyable invite, a party frame, a toast when someone joins.
10. **Performance tiers are adaptive and cheap:** pixel-ratio cap, animation LOD by distance, HUD updated at 20 Hz, few lights.

## Where Death Muffin is already ahead

Depth and persistence, readable gear, necromancer identity (thralls, corpses, the Legion), spell colour meaning and VFX variety, content breadth.

## Open ideas (not planned; see ROADMAP.md for what is)

A bounded "sortie" run with a draft of army-themed boons and a result card; a daily seeded descent with a leaderboard; a campaign meter such as "Diocese reclaimed
N/8"; a tagline such as "Raise a legion from the dead. Reclaim the diocese."
