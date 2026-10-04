class_name DmGatherSfx
extends RefCounted
## Port of src/audio/gatherSfx.ts: the sound of one work cycle (the skill's own, except where the map has a finer one).


static func gather_sfx(skill: String, kind: String = "") -> String:
	if skill == "mining" and kind == "seam":
		return "pickOre"
	if kind == "herb":
		return "gatherHerb"
	if skill == "gardening":
		return "gardenTend"
	if skill == "alchemy":
		return "brewTick"
	if skill == "salvaging":
		return "grind"
	var skills: Dictionary = DmContent.get_export("gameplay_gatheringRules", "SKILLS")
	if skills.has(skill):
		return str(skills[skill]["sfx"])
	return "shovel"
