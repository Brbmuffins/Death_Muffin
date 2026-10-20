extends SceneTree
## World track tests (headless):  godot --headless --path client --script res://tests/world_builder/run.gd
## Data export sanity, every model loads, locomotion/strike-timing goldens from the TS, the world builds, every area is reachable over the
## navmesh once its seals are broken (and sealed areas are not before), gates block, the Depths' sample floor is walkable.

## The heroes of the classes that show as "Coming later" and the retired placeholder hero have no model in the client (client/assets.list carries what its game uses).
const NOT_CARRIED := ["hero_bell_monk", "hero_carrion_witch", "hero_grave_warden", "hero_hollow_knight", "hero_veilwalker", "necromancer"]

var _fail := 0
var _pass := 0

func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)

func _frames(n: int) -> void:
	for i in n:
		await process_frame

## The navigation server syncs on its own clock: force the map, then wait (bounded, 10 s) until it has synced and stopped changing.
## A fixed 0.4 s wait raced under machine load ("sealed-state: chapterhouse reachable" failed with load ~21, 2026-10-10).
func _settle(b: DmWorldBuilder) -> void:
	var map := b.get_world_3d().navigation_map
	await create_timer(0.1).timeout
	NavigationServer3D.map_force_update(map)
	var last := NavigationServer3D.map_get_iteration_id(map)
	var stable := 0
	for i in 200:
		await create_timer(0.05).timeout
		var it := NavigationServer3D.map_get_iteration_id(map)
		if it == last and it > 0:
			stable += 1
			if stable >= 4:
				break
		else:
			stable = 0
			last = it

func _initialize() -> void:
	OS.set_environment("DM_SYNC_NAV", "1")   # the navigation merges in step with game time (world_builder.gd): the run is --fixed-fps
	_run.call_deferred()

func _json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())

func _finish() -> void:
	print("%d passed, %d failed" % [_pass, _fail])
	print("%s world_builder %d checks%s" % ["PASS" if _fail == 0 else "FAIL", _pass + _fail, "" if _fail == 0 else " (%d failed)" % _fail])
	quit(1 if _fail > 0 else 0)

func _reaches(b: DmWorldBuilder, from: Vector3, to: Vector3, tol := 1.5) -> bool:
	var p := b.nav_path(from, to)
	if p.size() < 2:
		return false
	return Vector2(p[p.size() - 1].x - to.x, p[p.size() - 1].z - to.z).length() < tol

