class_name DmQaClips
extends RefCounted
## Clip plan for the QA driver (`-- --dev-offline --class=11 --qa --clip-plan=/abs/plan.json --clips=/abs/dir`, with the engine started `--fixed-fps 30`): short videos of a rite in use. Loaded by main/qa_driver.gd
## only when `--clip-plan=` is given, so normal play never touches it (and `DmMain.qa_wanted` lets it start on the dev-offline backend of a debug build only). client/README.md "Clips and tune".
## For each clip the run enters the area, makes the stand-in enemies, lets the scene settle, then records the viewport at 30 frames per game second into `<dir>/<name>.mjpeg` (main/qa_mjpeg.gd)
## and writes `<dir>/<name>.json` = {fps, frames, width, height, cast_at_frame}. Variants of a clip are runs of their own with another `--tune=` (main/qa_tune.gd).
##
## Plan: {"discipline": "reaper" (or 1-4 / 11; the game must have been started as that class: `--class=N`),
##        "equip": ["<item id>", ...] (at most DmQaUiShots.MAX_EQUIP, worn by the hero for every clip, through the backend's equip call like the shot plan's: the model previews),
##        "clips": [{"name": "wraith", "area": "graves", "cast": "<rite id, e.g. haunting_wraith>", "at": "pack" | "ahead", "enemies": 6, "seconds": 5, "camera": "follow" | "wide" | "turntable",
##                   "equip": ["<item id>", ...] (this clip's own list: it wins over the plan's; the pieces worn before that are not in it are taken off),
##                   "setup": [{"do": "<word>", <its arguments>}, ...] (how the scene is set before recording), "steps": [{"at": <seconds>, "do": "<word>", ...}, ...] (what happens when)}]}
## `setup` and `steps` use the words of STEPS_FILE (main/qa_clip_steps.json: each word, its arguments and their types), e.g. setup [{"do": "hud", "show": true}, {"do": "stand_ins", "health": 1,
## "harmless": false}, {"do": "souls", "value": 0}, {"do": "top_up", "on": false}] and steps [{"at": 0.3, "do": "cast", "rite": "reap"}, {"at": 2, "do": "cast", "rite": "haunting_wraith"}]: mortal
## stand-ins, the HUD on screen, an empty soul bag that fills from the kills, two casts at set times. The runner checks a request against the branch's copy of that file; a new word is an
## entry there, its handler here (SETUP_WORDS / STEP_WORDS) and a check in tests/qa_shots.gd.
## At most MAX_CLIPS clips (the rest are left out, with a note), `seconds` MIN_SECONDS to MAX_SECONDS and `enemies` 0 to MAX_ENEMIES (clamped, with a note). Defaults: area graves, at pack, 6 enemies, 5 s, follow.
## "at": "pack" = the enemies bunched PACK_AHEAD m in front of the hero (the rite is aimed at the middle of them: a burst, a cloud, a thrown thing); "ahead" = the enemies in a line down the way the
## hero faces, from LINE_FIRST m away, LINE_STEP m apart (the rite is aimed down the line: a thing that travels). "camera": "follow" = the game's own camera; "wide" = its widest zoom;
## "turntable" = the hero's close-up (the shot plan's "hero" view) while the hero turns once round slowly, standing idle in place at the area's waystone, over the clip (a model preview: "cast" is not needed, "area" is the Chapterhouse
## unless it says another, "seconds" 6 unless it says another, and no enemies unless asked for).
## Unless the setup says otherwise, the stand-ins are the Graves' robbers with a lot of health and no damage that stand where they are put (a tune that changes the rite's damage cannot kill them or
## hurt the hero), and the HUD is hidden. Without cast steps the rite of `cast` is cast LEAD_FRAMES frames in (so the first frames show the scene before it) and again each time it is off cooldown;
## the hero's souls and essence are topped up for each cast unless the setup turns that off.

