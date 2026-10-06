class_name DmNextGame
extends Node3D
## The vertical-slice game scene (scene-first, replaces the DmGame hub for the rebuild). It composes child nodes and owns almost no logic:
##   Session (DmSession)  host / join on any MultiplayerPeer; solo = OfflineMultiplayerPeer, the SAME code path as a 2-player session
##   World   (DmNextWorld) DmWorldBuilder world, dressing, navmesh map          Camera (DmCameraRig)   the existing rig
##   Waves   (DmWaveDirector) host-side enemy waves + MultiplayerSpawner        Net (DmNextNet)        enemy / vitals replication
##   Input   (DmNextInput) click / WASD / hotbar -> intents + the hotbar seam   UiHost (DmNextUiHost) + Ui (DmGameUi): the real HUD and panels
## Players are DmHeroBody (DmSessionBody subclass made by the session's body_factory). See next/README.md for the seams the rites and
## rewards tracks plug into.
##
##   var g: DmNextGame = load("res://next/next_game.tscn").instantiate(); add_child(g); await g.start(character, api)
## `opts`: peer (MultiplayerPeer, default OfflineMultiplayerPeer = solo), visual (true), dressing (true), world (true: false = no world /
## navmesh, a headless client), waves (true), hud (true = the real HUD, "minimal" = DmNextHud orbs only, false = none), persist (true: settings,
## loadout and counsel state are written under user://).

const CASTER_DELAY := 0.8
const SLICE_PANELS := ["inventory", "grimoire", "settings"]   ## panels pre-built under the loading cover; the others open (and build) on first use

signal started
signal enemy_spawned(enemy: DmEnemy)            ## every spawned enemy (every peer), once in the tree: the rewards seam
signal area_changed(id: String)
signal hero_died(body: DmHeroBody)              ## host
signal hero_respawned(body: DmHeroBody)         ## host


@onready var session: DmSession = $Session
@onready var world: DmNextWorld = $World
@onready var director: DmWaveDirector = $Waves
@onready var net: DmNextNet = $Net
@onready var input: DmNextInput = $Input
@onready var camera: DmCameraRig = $Camera
var hud: DmNextHud                              ## only with opts hud = "minimal"
var ui_host: DmNextUiHost                       ## the DmGame-contract adapter the real HUD reads (hud mode true)
var ui: DmGameUi                                ## the existing HUD + panels
var areas: DmAreaFlow                           ## child "Areas": entry banners + Codex, processions, Grave Surges (next/areas/)
var chapterhouse: DmChapterhouse                ## child "Chapterhouse": NPCs, stations, waystones, seals, hover + prompts (next/chapterhouse/)

var character: Dictionary = {}
var api: Variant = null                         ## DmApi: the VPS backend online, the offline backend (DmOffline.make_api) offline
var is_offline: bool = true                     ## D4: true = backed by the local GDScript backend
var area_id: String = "chapterhouse"
var rewards: Node
var progress: DmNextProgress                     ## child "Progress" (host): persistence, upgrades, level-ups, the belt (next/progress/)
var bosses: DmBossHost                          ## child "Bosses" (every peer): summon rules, boss bodies, boss events + music
var enemy_fx: DmEnemyFx                          ## child "EnemyFx" (every peer): telegraphs, impacts, deaths, enemy voices
var corpses: DmCorpseField                       ## child "Corpses" (same path on every peer); host lays corpses from enemy deaths
var opts: Dictionary = {}
var load_ms: int = 0
var ready_ := false                             ## DmAudioHooks "main" shape: ready_, area_id, player, avatar, builder
var player: DmHeroBody:
	get: return local_body()
var avatar: DmAvatar:
	get: return local_body().avatar if local_body() != null else null
var builder: DmWorldBuilder:
	get: return world.builder

var _visual := true
var _has_world := true


