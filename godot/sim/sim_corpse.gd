class_name DmSimCorpse
extends RefCounted
## A corpse (port of `Corpse`). TS field names. kind: 'normal' | 'resonant' | 'swift' | 'toxic' | 'none'.

var id: int = 0
var x: float = 0.0
var z: float = 0.0
var kind: String = "normal"
var enemy: String = ""
var elite: bool = false
var facing: float = 0.0
var scale: float = 1.0
var area: String = ""
var bornAt: float = 0.0
var expiresAt: float = 0.0
## INF when it never ruptures.
var ruptureAt: float = INF
## Carrion Seed (seedOwner "" = none).
var seedOwner: String = ""
var seedDmg: float = 0.0
var seedCap: float = 0.0
var seedArmedAt: float = INF
var seedExpires: float = 0.0
## Echo corpses: "" none, a player id, or "*" for anyone.
var echoOwner: String = ""


## The wire/JSON form (what JSON.stringify gives the TS object: optional fields only when set, Infinity as null).
func to_dict() -> Dictionary:
	var d := {"id": id, "x": x, "z": z, "kind": kind, "enemy": enemy, "elite": elite, "facing": facing, "scale": scale, "area": area,
		"bornAt": bornAt, "expiresAt": expiresAt, "ruptureAt": (ruptureAt if ruptureAt != INF else null)}
	if seedOwner != "":
		d["seedOwner"] = seedOwner
		d["seedDmg"] = seedDmg
		d["seedCap"] = seedCap
		d["seedArmedAt"] = seedArmedAt if seedArmedAt != INF else null
		d["seedExpires"] = seedExpires
	if echoOwner != "":
		d["echoOwner"] = echoOwner
	return d


static func from_dict(d: Dictionary) -> DmSimCorpse:
	var c := DmSimCorpse.new()
	c.id = int(d["id"])
	c.x = float(d["x"])
	c.z = float(d["z"])
	c.kind = d["kind"]
	c.enemy = d["enemy"]
	c.elite = bool(d["elite"])
	c.facing = float(d["facing"])
	c.scale = float(d["scale"])
	c.area = d["area"]
	c.bornAt = float(d["bornAt"])
	c.expiresAt = float(d["expiresAt"])
	c.ruptureAt = float(d["ruptureAt"]) if d.get("ruptureAt") != null else INF
	if d.has("seedOwner"):
		c.seedOwner = d["seedOwner"]
		c.seedDmg = float(d.get("seedDmg", 0.0))
		c.seedCap = float(d.get("seedCap", 0.0))
		c.seedArmedAt = float(d["seedArmedAt"]) if d.get("seedArmedAt") != null else INF
		c.seedExpires = float(d.get("seedExpires", 0.0))
	if d.has("echoOwner"):
		c.echoOwner = d["echoOwner"]
	return c
