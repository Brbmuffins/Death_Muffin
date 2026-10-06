class_name DmChapterhouse
extends Node
## The hub of the slice, brought to life (child "Chapterhouse" of DmNextGame): NPCs you can talk to, stations that open the existing panels,
## waystone travel / recall, door seals, interactable hover + prompts. The rules are the current game's (DmGameActions.interact / talk_to /
## travel / start_recall, DmGameInput._pick, DmGameRewards.check_unlocks, DmGameHud.prompt); the content is the same (areas.json
## interactables, npcs.json, DmCovenantDialogue). Panels open through the DmGame-contract events on DmNextUiHost: `npc_interact(id)` and
## `station_interact(id)` (this node's signals of the same name are forwarded by the host).
##
## Cost: one 10 Hz tick (hover / pending interact / prompt), a 5 Hz NPC refresh, and the per-frame NPC animation only for NPCs near the player
## (DmHubNpcs). Nothing runs per frame for an idle hub with the player far from everyone.

signal npc_interact(npc_id: String)
signal station_interact(station_id: String)
signal interacted(it: Dictionary)                ## an interactable this hub does not own (boss summoning altars, stairs): the bosses / depths tracks listen here
signal seal_broken(area_id: String)
signal travelled(area_id: String)

const TICK_S := 0.1
const NPC_REFRESH_S := 0.2
const GUIDE_S := 0.5
const INTERACT_RANGE := 2.6                      ## DmGame.INTERACT_RANGE
const PICK_PX := 60.0                            ## DmGameInput._pick: interactables win over nothing within 60 px of the cursor
const WAYSTONE_RANGE := 5.0
const RECALL_S := 1.5                            ## DmGame.RECALL_MS
const STATIONS := {"forge": "workbench", "waystone": "waystone", "upgrades": "altar", "vault": "vault", "grinder": "grinder", "lectern": "lectern",
	"kiln": "kiln", "sawpit": "sawpit", "fire": "fire", "cauldron": "cauldron", "alembic": "alembic", "reagents": "shelf"}
const STATION_COUNSEL := {"kiln": "station_opened", "sawpit": "station_opened", "fire": "station_opened", "cauldron": "cauldron_opened",
	"alembic": "cauldron_opened", "reagents": "reagent_shelf_opened", "lectern": "lectern_used"}

var game: DmNextGame
var npcs: DmHubNpcs
var interactables: Array = []                    ## every interactable of every area, each with "area" added
var waystones: Array = []
var hover: Variant = null                        ## the interactable under the cursor, or null
var pending: Variant = null                      ## walking to it; interacts within INTERACT_RANGE
var prompt_text: Variant = null                  ## the HUD prompt (BBCode) or null
var talking: String = ""
var recall_active := false

var _acc := 0.0
var _npc_acc := 0.0
var _guide_acc := GUIDE_S
var _recall_end := 0
var _recall_fx: Variant = null
var _new: Dictionary = {}
var _npc_spots: Dictionary = {}
var _visual := false
var _vfx: Node
var _audio: Node


## Called by DmNextGame.start once the world exists (before the HUD).
func setup(game_: DmNextGame) -> void:
	game = game_
	_visual = game.opts.get("visual", true) and DisplayServer.get_name() != "headless"
	_vfx = get_node_or_null("/root/Vfx") if _visual else null
	_audio = get_node_or_null("/root/AudioDirector") if _visual else null
	for id in DmContent.area_order():
		for it in DmContent.area(String(id))["interactables"]:
			var d: Dictionary = (it as Dictionary).duplicate()
			d["area"] = String(id)
			interactables.append(d)
			if d["kind"] == "waystone":
				waystones.append(d)
	_npc_spots = DmContent.get_export("npcs", "NPCS")
	if game.world.builder != null:
		npcs = DmHubNpcs.new()
		npcs.setup(self)
		npcs.warm()
		npcs.refresh(0.0, 0.0, func(_id: String) -> bool: return false)
		_dress_waystones()
		game.input.clicked_move.connect(func(_p: Vector3) -> void:
			pending = null
			cancel_recall())
	set_process(true)


## After the rewards member exists: the persisted seal state decides which doors are open; kills that break a seal arrive with the
## rewards' accepted reports.
func start_seals() -> void:
	apply_seals()
	if game.rewards != null:
		game.rewards.member_credited.connect(func(_cid: int, _delta: Dictionary) -> void: check_seals())


# ---- frame / tick ---------------------------------------------------------------------------------------------------------------

