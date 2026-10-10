class_name DmNextGame
extends Node3D
## The vertical-slice game scene (scene-first; the one in-world game). It composes child nodes and owns almost no logic:
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
const CLIENT_ACTIVE_S := 20.0                    ## a joiner waits this long (after its hello, running frames) for the host's roster before giving up (`start_failed`)
const CLIENT_HARD_S := 85.0                      ## ...and never longer than this in wall time (the host waits DmSession.HELLO_TIMEOUT, 90 s)

signal started
signal enemy_spawned(enemy: DmEnemy)            ## every spawned enemy (every peer), once in the tree: the rewards seam
signal area_changed(id: String)
signal hero_died(body: DmHeroBody)              ## host
signal hero_respawned(body: DmHeroBody)         ## host
signal start_failed(reason: String)             ## a joiner could not enter the host's session (refused, full, lost): the caller returns to its own world


@onready var session: DmSession = $Session
@onready var world: DmNextWorld = $World
@onready var director: DmWaveDirector = $Waves
@onready var net: DmNextNet = $Net
@onready var input: DmNextInput = $Input
@onready var camera: DmCameraRig = $Camera
var hud: DmNextHud                              ## only with opts hud = "minimal"
var ui_host: DmNextUiHost                       ## the host-contract adapter the real HUD reads (hud mode true)
var ui: DmGameUi                                ## the existing HUD + panels
var areas: DmAreaFlow                           ## child "Areas": entry banners + Codex, processions, Grave Surges (next/areas/)
var perf: DmNextPerf                           ## child "Perf": graphics / fps cap / auto-resolution governor (next/perf/)
var chapterhouse: DmChapterhouse                ## child "Chapterhouse": NPCs, stations, waystones, seals, hover + prompts (next/chapterhouse/)
var acre: DmNextAcre                            ## child "Acre" (host with the HUD): visible Grave Laborers, labor / garden notices, the first-hour guidance feeds (next/gathering/)
var gather: DmNextGather                        ## child "Gather" (every peer): gathering nodes, the gather loop (host), skills, AFK (next/gathering/)
var party: DmNextParty                          ## child "Party" (every peer): the lobby link, hosting / joining, roster controls, party chat, the host <-> joiner handshake (next/party/)
var joiner: DmNextJoiner                        ## child "Joiner" (a party joiner only): its own character, backend session, loot and XP on its own account (next/party/)