## Build and start. Host path: the character's body is spawned in the Chapterhouse and the slice is live when this returns.
func start(character_: Dictionary, api_: Variant, opts_: Dictionary = {}) -> void:
	var t0 := Time.get_ticks_msec()
	opts = opts_
	character = character_
	api = api_
	is_offline = bool(opts.get("offline", true))
	_visual = bool(opts.get("visual", true))
	_has_world = bool(opts.get("world", true))
	DmSimData.ensure()
	input.game = self
	net.game = self
	director.game = self
	director.enabled = bool(opts.get("waves", true))
	corpses = DmCorpseField.new()
	corpses.name = "Corpses"
	add_child(corpses)
	enemy_fx = DmEnemyFx.new()
	enemy_fx.name = "EnemyFx"
	enemy_fx.player_pos = func() -> Vector3: return local_body().global_position if local_body() != null else camera.global_position
	enemy_fx.host.camera = camera
	add_child(enemy_fx)
	director.enemy_spawned.connect(func(e: DmEnemy) -> void:
		enemy_fx.watch(e)       # idempotent (the node also auto-watches); explicit so the seam is visible
		DmStatusSet.attach(e)   # every peer, so status visuals replicate (an ensure()d set never does)
		if multiplayer.is_server():
			net.watch_enemy(e)  # host-only cues (shield glance, sanctify, unbind) reach the clients
		if ui_host != null:
			ui_host.watch_enemy(e)
		corpses.track(e, String(e.get_meta("dm_area", area_id)))
		enemy_spawned.emit(e))
	bosses = DmBossHost.new()
	bosses.name = "Bosses"
	bosses.game = self
	bosses.visual = _visual
	bosses.audio_enabled = bool(opts.get("audio", DisplayServer.get_name() != "headless")) and _has_world
	add_child(bosses)
	bosses.fx.host.camera = camera
	bosses.fx.player_pos = enemy_fx.player_pos
	bosses.fx.host.sink = func(id: String, ctx: Dictionary) -> void:   # banners / toasts -> the HUD
		if ui_host != null:
			ui_host.game_event.emit(id, ctx)
	director.warm(true)   # every area's kinds: no first-entry hitch when a waystone or a door brings the hero to a new roster
	session.session_ended.connect(func(_r: String) -> void: set_process(false))
	if _has_world:
		world.build(bool(opts.get("dressing", true)))
		await world.wait_nav_ready()
		camera.setup(world.camera_config())
	else:
		camera.setup(DmData.world()["camera"])
	var d := DmCharacterBuild.discipline_for(float(character.get("class_index", 0)))
	session.character_name = String(opts.get("name", "You"))
	session.discipline_id = String(d["id"])
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	session.spawn_origin = Vector3(float(ret["x"]), 0.0, float(ret["z"]))
	session.body_factory = _make_body
	session.player_joined.connect(_on_player_joined)
	var peer: MultiplayerPeer = opts.get("peer", null)
	if peer == null:
		peer = OfflineMultiplayerPeer.new()
	var err := session.host(peer) if bool(opts.get("host", true)) else session.join(peer)
	assert(err == OK, "DmNextGame: session start failed (%s)" % error_string(err))
	bosses.fx.host.self_id = str(session.get_my_id())
	if session.is_host():
		var b := local_body()
		b.bind_character(character)
		_start_rewards(b)
		await _start_progress(b)
		_enter(b.position)
		camera.snap(b.position)
	chapterhouse = DmChapterhouse.new()
	chapterhouse.name = "Chapterhouse"
	add_child(chapterhouse)
	chapterhouse.setup(self)
	# A click on a boss summoning site (the hub owns hover/click, the bosses host owns summoning; E at the grave already summons there).
	chapterhouse.interacted.connect(func(it: Dictionary) -> void:
		if String(it.get("kind", "")) == "boss":
			var bid := chapterhouse.boss_for_summon(String(it["id"]))
			if bid != "":
				bosses.request_summon(bid))
	if session.is_host():
		chapterhouse.start_seals()
	# The current game's music, area beds and footsteps (AudioDirector autoload + DmAudioHooks): same sound as the existing game.
	await _start_hud()
	areas = DmAreaFlow.new()
	areas.name = "Areas"
	add_child(areas)
	areas.setup(self)
	# One hotbar path: the real HUD casts from the player's loadout (Grimoire edits); without it, the kit mapping does
	# (next/rites/dm_rite_hotbar.gd). Both connected = every key cast twice.
	if ui_host == null:
		DmRiteHotbar.wire(self)
	if bool(opts.get("audio", DisplayServer.get_name() != "headless")) and _has_world and get_node_or_null("/root/AudioDirector") != null:
		var hooks := DmAudioHooks.new()
		hooks.name = "AudioHooks"
		add_child(hooks)
		hooks.setup(self)
	if _visual:
		DmRiteFx.with_autoloads().warm()
		var at := local_body().global_position if local_body() != null else Vector3.ZERO
		enemy_fx.warm(at)
		bosses.warm(at)
	ready_ = true
	load_ms = Time.get_ticks_msec() - t0
	started.emit()


