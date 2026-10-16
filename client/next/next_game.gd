class_name DmNextGame
extends Node3D
## The game scene on the combat core (the rebuilt client's DmNextGame; client/code.list "Ported"): an OFFLINE solo run in the Hollow Graves. It composes
## child nodes and owns almost no logic:
##   Session (DmSession)   solo = OfflineMultiplayerPeer, the same code path as a party        World (DmNextWorld)  the area scene, its navigation map, its lights
##   Core    (DmCoreHost)  the one owner of the combat core and the crowd that draws it        Waves (DmWaveDirector)  waves, spawned through the core
##   Input   (DmNextInput) click / WASD / hover pick through the core                          Camera (DmCameraRig)    the existing rig
##   EnemyFx (DmEnemyFx)   telegraphs, strikes, deaths, voices: the core's events as effects   Hud (DmNextHud)         health + resource orbs, area name, death veil
## The hero is a DmHeroBody made by the session's body_factory, registered with the core as an external; the blows enemies land on it arrive as the
## core's EV_TARGET_HIT events (`_on_target_hit`). Enemies are ids (ints) everywhere, never nodes: `enemy_spawned` carries an id, the queries
## (`enemies_in_radius`, `enemy_position`) answer ids and positions from the core. No node and no script exists per creature.
##
## Off in this step, each until its ROADMAP item: the rites (the hero cannot attack: next/rites, no `Rites` node, `hotbar` goes nowhere), the login and front
## flow (`main/`), bosses (`bosses` stays null), party and co-op (the session is a 1-player host; no `Net`, `Party`, `Joiner`), gathering, the Chapterhouse
## (the hero starts and gets up at the Graves' door), the Depths, rewards and progression (`rewards`, `progress`, `meta` stay null: no XP, loot or
## saves), the full HUD (`ui_host`, `ui` stay null) and the graphics governor (`perf`). `start` refuses an online api: nothing here talks to a server.
##
##   var g: DmNextGame = load("res://next/next_game.tscn").instantiate(); add_child(g); await g.start(character, api, opts)
## `opts`: offline (must stay true), name, visual (true), waves (true), hud ("minimal" = DmNextHud orbs, false = none), audio (true outside a headless
## run: the music, ambience and footsteps), seed (the core's random seed; default from the clock), areas (["graves"]),
## data_dir (res://), baked_dir / assets_dir (where the baked crowd models are), peer (a MultiplayerPeer; default OfflineMultiplayerPeer).

signal started
signal enemy_spawned(id: int)                   ## every enemy the core made (an id; from DmCoreHost.enemy_spawned): the rewards seam
signal area_changed(id: String)
signal hero_died(body: DmHeroBody)              ## host
signal hero_respawned(body: DmHeroBody)         ## host
signal hero_hit(enemy_id: int, kind: String, damage: float)   ## an enemy's blow reached the hero (before the body's own damage rules)
signal start_failed(reason: String)             ## `start` refused to run (an online api)


@onready var session: DmSession = $Session
@onready var world: DmNextWorld = $World
@onready var core_host: DmCoreHost = $Core
@onready var director: DmWaveDirector = $Waves
@onready var input: DmNextInput = $Input
@onready var camera: DmCameraRig = $Camera
var hud: DmNextHud                              ## only with opts hud = "minimal"
var enemy_fx: DmEnemyFx                         ## child "EnemyFx": the core's events as effects
var look: DmHeroLook                            ## child "Look": the hero's ring and worn gear (next/hero/README.md)
## Left out until their step; the code that is shared with the full game asks `x != null` and finds none.
var ui_host: Node = null                        ## the full HUD's host-contract adapter
var ui: Node = null                             ## the full HUD and panels
var chapterhouse: Node = null                   ## NPCs, stations, waystones
var gather: Node = null                         ## gathering nodes
var bosses: Node = null                         ## the boss host
var rewards: Node = null
var progress: Node = null
var meta: Node = null
var perf: Node = null
var character: Dictionary = {}
var api: Variant = null                         ## DmApi: the offline backend (DmOffline.make_api)
var is_offline: bool = true
var area_id: String = ""
var hitstopper := DmHitStop.new()               ## the picture's micro-freeze on heavy hits / elite deaths (DmHitStop, as the original game)
var opts: Dictionary = {}
var load_ms: int = 0
var ready_ := false                             ## DmAudioHooks "main" shape: ready_, area_id, player, avatar, builder
var hits_taken := {}                            ## kind -> count: the blows that reached the hero (tests, the F3 overlay)
var player: DmHeroBody:
	get: return local_body()
var avatar: DmAvatar:
	get: return local_body().avatar if local_body() != null else null