var character: Dictionary = {}
var api: Variant = null                         ## DmApi: the VPS backend online, the offline backend (DmOffline.make_api) offline
var is_offline: bool = true                     ## D4: true = backed by the local GDScript backend
var area_id: String = "chapterhouse"
var rewards: Node
var progress: DmNextProgress                     ## child "Progress" (host): persistence, upgrades, level-ups, the belt (next/progress/)
var meta: DmNextMeta                             ## child "Meta" (host): difficulty, vows, the Omen, Soul Harvest, Kill Chain, Bonded Dead (next/meta/)
var bosses: DmBossHost                          ## child "Bosses" (every peer): summon rules, boss bodies, boss events + music
var enemy_fx: DmEnemyFx                          ## child "EnemyFx" (every peer): telegraphs, impacts, deaths, enemy voices
var look: DmHeroLook                            ## child "Look" (every peer): worn gear, cape, pet and hero ring on every hero, replicated (next/hero/README.md)
var chron: DmNextChronicle                       ## child "Chronicle" (host): the one Chronicle every system feeds, first-kill trophies (next/progress/)
var codex: DmNextCodex                           ## child "Codex" (host): enemies met, areas entered, bosses woken (next/progress/)
var boss_meta: DmBossMeta                        ## child "BossMeta" (host): the Covenant Seal altar choice, Empowered summons, the Seal's prize (next/bosses/)
var milestones: DmWaveMilestones                 ## child "Milestones" (host): wave-milestone banners and the Nightfall dimming (next/areas/)
var depths: DmDepths                            ## child "Depths" (host): the procedural descent (next/depths/)
var corpses: DmCorpseField                       ## child "Corpses" (same path on every peer); host lays corpses from enemy deaths
var hitstopper := DmHitStop.new()               ## the picture's micro-freeze on heavy hits / elite deaths (DmHitStop, as the original game)
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
var _hold: DmRelayPeer                          ## a joiner's relay peer, held until the world's nodes exist
var _aborted := false                           ## a joiner the host refused or lost while loading: start() stops where it is
var _vfx: Node
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
	enemy_fx.auto_watch = false   # enemies come through director.enemy_spawned below, zones through watch_zones_under: no node_added callback per node in the tree
	enemy_fx.player_pos = func() -> Vector3: return local_body().global_position if local_body() != null else camera.global_position
	enemy_fx.host.camera = camera
	enemy_fx.host.hitstop_cb = hitstop
	hitstopper.disabled = func() -> bool: return ui_host != null and bool(ui_host.settings["reduce_motion"])
	add_child(enemy_fx)
	enemy_fx.watch_zones_under(director.get_node("Bodies"))
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
	bosses.pools_created.connect(enemy_fx.watch_zones_under)
	add_child(bosses)
	bosses.fx.host.camera = camera
	bosses.fx.host.hitstop_cb = hitstop
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
	perf = DmNextPerf.new()
	perf.name = "Perf"
	perf.game = self
	add_child(perf)
	perf.apply(opts.get("settings", {}))   # the real settings arrive with the HUD (DmNextUiHost calls perf.apply on every change)
	look = DmHeroLook.new()
	look.name = "Look"
	add_child(look)
	look.attach(self)
	party = DmNextParty.new()
	party.name = "Party"   # before the session starts: its RPCs must exist at this path when the first packet arrives
	add_child(party)
	party.setup(self)
	var d := DmCharacterBuild.discipline_for(float(character.get("class_index", 0)))
	session.character_name = String(opts.get("name", "You"))
	session.discipline_id = String(d["id"])
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	session.spawn_origin = Vector3(float(ret["x"]), 0.0, float(ret["z"]))
	session.body_factory = _make_body
	session.spawn_override = _joiner_spawn
	session.move_half = 1000.0   # the world is larger than the session arena (areas out to x -72 / 150): click-to-move must reach them
	session.player_joined.connect(_on_player_joined)
	var peer: MultiplayerPeer = opts.get("peer", null)
	var lobby: DmLobbyClient = opts.get("lobby", null)   # a party joiner: the lobby socket the join happened on (main.gd hands it over)
	var is_host := bool(opts.get("host", true)) and lobby == null
	if lobby != null:
		var relay := DmRelayPeer.new()
		assert(relay.join(lobby) == OK, "DmNextGame: the lobby socket is not in a session")
		relay.hold = true   # nothing from the host is delivered until every node it addresses exists (released after the Gather node below)
		_hold = relay
		peer = relay
		party.adopt_client(lobby, relay)
	if peer == null:
		peer = OfflineMultiplayerPeer.new()
	var err := session.host(peer) if is_host else session.join(peer)
	assert(err == OK, "DmNextGame: session start failed (%s)" % error_string(err))
	if not is_host:
		session.session_started.connect(party.send_profile)
		joiner = DmNextJoiner.new()
		joiner.name = "Joiner"
		add_child(joiner)
		await joiner.setup(self, bool(opts.get("persist", DisplayServer.get_name() != "headless")))
	bosses.fx.host.self_id = str(session.get_my_id())
	if session.is_host():
		var b := local_body()
		b.bind_character(character)
		_start_rewards(b)
		party.attach_host()
		meta = DmNextMeta.new()
		meta.name = "Meta"
		add_child(meta)
		meta.attach(self)
		milestones = DmWaveMilestones.new()
		milestones.name = "Milestones"
		add_child(milestones)
		milestones.setup(self)
		chron = DmNextChronicle.new()
		chron.name = "Chronicle"
		add_child(chron)
		await chron.setup(self)   # before the progression: it adopts this chronicle
		await _start_progress(b)
		boss_meta = DmBossMeta.new()
		boss_meta.name = "BossMeta"
		add_child(boss_meta)
		await boss_meta.setup(self)
		codex = DmNextCodex.new()
		codex.name = "Codex"
		add_child(codex)
		codex.setup(self, progress.store)
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
		depths = DmDepths.new()
		depths.name = "Depths"
		add_child(depths)
		depths.setup(self)
	gather = DmNextGather.new()
	gather.name = "Gather"
	add_child(gather)
	await gather.setup(self)
	if _hold != null:
		printerr("[coop] joiner: world built in %d ms, talking to the host" % (Time.get_ticks_msec() - t0))
		_hold.hold = false
		_hold = null
	# The original game's music, area beds and footsteps (AudioDirector autoload + DmAudioHooks): same sound as the existing game.
	await _start_hud()
	if _aborted:
		return
	if codex != null:
		codex.seed_ui()
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
		# Every model, effect and area lighting drawn once under a cover, so no shader compiles mid-play (default: real renderer only).
		if bool(opts.get("warmup", DisplayServer.get_name() != "headless" or "--warmup" in OS.get_cmdline_user_args())) and _has_world:
			await DmNextWarmup.run(self)
	perf.hold()
	if ui_host == null:
		look.load_from_api()   # no panels here (a joiner, a headless host): the look comes from the character's own backend
	ready_ = true
	if ui_host != null:   # the counsel's welcome (and the discipline's first tip): the original game's `world_entered`
		var lvl := float(character.get("level", 1))
		var rl := DmAbilities.rite_level(lvl, ui_host.dev_access)
		var grim := false
		for id in ui_host.kit["grimoire"]:
			if DmAbilities.unlock_level(id) <= rl and DmAbilities.unlock_level(id) > 1:
				grim = true
		ui_host.game_event.emit("world_entered", {"family": local_body().family, "level": int(lvl), "grimoire_unlocked": grim})
	load_ms = Time.get_ticks_msec() - t0
	started.emit()
	if ui_host != null and joiner != null and joiner.notice != "":
		ui_host.game_event.emit("toast", {"text": joiner.notice, "kind": "err"})
		joiner.notice = ""
	if ui_host != null and String(opts.get("notice", "")) != "":   # why we are here (the session we were in ended)
		ui_host.game_event.emit("toast", {"text": String(opts["notice"]), "kind": "err"})


