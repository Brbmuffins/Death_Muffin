class_name DmGameHud
extends RefCounted
## DmGame.hud_state(): the sim-derived live numbers the HUD needs (WorldScene.updateHud), in the DmHud view-model shape
## (godot/ui/hud/README.md) minus the UI-owned parts (menus, toasts, panels, Next box, tips, party names' portraits are paths here).

const ART := "res://assets/game/art/"


static func art(rel: String) -> String:
	return ART + rel


static func build(g) -> Dictionary:
	var p: DmPlayer = g.player
	var now: float = g.now_ms
	var loc: Dictionary = g.prog.local
	var res: Dictionary = g.p["resource"]
	var family: String = g.discipline["family"]
	var vm = {
		"hp": g.p["hp"], "max_hp": p.max_hp(), "barrier": g.p["barrier"],
		"essence": res["value"], "max_essence": res["max"],
		"resource_label": DmResources.label_for(family), "resource_color": DmResources.color_for(family) if family != "necromancer" else "",
		"beat_pulse": family == "monk" and minf(fmod(now, 1200.0), 1200.0 - fmod(now, 1200.0)) <= 150.0,
		"level": g.character["level"], "xp": g.character.get("experience", 0), "xp_next": DmStats.xp_to_next(float(g.character["level"])),
		"dev": g.dev_access,
		"souls": g.p["souls"], "souls_max": g.p["soulsMax"],
		"thralls": g.actions.legion_places(), "thrall_cap": g.discipline["mods"]["thrallCap"], "raises_thralls": family == "necromancer",
		"gold": int(floor(float(g.character.get("gold", 0)))), "shards": loc["shards"],
		"damage": {"tier": loc["damageTier"], "pct": DmUpgrades.damage_bonus_pct(float(loc["damageTier"])), "cost": null if g.prog.damage_cost() == -1 else g.prog.damage_cost()},
		"wave": {"owned": loc["waveTierOwned"], "active": loc["waveTierActive"], "pct": DmWaveUpgrades.wave_modifiers(float(loc["waveTierActive"]))["speedPct"], "cost": null if g.prog.wave_cost() == -1 else g.prog.wave_cost()},
		"area_name": DmContent.area(g.area_id)["name"], "area_progress": area_progress(g),
		"ward": ward(g), "brews": brews(g), "save": g.last_save_text,
		"auto_combat": {"on": bool(g.settings["autoCombat"]), "available": g.settings_store.can_use_auto_combat() and g.settings["difficulty"] == "easy", "visible": g.settings_store.can_use_auto_combat()},
		"primary": {"icon": art(String(DmAbilities.def(g.primary)["icon"]).replace("art/", "")), "key": "LMB"},
		"slots": slots(g, now),
		"target": target(g), "boss": boss(g), "chain": chain(g, now), "depth": g.depths.hud_state() if g.depths != null else null,
		"omen": {"name": g.omen["name"], "icon": art(String(g.omen["icon"]).replace("art/", "")), "blurb": g.omen["blurb"], "visible": not DmContent.area(g.area_id)["safe"]},
		"party": party(g),
		"minimap": minimap(g),
		"prompt": prompt(g),
		"death": {"show": not g.player.alive, "sub": "The Chapterhouse will call you back…"},
	}
	return vm


static func slots(g, now: float) -> Array:
	var out: Array = []
	var keys = ["1", "2", "3", "4", "RMB", "R"]
	var lvl = float(g.character["level"])
	for i in g.hotbar.size():
		var id: String = String(g.hotbar[i])
		if id == "":
			continue
		var def = DmAbilities.def(id)
		var emp: bool = g.abilities.empowered(id)
		out.append({
			"icon": art(String(def["icon"]).replace("art/", "")), "key": keys[i], "cost": def["essenceCost"],
			"left_ms": DmPlayerRules.cooldown_left(g.p, id, now),
			"total_ms": DmWeaponLine.ability_cooldown_ms(id, float(def["cooldownMs"]), g.p["loadout"], DmAbilities.is_primary(id)),
			"affordable": emp or float(g.p["resource"]["value"]) >= float(def["essenceCost"]), "empowered": emp,
			"locked": DmAbilities.rite_level(lvl, g.dev_access) < DmAbilities.unlock_level(id), "unlock_level": DmAbilities.unlock_level(id),
			"alt": i == 4, "swap": false, "rune_icon": "",
		})
	return out


static func ward(g) -> Variant:
	var per: float = float(g.discipline["mods"]["wardPerThrall"])
	if per <= 0.0:
		return null
	var n: int = g.combat.my_thralls().size()
	var pct = DmMath.js_round(minf(0.6, per * n) * 100.0)
	return {"pct": pct, "thralls": n, "per_thrall": per} if pct > 0 else null


