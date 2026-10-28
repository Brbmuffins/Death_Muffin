class_name DmQaClips
extends RefCounted
## Clip plan for the QA driver (`-- --dev-offline --class=11 --qa --clip-plan=/abs/plan.json --clips=/abs/dir [--clip-fps=N] [--clip-width=N]`, with the engine started `--fixed-fps <the same N>`): short videos of a rite in use. Loaded by main/qa_driver.gd
## only when `--clip-plan=` is given, so normal play never touches it (and `DmMain.qa_wanted` lets it start on the dev-offline backend of a debug build only). client/main/CLIPS.md.
## For each clip the run enters the area, makes the stand-in enemies, lets the scene settle, then records the viewport at FPS frames per game second into `<dir>/<name>.mjpeg` (main/qa_mjpeg.gd), at most
## DmQaMjpeg.WIDTH wide, and writes `<dir>/<name>.json` = {fps, frames, width, height, cast_at_frame}. `--clip-fps=N` (MIN_FPS to MAX_FPS) and `--clip-width=N` (MIN_WIDTH to MAX_WIDTH) change those two
## (`options`): the team app records 1080p at 60 frames per game second with `--clip-fps=60 --clip-width=1920` and a window of 1920x1080 (Helix 2026-10-19), and makes the mp4 on the PC. Variants of a clip are runs of their own with another `--tune=` (main/qa_tune.gd).
##
## Plan: {"discipline": "reaper" (or 1-4 / 11; the game must have been started as that class: `--class=N`),
##        "equip": ["<item id>", ...] (at most DmQaUiShots.MAX_EQUIP, worn by the hero for every clip, through the backend's equip call like the shot plan's: the model previews),
##        "legion": ["<item id>", ...] (at most DmQaUiShots.MAX_LEGION: given to the Legion like the shot plan's, so the hero's thralls wear them; one armour piece and one weapon),
##        "clips": [{"name": "wraith", "area": "graves", "cast": "<rite id, e.g. haunting_wraith>", "at": "pack" | "ahead", "enemies": 6, "seconds": 5, "camera": "follow" | "wide" | "turntable" | "still",
##                   "equip": ["<item id>", ...] (this clip's own list: it wins over the plan's; the pieces worn before that are not in it are taken off),
##                   "setup": [{"do": "<word>", <its arguments>}, ...] (how the scene is set before recording), "steps": [{"at": <seconds>, "do": "<word>", ...}, ...] (what happens when)}]}
## `setup` and `steps` use the words of main/qa_clip_steps.json (each word, its arguments and their types), the same words and the same handlers as a shot's (main/qa_scene.gd, DmQaScene), e.g. setup [{"do": "hud", "show": true}, {"do": "stand_ins", "health": 1,
## "harmless": false}, {"do": "souls", "value": 0}, {"do": "top_up", "on": false}] and steps [{"at": 0.3, "do": "cast", "rite": "reap"}, {"at": 2, "do": "cast", "rite": "haunting_wraith"}]: mortal
## stand-ins, the HUD on screen, an empty soul bag that fills from the kills, two casts at set times. The runner checks a request against the branch's copy of that file; a new word is an
## entry there, its handler in qa_scene.gd and a check in tests/qa_shots.gd. `stand_at` puts the hero at a point of the area, `thralls` raises thralls for the hero ("mine") and for stand-in owners of other disciplines
## (the shot plan's, DmQaUiShots.thralls_of), and the steps `walk` (the hero walks to a point or along a path) and `candles` (a Sanctum candle group out or lit) make a scene with no rite in it: such a clip needs no `cast`.
## At most MAX_CLIPS clips (the rest are left out, with a note), `seconds` MIN_SECONDS to MAX_SECONDS and `enemies` 0 to MAX_ENEMIES (clamped, with a note). Defaults: area graves, at pack, 6 enemies, 5 s, follow.
## "at": "pack" = the enemies bunched PACK_AHEAD m in front of the hero (the rite is aimed at the middle of them: a burst, a cloud, a thrown thing); "ahead" = the enemies in a line down the way the
## hero faces, from LINE_FIRST m away, LINE_STEP m apart (the rite is aimed down the line: a thing that travels). "camera": "follow" = the game's own camera; "wide" = its widest zoom;
## "turntable" = the hero's close-up (the shot plan's "hero" view) while the hero turns once round slowly, standing idle in place at the area's waystone, over the clip (a model preview: "cast" is not needed, "area" is the Chapterhouse
## unless it says another, "seconds" 6 unless it says another, and no enemies unless asked for).
## A clip with "model" or "model_file" (main/qa_model.gd, DmQaModel: with "height", "anim", "turn") records that model instead of the hero, framed by its size; "move": true walks it across the frame at "speed"
## (else its row's stride times its height) with the camera following, or with "camera": "still" past a camera that stays put, drawn back to frame the whole walk; "camera": "turntable" turns it round.
## Such a clip needs no "cast" and stands at DmQaModel.SPOT of the Chapterhouse unless it says where.
## Unless the setup says otherwise, the stand-ins are the Graves' robbers with a lot of health and no damage that stand where they are put (a tune that changes the rite's damage cannot kill them or
## hurt the hero), and the HUD is hidden. Without cast steps the rite of `cast` is cast LEAD_FRAMES frames in (so the first frames show the scene before it) and again each time it is off cooldown (a rite with no cooldown is cast once);
## the hero's souls and essence are topped up for each cast unless the setup turns that off.

