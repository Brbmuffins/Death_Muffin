class_name DmGame
extends Node3D
## The in-world root (port of src/scenes/WorldScene.ts): world + DmWorldSim stepped at the frame's dt (clamped to 0.1 s like the web),
## the hero (DmPlayer body + DmAbilitySystem caster), input, entity views, loot, progression / inventory saves, areas, death / respawn.
## Seam with the UI track: godot/GAME_CONTRACT.md (properties, methods and signals below). Build with `await game.start(character, api, opts)`.
##   opts: {visual: bool = true (false = headless: no world nodes / camera / Vfx), persist: bool = true, settings_path: String, seed: int}
## Headless drive: `game.tick(dt)`.

signal character_changed
signal inventory_changed
signal progress_changed
signal area_changed(id: String)
signal hero_died
signal hero_respawned
signal game_event(event_id: String, ctx: Dictionary)
signal left_world                       ## the UI asked to leave (log out): main returns to the login screen
signal world_restart(character: Dictionary)   ## the UI saved a new discipline (class_changed): main rebuilds the world with this character
signal npc_interact(npc_id: String)
signal station_interact(station_id: String)

const RESPAWN_MS := 4000.0
const RECALL_MS := 1500.0
const INTERACT_RANGE := 2.6
const MAX_DT := 0.1
const SNAPSHOT_MS := 100.0
const MOVE_SEND_MS := 100.0
const HUD_INTERVAL_MS := 50.0
const NPC_TALK_RANGE := 3.4
const PLAYER_RADIUS := 0.45

# ---- contract properties -------------------------------------------------------------------------------------------------------
var api: DmApi
var character: Dictionary = {}
var progress: Dictionary:
	get: return prog.local if prog != null else {}
var settings: Dictionary:
	get: return settings_store.values
var slots: Array:
	get: return inventory.slots if inventory != null else []
var sim: DmWorldSim
var hero_id: int = 0
var area_id: String = "acre"
var in_depths: bool = false
var lootview: DmLootView
var camera: DmCameraRig

# ---- state ---------------------------------------------------------------------------------------------------------------------
var opts: Dictionary = {}
var visual := true
var self_id := "self"
var self_name := "You"
var now_ms := 0.0
var ready_ := false
var settings_store: DmSettings
var prog: DmProgression
var psync: DmProgressSync
var inventory: DmInventory
var chronicle: DmChronicle
var player: DmPlayer
var p: Dictionary:
	get: return player.p
var nav: DmNav
var builder: DmWorldBuilder
var world_root: Node3D
var abilities: Variant = null          # DmAbilitySystem (or the plain DmSimCaster headless)
var views: Variant = null              # DmEntityViews
var event_fx: Variant = null           # DmEventFx
var avatar: Variant = null             # DmAvatar
var boss_views: Dictionary = {}        # boss id -> DmBossView
var gather: Variant = null             # DmGatherLoop (g.gatherer.loop)
var gatherer: DmGameGather
var depths: Variant = null             # DmDepthsController
var input: DmGameInput
var rewards: DmGameRewards
var combat: DmGameCombat
var actions: DmGameActions
var hitstopper := DmHitStop.new()
var discipline: Dictionary = {}
var build: Dictionary = {}
var kit: Dictionary = {}
var hotbar: Array = []
var loadout: Array = []
var primary: String = "bone_needle"
var seen: Dictionary = {}
var dev_access := false
var dev_account := false
var release: String = ""
var omen: Dictionary = {}
var vfx: Node
var audio_hooks: DmAudioHooks
var audio: Node
var store: DmCounselStore
var keybinds: Dictionary = {}
## The in-world UI (DmGameUi, set by main): a window is open (gates combat input like the web's panelOpen()), a conversation is open, the Next line shows.
var ui: Node = null
var panel_open: bool:
	get: return ui != null and ui.has_method("panel_open") and bool(ui.panel_open())
var dialogue_open: bool:
	get: return ui != null and ui.get("dialogue") != null and bool(ui.dialogue.visible)
var next_active: bool:
	get: return ui != null and ui.get("guidance_hud") != null and ui.guidance_hud.current != null
var dead_until := 0.0
var recall_at := 0.0
var last_combat_at := -1e9
var last_hurt_at := -1e9
var coop: DmGameCoop
var my_cosmetics := {"cape": "", "pet": ""}
var pet_view: DmPetView = null
var npc_views: DmNpcViews = null
var laborer_views: DmLaborerViews = null
var labor: DmGameLabor
var npc_new: Dictionary = {}           # npc id -> has something new to say (the UI sets it from the guidance)
var party_code: String:
	get: return coop.party_code if coop != null else ""
var mirror: DmSimMirror:
	get: return coop.mirror if coop != null else null
var remotes: Dictionary = {}           # co-op: id -> {info, avatar, x, z, tx, tz, facing, moving, hpFrac}
var _hud_at := -1e9
var _chron_t := 30.0
var _lines_busy := false
var _last_area := ""
var _announced_areas: Dictionary = {}
var _bond_at := 0.0
var _waystones: Array = []
var _world_data: Dictionary = {}
var _sim_world: Dictionary = {}
var _loot_ready := true
var net_down := false
var last_save_text := {"text": "Saved ✓", "warn": false}


func _make(path: String) -> Variant:
	var s: Variant = load(path) if ResourceLoader.exists(path) else null
	return s


