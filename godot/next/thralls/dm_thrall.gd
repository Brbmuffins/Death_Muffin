class_name DmThrall
extends CharacterBody3D
## One raised thrall (all 8 kinds, one script; the kind scenes only set `kind`). Same idioms as DmEnemy: CharacterBody3D (FLOATING) +
## NavigationAgent3D, an explicit state machine, host-authoritative brain, replicated through get_net_state()/apply_net_state() (no RPCs).
## Numbers: DmThralls (rules/combat) + DmSimData (RALLY, CHILL, BONE_HEX, PLAGUE_BURST, LEGEND, SIGNATURE.rend), AI constants DmSimConsts (the old sim).
##
## Target contract with enemies: group "dm_target", dm_alive() (false while rising/dead), dm_take_enemy_hit(), dm_target_weight()
## (DmEnemy.find_target multiplies the distance: shieldbearer 0.55 = draws aggro, everyone else 1.1).

signal hit_dealt(target: Node3D, amount: float)       ## host: a blow landed (the sim's thrallHit)
signal damaged(amount: float, hp_left: float, from: Node)
signal died(thrall: DmThrall)                          ## host; `dead_reason` is killed / crumbled / sacrificed / decayed (one arg: DmStatusSet listens)
signal status_applied(enemy: Node3D, kind: StringName, seconds: float)   ## wraith chill, bone mage hex (already applied through DmStatusSet)
signal bell_heal(at: Vector3, frac: float)             ## Mourning Bell wraith hit: heal allies near `at`
signal plague_pool(at: Vector3, radius: float, seconds: float, dps: float)

enum S { RISING, IDLE, MOVE, ATTACK, DEAD }            ## wire ids: only ever APPEND
const GROUP := &"dm_thrall"
const LAYER_THRALL := 8                                ## physics layer 4 "thrall" (project.godot name to add)
const REPATH_S := 0.3
const REPATH_MOVE_SQ := 1.0
const DIRECT_RANGE_SQ := 9.0
const SCAN_S := 0.25
const ENGAGE_RANGE := 10.0                             ## sim: pick the nearest enemy within 10 m of the thrall
const TURN_RATE := 14.0
const CORPSE_S := 1.4
const WEIGHT_SHIELD := 0.55
const WEIGHT_OTHER := 1.1
const SIT := {"warrior": 1, "shieldbearer": 1}

# --- config (set by DmThrallHost via configure() before add_child; puppets get the same dictionary) ---
@export var kind: String = "warrior"
@export var with_visual: bool = true
@export var use_nav: bool = true
@export var use_avoidance: bool = false             ## RVO jams a tight pack (flaky stuck thralls in tests); the host's soft separation spaces them instead
var id: int = 0
var owner_peer: int = 1
var owner_node: Node3D                                 ## host side: the owner's body (follow / leash)
var slot: int = 0
var born_at: float = 0.0
var max_hp: float = 1.0
var hp: float = 1.0
var damage: float = 1.0
var interval: float = 1.0
var attack_range: float = 1.3
var speed: float = 5.0
var speed_mult: float = 1.0                            ## DmStatusSet writes these two
var attack_rate_mult: float = 1.0
var empowered: bool = false
var champion: bool = false
var ally_heal: float = 0.0
var lifetime_s: float = 0.0                            ## > 0: crumbles ("decayed") after this long (Veilwalker echo)
var death_burst_frac: float = 0.0                      ## Legion of the Unburied (host sets from the owner's legend mods)
var mark_mult: float = 1.0                             ## Spear-rally mark on the target (host sets)
var rally_t: float = 0.0
var stun_t: float = 0.0
var cursed_t: float = 0.0
var sep_v := Vector3.ZERO                              ## soft separation push (m/s), written by the host
var formation_rank: int = 0
var formation_count: int = 3
var legion_id: String = ""                             ## discipline id (look); "" = default
var kit: Dictionary = {}                               ## optional {weapon, armor} legion kit pieces (look only)

