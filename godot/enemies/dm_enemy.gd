class_name DmEnemy
extends CharacterBody3D
## One enemy as a Godot scene (pilot: the Hollow Graves robber). The body is a CharacterBody3D because enemies must be blocked by walls and
## by the player's body and slide along them: move_and_slide in FLOATING mode (no gravity/floor logic; the arenas are flat, see the
## integration notes for terrain) gives that for free and is cheaper than hand-rolled circle-vs-AABB resolution. Pathing is a
## NavigationAgent3D on the NavigationServer3D map (real navmesh, replaces godot/sim/nav.gd); crowd spacing is the agent's RVO avoidance,
## so enemies do not collide with each other (mask excludes the enemy layer).
##
## Authority (REBUILD D1): the brain (state machine, targeting, pathing, damage) runs only where is_multiplayer_authority(). Everywhere
## else the node is a puppet: apply_net_state() feeds it, _process interpolates and plays the animation. No RPCs here; the session layer
## calls get_net_state() on the host and apply_net_state() on clients.
##
## Stats come from the existing def (DmSimData.ENEMIES[def_id]) so numbers stay in one place. Not bit-exact with the old sim by design.
##
## Target contract (duck-typed, so the player scene needs no base class): a Node3D in group "dm_target"; optionally
## `dm_alive() -> bool`, `dm_take_enemy_hit(damage: float, from: Node[, kind: String]) -> void` (the optional damage kind is the sim's hurt `from`: melee, toxic,
## burn, ember, dust, curse; a target that declares only two parameters still works, see `deliver`) and `dm_target_weight() -> float` (distance multiplier in the target scan).

signal state_changed(prev: int, next: int)
signal struck(target: Node3D, damage: float)  ## the blow landed (host side); integration turns this into a player hurt event
signal damaged(amount: float, hp_left: float, from: Node)
signal died(enemy: DmEnemy)
## A ground telegraph for the integration/VFX layer (sim "telegraph" event): kind is the sim's telegraph kind ("cone", "slam", "dust", "erupt"...).
## `radius` 0 = a cone/line (use attack_range). The blow lands `seconds` later.
signal telegraph(kind: StringName, from: Vector3, aim: Vector3, radius: float, seconds: float)
## A one-off effect cue ("erupt", "dig_in"): the integration plays the sim's matching VFX/SFX.
signal statuses_cleared   ## a dig-in wipes bleed/withered/root/slow/chill: the host combat code listens and drops them
signal cue(kind: StringName, at: Vector3, radius: float)

const TARGET_GROUP := &"dm_target"
## Physics layers (project.godot layer names to add): 1 world, 2 player, 3 enemy.
const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_ENEMY := 4

const ATTACK_TRIGGER_PAD := 0.35   ## sim: swing when dist <= attackRange + 0.35
const STOP_FRAC := 0.8             ## sim: keep walking while dist > attackRange * 0.8
const STRIKE_REACH_MULT := 1.35    ## sim strike reach = attackRange * 1.35 + 0.4
const STRIKE_REACH_PAD := 0.4
const AGGRO_RANGE := 15.0          ## DmSimConsts.AGGRO_RANGE
const DROP_MULT := 1.5             ## lose the target beyond aggro * 1.5 (new: the sim just re-picked every tick)
const HOME_ARRIVE := 1.0
const WANDER_SPEED_MULT := 0.3     ## sim: idle drift at 0.3x
const WANDER_RADIUS := 4.0
const STAGGER_ICD := 0.9           ## min seconds between flinch staggers (anti stun-lock)
const REPATH_S := 0.3              ## min seconds between path requests per enemy (staggered randomly)
const REPATH_MOVE_SQ := 1.0        ## ...and only when the goal moved more than 1 m
const DIRECT_RANGE_SQ := 9.0       ## closer than 3 m to the goal: walk straight, skip the navmesh entirely
const SCAN_S := 0.25               ## target scan period
const TURN_RATE := 14.0
const INCENSE_MOVE := 1.3          ## DmSimData.CENSER moveMult / attackRateMult (Censer Bearer haste)
const INCENSE_ATTACK := 1.25
const LOOK_FALLBACK := {"rat": "bone_hound", "moth": "choir_wraith", "bat": "skull_rat", "ghoul": "grave_robber", "censer": "deacon"}
const LOOK_WINGS := {"moth": {"speed": 8.0, "amp": 0.55, "body": 0.16}, "bat": {"speed": 17.0, "amp": 0.75, "body": 0.22}}

