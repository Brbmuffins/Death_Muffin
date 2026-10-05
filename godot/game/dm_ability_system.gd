class_name DmAbilitySystem
extends DmSimCaster
## The non-headless half of src/gameplay/AbilitySystem.ts + NewBloodSystem.ts: DmSimCaster (godot/sim/sim_caster.gd) already does every cast check, aim,
## projectile flight, intent, timed rite, wisp and host-event reaction with the visuals stripped; this subclass puts back every effect, sound, hero gesture,
## camera shake and floating number the web does at the same moments, by overriding the caster's methods, running `super` (so gameplay stays bit-identical)
## and drawing around it. It never changes what the caster sends or spends.
##
## Wiring (see the report): `var abilities := DmAbilitySystem.new(sim, p, self_id, discipline_id, family, mods); abilities.game = self` (DmGame, duck-typed:
## avatar, camera, float_text; all optional). Per frame call `abilities.update(now_ms, dt)`; feed every sim event to `abilities.handle_event(ev)`.
## `game.p` and `abilities.p` must be the same Dictionary.
##
## Visual-only flying projectiles are a second Vfx.projectile with the caster's own from/to/speed/arc, so it flies the same line as the caster's shot.

## The host (DmGame or a stub): avatar, camera, float_text(x, y, z, text, kind), optional hit_number_scale(x, z).
var game: Variant = null
## Effects / audio back-ends (autoloads by default; tests swap in recording stubs).
var fx: Object = null
var audio: Object = null
## Counters of what was asked of Vfx / audio (tests, debugging).
var stats: Dictionary = {"decal": 0, "emit": 0, "smoke": 0, "flash": 0, "light": 0, "beam": 0, "orbit": 0, "projectile": 0, "bb": 0, "motif": 0, "spikes": 0,
	"hands": 0, "bone_orbit": 0, "sfx": 0, "loop": 0, "gesture": 0, "shake": 0, "float": 0}

var _pv: Dictionary = {}
var _last_shot: Variant = null
var _nb_id: String = ""
var _mantle_fx: Variant = null
var _vid: int = 0

const _NB_ATTACK := ["flail_swing", "palm_strike", "resonant_step", "hook_throw"]
const _CAST_SFX := {
	"flail_swing": "flail", "lantern_cone": "lantern", "chain_pull": "chain", "burn_the_dead": "pyre", "watchmans_ward": "ward", "cremate": "pyre",
	"last_light": "ward", "palm_strike": "palm", "resonant_step": "veilRite", "sound_the_corpse": "choir", "toll": "choir", "knell": "choir",
	"choir_of_one": "choir", "great_toll": "choir", "lay_to_rest": "ward", "hook_throw": "chain", "hex_charm": "bloodRite", "crow_swarm": "crow",
	"harvest": "bloodRite", "butcher": "bloodRite", "murder_of_crows": "crow", "spirit_bolt": "spiritBolt", "veil_form": "veilRite", "echo": "veilRite",
	"crossing": "veilRite", "veil_tear": "veilRite", "between_worlds": "veilRite", "hook_pull": "chain",
}


func _init(p_sim: DmWorldSim, p_state: Dictionary, p_self_id: String, p_discipline_id: String = "", p_family: String = "necromancer", p_mods: Dictionary = {}) -> void:
	super._init(p_sim, p_state, p_self_id, p_discipline_id, p_family, p_mods)
	var ml := Engine.get_main_loop()
	if ml is SceneTree:
		var root := (ml as SceneTree).root
		fx = root.get_node_or_null("Vfx")
		audio = root.get_node_or_null("AudioDirector")


## The realtime socket id replaces the provisional solo id once connected (AbilitySystem.setSelf).
func set_self(id: String) -> void:
	self_id = id


# --- thin wrappers over Vfx / audio / host (all null-safe, all counted) ----------------------------------------------------------------------

## A Callable for the effect/audio back-ends that keeps this object alive while an effect still holds it (a lambda captures `self` strongly;
## `Callable(self, name)` would dangle once a scene drops its abilities).
func _cb(method: StringName, args: Array = []) -> Callable:
	var me := self
	return func() -> Variant: return me.callv(method, args)


func _col(group: String, key: String) -> Color:
	return DmFxData.spell(group, key)


func _fol_p() -> Variant:
	return Vector3(_px(), 0.0, _pz()) if p["alive"] else null


func _fol_p2() -> Variant:
	return Vector2(_px(), _pz()) if p["alive"] else null


func _decal(tex: String, color: Variant, x: float, z: float, r: float, duration: float, opacity: float, extra: Dictionary = {}) -> Variant:
	var o := {"tex": tex, "color": color, "x": x, "z": z, "r": r, "duration": duration, "opacity": opacity}
	o.merge(extra, true)
	stats["decal"] += 1
	return fx.decal(o) if fx != null else null


func _emit(x: float, y: float, z: float, count: int, color: Variant, spread: float, speed: float, up: float, life: float, size: float, extra: Dictionary = {}) -> void:
	var o := {"x": x, "y": y, "z": z, "count": count, "color": color, "spread": spread, "speed": speed, "up": up, "life": life, "size": size}
	o.merge(extra, true)
	stats["emit"] += 1
	if fx != null:
		fx.emit(o)


func _smoke(x: float, y: float, z: float, count: int, color: Variant, spread: float, speed: float, up: float, life: float, size: float, extra: Dictionary = {}) -> void:
	var o := {"x": x, "y": y, "z": z, "count": count, "color": color, "spread": spread, "speed": speed, "up": up, "life": life, "size": size}
	o.merge(extra, true)
	stats["smoke"] += 1
	if fx != null:
		fx.emit_smoke(o)


func _flash(x: float, y: float, z: float, color: Variant, size: float, duration: float, extra: Dictionary = {}) -> void:
	var o := {"x": x, "y": y, "z": z, "color": color, "size": size, "duration": duration}
	o.merge(extra, true)
	stats["flash"] += 1
	if fx != null:
		fx.flash(o)


func _lf(x: float, y: float, z: float, color: Color, intensity: float, life: float) -> void:
	stats["light"] += 1
	if fx != null:
		fx.light_flash(Vector3(x, y, z), color, intensity, life)


func _beam(a: Variant, b: Callable, color: Variant, width: float, duration: float) -> Variant:
	stats["beam"] += 1
	return fx.beam(a, b, color, width, duration) if fx != null else null


func _orbit(o: Dictionary) -> Variant:
	stats["orbit"] += 1
	return fx.orbit(o) if fx != null else null


func _bb(id: String, x: float, z: float, o: Dictionary = {}) -> Variant:
	stats["bb"] += 1
	if fx == null:
		return null
	return fx.play(id, Vector3(x, float(o.get("y", 0.0)), z), o)


func _kill(h: Variant) -> void:
	if h != null and h is Object and is_instance_valid(h) and h.has_method("kill"):
		h.kill()


func _v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func _m_splinters(x: float, y: float, z: float, n: int, color: Variant, speed: float = 3.6, origin: String = "player") -> void:
	stats["motif"] += 1
	if fx != null:
		fx.motifs.bone_splinters(x, y, z, {"n": n, "color": color, "speed": speed, "origin": origin})


func _m_dirt(x: float, z: float, r: float, n: int, up: float = 2.4, origin: String = "player") -> void:
	stats["motif"] += 1
	if fx != null:
		fx.motifs.grave_dirt(x, z, {"r": r, "n": n, "up": up, "origin": origin})


func _m_motes(x: float, z: float, color: Variant, r: float, n: int, up: float = 1.1, y: float = 0.25, origin: String = "player") -> void:
	stats["motif"] += 1
	if fx != null:
		fx.motifs.soul_motes(x, z, color, {"r": r, "n": n, "up": up, "y": y, "origin": origin})


func _m_skulls(x: float, z: float, color: Variant, o: Dictionary) -> void:
	stats["motif"] += 1
	if fx != null:
		fx.motifs.skull_wisps(x, z, color, o)


func _sfx(id: String, x: float, z: float, intensity: float = 1.0) -> void:
	stats["sfx"] += 1
	if audio != null:
		audio.play_sfx(id, Vector2(x, z), intensity)


func _loop(id: String, ms: float, x: float, z: float, follow: Callable = Callable()) -> void:
	stats["loop"] += 1
	if audio != null:
		audio.loop_sfx(id, ms, Vector2(x, z), follow)


func _shake(amount: float) -> void:
	stats["shake"] += 1
	shakes.append(amount)
	if game != null and game.get("camera") != null:
		game.camera.shake(amount)


func _avatar() -> Variant:
	return game.get("avatar") if game != null else null


## Hero gesture: avatar.cast(kind, seconds, facing, gesture_seconds, ability_id). `gesture_s` < 0 reads CAST_FLOW[flow_id].gestureSeconds.
func _gesture(kind: String, seconds: float, flow_id: String, ability_id: String = "", gesture_s: float = -1.0) -> void:
	stats["gesture"] += 1
	var av: Variant = _avatar()
	if av == null or not av.has_method("cast"):
		return
	var gs := gesture_s
	if gs < 0.0:
		gs = float(DmAbilities.cast_flow(flow_id)["gestureSeconds"])
	av.cast(kind, seconds, float(p["facing"]), gs, ability_id)


func _tip() -> Array:
	if not tip_fn.is_valid():
		var av: Variant = _avatar()
		if av != null and av.has_method("tip"):
			var v: Variant = av.tip()
			if v is Vector3:
				return [v.x, v.y, v.z]
			if v is Array:
				return v
	return super._tip()


func _new_popups(from_idx: int) -> Array:
	var out: Array = []
	var b := _boss()
	for i in range(from_idx, popups.size()):
		var pu: Dictionary = popups[i]
		if b.active and pu["x"] == b.x and pu["z"] == b.z:
			continue
		out.append(pu)
	return out


## The context dictionary bound to the newest projectile's arrival (every rite binds its own).
func _last_ctx() -> Dictionary:
	var pr: Dictionary = _projectiles.back()
	return (pr["on_arrive"] as Callable).get_bound_arguments()[0]


func _timed_ctx() -> Dictionary:
	return (_timed.back()["tick"] as Callable).get_bound_arguments()[0]


# --- the visual projectile follows the caster's own shot ---------------------------------------------------------------------------------

func _vis_to(to_fn: Callable) -> Variant:
	var q: Variant = to_fn.call()
	return Vector3(q[0], q[1], q[2]) if q != null else null


func _vis_trail(pos: Vector3, color: Color) -> void:
	_m_motes(pos.x, pos.z, color, 0.1, 1, 0.5, pos.y - 0.1)


func _projectile(from: Array, to_fn: Callable, speed: float, arc: float, on_arrive: Callable) -> void:
	super._projectile(from, to_fn, speed, arc, on_arrive)
	_last_shot = null
	if _pv.is_empty() or fx == null:
		return
	var o := {"from": _v3(from), "to": _cb("_vis_to", [to_fn]), "speed": speed, "color": _pv["color"], "kind": _pv["kind"], "arc": arc}
	if _pv.has("tex"):
		o["tex"] = _pv["tex"]
		o["size"] = _pv["size"]
	if _pv.has("trail"):
		var me := self
		var tc: Color = _pv["trail"]
		o["on_trail"] = func(pos: Vector3) -> void: me._vis_trail(pos, tc)
	stats["projectile"] += 1
	_last_shot = fx.projectile(o)


# --- per frame -----------------------------------------------------------------------------------------------------------------------------

func update(now: float, dt: float) -> void:
	super.update(now, dt)
	if not popups.is_empty():
		for pu: Dictionary in popups:
			_float_number(float(pu["x"]), float(pu["z"]), float(pu["amount"]), String(pu["kind"]))
		popups = []
	if not notes.is_empty():
		for n: Dictionary in notes:
			stats["float"] += 1
			if game != null and game.has_method("float_text"):
				game.float_text(_px(), 2.4, _pz(), String(n["text"]), String(n["kind"]))
		notes = []


