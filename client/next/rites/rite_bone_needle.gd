extends DmRiteModule
## Bone Needle, the Gravecaller primary: targeting enemy, 380 ms, free, +6 essence per hit, range 11, projectile 26 m/s. Numbers: DmAbilities
## (needle_cast / needle_hit / shortfall); visuals: DmRiteFx.needle_cast / needle_hit (shared with the original game).
## Weapon variants (DmWeaponLine loadout, as the original game): Staff = longer reach + the needle pierces the enemy behind its target; Wand = damage / cadence
## (apply_cast_cost); Sickle = every needle (volley and pierce included) adds a Withered stack; Scythe = no projectile, a melee arc (`_reap`) that takes the
## Splinters / Marrow-Tap runes (Volley is the needle's) and leaves a 1.2 s window in which a kill of one of its victims banks an extra soul (`reaped_souls`).
## On the combat core (client/code.list "Ported"): the target is an id and a DmFoe snapshot, the blow is `c.deal` (the kill is known at once), the Sickle's Withered is
## the core's status. A boss is a foe like any (the host's queries append it after the enemies, `DmFoe.boss`): the needle's range counts its radius, and the Scythe's arc
## counts it separately with its own reach and one of the arc's hits, as today.

const SPEED := 26.0        ## sim_caster._fire_needle
const TARGET_Y := 1.0
const PICK_RADIUS := 1.5   ## aim point -> enemy when the client names no target (input tolerance, not a game number)


func _init() -> void:
	id = "bone_needle"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var foe := pick_enemy(c, intent["aim"], int(intent["target_id"]), PICK_RADIUS)
	if foe == null:
		return "no_target"
	if DmAbilities.shortfall(c.p, id, {"x": foe.x, "z": foe.z, "boss": foe.boss}, DmSimConsts.BOSS_RADIUS) > 0.0:
		return "range"
	intent["foe"] = foe
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var foe: DmFoe = intent["foe"]
	var m := c.mem(id)
	var rn := DmAbilities.rune(c.p, id)
	if bool(c.p["loadout"]["reap"]):
		return _reap(c, foe, m, rn)
	if rn == "rune_volley":
		m["casts"] = int(m.get("casts", 0)) + 1
	var nc := DmAbilities.needle_cast(DmAbilities.sp(c.p, c.now_ms), c.p["loadout"], rn, int(m.get("casts", 0)), c.rand())
	var dmg: float = nc["dmg"]
	var ess: float = nc["essence"]
	var splinters := rn == "rune_splinter"
	var from := c.tip()
	if not nc["volley"]:
		_launch(c, foe.id, from, dmg, ess, splinters, c.rand(), true, false)
		return ""
	# Volley rune: every 4th needle is 3, at the target and the enemies nearest it within reach of the caster (all at one target when it stands alone),
	# each for the volley fraction, the essence of one needle between them, 50 ms apart.
	var V: Dictionary = DmSimData.RUNE_TUNING["volley"]
	var foes: Array = []
	var first := {"id": foe.id, "x": foe.x, "z": foe.z, "e": foe}
	for n in c.foes_in_radius(Vector3(float(c.p["x"]), 0.0, float(c.p["z"])), float(V["reach"]) + 3.0):
		foes.append({"id": n.id, "x": n.x, "z": n.z, "e": n})
	var aims: Array = DmRunes.volley_targets({"x": float(c.p["x"]), "z": float(c.p["z"])}, first, foes)
	while aims.size() < int(V["needles"]):
		aims.append(first)
	var each := DmAbilities.volley_essence_each(ess)
	for i in aims.size():
		var tgt: DmFoe = aims[i]["e"]
		var f := Vector3(from.x + (i - 1) * 0.12, from.y, from.z)
		var crit := c.rand()
		if i == 0:
			_launch(c, tgt.id, f, dmg, each, false, crit, true, true)
		else:
			c.after(i * 50.0, func() -> void: _launch(c, tgt.id, f, dmg, each, false, crit, false, true))
	return ""


