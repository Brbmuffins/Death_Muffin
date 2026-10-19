class_name DmNextGame
extends Node3D
## The game scene on the combat core: a solo run in the Hollow Graves, with a character from the test
## server (the front flow) or a dev character on the local mock. It composes
## child nodes and owns almost no logic:
##   Session (DmSession)   solo = OfflineMultiplayerPeer, the same code path as a party        World (DmNextWorld)  the area scene, its navigation map, its lights
##   Core    (DmCoreHost)  the one owner of the combat core and the crowd that draws it        Waves (DmWaveDirector)  waves, spawned through the core
##   Input   (DmNextInput) click / WASD / hover pick through the core                          Camera (DmCameraRig)    the existing rig
##   EnemyFx (DmEnemyFx)   telegraphs, strikes, deaths, voices: the core's events as effects   UiHost, Ui (DmNextUiHost, DmGameUi)  the HUD and panels (B46)
##   Bosses  (DmBossHost)  the seven bosses: summon rules, the boss body (an external of the core, its brain GDScript), its fx and music      BossMeta (DmBossMeta)  the Covenant Seal's altar choice
## The hero is a DmHeroBody made by the session's body_factory, registered with the core as an external; the blows enemies land on it arrive as the
## core's EV_TARGET_HIT events (`_on_target_hit`). Enemies are ids (ints) everywhere, never nodes: `enemy_spawned` carries an id, the queries
## (`enemies_in_radius`, `enemy_position`) answer ids and positions from the core. No node and no script exists per creature.
##
## The hero fights with the Gravecaller's rites (next/rites: the `Rites` node, a DmRiteCaster, is attached to his body in `attach_caster`; LMB, keys 1-4, RMB and R go
## through DmNextInput and DmRiteHotbar). A rite calls the core synchronously (`core_host.damage / apply_status`, `corpses`, the legion), so a kill resolves inside the cast;
## its thralls are the core's and are drawn by the crowd. `rite_hit` carries every blow a rite or a Withered DoT lands, for the rewards seam.
##
## A boss (the Gravedigger King at his grave, the Bone Abbess at her Reliquary ... the Mire Mother at her altar) wakes where its summon site is (key E within 4 m, `bosses.request_summon`): its body is an
## external entity of the core (kind 1, DmBoss), its brain is GDScript, the rites and the thralls hit it through the core's host (`enemies_in_radius`, `damage`) and the events, its adds and pools are
## the core's and its defeat is `bosses.defeated` (a real kill, not a wipe; `rewards.on_boss_defeated` pays it) (client/README.md "The bosses").
##
## 2-PLAYER CO-OP (client/README.md "Co-op on the core"): the same scene runs as the HOST (the default: a solo run, or hosted over the test lobby's relay once `party.host_session` swaps
## the transport) or as a GUEST (`opts.lobby`: the lobby socket a join happened on, or `opts.peer` with `host` false). The host simulates and sends (`Net`, DmNextNet: the core's snapshot,
## its reliable batches and a baseline, hero vitals); the guest's core is a PUPPET (`core_host.puppet`): no director, no brains, the crowd, the effects and the HUD run from the
## puppet's events. Hero casts are intents the host resolves on its core (DmRiteCaster); a guest's hero is an external of the HOST's core (`core_id` is the host's id for it), and
## its thralls are the host's bodies. A guest's `enemy_died` events are presentation only: kill credit (`kill_credited`) is the HOST's, once.
##
## VALUE ON THE SERVER (DECISIONS D1, B20, B32; client/README.md "Value on the server"): the host's `rewards` (DmSessionRewards) hears `kill_credited` and pays every
## member in range through the backend's party session (numbered kill reports, XP and kill counts applied from what the server accepted), with the loot rolls from the
## member's drop tape; beside it are `meta` (DmNextMeta: difficulty, world vows, the Omen, Soul Harvest, the Kill Chain, Bonded Dead), `milestones`, `chron` (the Chronicle, first-kill
## trophies) and `progress` (DmNextProgress: levels, upgrade tiers, the belt, the backend saves). `loot` (DmNextLoot) is this player's drops and bag: a click
## walks to a drop, a tape drop is claimed (the server puts its own roll in the bag), worn gear feeds the build. `flush_all` saves everything (the last report, the
## Chronicle, the progression, the bag) on leave and on the window's close.
##
## THE WORLD: every area but the Depths (DmNextWorld, the area scenes; `opts.areas` takes a shorter list), the hero starting and getting up in the Chapterhouse. The
## Chapterhouse node (DmChapterhouse) breaks the seals as kills come in and opens the doors, runs waystone travel and the recall, the stations and the people.
## The Depths (DmDepths, `depths`, host only; client/README.md "The Depths") are the one area made at run time: the Warren's stair starts a run, each floor is generated, drawn and baked
## when it is entered, its dead are bodies of the core, the HUD reads its readout and map. The graphics preset, fps cap and auto-resolution are `perf` (DmNextPerf, the player's settings read from their file).
##
## GATHERING (client/README.md "Gathering and the Acre"): `gather` (DmNextGather: the nodes of every area, hover and click, the loop that walks, works and batches to the backend, the skills) is a child of every
## peer at the same path (its depleted nodes reach a guest as RPCs); `acre` (DmNextAcre: the visible Grave Laborers and the labor, garden and contract notices) is the host's, with the real HUD.
##
## Not in it: the Covenant Seal's altar choice (Ascension, B36: a summon is the plain soul-shard one). `start` refuses any api whose base url DmConfig does not allow
## (DmConfig.allows_api_base: the live server since launch day, B49; the local mock has none). It takes the
## character and its build from the front flow (`slots`, `local` below) until the progression and the bag have loaded theirs from the server.
##
##   var g: DmNextGame = load("res://next/next_game.tscn").instantiate(); add_child(g); await g.start(character, api, opts)
## `opts`: warmup (the first-use warm-up of models, effects and area lighting; default `_wants_warmup()`: on for players, off headless and on QA runs; the benchmark forces it), name, slots (the character's bag rows from the server: worn gear feeds the build), local (its progression: damage and legion tier, boons, vows; DmMain.load_build), visual (true), waves (true), hud (true = the HUD and panels on DmNextUiHost; false = none), audio (true outside a headless
## run: the music, ambience and footsteps), seed (the core's random seed; default from the clock), areas (the area ids to load; default every one, DmNextWorld.every_area),
## data_dir (res://), baked_dir / assets_dir (where the baked crowd models are), lod_distances / reserve / cull / anim_lod / thrall_shadows (the crowd's cost: CrowdView.setup),
## peer (a MultiplayerPeer; default OfflineMultiplayerPeer).