func _process(dt: float) -> void:
	if npcs != null:
		npcs.animate(dt)
	_acc += dt
	if _acc < TICK_S:
		return
	var step := _acc
	_acc = 0.0
	_tick(step)


func _tick(dt: float) -> void:
	var b := game.local_body()
	if b == null:
		return
	if recall_active:
		if game.input.held_direction() != Vector3.ZERO or b.moving or not b.alive:
			cancel_recall()
		elif Time.get_ticks_msec() >= _recall_end:
			finish_recall()
	if pending != null:
		if game.input.held_direction() != Vector3.ZERO or not b.alive:
			pending = null
		elif _dist(pending, b) < INTERACT_RANGE:
			interact(pending)
	_npc_acc += dt
	if _npc_acc >= NPC_REFRESH_S and npcs != null:
		_npc_acc = 0.0
		_refresh_npcs(b, NPC_REFRESH_S)
	if _vfx != null:
		_waystone_motes(b)
	_update_prompt(b)


func _refresh_npcs(b: DmHeroBody, dt: float) -> void:
	var ui := game.ui
	if talking != "" and (ui == null or not _dialogue_open() or String(ui.dialogue.npc) != talking):
		_set_talking("")
	elif talking != "" and npcs.distance_to(talking, b.position.x, b.position.z) > DmContent.get_export("npcs", "NPC_TALK_RANGE") + 3.5:
		ui.dialogue.close()
		_set_talking("")
	elif talking == "" and ui != null and _dialogue_open() and String(ui.dialogue.npc) != "":
		_set_talking(String(ui.dialogue.npc))
	_guide_acc += dt
	if _guide_acc >= GUIDE_S and ui != null and ui.get("memory") != null:
		_guide_acc = 0.0
		var st: Dictionary = ui.guidance_state()
		for nid in DmContent.get_export("npcs", "NPC_IDS"):
			_new[nid] = ui.memory.has_something_new(String(nid), st)
			if npcs.distance_to(String(nid), b.position.x, b.position.z) < 14.0 and ui.memory.first_sight(String(nid)):
				_event("npc_first_sight")
	npcs.hover_id = String((hover as Dictionary).get("npc", "")) if hover != null else ""
	npcs.reduce_motion = bool(game.ui_host.settings["reduce_motion"]) if game.ui_host != null else false
	npcs.refresh(b.position.x, b.position.z, func(id: String) -> bool: return bool(_new.get(id, false)))


func _set_talking(id: String) -> void:
	talking = id
	npcs.set_talking(id)
	npcs.refresh(game.local_body().position.x, game.local_body().position.z, func(i: String) -> bool: return bool(_new.get(i, false)))


# ---- hover, click, prompt -------------------------------------------------------------------------------------------------------

func interactables_near(px: float, pz: float) -> Array:
	var out: Array = []
	for it in interactables:
		if absf(float(it["x"]) - px) < 26.0 and absf(float(it["z"]) - pz) < 22.0:
			out.append(it)
	return out


## The interactable nearest the cursor within PICK_PX (the NPC ones carry "npc": the npc id). Called by DmNextInput's 10 Hz hover and on click.
func pick(screen: Vector2) -> Variant:
	var b := game.local_body()
	if b == null:
		return null
	var cam: DmCameraRig = game.camera
	var best: Variant = null
	var best_d := PICK_PX
	for it in interactables_near(b.position.x, b.position.z):
		var v := Vector3(float(it["x"]), 1.2, float(it["z"]))
		if cam.is_position_behind(v):
			continue
		var d := cam.unproject_position(v).distance_to(screen)
		if d < best_d:
			best_d = d
			best = it
	return best


func hover_at(screen: Vector2) -> void:
	hover = pick(screen)
	if hover != null and hover["kind"] == "npc":
		(hover as Dictionary)["npc"] = npc_of(hover)


## Left click on the ground view (after enemies): walk to the interactable and use it on arrival. True = the click was consumed.
func click_at(screen: Vector2) -> bool:
	var b := game.local_body()
	if b == null or not b.alive:
		return false
	hover_at(screen)
	if hover == null:
		return false
	return click_interactable(hover)


func click_interactable(it: Dictionary) -> bool:
	var b := game.local_body()
	if b == null or not b.alive:
		return false
	cancel_recall()
	pending = it
	if _dist(it, b) < INTERACT_RANGE:
		interact(it)
	else:
		game.session.request_move_to(Vector3(float(it["x"]), 0.0, float(it["z"]) + 1.4))
	return true


