class_name DmBoss
extends Node3D
## One boss as a node: the body of an EXTERNAL entity of the combat core (kind 1, DECISIONS B42) whose BRAIN is the existing per-boss brain of godot/sim/bosses
## (DmBossBrain: awaken, phases at 60/30 %, telegraph + resolve loop, arena leash, the numbers in content/bosses.json) running on the host through a DmBossNodeWorld.
## The arenas are open rings and the brain owns movement. The look is the original game's DmBossView (model, clips, glow, rise/fade) fed from a DmBossState; the
## effects are the current DmEventFx boss events (DmBossFx), exactly once per peer. See README.md.
##
## Ported to the combat core (client/code.list "Ported"). Today it is a DmEnemy, so rites, thralls, statuses, the hover pick and rewards treat it as an enemy; here
## it is a plain node and the core's world is told about it: it registers as an external (`core_id`, DmCoreHost.register_boss), DmCoreHost writes its place and
## whether it can be hurt into the core before every step (thralls then pick it by their boss rule and their blows come back as EV_THRALL_HIT_EXTERNAL), and the
## host's queries and damage calls (`enemies_in_radius`, `foe`, `damage`, `apply_status` ...) answer for its id (a rite hits it through `take_damage`). What it
## took from DmEnemy is here as small fields (hp, max_hp, radius, `damaged`, `died`); its statuses stay a GDScript DmStatusSet (B42). No collision, no navmesh agent,
## no state machine (the labels nobody read).
##
## Host: _physics_process pumps `brain.update(dt)` and mirrors the result (position, hp, phase, state) onto the body. Everywhere else the node is
## a puppet fed by DmBossHost's snapshots (`get_net_state` / `apply_net_state`). A guest's puppet is known to its puppet core host by the id the host's core gave the boss (told in the state),
## for the queries only (the hover pick, a cast's aim): nothing is written to the guest's core, which has no externals.

signal phase_changed(phase: int)
signal damaged(amount: float, hp_left: float, from: Node)
signal died(boss: DmBoss)           ## host: the fight was won (DmStatusSet clears its set on it, thralls drop it, rewards)

const BOSS_RADIUS := 1.6
const STUN_CAP_S := 0.5       ## a rite stun staggers the boss at most this long ...
const STUN_ICD_S := 8.0       ## ... and at most this often (anti stun-lock)
const GROUP := &"dm_boss"
const JUMP_M := 4.0           ## a brain position this far (m) from the body in one tick is a relocation: no interpolation glide

var boss_id: String = "gravedigger"
var def_id: String = ""                   ## "boss_<id>", the def DmBoss.ensure_def registered (the codex, DmFoe's scale)
var empowered: bool = false
var summoner: int = 0                     ## peer that woke it
var host_node: DmBossHost
var brain: DmBossBrain                    ## host only
var world: DmBossNodeWorld                ## host only
var bstate := DmBossState.new()           ## what DmBossView reads (every peer)
var view: DmBossView
var phase: int = 1
var telegraphs: Array = []                ## [[kind, seconds_left, radius]] live telegraphs (host: from the brain, puppets: from snapshots)
var visual := true
var core_id: int = 0                      ## this body's id in the host's combat core (an external of kind 1): set when it registers in _ready; a guest learns it from the first state
var max_hp: float = 1.0
var hp: float = 1.0
var radius: float = BOSS_RADIUS
var dead := false                         ## the fight was won (finish(true)): it takes no more blows and the brain stops
var _stun_icd: float = 0.0
var _net_pos := Vector3.ZERO
var _net_yaw: float = 0.0
var _net_seen := false


## The enemy def the codex and DmFoe read (they need def_id in DmSimData.ENEMIES). Registered once, never overwrites a real def.
static func def_key(id: String) -> String:
	return "boss_" + id


static func ensure_def(id: String) -> void:
	DmSimData.ensure()
	var key := def_key(id)
	if DmSimData.ENEMIES.has(key):
		return
	var bd: Dictionary = DmContent.boss(id)
	DmSimData.ENEMIES[key] = {"id": key, "name": bd["name"], "behavior": "boss", "rig": "humanoid", "hp": 1.0, "speed": 1.8, "radius": BOSS_RADIUS, "damage": 0.0,
		"attackRange": 4.5, "windupMs": 900, "cooldownMs": 3400, "xp": 0, "gold": [0, 0], "corpse": "normal", "scale": 1.0, "modelSlug": bd["modelSlug"],
		"inert": true}