const CASTER_DELAY := 0.8                       ## the host attaches a guest's caster this long after its body spawned (the guest's spawner must have made the body first)
const CLIENT_ACTIVE_S := 20.0                   ## a guest waits this long (after its hello, running frames) for the host's roster before giving up (`start_failed`)
const CLIENT_HARD_S := 85.0                     ## ...and never longer than this in wall time (the host waits DmSession.HELLO_TIMEOUT, 90 s)

signal started
signal enemy_spawned(id: int)                   ## every enemy the core made (an id; from DmCoreHost.enemy_spawned): the rewards seam
signal area_changed(id: String)
signal hero_died(body: DmHeroBody)              ## host
signal hero_respawned(body: DmHeroBody)         ## host
signal hero_hit(enemy_id: int, kind: String, damage: float)   ## an enemy's blow reached the hero (before the body's own damage rules)
signal rite_hit(rite: String, enemy_id: int, amount: float, crit: bool, killed: bool)   ## host: a rite's (or a Withered DoT's) blow on an enemy, from the local caster: the kill credit / rewards hook
signal start_failed(reason: String)             ## `start` refused to run (an api that is not the live server's), or a guest was refused / lost the host
signal kill_credited(enemy_id: int, def: String, level: int, elite: bool, area: String, killer_peer: int, x: float, z: float)   ## HOST only, once per kill: the kill report / rewards hook (killer_peer 0 = no hero)


@onready var session: DmSession = $Session
@onready var world: DmNextWorld = $World
@onready var core_host: DmCoreHost = $Core
@onready var net: DmNextNet = $Net
@onready var director: DmWaveDirector = $Waves
@onready var input: DmNextInput = $Input
@onready var camera: DmCameraRig = $Camera
var enemy_fx: DmEnemyFx                         ## child "EnemyFx": the core's events as effects
var look: DmHeroLook                            ## child "Look": the hero's ring and worn gear (next/hero/README.md)
var party: DmNextParty                          ## child "Party" (every peer): the lobby link, hosting / joining, the roster controls, the guest's profile (next/party/)
var friends: DmNextFriends                      ## child "Friends": the account's friends and friend requests (the test backend's friends routes; next/party/)
## Left out until their step; the code that is shared with the full game asks `x != null` and finds none.
var ui_host: DmNextUiHost                       ## child "UiHost" (opts hud = true): the host-contract adapter of the HUD and the panels (DECISIONS B46)
var ui: DmGameUi                                ## child "Ui" (opts hud = true): the HUD and panels
var areas: DmAreaFlow                           ## child "Areas": the entry banners and the Codex facts, the processions (next/areas/)
var chapterhouse: DmChapterhouse               ## child "Chapterhouse": NPCs, stations, waystones, seals, hover + prompts (next/chapterhouse/)
var depths: DmDepths                           ## child "Depths" (host): the procedural descent (next/depths/; client/README.md "The Depths")
var gather: DmNextGather                        ## child "Gather" (every peer): gathering nodes, the gather loop (host), skills, AFK (next/gathering/)
var acre: DmNextAcre                            ## child "Acre" (host, with the HUD): visible Grave Laborers, labor / garden notices, the first-hour guidance feeds (next/gathering/)
var bosses: DmBossHost                          ## child "Bosses": summon rules, the boss body, its events and music
var boss_meta: DmBossMeta                       ## child "BossMeta" (host): the Covenant Seal altar choice, Empowered summons, the Seal's prize (next/bosses/)
var rewards: DmSessionRewards                   ## child "Rewards" (host): kill credit, the backend's party session, loot rolls (next/rewards/)
var progress: DmNextProgress                    ## child "Progress" (host): levels, upgrade tiers, the belt, the backend saves (next/progress/)
var meta: DmNextMeta                            ## child "Meta" (host): difficulty, world vows, the Omen, Soul Harvest, the Kill Chain, Bonded Dead (next/meta/)
var milestones: DmWaveMilestones                ## child "Milestones" (host): the Wave Speed milestones' banners and the Nightfall light
var chron: DmNextChronicle                      ## child "Chronicle" (host): the one Chronicle every system feeds, first-kill trophies
var codex: DmNextCodex                          ## child "Codex" (host): enemies met, areas entered, bosses woken (the Codex panel's journal)
var loot: DmNextLoot                            ## child "Loot": this player's drops and bag (next/rewards/dm_next_loot.gd)
var joiner: DmNextJoiner                        ## child "Joiner" (a party guest only): its own character, backend session, XP and drops on its own account (next/party/)
var remote_builds := {}                         ## host: peer id -> a member's build from the server {character, slots, local} (DmNextParty.fetch_build)
var perf: DmNextPerf                           ## child "Perf": the graphics preset, the fps cap and the auto-resolution governor (next/perf/dm_next_perf.gd)
var character: Dictionary = {}
var api: Variant = null                         ## DmApi: the live server's (the front flow) or the local mock (DmOffline.make_api)
var is_offline: bool = true                     ## the api is the local mock (no base url)
var server_slots: Array = []                    ## the character's bag rows as the server holds them (opts.slots): what `build_for` builds from
var server_local: Dictionary = {}               ## its progression (opts.local)
var area_id: String = ""
var corpses: DmCoreCorpses:                     ## the corpse field as the rites see it (the core's: atomic consume, pick, in radius)
	get: return core_host.corpses