# --- runtime ---
var state: int = S.RISING
var state_t: float = 0.0
var attack_cd: float = 0.4
var target: Node3D
var swing_n: int = 0
var aim := Vector3.ZERO
var radius: float = 0.4
var creature: DmCreature
var agent: NavigationAgent3D
var rng := RandomNumberGenerator.new()

var _dt: float = 0.0
var _want_vel := Vector3.ZERO
var _safe_vel := Vector3.ZERO
var _nav_goal := Vector3.INF
var _repath_t: float = 0.0
var _scan_t: float = 0.0
var _seat_prev := Vector3.INF
var _age: float = 0.0
var _flash: float = 0.0
var _anim_acc: float = 0.0
var _lod_interval: float = 0.0
var _lod_t: float = 0.0
var _bob: float = 0.0
var _own: bool = true
var _em_hex: int = 0
var _em_k: float = 0.0
var _rally_look: bool = false
var _ring: Variant
var _ring_r := 0.5
var _ring_hex := 0xffffff
var _low_hp := false
const LOW_HP_ENTER := 0.35
const LOW_HP_LEAVE := 0.5
const LOW_HP_HEX := 0xff5a46
var _vfx: Node
var _audio: Node
var dead_reason: String = ""
var _swing_seen: int = 0
var _net_pos := Vector3.ZERO
var _net_yaw: float = 0.0
var _net_seen: bool = false
var _puppet_speed: float = 0.0
var _hover: float = 0.0

static var profile: bool = false
static var prof_ticks: int = 0
static var prof_brain_us: int = 0
static var prof_scans: int = 0
static var _warmed: bool = false


static func prof_reset() -> void:
	prof_ticks = 0
	prof_brain_us = 0
	prof_scans = 0


## Load every thrall model once (host calls it at session load) so the first raise does not hitch.
static func warm() -> void:
	if _warmed:
		return
	_warmed = true
	var seen := {}
	for k in DmThralls.KINDS:
		var slug := String(DmEntityViews.THRALL_SLUG.get(k, "skeleton_thrall"))
		if not seen.has(slug):
			seen[slug] = true
			DmCreature.new(slug, {}).dispose()


## Stats + identity in one dictionary: DmThralls.raise_stats output plus {id, owner_peer, slot, kind}. Call before add_child.
func configure(d: Dictionary) -> void:
	id = int(d.get("id", id))
	kind = String(d.get("kind", kind))
	owner_peer = int(d.get("owner_peer", owner_peer))
	slot = int(d.get("slot", slot))
	max_hp = float(d.get("maxHp", max_hp))
	hp = float(d.get("hp", max_hp))
	damage = float(d.get("damage", damage))
	interval = float(d.get("attackInterval", interval))
	attack_range = float(d.get("range", attack_range))
	speed = float(d.get("speed", speed))
	empowered = bool(d.get("empowered", false))
	champion = bool(d.get("champion", false))
	ally_heal = float(d.get("allyHeal", 0.0))
	legion_id = String(d.get("legion", legion_id))
	if d.has("pos"):
		position = d["pos"]
	if d.has("yaw"):
		rotation.y = float(d["yaw"])


func spawn_info() -> Dictionary:
	return {"id": id, "kind": kind, "owner_peer": owner_peer, "slot": slot, "maxHp": max_hp, "hp": hp, "damage": damage,
		"attackInterval": interval, "range": attack_range, "speed": speed, "empowered": empowered, "champion": champion,
		"allyHeal": ally_heal, "legion": legion_id, "pos": global_position, "yaw": rotation.y}


