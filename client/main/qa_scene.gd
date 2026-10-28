class_name DmQaScene
extends RefCounted
## The scene words of the QA recorders: one vocabulary (STEPS_FILE, main/qa_clip_steps.json), one handler per word, used by the clip recorder (main/qa_clips.gd, `setup` and `steps` of a clip) and
## the screenshot recorder (main/qa_ui_shots.gd, `setup` and `steps` of a shot). client/main/CLIPS.md and client/main/SCREENSHOTS.md. It is a class of its own, not part of either recorder, so a word is written once
## and neither recorder owns the other's words.
##
## A `setup` word sets the scene before the picture or the recording (each has a static handler below: `show_hud` for hud, `stand_ins`, `set_souls`, `top_up` (read by the casts), `stand_at`, `set_zoom` and
## `frame_model` for zoom, `raise_thralls`); a `steps` word happens at its `at` seconds (the instance's `tick`: cast, walk, candles). `words` checks a list against the vocabulary and `setup_of` reads a setup
## into the options the handlers take. Every handler that changes the game returns what puts it back, so a shot leaves the next one a clean scene; a clip ends its run and `close` ends its steps.
## A new word is an entry in STEPS_FILE (its arguments and their types), its handler here (named in SETUP_WORDS or STEP_WORDS, read by `setup_of` or `tick`), and a check in tests/qa_shots.gd.

const STEPS_FILE := "res://main/qa_clip_steps.json"   ## the words `setup` and `steps` may use, and their arguments
const SETUP_WORDS := ["hud", "stand_ins", "souls", "top_up", "stand_at", "thralls", "zoom"]   ## the setup words the recorders carry out; STEPS_FILE lists the same
const STEP_WORDS := ["cast", "walk", "candles"]                                            ## the step words `tick` carries out
const MAX_SETUP := 12
const MAX_STEPS := 24
const MAX_WALK_POINTS := 8
const ZOOM_MIN := 0.4      ## the `zoom` word: closer than a player can zoom (0.7) is for looking at a detail
const ZOOM_MAX := 1.45
const DUMMY := "robber"
const DUMMY_HP := 400.0         ## health multiplier of the stand-ins
const SHOT_ENEMIES := 6         ## the stand-ins of a shot whose `stand_ins` gives no `count`
const FIGHT_SIGHT := {"aggro": 36.0, "leash": 90.0}   ## stand-ins that fight (`stand_ins` `fight`): they see the hero across the area, as the Depths' hunters do
const STILL_SIGHT := {"aggro": 0.5, "leash": 1.0}     ## the others notice nobody and stand where they are put
const PACK_AHEAD := 8.0         ## m from the hero to the middle of a pack
const LINE_FIRST := 4.0         ## m from the hero to the first enemy of a line
const LINE_STEP := 2.5          ## m between the enemies of a line
const FACING := Vector3(0.0, 0.0, -1.0)   ## the way the hero faces and casts: up the screen of the game's fixed camera
const SETTLE_S := 1.5           ## game seconds the scene stands still after the stand-ins have risen
const SETTLE_MAX_S := 20.0      ## and the longest wait for them to rise
const THRALL_DAMAGE := 30.0     ## what the `thralls` word's thralls hit for (the bench fight's: a mortal stand-in goes down in a few blows); they cannot be hurt, so a scene shows the same fight every time
const THRALL_RISE_S := 2.5      ## game seconds a scene with thralls stands still at least, so they have risen


## What stands in for another player in a `thralls` scene: a body the core host knows as a hero (its place, `alive`, its discipline) that is never in the scene.
class StandIn:
	extends Node3D
	var alive := true
	var discipline_id := ""


# ------------------------------------------------------------------------------------------------------------------ the vocabulary

## The words `setup` and `steps` may use (STEPS_FILE): {"setup": {word: {"help", "args": {name: {type, min, max, required}}}}, "steps": {...}}; {} when the file is missing.
static func vocabulary() -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(STEPS_FILE)) if FileAccess.file_exists(STEPS_FILE) else null
	return v if v is Dictionary else {}


