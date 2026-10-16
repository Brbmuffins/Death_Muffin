class_name DmPbMock
extends RefCounted
## Mock server-shaped data for the panels_b gallery and tests. Item ids are real (data/gathering/gathering.json); numbers are arbitrary.

const NOW := 1790000000000   # a fixed "server now" in epoch ms


static func row(slot: int, item_id: String, qty: int = 1, rarity: String = "", extra: Dictionary = {}) -> Dictionary:
	var m := DmGatherData.item_meta(item_id)
	var d := {
		"id": slot + 1, "slot_index": slot, "item_id": item_id, "name": String(m.get("name", item_id)), "rarity": rarity if rarity != "" else String(m.get("rarity", "common")),
		"item_type": String(m.get("type", "material")), "quantity": qty, "equipped": 0, "sell_value": int(m.get("sell", 0)),
	}
	d.merge(extra, true)
	return d


## An affix roll at quality q (0..1) of its range at this item level, so the Reforge preview shows real ranges.
static func aff(id: String, ilvl: int, q: float) -> Dictionary:
	var r: Variant = DmAffixRules.affix_range(id, float(ilvl))
	return {"id": id, "v": int(r[0]) + int(float(int(r[1]) - int(r[0])) * q)}


static func gear(slot: int, item_id: String, name: String, item_type: String, rarity: String, ilvl: int, affixes: Array = [], extra: Dictionary = {}) -> Dictionary:
	var d := {"id": slot + 1, "slot_index": slot, "item_id": item_id, "name": name, "rarity": rarity, "base_rarity": rarity, "item_type": item_type, "quantity": 1, "equipped": 0, "sell_value": ilvl * 3}
	if not affixes.is_empty() or ilvl > 0:
		d["inst"] = {"id": 100 + slot, "ilvl": ilvl, "affixes": affixes}
	d.merge(extra, true)
	return d


## A bag with materials, seeds, tools and gear.
static func bag() -> Array:
	return [
		row(0, "ore_copper", 14), row(1, "ingot_copper", 3), row(2, "ingot_iron", 2), row(3, "plank_oak", 6), row(4, "herb_mourning_moss", 9),
		row(5, "bone_meal", 4), row(6, "seed_mourning_moss", 5), row(7, "seed_nightshade", 2), row(8, "sapling_oak", 1),
		row(9, "tool_pickaxe_iron", 1, "", {"item_type": "tool"}), row(10, "reagent_grave_dust", 22), row(11, "log_oak", 18),
		gear(12, "sword_bone", "Gravewarden's Blade", "weapon", "epic", 22, [aff("p_thrall_dmg", 22, 0.7), aff("s_thrall_hp", 22, 1.0)]),
		gear(13, "helm_copper", "Rusted Cowl", "armor_head", "common", 0),
		gear(14, "staff_ash", "Ashen Staff", "weapon", "uncommon", 9, [aff("p_essence_regen", 9, 0.4)]),
		gear(15, "ring_copper", "Copper Ring", "ring", "common", 0, [], {"inst": null}),
		gear(16, "robe_tattered", "Tattered Robe", "armor_chest", "uncommon", 6, [aff("s_ward", 6, 0.5)]),
		gear(100, "amulet_bone", "Bone Amulet", "trinket", "rare", 17, [aff("p_thrall_dmg", 17, 0.3), aff("p_essence_regen", 17, 0.9)], {"equipped": 1}),
	]


static func contracts_board(resets_at: String = "2026-10-05T00:00:00.000Z") -> Dictionary:
	return {
		"day": "2026-10-04", "resetsAt": resets_at, "streak": 3,
		"contracts": [
			{"slot": 0, "itemId": "log_oak", "name": "Oak Log", "qty": 12, "rarity": "common", "skill": "woodcutting", "rewardGold": 140, "rewardItem": null, "done": false},
			{"slot": 1, "itemId": "ingot_iron", "name": "Iron Ingot", "qty": 4, "rarity": "uncommon", "skill": "mining", "rewardGold": 520, "rewardItem": {"name": "Moss Tonic", "qty": 3}, "done": false},
			{"slot": 2, "itemId": "herb_nightshade", "name": "Nightshade", "qty": 1500, "rarity": "rare", "skill": "gardening", "rewardGold": 1840, "rewardItem": {"name": "Bone Opal", "qty": 1}, "done": true},
		],
		"bonus": {"gold": 900, "item": {"itemId": "gem_bone_opal", "qty": 1, "name": "Bone Opal"}, "claimed": false},
	}


static func garden_view(now: int = NOW) -> Dictionary:
	return {
		"now": now, "level": 12, "xp": 340, "xpToNext": 600,
		"plots": [
			{"plot": "h0", "kind": "herb", "label": "Mourning Bed I", "seedId": null, "plantedAt": 0, "readyAt": 0, "composted": false, "state": "empty"},
			{"plot": "h1", "kind": "herb", "label": "Mourning Bed II", "seedId": "seed_mourning_moss", "plantedAt": now - 600000, "readyAt": now + 600000, "composted": true, "state": "growing"},
			{"plot": "h2", "kind": "herb", "label": "Mourning Bed III", "seedId": "seed_nightshade", "plantedAt": now - 3000000, "readyAt": now - 1000, "composted": false, "state": "growing"},
			{"plot": "h3", "kind": "herb", "label": "Mourning Bed IV", "seedId": null, "plantedAt": 0, "readyAt": 0, "composted": false, "state": "empty"},
			{"plot": "t0", "kind": "tree", "label": "Coffin Patch I", "seedId": null, "plantedAt": 0, "readyAt": 0, "composted": false, "state": "empty"},
			{"plot": "t1", "kind": "tree", "label": "Coffin Patch II", "seedId": "sapling_oak", "plantedAt": now - 100000, "readyAt": now + 4000000, "composted": false, "state": "growing"},
		],
	}