func _ready() -> void:
	DmSimData.ensure()
	rng.randomize()
	_repath_t = rng.randf() * REPATH_S
	_scan_t = rng.randf() * SCAN_S
	radius = 0.8 if kind == "colossus" else 0.4
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	max_slides = 3
	collision_layer = LAYER_THRALL
	collision_mask = DmEnemy.LAYER_WORLD
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = 1.7
	$Collision.shape = cyl
	$Collision.position.y = 0.85
	agent = $Nav
	agent.radius = radius
	agent.path_desired_distance = 1.0   # the baked navmesh floats 0.5 m above the floor: 3-D waypoint distance never drops below that
	agent.target_desired_distance = 1.0
	agent.path_max_distance = 2.0
	agent.max_speed = speed * 1.4
	agent.avoidance_enabled = use_avoidance
	agent.avoidance_layers = 2          # thralls avoid each other only; enemies (layer 1) walk up to them and swing
	agent.avoidance_mask = 2
	agent.neighbor_distance = 3.0
	agent.max_neighbors = 4
	agent.time_horizon_agents = 0.8
	agent.velocity_computed.connect(_on_safe_velocity)
	agent.target_position = global_position
	_vfx = get_tree().root.get_node_or_null("Vfx")
	_audio = get_tree().root.get_node_or_null("AudioDirector")
	_own = not multiplayer.has_multiplayer_peer() or owner_peer == multiplayer.get_unique_id()
	if with_visual:
		_build_visual()
	add_to_group(&"dm_target")
	add_to_group(GROUP)
	state_t = 0.0
	if with_visual:
		_rise_fx()


func _exit_tree() -> void:
	if _ring != null:
		_ring.kill()
		_ring = null


func dm_alive() -> bool:
	return state != S.DEAD and state != S.RISING


func dm_target_weight() -> float:
	return WEIGHT_SHIELD if kind == "shieldbearer" else WEIGHT_OTHER


## Enemy blow lands (enemy.hit_target); take_damage applies the damage-taken multiplier.
func dm_take_enemy_hit(dmg: float, from: Node, _kind: String = "") -> void:
	take_damage(dmg, from)


## DmStatusSet / DoT / blows entry point (host only). Returns true when applied.
func take_damage(amount: float, from: Node = null, _allow_stagger: bool = true) -> bool:
	if not is_multiplayer_authority() or state == S.DEAD:
		return false
	var st := DmStatusSet.of(self)
	amount = DmStatusSet.scale_taken(self, amount)
	if st != null:
		amount = st.absorb(amount)
	hp -= amount
	_flash = 1.0
	damaged.emit(amount, hp, from)
	if hp <= 0.0:
		kill("killed")
	return true


func stun(seconds: float) -> void:
	if is_multiplayer_authority() and state != S.DEAD:
		stun_t = maxf(stun_t, seconds)


# ============================================================================================ brain (authority only)

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority() or state == S.DEAD:
		return
	var t0 := Time.get_ticks_usec() if profile else 0
	_dt = delta
	_age += delta
	state_t += delta
	attack_cd -= delta * attack_rate_mult * (float(DmSimData.RALLY["attackSpeedMult"]) if rally_t > 0.0 else 1.0)
	if rally_t > 0.0:
		rally_t = maxf(0.0, rally_t - delta)
	if cursed_t > 0.0:
		cursed_t = maxf(0.0, cursed_t - delta)
	if lifetime_s > 0.0 and _age >= lifetime_s:
		kill("decayed")
	elif owner_node == null or not is_instance_valid(owner_node) or (owner_node.has_method("dm_alive") and not owner_node.dm_alive()):
		kill("crumbled")
	elif stun_t > 0.0:
		stun_t -= delta
		_want_vel = Vector3.ZERO
		_move(delta)
	else:
		_think(delta)
		_move(delta)
	if profile:
		prof_ticks += 1
		prof_brain_us += Time.get_ticks_usec() - t0


func _think(delta: float) -> void:
	if state == S.RISING:
		if state_t >= DmSimConsts.THRALL_RISE_TIME:
			_set_state(S.IDLE)
		return
	var op := owner_node.global_position
	if _flat(op - global_position) > DmSimConsts.THRALL_TELEPORT:
		global_position = op + Vector3(rng.randf() - 0.5, 0.0, rng.randf() - 0.5) * 2.0
		target = null
		_nav_goal = Vector3.INF
	if not _target_ok(op):
		target = null
		_scan_t -= delta
		if _scan_t <= 0.0:
			_scan_t = SCAN_S
			target = _scan(op)
	if target != null:
		_engage(target.global_position, float(target.get("radius") if target.get("radius") != null else 0.4), delta)
	else:
		_follow(op, delta)


