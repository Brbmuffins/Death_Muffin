class_name DmCorpseField
extends Node
## The corpses of a session (REBUILD D1: host-authoritative). A Node named `Corpses`, same NodePath on every peer (RPCs resolve by path).
## Host: `track(enemy)` turns a DmEnemy's death into a corpse (or `add_corpse` for a sacrificed thrall / Black Litany remnant), ages and
## expires them (sim numbers), ruptures toxic ones into a DmHostileZone, and serves the query/consume API. Every peer (host included, solo
## too) gets spawn / gone events by RPC and builds the view from the replicated record: the dying body settles into the corpse (no shadow,
## pale marker ring, resonant tell, toxic aura) and fades / shatters when it goes. Contract: next/corpses/README.md.

signal corpse_added(c: DmSimCorpse)
signal corpse_consumed(c: DmSimCorpse, by_peer: int, reason: String)   ## host only, fired before corpse_gone
signal corpse_gone(c: DmSimCorpse, reason: String)                     ## every peer: expired, burst, or a consume reason
signal ruptured(c: DmSimCorpse, zone: DmHostileZone)                    ## host only

const ECHO_LIFE := 20.0          ## sim: a Veil echo corpse lasts 20 s
const ECHO_SCALE := 0.65
const ECHO_OFFSET := 0.45
const EXTRA_RING := 1.6          ## deathCorpses > 1: the others lie on a 1.6 m ring (sim collect_dead)
const FALLBACK_PICK_RANGE := 7.0 ## pick_corpse: no corpse under the cursor -> the nearest to the caster within 7 m
const TOXIC_R := 2.4             ## sim rupture zone: radius 2.4 x scale, 5 s, pulse 0.4 s, 6 x damage_scale(level) per pulse
const TOXIC_S := 5.0
const TOXIC_TICK := 0.4
const TOXIC_DMG := 6.0
const ADOPT_RANGE := 1.2         ## a corpse takes the dying body of the same def within 1.2 m (views: best_d = 1.2)
const MARKS_MAX := 8             ## pale rings are capped (views: CORPSE_MARKS_MAX); resonant tells always show
const FADE_S := 0.9
const SHATTER_S := 0.8

## Host knobs.
var auto_step := true                        ## false: tests/hosts call step(dt)
var life_mult := 1.0                         ## corpseLifeMult x vow multiplier (lingering_dead +50 %, thin_graves -25 %)
var echo_enabled := false                    ## a Veil caster is in the area: every corpse also drops a 20 s echo (queried only with include_echo)
var area_level: Callable = Callable()        ## (area: String) -> int, for the toxic pool's damage; default level 1
var resolve_pos: Callable = Callable()       ## (area, x, z) -> Vector2, optional navmesh snap for the extra deathCorpses
var visuals := true                          ## false: records only (dedicated/headless host, perf isolation)
var time := 0.0                              ## sim clock (host)

var corpses: Dictionary = {}                 ## id -> DmSimCorpse (replicated record on every peer)
var _next_id := 1
var _next_due := INF                         ## earliest expiresAt / ruptureAt: step() only scans when the clock reaches it
var _views: Dictionary = {}                  ## id -> View
var _fading: Array = []
var _rings := 0
var _can_fade := DisplayServer.get_name() != "headless"   ## the dummy renderer has no materials to fade

class View:
	extends RefCounted
	var creature: DmCreature
	var body: Node3D          ## freed when the fade ends
	var mark: Variant         ## DmFxHandle (the existing decal pool draws and fades it)
	var ring := false
	var t := 0.0
	var shatter := false


var vfx: Node = null                         ## the Vfx autoload (decals, particles); null in headless tests = no effects
var audio: Node = null


func _ready() -> void:
	if vfx == null:
		vfx = get_node_or_null("/root/Vfx")
	if vfx != null:
		DmFxTex.get_tex("ring")   # first-use warm: the decal textures exist before the first corpse
		DmFxTex.get_tex("disc")
	add_to_group(&"dm_corpse_field")   # corpse eaters (the Hungering affix) find the field without a path
	multiplayer.peer_connected.connect(_on_peer_connected)
	set_process(false)


# ====================================================================================================================== host: creation

## Listen to a DmEnemy: when it dies a corpse (its def's kind) appears at its feet. `area` / elite / scale / facing come from the enemy.
func track(e: DmEnemy, area := "") -> void:
	e.died.connect(_on_enemy_died.bind(area), CONNECT_ONE_SHOT)