## Build everything and connect to the server. `opts` documented on the class.
func start(character_: Dictionary, api_: DmApi, opts_: Dictionary = {}) -> void:
	opts = opts_
	release = "godot-" + str(ProjectSettings.get_setting("application/config/version", "dev"))
	vfx = get_node_or_null("/root/Vfx")
	audio = get_node_or_null("/root/AudioDirector")
	visual = bool(opts.get("visual", true)) and vfx != null and audio != null
	api = api_
	character = character_
	hero_id = int(character["id"])
	var persist: bool = bool(opts.get("persist", true))
	store = DmCounselStore.new("user://dm_local.json" if bool(opts.get("persist", true)) else "")
	keybinds = DmKeybinds.load_binds() if bool(opts.get("persist", true)) else {}
	settings_store = DmSettings.new(String(opts.get("settings_path", DmSettings.FILE)), persist)
	settings_store.set_active_character(hero_id, character.get("auto_combat_allowed", false) == true)
	settings_store.changed.connect(_on_settings_changed)
	DmSimData.ensure()
	self_name = String(opts.get("name", "You"))
	omen = _omen_for(Time.get_unix_time_from_system() * 1000.0)
	world_root = Node3D.new()
	world_root.name = "WorldRoot"
	add_child(world_root)
	_world_data = DmData.world()
	_sim_world = DmSimExact.load_json("res://data/sim/world.json")
	nav = DmNav.new()
	for o in _sim_world["obstacles"]:
		nav.add_obstacle(DmNavObstacle.from_dict(o))
	for s in _sim_world["sightBlockers"]:
		nav.add_sight_blocker(DmNavObstacle.from_dict(s))
	# Progression + chronicle + inventory (server state arrives below).
	prog = DmProgression.new(character, DmProgressSync.load_local(hero_id) if persist else null)
	chronicle = DmChronicle.new()
	prog.chronicle = chronicle
	chronicle.max_("peak.level", float(character.get("level", 1)))
	psync = DmProgressSync.new(api, prog, hero_id, persist)
	psync.save_state_changed.connect(func(_s): progress_changed.emit())
	psync.error.connect(func(m): toast(m, "err"))
	api.server_notice.connect(func(m): toast(m, "err"))
	prog.synced.connect(_on_progress_synced)
	prog.changed.connect(func(): progress_changed.emit())
	inventory = DmInventory.new(api, hero_id)
	inventory.changed.connect(_on_inventory_changed)
	# Kit, rites, hotbar.
	var base := DmCharacterBuild.discipline_for(float(character["class_index"]))
	kit = DmAbilities.kit_for(base["family"])
	dev_account = _is_dev_account()
	dev_access = dev_account and bool(settings["dev_access"])
	prog.dev_access = dev_access
	var rites := DmLoadout.load_rites(hero_id, DmAbilities.rite_level(float(character.get("level", 1)), dev_access), kit, persist)
	loadout = rites["keys"]
	primary = rites["primary"]
	seen = DmLoadout.load_seen(hero_id, rites, kit, persist)
	hotbar = _build_hotbar()
	# World nodes.
	if visual:
		_build_visual_world()
	nav.set_unlocked(open_areas())
	# Player, sim, caster.
	build = DmCharacterBuild.build(character, [], prog.local)
	discipline = build["discipline"]
	var pstate := DmPlayerRules.new_state(build["stats"], discipline["family"])
	player = DmPlayer.new(pstate, nav)
	var spawn: Dictionary = DmContent.get_export("areas", "PLAYER_SPAWN")
	player.teleport(float(spawn["x"]), float(spawn["z"]))
	_apply_player_extras()
	sim = DmWorldSim.new(nav, DmRng.new(int(opts.get("seed", int(Time.get_ticks_usec()) & 0x7fffffff))))
	sim.omen = omen
	sim.set_crypts(_sim_world["crypts"])
	sim.set_cover(_sim_world["cover"])
	sim.set_nodes(_sim_world["nodes"])
	sim.waveTier = float(prog.local["waveTierActive"])
	sim.difficulty = String(settings["difficulty"])
	sync_world_vows()
	input = DmGameInput.new(self)
	coop = DmGameCoop.new(self)
	rewards = DmGameRewards.new(self)
	combat = DmGameCombat.new(self)
	actions = DmGameActions.new(self)
	_make_abilities()
	_make_visual_components()
	depths = DmDepthsController.new(self)
	labor = DmGameLabor.new(self)
	if laborer_views != null:
		labor.views = laborer_views
		laborer_views.on_view = func(v: Dictionary) -> void: labor.note_labor(v)
	gatherer = DmGameGather.new(self)
	gather = gatherer.loop
	actions.load_belt()
	for d in DmContent.doors():
		if builder != null:
			builder.set_door_open(d["id"], nav.is_door_open(d), true)
	for a in DmContent.area_order():
		for it in DmContent.area(a)["interactables"]:
			if it["kind"] == "waystone":
				_waystones.append(it)
	apply_settings(settings_store.values)
	ready_ = true
	set_process(true)
	# Server data (the web's loadData + progression.connect).
	await _load_server_data()
	_enter_area(player.area if player.area != "" else "acre")
	if bool(opts.get("realtime", false)):
		coop.connect_initial()
	game_event.emit("world_entered", {"family": discipline["family"], "level": int(character["level"]), "grimoire_unlocked": grimoire_unlocked()})
	check_unlocks()


const DEV_ACCOUNTS := ["brbmuffins"]


## gm_enabled on the character, or a DEV_ACCOUNTS name in the session token (downloadable offline profiles can never be staff).
func _is_dev_account() -> bool:
	if character.get("gm_enabled", false) == true:
		return true
	var tok := api.get_token()
	if tok.begins_with("offline:"):
		return false
	return DmMain.token_username(tok).to_lower() in DEV_ACCOUNTS


## The Omen tints the sky over every area's own palette (half-way, so each place stays itself) and thickens or thins the fog in hunting grounds.
func _omen_light(area: String) -> void:
	var def: Dictionary = DmContent.area(area)
	var sky: Dictionary = omen["sky"]
	builder.moon.light_color = builder.moon.light_color.lerp(Color.hex(int(sky["moon"]) * 256 + 255), 0.5)
	var m: float = float(def["ambient"].get("fogMult", 1.0))
	if not def["safe"]:
		m *= float(sky["fogMult"])
	builder.env.fog_depth_end = 130.0 / maxf(0.2, m)


func _build_hotbar() -> Array:
	var sig: String = kit["signatures"].get(String(DmCharacterBuild.discipline_for(float(character["class_index"]))["id"]), "")
	var out: Array = loadout.duplicate()
	out.append(sig)
	return out


func _omen_for(ms: float) -> Dictionary:
	var order: Array = DmContent.get_export("omens", "OMEN_ORDER")
	var week_ms := 7.0 * 24.0 * 3600.0 * 1000.0
	var epoch := 4.0 * 24.0 * 3600.0 * 1000.0
	var w := int(floor((ms - epoch) / week_ms))
	return DmContent.get_export("omens", "OMENS")[order[((w % order.size()) + order.size()) % order.size()]]


func _build_visual_world() -> void:
	builder = DmWorldBuilder.new()
	builder.name = "World"
	builder.npcs_enabled = false
	world_root.add_child(builder)
	builder.build(_world_data)
	camera = DmCameraRig.new()
	camera.name = "Camera"
	add_child(camera)
	camera.setup(_world_data["camera"])
	lootview = DmLootView.new()
	lootview.name = "Loot"
	world_root.add_child(lootview)
	lootview.try_take = func(d: Dictionary) -> bool: return rewards.try_take(d)


func _make_abilities() -> void:
	var cls: Variant = _make("res://game/dm_ability_system.gd")
	var ctor: Variant = cls if cls != null else DmSimCaster
	abilities = ctor.new(sim, p, self_id, discipline["id"], discipline["family"], discipline["mods"])
	abilities.aim = {"x": 0.0, "z": 0.0}
	abilities.send_fn = Callable(self, "send_intent")   # every intent goes through the scene (lifesteal, guest relay)
	abilities.dash_fn = func(tx: float, tz: float) -> Array: return abilities.veil_target(p["x"], p["z"], tx, tz)
	if "game" in abilities:
		abilities.game = self
	abilities.dev = dev_access


