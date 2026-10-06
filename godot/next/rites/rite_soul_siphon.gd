extends DmRiteModule
## Soul Siphon (grimoire, level 6): latch a soul tether onto an enemy (range 9, 14 essence, 7 s, power 0.55). For 3 s it drains every 0.5 s: damage (power x
## spell power), heals you for 35 % of it and gives 2 essence a tick. It follows the enemy while you move and breaks when they get beyond 1.4 x the range (or
## die / you die). Numbers: DmAbilities + SOUL_SIPHON. Host: `mem("soul_siphon").tethers`; every peer draws the beams between the caster's body and the enemy
## (visual handles in the peer's own `mem(..).vis`) and ends them early on the host's `end` event. The boss does not exist in the rebuild's world yet.

const Y := 1.1


func _init() -> void:
	id = "soul_siphon"
	steps = true


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var foe := pick_enemy(c, intent["aim"], int(intent["target_id"]))
	if foe == null:
		return "no_target"
	var fp := foe.global_position
	if DmAbilities.shortfall(c.p, id, {"x": fp.x, "z": fp.z}, DmSimConsts.BOSS_RADIUS) > 0.0:
		return "range"
	intent["foe"] = foe
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var S: Dictionary = DmCombatData.const_table("SOUL_SIPHON")
	var def := DmAbilities.def(id)
	var m := c.mem(id)
	var tethers: Array = m.get_or_add("tethers", [])
	var sid := int(m.get("sid", 0)) + 1
	m["sid"] = sid
	var eid := int(c.world.enemy_id(intent["foe"]))
	tethers.append({"sid": sid, "eid": eid, "break_r": float(def["range"]) * float(S["breakMult"]), "dmg": DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id),
		"until": c.now_ms + float(S["durationS"]) * 1000.0, "next": c.now_ms + float(S["tickS"]) * 1000.0})
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "sid": sid, "enemy_id": eid, "dur": float(S["durationS"])})
	return ""


func step(c: DmRiteCaster, _dt: float) -> void:
	var tethers: Array = c.mem(id).get("tethers", [])
	var i := tethers.size() - 1
	while i >= 0:
		var t: Dictionary = tethers[i]
		var done := not bool(c.p["alive"]) or c.now_ms >= float(t["until"])
		while not done and c.now_ms >= float(t["next"]):
			t["next"] = float(t["next"]) + float(DmCombatData.const_table("SOUL_SIPHON")["tickS"]) * 1000.0
			done = not _tick(c, t)
		if done:
			tethers.remove_at(i)
			c.broadcast({"t": "end", "rite": id, "by": c.peer_id, "sid": int(t["sid"])})
		i -= 1


## One drain; false = the tether broke (target gone or out of reach).
func _tick(c: DmRiteCaster, t: Dictionary) -> bool:
	var S: Dictionary = DmCombatData.const_table("SOUL_SIPHON")
	var e := c.world.enemy_by_id(int(t["eid"])) as Node3D
	if e == null or not DmRiteCaster.alive_enemy(e):
		return false
	var gp := e.global_position
	if Vector2(gp.x - float(c.p["x"]), gp.z - float(c.p["z"])).length() > float(t["break_r"]):
		return false
	var dmg := float(t["dmg"])
	if DmStatusSet.hit(e, dmg, c.body):
		c.hit_resolved.emit(id, int(t["eid"]), dmg, false, float(e.get("hp")) <= 0.0)
	c.heal(dmg * float(S["healFrac"]))
	c.gain_essence(float(S["essencePerTick"]))
	c.broadcast({"t": "tick", "rite": id, "by": c.peer_id, "sid": int(t["sid"]), "pos": Vector3(gp.x, Y, gp.z), "amount": dmg})
	c.push_state()
	return true


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var vis: Dictionary = c.mem(id).get_or_add("vis", {})
	var sid := int(ev["sid"])
	match String(ev["t"]):
		"cast":
			var w := c.world
			var eid := int(ev["enemy_id"])
			var body := c.body
			var live := [true]
			var cas := func() -> Variant:
				return Vector3(body.global_position.x, 1.4, body.global_position.z) if live[0] and is_instance_valid(body) else null
			var tgt := func() -> Variant:
				var e := w.enemy_by_id(eid) as Node3D if w != null else null
				return Vector3(e.global_position.x, Y, e.global_position.z) if live[0] and e != null and is_instance_valid(e) else null
			var h: Array = c.fx.siphon_start(float(ev["dur"]), cas, tgt, body.global_position.x, body.global_position.z)
			vis[sid] = {"live": live, "h": h, "drains": 0}
		"tick":
			var pos: Vector3 = ev["pos"]
			var v: Dictionary = vis.get(sid, {})
			var n := int(v.get("drains", 0)) + 1
			if v.has("drains"):
				v["drains"] = n
			c.fx.siphon_tick(pos, Vector3(c.body.global_position.x, 1.4, c.body.global_position.z), n % 2 == 1)
			c.hit_number.emit(pos, float(ev["amount"]), false)
		"end":
			var v2: Dictionary = vis.get(sid, {})
			if v2.is_empty():
				return
			v2["live"][0] = false
			var h2: Array = v2["h"]
			for b in h2[0]:
				DmRiteFx.kill(b)
			DmRiteFx.kill(h2[1])
			DmRiteFx.kill(h2[2])
			vis.erase(sid)