func _on_enemy_died(e: DmEnemy, area: String) -> void:
	if not is_multiplayer_authority() or e.corpse_kind == "none":
		return
	var p := e.global_position
	var sc := e.scale.x
	var c := add_corpse(p.x, p.z, e.corpse_kind, e.def_id, e.elite, e.rotation.y, sc, area, e)
	if c == null:
		return
	if echo_enabled:
		var echo := add_corpse(p.x + ECHO_OFFSET, p.z + ECHO_OFFSET, "normal", e.def_id, false, e.rotation.y, ECHO_SCALE, area)
		if echo != null:
			echo.echoOwner = "*"
			echo.expiresAt = time + ECHO_LIFE
			_due(echo.expiresAt)
	var dc := int(e.def.get("deathCorpses", 1))
	for k in range(1, dc):
		var a := e.rotation.y + float(k) / float(dc - 1) * TAU
		var x := p.x + sin(a) * EXTRA_RING
		var z := p.z + cos(a) * EXTRA_RING
		if resolve_pos.is_valid():
			var r: Vector2 = resolve_pos.call(area, x, z)
			x = r.x
			z = r.y
		add_corpse(x, z, e.corpse_kind, "risen", false, a, 1.0, area)


## Lay a corpse down (host). Returns it, or null for kind "none" / when not the host. `body` = the dying DmEnemy to settle into the view.
## At the cap (DmSimConsts.MAX_CORPSES, 45) the oldest goes first ("expired").
func add_corpse(x: float, z: float, kind: String, enemy: String, elite: bool, facing: float, scale: float, area: String, body: DmEnemy = null) -> DmSimCorpse:
	if kind == "none" or not is_multiplayer_authority():
		return null
	if corpses.size() >= DmSimConsts.MAX_CORPSES:
		var oldest: DmSimCorpse = null
		for c: DmSimCorpse in corpses.values():
			if oldest == null or c.bornAt < oldest.bornAt:
				oldest = c
		if oldest != null:
			_remove(oldest, "expired", true)
	var c := DmSimCorpse.new()
	c.id = _next_id
	_next_id += 1
	c.x = x
	c.z = z
	c.kind = kind
	c.enemy = enemy
	c.elite = elite
	c.facing = facing
	c.scale = scale
	c.area = area
	c.bornAt = time
	c.expiresAt = time + DmSimConsts.CORPSE_LIFETIME * life_mult
	c.ruptureAt = time + DmSimConsts.TOXIC_RUPTURE if kind == "toxic" else INF
	_due(minf(c.expiresAt, c.ruptureAt))
	_install(c, body)
	if multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		_rpc_add.rpc(_pack(c))
	return c


func _due(t: float) -> void:
	_next_due = minf(_next_due, t)


func _physics_process(delta: float) -> void:
	if auto_step and is_multiplayer_authority():
		step(delta)


## Advance the host clock. Free when nothing is due (no per-corpse work per frame).
func step(dt: float) -> void:
	time += dt
	if time < _next_due:
		return
	_next_due = INF
	for c: DmSimCorpse in corpses.values():
		if time >= c.ruptureAt:
			_rupture(c)
		elif time >= c.expiresAt:
			_remove(c, "expired", true)
		else:
			_next_due = minf(_next_due, minf(c.expiresAt, c.ruptureAt))


func _rupture(c: DmSimCorpse) -> void:
	_remove(c, "burst", true)
	var level := int(area_level.call(c.area)) if area_level.is_valid() else 1
	var z := DmHostileZone.spawn(get_parent() if get_parent() != null else self, Vector3(c.x, 0.0, c.z), &"toxic", TOXIC_R * c.scale, TOXIC_S,
			TOXIC_DMG * DmEnemyStats.damage_scale(level) / TOXIC_TICK)
	z.tick_s = TOXIC_TICK
	ruptured.emit(c, z)


# ====================================================================================================================== queries (host)

## Corpses within r of pos (xz), nearest first. Echoes are excluded unless include_echo. filter: Callable(DmSimCorpse) -> bool. area "" = any.
func corpses_in_radius(pos: Vector3, r: float, filter: Callable = Callable(), area := "", include_echo := false) -> Array[DmSimCorpse]:
	var hits: Array = []
	var r2 := r * r
	for c: DmSimCorpse in corpses.values():
		if (c.echoOwner != "" and not include_echo) or (area != "" and c.area != area):
			continue
		var dx := c.x - pos.x
		var dz := c.z - pos.z
		var d2 := dx * dx + dz * dz
		if d2 <= r2 and (not filter.is_valid() or filter.call(c)):
			hits.append([d2, c.id, c])
	hits.sort()    # distance, then id (stable like the sim)
	var out: Array[DmSimCorpse] = []
	for h in hits:
		out.append(h[2])
	return out