func npc_of(it: Dictionary) -> String:
	for n in DmContent.get_export("npcs", "NPC_IDS"):
		if String(it["id"]) == DmGuidance.npc_interactable_id(String(n)):
			return String(n)
	return ""


## The NPC within talk range (the nearest), "" if none.
func nearest_npc() -> String:
	var b := game.local_body()
	if b == null:
		return ""
	var best := ""
	var best_d: float = float(DmContent.get_export("npcs", "NPC_TALK_RANGE"))
	for id in DmContent.get_export("npcs", "NPC_IDS"):
		var s: Dictionary = _npc_spots[id]
		var d := DmSimMath.hypot(float(s["x"]) - b.position.x, float(s["z"]) - b.position.z)
		if d < best_d:
			best_d = d
			best = String(id)
	return best


func _update_prompt(b: DmHeroBody) -> void:
	var p: Variant = null
	var awake: bool = game.bosses != null and game.bosses.active_boss() != null   # a boss site has nothing to offer while a boss is awake
	if hover != null and not _dialogue_open() and not (awake and String(hover["kind"]) == "boss"):
		p = "<kbd>Click</kbd> %s" % interact_prompt(hover)
	else:
		var n := nearest_npc()
		if n != "" and not _dialogue_open() and not _panel_open():
			p = "<kbd>E</kbd> Talk to %s" % _npc_spots[n].get("name", n)
		elif not awake and b != null and b.alive and not _dialogue_open() and not _panel_open():
			var site: String = game.bosses.site_near(b.position, DmBossHost.SUMMON_RANGE + 1.0) if game.bosses != null else ""
			if site != "":
				p = "<kbd>E</kbd> %s" % boss_prompt(site)
	prompt_text = p


func interact_prompt(it: Dictionary) -> String:
	match String(it["kind"]):
		"boss":
			var id := boss_for_summon(String(it["id"]))
			return boss_prompt(id if id != "" else "prelate")
		"stair", "depths_down", "depths_up", "depths_chest":
			return game.depths.prompt(it) if game.depths != null else "Use"
	return DmGameHud.interact_prompt(null, it)


func boss_prompt(boss_id: String) -> String:
	var b: Dictionary = DmContent.boss(boss_id)
	return "Summon %s · %d shards" % [b["name"], int(b["shards"])]


func boss_for_summon(id: String) -> String:
	for b in DmContent.get_export("bosses", "BOSS_IDS"):
		if DmContent.boss(b)["summonId"] == id:
			return b
	return ""


# ---- talking and stations -------------------------------------------------------------------------------------------------------

## The E key (DmGameUi calls it through the host): close the conversation, or talk to the nearest NPC.
func talk_key() -> void:
	var b := game.local_body()
	if b == null or not b.alive:
		return
	if _dialogue_open():
		game.ui.dialogue.close()
		return
	var id := nearest_npc()
	if id != "":
		talk_to(id)


func talk_to(id: String) -> void:
	var b := game.local_body()
	if b == null or not b.alive or not _npc_spots.has(id):
		return
	pending = null
	stop_player()
	var s: Dictionary = _npc_spots[id]
	b.yaw = atan2(float(s["x"]) - b.position.x, float(s["z"]) - b.position.z)
	_sfx("click")
	npc_interact.emit(id)


func stop_player() -> void:
	var b := game.local_body()
	if b == null:
		return
	pending = null
	if game.session.is_host():
		b.stop()
	else:
		game.session.request_move_to(b.position)


## Use an interactable (DmGameActions.interact).
func interact(it: Dictionary) -> void:
	pending = null
	stop_player()
	var kind := String(it["kind"])
	match kind:
		"inventory":
			_panel("inventory")
			station_interact.emit("reliquary")
		"professions":
			_panel("professions")
			station_interact.emit("professions")
		"npc":
			var n := npc_of(it)
			if n != "":
				talk_to(n)
		"stair", "depths_down", "depths_up", "depths_chest", "boss":
			interacted.emit(it)
		_:
			if STATIONS.has(kind):
				if STATION_COUNSEL.has(kind):
					_sfx("click")
					_event(STATION_COUNSEL[kind])
				station_interact.emit(STATIONS[kind])
			else:
				interacted.emit(it)


func near_grinder() -> bool:
	var b := game.local_body()
	if b == null or game.area_id != "acre":
		return false
	for it in interactables:
		if it["kind"] == "grinder":
			return _dist(it, b) < INTERACT_RANGE + 2.0
	return false