const FPS := 30                 ## frames per game second, unless the run asks for another (`options`)
const MIN_FPS := 10
const MAX_FPS := 60
const MIN_WIDTH := 320          ## the narrowest and widest picture a run may ask for (`--clip-width=`)
const MAX_WIDTH := 1920
const MAX_CLIPS := 4
const MIN_SECONDS := 1.0
const MAX_SECONDS := 8.0
const MAX_ENEMIES := 12
const MAX_NAME := 32            ## characters (the team app puts the variant's label before it in a file name)
const ATS := ["pack", "ahead"]
const CAMERAS := ["follow", "wide", "turntable", "still"]
const LEAD_FRAMES := 6          ## the scene is recorded this long (at FPS) before the first cast: 0.2 s, the same time at any frame rate


## The run's recording options from the game's arguments: {fps, width, notes}. `--clip-fps=N` and `--clip-width=N` outside their ranges, or not whole numbers, keep the defaults (FPS, DmQaMjpeg.WIDTH) with a note.
static func options(args: PackedStringArray) -> Dictionary:
	var out := {"fps": FPS, "width": DmQaMjpeg.WIDTH, "notes": []}
	for a in args:
		for spec in [["--clip-fps=", "fps", MIN_FPS, MAX_FPS], ["--clip-width=", "width", MIN_WIDTH, MAX_WIDTH]]:
			if not a.begins_with(spec[0]):
				continue
			var v := a.trim_prefix(spec[0])
			if v.is_valid_int() and int(v) >= int(spec[2]) and int(v) <= int(spec[3]):
				out[spec[1]] = int(v)
			else:
				(out["notes"] as Array).append("%s%s is not a whole number from %d to %d: %d kept" % [spec[0], v, spec[2], spec[3], out[spec[1]]])
	return out


