extends DmRiteModule
## Black Litany: consume every corpse (and sacrifice every thrall) within 7 m in one ritual burst; power grows with what you give. Numbers:
## DmAbilities.litany_mult / litany_spell_power / litany_gains (and the sim's applyLitany order: corpses, then thralls, then enemies in radius + edge).
## 40 essence, 14 s. Corpses only through the field's atomic consume ("litany"); thralls through DmThrallHost near + kill("sacrificed") (the Hollow Choir
## rune spares them, Requiem delays the burst and widens it, the Legion of the Unburied `sacrificeLeavesCorpse` lays a risen corpse where each fell).
## The caster's barrier and heal are paid ONCE, here on the host, from the burst's own counts (the current game paid them twice once; play() only draws).


func _init() -> void:
	id = "black_litany"


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var RT: Dictionary = DmSimData.RUNE_TUNING
	var rn := DmAbilities.rune(c.p, id)
	var r := float(DmAbilities.def(id)["radius"]) * float(intent.get("mult", 1.0)) * (float(RT["requiem"]["radiusMult"]) if rn == "rune_requiem" else 1.0)
	var sp := DmAbilities.litany_spell_power(DmAbilities.sp(c.p, c.now_ms), rn)
	var at := c.pos()
	var spare := rn == "rune_hollow_choir"
	if rn == "rune_requiem":
		var ms := float(RT["requiem"]["delayMs"])
		c.broadcast({"t": "requiem", "rite": id, "by": c.peer_id, "x": at.x, "z": at.z, "r": r, "ms": ms})
		c.after(ms, func() -> void: _burst(c, at, r, sp, spare))
		return ""
	_burst(c, at, r, sp, spare)
	return ""


func _burst(c: DmRiteCaster, at: Vector3, r: float, sp: float, spare: bool) -> void:
	var field := c.corpses()
	var host := c.thralls()
	var area := c.area()
	var corpses_n := 0
	var resonant := 0
	var tethers: Array = []
	if field != null:
		for cp: DmSimCorpse in field.corpses_in_radius(at, r, Callable(), area):
			var kind := cp.kind
			var cx := cp.x
			var cz := cp.z
			if not field.consume(cp.id, c.peer_id, "litany"):
				continue   # another caster took it first
			if kind == "resonant":
				resonant += 1
			else:
				corpses_n += 1
			tethers.append([cx, cz])
	var thr := 0
	var spared_at: Array = []
	if host != null:
		var leave := DmCombatData.truthy(c.mods.get("sacrificeLeavesCorpse"))
		for t in host.near(at, r):
			if t.state == DmThrall.S.DEAD:
				continue
			thr += 1
			var tp := t.global_position
			tethers.append([tp.x, tp.z])
			if spare:
				spared_at.append([tp.x, tp.z])
				continue
			t.kill("sacrificed")
			if leave and field != null:
				field.add_corpse(tp.x, tp.z, "normal", "risen", false, t.rotation.y, 1.0, area)
	var dmg := sp * DmAbilities.litany_mult(corpses_n, resonant, thr)
	var targets := 0
	for n in c.world.enemies_in_radius(at, r):
		var e := n as Node3D
		if e == null or not DmRiteCaster.alive_enemy(e):
			continue
		DmStatusSet.hit(e, dmg, c.body)
		targets += 1
		c.hit_resolved.emit(id, int(c.world.enemy_id(e)), dmg, false, float(e.get("hp")) <= 0.0)
	var given := {"corpses": corpses_n, "resonant": resonant, "thralls": 0 if spare else thr}
	var gains := DmAbilities.litany_gains(c.max_hp(), c.mods, given)   # paid once, here
	if float(gains["barrier"]) > 0.0:
		c.add_barrier(gains["barrier"])
	if float(gains["heal"]) > 0.0:
		c.heal(gains["heal"])
	c.broadcast({"t": "litany", "rite": id, "by": c.peer_id, "x": at.x, "z": at.z, "r": r, "corpses": corpses_n, "resonant": resonant, "thralls": given["thralls"],
		"spared": spared_at, "targets": targets, "dmg": dmg, "tethers": tethers.slice(0, 12), "barrier": gains["barrier"], "heal": gains["heal"]})
	c.push_state()


