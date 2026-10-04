class_name DmBossState
extends RefCounted
## Port of `BossState` (types.ts). Shared between the sim and the bosses track's brains. TS field names.
## state: 'idle' | 'move' | 'toll' | 'slam' | 'rain' | 'summon' | 'dead' | 'sunk'

var id: String = "prelate"
var active: bool = false
var x: float = 0.0
var z: float = 0.0
var facing: float = 0.0
var hp: float = 1.0
var maxHp: float = 1.0
var phase: int = 1
var state: String = "idle"
var stateT: float = 0.0
var flash: float = 0.0
var fracture: float = 0.0
var fractureT: float = 0.0
var withered: float = 0.0
var witheredT: float = 0.0
var witheredDps: float = 0.0
var level: float = 1.0
var empowered: bool = false


## Wire form: `empowered` is only present when true (absent = false, like an older snapshot).
func to_dict() -> Dictionary:
	var d := {
		"id": id, "active": active, "x": x, "z": z, "facing": facing, "hp": hp, "maxHp": maxHp, "phase": phase, "state": state,
		"stateT": stateT, "flash": flash, "fracture": fracture, "fractureT": fractureT, "withered": withered, "witheredT": witheredT,
		"witheredDps": witheredDps, "level": level,
	}
	if empowered:
		d["empowered"] = true
	return d


func from_dict(d: Dictionary) -> void:
	for k in d:
		if k in self:
			set(k, d[k])