func _target_ok(op: Vector3) -> bool:
	if not is_instance_valid(target):   # before the cast: casting a freed enemy errors
		return false
	var e := target as DmEnemy
	if e == null or not e.is_inside_tree():
		return false
	var sid := e.sm.id()
	if sid == DmEnemyState.Id.DEAD or sid == DmEnemyState.Id.BURROW or sid == DmEnemyState.Id.RISING or not e.is_hittable():
		return false
	return _flat(e.global_position - op) - _edge(e) <= DmSimConsts.THRALL_LEASH


## Boss engage rule: a boss (group dm_boss, radius 1.6) counts from its edge in the engage range and the owner leash, so the legion
## commits to it when it is within reach of the fight instead of waiting until the boss is nearly on top of a thrall.
static func _edge(e: DmEnemy) -> float:
	return e.radius if e.is_in_group(&"dm_boss") else 0.0


func _scan(op: Vector3) -> Node3D:
	if profile:
		prof_scans += 1
	var best: Node3D = null
	var best_d := ENGAGE_RANGE
	var lim := DmSimConsts.THRALL_LEASH - 2.0
	var p := global_position
	for n in get_tree().get_nodes_in_group(&"dm_enemy"):
		var e := n as DmEnemy
		var sid := e.sm.id()
		if sid == DmEnemyState.Id.DEAD or sid == DmEnemyState.Id.BURROW or sid == DmEnemyState.Id.RISING or not e.is_hittable():
			continue
		var ep := e.global_position
		var edge := _edge(e)
		if _flat(ep - op) - edge > lim:
			continue
		var d := _flat(ep - p) - edge
		if d < best_d:
			best_d = d
			best = e
	return best


func _engage(tp: Vector3, trad: float, delta: float) -> void:
	var d := _flat(tp - global_position)
	if d > attack_range + trad:
		_steer(tp, 1.0, delta)
		_set_state(S.MOVE)
		return
	_want_vel = Vector3.ZERO
	_face(tp, delta)
	if attack_cd <= 0.0:
		attack_cd = interval
		_swing(target)
	elif state != S.ATTACK or state_t > 0.5:
		_set_state(S.IDLE)


## Formation: a ring of 1.9 m around the owner, seats dealt by rank among the living (the host sets formation_rank/count).
func _follow(op: Vector3, delta: float) -> void:
	var ang := float(formation_rank) / float(maxi(3, formation_count)) * TAU + PI
	var seat := Vector3(op.x + sin(ang) * 1.9, 0.0, op.z + cos(ang) * 1.9)
	var d := _flat(seat - global_position)
	var seat_v := 0.0
	if _seat_prev != Vector3.INF and delta > 1e-5:
		seat_v = minf(12.0, _flat(seat - _seat_prev) / delta)
	_seat_prev = seat
	var following := state == S.MOVE and (d > DmSimConsts.FOLLOW_ARRIVE or seat_v > DmSimConsts.FOLLOW_SEAT_MOVING)
	if d > 0.5 or following:
		var mult := 1.35 if d > 6.0 else 1.0
		if d <= 0.5:
			mult = maxf(0.05, minf(speed * mult, seat_v + d * DmSimConsts.FOLLOW_CATCHUP) / speed)
		_steer(seat, mult, delta)
		_set_state(S.MOVE)
	elif state == S.MOVE:
		_set_state(S.IDLE)


func _swing(e: Node3D) -> void:
	aim = e.global_position
	swing_n += 1
	_set_state(S.ATTACK)
	var dmg := damage * (float(DmSimData.RALLY["damageMult"]) if rally_t > 0.0 else 1.0) \
		* (float(DmSimData.HAG_HEX["thrallDamageMult"]) if cursed_t > 0.0 else 1.0) * mark_mult
	var mine := DmStatusSet.of(self)
	if mine != null:
		dmg *= mine.damage_dealt_mult()
	DmStatusSet.hit(e, dmg, self)
	match kind:
		"wraith":
			DmStatusSet.ensure(e).apply(&"chill", self)
			status_applied.emit(e, &"chill", float(DmSimData.CHILL["durationS"]))
			if ally_heal > 0.0:
				bell_heal.emit(global_position, ally_heal)
		"bonemage":
			DmStatusSet.ensure(e).apply(&"hex", self)
			status_applied.emit(e, &"hex", float(DmSimData.BONE_HEX["durationS"]))
		"colossus":
			_cleave(e, dmg)
	hit_dealt.emit(e, dmg)
	_swing_visual()