# ---- waystones / recall ---------------------------------------------------------------------------------------------------------

func near_waystone(b: DmHeroBody) -> bool:
	for w in waystones:
		if _dist(w, b) < WAYSTONE_RANGE:
			return true
	return false


## Waystone travel (DmGameActions.travel): from the Chapterhouse or beside a waystone, to any area with a waystone whose seal is broken.
func travel(area: String) -> void:
	var b := game.local_body()
	if b == null or not b.alive:
		return
	if not near_waystone(b) and game.area_id != "chapterhouse":
		_toast("Stand beside a waystone to travel (or press T to return home)", "err")
		return
	var prog := _prog()
	if prog != null and not prog.is_unlocked(area):
		_toast("%s is still sealed." % String(DmContent.area(area).get("name", area)), "err")
		return
	for it in waystones:
		if it["area"] == area:
			teleport_to(float(it["x"]), float(it["z"]) + 1.6)
			travelled.emit(area)
			return


func teleport_to(x: float, z: float) -> void:
	var b := game.local_body()
	if b == null or not game.session.is_host():
		return
	_sfx("waystoneTravel")
	pending = null
	if _vfx != null:
		_burst(b.position)
	b.teleport(Vector3(x, 0.0, z))
	var th := b.get_node_or_null("Thralls") as DmThrallHost
	if th != null:
		th.recall()
	game.camera.snap(Vector3(x, 0.0, z))
	if _vfx != null:
		_burst(Vector3(x, 0.0, z))


## T: after RECALL_S standing still, back to the Chapterhouse (any movement cancels).
func start_recall() -> void:
	var b := game.local_body()
	if b == null or not b.alive or recall_active:
		return
	if game.area_id == "chapterhouse":
		_float("Already in the Chapterhouse")
		return
	stop_player()
	recall_active = true
	_recall_end = Time.get_ticks_msec() + int(RECALL_S * 1000.0)
	_sfx("recallStart")
	if _vfx != null:
		_recall_fx = _vfx.decal({"tex": "sigil", "color": 0x8f9ed1, "x": b.position.x, "z": b.position.z, "r": 1.4, "duration": RECALL_S, "opacity": 0.9, "growFrom": 0.2, "spin": 3.0})
	if b.avatar != null and b.avatar.has_method("cast"):
		b.avatar.cast("cast", 1.0)


func cancel_recall() -> void:
	if not recall_active:
		return
	recall_active = false
	_sfx("recallCancel")
	if _recall_fx != null and _recall_fx.has_method("kill"):
		_recall_fx.kill()
	_recall_fx = null


func finish_recall() -> void:
	recall_active = false
	_recall_fx = null
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	teleport_to(float(ret["x"]), float(ret["z"]))
	travelled.emit("chapterhouse")


func _unhandled_key_input(ev: InputEvent) -> void:
	var e := ev as InputEventKey
	if e != null and e.pressed and not e.echo and e.keycode == KEY_T and not (get_viewport().gui_get_focus_owner() is LineEdit):
		start_recall()


# ---- seals and doors ------------------------------------------------------------------------------------------------------------

func _prog() -> DmProgression:
	if game.ui_host != null:
		return game.ui_host.prog
	var m: DmRewardsMember = game.rewards.members.get(int(game.character.get("id", 0))) if game.rewards != null else null
	return m.prog if m != null else null


## The areas whose seal is broken (what DmGame.open_areas / is_unlocked say), applied to the world's gates and navmesh regions.
func apply_seals() -> void:
	var prog := _prog()
	var b: DmWorldBuilder = game.world.builder
	if prog == null or b == null:
		return
	var open: Array = []
	for id in DmContent.area_order():
		if prog.is_unlocked(String(id)):
			open.append(id)
	b.set_unlocked(open)


## DmGameRewards.check_unlocks: an area whose seal asks N kills in the area before it breaks (the Warren: 150 in the Graves, less with Swift Seals).
## Returns the ids broken now.
func check_seals() -> Array:
	var prog := _prog()
	var out: Array = []
	if prog == null:
		return out
	for id in DmContent.area_order():
		var u: Variant = DmContent.area(String(id)).get("unlock")
		if u == null or prog.really_unlocked(String(id)):
			continue
		if prog.kills(String(u["area"])) >= prog.unlock_kills(float(u["kills"])) and prog.unlock(String(id)):
			out.append(String(id))
			apply_seals()
			var door: Variant = null
			for d in DmContent.doors():
				if d["b"] == id:
					door = d
					break
			_event("banner", {"title": "A seal breaks", "sub": "%s lies open%s" % [DmContent.area(String(id))["name"], (" · " + door_direction(door)) if door != null else ""], "ms": 4800})
			if door != null:
				_sfx("gate", (float(door["rect"]["x0"]) + float(door["rect"]["x1"])) / 2.0, (float(door["rect"]["z0"]) + float(door["rect"]["z1"])) / 2.0)
			game.camera.shake(0.3)
			seal_broken.emit(String(id))
			if game.ui_host != null:
				game.ui_host.progress_changed.emit()
	return out