func _ready() -> void:
	add_to_group(GROUP)
	# The brain moves the body in _physics_process: interpolate it. A puppet is eased in _process, so it must not be.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON if is_multiplayer_authority() else Node.PHYSICS_INTERPOLATION_MODE_OFF
	reset_physics_interpolation()
	DmStatusSet.attach(self)   # every peer, same path: statuses (fracture, withered, bleed ...) replicate like any enemy's
	if visual:
		view = DmBossView.new()
		view.setup(get_parent(), boss_id)
		tree_exiting.connect(func() -> void:
			if view != null:
				view.dispose.call_deferred()   # the parent is busy while its child exits
				view = null)
	bstate.id = boss_id
	if not is_multiplayer_authority():
		damaged.connect(func(_a: float, _h: float, _f: Node) -> void: bstate.flash = 1.0)   # a puppet sees a hit as an hp drop
	if is_multiplayer_authority() and host_node != null:
		world = DmBossNodeWorld.new(host_node, self)
		brain = DmBossBrains.make(world, boss_id)
		world.refresh()
		brain.awaken(str(summoner), empowered)
		var ch: DmCoreHost = world.core()
		if ch != null:   # an external of the core: its place and whether it can be hurt are written before every step; thralls pick it and hit it through the core
			core_id = ch.register_boss(self)
			tree_exiting.connect(func() -> void:
				if is_instance_valid(ch):   # the scene may be coming down: the host can be gone first
					ch.unregister_boss(self))
		_mirror()


## Awake (summoned and not defeated / reset), whether or not it can be hit right now.
func is_awake() -> bool:
	return bstate.active and not dead


## Untargetable (rites, thralls, the hover pick) while the Mire Mother is sunk; the brain also refuses damage then. This is the core external's `alive`.
func is_hittable() -> bool:
	return is_awake() and bstate.state != "sunk"


# ============================================================================================ host brain

func _physics_process(delta: float) -> void:
	if brain == null or dead:
		return
	_stun_icd -= delta
	world.t += delta
	world.refresh()
	brain.update(delta)
	_mirror()


## Brain state -> body (position, hp, phase).
func _mirror() -> void:
	var s: Dictionary = brain.state
	var to := Vector3(float(s["x"]), 0.0, float(s["z"]))
	var jump := to.distance_squared_to(global_position) > JUMP_M * JUMP_M
	global_position = to
	if jump:
		reset_physics_interpolation()   # a phase relocation / emerge is a teleport, not a 60 m/s glide
	rotation.y = float(s["facing"])
	max_hp = float(s["maxHp"])
	hp = maxf(0.0, float(s["hp"]))
	bstate.active = bool(s["active"])
	bstate.x = float(s["x"])
	bstate.z = float(s["z"])
	bstate.facing = float(s["facing"])
	bstate.flash = float(s["flash"])
	bstate.state = String(s["state"])
	bstate.phase = int(s["phase"])
	bstate.empowered = bool(s.get("empowered", false))
	if bstate.phase != phase:
		phase = bstate.phase
		phase_changed.emit(phase)


## The brain reported the end of the fight (host, called by DmBossHost from the "defeated" event). `killed`: false = the party wiped / left.
func finish(killed: bool) -> void:
	_mirror()
	bstate.active = false
	if killed:
		bstate.state = "dead"
		hp = 0.0
		dead = true
		set_physics_process(false)
		died.emit(self)   # rewards, the status set clears; thralls drop it (is_hittable is false: the core's external is not alive)
	else:
		bstate.state = "idle"