func _cleave(main: DmEnemy, dmg: float) -> void:
	var C: Dictionary = DmSimData.RUNE_TUNING["colossus"]
	var part := dmg * float(C["cleaveFrac"])
	var r := float(C["cleaveRadius"])
	for n in get_tree().get_nodes_in_group(&"dm_enemy"):
		var o := n as DmEnemy
		if o == main or o.sm.id() == DmEnemyState.Id.DEAD or _flat(o.global_position - main.global_position) > r + o.radius:
			continue
		DmStatusSet.hit(o, part, self)


## Rally the Dead (host): heal, +40% damage / +30% attack speed for `secs`, optionally all turn on `focus`.
func rally(secs: float, focus: Node3D = null) -> void:
	rally_t = secs
	hp = minf(max_hp, hp + max_hp * float(DmSimData.RALLY["healFrac"]))
	if focus != null and _flat(focus.global_position - global_position) < DmSimConsts.THRALL_LEASH:
		target = focus


func kill(reason: String) -> void:
	if state == S.DEAD:
		return
	dead_reason = reason
	_set_state(S.DEAD)
	died.emit(self)
	if kind == "plaguebearer" and reason != "crumbled":
		var P: Dictionary = DmSimData.PLAGUE_BURST
		var pb := DmThralls.plague_burst(damage)
		_burst(float(P["radius"]), float(pb["dmg"]))
		plague_pool.emit(global_position, float(P["poolRadius"]), float(P["poolMs"]) / 1000.0, float(pb["poolDps"]))
	if reason == "killed" and death_burst_frac > 0.0:
		_burst(float(DmSimData.LEGEND["deathBurstR"]), DmThralls.death_burst_damage(death_burst_frac, max_hp))


func _burst(r: float, dmg: float) -> void:
	for n in get_tree().get_nodes_in_group(&"dm_enemy"):
		var e := n as DmEnemy
		if e.sm.id() != DmEnemyState.Id.DEAD and _flat(e.global_position - global_position) <= r + e.radius:
			DmStatusSet.hit(e, dmg, self)


func _set_state(s: int) -> void:
	if s == state:
		return
	state = s
	state_t = 0.0
	if s == S.DEAD:
		_on_dead()


# ---- movement (same shape as DmEnemy.steer_to / _move)

func _steer(goal: Vector3, mult: float, _delta: float) -> void:
	var pos := global_position
	var flat := Vector3(goal.x - pos.x, 0.0, goal.z - pos.z)
	var d2 := flat.length_squared()
	if d2 < 0.0025:
		return
	var dir := flat
	if use_nav and d2 > DIRECT_RANGE_SQ:
		_repath_t -= _dt
		if _repath_t <= 0.0:
			_repath_t = REPATH_S
			if _nav_goal == Vector3.INF or goal.distance_squared_to(_nav_goal) > REPATH_MOVE_SQ:
				_nav_goal = goal
				agent.target_position = goal
		if _nav_goal != Vector3.INF:
			var nxt := agent.get_next_path_position()
			var step := Vector3(nxt.x - pos.x, 0.0, nxt.z - pos.z)
			if step.length_squared() > 0.0004:
				dir = step
	var v := speed * speed_mult * mult
	_want_vel = dir.normalized() * minf(v, sqrt(d2) / maxf(_dt, 0.0001))


