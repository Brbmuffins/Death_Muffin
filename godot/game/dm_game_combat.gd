class_name DmGameCombat
extends RefCounted
## The defensive half of WorldScene.ts: onHurt (wards, barrier, Bulwark, chill, drag), onDeath, legend sync with the sim, the Bonded Dead boon.

var g
var legend_sig = ""
var legend_sent_at = -1e9


func _init(game) -> void:
	g = game


func my_thralls() -> Array:
	var out: Array = []
	for t in g.sim.thralls.values():
		if t.owner == g.self_id:
			out.append(t)
	return out


func on_hurt_event(ev: Dictionary) -> void:
	if String(ev["player"]) != g.self_id:
		return
	on_hurt(float(ev["dmg"]), String(ev["from"]), float(ev["x"]), float(ev["z"]), ev.get("chillMs"), ev.get("pull"))


func on_hurt(raw: float, from: String, x: float, z: float, chill_ms: Variant = null, pull: Variant = null) -> void:
	var player: DmPlayer = g.player
	if not player.alive:
		return
	var now: float = g.now_ms
	var mods: Dictionary = g.discipline["mods"]
	var n_thralls = my_thralls().size()
	var lantern = 0.0
	for z_ in g.sim.zones.values():
		if z_.kind == "warden_ward" and DmSimMath.hypot(z_.x - player.x, z_.z - player.z) <= z_.r:
			lantern = 0.2
			break
	var auto_guard = 0.3 if (g.settings_store.can_use_auto_combat() and bool(g.settings["auto_combat"]) and (g.discipline["family"] == "knight" or g.discipline["family"] == "veil")) else 0.0
	var flask_ward = DmBrews.brew_ward(g.p["brews"], from, now)
	var ward = float(mods["wardPerThrall"]) * n_thralls + lantern + auto_guard + flask_ward
	var guard = float(mods["colossusGuard"]) if DmLegend.colossus_active(mods, n_thralls) else 0.0
	var barrier_before = float(g.p["barrier"])
	var taken = player.take_damage(raw, ward, now, {"x": x, "z": z}, from, guard)
	var absorbed = barrier_before - float(g.p["barrier"])
	if absorbed >= 1.0:
		g.float_text(player.x, 2.3, player.z, "Warded -%d" % DmMath.js_round(absorbed), "ward")
	if float(mods.get("wardReflect", 0.0)) > 0.0:
		g.abilities.reflect_ward(raw, minf(float(DmLegend.L()["wardCap"]), float(mods["wardPerThrall"]) * n_thralls), x, z)
	if float(g.p["barrierBroke"]) > 0.0:
		var size = float(g.p["barrierBroke"])
		g.p["barrierBroke"] = 0.0
		if float(mods.get("litanyShatter", 0.0)) > 0.0:
			g.abilities.litany_shatter(size)
	if chill_ms != null and taken > 0.0 and player.alive:
		g.p["chilledUntil"] = maxf(float(g.p["chilledUntil"]), now + float(chill_ms))
		g.float_text(player.x, 2.5, player.z, "Chilled", "info")
	if pull != null and taken > 0.0 and player.alive:
		drag_player(pull)
	if g.p["lastBlock"] != "none":
		on_bulwark_block(raw, x, z)
	if taken >= 1.0 and g.gather != null:
		g.gather.stop("hurt")
	if float(g.p["hp"]) < player.max_hp() * 0.5:
		g.tip("hurt")
	g.emit_game_event("hurt_check", {"hp": g.p["hp"], "max_hp": player.max_hp()})
	g.actions.cancel_recall()
	if taken >= 1.0:
		g.float_text(player.x, 2.0, player.z, "-%d" % DmMath.js_round(taken), "hurt")
	g.last_combat_at = now
	g.last_hurt_at = now
	g.emit_game_event("hit_flash")
	g.play_sfx("hurt")
	if player.alive and float(g.p["hp"]) < player.max_hp() * 0.3:
		g.play_sfx("lowHealth")
	if g.camera != null:
		g.camera.shake(0.35 if from == "boss" else 0.12)
	if randf() < 0.35 and g.avatar != null and g.avatar.has_method("play_once"):
		g.avatar.play_once("hurt", 1.6)
	if g.visual:
		var E: Dictionary = DmContent.spell_fx()["enemy"]
		if from == "cone" or from == "boss":
			g.vfx.emit({"x": player.x, "y": 1.0, "z": player.z, "count": 10, "color": int(E["curse"]), "spread": 0.3, "speed": 2.0, "up": 1.0, "life": 0.4, "size": 0.25})
		if from == "ember" or from == "burn":
			g.vfx.emit({"x": player.x, "y": 1.0, "z": player.z, "count": 14, "color": int(E["emberCore"]), "spread": 0.35, "speed": 2.6, "up": 1.8, "life": 0.5, "size": 0.12, "gravity": 7.0})
			g.vfx.emit({"x": player.x, "y": 1.2, "z": player.z, "count": 4, "color": int(E["ember"]), "spread": 0.3, "speed": 1.0, "up": 1.4, "life": 0.7, "size": 0.22})
			if g.camera != null:
				g.camera.shake(0.16)
	if from == "toll" and player.alive:
		var stun: float = float(DmContent.get_export("enemies", "AFFIX_TUNING")["bellTolled"]["stunMs"])
		g.p["rootedUntil"] = maxf(float(g.p["rootedUntil"]), now + stun)
		g.float_text(player.x, 2.5, player.z, "Stunned", "info")
	if not player.alive:
		on_death()


