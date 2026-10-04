extends RefCounted
## Ground-state visuals of the event router: zoneVisual, syncEchoVisuals, raiseWall / wallGone, zoneAmbience, wadeRipples
## (WorldScene.ts 3968-4054, 5378-5469). Owned by DmEventFx (`fx`).

var fx: DmEventFx
var zone_fx: Dictionary = {}    # zone id -> Array of handles
var echo_fx: Dictionary = {}    # corpse id -> handle
var wall_fx: Dictionary = {}    # wall id -> {"node": Node3D, "cx", "cz"}
var _ripple_t := 0.0
var _ripple_cursor := 0


func _init(p_fx: DmEventFx) -> void:
	fx = p_fx


func clear() -> void:
	for id in zone_fx:
		for h in zone_fx[id]:
			h.kill()
	zone_fx.clear()
	for id in echo_fx:
		echo_fx[id].kill()
	echo_fx.clear()
	for id in wall_fx:
		var n: Node = wall_fx[id]["node"]
		if is_instance_valid(n):
			n.queue_free()
	wall_fx.clear()


func zone_gone(id: int) -> void:
	if zone_fx.has(id):
		for h in zone_fx[id]:
			h.kill()
	zone_fx.erase(id)


func _store(id: int, handles: Array) -> void:
	zone_fx[id] = handles