## A `setup` or `steps` list checked against the vocabulary: {items (each {"do", "at" (steps only), <its arguments>}; steps sorted by `at`), error}. `who` names the clip or shot in a refusal ("clip 2").
## A step's `at` is from 0 to `end` seconds for a clip (the recording's length); for a shot (`shot`) it is before `end` (the wait's end, when the picture is taken).
static func words(v: Variant, section: String, who: String, end: float, shot := false) -> Dictionary:
	var out := {"items": [], "error": ""}
	var known: Dictionary = vocabulary().get(section, {})
	if not (v is Array):
		out["error"] = "%s: \"%s\" must be a list of {\"do\": ...} objects" % [who, section]
		return out
	var cap := MAX_SETUP if section == "setup" else MAX_STEPS
	if (v as Array).size() > cap:
		out["error"] = "%s: \"%s\" has %d entries (at most %d)" % [who, section, (v as Array).size(), cap]
		return out
	var k := 0
	for e in v:
		k += 1
		var w := "%s %s %d" % [who, section, k]
		if not (e is Dictionary):
			out["error"] = "%s is not an object" % w
			return out
		var word := String(e.get("do", ""))
		if not known.has(word):
			out["error"] = "%s: \"do\" must be one of %s (main/qa_clip_steps.json)" % [w, ", ".join(known.keys())]
			return out
		var args: Dictionary = known[word].get("args", {})
		var item := {"do": word}
		if section == "steps":
			var at: Variant = e.get("at")
			var due: bool = (at is float or at is int) and float(at) >= 0.0 and (float(at) < end if shot else float(at) <= end)
			if not due:
				out["error"] = "%s (%s): \"at\" must be a number of seconds from 0 to %s" % [w, word, ("before the shot's wait of %s (the picture is taken when it ends)" % DmQaTune.fmt(end)) if shot else ("the clip's %s" % DmQaTune.fmt(end))]
				return out
			item["at"] = float(at)
		for key in e:
			if key == "do" or (key == "at" and section == "steps"):
				continue
			if not args.has(key):
				out["error"] = "%s (%s) has an unknown argument \"%s\" (it takes: %s)" % [w, word, key, ", ".join(args.keys())]
				return out
			var why := arg_refusal(e[key], args[key])
			if why != "":
				out["error"] = "%s (%s): \"%s\" %s" % [w, word, key, why]
				return out
			item[key] = e[key]
		for key in args:
			if bool(args[key].get("required", false)) and not item.has(key):
				out["error"] = "%s (%s) needs \"%s\"" % [w, word, key]
				return out
		(out["items"] as Array).append(item)
	if section == "steps":
		(out["items"] as Array).sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["at"]) < float(b["at"]))
	return out


## "" when `value` is what `spec` asks for, else why not (in plain words, after the argument's name).
static func arg_refusal(value: Variant, spec: Dictionary) -> String:
	match String(spec.get("type", "")):
		"bool":
			return "" if value is bool else "must be true or false"
		"number":
			if not (value is float or value is int):
				return "must be a number"
			if (spec.has("min") and float(value) < float(spec["min"])) or (spec.has("max") and float(value) > float(spec["max"])):
				return "must be from %s to %s" % [DmQaTune.fmt(spec.get("min", 0)), DmQaTune.fmt(spec.get("max", 0))]
			return ""
		"point":
			return "" if is_point(value) else "must be a point [x, z]"
		"path":
			return "" if is_point(value) or (value is Array and not (value as Array).is_empty() and (value as Array).size() <= MAX_WALK_POINTS and (value as Array).all(is_point)) else "must be a point [x, z] or a list of at most %d of them" % MAX_WALK_POINTS
		"owners":
			return String(DmQaUiShots.thralls_of(value)["error"])
		"candle_group":
			return "" if value is String and DmQaUiShots.CANDLE_GROUPS.has(value) else "must be one of %s" % ", ".join(DmQaUiShots.CANDLE_GROUPS)
		"rite":
			return "" if value is String and DmRiteRegistry.has(value) else "must be a rite id of next/rites/dm_rite_registry.gd"
		"enemy":
			return "" if value is String and not DmContent.enemy(value).is_empty() else "must be an enemy id of data/content/enemies.json"
	return "has a type this recorder does not know (%s)" % str(spec.get("type", ""))


