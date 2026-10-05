class_name DmGameActions
extends RefCounted
## Flasks, meals, brews and the belt, Recall, waystone travel, interactables (stations / NPCs / bosses / stairs) and boss summons,
## ported from WorldScene.ts (drinkFlask, eatMeal, drinkBuff, drinkBelt, startRecall, travel, teleportTo, interact, summonBossNormal,
## callEmpowered, openAltar).

var g
var flask_cd_until = 0.0
var meal_until = 0.0
var meal_rate = 0.0
var belt: Dictionary = {"elixir": "", "tonic": ""}
var recall_fx: Variant = null


func _init(game) -> void:
	g = game


func belt_key() -> String:
	return "dm_belt_%d" % g.hero_id


func load_belt() -> void:
	var raw = g.store.get_item(belt_key())
	if raw == "":
		return
	var v: Variant = JSON.parse_string(raw)
	if v is Dictionary:
		for slot in ["elixir", "tonic"]:
			var id: Variant = v.get(slot)
			belt[slot] = id if (id is String and DmContent.brews().has(id) and DmContent.brews()[id]["slot"] == slot) else ""


func save_belt() -> void:
	g.store.set_item(belt_key(), JSON.stringify(belt))


func set_belt(id: String) -> void:
	var b: Variant = DmContent.brews().get(id)
	if b == null:
		return
	belt[b["slot"]] = id
	g.store.set_item(belt_key(), JSON.stringify(belt))
	g.toast("%s is on your belt: press %s to drink it" % [b["label"], String(DmContent.get_export("brews", "BREW_KEYS")[b["slot"]]).to_upper()], "good")


func belt_brew(slot: String) -> String:
	var pick: String = belt[slot]
	if pick != "" and g.inventory.count(pick) > 0:
		return pick
	for id in DmContent.brews():
		if DmContent.brews()[id]["slot"] == slot and g.inventory.count(id) > 0:
			return id
	return ""


func drink_belt(slot: String) -> void:
	var id = belt_brew(slot)
	if id == "":
		if g.player.alive:
			g.float_text(g.player.x, 2.4, g.player.z, "No healing potions" if slot == "heal" else "Empty %s slot" % slot, "info")
			g.toast(empty_hint(slot))
		return
	drink_buff(id)


func empty_hint(slot: String) -> String:
	if slot == "heal":
		return "Healing: no potions yet. Brew Moss Tonic from Mourning Moss in the Alchemist's Wing (east door of the Chapterhouse), or loot them from the dead. Press Q to drink one."
	var kind = "elixir" if slot == "elixir" else "tonic"
	return "Empty %s slot. Click it to pick %s %s from your bag, or drag one here from the Reliquary. Brew them in the Alchemist's Wing. Press %s to drink it." % [kind, "an" if slot == "elixir" else "a", kind, "Z" if slot == "elixir" else "X"]


func drink_buff(id: String) -> void:
	var b: Variant = DmContent.brews().get(id)
	if b == null or not g.player.alive or g.inventory.count(id) <= 0:
		return
	var before: Variant = g.p["brews"].get(b["slot"])
	var prev: Variant = DmContent.brews().get(before["id"]) if (before != null and g.now_ms < float(before["until"])) else null
	if not g.inventory.consume(id):
		return
	var r = DmBrews.apply_brew(g.p["brews"], id, g.now_ms)
	var text: String
	if r["replaced"] and prev != null:
		text = "%s replaces %s" % [b["label"], prev["label"]]
	elif r["extended"]:
		text = "%s extended · %ds" % [b["label"], DmMath.js_round((float(r["until"]) - g.now_ms) / 1000.0)]
	else:
		text = "%s · %ds" % [b["label"], int(b["seconds"])]
	g.float_text(g.player.x, 2.2, g.player.z, text, "gold")
	if g.visual:
		g.vfx.emit({"x": g.player.x, "y": 0.8, "z": g.player.z, "count": 18, "color": int(b["color"]), "spread": 0.4, "speed": 0.6, "up": 1.8, "life": 0.8, "size": 0.24})
	g.play_sfx("drinkElixir")
	g.emit_game_event("brew_drunk")