# --- config (inspector) ---
@export var def_id: String = "robber"
@export var rising: bool = false          ## play the 1.1 s spawn rise first
@export var with_visual: bool = true      ## false = brain only (perf isolation)
@export var use_nav: bool = true
@export var use_avoidance: bool = true
@export var wander_enabled: bool = true
@export var leash_range: float = 30.0     ## max distance from home while chasing
@export var corpse_s: float = 0.0         ## 0 = corpse stays until freed by its owner
@export var hp_mult: float = 1.0          ## level/difficulty scaling is the spawner's job (sim spawn_enemy math)
@export var damage_mult: float = 1.0
@export var rng_seed: int = 0             ## 0 = random
@export var elite: bool = false           ## sim ELITE multipliers (hp/damage/scale/radius, wind-up x0.85, cooldown x0.8); elite affixes are a child component, see next/affixes
@export var in_graves: bool = true        ## burrowers: BURROW.eruptMultGraves / eruptMsGraves vs the deeper-area numbers
@export var flank_side: float = 0.0       ## +-1 flank side for flanker kinds; 0 = random per body
@export var model_slug: String = ""       ## "" = the def's modelSlug (or grave_robber); a scene sets it for defs that name no model (deacon)

# --- stats (filled from the def in _ready) ---
var def: Dictionary
var max_hp: float = 1.0
var hp: float = 1.0
var damage: float = 1.0
var speed: float = 2.6
var speed_mult: float = 1.0               ## statuses (chill, slow, frenzy...) write here
var radius: float = 0.45
var attack_range: float = 1.3
var windup_s: float = 0.42
var cooldown_s: float = 1.3
var aggro_range: float = AGGRO_RANGE
var corpse_kind: String = "normal"        ## def "corpse": normal / swift / resonant / toxic / none. The corpse system reads this from `died`.
var hit_run: float = 0.0                  ## def "hitRun": seconds spent fleeing after each blow (Tithe Bat)
var flying: float = 0.0                   ## def "flying": hover height of the visual (the body stays on the ground plane, like the sim)
var attack_rate_mult: float = 1.0         ## statuses (chill, frenzy) write here; scales how fast attack_cd runs down
var incense_t: float = 0.0                ## Censer Bearer haste: > 0 = x1.3 move, x1.25 attack rate (sim CENSER)
var aim := Vector3.ZERO                   ## where the current blow is aimed, fixed at wind-up start (the telegraph)
var attack_anim: String = "attack"       ## casters play "cast" (views: CASTERS)
var blow_kind: String = "melee"           ## damage kind of this body's plain blow (the sim's hurt `from`): "toxic" for rot bites (def rotBite)

# --- runtime ---
var sm: DmEnemyStateMachine
var target: Node3D:
	set(v):
		if target == v:
			return
		if target != null and is_instance_valid(target) and target.tree_exiting.is_connected(_on_target_gone):
			target.tree_exiting.disconnect(_on_target_gone)
		target = v
		if v != null:
			v.tree_exiting.connect(_on_target_gone)
var home: Vector3
var attack_cd: float = 0.0
var creature: DmCreature
var agent: NavigationAgent3D
var rng := RandomNumberGenerator.new()

