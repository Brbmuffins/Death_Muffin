extends SceneTree
## World track tests (headless):  godot --headless --path godot --script res://tests/world/run.gd
## Data export sanity, every model loads, locomotion/strike-timing goldens from the TS, the world builds, every area is reachable over the
## navmesh once its seals are broken (and sealed areas are not before), gates block, the Depths' sample floor is walkable.

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

## The navigation server syncs on its own clock: give it real time, then force the map.
func _settle(b: DmWorldBuilder) -> void:
	await create_timer(0.4).timeout
	NavigationServer3D.map_force_update(b.get_world_3d().navigation_map)
	await create_timer(0.1).timeout

func _initialize() -> void:
	_run.call_deferred()

func _json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())

func _finish() -> void:
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _reaches(b: DmWorldBuilder, from: Vector3, to: Vector3, tol := 1.5) -> bool:
	var p := b.nav_path(from, to)
	if p.size() < 2:
		return false
	return Vector2(p[p.size() - 1].x - to.x, p[p.size() - 1].z - to.z).length() < tol

func _run() -> void:
	var fx_dir := "res://tests/world/fixtures/"
	var loco: Variant = _json(fx_dir + "locomotion.json")
	var strikes: Variant = _json(fx_dir + "strike_timing.json")
	if loco == null or strikes == null:
		printerr("fixtures missing: run tools/godot/gen-fixtures.sh")
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
	_check(w.order.size() == 13, "13 areas exported")
	_check(w.doors.size() == 11, "11 doors exported")
	_check(w.props.size() > 500 and w.nodes.size() > 50 and w.walls.size() > 100, "layout exported (props/nodes/walls)")
	var used: Dictionary = DmData.load_json("assets_used")
	var missing := 0
	for m in used.models:
		if not ResourceLoader.exists("res://assets/slice/" + m):
			missing += 1
			printerr("model not imported: ", m)
	for t in used.textures:
		if not ResourceLoader.exists("res://assets/slice/" + t):
			missing += 1
	_check(missing == 0, "all %d models + %d textures imported" % [used.models.size(), used.textures.size()])
	var enemies: Dictionary = DmData.enemies()
	var npcs: Dictionary = DmData.load_json("npcs")
	var loaded := 0
	var noclip := 0
	var entries: Array = []
	entries.append_array(enemies.models.values())
	entries.append_array(npcs.models.values())
	entries.append_array(npcs.heroModels.values())
	for e in entries:
		var c := DmModels.creature_from(e)
		if c.root != null:
			loaded += 1
		if e.rigged and (c.animator as DmAnimator).valid():
			var ap: AnimationPlayer = c.anim
			if not (ap.has_animation("idle") or ap.has_animation("walk")):
				noclip += 1
				printerr("no idle/walk clip: ", e.slug)
		(c.root as Node3D).free()
	_check(loaded == entries.size(), "%d creature models instantiate" % entries.size())
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
	_check(b.area_nodes.size() == 13 and b.nav_regions.size() == 13 + 11, "an area node + nav region per area and per door")
	_check(b.gates.size() == 10, "10 gates (chapter_graves is always open)")
	var start := Vector3(0, 0, 24)

	# default seals: always-open halls reachable, sealed ones not
	var open_ids := ["chapterhouse", "acre", "alchemist_wing", "graves"]
	for id in w.order:
		var a: Dictionary = w.areas[id]
		var r: Dictionary = a.rect
		var ctr := b.nav_closest(Vector3((r.x0 + r.x1) / 2.0, 0, (r.z0 + r.z1) / 2.0))
		if id in open_ids:
			_check(_reaches(b, start, ctr), "sealed-state: %s reachable" % id)
	var oss: Dictionary = w.areas.ossuary.rect
	_check(not _reaches(b, start, Vector3((oss.x0 + oss.x1) / 2.0, 0, (oss.z0 + oss.z1) / 2.0), 3.0), "sealed-state: ossuary NOT reachable")
	_check((b.gates["graves_ossuary"].collider as CollisionShape3D).disabled == false, "sealed gate collider is solid")

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
	var path := b.nav_path(start, b.nav_closest(Vector3(90, 0, -126)))  # the Ember Altar in the Pyre, the far end
	_check(path.size() > 5, "Chapterhouse -> Cinder Pyre path (%d points)" % path.size())
	_check((b.gates["graves_ossuary"].collider as CollisionShape3D).disabled, "open gate collider is disabled")

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
	an.loco(1.0)
	_check(an.last_plan.clip == "walk" and absf(float(an.last_plan.timeScale) * float(an.last_plan.stride) - 1.0) < 0.5, "hero walk plan matches ground speed")
	an.loco(6.0)
	_check(an.last_plan.clip == "run", "hero runs at 6 m/s")
	_check(an.strike("attack", 0.2), "attack clip plays")
	await _frames(2)
	_check(an.death(), "death clip plays")
	_finish()
