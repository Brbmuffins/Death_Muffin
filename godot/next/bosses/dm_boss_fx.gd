class_name DmBossFx
extends Node
## Boss visuals and sounds on every peer, exactly once per event: the original game's own boss presentation (DmEventFx -> DmEventFxBoss:
## awaken / phase banners, telegraph shapes, impacts, the pits, the defeat; the sounds incl. `bossAwaken` which starts the AudioDirector boss
## bed). The host feeds it the brain's `t: "boss"` events (and broadcasts them to the other peers), so telegraph timing is the event's `ms`.
## The model/animation side is DmBossView, owned by each DmBoss.

## What the router needs from its "game": the enemy-fx stub plus banner/toast/float sinks and the boss-view hide.
class Host:
	extends DmEnemyFxHost
	var sink := Callable()           ## (event_id: String, ctx: Dictionary): "toast" / "banner" -> the HUD
	var hide_view := Callable()      ## (boss_id: String)
	func emit_game_event(id: String, ctx: Dictionary = {}) -> void:
		if sink.is_valid():
			sink.call(id, ctx)
	func boss_view_hide(id: String) -> void:
		if hide_view.is_valid():
			hide_view.call(id)

signal played(ev: Dictionary)       ## every peer, once per event (the local owner's auto-dodge reads the telegraphs from it)

var vfx: Node
var audio: Node
var fx: DmEventFx
var host := Host.new()
var player_pos := Callable()         ## () -> Vector3, the local hero (distance gating of hitstop / shake)
var events: int = 0                  ## events played (tests)


func _ready() -> void:
	DmSimData.ensure()
	if vfx == null:
		vfx = get_tree().root.get_node_or_null("Vfx")
	if audio == null:
		audio = get_tree().root.get_node_or_null("AudioDirector")
	_rebuild()


func _rebuild() -> void:
	fx = DmEventFx.new()
	fx.setup(host)
	fx.vfx = vfx
	fx.audio = audio


## Tests swap counting back-ends in before the first event.
func set_backends(p_vfx: Node, p_audio: Node) -> void:
	vfx = p_vfx
	audio = p_audio
	_rebuild()


## One brain event (`t: "boss"`): the router draws it inside Vfx.danger().
func play(ev: Dictionary) -> void:
	events += 1
	fx.handle_now(ev)
	played.emit(ev)


func _process(dt: float) -> void:
	host.now_ms += dt * 1000.0
	host.mirror.time = host.now_ms / 1000.0
	if player_pos.is_valid():
		var p: Vector3 = player_pos.call()
		host.p["x"] = p.x
		host.p["z"] = p.z
	fx.update(dt)


## Silent one-of-each shape at `at` (loading time): decal textures, pools and shaders exist before the first fight. The kinds the live bosses draw most
## differently (cone / grave, line / spokes / arc / ring / rain circles, and the phase burst + the summon marks); no sound, no banner.
const WARM_KINDS := ["sweep", "bury", "lance", "chorus", "hymn", "toll", "rain", "phase", "summon"]


func warm(at: Vector3) -> void:
	var quiet := fx.audio
	var sink := host.sink
	fx.audio = null
	host.sink = Callable()
	for kind in WARM_KINDS:
		play({"t": "boss", "kind": kind, "x": at.x, "z": at.z, "phase": 2, "boss": "gravedigger" if kind == "sweep" or kind == "bury" else "abbess", "ms": 250.0, "dir": 0.0, "r": 4.5,
			"targets": [[at.x, at.z + 2.0]]})
	events = 0
	fx.audio = quiet
	host.sink = sink


## A toxic ground pool (Saint rot): the original game's zone look (cracked green ground, bubbling puddle), gone with the zone node.
var _pool_zone := DmSimZone.new()

func pool_visual(z: DmHostileZone) -> void:
	_pool_zone.id = z.get_instance_id()
	_pool_zone.kind = String(z.kind)
	_pool_zone.x = z.global_position.x
	_pool_zone.z = z.global_position.z
	_pool_zone.r = z.radius
	_pool_zone.until = host.mirror.time + z.lifetime
	_pool_zone.hostile = true
	vfx.danger(fx.zones_fx.zone_visual.bind(_pool_zone), true)
	z.tree_exiting.connect(fx.zones_fx.zone_gone.bind(_pool_zone.id), CONNECT_ONE_SHOT)
