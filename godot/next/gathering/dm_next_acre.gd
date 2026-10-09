class_name DmNextAcre
extends Node
## The Acre's world glue on the rebuild (child "Acre" of DmNextGame, host with the real HUD): the visible Grave Laborers
## (DmLaborerViews) and its labor / garden / contract notices (DmGameLabor), plus the first-hour guidance feeds the "Next" box and the
## Covenant dialogue read. Nothing is re-implemented: the two classes above are used as they are, and this node is the host object they talk to
## (api, hero_id, builder, world_root, settings, vfx / audio, toast / banner / emit_game_event, gatherer, chronicle, prog, ui).
## Cost: one bool test + DmGameLabor's three timers per frame; the laborers (4 pooled models, built on the first Acre visit) only update while
## the hero is in the Acre; the guidance feeds are event driven (a dirty flag, the skills' `changed`, the trophy signal), never polled.

signal guidance_fed

var game: DmNextGame
var labor: DmGameLabor
var views: DmLaborerViews
var hover_d := 0.0                      ## the laborer pick's screen distance (px) of the last pick_laborer() hit

# ---- the host surface DmGameLabor / DmLaborerViews read -------------------------------------------------------------------------
var api: Variant
var hero_id := 0
var builder: DmWorldBuilder
var world_root: Node3D
var gatherer: DmNextGather
var chronicle: DmChronicle
var prog: DmProgression
var vfx: Node
var audio: Node
var ui: DmGameUi
var player := HeroPos.new()             ## `player.x / z` for the float over the hero
var ready_: bool:
	get: return game != null and game.ready_
var settings: Dictionary:
	get: return game.ui_host.settings

var _recheck := 0.0


class HeroPos extends RefCounted:
	var game: DmNextGame
	var x: float:
		get: return game.local_body().position.x
	var z: float:
		get: return game.local_body().position.z


func setup(game_: DmNextGame) -> void:
	game = game_
	player.game = game
	api = game.api
	hero_id = int(game.character.get("id", 0))
	builder = game.builder
	world_root = game.world
	gatherer = game.gather
	chronicle = game.chron.chronicle
	prog = game.ui_host.prog
	ui = game.ui
	var visual := bool(game.opts.get("visual", true)) and DisplayServer.get_name() != "headless"
	vfx = get_node_or_null("/root/Vfx") if visual else null
	audio = get_node_or_null("/root/AudioDirector") if visual and bool(game.opts.get("audio", true)) else null
	labor = DmGameLabor.new(self)
	if builder != null:
		views = DmLaborerViews.new()
		views.setup(self)
		labor.views = views
		views.on_view = func(v: Dictionary) -> void: labor.note_labor(v)
		game.area_changed.connect(func(a: String) -> void: views.set_active(a == "acre"))
		views.set_active(game.area_id == "acre")
	# Guidance feeds: the gathering skills the Next box reads, the panels' own changes, the first-kill trophies.
	game.gather.skills.changed.connect(_feed_skills)
	_feed_skills()
	if ui.pb != null and ui.pb.labor != null:
		for sig: Signal in [ui.pb.labor.assign_requested, ui.pb.labor.recall_requested, ui.pb.labor.collect_requested]:
			sig.connect(func(_a: Variant = null, _b: Variant = null) -> void: _recheck = 0.8)
	game.chron.trophy_claimed.connect(func(_id: String) -> void: feed_trophies())
	feed_trophies()
	set_process(true)


func _process(dt: float) -> void:
	labor.update(dt)
	if _recheck > 0.0:
		_recheck -= dt
		if _recheck <= 0.0 and views != null:
			views.refresh()   # the Laborers panel assigned / recalled / collected: the posts follow (and the guidance summary with them)
	if labor.guide_dirty:
		labor.guide_dirty = false
		if labor.summary != null:
			ui.labor_summary = labor.summary
		if labor.contract_summary != null:
			ui.contract_summary = labor.contract_summary
		guidance_fed.emit()
		ui._guide_t = 0.0                  # recompute the Next box now, not at the next 0.5 s tick
	if views != null and views.active:
		var b := game.local_body()
		if b != null:
			views.update(dt, b.position.x, b.position.z)


func _exit_tree() -> void:
	if labor != null:
		labor.dispose()
	if views != null and is_instance_valid(views):
		views.dispose()


## The gathering levels the guidance reads (`ui.skills`): the panels refresh them on open, a level gained while gathering does it here.
func _feed_skills() -> void:
	for s in DmGathering.SKILL_IDS:
		ui.skills[s] = game.gather.skills.level(s)
	ui._guide_t = 0.0


## Bosses beaten (the guidance's `bossesBeaten`): the backend chronicle's `boss.<id>` counters, mirrored into the counsel store key the UI reads.
func feed_trophies() -> void:
	var got: Array = []
	for id in DmGuidance.boss_ids():
		if game.chron.has_trophy(String(id)):
			got.append(id)
	ui.store.set_item(DmGuidance.boss_trophy_key(float(hero_id)), JSON.stringify(got))
	ui._guide_t = 0.0


# ---- the host calls DmGameLabor makes ------------------------------------------------------------------------------------------------

func play_sfx(id: String, _x: float = NAN, _z: float = NAN, _k: float = 1.0) -> void:
	if audio != null:
		audio.play_sfx(id)


func refresh_inventory() -> void:
	await game.ui_host.refresh_inventory()


func refresh_character() -> void:
	game.ui_host.refresh_character()


func toast(text: String, kind: String = "") -> void:
	game.ui_host.game_event.emit("toast", {"text": text, "kind": kind})


func banner(title: String, sub: String = "", ms: int = 3000) -> void:
	game.ui_host.game_event.emit("banner", {"title": title, "sub": sub, "ms": ms})


func float_text(x: float, y: float, z: float, text: String, kind: String = "info") -> void:
	game.ui_host.float_text(Vector3(x, y, z), text, kind)


## The Acre panels' hooks (DmUiPanelsB calls them through the host adapter).
func on_labor_collected(r: Dictionary, slot: int) -> void:
	labor.on_collected(r, slot)


func on_garden_result(kind: String, r: Dictionary) -> void:
	labor.on_garden_result(kind, r)


func on_contract_delivered(d: Dictionary) -> void:
	labor.on_contract_delivered(d)


func emit_game_event(id: String, ctx: Dictionary = {}) -> void:
	game.ui_host.game_event.emit(id, ctx)


# ---- hover / click -----------------------------------------------------------------------------------------

## The laborer under the cursor, or -1: nearer than `limit` px (the node pass's best), with the web's 18 px bonus. Sets `hover_d`.
func pick_laborer(screen: Vector2, limit: float) -> int:
	if views == null or not views.active:
		return -1
	var cam: DmCameraRig = game.camera
	var best := -1
	var best_d := limit
	for l: Dictionary in views.pick_list():
		var v := Vector3(float(l["x"]), 1.0, float(l["z"]))
		if cam.is_position_behind(v):
			continue
		var d := cam.unproject_position(v).distance_to(screen) - 18.0
		if d < best_d:
			best_d = d
			best = int(l["slot"])
	hover_d = best_d
	return best


func set_hover(slot: int) -> void:
	if views != null and views.hover_slot != slot:
		views.set_hover(slot)


func tip(slot: int) -> String:
	return views.tip(slot) if views != null else ""


func open_labor() -> void:
	if not ui.is_open("labor"):
		ui.toggle_panel("labor")
