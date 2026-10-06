class_name DmAffixSet
extends Node
## Elite affixes of ONE enemy (the current game's rules, DmSimData.AFFIX_TUNING): bellTolled, hungering, shrouded, vengeful. A child "Affixes"
## of the DmEnemy, created only on bodies that carry one (the spawn function, every peer), so a plain enemy has no node and no per-frame cost.
## Host: the rules (physics tick). Every peer: the look (persistent rings, 10 Hz motes) and each one-off moment exactly once (reliable RPC from
## the host, played locally on the host). See README.md.

signal moment(kind: StringName, at: Vector3)   ## every peer, once per beat: tell | toll | hungering | vengeful | unveil

const KINDS: Array[String] = ["bellTolled", "hungering", "shrouded", "vengeful"]   ## DmSimData.AFFIX_ORDER
const FOLLOW_RANGE := 30.0     ## motes only within this of the camera
const LOOK_S := 0.1
const MIASMA_HOLD_MS := 350    ## rite_miasma stamps meta dm_miasma_ms on shrouded bodies in its cloud (it scans at 10 Hz)
const HEAD_Y := 1.3

var vfx: Node                   ## test back-ends (null = the autoloads)
var audio: Node

var kinds: PackedStringArray = PackedStringArray()
var director: Node              ## host: spawns the vengeful Risen (set by DmWaveDirector)
var e: DmEnemy
var _host := false
var _t := 0.0
var _toll_cd := -1.0            ## -1 = fresh (the sim's null): starts at intervalS
var _toll_at := -1.0
var _toll_pos := Vector3.ZERO
var _hunger_cd := -1.0
var _shroud_t := 0.0
var _field: Node
var _rings: Array = []
var _shroud_ring: Variant = null
var _look_t := 0.0
var _ring_follow := Callable()
var _mote := {"x": 0.0, "y": 0.0, "z": 0.0, "count": 1, "color": 0, "spread": 0.1, "speed": 0.1, "up": 0.0, "life": 0.7, "size": 0.13, "gravity": 0.0}
var _sp: Dictionary


# ============================================================================================ rules of rolling

## Which affixes a new body gets (the sim's spawn_enemy + spawn_at_breach). Elite: the Omen's affix when it forces one, else one of the four;
## in the Depths plus DmSimDepthsRules.pick_extra_affixes. Non-elite: only Nightfall's shroud (`nightfall_chance` > 0 when the Nightfall
## milestone is active). `rand` returns [0, 1).
static func roll(elite: bool, omen_affix: String, depths_depth: float, nightfall_chance: float, rand: Callable) -> PackedStringArray:
	DmSimData.ensure()
	var out := PackedStringArray()
	if not elite:
		if nightfall_chance > 0.0 and float(rand.call()) < nightfall_chance:
			out.append("shrouded")
		return out
	var first := omen_affix
	if first == "":
		first = String(DmSimData.AFFIX_ORDER[int(floorf(float(rand.call()) * DmSimData.AFFIX_ORDER.size()))])
	out.append(first)
	if depths_depth >= 0.0:
		for a in DmSimDepthsRules.pick_extra_affixes(depths_depth, first, rand):
			out.append(String(a))
	return out


## Create the component on `body` (before it enters the tree: every peer's spawn function). No-op for an empty list.
static func attach(body: DmEnemy, list: PackedStringArray, p_director: Node = null) -> DmAffixSet:
	if list.is_empty():
		return null
	var s := DmAffixSet.new()
	s.name = "Affixes"
	s.kinds = list
	s.director = p_director
	body.add_child(s)
	body.set_meta(&"dm_affix_list", list)
	if list.has("shrouded"):
		body.set_meta(&"dm_shrouded", true)   # rite_miasma stamps dm_miasma_ms on these
	return s


static func of(body: Node) -> DmAffixSet:
	return body.get_node_or_null("Affixes") as DmAffixSet


func has(kind: String) -> bool:
	return kinds.has(kind)


# ============================================================================================ lifecycle

func _ready() -> void:
	e = get_parent() as DmEnemy
	if e == null:
		return
	DmSimData.ensure()
	_host = e.is_multiplayer_authority()
	_sp = DmFxData.data().get("spell_fx", {}).get("affix", {})
	_ring_follow = _ground
	if vfx == null:
		vfx = get_node_or_null("/root/Vfx")
	if audio == null:
		audio = get_node_or_null("/root/AudioDirector")
	e.state_changed.connect(_on_state)
	if _host:
		e.died.connect(_on_died)
	e.ready.connect(_dress, CONNECT_ONE_SHOT)   # the body's own _ready sets its scale; this runs first (children first)
	set_physics_process(_host)
	set_process(vfx != null and (has("hungering") or has("vengeful") or has("shrouded")))


