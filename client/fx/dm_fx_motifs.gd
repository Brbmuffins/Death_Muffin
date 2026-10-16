class_name DmFxMotifs
extends RefCounted
## Port of necroFx.ts: necromantic motifs layered over the rites (bone splinters, grave dirt, soul motes, rot spores, mist, skull and
## spirit wisps, spectral hands, cracked ground, slash marks). Small touches, never a flash: every call is skipped on Graphics: Low,
## thinned (and without rising billboards or hands) under reduced motion, drawn from a shared token budget so a full legion plus a
## rite rotation cannot flood the particle rings, quieter when a thrall caused it (origin "thrall"), and kept off the shared
## transient pool (decals/sprites, capped at 160) when it is busy. Colours come from the caller (SPELL_FX).

var stats := {"particles": 0, "billboards": 0, "decals": 0, "hands": 0, "calls": 0, "skipped": 0}
var enabled := true

var _fx: Node
var _p: DmFxPrims
var _caps := DmFxData.caps()
var _particle_tokens: float
var _sprite_tokens: float
var _last_ms: int


func _init(fx: Node, prims: DmFxPrims) -> void:
	_fx = fx
	_p = prims
	reset_budget()


func matter(key: String) -> Color:
	return DmFxData.hex(int(DmFxData.data().get("necro_matter", {}).get(key, 0xffffff)))


## Test hook: a refilled budget.
func reset_budget() -> void:
	_last_ms = Time.get_ticks_msec()
	_particle_tokens = float(_caps.get("motif_particle_burst", 240))
	_sprite_tokens = float(_caps.get("motif_sprite_burst", 14))


func _refill() -> void:
	var now := Time.get_ticks_msec()
	var dt := clampf(float(now - _last_ms) / 1000.0, 0.0, 2.0)
	_last_ms = now
	_particle_tokens = minf(float(_caps.motif_particle_burst), _particle_tokens + dt * float(_caps.motif_particle_per_s))
	_sprite_tokens = minf(float(_caps.motif_sprite_burst), _sprite_tokens + dt * float(_caps.motif_sprite_per_s))


## 0 = off (Graphics: Low), otherwise the share of motif particles to draw.
func scale(origin := "player") -> float:
	if not enabled or _fx.quality == "low":
		return 0.0
	return (float(_caps.motif_reduced_scale) if _fx.reduced_motion else 1.0) * (float(_caps.motif_thrall_scale) if origin == "thrall" else 1.0)


func _grant(n: int, origin: String) -> int:
	var s := scale(origin)
	if s <= 0.0 or n <= 0:
		return 0
	_refill()
	var want := maxi(0 if origin == "thrall" else 1, DmMath.js_round(float(n) * s))
	var got := mini(want, int(floor(_particle_tokens)))
	_particle_tokens -= got
	stats["calls"] += 1
	stats["particles"] += got
	if got == 0:
		stats["skipped"] += 1
	return got


func _grant_sprites(n: int, origin: String) -> int:
	if scale(origin) <= 0.0 or _fx.reduced_motion or origin == "thrall" or n <= 0:
		return 0
	if _p.transient_load() >= int(_caps.motif_transient_ceiling):
		return 0
	_refill()
	var got := mini(n, int(floor(_sprite_tokens)))
	_sprite_tokens -= got
	stats["billboards"] += got
	return got


func _o(o: Dictionary, key: String, d: Variant) -> Variant:
	return o.get(key, d)


## Ivory slivers that spit off a struck body and fall. o: n speed color origin
func bone_splinters(x: float, y: float, z: float, o: Dictionary = {}) -> void:
	var n := _grant(int(_o(o, "n", 5)), _o(o, "origin", "player"))
	if n == 0:
		return
	_p.emit({"x": x, "y": y, "z": z, "count": n, "color": _o(o, "color", matter("bone")), "spread": 0.08, "speed": _o(o, "speed", 3.6), "up": 1.9, "life": 0.5, "size": 0.075, "gravity": 14, "drag": 0.7})


## Grave dirt: dark clods thrown up (normal blending) and a low dust puff. o: r n y up origin
func grave_dirt(x: float, z: float, o: Dictionary = {}) -> void:
	var n := _grant(int(_o(o, "n", 5)), _o(o, "origin", "player"))
	if n == 0:
		return
	var r := float(_o(o, "r", 0.5))
	var y := float(_o(o, "y", 0.15))
	_p.emit_smoke({"x": x, "y": y, "z": z, "count": n, "color": matter("dirt"), "spread": r, "speed": 1.5, "up": _o(o, "up", 2.4), "life": 0.65, "size": 0.3, "gravity": 10, "shrink": 0.6, "drag": 0.8})
	_p.emit_smoke({"x": x, "y": y + 0.1, "z": z, "count": int(ceil(float(n) / 3.0)), "color": matter("dust"), "spread": r, "speed": 0.7, "up": 0.5, "life": 0.9, "size": 0.8, "shrink": -0.5, "drag": 1})


## Soul-light motes lifting off the ground. o: r n y up origin
func soul_motes(x: float, z: float, color: Variant, o: Dictionary = {}) -> void:
	var n := _grant(int(_o(o, "n", 6)), _o(o, "origin", "player"))
	if n == 0:
		return
	_p.emit({"x": x, "y": _o(o, "y", 0.25), "z": z, "count": n, "color": color, "spread": _o(o, "r", 0.5), "speed": 0.22, "up": _o(o, "up", 1.1), "life": 1.5, "size": 0.13, "gravity": -0.35, "drag": 0.6})