## The hero stays findable: contact shadow + pale ring (buildScene), discipline glow + bone ring + reticle + soul halo + target ring (mount).
func _dress_hero() -> void:
	var at := func() -> Variant: return Vector3(player.x, 0, player.z)
	vfx.decal({"hero": true, "persistent": true, "tex": "glow", "blending": "mix", "color": 0x07040d, "x": 0.0, "z": 0.0, "r": 1.25, "y": 0.045, "duration": 1e9, "opacity": 0.5, "fadeIn": 0.5, "follow": at})
	vfx.decal({"hero": true, "persistent": true, "tex": "ring", "color": 0xf0e8ff, "x": 0.0, "z": 0.0, "r": 0.8, "y": 0.05, "duration": 1e9, "opacity": 0.6, "fadeIn": 0.5, "follow": at})
	var col: int = int(Color.html(String(DmContent.discipline(String(discipline["id"]))["color"])).to_rgba32() >> 8)
	vfx.decal({"tex": "glow", "color": col, "x": 0.0, "z": 0.0, "r": 2.2, "duration": 1e9, "opacity": 0.13, "fadeIn": 0.01, "follow": at})
	vfx.decal({"tex": "ring", "color": 0xc8bea8, "x": 0.0, "z": 0.0, "r": 0.85, "duration": 1e9, "opacity": 0.46, "fadeIn": 0.01, "follow": at})
	vfx.decal({"tex": "ring", "color": 0xb6a9c8, "x": 0.0, "z": 0.0, "r": 0.35, "duration": 1e9, "opacity": 0.36, "fadeIn": 0.01, "follow": func() -> Variant: return Vector3(input.ground["x"], 0, input.ground["z"])})
	vfx.decal({"tex": "ring", "color": int(DmContent.spell_fx()["souls"]["jade"]), "x": 0.0, "z": 0.0, "r": 1.25, "duration": 1e9, "opacity": 0.75, "fadeIn": 0.01, "pulse": 5.0,
		"follow": func() -> Variant: return Vector3(player.x, 0, player.z) if (DmPlayerRules.souls_charged(p) and player.alive) else null})
	vfx.decal({"tex": "ring", "color": 0xf0e9dc, "x": 0.0, "z": 0.0, "r": 1.0, "duration": 1e9, "opacity": 0.85, "fadeIn": 0.01, "pulse": 6.0,
		"follow": func() -> Variant:
			var h: Variant = input.hover
			var id := -1
			if h != null and h["kind"] == "enemy":
				id = int(h["id"])
			elif input.attack_target != null and input.attack_target["kind"] == "enemy":
				id = int(input.attack_target["id"])
			elif input.auto_target_id >= 0:
				id = input.auto_target_id
			var e: DmSimEnemy = sim.enemies.get(id) if id >= 0 else null
			return Vector3(e.x, 0, e.z) if (e != null and e.state != "rising" and e.state != "burrow") else null})


## Waystones must read as "click me" from across the room: a pulsing teal ring, a glow, and the Binbun portal.
func _dress_waystones() -> void:
	for w in _waystones:
		vfx.decal({"tex": "ring", "color": 0x6fe3c8, "x": w["x"], "z": w["z"], "r": 1.7, "duration": 1e9, "opacity": 0.85, "pulse": 1.2, "persistent": true})
		vfx.decal({"tex": "glow", "color": 0x1f8f86, "x": w["x"], "z": w["z"], "r": 2.2, "duration": 1e9, "opacity": 0.5, "persistent": true})
		vfx.play("waystone_portal", Vector3(float(w["x"]), 0, float(w["z"])), {})


func _waystone_motes(dt: float) -> void:
	for w in _waystones:
		if absf(float(w["x"]) - player.x) > 22.0 or absf(float(w["z"]) - player.z) > 22.0 or randf() > dt * 6.0:
			continue
		var a := randf() * TAU
		vfx.emit({"x": float(w["x"]) + sin(a) * 0.9, "y": 0.2, "z": float(w["z"]) + cos(a) * 0.9, "count": 1, "color": 0x9ff5e0, "spread": 0.1, "speed": 0.1, "up": 1.6, "life": 1.6, "size": 0.22})


func _make_visual_components() -> void:
	if not visual:
		return
	vfx.binbun.enabled = String(settings["graphics"]) == "high"
	if vfx.binbun.enabled:
		vfx.binbun.preload_ids(["toxic_puddle", "grave_hands_pulse", "dirge_area", "plague_bloom_area", "enemy_breach_rim", "crypt_mist", "bell_toll_ring", "miasma_cloud", "grave_frost_mist", "surge_eruption"])
	_dress_hero()
	_dress_waystones()
	lootview.dropped_sound.connect(func(id: String, pos: Vector3): play_sfx(id, pos.x, pos.z))
	lootview.pickup_fx.connect(func(pos: Vector3, color: Color): vfx.emit({"x": pos.x, "y": pos.y, "z": pos.z, "count": 8, "color": color.to_rgba32() >> 8, "spread": 0.3, "speed": 1.2, "up": 1.0, "life": 0.4, "size": 0.14}))
	npc_views = DmNpcViews.new()
	npc_views.setup(world_root)
	laborer_views = DmLaborerViews.new()
	laborer_views.setup(self)
	audio_hooks = DmAudioHooks.new()
	audio_hooks.name = "AudioHooks"
	add_child(audio_hooks)
	audio_hooks.setup(self)
	var c: Variant = _make("res://game/dm_entity_views.gd")
	if c != null:
		views = c.new()
		views.setup(self)
	c = _make("res://game/dm_event_fx.gd")
	if c != null:
		event_fx = c.new()
		event_fx.setup(self)
		event_fx.hooks = {
			"on_death": func(ev): rewards.on_kill(ev),
			"on_hurt": func(ev): combat.on_hurt_event(ev),
			"on_boss_bussy": func(ev): combat.on_boss_busy(ev),
			"on_boss_busy": func(ev): combat.on_boss_busy(ev),
			"on_surge_cleared": func(ev): rewards.on_surge_cleared(ev),
			"on_node_gone": func(id): gatherer.on_node_gone(String(id)),
			"on_node_back": func(id): gatherer.on_node_back(String(id)),
			"on_boss_defeated": func(ev): rewards.on_boss_defeated(ev),
		}
	c = _make("res://game/dm_avatar.gd")
	if c != null:
		avatar = c.new()
		var dd: Dictionary = DmContent.discipline(String(discipline["id"]))
		avatar.settings = settings
		avatar.setup(world_root, dd.get("color", 0xa26bff), true, String(dd.get("modelSlug", "necromancer")))
		avatar.set_equipment(DmGear.equipped_by_slot(inventory.slots))


# ---- server data ---------------------------------------------------------------------------------------------------------------

func _load_server_data() -> void:
	var inv := await api.get_inventory(hero_id)
	if inv.ok and inv.data is Array:
		inventory.replace(inv.data)
		refresh_stats()
	else:
		toast(inv.error if inv.error != "" else "Failed to load your reliquary", "err")
	if not bool(opts.get("local_progress", false)):
		await psync.connect_server()
	refresh_stats()
	var ch := await api.get_chronicle(hero_id)
	if ch.ok and ch.data is Dictionary:
		chronicle.set_data(ch.data)
	await gatherer.load_professions()
	await load_cosmetics()
	character_changed.emit()
	inventory_changed.emit()
	progress_changed.emit()