var hitstopper := DmHitStop.new()               ## the picture's micro-freeze on heavy hits / elite deaths (DmHitStop, as the original game)
var is_guest := false                           ## this scene joined someone's session (opts.lobby, or opts.peer with host false): its core is a puppet
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
var _hold: DmRelayPeer                          ## a guest's relay peer, held until the world's nodes exist


## Build and start. Host path: the character's body stands in the Chapterhouse (at the Graves' door in a world without it) and the scene is live when this returns.
func start(character_: Dictionary, api_: Variant, opts_: Dictionary = {}) -> void:
	var t0 := Time.get_ticks_msec()
	opts = opts_
	character = character_
	api = api_
	var base_url := String(api_.get("base_url")) if api_ != null else ""
	if not DmConfig.allows_api_base(base_url):
		push_warning("DmNextGame: refused an api that is not the live server's (DECISIONS B38)")
		start_failed.emit("This build plays on the live server only.")
		return
	is_offline = base_url == ""
	server_slots = opts.get("slots", [])
	server_local = opts.get("local", {})
	_visual = bool(opts.get("visual", true))
	var lobby: DmLobbyClient = opts.get("lobby", null)   # a party guest: the lobby socket the join happened on
	var join: Variant = opts.get("join", null)   # {code} / {id}: take a seat in a party by ourselves (a launch argument `--join-party=<code>`, a shell without the panels)
	if join == null and lobby == null and opts.get("peer", null) == null and DmNextParty.arg("--join-party") != null:
		join = {"code": String(DmNextParty.arg("--join-party"))}
	var guest := lobby != null or join is Dictionary or (opts.get("peer", null) != null and not bool(opts.get("host", true)))
	is_guest = guest
	DmSimData.ensure()
	DmDbWarm.all()   # every dataset read now, in loading: the workers (the Depths' floor generator, the Gear Atlas' verdicts) then read a cache that never changes (client/README.md "Threads")
	input.game = self
	net.game = self
	director.game = self
	director.core_host = core_host
	director.enabled = bool(opts.get("waves", true)) and not guest   # the host's waves: a guest's bodies come from the wire
	world.build(opts.get("areas", []))
	await world.wait_nav_ready()
	camera.setup(world.camera_config())
	area_id = world.area_id
	var core_opts := {"nav_map": world.nav_map(), "bounds": world.bounds(), "view_parent": self, "puppet": guest}
	for k in ["seed", "data_dir", "baked_dir", "assets_dir", "wander", "lod_distances", "reserve", "cull", "anim_lod", "thrall_shadows"]:
		if opts.has(k):
			core_opts[k] = opts[k]
	core_host.setup(core_opts)
	world.bind_core(core_host.core)
	core_host.enemy_spawned.connect(func(id: int, _d: String, _l: int, _e: bool, _a: String, _af: int, _x: float, _z: float, _h: float) -> void: enemy_spawned.emit(id))
	core_host.target_hit.connect(_on_target_hit)
	core_host.target_effect.connect(_on_target_effect)
	core_host.enemy_died.connect(_on_enemy_died)
	perf = DmNextPerf.new()
	perf.name = "Perf"
	perf.game = self
	add_child(perf)
	perf.apply(opts.get("settings", _player_settings()))   # the crowd exists: its shadow policy is part of the preset
	enemy_fx = DmEnemyFx.new()
	enemy_fx.name = "EnemyFx"
	enemy_fx.player_pos = func() -> Vector3: return local_body().global_position if local_body() != null else camera.global_position
	enemy_fx.host.camera = camera
	enemy_fx.host.hitstop_cb = hitstop
	add_child(enemy_fx)
	enemy_fx.bind(core_host)
	bosses = DmBossHost.new()
	bosses.name = "Bosses"
	bosses.game = self
	bosses.visual = _visual
	bosses.audio_enabled = bool(opts.get("audio", DisplayServer.get_name() != "headless"))
	add_child(bosses)
	bosses.fx.host.camera = camera
	bosses.fx.host.hitstop_cb = hitstop
	bosses.fx.player_pos = enemy_fx.player_pos
	bosses.fx.host.sink = game_event   # banners / toasts -> the HUD
	session.session_ended.connect(_on_session_ended)
	look = DmHeroLook.new()
	look.name = "Look"
	add_child(look)
	look.attach(self)
	party = DmNextParty.new()
	party.name = "Party"   # before the session starts: its RPCs must exist at this path when the first packet arrives
	add_child(party)
	party.setup(self)
	friends = DmNextFriends.new()
	friends.name = "Friends"
	add_child(friends)
	friends.setup(self)
	var d := DmCharacterBuild.discipline_for(float(character.get("class_index", 0)))
	session.character_name = String(opts.get("name", "You"))
	session.discipline_id = String(d["id"])
	session.build_version = String(opts["build"]) if opts.has("build") else DmBuild.version()   # tests: play as another release build
	if opts.has("wire"):
		session.wire = int(opts["wire"])   # tests: play as a build with another core wire version
	# The host's own body starts 3 m from the origin (DmSession._spawn_point): the origin is the Chapterhouse's return point; a world without the
	# Chapterhouse puts the body itself on the Graves' door.
	session.spawn_origin = world.spawn_point() if world.has_area("chapterhouse") else world.spawn_point() - Vector3(3.0, 0.0, 0.0)
	session.spawn_override = _joiner_spawn
	session.spawn_resolve = _walkable_spawn
	session.body_factory = _make_body
	session.move_half = 1000.0   # the world is larger than the session arena (areas out to x -72 / 150): click-to-move must reach them
	session.player_joined.connect(_on_player_joined)
	session.player_left.connect(_on_player_left)
	var peer: MultiplayerPeer = opts.get("peer", null)
	if lobby == null and join is Dictionary:
		lobby = await party.seat(join)   # the world is built: the seat is taken just before the hello, so the host does not wait on a loading guest
		if lobby == null:
			start_failed.emit(String(party.last_error.get("text", "Could not join the party.")))
			return
	if lobby != null:
		lobby.relay = DmNextParty.checked_relay(lobby.relay)   # the test relay or none, whoever made the join
		var relay := DmRelayPeer.new()
		# Never call inside assert(): release exports strip asserts WITH their expression, so the guest never attached and never said hello (tools/hygiene rejects calls in asserts).
		var jerr := relay.join(lobby)
		if jerr != OK:
			printerr("[coop] guest: the lobby socket is not in a session (%s)" % error_string(jerr))
		relay.hold = true   # nothing from the host is delivered until every node it addresses exists (released below)
		_hold = relay
		peer = relay
		party.adopt_client(lobby, relay)
	if peer == null:
		peer = OfflineMultiplayerPeer.new()
	var err := session.join(peer) if guest else session.host(peer)
	assert(err == OK, "DmNextGame: session start failed (%s)" % error_string(err))
	bosses.fx.host.self_id = str(session.get_my_id())
	gather = DmNextGather.new()   # every peer, the same path: the host's depleted nodes arrive as RPCs, so it exists before a guest's hold is released below
	gather.name = "Gather"
	add_child(gather)
	await gather.setup(self)
	if guest:
		session.session_started.connect(party.send_profile)
		if _hold != null:
			_hold.hold = false   # every node the host addresses exists now (Session, Net, Core, Bosses, Party, Look): deliver what queued while the world was built
			_hold = null
		joiner = DmNextJoiner.new()   # our own account: the host's welcome hands it the party session to join (DmNextParty._rpc_welcome)
		joiner.name = "Joiner"
		add_child(joiner)
		await joiner.setup(self, bool(opts.get("persist", DisplayServer.get_name() != "headless")))
		if not await _await_active(CLIENT_ACTIVE_S):
			return   # start_failed was emitted: the caller returns to its own world
		var gb := local_body()
		core_host.set_focus_body(gb)
		net.apply_heroes()
		camera.snap(gb.position)
		_enter(gb.position)
		net.refused.connect(_on_net_refused)
		joiner.member.body = gb
		await _start_loot()
		joiner.event.connect(game_event)
	else:
		var b := local_body()
		b.bind_character(character)
		_register_body(b)
		await _start_value(b)
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
	await _start_hud()
	areas = DmAreaFlow.new()
	areas.name = "Areas"
	add_child(areas)
	areas.setup(self)
	if ui_host == null:
		DmRiteHotbar.wire(self)   # one hotbar path: the kit's mapping (LMB the primary, 1-4 the default loadout, RMB, R the signature); the full HUD's loadout replaces it
	if bool(opts.get("audio", DisplayServer.get_name() != "headless")) and get_node_or_null("/root/AudioDirector") != null:
		var hooks := DmAudioHooks.new()
		hooks.name = "AudioHooks"
		add_child(hooks)
		hooks.setup(self)
	if _visual:
		enemy_fx.warm(local_body().global_position)
		bosses.warm(local_body().global_position)
		DmRiteFx.with_autoloads().warm()
		# Every model, effect and area lighting drawn once under a cover, so no shader compiles mid-play (client/next/perf/dm_next_warmup.gd): for players
		# (`_wants_warmup`); `opts.warmup` overrides it.
		if bool(opts.get("warmup", _wants_warmup())):
			await DmNextWarmup.run(self)
	perf.hold()
	party.notice.connect(func(text: String, kind: String) -> void: game_event("toast", {"text": text, "kind": kind}))
	ready_ = true
	if ui_host != null:   # the counsel's welcome (and the discipline's first tip): the original game's `world_entered`
		var lvl := float(character.get("level", 1))
		var rl := DmAbilities.rite_level(lvl, ui_host.dev_access)
		var grim := false
		for id in ui_host.kit["grimoire"]:
			if DmAbilities.unlock_level(id) <= rl and DmAbilities.unlock_level(id) > 1:
				grim = true
		game_event("world_entered", {"family": local_body().family, "level": int(lvl), "grimoire_unlocked": grim})
	load_ms = Time.get_ticks_msec() - t0
	started.emit()
	if ui_host != null and joiner != null and joiner.notice != "":   # the backend refused the party session before the HUD existed
		game_event("toast", {"text": joiner.notice, "kind": "err"})
		joiner.notice = ""
	if ui != null:   # a player's window (the boot's game, not a test's bare scene)
		if String(opts.get("notice", "")) != "":   # why we are here (the session we were in ended, a join failed)
			game_event("toast", {"text": String(opts["notice"]), "kind": "err"})
		party.go_online()          # after the loading cover: friends see us online, invites and asks reach us (no-op without a lobby the build may use)
		_start_update_check(String(opts.get("update_check_installed", DmBuild.version())))
		friends.check_requests()   # a waiting friend request is a toast + the Friends tab's pip
	if not guest and DmNextParty.arg("--host-party") != null:   # a trial without a panel: host a Closed party at once and say its code
		party.hosting_changed.connect(func(on: bool) -> void:
			if on:
				printerr("[coop] hosting: the party's code is %s" % party.code)
				game_event("toast", {"text": "Party code: %s" % party.code, "kind": "good"}))
		party.host_session(String(DmNextParty.arg("--host-party")), true)


