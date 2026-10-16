class_name DmReaperSet
extends RefCounted
## Soul Harbinger's Raiment, the Reaper's legendary armor set (server/rules/content/legendarySets.ts). Its pieces are the items
## `leg_soul_harbingers_<part>`; the words are in content/setBonuses.json (text-only effects); the bonuses act on her rites, so they are
## folded into the discipline mods as extra keys, and ONLY while enough pieces are worn (every other build is untouched):
##   2 pieces: scytheRadiusMult 2.0 (Scythe Throw's radius, read by rite_scythe_throw.gd)
##   4 pieces: soulShield true (each Unleash Souls wisp that lands adds its damage to her barrier; rite_unleash_souls.gd)
##   5 pieces: soulScythes 15 (each landing wisp leaves a Scythe Throw behind, at most this many at once; rite_unleash_souls.gd)

const SET_ID := "soul_harbingers"
const PARTS: Array[String] = ["head", "chest", "hands", "legs", "feet"]
const SCYTHE_RADIUS_MULT := 2.0
const MAX_SCYTHES := 15


static func item_id(part: String) -> String:
	return DmLegendarySets.item_id(SET_ID, part)


## How many pieces of the set are worn.
static func worn(slots: Array) -> int:
	var by_slot := DmGear.equipped_by_slot(slots)
	var n := 0
	for part in PARTS:
		var s: Variant = by_slot.get(part)
		if s != null and String((s as Dictionary).get("item_id", "")) == item_id(part):
			n += 1
	return n


## The mods with the set's bonuses for the worn pieces added (a new Dictionary), or `mods` itself when fewer than two are worn.
static func apply(mods: Dictionary, slots: Array) -> Dictionary:
	var n := worn(slots)
	if n < 2:
		return mods
	var out := mods.duplicate()
	out["scytheRadiusMult"] = SCYTHE_RADIUS_MULT
	if n >= 4:
		out["soulShield"] = true
	if n >= 5:
		out["soulScythes"] = float(MAX_SCYTHES)
	return out