## One needle in flight: damage and essence on arrival, and (Splinters) a shard to the nearest other enemy. `lead` = it carries the cast's muzzle fx.
func _launch(c: DmRiteCaster, eid: int, from: Vector3, dmg: float, ess: float, splinters: bool, crit_roll: float, lead: bool, volley: bool) -> void:
	var foe := c.foe(eid)
	if foe == null:
		return
	var to := Vector3(foe.x, TARGET_Y, foe.z)
	c.after(from.distance_to(to) / SPEED * 1000.0, func() -> void: _arrive(c, eid, dmg, ess, crit_roll, splinters))
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "from": from, "to": to, "enemy_id": eid, "speed": SPEED, "volley": volley and lead, "lead": lead})


func _arrive(c: DmRiteCaster, eid: int, dmg: float, essence: float, crit_roll: float, splinters: bool = false) -> void:
	var e := c.foe(eid)
	if e == null:
		return
	var hit := DmAbilities.needle_hit(dmg, crit_roll)
	var amount: float = hit["amount"]
	var r := c.deal(eid, amount)
	if float(r["dealt"]) <= 0.0:
		return
	var killed := bool(r["killed"])
	c.gain_essence(essence)
	c.broadcast({"t": "hit", "rite": id, "by": c.peer_id, "enemy_id": eid, "pos": Vector3(e.x, TARGET_Y, e.z), "amount": amount, "crit": bool(hit["crit"])})
	c.hit_resolved.emit(id, eid, amount, bool(hit["crit"]), killed)
	var lo: Dictionary = c.p["loadout"]
	_wither(c, eid, amount, lo, killed)
	if float(lo["needlePierce"]) > 0.0:
		_pierce(c, e, dmg * float(DmSimData.NECRO_WEAPON_TUNING["staff"]["pierceDamageMult"]), int(lo["needlePierce"]), lo)
	if splinters:
		_splinter(c, e, dmg)
	c.push_state()


## Sickle: the needle adds one Withered stack (the strongest dps wins, the cap is the discipline's like every other source).
func _wither(c: DmRiteCaster, eid: int, dealt: float, lo: Dictionary, killed: bool) -> void:
	if float(lo["needleWithered"]) <= 0.0 or killed:
		return
	c.apply_status(eid, &"withered", 1, -1.0, {"dps": dealt * float(DmSimData.WITHERED["dpsPerStack"]), "cap": minf(12.0, maxf(1.0, floorf(DmLegend.effective_withered_cap(c.mods))))})


## Staff: the needle carries on through the nearest enemy(ies) behind its target, in its lane, for the pierce fraction.
func _pierce(c: DmRiteCaster, first: DmFoe, dmg: float, count: int, lo: Dictionary) -> void:
	var T: Dictionary = DmSimData.NECRO_WEAPON_TUNING["staff"]
	var pool: Array = []
	for n in c.foes_in_radius(Vector3(float(c.p["x"]), 0.0, float(c.p["z"])), float(T["pierceReach"]) + 14.0):
		if n.id != first.id:
			pool.append({"id": n.id, "x": n.x, "z": n.z, "radius": n.radius, "e": n})
	var nxt := DmWeaponLine.pierce_targets({"x": float(c.p["x"]), "z": float(c.p["z"])}, {"x": first.x, "z": first.z, "id": first.id}, pool, count)
	if nxt.is_empty():
		return
	var hits: Array = []
	for d: Dictionary in nxt:
		var o: DmFoe = d["e"]
		var r := c.deal(o.id, dmg)
		if float(r["dealt"]) <= 0.0:
			continue
		var killed := bool(r["killed"])
		c.hit_resolved.emit(id, int(d["id"]), dmg, false, killed)
		_wither(c, o.id, dmg, lo, killed)
		hits.append({"eid": int(d["id"]), "pos": Vector3(o.x, TARGET_Y, o.z)})
	if not hits.is_empty():
		c.broadcast({"t": "pierce", "rite": id, "by": c.peer_id, "from": Vector3(first.x, TARGET_Y, first.z), "hits": hits, "amount": dmg})