## Which way a door lies from the hall it leaves.
func door_direction(door: Dictionary) -> String:
	var a: Dictionary = DmContent.area(String(door["a"]))["rect"]
	var b: Dictionary = DmContent.area(String(door["b"]))["rect"]
	var dx := (float(b["x0"]) + float(b["x1"])) / 2.0 - (float(a["x0"]) + float(a["x1"])) / 2.0
	var dz := (float(b["z0"]) + float(b["z1"])) / 2.0 - (float(a["z0"]) + float(a["z1"])) / 2.0
	if absf(dx) > absf(dz):
		return "east" if dx > 0.0 else "west"
	return "south" if dz > 0.0 else "north"


## Is the door between two halls open right now (the world's gate state).
func door_open(id: String) -> bool:
	var b: DmWorldBuilder = game.world.builder
	if b == null:
		return false
	if b.gates.has(id):
		return bool(b.gates[id].open)
	return b.nav_regions.has("door:" + id) and (b.nav_regions["door:" + id] as NavigationRegion3D).enabled


# ---- visuals / plumbing ---------------------------------------------------------------------------------------------------------

## Waystones read as "click me" from across the room (DmGame._dress_waystones): pulsing teal ring, glow, the Binbun portal.
func _dress_waystones() -> void:
	if _vfx == null:
		return
	for w in waystones:
		_vfx.decal({"tex": "ring", "color": 0x6fe3c8, "x": w["x"], "z": w["z"], "r": 1.7, "duration": 1e9, "opacity": 0.85, "pulse": 1.2, "persistent": true})
		_vfx.decal({"tex": "glow", "color": 0x1f8f86, "x": w["x"], "z": w["z"], "r": 2.2, "duration": 1e9, "opacity": 0.5, "persistent": true})
		_vfx.play("waystone_portal", Vector3(float(w["x"]), 0, float(w["z"])), {})


func _waystone_motes(b: DmHeroBody) -> void:
	for w in waystones:
		if absf(float(w["x"]) - b.position.x) > 22.0 or absf(float(w["z"]) - b.position.z) > 22.0 or randf() > TICK_S * 6.0:
			continue
		var a := randf() * TAU
		_vfx.emit({"x": float(w["x"]) + sin(a) * 0.9, "y": 0.2, "z": float(w["z"]) + cos(a) * 0.9, "count": 1, "color": 0x9ff5e0, "spread": 0.1, "speed": 0.1, "up": 1.6, "life": 1.6, "size": 0.22})


func _burst(p: Vector3) -> void:
	_vfx.emit({"x": p.x, "y": 1.0, "z": p.z, "count": 50, "color": 0x8f9ed1, "spread": 0.6, "speed": 1.5, "up": 2.5, "life": 1.0, "size": 0.35})


func _dist(it: Dictionary, b: DmHeroBody) -> float:
	return DmSimMath.hypot(float(it["x"]) - b.position.x, float(it["z"]) - b.position.z)


func _dialogue_open() -> bool:
	return game.ui != null and game.ui.get("dialogue") != null and bool(game.ui.dialogue.visible)


func _panel_open() -> bool:
	return game.ui != null and bool(game.ui.panel_open())


func _panel(id: String) -> void:
	if game.ui != null:
		game.ui.toggle_panel(id)


func _event(id: String, ctx: Dictionary = {}) -> void:
	if game.ui_host != null:
		game.ui_host.game_event.emit(id, ctx)


func _toast(text: String, kind: String = "") -> void:
	_event("toast", {"text": text, "kind": kind})


func _float(text: String) -> void:
	var b := game.local_body()
	if game.ui_host != null and b != null:
		game.ui_host.float_text(b.position + Vector3(0, 2.4, 0), text, "info")


func _sfx(id: String, x: float = NAN, z: float = NAN) -> void:
	if _audio != null:
		_audio.play_sfx(id, null if is_nan(x) else Vector2(x, z), 1.0)