var _hurt: DmStateHurt
var _bob: float = 0.0
var _dt: float = 0.0
var _want_vel := Vector3.ZERO
var _safe_vel := Vector3.ZERO
var _nav_goal := Vector3.INF
var _repath_t: float = 0.0
var _scan_t: float = 0.0
var _stagger_t: float = 0.0
var _wander_heading: float = 0.0
var _anim: String = "idle"
var _flash: float = 0.0
var _anim_acc: float = 0.0
var _lod_interval: float = 0.0
var _lod_t: float = 0.0
# puppet state
var _net_pos := Vector3.ZERO
var _net_yaw: float = 0.0
var _net_seen: bool = false
var _puppet_speed: float = 0.0
var net_age: float = 0.0       ## seconds the host had spent in the replicated state when it sent the snapshot (telegraph lead-time)

# --- profiling (tests / tools/perf; off in the game) ---
static var profile: bool = false
static var prof_ticks: int = 0
static var prof_brain_us: int = 0
static var prof_nav_us: int = 0
static var prof_repaths: int = 0
static var prof_scans: int = 0
static var prof_kind: Dictionary = {}   ## def_id -> [ticks, brain_us]

static func prof_reset() -> void:
	prof_ticks = 0
	prof_brain_us = 0
	prof_nav_us = 0
	prof_repaths = 0
	prof_scans = 0
	prof_kind = {}


func _ready() -> void:
	DmSimData.ensure()
	def = DmSimData.ENEMIES[def_id]
	if rng_seed != 0:
		rng.seed = rng_seed
	else:
		rng.randomize()
	var el: Dictionary = DmSimData.ELITE
	max_hp = float(def["hp"]) * hp_mult * (float(el["hpMult"]) if elite else 1.0)
	hp = max_hp
	damage = float(def["damage"]) * damage_mult * (float(el["damageMult"]) if elite else 1.0)
	speed = float(def["speed"]) * (0.92 + rng.randf() * 0.16)   # sim: per-body +-8% speed
	radius = float(def["radius"]) * (1.25 if elite else 1.0)
	attack_range = float(def["attackRange"])
	windup_s = float(def["windupMs"]) / 1000.0 * (0.85 if elite else 1.0)
	cooldown_s = float(def["cooldownMs"]) / 1000.0 * (0.8 if elite else 1.0)
	corpse_kind = String(def.get("corpse", "normal"))
	hit_run = float(def.get("hitRun", 0.0))
	if bool(def.get("rotBite", false)):
		blow_kind = "toxic"
	flying = float(def.get("flying", 0.0))
	if flank_side == 0.0:
		flank_side = -1.0 if rng.randf() < 0.5 else 1.0
	if corpse_kind == "none" and corpse_s <= 0.0:
		corpse_s = 2.4   # sim/views: a body that leaves no corpse crumbles away ~1.4 s after the fall
	var sc := float(def.get("scale", 1.0)) * (float(el["scale"]) if elite else 1.0)
	scale = Vector3.ONE * sc
	attack_cd = 0.5 + rng.randf()                               # sim: first swing 0.5-1.5 s after spawn
	_repath_t = rng.randf() * REPATH_S
	_scan_t = rng.randf() * SCAN_S
	_wander_heading = rng.randf() * TAU
	home = global_position

	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	max_slides = 3   # cheaper than the default 6; walls here are plain boxes
	collision_layer = LAYER_ENEMY
	collision_mask = LAYER_WORLD | LAYER_PLAYER
	var cs: CollisionShape3D = $Collision
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = 1.7
	cs.shape = cyl
	cs.position.y = 0.85

	agent = $Nav
	agent.radius = radius
	agent.path_desired_distance = 0.5
	agent.target_desired_distance = 0.5
	agent.path_max_distance = 2.0
	agent.max_speed = speed * 1.3
	agent.avoidance_enabled = use_avoidance
	agent.neighbor_distance = 4.0
	agent.max_neighbors = 6
	agent.time_horizon_agents = 1.0
	agent.velocity_computed.connect(_on_safe_velocity)
	# Godot only runs RVO for an agent that has a navigation target; without one (an enemy that aggroes inside the 3 m direct-walk range
	# never requests a path) the safe velocity comes back zero and the body never moves. A placeholder target fixes it.
	agent.target_position = global_position

	if with_visual:
		var slug: String = model_slug if model_slug != "" else String(def.get("modelSlug", "grave_robber"))
		creature = DmCreature.new(slug, look_options())
		$Visual.add_child(creature.root)
		creature.set_loop("idle")

	sm = DmEnemyStateMachine.new()
	_build_states()
	sm.changed.connect(func(p: int, n: int) -> void: state_changed.emit(p, n))
	sm.start(initial_state())
	add_to_group(&"dm_enemy")


