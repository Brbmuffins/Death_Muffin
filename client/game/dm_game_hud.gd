class_name DmGameHud
extends RefCounted
## Helpers of the HUD view-model: the art path and the interaction prompts. The view-model itself is DmNextHudVm's, built from the core's bulk arrays
## (the old game's builder read the per-creature sim records, DmSimEnemy).

const ART := "res://assets/game/art/"


static func art(rel: String) -> String:
	return ART + rel


static func interact_prompt(g, it: Dictionary) -> String:
	match String(it["kind"]):
		"inventory": return "Open the Reliquary"
		"forge": return "Open the Workbench"
		"professions": return "Open Skills and AFK gathering"
		"waystone": return "Travel by Waystone"
		"kiln": return "Open Bone Kiln recipes"
		"sawpit": return "Open Sawpit recipes"
		"fire": return "Open Cooking Fire recipes"
		"upgrades": return "Open Ascension"
		"lectern": return "Open the Codex"
		"npc": return "Talk to %s" % it["label"]
		"vault": return "Open the Ossuary Vault (V)"
		"grinder": return "Salvage gear at the Bone Grinder"
		"cauldron": return "Brew at the Great Cauldron"
		"alembic": return "Brew at the Alembic"
		"reagents": return "Browse the Reagent Shelf"
		"stair", "depths_down", "depths_up", "depths_chest":
			return g.depths.prompt(it) if g.depths != null else "Use"
		"boss":
			var b: Dictionary = DmContent.boss(g.actions.boss_for_summon(String(it["id"])) if g.actions.boss_for_summon(String(it["id"])) != "" else "prelate")
			return "Summon %s · %d shards" % [b["name"], int(b["shards"])]
	return "Use"
