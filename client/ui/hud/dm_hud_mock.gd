class_name DmHudMock
extends RefCounted
## Mock view-models for the gallery and tests. Numbers match what the web HUD shows for a mid-level necromancer.

const A := "res://ui/hud/art/"


static func slots(cd_ms: Array = [0, 4200, 0, 900, 0, 0]) -> Array:
	var ids := ["spear", "exhume", "miasma", "litany", "corpse-explosion", "bone-fan"]
	var costs := [18, 12, 25, 40, 15, 0]
	var keys := ["1", "2", "3", "4", "RMB", "R"]
	var totals := [6000, 8000, 10000, 12000, 3000, 1000]
	var out: Array = []
	for i in 6:
		out.append({
			"icon": A + "abilities/necro-%s.webp" % ids[i], "key": keys[i], "cost": costs[i],
			"left_ms": cd_ms[i], "total_ms": totals[i], "affordable": true,
			"empowered": false, "locked": i == 5, "unlock_level": 10, "alt": i == 4, "swap": false,
		})
	return out


static func minimap(px: float = 0.0, pz: float = 20.0) -> Dictionary:
	var w: Dictionary = DmDb.slice("world") if DmDb.exists("slice/world") else {"areas": {}, "doors": []}
	var areas: Array = []
	for id in w["areas"]:
		var a: Dictionary = w["areas"][id]
		# A new character's seals: only these four are open; the rest (e.g. the Ossuary) stay sealed.
		areas.append({"id": id, "rect": a["rect"], "safe": a.get("safe", false), "unlocked": id in ["chapterhouse", "acre", "alchemist_wing", "graves"]})
	var doors: Array = []
	for d in w.get("doors", []):
		doors.append({"rect": d["rect"], "open": bool(d.get("open", false))})
	return {
		"px": px, "pz": pz, "facing": 0.6, "areas": areas, "doors": doors,
		"enemies": [{"x": px + 8, "z": pz - 10, "elite": false}, {"x": px + 12, "z": pz - 4, "elite": false}, {"x": px - 9, "z": pz - 14, "elite": true}, {"x": px + 3, "z": pz - 18, "elite": false}],
		"thralls": [{"x": px - 2, "z": pz - 3}, {"x": px + 2, "z": pz - 2}, {"x": px - 3, "z": pz + 1}],
		"allies": [], "corpses": [{"x": px + 5, "z": pz - 6}, {"x": px - 6, "z": pz - 8}],
		"boss": null, "waystones": [{"x": 9.0, "z": 26.5}], "stairs": [], "npcs": [{"x": -4.0, "z": 12.0, "fresh": true}, {"x": 5.0, "z": 18.0, "fresh": false}],
		"ping": null, "destination": {"x": px + 10, "z": pz - 20}, "depths": null,
	}


static func brews() -> Array:
	return [
		{"slot": "heal", "key": "Q", "label": "Mending", "glyph": "✚", "color": 0xe58aa8, "active": false, "left": 0, "frac": 0.0, "count": 3, "empty": false, "tip": "Mending draught: heals over a few seconds."},
		{"slot": "elixir", "key": "Z", "label": "Moonlit", "glyph": "☾", "color": 0xbcd0ff, "active": true, "left": 41, "frac": 0.68, "count": 2, "empty": false, "tip": "Moonlit: +25% damage."},
		{"slot": "tonic", "key": "X", "label": "", "glyph": "◆", "color": 0x9ff5e0, "active": false, "left": 0, "frac": 0.0, "count": 0, "empty": true, "tip": "Empty: drag a tonic here from the Reliquary."},
	]


static func combat() -> Dictionary:
	return {
		"hp": 1264, "max_hp": 1900, "barrier": 180, "essence": 62, "max_essence": 100, "resource_label": "Grave Essence", "resource_color": "",
		"level": 31, "xp": 18420, "xp_next": 29500, "dev": false,
		"auto_combat": {"on": false, "available": true, "visible": true},
		"primary": {"icon": A + "abilities/necro-needle.webp", "key": "LMB"},
		"slots": slots(), "souls": 7, "souls_max": 10, "thralls": 5, "thrall_cap": 8, "raises_thralls": true,
		"gold": 48210, "shards": 12,
		"damage": {"tier": 9, "pct": 72, "cost": 540},
		"wave": {"owned": 4, "active": 4, "pct": 48, "cost": 1126},
		"area_name": "The Hollow Graves", "area_progress": "Wave <b>14</b> · 212 / 300 kills",
		"ward": {"pct": 30, "thralls": 5, "per_thrall": 0.06},
		"brews": brews(), "save": {"text": "Saved 2 min ago", "warn": false},
		"target": {"name": "Grave Warden", "elite": true, "affixes": [{"id": "bellTolled", "name": "Bell-Tolled"}, {"id": "vengeful", "name": "Vengeful"}], "hp": 5200, "max_hp": 9000,
			"statuses": [{"icon": A + "ui/soul_shard.webp", "label": "Hexed", "n": 2}, {"icon": A + "ui/gold.webp", "label": "Plague", "n": 5}], "blurb": "Walks slowly, hits like the bell."},
		"boss": null,
		"party": [{"id": "a", "name": "Helix", "discipline": "Bell Monk", "portrait": A + "portraits/hollow_knight.webp", "hp_frac": 0.8}, {"id": "b", "name": "Moth", "discipline": "Gravecaller", "portrait": A + "portraits/gravecaller.webp", "hp_frac": 0.35}],
		"omen": {"name": "Blood Moon", "icon": A + "ui/blood_moon.webp", "blurb": "Elites drop more.", "visible": true},
		"depth": null, "chain": {"count": 23, "name": "Rampage", "bonus": 0.15, "frac": 0.6, "tier": 2},
		"minimap": minimap(), "next": null, "prompt": null, "hint": "Click to move · hold to attack",
		"death": {"show": false, "sub": ""}, "reveal": {"hud.spells": false}, "new": {},
	}


static func boss() -> Dictionary:
	var v := combat()
	v["hp"] = 480
	v["barrier"] = 0
	v["target"] = null
	v["boss"] = {"name": "The Bone Abbess", "phase": 2, "hp": 41200, "max_hp": 80000}
	v["chain"] = null
	v["slots"] = slots([0, 0, 0, 0, 0, 0])
	v["slots"][2]["empowered"] = true
	v["slots"][3]["affordable"] = false
	v["souls"] = 10
	v["area_name"] = "The Nave"
	v["area_progress"] = "<b>Boss</b> · phase 2 of 3"
	return v


static func calm() -> Dictionary:
	var v := combat()
	v["target"] = null
	v["chain"] = null
	v["ward"] = null
	v["party"] = []
	v["thralls"] = 0
	v["raises_thralls"] = true
	v["area_name"] = "The Chapterhouse"
	v["area_progress"] = "Sanctuary"
	v["hp"] = 1900
	v["barrier"] = 0
	v["souls"] = 0
	v["slots"] = slots([0, 0, 0, 0, 0, 0])
	v["slots"][0]["swap"] = true
	v["next"] = "Take the east door to the Hollow Graves."
	v["prompt"] = "<kbd>E</kbd> Open the Reliquary"
	v["dev"] = true
	v["omen"]["visible"] = false
	v["depth"] = {"depth": 7, "kills": 20, "need": 20, "open": true, "chest": true}
	v["reveal"] = {}
	v["new"] = {"hud.upgrades": true, "menu.atlas": true, "hud.shards": true}
	v["grimoire_new"] = true
	var mm := minimap(0.0, 20.0)
	mm["ping"] = {"x": 9.0, "z": 26.5}
	v["minimap"] = mm
	return v