## A joiner: wait until the host accepted it (roster arrived). false = the session ended or timed out first (`start_failed` emitted).
## The clock starts when our hello goes out, and counts only frames that ran: the first frames after the world build can stall for many
## seconds (shader compiles on the Compatibility renderer), which used up the whole wait before the hello was even sent (2026-10-10 co-op
## report). CLIENT_HARD_S caps the wait however slow the frames are.
func _await_active(timeout: float) -> bool:
	var begin := Time.get_ticks_msec()
	var waited := 0.0
	var last := begin
	var ended := [""]
	var cb := func(r: String) -> void: ended[0] = r if r != "" else "ended"
	session.session_ended.connect(cb)
	while not session.is_active() and ended[0] == "" and waited < timeout * 1000.0 and Time.get_ticks_msec() - begin < CLIENT_HARD_S * 1000.0:
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		if session.hello_at_ms > 0:
			waited += minf(float(now - last), 250.0)   # a stalled frame counts as at most a quarter second
		last = now
	session.session_ended.disconnect(cb)
	if session.is_active():
		printerr("[coop] joiner: accepted by the host after %d ms" % (Time.get_ticks_msec() - begin))
		var b := local_body()
		if b != null:
			camera.snap(b.position)
		return true
	_aborted = true
	printerr("[coop] joiner: gave up after %d ms (hello sent: %s, ended: %s)" % [Time.get_ticks_msec() - begin, session.hello_at_ms > 0, ended[0]])
	start_failed.emit(ended[0] if ended[0] != "" else "The host did not answer.")
	return false


## The local player's rewards member: the host's own (DmSessionRewards) or a joiner's (DmNextJoiner), `null` before either exists.
func my_member() -> DmRewardsMember:
	if rewards != null:
		return rewards.members.get(int(character.get("id", 0)))
	return joiner.member if joiner != null else null


## The HUD: `hud` true (default) = DmGameUi on the DmNextUiHost adapter (built and warmed here, under the caller's loading screen),
## "minimal" = the orbs-only DmNextHud, false = none (headless clients).
func _start_hud() -> void:
	var mode: Variant = opts.get("hud", true)
	if mode is String and mode == "minimal":
		hud = DmNextHud.new()
		hud.game = self
		add_child(hud)
	elif mode == true:
		if not session.is_host() and not await _await_active(CLIENT_ACTIVE_S):
			return   # start_failed was emitted: the caller returns to its own world
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
		ui.sound.connect(func(n: String) -> void:
			var a := get_node_or_null("/root/AudioDirector")
			if a != null:
				a.play_sfx(n))
		await ui.warm()
		if progress != null:
			progress.belt.load_pick(ui.belt_pick())
		ui_host.inventory.changed.connect(func(_s: Array) -> void: sync_runes())   # a socketed / removed rune reaches the caster
		ui_host.inventory.changed.connect(look.set_gear_from_slots)                 # worn gear reaches the avatar (and the other peers)
		look.set_gear_from_slots(ui_host.inventory.slots)
		ui_host.load_cosmetics()
		sync_runes()
		if session.is_host():   # the Acre's labor / garden glue runs on the host's own character
			acre = DmNextAcre.new()
			acre.name = "Acre"
			add_child(acre)
			acre.setup(self)


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
	if joiner != null:
		await joiner.flush_all()
	if rewards != null and session.is_host() and session.is_active():
		await rewards.end_session({})
	if chron != null:
		await chron.flush()
	if progress != null:
		await progress.flush_all()
	if ui_host != null and ui_host.inventory != null:
		await ui_host.inventory.flush()