func zone_visual(z: DmSimZone) -> void:
	zone_gone(z.id)
	var dur := maxf(0.1, z.until - fx.world_time())
	var kind := z.kind
	if kind == "warden_fire" or kind == "warden_ward" or kind == "witch_crows" or kind == "witch_charm" or kind == "veil_rift":
		var color: int
		match kind:
			"warden_fire":
				color = 0xff822d
			"warden_ward":
				color = fx.sp("warden", "gold")
			"witch_crows":
				color = fx.sp("witch", "blood")
			"witch_charm":
				color = 0xcc4499
			_:
				color = fx.sp("veilwalker", "cyan")
		var glyph := "cracks" if kind == "warden_fire" else ("glow" if kind == "witch_charm" else "sigil")
		_store(z.id, [
			fx.decal({"tex": "disc", "color": color, "x": z.x, "z": z.z, "r": z.r, "duration": dur, "opacity": 0.32 if kind == "witch_charm" else 0.4, "growFrom": 0.3, "fadeOut": 0.35}),
			fx.decal({"tex": glyph, "color": color, "x": z.x, "z": z.z, "r": z.r, "duration": dur, "opacity": 0.72, "pulse": 4 if kind == "warden_fire" else 2, "fadeOut": 0.35}),
		])
		return
	if kind == "dirge" or kind == "flower":
		# Signature zones: Dirge = cold-blue bell rings, Plague Bloom = a chartreuse flower sigil.
		var dirge := kind == "dirge"
		var d_deep := fx.sp("dirge", "deep")
		var d_frost := fx.sp("dirge", "frost")
		var d_pale := fx.sp("dirge", "pale")
		var b_rot := fx.sp("bloom", "rot")
		var b_petal := fx.sp("bloom", "petal")
		_store(z.id, [
			fx.decal({"tex": "disc", "color": d_deep if dirge else b_rot, "x": z.x, "z": z.z, "r": z.r, "duration": dur, "opacity": 0.45, "growFrom": 0.3, "fadeOut": 0.6}),
			fx.decal({"tex": "ring" if dirge else "sigil", "color": d_frost if dirge else b_petal, "x": z.x, "z": z.z, "r": z.r * 0.95, "duration": dur, "opacity": 0.6, "pulse": 6 if dirge else 2, "spin": 0.0 if dirge else 0.9, "fadeOut": 0.6}),
		])
		fx.emit({"x": z.x, "y": 0.4, "z": z.z, "count": 30 if dirge else 18, "color": d_pale if dirge else b_petal, "spread": z.r * 0.5, "speed": 0.6, "up": 2.0 if dirge else 1.2, "life": 1, "size": 0.22})
		# Grave mist and soul-lights: the dirge is sung over the dead; the bloom sheds rot spores.
		if dirge:
			fx.vfx.motifs.mist_whisper(z.x, z.z, d_deep, {"r": z.r * 0.6, "n": 3})
			fx.vfx.motifs.spirit_wisps(z.x, z.z, d_pale, {"n": 3, "r": z.r * 0.6, "y": 0.3, "size": 0.8})
		else:
			fx.vfx.motifs.rot_spores(z.x, z.z, b_petal, {"r": z.r * 0.7, "n": 12})
		if dirge:
			fx.snd("tollSmall", z.x, z.z)
		fx.bb("dirge_area" if dirge else "plague_bloom_area", z.x, z.z, {"scale": z.r / 6.0 if dirge else z.r / 2.4})
		return
	if kind == "dust":
		# Shroud Moth cloud: a low ochre haze, a few slow puffs (cheap: two decals + one burst of smoke).
		var dust := fx.sp("enemy", "dust")
		_store(z.id, [
			fx.decal({"tex": "disc", "color": fx.sp("enemy", "dustDeep"), "x": z.x, "z": z.z, "r": z.r, "duration": dur, "opacity": 0.55, "growFrom": 0.4, "fadeOut": 0.6}),
			fx.decal({"tex": "glow", "color": dust, "x": z.x, "z": z.z, "r": z.r * 1.05, "duration": dur, "opacity": 0.35, "pulse": 1.5, "fadeOut": 0.6}),
		])
		fx.emit_smoke({"x": z.x, "y": 0.5, "z": z.z, "count": 6, "color": dust, "spread": z.r * 0.5, "speed": 0.4, "up": 0.35, "life": minf(dur, 3.0), "size": 1.5, "shrink": -0.6})
		return
	if kind == "ember":
		# Burning ground: an orange disc over glowing cracks, with sparks rising off it (see zone_ambience).
		var ember := fx.sp("enemy", "ember")
		_store(z.id, [
			fx.decal({"tex": "disc", "color": fx.sp("enemy", "emberDeep"), "x": z.x, "z": z.z, "r": z.r, "duration": dur, "opacity": 0.6, "growFrom": 0.3, "fadeOut": 0.6}),
			fx.decal({"tex": "cracks", "color": ember, "x": z.x, "z": z.z, "r": z.r * 0.95, "duration": dur, "opacity": 0.75, "pulse": 2.5, "fadeOut": 0.6}),
			fx.decal({"tex": "glow", "color": ember, "x": z.x, "z": z.z, "r": z.r * 1.05, "duration": dur, "opacity": 0.3, "pulse": 1.5, "fadeOut": 0.6}),
			fx.bb("bonfire", z.x, z.z, {"scale": z.r / 2.2, "duration": dur, "alpha": 0.85}),
		])
		return
	var toxic := kind == "toxic"
	var color2: int = fx.sp("enemy", "toxic") if toxic else fx.sp("miasma", "deep")
	# Toxic (hostile) and rot (a detonated sac, now yours) pools are cracked ground; miasma is a sigil.
	var pool := toxic or kind == "rot"
	# Creeping Rot rune: the circle walks, so its drawing follows the zone's live position.
	var opts: Dictionary = {}
	if z.creep != 0.0:
		var zid := z.id
		opts["follow"] = func() -> Variant:
			var live = fx.zones_map().get(zid)
			return Vector3(live.x, 0.0, live.z) if live != null else null
	var d1 := {"tex": "disc", "color": color2, "x": z.x, "z": z.z, "r": z.r, "duration": dur, "opacity": 0.5 if toxic else 0.66, "growFrom": 0.3, "fadeOut": 0.6}
	d1.merge(opts)
	var d2 := {"tex": "cracks" if pool else "sigil", "color": fx.sp("enemy", "rot") if toxic else fx.sp("miasma", "rot"), "x": z.x, "z": z.z, "r": z.r * 0.95, "duration": dur, "opacity": 0.22, "spin": 0.0 if pool else 0.6, "fadeOut": 0.6}
	d2.merge(opts)
	var handles: Array = [fx.decal(d1), fx.decal(d2)]
	if z.creep != 0.0:
		handles.append(fx.bb("miasma_cloud", z.x, z.z, {"scale": z.r / 3.8, "duration": dur, "follow": opts["follow"]}))
	# Contagion rune: a sickly green ring marks a circle that spreads.
	if z.contagion:
		var d3 := {"tex": "ring", "color": fx.sp("lance", "rot"), "x": z.x, "z": z.z, "r": z.r * 1.02, "duration": dur, "opacity": 0.55, "pulse": 3, "fadeOut": 0.6}
		d3.merge(opts)
		handles.append(fx.decal(d3))
	if pool:
		var po := {"scale": z.r / 2.6, "duration": dur}
		if toxic:
			po["colors"] = [fx.sp("enemy", "toxic"), fx.sp("enemy", "rot"), 0x1a2010]
		handles.append(fx.bb("toxic_puddle", z.x, z.z, po))
	_store(z.id, handles)