## The default (robber) state set. A kind's script overrides this, calling super() and then re-adding only the states that differ (same id
## replaces the slot), e.g. a caster swaps CHASE for DmStateKite.
func _build_states() -> void:
	sm.add(DmStateRising.new(self, DmEnemyState.Id.RISING))
	sm.add(DmStateIdle.new(self, DmEnemyState.Id.IDLE))
	sm.add(DmStateChase.new(self, DmEnemyState.Id.CHASE))
	sm.add(DmStateAttack.new(self, DmEnemyState.Id.ATTACK))
	_hurt = DmStateHurt.new(self, DmEnemyState.Id.HURT)
	sm.add(_hurt)
	sm.add(DmStateReturn.new(self, DmEnemyState.Id.RETURN))
	sm.add(DmStateDead.new(self, DmEnemyState.Id.DEAD))


func initial_state() -> int:
	return DmEnemyState.Id.RISING if rising else DmEnemyState.Id.IDLE


## How this kind is dressed (mirrors DmEntityViews._enemy_opts): wings, tint, emissive, missing-model fallback.
func look_options() -> Dictionary:
	var o := {"hitstop": true}
	var em := 0
	var ek := 0.0
	if elite:
		em = 0x4a1f8a
		ek = 0.14
	elif def_id == "risen":
		em = 0x2a3a18
		ek = 0.3
	if ek > 0.0:
		o["emissive"] = em
		o["emissive_intensity"] = ek
	if def_id == "risen":
		o["tint"] = 0x8a8078
	if LOOK_FALLBACK.has(def_id):
		o["fallback"] = LOOK_FALLBACK[def_id]
	if LOOK_WINGS.has(def_id):
		o["wings"] = LOOK_WINGS[def_id]
	return o


# ============================================================================================ brain (authority only)

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	var t0 := Time.get_ticks_usec() if profile else 0
	_dt = delta
	var sid := sm.id()
	if sid != DmEnemyState.Id.HURT and sid != DmEnemyState.Id.RISING:
		attack_cd -= delta * attack_rate_mult * (INCENSE_ATTACK if incense_t > 0.0 else 1.0)
	if incense_t > 0.0:
		incense_t -= delta
	_stagger_t -= delta
	sm.tick(delta)
	_move(delta)
	if profile:
		var us := Time.get_ticks_usec() - t0
		prof_ticks += 1
		prof_brain_us += us
		var k: Array = prof_kind.get(def_id, [0, 0])
		k[0] += 1
		k[1] += us
		prof_kind[def_id] = k


## Apply the velocity the states asked for this tick (_want_vel), turn toward it, and set the walk/run clip.
func _move(delta: float) -> void:
	var v := _want_vel
	if use_avoidance and agent.avoidance_enabled and v != Vector3.ZERO:
		agent.velocity = v
		v = _safe_vel
	velocity = v
	if v != Vector3.ZERO:
		move_and_slide()
		rotation.y = lerp_angle(rotation.y, atan2(v.x, v.z), minf(1.0, TURN_RATE * delta))
	_loco(_want_vel.length())
	_want_vel = Vector3.ZERO