## Host: value on the server. The rewards session with this player's member (its open is not awaited: a failure arrives as session_failed), the meta systems, the
## Chronicle (before the progression: it adopts it) and the progression, which reads the saved state from the backend before the first wave, then this player's
## loot and bag. Awaited under the loading cover.
func _start_value(b: DmHeroBody) -> void:
	var cid := int(character.get("id", 0))
	rewards = DmSessionRewards.new()
	rewards.name = "Rewards"
	rewards.local_peer_id = session.get_my_id()
	rewards.area_id = "graves"
	add_child(rewards)
	rewards.attach_game(self)
	var d := DmCharacterBuild.discipline_for(float(character.get("class_index", 0)))
	rewards.add_member(DmRewardsMember.make(cid, session.get_my_id(), b, api, int(character.get("level", 1)), {"id": d["id"], "family": d["family"]}))
	rewards.start(cid)
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
	await chron.setup(self)
	progress = DmNextProgress.new()
	progress.name = "Progress"
	add_child(progress)
	await progress.setup(self, rewards.members.get(cid), bool(opts.get("persist", DisplayServer.get_name() != "headless")))
	boss_meta = DmBossMeta.new()
	boss_meta.name = "BossMeta"
	add_child(boss_meta)
	await boss_meta.setup(self)
	party.attach_host()
	codex = DmNextCodex.new()
	codex.name = "Codex"
	add_child(codex)
	codex.setup(self, progress.store)
	await _start_loot()
	for src: Node in [progress, meta]:
		src.connect(&"event", game_event)   # level-ups, toasts, floats -> the HUD