## Parses and validates plan text. Returns {ok, error, discipline (name or ""), class_index (0 = not set), equip (the plan's), clips, notes}; each clip is {name, area, cast, at, enemies, seconds, camera, equip (what it wears:
## its own list, else the plan's), dress (the plan names items somewhere: the run sets what is worn for every clip)}.
static func parse(text: String) -> Dictionary:
	var out := {"ok": false, "error": "", "discipline": "", "class_index": 0, "equip": [], "legion": [], "clips": [], "notes": []}
	var js := JSON.new()
	var raw: Variant = js.data if js.parse(text) == OK else null
	if not (raw is Dictionary):
		out["error"] = "plan must be a JSON object"
		return out
	var list: Variant = raw.get("clips")
	if not (list is Array) or (list as Array).is_empty():
		out["error"] = "plan needs a non-empty \"clips\" array"
		return out
	var disc: Variant = raw.get("discipline")
	if disc != null:
		var ci := DmQaUiShots.class_index_of(disc)
		if ci == 0:
			out["error"] = "unknown discipline \"%s\" (known: %s)" % [disc, ", ".join(DmQaUiShots.DISCIPLINES.keys())]
			return out
		out["class_index"] = ci
		out["discipline"] = String(DmQaUiShots.DISCIPLINES.find_key(ci))
	var worn := _equip_list(raw.get("equip", []), "the plan", out["notes"])
	if worn["error"] != "":
		out["error"] = worn["error"]
		return out
	out["equip"] = worn["ids"]
	var kit: Variant = raw.get("legion", [])
	if not kit is Array:
		out["error"] = "the plan: \"legion\" must be a list of item ids"
		return out
	for id in kit:
		if DmLegion.kit_id_for_type(DmLootData.item(String(id)).get("type")) == null:
			out["error"] = "the plan: legion: \"%s\" cannot go on the Legion (an armour piece or a weapon)" % id
			return out
		if (out["legion"] as Array).size() >= DmQaUiShots.MAX_LEGION:
			(out["notes"] as Array).append("the plan has more than %d Legion items, only the first %d are given" % [DmQaUiShots.MAX_LEGION, DmQaUiShots.MAX_LEGION])
			break
		(out["legion"] as Array).append(String(id))
	var any_equip: bool = raw.has("equip")   # a plan that names items anywhere takes charge of what is worn for every clip
	var seen := {}
	var i := 0
	for c in list:
		if i >= MAX_CLIPS:
			(out["notes"] as Array).append("the plan has %d clips, only the first %d are made" % [(list as Array).size(), MAX_CLIPS])
			break
		var n := i + 1
		if not (c is Dictionary):
			out["error"] = "clip %d is not an object" % n
			return out
		var cast := String(c.get("cast", ""))
		var camera := String(c.get("camera", "follow")).to_lower()
		var model := _model_of(c, camera, n)
		if model.has("error"):
			out["error"] = model["error"]
			return out
		var still: bool = camera == "turntable" or not model.is_empty()   # a model preview: no rite, the Chapterhouse, 6 s and no enemies unless it says so
		var length: Variant = c.get("seconds", 6.0 if still else 5.0)
		var seconds := clampf(float(length), MIN_SECONDS, MAX_SECONDS) if (length is float or length is int) else 5.0
		var setup := DmQaScene.words(c.get("setup", []), "setup", "clip %d" % n, seconds)
		var steps := DmQaScene.words(c.get("steps", []), "steps", "clip %d" % n, seconds)
		for w: Dictionary in [setup, steps]:
			if w["error"] != "":
				out["error"] = w["error"]
				return out
		var cast_steps: bool = (steps["items"] as Array).any(func(st: Dictionary) -> bool: return st["do"] == "cast")
		var scene: bool = (setup["items"] as Array).any(func(w: Dictionary) -> bool: return w["do"] == "thralls") or (steps["items"] as Array).any(func(w: Dictionary) -> bool: return w["do"] != "cast")
		if cast == "" and not still and not cast_steps and not scene:
			out["error"] = "clip %d: \"cast\" is the id of the rite to cast (e.g. haunting_wraith), unless its steps cast or the clip is a scene (thralls, a walk, candles)" % n
			return out
		if cast != "" and not DmRiteRegistry.has(cast):
			out["error"] = "clip %d: unknown rite \"%s\" (a rite id of next/rites/dm_rite_registry.gd)" % [n, cast]
			return out
		var area := String(c.get("area", DmQaModel.AREA if not model.is_empty() else ("chapterhouse" if camera == "turntable" else "graves")))
		if DmContent.area(area).is_empty():
			out["error"] = "clip %d: unknown area \"%s\"" % [n, area]
			return out
		var at := String(c.get("at", "pack")).to_lower()
		if not ATS.has(at):
			out["error"] = "clip %d: \"at\" must be %s" % [n, " or ".join(ATS)]
			return out
		if not CAMERAS.has(camera):
			out["error"] = "clip %d: \"camera\" must be %s" % [n, " or ".join(CAMERAS)]
			return out
		for key in ["enemies", "seconds"]:
			if c.has(key) and not (c[key] is float or c[key] is int):
				out["error"] = "clip %d: \"%s\" must be a number" % [n, key]
				return out
		var enemies := clampi(int(c.get("enemies", 0 if still else 6)), 0, MAX_ENEMIES)
		if c.has("enemies") and enemies != int(c["enemies"]):
			(out["notes"] as Array).append("clip %d: %d enemies is outside 0-%d, made %d" % [n, int(c["enemies"]), MAX_ENEMIES, enemies])
		if c.has("seconds") and not is_equal_approx(seconds, float(c["seconds"])):
			(out["notes"] as Array).append("clip %d: %s seconds is outside %d-%d, made %d" % [n, DmQaTune.fmt(c["seconds"]), int(MIN_SECONDS), int(MAX_SECONDS), int(seconds)])
		var clip_worn: Array = out["equip"]
		if c.has("equip"):
			var own := _equip_list(c["equip"], "clip %d" % n, out["notes"])
			if own["error"] != "":
				out["error"] = own["error"]
				return out
			clip_worn = own["ids"]
			any_equip = true
		var opts := DmQaScene.setup_of(setup["items"])
		if not model.is_empty() and not c.has("area") and opts["stand_at"] == null:   # no place named: the model view's own spot
			opts["stand_at"] = DmQaModel.SPOT
		var nm := slug(String(c.get("name", "")), n)
		var base := nm
		var dup := 2
		while seen.has(nm):
			nm = "%s-%d" % [base.substr(0, MAX_NAME - 2), dup]
			dup += 1
		seen[nm] = true
		(out["clips"] as Array).append({"name": nm, "area": area, "cast": cast, "at": at, "enemies": enemies, "seconds": seconds, "camera": camera, "equip": clip_worn, "dress": false,
			"setup": opts, "steps": steps["items"], "model": model, "dirs": []})
		i += 1
	for clip: Dictionary in out["clips"]:
		clip["dress"] = any_equip
		clip["setup"]["legion"] = out["legion"]
	out["ok"] = true
	return out