func _on_safe_velocity(safe: Vector3) -> void:
	_safe_vel = Vector3(safe.x, 0.0, safe.z)


func scan_due(dt: float) -> bool:
	_scan_t -= dt
	if _scan_t > 0.0:
		return false
	_scan_t = SCAN_S
	if profile:
		prof_scans += 1
	return true


## Nearest alive target within `rng_m` (flat distance), or null.
func find_target(rng_m: float) -> Node3D:
	var best: Node3D = null
	var best_d := rng_m * rng_m
	var p := global_position
	for n in get_tree().get_nodes_in_group(TARGET_GROUP):
		var tg := n as Node3D
		if not target_valid(tg):
			continue
		var dx := tg.global_position.x - p.x
		var dz := tg.global_position.z - p.z
		var d := dx * dx + dz * dz
		if tg.has_method("dm_target_weight"):   # sim pick_target: thralls count 1.1x as far (shieldbearer 0.55x); players/dummies 1.0
			var w: float = tg.dm_target_weight()
			d *= w * w
		if d < best_d:
			best_d = d
			best = tg
	return best


func target_valid(tg: Variant) -> bool:
	if tg == null or not is_instance_valid(tg) or not (tg as Node).is_inside_tree():
		return false
	return not (tg.has_method("dm_alive") and not tg.dm_alive())


func flat_dist_to(n: Node3D) -> float:
	var a := n.global_position - global_position
	return sqrt(a.x * a.x + a.z * a.z)


func flat_dist_home() -> float:
	var a := home - global_position
	return sqrt(a.x * a.x + a.z * a.z)


func should_return() -> bool:
	return flat_dist_home() > HOME_ARRIVE


func stop() -> void:
	_want_vel = Vector3.ZERO
	_nav_goal = Vector3.INF
	_repath_t = minf(_repath_t, rng.randf() * REPATH_S)   # a fresh path soon, but spread so a whole pack does not repath in one tick


## Walk toward `goal` (world point) through the navmesh. Close goals (< 3 m) are walked straight; far goals use the agent's path, re-requested
## at most every REPATH_S seconds (randomly staggered per enemy) and only when the goal moved > 1 m.
func steer_to(goal: Vector3, mult: float) -> void:
	var pos := global_position
	var flat := Vector3(goal.x - pos.x, 0.0, goal.z - pos.z)
	var d2 := flat.length_squared()
	if d2 < 0.0025:
		return
	var dir := flat
	if use_nav and d2 > DIRECT_RANGE_SQ:
		var t0 := Time.get_ticks_usec() if profile else 0
		_repath_t -= _dt
		if _repath_t <= 0.0:
			_repath_t = REPATH_S
			if _nav_goal == Vector3.INF or goal.distance_squared_to(_nav_goal) > REPATH_MOVE_SQ:
				_nav_goal = goal
				agent.target_position = goal
				if profile:
					prof_repaths += 1
		if _nav_goal != Vector3.INF:
			var nxt := agent.get_next_path_position()
			var step := Vector3(nxt.x - pos.x, 0.0, nxt.z - pos.z)
			if step.length_squared() > 0.0004:
				dir = step
		if profile:
			prof_nav_us += Time.get_ticks_usec() - t0
	_want_vel = dir.normalized() * speed * speed_mult * (INCENSE_MOVE if incense_t > 0.0 else 1.0) * mult


## Move straight toward `goal` at an absolute speed (m/s), no navmesh (underground tunnelling).
func move_straight(goal: Vector3, spd: float) -> void:
	var flat := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	if flat.length_squared() > 0.0025:
		_want_vel = flat.normalized() * spd


func face_point(p: Vector3, dt: float) -> void:
	var d := p - global_position
	if d.x * d.x + d.z * d.z > 0.0001:
		rotation.y = lerp_angle(rotation.y, atan2(d.x, d.z), minf(1.0, TURN_RATE * dt))


