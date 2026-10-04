class_name DmPaMock
extends RefCounted
## Mock data for the panels-A gallery and tests: plain Dictionaries in the exact shapes the panels take (see each panel's header).


static func ascension_state() -> Dictionary:
	return {
		"run": {"prelateKills": 1, "peakWaveTier": 5, "kills": 1240},
		"shards": 350, "ashes": 90, "ascension": 2,
		"unlocks": ["vow:swollen_waves"],
		"boons": {"vigil": 2, "marrow_font": 1},
		"vows": {"elder_dead": 3, "iron_dead": 1},
	}


static func grimoire_state() -> Dictionary:
	var k: Dictionary = DmContent.kit("necromancer")
	return {
		"rites": {"primary": "bone_needle", "keys": ["marrow_spear", "exhume", "miasma", "black_litany", "corpse_explosion"]},
		"level": 12, "unseen": ["bone_fan", "grave_frost"],
		"kit": {"primaries": k["primaries"], "grimoire": k["grimoire"], "rmb": k["rmb"]},
	}


static func runes() -> Dictionary:
	return {"sockets": {"bone_needle": "rune_splinter"}, "owned": {"rune_marrow_tap": 1, "rune_volley": 2, "rune_splinter": 1}}


static func legion() -> Dictionary:
	return {
		"kit": {
			"weapon": {"slot_index": 120, "name": "Grave-Iron Blade", "rarity": "epic", "ilvl": 22, "lines": ["Thralls hit +9% harder", "Thralls attack +2.4% faster"], "unused": ["+8% spell damage"]},
			"armor": null,
		},
		"bonus_lines": ["Thralls hit +12% harder", "Thralls have +6% health", "Thralls attack +3.4% faster"],
		"thrall": {"hp": 188.0, "damage": 14.6},
		"spares": [
			{"slot_index": 7, "name": "Hollow Shield", "rarity": "uncommon", "kit": "weapon", "verdict": "up", "text": "+3% damage"},
			{"slot_index": 9, "name": "Charnel Gloves", "rarity": "common", "kit": "armor", "verdict": "up", "text": "+4% health (fills the empty slot)"},
			{"slot_index": 11, "name": "Tattered Cowl", "rarity": "common", "kit": "armor", "verdict": "down", "text": "-2% health"},
			{"slot_index": 12, "name": "Rusted Ring", "rarity": "common", "kit": "weapon", "verdict": "same", "text": ""},
			{"slot_index": 14, "name": "Plain Staff", "rarity": "common", "kit": "weapon", "verdict": "down", "text": "-1% damage"},
		],
		"tier": 4, "cost": 1250, "gold": 980,
	}


static func cosmetics_view() -> Dictionary:
	var c: Dictionary = DmContent.file("cosmetics")
	var capes: Array = []
	var i := 0
	for cp in c["CAPES"]:
		var d: Dictionary = cp.duplicate()
		var need: int = int(d.get("total", 99))
		d["need"] = need
		d["have"] = need if i < 2 else int(need * (0.2 + 0.1 * i))
		d["unlocked"] = i < 2
		capes.append(d)
		i += 1
		if i >= 5:
			break
	var pets: Array = []
	var j := 0
	for p in c["PETS"]:
		var d: Dictionary = p.duplicate()
		d["adopted"] = j == 0
		pets.append(d)
		j += 1
	return {"totalLevel": 143, "selected": {"cape": "cape_apprentice", "pet": ""}, "capes": capes, "pets": pets}


static func sheet() -> Dictionary:
	var f := FileAccess.open("res://data/panels_a/sheet_sample.json", FileAccess.READ)
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	d["ready"] = true
	return d


static func chronicle() -> Dictionary:
	return {
		"life": {"kills": 18432, "kills.graves": 7210, "kills.ossuary": 5100, "boss.gravedigger": 6, "boss.prelate": 2, "deaths": 41, "peak.depth": 14, "depths.floors": 38, "depths.chests": 12, "peak.level": 31, "peak.wave": 6, "gold.earned": 1284000, "gold.spent": 902300, "sold": 612, "crafted": 188, "gathered.woodcutting": 940, "gathered.mining": 410, "gathered.fishing": 120, "gathered.gravedigging": 560, "afkSeconds": 7200, "playSeconds": 91800},
		"run": {"kills": 1240, "boss.prelate": 1, "deaths": 3, "gold.earned": 96400, "playSeconds": 14400},
		"runNo": 3,
		"runs": [{"runNo": 2, "stats": {"kills": 6100, "boss.prelate": 1, "deaths": 12, "gold.earned": 400000, "playSeconds": 30000}, "endedAt": "2026-09-30T12:00:00Z"}, {"runNo": 1, "stats": {"kills": 4800, "boss.prelate": 1, "deaths": 20, "gold.earned": 250000, "playSeconds": 22000}, "endedAt": "2026-09-12T08:30:00Z"}],
	}


## Fake per-item verdicts so the Atlas gallery shows the arrows (real ones come from gearStats.itemVerdict).
static func atlas_context() -> Dictionary:
	var a := DmPaData.atlas()
	var verdicts: Dictionary = {}
	var outlooks: Dictionary = {}
	var owned: Dictionary = {"set_gravecaller_chest": {"n": 1, "worn": true}, "helm_copper": {"n": 1, "worn": false}}
	for id in a["item_order"]:
		var it: Dictionary = a["items"][id]
		if not bool(it["gear"]):
			continue
		var fit: float = float(it["fit"].get("gravecaller", 0))
		var pct: float = fit * 1.6 - 3.0
		var kind := "upgrade" if pct > 0.5 else ("downgrade" if pct < -0.5 else "same")
		verdicts[id] = {"kind": kind, "pct": absf(pct), "text": "%s for your Gravecaller: %+.0f%% (stub verdict)" % [kind.capitalize(), pct], "empty": String(it["slot"]) in ["feet", "hands"]}
		if String(it.get("set_id", "")) != "":
			outlooks[id] = {"setName": String(it["set_id"]).capitalize(), "total": 5, "withSetPct": fit * 5.0, "bonusPct": fit * 1.5, "hint": "Set piece 1/5 (next bonus at 2)"}
	return {"disc": "gravecaller", "level": 12, "area": "graves", "owned": owned, "verdicts": verdicts, "outlooks": outlooks}