## A clip's model view (DmQaModel: "model" / "model_file", "height", "anim", "turn" degrees, "move", "speed"), checked: {} for a clip without one, {error} when it is wrong, else DmQaModel.spec_of's
## fields with turn (default: side on for a "move", else DmQaUiShots.DEFAULT_TURN), move, speed (m/s: the plan's, else the row's stride for the clip; a "move" without either is refused) and
## still (the camera stays put: "camera": "still").
static func _model_of(c: Dictionary, camera: String, n: int) -> Dictionary:
	if not (c.has("model") or c.has("model_file")):
		for key in ["move", "speed", "height"]:
			if c.has(key):
				return {"error": "clip %d: \"%s\" is for a model clip (\"model\" or \"model_file\")" % [n, key]}
		if camera == "still":
			return {"error": "clip %d: \"camera\": \"still\" is for a model clip (\"model\" or \"model_file\")" % n}
		return {}
	var spec := DmQaModel.spec_of(c)
	if spec["error"] != "":
		return {"error": "clip %d: %s" % [n, spec["error"]]}
	spec.erase("error")
	if camera == "wide":
		return {"error": "clip %d: a model clip's \"camera\" is follow (one side), still (one side, the camera not moving) or turntable" % n}
	for key in ["turn", "speed"]:
		if c.has(key) and not (c[key] is float or c[key] is int):
			return {"error": "clip %d: \"%s\" must be a number" % [n, key]}
	var move: Variant = c.get("move", false)
	if not move is bool:
		return {"error": "clip %d: \"move\" is true or false" % n}
	spec["move"] = move
	spec["still"] = camera == "still"
	spec["turn"] = fmod(float(c.get("turn", 90.0 if move else DmQaUiShots.DEFAULT_TURN)), 360.0)
	spec["speed"] = 0.0
	if move:
		if spec["anim"] == "":
			spec["anim"] = "walk"
		spec["speed"] = DmQaModel.move_speed(spec, spec["anim"], c.get("speed"))
		if spec["speed"] <= 0.0:
			return {"error": "clip %d: \"move\" needs \"speed\" (m/s), or a model row with a stride for \"%s\"" % [n, spec["anim"]]}
	return spec


## An `equip` list: {ids (at most DmQaUiShots.MAX_EQUIP item ids a hero can wear), error}. `what` says whose list it is in the refusals and the note.
static func _equip_list(v: Variant, what: String, notes: Array) -> Dictionary:
	var out := {"ids": [], "error": ""}
	if not (v is Array):
		out["error"] = "%s: \"equip\" must be a list of item ids" % what
		return out
	for id in v:
		var def := DmLootData.item(String(id))
		if def.is_empty():
			out["error"] = "%s: equip: unknown item \"%s\"" % [what, id]
			return out
		if DmGear.equip_slot_of({"item_type": def.get("type", ""), "item_equipment_slot": def.get("equipment_slot")}) == "":
			out["error"] = "%s: equip: \"%s\" cannot be worn (%s)" % [what, id, def.get("type", "?")]
			return out
		if (out["ids"] as Array).size() >= DmQaUiShots.MAX_EQUIP:
			notes.append("%s has more than %d items to wear, only the first %d are" % [what, DmQaUiShots.MAX_EQUIP, DmQaUiShots.MAX_EQUIP])
			break
		(out["ids"] as Array).append(String(id))
	return out