## The corpse a cast at `aim` means (sim pick_corpse): nearest to the aim within pick_r AND within max_range of from_pos, else the nearest to
## from_pos within 7 m. Echoes never. Returns null when there is none.
func pick_corpse(aim: Vector3, pick_r: float, max_range: float, from_pos: Vector3, area := "") -> DmSimCorpse:
	var best: DmSimCorpse = null
	var best_d := pick_r
	var near: DmSimCorpse = null
	var near_d := FALLBACK_PICK_RANGE
	for c: DmSimCorpse in corpses.values():
		if c.echoOwner != "" or (area != "" and c.area != "" and c.area != area):
			continue
		var fd := Vector2(c.x - from_pos.x, c.z - from_pos.z).length()
		var d := Vector2(c.x - aim.x, c.z - aim.z).length()
		if d < best_d and fd <= max_range:
			best_d = d
			best = c
		if fd < near_d:
			near_d = fd
			near = c
	return best if best != null else near


func get_corpse(id: int) -> DmSimCorpse:
	return corpses.get(id)


func count() -> int:
	return corpses.size()


## Atomically take a corpse (host). True for exactly one caller; false when it is already gone (or on a client). `reason` shows in the view
## ("consumed" spirit wisps, "litany", "raised", "devoured", "burst" = blown apart by Corpse Explosion).
func consume(corpse_id: int, by_peer: int, reason := "consumed") -> bool:
	var c: DmSimCorpse = corpses.get(corpse_id)
	if c == null or not is_multiplayer_authority():
		return false
	corpse_consumed.emit(c, by_peer, reason)
	_remove(c, reason, true)
	return true


func _remove(c: DmSimCorpse, reason: String, broadcast: bool) -> void:
	if not corpses.erase(c.id):
		return
	_view_gone(c, reason)
	corpse_gone.emit(c, reason)
	if broadcast and multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		_rpc_gone.rpc(c.id, reason)


# ====================================================================================================================== replication

func _pack(c: DmSimCorpse) -> Array:
	return [c.id, c.x, c.z, c.kind, c.enemy, c.elite, c.facing, c.scale, c.area, c.echoOwner]


func _unpack(a: Array) -> DmSimCorpse:
	var c := DmSimCorpse.new()
	c.id = a[0]
	c.x = a[1]
	c.z = a[2]
	c.kind = a[3]
	c.enemy = a[4]
	c.elite = a[5]
	c.facing = a[6]
	c.scale = a[7]
	c.area = a[8]
	c.echoOwner = a[9]
	return c


@rpc("authority", "call_remote", "reliable")
func _rpc_add(a: Array) -> void:
	var c := _unpack(a)
	if not corpses.has(c.id):
		_install(c, null)


@rpc("authority", "call_remote", "reliable")
func _rpc_gone(id: int, reason: String) -> void:
	var c: DmSimCorpse = corpses.get(id)
	if c != null:
		_remove(c, reason, false)


@rpc("authority", "call_remote", "reliable")
func _rpc_snapshot(list: Array) -> void:
	for a in list:
		if not corpses.has(a[0]):
			_install(_unpack(a), null)


func _on_peer_connected(id: int) -> void:
	if corpses.is_empty() or not is_multiplayer_authority():
		return
	var list: Array = []
	for c: DmSimCorpse in corpses.values():
		list.append(_pack(c))
	_rpc_snapshot.rpc_id(id, list)


# ====================================================================================================================== views (every peer)

func _install(c: DmSimCorpse, body: DmEnemy) -> void:
	corpses[c.id] = c
	if visuals and c.echoOwner == "":
		_build_view(c, body)
	corpse_added.emit(c)