func drag_player(pull: Dictionary) -> void:
	var p: DmPlayer = g.player
	var d = DmSimMath.hypot(float(pull["x"]) - p.x, float(pull["z"]) - p.z)
	var m = minf(float(pull["m"]), maxf(0.0, d - 1.6))
	if m <= 0.05:
		return
	var r: Array = g.nav.resolve(p.x + ((float(pull["x"]) - p.x) / d) * m, p.z + ((float(pull["z"]) - p.z) / d) * m, 0.45)
	p.x = r[0]
	p.z = r[1]
	p.stop()
	g.p["rootedUntil"] = maxf(float(g.p["rootedUntil"]), g.now_ms + float(pull["rootMs"]))
	g.float_text(p.x, 2.5, p.z, "Dragged!", "info")
	if g.camera != null:
		g.camera.shake(0.2)


func on_bulwark_block(raw: float, x: float, z: float) -> void:
	var perfect: bool = g.p["lastBlock"] == "perfect"
	var p: DmPlayer = g.player
	g.float_text(p.x, 2.5, p.z, "Perfect block" if perfect else "Blocked", "info")
	if g.visual:
		g.vfx.decal({"tex": "ring", "color": int(DmContent.spell_fx()["knight"]["steel"]), "x": p.x, "z": p.z, "r": 1.5 if perfect else 1.1, "duration": 0.3, "opacity": 1.0 if perfect else 0.6, "growFrom": 0.5})
	if not perfect:
		return
	g.play_sfx("shard", p.x, p.z, 1.4)
	var best: Variant = null
	var best_d = 0.0
	for e in g.sim.enemies.values():
		if e.state == "dead":
			continue
		var d = DmSimMath.hypot(e.x - x, e.z - z)
		if d <= 1.5 + e.radius and (best == null or d < best_d):
			best = e.id
			best_d = d
	if best != null:
		g.send_intent({"t": "hit", "by": g.self_id, "ids": [best], "dmg": raw * float(DmContent.get_export("abilities", "BULWARK")["reflect"])})