const FPS := 30                 ## frames per game second
const MAX_CLIPS := 4
const MIN_SECONDS := 1.0
const MAX_SECONDS := 8.0
const MAX_ENEMIES := 12
const MAX_NAME := 32            ## characters (the team app puts the variant's label before it in a file name)
const ATS := ["pack", "ahead"]
const CAMERAS := ["follow", "wide", "turntable"]
const LEAD_FRAMES := 6          ## the scene is recorded this long before the first cast
const SETTLE_S := 1.5           ## game seconds the scene stands still after the stand-ins have risen
const SETTLE_MAX_S := 20.0      ## and the longest wait for them to rise
const DUMMY := "robber"
const DUMMY_HP := 400.0         ## health multiplier of the stand-ins
const PACK_AHEAD := 8.0         ## m from the hero to the middle of a pack
const LINE_FIRST := 4.0         ## m from the hero to the first enemy of a line
const LINE_STEP := 2.5          ## m between the enemies of a line
const FACING := Vector3(0.0, 0.0, -1.0)   ## the way the hero faces and casts: up the screen of the game's fixed camera
const STEPS_FILE := "res://main/qa_clip_steps.json"   ## the words `setup` and `steps` may use, and their arguments
const MAX_SETUP := 12
const MAX_STEPS := 24
const SETUP_WORDS := ["hud", "stand_ins", "souls", "top_up"]   ## the setup words this recorder carries out (stage, record); STEPS_FILE lists the same
const STEP_WORDS := ["cast"]                                   ## the step words it carries out (record's loop)


## Parses and validates plan text. Returns {ok, error, discipline (name or ""), class_index (0 = not set), equip (the plan's), clips, notes}; each clip is {name, area, cast, at, enemies, seconds, camera, equip (what it wears:
## its own list, else the plan's), dress (the plan names items somewhere: the run sets what is worn for every clip)}.
static func parse(text: String) -> Dictionary:
	var out := {"ok": false, "error": "", "discipline": "", "class_index": 0, "equip": [], "clips": [], "notes": []}
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
		var length: Variant = c.get("seconds", 6.0 if camera == "turntable" else 5.0)
		var seconds := clampf(float(length), MIN_SECONDS, MAX_SECONDS) if (length is float or length is int) else 5.0
		var setup := _words(c.get("setup", []), "setup", n, seconds)
		var steps := _words(c.get("steps", []), "steps", n, seconds)
		for w: Dictionary in [setup, steps]:
			if w["error"] != "":
				out["error"] = w["error"]
				return out
		var cast_steps: bool = (steps["items"] as Array).any(func(st: Dictionary) -> bool: return st["do"] == "cast")
		if cast == "" and camera != "turntable" and not cast_steps:
			out["error"] = "clip %d: \"cast\" is the id of the rite to cast (e.g. haunting_wraith), unless its steps cast" % n
			return out
		if cast != "" and not DmRiteRegistry.has(cast):
			out["error"] = "clip %d: unknown rite \"%s\" (a rite id of next/rites/dm_rite_registry.gd)" % [n, cast]
			return out
		var area := String(c.get("area", "chapterhouse" if camera == "turntable" else "graves"))
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
		var enemies := clampi(int(c.get("enemies", 0 if camera == "turntable" else 6)), 0, MAX_ENEMIES)
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
		var nm := slug(String(c.get("name", "")), n)
		var base := nm
		var dup := 2
		while seen.has(nm):
			nm = "%s-%d" % [base.substr(0, MAX_NAME - 2), dup]
			dup += 1
		seen[nm] = true
		(out["clips"] as Array).append({"name": nm, "area": area, "cast": cast, "at": at, "enemies": enemies, "seconds": seconds, "camera": camera, "equip": clip_worn, "dress": false,
			"setup": _setup_of(setup["items"]), "steps": steps["items"]})
		i += 1
	for clip: Dictionary in out["clips"]:
		clip["dress"] = any_equip
	out["ok"] = true
	return out


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


## The words `setup` and `steps` may use (STEPS_FILE): {"setup": {word: {"help", "args": {name: {type, min, max, required}}}}, "steps": {...}}; {} when the file is missing.
static func vocabulary() -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(STEPS_FILE)) if FileAccess.file_exists(STEPS_FILE) else null
	return v if v is Dictionary else {}


