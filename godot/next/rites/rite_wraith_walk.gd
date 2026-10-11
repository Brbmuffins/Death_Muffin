extends DmRiteModule
## Wraith Walk (the Reaper): she becomes a towering phantom and rushes up to 9 m toward the cursor (at least 2 m), 4 souls, 11 s. Everything in the
## lane she passes through (1.6 m either side, plus the enemy's radius) burns in green flame (the `wraithfire` status, a Hemorrhage-style damage-over-time) for 5 s at power 0.7 a second, +15% a
## soul it costs (the bag's own +2% a soul is what is left in the bag). Host-authoritative like Veil Step: `body.phase_point`
## validates the way, `body.dash` glides the body (0.32 s). The lane is read once, at the cast, from where she started to where the dash ends.


const PHANTOM_ALPHA := 0.45   ## how see-through she is while rushing
const PHANTOM_GLOW := 0.9     ## the faint green emissive (her resting glow is 0.04)


func _init() -> void:
	id = "wraith_walk"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var K := DmReaperRites.k()
	var dir := DmReaperRites.facing(c, intent["aim"])
	if dir == Vector2.ZERO:
		return "no_target"
	var from := c.pos()
	var want := clampf(Vector2(intent["aim"].x - from.x, intent["aim"].z - from.z).length(), float(K["wraithMinM"]), float(DmAbilities.def(id)["range"]))
	var goal := Vector3(from.x + dir.x * want, 0.0, from.z + dir.y * want)
	var b: Node3D = c.body
	var to := (b.call("phase_point", goal) as Vector3) if b.has_method("phase_point") else goal
	if Vector2(to.x - from.x, to.z - from.z).length() < 0.5:
		return "no_target"
	intent["to"] = to
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var K := DmReaperRites.k()
	var from := c.pos()
	var to: Vector3 = intent["to"]
	var lane_v := Vector2(to.x - from.x, to.z - from.z)
	var length := lane_v.length()
	var dir := lane_v / length
	var dps := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var spent := DmAbilities.soul_cost(c.p, id)   # already paid by the cast (DmAbilities.apply_cast_cost)
	dps *= 1.0 + float(K["wraithPerSoul"]) * float(spent)
	var marks: Array = []
	for hit: Dictionary in DmRiteModule.lane(c, from.x, from.z, dir.x, dir.y, length, float(DmAbilities.def(id)["radius"]), true):
		var e := hit["e"] as DmEnemy
		if e == null or not e.is_hittable():
			continue
		DmStatusSet.ensure(e).apply(&"wraithfire", c.body, 1, float(K["wraithCurseS"]), {"dps": dps})
		if marks.size() < DmReaperRites.SHOWN:
			marks.append(Vector3(e.global_position.x, 0.9, e.global_position.z))
	c.p["phasedUntil"] = c.now_ms + float(K["wraithDashS"]) * 1000.0   # untouchable for the rush (DmPlayerRules.take_damage)
	if c.body.has_method("dash"):
		c.body.call("dash", to, float(K["wraithDashS"]), false)   # an even rush: no 56 m/s first step for other peers to snap over
	else:
		c.body.position = Vector3(to.x, c.body.position.y, to.z)
		c.body.reset_physics_interpolation()
	c.broadcast({"t": "walk", "rite": id, "by": c.peer_id, "fx": from.x, "fz": from.z, "tx": to.x, "tz": to.z, "hits": marks, "souls": spent, "dash": float(K["wraithDashS"])})
	c.push_state()
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var fx0 := float(ev["fx"])
	var fz0 := float(ev["fz"])
	var tx := float(ev["tx"])
	var tz := float(ev["tz"])
	var n := clampi(int(ceil(Vector2(tx - fx0, tz - fz0).length() / 1.5)), 2, 7)
	for i in n:
		var k := float(i) / float(n - 1)
		c.fx.smoke(lerpf(fx0, tx, k), 0.9, lerpf(fz0, tz, k), 2, DmReaperRites.DEEP, 0.5, 0.5, 0.8, 0.9, 1.2, {"shrink": -0.4})
	c.fx.decal("ring", DmReaperRites.GREEN, fx0, fz0, 2.0, 0.4, 0.8, {"growFrom": 0.4, "fadeOut": 0.3})
	c.fx.decal("ring", DmReaperRites.PALE, tx, tz, 2.4, 0.5, 0.8, {"growFrom": 0.3, "fadeOut": 0.35})
	for h: Vector3 in ev["hits"]:
		c.fx.emit(h.x, 0.9, h.z, 6, DmReaperRites.GREEN, 0.3, 2.0, 1.4, 0.5, 0.12, {"gravity": 4.0})
	c.fx.sfx("wail", fx0, fz0, 0.9)
	c.fx.sfx("banshee", fx0, fz0, 1.0)   # the banshee keen over the rush
	c.shake_requested.emit(0.04)
	_phantom(c, float(ev["dash"]))


## The hero swells into a towering, half-see-through phantom with a faint green glow for the rush, then settles back (every peer; the avatar is the
## model on the body). The body is never blocked by monsters (it is a point on the navmesh, not a physics body); `phase_point` stops it at walls but not at props.
func _phantom(c: DmRiteCaster, secs: float) -> void:
	var b: Node3D = c.body
	var av: Variant = b.get("avatar") if b != null else null
	if av == null or not is_instance_valid(av) or not (av is DmAvatar):
		return
	var a := av as DmAvatar
	var cr := a.c
	cr.set_opacity(PHANTOM_ALPHA)
	cr.set_emissive(0x6ee7a0, PHANTOM_GLOW)   # DmReaperRites.GREEN
	var base := cr.root.scale   # the model swells about its own feet (scaling the avatar node scaled her world position away from the origin)
	var tw := a.create_tween()
	tw.tween_property(cr.root, "scale", base * 1.6, 0.08)
	tw.tween_interval(maxf(0.0, secs - 0.05))
	tw.tween_property(cr.root, "scale", base, 0.22)
	tw.tween_callback(func() -> void:
		if is_instance_valid(a):
			cr.set_opacity(1.0)
			cr.set_emissive(a.accent_hex, 0.04))