func _float_number(x: float, z: float, amount: float, kind: String) -> void:
	stats["float"] += 1
	if game == null or not game.has_method("float_text"):
		return
	var scale := 1.0
	if game.has_method("hit_number_scale"):
		scale = float(game.hit_number_scale(x, z))
	game.float_text(x, 1.6, z, str(DmMath.js_round(amount * scale)), "crit" if kind == "crit" else "hit")


# --- Soul Harvest / casting ----------------------------------------------------------------------------------------------------------

func cast(id: String, target: Dictionary, now: float) -> String:
	var emp := empowered(id)
	var r := super.cast(id, target, now)
	if r == "ok" and emp:
		_soul_release()
	return r


## The harvested souls pour out of the caster into the empowered spell.
func _soul_release() -> void:
	var x := _px()
	var z := _pz()
	var jade := _col("souls", "jade")
	var pale := _col("souls", "pale")
	_decal("ring", jade, x, z, 1.8, 0.5, 1.0, {"growFrom": 0.3})
	_emit(x, 0.4, z, 20, jade, 0.6, 1.2, 3.2, 0.8, 0.3)
	_emit(x, 1.4, z, 8, pale, 0.3, 2.4, 1.0, 0.5, 0.22)
	_lf(x, 1.6, z, jade, 26.0, 0.45)
	_m_motes(x, z, pale, 1.1, 10, 2.2, 0.3)
	_m_skulls(x, z, pale, {"n": 2, "r": 0.7, "y": 1.0, "size": 0.55, "rise": 1.2})
	_bb("soul_harvest_pillar", x, z)
	_sfx("soulRelease", x, z)


# --- Bone Needle / scythe / spear ----------------------------------------------------------------------------------------------------------

func _needle(t: Dictionary) -> String:
	var r := super._needle(t)
	if r != "ok":
		return r
	var N := DmFxData.spell_group("needle")
	_gesture("cast", 3.2, "bone_needle", "bone_needle")
	var from := _tip()
	_flash(from[0], from[1], from[2], N["trail"], 0.7, 0.14)
	_sfx("needleCast", _px(), _pz())
	if rune("bone_needle") == "rune_volley" and _needle_casts % int(DmSimData.RUNE_TUNING["volley"]["every"]) == 0:
		_m_splinters(from[0], from[1], from[2], 5, N["core"], 3.5)
		_decal("ring", N["trail"], _px(), _pz(), 1.3, 0.35, 0.55, {"growFrom": 0.4})
	return r


func _fire_needle(from: Array, ctx: Dictionary) -> void:
	_pv = {"kind": "needle", "color": _col("needle", "trail")}
	super._fire_needle(from, ctx)
	_pv = {}


func _needle_arrive(pos: Array, ctx: Dictionary) -> void:
	var lands := false
	if p["alive"]:
		lands = _boss().active if ctx["boss"] else sim.enemies.has(int(ctx["enemy_id"]))
	super._needle_arrive(pos, ctx)
	if not lands:
		return
	var N := DmFxData.spell_group("needle")
	var crit: bool = ctx["crit"]
	_sfx("needleHit", pos[0], pos[2], 1.4 if crit else 1.0)
	_flash(pos[0], pos[1], pos[2], N["impact"], 1.7 if crit else 1.05, 0.2)
	_emit(pos[0], pos[1], pos[2], 16 if crit else 8, N["dust"], 0.1, 3.2, 1.2, 0.4, 0.13, {"gravity": 7.0})
	if crit:
		_emit(pos[0], pos[1], pos[2], 10, N["trail"], 0.2, 4.0, 0.5, 0.3, 0.3)
	_m_splinters(pos[0], pos[1], pos[2], 7 if crit else 3, N["core"])
	if crit:
		_bb("crit_hit", pos[0], pos[2], {"y": pos[1]})


func _enemy_follow(id: int, y: float, last: Array) -> Variant:
	var e: DmSimEnemy = sim.enemies.get(id)
	if e != null:
		last[0] = e.x
		last[1] = e.z
	return Vector3(last[0], y, last[1])


func _splinter(first_id: int, at: Array, dmg: float, skip: Dictionary = {}) -> void:
	var first: DmSimEnemy = sim.enemies.get(first_id)
	var pool: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if not _gone(e) and not skip.has(e.id):
			pool.append(_foe_dict(e))
	var fd: Dictionary = _foe_dict(first) if first != null else {"id": first_id, "x": at[0], "z": at[2]}
	var tg: Variant = DmRunes.splinter_target(fd, pool)
	super._splinter(first_id, at, dmg, skip)
	if tg == null:
		return
	var core := _col("needle", "core")
	var last: Array = [tg["x"], tg["z"]]
	_beam(Vector3(at[0], 1.0, at[2]), _cb("_enemy_follow", [int(tg["id"]), 1.0, last]), core, 0.03, 0.16)
	_flash(tg["x"], 1.0, tg["z"], core, 0.7, 0.16)
	_m_splinters(tg["x"], 1.0, tg["z"], 3, core)
	_m_splinters(at[0], 1.0, at[2], 6, core, 4.5)


func _pierce_beyond(first_id: int, at: Array, dmg: float, count: int, extra: Dictionary) -> void:
	var pool: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		if not _gone(e):
			pool.append(_foe_dict(e))
	var nxt := DmWeaponLine.pierce_targets({"x": _px(), "z": _pz()}, {"x": at[0], "z": at[2], "id": first_id}, pool, count)
	super._pierce_beyond(first_id, at, dmg, count, extra)
	if nxt.is_empty():
		return
	var N := DmFxData.spell_group("needle")
	for e: Dictionary in nxt:
		var last: Array = [e["x"], e["z"]]
		_beam(Vector3(at[0], 1.0, at[2]), _cb("_enemy_follow", [int(e["id"]), 1.0, last]), N["trail"], 0.02, 0.12)
		_flash(e["x"], 1.0, e["z"], N["impact"], 0.8, 0.16)
		_emit(e["x"], 1.0, e["z"], 6, N["dust"], 0.1, 3.0, 1.0, 0.35, 0.12, {"gravity": 7.0})
		_m_splinters(e["x"], 1.0, e["z"], 3, N["core"])
	_sfx("needleHit", nxt[0]["x"], nxt[0]["z"], 0.8)


func _reap(t: Dictionary) -> String:
	var T: Dictionary = DmSimData.NECRO_WEAPON_TUNING["scythe"]
	var n0 := popups.size()
	var reaped_before := _reaped.duplicate()
	var r := super._reap(t)
	if r != "ok":
		return r
	_gesture("attack", 2.6, "bone_needle", "", float(T["gestureSeconds"]))
	var N := DmFxData.spell_group("needle")
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var l := _h(dx, dz)
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	var window := _now + float(T["reapWindowMs"])
	var landed := 0
	for id in _reaped.keys():
		if float(_reaped[id]) == window and not (reaped_before.has(id) and float(reaped_before[id]) == window):
			var e: DmSimEnemy = sim.enemies.get(int(id))
			if e == null:
				continue
			landed += 1
			_emit(e.x, 0.9, e.z, 7, N["dust"], 0.2, 3.0, 1.2, 0.4, 0.13, {"gravity": 7.0})
			_flash(e.x, 1.0, e.z, N["impact"], 0.9, 0.16)
			_m_splinters(e.x, 0.9, e.z, 4, N["core"])
	var b := _boss()
	var hit_boss := false
	for i in range(n0, popups.size()):
		if b.active and popups[i]["x"] == b.x and popups[i]["z"] == b.z:
			hit_boss = true
	if hit_boss:
		landed += 1
		_flash(b.x, 1.6, b.z, N["impact"], 1.2, 0.18)
		var bd := _h(b.x - _px(), b.z - _pz())
		if bd - DmSimConsts.BOSS_RADIUS > float(T["reach"]) * 0.6:
			var at := maxf(1.3, bd - DmSimConsts.BOSS_RADIUS)
			_decal("crescent", N["trail"], _px() + dx * at, _pz() + dz * at, 1.6, 0.28, 0.85, {"rot": atan2(dx, dz), "growFrom": 0.6, "fadeOut": 0.22})
	_decal("crescent", N["trail"], _px() + dx * 1.3, _pz() + dz * 1.3, 2.0, 0.32, 0.95, {"rot": atan2(dx, dz), "growFrom": 0.6, "fadeOut": 0.25})
	_lf(_px() + dx * 1.3, 1.0, _pz() + dz * 1.3, N["trail"], 10.0, 0.16)
	_m_dirt(_px() + dx * 1.5, _pz() + dz * 1.5, 0.7, 5)
	_sfx("spear", _px(), _pz(), 1.1)
	if landed > 0:
		_sfx("boneHit", _px() + dx * 1.8, _pz() + dz * 1.8)
	return r


func _spear(t: Dictionary, mult: float = 1.0) -> String:
	_pv = {"kind": "needle", "color": _col("spear", "bone")}
	var r := super._spear(t, mult)
	_pv = {}
	if r != "ok":
		return r
	var S := DmFxData.spell_group("spear")
	var ctx := _last_ctx()
	_gesture("cast", 2.4, "marrow_spear", "marrow_spear")
	var tip := _tip()
	_flash(tip[0], tip[1], tip[2], S["bone"], 0.65, 0.12)
	var end: Array = ctx["end"]
	_beam(_v3(tip), _cb("_vis_const", [end]), S["bone"], 0.025, 0.16)
	return r


func _vis_const(a: Array) -> Variant:
	return _v3(a)


func _spear_arrive(pos: Array, ctx: Dictionary) -> void:
	var n0 := popups.size()
	var alive: bool = p["alive"]
	super._spear_arrive(pos, ctx)
	if not alive or ctx["centre"] != null or ctx["impale"]:
		return
	var S := DmFxData.spell_group("spear")
	for pu: Dictionary in _new_popups(n0):
		_flash(pu["x"], 0.8, pu["z"], S["bone"], 0.65, 0.14)
	var origin: Dictionary = ctx["origin"]
	var dx: float = ctx["dx"]
	var dz: float = ctx["dz"]
	var rng_m: float = ctx["rng"]
	var radius: float = ctx["radius"]
	var mult: float = ctx["mult"]
	var end: Array = ctx["end"]
	var ox: float = origin["x"]
	var oz: float = origin["z"]
	if fx != null:
		stats["spikes"] += 1
		fx.spike_line(ox, oz, dx, dz, rng_m, radius * 1.3, false)
	_decal("cracks", S["crack"], ox + dx * rng_m * 0.5, oz + dz * rng_m * 0.5, rng_m * 0.5, 0.65, 0.55, {"sx": 0.16 * mult, "rot": atan2(dx, dz)})
	for i in range(1, 7):
		var x := ox + dx * (float(i) / 6.0) * rng_m
		var z := oz + dz * (float(i) / 6.0) * rng_m
		_emit(x, 0.3, z, 3, S["bone"], 0.25, 1.4, 2.1, 0.4, 0.12, {"gravity": 9.0})
		if i % 2 == 0:
			_m_dirt(x, z, radius * 0.8, int(4.0 * mult))
	_m_splinters(end[0], 0.6, end[2], 6, S["bone"], 4.5)
	_lf(ox + dx * 4.0, 1.0, oz + dz * 4.0, S["crack"], 12.0, 0.22)
	_sfx("spear", ox + dx * 3.0, oz + dz * 3.0)
	_shake(0.055)


func _spear_ring(c: Dictionary, r: float, dmg: float) -> void:
	var n0 := popups.size()
	super._spear_ring(c, r, dmg)
	var S := DmFxData.spell_group("spear")
	for pu: Dictionary in _new_popups(n0):
		_flash(pu["x"], 0.8, pu["z"], S["bone"], 0.65, 0.14)
	var cx: float = c["x"]
	var cz: float = c["z"]
	if fx != null:
		stats["spikes"] += 2
		fx.spike_ring(cx, cz, r * 0.95, DmMath.js_round(10.0 + r * 3.0), 1.1)
		fx.spike_ring(cx, cz, r * 0.5, 6, 0.9)
	_decal("ring", S["bone"], cx, cz, r * 1.05, 0.7, 0.85, {"growFrom": 0.3})
	_decal("cracks", S["crack"], cx, cz, r, 0.8, 0.6, {"rot": randf() * 6.0})
	_m_dirt(cx, cz, r * 0.8, 8, 3.0)
	_m_splinters(cx, 0.6, cz, 8, S["bone"], 4.5)
	_lf(cx, 1.0, cz, S["crack"], 14.0, 0.25)
	_sfx("spear", cx, cz)
	_shake(0.07)