static func area_progress(g) -> String:
	var here: String = g.area_id
	var guided: bool = g.next_active
	if here == "acre":
		return "A gathering sanctuary: click a glowing node to work it" if guided else "Click a glowing node to gather · Walk east to the Chapterhouse for combat"
	if here == "chapterhouse":
		return "Sanctuary: Reliquary, Workbench, Altar and Waystone · East door: the Alchemist's Wing" if guided else "Walk north to the Hollow Graves · Click an enemy to attack · East door: the Alchemist's Wing"
	if here == "alchemist_wing":
		return "Sanctuary: the Great Cauldron, the Alembic and the Reagent Shelf" if guided else "Brew at the Great Cauldron or the Alembic · Browse the Reagent Shelf"
	if here == "depths":
		return g.depths.progress_line() if g.depths != null else ""
	var def: Dictionary = DmContent.area(here)
	if def["safe"]:
		return "Sanctuary. The dead cannot follow you here."
	var pending: Array = []
	for id in DmContent.area_order():
		var u: Variant = DmContent.area(id).get("unlock")
		if u != null and u["area"] == here and not g.prog.really_unlocked(id):
			pending.append({"id": id, "need": g.prog.unlock_kills(float(u["kills"]))})
	pending.sort_custom(func(a, b): return a["need"] < b["need"])
	if not pending.is_empty():
		var kills: int = g.prog.kills(here)
		var lines: Array = []
		for e in pending:
			var door_name = ""
			for d in DmContent.doors():
				if d["b"] == e["id"] and d["a"] != here:
					door_name = " (%s)" % g.rewards.door_direction(d)
					break
			lines.append("%s%s" % [DmGuidance.format_seal_progress(String(e["id"]), float(kills), float(e["need"])), door_name])
		return "<br>".join(lines)
	if here == "sanctum":
		return "The Prelate walks." if g.sim.boss.state.active else "Offer <b>%d/%d</b> soul shards at the Sundered Bell" % [int(g.prog.local["shards"]), int(DmContent.get_export("areas", "BOSS_SUMMON_SHARDS"))]
	return "<b>%d</b> slain here · Level %d dead" % [g.prog.kills(here), int(float(def["level"]) + g.rewards.world_levels())]


static func brews(g) -> Array:
	var now: float = g.now_ms
	var out: Array = []
	var flasks: Dictionary = DmContent.healing_flasks()
	var hid: String = DmPotionBelt.heal_pick(func(f: String) -> int: return g.inventory.count(f))
	var total = 0
	for f in flasks:
		total += g.inventory.count(f)
	var cd_left = maxf(0.0, g.actions.flask_cd_until - now)
	var cd_total = DmBrews.heal_cooldown_ms()
	out.append({"slot": "heal", "key": "Q", "label": "Heal", "glyph": "✚", "color": 0xe0709c, "active": false, "left": 0, "frac": (cd_left / cd_total) if (cd_left > 0.0 and hid != "") else 0.0,
		"count": total, "empty": hid == "", "tip": ("Dry Cellar: your vow forbids healing flasks. Break it at the Altar of Ascension." if bool(g.prog.vow_fx().get("noFlasks", false)) else (("Healing: %s restores %d%% of your health (%d carried). Press Q to drink; sips are %ds apart." % [DmContent.item(hid)["name"], DmMath.js_round(float(flasks[hid]) * 100.0), total, int(cd_total / 1000.0)]) if hid != "" else g.actions.empty_hint("heal")))})
	for slot in ["elixir", "tonic"]:
		var act: Variant = g.p["brews"].get(slot)
		var live: Variant = act if (act != null and now < float(act["until"])) else null
		var belt_id: String = g.actions.belt_brew(slot)
		var shown: String = String(live["id"]) if live != null else belt_id
		var key: String = String(DmContent.get_export("brews", "BREW_KEYS")[slot]).to_upper()
		if shown == "":
			out.append({"slot": slot, "key": key, "label": "Elixir" if slot == "elixir" else "Tonic", "glyph": "⚗" if slot == "elixir" else "✧", "color": 0x8a8aa0, "active": false, "left": 0, "frac": 0.0, "count": 0, "empty": true, "tip": g.actions.empty_hint(slot)})
			continue
		var def: Dictionary = DmContent.brews()[shown]
		var left = int(ceil((float(live["until"]) - now) / 1000.0)) if live != null else 0
		out.append({"slot": slot, "key": key, "label": def["label"], "glyph": def["glyph"], "color": def["color"], "active": live != null, "left": left, "empty": false,
			"frac": minf(1.0, (float(live["until"]) - now) / (float(def["seconds"]) * 1000.0)) if live != null else 0.0,
			"count": g.inventory.count(belt_id) if belt_id != "" else 0,
			"tip": "%s: %s · %ds" % [def["label"], "active" if live != null else "on your belt", int(def["seconds"])]})
	return out


