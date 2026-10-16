class_name DmDevEntry
extends Node
## The dev entry of the rebuilt client until the front flow arrives (ROADMAP: login and character select): starts the game scene (DmNextGame) OFFLINE in
## the Hollow Graves with a dev character, the way today's `--dev-offline --class=2` does. It is the project's main scene (project.godot run/main_scene).
## Nothing here reaches a server: the backend is the local mock (DmOffline.make_mock, its accounts in user://dm_dev_offline_db.json), and DmNextGame
## refuses any api that has a base url.
##
##   godot --path client                                   # the Gravecaller (class 2), level 10, the minimal HUD, waves
##   godot --path client -- --class=1 --seed=7             # after `--`: the options below
##
## He fights with the rites of today's game (client/README.md "The Gravecaller's rites"): LMB walks, or attacks the enemy under the cursor with the primary (Bone Needle; hold to
## repeat, Shift+LMB casts in place), keys 1-4 are the kit's default loadout (Marrow Spear, Exhume, Miasma, Black Litany), RMB is Corpse Explosion and R the signature from level 10
## (Command: Rend). WASD walks. Click-to-move, camera zoom on the wheel.
##
## Options: --class=N (discipline index, default 2 = Gravecaller), --level=N (the character's level, default 10: R works from 10, Bone Mantle from 12, Bone Storm from 14), --seed=N (the combat core's seed), --no-waves, --crowd=N (a first wave of N bodies 6 to 12 m
## around the hero, and waves of N after it, up to N alive: a look at a big fight), --baked=<dir> (the baked crowd models; default res://crowd/baked: `bash client/tools/bake_crowd.sh` makes the robber and the hound),
## --shot=<png> [--shot-after=<game seconds, default 25>] (save a screenshot and quit: the QA hook).

const DEV_DB := "user://dm_dev_offline_db.json"   ## this project's own user folder ("Death Muffin (rebuild)"), never the live game's

var game: DmNextGame
var api: DmApi
var mock: DmMockBackend     ## the local backend; the api's transport only points at it, so it is kept here


func _ready() -> void:
	get_tree().auto_accept_quit = true
	# Physics interpolation is opt-in per body (as DmMain does): everything is OFF by default, and only what is moved in _physics_process turns itself ON.
	get_tree().root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# The Vfx autoload reads the current 3D camera every frame: keep one alive until the world's camera takes over.
	var idle := Camera3D.new()
	idle.name = "IdleCamera"
	add_child(idle)
	idle.current = true
	var args := OS.get_cmdline_user_args()
	var opts := options(args)
	mock = DmOffline.make_mock(DEV_DB)
	api = DmOffline.make_api(mock)
	var r := await api.register("tester", "t@example.com", "pw1234")
	if not r.ok:
		r = await api.login("tester", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(int(opts["class"]))
	c.data["level"] = int(opts["level"])   # the mock's character starts at level 1; the dev entry plays at the level the signature unlocks at
	game = load("res://next/next_game.tscn").instantiate()
	game.name = "NextGame"
	add_child(game)
	var game_opts := {"offline": true, "name": "tester", "hud": "minimal", "waves": not bool(opts["no_waves"])}
	if opts.has("seed"):
		game_opts["seed"] = opts["seed"]
	if opts.has("baked"):
		game_opts["baked_dir"] = opts["baked"]
	await game.start(c.data, api, game_opts)
	if game.ready_:
		idle.queue_free()
		var crowd := int(opts.get("crowd", 0))
		if crowd > 0:
			var d := game.director
			d.cap = crowd
			d.wave_size = crowd
			d.enemy_limit = crowd + 12
			d.spawn_min = 6.0
			d.spawn_max = 12.0
			d.spawn_wave([game.local_body()], crowd)
			d.flush_spawns()
		if opts.has("shot"):
			_shot_after(String(opts["shot"]), float(opts["shot_after"]))


## The launch options after `--`.
static func options(args: PackedStringArray) -> Dictionary:
	var o := {"class": 2, "level": 10, "no_waves": false, "shot_after": 25.0}
	for a in args:
		if a.begins_with("--class="):
			o["class"] = int(a.substr(8))
		elif a.begins_with("--level="):
			o["level"] = clampi(int(a.substr(8)), 1, 60)
		elif a.begins_with("--seed="):
			o["seed"] = int(a.substr(7))
		elif a == "--no-waves":
			o["no_waves"] = true
		elif a.begins_with("--crowd="):
			o["crowd"] = int(a.substr(8))
		elif a.begins_with("--baked="):
			o["baked"] = a.substr(8)
		elif a.begins_with("--shot="):
			o["shot"] = a.substr(7)
		elif a.begins_with("--shot-after="):
			o["shot_after"] = float(a.substr(13))
	return o


## QA: after `seconds` of game time save the viewport and quit.
func _shot_after(path: String, seconds: float) -> void:
	var until := Engine.get_physics_frames() + int(seconds * 60.0)
	while Engine.get_physics_frames() < until:
		await get_tree().physics_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("saved ", path, " ", img.get_size(), " enemies ", game.core_host.alive_count(), " crowd ", game.core_host.view.stats())
	get_tree().quit(0)