func _spear_impale(origin: Dictionary, dx: float, dz: float, rng_m: float, half_w: float, dmg: float) -> void:
	super._spear_impale(origin, dx, dz, rng_m, half_w, dmg)
	var S := DmFxData.spell_group("spear")
	var foes: Array = []
	for e: DmSimEnemy in _live_foes():
		foes.append(_foe_dict(e))
	var hit: Variant = DmRunes.impale_target(origin, dx, dz, rng_m, half_w, foes)
	var b := _boss()
	var boss_along := INF
	if b.active:
		var rx := b.x - float(origin["x"])
		var rz := b.z - float(origin["z"])
		var along := rx * dx + rz * dz
		if along > 0.0 and along < rng_m + DmSimConsts.BOSS_RADIUS and absf(rx * dz - rz * dx) < half_w + DmSimConsts.BOSS_RADIUS:
			boss_along = along
	var ox: float = origin["x"]
	var oz: float = origin["z"]
	if hit == null and boss_along == INF:
		var ex := ox + dx * rng_m
		var ez := oz + dz * rng_m
		if fx != null:
			stats["spikes"] += 1
			fx.spike_line(ox, oz, dx, dz, 2.0, 0.6, false)
		_m_dirt(ex, ez, 0.6, 4)
		_sfx("spear", ex, ez)
		return
	var tx: float
	var tz: float
	var al: float
	if hit != null and float(hit["along"]) <= boss_along:
		var e: Dictionary = hit["foe"]
		var root_s := float(DmSimData.RUNE_TUNING["impale"]["rootS"])
		if fx != null:
			stats["spikes"] += 1
			fx.spike_ring(e["x"], e["z"], 0.95, 9, root_s + 0.1)
		_decal("ring", S["crack"], e["x"], e["z"], 1.3, root_s, 0.7, {"growFrom": 0.5, "fadeOut": 0.4})
		tx = e["x"]
		tz = e["z"]
		al = hit["along"]
	else:
		tx = b.x
		tz = b.z
		al = boss_along
	if fx != null:
		stats["spikes"] += 1
		fx.spike_line(ox, oz, dx, dz, maxf(1.5, al), 0.5, false)
	_flash(tx, 1.0, tz, S["bone"], 1.4, 0.2)
	_m_splinters(tx, 1.0, tz, 8, S["bone"], 4.5)
	_lf(tx, 1.0, tz, S["crack"], 14.0, 0.25)
	_sfx("spear", tx, tz)
	_shake(0.06)


# --- Exhume / Miasma -------------------------------------------------------------------------------------------------------------------------

func _exhume(t: Dictionary) -> String:
	# Everything about the bodies is read before the host can consume them.
	var c := pick_corpse(t)
	var RT: Dictionary = DmSimData.RUNE_TUNING
	var rn := rune("exhume")
	var company: Array = []
	var others: Array = []
	if c != null:
		if rn == "rune_bone_colossus":
			for o: DmSimCorpse in _corpses_within(c.x, c.z, float(RT["colossus"]["pickRadius"])).slice(0, int(RT["colossus"]["corpses"])):
				company.append([o.x, o.z])
		if rn == "rune_mass_grave":
			for o: DmSimCorpse in _corpses_within(c.x, c.z, float(RT["massGrave"]["pickRadius"])).slice(0, int(RT["massGrave"]["count"])):
				if o.id != c.id:
					others.append([o.x, o.z])
	var cx_ := c.x if c != null else 0.0
	var cz_ := c.z if c != null else 0.0
	var r := super._exhume(t)
	if r != "ok":
		return r
	var X := DmFxData.spell_group("exhume")
	var N := DmFxData.spell_group("needle")
	_gesture("dig", 2.6, "exhume", "exhume")
	var tipv := _tip()
	_beam(_v3(tipv), _cb("_vis_const", [[cx_, 0.3, cz_]]), X["beam"], 0.06, 0.4)
	_sfx("exhume", cx_, cz_)
	_emit(cx_, 0.2, cz_, 26, X["spirit"], 0.6, 0.4, 3.4, 1.0, 0.34, {"gravity": -0.5})
	_decal("cracks", X["deep"], cx_, cz_, 1.4, 1.3, 0.9, {"rot": randf() * 6.0, "growFrom": 0.3})
	_m_dirt(cx_, cz_, 0.6, 9, 3.0)
	if fx != null:
		stats["motif"] += 2
		fx.motifs.spectral_hands(cx_, cz_, {"n": 3, "r": 0.6, "duration": 1.2})
		fx.motifs.spirit_wisps(cx_, cz_, X["spirit"], {"n": 2, "r": 0.3, "y": 0.5, "size": 0.7})
	_bb("exhume_lift", cx_, cz_)
	if rn == "rune_mass_grave":
		for o: Array in others:
			_beam(_v3(_tip()), _cb("_vis_const", [[o[0], 0.3, o[1]]]), X["beam"], 0.04, 0.35)
			_decal("cracks", X["deep"], o[0], o[1], 1.2, 1.2, 0.9, {"rot": randf() * 6.0, "growFrom": 0.3})
			_m_dirt(o[0], o[1], 0.5, 6, 2.6)
			if fx != null:
				stats["motif"] += 1
				fx.motifs.spectral_hands(o[0], o[1], {"n": 2, "r": 0.5, "duration": 1.1})
			_emit(o[0], 0.2, o[1], 18, X["spirit"], 0.5, 0.4, 3.0, 1.0, 0.3, {"gravity": -0.5})
	elif _colossus_cast and not company.is_empty():
		var ccx := 0.0
		var ccz := 0.0
		for o: Array in company:
			ccx += o[0]
			ccz += o[1]
		ccx /= company.size()
		ccz /= company.size()
		for o: Array in company:
			_beam(Vector3(o[0], 0.4, o[1]), _cb("_vis_const", [[ccx, 1.2, ccz]]), X["beam"], 0.05, 0.7)
			_emit(o[0], 0.3, o[1], 14, X["spirit"], 0.4, 2.2, 1.2, 0.8, 0.3)
			_m_splinters(o[0], 0.4, o[1], 5, N["core"], 3.0)
		_decal("sigil", X["spirit"], ccx, ccz, 3.2, 1.4, 0.8, {"growFrom": 1.4, "spin": 0.8})
		_decal("ring", X["beam"], ccx, ccz, 3.6, 0.9, 0.9, {"growFrom": 0.4})
		_emit(ccx, 0.4, ccz, 36, X["spirit"], 3.0, 5.0, 0.4, 0.5, 0.3, {"inward": true, "drag": 0.0})
		_lf(ccx, 1.5, ccz, X["spirit"], 34.0, 0.9)
		_shake(0.1)
	return r


func _miasma(t: Dictionary, mult: float = 1.0) -> String:
	_pv = {"kind": "orb", "color": _col("miasma", "rot")}
	var r := super._miasma(t, mult)
	_pv = {}
	if r == "ok":
		_gesture("cast", 2.2, "miasma", "miasma")
	return r


func _send_on_arrive(pos: Array, intent: Dictionary) -> void:
	var alive: bool = p["alive"]
	super._send_on_arrive(pos, intent)
	if not alive or intent.get("t") != "miasma":
		return
	var M := DmFxData.spell_group("miasma")
	var x: float = intent["x"]
	var z: float = intent["z"]
	var r: float = intent["r"]
	_decal("ring", M["rot"], x, z, r, 0.45, 0.7, {"growFrom": 0.2})
	_sfx("miasma", x, z)
	_loop("miasmaLoop", 6000.0, x, z)
	_smoke(x, 0.4, z, 6, M["spore"], r * 0.6, 0.5, 0.3, 0.9, 1.1, {"shrink": -0.3, "drag": 0.8})
	_emit(x, 0.3, z, 16, M["rot"], r * 0.5, 1.1, 0.6, 0.65, 0.18)
	if fx != null:
		stats["motif"] += 1
		fx.motifs.rot_spores(x, z, M["rot"], {"r": r * 0.75, "n": DmMath.js_round(8.0 + r * 2.0)})
	if not intent.has("creep"):
		_bb("miasma_cloud", x, z, {"scale": r / 3.8})


# --- Grimoire rites --------------------------------------------------------------------------------------------------------------------------

func _skull(t: Dictionary) -> String:
	var r := super._skull(t)
	if r == "ok":
		var from := _tip()
		_gesture("cast", 2.8, "wailing_skull", "wailing_skull")
		_flash(from[0], from[1], from[2], _col("skull", "jade"), 0.9, 0.18)
		_sfx("wail", _px(), _pz())
	return r


func _skull_leap(from: Array, t: Dictionary, dmg: float, hop: int, budget: int, struck: Dictionary) -> void:
	_pv = {"kind": "sprite", "tex": "skull", "size": 0.95, "color": _col("skull", "jade"), "trail": _col("skull", "jade")}
	super._skull_leap(from, t, dmg, hop, budget, struck)
	_pv = {}
	var shot: Variant = _last_shot
	var follow := Callable()
	if shot != null:
		follow = Callable(shot, "pos")
	_bb("wailing_skull_projectile", from[0], from[2], {"y": from[1], "follow": follow})


func _skull_arrive(pos: Array, ctx: Dictionary) -> void:
	var landed := false
	var killed := false
	if p["alive"]:
		if ctx["boss"]:
			landed = _boss().active
		else:
			var e: DmSimEnemy = sim.enemies.get(int(ctx["enemy_id"]))
			if e != null and e.state != "dead" and e.hp > 0.0:
				landed = true
				killed = e.hp <= float(ctx["dmg"]) * (1.0 + float(DmSimData.FRACTURE["perStack"]) * e.fracture)
	var n_proj := _projectiles.size()
	super._skull_arrive(pos, ctx)
	if not p["alive"] and not landed:
		return
	var SK := DmFxData.spell_group("skull")
	if landed:
		_sfx("needleHit", pos[0], pos[2], 1.2)
		_flash(pos[0], pos[1], pos[2], SK["pale"], 1.9 if killed else 1.3, 0.22, {"tex": "skull"})
		_decal("ring", SK["jade"], pos[0], pos[2], 0.9, 0.4, 0.9, {"growFrom": 0.3})
		_emit(pos[0], pos[1], pos[2], 18 if killed else 10, SK["jade"], 0.2, 2.4, 1.4, 0.5, 0.22, {"gravity": -1.0})
		_m_splinters(pos[0], pos[1], pos[2], 6 if killed else 3, SK["pale"])
	if _projectiles.size() > n_proj:
		_sfx("wail", pos[0], pos[2], 0.6)