## A blow: from a rite (the host's `damage` call), a thrall (EV_THRALL_HIT_EXTERNAL) or a DoT lump of its status set. `from` is the hero body or thrall owner that
## gets the kill (the brain's `last_hit_by` is its peer). The status set's damage-taken multiplier is not applied: the brain takes the blow as it is (it does today).
func take_damage(amount: float, from: Node = null, _allow_stagger: bool = true) -> bool:
	if brain == null or not is_multiplayer_authority() or not is_hittable():
		return false
	brain.damage(amount, _credit(from), 0)   # Fracture is the brain's, never passed in
	hp = maxf(0.0, float(brain.state["hp"]))
	damaged.emit(amount, hp, from)
	if hp <= 0.0:
		brain.update(0.0)   # the brain reports the defeat now, not next tick
		_mirror()
	return true


func stun(seconds: float) -> void:
	if brain == null or not is_hittable() or _stun_icd > 0.0:
		return
	_stun_icd = STUN_ICD_S
	brain.stagger(minf(seconds, STUN_CAP_S))


## "peer id" of whoever dealt a blow (a player body, or a thrall's owner); "" when unknown.
static func _credit(from: Node) -> String:
	if from == null:
		return ""
	var p: Variant = from.get("owner_peer")
	return str(int(p)) if p != null else ""


# ============================================================================================ replication

func get_net_state() -> Dictionary:
	var d := {"pos": global_position, "yaw": rotation.y, "hp": hp}
	d["ph"] = phase
	d["mx"] = max_hp
	d["act"] = bstate.active
	d["bs"] = bstate.state
	d["emp"] = bstate.empowered
	d["cid"] = core_id
	var tl: Array = []
	if brain != null:
		var now: float = world.now()
		for p in brain.pending:
			tl.append([p.kind, maxf(0.0, p.at - now), p.r])
	d["tl"] = tl
	return d


func apply_net_state(d: Dictionary) -> void:
	max_hp = float(d.get("mx", max_hp))
	var first := not _net_seen
	_net_pos = d["pos"]
	_net_yaw = float(d["yaw"])
	var new_hp := float(d["hp"])
	if _net_seen and new_hp < hp - 0.001 and not is_multiplayer_authority():
		var lost := hp - new_hp
		hp = new_hp
		damaged.emit(lost, hp, null)   # a puppet sees the hit as the hp drop
	hp = new_hp
	if first:
		global_position = _net_pos
		rotation.y = _net_yaw
		reset_physics_interpolation()
		_net_seen = true
	bstate.active = bool(d.get("act", false))
	bstate.state = String(d.get("bs", "idle"))
	bstate.empowered = bool(d.get("emp", false))
	bstate.phase = int(d.get("ph", 1))
	bstate.x = float(d["pos"].x) if first else bstate.x
	bstate.z = float(d["pos"].z) if first else bstate.z
	telegraphs = d.get("tl", [])
	if core_id == 0 and int(d.get("cid", 0)) != 0 and host_node != null:
		_adopt(int(d["cid"]))
	if bstate.phase != phase:
		phase = bstate.phase
		phase_changed.emit(phase)
		if first and phase >= 3 and host_node != null:
			host_node.replay_pits(self)   # a late joiner: the open graves have no event to wait for


## A guest: the host's id for this boss, and the puppet core host's list of bosses (the queries answer for it as they do on the host).
func _adopt(id: int) -> void:
	core_id = id
	var ch: DmCoreHost = host_node.core_host()
	if ch == null:
		return
	ch.adopt_boss(self, id)
	tree_exiting.connect(func() -> void:
		if is_instance_valid(ch):
			ch.unregister_boss(self))


func _process(delta: float) -> void:
	if brain == null:   # puppet: eased position / facing, local flash decay
		if _net_seen:
			var before := global_position
			var diff := _net_pos - before
			if diff.length_squared() > 36.0:
				global_position = _net_pos
			else:
				global_position = before + diff * (1.0 - exp(-15.0 * delta))
			rotation.y = lerp_angle(rotation.y, _net_yaw, 1.0 - exp(-15.0 * delta))
		bstate.x = global_position.x
		bstate.z = global_position.z
		bstate.facing = rotation.y
		bstate.flash = maxf(0.0, bstate.flash - delta * 4.0)
	else:   # host: the view and fx read the DRAWN (physics-interpolated) position; _mirror writes the tick position again next tick
		var ip := get_global_transform_interpolated().origin
		bstate.x = ip.x
		bstate.z = ip.z
	if view != null:
		view.sync(bstate, delta)
