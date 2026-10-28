class_name DmQaModel
extends RefCounted
## The model view of the QA plans (a shot's "view": "model", a clip's "model"): one model alone where the hero stands, in the area's own light, the hero hidden, the HUD and the waves away,
## the camera framing the model by its size like the hero close-up (DmQaUiShots.HERO_CAM) frames the hero. The model is a row of game/view_models.json ("model": "<id>", at the row's
## height and turn, as the game shows it) or a GLB the job brought along ("model_file": "<name>.glb", found beside the game's exe or the plan file; with "model" too it takes that row's height,
## turn and stride, so a changed model is seen as its creature will be). A file is loaded with GLTFDocument at run time, so a team PC sees a new model without a new build. SCREENSHOTS.md "Model view".

const FILE_RE := "^[A-Za-z0-9][A-Za-z0-9_-]{0,59}\\.glb$"
const ANIM_RE := "^[A-Za-z0-9_.|-]{1,48}$"
const MIN_HEIGHT := 0.1
const MAX_HEIGHT := 30.0
const MAX_SPEED := 15.0       ## m/s of a "move" clip's "speed"
const SETTLE_MS := 1500      ## a model still waits at least this: the hero's arrival in the area leaves a puff of wisps that fades in about a second (the clips' own settle, DmQaClips.SETTLE_S)
const DEFAULT_AT := 0.35      ## a still's moment of its clip ("anim_at"): a little in, past a walk's first contact
const WIDE := 2.4             ## the hero close-up fits a body this many times its height across: a longer model is framed by its length over this
const HERO_ROW := "hero_gravecaller"   ## the body DmQaUiShots.HERO_CAM frames
const CUT_MARGIN := 1.3       ## the near plane stands this many times the model's turning radius in front of its middle
const MIN_NEAR := 0.05
const FLOOR_KEEP := 0.9       ## the near plane stays this share of the way to the floor at the bottom of the picture
const AREA := "chapterhouse"            ## where a model view stands when the plan names no place: the same backdrop every time
const SPOT := Vector2(-4.0, 25.0)       ## in it: open floor between the pillars, the hall behind, the camera inside the room (data/slice/world.json); what stands between is cut away (cut_near)


## The model fields of a shot or clip checked: {model (row id or ""), file ("" or a safe .glb name), row (the model row, {} without one), height (0 = the row's, or the file as it is),
## anim ("" = idle, else the first clip), anim_at (0-1), error ("" = fine)}.
static func spec_of(s: Dictionary) -> Dictionary:
	var out := {"model": String(s.get("model", "")), "file": String(s.get("model_file", "")), "row": {}, "height": 0.0, "anim": String(s.get("anim", "")), "anim_at": DEFAULT_AT, "error": ""}
	if out["model"] == "" and out["file"] == "":
		out["error"] = "the model view needs \"model\" (a row id of game/view_models.json) or \"model_file\" (a .glb sent with the job)"
		return out
	if out["model"] != "":
		out["row"] = DmCreature.model_entry(out["model"])
		if (out["row"] as Dictionary).is_empty() or String(out["row"].get("url", "")) == "":
			out["error"] = "\"model\": no model row \"%s\" (game/view_models.json)" % out["model"]
			return out
	if out["file"] != "" and RegEx.create_from_string(FILE_RE).search(out["file"]) == null:
		out["error"] = "\"model_file\" is a file name like ghoul_v2.glb (letters, digits, - and _, ending .glb)"
		return out
	if out["anim"] != "" and RegEx.create_from_string(ANIM_RE).search(out["anim"]) == null:
		out["error"] = "\"anim\" is a clip name of the model (letters, digits, _ . | -)"
		return out
	for key in ["height", "anim_at"]:
		if s.has(key) and not (s[key] is float or s[key] is int):
			out["error"] = "\"%s\" must be a number" % key
			return out
	if s.has("height"):
		if float(s["height"]) < MIN_HEIGHT or float(s["height"]) > MAX_HEIGHT:
			out["error"] = "\"height\" is metres from %s to %s" % [DmQaTune.fmt(MIN_HEIGHT), DmQaTune.fmt(MAX_HEIGHT)]
			return out
		out["height"] = float(s["height"])
	if s.has("anim_at"):
		out["anim_at"] = clampf(float(s["anim_at"]), 0.0, 1.0)
	return out


