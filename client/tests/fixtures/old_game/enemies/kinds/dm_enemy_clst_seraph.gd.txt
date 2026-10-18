class_name DmEnemyClstSeraph
extends DmEnemyClstCaster
## Weeping Seraph: a hovering support body. Every cooldown (8.5 s) it Sanctifies (DmStatusSet "sanctified": -30% damage taken, 5 s) up to
## WARD.maxTargets of the most wounded living allies within WARD.range, all at once, if at least one needs it; that spends the cooldown. With
## nobody to bless it casts the curse (DmEnemyClstCaster) on its target instead, from range, keeping 4 m away. Silenced: neither.

const WARD_RETRY_S := 0.25   ## no ally to bless: look again soon, not every tick

var _ward_t: float = 0.0


func _ready() -> void:
	super()
	attack_kind = "curse"   # support kinds have no def.attack; the sim casts `curse` for them


func kite_params() -> Array:
	return [0.0, 0.5, 4.0, 0.7]


func look_options() -> Dictionary:
	var o := super()
	o["wings"] = {"speed": 3.2, "amp": 0.22, "body": 0.3}
	return o


func _physics_process(delta: float) -> void:
	if is_multiplayer_authority():
		_ward_t -= delta
		var sid := sm.id()
		if attack_cd <= 0.0 and _ward_t <= 0.0 and sid != DmEnemyState.Id.ATTACK and sid != DmEnemyState.Id.HURT \
				and sid != DmEnemyState.Id.DEAD and sid != DmEnemyState.Id.RISING:
			var ss := DmStatusSet.of(self)
			if ss == null or not ss.is_silenced():
				_ward()
	super(delta)


func _ward() -> void:
	var W: Dictionary = DmSimData.WARD
	var r2 := float(W["range"]) * float(W["range"])
	var cand: Array = []
	for n in get_tree().get_nodes_in_group(&"dm_enemy"):
		var o := n as DmEnemy
		if o == null or o == self:
			continue
		var s := o.sm.id()
		if s == DmEnemyState.Id.DEAD or s == DmEnemyState.Id.RISING or s == DmEnemyState.Id.BURROW:
			continue
		var d := o.global_position - global_position
		if d.x * d.x + d.z * d.z > r2:
			continue
		var os := DmStatusSet.of(o)
		if os != null and os.has(&"sanctified"):
			continue
		cand.append(o)
	if cand.is_empty():
		_ward_t = WARD_RETRY_S
		return
	cand.sort_custom(func(a: DmEnemy, b: DmEnemy) -> bool: return a.hp / a.max_hp < b.hp / b.max_hp)
	for k in mini(cand.size(), int(W["maxTargets"])):
		var o: DmEnemy = cand[k]
		DmStatusSet.ensure(o).apply(&"sanctified", self)
		cue.emit(&"sanctify", o.global_position, 0.0)
	attack_cd = cooldown_s
