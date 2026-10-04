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


## The wire/JSON form (optional fields only when set, like JSON.stringify of the TS object).
func to_dict() -> Dictionary:
	var d := {"id": id, "kind": kind, "owner": owner, "x": x, "z": z, "r": r, "until": until, "bornAt": bornAt, "tick": tick, "dps": dps,
		"slow": slow, "witheredCap": witheredCap, "bloom": bloom, "hostile": hostile}
	if creep != 0.0:
		d["creep"] = creep
	if contagion:
		d["contagion"] = true
	if gen >= 0:
		d["gen"] = gen
	if spreadT != INF:
		d["spreadT"] = spreadT
	return d


static func from_dict(d: Dictionary) -> DmSimZone:
	var z := DmSimZone.new()
	z.id = int(d["id"])
	z.kind = d["kind"]
	z.owner = d["owner"]
	z.x = float(d["x"])
	z.z = float(d["z"])
	z.r = float(d["r"])
	z.until = float(d["until"])
	z.bornAt = float(d["bornAt"])
	z.tick = float(d["tick"])
	z.dps = float(d["dps"])
	z.slow = float(d["slow"])
	z.witheredCap = float(d["witheredCap"])
	z.bloom = bool(d["bloom"])
	z.hostile = bool(d["hostile"])
	z.creep = float(d.get("creep", 0.0))
	z.contagion = bool(d.get("contagion", false))
	z.gen = int(d["gen"]) if d.has("gen") else -1
	z.spreadT = float(d["spreadT"]) if d.has("spreadT") else INF
	return z
