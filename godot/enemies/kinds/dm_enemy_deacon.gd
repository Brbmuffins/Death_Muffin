class_name DmEnemyDeacon
extends DmEnemy
## Crypt Deacon (Ossuary, def `deacon`, behaviour "support"): a robed caster that keeps its distance (DmStateCathSupport) and, whenever its
## cooldown is up and it is not silenced, does the first of these (sim order, with or without a target):
##  1. RAISE: a corpse within 8 m -> a 1.5 s channel (telegraph "raise": thread from the Deacon to the corpse); at the end the corpse is consumed
##     ("raised") and a Risen spawns on it (`raised`; the wave director answers it).
##  2. SANCTIFY: the most wounded other non-Deacon ally within SANCTIFIED.range that is not already blessed gets `sanctified` (damage taken
##     x0.7 for 5 s, DmStatusSet); cooldown x0.6. `cue("sanctify", ally_pos)` for the thread/halo.
##  3. CURSE: the target within attackRange -> 1.5 s wind-up (telegraph "curse"), one blow of def damage.
## The corpse / Sanctify scan runs at the target-scan rate (0.25 s), not every tick.

signal raised(at: Vector3)    ## host: a Risen is being raised at `at` (the wave director spawns it)

const CORPSE_RANGE := 8.0
const FIND_RETRY_S := 2.0     ## re-search for the corpse field this often while none was found

var corpses: DmCorpseField    ## set by the integration; else found once by name ("Corpses") under the scene root
var swing_raise: bool = false ## the current swing is a raise (replicated as "rz")
var _raise_pending: int = -1  ## corpse id chosen by the trigger, adopted by begin_attack
var _raise_id: int = -1
var _support_t: float = 0.0
var _find_t: float = 0.0


func _ready() -> void:
	if model_slug == "":
		model_slug = "deacon"   # the def names no model
	super()
	attack_anim = "cast"
	_support_t = rng.randf() * SCAN_S


func _build_states() -> void:
	super()
	sm.add(DmStateCathSupport.new(self, DmEnemyState.Id.CHASE))


func silenced() -> bool:
	var ss := DmStatusSet.of(self)
	return ss != null and ss.is_silenced()


func _physics_process(delta: float) -> void:
	super(delta)
	if not is_multiplayer_authority():
		return
	_support_t -= delta
	if _support_t > 0.0 or attack_cd > 0.0:
		return
	_support_t = SCAN_S
	var sid := sm.id()
	if sid != DmEnemyState.Id.IDLE and sid != DmEnemyState.Id.CHASE and sid != DmEnemyState.Id.RETURN:
		return
	if silenced():
		return
	var c := _nearest_corpse()
	if c != null:
		_raise_pending = c.id
		aim = Vector3(c.x, 0.0, c.z)
		sm.change(DmEnemyState.Id.ATTACK)
		return
	var ally := sanctify_target()
	if ally != null:
		DmStatusSet.ensure(ally).apply(&"sanctified", self, 1, float(DmSimData.SANCTIFIED["durationS"]))
		attack_cd = float(def["cooldownMs"]) / 1000.0 * float(DmSimData.SANCTIFIED["cooldownMult"])
		cue.emit(&"sanctify", ally.global_position, 0.0)


func _nearest_corpse() -> DmSimCorpse:
	if corpses == null or not is_instance_valid(corpses):
		_find_t -= SCAN_S
		if _find_t > 0.0:
			return null
		_find_t = FIND_RETRY_S
		corpses = get_tree().root.find_child("Corpses", true, false) as DmCorpseField
		if corpses == null:
			return null
	if corpses.count() == 0:
		return null
	var l := corpses.corpses_in_radius(global_position, CORPSE_RANGE)
	return l[0] if not l.is_empty() else null


## The most wounded unblessed non-Deacon ally within reach (sim sanctify_target), or null.
func sanctify_target() -> DmEnemy:
	var best: DmEnemy = null
	var best_frac := 0.999
	var r2 := float(DmSimData.SANCTIFIED["range"]) * float(DmSimData.SANCTIFIED["range"])
	for n in get_tree().get_nodes_in_group(&"dm_enemy"):
		var o := n as DmEnemy
		if o == null or o == self or o.def_id == "deacon" or o.hp <= 0.0:
			continue
		var s := o.sm.id()
		if s == DmEnemyState.Id.DEAD or s == DmEnemyState.Id.RISING or s == DmEnemyState.Id.BURROW:
			continue
		var d := o.global_position - global_position
		if d.x * d.x + d.z * d.z > r2:
			continue
		var frac := o.hp / o.max_hp
		if frac >= best_frac:
			continue
		var st := DmStatusSet.of(o)
		if st != null and st.has(&"sanctified"):
			continue
		best_frac = frac
		best = o
	return best


func begin_attack() -> void:
	_raise_id = _raise_pending
	_raise_pending = -1
	swing_raise = _raise_id >= 0
	if swing_raise:
		face_point(aim, 1.0)
		announce_telegraph(windup_s)
	else:
		super()


func announce_telegraph(seconds: float) -> void:
	telegraph.emit(&"raise" if swing_raise else &"curse", global_position, aim, 0.0, seconds)


func strike() -> void:
	if not swing_raise:
		super()
		return
	swing_raise = false
	if corpses != null and is_instance_valid(corpses) and corpses.consume(_raise_id, 1, "raised"):
		raised.emit(aim)   # the wave director (host) spawns the Risen with this body's level / multipliers
	_raise_id = -1


func get_net_state() -> Dictionary:
	var d := super()
	d["rz"] = swing_raise
	return d


func apply_net_state(d: Dictionary) -> void:
	swing_raise = bool(d.get("rz", false))
	super(d)
