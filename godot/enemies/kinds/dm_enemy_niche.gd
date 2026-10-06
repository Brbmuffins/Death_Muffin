class_name DmEnemyNiche
extends DmEnemy
## "support" inert kind: the Bone Abbess's Skull Niche. It only stands (the brain heals through it and fires its lances), never targets, moves or
## blows, and cannot be staggered or stunned. States are labels: RISING (the spawn rise), IDLE, DEAD. It crumbles when killed (the brain
## reports `nicheBreak`; the nicheBreak fx is the burst), so the body is hidden at once instead of toppling like a rig with no death clip.


func _ready() -> void:
	use_nav = false
	use_avoidance = false
	wander_enabled = false
	super()


func _build_states() -> void:
	sm.add(DmStateRising.new(self, DmEnemyState.Id.RISING))
	sm.add(DmEnemyState.new(self, DmEnemyState.Id.IDLE))
	sm.add(DmStateDead.new(self, DmEnemyState.Id.DEAD))


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority() or sm.id() == DmEnemyState.Id.IDLE:
		return   # nothing to think about while it stands
	sm.tick(delta)


func take_damage(amount: float, from: Node = null, _allow_stagger: bool = true) -> bool:
	return super(amount, from, false)


func stun(_seconds: float) -> void:
	pass


func on_death() -> void:
	super()
	if creature != null:
		creature.root.rotation.x = 0.0
		creature.root.visible = false
