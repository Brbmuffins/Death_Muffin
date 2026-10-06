class_name DmEnemyFx
extends Node
## The visuals and sounds of the rebuilt enemies (godot/enemies), on every peer: host, clients and solo go through the same code.
## See README.md for the contract. In short: add one to the scene, `setup()` it, and it watches every DmEnemy (node_added) and DmHostileZone.
##
## Exactly once per event per peer: everything is driven by signals each peer's own DmEnemy emits once (`telegraph`, `damaged`, `state_changed`,
## a puppet derives the same signals from the replicated snapshot, see DmEnemy.apply_net_state). The host-only `struck` and `cue`
## signals are deliberately NOT used: a client never sees them. The impact of a swing is a timer started when ATTACK begins (wind-up length is
## the same everywhere) and cancelled if the swing is interrupted.
##
## The look and sound are the current game's: telegraph shapes/colours come from DmEventFxTelegraph (the same module DmEventFx.handle uses),
## death/voices from DmEventFx, spawn/elite/censer/eruption beats from DmEntityViews. No new effect ids, textures or sounds, so DmWarmup's
## existing pass already covers everything (EFFECT_IDS lists the Binbun ids used, SFX_IDS the sounds). Particle bursts and decals go through
## the pooled Vfx rings, so nothing here allocates per particle; per-frame work is one pass over the watched enemies every AMBIENT_S.

const AMBIENT_S := 0.2
const NEAR_X := 24.0               ## ambient motes only near the hero (DmEntityViews near_fx)
const NEAR_Z := 20.0
const ELITE_AGGRO_RANGE := 40.0
const ELITE_COLOR := 0x9b5cff
const EFFECT_IDS: Array[String] = ["censer_incense", "vengeful_burst", "surge_eruption", "bonfire"]
const SFX_IDS: Array[String] = ["eliteAggro", "eliteDeath", "enemyDeath", "tellStrike", "tollSmall", "burst", "boneHit",
	"enemyAttackBeast", "enemyAttackHumanoid", "enemyAttackBrute", "enemyAttackSpirit",
	"enemyDeathBeast", "enemyDeathHumanoid", "enemyDeathBrute", "enemyDeathSpirit", "emberThrow", "emberBurst", "slagSlam", "curse"]
const FIRE_DEFS: Array[String] = ["cinder_husk", "pyre_priest", "cinderhound", "slag_brute"]   ## the Cinder Pyre's dead: sparks, soot, ember tells
const FEN_DEFS: Array[String] = ["fen_wisp", "bog_hag", "drowned_sexton", "mire_leech"]
const FEN_TEAL := 0x7fe0d0
const WRAITH_DEFS: Array[String] = ["wraith"]    ## leave no body: they thin to mist and sink

var vfx: Node                      ## the Vfx autoload (tests pass a counting stub)
var audio: Node                    ## the AudioDirector autoload (ditto)
var fx: DmEventFx                  ## the shared router half: telegraphs, deaths, voices, zone visuals
var host := DmEnemyFxHost.new()
var player_pos := Callable()       ## () -> Vector3, the local hero; default: the camera's ground point
var auto_watch := true
var scope: Node = null             ## only watch enemies / zones under this node (null = the whole tree); lets two peers share one test tree
var stats := {"spawn": 0, "telegraph": 0, "strike": 0, "hit": 0, "death": 0, "erupt": 0, "dig": 0, "zone": 0}

class DefStub:
	extends RefCounted
	var def: String = ""


class Slot:
	extends RefCounted
	var e: DmEnemy
	var strike_at := -1.0          ## game-clock ms when the current swing lands, -1 = none
	var follow: Callable
	var aura: Variant = null       ## elite ring / censer ground ring
	var incense: Variant = null    ## censer_incense Binbun handle
	var conns: Array = []          ## [Signal, Callable] pairs to disconnect on exit