## This player's drops and bag (host or guest; after its rewards member exists). Awaited under the loading cover: it reads the bag.
func _start_loot() -> void:
	loot = DmNextLoot.new()
	loot.name = "Loot"
	add_child(loot)
	await loot.setup(self)
	loot.event.connect(game_event)   # toasts, floats, pickup lines -> the HUD


## A game moment for the player's screen (toast, banner, float, loot, chat, level_up ...): DmGameUi draws it or hands it to the counsel.
func game_event(id: String, ctx: Dictionary) -> void:
	if ui_host != null:
		ui_host.game_event.emit(id, ctx)


## The panels this build has to warm (no Altar: DECISIONS B36).
const WARM_PANELS := ["inventory", "sheet", "cosmetics", "legion", "forge", "professions", "garden", "labor", "contracts", "grimoire", "codex", "atlas", "map", "settings", "salvage", "shelf", "party"]


## The HUD and the panels (opts hud = true; DECISIONS B46): DmGameUi on DmNextUiHost, built and warmed under the
## caller's loading cover. The worn gear reaches the avatar and the socketed runes the caster whenever the bag changes.
func _start_hud() -> void:
	if opts.get("hud", false) != true:
		return
	ui_host = DmNextUiHost.new()
	ui_host.name = "UiHost"
	add_child(ui_host)
	await ui_host.setup(self, bool(opts.get("persist", DisplayServer.get_name() != "headless")))
	ui = DmGameUi.new()
	ui.name = "Ui"
	ui.warm_panels = WARM_PANELS
	add_child(ui)
	ui.setup(ui_host)
	ui.sound.connect(func(n: String) -> void:
		var a := get_node_or_null("/root/AudioDirector")
		if a != null:
			a.play_sfx(n))
	await ui.warm()
	if codex != null:
		codex.seed_ui()
	if belt() != null:
		belt().load_pick(ui.belt_pick())
	if loot != null:
		loot.inventory_changed.connect(sync_runes)                                      # a socketed / removed rune reaches the caster
		loot.inventory_changed.connect(func() -> void: look.set_gear_from_slots(loot.slots()))   # worn gear reaches the avatar (and the other peers)
		look.set_gear_from_slots(loot.slots())
	ui_host.load_cosmetics()
	sync_runes()
	if session.is_host():   # the Acre's labor / garden glue runs on the host's own character
		acre = DmNextAcre.new()
		acre.name = "Acre"
		add_child(acre)
		acre.setup(self)