static func is_point(v: Variant) -> bool:
	return v is Array and (v as Array).size() == 2 and ((v as Array)[0] is float or (v as Array)[0] is int) and ((v as Array)[1] is float or (v as Array)[1] is int)


## A walk step's `to` as ground points: one [x, z] or a list of them.
static func points_of(to: Variant) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for pt in ([to] if is_point(to) else to):
		out.append(Vector3(float(pt[0]), 0.0, float(pt[1])))
	return out


## A setup as the handlers read it: every option with its default (the stand-ins as before, the HUD hidden, the souls as they are, topped up for each cast), and `words`, the setup words it names (a shot
## changes only what its setup names; a clip's own defaults apply to the rest).
static func setup_of(items: Array) -> Dictionary:
	var o := {"hud": false, "kind": DUMMY, "health": DUMMY_HP, "harmless": true, "fight": false, "distance": -1.0, "count": -1, "souls": -1.0, "top_up": true, "stand_at": null, "thralls": {}, "legion": [], "zoom": 0.0, "words": []}
	for it: Dictionary in items:
		(o["words"] as Array).append(String(it["do"]))
		match String(it["do"]):
			"hud":
				o["hud"] = bool(it["show"])
			"stand_ins":
				o["kind"] = String(it.get("kind", o["kind"]))
				o["health"] = float(it.get("health", o["health"]))
				o["harmless"] = bool(it.get("harmless", o["harmless"]))
				o["fight"] = bool(it.get("fight", o["fight"]))
				o["distance"] = float(it.get("distance", o["distance"]))
				o["count"] = int(it.get("count", o["count"]))
			"souls":
				o["souls"] = float(it["value"])
			"top_up":
				o["top_up"] = bool(it["on"])
			"stand_at":
				o["stand_at"] = Vector2(float(it["at"][0]), float(it["at"][1]))
			"thralls":
				o["thralls"] = DmQaUiShots.thralls_of(it["owners"])["thralls"]
			"zoom":
				o["zoom"] = clampf(float(it["value"]), ZOOM_MIN, ZOOM_MAX)
	return o


# ------------------------------------------------------------------------------------------------------------------ the setup words

## The waves and the enemies about away (the stand-ins and thralls are the only ones). Returns what puts the waves back.
static func quiet(game: DmNextGame) -> Callable:
	var waves := game.director.enabled
	game.director.enabled = false
	for id in game.core_host.enemies_in_radius(game.local_body().position, 400.0):
		game.core_host.remove_enemy(id)
	return func() -> void: game.director.enabled = waves


## `hud`: the HUD shown or hidden. Returns what puts it back as `was`.
static func show_hud(game: DmNextGame, show: bool, was: bool) -> Callable:
	if game.ui != null:
		game.ui.visible = show
	return func() -> void:
		if game.ui != null:
			game.ui.visible = was


## `stand_at`: the hero stands at the point [x, z] of the area he is in (the caller waits a frame or two for the area to follow). Returns what stands him where he was.
static func stand_at(game: DmNextGame, pt: Vector2) -> Callable:
	var body := game.local_body()
	var was := body.position
	game.chapterhouse.teleport_to(pt.x, pt.y)
	return func() -> void: body.teleport(was)


## The hero facing FACING, up the screen: the way the stand-ins are laid out and the rites are cast.
static func face_up(body: DmHeroBody) -> void:
	body.set_facing(atan2(FACING.x, FACING.z))


## `zoom`: the camera's zoom (1 the game's default, 0.7 the closest a player can zoom). Returns what puts it back as `was`.
static func set_zoom(game: DmNextGame, zoom: float, was: float) -> Callable:
	game.camera.zoom = zoom
	game.camera.target_zoom = zoom
	return func() -> void:
		game.camera.zoom = was
		game.camera.target_zoom = was


