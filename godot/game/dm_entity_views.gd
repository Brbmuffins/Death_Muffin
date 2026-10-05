class_name DmEntityViews
extends Node3D
## Maps simulation entities onto animated creatures (port of src/graphics/EntityViews.ts): enemies climb out of the ground, die into
## corpses that stay where they fell, and are consumed or sink away; thralls get weapons, a spirit ring and the legion's look.
## Driven purely from the sim: `sync(sim.enemies, sim.thralls, dt, focus_x, focus_z)` every frame, `on_event(ev)` for every sim event,
## `prune_corpses(sim.corpses)` after a resync. Visual effects go through the Vfx autoload (the web's `effects.*`); sounds through
## AudioDirector (`audio.play`). Replaces the slice's world/enemy.gd + thrall.gd.
##
## Host (`game`, duck-typed): world_root, self_id; optional legion_kit_for(owner) -> {weapon:{itemId,rarity}, armor:{...}} | null,
## discipline_id_for(owner) -> String | null, hitstop(seconds).

const ENEMY_SLUG := {
	"robber": "grave_robber", "hound": "bone_hound", "penitent": "penitent", "sac": "carrion_sac", "deacon": "deacon", "risen": "skeleton_thrall",
	"censer": "censer_bearer", "wraith": "choir_wraith", "rat": "skull_rat", "golem": "bone_golem", "gargoyle": "belfry_gargoyle",
	"moth": "shroud_moth", "bat": "tithe_bat", "seraph": "weeping_seraph", "ghoul": "barrow_ghoul", "acolyte": "lich_acolyte",
	"templar": "bell_templar", "niche": "skull_niche", "plague_doctor": "plague_doctor", "flagellant": "flagellant",
	"cinder_husk": "cinder_husk", "pyre_priest": "pyre_priest", "cinderhound": "cinderhound", "slag_brute": "slag_brute",
	"bog_hag": "bog_hag", "mire_leech": "mire_leech", "fen_wisp": "fen_wisp", "drowned_sexton": "drowned_sexton",
}
const ENEMY_FALLBACK := {
	"censer": "deacon", "wraith": "penitent", "rat": "bone_hound", "golem": "skeleton_thrall", "gargoyle": "bone_hound",
	"moth": "choir_wraith", "bat": "skull_rat", "seraph": "deacon", "ghoul": "grave_robber", "acolyte": "deacon", "templar": "grave_robber",
	"plague_doctor": "deacon", "flagellant": "grave_robber", "cinder_husk": "grave_robber", "pyre_priest": "deacon", "cinderhound": "bone_hound",
	"slag_brute": "bone_golem", "bog_hag": "deacon", "mire_leech": "skull_rat", "fen_wisp": "choir_wraith", "drowned_sexton": "bone_golem",
}
const CASTERS := ["penitent", "deacon", "wraith", "censer", "moth", "seraph", "acolyte", "plague_doctor", "pyre_priest", "bog_hag", "fen_wisp"]
const FIRE_DEAD := ["cinder_husk", "pyre_priest", "cinderhound", "slag_brute"]
const FEN_DEAD := ["fen_wisp", "bog_hag", "drowned_sexton", "mire_leech"]
const HOVER := {"wraith": 0.45}
const WINGS := {
	"moth": {"speed": 8.0, "amp": 0.55, "body": 0.16},
	"bat": {"speed": 17.0, "amp": 0.75, "body": 0.22},
	"seraph": {"speed": 3.2, "amp": 0.22, "body": 0.3},
}
const LEGION := {
	"ossuary": {"slug": "thrall_sentinel", "tint": 0xffffff, "emissive": 0x6b4a1f, "glow": 0.12, "armed": true},
	"gravecaller": {"slug": "thrall_legionnaire", "tint": 0xffffff, "emissive": 0x6a3fc0, "glow": 0.16, "armed": true},
	"rotweaver": {"slug": "thrall_plague", "tint": 0xffffff, "emissive": 0x5a6a18, "glow": 0.16, "armed": false},
	"mourner": {"slug": "wraith_thrall"},
}
const THRALL_SLUG := {
	"warrior": "skeleton_thrall", "shieldbearer": "skeleton_thrall", "hound": "bone_hound", "wraith": "skeleton_thrall",
	"archer": "skeleton_thrall", "bonemage": "skeleton_thrall", "plaguebearer": "carrion_sac", "colossus": "bone_colossus",
}
const THRALL_LOOK := {
	"archer": {"tint": 0xf2e6cc, "emissive": 0x6b4a1f, "glow": 0.25},
	"bonemage": {"tint": 0xe6dccb, "emissive": 0xb07a2a, "glow": 0.35},
	"plaguebearer": {"tint": 0xb9c48a, "emissive": 0x5a6a18, "glow": 0.35, "scale": 0.8, "ring": 0.7},
	"colossus": {"tint": 0xffffff, "emissive": 0x1f8f86, "glow": 0.1, "ring": 1.7},
}
const KIT_BODIES := ["warrior", "shieldbearer", "archer", "bonemage"]
const KIT_ARMOR_STRENGTH := 0.32
const THRALL_MOVE_HOLD_S := 0.18
const SHADOW_CASTERS := 12
const ENEMY_TURN_RATE := 9.0
const MAX_CROWD := 140
const CROWD_EASE := 9.0
const CROWD_FOOTPRINT := 1.12
const CROWDED_SHADOW_CASTERS := 8
const FLINCH_BURST := 6
const FLINCH_WINDOW_MS := 380
const HEAVY_HIT := 0.22
const HEAVY_HIT_ELITE := 0.12
const HITSTOP_RANGE := 16.0
const SETTLE_DEPTH := 0.06
const NO_SETTLE := -1.0
const CORPSE_ANIM_S := 6.0
const CORPSE_REST_S := 0.35
const CORPSE_MARKS_MAX := 8
const THRALL_RIM_OWN := 0.9
const THRALL_RIM_ALLY := 0.6
const HEAD_Y := {"humanoid": 1.3, "robed": 1.35, "quadruped": 0.75, "bloat": 1.05}
# knockback.ts
const KNOCK_K := 140.0
const KNOCK_MAX := 0.6
# animLod.ts
const ANIM_MID_S := 1.0 / 24.0
const ANIM_FAR_S := 1.0 / 10.0


class View extends RefCounted:
	var c: DmCreature
	var move_hold_t := 0.0
	var x := 0.0
	var z := 0.0
	var facing := 0.0
	var last_state := ""
	var def := ""
	var kind := ""
	var ring: Variant = null
	var hex_fx: Variant = null
	var elite_aura: Variant = null
	var aura_fx: Variant = null
	var affix := ""
	var affix_fx: Array = []
	var has_shroud := false
	var shroud := 1.0
	var shattered := false
	var die_t := 0.0
	var sink_t := 0.0
	var anim_skip := 0
	var anim_dt := 0.0
	var is_float := false
	var under := false
	var mound: MeshInstance3D = null
	var last_flash := 0.0
	var flinch_at := 0.0
	var has_gs := false
	var gs := 0.0
	var ox := 0.0
	var oz := 0.0
	var tox := 0.0
	var toz := 0.0
	var in_crowd := false
	var rest_t := 0.0
	var kn: Variant = null
	var has_last_hp := false
	var last_hp := 0.0
	var has_settle := false
	var settle_t := 0.0
	var settle_y := 0.0
	var extras: Array = []


var game: Variant = null
var hover_id: int = -1
var vfx: Node = null
var audio: Node = null

var _enemies: Dictionary = {}
var _thralls: Dictionary = {}
var _corpses: Dictionary = {}
var _corpse_rings: Dictionary = {}
var _dying: Array = []
## Dead enemies' creatures, kept for the next spawn of the same model + look (instancing a skinned model is the wave-spawn cost).
var _pool: Dictionary = {}   # pool key -> Array[DmCreature]
const POOL_PER_KEY := 12
var pool_hits := 0
var pool_misses := 0
var _fading: Array = []
var _frame := 0
var _crowd: Array = []        # [x, z, r, w]
var _crowd_views: Array = []
var _crowd_out := PackedFloat32Array()
var _crowd_accum := 1.0
var _crowd_size := 0
var _focus_x := 0.0
var _focus_z := 0.0
var _flinch_starts: Array = []
var _mound_mesh: Mesh
var _mound_mat: StandardMaterial3D
var _enemy_defs: Dictionary = {}
var _burrow: Dictionary = {}
var _censer: Dictionary = {}
var _unbind: Dictionary = {}
var _champion_scale := 1.35
var _status_fx: Dictionary = {}
var _spell_fx: Dictionary = {}


func setup(host: Variant) -> void:
	game = host
	name = "EntityViews"
	var parent: Node = host.get("world_root") if host != null and host.get("world_root") != null else null
	if parent != null:
		parent.add_child(self)
	var root := Engine.get_main_loop() as SceneTree
	vfx = root.root.get_node_or_null("Vfx")
	audio = root.root.get_node_or_null("AudioDirector")
	_enemy_defs = DmContent.enemies()
	_burrow = DmContent.get_export("enemies", "BURROW")
	_censer = DmContent.get_export("enemies", "CENSER")
	_unbind = DmContent.get_export("enemies", "UNBIND")
	var legend: Dictionary = DmContent.get_export("gameplay_legendary", "LEGEND")
	_champion_scale = float(legend.get("championScale", 1.35))
	_status_fx = DmContent.get_export("statuses", "STATUS_FX")
	_spell_fx = DmFxData.data().get("spell_fx", {})
	_crowd_out.resize(2 * (MAX_CROWD + 2))

# ----------------------------------------------------------------------------------------------------------------- helpers

func _sp(group: String, key: String) -> int:
	return int((_spell_fx.get(group, {}) as Dictionary).get(key, 0xffffff))