func sync_echo_visuals() -> void:
	var p: Dictionary = fx.game.p
	var visible: bool = String(p.get("family", "")) == "veil" and (bool(p.get("veilForm", false)) or fx.now() < float(p.get("betweenUntil", 0.0)))
	var corpses: Dictionary = fx.corpses_map()
	for id in echo_fx.keys():
		var c = corpses.get(id)
		if visible and c != null and c.echoOwner != "":
			continue
		echo_fx[id].kill()
		echo_fx.erase(id)
	if not visible:
		return
	var t: float = fx.world_time()
	for c in corpses.values():
		if c.echoOwner == "" or echo_fx.has(c.id):
			continue
		echo_fx[c.id] = fx.decal({"tex": "sigil", "color": fx.sp("veilwalker", "cyan"), "x": c.x, "z": c.z, "r": 0.8, "duration": maxf(0.1, c.expiresAt - t), "opacity": 0.8, "pulse": 3, "fadeOut": 0.2})


# --- Ossuary Wall ----------------------------------------------------------------------------------------------------------

## A fence of fused rib-bones along the wall segment.
func raise_wall(ev: Dictionary) -> void:
	var x0 := fx.f(ev, "x0")
	var z0 := fx.f(ev, "z0")
	var x1 := fx.f(ev, "x1")
	var z1 := fx.f(ev, "z1")
	var bone := fx.sp("wall", "bone")
	var amber := fx.spc("wall", "amber")
	var length := sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0))
	var n := maxi(6, DmMath.js_round(length * 2.2))
	var rib := CylinderMesh.new()
	rib.top_radius = 0.0
	rib.bottom_radius = 0.22
	rib.height = 1.0
	rib.radial_segments = 5
	rib.rings = 1
	var mat := StandardMaterial3D.new()
	mat.albedo_color = DmFxData.hex(bone)
	mat.roughness = 0.8
	mat.emission_enabled = true
	mat.emission = amber
	mat.emission_energy_multiplier = 0.08
	rib.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = rib
	mm.instance_count = n
	for i in n:
		var t := (float(i) + 0.5) / float(n)
		var h := 1.4 + float((i * 7919) % 5) * 0.18
		var pos := Vector3(x0 + (x1 - x0) * t, h / 2.0, z0 + (z1 - z0) * t)
		var eul := Vector3(float((i % 3) - 1) * 0.18, float(i) * 1.3, float((i % 2) * 2 - 1) * 0.12)
		var basis := Basis.from_euler(eul, EULER_ORDER_XYZ) * Basis.from_scale(Vector3(1.0, h, 1.0))
		mm.set_instance_transform(i, Transform3D(basis, pos))
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	node.name = "OssuaryWall%d" % int(ev["id"])
	fx.game.world_root.add_child(node)
	var cx := (x0 + x1) / 2.0
	var cz := (z0 + z1) / 2.0
	wall_fx[int(ev["id"])] = {"node": node, "cx": cx, "cz": cz}
	for i in 7:
		var t := float(i) / 6.0
		fx.emit({"x": x0 + (x1 - x0) * t, "y": 0.3, "z": z0 + (z1 - z0) * t, "count": 6, "color": bone, "spread": 0.3, "speed": 1.5, "up": 2.5, "life": 0.6, "size": 0.14, "gravity": 9})
	# The wall tears out of the grave: soil along its foot, chips off the ribs, a crack in the ground beneath it.
	for i in 5:
		var t := float(i) / 4.0
		fx.vfx.motifs.grave_dirt(x0 + (x1 - x0) * t, z0 + (z1 - z0) * t, {"r": 0.4, "n": 3})
	fx.vfx.motifs.bone_splinters(cx, 1.0, cz, {"n": 8, "color": bone, "speed": 4.5})
	fx.vfx.motifs.cracked_ground(cx, cz, length * 0.5, fx.sp("wall", "dust"), {"rot": atan2(x1 - x0, z1 - z0), "sx": 0.22, "duration": 2.2, "opacity": 0.6})
	fx.snd("boneHit", cx, cz)
	fx.shake(0.15)