func eat_meal(id: String) -> void:
	var meal: Variant = DmBrews.meal(id)
	var now: float = g.now_ms
	if meal == null or not g.player.alive:
		return
	if now >= meal_until and g.inventory.count(id) > 0:
		g.play_sfx("eatMeal")
	if now < meal_until:
		g.float_text(g.player.x, 2.4, g.player.z, "Still eating", "info")
		return
	if not g.inventory.consume(id):
		return
	meal_until = now + float(meal["seconds"]) * 1000.0
	meal_rate = (g.player.max_hp() * float(meal["healFrac"])) / float(meal["seconds"])
	g.float_text(g.player.x, 2.2, g.player.z, "Well fed · +%d%% over %ds" % [DmMath.js_round(float(meal["healFrac"]) * 100.0), int(meal["seconds"])], "gold")
	if g.visual:
		g.vfx.emit({"x": g.player.x, "y": 0.8, "z": g.player.z, "count": 14, "color": 0xe9c98f, "spread": 0.4, "speed": 0.4, "up": 1.2, "life": 0.8, "size": 0.22})
	g.emit_game_event("meal_eaten")


func drink_flask(prefer: String = "") -> void:
	if prefer != "" and DmBrews.meal(prefer) != null:
		eat_meal(prefer)
		return
	if prefer != "" and DmContent.brews().has(prefer):
		drink_buff(prefer)
		return
	var now: float = g.now_ms
	if not g.player.alive or now < flask_cd_until:
		return
	if bool(g.prog.vow_fx().get("noFlasks", false)):
		g.float_text(g.player.x, 2.4, g.player.z, "Dry Cellar", "info")
		g.toast("Your Dry Cellar vow forbids healing flasks. Brews and meals still work.")
		return
	var flasks: Dictionary = DmContent.healing_flasks()
	var id = prefer if (prefer != "" and flasks.has(prefer)) else DmPotionBelt.heal_pick(func(f: String) -> int: return g.inventory.count(f))
	if id == "" or not g.inventory.consume(id):
		g.float_text(g.player.x, 2.4, g.player.z, "No healing potions", "info")
		g.toast(empty_hint("heal"))
		return
	flask_cd_until = now + DmBrews.heal_cooldown_ms()
	var amount: float = g.player.max_hp() * float(flasks[id])
	g.player.heal(amount)
	g.float_text(g.player.x, 2.2, g.player.z, "+%d" % DmMath.js_round(amount), "heal")
	g.play_sfx("drinkFlask")
	if g.visual:
		g.vfx.emit({"x": g.player.x, "y": 0.5, "z": g.player.z, "count": 26, "color": 0xc85a8a, "spread": 0.5, "speed": 0.6, "up": 2.2, "life": 0.9, "size": 0.3})


func legion_places() -> int:
	var n = 0
	for t in g.combat.my_thralls():
		n += int(DmThralls.weight(String(t.kind)))
	return n


# ---- recall / travel -----------------------------------------------------------------------------------------------------------

func start_recall() -> void:
	if not g.player.alive or g.recall_at > 0.0:
		return
	if g.gather != null:
		g.gather.stop("moved")
	if g.area_id == "chapterhouse":
		g.float_text(g.player.x, 2.4, g.player.z, "Already in the Chapterhouse", "info")
		return
	g.player.stop()
	g.recall_at = g.now_ms + g.RECALL_MS
	g.play_sfx("recallStart")
	if g.visual:
		recall_fx = g.vfx.decal({"tex": "sigil", "color": 0x8f9ed1, "x": g.player.x, "z": g.player.z, "r": 1.4, "duration": g.RECALL_MS / 1000.0, "opacity": 0.9, "growFrom": 0.2, "spin": 3.0})
	if g.avatar != null and g.avatar.has_method("cast"):
		g.avatar.cast("cast", 1.0)


func cancel_recall() -> void:
	if g.recall_at <= 0.0:
		return
	g.play_sfx("recallCancel")
	g.recall_at = 0.0
	if recall_fx != null and recall_fx.has_method("kill"):
		recall_fx.kill()
	recall_fx = null