## The HUD: `hud` true (default) = DmGameUi on the DmNextUiHost adapter (built and warmed here, under the caller's loading screen),
## "minimal" = the orbs-only DmNextHud, false = none (headless clients).
func _start_hud() -> void:
	var mode: Variant = opts.get("hud", true)
	if mode is String and mode == "minimal":
		hud = DmNextHud.new()
		hud.game = self
		add_child(hud)
	elif mode == true and session.is_host():
		ui_host = DmNextUiHost.new()
		ui_host.name = "UiHost"
		add_child(ui_host)
		await ui_host.setup(self, bool(opts.get("persist", DisplayServer.get_name() != "headless")))
		for e in director.enemies.values():
			ui_host.watch_enemy(e)
		ui = DmGameUi.new()
		ui.name = "Ui"
		add_child(ui)
		ui.setup(ui_host)
		ui.warm_panels = SLICE_PANELS
		ui.sound.connect(func(n: String) -> void:
			var a := get_node_or_null("/root/AudioDirector")
			if a != null:
				a.play_sfx(n))
		await ui.warm()
		if progress != null:
			progress.belt.load_pick(ui.belt_pick())


## Host: the rewards track's node (DmSessionRewards) with one member per player; kills arrive through `enemy_spawned` -> `died`.
func _start_rewards(b: DmHeroBody) -> void:
	rewards = DmSessionRewards.new()
	rewards.name = "Rewards"
	rewards.local_peer_id = session.get_my_id()
	rewards.area_id = "graves"
	add_child(rewards)
	rewards.attach_spawner(self)
	var d := DmCharacterBuild.discipline_for(float(character.get("class_index", 0)))
	rewards.add_member(DmRewardsMember.make(int(character.get("id", 0)), session.get_my_id(), b, api, int(character.get("level", 1)), {"id": d["id"], "family": d["family"]}))
	rewards.start(int(character.get("id", 0)))   # session_open (async; a failure arrives as session_failed)


## Host: the character's persistence, upgrades, level-ups and belt (next/progress/). Awaited under the loading cover: it reads the backend's
## saved progression (tiers, shards, kills) before the first wave.
func _start_progress(b: DmHeroBody) -> void:
	progress = DmNextProgress.new()
	progress.name = "Progress"
	add_child(progress)
	await progress.setup(self, rewards.members.get(int(character.get("id", 0))), bool(opts.get("persist", DisplayServer.get_name() != "headless")))


## Everything the character earned, saved: the session's last kill batch, the progression, the bag. The window close and leave() call it.
func flush_all() -> void:
	if rewards != null and session.is_host() and session.is_active():
		await rewards.end_session({})
	if progress != null:
		await progress.flush_all()
	if ui_host != null and ui_host.inventory != null:
		await ui_host.inventory.flush()


func _make_body() -> DmSessionBody:
	var b := DmHeroBody.new()
	b.game = self
	b.died.connect(func(x: DmHeroBody) -> void: hero_died.emit(x))
	b.respawned.connect(func(x: DmHeroBody) -> void: hero_respawned.emit(x))
	return b


func _on_player_joined(id: int) -> void:
	# A joiner on the host: a rewards member without its own api yet (its gear drops land unrolled until the join handshake carries one).
	if rewards != null and session.is_host() and id != session.get_my_id() and body_of(id) != null:
		rewards.add_member(DmRewardsMember.make(0, id, body_of(id), null, 1, {"id": body_of(id).discipline_id, "family": "necromancer"}))


