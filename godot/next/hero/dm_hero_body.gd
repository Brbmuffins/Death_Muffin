class_name DmHeroBody
extends DmSessionBody
## The real hero as a session body: the DmAvatar model for the character's discipline, vitals (DmPlayerRules state, host-side), a
## navmesh-aware mover, a physics collider for enemies, and the enemy target contract (group `dm_target`, `dm_alive()`).
##
## The avatar is parented to the game node (the session's Players node may only hold bodies), at world scale, and follows the body.
## The host simulates (`step_host`, from DmSession intents); every peer renders. Puppets mirror the vitals the host broadcasts
## (`apply_vitals`). Death -> respawn in the Chapterhouse after RESPAWN_S, host side, like DmGame.respawn().

signal hurt(amount: float, source: Node)        ## host only
signal died(body: DmHeroBody)                   ## host only
signal respawned(body: DmHeroBody)              ## host only
signal enemy_effect(kind: StringName)           ## host only: an enemy chilled / rooted / dragged this body (the HUD floats the word)

const RESPAWN_S := 4.0                          ## DmGame.RESPAWN_MS
const MAX_STEP := 0.25                          ## clamp host dt (a hitch must not teleport the body through a wall)
const PULL_S := 0.3                             ## a Drowned Sexton's drag is a glide (clients interpolate it; a teleport would snap), not a jump

var game: Node                                  ## the DmNextGame (injected by the body factory)
var p: Dictionary = {}                          ## host: DmPlayerRules state. Empty on puppets.
var character: Dictionary = {}                  ## host: the character this body plays (level / class_index)
var mods: Dictionary = {}                       ## host: the discipline's mods (DmCharacterBuild), e.g. Ossuary's wardPerThrall
var character_id: int = 0
var avatar: DmAvatar
var hp: float = 100.0                           ## every peer: mirrored from p (host) / vitals broadcast (puppets)
var max_hp: float = 100.0
var resource: float = 0.0
var resource_max: float = 100.0
var alive: bool = true
var family: String = "necromancer"
var move_speed: float = 5.0
var wade_mult: float = 1.0                      ## host: the Drowned Congregation's rising water (DmBossHost), x the move speed
var speed_mult: float = 1.0                     ## written by the body's DmStatusSet only (chill, root = 0); the host's mover scales its speed by it
var moving: bool = false

var x: float:   ## the DmAudioHooks "player" shape (x / z on the ground plane)
	get: return position.x
var z: float:
	get: return position.z

var _path := PackedVector3Array()
var _path_i: int = 0
var _clock_ms: float = 0.0
var _dead_t: float = 0.0
var _last_hp: float = -1.0
var _hurt_cd: float = 0.0
var _was_alive: bool = true
var _prev_pos := Vector3.ZERO
var _prev_set: bool = false
var _speed_vis: float = 0.0


func setup(peer_id: int, nm: String, disc: String, pos: Vector3) -> void:
	show_capsule = false
	super.setup(peer_id, nm, disc, pos)
	add_to_group(DmEnemy.TARGET_GROUP)
	var sb := StaticBody3D.new()
	sb.name = "Collider"
	sb.collision_layer = DmEnemy.LAYER_PLAYER
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = CAPSULE_RADIUS
	cap.height = CAPSULE_HEIGHT
	cs.shape = cap
	cs.position.y = CAPSULE_HEIGHT * 0.5
	sb.add_child(cs)
	add_child(sb)


func _ready() -> void:
	_make_avatar.call_deferred()
	if simulated:
		_init_state()   # before the caster attaches: it builds from the body's character (its discipline)
	if game != null and game.has_method("attach_caster"):
		game.attach_caster(self)


## Host: give the body its character. A joiner without one plays a level-1 default of its discipline.
func bind_character(ch: Dictionary) -> void:
	character = ch
	character_id = int(ch.get("id", 0))
	_init_state()
	var rites := get_node_or_null("Rites") as DmRiteCaster
	if rites != null:
		rites.rebuild()   # the caster attached before the character was bound


func _init_state() -> void:
	if character.is_empty():
		var idx := 0
		var by_index: Dictionary = DmCombatData.disciplines()["by_index"]
		var best := 1 << 30
		for k in by_index:
			if String(by_index[k]) == discipline_id and int(k) < best:
				best = int(k)
		idx = best if best < (1 << 30) else 0
		character = {"class_index": idx, "level": 1, "id": 0}
	var b: Dictionary = game.build_for(owner_peer) if game != null and game.has_method("build_for") else DmCharacterBuild.build(character, [], {})
	family = String(b["discipline"]["family"])
	mods = b["discipline"]["mods"]
	p = DmPlayerRules.new_state(b["stats"], family)
	p["x"] = position.x
	p["z"] = position.z
	p["facing"] = yaw
	_mirror_from_state()


## Host: take new stats after a level-up, an upgrade or a gear change (hp keeps its share; a level-up heals separately).
func refresh_stats(build: Dictionary) -> void:
	if p.is_empty():
		return
	DmPlayerRules.set_stats(p, build["stats"])
	mods = build["discipline"]["mods"]
	_mirror_from_state()