## Scythe: an arc (maxHits enemies inside the cone, the boss counted separately with its own reach), instant, no crit, +4 essence a hit. Splinters sends a
## shard from the first victim to the nearest enemy the arc missed. `m["reaped"]` {enemy id: window end ms} feeds `reaped_souls`.
func _reap(c: DmRiteCaster, foe: DmFoe, m: Dictionary, rn: String) -> String:
	var T: Dictionary = DmSimData.NECRO_WEAPON_TUNING["scythe"]
	var px := float(c.p["x"])
	var pz := float(c.p["z"])
	var dx := foe.x - px
	var dz := foe.z - pz
	var l := DmWeaponLine.hypot2(dx, dz)
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	var caster := {"x": px, "z": pz}
	var aim := {"x": foe.x, "z": foe.z}
	var pool: Array = []
	var boss: DmFoe = null
	for n in c.foes_in_radius(Vector3(px, 0.0, pz), float(T["bossReach"]) + 6.0):
		if n.boss:
			boss = n
		else:
			pool.append({"id": n.id, "x": n.x, "z": n.z, "radius": n.radius, "e": n})
	var struck := DmWeaponLine.reap_targets(caster, aim, pool)
	var hit_boss := boss != null and not DmWeaponLine.reap_targets(caster, aim, [{"x": boss.x, "z": boss.z, "radius": DmSimConsts.BOSS_RADIUS}], float(T["bossReach"])).is_empty()
	var hits: Array = struck.slice(0, maxi(0, int(T["maxHits"]) - (1 if hit_boss else 0)))
	var landed := hits.size() + (1 if hit_boss else 0)
	var rc := DmAbilities.reap_cast(DmAbilities.sp(c.p, c.now_ms), rn, c.rand(), landed)
	var dmg: float = rc["dmg"]
	var reaped: Dictionary = m.get_or_add("reaped", {})
	if reaped.size() > 64:
		for k in reaped.keys():
			if float(reaped[k]) < c.now_ms:
				reaped.erase(k)
	var spots: Array = []
	var skip: Array[DmFoe] = []
	for d: Dictionary in hits:
		var o: DmFoe = d["e"]
		var r := c.deal(o.id, dmg)
		if float(r["dealt"]) <= 0.0:
			continue
		reaped[int(d["id"])] = c.now_ms + float(T["reapWindowMs"])
		skip.append(o)
		spots.append(Vector3(o.x, TARGET_Y, o.z))
		c.hit_resolved.emit(id, int(d["id"]), dmg, false, bool(r["killed"]))
	var boss_pos := Vector3.INF
	if hit_boss:
		var br := c.deal(boss.id, dmg)
		if float(br["dealt"]) > 0.0:
			boss_pos = Vector3(boss.x, TARGET_Y, boss.z)
			c.hit_resolved.emit(id, boss.id, dmg, false, bool(br["killed"]))
	if spots.size() + (1 if boss_pos != Vector3.INF else 0) > 0:
		c.gain_essence(float(rc["essence"]))
	c.broadcast({"t": "reap", "rite": id, "by": c.peer_id, "px": px, "pz": pz, "dx": dx, "dz": dz, "hits": spots, "boss": boss_pos, "amount": dmg})
	if rn == "rune_splinter" and not skip.is_empty():
		_splinter(c, skip[0], dmg, skip)
	c.push_state()
	return ""