func _exit_tree() -> void:
	_kill_rings()


func _on_state(_prev: int, next: int) -> void:
	if next == DmEnemyState.Id.DEAD:
		_kill_rings()
		set_physics_process(false)
		set_process(false)


func _ground() -> Vector3:
	return Vector3(e.global_position.x, 0.0, e.global_position.z) if is_instance_valid(e) else Vector3.ZERO


func _col(key: String) -> int:
	return int(_sp.get(key, 0xffffff))


# ============================================================================================ look (every peer)

## The persistent tell of each affix: a ring / glow / cracks under the body (DmEntityViews._dress_affix, same numbers).
func _dress() -> void:
	if vfx == null:
		return
	var sc := e.scale.x
	for k in kinds:
		match k:
			"bellTolled":
				_ring({"tex": "ring", "color": _col("bell"), "r": 1.55 * sc, "opacity": 0.6, "pulse": 2.5})
			"hungering":
				_ring({"tex": "glow", "color": _col("drool"), "r": 1.2 * sc, "opacity": 0.45})
			"shrouded":
				_shroud_ring = _ring({"tex": "glow", "color": _col("shroud"), "r": 1.5 * sc, "opacity": 0.7, "blending": "mix"})
			"vengeful":
				_ring({"tex": "cracks", "color": _col("vengeful"), "r": 1.3 * sc, "opacity": 0.75, "pulse": 3.0, "spin": 0.2})


func _ring(o: Dictionary) -> Variant:
	var p := _ground()
	o["danger"] = true
	o["x"] = p.x
	o["z"] = p.z
	o["duration"] = 1e9
	o["follow"] = _ring_follow
	var h: Variant = vfx.decal(o)
	if h != null:
		_rings.append(h)
	return h


func _kill_rings() -> void:
	for h in _rings:
		h.kill()
	_rings.clear()
	_shroud_ring = null


## Shroud lifted for good (Last Light / a Warden sweep: DmSimSignatures.strip_shroud): the ring goes everywhere.
func strip_shroud() -> void:
	if not has("shrouded") or not _host:
		return
	kinds.remove_at(kinds.find("shrouded"))
	e.remove_meta(&"dm_shrouded")
	var st := DmStatusSet.of(e)
	if st != null:
		st.remove(&"shrouded")
	_send(&"unveil", _ground(), Vector3.ZERO, 0.0)


func _process(dt: float) -> void:
	_look_t -= dt
	if _look_t > 0.0:
		return
	_look_t = LOOK_S
	var cam := get_viewport().get_camera_3d()
	if cam == null or e.sm == null or e.sm.id() == DmEnemyState.Id.DEAD:
		return
	var p := e.global_position
	if cam.global_position.distance_squared_to(p) > FOLLOW_RANGE * FOLLOW_RANGE:
		return
	var sc := e.scale.x
	var head := HEAD_Y * sc
	_mote["x"] = p.x
	_mote["z"] = p.z
	_mote["spread"] = 0.1
	_mote["gravity"] = 0.0
	if has("hungering") and randf() < LOOK_S * 4.0:
		_mote["x"] = p.x + sin(e.rotation.y) * 0.3 * sc
		_mote["z"] = p.z + cos(e.rotation.y) * 0.3 * sc
		_mote["y"] = head
		_mote["color"] = _col("drool")
		_mote["spread"] = 0.06
		_mote["speed"] = 0.1
		_mote["up"] = -0.3
		_mote["size"] = 0.13
		_mote["gravity"] = 7
		vfx.emit(_mote)
		_mote["x"] = p.x
		_mote["z"] = p.z
		_mote["gravity"] = 0.0
	if has("vengeful") and randf() < LOOK_S * 3.0:
		_mote["y"] = 0.3 + randf() * head
		_mote["color"] = _col("vengeful")
		_mote["spread"] = 0.35 * sc
		_mote["speed"] = 0.2
		_mote["up"] = 1.1
		_mote["size"] = 0.12
		vfx.emit(_mote)
	if has("shrouded") and randf() < LOOK_S * 2.0:
		var st := DmStatusSet.of(e)
		if st != null and st.has(&"shrouded"):   # lifted in a friendly cloud: no wisps
			vfx.emit_smoke({"x": p.x, "y": 0.4 + randf() * head, "z": p.z, "count": 1, "color": _col("shroud"), "spread": 0.4 * sc, "speed": 0.15, "up": 0.4, "life": 1.2, "size": 0.9, "shrink": -0.6})