func travel(area: String) -> void:
	var near_stone = false
	for it in g._waystones:
		if DmSimMath.hypot(float(it["x"]) - g.player.x, float(it["z"]) - g.player.z) < 5.0:
			near_stone = true
			break
	if not near_stone and g.area_id != "chapterhouse":
		g.toast("Stand beside a waystone to travel (or press T to return home)", "err")
		return
	for it in DmContent.area(area)["interactables"]:
		if it["kind"] == "waystone":
			teleport_to(float(it["x"]), float(it["z"]) + 1.6)
			return


func teleport_to(x: float, z: float) -> void:
	g.play_sfx("waystoneTravel")
	if g.gather != null:
		g.gather.stop("left")
	if g.visual:
		g.vfx.emit({"x": g.player.x, "y": 1.0, "z": g.player.z, "count": 50, "color": 0x8f9ed1, "spread": 0.6, "speed": 1.5, "up": 2.5, "life": 1.0, "size": 0.35})
	g.player.teleport(x, z)
	g.input.attack_target = null
	g.input.pending_interact = null
	if g.camera != null:
		g.camera.snap(Vector3(x, 0, z))
	g.send_intent({"t": "recallThralls", "by": g.self_id, "x": x, "z": z})
	if g.visual:
		g.vfx.emit({"x": x, "y": 1.0, "z": z, "count": 50, "color": 0x8f9ed1, "spread": 0.6, "speed": 1.5, "up": 2.5, "life": 1.0, "size": 0.35})


# ---- NPCs / interactables ------------------------------------------------------------------------------------------------------

func npc_spot(id: String) -> Dictionary:
	return DmContent.get_export("npcs", "NPCS")[id] if DmContent.get_export("npcs", "NPCS").has(id) else {}


func nearest_npc() -> String:
	var best = ""
	var best_d: float = float(DmContent.get_export("npcs", "NPC_TALK_RANGE"))
	for id in DmContent.get_export("npcs", "NPC_IDS"):
		var s: Dictionary = DmContent.get_export("npcs", "NPCS")[id]
		var d = DmSimMath.hypot(float(s["x"]) - g.player.x, float(s["z"]) - g.player.z)
		if d < best_d:
			best_d = d
			best = id
	return best


func talk_key() -> void:
	if not g.player.alive:
		return
	if g.dialogue_open:
		g.ui.dialogue.close()
		return
	var id = nearest_npc()
	if id != "":
		talk_to(id)


func talk_to(id: String) -> void:
	if not g.player.alive:
		return
	if g.gather != null:
		g.gather.stop("panel")
	g.player.stop()
	g.input.attack_target = null
	g.input.pending_interact = null
	var s: Dictionary = DmContent.get_export("npcs", "NPCS")[id]
	g.player.face(float(s["x"]), float(s["z"]))
	g.play_sfx("click")
	g.npc_interact.emit(id)


func boss_for_summon(id: String) -> String:
	for b in DmContent.get_export("bosses", "BOSS_IDS"):
		if DmContent.boss(b)["summonId"] == id:
			return b
	return ""