func on_death() -> void:
	g.rewards.chain.reset()
	if g.gather != null:
		g.gather.stop("dead")
	g.dead_until = g.now_ms + g.RESPAWN_MS
	g.input.attack_target = null
	if g.avatar != null and g.avatar.has_method("play_once"):
		g.avatar.play_once("death", 1.0)
	g.play_sfx("playerDeath")
	g.chronicle.add("deaths")
	if g.depths != null:
		g.depths.on_player_death()
	g.emit_game_event("death", {"show": true, "sub": "The Chapterhouse will call you back…"})
	g.hero_died.emit()


## Tell the sim which legendary mechanics it must run for us.
func sync_legend(now: float, force: bool = false) -> void:
	var l = DmLegend.sim_legend_of(g.discipline["mods"])
	var sig = JSON.stringify(l) if DmLegend.sim_legend_active(l) else ""
	if not force and sig == legend_sig and (sig == "" or now - legend_sent_at < 5000.0):
		return
	if sig == "" and legend_sig == "":
		return
	legend_sig = sig
	legend_sent_at = now
	g.send_intent({"t": "legend", "by": g.self_id, "mods": l})


## The Bonded Dead boon: a thrall rises beside you whenever you enter a hunting ground with none.
func tick_bond(now: float) -> void:
	if g._bond_at == 0.0 or now < g._bond_at or not g.player.alive or g.area_id == "depths":
		return
	g._bond_at = 0.0
	if not bool(g.prog.boons()["bondedDead"]) or DmContent.area(g.area_id)["safe"] or g.discipline["family"] != "necromancer":
		return
	if not my_thralls().is_empty():
		return
	var m: Dictionary = g.discipline["mods"]
	var x: float = g.player.x + sin(g.player.facing) * 1.4
	var z: float = g.player.z + cos(g.player.facing) * 1.4
	g.send_intent({"t": "exhume", "by": g.self_id, "x": x, "z": z, "r": 0.8, "kind": m["thrallKind"], "cap": m["thrallCap"], "hp": g.p["stats"]["thrallHp"], "damage": g.p["stats"]["thrallDamage"], "attackSpeedMult": m["thrallAttackSpeedMult"], "bond": true})
	g.toast("Your bonded dead rises beside you", "good")


## The host refused our summon (another boss woke first): refund the shards, or the Seal and gold, we spent.
func on_boss_busy(ev: Dictionary) -> void:
	if ev.get("by") != g.self_id:
		return
	var boss: String = String(ev["boss"])
	var empowered: bool = boss != "prelate" and g.rewards.empower_pending == boss
	if boss == "prelate":
		g.prog.add_shards(int(DmContent.boss("prelate")["shards"]))
	elif empowered:
		g.rewards.empower_pending = ""
		g.inventory.exclusive(func() -> Variant:
			var r: DmResult = await g.psync.spend_on_server(func() -> DmResult: return await g.api.boss_key_refund(g.hero_id, boss))
			if r.ok and r.data is Dictionary and r.data.has("bag"):
				g.inventory.replace(r.data["bag"])
			return r)
	else:
		g.prog.refund_boss_shards(boss)
	var awake: Dictionary = DmContent.boss(String(ev["awake"]))
	g.toast("%s already stirs in %s. %s" % [awake["name"], DmContent.area(String(awake["area"]))["name"], "Your Seal and gold are returned." if empowered else "Your shards are returned."], "err")


# ---- counsel facts (WorldScene.counselBusy / tickOnboarding) -------------------------------------------------------------------

var _last_tip_check := -1e9

## Busy flags for DmCounsel.tick(dt, busy).
func counsel_busy() -> Dictionary:
	var now: float = g.now_ms
	return {"combat": now - g.last_combat_at < 4000.0, "hurt": now - g.last_hurt_at < 4000.0, "dead": not g.player.alive}