## Idle drift around home (sim: facing drifts randomly, walks at 0.3x). Straight movement, no pathing.
func wander(dt: float) -> void:
	if not wander_enabled:
		return
	if rng.randf() < dt * 0.3:
		_wander_heading += (rng.randf() - 0.5) * 2.0
	var away := global_position - home
	if away.x * away.x + away.z * away.z > WANDER_RADIUS * WANDER_RADIUS:
		_wander_heading = atan2(-away.x, -away.z)
	_want_vel = Vector3(sin(_wander_heading), 0.0, cos(_wander_heading)) * speed * speed_mult * (INCENSE_MOVE if incense_t > 0.0 else 1.0) * WANDER_SPEED_MULT


## Called when a swing starts (wind-up begins): fix the aim and announce the telegraph. Kinds override to aim/announce differently.
func begin_attack() -> void:
	aim = target.global_position if target_valid(target) else global_position + Vector3(sin(rotation.y), 0.0, cos(rotation.y))
	if target_valid(target):
		face_point(aim, 1.0)
	announce_telegraph(windup_s)


## Announce the ground telegraph of the wind-up that just began (`seconds` of it left). Runs on the authority at the start of the swing and on
## puppets when the replicated ATTACK state arrives (aim is replicated), so every peer's VFX layer gets the same `telegraph` signal. The plain
## melee swing has none; caster / hazard kinds override.
func announce_telegraph(_seconds: float) -> void:
	pass


## Puppet-side hook: the swing's impact moment on EVERY peer (DmEnemyFx calls it at the wind-up's end). Kinds whose blow leaves a host-spawned zone
## spawn the visual-only copy here on non-authority peers.
func on_impact_visual() -> void:
	pass


## The blow lands (end of wind-up). Reach is measured from the body, like the sim. Kinds override (slam / cone / dust ...).
func strike() -> void:
	var tg := target
	if not target_valid(tg):
		return
	if flat_dist_to(tg) <= attack_range * STRIKE_REACH_MULT + STRIKE_REACH_PAD:
		hit_target(tg, damage)


## `kind` "" = this body's blow_kind.
func hit_target(tg: Node3D, dmg: float, kind: String = "") -> void:
	struck.emit(tg, dmg)
	deliver(tg, dmg, self, kind if kind != "" else blow_kind)


## The target contract call, with the damage kind when the target takes one (hero: Veilwalker's burn / toxic immunity, brew fire / rot resist).
## Shared by blows and hostile zones. A target whose dm_take_enemy_hit predates `kind` (two parameters) gets the old call.
static func deliver(tg: Node, dmg: float, from: Node, kind: String) -> void:
	if not tg.has_method("dm_take_enemy_hit"):
		return
	var cb := Callable(tg, &"dm_take_enemy_hit")
	if cb.get_argument_count() >= 3:
		cb.call(dmg, from, kind)
	else:
		cb.call(dmg, from)


## Every valid target within `r` (flat) of point `c`.
func targets_within(c: Vector3, r: float) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var r2 := r * r
	for n in get_tree().get_nodes_in_group(TARGET_GROUP):
		var tg := n as Node3D
		if not target_valid(tg):
			continue
		var dx := tg.global_position.x - c.x
		var dz := tg.global_position.z - c.z
		if dx * dx + dz * dz <= r2:
			out.append(tg)
	return out


## State the swing ends in (after the 0.3 s recovery). Bats hit-and-run.
func post_attack_state() -> int:
	if hit_run > 0.0 and target_valid(target):
		return DmEnemyState.Id.FLEE
	return DmEnemyState.Id.CHASE if target_valid(target) else DmEnemyState.Id.IDLE


## False while the body cannot be hurt (burrowed ghoul). take_damage respects it.
func is_hittable() -> bool:
	return true


