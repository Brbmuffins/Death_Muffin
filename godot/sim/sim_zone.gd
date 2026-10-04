class_name DmSimZone
extends RefCounted
## A ground zone (port of `Zone`). TS field names. creep/contagion/gen/spreadT are optional in TS: creep 0 = none, gen -1 = none.

var id: int = 0
var kind: String = "miasma"
var owner: String = ""
var x: float = 0.0
var z: float = 0.0
var r: float = 1.0
var until: float = 0.0
var bornAt: float = 0.0
var tick: float = 0.0
var dps: float = 0.0
var slow: float = 1.0
var witheredCap: float = 0.0
var bloom: bool = false
var hostile: bool = false
var creep: float = 0.0
var contagion: bool = false
var gen: int = -1
var spreadT: float = INF