## Every 400 ms: the lastCombatAt / lastHurtAt bookkeeping of tickOnboarding (a fight is three living dead within 9 m, or the boss awake).
func tick_counsel(now: float) -> void:
	if now - _last_tip_check < 400.0 or not g.player.alive:
		return
	_last_tip_check = now
	var p: DmPlayer = g.player
	if g.sim.boss.state.active:
		g.last_hurt_at = now
		g.last_combat_at = now
	else:
		var near := 0
		for e in g.sim.enemies.values():
			if e.state != "dead" and DmSimMath.hypot(e.x - p.x, e.z - p.z) < 9.0:
				near += 1
				if near >= 3:
					g.last_combat_at = now
					break


## The state-based counsel facts (DmCounselEvents.tick_calls ctx); the UI asks every 400 ms.
func counsel_tick_ctx() -> Dictionary:
	var p: DmPlayer = g.player
	var corpses_near := 0
	var pack := false
	for c in g.sim.corpses.values():
		if DmSimMath.hypot(c.x - p.x, c.z - p.z) > 7.0:
			continue
		corpses_near += 1
		if not pack:
			var n := 0
			for e in g.sim.enemies.values():
				if e.state != "dead" and DmSimMath.hypot(e.x - c.x, e.z - c.z) < 3.0:
					n += 1
			pack = n >= 3
	var wave_cost: int = g.prog.wave_cost()
	var has_tool := false
	var has_belt := false
	var brews: Dictionary = DmContent.brews()
	var flasks: Dictionary = DmContent.healing_flasks()
	for s in g.inventory.slots:
		var id := String(s["item_id"])
		if id.begins_with("tool_"):
			has_tool = true
		if brews.has(id) or flasks.has(id):
			has_belt = true
	var boss_near: Array = []
	for id in ["gravedigger", "abbess", "congregation", "saint", "regent", "mire"]:
		var def: Dictionary = DmContent.boss(id)
		if g.player.area != String(def["area"]):
			continue
		for it in DmContent.area(String(def["area"]))["interactables"]:
			if it["id"] == def["summonId"] and DmSimMath.hypot(float(it["x"]) - p.x, float(it["z"]) - p.z) < 12.0:
				boss_near.append(id)
	var loc: Dictionary = g.prog.local
	var cheapest := INF
	for k in DmProgContent.vow_order():
		var key := DmAscension.vow_key(String(k))
		if not DmAscension.is_unlocked(loc.get("unlocks"), key):
			cheapest = minf(cheapest, float(DmAscension.unlock_cost(key)))
	for k in DmProgContent.boon_order():
		var key2 := DmAscension.boon_key(String(k))
		if not DmAscension.is_unlocked(loc.get("unlocks"), key2):
			cheapest = minf(cheapest, float(DmAscension.unlock_cost(key2)))
	var gate_near := false
	for d in DmContent.doors():
		if g.nav.is_door_open(d):
			continue
		var dx := maxf(maxf(float(d["rect"]["x0"]) - p.x, 0.0), p.x - float(d["rect"]["x1"]))
		var dz := maxf(maxf(float(d["rect"]["z0"]) - p.z, 0.0), p.z - float(d["rect"]["z1"]))
		if DmSimMath.hypot(dx, dz) < 6.0:
			gate_near = true
			break
	var ctx := {
		"wave_affordable": wave_cost != -1 and float(g.character.get("gold", 0)) >= float(wave_cost), "thralls_mine": my_thralls().size(), "corpses_near": corpses_near,
		"pack_on_corpse": pack, "family": g.discipline["family"], "level": g.character["level"], "total_kills": loc["totalKills"], "has_tool": has_tool,
		"has_belt_item": has_belt, "shards": loc["shards"], "boss_near": boss_near, "has_seal": g.inventory.count(DmGoldSink.COVENANT_SEAL) > 0, "area": g.area_id,
		"cheapest_unlock": cheapest, "boss_kills": loc["bossKills"], "ascension": loc["ascension"], "ashes": loc["ashes"], "gate_near": gate_near,
	}
	return ctx