var _slots: Dictionary = {}        ## instance id -> Slot
var _clock := 0.0
var _amb_t := 0.0
var _tele := {}                    ## scratch telegraph event, reused (the router reads it synchronously)
var _tele_call := Callable()
var _death_ev := {}
var _zone := DmSimZone.new()
var _px := 0.0
var _pz := 0.0
var _amb_dust := {"x": 0.0, "y": 0.1, "z": 0.0, "count": 1, "color": 0x2a2230, "spread": 0.5, "speed": 0.5, "up": 0.6, "life": 1, "size": 0.9}
var _amb_mote := {"x": 0.0, "y": 0.0, "z": 0.0, "count": 1, "color": 0xb9cbe6, "spread": 0.35, "speed": 0.1, "up": -0.3, "life": 0.7, "size": 0.18}
var _pf := {"x": 0.0, "y": 0.0, "z": 0.0, "count": 1, "color": 0, "spread": 0.3, "speed": 0.2, "up": 1.0, "life": 0.8, "size": 0.1}   ## scratch for the pyre / fen tells
var _stub := DefStub.new()          ## stands in for the sim enemy record the telegraph router looks the def up in (slag brute's slam)
var _amb_dirt := {"x": 0.0, "y": 0.15, "z": 0.0, "count": 2, "color": 0xffffff, "spread": 0.35, "speed": 0.9, "up": 1.2, "life": 0.4, "size": 0.12, "gravity": 9}


func _ready() -> void:
	DmSimData.ensure()
	var root := get_tree().root
	if vfx == null:
		vfx = root.get_node_or_null("Vfx")
	if audio == null:
		audio = root.get_node_or_null("AudioDirector")
	_rebuild_router()
	if auto_watch:
		get_tree().node_added.connect(_on_node_added)
		for n in get_tree().get_nodes_in_group(&"dm_enemy"):
			_on_node_added(n)
		for n in get_tree().get_nodes_in_group(&"dm_hostile_zone"):
			_on_node_added(n)


## (Re)create the shared router against the current vfx / audio (tests swap them in before the first event).
func _rebuild_router() -> void:
	fx = DmEventFx.new()
	fx.setup(host)
	fx.vfx = vfx
	fx.audio = audio
	_tele_call = fx.telegraph_fx.telegraph.bind(_tele)
	_amb_dirt["color"] = fx.sp("enemy", "dirt")


## Use these instead of the autoloads (counting back-ends in tests).
func set_backends(p_vfx: Node, p_audio: Node) -> void:
	vfx = p_vfx
	audio = p_audio
	_rebuild_router()


func _on_node_added(n: Node) -> void:
	if scope != null and not scope.is_ancestor_of(n):
		return
	if n is DmEnemy:
		watch(n)
	elif n is DmHostileZone:
		_on_zone(n)


# ============================================================================================ watching

func watch(e: DmEnemy) -> void:
	if e == null or _slots.has(e.get_instance_id()):
		return
	var s := Slot.new()
	s.e = e
	s.follow = _pos_of.bind(e.get_instance_id())   # by id, never a lambda capturing the node (it can be freed under a live decal)
	_slots[e.get_instance_id()] = s
	_link(s, e.telegraph, _on_telegraph.bind(e))
	_link(s, e.damaged, _on_damaged.bind(e))
	_link(s, e.cue, _on_cue.bind(e))
	_link(s, e.state_changed, _on_state.bind(e))
	_link(s, e.tree_exiting, _on_exit.bind(e))
	if e.is_node_ready():
		_on_ready(e)
	else:
		_link(s, e.ready, _on_ready.bind(e))


func _link(s: Slot, sig: Signal, cb: Callable) -> void:
	sig.connect(cb)
	s.conns.append([sig, cb])


func _pos_of(id: int) -> Variant:
	var s: Slot = _slots.get(id)
	if s == null or not is_instance_valid(s.e) or s.e.sm == null or s.e.sm.id() == DmEnemyState.Id.DEAD:
		return null
	return Vector3(s.e.global_position.x, 0.0, s.e.global_position.z)


func watched() -> int:
	return _slots.size()


## Stop watching (the enemy is leaving the tree): kill what it wore, disconnect.
func _on_exit(e: DmEnemy) -> void:
	var s: Slot = _slots.get(e.get_instance_id())
	if s == null:
		return
	_slots.erase(e.get_instance_id())
	_kill(s.aura)
	_kill(s.incense)
	for c in s.conns:
		if (c[0] as Signal).is_connected(c[1]):
			(c[0] as Signal).disconnect(c[1])
	s.conns.clear()


func clear() -> void:
	for s in _slots.values().duplicate():
		_on_exit((s as Slot).e)
	fx.clear()