## A clip's file name: lower case letters, digits and hyphens, at most MAX_NAME long, starting with a letter or digit ("clip-<n>" when nothing is left).
static func slug(name: String, n: int) -> String:
	var s := RegEx.create_from_string("[^a-z0-9-]+").sub(name.to_lower(), "-", true).substr(0, MAX_NAME)
	while s.begins_with("-"):
		s = s.substr(1)
	while s.ends_with("-"):
		s = s.left(s.length() - 1)
	return s if s != "" else "clip-%d" % n


## "" when the game is the class the plan wants (or the plan names none), else why not: a clip of another class's hero would show the wrong hero, so the run does not start.
static func class_refusal(plan: Dictionary, have: int) -> String:
	var want := int(plan["class_index"])
	if want == 0 or want == have:
		return ""
	return "the game runs class %d, the plan wants %s (%d): start it with --class=%d" % [have, plan["discipline"], want, want]


## Runs the plan on a live game, then quits the tree: exit code 0 = every clip written, 1 = one was not (a run with no renderer, a rite that was refused), 2 = a plan or a class the run cannot use.
## `root` is any node in the tree (the QA driver); `source` returns the picture to store (default the viewport's), null = nothing is drawn.
## `fps` and `width`: the recording's frames per game second and widest picture (`options`).
static func run(root: Node, game: DmNextGame, plan_path: String, out_dir: String, source := Callable(), fps := FPS, width := DmQaMjpeg.WIDTH) -> void:
	var tree := root.get_tree()
	var plan := parse(FileAccess.get_file_as_string(plan_path))
	if not plan["ok"] or out_dir == "":
		print("QA-CLIPS plan error: ", plan["error"] if not plan["ok"] else "--clips=<abs dir> says where the clips are written")
		tree.quit(2)
		return
	for note in plan["notes"]:
		print("QA-CLIPS note: ", note)
	var wrong := class_refusal(plan, int(game.character.get("class_index", 0)))
	if wrong != "":
		print("QA-CLIPS discipline: ", wrong)
		tree.quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	for clip in plan["clips"]:   # where a model clip's "model_file" may be: beside the game (a team job's files) or the plan
		clip["dirs"] = [OS.get_executable_path().get_base_dir(), plan_path.get_base_dir()]
	if not source.is_valid() and DisplayServer.get_name() == "headless":
		for clip in plan["clips"]:
			print("QA-CLIPS clip FAILED %s/%s.mjpeg: no picture, this run draws nothing (headless: start it with a renderer)" % [out_dir, clip["name"]])
		tree.quit(1)
		return
	await tree.create_timer(1.0).timeout   # the loading screen's fade-out
	var bad := 0
	var noted := false
	for clip in plan["clips"]:
		var t0 := Time.get_ticks_msec()
		var r: Dictionary = await record(root, game, clip, out_dir, source, fps, width)
		if not noted and r.has("step") and absf(float(r["step"]) - 1.0 / fps) > 0.0005:
			noted = true
			print("QA-CLIPS note: the frame step is %.4f s, not 1/%d: the clips keep %d frames per game second all the same (start the engine with --fixed-fps %d for one picture per frame)" % [float(r["step"]), fps, fps, fps])
		if r["ok"]:
			print("QA-CLIPS clip %s/%s.mjpeg %d frames %dx%d, cast at frame %s, %dms" % [out_dir, clip["name"], r["frames"], r["width"], r["height"], str(r["casts"]), Time.get_ticks_msec() - t0])
		else:
			bad += 1
			print("QA-CLIPS clip FAILED %s/%s.mjpeg: %s" % [out_dir, clip["name"], r["why"]])
	tree.quit(1 if bad > 0 else 0)