func refresh_character() -> void:
	var r := await api.get_character()
	if r.ok and r.data is Dictionary:
		for k in r.data:
			character[k] = r.data[k]
		refresh_stats()
		character_changed.emit()
	await load_cosmetics()


## The server's saved cape and companion (applyCosmetics): dress the hero, tell the party.
func load_cosmetics() -> void:
	var r: DmResult = await api.get_cosmetics(hero_id)
	if r.ok and r.data is Dictionary and r.data.get("selected") is Dictionary:
		apply_cosmetics(r.data["selected"])


func apply_cosmetics(sel: Dictionary) -> void:
	var cape: String = String(sel["cape"]) if sel.get("cape") != null else ""
	var pet: String = String(sel["pet"]) if sel.get("pet") != null else ""
	my_cosmetics = {"cape": cape, "pet": pet}
	if avatar != null:
		avatar.set_cape(cape)
	var def: Variant = _pet_def(pet)
	if (pet_view.id() if pet_view != null else "") != (String(def["id"]) if def != null else ""):
		if pet_view != null:
			pet_view.dispose()
			pet_view = null
		if def != null and visual:
			pet_view = DmPetView.new(world_root, def, player.x, player.z)
	coop.broadcast_gear(true)


static func _pet_def(id: String) -> Variant:
	if id == "":
		return null
	for p in DmContent.get_export("cosmetics", "PETS"):
		if p["id"] == id:
			return p
	return null


func refresh_inventory() -> void:
	var r := await api.get_inventory(hero_id)
	if r.ok and r.data is Array:
		inventory.replace(r.data)
	inventory_changed.emit()


func refresh_progress() -> void:
	var r := await api.necro_get(hero_id)
	if r.ok and r.data is Dictionary and r.data.has("progress"):
		prog.adopt(r.data["progress"])
	progress_changed.emit()


## Counsel facts about the bag (WorldScene's inventory.onChange handlers).
func counsel_bag_ctx() -> Dictionary:
	var used := 0
	var cand := false
	for sl in inventory.slots:
		if int(sl["slot_index"]) >= 0 and int(sl["slot_index"]) < DmLoot.bag_size() and not bool(sl.get("equipped", 0)):
			used += 1
			var t := String(sl.get("item_type", DmContent.item(String(sl["item_id"])).get("type", "")))
			if t == "weapon" or t.begins_with("armor_"):
				cand = true
	var lvl := DmAbilities.rite_level(float(character["level"]), dev_access)
	var learned := 0
	for id in DmLoadout.assignable_rites(kit):
		if DmAbilities.unlock_level(id) <= lvl:
			learned += 1
	var runes := 0
	for k in DmRunes.owned_runes(inventory.slots).values():
		runes += int(k)
	runes += DmRunes.sockets_of(inventory.slots).size()
	return {"slots_used": used, "bag_size": DmLoot.bag_size(), "family": discipline["family"], "kit_candidates": cand, "owns_rune": runes > 0, "learned_rites": learned, "rune_count": runes}


func _on_inventory_changed(_s: Array) -> void:
	emit_game_event("bag_changed", counsel_bag_ctx())
	if coop != null:
		coop.broadcast_gear()
	refresh_stats()
	if avatar != null:
		avatar.set_equipment(DmGear.equipped_by_slot(inventory.slots))
	inventory_changed.emit()


func _on_progress_synced() -> void:
	if builder == null and not ready_:
		return
	nav.set_unlocked(open_areas())
	_sync_doors()
	check_unlocks()
	if sim != null:
		sync_world_vows()
		sim.waveTier = float(prog.local["waveTierActive"])
	refresh_stats()
	progress_changed.emit()


func _sync_doors(instant: bool = false) -> void:
	if builder == null:
		return
	builder.set_unlocked(open_areas())
	for d in DmContent.doors():
		builder.set_door_open(d["id"], nav.is_door_open(d), instant)


func open_areas() -> Array:
	return DmContent.area_order() if dev_access else prog.local["unlocked"]


func sync_world_vows() -> void:
	if sim == null or (coop != null and coop.mirror != null):
		return
	sim.vows = DmAscension.world_vows(prog.vows())
	sim.corpseLifeMult = float(prog.boons()["corpseLifeMult"])


# ---- stats / build -------------------------------------------------------------------------------------------------------------

## WorldScene.refreshStats + applyBoons: one DmCharacterBuild.build() does the whole stack.
func refresh_stats() -> void:
	if player == null:
		return
	var was_main: String = str(p["loadout"].get("main", "")) if p.has("loadout") else ""
	build = DmCharacterBuild.build(character, inventory.slots, prog.local)
	discipline = build["discipline"]
	DmPlayerRules.set_stats(p, build["stats"])
	p["loadout"] = build["loadout"]
	_apply_player_extras()
	if abilities != null:
		abilities.mods = discipline["mods"]
	var now_main := str(build["loadout"].get("main", ""))
	if now_main != was_main and now_main != "" and now_main != "null" and now_main != "staff":
		tip("necroWeapon")
	if sim != null and (coop == null or coop.mirror == null):
		sim.waveTier = float(prog.local["waveTierActive"])


func _apply_player_extras() -> void:
	var boons: Dictionary = build["boons"] if not build.is_empty() else prog.boons()
	p["soulsMax"] = maxf(10.0, float(DmCombatData.const_table("SOUL_HARVEST")["souls"]) - float(boons["soulsDiscount"]))
	p["soulRateMult"] = float(discipline["mods"].get("soulHarvestRateMult", 1.0))
	p["runes"] = DmRunes.sockets_of(inventory.slots) if (inventory != null and discipline["family"] == "necromancer") else {}
	p["family"] = discipline["family"]


func grimoire_unlocked() -> bool:
	var lvl := DmAbilities.rite_level(float(character["level"]), dev_access)
	for id in kit["grimoire"]:
		if DmAbilities.unlock_level(id) <= lvl and DmAbilities.unlock_level(id) > 1:
			return true
	return false


func set_primary(id: String) -> void:
	if DmAbilities.rite_level(float(character["level"]), dev_access) < DmAbilities.unlock_level(id) or primary == id:
		return
	primary = id
	DmLoadout.save_rites(hero_id, {"primary": primary, "keys": loadout}, bool(opts.get("persist", true)))
	mark_seen([id])
	play_sfx("click")
	game_event.emit("rite_primary_set", {"ability": id})


func set_rite(slot: int, id: String) -> void:
	if slot < 0 or slot >= DmLoadout.SLOTS or not DmLoadout.assignable_rites(kit).has(id) or DmAbilities.rite_level(float(character["level"]), dev_access) < DmAbilities.unlock_level(id) or loadout[slot] == id:
		return
	loadout = DmLoadout.assign_rite(loadout, slot, id)
	DmLoadout.save_rites(hero_id, {"primary": primary, "keys": loadout}, bool(opts.get("persist", true)))
	mark_seen([id])
	hotbar = _build_hotbar()
	input.queued_cast = null
	play_sfx("click")
	game_event.emit("rite_key_set", {"ability": id})