static func _kill(h: Variant) -> void:
	if h != null:
		h.kill()


# ============================================================================================ events

## Spawn / rise, elite ring, censer aura. Runs once, when the enemy's own _ready has finished (def and stats are loaded).
func _on_ready(e: DmEnemy) -> void:
	var s: Slot = _slots.get(e.get_instance_id())
	if s == null:
		return
	var p := e.global_position
	if e.rising:
		stats["spawn"] += 1
		vfx.emit_smoke({"x": p.x, "y": 0.2, "z": p.z, "count": 10, "color": 0x2a2230, "spread": 0.7, "speed": 1, "up": 0.9, "life": 1.3, "size": 1.2, "shrink": -1})
		vfx.emit({"x": p.x, "y": 0.1, "z": p.z, "count": 4, "color": 0x5b2bb0, "spread": 0.5, "speed": 0.6, "up": 1.4, "life": 0.8, "size": 0.24})
		vfx.decal({"tex": "cracks", "color": 0x7c3aed, "x": p.x, "z": p.z, "r": 1.6 if e.elite else 1.1, "rot": randf() * 6.0, "duration": 2.2, "opacity": 0.8, "growFrom": 0.3})
	if e.elite:
		if e.rising and _dist(p.x, p.z) < ELITE_AGGRO_RANGE:
			fx.snd("eliteAggro", p.x, p.z)
		s.aura = vfx.decal({"danger": true, "tex": "ring", "color": ELITE_COLOR, "x": p.x, "z": p.z, "r": 1.1 * e.scale.x,
			"duration": 1e9, "opacity": 0.8, "pulse": 4.0, "follow": s.follow})
	if bool(e.def.get("aura", false)):
		# The Censer Bearer's incense cloud (the ground ring, smoke and the hasted bodies' motes are the status track's DmStatusSet).
		s.incense = fx.bb("censer_incense", p.x, p.z, {"follow": s.follow})


## A ground telegraph (host: begin_attack / erupt enter; client: derived from the replicated state). The router draws the shape in
## the current game's colours and schedules its own landing flourishes; the sound is its `tellStrike` / `tollSmall`.
func _on_telegraph(kind: StringName, from: Vector3, aim: Vector3, radius: float, seconds: float, _e: DmEnemy) -> void:
	stats["telegraph"] += 1
	_tele["kind"] = String(kind)
	_tele["x"] = from.x
	_tele["z"] = from.z
	_tele["tx"] = aim.x
	_tele["tz"] = aim.z
	_tele["ms"] = seconds * 1000.0
	if radius > 0.0:
		_tele["r"] = radius
	else:
		_tele.erase("r")
	if _e != null:   # the router picks the Slag Brute's molten slam by the enemy's def: lend it a stub for this synchronous call
		_stub.def = _e.def_id
		_tele["id"] = -7
		host.mirror.enemies[-7] = _stub
	vfx.danger(_tele_call)
	if _e != null:
		host.mirror.enemies.erase(-7)
		_tele.erase("id")


## Host-side one-off cues. Only the Deacon's Sanctify: DmEventFx._sanctify's thread and halo (the blessed body's motes come from DmStatusSet).
func _on_cue(kind: StringName, at: Vector3, _radius: float, e: DmEnemy) -> void:
	if kind != &"sanctify":
		return
	var gold := fx.status_fx("sanctified", "gold")
	var p := e.global_position
	fx.beam(Vector3(p.x, 1.9, p.z), Vector3(at.x, 1.6, at.z), gold, 0.04, 0.5)
	fx.decal({"tex": "ring", "color": gold, "x": at.x, "z": at.z, "r": 1.1, "duration": 0.8, "opacity": 0.8, "growFrom": 1.8})


func _on_damaged(amount: float, _hp_left: float, from: Node, e: DmEnemy) -> void:
	stats["hit"] += 1
	var frac := amount / maxf(1.0, e.max_hp)
	var p := e.global_position
	if frac >= (DmEntityViews.HEAVY_HIT_ELITE if e.elite else DmEntityViews.HEAVY_HIT) and _dist(p.x, p.z) < DmEntityViews.HITSTOP_RANGE:
		host.hitstop(DmEntityViews.hitstop_seconds(minf(1.0, frac * 1.6)))