func _st(group: String, key: String) -> int:
	return int((_status_fx.get(group, {}) as Dictionary).get(key, 0xffffff))

func _emit(o: Dictionary) -> void:
	if vfx != null:
		vfx.emit(o)

func _smoke(o: Dictionary) -> void:
	if vfx != null:
		vfx.emit_smoke(o)

func _decal(o: Dictionary) -> Variant:
	return vfx.decal(o) if vfx != null else null

func _kill(h: Variant) -> void:
	if h != null:
		h.kill()

func _alive(h: Variant) -> bool:
	return h != null and h.alive

func _sfx(id: String, x: float, z: float) -> void:
	if audio != null:
		audio.play_sfx(id, Vector2(x, z), 1.0)

func _now_ms() -> float:
	return float(Time.get_ticks_msec())

func _def(id: String) -> Dictionary:
	return _enemy_defs.get(id, {})

func _follow(v: View) -> Callable:
	return func(): return Vector3(v.x + v.ox, 0.0, v.z + v.oz)

func _kill_affix_fx(v: View) -> void:
	for h in v.affix_fx:
		_kill(h)
	v.affix_fx = []

func _affixes_of(e: DmSimEnemy) -> Array:
	var out: Array = []
	if e.affix != "":
		out.append(e.affix)
		for x in e.extra:
			out.append(x["affix"])
	return out

static func turn_toward(cur: float, target: float, dt: float, rate: float, max_rate: float = INF) -> float:
	var d := target - cur
	while d > PI:
		d -= TAU
	while d < -PI:
		d += TAU
	var lim := max_rate * dt
	return cur + maxf(-lim, minf(lim, d * minf(1.0, dt * rate)))

static func step_speed(dx: float, dz: float, dt: float, max_step: float = 3.0) -> float:
	var d := sqrt(dx * dx + dz * dz)
	return d / dt if (dt > 1e-5 and d <= max_step) else 0.0

static func smooth_speed(prev: float, sample: float, dt: float, tau: float = 0.12) -> float:
	return prev + (sample - prev) * (1.0 - exp(-maxf(0.0, dt) / tau))

## animInterval: seconds that must accumulate before a body's mixer updates again (0 = every frame).
static func anim_interval(ax: float, az: float, busy: bool, crowded: bool) -> float:
	var near_x := 10.0 if crowded else 13.0
	var near_z := 9.0 if crowded else 11.0
	if busy or (ax < near_x and az < near_z):
		return 0.0
	return ANIM_FAR_S if (ax > 26.0 or az > 22.0) else ANIM_MID_S

## knockImpulse
static func knock_impulse(frac: float, mass: float, dx: float, dz: float) -> Vector2:
	var l := sqrt(dx * dx + dz * dz)
	if l == 0.0:
		l = 1.0
	var push := pow(clampf(frac, 0.0, 1.0), 0.6) * 16.0 / maxf(0.6, mass)
	var v := minf(push, 20.0)
	return Vector2(dx / l * v, dz / l * v)

static func step_knock(k: Dictionary, dt: float) -> void:
	var n := maxi(1, ceili(dt / (1.0 / 120.0)))
	var h := dt / n
	var c := 2.0 * sqrt(KNOCK_K)
	for i in n:
		k.vx += (-KNOCK_K * k.x - c * k.vx) * h
		k.vz += (-KNOCK_K * k.z - c * k.vz) * h
		k.x += k.vx * h
		k.z += k.vz * h
	var d := sqrt(k.x * k.x + k.z * k.z)
	if d > KNOCK_MAX:
		k.x *= KNOCK_MAX / d
		k.z *= KNOCK_MAX / d
	if d < 1e-3 and sqrt(k.vx * k.vx + k.vz * k.vz) < 0.02:
		k.x = 0.0
		k.z = 0.0
		k.vx = 0.0
		k.vz = 0.0

static func knock_active(k: Dictionary) -> bool:
	return k.x != 0.0 or k.z != 0.0 or k.vx != 0.0 or k.vz != 0.0

static func settle_depth(t: float, depth: float, dur: float = 0.45) -> float:
	var k := clampf(t / dur, 0.0, 1.0)
	return depth * k * k * (3.0 - 2.0 * k)

## hitstopSeconds(weight): round(2 + w*2) frames of 1/60 s.
static func hitstop_seconds(weight: float) -> float:
	var w := clampf(weight, 0.0, 1.0)
	return float(roundi(2.0 + w * 2.0)) / 60.0

func _allow_burst() -> bool:
	var now := _now_ms()
	while not _flinch_starts.is_empty() and now - _flinch_starts[0] > FLINCH_WINDOW_MS:
		_flinch_starts.pop_front()
	if _flinch_starts.size() >= FLINCH_BURST:
		return false
	_flinch_starts.append(now)
	return true

func _make_mound() -> MeshInstance3D:
	if _mound_mesh == null:
		var s := SphereMesh.new()
		s.radius = 0.55
		s.height = 1.1
		s.is_hemisphere = true
		s.radial_segments = 14
		s.rings = 5
		_mound_mesh = s
		_mound_mat = StandardMaterial3D.new()
		_mound_mat.albedo_color = DmGearProps.col(0x33251a)
		_mound_mat.roughness = 1.0
		_mound_mat.metallic = 0.0
	var m := MeshInstance3D.new()
	m.mesh = _mound_mesh
	m.material_override = _mound_mat
	m.scale = Vector3(1.0, 0.4, 1.3)
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return m

func _is_own(owner: String) -> Variant:
	if game != null and game.has_method("is_own_legion"):
		return game.is_own_legion(owner)
	var sid: Variant = game.get("self_id") if game != null else null
	if sid == null or String(sid) == "":
		return null
	return owner == String(sid)

# ----------------------------------------------------------------------------------------------------------------- makers

## The look of an enemy body (tint, emissive, spectral, wings, fallback rig): also its pool key. `e` is a DmSimEnemy or a dict with def/elite/area.
func _enemy_opts(e: Variant) -> Dictionary:
	var risen: bool = e.def == "risen"
	var wraith: bool = e.def == "wraith"
	var drowned: bool = risen and e.area == "fen"
	var em := 0x000000
	var ek := 0.0
	if e.elite:
		em = 0x4a1f8a
		ek = 0.14
	elif risen:
		em = 0x1f8f86 if drowned else 0x2a3a18
		ek = 0.4 if drowned else 0.3
	elif wraith:
		em = 0x9fb6d8
		ek = 0.35
	elif e.def == "fen_wisp":
		em = 0x7fe0d0
		ek = 0.9
	var o := {
		"tint": (0x7ab0a8 if drowned else 0x8a8078) if risen else 0xffffff,
		"emissive": em, "emissive_intensity": ek, "spectral": wraith,
		"hitstop": true,
	}
	if ENEMY_FALLBACK.has(e.def):
		o["fallback"] = ENEMY_FALLBACK[e.def]
	if WINGS.has(e.def):
		o["wings"] = WINGS[e.def]
	return o

func _make_enemy(e: DmSimEnemy) -> View:
	var slug: String = ENEMY_SLUG.get(e.def, "grave_robber")
	var o := _enemy_opts(e)
	var c := _creature(slug, o)
	c.root.position = Vector3(e.x, 0.0, e.z)
	c.root.rotation.y = e.facing
	c.root.scale = Vector3.ONE * e.scale
	add_child(c.root)
	var v := View.new()
	v.c = c
	v.x = e.x
	v.z = e.z
	v.facing = e.facing
	v.def = e.def
	if e.elite:
		v.elite_aura = _decal({"danger": true, "tex": "ring", "color": 0x9b5cff, "x": e.x, "z": e.z, "r": 1.1 * e.scale,
			"duration": 1e9, "opacity": 0.8, "pulse": 4.0, "follow": _follow(v)})
	if e.affix != "":
		_dress_affix(v, e)
	return v

static func _pool_key(slug: String, o: Dictionary) -> String:
	return slug + "|" + var_to_str(o)

## A pooled body of this model + look when one is free, else a new instance. Only enemy bodies are pooled (thralls carry hand props).
func _creature(slug: String, o: Dictionary) -> DmCreature:
	var key := _pool_key(slug, o)
	var list: Array = _pool.get(key, [])
	while not list.is_empty():
		var c: DmCreature = list.pop_back()
		if c.root != null and is_instance_valid(c.root):
			c.recycle_reset()
			pool_hits += 1
			return c
	pool_misses += 1
	var nc := DmCreature.new(slug, o)
	nc.opts["pool_key"] = key
	return nc

## Retire a body: back to the pool when it is a pooled kind with room, else freed.
func _retire(c: DmCreature) -> void:
	var key := String(c.opts.get("pool_key", ""))
	if key == "" or c.root == null or not is_instance_valid(c.root):
		c.dispose()
		return
	var list: Array = _pool.get(key, [])
	if list.size() >= POOL_PER_KEY:
		c.dispose()
		return
	if c.root.get_parent() != null:
		c.root.get_parent().remove_child(c.root)
	list.append(c)
	_pool[key] = list

## Pre-build `n` bodies of every enemy kind (DmWarmup), so even a wave's first spawn of a kind reuses a body.
func prewarm(n: int = 2) -> int:
	var made := 0
	for def in ENEMY_SLUG:
		var o := _enemy_opts({"def": def, "elite": false, "area": ""})
		var slug: String = ENEMY_SLUG[def]
		var key := _pool_key(slug, o)
		var have: int = (_pool.get(key, []) as Array).size()
		for i in maxi(0, n - have):
			var c := DmCreature.new(slug, o)
			c.opts["pool_key"] = key
			_retire(c)
			made += 1
	return made

## Background top-up for the area the hero is in: enough bodies of each roster kind for a wave (by roster weight, 2..8), built
## one per frame so a wave's spawn frame only takes bodies out of the pool.
var _topup: Array = []   # [def, area, target]