func _step(t: Dictionary) -> String:
	var ox := _px()
	var oz := _pz()
	var n0 := popups.size()
	var r := super._step(t)
	if r != "ok":
		return r
	var ST := DmFxData.spell_group("step")
	_smoke(ox, 0.9, oz, 6, ST["mist"], 0.45, 0.7, 0.7, 0.75, 1.2, {"shrink": -0.4})
	_emit(ox, 1.0, oz, 18, ST["blood"], 0.4, 2.2, 1.2, 0.45, 0.2, {"gravity": 6.0})
	_decal("bloodSigil", ST["crimson"], ox, oz, 1.2, 0.8, 0.85, {"growFrom": 0.6})
	_m_dirt(ox, oz, 0.5, 6)
	_m_motes(ox, oz, ST["blood"], 0.4, 4, 1.4)
	_bb("grave_step_smoke", ox, oz, {"duration": 1.4})
	_gesture("cast", 3.0, "grave_step", "grave_step")
	_beam(Vector3(ox, 1.0, oz), _cb("_vis_p1"), ST["blood"], 0.07, 0.22)
	for pu: Dictionary in _new_popups(n0):
		_flash(pu["x"], 0.9, pu["z"], ST["blood"], 0.7, 0.16)
	var rr := float(DmCombatData.const_table("GRAVE_STEP")["burstRadius"])
	var x := _px()
	var z := _pz()
	_decal("bloodSigil", ST["blood"], x, z, rr * 1.15, 0.9, 1.0, {"growFrom": 0.25, "spin": 0.8})
	_decal("ring", ST["crimson"], x, z, rr * 1.05, 0.4, 0.9, {"growFrom": 0.15})
	_emit(x, 0.6, z, 26, ST["blood"], 0.3, rr * 2.6, 1.4, 0.5, 0.26, {"drag": 1.5})
	_emit(x, 0.8, z, 8, ST["hot"], 0.2, 2.0, 2.2, 0.35, 0.18)
	_smoke(x, 0.5, z, 5, ST["mist"], rr * 0.4, 1.2, 0.5, 0.8, 1.2, {"shrink": -0.4})
	_lf(x, 1.2, z, ST["blood"], 30.0, 0.35)
	_m_dirt(x, z, rr * 0.5, 8, 3.0)
	_m_splinters(x, 0.5, z, 6, DmFxData.hex(int(DmFxData.data()["necro_matter"]["bone"])))
	_bb("grave_step_smoke", x, z, {"scale": 1.2, "duration": 1.4})
	_sfx("bloodStep", x, z)
	_shake(0.05)
	return r


func _vis_p1() -> Variant:
	return Vector3(_px(), 1.0, _pz())


func _frost(t: Dictionary) -> String:
	_pv = {"kind": "orb", "color": _col("frost", "pale")}
	var r := super._frost(t)
	_pv = {}
	if r != "ok":
		return r
	var FR := DmFxData.spell_group("frost")
	var ctx := _last_ctx()
	var origin: Dictionary = ctx["origin"]
	var dx: float = ctx["dx"]
	var dz: float = ctx["dz"]
	var ln: float = ctx["len"]
	var ox: float = origin["x"]
	var oz: float = origin["z"]
	var rot := atan2(dx, dz)
	_gesture("cast", 2.4, "grave_frost", "grave_frost")
	var tip := _tip()
	_flash(tip[0], tip[1], tip[2], FR["pale"], 0.8, 0.14)
	_decal("frostFan", FR["frost"], ox + dx * ln * 0.5, oz + dz * ln * 0.5, ln * 0.5, 0.9, 0.95, {"rot": rot + PI, "growFrom": 0.35, "fadeIn": 0.08, "fadeOut": 0.45})
	for i in range(1, 5):
		var k := float(i) / 4.0
		_smoke(ox + dx * ln * k * 0.8, 0.7, oz + dz * ln * k * 0.8, 2, 0xb9cbe6, 0.4 + k * 1.4, 0.6, 0.3, 0.7, 1.0 + k * 0.6, {"shrink": -0.4, "drag": 1.0})
		_emit(ox + dx * ln * k * 0.85, 0.8, oz + dz * ln * k * 0.85, 5, FR["pale"], 0.3 + k * 1.2, 1.2, 0.4, 0.45, 0.14)
	_sfx("frost", ox + dx * 2.0, oz + dz * 2.0)
	if fx != null:
		stats["motif"] += 4
		fx.motifs.cracked_ground(ox + dx * ln * 0.5, oz + dz * ln * 0.5, ln * 0.5, FR["pale"], {"rot": rot, "sx": 0.5, "duration": 1.8, "opacity": 0.4})
		for i in range(1, 4):
			fx.motifs.mist_whisper(ox + dx * ln * i * 0.28, oz + dz * ln * i * 0.28, 0x8fa6c8, {"r": 0.5 + i * 0.5, "n": 2})
	_bb("grave_frost_mist", ox + dx * ln * 0.45, oz + dz * ln * 0.45, {"rot": rot})
	return r


func _frost_arrive(pos: Array, ctx: Dictionary) -> void:
	# The cone's victims are read before the intents change their chill.
	var seen: Array = []
	if p["alive"]:
		var G: Dictionary = DmSimData.GRAVE_FROST
		var origin: Dictionary = ctx["origin"]
		var dx: float = ctx["dx"]
		var dz: float = ctx["dz"]
		var ln: float = ctx["len"]
		var slope := tan((float(G["halfAngleDeg"]) * PI) / 180.0)
		var count := 0
		for e: DmSimEnemy in sim.enemies.values():
			if _gone(e):
				continue
			var rx := e.x - float(origin["x"])
			var rz := e.z - float(origin["z"])
			var along := rx * dx + rz * dz
			if along < -e.radius or along > ln + e.radius:
				continue
			if absf(rx * dz - rz * dx) > slope * maxf(0.0, along) + e.radius:
				continue
			seen.append({"x": e.x, "z": e.z, "scale": e.scale, "shatter": e.chillT > 0.0})
			count += 1
			if count >= 64:
				break
	super._frost_arrive(pos, ctx)
	if not p["alive"] and seen.is_empty():
		return
	var FR := DmFxData.spell_group("frost")
	var shown := 0
	var shattered := 0
	for s: Dictionary in seen:
		shown += 1
		if s["shatter"]:
			shattered += 1
		if shown <= 14:
			_decal("rime", FR["frost"], s["x"], s["z"], 0.75 * float(s["scale"]), 1.4, 0.9, {"rot": randf() * 6.0, "growFrom": 0.4})
			if s["shatter"]:
				if shown <= 3:
					_bb("frost_shard_hit", s["x"], s["z"])
				_flash(s["x"], 1.0, s["z"], FR["pale"], 1.2, 0.18)
				_emit(s["x"], 1.0, s["z"], 10, FR["pale"], 0.2, 3.4, 2.0, 0.5, 0.13, {"gravity": 10.0})
				if shown <= 4:
					_m_splinters(s["x"], 1.0, s["z"], 4, FR["pale"])
	var origin2: Dictionary = ctx["origin"]
	var ln2: float = ctx["len"]
	_lf(float(origin2["x"]) + float(ctx["dx"]) * ln2 * 0.5, 1.0, float(origin2["z"]) + float(ctx["dz"]) * ln2 * 0.5, FR["frost"], 18.0, 0.3)
	if shattered > 0:
		_sfx("needleHit", pos[0], pos[2], 1.4)
	_shake(0.04)


# --- Soul Siphon / Bone Prison / Grave Hands / Bone Storm ---------------------------------------------------------------------------------

func _siphon(t: Dictionary, now: float) -> String:
	var r := super._siphon(t, now)
	if r != "ok":
		return r
	var SI := DmFxData.spell_group("siphon")
	var S: Dictionary = DmCombatData.const_table("SOUL_SIPHON")
	var ctx := _timed_ctx()
	_gesture("cast", 2.4, "soul_siphon", "soul_siphon")
	var dur := float(S["durationS"])
	var tgt := _cb("_siphon_vis_target", [ctx])
	var cas := _cb("_siphon_vis_caster", [ctx])
	var beams: Array = [_beam(cas, tgt, SI["deep"], 0.1, dur), _beam(cas, tgt, SI["jade"], 0.055, dur), _beam(cas, tgt, SI["pale"], 0.02, dur)]
	var first: Variant = tgt.call()
	var core: Variant = null
	if first != null:
		core = _bb("soul_orb", first.x, first.z, {"y": first.y, "follow": tgt, "duration": dur, "colors": [SI["jade"], SI["pale"], SI["deep"]]})
	var rim: Variant = _bb("soul_siphon_beam", _px(), _pz(), {"follow": cas, "duration": dur})
	_sfx("siphon", _px(), _pz())
	_loop("siphonLoop", dur * 1000.0, _px(), _pz(), _cb("_fol_p2"))
	ctx["vis"] = {"beams": beams, "core": core, "rim": rim, "drains": 0}
	return r


func _siphon_vis_target(ctx: Dictionary) -> Variant:
	var q: Variant = _siphon_target(ctx)
	return Vector3(q[0], q[1], q[2]) if q != null else null


func _siphon_vis_caster(ctx: Dictionary) -> Variant:
	return Vector3(_px(), 1.4, _pz()) if (not ctx["ended"] and p["alive"]) else null


func _siphon_tick(now_ms: float, ctx: Dictionary) -> Variant:
	var q: Variant = _siphon_target(ctx)
	var r: Variant = super._siphon_tick(now_ms, ctx)
	if q == null or not ctx.has("vis"):
		return r
	var SI := DmFxData.spell_group("siphon")
	var vis: Dictionary = ctx["vis"]
	for k in 6:
		var f := (float(k) + randf()) / 6.0
		_emit(q[0] + (_px() - q[0]) * f, q[1] + (1.4 - q[1]) * f, q[2] + (_pz() - q[2]) * f, 1, SI["pale"] if k % 2 == 1 else SI["jade"], 0.08, 0.2, 0.1, 0.3, 0.22)
	_emit(q[0], q[1], q[2], 5, SI["pale"], 0.25, 0.6, 0.3, 0.35, 0.16)
	_emit(_px(), 1.3, _pz(), 3, SI["jade"], 0.2, 0.3, 0.6, 0.4, 0.18)
	vis["drains"] = int(vis["drains"]) + 1
	if int(vis["drains"]) % 2 == 1:
		_m_skulls(q[0], q[2], SI["pale"], {"n": 1, "y": q[1] + 0.3, "size": 0.5, "rise": 0.9, "duration": 0.7})
	return r


func _siphon_end(ctx: Dictionary) -> void:
	super._siphon_end(ctx)
	if ctx.has("vis"):
		var vis: Dictionary = ctx["vis"]
		for b in vis["beams"]:
			_kill(b)
		_kill(vis["core"])
		_kill(vis["rim"])


func _prison(t: Dictionary) -> String:
	var r := super._prison(t)
	if r != "ok":
		return r
	var PR := DmFxData.spell_group("prison")
	var P: Dictionary = DmSimData.BONE_PRISON
	var xz := _ground_aim("bone_prison", t)
	var x: float = xz[0]
	var z: float = xz[1]
	var rr := float(DmSimData.ABILITIES["bone_prison"]["radius"])
	_gesture("cast", 2.3, "bone_prison", "bone_prison")
	if fx != null:
		stats["spikes"] += 1
		fx.spike_ring(x, z, rr, int(P["spikes"]), float(P["rootS"]) + 0.1)
	_decal("cracks", PR["dust"], x, z, rr * 1.1, float(P["rootS"]) + 0.4, 0.8, {"rot": randf() * 6.0, "growFrom": 0.6, "fadeOut": 0.4})
	_decal("boneRing", PR["amber"], x, z, rr + 0.3, float(P["rootS"]), 0.4, {"growFrom": 0.8, "fadeOut": 0.3})
	_smoke(x, 0.3, z, 6, PR["dust"], rr * 0.8, 0.9, 0.5, 0.9, 1.1)
	_emit(x, 0.4, z, 18, PR["bone"], rr, 1.8, 2.2, 0.5, 0.12, {"gravity": 9.0})
	for i in 6:
		var a := (float(i) / 6.0) * TAU
		_m_dirt(x + cos(a) * rr * 0.9, z + sin(a) * rr * 0.9, 0.35, 3)
	_m_splinters(x, 0.9, z, 10, PR["bone"], rr * 1.6)
	_bb("bone_prison_burst", x, z, {"scale": rr / 2.4})
	_sfx("prison", x, z)
	_shake(0.06)
	return r