func _on_state(_prev: int, next: int, e: DmEnemy) -> void:
	var s: Slot = _slots.get(e.get_instance_id())
	if s == null:
		return
	s.strike_at = -1.0   # any change interrupts a swing in flight (stun, death); the swing's own end is handled by the timer
	match next:
		DmEnemyState.Id.ATTACK:
			s.strike_at = _clock + maxf(0.0, e.windup_s - e.net_age) * 1000.0
		DmEnemyState.Id.DEAD:
			_die(s, e)
		DmEnemyState.Id.EMERGE:
			_erupt(e)
		DmEnemyState.Id.DIG:
			stats["dig"] += 1
			var p := e.global_position
			vfx.emit_smoke({"x": p.x, "y": 0.2, "z": p.z, "count": 4, "color": fx.sp("enemy", "dirt"), "spread": 0.5, "speed": 0.6, "up": 0.4, "life": 1, "size": 0.9})


## The swing lands (timer): the enemy's voice, plus the kind's impact beat. Telegraph landings (rings, cracks, shakes) are the router's.
func _impact(s: Slot) -> void:
	var e := s.e
	stats["strike"] += 1
	var a := e.aim
	fx.foe_voice("attack", e.def_id, e.global_position.x, e.global_position.z, 18.0)
	if e is DmEnemyHazard:
		vfx.emit_smoke({"x": a.x, "y": 0.3, "z": a.z, "count": 4, "color": 0x3b3440, "spread": (e as DmEnemyHazard).slam_radius() * 0.45, "speed": 1.2, "up": 0.5, "life": 0.8, "size": 1.0})
		vfx.emit({"x": a.x, "y": 0.2, "z": a.z, "count": 10, "color": 0x8a8378, "spread": 0.8, "speed": 2.2, "up": 1.8, "life": 0.5, "size": 0.13, "gravity": 9})
		fx.snd("boneHit", a.x, a.z, 0.8)
	elif e is DmEnemyCaster:
		if (e as DmEnemyCaster).attack_kind == "dust":
			var r := float(DmSimData.DUST["radius"])
			var dust := fx.sp("enemy", "dust")
			vfx.emit({"x": a.x, "y": 0.4, "z": a.z, "count": 18, "color": dust, "spread": r * 0.5, "speed": 1.6, "up": 0.9, "life": 0.7, "size": 0.2, "drag": 0.5})
			vfx.decal({"tex": "ring", "color": dust, "x": a.x, "z": a.z, "r": r * 1.2, "duration": 0.45, "opacity": 0.9, "growFrom": 0.3})
			if not e.is_multiplayer_authority():
				# The host's strike spawned the damaging cloud; this peer gets the visual-only copy (REBUILD: zones are host-spawned).
				var zn := DmHostileZone.spawn(e.get_parent(), a, &"dust", r, float(DmSimData.DUST["cloudS"]), 0.0, e)
				zn.damaging = false
	else:
		vfx.emit_smoke({"x": a.x, "y": 0.3, "z": a.z, "count": 2, "color": 0x3a3340, "spread": 0.3, "speed": 0.8, "up": 0.3, "life": 0.5, "size": 0.6})
	if e.def_id == "cinder_husk" or e.def_id == "cinderhound" or e.def_id == "slag_brute":
		# The Pyre's dead strike in a shower of sparks (DmEventFx._melee).
		_pf["color"] = fx.sp("enemy", "emberCore")
		_pf_burst(a.x, 0.9, a.z, 0.3, 3.0, 1.6, 0.4, 0.1, 8.0, 12 if e.def_id == "slag_brute" else 7)
	e.on_impact_visual()


## One burst through the scratch dictionary: spread, speed, up, life, size, gravity (drag stays 0).
func _pf_burst(x: float, y: float, z: float, spread: float, speed: float, up: float, life: float, size: float, gravity: float, count: int = 1) -> void:
	_pf["count"] = count
	_pf["x"] = x
	_pf["y"] = y
	_pf["z"] = z
	_pf["spread"] = spread
	_pf["speed"] = speed
	_pf["up"] = up
	_pf["life"] = life
	_pf["size"] = size
	_pf["gravity"] = gravity
	vfx.emit(_pf)