func mark_seen(ids: Array) -> void:
	var changed := false
	for id in ids:
		if not seen.has(id):
			seen[id] = true
			changed = true
	if changed:
		DmLoadout.save_seen(hero_id, seen, bool(opts.get("persist", true)))


# ---- frame ---------------------------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not ready_:
		return
	tick(minf(delta, MAX_DT))


func _notification(what: int) -> void:
	# The web's window blur: held keys and aiming are forgotten, the hero stops (unless it is gathering AFK).
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and ready_:
		input.keys.clear()
		input.mouse["shift"] = false
		input.mouse["aiming"] = false
		if not gatherer.afk:
			player.stop()


func _unhandled_input(ev: InputEvent) -> void:
	if ready_ and input != null:
		input.handle(ev)


## WorldScene.update(dt, now): one frame.
func tick(dt: float) -> void:
	now_ms += dt * 1000.0
	var now := now_ms
	chronicle.time(dt, gather != null and gather.get("afk") == true)
	psync.tick(dt)
	inventory.tick(dt)
	_tick_chronicle(dt)
	if event_fx != null:
		event_fx.update(dt)
	# Death / respawn.
	if not player.alive and dead_until > 0.0 and now >= dead_until:
		respawn()
	input.update_cursor()
	input.update_attack_target(now)
	var kd := input.key_dir()
	if kd.x != 0.0 or kd.z != 0.0:
		input.attack_target = null
		input.pending_interact = null
		actions.cancel_recall()
		if gather != null:
			gather.stop("moved")
	var auto_move: Variant = input.auto_movement(dt, now)
	_update_movement_mods()
	var moved := player.update(dt, now, {"x": kd.x, "z": kd.z} if (kd.x != 0.0 or kd.z != 0.0) else auto_move)
	if settings_store.can_use_auto_combat() and bool(settings["auto_combat"]) and player.alive and now - float(p["lastHurtAt"]) < 5000.0:
		player.heal(player.max_hp() * 0.02 * dt)
	if now < actions.meal_until and player.alive:
		player.heal(actions.meal_rate * dt)
	gather.update(dt)
	labor.update(dt)
	if visual:
		gatherer.tick_visuals(dt)
	if moved:
		actions.cancel_recall()
	input.tick_combat(now)
	abilities.update(now, dt)
	combat.sync_legend(now)
	input.aim_when_standing(now)
	if recall_at > 0.0 and now >= recall_at:
		actions.cancel_recall()
		actions.teleport_to(float(DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")["x"]), float(DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")["z"]))
	if input.pending_interact != null and DmSimMath.hypot(input.pending_interact["x"] - player.x, input.pending_interact["z"] - player.z) < INTERACT_RANGE:
		actions.interact(input.pending_interact)
	var area := player.area if player.area != "" else area_id
	if area != area_id:
		_enter_area(area)
	if depths != null:
		depths.update(dt, now, player.area == "depths")
	# Authoritative world (solo / host), or the mirror of the host's (guest).
	if coop.mirror == null:
		sim.set_player(DmSimPlayer.make(self_id, player.x, player.z, player.area if player.alive else "", player.alive, float(character["level"]), String(discipline["family"])))
		for rid in remotes:
			var r: Dictionary = remotes[rid]
			sim.set_player(DmSimPlayer.make(rid, r["tx"], r["tz"], nav.area_at(r["tx"], r["tz"]), float(r["hpFrac"]) > 0.0, float(r.get("level", 1)), String(r.get("family", ""))))
		var events := sim.step(dt)
		for ev in events:
			handle_event(ev)
		coop.host_publish(events, now)
	else:
		event_out_clear()
		coop.guest_update(dt)
	coop.send_move(now)
	if visual:
		coop.update_remotes(dt)
	# Loot.
	rewards.tick_loot(dt)
	# Visuals.
	hitstopper.frame(dt)
	if visual:
		vfx.hitstop_scale = hitstopper.scale
		_tick_visuals(dt, now)
	input.tick_chain_and_beat(now)
	if visual:
		_tick_hud_state(now)
	combat.tick_bond(now)
	combat.tick_counsel(now)
	rewards.tick_milestones(dt)
	_tick_audio()


func _update_movement_mods() -> void:
	# Drowned Congregation: the water rises each phase; wading outside her dais is slower. The Mourning Fen: wading the bog is slow.
	var b := sim.boss.state
	var C: Dictionary = DmContent.get_export("bosses", "CONGREGATION")["water"] if DmContent.get_export("bosses", "CONGREGATION") != null else {}
	var mire := int(b.phase) if (b.active and b.id == "mire") else 0
	var wading := false
	if b.active and b.id == "congregation" and int(b.phase) >= 2 and player.area == "nave" and not C.is_empty():
		var arena: Dictionary = DmContent.boss("congregation")["arena"]
		var d := DmSimMath.hypot(player.x - arena["x"], player.z - arena["z"])
		wading = d <= float(arena["r"]) and d > float(C["dais"])
	var bog := 1.0
	if player.area == "fen":
		bog = DmFenRules.bog_mult(player.x, player.z, mire)
	var slow := 1.0
	if wading:
		slow = float(C["slowP3"]) if int(b.phase) >= 3 else float(C["slowP2"])
	if builder != null and builder.has_method("set_fen_flood"):
		builder.set_fen_flood(DmFenRules.flood_scale(mire))
	p["moveMult"] = slow * bog * (1.0 + DmPlayerRules.brew_value(p, "speed", now_ms))


func handle_event(ev: Dictionary) -> void:
	if ev["t"] == "boss" and input.telegraphs != null and event_fx == null:
		input.telegraphs.on_event(ev, now_ms)   # (DmEventFx feeds them itself, as onBossEvent does)
	# The caster hears the host's answers first (essence refunds, barrier, wisps, souls).
	var was_charged := DmPlayerRules.souls_charged(p)
	abilities.handle_event(ev)
	if ev["t"] == "death" and not was_charged and DmPlayerRules.souls_charged(p) and ev.get("killer") == self_id:
		rewards.on_souls_charged()
	if event_fx != null:
		event_fx.handle(ev)
	else:
		_handle_event_core(ev)


## Without the visual router (headless) the gameplay consequences still run.
func _handle_event_core(ev: Dictionary) -> void:
	if depths != null:
		depths.on_event(ev)
	match ev["t"]:
		"death":
			rewards.on_kill(ev)
		"hurt":
			combat.on_hurt_event(ev)
		"nodeGone":
			gatherer.on_node_gone(String(ev["id"]))
		"nodeBack":
			gatherer.on_node_back(String(ev["id"]))
		"bossBusy":
			combat.on_boss_busy(ev)
		"surgeCleared":
			rewards.on_surge_cleared(ev)
		"boss":
			if ev["kind"] == "defeated":
				rewards.on_boss_defeated(ev)