func _hands(t: Dictionary, now: float) -> String:
	var r := super._hands(t, now)
	if r != "ok":
		return r
	var GH := DmFxData.spell_group("hands")
	var G: Dictionary = DmSimData.GRAVE_HANDS
	var ctx := _timed_ctx()
	var x: float = ctx["x"]
	var z: float = ctx["z"]
	var rr: float = ctx["r"]
	_gesture("dig", 2.2, "grave_hands", "grave_hands")
	var corpses := mini(int(G["maxCorpses"]), _corpses_in(x, z, rr))
	var hands := mini(int(G["maxHands"]), int(G["hands"]) + corpses * int(G["handsPerCorpse"]))
	var dur := float(G["durationS"])
	var vis: Dictionary = {"hands": null, "ground": null, "seep": null}
	if fx != null:
		stats["hands"] += 1
		vis["hands"] = fx.grave_hands(x, z, rr, hands, dur)
	vis["ground"] = _decal("disc", GH["earth"], x, z, rr, dur, 0.7, {"growFrom": 0.5, "fadeOut": 0.4})
	vis["seep"] = _decal("cracks", GH["seep"], x, z, rr * 0.95, dur, 0.35, {"rot": randf() * 6.0, "pulse": 2.0, "fadeOut": 0.4})
	_smoke(x, 0.2, z, 8, GH["earth"], rr * 0.7, 0.8, 0.6, 1.0, 1.2)
	for i in 5:
		var a := float(i) * 2.4
		_m_dirt(x + cos(a) * rr * 0.55, z + sin(a) * rr * 0.55, 0.4, 3)
	_bb("grave_hands_pulse", x, z, {"scale": rr / 3.5})
	_sfx("hands", x, z)
	_loop("handsLoop", 3000.0, x, z)
	_timed.back()["end"] = Callable(self, "_hands_end").bind(vis)
	return r


func _hands_end(vis: Dictionary) -> void:
	for k in ["hands", "ground", "seep"]:
		_kill(vis[k])


func _hands_tick(now_ms: float, ctx: Dictionary) -> Variant:
	var r: Variant = super._hands_tick(now_ms, ctx)
	var GH := DmFxData.spell_group("hands")
	var ic := _in_circle(ctx["x"], ctx["z"], ctx["r"])
	var ids: Array = ic["ids"]
	for k in mini(4, ids.size()):
		var e: DmSimEnemy = sim.enemies.get(int(ids[k]))
		if e != null:
			_emit(e.x, 0.4, e.z, 3, GH["bone"], 0.3, 1.2, 1.2, 0.35, 0.1, {"gravity": 8.0})
	var a := randf() * TAU
	var d := sqrt(randf()) * float(ctx["r"]) * 0.85
	_m_motes(float(ctx["x"]) + cos(a) * d, float(ctx["z"]) + sin(a) * d, GH["seep"], 0.25, 2, 0.9, 0.15)
	return r


func _storm(t: Dictionary, now: float) -> String:
	var r := super._storm(t, now)
	if r != "ok":
		return r
	var BS := DmFxData.spell_group("storm")
	var B: Dictionary = DmCombatData.const_table("BONE_STORM")
	var ctx := _timed_ctx()
	var tm: Dictionary = _timed.back()
	var life := (float(tm["until"]) - now) / 1000.0
	var rr: float = ctx["r"]
	var vis: Dictionary = {"ended": false}
	var follow := _cb("_storm_follow", [ctx, vis])
	_gesture("cast", 2.0, "bone_storm", "bone_storm")
	var c: Array = ctx["c"]
	if fx != null:
		stats["bone_orbit"] += 1
		vis["bones"] = fx.bone_orbit({"fallbackTex": "boneShard", "fallbackColor": BS["bone"], "count": int(B["shards"]), "radius": rr * 0.8, "y": 0.25, "size": 0.34, "duration": life, "speed": 7.0, "follow": follow, "funnel": true})
	vis["dust"] = _bb("bone_storm_dust", c[0], c[1], {"follow": follow, "duration": life, "colors": [BS["bone"], BS["ash"], BS["dust"]]})
	vis["ring"] = _decal("ring", BS["ash"], c[0], c[1], rr, life, 0.35, {"spin": 2.0, "fadeOut": 0.4, "follow": follow})
	_sfx("storm", c[0], c[1])
	_loop("boneStormLoop", life * 1000.0, c[0], c[1])
	tm["end"] = Callable(self, "_storm_end").bind(vis)
	return r


func _storm_follow(ctx: Dictionary, vis: Dictionary) -> Variant:
	if vis["ended"]:
		return null
	var c: Array = ctx["c"]
	return Vector3(c[0], 0.0, c[1])


func _storm_end(vis: Dictionary) -> void:
	vis["ended"] = true
	for k in ["bones", "dust", "ring"]:
		if vis.has(k):
			_kill(vis[k])


func _storm_tick(t_now: float, ctx: Dictionary) -> Variant:
	var r: Variant = super._storm_tick(t_now, ctx)
	var BS := DmFxData.spell_group("storm")
	var c: Array = ctx["c"]
	var rr: float = ctx["r"]
	var ic := _in_circle(c[0], c[1], rr)
	var has_ids: bool = not ic["ids"].is_empty()
	if has_ids:
		_sfx("boneHit", c[0], c[1])
	_smoke(c[0], 0.4, c[1], 3, BS["ash"], rr * 0.4, 0.9, 1.4, 0.9, 1.1, {"shrink": -0.4})
	_m_splinters(c[0], 0.8, c[1], 6 if has_ids else 3, BS["bone"], rr * 1.2)
	_m_dirt(c[0], c[1], rr * 0.5, 3, 3.0)
	return r


# --- Bone Mantle ---------------------------------------------------------------------------------------------------------------------------

func _mantle() -> String:
	var r := super._mantle()
	if r == "ok":
		var MN := DmFxData.spell_group("mantle")
		_gesture("cast", 1.8, "bone_mantle", "bone_mantle")
		_emit(_px(), 1.3, _pz(), 18, MN["bone"], 0.5, 1.4, 1.0, 0.5, 0.2)
		_m_dirt(_px(), _pz(), 0.8, 5)
	return r


func on_mantle(ev: Dictionary, mine: bool) -> void:
	on_mantle_follow(ev, mine, Callable())


## `follow`: () -> Vector3 | null, where the caster is (a remote caster's reported position); default: our own body, or the event's point.
func on_mantle_follow(ev: Dictionary, mine: bool, follow: Callable) -> void:
	var MN := DmFxData.spell_group("mantle")
	var M: Dictionary = DmSimData.BONE_MANTLE
	var fol := follow
	if not fol.is_valid():
		fol = _cb("_fol_p") if mine else _cb("_vis_const", [[float(ev["x"]), 0.0, float(ev["z"])]])
	for tt: Array in ev["tethers"]:
		_beam(Vector3(tt[0], 0.4, tt[1]), _cb("_mantle_beam_end", [fol]), MN["bone"], 0.05, 0.4)
		_emit(tt[0], 0.4, tt[1], 10, MN["bone"], 0.4, 1.2, 1.6, 0.5, 0.16, {"gravity": 4.0})
		_smoke(tt[0], 0.3, tt[1], 2, MN["dust"], 0.4, 0.5, 0.4, 0.8, 0.9)
		_m_splinters(tt[0], 0.5, tt[1], 3, MN["bone"], 3.6, "player" if mine else "thrall")
	var handle: Variant = null
	if fx != null:
		stats["bone_orbit"] += 1
		handle = fx.bone_orbit({"fallbackTex": "boneShard", "fallbackColor": MN["bone"], "count": mini(15, 6 + int(ev["corpses"]) * 2), "radius": float(M["orbitRadius"]),
			"y": 0.7, "size": 0.5, "duration": float(M["durationS"]), "speed": 3.4, "follow": fol})
	var ring: Variant = _decal("boneRing", MN["amber"], float(ev["x"]), float(ev["z"]), float(M["orbitRadius"]) + 0.5, float(M["durationS"]), 0.45,
		{"growFrom": 0.4, "spin": 0.5, "fadeOut": 0.4, "follow": fol})
	_lf(float(ev["x"]), 1.4, float(ev["z"]), MN["gold"], 26.0, 0.4)
	_sfx("mantle", float(ev["x"]), float(ev["z"]))
	super.on_mantle(ev, mine)
	if not mine:
		return
	if not p["alive"]:
		_kill(handle)
		_kill(ring)
		return
	_kill(_mantle_fx)
	_mantle_fx = [handle, ring]
	_shake(0.04)


func _mantle_beam_end(fol: Callable) -> Variant:
	var f: Variant = fol.call()
	return Vector3(f.x, 1.1, f.z) if f != null else null


func _kill_mantle_fx() -> void:
	if _mantle_fx is Array:
		for h in _mantle_fx:
			_kill(h)
	_mantle_fx = null


func _update_mantle(now: float) -> void:
	if now < _mantle_until and not p["alive"]:
		_kill_mantle_fx()
	var n0 := popups.size()
	var next_before := _next_shard_at
	super._update_mantle(now)
	if _next_shard_at == next_before:
		return
	var MN := DmFxData.spell_group("mantle")
	var any := false
	for pu: Dictionary in _new_popups(n0):
		any = true
		_emit(pu["x"], 0.9, pu["z"], 4, MN["bone"], 0.2, 2.2, 1.0, 0.3, 0.12, {"gravity": 8.0})
	if any:
		_sfx("boneHit", _px(), _pz())


# --- Requiem wisps / legendary set mechanics -------------------------------------------------------------------------------------------------

func _wisp_fx(w: Dictionary, secs: float) -> void:
	_vid += 1
	w["vid"] = _vid
	w["fx"] = _orbit({"tex": "wisp", "color": _col("souls", "jade"), "count": 1, "radius": float(w["radius"]), "y": 1.5, "size": 0.6, "duration": secs,
		"speed": float(w["speed"]), "follow": _cb("_fol_p")})


func on_corpse_consumed() -> void:
	var secs := float(mods.get("corpseWisp", 0.0))
	var before: Dictionary = {}
	for w: Dictionary in _wisps:
		before[w.get("vid", -1)] = float(w["until"])
	var n0 := _wisps.size()
	var at_cap := n0 >= int(DmSimData.LEGEND["wispCap"])
	super.on_corpse_consumed()
	if not (secs > 0.0) or not p["alive"]:
		return
	if at_cap:
		for w: Dictionary in _wisps:
			if float(w["until"]) != float(before.get(w.get("vid", -1), -1.0)):
				_kill(w.get("fx"))
				_wisp_fx(w, secs)
				break
	elif _wisps.size() > n0:
		_wisp_fx(_wisps.back(), secs)
		_emit(_px(), 1.2, _pz(), 6, _col("souls", "pale"), 0.3, 1.2, 0.8, 0.45, 0.16)


func _tick_wisps(now: float) -> void:
	var before: Array = _wisps.duplicate()
	super._tick_wisps(now)
	if before.size() == _wisps.size():
		return
	var live: Dictionary = {}
	for w: Dictionary in _wisps:
		live[w.get("vid", -1)] = true
	for w: Dictionary in before:
		if not live.has(w.get("vid", -1)):
			_kill(w.get("fx"))


func _wraith_nova() -> void:
	var k := float(mods.get("wraithNova", 0.0))
	var src: Array = []
	if k > 0.0 and p["alive"]:
		for w: Dictionary in _wisps:
			src.append(_wisp_at(w, _now))
		for th: DmSimThrall in sim.thralls.values():
			if th.owner == self_id and th.kind == "wraith" and th.state != "dead" and th.state != "rising":
				src.append([th.x, th.z])
	super._wraith_nova()
	if src.is_empty():
		return
	var jade := _col("souls", "jade")
	var pale := _col("souls", "pale")
	for s: Array in src.slice(0, int(DmSimData.LEGEND["novaMax"])):
		_decal("ring", jade, s[0], s[1], float(DmSimData.LEGEND["novaR"]), 0.45, 0.8, {"growFrom": 0.15})
		_emit(s[0], 0.9, s[1], 8, pale, 0.4, 3.2, 0.6, 0.4, 0.16)
	_sfx("soulRelease", _px(), _pz(), 0.8)


func litany_shatter(barrier_size: float) -> void:
	var dmg := DmLegend.shatter_damage(barrier_size, float(mods.get("litanyShatter", 0.0)))
	var alive: bool = p["alive"]
	super.litany_shatter(barrier_size)
	if dmg <= 0.0 or not alive:
		return
	var S := DmFxData.spell_group("spear")
	_decal("ring", S["bone"], _px(), _pz(), float(DmSimData.LEGEND["shatterR"]), 0.5, 1.0, {"growFrom": 0.1})
	_m_splinters(_px(), 1.0, _pz(), 12, S["bone"], 6.0)
	_emit(_px(), 0.8, _pz(), 14, S["bone"], 0.5, 5.0, 1.2, 0.5, 0.16, {"gravity": 6.0})
	_sfx("boneHit", _px(), _pz(), 1.1)
	_shake(0.07)