func queue_area(area: String) -> void:
	_topup.clear()
	var def: Dictionary = DmSimData.AREAS.get(area, {})
	var roster: Array = def.get("enemies", [])
	var total := 0.0
	for r in roster:
		total += float(r.get("weight", 1.0))
	for r in roster:
		var share := float(r.get("weight", 1.0)) / maxf(total, 0.001)
		var pack: Variant = DmSimData.ENEMIES.get(String(r["id"]), {}).get("pack")
		var want := ceili(share * 14.0) + (int(pack[1]) if pack != null else 0)
		_topup.append([String(r["id"]), area, clampi(want, 2, 8)])

func _pump_topup() -> void:
	while not _topup.is_empty():
		var it: Array = _topup[0]
		if not ENEMY_SLUG.has(it[0]):
			_topup.pop_front()
			continue
		var o := _enemy_opts({"def": it[0], "elite": false, "area": it[1]})
		var slug: String = ENEMY_SLUG[it[0]]
		var key := _pool_key(slug, o)
		if (_pool.get(key, []) as Array).size() >= int(it[2]):
			_topup.pop_front()
			continue
		var c := DmCreature.new(slug, o)
		c.opts["pool_key"] = key
		_retire(c)
		return

## Show every pooled body once under `parent` (one opaque, one mid-fade per kind) so their shaders compile during the loading screen.
func warm_bodies(parent: Node3D, at: Vector3) -> Array:
	var out: Array = []
	var i := 0
	for key in _pool:
		var list: Array = _pool[key]
		for j in mini(list.size(), 2):
			var c: DmCreature = list[j]
			parent.add_child(c.root)
			c.root.position = at + Vector3(float(i % 8) - 3.5, 0.0, float(i / 8) * 0.6) * 0.5
			c.root.scale = Vector3.ONE * 0.3
			if j == 1:
				c.set_opacity(0.5)
			c.update(0.016)
			out.append(c)
			i += 1
	return out

func warm_bodies_end(bodies: Array) -> void:
	for c: DmCreature in bodies:
		if c.root != null and is_instance_valid(c.root) and c.root.get_parent() != null:
			c.root.get_parent().remove_child(c.root)
		c.recycle_reset()

## A readable, persistent tell for each elite affix.
func _dress_affix(v: View, e: DmSimEnemy) -> void:
	v.affix = e.affix
	var fol := func(): return Vector3(v.x, 0.0, v.z)
	var fxs: Array = []
	for affix in _affixes_of(e):
		match affix:
			"bellTolled":
				fxs.append(_decal({"danger": true, "tex": "ring", "color": _sp("affix", "bell"), "x": e.x, "z": e.z, "r": 1.55 * e.scale, "duration": 1e9, "opacity": 0.6, "pulse": 2.5, "follow": fol}))
			"hungering":
				fxs.append(_decal({"danger": true, "tex": "glow", "color": _sp("affix", "drool"), "x": e.x, "z": e.z, "r": 1.2 * e.scale, "duration": 1e9, "opacity": 0.45, "follow": fol}))
			"shrouded":
				fxs.append(_decal({"danger": true, "tex": "glow", "color": _sp("affix", "shroud"), "x": e.x, "z": e.z, "r": 1.5 * e.scale, "duration": 1e9, "opacity": 0.7, "blending": "mix", "follow": fol}))
				v.has_shroud = true
				v.shroud = 1.0
			"vengeful":
				fxs.append(_decal({"danger": true, "tex": "cracks", "color": _sp("affix", "vengeful"), "x": e.x, "z": e.z, "r": 1.3 * e.scale, "duration": 1e9, "opacity": 0.75, "pulse": 3.0, "spin": 0.2, "follow": fol}))
	v.affix_fx = fxs

## Per-frame affix particles / shroud fade.
func _tick_affix(v: View, e: DmSimEnemy, dt: float, near_fx: bool) -> void:
	var head_y: float = HEAD_Y.get(String(_def(e.def).get("rig", "humanoid")), 1.3) * e.scale
	for affix in _affixes_of(e):
		match affix:
			"hungering":
				if near_fx and randf() < dt * 4.0:
					var f := v.facing
					_emit({"x": e.x + sin(f) * 0.3 * e.scale, "y": head_y, "z": e.z + cos(f) * 0.3 * e.scale, "count": 1, "color": _sp("affix", "drool"), "spread": 0.06, "speed": 0.1, "up": -0.3, "life": 0.7, "size": 0.13, "gravity": 7})
			"vengeful":
				if near_fx and randf() < dt * 3.0:
					_emit({"x": e.x, "y": 0.3 + randf() * head_y, "z": e.z, "count": 1, "color": _sp("affix", "vengeful"), "spread": 0.35 * e.scale, "speed": 0.2, "up": 1.1, "life": 0.7, "size": 0.12})
			"shrouded":
				var target := 1.0 if e.slowT > 0.0 else 0.38
				v.shroud = v.shroud + (target - v.shroud) * minf(1.0, dt * 6.0)
				v.c.set_opacity(v.shroud)
				if near_fx and target < 1.0 and randf() < dt * 2.0:
					_smoke({"x": e.x, "y": 0.4 + randf() * head_y, "z": e.z, "count": 1, "color": _sp("affix", "shroud"), "spread": 0.4 * e.scale, "speed": 0.15, "up": 0.4, "life": 1.2, "size": 0.9, "shrink": -0.6})

func _make_thrall(t: DmSimThrall) -> View:
	var wraith := t.kind == "wraith"
	var look: Variant = THRALL_LOOK.get(t.kind)
	var legion: Variant = null
	if look == null:
		var lid := "mourner" if t.kind == "wraith" else _legion_of(t.owner)
		legion = LEGION.get(lid)
	var kit: Variant = null
	if KIT_BODIES.has(t.kind) and game != null and game.has_method("legion_kit_for"):
		kit = game.legion_kit_for(t.owner)
	var kit_weapon: Variant = kit.get("weapon") if kit is Dictionary else null
	var kit_armor: Variant = kit.get("armor") if kit is Dictionary else null
	var slug: String = String(legion.slug) if legion != null else String(THRALL_SLUG.get(t.kind, "skeleton_thrall"))
	var own: Variant = _is_own(t.owner)
	var glow_base: float = 1.1 if wraith else (float(look.glow) if look != null else (float(legion.get("glow", 0.18)) if legion != null else 0.18)) + (0.22 if t.empowered else 0.0)
	var o := {
		"gear_tint": kit_armor != null,
		"tint": int(look.tint) if look != null else (int(legion.get("tint", 0xf4ecff)) if legion != null and legion.has("tint") else (0xb9c4ff if wraith else 0xf4ecff)),
		"emissive": int(look.emissive) if look != null else (int(legion.emissive) if legion != null and legion.has("emissive") else (0x8f9ed1 if wraith else 0x1f8f86)),
		"emissive_intensity": glow_base + (0.35 if t.champion else 0.0),
		"spectral": wraith,
		"scale": (float(look.scale) if look != null and look.has("scale") else (1.1 if t.kind == "shieldbearer" else 1.0)) * (_champion_scale if t.champion else 1.0),
		"rim": {"color": 0xd9a441 if t.champion else _sp("exhume", "spirit"), "strength": 1.4 if t.champion else (THRALL_RIM_ALLY if own == false else THRALL_RIM_OWN)},
	}
	var c := DmCreature.new(slug, o)
	add_child(c.root)
	var armed: bool = legion == null or bool(legion.get("armed", false))
	if (t.kind == "warrior" or t.kind == "shieldbearer") and armed:
		var blade: Node3D = DmGearProps.bone_sword(int(DmGearProps.tier(String(kit_weapon.itemId), String(kit_weapon.get("rarity", ""))).color)) if kit_weapon != null else DmGearProps.bone_sword()
		c.attach("R_Hand", blade, Vector3(0, 1, 0.55), 0.6)
		c.attach("L_Hand", DmGearProps.round_shield(0.5 if t.kind == "shieldbearer" else 0.32), Vector3(0, 1, 0), 0.5)
	elif t.kind == "archer":
		var bow := DmGearProps.bone_bow()
		if kit_weapon != null:
			DmGearProps.upgrade_thrall_prop(bow, "bow", String(kit_weapon.itemId), String(kit_weapon.get("rarity", "")))
		c.attach("L_Hand", bow, Vector3(0, 1, 0), 0.5)
	elif t.kind == "bonemage":
		var staff := DmGearProps.bone_staff()
		if kit_weapon != null:
			DmGearProps.upgrade_thrall_prop(staff, "staff", String(kit_weapon.itemId), String(kit_weapon.get("rarity", "")))
		c.attach("R_Hand", staff, Vector3(0, 1, 0.12), 0.15)
	if kit_armor != null:
		var tier := DmGearProps.tier(String(kit_armor.itemId), String(kit_armor.get("rarity", "")))
		for region in ["chest", "hands"]:
			c.set_region_tint(region, {"color": tier.color, "glow": tier.glow if int(tier.glow) >= 0 else null, "strength": KIT_ARMOR_STRENGTH})
	var v := View.new()
	v.c = c
	v.x = t.x
	v.z = t.z
	v.facing = t.facing
	v.kind = t.kind
	v.is_float = wraith
	var ring_r: float = (float(look.ring) if look != null and look.has("ring") else (0.6 if t.kind == "hound" else 0.5)) * (1.3 if t.champion else 1.0)
	v.ring = _decal({
		"other": own == false, "tex": "ring",
		"color": 0xd9a441 if t.champion else (0x8fb4ff if wraith else _sp("exhume", "spirit")),
		"x": t.x, "z": t.z, "r": ring_r, "duration": 1e9, "opacity": 1.0 if t.empowered else 0.7, "follow": _follow(v)})
	return v

