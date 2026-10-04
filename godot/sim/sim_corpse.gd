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