func wall_gone(id: int) -> void:
	var w = wall_fx.get(id)
	if w == null:
		return
	fx.emit_smoke({"x": w["cx"], "y": 0.6, "z": w["cz"], "count": 16, "color": fx.sp("wall", "dust"), "spread": 2.4, "speed": 0.8, "up": 0.8, "life": 1.4, "size": 1.6})
	var n: Node = w["node"]
	if is_instance_valid(n):
		n.queue_free()
	wall_fx.erase(id)


# --- ambient ---------------------------------------------------------------------------------------------------------------

## Bodies wading through the nave's flood and the graveyard puddles ring the water.
func wade_ripples(dt: float) -> void:
	_ripple_t -= dt
	if _ripple_t > 0.0:
		return
	_ripple_t = 0.15
	_ripple_cursor += 1
	var p: Dictionary = fx.game.p
	var pxx: float = fx.px()
	var pzz: float = fx.pz()
	if bool(p.get("moving", false)) and _ripple_cursor % 2 == 0:
		fx.add_ripple(pxx, pzz, 0.9)
	if _ripple_cursor % 3 == 0:
		for id in fx.game.remote_ids() if fx.game.has_method("remote_ids") else []:
			var rem = fx.game.get("remotes")
			var r = rem.get(id) if rem is Dictionary else null
			var at: Variant = fx.remote_xz(String(id))
			if r != null and at is Vector3 and bool(r.get("moving")):
				fx.add_ripple(at.x, at.z, 0.8)
	# One other wader per tick, round-robin, so a horde can't flood the 16 ripple slots.
	var near := func(b) -> bool:
		return b.moving and absf(b.x - pxx) < 24.0 and absf(b.z - pzz) < 20.0 and fx.is_wet(b.x, b.z)
	var n := 0
	for e in fx.enemies_map().values():
		if near.call(e):
			n += 1
	for t in fx.thralls_map().values():
		if near.call(t):
			n += 1
	if n == 0:
		return
	var pick := _ripple_cursor % n
	for b in [fx.enemies_map(), fx.thralls_map()]:
		for e in b.values():
			if not near.call(e):
				continue
			if pick == 0:
				fx.add_ripple(e.x, e.z, 0.7)
				return
			pick -= 1


## Living zones churn: miasma sheds spores, toxic pools bubble.
func zone_ambience(dt: float) -> void:
	var zones: Dictionary = fx.zones_map()
	if zones.is_empty():
		return
	var pxx: float = fx.px()
	var pzz: float = fx.pz()
	for z in zones.values():
		if absf(z.x - pxx) > 30.0 or absf(z.z - pzz) > 26.0:
			continue
		var rate: float = z.r * z.r * 0.8
		if randf() < dt * rate:
			var a: float = randf() * TAU
			var d: float = sqrt(randf()) * z.r
			var x: float = z.x + cos(a) * d
			var zz: float = z.z + sin(a) * d
			if z.kind == "miasma" or z.kind == "rot":
				fx.emit({"x": x, "y": 0.2, "z": zz, "count": 1, "color": fx.sp("miasma", "rot"), "spread": 0.2, "speed": 0.15, "up": 0.9, "life": 1.4, "size": 0.22, "drag": 0.5})
				if randf() < 0.4:
					fx.emit_smoke({"x": x, "y": 0.3, "z": zz, "count": 1, "color": 0x56662a, "spread": 0.3, "speed": 0.2, "up": 0.3, "life": 2, "size": 1.6, "shrink": -0.8, "drag": 0.5})
			elif z.kind == "ember":
				fx.emit({"x": x, "y": 0.15, "z": zz, "count": 1, "color": fx.sp("enemy", "emberCore"), "spread": 0.1, "speed": 0.3, "up": 1.6, "life": 0.9, "size": 0.14, "drag": 0.4})
			elif z.kind == "toxic":
				fx.emit({"x": x, "y": 0.1, "z": zz, "count": 1, "color": fx.sp("enemy", "toxic"), "spread": 0.1, "speed": 0.05, "up": 0.6, "life": 0.8, "size": 0.28})