## Called by each DmHeroBody in its _ready on every peer: attaches "Rites" (DmRiteCaster, `self` is its DmRiteWorld), "Thralls"
## (DmThrallHost) and "Statuses" (DmStatusSet).
## The host holds off for a joiner's body: its caster would RPC the joiner before the joiner's spawner has created the body (a missing path).
func attach_caster(body: DmHeroBody) -> void:
	if multiplayer.is_server() and body.owner_peer != session.get_my_id():
		await get_tree().create_timer(CASTER_DELAY).timeout
		if not is_instance_valid(body) or not body.is_inside_tree():
			return
	DmRiteCaster.attach(body, self)
	DmThrallHost.attach(body, self)   # "Thralls": raise/rally/command on the host, puppets elsewhere
	if body.get_node_or_null("Statuses") == null:
		DmStatusSet.attach(body)       # player statuses replicate like enemies'


func _process(dt: float) -> void:
	var b := local_body()
	if b == null:
		return
	camera.update_rig(dt, b.position)
	if _has_world:
		world.update(camera, b.position, dt)
	_enter(b.position)


func _enter(pos: Vector3) -> void:
	var a := world.area_at(pos.x, pos.z) if _has_world else ""
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


## Living enemies within `r` metres of `pos` (flat; measured to the enemy's edge).
func enemies_in_radius(pos: Vector3, r: float) -> Array[DmEnemy]:
	var out := director.enemies_in_radius(pos, r)
	for b in bosses.living():   # a boss counts from its edge, like any big body
		if Vector2(b.global_position.x - pos.x, b.global_position.z - pos.z).length() - b.radius <= r:
			out.append(b)
	return out


func enemy_by_id(id: int) -> DmEnemy:
	return director.enemy_by_id(id) if id < DmBossHost.ID_BASE else bosses.boss_by_id(id)


func enemy_id(enemy: Node) -> int:
	return director.enemy_id(enemy)


## DmRiteWorld optional hooks: the local owner's cursor ground point / hovered enemy, and a body's build for the caster.
func aim_point() -> Vector3:
	return input.aim_point()


func aim_target_id() -> int:
	return input.hovered_enemy_id()


func rite_build(peer_id: int) -> Dictionary:
	var out := build_for(peer_id)
	out["runes"] = {}
	return out


## A body's DmCharacterBuild. The local host's carries its progression (damage tier, boons, vows) and its bag's gear; others get the defaults.
func build_for(peer_id: int) -> Dictionary:
	var b := body_of(peer_id)
	var ch: Dictionary = b.character if b != null and not b.character.is_empty() else {"class_index": 0, "level": 1}
	if progress != null and peer_id == session.get_my_id():
		return DmCharacterBuild.build(ch, progress.slots(), progress.prog.local)
	return DmCharacterBuild.build(ch, [], {})


## Who is in the session: [{peer_id, name, discipline, character_id, body}]. character_id is the backend character id of the local host's
## character; remote members are 0 until the join handshake carries one (REBUILD phase 4).
func roster() -> Array:
	var out: Array = []
	for r in session.get_roster():
		var b := body_of(int(r["peer_id"]))
		var cid := 0
		if b != null:
			cid = b.character_id
		out.append({"peer_id": int(r["peer_id"]), "name": String(r["name"]), "discipline": String(r["discipline"]), "character_id": cid, "body": b})
	return out


func body_position(peer_id: int) -> Vector3:
	var b := body_of(peer_id)
	return b.position if b != null else Vector3.INF


## The area at a ground point ("" = outside every area): the rites walk a cast back to where its caster's area ends.
func area_at(x: float, z: float) -> String:
	return world.area_at(x, z) if _has_world else ""


## The area id a player is standing in ("" between areas).
func area_of(peer_id: int) -> String:
	var b := body_of(peer_id)
	return world.area_at(b.position.x, b.position.z) if b != null and _has_world else ""


func leave() -> void:
	await flush_all()
	await session.leave()