## Host: push the bag's sockets to the local caster (the bag changed, or the HUD's inventory just loaded).
func sync_runes() -> void:
	var b := local_body()
	var c := b.get_node_or_null("Rites") as DmRiteCaster if b != null else null
	if c != null and session.is_host():
		c.set_runes(rune_sockets(session.get_my_id()))


## The core's EV_TARGET_HIT: enemy `enemy_id` hit external `target`. A hero takes it through its own damage rules, with the enemy as the source.
func _on_target_hit(enemy_id: int, target: int, kind: int, damage: float) -> void:
	var b := core_host.hero_for(target) as DmHeroBody
	if b == null:
		return
	var kind_name: String = DmCoreEvents.HIT_KINDS[kind]
	hits_taken[kind_name] = int(hits_taken.get(kind_name, 0)) + 1
	hero_hit.emit(enemy_id, kind_name, damage)
	b.dm_take_enemy_hit(damage, enemy_id, kind_name)


## The core's EV_TARGET_EFFECT: enemy `enemy_id` chilled, rooted or dragged external `target` (the Bog Hag's and the Fen Wisp's cold, the Drowned Sexton's chain). A hero takes it as the
## body's own `dm_enemy_effect` (a status, or the pull through the dash glide); a dead one refuses it.
func _on_target_effect(enemy_id: int, target: int, effect: int, seconds: float, x: float, z: float) -> void:
	var b := core_host.hero_for(target) as DmHeroBody
	if b == null:
		return
	var kind: StringName = DmCoreEvents.EFFECTS[effect]
	if kind == &"pull":
		var was_alive := b.alive
		b.dm_enemy_effect(kind, {"to": Vector3(x, b.position.y, z), "from": enemy_id})
		if was_alive and b.owner_peer != session.get_my_id():
			net.hero_effect(b.owner_peer, kind)   # a guest's own HUD floats "Dragged!" (the chill and the root are statuses: they replicate)
	else:
		b.dm_enemy_effect(kind, {"seconds": seconds, "from": enemy_id})


## The core's EV_ENEMY_DIED. The HOST credits the kill (once): to the hero who struck it, or to the owner of the thrall whose blow it was (the event names the thrall); a death with no
## hero behind it (a foe's own effect) has killer_peer 0. This is the kill report's and the rewards' hook (`kill_credited`).
## A guest's puppet core emits the same event for the picture (the death, the corpse, the sound) and credits nothing: its kills are in the host's report already.
func _on_enemy_died(id: int, def: String, level: int, elite: bool, area: String, source: int, x: float, z: float) -> void:
	if not session.is_host():
		return
	var killer := core_host.hero_for(source) as DmHeroBody if source != 0 else null
	if killer == null and source != 0:
		killer = core_host.hero_for(int(core_host.core.thrall_info(source).get("owner", 0))) as DmHeroBody
	kill_credited.emit(id, def, level, elite, area, killer.owner_peer if killer != null else 0, x, z)


## Host: a hero body (any player's) is an external of the core: its id is the source of its blows and the owner of its thralls, and the guests learn it from `Net`.
func _register_body(b: DmHeroBody) -> void:
	b.core_id = core_host.register_hero(b)
	b.tree_exiting.connect(func() -> void: core_host.unregister_hero(b))


## Where a new player appears: around the host's hero (null while he lies dead or is below in the Depths).
func _joiner_spawn() -> Variant:
	var b := local_body()
	if b == null or not b.alive or area_id == "depths":   # (a solo descent: a new player appears at the origin, the Chapterhouse)
		return null
	return b.position


## A new player's ring point moved onto the navmesh (about one in five fell off it).
func _walkable_spawn(pt: Vector3) -> Vector3:
	return world.nav_clamp(pt) if world.nav_ready() else pt


## Host: a player was accepted. Its body is an external of the core, then it gets the whole present (Net) and, once its profile arrives, its class and level (DmNextParty).
func _on_player_joined(id: int) -> void:
	if not session.is_host() or id == session.get_my_id():
		return
	var b := body_of(id)
	if b != null and b.core_id == 0:
		_register_body(b)
	net.add_guest(id)
	party.send_seals(id)   # the host's seals and doors (the baseline above is the core's present; the world's is told here)