func _legion_of(owner: String) -> String:
	if game != null and game.has_method("discipline_id_for"):
		var d: Variant = game.discipline_id_for(owner)
		return String(d) if d != null else ""
	return ""

# ----------------------------------------------------------------------------------------------------------------- per-enemy effects

## Ember shedding and hit sparks for the Cinder Pyre's dead.
func _fire_dead(e: DmSimEnemy, dt: float, struck: bool) -> void:
	var s := e.scale
	var ember := _sp("enemy", "ember")
	var core := _sp("enemy", "emberCore")
	var deep := _sp("enemy", "emberDeep")
	if struck:
		var heavy := e.def == "slag_brute"
		_emit({"x": e.x, "y": 1.1 * s, "z": e.z, "count": 14 if heavy else 9, "color": core, "spread": 0.25, "speed": 4.2 if heavy else 3.2, "up": 2, "life": 0.55, "size": 0.11, "gravity": 9})
		_emit({"x": e.x, "y": 1.1 * s, "z": e.z, "count": 4, "color": ember, "spread": 0.3, "speed": 1.6, "up": 1.2, "life": 0.7, "size": 0.2, "gravity": 4})
		if heavy:
			_smoke({"x": e.x, "y": 1.4, "z": e.z, "count": 2, "color": deep, "spread": 0.4, "speed": 0.6, "up": 0.5, "life": 0.8, "size": 0.9, "shrink": -0.5})
	match e.def:
		"cinder_husk":
			if randf() < dt * 7.0:
				_emit({"x": e.x, "y": 0.9 + randf() * 0.9, "z": e.z, "count": 1, "color": ember if randf() < 0.6 else core, "spread": 0.3, "speed": 0.15, "up": 1.1, "life": 0.9, "size": 0.1, "drag": 0.5})
		"pyre_priest":
			if randf() < dt * (22.0 if e.state == "windup" else 5.0):
				_emit({"x": e.x, "y": 0.9 * s, "z": e.z, "count": 1, "color": core, "spread": 0.2, "speed": 0.2, "up": 1.2, "life": 0.7, "size": 0.18 if e.state == "windup" else 0.11, "drag": 0.4})
			if randf() < dt * 2.0:
				_smoke({"x": e.x, "y": 1.5, "z": e.z, "count": 1, "color": 0x8a8680, "spread": 0.3, "speed": 0.15, "up": 0.3, "life": 1.6, "size": 0.7, "shrink": -0.4})
		"cinderhound":
			if e.moving and randf() < dt * 14.0:
				_emit({"x": e.x, "y": 0.35, "z": e.z, "count": 1, "color": ember if randf() < 0.5 else core, "spread": 0.15, "speed": 0.4, "up": 0.8, "life": 0.55, "size": 0.09, "gravity": 2})
			if e.moving and randf() < dt * 4.0:
				_smoke({"x": e.x, "y": 0.5, "z": e.z, "count": 1, "color": deep, "spread": 0.2, "speed": 0.2, "up": 0.3, "life": 0.8, "size": 0.6, "shrink": -0.5})
		"slag_brute":
			if randf() < dt * 6.0:
				_emit({"x": e.x, "y": 1.0 + randf() * 1.6, "z": e.z, "count": 1, "color": ember, "spread": 0.6, "speed": 0.15, "up": 1, "life": 1.1, "size": 0.16, "drag": 0.5})
			if randf() < dt * 2.5:
				_smoke({"x": e.x, "y": 2.2, "z": e.z, "count": 1, "color": deep, "spread": 0.4, "speed": 0.2, "up": 0.6, "life": 1.6, "size": 1.1, "shrink": -0.4})

## The Fen's dead: the wisp's marsh-light, the hag's drips, the sexton's water, the leech's slither.
func _fen_dead(e: DmSimEnemy, dt: float, lift: float, id: int, v: View) -> void:
	var T := 0x7fe0d0
	match e.def:
		"fen_wisp":
			if randf() < dt * 9.0:
				_emit({"x": e.x, "y": lift + 0.2 + randf() * 0.6, "z": e.z, "count": 1, "color": T if randf() < 0.6 else 0xeaffff, "spread": 0.25, "speed": 0.15, "up": -0.2, "life": 0.8, "size": 0.12, "drag": 0.6})
		"bog_hag":
			var wind := e.state == "windup"
			if randf() < dt * (20.0 if wind else 3.0):
				_emit({"x": e.x, "y": 1.0 + randf() * 0.8, "z": e.z, "count": 1, "color": _sp("enemy", "hex") if wind else 0x6fb4a8, "spread": 0.3, "speed": 0.2, "up": 1.2 if wind else -0.4, "life": 0.8, "size": 0.14, "gravity": -0.3 if wind else 5})
		"drowned_sexton":
			if randf() < dt * 6.0:
				_emit({"x": e.x + (randf() - 0.5) * 0.8, "y": 1.6 * e.scale, "z": e.z + (randf() - 0.5) * 0.8, "count": 1, "color": 0x3a5a54, "spread": 0.1, "speed": 0.1, "up": -0.3, "life": 0.6, "size": 0.1, "gravity": 9})
		"mire_leech":
			var w := sin(_now_ms() / 85.0 + id * 1.7) * (1.0 if e.moving else 0.25)
			var k := e.scale
			v.c.root.scale = Vector3(k * (1.0 + 0.12 * w), k * (1.0 - 0.09 * w), k * (1.0 + 0.1 * w))
			v.c.root.rotation.z = 0.12 * w

# ----------------------------------------------------------------------------------------------------------------- events

func on_event(ev: Dictionary, lookup_corpse_facing: Callable = Callable()) -> void:
	match String(ev.get("t", "")):
		"spawn":
			_smoke({"x": ev.x, "y": 0.2, "z": ev.z, "count": 10, "color": 0x2a2230, "spread": 0.7, "speed": 1, "up": 0.9, "life": 1.3, "size": 1.2, "shrink": -1})
			_emit({"x": ev.x, "y": 0.1, "z": ev.z, "count": 4, "color": 0x5b2bb0, "spread": 0.5, "speed": 0.6, "up": 1.4, "life": 0.8, "size": 0.24})
			_decal({"tex": "cracks", "color": 0x7c3aed, "x": ev.x, "z": ev.z, "r": 1.6 if ev.get("elite", false) else 1.1, "rot": randf() * 6.0, "duration": 2.2, "opacity": 0.8, "growFrom": 0.3})
		"erupt":
			var dirt := _sp("enemy", "dirt")
			var r := float(ev.r)
			_emit({"x": ev.x, "y": 0.3, "z": ev.z, "count": 22, "color": dirt, "spread": r * 0.5, "speed": 3.2, "up": 3, "life": 0.7, "size": 0.2, "gravity": 10})
			_emit({"x": ev.x, "y": 0.4, "z": ev.z, "count": 8, "color": 0xe0d6c2, "spread": r * 0.4, "speed": 2.4, "up": 2.6, "life": 0.6, "size": 0.12, "gravity": 10})
			_smoke({"x": ev.x, "y": 0.3, "z": ev.z, "count": 5, "color": 0x2a1a10, "spread": r * 0.4, "speed": 1, "up": 0.6, "life": 1, "size": 1.1})
			_decal({"tex": "cracks", "color": dirt, "x": ev.x, "z": ev.z, "r": r, "rot": randf() * 6.0, "duration": 1.6, "opacity": 0.8, "growFrom": 0.6, "fadeOut": 0.5})
			_sfx("burst", ev.x, ev.z)
		"digIn":
			var v: View = _enemies.get(int(ev.id))
			if v != null:
				v.c.play_once("dig", 1.0, float(_burrow.digS))
			_smoke({"x": ev.x, "y": 0.2, "z": ev.z, "count": 4, "color": _sp("enemy", "dirt"), "spread": 0.5, "speed": 0.6, "up": 0.4, "life": 1, "size": 0.9})
		"unbind":
			var curse := _sp("enemy", "curse")
			var tx: float = ev.tx
			var tz: float = ev.tz
			if vfx != null:
				vfx.beam(Vector3(ev.x, 1.6, ev.z), func(): return Vector3(tx, 0.3, tz), curse, 0.06, float(_unbind.delayS))
			_decal({"tex": "sigil", "color": curse, "x": tx, "z": tz, "r": 1.0, "duration": float(_unbind.delayS) + 0.3, "opacity": 0.85, "spin": 2.5, "fadeOut": 0.3})
			_sfx("raise", tx, tz)
		"shieldBlock":
			var v2: View = _enemies.get(int(ev.id))
			var f := v2.facing if v2 != null else 0.0
			_emit({"x": ev.x + sin(f) * 0.6, "y": 1.1, "z": ev.z + cos(f) * 0.6, "count": 8, "color": _sp("enemy", "toll"), "spread": 0.15, "speed": 2.6, "up": 0.8, "life": 0.3, "size": 0.12, "gravity": 6})
			_sfx("tollSmall", ev.x, ev.z)
		"death":
			_on_death(ev)
		"corpse":
			_on_corpse(ev, lookup_corpse_facing)
		"corpseGone":
			_on_corpse_gone(ev)
		"detonated":
			if not ev.get("ok", false):
				return
			var cv: View = _corpses.get(int(ev.corpseId))
			if cv != null:
				cv.shattered = true
		"affix":
			_affix_moment(ev)
		"thrallGone":
			_on_thrall_gone(ev)
		"thrall":
			_sfx("thrallRise", ev.x, ev.z)
			var spirit := _sp("exhume", "spirit")
			_decal({"tex": "sigil", "color": spirit, "x": ev.x, "z": ev.z, "r": 1.4, "duration": 1.3, "opacity": 0.9, "growFrom": 0.2, "spin": 2.0})
			_emit({"x": ev.x, "y": 0.2, "z": ev.z, "count": 40, "color": spirit, "spread": 0.5, "speed": 0.6, "up": 3.6, "life": 1, "size": 0.36, "gravity": -0.6})
			_emit({"x": ev.x, "y": 0.2, "z": ev.z, "count": 16, "color": _sp("exhume", "beam"), "spread": 0.3, "speed": 0.3, "up": 5, "life": 0.7, "size": 0.22})
			_smoke({"x": ev.x, "y": 0.2, "z": ev.z, "count": 6, "color": 0x1c2a2a, "spread": 0.6, "speed": 0.8, "up": 0.8, "life": 1.2, "size": 1.2})
			if vfx != null:
				vfx.motifs.grave_dirt(ev.x, ev.z, {"r": 0.5, "n": 6, "up": 2.6, "origin": "thrall"})
				vfx.light_flash(Vector3(ev.x, 1.2, ev.z), DmFxData.hex(spirit), 22.0, 0.6)

