extends "res://tests/common/dm_parity_part.gd"
## Client / server parity for client/rules/combat: replays the fixtures the server's vitest writes (see dm_parity_part.gd).


func fixtures() -> Array:
	return [["rules_combat", "kill"], ["rules_combat", "legion"], ["rules_combat", "runes"], ["rules_combat", "loadout"]]


func call_fn(fn: String, a: Variant) -> Variant:
	match fn:
		"killXpBase": return DmEnemyStats.kill_xp_base(a[0], a[1], a[2], a[3], a[4])
		"killGoldMax": return DmEnemyStats.kill_gold_max(a[0], a[1], a[2], a[3], a[4])
		"newBloodDamageMult": return DmEnemyStats.new_blood_damage_mult(a[0])
		"newBloodXpMult": return DmEnemyStats.new_blood_xp_mult(a[0], a[1])
		"kitIdForType": return DmLegion.kit_id_for_type(a[0])
		"kitSlotId": return DmLegion.kit_slot_id(float(a[0]))
		"statPoints": return DmLegion.stat_points(a[0])
		"pieceBonus": return DmLegion.piece_bonus(a[0], a[1])
		"reinforceBonus": return DmLegion.reinforce_bonus(float(a[0]) if a[0] != null else NAN)
		"legionBonus": return DmLegion.legion_bonus(a[0], float(a[1]))
		"isRuneSlot": return DmRunes.is_rune_slot(a[0])
		"runeSlotRite": return DmRunes.rune_slot_rite(a[0])
		"runeSlotIndex": return DmRunes.rune_slot_index(a[0])
		"runeEquippedSlot": return DmRunes.rune_equipped_slot(a[0])
		"runeFits": return DmRunes.rune_fits(a[0], a[1])
		"socketsOf": return DmRunes.sockets_of(a[0])
		"socketsSignature": return DmRunes.sockets_signature(DmRunes.sockets_of(a[0]))
		"ownedRunes": return DmRunes.owned_runes(a[0])
		"cleanName": return DmOfflineLoadout.clean_name(a[0])
		"normalizePreset": return DmOfflineLoadout.normalize_preset(a[0])
		"applyLoadout":
			var table: Dictionary = a[1]
			return DmOfflineLoadout.apply_loadout(a[0], func(id: String) -> Dictionary: return table.get(id, {"maxStack": 1, "equipSlot": null, "twoHanded": false}), a[2], a[3])
	return "UNKNOWN FN " + fn
