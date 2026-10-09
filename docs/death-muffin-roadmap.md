# Death Muffin future features

> **OBSOLETE (archived 2026-10-09).** Early web-era feature wishlist (bots and more). Current plan: [ROADMAP.md](../ROADMAP.md). See [ARCHIVE.md](ARCHIVE.md).

## Game bots

Requested by the owner on 2026-09-27; recorded for future work.

- Bot opponents to fight against, with configurable classes and difficulty.
- Companion bots that join a world, navigate, select targets, manage Grave Essence, raise thralls, and combine spells.
- Persistent grinding bots that gain levels, loot, upgrades, and leaderboard rank through normal gameplay.
- Owner controls to start, pause, stop, and configure bots, including session/world selection and farming limits.
- Identify bot-controlled leaderboard entries and provide a player/bot filter; the owner can choose whether the default board includes both.

There is already a headless combat/farming bot in `src/gameplay/balance/harness.ts`, plus the boss harness used by `npm run balance:boss`. This is a testing foundation, not an authenticated persistent player. Start future work from those decision loops and the existing Intent → WorldSim → SimEvent architecture instead of rebuilding combat.

Start with one server-controlled bot in a dedicated test world. Reuse the existing movement, combat intents, progression rules, and authenticated game services. Verify navigation, corpse targeting, resource management, save/reload, and recovery from death before running persistent sessions. Add personality, opponent tactics, and class-specific strategies after the basic loop works reliably.

## Spell variety

The owner requested more spell choice while preserving existing artwork and smooth gameplay. See [SPELL-VARIETY-PLAN.md](SPELL-VARIETY-PLAN.md) for the proposed loadout system, four MVP additions and later class options. These are future designs; richer spell hover cards describe the shipped kit.
