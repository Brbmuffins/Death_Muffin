class_name DmSimPlayer
extends RefCounted
## A player body as the host sees it (port of `PlayerBody`). The world scene owns the real body and calls sim.set_player(body) each frame.
## area: area id or "" (null). family: class family id ("necromancer", "veil", ...) or "".

var id: String = ""
var x: float = 0.0
var z: float = 0.0
var alive: bool = true
var area: String = ""
var family: String = ""
var level: float = 0.0


static func make(p_id: String, p_x: float, p_z: float, p_area: String, p_alive: bool = true, p_level: float = 0.0, p_family: String = "") -> DmSimPlayer:
	var b := DmSimPlayer.new()
	b.id = p_id
	b.x = p_x
	b.z = p_z
	b.area = p_area
	b.alive = p_alive
	b.level = p_level
	b.family = p_family
	return b