func reflect_ward(raw: float, bone_ward: float, x: float, z: float) -> void:
	var dmg := DmLegend.ward_reflect_damage(raw, bone_ward, float(mods.get("wardReflect", 0.0)))
	var best: DmSimEnemy = null
	if dmg >= 1.0:
		var best_d := 0.6
		for e: DmSimEnemy in sim.enemies.values():
			if e.state == "dead" or e.state == "burrow":
				continue
			var d := _h(e.x - x, e.z - z)
			if d <= best_d + e.radius * 0.5 and (best == null or d < best_d):
				best = e
				best_d = d
	var bx := 0.0
	var bz := 0.0
	if best != null:
		bx = best.x
		bz = best.z
	super.reflect_ward(raw, bone_ward, x, z)
	if best != null:
		_emit(bx, 1.0, bz, 5, _col("spear", "bone"), 0.2, 2.4, 0.8, 0.3, 0.12)


# --- Spell variety ---------------------------------------------------------------------------------------------------------------------------

func _fan(t: Dictionary) -> String:
	_pv = {"kind": "needle", "color": _col("needle", "trail")}
	var r := super._fan(t)
	_pv = {}
	if r == "ok":
		var from := _tip()
		_gesture("cast", 3.2, "bone_fan", "bone_fan")
		_flash(from[0], from[1], from[2], _col("needle", "trail"), 0.8, 0.14)
		_sfx("boneFan", _px(), _pz())
	return r


func _fan_arrive(pos: Array, ctx: Dictionary) -> void:
	var pick: Variant = ctx["pick"]
	var N := DmFxData.spell_group("needle")
	if not p["alive"] or pick == null:
		_emit(pos[0], pos[1], pos[2], 4, N["dust"], 0.1, 1.5, 0.6, 0.3, 0.1, {"gravity": 6.0})
		super._fan_arrive(pos, ctx)
		return
	var lands := false
	if pick.get("boss", false):
		lands = _boss().active
	else:
		var e: DmSimEnemy = sim.enemies.get(int(pick["id"]))
		lands = e != null and e.state != "dead"
	super._fan_arrive(pos, ctx)
	if not lands:
		return
	_sfx("needleHit", pos[0], pos[2], 0.8)
	_flash(pos[0], pos[1], pos[2], N["impact"], 0.8, 0.16)
	_emit(pos[0], pos[1], pos[2], 6, N["dust"], 0.1, 3.0, 1.1, 0.35, 0.12, {"gravity": 7.0})


func _lance(t: Dictionary) -> String:
	_pv = {"kind": "orb", "color": _col("lance", "rot")}
	var r := super._lance(t)
	_pv = {}
	if r != "ok":
		return r
	var LN := DmFxData.spell_group("lance")
	var def: Dictionary = DmSimData.ABILITIES["rot_lance"]
	var ctx := _last_ctx()
	var origin: Dictionary = ctx["origin"]
	var end := [float(origin["x"]) + float(ctx["dx"]) * float(def["range"]), 1.0, float(origin["z"]) + float(ctx["dz"]) * float(def["range"])]
	_gesture("cast", 2.8, "rot_lance", "rot_lance")
	var tip := _tip()
	_flash(tip[0], tip[1], tip[2], LN["rot"], 0.7, 0.14)
	_sfx("rotLance", _px(), _pz(), 0.8)
	_beam(_v3(tip), _cb("_vis_const", [end]), LN["deep"], 0.03, 0.18)
	return r


func _lance_arrive(pos: Array, ctx: Dictionary) -> void:
	var n0 := popups.size()
	super._lance_arrive(pos, ctx)
	var LN := DmFxData.spell_group("lance")
	var hits := popups.slice(n0)
	for pu: Dictionary in hits:
		_smoke(pu["x"], 0.9, pu["z"], 2, LN["spore"], 0.3, 0.5, 0.5, 0.6, 0.8, {"shrink": -0.3})
		_emit(pu["x"], 1.0, pu["z"], 8, LN["rot"], 0.2, 2.0, 0.8, 0.45, 0.14, {"gravity": 3.0})
	if not hits.is_empty():
		_sfx("needleHit", hits[0]["x"], hits[0]["z"], 0.7)


# --- Grave Offering ---------------------------------------------------------------------------------------------------------------------

func _offering(t: Dictionary) -> String:
	var r := super._offering(t)
	if r == "ok":
		_gesture("cast", 2.4, "grave_offering", "grave_offering")
	return r


func on_offering(ev: Dictionary, mine: bool) -> void:
	on_offering_follow(ev, mine, Callable())


func on_offering_follow(ev: Dictionary, mine: bool, _follow: Callable) -> void:
	if not ev["ok"]:
		super.on_offering(ev, mine)
		return
	var X := DmFxData.spell_group("exhume")
	_decal("ring", X["spirit"], float(ev["x"]), float(ev["z"]), 1.1, 0.5, 0.9, {"growFrom": 0.3})
	_emit(float(ev["x"]), 0.5, float(ev["z"]), 14, X["spirit"], 0.3, 1.0, 2.2, 0.6, 0.18)
	_bb("grave_offering_ripple", float(ev["x"]), float(ev["z"]))
	_pv = {"kind": "sprite", "tex": "wisp", "size": 0.9, "color": X["beam"]}
	super.on_offering(ev, mine)
	_pv = {}
	_sfx("graveOffering", float(ev["x"]), float(ev["z"]))


func _offering_arrive(pos: Array, ctx: Dictionary) -> void:
	var alive: bool = p["alive"]
	super._offering_arrive(pos, ctx)
	_flash(pos[0], pos[1], pos[2], _col("exhume", "spirit"), 1.2, 0.2)
	_bb("grave_offering_orb", pos[0], pos[2])
	if ctx["mine"] and alive:
		_sfx("graveOffering", pos[0], pos[2])


# --- Ivory Cleave / Veil Step / Rally / Seed ----------------------------------------------------------------------------------------------

func _cleave(t: Dictionary) -> String:
	var n0 := popups.size()
	var r := super._cleave(t)
	if r != "ok":
		return r
	var S := DmFxData.spell_group("spear")
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var l := _h(dx, dz)
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	_gesture("cast", 3.0, "ivory_cleave", "ivory_cleave")
	var hits := _new_popups(n0)
	var k := 0
	for pu: Dictionary in hits:
		k += 1
		_emit(pu["x"], 0.9, pu["z"], 5, S["bone"], 0.2, 2.4, 1.1, 0.35, 0.12, {"gravity": 8.0})
		if k <= 2:
			_bb("ivory_cleave_hit", pu["x"], pu["z"])
	var rot := atan2(dx, dz)
	_decal("crescent", S["bone"], _px() + dx * 1.5, _pz() + dz * 1.5, 2.2, 0.45, 1.0, {"rot": rot, "growFrom": 0.6, "fadeOut": 0.3})
	_decal("crescent", S["crack"], _px() + dx * 1.6, _pz() + dz * 1.6, 2.4, 0.35, 0.6, {"rot": rot, "growFrom": 0.7})
	_lf(_px() + dx * 1.5, 1.0, _pz() + dz * 1.5, S["crack"], 14.0, 0.2)
	_sfx("ivoryCleave", _px(), _pz(), 1.3)
	if not hits.is_empty():
		_sfx("boneHit", _px() + dx * 2.0, _pz() + dz * 2.0)
	_shake(0.05)
	return r


func _veil(t: Dictionary) -> String:
	var fx0 := _px()
	var fz0 := _pz()
	var r := super._veil(t)
	if r != "ok":
		return r
	var VL := DmFxData.spell_group("veil")
	var d: Dictionary = _dashing
	var tx: float = d["tx"]
	var tz: float = d["tz"]
	_gesture("cast", 3.4, "veil_step")
	var dist := _h(tx - fx0, tz - fz0)
	var rot := atan2(tx - fx0, tz - fz0)
	_decal("veilStreak", VL["jade"], (fx0 + tx) / 2.0, (fz0 + tz) / 2.0, dist / 2.0 + 0.4, 0.6, 0.85, {"sx": 0.35, "rot": rot, "fadeOut": 0.45})
	_smoke(fx0, 0.9, fz0, 4, VL["deep"], 0.4, 0.5, 0.5, 0.6, 1.0, {"shrink": -0.3})
	_emit(fx0, 1.0, fz0, 12, VL["pale"], 0.3, 1.6, 0.8, 0.4, 0.14)
	_bb("veil_step_trail", fx0, fz0, {"duration": 0.6, "rot": rot})
	_decal("ring", VL["jade"], tx, tz, 1.0, 0.45, 0.9, {"growFrom": 0.2})
	_lf(tx, 1.2, tz, VL["jade"], 14.0, 0.25)
	_sfx("veilStep", fx0, fz0, 1.3)
	return r


func _rally(t: Dictionary) -> String:
	var r := super._rally(t)
	if r == "ok":
		_gesture("cast", 2.0, "rally_dead", "rally_dead")
		_decal("rallySigil", _col("rend", "jade"), _px(), _pz(), 2.4, 0.8, 0.9, {"growFrom": 0.4, "spin": 1.0})
	return r


func on_rally(ev: Dictionary, follow: Callable = Callable()) -> void:
	var RD := DmFxData.spell_group("rend")
	var dur := float(DmSimData.RALLY["durationS"]) + float(DmSimData.RALLY["gravecallerBonusS"])
	for id in ev["ids"]:
		var at := _cb("_rally_at", [int(id)])
		var fv: Variant = follow.call() if follow.is_valid() else null
		var fx_ := Vector3(ev["x"], 0.0, ev["z"]) if fv == null else (fv as Vector3)
		_beam(Vector3(fx_.x, 1.2, fx_.z), _cb("_rally_beam_end", [int(id)]), RD["jade"], 0.04, 0.45)
		_decal("rallySigil", RD["jade"], 0.0, 0.0, 0.7, dur, 0.7, {"spin": 1.4, "fadeOut": 0.4, "follow": at})
		var a0: Variant = at.call()
		if a0 != null:
			_bb("rally_thrall_rim", a0.x, a0.z, {"follow": at, "duration": dur})
	_lf(float(ev["x"]), 1.2, float(ev["z"]), RD["jade"], 18.0, 0.3)
	_bb("rally_area", float(ev["x"]), float(ev["z"]))
	_sfx("rallyDead", float(ev["x"]), float(ev["z"]))


func _rally_at(id: int) -> Variant:
	var th: DmSimThrall = sim.thralls.get(id)
	if th != null and th.state != "dead" and th.rallyT > 0.0:
		return Vector3(th.x, 0.0, th.z)
	return null


func _rally_beam_end(id: int) -> Variant:
	var a: Variant = _rally_at(id)
	return Vector3(a.x, 1.0, a.z) if a != null else null


func _seed(t: Dictionary) -> String:
	var c := pick_corpse(t, 2.5, float(DmSimData.ABILITIES["carrion_seed"]["range"]))
	var cx_ := c.x if c != null else 0.0
	var cz_ := c.z if c != null else 0.0
	var r := super._seed(t)
	if r == "ok":
		_gesture("cast", 2.4, "carrion_seed", "carrion_seed")
		_sfx("carrionSeed", cx_, cz_, 1.2)
	return r


var _seeds: Dictionary = {}
var _seed_cores: Dictionary = {}


func on_seeded(ev: Dictionary) -> void:
	var BL := DmFxData.spell_group("bloom")
	var cid := int(ev["corpseId"])
	_kill(_seeds.get(cid))
	_kill(_seed_cores.get(cid))
	var life := float(DmSimData.CARRION_SEED["lifeS"]) + 1.0
	var core: Variant = _bb("carrion_seed_armed", float(ev["x"]), float(ev["z"]), {"duration": life})
	if core != null:
		_seed_cores[cid] = core
	_emit(float(ev["x"]), 0.4, float(ev["z"]), 10, BL["petal"], 0.3, 0.8, 1.2, 0.5, 0.14)
	_seeds[cid] = _decal("seedBud", BL["petal"], float(ev["x"]), float(ev["z"]), 0.75, life, 0.95, {"growFrom": 0.2, "pulse": 3.0, "fadeIn": float(ev["armMs"]) / 1000.0})