func _tick_visuals(dt: float, now: float) -> void:
	var vdt := dt
	if avatar != null and avatar.has_method("update"):
		avatar.update(vdt, player.x, player.z, player.facing, player.moving, float(p["stats"]["moveSpeed"]))
	if views != null:
		views.sync(sim.enemies, sim.thralls, vdt, player.x, player.z)
		views.prune_corpses(sim.corpses)
	var b := sim.boss.state
	if laborer_views != null:
		laborer_views.reduce_motion = bool(settings["reduce_motion"])
		laborer_views.update(vdt, player.x, player.z)
	if npc_views != null:
		_tick_npcs(vdt)
		npc_views.hover_id = ""
		if input.hover != null and input.hover["kind"] == "interact" and input.hover["it"]["kind"] == "npc":
			for nid in DmContent.get_export("npcs", "NPC_IDS"):
				if String(input.hover["it"]["id"]) == DmGuidance.npc_interactable_id(String(nid)):
					npc_views.hover_id = String(nid)
		npc_views.reduce_motion = bool(settings["reduce_motion"])
		npc_views.update(vdt, player.x, player.z, func(id: String) -> bool: return npc_new.get(id, false))
	if pet_view != null:
		pet_view.update(vdt, player.x, player.z, player.facing)
	var bv: Variant = boss_view(String(b.id) if b.id != "" else "prelate")
	if bv != null:
		bv.sync(b, vdt)
	var cx := player.x
	var cz := player.z
	camera.update_rig(dt, Vector3(cx, 0, cz))
	builder.update_occlusion(camera, Vector3(player.x, 0, player.z))
	builder.update_streaming(camera.focus.x, camera.focus.z)
	builder.update_light_lod(camera.focus.x, camera.focus.z)


var _npc_t := 0.0

## tickGuidance: who has something new to say (the "!"), first sight of a person, the conversation range.
func _tick_npcs(dt: float) -> void:
	var talking := ""
	if dialogue_open:
		talking = String(ui.dialogue.npc)
		if talking != "" and npc_views.distance_to(talking, player.x, player.z) > NPC_TALK_RANGE + 3.5:
			ui.dialogue.close()
			talking = ""
	npc_views.set_talking(talking)
	_npc_t -= dt
	if _npc_t > 0.0 or ui == null or ui.get("memory") == null:
		return
	_npc_t = 0.5
	var st: Dictionary = ui.guidance_state()
	for nid in DmContent.get_export("npcs", "NPC_IDS"):
		npc_new[nid] = ui.memory.has_something_new(String(nid), st)
		if npc_views.distance_to(String(nid), player.x, player.z) < 14.0 and ui.memory.first_sight(String(nid)):
			emit_game_event("npc_first_sight")


const REMOTE_GESTURE := {"exhumed": "exhume", "litanyResult": "black_litany", "detonated": "corpse_explosion", "mantle": "bone_mantle", "offering": "grave_offering",
	"rend": "command_rend", "rally": "rally_dead", "seeded": "carrion_seed"}

var empower_pending: String:
	get: return rewards.empower_pending if rewards != null else ""


## Rite events that carry their caster: a remote necromancer makes the same weapon gesture we would (castClips).
func remote_gesture(ev: Dictionary) -> void:
	var id: String = REMOTE_GESTURE.get(ev["t"], "")
	var by: Variant = ev.get("by")
	if id == "" or by == null or String(by) == self_id or not remotes.has(String(by)):
		return
	var r: Dictionary = remotes[String(by)]
	if r.get("avatar") != null:
		r["avatar"].cast("dig" if (id == "exhume" or id == "carrion_seed") else "cast", 2.0, r["facing"], float(DmAbilities.cast_flow(id)["gestureSeconds"]), id)


func boss_view_hide(id: String) -> void:
	var v: Variant = boss_view(id)
	if v != null:
		v.hide()


func boss_view(id: String) -> Variant:
	if boss_views.has(id):
		return boss_views[id]
	var c: Variant = _make("res://game/dm_boss_view.gd")
	if c == null:
		return null
	var v: Variant = c.new()
	v.setup(world_root, id)
	boss_views[id] = v
	return v


func _tick_audio() -> void:
	if not visual:
		return
	var b := sim.boss.state
	var area_ok := b.active and String(DmContent.boss(String(b.id) if b.id != "" else "prelate")["area"]) == area_id
	audio_hooks.update_boss(player.alive, b.active, String(DmContent.boss(String(b.id) if b.id != "" else "prelate")["area"]))


func event_out_clear() -> void:
	coop.event_out.clear()


func _tick_chronicle(dt: float) -> void:
	_chron_t -= dt
	if _chron_t > 0.0:
		return
	_chron_t = 30.0
	flush_chronicle()


func flush_chronicle() -> void:
	var batch := chronicle.flush_begin()
	if batch.is_empty():
		return
	var r := await api.add_chronicle(hero_id, batch["sums"], batch["maxes"])
	chronicle.flush_done(batch, r.ok)
	while not chronicle.pending_ascends.is_empty():
		var rank: int = chronicle.pending_ascends.pop_front()
		await api.ascend_chronicle(hero_id, rank)
		var g := await api.get_chronicle(hero_id)
		if g.ok and g.data is Dictionary:
			chronicle.set_data(g.data)


# ---- areas ---------------------------------------------------------------------------------------------------------------------

func _enter_area(area: String) -> void:
	area_id = area
	in_depths = area == "depths"
	_bond_at = now_ms + 1500.0
	if builder != null:
		builder.set_area(area)
	var def: Dictionary = DmContent.area(area)
	if not _announced_areas.has(area):
		_announced_areas[area] = true
		if area != "depths":
			banner(def["name"], def["subtitle"], 3000)
		if ["cloister", "pyre", "fen", "warren", "alchemist_wing", "coliseum"].has(area):
			game_event.emit("area_first_entered", {"area": area})
		if area == "acre":
			game_event.emit("area_first_entered", {"area": area})
	codex_discover("area", area)
	if laborer_views != null:
		laborer_views.set_active(area == "acre")
	psync.flush()
	area_changed.emit(area)


# ---- death / respawn -----------------------------------------------------------------------------------------------------------

func respawn() -> void:
	dead_until = 0.0
	if depths != null:
		depths.finish_after_death()
	player.revive()
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	player.teleport(float(ret["x"]), float(ret["z"]))
	if camera != null:
		camera.snap(Vector3(player.x, 0, player.z))
	if avatar != null and avatar.has_method("play_once"):
		avatar.set_loop("idle")
		avatar.play_once("dig", 1.2)
	toast("You rise again in the Chapterhouse. Nothing was lost.", "good")
	hero_respawned.emit()


## AbilitySystem.cast: the caster is headless; the TS stops the hero on these rites.
func node_hover(h: Variant) -> void:
	gatherer.node_hover(h)


func do_cast(id: String, target: Dictionary, now: float) -> String:
	var res: String = abilities.cast(id, target, now)
	if res == "ok" and (id == "veil_step" or id == "shield_bash" or id == "grave_slam"):
		player.stop()
	return res