## The runtime world builder does not exist here (the area is a scene): code that asks for it is null-guarded.
var builder: DmWorldBuilder:
	get: return null

var _visual := true
var _vfx: Node


## Build and start. Host path: the character's body stands at the Graves' door and the scene is live when this returns.
func start(character_: Dictionary, api_: Variant, opts_: Dictionary = {}) -> void:
	var t0 := Time.get_ticks_msec()
	opts = opts_
	character = character_
	api = api_
	if not bool(opts.get("offline", true)) or (api_ != null and String(api_.get("base_url")) != ""):
		push_warning("DmNextGame: the game scene on the core plays offline only in this step (no request leaves the game)")
		start_failed.emit("This game scene is offline only.")
		return
	_visual = bool(opts.get("visual", true))
	DmSimData.ensure()
	input.game = self
	director.game = self
	director.core_host = core_host
	director.enabled = bool(opts.get("waves", true))
	world.build(opts.get("areas", ["graves"]))
	await world.wait_nav_ready()
	camera.setup(world.camera_config())
	area_id = world.area_id
	var core_opts := {"nav_map": world.nav_map(), "bounds": world.bounds(), "view_parent": self}
	for k in ["seed", "data_dir", "baked_dir", "assets_dir", "wander"]:
		if opts.has(k):
			core_opts[k] = opts[k]
	core_host.setup(core_opts)
	core_host.enemy_spawned.connect(func(id: int, _d: String, _l: int, _e: bool, _a: String, _af: int, _x: float, _z: float, _h: float) -> void: enemy_spawned.emit(id))
	core_host.target_hit.connect(_on_target_hit)
	enemy_fx = DmEnemyFx.new()
	enemy_fx.name = "EnemyFx"
	enemy_fx.player_pos = func() -> Vector3: return local_body().global_position if local_body() != null else camera.global_position
	enemy_fx.host.camera = camera
	enemy_fx.host.hitstop_cb = hitstop
	add_child(enemy_fx)
	enemy_fx.bind(core_host)
	session.session_ended.connect(func(_r: String) -> void: set_process(false))
	look = DmHeroLook.new()
	look.name = "Look"
	add_child(look)
	look.attach(self)
	var d := DmCharacterBuild.discipline_for(float(character.get("class_index", 0)))
	session.character_name = String(opts.get("name", "You"))
	session.discipline_id = String(d["id"])
	session.build_version = DmBuild.version()
	session.spawn_origin = world.spawn_point() - Vector3(3.0, 0.0, 0.0)   # the host's own body starts 3 m from the origin (DmSession._spawn_point)
	session.body_factory = _make_body
	session.move_half = 1000.0   # the world is larger than the session arena (areas out to x -72 / 150): click-to-move must reach them
	var peer: MultiplayerPeer = opts.get("peer", null)
	if peer == null:
		peer = OfflineMultiplayerPeer.new()
	var err := session.host(peer)
	assert(err == OK, "DmNextGame: session start failed (%s)" % error_string(err))
	var b := local_body()
	b.bind_character(character)
	b.teleport(world.spawn_point())
	b.core_id = core_host.register_hero(b)
	b.tree_exiting.connect(func() -> void: core_host.unregister_hero(b))
	_enter(b.position)
	camera.snap(b.position)
	_start_hud()
	if bool(opts.get("audio", DisplayServer.get_name() != "headless")) and get_node_or_null("/root/AudioDirector") != null:
		var hooks := DmAudioHooks.new()
		hooks.name = "AudioHooks"
		add_child(hooks)
		hooks.setup(self)
	if _visual:
		enemy_fx.warm(b.global_position)
	ready_ = true
	load_ms = Time.get_ticks_msec() - t0
	started.emit()


func _start_hud() -> void:
	if opts.get("hud", false) is String and opts.get("hud") == "minimal":
		hud = DmNextHud.new()
		hud.game = self
		add_child(hud)


## The core's EV_TARGET_HIT: enemy `enemy_id` hit external `target`. A hero takes it through its own damage rules, with the enemy as the source.
func _on_target_hit(enemy_id: int, target: int, kind: int, damage: float) -> void:
	var b := core_host.hero_for(target) as DmHeroBody
	if b == null:
		return
	var kind_name: String = DmCoreEvents.HIT_KINDS[kind]
	hits_taken[kind_name] = int(hits_taken.get(kind_name, 0)) + 1
	hero_hit.emit(enemy_id, kind_name, damage)
	b.dm_take_enemy_hit(damage, enemy_id, kind_name)