## One clip: stages the scene, records it, writes `<out_dir>/<name>.mjpeg` and `.json`; the files of a clip that failed are removed. Returns {ok, why, frames, width, height, casts (the frames the rite was cast at; none for a clip with no `cast`, which has `cast_at_frame` -1), step (a frame's game time)}.
static func record(root: Node, game: DmNextGame, clip: Dictionary, out_dir: String, source := Callable(), fps := FPS, width := DmQaMjpeg.WIDTH) -> Dictionary:
	var tree := root.get_tree()
	var rite: String = clip["cast"]   # "" = no cast (a turntable preview)
	var res := {"ok": false, "why": "", "frames": 0, "width": 0, "height": 0, "casts": []}
	var body := game.local_body()
	var caster := body.get_node_or_null("Rites") as DmRiteCaster if body != null else null
	if caster == null:
		res["why"] = "the hero has no rite caster"
		return res
	if clip["dress"]:
		await dress(game, clip["equip"])
	var opts: Dictionary = clip.get("setup", DmQaScene.setup_of([]))
	await legion(game, opts["legion"])
	var staged: Dictionary = await stage(root, game, clip)
	var steps: Array = clip.get("steps", [])
	var scene := DmQaScene.new(game, caster, opts, staged["aim"], steps, DmQaScene.rites_of(clip["cast"], steps), "clip")
	if String(staged["saved"].get("error", "")) != "":
		_clean_up(game, scene, staged)
		res["why"] = "the model could not be made (%s)" % staged["saved"]["error"]
		return res
	var timed: bool = steps.any(func(st: Dictionary) -> bool: return st["do"] == "cast")   # cast steps say when; nothing is cast by itself then
	if float(opts["souls"]) >= 0.0:
		DmQaScene.set_souls(caster, float(opts["souls"]))
	var turntable: bool = clip["camera"] == "turntable"
	var model: Dictionary = clip.get("model", {})
	var holder: Node3D = staged["saved"].get("model")
	var ap: AnimationPlayer = staged["saved"].get("ap")
	var anim := DmQaModel.clip_of(staged["saved"], String(model["anim"]), "QA-CLIPS") if holder != null else ""
	var path_from := Vector3.ZERO
	var heading := Vector3.ZERO
	if holder != null:
		if anim != "":
			ap.play(anim, 0.0)
		heading = Vector3(sin(deg_to_rad(float(model["turn"]))), 0.0, cos(deg_to_rad(float(model["turn"]))))
		path_from = holder.position - heading * float(model["speed"]) * float(clip["seconds"]) * 0.5   # a "move" crosses where it stood half-way through
	var base := "%s/%s" % [out_dir, clip["name"]]
	_remove(base + ".json")   # a clip's json is there only with the clip it describes
	var writer := DmQaMjpeg.new()
	writer.max_width = width
	var lead := int(roundf(float(LEAD_FRAMES) * float(fps) / float(FPS)))
	if not writer.open(base + ".mjpeg"):
		res["why"] = "cannot write %s.mjpeg" % base
		_clean_up(game, scene, staged)
		return res
	scene.casts = res["casts"]
	var total := int(roundf(float(clip["seconds"]) * fps))
	var guard := total * 20 + 600   # iterations: a game whose time does not advance ends the clip instead of hanging
	var elapsed := 0.0
	var casts: Array = res["casts"]
	var failed := ""
	while writer.frames < total and failed == "":
		guard -= 1
		if guard < 0:
			failed = "the game's time did not advance"
			break
		if holder != null:
			_model_step(game, holder, ap, anim, model, path_from + heading * float(model["speed"]) * elapsed, float(writer.frames) / float(total) if turntable else -1.0)
		elif turntable:
			_spin(body, float(writer.frames) / float(total))
		if rite != "" and not timed and ((casts.is_empty() and writer.frames >= lead) or (not casts.is_empty() and float(DmAbilities.def(rite)["cooldownMs"]) > 0.0 and caster.cooldown_left(rite) <= 0.0)):
			var why := scene.request(rite)
			if why == "":
				casts.append(writer.frames)
			elif why != "busy" and why != "cooldown":   # those two are tried again next frame
				failed = "the rite was refused (%s)" % why
				break
		scene.tick(float(writer.frames) / fps, writer.frames)   # the steps due, a walk going on: a cast step waits while the rite is busy or cooling down, any other refusal fails the clip
		if scene.failed != "":
			failed = scene.failed
			break
		await tree.process_frame
		var dt := root.get_process_delta_time()
		res["step"] = dt
		elapsed += dt
		var due := mini(total, int(floor(elapsed * fps + 1e-6))) - writer.frames
		if due > 0:
			var img: Image = source.call() if source.is_valid() else DmQaUiShots.grab(root)
			if not writer.add(img, due):
				failed = "no picture to store (the renderer drew nothing)"
	writer.close()
	_clean_up(game, scene, staged)
	if failed == "":
		failed = scene.problem()
	if failed == "" and rite != "" and not timed and casts.is_empty():
		failed = "the rite was never cast"
	if failed != "":
		_remove(base + ".mjpeg")
		res["why"] = failed
		return res
	var meta := FileAccess.open(base + ".json", FileAccess.WRITE)
	if meta == null:
		_remove(base + ".mjpeg")
		res["why"] = "cannot write %s.json" % base
		return res
	meta.store_string(JSON.stringify({"fps": fps, "frames": writer.frames, "width": writer.width, "height": writer.height, "cast_at_frame": casts[0] if not casts.is_empty() else -1}))
	meta.close()
	res["ok"] = true
	res["frames"] = writer.frames
	res["width"] = writer.width
	res["height"] = writer.height
	return res