## The reference's `codex_discover(kind, id)` (the boss and enemy fx call it by name).
func codex_discover(kind: String, id: String) -> void:
	if codex != null:
		codex.discover(kind, id)


func _make_body() -> DmSessionBody:
	var b := DmHeroBody.new()
	b.game = self
	b.died.connect(func(x: DmHeroBody) -> void: hero_died.emit(x))
	b.respawned.connect(func(x: DmHeroBody) -> void: hero_respawned.emit(x))
	return b


## A new player appears beside the host (wherever it is), except in the Depths (a solo descent: the Chapterhouse) or when the host is down.
func _joiner_spawn() -> Variant:
	var b := local_body()
	if b == null or not b.alive or area_id == "depths":
		return null
	return b.position


func _on_player_joined(_id: int) -> void:
	pass   # a joiner's rewards member is made when its profile arrives (DmNextParty._rpc_profile): its character id and level come from it


## Called by each DmHeroBody in its _ready on every peer: attaches "Rites" (DmRiteCaster, `self` is its DmRiteWorld), "Thralls"
## (DmThrallHost) and "Statuses" (DmStatusSet).
## The host holds off for a joiner's body: its caster would RPC the joiner before the joiner's spawner has created the body (a missing path).
func attach_caster(body: DmHeroBody) -> void:
	if multiplayer.is_server() and body.owner_peer != session.get_my_id():
		await get_tree().create_timer(CASTER_DELAY).timeout
		if not is_instance_valid(body) or not body.is_inside_tree():
			return
	var caster := DmRiteCaster.attach(body, self)
	if body.owner_peer == session.get_my_id():
		caster.shake_requested.connect(camera.shake)   # the camera honours reduce_motion
	DmThrallHost.attach(body, self)   # "Thralls": raise/rally/command on the host, puppets elsewhere
	if body.get_node_or_null("Statuses") == null:
		DmStatusSet.attach(body)       # player statuses replicate like enemies'


func _process(dt: float) -> void:
	hitstopper.frame(dt)
	if _visual:
		if _vfx == null:
			_vfx = get_node_or_null("/root/Vfx")
		if _vfx != null:
			_vfx.hitstop_scale = hitstopper.scale
		DmCreature.hitstop_scale = hitstopper.scale
	var b := local_body()
	if b == null:
		return
	camera.update_rig(dt, b.visual_position())   # the drawn (interpolated) hero position: the follow is smooth at any display rate
	if _has_world:
		world.update(camera, b.position, dt)
	_enter(b.position)


func _enter(pos: Vector3) -> void:
	var a := world.area_at(pos.x, pos.z) if _has_world else ""
	if a != "" and a != area_id:
		area_id = a
		if perf != null:
			perf.hold()   # an area entry is a load: slow frames around it are not a GPU problem
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
	out["runes"] = rune_sockets(peer_id)
	return out


## The runes a peer's character has socketed ({rite: rune_id}, DmRunes.sockets_of the bag). Only the local host's bag is known.
func rune_sockets(peer_id: int) -> Dictionary:
	if progress == null or peer_id != session.get_my_id():
		return {}
	var b := body_of(peer_id)
	return DmRunes.sockets_of(progress.slots()) if b != null and b.family == "necromancer" else {}


## Host: push the bag's sockets to the local caster (the bag changed, or the HUD's inventory just loaded).
func sync_runes() -> void:
	var b := local_body()
	var c := b.get_node_or_null("Rites") as DmRiteCaster if b != null else null
	if c != null and session.is_host():
		c.set_runes(rune_sockets(session.get_my_id()))


## The rite on a hotbar slot (0 = LMB primary, 1-4, 5 = RMB, 6 = R): the HUD's loadout when it is up, else the kit's mapping.
func rite_for_slot(slot: int) -> String:
	if ui_host != null:
		return ui_host.rite_at(slot)
	var b := local_body()
	return DmRiteHotbar.rite_for_slot(slot, b.family, b.discipline_id) if b != null else ""


## Ask for a picture freeze (DmHitStop: min gap, leaky budget, off under reduce_motion). `weight` 0..1.
func hitstop(weight: float) -> void:
	hitstopper.request(weight)


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
	# The session closes its own peer at the start of leave() (the host's closed RPC runs locally) and then waits 0.25 s: nothing in the
	# tree may tick without a peer (get_unique_id errors), so stop it first. The caller frees the node afterwards.
	process_mode = Node.PROCESS_MODE_DISABLED
	await session.leave()