## `zoom` of a model view (`saved` is DmQaModel.begin's answer): the model's own framing, for a body of `view` (its size, or the walk it crosses), drawn back (or in) by `back` (0 = as framed).
## DmQaModel.end puts the camera back.
static func frame_model(game: DmNextGame, saved: Dictionary, view: Vector3, back: float) -> void:
	DmQaModel.frame(game, view)
	game.camera.cfg["dist"] = float(game.camera.cfg["dist"]) * (back if back > 0.0 else 1.0)
	game.camera.near = DmQaModel.cut_near(game.camera.cfg, saved["size"], game.camera.fov)
	game.camera.snap(game.local_body().position)


## `souls`: the Reaper's souls, held to her bag's size. Returns what gives her the souls she had.
static func set_souls(caster: DmRiteCaster, value: float) -> Callable:
	var was: Variant = caster.p.get("souls")
	if caster.p.has("soulsMax"):
		caster.p["souls"] = clampf(value, 0.0, float(caster.p["soulsMax"]))
	return func() -> void:
		if was != null:
			caster.p["souls"] = was


## Where the stand-ins stand for a hero at `origin` facing FACING: "pack" = a hexagonal bunch round the point PACK_AHEAD m ahead (1.5 m rings), "ahead" = a line down the facing, alternately 0.5 m to either side,
## from LINE_FIRST m away. `distance` (the setup's, when 0 or more) moves the pack's middle or the line's first one to that many metres ahead.
static func layout(at: String, n: int, origin: Vector3, distance := -1.0) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if at == "ahead":
		var first := distance if distance >= 0.0 else LINE_FIRST
		for i in n:
			out.append(origin + FACING * (first + LINE_STEP * i) + Vector3(0.5 if i % 2 == 0 else -0.5, 0.0, 0.0))
		return out
	var middle := origin + FACING * (distance if distance >= 0.0 else PACK_AHEAD)
	for i in n:
		if i == 0:
			out.append(middle)
		elif i <= 6:
			out.append(middle + Vector3(cos(TAU * float(i) / 6.0), 0.0, sin(TAU * float(i) / 6.0)) * 1.5)
		else:
			out.append(middle + Vector3(cos(TAU * (float(i - 7) + 0.5) / 6.0), 0.0, sin(TAU * (float(i - 7) + 0.5) / 6.0)) * 3.0)
	return out


## The ground point the rite is aimed at: the first stand-in of the layout (the middle of a pack, the near end of a line), or PACK_AHEAD m ahead when there are none.
static func aim_at(spots: Array[Vector3], origin: Vector3) -> Vector3:
	return spots[0] if not spots.is_empty() else origin + FACING * PACK_AHEAD


## `stand_ins`: the enemies at `spots` (snapped to the navmesh): by default the Graves' robbers with DUMMY_HP times the health and no damage, that notice nobody; the setup (`opts`: kind,
## health, harmless, fight) can make them another kind, mortal, able to hurt the hero, or come at the hero and fight. Returns their core ids.
static func stand_ins(game: DmNextGame, spots: Array[Vector3], opts := {}) -> Array[int]:
	var ids: Array[int] = []
	var mults := {"hp": float(opts.get("health", DUMMY_HP)), "dmg": 0.0 if bool(opts.get("harmless", true)) else 1.0}
	for spot in spots:
		var id := game.director.spawn(String(opts.get("kind", DUMMY)), game.world.nav_closest(spot), [], false, mults, FIGHT_SIGHT if bool(opts.get("fight", false)) else STILL_SIGHT)
		if id > 0:
			ids.append(id)
	return ids


## The stand-ins sent away without a death: the call that undoes `stand_ins`.
static func remove_stand_ins(game: DmNextGame, ids: Array) -> void:
	for id in ids:
		game.core_host.remove_enemy(id)


static func rising(core: DmCoreHost, ids: Array[int]) -> bool:
	for id in ids:
		var info := core.enemy_info(id)
		if not info.is_empty() and int(info["state"]) == DmCoreEvents.State.RISING:
			return true
	return false