func _erupt(e: DmEnemy) -> void:
	stats["erupt"] += 1
	var a := e.aim
	var dirt := fx.sp("enemy", "dirt")
	var r := float(DmSimData.BURROW["eruptR"])
	vfx.emit({"x": a.x, "y": 0.3, "z": a.z, "count": 22, "color": dirt, "spread": r * 0.5, "speed": 3.2, "up": 3, "life": 0.7, "size": 0.2, "gravity": 10})
	vfx.emit({"x": a.x, "y": 0.4, "z": a.z, "count": 8, "color": 0xe0d6c2, "spread": r * 0.4, "speed": 2.4, "up": 2.6, "life": 0.6, "size": 0.12, "gravity": 10})
	vfx.emit_smoke({"x": a.x, "y": 0.3, "z": a.z, "count": 5, "color": 0x2a1a10, "spread": r * 0.4, "speed": 1, "up": 0.6, "life": 1, "size": 1.1})
	vfx.decal({"tex": "cracks", "color": dirt, "x": a.x, "z": a.z, "r": r, "rot": randf() * 6.0, "duration": 1.6, "opacity": 0.8, "growFrom": 0.6, "fadeOut": 0.5})
	fx.snd("burst", a.x, a.z)


func _die(s: Slot, e: DmEnemy) -> void:
	stats["death"] += 1
	_kill(s.aura)
	_kill(s.incense)
	s.aura = null
	s.incense = null
	var p := e.global_position
	_death_ev["id"] = e.get_instance_id()
	_death_ev["x"] = p.x
	_death_ev["z"] = p.z
	_death_ev["elite"] = e.elite
	_death_ev["def"] = e.def_id
	fx._death(_death_ev)   # death + elite-death sound, death voice (<= 26 m), elite hitstop, water ripple, fire-death flare
	if bool(e.def.get("emberDeath", false)):   # the Cinder Husk's last embers (the pool itself is DmEnemyPfMelee's)
		_death_ev["kind"] = "ember"
		_death_ev["r"] = float(DmSimData.EMBER_DEATH["radius"])
		fx._burst(_death_ev)
		_death_ev.erase("kind")
		_death_ev.erase("r")
	if e.def_id in WRAITH_DEFS:
		vfx.emit({"x": p.x, "y": 1.4, "z": p.z, "count": 22, "color": 0xb9cbe6, "spread": 0.6, "speed": 0.9, "up": 1.2, "life": 1.1, "size": 0.3, "drag": 1})
		var vis := e.get_node_or_null("Visual") as Node3D
		if vis != null:
			var tw := e.create_tween()
			tw.tween_property(vis, "position:y", vis.position.y - 1.2, 1.1)
			tw.tween_callback(vis.hide)
		return
	vfx.emit_smoke({"x": p.x, "y": 0.3, "z": p.z, "count": 6, "color": 0x3b3440, "spread": 0.6, "speed": 0.8, "up": 0.4, "life": 1, "size": 1})
	if e.elite:
		vfx.emit({"x": p.x, "y": 1, "z": p.z, "count": 40, "color": 0xb58cff, "spread": 0.8, "speed": 3, "up": 2, "life": 1.1, "size": 0.35})
		vfx.light_flash(Vector3(p.x, 1.5, p.z), DmFxData.hex(0xa26bff), 25.0, 0.5)


# ============================================================================================ warm-up

