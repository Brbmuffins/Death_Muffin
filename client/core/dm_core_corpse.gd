class_name DmCoreCorpse
extends RefCounted
## One corpse as a cast sees it: a snapshot of the combat core's record (`DmCore.corpse_info`), taken when the cast asks. The corpses themselves live
## in the core (laid at a death, expiring, consumed atomically); this is only what a rite reads before it consumes one. Field names are the corpse
## field's (DmCorpseField / the TS `Corpse`): `kind` is "normal", "swift", "resonant", "toxic" or "none"; `enemy` the def it came from ("risen" for the
## extra bodies and a sacrificed thrall's).

var id: int = 0
var x: float = 0.0
var z: float = 0.0
var kind: String = "normal"
var enemy: String = ""
var elite: bool = false
var facing: float = 0.0
var scale: float = 1.0
var area: String = ""


static func of(info: Dictionary) -> DmCoreCorpse:
	if info.is_empty():
		return null
	var c := DmCoreCorpse.new()
	c.id = int(info["id"])
	c.x = float(info["x"])
	c.z = float(info["z"])
	c.kind = String(info["kind"])
	c.enemy = String(info["enemy"])
	c.elite = bool(info["elite"])
	c.facing = float(info["facing"])
	c.scale = float(info["scale"])
	c.area = String(info["area"])
	return c
