extends DmRiteModule
## Dirge (the Mourner's signature, R): toll a 4 s funeral bell-song around you (radius 6, centred on the cast spot). Each second you and your allies' thralls mend (a flat
## spell power x 0.6 for players, 8 % of max health for thralls) and the enemies inside stay Silenced (1.2 s, refreshed at 4 Hz). 35 essence, 18 s, unlocks at level 10.
## Numbers: DmSimData.SIGNATURE.dirge + the def; the zone follows sim_zones.tick_dirge. Visuals: DmRiteFx.dirge_zone / dirge_pulse. Events: `cast`, `pulse`.

const SCAN_S := 0.25
const PULSE_S := 1.0


func _init() -> void:
	id = "dirge"
	steps = true


func resolve(c: DmRiteCaster, _intent: Dictionary) -> String:
	var D: Dictionary = DmSimData.SIGNATURE["dirge"]
	var at := c.pos()
	c.mem(id).get_or_add("zones", []).append({"x": at.x, "z": at.z, "r": float(D["radius"]), "until": c.now_ms + float(D["durationS"]) * 1000.0,
		"heal": DmAbilities.sp(c.p, c.now_ms) * float(DmAbilities.def(id)["power"]), "pulse": 0.0, "scan": 0.0})
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "tip": c.tip(), "x": at.x, "z": at.z, "r": float(D["radius"]), "ms": float(D["durationS"]) * 1000.0})
	return ""


func step(c: DmRiteCaster, dt: float) -> void:
	var zones: Array = c.mem(id).get("zones", [])
	var i := 0
	while i < zones.size():
		var z: Dictionary = zones[i]
		if c.now_ms >= float(z["until"]):
			zones.remove_at(i)
			continue
		i += 1
		var at := Vector3(z["x"], 0.0, z["z"])
		z["scan"] = float(z["scan"]) - dt
		if z["scan"] <= 0.0:
			z["scan"] = SCAN_S
			for n in c.world.enemies_in_radius(at, float(z["r"]) + 2.0):
				var e := n as Node3D
				if e != null and DmRiteCaster.alive_enemy(e) and Vector2(e.global_position.x - at.x, e.global_position.z - at.z).length() <= float(z["r"]) + float(e.get("radius")):
					DmStatusSet.ensure(e).apply(&"silence", c.body, 1, float(DmSimData.SIGNATURE["dirge"]["silenceS"]))
		z["pulse"] = float(z["pulse"]) - dt
		if z["pulse"] <= 0.0:
			z["pulse"] = float(z["pulse"]) + PULSE_S
			_pulse(c, z, at)


## Mend the players and thralls inside (host), then draw the beat on every peer.
func _pulse(c: DmRiteCaster, z: Dictionary, at: Vector3) -> void:
	var r := float(z["r"])
	var heal := float(z["heal"])
	var frac := float(DmSimData.SIGNATURE["dirge"]["thrallHealFrac"])
	for b: Node in c.body.get_parent().get_children():   # the party: bodies are siblings (the session's Players node)
		var bb := b as Node3D
		if bb == null:
			continue
		if Vector2(bb.global_position.x - at.x, bb.global_position.z - at.z).length() <= r + DmSimConsts.PLAYER_RADIUS:
			if bb == c.body:
				c.heal(heal)
			elif bb.has_method("heal"):
				bb.heal(heal)
		var th := bb.get_node_or_null("Thralls") as DmThrallHost   # any legion standing in it (sim: every thrall in the zone)
		if th != null:
			for t in th.near(at, r):
				if t.state != DmThrall.S.DEAD:
					t.hp = minf(t.max_hp, t.hp + t.max_hp * frac)
	c.broadcast({"t": "pulse", "rite": id, "by": c.peer_id, "x": at.x, "z": at.z, "r": r, "heal": heal})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	if String(ev["t"]) == "pulse":
		c.fx.dirge_pulse(float(ev["x"]), float(ev["z"]), float(ev["r"]))
		return
	c.fx.signature_cast("dirge", ev["tip"])
	c.fx.dirge_zone(float(ev["x"]), float(ev["z"]), float(ev["r"]), float(ev["ms"]) / 1000.0)