func interact(it: Dictionary) -> void:
	g.input.pending_interact = null
	g.player.stop()
	match String(it["kind"]):
		"inventory": g.open_panel("inventory")
		"forge": g.station_interact.emit("workbench")
		"professions": g.open_panel("professions")
		"waystone": g.station_interact.emit("waystone")
		"stair":
			if g.depths != null:
				g.depths.stair_clicked()
		"depths_down":
			if g.depths != null:
				g.depths.descend()
		"depths_up":
			if g.depths != null:
				g.depths.leave()
		"depths_chest":
			if g.depths != null:
				g.depths.open_chest()
		"kiln", "sawpit", "fire":
			if g.gather != null:
				g.gather.stop("panel")
			g.play_sfx("click")
			g.emit_game_event("station_opened")
			g.station_interact.emit(String(it["kind"]))
		"cauldron", "alembic":
			if g.gather != null:
				g.gather.stop("panel")
			g.play_sfx("click")
			g.emit_game_event("cauldron_opened")
			g.station_interact.emit(String(it["kind"]))
		"reagents":
			if g.gather != null:
				g.gather.stop("panel")
			g.play_sfx("click")
			g.emit_game_event("reagent_shelf_opened")
			g.station_interact.emit("shelf")
		"upgrades": g.station_interact.emit("altar")
		"vault":
			if g.gather != null:
				g.gather.stop("panel")
			g.station_interact.emit("vault")
		"grinder":
			if g.gather != null:
				g.gather.stop("panel")
			g.station_interact.emit("grinder")
		"npc":
			for n in DmContent.get_export("npcs", "NPC_IDS"):
				if String(it["id"]) == DmGuidance.npc_interactable_id(String(n)):
					talk_to(String(n))
					return
		"lectern":
			g.emit_game_event("lectern_used")
			g.station_interact.emit("lectern")
		"boss":
			var id = boss_for_summon(String(it["id"]))
			if id == "":
				id = "prelate"
			var b = g.sim.boss.state
			if b.active:
				var awake: Dictionary = DmContent.boss(String(b.id) if b.id != "" else "prelate")
				if awake["id"] != id:
					g.toast("%s already stirs in %s." % [awake["name"], DmContent.area(String(awake["area"]))["name"]], "err")
				return
			if DmGoldSink.can_empower(id):
				open_altar(id)
				return
			summon_boss_normal(id)


func open_altar(id: String) -> void:
	var bound = false
	var r = await g.api.boss_key_status(g.hero_id)
	if r.ok and r.data is Dictionary:
		bound = (r.data.get("bound", []) as Array).has(id)
	if g.sim.boss.state.active:
		return
	if g.inventory.count(DmGoldSink.COVENANT_SEAL) > 0 or bound:
		g.emit_game_event("boss_key_offer", {"boss": id, "seals": g.inventory.count(DmGoldSink.COVENANT_SEAL), "gold": g.character.get("gold", 0), "shards": g.prog.local["shards"], "bound": bound})
	else:
		summon_boss_normal(id)


## Wake a boss with soul shards (the original way).
func summon_boss_normal(id: String) -> void:
	var def: Dictionary = DmContent.boss(id)
	if g.sim.boss.state.active:
		return
	var ok: bool = g.prog.spend_shards(float(def["shards"])) if id == "prelate" else g.prog.spend_boss_shards(id)
	if not ok:
		g.toast("%s demands %d soul shards (you have %d). Elites carry them." % [def["summonLabel"], int(def["shards"]), int(g.prog.local["shards"])], "err")
		return
	g.send_intent({"t": "summonBoss", "by": g.self_id, "boss": id})


## Call an area boss Empowered (the UI's BossKeyPrompt confirms): the server takes the Seal and gold, then the host wakes it with the flag.
func call_empowered(id: String) -> void:
	if g.sim.boss.state.active:
		var awake: Dictionary = DmContent.boss(String(g.sim.boss.state.id))
		g.toast("%s already stirs in %s." % [awake["name"], DmContent.area(String(awake["area"]))["name"]], "err")
		return
	var reply: Variant = await g.inventory.exclusive(func() -> Variant:
		var r: DmResult = await g.psync.spend_on_server(func() -> DmResult: return await g.api.boss_key_summon(g.hero_id, id))
		if r.ok and r.data is Dictionary and r.data.has("bag"):
			g.inventory.replace(r.data["bag"])
		return r)
	var r: DmResult = reply
	if not r.ok:
		g.toast(r.error if r.error != "" else "The Seal would not take.", "err")
		return
	g.rewards.empower_pending = id
	g.rewards.empower_summon_id = int(r.data.get("summon_id", 0))
	g.toast("Your bound summon answers, free." if r.data.get("reused", false) else "The Seal is spent (%d gold)." % int(r.data.get("cost", 0)), "good")
	g.send_intent({"t": "summonBoss", "by": g.self_id, "boss": id, "empowered": true})
