class_name DmEnemyState
extends RefCounted
## Base class of one enemy behaviour state. A state owns its own timers; the enemy owns the body (movement, nav, animation, stats).
## `tick` runs only on the authority. `enter`/`exit` are authority-only too; a non-authority copy plays DmEnemy._remote_visual instead.

## State ids. The int is what goes over the wire in get_net_state(), so only ever APPEND.
enum Id { RISING, IDLE, CHASE, ATTACK, HURT, RETURN, DEAD }
const NAMES: Array[String] = ["rising", "idle", "chase", "attack", "hurt", "return", "dead"]

var id: int = Id.IDLE
var enemy: DmEnemy
var t: float = 0.0  ## seconds in this state

func _init(e: DmEnemy, state_id: int) -> void:
	enemy = e
	id = state_id

func enter(_prev: int) -> void:
	t = 0.0

func exit(_next: int) -> void:
	pass

## Called every physics tick on the authority; return the id of the state to switch to, or -1 to stay.
func tick(_dt: float) -> int:
	return -1
