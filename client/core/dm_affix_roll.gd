class_name DmAffixRoll
extends RefCounted
## The director's roll of which elite affixes a new body gets: `DmAffixSet.roll` of today's game (godot/next/affixes/dm_affix_set.gd), unchanged. The
## rules the affixes then run by (the bell's ring and toll, Hungering's meals, the shroud, Vengeful's Risen) are in the combat core
## (native/src/core/affixes.cpp); only the roll stays GDScript, so the director's random stream is the same as today's (native/README.md "Design").
## When the roll changes in godot/, change it here.


## Which affixes a new body gets (the sim's spawn_enemy + spawn_at_breach). Elite: the Omen's affix when it forces one, else one of the four;
## in the Depths plus DmSimDepthsRules.pick_extra_affixes. Non-elite: only Nightfall's shroud (`nightfall_chance` > 0 when the Nightfall
## milestone is active). `rand` returns [0, 1).
static func roll(elite: bool, omen_affix: String, depths_depth: float, nightfall_chance: float, rand: Callable) -> PackedStringArray:
	DmSimData.ensure()
	var out := PackedStringArray()
	if not elite:
		if nightfall_chance > 0.0 and float(rand.call()) < nightfall_chance:
			out.append("shrouded")
		return out
	var first := omen_affix
	if first == "":
		first = String(DmSimData.AFFIX_ORDER[int(floorf(float(rand.call()) * DmSimData.AFFIX_ORDER.size()))])
	out.append(first)
	if depths_depth >= 0.0:
		for a in DmSimDepthsRules.pick_extra_affixes(depths_depth, first, rand):
			out.append(String(a))
	return out
