extends RefCounted
## Enemy telegraphs (WorldScene.ts telegraph() 3817-3967): the ground shapes, projectiles and delayed landings of every
## windup the sim announces. Owned by DmEventFx (`fx`). Always called inside Vfx.danger().

var fx: DmEventFx


func _init(p_fx: DmEventFx) -> void:
	fx = p_fx


func _dec(tex: String, color: Variant, x: float, z: float, r: float, duration: float, opacity: float, extra: Dictionary = {}) -> void:
	var o := {"tex": tex, "color": color, "x": x, "z": z, "r": r, "duration": duration, "opacity": opacity}
	o.merge(extra, true)
	fx.decal(o)


func telegraph(ev: Dictionary) -> void:
	var kind := String(ev.get("kind", ""))
	var ex := fx.f(ev, "x")
	var ez := fx.f(ev, "z")
	var tx := fx.f(ev, "tx")
	var tz := fx.f(ev, "tz")
	var ms_raw := fx.f(ev, "ms")
	var ms := ms_raw / 1000.0
	var sfx := "tellStrike"
	if kind == "cone" or kind == "toll":
		sfx = "tollSmall"
	elif kind == "raise":
		sfx = "raise"
	elif kind == "curse":
		sfx = "curse"
	fx.snd(sfx, ex, ez)
	var E_ember := fx.sp("enemy", "ember")
	var E_core := fx.sp("enemy", "emberCore")
	var E_deep := fx.sp("enemy", "emberDeep")
	var def := fx.enemy_def(ev["id"]) if ev.has("id") else ""
	if kind == "toll":
		# Bell-Tolled elite: a bronze ring fills in; step out before it sounds.
		var r := fx.f(ev, "r", float(DmSimData.AFFIX_TUNING["bellTolled"]["r"]))
		var bell := fx.sp("affix", "bell")
		_dec("disc", bell, tx, tz, r, ms, 0.7, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.2})
		_dec("ring", bell, tx, tz, r, ms, 0.9, {"fadeOut": 0.05})
	elif kind == "cone":
		var rot := atan2(tx - ex, tz - ez)
		var toll := fx.sp("enemy", "toll")
		var range_ := float(DmSimData.ENEMIES["penitent"]["attackRange"])
		# The sim's cone reaches attackRange + 0.4 (a body's width): draw all of it, so nobody is hit standing outside the red.
		var reach := (range_ + DmSimConsts.CONE_REACH_PAD) / 2.0
		_dec("cone", toll, ex, ez, reach, ms, 0.5, {"sz": 1, "anchor": 1, "rot": rot + PI, "fadeIn": ms * 0.6, "fadeOut": 0.05})
		_dec("coneEdge", toll, ex, ez, reach, ms, 0.8, {"sz": 1, "anchor": 1, "rot": rot + PI, "fadeIn": ms * 0.15, "fadeOut": 0.05})
		for k in 3:
			_dec("ring", toll, ex, ez, range_ * (0.45 + float(k) * 0.28), 0.45, 0.8 - float(k) * 0.2, {"growFrom": 0.2, "delay": ms + float(k) * 0.08})
	elif kind == "slam" and def == "slag_brute":
		# Slag Brute: a molten ring fills as the fist rises; it lands with a shockwave, a heat flash and a heavy shake.
		var r2 := fx.f(ev, "r", 2.7)
		_dec("disc", E_deep, tx, tz, r2, ms, 0.7, {"fadeIn": ms * 0.7, "fadeOut": 0.05, "growFrom": 0.4})
		_dec("ring", E_ember, tx, tz, r2, ms, 0.95, {"fadeOut": 0.05})
		_dec("cracks", E_core, tx, tz, r2 * 0.9, ms, 0.6, {"rot": randf() * 6.0, "fadeIn": ms * 0.8, "fadeOut": 0.05})
		fx.later(ms_raw, func():
			_dec("ring", E_core, tx, tz, r2 * 1.35, 0.5, 1, {"growFrom": 0.3})
			_dec("cracks", E_ember, tx, tz, r2 * 0.95, 1.6, 0.85, {"rot": randf() * 6.0, "growFrom": 0.5})
			fx.bb("surge_eruption", tx, tz, {"scale": r2 / 2.0, "colors": [E_ember, E_core, E_deep]})
			fx.emit({"x": tx, "y": 0.3, "z": tz, "count": 34, "color": E_core, "spread": r2 * 0.5, "speed": 4.5, "up": 3.2, "life": 0.8, "size": 0.14, "gravity": 9})
			fx.emit_smoke({"x": tx, "y": 0.3, "z": tz, "count": 6, "color": E_deep, "spread": r2 * 0.5, "speed": 1.6, "up": 0.7, "life": 1.1, "size": 1.4})
			fx.snd("slagSlam", tx, tz)
			fx.ember_shake(tx, tz, 0.2))
	elif kind == "slam":
		var r3 := fx.f(ev, "r", 1.9)
		var slam := fx.sp("enemy", "slam")
		_dec("disc", slam, tx, tz, r3, ms, 0.7, {"fadeIn": ms * 0.7, "fadeOut": 0.05, "growFrom": 0.4})
		if r3 > 2.2:
			# A Bone Golem's slam: the wide ring cracks as it lands.
			_dec("ring", slam, tx, tz, r3, ms, 0.9, {"fadeOut": 0.05})
			_dec("cracks", slam, tx, tz, r3 * 0.9, 1.2, 0.85, {"rot": randf() * 6.0, "growFrom": 0.5, "delay": ms})
			fx.emit_smoke({"x": tx, "y": 0.3, "z": tz, "count": 6, "color": 0x3b3440, "spread": r3 * 0.5, "speed": 1.4, "up": 0.5, "life": 0.9, "size": 1.2})
	elif kind == "scream":
		# Choir Wraith: pale song-lines run from the singer to a ring that breaks when the hymn does.
		var r4 := fx.f(ev, "r", 2.2)
		var song := 0xb9cbe6
		fx.beam(Vector3(ex, 2.0, ez), Vector3(tx, 0.3, tz), song, 0.03, ms)
		_dec("disc", song, tx, tz, r4, ms, 0.45, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.2})
		_dec("sigil", song, tx, tz, r4, ms, 0.6, {"spin": -1.5, "fadeOut": 0.05})
		_dec("ring", 0xeef4ff, tx, tz, r4 * 1.15, 0.35, 1, {"growFrom": 0.5, "delay": ms})
		fx.later(ms_raw, func(): fx.bb("choir_scream", tx, tz, {"scale": r4 / 2.2}))
	elif kind == "dive":
		# Belfry Gargoyle: a bronze mark fills in under the target; the stone lands when it's full.
		var r5 := fx.f(ev, "r", 2.0)
		var dive := fx.sp("enemy", "dive")
		# Kept low: the bronze disc is additive and blooms hard; the ring carries the read.
		_dec("disc", dive, tx, tz, r5, ms, 0.22, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.3})
		_dec("ring", dive, tx, tz, r5, ms, 0.7, {"fadeOut": 0.05})
		_dec("cracks", fx.sp("enemy", "slam"), tx, tz, r5 * 0.95, 1.4, 0.8, {"rot": randf() * 6.0, "growFrom": 0.5, "delay": ms})
		fx.later(ms_raw, func():
			fx.emit_smoke({"x": tx, "y": 0.3, "z": tz, "count": 5, "color": 0x3b3440, "spread": r5 * 0.45, "speed": 1.3, "up": 0.5, "life": 0.8, "size": 1.1})
			fx.emit({"x": tx, "y": 0.3, "z": tz, "count": 14, "color": 0x8a8378, "spread": r5 * 0.4, "speed": 2.4, "up": 2, "life": 0.6, "size": 0.14, "gravity": 9})
			fx.snd("boneHit", tx, tz)
			fx.shake(0.08))
	elif kind == "erupt":
		# Barrow Ghoul: the ground cracks open in a dirt-brown ring; it breaks out when the ring fills.
		var r6 := fx.f(ev, "r", 1.8)
		var dirt := fx.sp("enemy", "dirt")
		_dec("disc", dirt, tx, tz, r6, ms, 0.45, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.2})
		_dec("ring", 0xa07a50, tx, tz, r6, ms, 0.85, {"fadeOut": 0.05})
		_dec("cracks", dirt, tx, tz, r6 * 0.9, ms, 0.7, {"rot": randf() * 6.0, "growFrom": 0.2, "fadeOut": 0.05})
	elif kind == "flask":
		# Plague Doctor: a rot-green ring where the flask will land (enemy rot, never the player's Miasma).
		var r7 := fx.f(ev, "r", 1.8)
		var rotc := fx.sp("enemy", "toxic")
		_dec("disc", rotc, tx, tz, r7, ms, 0.45, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.25})
		_dec("ring", fx.sp("enemy", "rot"), tx, tz, r7, ms, 0.9, {"fadeOut": 0.05})
		_lob(ex, ez, tx, tz, ms, rotc, 1.6, 30.0)
	elif kind == "ember":
		# Pyre Priest: an ember-orange ring where the coal will land.
		var r8 := fx.f(ev, "r", 1.7)
		_dec("disc", E_ember, tx, tz, r8, ms, 0.45, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.25})
		_dec("ring", E_core, tx, tz, r8, ms, 0.9, {"fadeOut": 0.05})
		_lob(ex, ez, tx, tz, ms, E_ember, 1.6, 30.0)
		fx.snd("emberThrow", ex, ez)
		# The coal lands as the windup ends: a flare, a burst of sparks and a jolt if you are near.
		fx.later(ms_raw, func():
			fx.bb("vengeful_burst", tx, tz, {"scale": r8 / 1.4, "colors": [E_ember, E_core, E_deep]})
			fx.emit({"x": tx, "y": 0.4, "z": tz, "count": 16, "color": E_core, "spread": r8 * 0.4, "speed": 3, "up": 2.6, "life": 0.7, "size": 0.13, "gravity": 8})
			fx.snd("emberBurst", tx, tz)
			fx.ember_shake(tx, tz, 0.06))
	elif kind == "dust":
		# Shroud Moth: dust sifts down from the wings onto a ring; the cloud (a zone) follows the burst.
		var r9 := fx.f(ev, "r", 2.0)
		var dust := fx.sp("enemy", "dust")
		_dec("disc", dust, tx, tz, r9, ms, 0.4, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.25})
		_dec("ring", dust, tx, tz, r9, ms, 0.85, {"fadeOut": 0.05})
		fx.emit({"x": ex, "y": 1.4, "z": ez, "count": 10, "color": dust, "spread": 0.6, "speed": 0.4, "up": -0.6, "life": ms, "size": 0.16, "drag": 0.6})
	elif kind == "raise":
		var rot_c := fx.sp("enemy", "rot")
		fx.beam(Vector3(ex, 1.8, ez), Vector3(tx, 0.3, tz), rot_c, 0.05, ms)
		_dec("sigil", rot_c, tx, tz, 1, ms, 0.8, {"spin": 3})
	elif kind == "hex":
		# Bog Hag: a sickly magenta ring on the knot of thralls she will curse, and a thread from her to it.
		var r10 := fx.f(ev, "r", float(DmSimData.HAG_HEX["radius"]))
		var H := fx.sp("enemy", "hex")
		_dec("disc", H, tx, tz, r10, ms, 0.38, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.3})
		_dec("ring", H, tx, tz, r10, ms, 0.95, {"fadeOut": 0.05, "pulse": 3})
		_dec("sigil", H, tx, tz, r10 * 0.8, ms, 0.7, {"spin": 1.8, "fadeOut": 0.05})
		fx.beam(Vector3(ex, 1.9, ez), Vector3(tx, 0.5, tz), H, 0.04, ms)
		fx.later(ms_raw, func():
			_dec("ring", H, tx, tz, r10 * 1.25, 0.5, 1, {"growFrom": 0.3})
			fx.emit({"x": tx, "y": 0.8, "z": tz, "count": 26, "color": H, "spread": r10 * 0.45, "speed": 1.4, "up": 2.2, "life": 0.9, "size": 0.2})
			fx.snd("curse", tx, tz))
	elif kind == "pulse":
		# Fen Wisp: a cold teal ring where you stand, ripples spreading on the water.
		var r11 := fx.f(ev, "r", 2.3)
		var W := 0x7fe0d0
		_dec("disc", W, tx, tz, r11, ms, 0.3, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.3})
		_dec("ring", 0xc4fff2, tx, tz, r11, ms, 1, {"fadeOut": 0.05, "pulse": 4})
		fx.later(ms_raw, func():
			_dec("ring", 0xeaffff, tx, tz, r11 * 1.2, 0.45, 1, {"growFrom": 0.3})
			fx.emit({"x": tx, "y": 0.4, "z": tz, "count": 18, "color": W, "spread": r11 * 0.4, "speed": 1.6, "up": 1.8, "life": 0.8, "size": 0.16})
			fx.add_ripple(tx, tz, 2.0))
	elif kind == "hook":
		# Drowned Sexton: a rust-brown line along the chain's path, to its full reach.
		var dx := tx - ex
		var dz := tz - ez
		var dir := atan2(dx, dz)
		var hook_len := fx.f(ev, "r", float(DmSimData.SEXTON_HOOK["range"]))
		# The chain catches 0.6m past its reach and 0.3m either side of the line: draw all of it.
		var len_drawn := hook_len + 0.6
		var hx := ex + sin(dir) * len_drawn * 0.5
		var hz := ez + cos(dir) * len_drawn * 0.5
		_dec("disc", 0xa8743a, hx, hz, len_drawn / 2.0, ms, 0.55, {"sz": 1, "sx": ((float(DmSimData.SEXTON_HOOK["halfWidth"]) + 0.3) * 2.0) / len_drawn, "rot": dir + PI, "fadeIn": ms * 0.7, "fadeOut": 0.05})
		_dec("ring", 0xe0a458, ex + sin(dir) * hook_len, ez + cos(dir) * hook_len, 0.9, ms, 0.8, {"fadeOut": 0.05})
		fx.snd("boneHit", ex, ez)
	elif kind == "curse":
		var cu := fx.sp("enemy", "curse")
		_dec("ring", cu, tx, tz, 1.2, ms, 0.85, {"growFrom": 2})
		_dec("glow", cu, tx, tz, 1.4, 0.3, 0.9, {"delay": ms})


func _lob(ex: float, ez: float, tx: float, tz: float, ms: float, color: int, from_y: float, arc: float) -> void:
	var dist := sqrt((tx - ex) * (tx - ex) + (tz - ez) * (tz - ez))
	fx.vfx.projectile({"from": Vector3(ex, from_y, ez), "to": func() -> Variant: return Vector3(tx, 0.3, tz), "kind": "orb", "color": color, "speed": maxf(4.0, dist / maxf(0.2, ms)), "arc": arc})