func _on_death(ev: Dictionary) -> void:
	var id := int(ev.id)
	var v: View = _enemies.get(id)
	if v == null:
		return
	_enemies.erase(id)
	# The final blow sets a pale hit flash. This view becomes the corpse, so it no longer receives enemy flash updates.
	v.c.set_flash(0.0)
	if v.mound != null:
		v.mound.queue_free()
		v.mound = null
		v.c.root.visible = true
	_kill(v.elite_aura)
	_kill(v.aura_fx)
	_kill_affix_fx(v)
	if v.has_shroud and v.shroud < 1.0:
		v.c.set_opacity(1.0)
	if ev.get("def", "") == "wraith":
		# A wraith leaves no body: it thins to mist and sinks away.
		_emit({"x": ev.x, "y": 1.4, "z": ev.z, "count": 22, "color": 0xb9cbe6, "spread": 0.6, "speed": 0.9, "up": 1.2, "life": 1.1, "size": 0.3, "drag": 1})
		v.sink_t = 0.0
		_fading.append(v)
		return
	v.die_t = 0.0
	if not v.c.play_death():
		v.c.toppled = 0.0001
	_dying.append(v)
	_smoke({"x": ev.x, "y": 0.3, "z": ev.z, "count": 6, "color": 0x3b3440, "spread": 0.6, "speed": 0.8, "up": 0.4, "life": 1, "size": 1})
	if ev.get("elite", false):
		_emit({"x": ev.x, "y": 1, "z": ev.z, "count": 40, "color": 0xb58cff, "spread": 0.8, "speed": 3, "up": 2, "life": 1.1, "size": 0.35})
		if vfx != null:
			vfx.light_flash(Vector3(ev.x, 1.5, ev.z), DmFxData.hex(0xa26bff), 25.0, 0.5)

func _on_corpse(ev: Dictionary, lookup_corpse_facing: Callable) -> void:
	var c: DmSimCorpse = ev.corpse
	if c.echoOwner != "":
		return
	var best := -1
	var best_d := 1.2
	for i in _dying.size():
		var v: View = _dying[i]
		var d := sqrt((v.x - c.x) * (v.x - c.x) + (v.z - c.z) * (v.z - c.z))
		if v.def == c.enemy and d < best_d:
			best_d = d
			best = i
	if best >= 0:
		var v2: View = _dying[best]
		_dying.remove_at(best)
		v2.c.set_cast_shadow(false)
		_corpses[c.id] = v2
	else:
		# Corpse without a dying body (a sacrificed thrall, or a late join): lay one down.
		var slug: String = ENEMY_SLUG.get(c.enemy, "grave_robber")
		var cr := DmCreature.new(slug, {"tint": 0x8a8078 if c.enemy == "risen" else 0xffffff, "cast_shadow": false})
		cr.root.position = Vector3(c.x, 0.0, c.z)
		cr.root.rotation.y = float(lookup_corpse_facing.call(c)) if lookup_corpse_facing.is_valid() else c.facing
		cr.root.scale = Vector3.ONE * c.scale
		add_child(cr.root)
		var v3 := View.new()
		v3.c = cr
		v3.x = c.x
		v3.z = c.z
		v3.facing = c.facing
		v3.last_state = "corpse"
		v3.die_t = 5.0
		v3.has_settle = true
		v3.settle_t = NO_SETTLE
		if not cr.hold_last_frame("death"):
			cr.toppled = 1.0
		cr.set_cast_shadow(false)
		_corpses[c.id] = v3
	if c.kind == "toxic":
		_decal({"tex": "disc", "color": 0x6f8f3a, "x": c.x, "z": c.z, "r": 2.4 * c.scale, "duration": 5, "opacity": 0.35, "pulse": 6.0, "growFrom": 0.6})
	if c.kind != "resonant" and not _alive(_corpse_rings.get(c.id)):
		# Every fresh corpse is a necromancer's resource, and a toppled body is dark on dark ground: a faint pale ring marks it for the 26 s
		# it lasts. Capped so a wipe of 40 bodies does not add 40 draw calls.
		var live := 0
		for h in _corpse_rings.values():
			if _alive(h):
				live += 1
		var marsh := c.area == "fen"
		if live < CORPSE_MARKS_MAX:
			_corpse_rings[c.id] = _decal({"tex": "ring", "color": 0xffe6b0 if marsh else 0xd8cdf2, "x": c.x, "z": c.z, "r": (1.1 if marsh else 0.8) * maxf(1.0, c.scale), "duration": 26, "opacity": 0.85 if marsh else 0.4, "fadeIn": 0.8, "pulse": 2.0})
	if c.kind == "resonant":
		if not _alive(_corpse_rings.get(c.id)):
			_corpse_rings[c.id] = _decal({"tex": "ring", "color": 0xc6a4ff, "x": c.x, "z": c.z, "r": 1.2, "duration": 26, "opacity": 0.6, "pulse": 3.0})

func _on_corpse_gone(ev: Dictionary) -> void:
	var id := int(ev.id)
	_kill(_corpse_rings.get(id))
	_corpse_rings.erase(id)
	var v: View = _corpses.get(id)
	if v == null:
		return
	_corpses.erase(id)
	v.sink_t = 0.0
	_fading.append(v)
	match String(ev.get("reason", "")):
		"consumed":
			_emit({"x": v.x, "y": 0.4, "z": v.z, "count": 22, "color": _sp("exhume", "spirit"), "spread": 0.6, "speed": 0.8, "up": 2.6, "life": 0.9, "size": 0.35})
		"litany":
			_emit({"x": v.x, "y": 0.4, "z": v.z, "count": 18, "color": _sp("litany", "core"), "spread": 0.6, "speed": 0.8, "up": 2.2, "life": 0.8, "size": 0.35})
		"raised":
			_emit({"x": v.x, "y": 0.4, "z": v.z, "count": 18, "color": _sp("enemy", "rot"), "spread": 0.6, "speed": 0.8, "up": 2, "life": 1, "size": 0.35})
		"devoured":
			# Torn apart and swallowed: olive gore, no spirit left to rise.
			_emit({"x": v.x, "y": 0.4, "z": v.z, "count": 22, "color": _sp("affix", "drool"), "spread": 0.5, "speed": 1.6, "up": 1.4, "life": 0.7, "size": 0.26, "gravity": 5})
			_smoke({"x": v.x, "y": 0.3, "z": v.z, "count": 3, "color": 0x2b3317, "spread": 0.4, "speed": 0.6, "up": 0.4, "life": 1, "size": 1})
		"burst":
			if v.shattered:
				# Corpse Explosion: the body is blown apart (the blast VFX plays from the 'detonated' event).
				v.c.set_opacity(0.0)
				v.sink_t = 0.8
			else:
				_emit({"x": v.x, "y": 0.5, "z": v.z, "count": 20, "color": _sp("miasma", "rot"), "spread": 0.6, "speed": 2.5, "up": 1.5, "life": 0.7, "size": 0.3})

func _on_thrall_gone(ev: Dictionary) -> void:
	var id := int(ev.id)
	var v: View = _thralls.get(id)
	if v == null:
		return
	_thralls.erase(id)
	_kill(v.hex_fx)
	_kill(v.ring)
	v.sink_t = 0.0
	_fading.append(v)
	var reason := String(ev.get("reason", ""))
	_emit({"x": ev.x, "y": 0.8, "z": ev.z, "count": 30 if reason == "sacrificed" else 14, "color": 0xd8cfbd, "spread": 0.5, "speed": 2, "up": 1.2, "life": 0.8, "size": 0.25, "gravity": 3})
	# A thrall that falls comes apart: bone chips and a pale soul-light that lets go (quiet; thralls die constantly).
	if reason == "killed" and sqrt((ev.x - _focus_x) * (ev.x - _focus_x) + (ev.z - _focus_z) * (ev.z - _focus_z)) < 24.0:
		_sfx("thrallDeath", ev.x, ev.z)
	if reason != "sacrificed" and vfx != null:
		vfx.motifs.bone_splinters(ev.x, 0.7, ev.z, {"n": 4, "origin": "thrall"})
		vfx.motifs.soul_motes(ev.x, ev.z, 0xd8cfbd, {"r": 0.3, "n": 3, "y": 0.6, "up": 1.2, "origin": "thrall"})