## Host: a player left: its legion goes with it, the others learn the new table of heroes.
func _on_player_left(id: int) -> void:
	if not session.is_host():
		return
	var b := body_of(id)
	if b != null and b.core_id != 0:
		core_host.core.sacrifice_thralls(b.core_id)
	net.remove_guest(id)
	net.send_heroes()


func _on_session_ended(_reason: String) -> void:
	set_process(false)


## Guest: the host's messages cannot be used (another version of the game, other data). The player reads why, as a refused join says.
func _on_net_refused(why: String) -> void:
	session.abort(why)


func _make_body() -> DmSessionBody:
	var b := DmHeroBody.new()
	b.game = self
	b.died.connect(func(x: DmHeroBody) -> void: hero_died.emit(x))
	b.respawned.connect(func(x: DmHeroBody) -> void: hero_respawned.emit(x))
	return b


## Called by each DmHeroBody in its _ready: attaches "Rites" (the DmRiteCaster, `self` is its DmRiteWorld) and "Statuses" (the hero's DmStatusSet, a status set on a hero body
## only; the statuses of enemies and thralls are the core's). The legion is the caster's (`thralls()`, the core's thralls): there is no "Thralls" node.
## The host holds off for a guest's body: its caster would RPC the guest before the guest's spawner has created the body (a missing path).
func attach_caster(body: DmHeroBody) -> void:
	if multiplayer.is_server() and body.owner_peer != session.get_my_id():
		await get_tree().create_timer(CASTER_DELAY).timeout
		if not is_instance_valid(body) or not body.is_inside_tree():
			return
	var caster := DmRiteCaster.attach(body, self)
	if body.owner_peer == session.get_my_id():
		caster.shake_requested.connect(camera.shake)   # the camera honours reduce_motion
	caster.hit_resolved.connect(func(rite: String, enemy_id: int, amount: float, crit: bool, killed: bool) -> void: rite_hit.emit(rite, enemy_id, amount, crit, killed))
	if body.get_node_or_null("Statuses") == null:
		DmStatusSet.attach(body)


## Freed (log out, switch character): stop every effect, persistent decals included. The Vfx autoload outlives the game, and an effect that
## follows a body (an Unleash Souls orbit) would otherwise call its closure on the freed body every frame.
func _exit_tree() -> void:
	var vfx := get_node_or_null("/root/Vfx")
	if vfx != null:
		vfx.clear_all()


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
		if perf != null:
			perf.hold()   # an area entry is a load: slow frames around it are not a GPU problem
		world.enter_area(a)
		area_changed.emit(a)


## A player's window (opts.hud): the graphics, brightness, fps and window settings from the player's own file, READ only (the Settings panel that changes
## them comes with the panels). A bare scene (tests): High's defaults.
func _player_settings() -> Dictionary:
	return DmSettings.new(DmSettings.FILE, true).values if opts.get("hud", false) == true else {}


# ---- update notice (since launch day 2026-10-18) -----------------------------------------------------------------------

const UPDATE_TEXT := "A new version of Death Muffin is out. Restart the game from the launcher to update."
var update_check: DmUpdateCheck
var _update_shown := ""

## An installed release build asks every few minutes whether a newer one is out (DmUpdateCheck) and says so at once, fight or not (owner 2026-10-15).
func _start_update_check(installed: String) -> void:
	if not DmBuild.is_release(installed) or api == null or not api.has_method("fetch_client_manifest"):
		return
	update_check = DmUpdateCheck.new()
	update_check.name = "UpdateCheck"
	add_child(update_check)
	update_check.update_available.connect(func(_v: String) -> void: _show_update_notice())
	update_check.setup(installed, api.fetch_client_manifest)


func _show_update_notice() -> void:
	if update_check == null or ui_host == null or _update_shown == update_check.notified:
		return
	_update_shown = update_check.notified
	ui_host.game_event.emit("toast", {"text": UPDATE_TEXT, "kind": "good"})


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


## The build a body's caster reads (DmRiteWorld): its DmCharacterBuild and its socketed runes.
func rite_build(peer_id: int) -> Dictionary:
	var out := build_for(peer_id)
	out["runes"] = rune_sockets(peer_id)
	return out


## The runes a peer's character has socketed ({rite: rune_id}, DmRunes.sockets_of its rows): ours from our bag, a member's from the server's record
## of it (remote_builds, DECISIONS B22), {} until that arrives.
func rune_sockets(peer_id: int) -> Dictionary:
	var b := body_of(peer_id)
	if b == null or b.family != "necromancer":
		return {}
	if peer_id == session.get_my_id():
		return DmRunes.sockets_of(progress.slots()) if progress != null else {}
	var rb: Variant = remote_builds.get(peer_id)
	return DmRunes.sockets_of(rb["slots"]) if rb is Dictionary else {}


## The rite on a hotbar slot (0 = LMB primary, 1-4, 5 = RMB, 6 = R): the kit's mapping (no full HUD, so no loadout of the player's).
func rite_for_slot(slot: int) -> String:
	if ui_host != null:
		return ui_host.rite_at(slot)
	var b := local_body()
	return DmRiteHotbar.rite_for_slot(slot, b.family, b.discipline_id) if b != null else ""