func _move(delta: float) -> void:
	var v := _want_vel
	if agent.avoidance_enabled and v != Vector3.ZERO:
		agent.velocity = v
		v = _safe_vel
	velocity = v + sep_v
	if v != Vector3.ZERO or sep_v != Vector3.ZERO:
		move_and_slide()
	if v != Vector3.ZERO:
		rotation.y = lerp_angle(rotation.y, atan2(v.x, v.z), minf(1.0, TURN_RATE * delta))
	_loco(_want_vel.length())
	_want_vel = Vector3.ZERO


func _on_safe_velocity(safe: Vector3) -> void:
	_safe_vel = Vector3(safe.x, 0.0, safe.z)


func _face(p: Vector3, dt: float) -> void:
	var d := p - global_position
	if d.x * d.x + d.z * d.z > 0.0001:
		rotation.y = lerp_angle(rotation.y, atan2(d.x, d.z), minf(1.0, TURN_RATE * dt))


func _flat(v: Vector3) -> float:
	return sqrt(v.x * v.x + v.z * v.z)


# ============================================================================================ visuals (every peer)

func _build_visual() -> void:
	var wraith := kind == "wraith"
	var look: Variant = DmEntityViews.THRALL_LOOK.get(kind)
	var legion: Variant = null
	if look == null:
		legion = DmEntityViews.LEGION.get("mourner" if wraith else legion_id)
	var kw: Variant = kit.get("weapon") if DmEntityViews.KIT_BODIES.has(kind) else null
	var ka: Variant = kit.get("armor") if DmEntityViews.KIT_BODIES.has(kind) else null
	var slug: String = String(legion.slug) if legion != null else String(DmEntityViews.THRALL_SLUG.get(kind, "skeleton_thrall"))
	var glow: float = 1.1 if wraith else (float(look.glow) if look != null else (float(legion.get("glow", 0.18)) if legion != null else 0.18)) + (0.22 if empowered else 0.0)
	glow += 0.35 if champion else 0.0
	var em: int = int(look.emissive) if look != null else (int(legion.emissive) if legion != null and legion.has("emissive") else (0x8f9ed1 if wraith else 0x1f8f86))
	var spirit: int = DmFxData.spell("exhume", "spirit").to_html(false).hex_to_int()   # the original game's friendly rim/ring colour
	var rim_color := 0xd9a441 if champion else spirit
	var o := {
		"gear_tint": ka != null,
		"tint": int(look.tint) if look != null else (int(legion.get("tint", 0xf4ecff)) if legion != null and legion.has("tint") else (0xb9c4ff if wraith else 0xf4ecff)),
		"emissive": em, "emissive_intensity": glow, "spectral": wraith,
		"scale": (float(look.scale) if look != null and look.has("scale") else (1.1 if kind == "shieldbearer" else 1.0)) * (1.35 if champion else 1.0),
		"rim": {"color": rim_color, "strength": 1.4 if champion else (DmEntityViews.THRALL_RIM_OWN if _own else DmEntityViews.THRALL_RIM_ALLY)},
	}
	_em_hex = em
	_em_k = glow
	creature = DmCreature.new(slug, o)
	$Visual.add_child(creature.root)
	var armed: bool = legion == null or bool(legion.get("armed", false))
	if (kind == "warrior" or kind == "shieldbearer") and armed:
		creature.attach("R_Hand", DmGearProps.bone_sword(int(DmGearProps.tier(String(kw.itemId), String(kw.get("rarity", ""))).color)) if kw != null else DmGearProps.bone_sword(), Vector3(0, 1, 0.55), 0.6)
		creature.attach("L_Hand", DmGearProps.round_shield(0.5 if kind == "shieldbearer" else 0.32), Vector3(0, 1, 0), 0.5)
	elif kind == "archer":
		var bow := DmGearProps.bone_bow()
		if kw != null:
			DmGearProps.upgrade_thrall_prop(bow, "bow", String(kw.itemId), String(kw.get("rarity", "")))
		creature.attach("L_Hand", bow, Vector3(0, 1, 0), 0.5)
	elif kind == "bonemage":
		var staff := DmGearProps.bone_staff()
		if kw != null:
			DmGearProps.upgrade_thrall_prop(staff, "staff", String(kw.itemId), String(kw.get("rarity", "")))
		creature.attach("R_Hand", staff, Vector3(0, 1, 0.12), 0.15)
	if ka != null:
		var tier := DmGearProps.tier(String(ka.itemId), String(ka.get("rarity", "")))
		for region in ["chest", "hands"]:
			creature.set_region_tint(region, {"color": tier.color, "glow": tier.glow if int(tier.glow) >= 0 else null, "strength": DmEntityViews.KIT_ARMOR_STRENGTH})
	creature.set_loop("idle")
	if wraith:
		_hover = 0.25
	# Ground ring in the legion's colour: gold = champion, blue = wraith, teal = spirit; dim when it is an ally's, not yours.
	var ring_r: float = (float(look.ring) if look != null and look.has("ring") else (0.6 if kind == "hound" else 0.5)) * (1.3 if champion else 1.0)
	var ring_hex := 0xd9a441 if champion else (0x8fb4ff if wraith else spirit)
	# The original game's ground ring: a Vfx decal that follows the body ("other" dims an ally's); gold = champion, blue = wraith.
	_ring_r = ring_r
	_ring_hex = ring_hex
	_make_ring()