## One-off affix beats reported by the host.
func _affix_moment(ev: Dictionary) -> void:
	var x: float = ev.x
	var z: float = ev.z
	match String(ev.affix):
		"bellTolled":
			var r := float(ev.get("r", 3.0))
			var bell := _sp("affix", "bell")
			_sfx("toll", x, z)
			for k in 3:
				_decal({"tex": "ring", "color": bell, "x": x, "z": z, "r": r * (0.75 + k * 0.2), "duration": 0.5, "opacity": 1.0 - k * 0.25, "growFrom": 0.15, "delay": k * 0.07})
			_emit({"x": x, "y": 0.8, "z": z, "count": 36, "color": bell, "spread": r * 0.3, "speed": 5, "up": 0.8, "life": 0.5, "size": 0.28})
			if vfx != null:
				vfx.light_flash(Vector3(x, 1.5, z), DmFxData.hex(bell), 30.0, 0.4)
		"hungering":
			var tx := float(ev.get("tx", x)) if ev.get("tx") != null else x
			var tz := float(ev.get("tz", z)) if ev.get("tz") != null else z
			var drool := _sp("affix", "drool")
			_sfx("raise", tx, tz)
			if vfx != null:
				vfx.beam(Vector3(tx, 0.3, tz), func(): return Vector3(x, 1.1, z), drool, 0.07, 0.45)
			_emit({"x": x, "y": 1.1, "z": z, "count": 14, "color": drool, "spread": 0.3, "speed": 0.8, "up": 0.4, "life": 0.8, "size": 0.2, "gravity": 4})
		"vengeful":
			var r2 := float(ev.get("r", 1.8)) if ev.get("r") != null else 1.8
			var veng := _sp("affix", "vengeful")
			_sfx("burst", x, z)
			_decal({"tex": "cracks", "color": veng, "x": x, "z": z, "r": r2 * 1.4, "rot": randf() * 6.0, "duration": 2, "opacity": 0.9, "growFrom": 0.3})
			_decal({"tex": "ring", "color": _sp("detonate", "ember"), "x": x, "z": z, "r": r2, "duration": 0.5, "opacity": 1, "growFrom": 0.2})
			_emit({"x": x, "y": 0.6, "z": z, "count": 40, "color": veng, "spread": 0.5, "speed": 3.5, "up": 2.2, "life": 0.8, "size": 0.3})
			_smoke({"x": x, "y": 0.4, "z": z, "count": 6, "color": _sp("detonate", "smoke"), "spread": 0.8, "speed": 1, "up": 0.8, "life": 1.2, "size": 1.3})
			if vfx != null:
				vfx.light_flash(Vector3(x, 1.2, z), DmFxData.hex(veng), 32.0, 0.5)

# ----------------------------------------------------------------------------------------------------------------- per-frame helpers

## React to hp lost since the last frame: a visual shove away from the hero (bigger for harder hits, smaller for heavy bodies and for an
## enemy mid-swing) and, for a heavy blow that leaves the target standing, a hitstop request.
func _on_hit(v: View, e: DmSimEnemy, fx0: float, fz0: float, near: bool) -> void:
	var prev := v.last_hp if v.has_last_hp else e.hp
	v.last_hp = e.hp
	v.has_last_hp = true
	var drop := prev - e.hp
	if drop <= 0.0 or not near or v.under or e.hp <= 0.0 or bool(_def(e.def).get("inert", false)):
		return
	var frac := drop / maxf(1.0, e.maxHp)
	var committed := e.state == "windup" or e.state == "channel"
	var imp := knock_impulse(frac * (0.4 if committed else 1.0), e.scale * e.scale, e.x - fx0, e.z - fz0)
	if v.kn == null:
		v.kn = {"x": 0.0, "z": 0.0, "vx": 0.0, "vz": 0.0}
	v.kn.vx += imp.x
	v.kn.vz += imp.y
	var dist := sqrt((e.x - fx0) * (e.x - fx0) + (e.z - fz0) * (e.z - fz0))
	if frac >= (HEAVY_HIT_ELITE if e.elite else HEAVY_HIT) and dist < HITSTOP_RANGE:
		if game != null and game.has_method("hitstop"):
			game.hitstop(hitstop_seconds(minf(1.0, frac * 1.6)))

## Dust puff where a body lands.
func _landing_dust(v: View) -> void:
	if absf(v.x - _focus_x) > 24.0 or absf(v.z - _focus_z) > 20.0:
		return
	var k := v.c.root.scale.x
	_smoke({"x": v.x, "y": 0.1, "z": v.z, "count": 3, "color": 0x5d544a, "spread": 0.45 * k, "speed": 0.7, "up": 0.25, "life": 0.8, "size": 0.9 * k})
	_emit({"x": v.x, "y": 0.1, "z": v.z, "count": 5, "color": 0x7a6f60, "spread": 0.4 * k, "speed": 1.1, "up": 0.7, "life": 0.4, "size": 0.1, "gravity": 8})

## Death settle: once the fall has mostly played the body lands (dust) and eases a little way into the ground.
func _settle(v: View, dt: float) -> void:
	if not v.has_settle:
		if not v.c.has_landed():
			return
		v.has_settle = true
		v.settle_t = 0.0
		v.settle_y = 0.0 if v.c.toppled > 0.0 else v.c.root.position.y
		_landing_dust(v)
	v.settle_t += dt
	var base := v.c.root.position.y if v.c.toppled > 0.0 else v.settle_y
	v.c.root.position.y = base - settle_depth(v.settle_t, SETTLE_DEPTH * v.c.root.scale.x)

func _topple(v: View, dt: float) -> void:
	if v.c.toppled <= 0.0:
		return
	v.c.toppled = minf(1.0, v.c.toppled + dt * 3.0)
	v.c.root.rotation.z = (PI / 2.0) * v.c.toppled
	v.c.root.position.y = 0.2 * v.c.toppled

func _measure_speed(v: View, x: float, z: float, dt: float) -> void:
	var inst := step_speed(x - v.x, z - v.z, dt)
	v.gs = smooth_speed(v.gs if v.has_gs else inst, inst, dt, 0.18)
	v.has_gs = true

func _shadow_lod(enemies: Dictionary, fx0: float, fz0: float) -> void:
	var ranked: Array = []
	for id in enemies:
		var v: View = _enemies.get(id)
		if v == null:
			continue
		var e: DmSimEnemy = enemies[id]
		ranked.append([(e.x - fx0) * (e.x - fx0) + (e.z - fz0) * (e.z - fz0), v])
	ranked.sort_custom(func(a, b): return a[0] < b[0])
	var budget := CROWDED_SHADOW_CASTERS if enemies.size() >= 32 else SHADOW_CASTERS
	for i in ranked.size():
		(ranked[i][1] as View).c.set_cast_shadow(i < budget)

func _tick_anim(v: View, dt: float, fx0: float, fz0: float, crowded: bool) -> void:
	# Animation LOD by distance from the camera focus: near bodies update every frame, mid-distance ~24 Hz, far or off-screen ~10 Hz.
	# Skipped time accumulates so motion stays correct; a swing or cast always runs at full rate.
	v.anim_dt += dt
	var interval := anim_interval(absf(v.x - fx0), absf(v.z - fz0), v.c.busy(), crowded)
	if v.anim_dt < interval:
		return
	v.c.steady_every = 1 if interval == 0.0 else 2
	v.c.update(v.anim_dt)
	v.anim_dt = 0.0

## Slide drawn bodies apart where the sim leaves them overlapping (crowdSeparation.ts): eased, capped, drawn position only.
func _separate_crowd(enemies: Dictionary, thralls: Dictionary, dt: float, fx0: float, fz0: float) -> void:
	_crowd_accum += dt
	var k := minf(1.0, dt * CROWD_EASE)
	var every := 1.0 / 20.0 if _crowd_size > 30 else 1.0 / 30.0
	if _crowd_accum >= every:
		_crowd_accum = 0.0
		_solve_crowd(enemies, thralls, fx0, fz0)
	for map in [_enemies, _thralls]:
		for v: View in map.values():
			var tx := v.tox if v.in_crowd else 0.0
			var tz := v.toz if v.in_crowd else 0.0
			if v.ox == 0.0 and v.oz == 0.0 and tx == 0.0 and tz == 0.0:
				continue
			# Bodies that left the crowd (far away, burrowed, rising) ease back to their sim spot.
			v.ox += (tx - v.ox) * k
			v.oz += (tz - v.oz) * k
			if not v.in_crowd and absf(v.ox) < 1e-3 and absf(v.oz) < 1e-3:
				v.ox = 0.0
				v.oz = 0.0
			v.c.root.position.x += v.ox
			v.c.root.position.z += v.oz

func _solve_crowd(enemies: Dictionary, thralls: Dictionary, fx0: float, fz0: float) -> void:
	_crowd.clear()
	_crowd_views.clear()
	_crowd.append([fx0, fz0, 0.45, 0.0])   # body 0 is the hero: an obstacle that never yields
	for v: View in _enemies.values():
		v.in_crowd = false
	for v: View in _thralls.values():
		v.in_crowd = false
	var near := func(x: float, z: float) -> bool: return absf(x - fx0) < 22.0 and absf(z - fz0) < 18.0
	for id in enemies:
		var v: View = _enemies.get(id)
		var e: DmSimEnemy = enemies[id]
		if v == null or v.under or e.state == "rising" or e.state == "burrow" or e.state == "dead" or not near.call(e.x, e.z):
			continue
		if _crowd.size() > MAX_CROWD:
			break
		_crowd.append([e.x, e.z, e.radius * CROWD_FOOTPRINT, 0.0 if bool(_def(e.def).get("inert", false)) else 1.0])
		_crowd_views.append(v)
	for id in thralls:
		var v2: View = _thralls.get(id)
		var t: DmSimThrall = thralls[id]
		if v2 == null or t.state == "rising" or not near.call(t.x, t.z):
			continue
		if _crowd.size() > MAX_CROWD:
			break
		var sc: float = float((THRALL_LOOK.get(t.kind, {}) as Dictionary).get("scale", 1.1 if t.kind == "shieldbearer" else 1.0))
		_crowd.append([t.x, t.z, 0.4 * CROWD_FOOTPRINT * sc, 0.8])
		_crowd_views.append(v2)
	_crowd_size = _crowd.size()
	_separate_bodies(_crowd, _crowd_out, 2, 0.55)
	for i in range(1, _crowd.size()):
		var vv: View = _crowd_views[i - 1]
		vv.in_crowd = true
		vv.tox = _crowd_out[i * 2]
		vv.toz = _crowd_out[i * 2 + 1]