# ---- contract methods ----------------------------------------------------------------------------------------------------------

func cast(slot: int) -> void:
	if slot <= 0:
		input.cast_slot_primary()   # the HUD's LMB socket
	else:
		input.cast_slot(slot)


func use_belt(slot: String) -> void:
	if slot == "heal":
		actions.drink_flask()
	else:
		actions.drink_belt(slot)


func navigate(x: float, z: float) -> bool:
	return input.navigate_from_minimap(x, z)


func set_auto_combat(on: bool) -> void:
	if not settings_store.can_use_auto_combat():
		return
	if settings["difficulty"] != "easy":
		toast("Auto combat is available on Easy difficulty. Change it in Settings.")
		return
	if bool(settings["auto_combat"]) == on:
		return
	settings_store.update({"auto_combat": on})
	input.auto_target_id = -1
	input.auto_aim = null
	toast("Auto combat on — your hero engages nearby enemies. Click or use keys to take control; G turns it off." if on else "Auto combat off — click enemies and use your rites manually.", "good")


func buy_upgrade(kind: String) -> void:
	var before := _thrall_numbers()
	var ok := false
	match kind:
		"damage": ok = prog.buy_damage()
		"wave": ok = prog.buy_wave()
		"legion": ok = prog.buy_legion()
	if not ok:
		return
	refresh_stats()
	if kind != "wave":
		_refresh_standing_thralls(before)
	play_sfx("shard")


func set_wave_tier(tier: float) -> void:
	prog.set_active_wave_tier(tier)
	if coop.mirror == null:
		sim.waveTier = float(prog.local["waveTierActive"])


func _thrall_numbers() -> Dictionary:
	return {"hp": float(p["stats"]["thrallHp"]), "damage": float(p["stats"]["thrallDamage"]), "speedMult": float(discipline["mods"]["thrallAttackSpeedMult"])}


func _refresh_standing_thralls(before: Dictionary) -> int:
	var after := _thrall_numbers()
	var r: Variant = DmLegion.thrall_refresh(before, after)
	if r == null:
		return 0
	var mine := 0
	for t in sim.thralls.values():
		if t.owner == self_id and t.state != "dead":
			mine += 1
	if mine == 0:
		return 0
	var intent: Dictionary = {"t": "refreshThralls", "by": self_id}
	intent.merge(r)
	send_intent(intent)
	return mine


func apply_settings(s: Dictionary) -> void:
	if opts.get("settings_applied_to_store", false) == false and s != settings_store.values:
		settings_store.update(s)
	if visual:
		audio.apply_settings(settings_store.audio_dict())
		vfx.quality = String(settings["graphics"])
		vfx.reduced_motion = bool(settings["reduce_motion"])
		if camera != null:
			camera.reduced_motion = bool(settings["reduce_motion"])
	hitstopper.disabled = func() -> bool: return bool(settings["reduce_motion"])
	if sim != null:
		_on_difficulty(String(settings["difficulty"]))


func _on_settings_changed(_v: Dictionary) -> void:
	_apply_dev_access()
	if sim != null:
		_on_difficulty(String(settings["difficulty"]))
	if visual and ready_:
		audio.apply_settings(settings_store.audio_dict())
		vfx.quality = String(settings["graphics"])
		vfx.reduced_motion = bool(settings["reduce_motion"])
		if camera != null:
			camera.reduced_motion = bool(settings["reduce_motion"])


func _on_difficulty(d: String) -> void:
	if coop != null and coop.mirror != null:
		if coop.mirror.difficulty != d:
			toast("The world keeper's difficulty applies (%s)" % String(DmContent.difficulty(coop.mirror.difficulty)["name"]))
		return
	if sim.difficulty == d:
		return
	sim.difficulty = d
	toast("Difficulty: %s — the next dead to rise feel it" % String(DmContent.difficulty(d)["name"]), "good")


# ---- optional contract methods (GAME_CONTRACT.md, "Additions by game-ui") -------------------------------------------------------------------

## Records a Codex discovery (kind: dead | area): the UI's Codex journal listens for `codex` {kind, id}.
func codex_discover(kind: String, id: String) -> void:
	emit_game_event("codex", {"kind": kind, "id": id})


## Opens or toggles one of the UI's windows (inventory, professions, labor, ...).
func open_panel(panel: String) -> void:
	if ui != null and ui.has_method("toggle_panel"):
		ui.toggle_panel(panel)


func travel(area: String) -> void:
	actions.travel(area)


func start_recall() -> void:
	actions.start_recall()


## Reliquary double-click / Drink / Eat (drinkFlask(prefer): a flask, a meal or a brew).
func use_item(item_id: String) -> void:
	actions.drink_flask(item_id)


## The UI owns the pick in its store and tells the game which brew a belt slot holds.
func set_belt(slot: String, item_id: String) -> void:
	if slot in ["elixir", "tonic"]:
		actions.belt[slot] = item_id
		actions.save_belt()


## Grimoire changes: the UI persists `dm_loadout_v2_<id>`; the HUD slots follow (setRite / setPrimary / applyRitesPreset).
func set_rites(new_primary: String, keys: Array) -> void:
	primary = new_primary
	loadout = keys.duplicate()
	hotbar = _build_hotbar()
	input.queued_cast = null
	DmLoadout.save_rites(hero_id, {"primary": primary, "keys": loadout}, bool(opts.get("persist", true)))
	mark_seen([primary] + keys)


## The Bone Grinder is within reach (WorldScene.nearGrinder: in the Acre, INTERACT_RANGE + 2 of the grinder).
func near_grinder() -> bool:
	if area_id != "acre":
		return false
	for it in DmContent.area("acre")["interactables"]:
		if it["kind"] == "grinder":
			return DmSimMath.hypot(float(it["x"]) - player.x, float(it["z"]) - player.z) < INTERACT_RANGE + 2.0
	return false


func counsel_busy() -> Dictionary:
	return combat.counsel_busy()


func counsel_tick_ctx() -> Dictionary:
	return combat.counsel_tick_ctx()


func stop_gathering(reason: String) -> void:
	gatherer.loop.stop(reason)


func afk_active() -> bool:
	return gatherer.loop.afk


func afk_status() -> Dictionary:
	return gatherer.afk_status()


## Starts AFK gathering on a node of that kind; returns "" or the player-readable refusal (also toasted).
func start_afk(node_id: String) -> String:
	var err: String = await gatherer.start_afk(node_id)
	if err != "":
		toast(err, "err")
	return err


func stop_player() -> void:
	player.stop()


func talk_key() -> void:
	actions.talk_key()


func dial_wave(delta: int) -> void:
	set_wave_tier(float(prog.local["waveTierActive"]) + delta)


func summon_boss(id: String) -> void:
	actions.summon_boss_normal(id)


func summon_boss_empowered(id: String) -> void:
	actions.call_empowered(id)