## Damage from the host's combat code (the status set's damage-taken multiplier is applied here). Returns true when applied. A hit also aggroes the attacker if nothing is targeted.
func take_damage(amount: float, from: Node = null, allow_stagger: bool = true) -> bool:
	if not is_multiplayer_authority() or sm.id() == DmEnemyState.Id.DEAD or sm.id() == DmEnemyState.Id.RISING or not is_hittable():
		return false
	amount = DmStatusSet.scale_taken(self, amount)   # sanctified / fracture / shrouded: once, here, for every source
	hp -= amount
	_flash = 1.0
	damaged.emit(amount, hp, from)
	if hp <= 0.0:
		hp = 0.0
		sm.change(DmEnemyState.Id.DEAD)
		return true
	if target == null and from is Node3D and target_valid(from):
		target = from
	var sid := sm.id()
	if allow_stagger and _stagger_t <= 0.0 and (sid == DmEnemyState.Id.IDLE or sid == DmEnemyState.Id.CHASE or sid == DmEnemyState.Id.RETURN):
		_stagger_t = STAGGER_ICD
		_hurt.duration = 0.3
		sm.change(DmEnemyState.Id.HURT)
	elif sid == DmEnemyState.Id.IDLE and target != null:
		sm.change(DmEnemyState.Id.CHASE)
	return true


## Hard interrupt (stun rite): cancels a swing too.
func stun(seconds: float) -> void:
	if not is_multiplayer_authority() or sm.id() == DmEnemyState.Id.DEAD or not is_hittable():
		return
	_hurt.duration = seconds
	sm.change(DmEnemyState.Id.HURT)


# ============================================================================================ visuals (every peer)

func play_attack(windup: float) -> void:
	_anim = "attack"
	if creature != null:
		creature.play_strike(attack_anim, windup)

func play_hurt() -> void:
	_anim = "hurt"
	if creature != null:
		creature.flinch()

func on_death() -> void:
	_anim = "death"
	collision_layer = 0
	collision_mask = 0
	agent.avoidance_enabled = false
	set_physics_process(false)
	if creature != null and not creature.play_death():
		creature.root.rotation.x = -PI * 0.5   # rigs with no death clip: tip over
	if is_multiplayer_authority():
		died.emit(self)
	if corpse_s > 0.0:
		get_tree().create_timer(corpse_s).timeout.connect(queue_free)


func current_clip() -> String:
	return creature.ap.current_animation if creature != null and creature.ap != null else ""


func _loco(ground: float) -> void:
	var sid := sm.id() if sm != null else -1
	if sid == DmEnemyState.Id.ATTACK or sid == DmEnemyState.Id.HURT or sid == DmEnemyState.Id.DEAD or sid == DmEnemyState.Id.ERUPT \
			or sid == DmEnemyState.Id.DIG or sid == DmEnemyState.Id.BURROW:
		return
	if ground > 0.2:
		_anim = "run" if ground > speed * 1.2 else "walk"
		if creature != null:
			_anim = String(creature.set_ground_speed(snappedf(ground, 0.25)).clip)
	else:
		_anim = "idle"
		if creature != null:
			creature.set_loop("idle")


func _process(delta: float) -> void:
	if not is_multiplayer_authority():
		_puppet_step(delta)
	if creature == null:
		return
	if flying > 0.0 and sm.id() != DmEnemyState.Id.DEAD:
		_bob += delta
		$Visual.position.y = flying + sin(_bob * 1000.0 / 520.0 + float(get_instance_id() % 7)) * 0.18   # views: hover + sin(t/520 + id) * 0.18
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 6.0)
		creature.set_flash(_flash)
	# Animation LOD: near bodies every frame, mid-distance ~24 Hz, far ~10 Hz; a swing/flinch/death always runs at full rate.
	_anim_acc += delta
	_lod_t -= delta
	if _lod_t <= 0.0:
		_lod_t = 0.5
		_lod_interval = 0.0
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam != null:
			var d := cam.global_position.distance_to(global_position)
			_lod_interval = 0.0 if d < 18.0 else (0.04 if d < 40.0 else 0.1)
	if _anim_acc >= _lod_interval or creature.busy():
		creature.steady_every = 1 if _lod_interval == 0.0 else 2
		creature.update(_anim_acc)
		_anim_acc = 0.0