# ============================================================================================ rules (host)

func _physics_process(dt: float) -> void:
	var sid := e.sm.id()
	if sid == DmEnemyState.Id.DEAD:
		return
	if has("shrouded"):   # the ward is geometry in the sim (on from the spawn), not a timer
		_shroud_t -= dt
		if _shroud_t <= 0.0:
			_shroud_t = LOOK_S
			_tick_shroud()
	if sid == DmEnemyState.Id.RISING or sid == DmEnemyState.Id.HURT or sid == DmEnemyState.Id.BURROW:
		return   # the sim ticks the other affixes only while the body acts (not rising, stunned, burrowed)
	_t += dt
	var T: Dictionary = DmSimData.AFFIX_TUNING
	if has("bellTolled"):
		_tick_bell(T["bellTolled"], dt)
	if has("hungering"):
		_tick_hunger(T["hungering"], dt)


func _tick_bell(B: Dictionary, dt: float) -> void:
	if _toll_at >= 0.0:
		if _t >= _toll_at:
			_toll_at = -1.0
			_sound_toll(B)
		return
	_toll_cd = (float(B["intervalS"]) if _toll_cd < 0.0 else _toll_cd) - dt
	if _toll_cd > 0.0:
		return
	_toll_cd = float(B["intervalS"])
	_toll_at = _t + float(B["windupS"])
	_toll_pos = _ground()
	e.telegraph.emit(&"toll", _toll_pos, _toll_pos, float(B["r"]), float(B["windupS"]))   # the router draws the filling ring + sound
	_send(&"tell", _toll_pos, _toll_pos, float(B["windupS"]))


## The bell sounds where it was struck: blow x damageMult to every hero and thrall inside r (the sim's `toll` hurt; stunMs is data the sim never used).
func _sound_toll(B: Dictionary) -> void:
	var dmg := e.damage * float(B["damageMult"])
	for tg in e.targets_within(_toll_pos, float(B["r"])):
		DmEnemy.deliver(tg, dmg, e, "toll")
	_send(&"toll", _toll_pos, Vector3.ZERO, float(B["r"]))


## Eats the nearest corpse within reach while hurt: heals healFrac of max hp (capped at missing hp), the corpse goes through the field's atomic consume.
func _tick_hunger(H: Dictionary, dt: float) -> void:
	_hunger_cd = (float(H["intervalS"]) if _hunger_cd < 0.0 else _hunger_cd) - dt
	if _hunger_cd > 0.0:
		return
	var c: DmSimCorpse = null
	if e.hp < e.max_hp:
		if _field == null or not is_instance_valid(_field):
			_field = get_tree().get_first_node_in_group(&"dm_corpse_field")
		if _field != null:
			var near: Array[DmSimCorpse] = _field.corpses_in_radius(e.global_position, float(H["reach"]), Callable(), String(e.get_meta(&"dm_area", "")))
			if not near.is_empty():
				c = near[0]
	if c == null:
		_hunger_cd = 0.5
		return
	var cx := c.x
	var cz := c.z
	if not _field.consume(c.id, 1, "devoured"):
		_hunger_cd = 0.5
		return
	_hunger_cd = float(H["intervalS"])
	var heal := minf(e.max_hp - e.hp, e.max_hp * float(H["healFrac"]))
	e.hp += heal
	_send(&"hungering", _ground(), Vector3(cx, 0.0, cz), heal)


## The ward holds unless a friendly Miasma / rot cloud covers the body: the status the damage path already multiplies by (DmStatusSet.scale_taken).
func _tick_shroud() -> void:
	var st := DmStatusSet.of(e)
	if st == null:
		return
	var in_cloud := Time.get_ticks_msec() - int(e.get_meta(&"dm_miasma_ms", -1000000)) < MIASMA_HOLD_MS
	if in_cloud == st.has(&"shrouded"):
		if in_cloud:
			st.remove(&"shrouded")
		else:
			st.apply(&"shrouded")