func enter_depths(depth: int) -> void:
	if depths != null:
		depths.enter(depth)


func talk_to(npc_id: String) -> void:
	actions.talk_to(npc_id)


func belt_choices(slot: String) -> Array:
	var out: Array = []
	var on: String = actions.belt_brew(slot)
	for id in DmContent.brews():
		var b: Dictionary = DmContent.brews()[id]
		if b["slot"] == slot and inventory.count(id) > 0:
			out.append({"id": id, "label": b["label"], "glyph": b["glyph"], "color": b["color"], "count": inventory.count(id), "current": id == on})
	return out


## Settings -> Leave: save, then log out (web: setToken(null); goLogin()).
func party_create() -> void:
	await coop.create_party()


func party_join(code: String) -> void:
	await coop.join_party(code)


func party_leave() -> void:
	await coop.leave_party()


func send_chat(text: String) -> void:
	coop.send_chat(text)


func pause_coop() -> void:
	coop.pause()


func resume_coop() -> void:
	coop.resume()


func leave_world() -> void:
	await flush_all()
	api.set_token("")
	left_world.emit()


## The UI saved a new discipline (ClassPanel) and hands the new character over: the world is rebuilt (web onClassChanged -> goWorld).
func class_changed(new_character: Dictionary) -> void:
	ready_ = false
	world_restart.emit(new_character)


func do_ascend() -> void:
	var heat: int = prog.heat()
	var earned: int = prog.ascend()
	if earned == 0:
		return
	sim.waveTier = 0.0
	refresh_stats()
	if visual:
		var altar: Dictionary = {}
		for it in DmContent.area("chapterhouse")["interactables"]:
			if it["kind"] == "upgrades":
				altar = it
		if not altar.is_empty():
			vfx.emit({"x": altar["x"], "y": 0.4, "z": altar["z"], "count": 120, "color": 0xd9a441, "spread": 1.2, "speed": 1.4, "up": 5.0, "life": 1.8, "size": 0.34})
			vfx.decal({"tex": "sigil", "color": 0xd9a441, "x": altar["x"], "z": altar["z"], "r": 4.0, "duration": 2.4, "opacity": 1.0, "growFrom": 0.2, "spin": 1.4})
	if camera != null:
		camera.shake(0.4)
	play_sfx("levelUp")
	banner("Ascended at heat %d" % heat, "+%d Ashes%s · swear your vows for the next run" % [earned, " · a new best rank" if (heat > 0 and heat >= int(prog.local["ascension"])) else ""], 4200)
	psync.flush()


func do_swear(next: Dictionary) -> void:
	var before := JSON.stringify(DmAscension.world_vows(prog.vows()))
	var restarted: bool = prog.vows_restart_run(next)
	if not prog.swear_vows(next):
		toast(prog.vows_problem(next) if prog.vows_problem(next) != "" else "The Altar refuses.", "err")
		return
	sync_world_vows()
	refresh_stats()
	if before != JSON.stringify(DmAscension.world_vows(prog.vows())):
		for a in DmContent.area_order():
			if not DmContent.area(a)["safe"]:
				sim.clear_area(a)
	play_sfx("shard")
	toast("Vows sworn: heat %d%s" % [prog.heat(), " · this run's tally restarts" if restarted else ""], "good")


func do_open(key: String) -> void:
	if not prog.unlock_at_altar(key):
		toast(prog.unlock_problem(key) if prog.unlock_problem(key) != "" else "The Altar refuses.", "err")
		return
	play_sfx("levelUp")
	toast("%s unlocked" % key.substr(key.find(":") + 1), "good")


## Dev access toggle (Settings -> preview as a normal player): rites, areas and gathering tiers open or close.
func _apply_dev_access() -> void:
	if not dev_account:
		return
	var on := bool(settings["dev_access"])
	if on == dev_access:
		return
	dev_access = on
	prog.dev_access = on
	gatherer.skills.dev_access = on
	if abilities != null:
		abilities.dev = on
	nav.set_unlocked(open_areas())
	_sync_doors()
	progress_changed.emit()
	toast("Dev access on: every rite, area and gathering tier is open (nothing is saved)." if on else "Dev access off: previewing as a normal player.", "good")


## Save everything now (leaving the world, class change, window close).
func flush_all() -> void:
	psync.save_local_now()
	await psync.flush()
	await inventory.flush()
	await gatherer.loop.flush()
	await flush_chronicle()


func _exit_tree() -> void:
	if coop != null:
		coop.dispose()
	if labor != null:
		labor.dispose()
	if laborer_views != null:
		laborer_views.dispose()
	if ready_ and psync != null:
		psync.save_local_now()


# ---- helpers the components use ------------------------------------------------------------------------------------------------

func send_intent(intent: Dictionary) -> void:
	# Lifesteal (elixir): every direct hit the player lands goes through here, so this is the one place it applies.
	if intent["t"] == "hit" and intent.get("by") == self_id and player.alive:
		var ls := DmPlayerRules.brew_value(p, "lifesteal", now_ms)
		if ls > 0.0:
			var heal := DmBrews.lifesteal_heal(float(intent["dmg"]), float((intent["ids"] as Array).size()) + (1.0 if intent.get("boss", false) else 0.0), ls, player.max_hp())
			if heal >= 1.0:
				player.heal(heal)
	if coop != null and coop.mirror != null:
		coop.rt.send_intent(intent)
	else:
		sim.apply(intent)


func emit_game_event(id: String, ctx: Dictionary = {}) -> void:
	game_event.emit(id, ctx)


func toast(text: String, kind: String = "") -> void:
	game_event.emit("toast", {"text": text, "kind": kind})


func banner(title: String, sub: String = "", ms: int = 3000) -> void:
	game_event.emit("banner", {"title": title, "sub": sub, "ms": ms})


func tip(id: String, delay_ms: float = 0.0, opts_: Variant = null) -> void:
	game_event.emit("tip", {"id": id, "delay_ms": delay_ms, "opts": opts_ if opts_ != null else {}})


func float_text(x: float, y: float, z: float, text: String, kind: String = "info", color: Variant = null) -> void:
	if not bool(settings["damage_numbers"]) and kind in ["hit", "dot", "thrall", "spear"]:
		return
	var ctx := {"world": Vector3(x, y, z), "text": text, "kind": kind}
	if color != null:
		ctx["color"] = color
	game_event.emit("float", ctx)


func hitstop(weight: float) -> void:
	hitstopper.request(weight)


func play_sfx(id: String, x: float = NAN, z: float = NAN, intensity: float = 1.0) -> void:
	if not visual:
		return
	if is_nan(x):
		audio.play_sfx(id, null, intensity)
	else:
		audio.play_sfx(id, Vector2(x, z), intensity)


func remote_ids() -> Array:
	return remotes.keys()


func check_unlocks() -> void:
	rewards.check_unlocks()


func _tick_hud_state(_now: float) -> void:
	pass


func hud_state() -> Dictionary:
	return DmGameHud.build(self)


func is_in_depths() -> bool:
	return area_id == "depths"