# ============================================================================================ replication seam

## Everything a puppet needs. Host calls this at the replication rate (10-20 Hz); allocation per call is fine at that rate.
func get_net_state() -> Dictionary:
	return {"pos": global_position, "yaw": rotation.y, "state": sm.id(), "hp": hp, "anim": _anim, "aim": aim,
		"t": sm.current.t if sm.current != null else 0.0}


## Puppet side: adopt a snapshot (position/yaw are eased toward in _process; first snapshot snaps). Also valid on the authority
## (host migration / tests), where it simply teleports and sets the state without running enter().
func apply_net_state(d: Dictionary) -> void:
	_net_pos = d["pos"]
	_net_yaw = float(d["yaw"])
	var new_hp := float(d["hp"])
	if _net_seen and new_hp < hp - 0.001 and not is_multiplayer_authority():
		_flash = 1.0   # a puppet sees the hit as the hp drop: same flash and `damaged` signal the authority has
		var lost := hp - new_hp
		hp = new_hp
		damaged.emit(lost, hp, null)
	hp = new_hp
	aim = d.get("aim", aim)
	net_age = float(d.get("t", 0.0))
	var st := int(d["state"])
	if not _net_seen:
		global_position = _net_pos
		rotation.y = _net_yaw
		_net_seen = true
	var old := sm.id()
	if st != old:
		sm.force(st)
		_remote_visual(st, String(d.get("anim", "idle")), old == -1)
		state_changed.emit(old, st)
	elif st == DmEnemyState.Id.IDLE or st == DmEnemyState.Id.CHASE or st == DmEnemyState.Id.RETURN:
		_anim = String(d.get("anim", _anim))


func _remote_visual(st: int, anim: String, first: bool) -> void:
	match st:
		DmEnemyState.Id.ATTACK:
			play_attack(windup_s)
			if not is_multiplayer_authority():
				announce_telegraph(maxf(0.05, windup_s - net_age))
		DmEnemyState.Id.HURT:
			play_hurt()
		DmEnemyState.Id.DEAD:
			if first and creature != null:
				creature.hold_last_frame("death")
			on_death()
		_:
			_anim = anim
	$Visual.visible = st != DmEnemyState.Id.BURROW and st != DmEnemyState.Id.ERUPT
	_remote_extra(st)


## Hide / show the body (and stop it colliding with players and enemies while it is below).
func set_underground(on: bool) -> void:
	$Visual.visible = not on
	collision_layer = 0 if on else LAYER_ENEMY
	collision_mask = LAYER_WORLD if on else (LAYER_WORLD | LAYER_PLAYER)
	agent.avoidance_enabled = use_avoidance and not on

func play_dig(seconds: float) -> void:
	_anim = "dig"
	if creature != null:
		creature.play_once("dig", 1.0, seconds)


## Puppet hook for kinds with their own states (dig / emerge clips).
func _remote_extra(_st: int) -> void:
	pass


func _puppet_step(delta: float) -> void:
	if not _net_seen or sm == null or sm.id() == DmEnemyState.Id.DEAD:
		return
	var before := global_position
	var diff := _net_pos - before
	if diff.length_squared() > 36.0:
		global_position = _net_pos
	else:
		global_position = before + diff * (1.0 - exp(-15.0 * delta))
	rotation.y = lerp_angle(rotation.y, _net_yaw, 1.0 - exp(-15.0 * delta))
	var sp := (global_position - before).length() / maxf(delta, 0.0001)
	_puppet_speed = lerpf(_puppet_speed, sp, 1.0 - exp(-10.0 * delta))
	_loco(_puppet_speed if _puppet_speed > 0.3 else 0.0)


func _on_target_gone() -> void:
	target = null