## Host: a drunk brew on the body's clock (ward and speed brews act through `p["brews"]`).
func apply_brew(id: String) -> Dictionary:
	return DmBrews.apply_brew(p["brews"], id, _clock_ms)


## Host: full health and resource (a level-up).
func restore_vitals() -> void:
	if p.is_empty():
		return
	p["hp"] = float(p["stats"]["maxHp"])
	p["resource"]["value"] = p["resource"]["max"]
	_mirror_from_state()


func clock_ms() -> float:
	return _clock_ms


func _make_avatar() -> void:
	if avatar != null or not is_inside_tree() or game == null:
		return
	var dd: Dictionary = DmContent.discipline(discipline_id)
	if dd.is_empty():
		dd = DmContent.discipline("gravecaller")
	avatar = DmAvatar.new()
	avatar.setup(game, dd.get("color", 0xa26bff), true, String(dd.get("modelSlug", "hero_gravecaller")))
	avatar.c.root.position = Vector3(position.x, 0.0, position.z)
	tree_exiting.connect(func() -> void:
		if avatar != null and is_instance_valid(avatar):
			avatar.queue_free())


# ---- enemy target contract ----------------------------------------------------------------------------------------------------

func dm_alive() -> bool:
	return alive


func dm_take_enemy_hit(damage: float, from: Node, kind: String = "melee") -> void:
	take_damage(damage, from, kind)


## Host only. Returns the damage actually taken (after Bone Ward / barrier). Death starts the respawn clock.
func take_damage(amount: float, source: Node = null, kind: String = "melee") -> float:
	if p.is_empty() or not alive:
		return 0.0
	amount = DmStatusSet.scale_taken(self, amount)   # the status set's damage-taken multiplier, once, here
	var from: Variant = null
	if source is Node3D:
		from = {"x": (source as Node3D).global_position.x, "z": (source as Node3D).global_position.z}
	var taken := DmPlayerRules.take_damage(p, amount, _ward() + DmBrews.brew_ward(p["brews"], kind, _clock_ms), _clock_ms, from, kind, 0.0)
	_mirror_from_state()
	if taken > 0.0:
		hurt.emit(taken, source)
	if not bool(p["alive"]):
		stop()
		_dead_t = RESPAWN_S
		died.emit(self)
	return taken


## Host: what an enemy does to a hero besides damage (the DmPfUtil contract): `chill` / `root` {seconds, from} are statuses (the set owns the
## move multiplier and replicates them), `pull` {to, from} drags the body through the dash glide (navmesh-resolved, keeps its facing).
func dm_enemy_effect(kind: StringName, params: Dictionary) -> void:
	if p.is_empty() or not alive:
		return
	var from: Node = params.get("from")
	match kind:
		&"chill", &"root":
			DmStatusSet.ensure(self).apply(kind, from if is_instance_valid(from) else null, 1, float(params.get("seconds", -1.0)))
		&"pull":
			var y := yaw
			dash(resolve_point(params["to"]), PULL_S)
			yaw = y
		_:
			return
	enemy_effect.emit(kind)


func heal(amount: float) -> void:
	if not p.is_empty():
		DmPlayerRules.heal(p, amount)
		_mirror_from_state()


## Bone Ward: the discipline's wardPerThrall (Ossuary 10 %) per living thrall, capped by DmLegend (the old game's onHurt, DmAbilities.incoming_ward).
func _ward() -> float:
	var per := float(mods.get("wardPerThrall", 0.0))
	var th := get_node_or_null("Thralls") as DmThrallHost
	return per * float(th.count()) if per > 0.0 and th != null else 0.0


## Host: hold the body still for `seconds` (the Gravedigger's Burial, a boss grasp). Casting stays allowed; movement stops and walks are dropped.
func root_for(seconds: float) -> void:
	if p.is_empty():
		return
	p["rootedUntil"] = maxf(float(p["rootedUntil"]), _clock_ms + seconds * 1000.0)
	stop()


## Host: move the body instantly (respawn, waystone, Grave Step).
func teleport(to: Vector3) -> void:
	position = Vector3(to.x, 0.0, to.z)
	dashing = false
	stop()
	_path = PackedVector3Array()
	_prev_set = false
	if not p.is_empty():
		p["x"] = position.x
		p["z"] = position.z


func _mirror_from_state() -> void:
	hp = float(p["hp"])
	max_hp = float(p["stats"]["maxHp"])
	resource = float(p["resource"]["value"])
	resource_max = float(p["resource"]["max"])
	alive = bool(p["alive"])
	move_speed = float(p["stats"]["moveSpeed"])


## [hp, max_hp, resource, resource_max, alive] for the vitals broadcast.
func vitals() -> Array:
	return [hp, max_hp, resource, resource_max, alive]


func apply_vitals(v: Array) -> void:
	hp = float(v[0])
	max_hp = float(v[1])
	resource = float(v[2])
	resource_max = float(v[3])
	alive = bool(v[4])