## Loading-time pre-warm (silent, ~0.3 s of effects at `at`, which should be in front of the camera): one of every telegraph shape, the
## spawn / death / eruption bursts and the censer effect, so their pooled slots, textures and shaders exist before the first fight.
## Everything is an existing effect, so DmWarmup's all-effects pass (old game) already covers the Binbun scenes; the next game has no
## DmWarmup, so DmNextGame calls this once at the end of start().
func warm(at: Vector3) -> void:
	var quiet := fx.audio
	fx.audio = null
	var a := Vector3(at.x, 0.0, at.z + 2.5)
	for kind in [&"cone", &"slam", &"dust", &"erupt", &"ember", &"hex", &"pulse", &"hook"]:
		_on_telegraph(kind, Vector3(at.x, 0.0, at.z), a, 0.0 if kind == &"cone" else 1.8, 0.3, null)
	for id in ["vengeful_burst", "surge_eruption", "bonfire"]:   # the pyre's bursts and burning pools
		var hb = fx.bb(id, at.x, at.z, {"scale": 0.5})
		if hb != null:
			hb.kill()
	vfx.emit_smoke({"x": at.x, "y": 0.2, "z": at.z, "count": 10, "color": 0x2a2230, "spread": 0.7, "speed": 1, "up": 0.9, "life": 0.3, "size": 1.2, "shrink": -1})
	vfx.emit({"x": at.x, "y": 0.1, "z": at.z, "count": 4, "color": 0x5b2bb0, "spread": 0.5, "speed": 0.6, "up": 1.4, "life": 0.3, "size": 0.24})
	vfx.decal({"tex": "cracks", "color": 0x7c3aed, "x": at.x, "z": at.z, "r": 1.1, "duration": 0.3, "opacity": 0.8, "growFrom": 0.3})
	vfx.decal({"danger": true, "tex": "ring", "color": ELITE_COLOR, "x": at.x, "z": at.z, "r": 1.1, "duration": 0.3, "opacity": 0.8, "pulse": 4.0})
	vfx.light_flash(Vector3(at.x, 1.5, at.z), DmFxData.hex(0xa26bff), 25.0, 0.3)
	var h = fx.bb("censer_incense", at.x, at.z)
	if h != null:
		h.kill()
	fx.audio = quiet
	stats["telegraph"] = 0


# ============================================================================================ hostile zones

func _on_zone(z: DmHostileZone) -> void:
	if z == null or (z.kind != &"dust" and z.kind != &"ember"):
		return
	stats["zone"] += 1
	_zone.id = z.get_instance_id()
	_zone.kind = String(z.kind)
	_zone.x = z.global_position.x
	_zone.z = z.global_position.z
	_zone.r = z.radius
	_zone.until = host.mirror.time + z.lifetime
	_zone.hostile = true
	vfx.danger(fx.zones_fx.zone_visual.bind(_zone), true)
	z.tree_exiting.connect(fx.zones_fx.zone_gone.bind(_zone.id), CONNECT_ONE_SHOT)


# ============================================================================================ frame

func _process(dt: float) -> void:
	_clock += dt * 1000.0
	host.now_ms = _clock
	host.mirror.time = _clock / 1000.0
	var pp: Vector3 = _hero()
	_px = pp.x
	_pz = pp.z
	host.p["x"] = _px
	host.p["z"] = _pz
	fx.update(dt)
	for s: Slot in _slots.values():
		if s.strike_at >= 0.0 and _clock >= s.strike_at:
			s.strike_at = -1.0
			_impact(s)
	_amb_t += dt
	if _amb_t >= AMBIENT_S:
		_ambient(_amb_t)
		_amb_t = 0.0


func _hero() -> Vector3:
	if player_pos.is_valid():
		return player_pos.call()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position if cam != null else Vector3.ZERO


func _dist(x: float, z: float) -> float:
	return sqrt((x - _px) * (x - _px) + (z - _pz) * (z - _pz))


## Idle motes of the kinds that have them (rising dust, hover motes, a tunnelling ghoul's dirt).
func _ambient(dt: float) -> void:
	for s: Slot in _slots.values():
		var e := s.e
		if e.sm == null:
			continue
		var st := e.sm.id()
		if st == DmEnemyState.Id.DEAD:
			continue
		var p := e.global_position
		if absf(p.x - _px) > NEAR_X or absf(p.z - _pz) > NEAR_Z:
			continue
		if st == DmEnemyState.Id.RISING and randf() < dt * 8.0:
			_burst(_amb_dust, p.x, 0.1, p.z, true)
		if st == DmEnemyState.Id.BURROW and randf() < dt * 7.0:
			_burst(_amb_dirt, p.x, 0.15, p.z, false)
		if e.flying > 0.0 and randf() < dt * 4.0 and e.def_id != "fen_wisp":
			_burst(_amb_mote, p.x, e.flying + 0.2, p.z, false)
		if FIRE_DEFS.has(e.def_id):
			_fire_idle(e, st, p, dt)
		elif FEN_DEFS.has(e.def_id):
			_fen_idle(e, st, p, dt)


func _burst(o: Dictionary, x: float, y: float, z: float, smoke: bool) -> void:
	o["x"] = x
	o["y"] = y
	o["z"] = z
	if smoke:
		vfx.emit_smoke(o)
	else:
		vfx.emit(o)


