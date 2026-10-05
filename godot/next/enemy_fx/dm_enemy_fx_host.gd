class_name DmEnemyFxHost
extends RefCounted
## The "game" a standalone DmEventFx instance needs (see dm_event_fx.gd header), reduced to what enemy telegraphs, deaths and hostile zones
## read: the local hero's position (for distance gating), a millisecond clock (fx_later), a camera to shake, a hitstop callback and an
## optional ripple surface. Everything else DmEventFx asks for is answered with "nothing" (no sim, no remotes, no views).
## DmEnemyFx owns one of these and refreshes `p` / `now_ms` once a frame, in place (no allocation).

## What DmEventFx.world() reads (zones/enemies/corpses maps are empty: the rebuilt enemies are nodes, not sim records).
class World:
	extends RefCounted
	var time: float = 0.0
	var enemies: Dictionary = {}
	var thralls: Dictionary = {}
	var zones: Dictionary = {}
	var corpses: Dictionary = {}
	var bossState = null

var self_id := "me"
var p: Dictionary = {"x": 0.0, "z": 0.0, "alive": true}
var now_ms := 0.0
var area_id := "graves"
var mirror := World.new()
var camera: Object = null          ## anything with shake(amount: float)
var dressing: Object = null        ## anything with add_ripple(x, z, size) / is_wet(x, z)
var hitstop_cb := Callable()       ## (seconds: float)


func hitstop(seconds: float) -> void:
	if hitstop_cb.is_valid():
		hitstop_cb.call(seconds)


func emit_game_event(_id: String, _ctx: Dictionary = {}) -> void:
	pass


func float_text(_x: float, _y: float, _z: float, _text: String, _kind: String) -> void:
	pass
