# Proposal: Workbench recipes for the old sell-only trade goods

Status: **implemented** 3 Oct 2026 on branch `claude/trade-goods-recipes` as `server/death-muffin/backend/migrations/028-trade-goods-recipes.sql` (generated from `src/content/tradeGoods.ts`; `tools/build-trade-goods-sql.mjs --check`). One change: the Bronze Warden Kit takes `ingot_bronze` x6 + `plank_oak` x2 (60 in, 55 out), because the table's 3 x 9 + 2 x 3 = 33 in against 55 out broke the proposal's own "never pays out more than it eats" rule. The rune-socket gem idea below stays an open owner question.
Context: `docs/polish/loot.md` item 14. The Sexton's Contracts already use all of these (no migration); this adds a second use each.

Recipes live in the live `recipes` / `recipe_ingredients` tables (migrations 004, 009, 014 are generated from the content files), so they cannot ship without SQL.
If approved: add the rows to a content file, generate `028-trade-goods-recipes.sql` with a `--check` test like `tools/build-alchemy-sql.mjs`, and add the rows to `ALL_RECIPE_ROWS`.

| Recipe id | Profession / level | Result | Ingredients | Vendor check (inputs vs result) |
|---|---|---|---|---|
| `craft_bronze_warden_kit` | mining 12 | `kit_iron_warden` x1 | `ingot_bronze` x3, `plank_oak` x2 | 3 x 9 + 3 = 30 in, 55 out; same as the iron recipe (iron is also 9) |
| `craft_tin_augment` | mining 5 | `augment_copper` x1 | `ingot_tin` x2 | 8 in, 8 out |
| `craft_garnet_ring` | mining 8 | `ring_copper` x1 | `gem_grave_garnet` x1, `material_copper_bar` x2 | 28 in, 12 out (a loss, so no loop) |
| `craft_opal_flask` | fishing 20 | `flask_damage` x2 | `gem_bone_opal` x1, `fish_fillet` x3 | 51 in, 40 out |

Not proposed: anything that pays out more vendor value than it eats, and anything that turns a Covenant Seal or Reliquary Fragment into a rune or legendary (that is new loot, against "reduce the loot").
Open design question for the owner: rune sockets that need a gem (garnet for uncommon runes, opal for rare, sapphire for epic). It would be a code-only change to `runes.cjs`, the Reliquary and the mock, but it gates a core mechanic on a rare drop, so it was left out.