## crowdSeparation.separateBodies: pairs push apart along their line of centres in proportion to how much each yields.
func _separate_bodies(bodies: Array, out: PackedFloat32Array, iterations: int, max_offset: float) -> void:
	var n := bodies.size()
	var fit := 0.95
	var px := PackedFloat64Array()
	var pz := PackedFloat64Array()
	px.resize(n)
	pz.resize(n)
	for i in n:
		px[i] = bodies[i][0]
		pz[i] = bodies[i][1]
	for it in iterations:
		for i in n:
			var a: Array = bodies[i]
			for j in range(i + 1, n):
				var b: Array = bodies[j]
				var mn: float = (a[2] + b[2]) * fit
				var dx := px[j] - px[i]
				var dz := pz[j] - pz[i]
				if dx > mn or dx < -mn or dz > mn or dz < -mn:
					continue
				var d := sqrt(dx * dx + dz * dz)
				if d >= mn:
					continue
				var nx := dx / d if d > 0.0 else 0.0
				var nz := dz / d if d > 0.0 else 0.0
				if d < 1e-4:
					var ang := fmod(i * 12.9898 + j * 78.233, TAU)
					nx = cos(ang)
					nz = sin(ang)
				var total: float = a[3] + b[3]
				if total <= 0.0:
					continue
				var push := mn - d
				var pa: float = (a[3] / total) * push
				var pb: float = (b[3] / total) * push
				px[i] -= nx * pa
				pz[i] -= nz * pa
				px[j] += nx * pb
				pz[j] += nz * pb
	for i in n:
		var ox: float = px[i] - bodies[i][0]
		var oz: float = pz[i] - bodies[i][1]
		var l := sqrt(ox * ox + oz * oz)
		if l > max_offset:
			ox *= max_offset / l
			oz *= max_offset / l
		out[i * 2] = ox
		out[i * 2 + 1] = oz

# ----------------------------------------------------------------------------------------------------------------- sync