## The scene stands still for `still_s` game seconds, and on while a stand-in is still rising (at most SETTLE_MAX_S).
static func settle(root: Node, core: DmCoreHost, ids: Array[int], still_s: float) -> void:
	var settled := 0.0
	var waited := 0.0
	while waited < SETTLE_MAX_S and (settled < still_s or rising(core, ids)):
		await root.get_tree().process_frame
		var dt := root.get_process_delta_time()
		waited += dt
		if not rising(core, ids):
			settled += dt


## How long the scene stands still before it is shown: SETTLE_S, and THRALL_RISE_S at least when thralls are raised.
static func still_for(thralls: Dictionary) -> float:
	return maxf(SETTLE_S, THRALL_RISE_S) if not thralls.is_empty() else SETTLE_S


## `thralls`: the waves away, the thralls raised (straight into the core, no corpses or cap) round their owners: the hero for "mine", a stand-in owner of a discipline STANDIN_SPOTS away from him for the rest.
## `damage` is what each thrall hits for (0 = none, a shot's looks; the word's thralls fight the enemies, with `clear` false so the enemies already about stay). Returns what puts it back: the thralls gone, the
## stand-ins unregistered, the waves as they were.
static func raise_thralls(game: DmNextGame, owners: Dictionary, damage := 0.0, clear := true) -> Array[Callable]:
	var host := game.core_host
	var hero := game.local_body()
	var waves := game.director.enabled
	game.director.enabled = false
	if clear:
		for id in host.enemies_in_radius(hero.position, 400.0):
			host.remove_enemy(id)
	var made: Array[StandIn] = []
	var spot := 0
	var raised := 0
	for owner in owners:
		var id := hero.core_id
		var at := Vector2(hero.position.x, hero.position.z)
		if owner != "mine":
			var body := StandIn.new()
			body.discipline_id = String(owner)
			var off: Vector2 = DmQaUiShots.STANDIN_SPOTS[spot]
			spot += 1
			body.position = Vector3(at.x + off.x, 0.0, at.y + off.y)
			id = host.register_hero(body)
			made.append(body)
			at += off
		var kinds: Array = owners[owner]
		for k in kinds.size():
			var kind := String(kinds[k])
			var a := TAU * float(k) / float(maxi(1, kinds.size()))
			var stats := DmThralls.raise_stats({"kind": kind, "hp": 1.0e6, "damage": damage, "attackSpeedMult": 1.0}, {"kind": "normal", "enemy": "risen", "elite": false}, 1.0, raised + 1, 0.0)
			host.core.raise_thrall(stats, id, at + Vector2(cos(a), sin(a)) * 1.9, 0.0, -1.0)
			raised += 1
	var undo: Array[Callable] = []
	undo.append(func() -> void:
		for tid in host.core.thrall_ids():
			host.core.kill_thrall(tid, "crumbled")
		for body in made:
			host.unregister_hero(body)
			body.free()
		game.director.enabled = waves)
	return undo


## The caster as a recording starts it: no cooldown, no cast lock, nothing of the last rites (`rites`) still going.
static func fresh_caster(caster: DmRiteCaster, rites: Array[String]) -> void:
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	for r in rites:
		caster.mem(r).clear()


## Fills what the rite costs, so a cast is never refused for it: the Reaper's soul bag, everyone else's essence.
static func top_up(caster: DmRiteCaster) -> void:
	if caster.p.get("family") == "reaper":
		caster.p["souls"] = maxf(float(caster.p["souls"]), float(caster.p.get("soulsMax", 30.0)))
	else:
		caster.p["resource"]["value"] = caster.p["resource"]["max"]


## The rites a scene casts: `rite` (a clip's own, "" for none) and those of its cast steps, each once.
static func rites_of(rite: String, steps: Array) -> Array[String]:
	var out: Array[String] = []
	if rite != "":
		out.append(rite)
	for st: Dictionary in steps:
		if st["do"] == "cast" and not out.has(String(st["rite"])):
			out.append(String(st["rite"]))
	return out