## Extra souls for a kill of an enemy this caster's scythe struck in the last 1.2 s (the host's kill-credit path asks once per own kill).
func reaped_souls(c: DmRiteCaster, eid: int) -> float:
	var reaped: Dictionary = c.mem(id).get("reaped", {})
	if reaped.is_empty() or c.world == null:
		return 0.0
	if not reaped.has(eid):
		return 0.0
	var until := float(reaped[eid])
	reaped.erase(eid)
	return float(DmSimData.NECRO_WEAPON_TUNING["scythe"]["soulsPerKill"]) if c.now_ms <= until else 0.0


## Splinters rune: a shard flies to the nearest OTHER enemy within reach for 30 % of the needle's (uncritted) damage.
func _splinter(c: DmRiteCaster, first: DmFoe, dmg: float, skip: Array[DmFoe] = []) -> void:
	var fd := {"id": first.id, "x": first.x, "z": first.z}
	var skip_ids := PackedInt32Array()
	for k in skip:
		skip_ids.append(k.id)
	var pool: Array = []
	for n in c.foes_in_radius(first.pos(), float(DmSimData.RUNE_TUNING["splinter"]["reach"]) + 3.0):
		if n.id != first.id and not skip_ids.has(n.id):
			pool.append({"id": n.id, "x": n.x, "z": n.z, "e": n})
	var tg: Variant = DmRunes.splinter_target(fd, pool)
	if tg == null:
		return
	var o: DmFoe = tg["e"]
	var amount := DmAbilities.splinter_damage(dmg)
	var r := c.deal(o.id, amount)
	if float(r["dealt"]) <= 0.0:
		return
	c.hit_resolved.emit(id, int(tg["id"]), amount, false, bool(r["killed"]))
	c.broadcast({"t": "splinter", "rite": id, "by": c.peer_id, "from": Vector3(first.x, 1.0, first.z), "pos": Vector3(o.x, 1.0, o.z), "amount": amount})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	match String(ev["t"]):
		"cast":
			var from: Vector3 = ev["from"]
			var to: Vector3 = ev["to"]
			if bool(ev.get("lead", true)):   # a volley's other needles are shots only
				c.fx.needle_cast([from.x, from.y, from.z], from.x, from.z, bool(ev.get("volley", false)))
			c.fx.shot(from, follow_enemy(c, int(ev["enemy_id"]), to, TARGET_Y), float(ev["speed"]), 0.0, "needle", DmFxData.spell("needle", "trail"))
		"hit":
			var pos: Vector3 = ev["pos"]
			c.fx.needle_hit([pos.x, pos.y, pos.z], bool(ev["crit"]))
			c.hit_number.emit(pos, float(ev["amount"]), bool(ev["crit"]))
		"pierce":
			var from2: Vector3 = ev["from"]
			var hs: Array = ev["hits"]
			for h: Dictionary in hs:
				var hp: Vector3 = h["pos"]
				c.fx.pierce_shot(from2, DmRiteModule.follow_enemy(c, int(h["eid"]), hp, TARGET_Y), hp.x, hp.z)
				c.hit_number.emit(hp, float(ev["amount"]), false)
			var first_pos: Vector3 = (hs[0] as Dictionary)["pos"]
			c.fx.pierce_sound(first_pos.x, first_pos.z)
		"reap":
			var rdx := float(ev["dx"])
			var rdz := float(ev["dz"])
			var landed := 0
			for sp: Vector3 in ev["hits"]:
				c.fx.reap_hit(sp.x, sp.z)
				c.hit_number.emit(sp, float(ev["amount"]), false)
				landed += 1
			var bp: Vector3 = ev["boss"]
			if bp != Vector3.INF:
				landed += 1
				c.fx.reap_boss(bp.x, bp.z, float(ev["px"]), float(ev["pz"]), rdx, rdz)
				c.hit_number.emit(bp, float(ev["amount"]), false)
			c.fx.reap_swing(float(ev["px"]), float(ev["pz"]), rdx, rdz, landed)
		"splinter":
			var to: Vector3 = ev["pos"]
			c.fx.splinter_shard(ev["from"], to)
			c.hit_number.emit(to, float(ev["amount"]), false)