func _run() -> void:
	var fx_dir := "res://tests/world_builder/fixtures/"
	var loco: Variant = _json(fx_dir + "locomotion.json")
	var strikes: Variant = _json(fx_dir + "strike_timing.json")
	if loco == null or strikes == null:
		printerr("FAIL world: fixtures missing: they are committed in git (restore with git checkout)")
		quit(1)
		return

	# ---- goldens from the TypeScript
	var bad := 0
	for c in loco:
		var row: Dictionary = c.row if c.row != null else {}
		var p := DmAnimator.plan_loco(row, float(c.height), float(c.ground), bool(c.hasRun), bool(c.wasRun))
		if p.clip != c.clip or absf(float(p.timeScale) - float(c.timeScale)) > 1e-9 or absf(float(p.stride) - float(c.stride)) > 1e-9 or absf(float(p.residual) - float(c.residual)) > 1e-9:
			bad += 1
	_check(bad == 0, "planLocomotion matches %d TS cases (%d bad)" % [loco.size(), bad])
	bad = 0
	for c in strikes:
		var t := DmAnimator.strike_timing(float(c.duration), float(c.impact) if c.impact != null else -1.0, float(c.impactIn), float(c.follow))
		for k in ["speed", "startAt", "endAt", "impactAfter"]:
			if absf(float(t[k]) - float(c[k])) > 1e-9:
				bad += 1
	_check(bad == 0, "strikeTiming matches %d TS cases (%d bad)" % [strikes.size(), bad])

	# ---- exported data
	var w: Dictionary = DmData.world()
	_check(not w.order.is_empty() and w.order.size() == w.areas.size() and w.order.size() == DmContent.get_export("areas", "AREA_ORDER").size(), "every area is exported (%d), in the order the content names" % w.order.size())
	_check(not w.doors.is_empty() and w.doors.size() == DmContent.doors().size(), "every door of the content is exported (%d)" % w.doors.size())
	_check(not w.props.is_empty() and not w.nodes.is_empty() and not w.walls.is_empty(), "layout exported (props/nodes/walls)")
	var used: Dictionary = DmData.load_json("assets_used")
	var missing := 0
	for m in used.models:
		if not ResourceLoader.exists("res://assets/slice/" + m) and not NOT_CARRIED.has(String(m).get_slice("/", 1)):
			missing += 1
			printerr("model not imported: ", m)
	for t in used.textures:
		if not ResourceLoader.exists("res://assets/slice/" + t):
			missing += 1
	_check(missing == 0, "all %d models + %d textures imported (but the %d heroes the client does not carry)" % [used.models.size(), used.textures.size(), NOT_CARRIED.size()])
	var enemies: Dictionary = DmData.enemies()
	var npcs: Dictionary = DmData.load_json("npcs")
	var loaded := 0
	var noclip := 0
	var entries: Array = []
	entries.append_array(enemies.models.values())
	entries.append_array(npcs.models.values())
	entries.append_array(npcs.heroModels.values())
	var carried := 0
	for e in entries:
		if NOT_CARRIED.has(String(e.slug)):
			continue
		carried += 1
		var c := DmModels.creature_from(e)
		if c.root != null:
			loaded += 1
		if e.rigged and (c.animator as DmAnimator).valid():
			var ap: AnimationPlayer = c.anim
			if not (ap.has_animation("idle") or ap.has_animation("walk")):
				noclip += 1
				printerr("no idle/walk clip: ", e.slug)
		(c.root as Node3D).free()
	_check(loaded == carried and carried > 0, "%d creature models instantiate" % carried)
	_check(noclip == 0, "every rigged creature has idle or walk")
	for id in enemies.defs:
		var d: Dictionary = enemies.defs[id]
		if not enemies.models.has(d.model):
			_check(false, "enemy %s has a model entry" % id)
	for ar in w.areas.values():
		for r in ar.enemies:
			if not enemies.defs.has(r.id):
				_check(false, "roster enemy %s exists" % r.id)

	# ---- the world builds
	var b := DmWorldBuilder.new()
	root.add_child(b)
	var t_build := Time.get_ticks_msec()
	b.build(w)
	print("world build: %d ms" % (Time.get_ticks_msec() - t_build))
	await _settle(b)
	print("nav bake: %d ms, %d regions, %d links" % [b.nav_bake_ms, b.nav_regions.size(), b.nav_links.size()])
	_check(b.area_nodes.size() == w.order.size() and b.nav_regions.size() == w.order.size() + w.doors.size(), "an area node + nav region per area and per door")
	_check(b.gates.size() == w.doors.size() - 1 and not b.gates.has("chapter_graves"), "a gate for each door but chapter_graves, which is always open (%d)" % b.gates.size())
	var home: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	var start := Vector3(float(home.x), 0, float(home.z))

	# default seals: the areas with no seal (world.json: unlock null) are reachable, sealed ones not
	var open_ids: Array = []
	for id in w.order:
		if w.areas[id].unlock == null and not w.areas[id].instance:
			open_ids.append(id)
	_check(not open_ids.is_empty(), "some areas start unsealed (%s)" % ", ".join(open_ids))
	var sealed_id := ""
	for id in w.order:
		if not open_ids.has(id) and not w.areas[id].instance and sealed_id == "":
			sealed_id = id
	for id in w.order:
		var a: Dictionary = w.areas[id]
		var r: Dictionary = a.rect
		var ctr := b.nav_closest(Vector3((r.x0 + r.x1) / 2.0, 0, (r.z0 + r.z1) / 2.0))
		if id in open_ids:
			_check(_reaches(b, start, ctr), "sealed-state: %s reachable" % id)
	var oss: Dictionary = w.areas[sealed_id].rect
	_check(sealed_id != "" and not _reaches(b, start, Vector3((oss.x0 + oss.x1) / 2.0, 0, (oss.z0 + oss.z1) / 2.0), 3.0), "sealed-state: %s NOT reachable" % sealed_id)
	var sealed_gate := ""   # the gate of a door into the sealed area
	for d in w.doors:
		if (d.a == sealed_id or d.b == sealed_id) and b.gates.has(d.id) and sealed_gate == "":
			sealed_gate = d.id
	_check(sealed_gate != "" and (b.gates[sealed_gate].collider as CollisionShape3D).disabled == false, "sealed gate (%s) collider is solid" % sealed_gate)

	# every seal broken: every area reachable from the Chapterhouse, and walkable at its centre
	b.open_all()
	await _settle(b)
	for id in w.order:
		var a: Dictionary = w.areas[id]
		if id == "depths":
			continue
		var r: Dictionary = a.rect
		var want := Vector3((r.x0 + r.x1) / 2.0, 0, (r.z0 + r.z1) / 2.0)
		var ctr := b.nav_closest(want)
		var ok := _reaches(b, start, ctr)
		_check(ok, "open-state: %s reachable from the Chapterhouse" % id)
		var snap := Vector2(ctr.x - want.x, ctr.z - want.z).length()
		_check(snap < 12.0, "%s centre is (near) walkable navmesh (%.1f m off)" % [id, snap])
		_check(b.area_at(ctr.x, ctr.z) == id, "%s navmesh point lies in the area" % id)
	var far_id := ""   # the far end of the world: the area whose centre is farthest from the start
	var far_d := -1.0
	for id in w.order:
		if id == "depths":
			continue
		var fr: Dictionary = w.areas[id].rect
		var fd := Vector2((fr.x0 + fr.x1) / 2.0 - start.x, (fr.z0 + fr.z1) / 2.0 - start.z).length()
		if fd > far_d:
			far_d = fd
			far_id = id
	var far_r: Dictionary = w.areas[far_id].rect
	var far_c := b.nav_closest(Vector3((far_r.x0 + far_r.x1) / 2.0, 0, (far_r.z0 + far_r.z1) / 2.0))
	var path := b.nav_path(start, far_c)
	_check(path.size() > 2 and _reaches(b, start, far_c), "Chapterhouse -> %s (the far end) path (%d points)" % [far_id, path.size()])
	_check((b.gates[sealed_gate].collider as CollisionShape3D).disabled, "open gate collider is disabled")

	# depths: instance open, walk from the start to the stair down
	var D: Dictionary = w.depths
	var ds := b.nav_closest(Vector3(D.start.x, 0, D.start.z))
	var dd := b.nav_closest(Vector3(D.stairDown.x, 0, D.stairDown.z))
	_check(_reaches(b, ds, dd, 2.0), "depths sample floor: start -> stair down walkable")

	# stride-matched animator on a real model
	var hero: Dictionary = DmData.hero()
	var c := DmModels.creature_from(hero.model)
	var an: DmAnimator = c.animator
	root.add_child(c.root)
	var walk_u := float(an.stride.get("walk", DmAnimator.DEFAULT_WALK)) * an.height   # the model's walking stride, in metres a second
	an.loco(walk_u)
	_check(an.last_plan.clip == "walk" and absf(float(an.last_plan.timeScale) * float(an.last_plan.stride) - walk_u) < 0.05 * walk_u, "hero walk plan matches ground speed")
	an.loco(walk_u * DmAnimator.RUN_UP * 1.5)
	_check(an.last_plan.clip == "run", "hero runs once the ground speed is past the walk stride's run threshold")
	_check(an.strike("attack", 0.2), "attack clip plays")
	await _frames(2)
	_check(an.death(), "death clip plays")
	_finish()