## The ground ring (a decal that follows the body). A thrall under LOW_HP_ENTER of its health wears a pulsing red ring instead, so a failing legion
## member is findable at a glance; it goes back at LOW_HP_LEAVE (a Rally heal), so the ring is not rebuilt on every hit.
func _make_ring() -> void:
	if _ring != null:
		_ring.kill()
		_ring = null
	if _vfx == null:
		return
	var o := {"other": not _own, "tex": "ring", "color": LOW_HP_HEX if _low_hp else _ring_hex, "x": global_position.x, "z": global_position.z, "r": _ring_r * (1.15 if _low_hp else 1.0),
		"duration": 1e9, "opacity": 0.95 if _low_hp else (1.0 if empowered else 0.7), "follow": func() -> Variant: return Vector3(global_position.x, 0.0, global_position.z) if is_inside_tree() else null}
	if _low_hp:
		o["pulse"] = 4.0
	_ring = _vfx.decal(o)


## Two compares per frame (no allocation); the ring is rebuilt only when the state flips.
func _low_hp_check() -> void:
	if _ring == null or max_hp <= 0.0 or state == S.RISING:
		return
	var want := hp > 0.0 and hp < max_hp * (LOW_HP_LEAVE if _low_hp else LOW_HP_ENTER)
	if want != _low_hp:
		_low_hp = want
		_make_ring()


func play_attack() -> void:
	if creature != null:
		creature.play_strike("attack", 0.12)


func _swing_visual() -> void:
	play_attack()


func _on_dead() -> void:
	collision_layer = 0
	collision_mask = 0
	agent.avoidance_enabled = false
	remove_from_group(&"dm_target")
	if creature != null and not creature.play_death():
		creature.root.rotation.x = -PI * 0.5
	if _ring != null:
		_ring.kill()
	_death_fx()
	set_physics_process(false)
	get_tree().create_timer(CORPSE_S).timeout.connect(queue_free)


## The original game's rise (sigil, spirit motes, dirt, flash) and fall (bone chips, soul motes) looks, from DmEntityViews.on_event.
func _rise_fx() -> void:
	if _vfx == null:
		return
	var p := global_position
	var spirit: int = DmFxData.spell("exhume", "spirit").to_html(false).hex_to_int()
	_vfx.decal({"tex": "sigil", "color": spirit, "x": p.x, "z": p.z, "r": 1.4, "duration": 1.3, "opacity": 0.9, "growFrom": 0.2, "spin": 2.0})
	_vfx.emit({"x": p.x, "y": 0.2, "z": p.z, "count": 40, "color": spirit, "spread": 0.5, "speed": 0.6, "up": 3.6, "life": 1, "size": 0.36, "gravity": -0.6})
	_vfx.motifs.grave_dirt(p.x, p.z, {"r": 0.5, "n": 6, "up": 2.6, "origin": "thrall"})
	if _audio != null:
		_audio.play_sfx("thrallRise", Vector2(p.x, p.z), 1.0)