func _build_view(c: DmSimCorpse, hint: DmEnemy) -> void:
	var v := View.new()
	var e := hint if hint != null else _find_body(c)
	if e != null and e.creature != null:
		e.set_meta(&"corpse_id", c.id)
		v.creature = e.creature
		v.body = e
		v.creature.set_cast_shadow(false)
	elif DmSimData.ENEMIES.has(c.enemy):
		# no dying body here (sacrificed thrall, late join, risen): lay one down in its death pose
		var slug := String(DmSimData.ENEMIES[c.enemy].get("modelSlug", "grave_robber"))
		var cr := DmCreature.new(slug, {"tint": 0x8a8078 if c.enemy == "risen" else 0xffffff, "cast_shadow": false})
		var n := Node3D.new()
		n.position = Vector3(c.x, 0.0, c.z)
		n.rotation.y = c.facing
		n.scale = Vector3.ONE * c.scale
		n.add_child(cr.root)
		add_child(n)
		if not cr.hold_last_frame("death"):
			cr.toppled = 1.0
		v.creature = cr
		v.body = n
	# the current game's looks (dm_entity_views _on_corpse): green aura on toxic, a faint pale ring (capped) on the rest, a violet tell on resonant
	if c.kind == "toxic":
		_decal({"tex": "disc", "color": 0x6f8f3a, "x": c.x, "z": c.z, "r": TOXIC_R * c.scale, "duration": 5, "opacity": 0.35, "pulse": 6.0, "growFrom": 0.6})
	if c.kind == "resonant":
		v.mark = _decal({"tex": "ring", "color": 0xc6a4ff, "x": c.x, "z": c.z, "r": 1.2, "duration": 26, "opacity": 0.6, "pulse": 3.0})
	elif _rings < MARKS_MAX:
		var marsh := c.area == "fen"
		v.mark = _decal({"tex": "ring", "color": 0xffe6b0 if marsh else 0xd8cdf2, "x": c.x, "z": c.z, "r": (1.1 if marsh else 0.8) * maxf(1.0, c.scale),
				"duration": 26, "opacity": 0.85 if marsh else 0.4, "fadeIn": 0.8, "pulse": 2.0})
		v.ring = true
		_rings += 1
	_views[c.id] = v


func _find_body(c: DmSimCorpse) -> DmEnemy:
	var best: DmEnemy = null
	var best_d := ADOPT_RANGE
	for n in get_tree().get_nodes_in_group(&"dm_enemy"):
		var e := n as DmEnemy
		if e == null or e.def_id != c.enemy or e.has_meta(&"corpse_id") or e.sm == null or e.sm.id() != DmEnemyState.Id.DEAD:
			continue
		var d := Vector2(e.global_position.x - c.x, e.global_position.z - c.z).length()
		if d < best_d:
			best_d = d
			best = e
	return best


func _decal(o: Dictionary) -> Variant:
	return vfx.decal(o) if vfx != null else null


func _emit(o: Dictionary) -> void:
	if vfx != null:
		vfx.emit(o)


func _view_gone(c: DmSimCorpse, reason: String) -> void:
	var v: View = _views.get(c.id)
	if v == null:
		return
	_views.erase(c.id)
	if v.ring:
		_rings -= 1
	if v.mark != null:
		v.mark.kill()
	_gone_fx(c, reason)
	if v.body == null or not is_instance_valid(v.body):
		return
	if v.body is DmEnemy:
		v.body.remove_meta(&"corpse_id")
	v.shatter = reason == "burst" and c.kind != "toxic"
	if v.shatter and _can_fade:
		v.creature.set_opacity(0.0)
	_fading.append(v)
	set_process(true)


func _process(delta: float) -> void:
	for i in range(_fading.size() - 1, -1, -1):
		var v: View = _fading[i]
		v.t += delta
		var life := SHATTER_S if v.shatter else FADE_S
		if v.t >= life:
			if is_instance_valid(v.body):
				v.body.queue_free()
			_fading.remove_at(i)
		elif not v.shatter and _can_fade:
			v.creature.set_opacity(1.0 - v.t / FADE_S)
	if _fading.is_empty():
		set_process(false)


## Test/diagnostic: how many views / live marks exist.
func view_count() -> int:
	return _views.size()


func fading_count() -> int:
	return _fading.size()


## The wisps the current game plays per reason (dm_entity_views _on_corpse_gone). Colours are the spell palette's.
func _gone_fx(c: DmSimCorpse, reason: String) -> void:
	if vfx == null:
		return
	var sp: Dictionary = DmFxData.data().get("spell_fx", {})
	var o := {"x": c.x, "y": 0.4, "z": c.z, "spread": 0.6, "speed": 0.8, "size": 0.35}
	match reason:
		"consumed":
			o.merge({"count": 22, "color": int(sp.get("exhume", {}).get("spirit", 0xffffff)), "up": 2.6, "life": 0.9})
		"litany":
			o.merge({"count": 18, "color": int(sp.get("litany", {}).get("core", 0xffffff)), "up": 2.2, "life": 0.8})
		"raised":
			o.merge({"count": 18, "color": int(sp.get("enemy", {}).get("rot", 0xffffff)), "up": 2.0, "life": 1.0})
		"devoured":
			o.merge({"count": 22, "color": int(sp.get("affix", {}).get("drool", 0xffffff)), "spread": 0.5, "speed": 1.6, "up": 1.4, "life": 0.7, "size": 0.26, "gravity": 5})
		"burst":
			if c.kind == "toxic":
				return
			o.merge({"y": 0.5, "count": 20, "color": int(sp.get("miasma", {}).get("rot", 0xffffff)), "speed": 2.5, "up": 1.5, "life": 0.7, "size": 0.3})
		_:
			return
	_emit(o)
