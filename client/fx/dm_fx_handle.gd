class_name DmFxHandle
extends RefCounted
## What every DmFx spawn returns (the web's `Handle`: kill() + alive). Binbun handles also support move() and set_alpha().

var alive: bool:
	get:
		return is_alive()


func is_alive() -> bool:
	return false


func kill() -> void:
	pass


## Binbun only: move a following effect (`follow` does this for you).
func move(_p: Vector3) -> void:
	pass


## Binbun only: overall opacity multiplier.
func set_alpha(_a: float) -> void:
	pass