## A seed withered, burst or its corpse was used by another rite.
func on_seed_gone(corpse_id: int) -> void:
	_kill(_seeds.get(corpse_id))
	_seeds.erase(corpse_id)
	_kill(_seed_cores.get(corpse_id))
	_seed_cores.erase(corpse_id)


func on_seed_burst(ev: Dictionary) -> void:
	var BL := DmFxData.spell_group("bloom")
	var x := float(ev["x"])
	var z := float(ev["z"])
	var r := float(ev["r"])
	_decal("ring", BL["petal"], x, z, r, 0.5, 1.0, {"growFrom": 0.2})
	_decal("disc", BL["rot"], x, z, r * 0.9, 1.5, 0.55, {"fadeOut": 0.8})
	_emit(x, 0.5, z, 30, BL["petal"], 0.4, r * 2.4, 1.6, 0.6, 0.22, {"drag": 1.4})
	_smoke(x, 0.6, z, 6, BL["spore"], r * 0.4, 1.0, 0.6, 1.0, 1.4, {"shrink": -0.4})
	_lf(x, 1.0, z, BL["petal"], 22.0, 0.3)
	_bb("carrion_seed_burst", x, z, {"scale": r / 3.0})
	_bb("toxic_puddle", x, z, {"scale": r / 3.0, "duration": 1.5})
	_sfx("seedBurst", x, z)
	_shake(0.06)


# --- Hollow Knight -----------------------------------------------------------------------------------------------------------------------

func _hollow_cut(t: Dictionary) -> String:
	var n0 := popups.size()
	var r := super._hollow_cut(t)
	if r != "ok":
		return r
	var KN := DmFxData.spell_group("knight")
	var HC: Dictionary = DmCombatData.const_table("HOLLOW_CUT")
	var dx: float = t["x"] - _px()
	var dz: float = t["z"] - _pz()
	var l := _h(dx, dz)
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	_gesture("attack", 3.0, "hollow_cut")
	var hits := _new_popups(n0)
	for pu: Dictionary in hits:
		_emit(pu["x"], 1.0, pu["z"], 4, KN["pale"], 0.2, 2.2, 1.0, 0.3, 0.1, {"gravity": 8.0})
	_decal("crescent", KN["steel"], _px() + dx * 1.2, _pz() + dz * 1.2, float(HC["reach"]), 0.32, 0.95, {"rot": atan2(dx, dz), "growFrom": 0.7, "fadeOut": 0.22})
	_lf(_px() + dx * 1.2, 1.0, _pz() + dz * 1.2, KN["pale"], 10.0, 0.16)
	_sfx("hollowCut", _px(), _pz(), 1.45)
	if not hits.is_empty():
		_sfx("boneHit", _px() + dx * 1.6, _pz() + dz * 1.6)
	return r


func _shield_bash(t: Dictionary) -> String:
	var r := super._shield_bash(t)
	if r != "ok":
		return r
	var KN := DmFxData.spell_group("knight")
	var d: Dictionary = _dashing
	var fx_ := float(d["fx"])
	var fz_ := float(d["fz"])
	_gesture("attack", 3.2, "shield_bash")
	_decal("glow", KN["steel"], (fx_ + float(d["tx"])) / 2.0, (fz_ + float(d["tz"])) / 2.0, 1.3, 0.3, 0.7, {"fadeOut": 0.2})
	_smoke(fx_, 0.4, fz_, 4, KN["dust"], 0.4, 0.6, 0.3, 0.5, 0.8)
	_sfx("shieldBash", fx_, fz_, 1.2)
	_shake(0.04)
	return r


func _grave_slam(t: Dictionary) -> String:
	var fx0 := _px()
	var fz0 := _pz()
	var r := super._grave_slam(t)
	if r == "ok":
		var KN := DmFxData.spell_group("knight")
		_gesture("attack", 2.6, "grave_slam")
		_smoke(fx0, 0.4, fz0, 5, KN["dust"], 0.5, 0.8, 0.6, 0.5, 0.9)
		_sfx("graveSlam", fx0, fz0, 0.9)
	return r


func _slam_landing(at: Array, dmg: float) -> void:
	super._slam_landing(at, dmg)
	var KN := DmFxData.spell_group("knight")
	var rr := float(DmCombatData.const_table("GRAVE_SLAM")["slamR"])
	_decal("ring", KN["steel"], at[0], at[1], rr, 0.5, 1.0, {"growFrom": 0.2, "fadeOut": 0.3})
	_decal("glow", KN["oath"], at[0], at[1], rr * 0.7, 0.4, 0.55, {"fadeOut": 0.3})
	_emit(at[0], 0.4, at[1], 20, KN["dust"], 0.6, 3.4, 1.6, 0.5, 0.18, {"gravity": 10.0})
	_lf(at[0], 1.0, at[1], KN["pale"], 18.0, 0.22)
	_bb("rend_impact", at[0], at[1])
	_sfx("graveSlamLand", at[0], at[1], 0.8)
	_shake(0.12)


func _bulwark(now: float) -> String:
	var r := super._bulwark(now)
	if r == "ok":
		var KN := DmFxData.spell_group("knight")
		var hold := float(DmCombatData.const_table("BULWARK")["holdS"])
		_gesture("cast", 1.6, "bulwark")
		_decal("ring", KN["steel"], _px(), _pz(), 1.15, hold, 0.8, {"growFrom": 0.4, "follow": _cb("_fol_p")})
		_emit(_px(), 1.1, _pz(), 12, KN["pale"], 0.4, 1.2, 0.8, 0.4, 0.16)
		_sfx("bulwarkRaise", _px(), _pz(), 0.8)
	return r


func _corpse_vigil(t: Dictionary) -> String:
	var r := super._corpse_vigil(t)
	if r == "ok":
		_gesture("cast", 1.8, "corpse_vigil")
	return r


func _grave_brand(t: Dictionary) -> String:
	var r := super._grave_brand(t)
	if r == "ok":
		_gesture("cast", 2.2, "grave_brand")
	return r


func _oath_unbroken(now: float) -> String:
	var r := super._oath_unbroken(now)
	if r == "ok":
		var KN := DmFxData.spell_group("knight")
		var dur := float(DmCombatData.const_table("OATH_UNBROKEN")["durationS"])
		var fol := _cb("_fol_p")
		_gesture("cast", 2.0, "oath_unbroken")
		_decal("ring", KN["oath"], _px(), _pz(), 1.6, dur, 0.75, {"growFrom": 0.3, "follow": fol, "spin": 0.6})
		_decal("glow", KN["oath"], _px(), _pz(), 2.4, dur, 0.3, {"growFrom": 0.5, "follow": fol})
		_emit(_px(), 1.3, _pz(), 24, KN["oath"], 0.5, 2.0, 1.4, 0.7, 0.2)
		_lf(_px(), 1.4, _pz(), KN["oath"], 22.0, 0.35)
		_sfx("oathUnbroken", _px(), _pz(), 0.9)
		_shake(0.08)
	return r


## The host spent a body on Corpse Vigil (only routed with route_vigil, as the web never calls it).
func on_vigil(ev: Dictionary, mine: bool) -> void:
	if ev.get("ok", true) != false:
		var KN := DmFxData.spell_group("knight")
		_decal("ring", KN["pale"], float(ev["x"]), float(ev["z"]), 1.2, 0.6, 0.9, {"growFrom": 0.3})
		_emit(float(ev["x"]), 0.6, float(ev["z"]), 14, KN["pale"], 0.3, 1.0, 2.0, 0.7, 0.16)
		_sfx("corpseVigil", float(ev["x"]), float(ev["z"]), 0.9)
		if mine and p["alive"]:
			_decal("glow", KN["pale"], _px(), _pz(), 1.4, float(DmCombatData.const_table("CORPSE_VIGIL")["durationS"]), 0.4, {"growFrom": 0.5, "follow": _cb("_fol_p")})
	super.on_vigil(ev, mine)


## The host armed or sprung a Grave Brand (the web scene does not route it either).
func on_brand(ev: Dictionary) -> void:
	var KN := DmFxData.spell_group("knight")
	var GB: Dictionary = DmSimData.GRAVE_BRAND
	var x := float(ev["x"])
	var z := float(ev["z"])
	if ev.get("sprung", false):
		_decal("ring", KN["oath"], x, z, float(GB["triggerR"]), 0.45, 1.0, {"growFrom": 0.3})
		_emit(x, 0.5, z, 16, KN["oath"], 0.4, 2.4, 1.0, 0.5, 0.16, {"gravity": 8.0})
		_sfx("graveBrand", x, z, 1.1)
		return
	_decal("graveOutline", KN["oath"], x, z, float(GB["triggerR"]), float(GB["lifeS"]), 0.5, {"growFrom": 0.6, "fadeOut": 0.5})
	_emit(x, 0.4, z, 10, KN["oath"], 0.3, 1.0, 0.6, 0.5, 0.14)
	_sfx("graveBrand", x, z, 0.7)


# --- Signatures, Litany, Corpse Explosion -------------------------------------------------------------------------------------------------

func _signature(id: String, t: Dictionary) -> String:
	var r := super._signature(id, t)
	if r != "ok":
		return r
	var sig: String = DmCombatData.const_table("SIGNATURE_KIND")[id]
	var color: Color
	match sig:
		"wall":
			color = _col("wall", "amber")
		"rend":
			color = _col("rend", "jade")
		"dirge":
			color = _col("dirge", "frost")
		_:
			color = _col("bloom", "petal")
	_gesture("cast", 1.8, id, id)
	_emit(_px(), 1.4, _pz(), 24, color, 0.4, 1.6, 1.2, 0.6, 0.24)
	_lf(_px(), 1.8, _pz(), color, 24.0, 0.4)
	var sid := "sigWall" if sig == "wall" else ("sigRend" if sig == "rend" else ("sigDirge" if sig == "dirge" else "sigBloom"))
	_sfx(sid, _px(), _pz())
	if sig == "dirge":
		_loop("dirgeLoop", 4000.0, _px(), _pz())
	elif sig == "bloom":
		_loop("bloomPulse", 6000.0, _px(), _pz())
	return r


func _litany(mult: float = 1.0) -> String:
	var r := super._litany(mult)
	if r == "ok":
		_gesture("cast", 1.6, "black_litany", "black_litany")
	return r


func _detonate(t: Dictionary) -> String:
	var c := pick_corpse(t, float(DmSimData.ABILITIES["exhume"]["radius"]), float(DmSimData.ABILITIES["corpse_explosion"]["range"]))
	var cx_ := c.x if c != null else 0.0
	var cz_ := c.z if c != null else 0.0
	var r := super._detonate(t)
	if r != "ok":
		return r
	var D := DmFxData.spell_group("detonate")
	_gesture("cast", 3.0, "corpse_explosion", "corpse_explosion")
	var tip := _tip()
	_flash(tip[0], tip[1], tip[2], D["hot"], 0.7, 0.14)
	_beam(_v3(tip), _cb("_vis_const", [[cx_, 0.4, cz_]]), D["ember"], 0.05, 0.2)
	_decal("glow", D["ember"], cx_, cz_, 1.1, 0.25, 0.9, {"growFrom": 0.4})
	return r


