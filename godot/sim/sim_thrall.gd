class_name DmSimThrall
extends RefCounted
## A raised thrall (port of `Thrall` in types.ts). TS field names. target: enemy id or -1.

var id: int = 0
var owner: String = ""
var kind: String = "warrior"
var x: float = 0.0
var z: float = 0.0
var facing: float = 0.0
var hp: float = 0.0
var maxHp: float = 0.0
var damage: float = 0.0
var attackInterval: float = 1.0
var range: float = 1.3
var speed: float = 5.0
## 'rising' | 'idle' | 'move' | 'attack' | 'dead'
var state: String = "rising"
var stateT: float = 0.0
var attackCd: float = 0.0
var target: int = -1
var slot: int = 0
var bornAt: float = 0.0
var empowered: bool = false
var flash: float = 0.0
var gait: float = 0.0
var moving: bool = false
var rallyT: float = 0.0
var champion: bool = false
## Veilwalker Echo: expiry sim time, or -1 when not an echo.
var echoUntil: float = -1.0
var allyHeal: float = 0.0
var cursedT: float = 0.0
var stallT: float = 0.0
## Detour waypoints: Array of Vector2(x, z); empty = none. detourUntil is a sim time.
var detour: Array = []
var hasDetour: bool = false
var detourUntil: float = 0.0
var nextPathAt: float = 0.0
## Formation seat of the previous tick (NAN = none yet).
var seatX: float = NAN
var seatZ: float = NAN