## The scene of one clip: the HUD away, no waves, the hero at the area's waystone facing DmQaScene.FACING with the camera set, the stand-ins made and risen, the scene stood still for SETTLE_S, the caster fresh.
## Returns {aim, ids (the stand-ins' core ids), saved (what the turntable's view changed, for `_view_end`; empty for the other cameras), undo (what takes the thralls and their stand-in owners away, Callables)}.
static func stage(root: Node, game: DmNextGame, clip: Dictionary) -> Dictionary:
	var tree := root.get_tree()
	var core: DmCoreHost = game.core_host
	var body := game.local_body()
	var opts: Dictionary = clip.get("setup", DmQaScene.setup_of([]))
	if game.ui != null:
		game.ui.close_panels()
		DmQaScene.show_hud(game, bool(opts["hud"]), false)
	DmQaScene.quiet(game)   # no waves and no Grave Surge: the stand-ins are the only enemies
	game.director.surge = null
	core.core.set_wander(false)
	DmQaUiShots.go_area(game, clip["area"])
	var give_up := 240
	while game.area_id != clip["area"] and give_up > 0:
		await tree.process_frame
		give_up -= 1
	for _i in 3:
		await tree.process_frame
	if opts["stand_at"] != null:   # the setup's `stand_at`: the hero stands there, not at the waystone
		DmQaScene.stand_at(game, opts["stand_at"])
		for _i in 2:
			await tree.process_frame
	var zoom := float(game.camera.cfg["zoomMax"]) if clip["camera"] == "wide" else (float(opts["zoom"]) if float(opts["zoom"]) > 0.0 else 1.0)   # the setup's `zoom` (0 = none)
	DmQaScene.set_zoom(game, zoom, zoom)
	body.heal(1e6)
	var origin := body.position
	DmQaScene.face_up(body)
	game.camera.snap(origin)
	var caster := body.get_node_or_null("Rites") as DmRiteCaster
	if caster != null:   # a clip after another one starts as the first did: no cooldown, no cast lock, nothing of the last rite still walking
		DmQaScene.fresh_caster(caster, DmQaScene.rites_of(String(clip["cast"]), clip.get("steps", [])))
	var count := int(opts["count"]) if int(opts["count"]) >= 0 else int(clip["enemies"])   # the setup's `stand_ins` count, else the clip's "enemies"
	var spots := DmQaScene.layout(clip["at"], count, origin, float(opts["distance"]))
	var ids := DmQaScene.stand_ins(game, spots, opts)
	var undo: Array[Callable] = []
	var thralls: Dictionary = opts["thralls"]
	if not thralls.is_empty():   # the setup's `thralls`: raised for the hero and the stand-in owners, after the stand-ins so they are not cleared, to fight them
		undo.append_array(DmQaScene.raise_thralls(game, thralls, DmQaScene.THRALL_DAMAGE, false))
	var saved := {}
	if not (clip.get("model", {}) as Dictionary).is_empty():   # the model alone where the hero stands, the hero hidden (DmQaModel); the record loop turns, moves and plays it
		saved = DmQaModel.begin(game, clip["model"], float(clip["model"]["turn"]), clip.get("dirs", []), "QA-CLIPS")
		var m: Dictionary = clip["model"]
		var back := float(opts["zoom"])
		if saved.has("size") and ((bool(m["still"]) and bool(m["move"])) or back > 0.0):
			var size: Vector3 = saved["size"]
			var view := size
			if bool(m["still"]) and bool(m["move"]):   # the camera stays put, drawn back to frame the walk with a body length to spare at each end
				view.x = float(m["speed"]) * float(clip["seconds"]) + 2.0 * maxf(size.x, size.z)
			DmQaScene.frame_model(game, saved, view, back)   # the setup's `zoom` draws the framing back (or in)
	elif clip["camera"] == "turntable":   # the hero's close-up from the front, the HUD away (the shot plan's "hero" view); the record loop turns the hero
		saved = DmQaUiShots._view_begin(game, {"view": "hero", "turn": 0.0})
	await DmQaScene.settle(root, core, ids, DmQaScene.still_for(thralls))
	return {"aim": DmQaScene.aim_at(spots, origin), "ids": ids, "saved": saved, "undo": undo}