## A clip's `setup` or `steps` list checked against the vocabulary: {items (each {"do", "at" (steps only), <its arguments>}; steps sorted by `at`), error}.
static func _words(v: Variant, section: String, n: int, seconds: float) -> Dictionary:
	var out := {"items": [], "error": ""}
	var words: Dictionary = vocabulary().get(section, {})
	if not (v is Array):
		out["error"] = "clip %d: \"%s\" must be a list of {\"do\": ...} objects" % [n, section]
		return out
	var cap := MAX_SETUP if section == "setup" else MAX_STEPS
	if (v as Array).size() > cap:
		out["error"] = "clip %d: \"%s\" has %d entries (at most %d)" % [n, section, (v as Array).size(), cap]
		return out
	var k := 0
	for e in v:
		k += 1
		var w := "clip %d %s %d" % [n, section, k]
		if not (e is Dictionary):
			out["error"] = "%s is not an object" % w
			return out
		var word := String(e.get("do", ""))
		if not words.has(word):
			out["error"] = "%s: \"do\" must be one of %s (main/qa_clip_steps.json)" % [w, ", ".join(words.keys())]
			return out
		var args: Dictionary = words[word].get("args", {})
		var item := {"do": word}
		if section == "steps":
			var at: Variant = e.get("at")
			if not (at is float or at is int) or float(at) < 0.0 or float(at) > seconds:
				out["error"] = "%s (%s): \"at\" must be a number of seconds from 0 to the clip's %s" % [w, word, DmQaTune.fmt(seconds)]
				return out
			item["at"] = float(at)
		for key in e:
			if key == "do" or (key == "at" and section == "steps"):
				continue
			if not args.has(key):
				out["error"] = "%s (%s) has an unknown argument \"%s\" (it takes: %s)" % [w, word, key, ", ".join(args.keys())]
				return out
			var why := _arg_refusal(e[key], args[key])
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
static func _arg_refusal(value: Variant, spec: Dictionary) -> String:
	match String(spec.get("type", "")):
		"bool":
			return "" if value is bool else "must be true or false"
		"number":
			if not (value is float or value is int):
				return "must be a number"
			if (spec.has("min") and float(value) < float(spec["min"])) or (spec.has("max") and float(value) > float(spec["max"])):
				return "must be from %s to %s" % [DmQaTune.fmt(spec.get("min", 0)), DmQaTune.fmt(spec.get("max", 0))]
			return ""
		"rite":
			return "" if value is String and DmRiteRegistry.has(value) else "must be a rite id of next/rites/dm_rite_registry.gd"
		"enemy":
			return "" if value is String and not DmContent.enemy(value).is_empty() else "must be an enemy id of data/content/enemies.json"
	return "has a type this recorder does not know (%s)" % str(spec.get("type", ""))


## A clip's setup as the recorder reads it: every option with its default (the stand-ins as before, the HUD hidden, the souls as they are, topped up for each cast).
static func _setup_of(items: Array) -> Dictionary:
	var o := {"hud": false, "kind": DUMMY, "health": DUMMY_HP, "harmless": true, "souls": -1.0, "top_up": true}
	for it: Dictionary in items:
		match String(it["do"]):
			"hud":
				o["hud"] = bool(it["show"])
			"stand_ins":
				o["kind"] = String(it.get("kind", o["kind"]))
				o["health"] = float(it.get("health", o["health"]))
				o["harmless"] = bool(it.get("harmless", o["harmless"]))
			"souls":
				o["souls"] = float(it["value"])
			"top_up":
				o["top_up"] = bool(it["on"])
	return o


## A clip's file name: lower case letters, digits and hyphens, at most MAX_NAME long, starting with a letter or digit ("clip-<n>" when nothing is left).
static func slug(name: String, n: int) -> String:
	var s := RegEx.create_from_string("[^a-z0-9-]+").sub(name.to_lower(), "-", true).substr(0, MAX_NAME)
	while s.begins_with("-"):
		s = s.substr(1)
	while s.ends_with("-"):
		s = s.left(s.length() - 1)
	return s if s != "" else "clip-%d" % n