static func labor_view(now: int = NOW) -> Dictionary:
	return {
		"now": now, "capMs": 8 * 3600000, "totalLevel": 112, "levelsPerSlot": 50,
		"slots": [
			{"slot": 0, "unlocked": true, "nodeType": "seam_iron", "nodeName": "Iron Seam", "skill": "mining", "item": "ore_iron", "startedAt": now - 5 * 3600000},
			{"slot": 1, "unlocked": true, "nodeType": "coffin_oak", "nodeName": "Coffin-Oak", "skill": "woodcutting", "item": "log_oak", "startedAt": now - 2000},
			{"slot": 2, "unlocked": true, "nodeType": null, "nodeName": null, "skill": null, "item": null, "startedAt": 0},
			{"slot": 3, "unlocked": false, "nodeType": null, "nodeName": null, "skill": null, "item": null, "startedAt": 0},
		],
	}


static func levels() -> Dictionary:
	return {"woodcutting": 22, "mining": 31, "fishing": 18, "gravedigging": 41, "gardening": 12, "alchemy": 9, "salvaging": 14}


static func skills() -> Dictionary:
	var out := {}
	var lv := levels()
	for id: String in lv:
		var l: int = lv[id]
		out[id] = {"level": l, "xp": int(DmGathering.xp_to_next(l) * 0.4), "next": DmGathering.xp_to_next(l)}
	out["gravedigging"] = {"level": 99, "xp": 0, "next": DmGathering.xp_to_next(99)}
	return out


static func gather_report() -> Dictionary:
	return {
		"seconds": 5025, "reason": "bagFull", "totalItems": 412, "goldValue": 3880, "gold": 120,
		"items": [
			{"itemId": "log_oak", "name": "Oak Log", "qty": 260, "rarity": "common"},
			{"itemId": "log_elm", "name": "Elm Log", "qty": 140, "rarity": "uncommon"},
			{"itemId": "ring_copper", "name": "Copper Ring", "qty": 1, "rarity": "rare"},
		],
		"skills": [{"name": "Woodcutting", "xp": 2410, "fromLevel": 21, "toLevel": 22}, {"name": "Gravedigging", "xp": 90, "fromLevel": 41, "toLevel": 41}],
		"best": {"itemId": "ring_copper", "name": "Copper Ring", "qty": 1, "rarity": "rare"},
		"milestones": ["500 finds, lifetime"], "records": ["Personal best: 412 finds in one session"],
	}


static func salvage_bag() -> Array:
	return [
		gear(0, "sword_bone", "Gravewarden's Blade", "weapon", "epic", 22, [aff("p_thrall_dmg", 22, 0.7), aff("s_thrall_hp", 22, 1.0)]),
		gear(1, "helm_copper", "Rusted Cowl", "armor_head", "common", 0),
		gear(2, "staff_ash", "Ashen Staff", "weapon", "uncommon", 9, [aff("p_essence_regen", 9, 0.4)]),
		gear(3, "ring_copper", "Copper Ring", "ring", "common", 4),
		gear(4, "robe_tattered", "Tattered Robe", "armor_chest", "uncommon", 6, [aff("s_ward", 6, 0.5)]),
		gear(5, "rune_relic", "Relic Rune", "rune", "rare", 0, [], {"quantity": 3}),
		gear(6, "gloves_old", "Grave Gloves", "armor_hands", "rare", 14, [aff("p_thrall_dmg", 14, 0.2), aff("s_thrall_hp", 14, 0.6)]),
		gear(100, "amulet_bone", "Bone Amulet", "trinket", "rare", 17, [], {"equipped": 1}),
		row(8, "ore_copper", 14),
	]


static func vault_state() -> Dictionary:
	var b: Array = [
		row(0, "ore_copper", 14), row(1, "ingot_iron", 2), row(2, "herb_mourning_moss", 9), row(3, "reagent_grave_dust", 22),
		gear(4, "sword_bone", "Gravewarden's Blade", "weapon", "epic", 22, [aff("p_thrall_dmg", 22, 0.7)]),
		gear(5, "helm_copper", "Rusted Cowl", "armor_head", "common", 0),
		gear(6, "amulet_bone", "Bone Amulet", "trinket", "rare", 17, [], {"equipped": 1}),
		row(9, "flask_hp_minor", 3),
	]
	var v: Array = [
		row(0, "ingot_copper", 40), row(1, "plank_oak", 12), row(2, "bone_meal", 30), row(3, "ore_iron", 25),
		gear(5, "ring_copper", "Copper Ring", "ring", "uncommon", 8, [aff("p_essence_regen", 8, 0.5)]),
		row(41, "log_oak", 99), row(42, "reagent_wraith_ectoplasm", 6), row(80, "gem_grave_garnet", 2),
	]
	return {"bag": b, "vault": v}


static func reforge_pieces() -> Array:
	return [
		gear(12, "sword_bone", "Gravewarden's Blade", "weapon", "epic", 22, [aff("p_thrall_dmg", 22, 0.7), aff("s_thrall_hp", 22, 1.0)]),
		gear(14, "staff_ash", "Ashen Staff", "weapon", "uncommon", 9, [aff("p_essence_regen", 9, 0.4)]),
		gear(100, "amulet_bone", "Bone Amulet", "trinket", "rare", 17, [aff("p_thrall_dmg", 17, 0.3), aff("p_essence_regen", 17, 0.9)], {"equipped": 1}),
		gear(15, "ring_copper", "Copper Ring", "ring", "common", 0),
	]
