class_name DmEnemyStateMachine
extends RefCounted
## Tiny explicit state machine: a fixed array of DmEnemyState objects indexed by DmEnemyState.Id. No per-tick allocation.
##
## Why objects and not a `match` in the enemy: each state is a small file with its own timers, so the next enemy kind overrides one
## state (say a caster's ATTACK) and inherits the rest. Transitions are returned from tick() (`return DmEnemyState.Id.CHASE`) or forced
## from outside through change() (damage, stun, death).

signal changed(prev: int, next: int)

var states: Array[DmEnemyState] = []
var current: DmEnemyState
var prev_id: int = -1

func add(s: DmEnemyState) -> void:
	if states.size() <= s.id:
		states.resize(s.id + 1)
	states[s.id] = s

func id() -> int:
	return current.id if current != null else -1

func start(state_id: int) -> void:
	current = states[state_id]
	current.enter(-1)

func change(next_id: int) -> void:
	var s: DmEnemyState = states[next_id]
	if s == null:
		return
	var old := id()
	if current != null:
		current.exit(next_id)
	prev_id = old
	current = s
	current.enter(old)
	changed.emit(old, next_id)

## Advance the current state; follow at most one transition per tick (a state that chains is a bug, not a feature).
func tick(dt: float) -> void:
	current.t += dt
	var nxt := current.tick(dt)
	if nxt >= 0 and nxt != current.id:
		change(nxt)

## Non-authority: adopt a replicated state id without running enter/exit logic (the enemy plays the visual itself).
func force(state_id: int) -> void:
	var old := id()
	current = states[state_id]
	current.t = 0.0
	prev_id = old
