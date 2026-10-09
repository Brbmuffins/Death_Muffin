class_name DmBoss
extends DmEnemy
## One boss as a node: a DmEnemy (so rites, thralls, statuses, rewards and the HUD already know how to hit it) whose BRAIN is the existing
## per-boss brain of godot/sim/bosses (DmBossBrain: awaken, phases at 60/30 %, telegraph + resolve loop, arena leash, the numbers in
## content/bosses.json) running on the host through a DmBossNodeWorld. No navmesh / no DmEnemy state set: the arenas are open rings and the brain
## owns movement. The look is the original game's DmBossView (model, clips, glow, rise/fade) fed from a DmBossState; the effects are the
## current DmEventFx boss events (DmBossFx), exactly once per peer. See README.md.
##
## Host: _physics_process pumps `brain.update(dt)` and mirrors the result (position, hp, phase, state) onto the body. Everywhere else the node is
## a puppet fed by DmBossHost's snapshots (`get_net_state` / `apply_net_state`).

signal phase_changed(phase: int)

const BOSS_RADIUS := 1.6
const STUN_CAP_S := 0.5       ## a rite stun staggers the boss at most this long ...
const STUN_ICD_S := 8.0       ## ... and at most this often (anti stun-lock)
const GROUP := &"dm_boss"
static var _defs_ready: Dictionary = {}

var boss_id: String = "gravedigger"
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
var _stun_icd: float = 0.0
var _flash_k: float = 0.0


## The enemy def DmEnemy._ready reads (it needs def_id in DmSimData.ENEMIES). Registered once, never overwrites a real def.
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
	super()
	add_to_group(GROUP)
	use_nav = false
	use_avoidance = false
	wander_enabled = false
	collision_mask = 0
	collision_layer = LAYER_ENEMY
	radius = BOSS_RADIUS
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
		_mirror()


func _build_states() -> void:
	for id in [DmEnemyState.Id.RISING, DmEnemyState.Id.IDLE, DmEnemyState.Id.CHASE, DmEnemyState.Id.ATTACK]:
		sm.add(DmEnemyState.new(self, id))   # labels only: the brain decides, nothing ticks
	sm.add(DmStateDead.new(self, DmEnemyState.Id.DEAD))


func initial_state() -> int:
	return DmEnemyState.Id.IDLE


## Awake (summoned and not defeated / reset), whether or not it can be hit right now.
func is_awake() -> bool:
	return bstate.active and sm.id() != DmEnemyState.Id.DEAD


## Untargetable (rites, thralls, the hover pick, enemies' focus) while the Mire Mother is sunk; the brain also refuses damage then.
func is_hittable() -> bool:
	return is_awake() and bstate.state != "sunk"


# ============================================================================================ host brain

func _physics_process(delta: float) -> void:
	if brain == null or sm.id() == DmEnemyState.Id.DEAD:
		return
	var t0 := Time.get_ticks_usec() if profile else 0
	_stun_icd -= delta
	world.t += delta
	world.refresh()
	brain.update(delta)
	_mirror()
	if profile:
		prof_ticks += 1
		prof_brain_us += Time.get_ticks_usec() - t0


## Brain state -> body (position, hp, phase, the DmEnemy state label).
func _mirror() -> void:
	var s: Dictionary = brain.state
	global_position = Vector3(float(s["x"]), 0.0, float(s["z"]))
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
	var want := DmEnemyState.Id.ATTACK
	match bstate.state:
		"idle": want = DmEnemyState.Id.IDLE
		"move": want = DmEnemyState.Id.CHASE
	if sm.id() != DmEnemyState.Id.DEAD and sm.id() != want:
		sm.change(want)


## The brain reported the end of the fight (host, called by DmBossHost from the "defeated" event). `killed`: false = the party wiped / left.
func finish(killed: bool) -> void:
	_mirror()
	bstate.active = false
	if killed:
		bstate.state = "dead"
		hp = 0.0
		sm.change(DmEnemyState.Id.DEAD)   # on_death -> `died` (rewards, thrall retarget)
	else:
		bstate.state = "idle"


func take_damage(amount: float, from: Node = null, _allow_stagger: bool = true) -> bool:
	if brain == null or not is_multiplayer_authority() or not is_hittable():
		return false
	brain.damage(amount, _credit(from), 0)   # Fracture is the status set's (damage_taken_mult), not the brain's
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
	var d := super()
	d["ph"] = phase
	d["mx"] = max_hp
	d["act"] = bstate.active
	d["bs"] = bstate.state
	d["emp"] = bstate.empowered
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
	super(d)
	bstate.active = bool(d.get("act", false))
	bstate.state = String(d.get("bs", "idle"))
	bstate.empowered = bool(d.get("emp", false))
	bstate.phase = int(d.get("ph", 1))
	bstate.x = float(d["pos"].x) if first else bstate.x
	bstate.z = float(d["pos"].z) if first else bstate.z
	telegraphs = d.get("tl", [])
	if bstate.phase != phase:
		phase = bstate.phase
		phase_changed.emit(phase)
		if first and phase >= 3 and host_node != null:
			host_node.replay_pits(self)   # a late joiner: the open graves have no event to wait for


func _process(delta: float) -> void:
	super(delta)
	if brain == null:   # puppet: eased position / facing, local flash decay
		bstate.x = global_position.x
		bstate.z = global_position.z
		bstate.facing = rotation.y
		bstate.flash = maxf(0.0, bstate.flash - delta * 4.0)
	if view != null:
		view.sync(bstate, delta)