## The ground speed (m/s) a model walks at in a "move" clip: the plan's "speed", else the row's stride for the clip times its height (the speed at which the feet stay planted, DmAnimator.plan_loco); 0 = none known.
static func move_speed(spec: Dictionary, anim: String, speed: Variant) -> float:
	if speed is float or speed is int:
		return clampf(float(speed), 0.0, MAX_SPEED)
	var stride: Dictionary = spec["row"].get("stride", {}) if spec["row"].get("stride") is Dictionary else {}
	var h := float(spec["height"]) if float(spec["height"]) > 0.0 else float(spec["row"].get("height", 0.0))
	return float(stride.get(anim, 0.0)) * h


## The model made (not yet in the tree): {root (feet at y 0, facing +Z), ap (AnimationPlayer or null), size (its normalised bounds' size), clips (its clip names), error}.
## `dirs`: where a "model_file" may be (the exe's folder, the plan's); nothing else is read.
static func make(spec: Dictionary, dirs: Array) -> Dictionary:
	var out := {"root": null, "ap": null, "size": Vector3.ZERO, "clips": [], "error": ""}
	var row: Dictionary = spec["row"]
	var height := float(spec["height"]) if float(spec["height"]) > 0.0 else float(row.get("height", 0.0))
	var yaw := float(row.get("yaw", 0.0))
	if spec["file"] == "":
		var c := DmModels.creature(String(row["url"]), height, yaw)
		var inf := DmModels.analyze(String(row["url"]), height)
		out["size"] = (inf.size as Vector3) * float(inf.scale)
		out["root"] = c.root
		out["ap"] = c.anim
	else:
		var path := ""
		for d in dirs:
			if String(d) != "" and FileAccess.file_exists(String(d).path_join(spec["file"])):
				path = String(d).path_join(spec["file"])
				break
		if path == "":
			out["error"] = "model file %s is not beside the game or the plan" % spec["file"]
			return out
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err := doc.append_from_file(path, state)
		var scene: Node3D = doc.generate_scene(state) as Node3D if err == OK else null
		if scene == null:
			out["error"] = "model file %s could not be read as a glTF (error %d)" % [spec["file"], err]
			return out
		var b: AABB = DmModels.measure(scene).bounds
		var s := height / maxf(b.size.y, 0.0001) if height > 0.0 else 1.0
		var c := DmModels.hold(scene, s, Vector3(b.get_center().x, b.position.y, b.get_center().z), yaw)
		if c.anim != null:
			DmModels._prep_anims(c.anim)   # its own clips: loops and root travel as the game's models have them
		out["size"] = b.size * s
		out["root"] = c.root
		out["ap"] = c.anim
	if out["ap"] != null:
		for nm in (out["ap"] as AnimationPlayer).get_animation_list():
			if nm != "RESET":
				(out["clips"] as Array).append(String(nm))
	return out


## The clip a view plays: the one asked for when the model has it, else idle, else its first; "" = none (no clips). `asked` is printed about when the model lacks it.
static func clip_of(made: Dictionary, asked: String, tag: String) -> String:
	var clips: Array = made["clips"]
	if asked != "" and clips.has(asked):
		return asked
	if asked != "":
		print("%s model: no clip \"%s\" (it has: %s)" % [tag, asked, ", ".join(clips)])
	return "idle" if clips.has("idle") else (String(clips[0]) if not clips.is_empty() else "")


