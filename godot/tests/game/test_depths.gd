extends RefCounted
## DmDepthsController against a real headless DmGame on DmApi's mock backend: Warren stair -> depth 1 -> clear it -> descend -> depth 5 chest -> leave -> resume.

var passed := 0
var failed := 0
var events: Array = []


## DmGame that routes sim events to the controller the way the lead's handle_event must.
class TGame extends DmGame:
	func handle_event(ev: Dictionary) -> void:
		if depths != null:
			depths.on_event(ev)
		super(ev)


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", what)


func _tick(game: DmGame, seconds: float) -> void:
	for i in int(seconds * 60.0):
		game.player.hp = game.player.max_hp()
		game.tick(1.0 / 60.0)


func _count(id: String) -> int:
	var n := 0
	for e in events:
		if e[0] == id:
			n += 1
	return n


func _kill_floor(game: DmGame) -> void:
	for i in 3000:
		if bool(game.sim.depths["stairOpen"]):
			return
		for id in game.sim.enemies.keys():
			var e: DmSimEnemy = game.sim.enemies[id]
			if e.area == "depths" and e.hp > 0.0:
				game.sim.damage_enemy(e, 1.0e9, game.self_id)
		_tick(game, 0.1)


func run(tree: SceneTree) -> void:
	var mock := DmMockBackend.new("")
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	var r := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := TGame.new()
	tree.root.add_child(game)
	await game.start(c.data, api, {"visual": false, "persist": false, "seed": 11, "local_progress": true})
	game.game_event.connect(func(id: String, ctx: Dictionary): events.append([id, ctx]))
	game.nav.set_unlocked(DmContent.area_order())
	var d := DmDepthsController.new(game)
	game.depths = d
	check(d.hud_state() == null and d.map_floor() == null and d.interactables().is_empty(), "no run: empty readouts")
	check(d.loot_area("depths") == null, "no run: no loot area")
	_tick(game, 0.5)
	# the Warren stair
	var stair: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	game.player.teleport(float(stair["x"]), float(stair["z"]) + 2.3)
	check(d.prompt({"kind": "stair"}).begins_with("Descend into the Catacomb Depths"), "stair prompt")
	check(d.stair_clicked() == 0, "stair click starts the run")
	check(game.sim.depths != null and int(game.sim.depths["depth"]) == 1, "depth 1 run")
	check(d.floor_() != null and game.nav.depths_floor() != null, "floor loaded into the nav")
	var f: Dictionary = d.floor_()
	check(absf(game.player.x - float(f["start"]["x"])) < 0.01 and absf(game.player.z - float(f["start"]["z"])) < 0.01, "hero on the floor's start")
	check(absf(game.player.facing - PI) < 1e-6, "facing north")
	check(_count("banner") >= 1 and _count("depths_floor") == 1, "banner + counsel event")
	_tick(game, 0.2)
	check(game.player.area == "depths", "hero in the depths: %s" % game.player.area)
	check(game.area_id == "depths", "game area depths: %s" % game.area_id)
	var its := d.interactables()
	check(its.size() == 2 and its[0]["kind"] == "depths_up" and its[1]["kind"] == "depths_down", "depth 1: up + down only")
	var hud: Variant = d.hud_state()
	check(hud != null and hud["depth"] == 1 and hud["need"] == 10 and hud["kills"] == 0 and hud["open"] == false and hud["chest"] == false, "hud state: %s" % str(hud))
	var mf: Variant = d.map_floor()
	check(mf != null and mf["rooms"].size() == 9 and mf["down"]["open"] == false and mf["chest"] == null, "map floor")
	check(d.progress_line().begins_with("Level <b>"), "progress line: %s" % d.progress_line())
	check(d.loot_area("depths") == "ossuary" and d.loot_area("graves") == null, "loot area")
	check(d.prompt(its[1]).begins_with("The stair is sealed"), "sealed prompt")
	check(not d.descend(), "sealed stair refuses")
	# fight: the floor's enemies come and die
	_tick(game, 3.0)
	var seen := 0
	for id in game.sim.enemies:
		if game.sim.enemies[id].area == "depths":
			seen += 1
	check(seen > 0, "the dead climbed out (%d)" % seen)
	var gold0 := int(game.character["gold"])
	var peak0 := float(game.chronicle.view()["life"].get("kills.depths", 0.0))
	_kill_floor(game)
	check(bool(game.sim.depths["stairOpen"]), "stair open after the quota")
	_tick(game, 0.2)
	check(d.hud_state()["open"] == true and d.hud_state()["kills"] == 10, "hud: open at 10/10")
	check(d.prompt(d.interactables()[1]) == "Descend to depth 2", "open prompt")
	check(float(game.chronicle.view()["life"].get("kills.depths", 0.0)) > peak0, "kills.depths recorded")
	check(float(game.chronicle.view()["life"].get("depths.floors", 0.0)) >= 1.0, "floor counted")
	var cleared := false
	for e in events:
		if e[0] == "banner" and e[1]["title"] == "The stair opens":
			cleared = true
	check(cleared, "stair-opens banner")
	check(int(game.character["gold"]) >= gold0, "gold not lost")
	# descend
	check(d.descend(), "descend")
	check(int(game.sim.depths["depth"]) == 2, "depth 2")
	check(float(game.chronicle.view()["life"].get("peak.depth", 0.0)) >= 2.0, "peak.depth 2")
	check(d.hud_state()["open"] == false and d.hud_state()["need"] == 11, "depth 2 hud: %s" % str(d.hud_state()))
	check(absf(game.player.x - float(d.floor_()["start"]["x"])) < 0.01, "arrived at depth 2 start")
	# depth 5 (chest floor): jump the run forward through the sim API the way a resume does
	d.leave()
	check(game.sim.depths != null, "leave asks twice (first click only arms)")
	check(d.leave(), "second click (inside the window) leaves")
	check(game.sim.depths == null and game.nav.depths_floor() == null, "run closed")
	check(absf(game.player.z - (float(stair["z"]) + 2.3)) < 0.01, "back at the Warren stair %f %f" % [game.player.x, game.player.z])
	_tick(game, 0.3)
	check(d.hud_state() == null and d.interactables().is_empty(), "closed: no readouts")
	# resume at deepest: a deeper floor is on record -> the choice
	events.clear()
	var back := d.stair_clicked()
	check(back == 2 and _count("depths_stair_offer") == 1 and events[0][1]["deepest"] == 2, "stair click offers the choice (resume 2)")
	check(game.sim.depths == null, "no run before the pick")
	game.chronicle.max_("peak.depth", 5.0)
	check(d.prompt({"kind": "stair"}).contains("resume at depth 5"), "prompt names the resume depth")
	check(d.enter(5), "enter at depth 5 (resume)")
	var f5: Dictionary = d.floor_()
	check(int(game.sim.depths["depth"]) == 5 and f5["chest"] != null, "depth 5 holds a chest")
	var its5 := d.interactables()
	check(its5.size() == 3 and its5[2]["kind"] == "depths_chest", "chest is an interactable")
	check(d.hud_state()["chest"] == true and d.map_floor()["chest"] != null, "chest in hud + map")
	check(d.loot_area("depths") == "coliseum", "depth 5 loot area")
	check(not d.open_chest() == false, "chest opens")
	check(not d.open_chest(), "chest opens once")
	check(d.hud_state()["chest"] == false and d.interactables().size() == 2 and d.map_floor()["chest"] == null, "chest gone after opening")
	var opened := false
	for e in events:
		if e[0] == "banner" and e[1]["title"] == "The chest opens":
			opened = true
	check(opened and _count("depths_chest") == 1, "chest banner + counsel event")
	# death: the run is over, the floor stays until finish_after_death
	game.depths.on_player_death()
	check(d.interactables().is_empty() and game.sim.depths != null, "after death: no interactables, floor still up")
	d.finish_after_death()
	check(game.sim.depths == null and game.nav.depths_floor() == null, "finish_after_death closes the run")
	check(d.enter(1), "a new run can start")
	d.dispose()
	check(game.sim.depths == null, "dispose closes the run")
	game.queue_free()