## Where the stand-ins stand for a hero at `origin` facing FACING: "pack" = a hexagonal bunch round the point PACK_AHEAD m ahead (1.5 m rings), "ahead" = a line down the facing, alternately 0.5 m to either side.
static func layout(at: String, n: int, origin: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if at == "ahead":
		for i in n:
			out.append(origin + FACING * (LINE_FIRST + LINE_STEP * i) + Vector3(0.5 if i % 2 == 0 else -0.5, 0.0, 0.0))
		return out
	var middle := origin + FACING * PACK_AHEAD
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


## "" when the game is the class the plan wants (or the plan names none), else why not: a clip of another class's hero would show the wrong hero, so the run does not start.
static func class_refusal(plan: Dictionary, have: int) -> String:
	var want := int(plan["class_index"])
	if want == 0 or want == have:
		return ""
	return "the game runs class %d, the plan wants %s (%d): start it with --class=%d" % [have, plan["discipline"], want, want]


## Runs the plan on a live game, then quits the tree: exit code 0 = every clip written, 1 = one was not (a run with no renderer, a rite that was refused), 2 = a plan or a class the run cannot use.
## `root` is any node in the tree (the QA driver); `source` returns the picture to store (default the viewport's), null = nothing is drawn.
static func run(root: Node, game: DmNextGame, plan_path: String, out_dir: String, source := Callable()) -> void:
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
		var r: Dictionary = await record(root, game, clip, out_dir, source)
		if not noted and r.has("step") and absf(float(r["step"]) - 1.0 / FPS) > 0.0005:
			noted = true
			print("QA-CLIPS note: the frame step is %.4f s, not 1/%d: the clips keep %d frames per game second all the same (start the engine with --fixed-fps %d for one picture per frame)" % [float(r["step"]), FPS, FPS, FPS])
		if r["ok"]:
			print("QA-CLIPS clip %s/%s.mjpeg %d frames %dx%d, cast at frame %s, %dms" % [out_dir, clip["name"], r["frames"], r["width"], r["height"], str(r["casts"]), Time.get_ticks_msec() - t0])
		else:
			bad += 1
			print("QA-CLIPS clip FAILED %s/%s.mjpeg: %s" % [out_dir, clip["name"], r["why"]])
	tree.quit(1 if bad > 0 else 0)


## One clip: stages the scene, records it, writes `<out_dir>/<name>.mjpeg` and `.json`; the files of a clip that failed are removed. Returns {ok, why, frames, width, height, casts (the frames the rite was cast at; none for a clip with no `cast`, which has `cast_at_frame` -1), step (a frame's game time)}.
static func record(root: Node, game: DmNextGame, clip: Dictionary, out_dir: String, source := Callable()) -> Dictionary:
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
	var staged: Dictionary = await stage(root, game, clip)
	var opts: Dictionary = clip.get("setup", _setup_of([]))
	var steps: Array = clip.get("steps", [])
	var timed: bool = steps.any(func(st: Dictionary) -> bool: return st["do"] == "cast")   # cast steps say when; nothing is cast by itself then
	if float(opts["souls"]) >= 0.0 and caster.p.has("soulsMax"):
		caster.p["souls"] = clampf(float(opts["souls"]), 0.0, float(caster.p["soulsMax"]))
	var turntable: bool = clip["camera"] == "turntable"
	var base := "%s/%s" % [out_dir, clip["name"]]
	_remove(base + ".json")   # a clip's json is there only with the clip it describes
	var writer := DmQaMjpeg.new()
	if not writer.open(base + ".mjpeg"):
		res["why"] = "cannot write %s.mjpeg" % base
		_clean_up(game, caster, _rites(rite, steps), staged)
		return res
	var last := [""]   # why the host refused the last request ("" = it took it)
	var on_refused := func(_id: String, why: String) -> void:
		last[0] = why
	caster.cast_rejected.connect(on_refused)
	var total := int(roundf(float(clip["seconds"]) * FPS))
	var guard := total * 20 + 600   # iterations: a game whose time does not advance ends the clip instead of hanging
	var elapsed := 0.0
	var casts: Array = res["casts"]
	var failed := ""
	var next_step := 0
	while writer.frames < total and failed == "":
		guard -= 1
		if guard < 0:
			failed = "the game's time did not advance"
			break
		if turntable:
			_spin(body, float(writer.frames) / float(total))
		if rite != "" and not timed and ((casts.is_empty() and writer.frames >= LEAD_FRAMES) or (not casts.is_empty() and caster.cooldown_left(rite) <= 0.0)):
			if bool(opts["top_up"]):
				_top_up(caster)
			last[0] = ""
			caster.request_cast(rite, staged["aim"], -1)
			if last[0] == "":
				casts.append(writer.frames)
			elif last[0] != "busy" and last[0] != "cooldown":   # those two are tried again next frame
				failed = "the rite was refused (%s)" % last[0]
				break
		while next_step < steps.size() and float(writer.frames) / FPS >= float(steps[next_step]["at"]):
			var st: Dictionary = steps[next_step]
			# "cast", the one step word (STEP_WORDS): the step waits while the rite is busy or cooling down, any other refusal fails the clip
			if bool(opts["top_up"]):
				_top_up(caster)
			last[0] = ""
			caster.request_cast(String(st["rite"]), staged["aim"], -1)
			if last[0] == "busy" or last[0] == "cooldown":
				break
			if last[0] != "":
				failed = "step %d (cast %s at %s s) was refused (%s)" % [next_step + 1, st["rite"], DmQaTune.fmt(st["at"]), last[0]]
				break
			casts.append(writer.frames)
			next_step += 1
		if failed != "":
			break
		await tree.process_frame
		var dt := root.get_process_delta_time()
		res["step"] = dt
		elapsed += dt
		var due := mini(total, int(floor(elapsed * FPS + 1e-6))) - writer.frames
		if due > 0:
			var img: Image = source.call() if source.is_valid() else DmQaUiShots.grab(root)
			if not writer.add(img, due):
				failed = "no picture to store (the renderer drew nothing)"
	writer.close()
	caster.cast_rejected.disconnect(on_refused)
	_clean_up(game, caster, _rites(rite, steps), staged)
	if failed == "" and next_step < steps.size():
		failed = "step %d (cast %s at %s s) never went off before the clip ended (%s)" % [next_step + 1, steps[next_step]["rite"], DmQaTune.fmt(steps[next_step]["at"]), last[0] if last[0] != "" else "no time left"]
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
	meta.store_string(JSON.stringify({"fps": FPS, "frames": writer.frames, "width": writer.width, "height": writer.height, "cast_at_frame": casts[0] if not casts.is_empty() else -1}))
	meta.close()
	res["ok"] = true
	res["frames"] = writer.frames
	res["width"] = writer.width
	res["height"] = writer.height
	return res


## The scene of one clip: the HUD away, no waves, the hero at the area's waystone facing FACING with the camera set, the stand-ins made and risen, the scene stood still for SETTLE_S, the caster fresh.
## Returns {aim, ids (the stand-ins' core ids), saved (what the turntable's view changed, for `_view_end`; empty for the other cameras)}.
static func stage(root: Node, game: DmNextGame, clip: Dictionary) -> Dictionary:
	var tree := root.get_tree()
	var core: DmCoreHost = game.core_host
	var body := game.local_body()
	var opts: Dictionary = clip.get("setup", _setup_of([]))
	if game.ui != null:
		game.ui.close_panels()
		game.ui.visible = bool(opts["hud"])
	game.director.enabled = false   # no waves and no Grave Surge: the stand-ins are the only enemies
	game.director.surge = null
	core.core.set_wander(false)
	for id in core.enemies_in_radius(body.position, 400.0):
		core.remove_enemy(id)
	DmQaUiShots.go_area(game, clip["area"])
	var give_up := 240
	while game.area_id != clip["area"] and give_up > 0:
		await tree.process_frame
		give_up -= 1
	for _i in 3:
		await tree.process_frame
	var zoom := float(game.camera.cfg["zoomMax"]) if clip["camera"] == "wide" else 1.0
	game.camera.zoom = zoom
	game.camera.target_zoom = zoom
	body.heal(1e6)
	var origin := body.position
	body.set_facing(atan2(FACING.x, FACING.z))
	game.camera.snap(origin)
	var caster := body.get_node_or_null("Rites") as DmRiteCaster
	if caster != null:   # a clip after another one starts as the first did: no cooldown, no cast lock, nothing of the last rite still walking
		caster.p["cooldowns"].clear()
		caster.p["castUntil"] = 0.0
		for r in _rites(String(clip["cast"]), clip.get("steps", [])):
			caster.mem(r).clear()
	var spots := layout(clip["at"], int(clip["enemies"]), origin)
	var ids := stand_ins(game, spots, opts)
	var saved := {}
	if clip["camera"] == "turntable":   # the hero's close-up from the front, the HUD away (the shot plan's "hero" view); the record loop turns the hero
		saved = DmQaUiShots._view_begin(game, {"view": "hero", "turn": 0.0})
	var settled := 0.0
	var waited := 0.0
	while waited < SETTLE_MAX_S and (settled < SETTLE_S or _rising(core, ids)):
		await tree.process_frame
		var dt := root.get_process_delta_time()
		waited += dt
		if not _rising(core, ids):
			settled += dt
	return {"aim": aim_at(spots, origin), "ids": ids, "saved": saved}


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


## The stand-in enemies at `spots` (snapped to the navmesh), that notice nobody: by default the Graves' robbers with DUMMY_HP times the health and no damage; a clip's setup (`opts`: kind,
## health, harmless) can make them another kind, mortal or able to hurt the hero. Returns their core ids.
static func stand_ins(game: DmNextGame, spots: Array[Vector3], opts := {}) -> Array[int]:
	var ids: Array[int] = []
	var mults := {"hp": float(opts.get("health", DUMMY_HP)), "dmg": 0.0 if bool(opts.get("harmless", true)) else 1.0}
	for spot in spots:
		var id := game.director.spawn(String(opts.get("kind", DUMMY)), game.world.nav_closest(spot), [], false, mults, {"aggro": 0.5, "leash": 1.0})
		if id > 0:
			ids.append(id)
	return ids


## The turntable: the hero turned `t` of the way round (0 = facing the camera), the avatar with it.
static func _spin(body: DmHeroBody, t: float) -> void:
	body.yaw = TAU * t
	if body.avatar != null:
		body.avatar.c.root.rotation.y = body.yaw


static func _remove(file: String) -> void:
	if FileAccess.file_exists(file):
		DirAccess.remove_absolute(file)


static func _rising(core: DmCoreHost, ids: Array[int]) -> bool:
	for id in ids:
		var info := core.enemy_info(id)
		if not info.is_empty() and int(info["state"]) == DmCoreEvents.State.RISING:
			return true
	return false


## Fills what the rite costs, so a cast is never refused for it: the Reaper's soul bag, everyone else's essence.
static func _top_up(caster: DmRiteCaster) -> void:
	if caster.p.get("family") == "reaper":
		caster.p["souls"] = maxf(float(caster.p["souls"]), float(caster.p.get("soulsMax", 30.0)))
	else:
		caster.p["resource"]["value"] = caster.p["resource"]["max"]


## The rites a clip casts: its `cast` and those of its cast steps, each once.
static func _rites(rite: String, steps: Array) -> Array[String]:
	var out: Array[String] = []
	if rite != "":
		out.append(rite)
	for st: Dictionary in steps:
		if st["do"] == "cast" and not out.has(String(st["rite"])):
			out.append(String(st["rite"]))
	return out


## After a clip: the stand-ins still standing sent away without a death, what the rites left behind forgotten.
static func _clean_up(game: DmNextGame, caster: DmRiteCaster, rites: Array[String], staged: Dictionary) -> void:
	for id in staged["ids"]:
		game.core_host.remove_enemy(id)
	for r in rites:
		caster.mem(r).clear()
	if not (staged["saved"] as Dictionary).is_empty():
		DmQaUiShots._view_end(game, staged["saved"])