## The view set up: the model made and stood where the hero stands, turned `turn` degrees (0 faces the camera), the hero and his rings hidden, the HUD and the waves away, the camera framing it.
## Returns what `end` puts back, with "model" (the holder), "ap", "size" and "clips"; or {error} when the model could not be made.
static func begin(game: DmNextGame, spec: Dictionary, turn: float, dirs: Array, tag: String) -> Dictionary:
	var made := make(spec, dirs)
	if made["error"] != "":
		print("%s model: %s" % [tag, made["error"]])
		return {"error": made["error"]}
	var body := game.local_body()
	var saved := {"hud": game.ui.visible, "cfg": game.camera.cfg, "zoom": game.camera.zoom, "target_zoom": game.camera.target_zoom, "near": game.camera.near,
		"waves": game.director.enabled, "hero_shown": body.avatar == null or body.avatar.c.root.visible, "model": made["root"], "ap": made["ap"], "size": made["size"], "clips": made["clips"], "error": ""}
	game.ui.visible = false
	game.director.enabled = false
	for id in game.core_host.enemies_in_radius(body.position, 400.0):
		game.core_host.remove_enemy(id)
	if body.avatar != null:
		body.avatar.c.root.visible = false
	if game.look != null:
		game.look.show_ring(body, false)
	var holder: Node3D = made["root"]
	holder.name = "QaModel"
	game.add_child(holder)
	holder.position = Vector3(body.position.x, 0.0, body.position.z)
	holder.rotation.y = deg_to_rad(turn)
	frame(game, made["size"])
	game.camera.snap(body.position)
	var size: Vector3 = made["size"]
	print("%s model %s: %.2f m tall, %.2f x %.2f m, clips: %s" % [tag, spec["file"] if spec["file"] != "" else spec["model"], size.y, size.x, size.z, ", ".join(made["clips"])])
	return saved


## The hero close-up's camera scaled to a model of `size`: as far and as high as frames its height (or its length, for a long low one) as the close-up frames the hero's, looking at its middle,
## with nothing between it and the model (cut_near).
static func frame(game: DmNextGame, size: Vector3) -> void:
	var hero_h := float(DmCreature.model_entry(HERO_ROW).get("height", 1.0))
	var k := maxf(size.y / hero_h, maxf(size.x, size.z) / (WIDE * hero_h))
	k = maxf(k, 0.15)
	var cfg: Dictionary = game.camera.cfg.duplicate()
	cfg.merge(DmQaUiShots.HERO_CAM, true)
	cfg["dist"] = float(DmQaUiShots.HERO_CAM["dist"]) * k
	cfg["lookAtY"] = size.y * float(DmQaUiShots.HERO_CAM["lookAtY"]) / hero_h
	game.camera.cfg = cfg
	game.camera.zoom = 1.0
	game.camera.target_zoom = 1.0
	game.camera.near = cut_near(cfg, size, game.camera.fov)


## The camera's near plane for a model of `size` framed by `cfg` (vertical `fov` degrees): just in front of the model (its turning circle, CUT_MARGIN times), so a wall, pillar or tomb
## between the camera and the model is cut away, but never into the floor at the bottom of the picture (FLOOR_KEEP of its depth: a camera drawn back for a walk sees floor nearer than the model).
static func cut_near(cfg: Dictionary, size: Vector3, fov: float) -> float:
	var dist := float(cfg["dist"])
	var up := dist * float(cfg["heightFactor"])
	var back := dist * float(cfg["backFactor"])
	var to_model := Vector2(back, up - float(cfg["lookAtY"])).length()
	var half := deg_to_rad(fov) * 0.5
	var floor_depth := up / sin(atan2(up - float(cfg["lookAtY"]), back) + half) * cos(half)   # the bottom edge's ray meets the floor this far in front of the camera
	return maxf(MIN_NEAR, minf(to_model - CUT_MARGIN * 0.5 * Vector2(size.x, size.z).length(), FLOOR_KEEP * floor_depth))


## A still's pose: `anim` at `at` of its length, frozen.
static func pose(ap: AnimationPlayer, anim: String, at: float) -> void:
	if ap == null or anim == "":
		return
	ap.play(anim, 0.0)
	ap.seek(at * ap.get_animation(anim).length, true)
	ap.speed_scale = 0.0


static func end(game: DmNextGame, saved: Dictionary) -> void:
	var holder: Variant = saved.get("model")
	if holder is Node3D and is_instance_valid(holder):
		(holder as Node3D).queue_free()
	game.ui.visible = saved["hud"]
	game.camera.cfg = saved["cfg"]
	game.camera.zoom = saved["zoom"]
	game.camera.target_zoom = saved["target_zoom"]
	game.camera.near = saved["near"]
	game.director.enabled = saved["waves"]
	var body := game.local_body()
	if body.avatar != null:
		body.avatar.c.root.visible = saved["hero_shown"]
	if game.look != null:
		game.look.show_ring(body, true)
	game.camera.snap(body.position)