## Ember shedding of the Cinder Pyre's dead (DmEntityViews._fire_dead, same rates).
func _fire_idle(e: DmEnemy, st: int, p: Vector3, dt: float) -> void:
	var ember := fx.sp("enemy", "ember")
	var core := fx.sp("enemy", "emberCore")
	var deep := fx.sp("enemy", "emberDeep")
	var s := e.scale.x
	_pf["drag"] = 0.5
	match e.def_id:
		"cinder_husk":
			if randf() < dt * 7.0:
				_pf["color"] = ember if randf() < 0.6 else core
				_pf_burst(p.x, 0.9 + randf() * 0.9, p.z, 0.3, 0.15, 1.1, 0.9, 0.1, 0.0)
		"pyre_priest":
			var wind := st == DmEnemyState.Id.ATTACK
			if randf() < dt * (22.0 if wind else 5.0):
				_pf["color"] = core
				_pf_burst(p.x, 0.9 * s, p.z, 0.2, 0.2, 1.2, 0.7, 0.18 if wind else 0.11, 0.0)
			if randf() < dt * 2.0:
				_burst_smoke(p.x, 1.5, p.z, 0x8a8680, 0.3, 0.15, 0.3, 1.6, 0.7)
		"cinderhound":
			var moving := st == DmEnemyState.Id.CHASE
			if moving and randf() < dt * 14.0:
				_pf["color"] = ember if randf() < 0.5 else core
				_pf_burst(p.x, 0.35, p.z, 0.15, 0.4, 0.8, 0.55, 0.09, 2.0)
			if moving and randf() < dt * 4.0:
				_burst_smoke(p.x, 0.5, p.z, deep, 0.2, 0.2, 0.3, 0.8, 0.6)
		"slag_brute":
			if randf() < dt * 6.0:
				_pf["color"] = ember
				_pf_burst(p.x, 1.0 + randf() * 1.6, p.z, 0.6, 0.15, 1.0, 1.1, 0.16, 0.0)
			if randf() < dt * 2.5:
				_burst_smoke(p.x, 2.2, p.z, deep, 0.4, 0.2, 0.6, 1.6, 1.1)
	_pf.erase("drag")


## The Fen's dead: the wisp's marsh-light, the hag's drips, the sexton's water (DmEntityViews._fen_dead; the leech's wiggle is the body's own).
func _fen_idle(e: DmEnemy, st: int, p: Vector3, dt: float) -> void:
	match e.def_id:
		"fen_wisp":
			if randf() < dt * 9.0:
				_pf["color"] = FEN_TEAL if randf() < 0.6 else 0xeaffff
				_pf["drag"] = 0.6
				_pf_burst(p.x, e.flying + 0.2 + randf() * 0.6, p.z, 0.25, 0.15, -0.2, 0.8, 0.12, 0.0)
				_pf.erase("drag")
		"bog_hag":
			var wind := st == DmEnemyState.Id.ATTACK
			if randf() < dt * (20.0 if wind else 3.0):
				_pf["color"] = fx.sp("enemy", "hex") if wind else 0x6fb4a8
				_pf_burst(p.x, 1.0 + randf() * 0.8, p.z, 0.3, 0.2, 1.2 if wind else -0.4, 0.8, 0.14, -0.3 if wind else 5.0)
		"drowned_sexton":
			if randf() < dt * 6.0:
				_pf["color"] = 0x3a5a54
				_pf_burst(p.x + (randf() - 0.5) * 0.8, 1.6 * e.scale.x, p.z + (randf() - 0.5) * 0.8, 0.1, 0.1, -0.3, 0.6, 0.1, 9.0)


func _burst_smoke(x: float, y: float, z: float, color: int, spread: float, speed: float, up: float, life: float, size: float) -> void:
	_pf["count"] = 1
	_pf["x"] = x
	_pf["y"] = y
	_pf["z"] = z
	_pf["color"] = color
	_pf["spread"] = spread
	_pf["speed"] = speed
	_pf["up"] = up
	_pf["life"] = life
	_pf["size"] = size
	_pf["shrink"] = -0.5
	_pf["gravity"] = 0.0
	vfx.emit_smoke(_pf)
	_pf.erase("shrink")