func _death_fx() -> void:
	if _vfx == null:
		return
	var p := global_position
	_vfx.emit({"x": p.x, "y": 0.8, "z": p.z, "count": 30 if dead_reason == "sacrificed" else 14, "color": 0xd8cfbd, "spread": 0.5, "speed": 2, "up": 1.2, "life": 0.8, "size": 0.25, "gravity": 3})
	if dead_reason != "sacrificed":
		_vfx.motifs.bone_splinters(p.x, 0.7, p.z, {"n": 4, "origin": "thrall"})
		_vfx.motifs.soul_motes(p.x, p.z, 0xd8cfbd, {"r": 0.3, "n": 3, "y": 0.6, "up": 1.2, "origin": "thrall"})
	if dead_reason == "killed" and _audio != null:
		_audio.play_sfx("thrallDeath", Vector2(p.x, p.z), 1.0)


func current_clip() -> String:
	return creature.ap.current_animation if creature != null and creature.ap != null else ""


func _loco(ground: float) -> void:
	if state == S.ATTACK or state == S.DEAD or creature == null:
		return
	if ground > 0.2:
		creature.set_ground_speed(snappedf(ground, 0.25))
	else:
		creature.set_loop("idle")


func _process(delta: float) -> void:
	if not is_multiplayer_authority():
		_puppet_step(delta)
	if creature == null or state == S.DEAD and not creature.busy():
		return
	if _hover > 0.0:
		_bob += delta
		$Visual.position.y = _hover + sin(_bob * 2.5 + float(id)) * 0.1
	if state == S.RISING:
		var k := minf(1.0, state_t / DmSimConsts.THRALL_RISE_TIME)
		$Visual.position.y = _hover - 1.8 * (1.0 - k) * (1.0 - k)
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 5.0)
		creature.set_flash(_flash)
	_low_hp_check()
	var want_rally := rally_t > 0.0
	if want_rally != _rally_look:
		_rally_look = want_rally
		creature.set_emissive(0xffd27a if want_rally else _em_hex, _em_k + 0.45 if want_rally else _em_k)
	# animation LOD as DmEnemy: near every frame, mid ~24 Hz, far ~10 Hz; swings / death at full rate
	_anim_acc += delta
	_lod_t -= delta
	if _lod_t <= 0.0:
		_lod_t = 0.5
		_lod_interval = 0.0
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam != null:
			_lod_interval = DmCreature.lod_interval(cam, global_position)
	if _anim_acc >= _lod_interval or creature.busy():
		creature.steady_every = 1 if _lod_interval == 0.0 else 2
		creature.update(_anim_acc)
		_anim_acc = 0.0


# ============================================================================================ replication seam

func get_net_state() -> Dictionary:
	return {"pos": global_position, "yaw": rotation.y, "state": state, "hp": hp, "swing": swing_n, "aim": aim, "rally": rally_t > 0.0, "why": dead_reason}


func apply_net_state(d: Dictionary) -> void:
	_net_pos = d["pos"]
	_net_yaw = float(d["yaw"])
	hp = float(d["hp"])
	dead_reason = String(d.get("why", dead_reason))
	rally_t = 0.3 if bool(d.get("rally", false)) else 0.0
	if not _net_seen:
		global_position = _net_pos
		rotation.y = _net_yaw
		_net_seen = true
		_swing_seen = int(d["swing"])
	var st := int(d["state"])
	if st != state:
		var old := state
		state = st
		state_t = 0.0
		if st == S.DEAD:
			if old != S.DEAD:
				_on_dead()
	if int(d["swing"]) != _swing_seen:
		_swing_seen = int(d["swing"])
		aim = d["aim"]
		state = S.ATTACK if state != S.DEAD else state
		_swing_visual()
	elif state == S.ATTACK and st != S.ATTACK:
		state = st


func _puppet_step(delta: float) -> void:
	if not _net_seen or state == S.DEAD:
		return
	state_t += delta
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