## Create / update / retire the views. enemies: id -> DmSimEnemy, thralls: id -> DmSimThrall. fx/fz = the camera focus (the hero).
func sync(enemies: Dictionary, thralls: Dictionary, dt: float, focus_x: float, focus_z: float) -> void:
	if not _topup.is_empty() and enemies.size() < 40:
		_pump_topup()
	_frame += 1
	if vfx != null:
		DmCreature.hitstop_scale = float(vfx.hitstop_scale)
	var crowded := enemies.size() + thralls.size() >= 32
	if _frame % 10 == 0:
		_shadow_lod(enemies, focus_x, focus_z)
	var now := _now_ms()
	for id in enemies:
		var e: DmSimEnemy = enemies[id]
		var v: View = _enemies.get(id)
		if v == null:
			v = _make_enemy(e)
			_enemies[id] = v
		_measure_speed(v, e.x, e.z, dt)
		v.x = e.x
		v.z = e.z
		v.facing = turn_toward(v.facing, e.facing, dt, 10.0, ENEMY_TURN_RATE)
		var rise := minf(1.0, e.stateT / 1.1) if e.state == "rising" else 1.0
		var def := _def(e.def)
		var flying: Variant = def.get("flying")
		var hover: float = float(flying) if flying != null else float(HOVER.get(e.def, 0.0))
		var lift := 0.0
		if hover > 0.0:
			lift = hover + sin(now / 520.0 + id) * (0.18 if flying != null else 0.12)
		if def.has("dive") and e.diving:
			# Belfry Gargoyle dive: climb over the mark for the first half, then drop onto it.
			var kk := minf(1.0, e.stateT / ((float(def.windupMs) / 1000.0) * (0.85 if e.elite else 1.0)))
			lift = hover + kk * 3.0 if kk < 0.5 else (hover + 1.5) * pow(1.0 - (kk - 0.5) * 2.0, 2.0)
		elif def.has("dive") and e.state == "recover":
			lift = 0.05
		v.c.root.position = Vector3(e.x, -1.7 * (1.0 - rise) * (1.0 - rise) + lift, e.z)
		v.c.root.rotation.y = v.facing
		v.c.set_flash(e.flash)
		var key := "dive" if e.diving else (e.state if (e.state == "windup" or e.state == "channel") else ("walk" if e.moving else "idle"))
		if key != v.last_state:
			if key == "dive":
				v.c.play_once("dive", 1.0, (float(def.windupMs) / 1000.0) * 1.2)
			elif key == "windup" or key == "channel":
				var cast := CASTERS.has(e.def)
				# The sim lands the blow when the wind-up ends: time the swing's impact frame to it.
				if key == "windup":
					v.c.play_strike("cast" if cast else "attack", (float(def.windupMs) / 1000.0) * (0.85 if e.elite else 1.0))
				else:
					v.c.play_once("cast" if cast else "attack", 1.3 if cast else 1.6)
			elif key == "walk":
				v.gs = e.speed   # start the legs at the pace the sim is about to move the body
				v.has_gs = true
				v.c.set_ground_speed(e.speed)
			else:
				v.c.set_loop("idle")
			v.last_state = key
		elif key == "walk":
			v.c.set_ground_speed(v.gs if v.has_gs else e.speed)
		var near_fx := absf(e.x - focus_x) < 24.0 and absf(e.z - focus_z) < 20.0
		# A fresh hit makes the body flinch (throttled per enemy, near the camera only).
		var fresh := e.flash > 0.9 and v.last_flash < 0.5
		v.last_flash = e.flash
		_on_hit(v, e, focus_x, focus_z, near_fx)
		if fresh and near_fx and not v.under and now >= v.flinch_at and v.c.has("hurt") and _allow_burst():
			v.flinch_at = now + 700.0
			v.c.flinch()
		_tick_anim(v, dt, focus_x, focus_z, crowded)
		if near_fx and FIRE_DEAD.has(e.def):
			_fire_dead(e, dt, fresh)
		if near_fx and FEN_DEAD.has(e.def):
			_fen_dead(e, dt, lift, id, v)
		if near_fx and e.withered > 0.0 and randf() < dt * (1.0 + e.withered * 0.75):
			_emit({"x": e.x, "y": 0.8 + randf() * 0.8, "z": e.z, "count": 1, "color": _sp("miasma", "rot"), "spread": 0.4, "speed": 0.2, "up": 0.7, "life": 0.9, "size": 0.2})
		if near_fx and e.fracture > 0.0 and randf() < dt * 1.5 * e.fracture:
			_emit({"x": e.x, "y": 1.2, "z": e.z, "count": 1, "color": _sp("needle", "dust"), "spread": 0.3, "speed": 0.6, "up": 0.4, "life": 0.5, "size": 0.1, "gravity": 5})
		# Status tells: marrow drips, frost motes, a priest-gold glint.
		if near_fx and e.bleedT > 0.0 and randf() < dt * 4.0:
			_emit({"x": e.x, "y": 0.7 + randf() * 0.6, "z": e.z, "count": 1, "color": _st("hemorrhage", "crimson") if randf() < 0.7 else _st("hemorrhage", "ember"), "spread": 0.3, "speed": 0.1, "up": -0.2, "life": 0.6, "size": 0.12, "gravity": 8})
		if near_fx and e.chillT > 0.0 and randf() < dt * 3.0:
			_emit({"x": e.x, "y": 0.3 + randf() * 1.2, "z": e.z, "count": 1, "color": _st("chill", "frost"), "spread": 0.45, "speed": 0.15, "up": 0.2, "life": 0.8, "size": 0.14, "drag": 0.5})
		if near_fx and e.sanctT > 0.0 and randf() < dt * 2.0:
			_emit({"x": e.x, "y": 1.9 * e.scale, "z": e.z, "count": 1, "color": _st("sanctified", "gold"), "spread": 0.35, "speed": 0.1, "up": 0.5, "life": 0.7, "size": 0.16})
		# A frenzied Flagellant sheds blood motes (hp below half; mirrors see the same hp).
		if near_fx and def.get("frenzy") != null and e.hp < e.maxHp * 0.5 and randf() < dt * 5.0:
			_emit({"x": e.x, "y": 1.1, "z": e.z, "count": 1, "color": 0x9a1b2a, "spread": 0.3, "speed": 0.4, "up": 0.4, "life": 0.5, "size": 0.14, "gravity": 6})
		# Incensed (a Censer Bearer's aura): bronze motes drifting off the shoulders.
		if near_fx and e.incenseT > 0.0 and randf() < dt * 3.0:
			_emit({"x": e.x, "y": 1.2 * e.scale, "z": e.z, "count": 1, "color": _st("incensed", "bronze"), "spread": 0.4, "speed": 0.2, "up": 0.6, "life": 0.8, "size": 0.14})
		# The Censer Bearer itself trails incense smoke and wears its aura on the ground.
		if bool(def.get("aura", false)):
			if v.aura_fx == null:
				v.aura_fx = _decal({"danger": true, "tex": "ring", "color": _st("incensed", "bronze"), "x": e.x, "z": e.z, "r": float(_censer.radius), "duration": 1e9, "opacity": 0.22, "pulse": 2.5, "follow": _follow(v)})
			if near_fx and randf() < dt * 2.0:
				_smoke({"x": e.x, "y": 1.1, "z": e.z, "count": 1, "color": _st("incensed", "smoke"), "spread": 0.3, "speed": 0.3, "up": 0.5, "life": 1.4, "size": 0.9, "shrink": -0.5})
		if near_fx and hover > 0.0 and randf() < dt * 4.0:
			_emit({"x": e.x, "y": lift + 0.2, "z": e.z, "count": 1, "color": 0xb9cbe6, "spread": 0.35, "speed": 0.1, "up": -0.3, "life": 0.7, "size": 0.18})
		# Barrow Ghoul: underground from 'burrow' until its eruption windup ends (the mirror sees only states).
		if e.state == "burrow":
			v.under = true
		elif v.under and e.state != "windup":
			v.under = false
		if v.under:
			if v.mound == null:
				v.mound = _make_mound()
				add_child(v.mound)
			v.mound.position = Vector3(e.x, 0.0, e.z)
			v.mound.rotation.y = v.facing
			v.c.root.visible = false
			if near_fx and e.moving and randf() < dt * 7.0:
				_emit({"x": e.x, "y": 0.15, "z": e.z, "count": 2, "color": _sp("enemy", "dirt"), "spread": 0.35, "speed": 0.9, "up": 1.2, "life": 0.4, "size": 0.12, "gravity": 9})
		elif v.mound != null:
			v.mound.queue_free()
			v.mound = null
			v.c.root.visible = true
		# Lich Acolyte: its crimson reach shows only while one of your thralls stands inside it.
		if bool(def.get("unbind", false)):
			var any := false
			var rng := float(_unbind.range)
			for t: DmSimThrall in thralls.values():
				if absf(t.x - e.x) < rng and sqrt((t.x - e.x) * (t.x - e.x) + (t.z - e.z) * (t.z - e.z)) <= rng:
					any = true
					break
			if any and v.aura_fx == null:
				v.aura_fx = _decal({"danger": true, "tex": "ring", "color": _sp("enemy", "curse"), "x": e.x, "z": e.z, "r": rng, "duration": 1e9, "opacity": 0.15, "pulse": 1.5, "follow": _follow(v)})
			elif not any and v.aura_fx != null:
				_kill(v.aura_fx)
				v.aura_fx = null
		if near_fx and e.state == "rising" and randf() < dt * 8.0:
			_smoke({"x": e.x, "y": 0.1, "z": e.z, "count": 1, "color": 0x2a2230, "spread": 0.5, "speed": 0.5, "up": 0.6, "life": 1, "size": 0.9})
		# A mirror may learn the affix after the view exists (late snapshot field).
		if e.affix != "" and v.affix == "":
			_dress_affix(v, e)
		if v.affix != "":
			_tick_affix(v, e, dt, near_fx)
	# Enemies that vanished without a death event (mirror resync, area clear).
	for id in _enemies.keys():
		if not enemies.has(id):
			var gone: View = _enemies[id]
			_enemies.erase(id)
			if gone.mound != null:
				gone.mound.queue_free()
				gone.mound = null
			_kill(gone.elite_aura)
			_kill(gone.aura_fx)
			_kill_affix_fx(gone)
			gone.sink_t = 0.0
			_fading.append(gone)

	for id in thralls:
		var t: DmSimThrall = thralls[id]
		var tv: View = _thralls.get(id)
		if tv == null:
			tv = _make_thrall(t)
			_thralls[id] = tv
		_measure_speed(tv, t.x, t.z, dt)
		tv.x = t.x
		tv.z = t.z
		tv.facing = turn_toward(tv.facing, t.facing, dt, 10.0, ENEMY_TURN_RATE)
		var trise := minf(1.0, t.stateT / 0.9) if t.state == "rising" else 1.0
		var thover := 0.25 + sin(now / 400.0 + id) * 0.1 if tv.is_float else 0.0
		tv.c.root.position = Vector3(t.x, -1.8 * (1.0 - trise) * (1.0 - trise) + thover, t.z)
		tv.c.root.rotation.y = tv.facing
		tv.c.set_flash(t.flash)
		# A snapshot-mirrored legion (co-op guest) can still blink `moving` for a tick; walk -> idle needs it to stay off for a moment.
		tv.move_hold_t = THRALL_MOVE_HOLD_S if t.moving else maxf(0.0, tv.move_hold_t - dt)
		var tkey := "attack" if (t.state == "attack" and t.stateT < 0.1) else ("move" if (t.moving or (tv.move_hold_t > 0.0 and tv.last_state == "move")) else "idle")
		# A thrall's hit applies the instant its attack starts: open the swing just before its impact frame.
		if tkey == "attack" and tv.last_state != "attack":
			tv.c.play_strike("attack", 0.12)
		elif tkey == "move" and tv.last_state != "move":
			tv.gs = t.speed
			tv.has_gs = true
			tv.c.set_ground_speed(t.speed)
		elif tkey == "move":
			tv.c.set_ground_speed(tv.gs if tv.has_gs else t.speed)
		elif tkey == "idle" and tv.last_state != "idle":
			tv.c.set_loop("idle")
		tv.last_state = tkey
		# A Bog Hag's hex: a magenta sigil ring follows the thrall and sickly motes drip off it while it lasts.
		if t.cursedT > 0.0:
			if not _alive(tv.hex_fx):
				tv.hex_fx = _decal({"danger": true, "tex": "sigil", "color": _sp("enemy", "hex"), "x": t.x, "z": t.z, "r": 0.95, "duration": 1e9, "opacity": 0.9, "spin": 2.0, "follow": _follow(tv)})
			if absf(t.x - focus_x) < 24.0 and absf(t.z - focus_z) < 20.0 and randf() < dt * 5.0:
				_emit({"x": t.x, "y": 0.9 + randf() * 0.8, "z": t.z, "count": 1, "color": _sp("enemy", "hex"), "spread": 0.25, "speed": 0.15, "up": -0.5, "life": 0.7, "size": 0.12, "gravity": 4})
		elif tv.hex_fx != null:
			_kill(tv.hex_fx)
			tv.hex_fx = null
		_tick_anim(tv, dt, focus_x, focus_z, crowded)
	for id in _thralls.keys():
		if not thralls.has(id):
			var tg: View = _thralls[id]
			_thralls.erase(id)
			_kill(tg.hex_fx)
			_kill(tg.ring)
			tg.sink_t = 0.0
			_fading.append(tg)

	_separate_crowd(enemies, thralls, dt, focus_x, focus_z)
	_focus_x = focus_x
	_focus_z = focus_z
	# Knockback springs ride on top of the crowd offset (drawn position only), frozen along with everything else in a hitstop.
	for v: View in _enemies.values():
		if v.kn == null or not knock_active(v.kn):
			continue
		step_knock(v.kn, dt * DmCreature.hitstop_scale)
		v.c.root.position.x += v.kn.x
		v.c.root.position.z += v.kn.z

	for i in range(_dying.size() - 1, -1, -1):
		var d: View = _dying[i]
		d.die_t += dt
		d.c.update(dt)
		_topple(d, dt)
		_settle(d, dt)
		# No corpse arrived (corpse kind "none"): crumble away.
		if d.die_t > 1.4:
			_dying.remove_at(i)
			d.sink_t = 0.0
			_fading.append(d)
	for cv: View in _corpses.values():
		cv.die_t += dt
		# A corpse's mixer stops shortly after its death clip has landed (the settle ease carries the rest).
		if cv.die_t < CORPSE_ANIM_S and cv.rest_t < CORPSE_REST_S:
			cv.c.update(dt)
			if cv.c.has_landed():
				cv.rest_t += dt
		_topple(cv, dt)
		if not (cv.has_settle and cv.settle_t == NO_SETTLE):
			_settle(cv, dt)
	for i in range(_fading.size() - 1, -1, -1):
		var f: View = _fading[i]
		f.sink_t += dt
		f.c.root.position.y -= dt * 1.3
		f.c.set_opacity(maxf(0.0, 1.0 - f.sink_t / 0.9))
		if f.sink_t > 0.9:
			if f.mound != null:
				f.mound.queue_free()
				f.mound = null
			_retire(f.c)
			_fading.remove_at(i)

## Drop corpse bodies the authority no longer has (resync after migration / drift).
func prune_corpses(valid: Dictionary) -> void:
	for id in _corpses.keys():
		if valid.has(id):
			continue
		var v: View = _corpses[id]
		_corpses.erase(id)
		v.sink_t = 0.0
		_fading.append(v)

## World position of a live enemy for screen-space picking (null when it has no view).
func enemy_anchor(id: int) -> Variant:
	var v: View = _enemies.get(id)
	return Vector3(v.x, 1.0, v.z) if v != null else null

func counts() -> Dictionary:
	return {"enemies": _enemies.size(), "thralls": _thralls.size(), "corpses": _corpses.size(), "dying": _dying.size(), "fading": _fading.size()}

## Enemy body pool (QA/perf): bodies waiting, spawns served from the pool vs new instances.
func pool_counts() -> Dictionary:
	var pooled := 0
	for key in _pool:
		pooled += (_pool[key] as Array).size()
	return {"pooled": pooled, "pool_hits": pool_hits, "pool_misses": pool_misses}

## QA/test accessors.
func enemy_view(id: int) -> Variant:
	var v: View = _enemies.get(id)
	return v.c if v != null else null

func thrall_view(id: int) -> Variant:
	var v: View = _thralls.get(id)
	return v.c if v != null else null

func dispose() -> void:
	for h in _corpse_rings.values():
		_kill(h)
	_corpse_rings.clear()
	for map in [_enemies, _thralls, _corpses]:
		for v: View in map.values():
			v.c.dispose()
			if v.mound != null:
				v.mound.queue_free()
		map.clear()
	for list in [_dying, _fading]:
		for v: View in list:
			v.c.dispose()
		list.clear()
	for key in _pool:
		for c: DmCreature in _pool[key]:
			c.dispose()
	_pool.clear()
	if is_inside_tree():
		get_parent().remove_child(self)
	queue_free()
