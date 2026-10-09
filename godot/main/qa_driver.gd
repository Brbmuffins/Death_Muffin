extends Node
## Autoload QA driver. Inactive unless the game is started with user args:  -- --qa [--shots=<dir>] [--seconds=N] [--shot-plan=<plan.json>]
## Launch it with the dev-offline quick start (`--dev-offline --class=2`, or its alias `--world-demo`): the rebuild (DmNextGame) as the test account `tester`.
## Default: scripted fight in the Hollow Graves, a wave of the dead around the hero, the real rites cast at the nearest enemy, Exhume for thralls; one
## screenshot a second (qa_NN.png); quits after N seconds. With --shot-plan: the UI shot plan (main/qa_ui_shots.gd) instead of the fight.

var active := false
var shots := "res://../shots"
var seconds := 20.0
var t := 0.0
var n := 0
var nxt: DmNextGame   ## the rebuild, found once "Main/NextGame" is ready; driven through its own seams (director.spawn, DmNextInput.cast_at)
var _cast_t := 0.0
var _setup := false
var plan_path := ""   ## --shot-plan=<abs json>: UI shot plan (main/qa_ui_shots.gd) instead of the fight

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--qa":
			active = true
		elif a.begins_with("--shot-plan="):
			plan_path = a.substr(12)
		elif a.begins_with("--shots="):
			shots = a.substr(8)
		elif a.begins_with("--seconds="):
			seconds = float(a.substr(10))
	set_process(active)

func _process(dt: float) -> void:
	t += dt
	if nxt != null:
		if plan_path != "":
			if nxt.ui == null or nxt.ui.warming or DmLoadingScreen.current != null or t < 3.0:
				return
			set_process(false)
			DmQaUiShots.run(self, nxt, plan_path, shots)
			return
		_process_next(dt)
		return
	var nm := get_tree().root.get_node_or_null("Main/NextGame")
	if nm != null and nm.ready_:
		nxt = nm


## The scripted fight (the default, on DmNextGame): the hero walks to the Graves, a pack of robbers keeps arriving, the primary
## rite is cast at the nearest one every 0.4 s, Exhume now and then; hp / essence are topped up. Same screenshots and quit rule. Runs only with `--qa`;
## a few timers per second, nothing per frame beyond the clock.
func _process_next(dt: float) -> void:
	var b := nxt.local_body()
	if b == null:
		return
	if not _setup and t > 4.0:
		_setup = true
		b.teleport(Vector3(0.0, 0.0, 9.0))
	if _setup and t > 9.0:
		var foes: Array = nxt.director.enemies.values().filter(func(e: Variant) -> bool: return is_instance_valid(e))
		var ids: Dictionary = {}
		for k in nxt.director.enemies:
			ids[nxt.director.enemies[k]] = int(k)
		if foes.size() < 6 and fmod(t, 3.0) < dt:
			for i in 5:
				nxt.director.spawn("robber", b.position + Vector3(randf_range(-6.0, 6.0), 0.0, -randf_range(5.0, 10.0)))
		_cast_t -= dt
		if _cast_t <= 0.0:
			_cast_t = 0.4
			var best: DmEnemy = null
			var bd := 99.0
			for e in foes:
				var d := Vector2(e.position.x - b.position.x, e.position.z - b.position.z).length()
				if d < bd:
					bd = d
					best = e
			if best != null:
				var slot := 5 if fmod(t, 4.0) < 0.5 else 0
				nxt.input.cast_at(slot, Vector3(best.position.x, 0.0, best.position.z), int(ids.get(best, 0)), false)
				var caster := b.get_node_or_null("Rites") as DmRiteCaster
				if caster != null:
					caster.p["resource"]["value"] = caster.p["resource"]["max"]
				b.heal(1e6)
	if t > float(n + 1):
		n += 1
		var vp := get_viewport()
		var tex := vp.get_texture() if vp != null else null   # null on a headless run: nothing to shoot, the fight still runs
		var img := tex.get_image() if tex != null else null
		if img != null:
			DirAccess.make_dir_recursive_absolute(shots)
			img.save_png("%s/qa_%02d.png" % [shots, n])
	if t > seconds:
		get_tree().quit()