# ---- movement (host) ----------------------------------------------------------------------------------------------------------

## Navmesh queries for the blink / dash rites (DmSessionBody contract). While the nav map is not ready everything is walkable.
func walkable(pt: Vector3) -> bool:
	if game == null or game.world == null or not game.world.nav_ready():
		return true
	var c: Vector3 = game.world.nav_closest(pt)
	return Vector2(c.x - pt.x, c.z - pt.z).length_squared() < 0.0004


func area_of_point(pt: Vector3) -> String:
	return game.world.area_at(pt.x, pt.z) if game != null and game.world != null else ""


func resolve_point(pt: Vector3) -> Vector3:
	if game != null and game.world != null and game.world.nav_ready():
		return game.world.nav_clamp(Vector3(pt.x, 0.0, pt.z))
	return Vector3(pt.x, 0.0, pt.z)


## Click-to-move: plan along the navmesh. Falls back to a straight line while the nav map is not ready.
func set_move_target(pt: Vector3) -> void:
	super.set_move_target(pt)
	_path = PackedVector3Array()
	_path_i = 0
	if not alive:
		has_target = false
		return
	if game != null and game.world != null and game.world.nav_ready():
		_path = game.world.nav_path(position, pt)
	if _path.is_empty():
		_path = PackedVector3Array([move_target])


func step_host(delta: float, _speed: float, _half: float) -> void:
	delta = minf(delta, MAX_STEP)
	_clock_ms += delta * 1000.0
	if p.is_empty():
		return
	DmPlayerRules.tick_vitals(p, delta, _clock_ms)
	if not bool(p["alive"]):
		_dead_t -= delta
		if _dead_t <= 0.0:
			_respawn()
		_mirror_from_state()
		rotation.y = yaw
		return
	if _step_dash(delta):
		p["x"] = position.x
		p["z"] = position.z
		p["facing"] = yaw
		_mirror_from_state()
		return
	if _dir_ttl > 0.0:
		_dir_ttl -= delta
		if _dir_ttl <= 0.0:
			move_dir = Vector3.ZERO
	var br: Dictionary = p["brews"]   # Flask of speed / ghostwalk (a brew lookup only while one was ever drunk)
	var brew_mult := 1.0 + DmBrews.brew_value(br, "speed", _clock_ms) if (br["elixir"] != null or br["tonic"] != null) else 1.0
	p["moveMult"] = brew_mult * wade_mult   # the Congregation's water x brews; the status speed_mult is applied once, below
	var speed := DmPlayerRules.move_speed(p, _clock_ms) * speed_mult
	var vel := Vector3.ZERO
	if _clock_ms < float(p["rootedUntil"]):
		speed = 0.0
		move_dir = Vector3.ZERO
	if move_dir.length_squared() > 0.0001:
		vel = move_dir * speed
		has_target = false
	elif has_target:
		vel = _path_velocity(speed, delta)
	if vel != Vector3.ZERO:
		var np := position + vel * delta
		np.y = 0.0
		if game != null and game.world != null and game.world.nav_ready():
			np = game.world.nav_clamp(np)
		position = np
		yaw = atan2(vel.x, vel.z)
	rotation.y = yaw
	p["x"] = position.x
	p["z"] = position.z
	p["facing"] = yaw
	_mirror_from_state()


## Velocity toward the next waypoint (skips reached ones); clears the target at the end of the path.
func _path_velocity(speed: float, delta: float) -> Vector3:
	while _path_i < _path.size():
		var wp := _path[_path_i]
		var d := Vector3(wp.x - position.x, 0.0, wp.z - position.z)
		if d.length() <= maxf(0.12, speed * delta * 0.5):
			_path_i += 1
			continue
		return d.normalized() * speed
	has_target = false
	return Vector3.ZERO


func _respawn() -> void:
	DmPlayerRules.revive(p)
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	teleport(Vector3(float(ret["x"]), 0.0, float(ret["z"])))
	_mirror_from_state()
	respawned.emit(self)


# ---- visuals (every peer) -----------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	super._process(delta)
	if avatar == null:
		return
	_hurt_cd -= delta
	var inst := 0.0
	if _prev_set and delta > 0.0:
		inst = Vector3(position.x - _prev_pos.x, 0.0, position.z - _prev_pos.z).length() / delta
	_prev_pos = position
	_prev_set = true
	_speed_vis = lerpf(_speed_vis, inst, 1.0 - exp(-12.0 * delta))
	moving = alive and _speed_vis > 0.6
	if alive != _was_alive:
		_was_alive = alive
		if alive:
			avatar.set_loop("idle")
			avatar.play_once("dig", 1.2)
		else:
			avatar.c.play_death()
	elif alive and _last_hp >= 0.0 and hp < _last_hp - 0.01 and _hurt_cd <= 0.0:
		_hurt_cd = 0.7
		avatar.play_once("hurt", 1.0)
	_last_hp = hp
	avatar.update(delta, position.x, position.z, yaw, moving, maxf(_speed_vis, 0.1) if moving else move_speed)
