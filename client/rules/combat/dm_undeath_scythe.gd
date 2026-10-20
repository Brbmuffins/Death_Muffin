class_name DmUndeathScythe
extends RefCounted
## The Scythe of Undeath (item `scythe_of_undeath`, server/rules/content/undeathScythe.ts): a Reaper test weapon with the three affixes a set could have. Its words
## are the item's lore; the affixes act on her rites, so they are folded into the discipline mods as extra keys, ONLY while it is in her main hand:
##   wraithCount 3 + wraithSpreadDeg 25: Haunting Wraith raises three wraiths, 25 degrees apart, in a cone (rite_haunting_wraith.gd)
##   soulMight 0.02 + soulWard 0.01: each soul in her bag adds this much rite damage (on top of the bag's own +2%, DmAbilities.sp) and cuts this much of the
##     damage she takes (DmPlayerRules.take_damage); the rite caster copies both onto her state when the mods are set
##   soulWraith true: a soul she earns while the bag is full casts a free Haunting Wraith, with every effect above, at an enemy picked at random and
##     weighted towards the near ones (DmNextMeta._bank_reaper_soul, rite_haunting_wraith.gd `free_cast`)

const ITEM_ID := "scythe_of_undeath"
const WRAITHS := 3
const SPREAD_DEG := 25.0
const MIGHT_PER_SOUL := 0.02
const WARD_PER_SOUL := 0.01
const FREE_COOLDOWN_MS := 1000.0   ## at most one free wraith a second, so a pack dying at once does not raise one per corpse


static func worn(slots: Array) -> bool:
	var main: Variant = DmGear.equipped_by_slot(slots).get("main_hand")
	return main != null and String((main as Dictionary).get("item_id", "")) == ITEM_ID


## The mods with the scythe's affixes added (a new Dictionary), or `mods` itself when it is not worn (every other build is untouched).
static func apply(mods: Dictionary, slots: Array) -> Dictionary:
	if not worn(slots):
		return mods
	var out := mods.duplicate()
	out["wraithCount"] = float(WRAITHS)
	out["wraithSpreadDeg"] = SPREAD_DEG
	out["soulMight"] = MIGHT_PER_SOUL
	out["soulWard"] = WARD_PER_SOUL
	out["soulWraith"] = true
	return out