## `candles`: a Bell Sanctum candle group put out (`out`) or lit. Returns what lights the group again.
static func candles(game: DmNextGame, group: String, out: bool) -> Callable:
	var dressing = game.world.dressing
	if dressing == null:
		return func() -> void: pass
	dressing.set_candle_group(group, not out)
	return dressing.set_candle_group.bind(group, true)


# ------------------------------------------------------------------------------------------------------------------ the steps

var game: DmNextGame
var body: DmHeroBody
var caster: DmRiteCaster
var opts: Dictionary            ## the setup (`setup_of`): `top_up` is read by every cast
var aim: Vector3                ## where a cast is aimed (`aim_at`)
var steps: Array                ## the steps, sorted by `at`
var rites: Array[String]        ## the rites the scene casts, forgotten at `close`
var noun: String                ## "clip" or "shot", in what is said when a step goes wrong
var casts: Array = []           ## what `mark` was at each cast step that went off (a clip's frame number)
var failed := ""                ## why a step failed ("" = none has)
var refused := ""               ## why the host refused the last cast request ("" = it took it)
var next := 0                   ## the step to go off next
var walk: Array[Vector3] = []   ## the points the hero has still to walk to (the `walk` step)
var _on_refused: Callable


func _init(game_: DmNextGame, caster_: DmRiteCaster, opts_: Dictionary, aim_: Vector3, steps_: Array, rites_: Array[String], noun_: String) -> void:
	game = game_
	body = game_.local_body()
	caster = caster_
	opts = opts_
	aim = aim_
	steps = steps_
	rites = rites_
	noun = noun_
	_on_refused = func(_id: String, why: String) -> void: refused = why
	caster.cast_rejected.connect(_on_refused)


## A cast of `rite` at the aim (the caster topped up first unless the setup turned that off). Returns why the host refused it ("busy" and "cooldown" are tried again), "" when it took it.
func request(rite: String) -> String:
	if bool(opts["top_up"]):
		top_up(caster)
	refused = ""
	caster.request_cast(rite, aim, -1)
	return refused


## The seconds the next step is due at, INF when none is left.
func next_at() -> float:
	return float(steps[next]["at"]) if next < steps.size() else INF


## The steps due `t` seconds in, and the hero walking on to the next point of a walk path. A cast step that is busy or cooling down waits for the next call; any other refusal sets `failed`. `mark` is stored for each cast.
func tick(t: float, mark: Variant) -> void:
	if not walk.is_empty() and not body.has_target:
		body.set_move_target(walk.pop_front())
	while failed == "" and next < steps.size() and t >= float(steps[next]["at"]):
		var st: Dictionary = steps[next]
		match String(st["do"]):
			"walk":
				walk = points_of(st["to"])
				body.set_move_target(walk.pop_front())
			"candles":
				candles(game, String(st["group"]), bool(st.get("out", true)))
			_:   # "cast"
				var why := request(String(st["rite"]))
				if why == "busy" or why == "cooldown":
					return
				if why != "":
					failed = "step %d (cast %s at %s s) was refused (%s)" % [next + 1, st["rite"], DmQaTune.fmt(st["at"]), why]
					return
				casts.append(mark)
		next += 1


## "" when every step went off, else why not: one refused, or one that never came due before the end.
func problem() -> String:
	if failed != "":
		return failed
	if next < steps.size():
		return "step %d (%s at %s s) never went off before the %s ended (%s)" % [next + 1, steps[next]["do"], DmQaTune.fmt(steps[next]["at"]), noun, refused if refused != "" else "no time left"]
	return ""


## The scene's steps ended: the refusal watch off, a walk the scene did not finish stopped, the candles a step put out lit again, what the rites left behind forgotten.
func close() -> void:
	if caster.cast_rejected.is_connected(_on_refused):
		caster.cast_rejected.disconnect(_on_refused)
	body.stop()
	var dressing = game.world.dressing
	if dressing != null:
		for group in (dressing.candle_off as Dictionary).keys():
			dressing.set_candle_group(String(group), true)
	for r in rites:
		caster.mem(r).clear()