## Everyone sees the blast when the host reports it (ember burst + bone shrapnel).
func on_detonated(ev: Dictionary, mine: bool) -> void:
	super.on_detonated(ev, mine)
	if not ev["ok"]:
		return
	var D := DmFxData.spell_group("detonate")
	var x := float(ev["x"])
	var z := float(ev["z"])
	var r := float(ev["r"])
	_sfx("corpseExplode", x, z)
	_flash(x, 0.7, z, D["hot"], r * 0.8, 0.2)
	_decal("ring", D["ember"], x, z, r, 0.45, 1.0, {"growFrom": 0.15})
	_decal("glow", D["crimson"], x, z, r * 0.9, 0.7, 0.85, {"growFrom": 0.4})
	_decal("cracks", D["crimson"], x, z, r * 0.75, 1.6, 0.85, {"rot": randf() * 6.0, "growFrom": 0.5})
	_emit(x, 0.6, z, 24, D["ember"], 0.3, r * 2.8, 1.6, 0.5, 0.34, {"drag": 1.5})
	_emit(x, 0.7, z, 16, D["bone"], 0.25, r * 2.3, 4.5, 0.9, 0.14, {"gravity": 14.0})
	_emit(x, 0.4, z, 8, D["crimson"], 0.3, 2.0, 2.4, 0.8, 0.26, {"gravity": 6.0})
	_smoke(x, 0.4, z, 4, D["smoke"], r * 0.35, 1.4, 0.8, 0.75, 1.0, {"shrink": -0.3})
	var who := "player" if mine else "thrall"
	_m_dirt(x, z, r * 0.4, 9, 3.2, who)
	_m_splinters(x, 0.8, z, 8, D["bone"], r * 1.8, who)
	_m_skulls(x, z, D["hot"], {"n": 1, "y": 0.8, "size": 0.7, "rise": 1.2, "origin": who})
	_lf(x, 1.2, z, D["ember"], 55.0 if ev.get("elite", false) else 38.0, 0.45)
	_bb("corpse_explosion", x, z, {"scale": r / 3.0})
	if ev.get("corpseKind") == "resonant":
		_decal("ring", _col("enemy", "toll"), x, z, r * 1.05, 0.6, 0.8, {"growFrom": 0.2, "delay": 0.06})
		_sfx("tollSmall", x, z)
	if ev.get("corpseKind") == "toxic":
		_emit(x, 0.4, z, 24, _col("miasma", "rot"), 0.5, 3.0, 1.4, 0.8, 0.3)
	if ev.get("elite", false):
		_decal("ring", D["hot"], x, z, r * 1.2, 0.5, 0.9, {"growFrom": 0.1, "delay": 0.08})
	_shake((0.055 if mine else 0.025) + (0.035 if ev.get("elite", false) else 0.0))


## VFX + self-effects when the host reports the litany outcome (everyone sees them; the barrier and heal are the caster's).
func on_litany(ev: Dictionary, mine: bool) -> void:
	var L := DmFxData.spell_group("litany")
	var X := DmFxData.spell_group("exhume")
	var x := float(ev["x"])
	var z := float(ev["z"])
	var r := float(ev["r"])
	var tip: Array = _tip() if mine else [x, 1.6, z]
	var tethers: Array = ev["tethers"]
	for k in mini(10, tethers.size()):
		var tt: Array = tethers[k]
		_beam(Vector3(tt[0], 0.6, tt[1]), _cb("_vis_const", [tip]), L["core"], 0.045, 0.5)
		_emit(tt[0], 0.5, tt[1], 8, L["core"], 0.3, 0.6, 1.5, 0.6, 0.3)
	_emit(x, 0.6, z, 32, L["core"], r, 7.0, 0.2, 0.25, 0.22, {"inward": true, "drag": 0.0})
	_smoke(x, 0.5, z, 4, L["void"], 1.0, 0.4, 0.2, 0.65, 1.3, {"shrink": -0.3})
	_decal("sigil", L["core"], x, z, r, 0.7, 0.5, {"growFrom": 0.1, "spin": 0.35})
	_bb("litany_pulse", x, z, {"scale": r / 7.0})
	_decal("ring", L["hot"], x, z, r * 1.15, 0.55, 1.0, {"growFrom": 0.05, "delay": 0.18})
	_emit(x, 0.5, z, 48, L["core"], 1.0, 9.0, 1.8, 0.55, 0.23)
	_emit(x, 0.8, z, 16, L["hot"], 0.6, 5.0, 3.0, 0.45, 0.2)
	_flash(x, 1.5, z, L["core"], minf(2.0, r * 0.24), 0.3)
	var who := "player" if mine else "thrall"
	if fx != null:
		stats["motif"] += 1
		fx.motifs.skull_ring(x, z, minf(r * 0.62, 5.0), L["hot"], {"n": mini(8, 4 + int(ev["corpses"]) + int(ev["thralls"])), "origin": who})
	for k in mini(5, tethers.size()):
		_m_motes(tethers[k][0], tethers[k][1], L["hot"], 0.3, 3, 1.8, 0.25, who)
	_lf(x, 2.0, z, L["core"], 32.0, 0.4)
	if ev.get("spared", 0):
		for th: DmSimThrall in sim.thralls.values():
			if (mine and th.owner != self_id) or _h(th.x - x, th.z - z) > r:
				continue
			_decal("ring", X["spirit"], th.x, th.z, 1.2, 0.9, 0.9, {"growFrom": 0.3})
			_m_motes(th.x, th.z, X["beam"], 0.35, 4, 2.2, 0.25, "thrall")
	_sfx("litany", x, z, 1.0 + minf(0.6, float(int(ev["corpses"]) + int(ev["thralls"])) * 0.05))
	_shake(0.08 + minf(0.08, float(int(ev["corpses"]) + int(ev["thralls"])) * 0.008))
	super.on_litany(ev, mine)


# --- New Blood families (NewBloodSystem.ts) ----------------------------------------------------------------------------------------------------

func _nb_color() -> Color:
	match family:
		"warden":
			return _col("warden", "gold")
		"monk":
			return _col("monk", "sound")
		"witch":
			return _col("witch", "blood")
	return _col("veilwalker", "cyan")


func _nb_ring(x: float, z: float, r: float, duration: float = 0.5) -> void:
	var col := _nb_color()
	_decal("soundRing" if family == "monk" else "ring", col, x, z, r, duration, 0.85, {"growFrom": 0.3, "fadeOut": 0.3})
	_emit(x, 0.7, z, 10, col, minf(r, 2.0), 1.5, 1.4, 0.5, 0.14)


func _nb_gesture(t: Dictionary) -> void:
	super._nb_gesture(t)
	if _nb_id == "":
		return
	var attack := _NB_ATTACK.has(_nb_id)
	_gesture("attack" if attack else "cast", 2.8 if attack else 2.0, _nb_id)
	if _CAST_SFX.has(_nb_id):
		_sfx(_CAST_SFX[_nb_id], _px(), _pz())


func _nb_cast(id: String, t: Dictionary, now: float) -> Variant:
	_nb_id = id
	var def: Dictionary = DmSimData.ABILITIES[id] if DmSimData.ABILITIES.has(id) else {}
	var r: Variant = super._nb_cast(id, t, now)
	_nb_id = ""
	if r == null or r != "ok":
		return r
	var px := _px()
	var pz := _pz()
	var tx := float(t["x"])
	var tz := float(t["z"])
	var dx := tx - px
	var dz := tz - pz
	var l := _h(dx, dz)
	if l == 0.0:
		l = 1.0
	var WA := _col("warden", "gold")
	var WB := _col("witch", "blood")
	match id:
		"flail_swing":
			_nb_ring(px + dx / l * 3.0 * 0.5, pz + dz / l * 3.0 * 0.5, 3.0)
		"lantern_cone":
			_decal("lanternCone", WA, px + dx / l * 3.5, pz + dz / l * 3.5, 3.5, 0.65, 0.75, {"rot": atan2(dx, dz) + PI, "fadeOut": 0.4})
			_nb_ring(px + dx / l * 3.0, pz + dz / l * 3.0, 3.5)
		"hook_pull":
			var e := _nb_target(t, float(def["range"]))
			if e != null:
				var last: Array = [e.x, e.z]
				_beam(Vector3(px, 1.4, pz), _cb("_enemy_follow", [e.id, 1.1, last]), WB, 0.07, 0.35)
		"crow_swarm":
			_orbit({"tex": "crow", "color": WB, "count": 4, "radius": 2.0, "y": 1.2, "size": 0.65, "duration": 5.0, "speed": 3.0, "follow": _cb("_vis_const", [[tx, 0.0, tz]])})
		"veil_tear":
			_decal("veilRift", _col("veilwalker", "cyan"), tx, tz, 3.0, 2.0, 0.75, {"pulse": 5.0, "fadeOut": 0.5})
		"last_light", "toll", "great_toll":
			_nb_ring(px, pz, float(def["radius"]))
		"palm_strike":
			_nb_ring(tx, tz, 1.0)
		"resonant_step":
			_nb_ring(px, pz, 1.5)
		"choir_of_one":
			_nb_ring(px, pz, 2.5, 1.0)
		"hook_throw":
			_beam(Vector3(px, 1.4, pz), _cb("_vis_const", [[tx, 1.1, tz]]), WB, 0.05, 0.25)
			_flash(tx, 1.1, tz, WB, 0.85, 0.45, {"tex": "hookChain"})
			_nb_ring(tx, tz, 0.8)
		"murder_of_crows":
			_loop("crowSwarmLoop", 8000.0, px, pz, _cb("_fol_p2"))
			_orbit({"tex": "crow", "color": WB, "count": 6, "radius": 2.5, "y": 1.5, "size": 0.75, "duration": 8.0, "speed": 3.8, "follow": _cb("_aim_follow", [tx, tz])})
		"spirit_bolt":
			_nb_ring(tx, tz, 0.8)
		"veil_form":
			_nb_ring(px, pz, 1.2)
		"between_worlds":
			_nb_ring(px, pz, 2.0, 1.0)
	return r


func _aim_follow(tx: float, tz: float) -> Variant:
	if aim != null:
		return Vector3(float(aim["x"]), 0.0, float(aim["z"]))
	return Vector3(tx, 0.0, tz)


func _nb_update(now: float) -> void:
	var choir_before := _next_choir_beat
	var peck_before := _next_crow_peck
	super._nb_update(now)
	if _next_choir_beat != choir_before:
		_nb_ring(_px(), _pz(), 2.5)
	if _next_crow_peck != peck_before:
		for v: DmSimEnemy in sim.enemies.values():
			if v.state != "dead" and _h(v.x - _px(), v.z - _pz()) <= 3.0:
				_nb_ring(v.x, v.z, 0.6, 0.25)
				break


func on_new_blood(ev: Dictionary, mine: bool) -> void:
	_nb_on_event(ev, mine)


func _nb_on_event(ev: Dictionary, mine: bool) -> void:
	if ev["ok"]:
		var kind: String = ev["kind"]
		_nb_ring(float(ev["x"]), float(ev["z"]), 6.0 if (kind == "last_light" or kind == "great_toll") else 1.5)
		if not mine and _CAST_SFX.has(kind):
			_sfx(_CAST_SFX[kind], float(ev["x"]), float(ev["z"]), 0.7)
	super._nb_on_event(ev, mine)
	if ev["ok"] and mine and String(ev["kind"]) == "harvest":
		_loop("crowSwarmLoop", 6000.0, _px(), _pz(), _cb("_fol_p2"))
		_orbit({"tex": "crow", "color": _col("witch", "blood"), "count": 3, "radius": 1.1, "y": 1.8, "size": 0.55, "duration": 6.0, "speed": 2.7, "follow": _cb("_fol_p")})


# --- host events the web scene routes into the ability system -----------------------------------------------------------------------------------

## handle_event plus the visual-only events (rally / seeded / seedGone / seedBurst / corpseGone), as WorldScene.handleEvent routes them.
## Inside DmGame the event router (DmEventFx) already sends these to on_rally etc., so they are only routed here without one
## (standalone ability-fx tests); routing both drew every Rally / Carrion Seed effect twice.
func handle_event(ev: Dictionary) -> void:
	if game == null or game.get("event_fx") == null:
		_route_visual(ev)
	super.handle_event(ev)


func _route_visual(ev: Dictionary) -> void:
	match ev["t"]:
		"rally":
			on_rally(ev, _cb("_fol_p") if ev["by"] == self_id else Callable())
		"seeded":
			on_seeded(ev)
		"seedGone":
			on_seed_gone(int(ev["corpseId"]))
		"seedBurst":
			on_seed_burst(ev)
		"corpseGone":
			on_seed_gone(int(ev["id"]))
