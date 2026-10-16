class_name DmFxLight
extends OmniLight3D
## Replacement for vfx_light.gd. The effect's own OmniLight3D is never lit natively (the web keeps one shared flash light so the
## lit-material light count never changes); DmFx reads `peak_energy()` and routes it through its single flash light.

var base_energy: float = -1.0
var light_multiplier: float = 1.0


func _ready() -> void:
	if base_energy < 0.0:
		base_energy = light_energy
	visible = false


func peak_energy() -> float:
	return base_energy if base_energy >= 0.0 else light_energy