## Colossus Mantle (legendary), HOST, when the caster is hit: 4 - `wardReflect` of the blow's Bone Ward share goes back at its source (an enemy within reach);
## 5 - a Litany barrier that just broke bursts into shards (`litanyShatter` x its size) around the caster.
func hurt_legend(c: DmRiteCaster, raw: float, ward: float, source: Node, broke: float) -> void:
	var back := DmLegend.ward_reflect_damage(raw, ward, float(c.mods.get("wardReflect", 0.0)))
	if back >= 1.0 and source is DmEnemy and DmRiteCaster.alive_enemy(source):
		DmStatusSet.hit(source, back, c.body)
		var sp := (source as Node3D).global_position
		c.hit_resolved.emit(id, int(c.world.enemy_id(source)), back, false, float(source.get("hp")) <= 0.0)
		c.broadcast({"t": "reflect", "rite": id, "by": c.peer_id, "x": sp.x, "z": sp.z, "amount": back})
	var dmg := DmLegend.shatter_damage(broke, float(c.mods.get("litanyShatter", 0.0)))
	if dmg > 0.0 and bool(c.p["alive"]):
		var at := c.pos()
		for e in enemies_in_circle(c, at.x, at.z, float(DmSimData.LEGEND["shatterR"])):
			DmStatusSet.hit(e, dmg, c.body)
			c.hit_resolved.emit(id, int(c.world.enemy_id(e)), dmg, false, float(e.get("hp")) <= 0.0)
		c.broadcast({"t": "shatter", "rite": id, "by": c.peer_id, "x": at.x, "z": at.z, "r": float(DmSimData.LEGEND["shatterR"]), "amount": dmg})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var mine := c.is_owner_peer()
	match String(ev["t"]):
		"reflect":
			c.fx.legend_hit(float(ev["x"]), float(ev["z"]), 0.0)
			c.hit_number.emit(Vector3(float(ev["x"]), 1.0, float(ev["z"])), float(ev["amount"]), false)
			return
		"wisp":   # Requiem 4: an orbiting healing wisp, drawn on every peer around the caster's body
			var w: WeakRef = weakref(c.body)
			c.fx.wisp(float(ev["secs"]), float(ev["speed"]), float(ev["radius"]), func() -> Variant:
				var b := w.get_ref() as Node3D
				return Vector3(b.global_position.x, 0.0, b.global_position.z) if b != null else null)
			return
		"nova":
			c.fx.legend_nova(ev["pts"], float(ev["r"]))
			c.hit_number.emit(Vector3(float(ev["pts"][0][0]), 1.0, float(ev["pts"][0][1])), float(ev["amount"]), false)
			return
		"shatter":
			c.fx.legend_hit(float(ev["x"]), float(ev["z"]), float(ev["r"]))
			c.shake_requested.emit(0.07)
			return
	if String(ev["t"]) == "requiem":
		c.fx.requiem(ev, mine)
		return
	var b: Node3D = c.body
	var tip: Array = [b.global_position.x, 1.4, b.global_position.z] if mine and b != null else [float(ev["x"]), 1.6, float(ev["z"])]
	c.fx.litany_result(ev, mine, tip)
	var X := DmFxData.spell_group("exhume")
	for sp: Array in ev["spared"]:
		c.fx.decal("ring", X["spirit"], sp[0], sp[1], 1.2, 0.9, 0.9, {"growFrom": 0.3})
		c.fx.motes(sp[0], sp[1], X["beam"], 0.35, 4, 2.2, 0.25, "thrall")
	c.shake_requested.emit(c.fx.litany_finish(ev))
	if mine and int(ev["targets"]) > 0:
		c.hit_number.emit(Vector3(float(ev["x"]), 1.0, float(ev["z"])), float(ev["dmg"]), false)