## A body's DmCharacterBuild. The local host's carries its progression (damage tier, boons, vows) and its bag's gear (the progress node's; before it
## loaded, what the server gave: `server_slots`, `server_local`); a party member's comes from the server's record of that member (remote_builds: gear, set bonuses,
## boons, vows, upgrade tiers); until it arrives, the defaults. A guest's own hero is simulated by the host: what it builds here is only what it shows itself.
func build_for(peer_id: int) -> Dictionary:
	var b := body_of(peer_id)
	var ch: Dictionary = b.character if b != null and not b.character.is_empty() else {"class_index": 0, "level": 1}
	if peer_id == session.get_my_id():
		if progress != null:
			return DmCharacterBuild.build(ch, progress.slots(), without_ascension(progress.prog.local))
		return DmCharacterBuild.build(ch, server_slots, without_ascension(server_local))
	var rb: Variant = remote_builds.get(peer_id)
	if rb is Dictionary:
		var rch: Dictionary = (rb["character"] as Dictionary).duplicate()
		rch["level"] = maxf(float(rch.get("level", 1)), float(ch.get("level", 1)))   # a level-up the host credited since the fetch
		return DmCharacterBuild.build(rch, rb["slots"], without_ascension(rb["local"]))
	return DmCharacterBuild.build(ch, [], {})


## A progression record as a build reads it in the rebuild: without the vows and Covenant Boons (DECISIONS B36: Ascension is not in the rebuild; the saved
## data stays on the server, untouched).
static func without_ascension(local: Dictionary) -> Dictionary:
	if not local.has("vows") and not local.has("boons"):
		return local
	var out := local.duplicate()
	out.erase("vows")
	out.erase("boons")
	return out


## The local player's rewards member: the host's own (DmSessionRewards) or a guest's (DmNextJoiner), null before either exists.
func my_member() -> DmRewardsMember:
	if rewards != null:
		return rewards.members.get(int(character.get("id", 0)))
	return joiner.member if joiner != null else null


## The backend party session this player is in ("" = none: not open yet, or a backend without sessions). Claims and gear rolls carry it.
func party_session_id() -> String:
	if rewards != null:
		return rewards.session_id
	return joiner.session_id if joiner != null else ""


## The local hero's belt (Q the healing flask, Z / X the brews): the host's own (the progression's), or a guest's (the loot node's: its own bag pays, the host
## applies the drink).
func belt() -> DmNextBelt:
	if progress != null:
		return progress.belt
	return loot.guest_belt if loot != null else null


## Q / Z / X (DmNextUiHost) and the HUD's belt chips: drink the flask or a belt brew.
func use_belt(slot: String) -> void:
	var bl := belt()
	if bl == null:
		return
	if slot == "heal":
		bl.drink_flask()
	else:
		bl.drink_belt(slot)


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


## Where a fallen hero gets up: the Chapterhouse's return point (the Graves' door in a world without the Chapterhouse).
func respawn_point() -> Vector3:
	return world.spawn_point()


## The warm-up runs for players: not on a headless run, and not on a QA or screenshot run (`--qa`, `--shot-plan=`), where software GL
## spends minutes on it and nobody plays. `--warmup` forces it; `opts.warmup` overrides all of it (the benchmark: on; the look and HUD tools: off).
static func _wants_warmup(args: PackedStringArray = OS.get_cmdline_user_args(), display: String = DisplayServer.get_name()) -> bool:
	if "--warmup" in args:
		return true
	if display == "headless":
		return false
	for a in args:
		if a == "--qa" or a.begins_with("--shot-plan="):
			return false
	return true


## A guest: wait until the host accepted it (the roster arrived). false = the session ended or timed out first (`start_failed` emitted).
## The clock starts when our hello goes out and counts only frames that ran: the first frames after the world build can stall for many seconds, which used up the whole
## wait before the hello was even sent (2026-10-10 co-op report). CLIENT_HARD_S caps the wait however slow the frames are.
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
		printerr("[coop] guest: accepted by the host after %d ms" % (Time.get_ticks_msec() - begin))
		return true
	printerr("[coop] guest: gave up after %d ms (hello sent: %s, ended: %s)" % [Time.get_ticks_msec() - begin, session.hello_at_ms > 0, ended[0]])
	start_failed.emit(ended[0] if ended[0] != "" else "The host did not answer.")
	return false


## Everything the character earned, saved: the session's last kill batch, the Chronicle, the progression, the bag. leave() and the window's close call it.
func flush_all() -> void:
	if joiner != null:
		await joiner.flush_all()
	if rewards != null and session.is_host() and session.is_active():
		await rewards.end_session({})
	if chron != null:
		await chron.flush()
	if progress != null:
		await progress.flush_all()
	if loot != null and loot.inventory != null:
		await loot.inventory.flush()


func leave() -> void:
	await flush_all()
	# The session closes its own peer at the start of leave() (the host's closed RPC runs locally) and then waits 0.25 s: nothing in the
	# tree may tick without a peer (get_unique_id errors), so stop it first. The caller frees the node afterwards.
	process_mode = Node.PROCESS_MODE_DISABLED
	await session.leave()