## Vengeful: burst into Risen on the ring where it fell (sim vengeance: 3 at 1.4 m, as strong as the body that died).
func _on_died(_body: DmEnemy) -> void:
	if not has("vengeful"):
		return
	var at := _ground()
	_send(&"vengeful", at, Vector3.ZERO, 1.8)
	if director == null or not is_instance_valid(director):
		return
	var n := int(DmSimData.AFFIX_TUNING["vengeful"]["risen"])
	var spin := randf() * TAU
	for i in n:
		var a := spin + float(i) / float(n) * TAU
		var p := at + Vector3(cos(a), 0.0, sin(a)) * 1.4
		if director.game != null and director.game.world != null and director.game.world.nav_ready():
			p = director.game.world.nav_closest(p)
		director.spawn("risen", p, [], false, {"level": float(e.get_meta(&"dm_level", 1.0)), "hp": e.hp_mult, "dmg": e.damage_mult},
			{"area": String(e.get_meta(&"dm_area", ""))})


# ============================================================================================ moments (once per peer)

func _send(kind: StringName, at: Vector3, to: Vector3, amount: float) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		_rpc_moment.rpc(String(kind), at, to, amount)
	_play(kind, at, to, amount)


@rpc("authority", "call_remote", "reliable")
func _rpc_moment(kind: String, at: Vector3, to: Vector3, amount: float) -> void:
	_play(StringName(kind), at, to, amount)


func _play(kind: StringName, at: Vector3, to: Vector3, amount: float) -> void:
	moment.emit(kind, at)
	match kind:
		&"tell":
			if not _host:
				e.telegraph.emit(&"toll", at, at, float(DmSimData.AFFIX_TUNING["bellTolled"]["r"]), amount)
		&"unveil":
			if kinds.has("shrouded"):
				kinds.remove_at(kinds.find("shrouded"))
			if _shroud_ring != null:
				_shroud_ring.kill()
				_rings.erase(_shroud_ring)
				_shroud_ring = null
		_:
			if vfx != null:
				_burst(kind, at, to, amount)


## The one-off beats (DmEntityViews._affix_moment, same numbers and sounds).
func _burst(kind: StringName, at: Vector3, to: Vector3, amount: float) -> void:
	var x := at.x
	var z := at.z
	match kind:
		&"toll":
			var r := amount
			var bell := _col("bell")
			_sfx("toll", x, z)
			for k in 3:
				vfx.decal({"tex": "ring", "color": bell, "x": x, "z": z, "r": r * (0.75 + k * 0.2), "duration": 0.5, "opacity": 1.0 - k * 0.25, "growFrom": 0.15, "delay": k * 0.07})
			vfx.emit({"x": x, "y": 0.8, "z": z, "count": 36, "color": bell, "spread": r * 0.3, "speed": 5, "up": 0.8, "life": 0.5, "size": 0.28})
			vfx.light_flash(Vector3(x, 1.5, z), DmFxData.hex(bell), 30.0, 0.4)
		&"hungering":
			var drool := _col("drool")
			_sfx("raise", to.x, to.z)
			vfx.beam(Vector3(to.x, 0.3, to.z), func() -> Vector3: return Vector3(x, 1.1, z), drool, 0.07, 0.45)
			vfx.emit({"x": x, "y": 1.1, "z": z, "count": 14, "color": drool, "spread": 0.3, "speed": 0.8, "up": 0.4, "life": 0.8, "size": 0.2, "gravity": 4})
		&"vengeful":
			var veng := _col("vengeful")
			_sfx("burst", x, z)
			vfx.decal({"tex": "cracks", "color": veng, "x": x, "z": z, "r": amount * 1.4, "rot": randf() * 6.0, "duration": 2, "opacity": 0.9, "growFrom": 0.3})
			vfx.decal({"tex": "ring", "color": int(DmFxData.data().get("spell_fx", {}).get("detonate", {}).get("ember", 0xffffff)), "x": x, "z": z, "r": amount, "duration": 0.5, "opacity": 1, "growFrom": 0.2})
			vfx.emit({"x": x, "y": 0.6, "z": z, "count": 40, "color": veng, "spread": 0.5, "speed": 3.5, "up": 2.2, "life": 0.8, "size": 0.3})
			vfx.emit_smoke({"x": x, "y": 0.4, "z": z, "count": 6, "color": int(DmFxData.data().get("spell_fx", {}).get("detonate", {}).get("smoke", 0x333333)), "spread": 0.8, "speed": 1, "up": 0.8, "life": 1.2, "size": 1.3})
			vfx.light_flash(Vector3(x, 1.2, z), DmFxData.hex(veng), 32.0, 0.5)


func _sfx(id: String, x: float, z: float) -> void:
	if audio != null:
		audio.play_sfx(id, Vector2(x, z), 1.0)
