class_name DmEnemyPfFlanker
extends DmEnemyFlanker
## Cinderhound and Mire Leech: the flank kinds (DmEnemyFlanker) with their look. The leech (def `rotBite`) also wiggles as it slithers, the views'
## squash-and-sway: scale (1 + .12 w, 1 - .09 w, 1 + .1 w) and roll .12 w, w = sin(t / 85 ms + id x 1.7) at full strength while moving, a quarter at rest.

var _wiggle: bool = false
var _phase: float = 0.0


func _ready() -> void:
	super()
	_wiggle = bool(def.get("rotBite", false)) and creature != null
	_phase = float(get_instance_id() % 97) * 1.7


func look_options() -> Dictionary:
	return DmPfUtil.look(super(), def_id)


func _process(delta: float) -> void:
	super(delta)
	if _wiggle and sm.id() != DmEnemyState.Id.DEAD and _lod_interval < 0.1:
		var w := sin(float(Time.get_ticks_msec()) / 85.0 + _phase) * (1.0 if (_anim == "walk" or _anim == "run") else 0.25)
		creature.root.scale = Vector3(1.0 + 0.12 * w, 1.0 - 0.09 * w, 1.0 + 0.1 * w)
		creature.root.rotation.z = 0.12 * w