static func target(g) -> Variant:
	var h: Variant = g.input.hover
	var e: DmSimEnemy = null
	if h != null and h["kind"] == "enemy":
		e = g.sim.enemies.get(int(h["id"]))
	elif g.input.attack_target != null and g.input.attack_target["kind"] == "enemy":
		e = g.sim.enemies.get(int(g.input.attack_target["id"]))
	if e == null:
		return null
	var d: Dictionary = DmContent.enemy(e.def)
	var statuses: Array = []
	var S = "art/status/"
	if e.fracture > 0: statuses.append({"icon": art(S + "fracture.webp"), "label": "Fracture", "n": e.fracture})
	if e.withered > 0: statuses.append({"icon": art(S + "withered.webp"), "label": "Withered", "n": e.withered})
	if e.slowT > 0.0: statuses.append({"icon": art(S + "void-rot.webp"), "label": "Miasma", "n": 1})
	var affixes: Array = []
	if e.affix != "":
		var ad: Dictionary = DmContent.get_export("enemies", "ELITE_AFFIXES")[e.affix]
		affixes.append({"id": e.affix, "name": ad["name"]})
	return {"name": d["name"], "elite": e.elite, "affixes": affixes, "hp": e.hp, "max_hp": e.maxHp, "statuses": statuses, "blurb": d.get("blurb", "")}


static func boss(g) -> Variant:
	var b = g.sim.boss.state
	if not b.active:
		return null
	var def: Dictionary = DmContent.boss(String(b.id) if b.id != "" else "prelate")
	return {"name": ("Empowered " if b.empowered else "") + String(def["name"]), "phase": b.phase, "hp": b.hp, "max_hp": b.maxHp, "phases": def["phases"]}


static func chain(g, now: float) -> Variant:
	var c: DmKillChain = g.rewards.chain
	if not c.active() or not g.player.alive:
		return null
	var t: Variant = c.tier()
	var tiers: Array = DmProgContent.get_data()["chain"]["tiers"]
	return {"count": c.count, "name": t["name"] if t != null else "Chain", "bonus": t["bonus"] if t != null else 0.0, "frac": c.frac(now), "tier": (tiers.find(t) + 1) if t != null else 0}


static func party(g) -> Array:
	var d: Dictionary = g.discipline
	var asc = int(g.prog.local["ascension"])
	var out = [{"id": g.self_id, "name": g.self_name, "discipline": "%s · Level %d%s" % [DmContent.discipline(String(d["id"])).get("name", d["id"]), int(g.character["level"]), (" · Ascension %s" % DmAscension.roman(asc)) if asc > 0 else ""],
		"portrait": art("portraits/%s.webp" % d["id"]), "hp_frac": float(g.p["hp"]) / g.player.max_hp()}]
	return out


static func prompt(g) -> Variant:
	var h: Variant = g.input.hover
	if h != null and h["kind"] == "interact" and not g.dialogue_open:
		return "<kbd>Click</kbd> %s" % interact_prompt(g, h["it"])
	var n: String = g.actions.nearest_npc()
	if n != "" and not g.dialogue_open and not g.panel_open:
		return "<kbd>E</kbd> Talk to %s" % DmContent.get_export("npcs", "NPCS")[n].get("name", n)
	return null


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


static func minimap(g) -> Dictionary:
	var areas: Array = []
	for id in DmContent.area_order():
		var a: Dictionary = DmContent.area(id)
		areas.append({"id": id, "rect": a["rect"], "safe": a["safe"], "unlocked": g.prog.is_unlocked(id) or g.dev_access, "instance": a.get("instance", false)})
	var doors: Array = []
	for d in DmContent.doors():
		doors.append({"rect": d["rect"], "open": g.nav.is_door_open(d)})
	var enemies: Array = []
	for e in g.sim.enemies.values():
		if e.state != "dead":
			enemies.append({"x": e.x, "z": e.z, "elite": e.elite})
	var thralls: Array = []
	for t in g.sim.thralls.values():
		thralls.append({"x": t.x, "z": t.z})
	var corpses: Array = []
	for c in g.sim.corpses.values():
		corpses.append({"x": c.x, "z": c.z})
	var stairs: Array = []
	for it in DmContent.area("warren")["interactables"]:
		if it["kind"] == "stair":
			stairs.append(it)
	var npcs: Array = []
	for id in DmContent.get_export("npcs", "NPC_IDS"):
		var s: Dictionary = DmContent.get_export("npcs", "NPCS")[id]
		npcs.append({"x": s["x"], "z": s["z"], "fresh": false})
	var b = g.sim.boss.state
	return {"px": g.player.x, "pz": g.player.z, "facing": g.player.facing, "areas": areas, "doors": doors, "enemies": enemies, "thralls": thralls, "allies": [],
		"corpses": corpses, "boss": {"x": b.x, "z": b.z} if b.active else null, "waystones": g._waystones, "stairs": stairs, "npcs": npcs,
		"ping": null, "destination": g.player.destination(), "depths": g.depths.map_floor() if g.depths != null else null}