## The plan's Legion kit on the hero, once: given to the Legion like the shot plan's `legion` (DmQaUiShots.prepare), unless those pieces are on it already (a clip after another one).
static func legion(game: DmNextGame, ids: Array) -> void:
	if ids.is_empty():
		return
	await game.ui_host.refresh_inventory()
	var worn := DmLegion.kit_pieces(game.ui_host.inventory.slots)
	var have := worn.values().map(func(row: Dictionary) -> String: return String(row.get("item_id", "")))
	if ids.all(func(id: String) -> bool: return have.has(id)):
		return
	await DmQaUiShots.prepare(game, {"bag": "keep", "give": [], "equip": [], "legion": ids, "class_index": 0})


## What the hero wears for a clip: exactly the items of `wanted`. A piece worn that is not in the list is taken off (the backend's equip call, back to the bag), the ones missing are put on like the shot plan's `equip`
## (DmQaUiShots.prepare: into the bag with a real roll, then worn; the hero's look follows).
static func dress(game: DmNextGame, wanted: Array) -> void:
	var host := game.ui_host
	await host.refresh_inventory()
	var kept := {}
	var worn := DmGear.equipped_by_slot(host.inventory.slots)
	for slot in worn:
		var row: Dictionary = worn[slot]
		var id := String(row["item_id"])
		if wanted.has(id) and not kept.has(id):
			kept[id] = true
			continue
		var res: DmResult = await host.api.equip_item(host.hero_id, int(row["slot_index"]), 0)
		if not res.ok:
			print("QA-CLIPS equip: %s could not be taken off: %s" % [id, res.error])
	await host.refresh_inventory()
	var missing := wanted.filter(func(id: String) -> bool: return not kept.has(id))
	if not missing.is_empty():
		await DmQaUiShots.prepare(game, {"bag": "keep", "give": [], "equip": missing, "class_index": 0})
	elif worn.size() != kept.size():
		for _i in 4:   # the avatar's look follows the bag a few frames after a change
			await game.get_tree().process_frame


## One frame of a model clip: the clip played on (a clip that does not loop starts again), the model at `at` with the hidden hero under it so the camera follows a "move" (not a still one), and turned `spin`
## of the way round from its "turn" on a turntable (-1 = not turning).
static func _model_step(game: DmNextGame, holder: Node3D, ap: AnimationPlayer, anim: String, model: Dictionary, at: Vector3, spin: float) -> void:
	if ap != null and anim != "" and not ap.is_playing():
		ap.play(anim, 0.0)
	if spin >= 0.0:
		holder.rotation.y = deg_to_rad(float(model["turn"])) + TAU * spin
	if bool(model["move"]):
		holder.position = Vector3(at.x, 0.0, at.z)
		if not bool(model["still"]):
			game.local_body().teleport(holder.position)


## The turntable: the hero turned `t` of the way round (0 = facing the camera), the avatar with it.
static func _spin(body: DmHeroBody, t: float) -> void:
	body.yaw = TAU * t
	if body.avatar != null:
		body.avatar.c.root.rotation.y = body.yaw


static func _remove(file: String) -> void:
	if FileAccess.file_exists(file):
		DirAccess.remove_absolute(file)


## After a clip: the stand-ins still standing sent away without a death, the thralls gone, the scene's steps ended (a walk stopped, candles lit, what the rites left behind forgotten).
static func _clean_up(game: DmNextGame, scene: DmQaScene, staged: Dictionary) -> void:
	DmQaScene.remove_stand_ins(game, staged["ids"])
	for undo: Callable in staged.get("undo", []):
		undo.call()
	scene.close()
	if (staged["saved"] as Dictionary).has("model"):
		DmQaModel.end(game, staged["saved"])
	elif not (staged["saved"] as Dictionary).is_empty() and not (staged["saved"] as Dictionary).has("error"):
		DmQaUiShots._view_end(game, staged["saved"])