func _make_body() -> DmSessionBody:
	var b := DmHeroBody.new()
	b.game = self
	b.died.connect(func(x: DmHeroBody) -> void: hero_died.emit(x))
	b.respawned.connect(func(x: DmHeroBody) -> void: hero_respawned.emit(x))
	return b


## Called by each DmHeroBody in its _ready on every peer: attaches "Statuses" (the hero's DmStatusSet, a status set on a hero body only). The rites'
## caster ("Rites") and the thralls' host come with the rites (ROADMAP: the Gravecaller's rites ported to the core).
func attach_caster(body: DmHeroBody) -> void:
	if body.get_node_or_null("Statuses") == null:
		DmStatusSet.attach(body)


func _process(dt: float) -> void:
	hitstopper.frame(dt)
	if _visual:
		if _vfx == null:
			_vfx = get_node_or_null("/root/Vfx")
		if _vfx != null:
			_vfx.hitstop_scale = hitstopper.scale
		DmCreature.hitstop_scale = hitstopper.scale
		if core_host.view != null:
			core_host.view.hitstop_scale = hitstopper.scale
	var b := local_body()
	if b == null:
		return
	camera.update_rig(dt, b.visual_position())   # the drawn (interpolated) hero position: the follow is smooth at any display rate
	world.update(camera, b.position, dt)
	_enter(b.position)


func _enter(pos: Vector3) -> void:
	var a := world.area_at(pos.x, pos.z)
	if a != "" and a != area_id:
		area_id = a
		world.enter_area(a)
		area_changed.emit(a)


# ---- seams: accessors for the rites and rewards tracks ------------------------------------------------------------------------

## The body this peer controls (null until the session spawned it).
func local_body() -> DmHeroBody:
	return session.get_body(session.get_my_id()) as DmHeroBody if session.is_active() else null


func body_of(peer_id: int) -> DmHeroBody:
	return session.get_body(peer_id) as DmHeroBody


## Living enemies within `r` metres of `pos` (flat; measured to the enemy's edge): ids, in spawn order.
func enemies_in_radius(pos: Vector3, r: float) -> PackedInt32Array:
	return core_host.enemies_in_radius(pos, r)


## Where an enemy stands (Vector3.INF when it is gone) and whether it is alive.
func enemy_position(id: int) -> Vector3:
	return core_host.enemy_position(id)


func enemy_alive(id: int) -> bool:
	return core_host.enemy_alive(id)


## DmRiteWorld optional hooks: the local owner's cursor ground point / hovered enemy (an id).
func aim_point() -> Vector3:
	return input.aim_point()


func aim_target_id() -> int:
	return input.hovered_enemy_id()


## Ask for a picture freeze (DmHitStop: min gap, leaky budget). `weight` 0..1.
func hitstop(weight: float) -> void:
	hitstopper.request(weight)


## A body's DmCharacterBuild: the character with no bag and no progression (offline, no saves in this step), so level-1 gear and the base mods.
func build_for(peer_id: int) -> Dictionary:
	var b := body_of(peer_id)
	var ch: Dictionary = b.character if b != null and not b.character.is_empty() else {"class_index": 0, "level": 1}
	return DmCharacterBuild.build(ch, [], {})


## Who is in the session: [{peer_id, name, discipline, character_id, body}].
func roster() -> Array:
	var out: Array = []
	for r in session.get_roster():
		var b := body_of(int(r["peer_id"]))
		out.append({"peer_id": int(r["peer_id"]), "name": String(r["name"]), "discipline": String(r["discipline"]), "character_id": b.character_id if b != null else 0, "body": b})
	return out


func body_position(peer_id: int) -> Vector3:
	var b := body_of(peer_id)
	return b.position if b != null else Vector3.INF


## The area at a ground point ("" = outside every loaded area): the rites walk a cast back to where its caster's area ends.
func area_at(x: float, z: float) -> String:
	return world.area_at(x, z)


## The area id a player is standing in ("" between areas).
func area_of(peer_id: int) -> String:
	var b := body_of(peer_id)
	return world.area_at(b.position.x, b.position.z) if b != null else ""


## Where a fallen hero gets up (today the Chapterhouse, which is not loaded yet): the Graves' door.
func respawn_point() -> Vector3:
	return world.spawn_point()


func flush_all() -> void:
	pass   # nothing is saved in this step


func leave() -> void:
	await flush_all()
	# The session closes its own peer at the start of leave() (the host's closed RPC runs locally) and then waits 0.25 s: nothing in the
	# tree may tick without a peer (get_unique_id errors), so stop it first. The caller frees the node afterwards.
	process_mode = Node.PROCESS_MODE_DISABLED
	await session.leave()