## Rot spores drifting up in a slow cloud (a darker smoke mote under them). o: r n y origin
func rot_spores(x: float, z: float, color: Variant, o: Dictionary = {}) -> void:
	var n := _grant(int(_o(o, "n", 8)), _o(o, "origin", "player"))
	if n == 0:
		return
	var r := float(_o(o, "r", 1.0))
	var y := float(_o(o, "y", 0.3))
	_p.emit({"x": x, "y": y, "z": z, "count": n, "color": color, "spread": r, "speed": 0.3, "up": 0.45, "life": 2.2, "size": 0.1, "gravity": -0.08, "drag": 0.5})
	if n >= 4:
		_p.emit_smoke({"x": x, "y": y + 0.2, "z": z, "count": int(ceil(float(n) / 4.0)), "color": 0x3d4a22, "spread": r, "speed": 0.2, "up": 0.25, "life": 2.2, "size": 0.7, "shrink": -0.6, "drag": 0.5})


## A thin, low whisper of mist along the ground. o: r n origin
func mist_whisper(x: float, z: float, color: Variant, o: Dictionary = {}) -> void:
	var n := _grant(int(_o(o, "n", 2)), _o(o, "origin", "player"))
	if n == 0:
		return
	_p.emit_smoke({"x": x, "y": 0.35, "z": z, "count": n, "color": color, "spread": _o(o, "r", 1.0), "speed": 0.25, "up": 0.2, "life": 1.7, "size": 1.1, "shrink": -0.7, "drag": 0.7})


## Skull faces that bloom above a point and drift up, one billboard each (capped). o: n r y size rise duration origin
func skull_wisps(x: float, z: float, color: Variant, o: Dictionary = {}) -> void:
	var n := _grant_sprites(int(_o(o, "n", 1)), _o(o, "origin", "player"))
	for i in n:
		var a := float(i) / float(maxi(1, n)) * TAU + randf() * 0.4
		var r := float(_o(o, "r", 0.0))
		_p.flash({"x": x + cos(a) * r, "y": _o(o, "y", 0.7), "z": z + sin(a) * r, "color": color, "size": _o(o, "size", 0.6), "duration": _o(o, "duration", 0.8), "tex": "skull", "rise": _o(o, "rise", 0.8), "opacity": 0.62})


## A ring of skulls standing on a circle (Black Litany). o: n size origin
func skull_ring(x: float, z: float, r: float, color: Variant, o: Dictionary = {}) -> void:
	var o2 := o.duplicate()
	o2["n"] = _o(o, "n", 8)
	o2["r"] = r
	o2["y"] = 0.55
	o2["size"] = _o(o, "size", 0.7)
	o2["rise"] = 0.9
	o2["duration"] = 0.9
	skull_wisps(x, z, color, o2)


## Wisps (the pale spirit sprite) rising from a point. o: n r y size origin
func spirit_wisps(x: float, z: float, color: Variant, o: Dictionary = {}) -> void:
	var n := _grant_sprites(int(_o(o, "n", 2)), _o(o, "origin", "player"))
	for i in n:
		var a := randf() * TAU
		var r := float(_o(o, "r", 0.4)) * sqrt(randf())
		_p.flash({"x": x + cos(a) * r, "y": _o(o, "y", 0.4), "z": z + sin(a) * r, "color": color, "size": _o(o, "size", 0.8), "duration": 1.1, "tex": "wisp", "rise": 1.3, "opacity": 0.8})


## Skeletal hands clawing out of the ground; at most a few fields live at once, none for thralls or when reduced. o: n r duration origin
func spectral_hands(x: float, z: float, o: Dictionary = {}) -> void:
	var origin: String = _o(o, "origin", "player")
	if scale(origin) <= 0.0 or _fx.reduced_motion or origin == "thrall":
		return
	if _p.active_hand_fields() >= 3:
		return
	stats["hands"] += 1
	_p.grave_hands(x, z, float(_o(o, "r", 0.7)), int(_o(o, "n", 3)), float(_o(o, "duration", 1.1)))


## Cracked ground under a point: a faded sigil that lingers (decal, so only when the pool has room). o: duration opacity sx rot origin
func cracked_ground(x: float, z: float, r: float, color: Variant, o: Dictionary = {}) -> void:
	var origin: String = _o(o, "origin", "player")
	if scale(origin) <= 0.0 or _p.transient_load() >= int(_caps.motif_transient_ceiling):
		return
	stats["decals"] += 1
	var d := {"tex": "cracks", "color": color, "x": x, "z": z, "r": r, "rot": _o(o, "rot", randf() * 6.0), "duration": _o(o, "duration", 1.4), "opacity": float(_o(o, "opacity", 0.5)) * (0.6 if origin == "thrall" else 1.0), "growFrom": 0.5}
	if o.has("sx"):
		d["sx"] = o["sx"]
	_p.decal(d)


## A spectral claw-mark across a target (the crescent sprite, laid on the ground for a moment). o: rot r duration origin
func slash_mark(x: float, z: float, color: Variant, o: Dictionary = {}) -> void:
	var origin: String = _o(o, "origin", "player")
	if scale(origin) <= 0.0 or _p.transient_load() >= int(_caps.motif_transient_ceiling):
		return
	stats["decals"] += 1
	_p.decal({"tex": "crescent", "color": color, "x": x, "z": z, "r": _o(o, "r", 1.0), "rot": _o(o, "rot", randf() * 6.0), "duration": _o(o, "duration", 0.4), "opacity": 0.55 if origin == "thrall" else 0.85, "growFrom": 0.6, "fadeOut": 0.25})
