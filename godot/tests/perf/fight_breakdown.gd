extends SceneTree
## Audit probe (not committed): a held big fight (god necromancer on auto combat, ~N enemies kept alive, thralls raised by the
## autocombat rotation), then a knock-out breakdown: each processing script class / native class in turn has its process and
## physics process switched off for a segment; the drop in frame time vs. the neighbouring baseline segments = that class's
## inclusive cost (its own script + the physics / animation it drives). Headless = CPU only.
##   nice -n 10 godot --headless --fixed-fps 60 --path godot --script res://tests/perf/fight_breakdown.gd -- [--area=graves] [--n=30] [--thralls=10]
##     [--seg=240] [--reps=2] [--groups=<label,...>] [--classes=1]     knock-out table
##   --full-party   the in-game benchmark's Full Party fight (DmBenchmark.SIZES: 72 enemies, 32 thralls, the room's boss held awake; the director,
##     upkeep and enemy health are the benchmark's own, DmBenchFight.arm / upkeep): --area defaults to sanctum (the benchmark's Standard room),
##     --n / --thralls still override the counts, --boss=<id>|none the boss. `--full-party --reps=0 --seg=600` prints the base line only.
## Numbers are main-thread CPU ms per frame (/proc/thread-self/schedstat): other processes' load does not move them, the fight's own
## ebb and flow does (compare several reps; never assert them in a test).

var g: DmNextGame
var hero: DmHeroBody
var fight: Dictionary          ## DmBenchFight.boot's result
var full := false              ## --full-party: the benchmark's fight rules (DmBenchFight.upkeep) instead of this probe's own top-up
var thralls := 0
var boss := ""
var every := 20                ## frames between upkeeps (the benchmark's 0.25 s at 60 fps in a full-party run)


func _initialize() -> void:
	_run.call_deferred()


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _top_up(n: int) -> void:
	DmBenchFight.top_up(g, hero, n)


## Main-thread CPU time (ns) from the kernel: immune to other processes' load (wall time on the shared VPS is not).
func _cpu_ns() -> int:
	var f := FileAccess.open("/proc/thread-self/schedstat", FileAccess.READ)
	return int(f.get_line().split(" ")[0]) if f != null else 0


## One segment: mean wall ms per frame, mean TIME_PROCESS / TIME_PHYSICS_PROCESS ms.
func _seg(frames: int, n: int) -> Dictionary:
	var wall := 0.0
	var pr := 0.0
	var ph := 0.0
	var walls: Array = []
	var c0 := _cpu_ns()
	for i in frames:
		if i % every == 0:
			if full:
				DmBenchFight.upkeep(fight, n, thralls, boss)
			else:
				_top_up(n)
				hero.heal(1e6)
		var f0 := Time.get_ticks_usec()
		await process_frame
		var w := (Time.get_ticks_usec() - f0) / 1000.0
		wall += w
		walls.append(w)
		pr += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		ph += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var cpu := (_cpu_ns() - c0) / 1e6 / frames
	walls.sort()
	return {"cpu": cpu, "wall": wall / frames, "p50": walls[frames / 2], "p95": walls[int(frames * 0.95)], "proc": pr / frames, "phys": ph / frames}


func _key(nd: Node) -> String:
	var s: Script = nd.get_script()
	if s != null:
		var gn := String(s.get_global_name())
		return gn if gn != "" else s.resource_path.get_file()
	return nd.get_class()


func _census() -> Dictionary:
	var out := {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		for c in nd.get_children():
			stack.append(c)
		var active := nd.is_processing() or nd.is_physics_processing() or nd is AnimationMixer or nd is CPUParticles3D or nd is GPUParticles3D
		if not active:
			continue
		var k := _key(nd)
		if not out.has(k):
			out[k] = []
		out[k].append(nd)
	return out


func _set_on(nodes: Array, on: bool, saved: Dictionary, mode: String = "all") -> void:
	for nd in nodes:
		if not is_instance_valid(nd):
			continue
		if on:
			if saved.has(nd):
				var s: Array = saved[nd]
				nd.set_process(s[0])
				nd.set_physics_process(s[1])
				if nd is AnimationMixer:
					nd.active = s[2]
				elif nd is CPUParticles3D or nd is GPUParticles3D:
					nd.emitting = s[2]
		else:
			saved[nd] = [nd.is_processing(), nd.is_physics_processing(), nd.active if nd is AnimationMixer else (nd.emitting if (nd is CPUParticles3D or nd is GPUParticles3D) else false)]
			if mode != "phys":
				nd.set_process(false)
			if mode != "proc":
				nd.set_physics_process(false)
			if nd is AnimationMixer:
				nd.active = false
			elif nd is CPUParticles3D or nd is GPUParticles3D:
				nd.emitting = false


func _run() -> void:
	full = OS.get_cmdline_user_args().has("--full-party")
	var area := _arg("area", "sanctum" if full else "graves")
	if full:
		seed(DmBenchmark.SEED)
	fight = await DmBenchFight.boot(root, int(_arg("disc", "2")), {}, {}, area)
	g = fight["game"]
	hero = fight["hero"]
	var caster: DmRiteCaster = fight["caster"]
	var at: Vector3 = fight["at"]
	var n := int(_arg("n", str(DmBenchmark.SIZES["full_party"][0]) if full else "30"))
	var seg := int(_arg("seg", "240"))
	var want_thralls := int(_arg("thralls", str(DmBenchmark.SIZES["full_party"][1]) if full else "10"))
	thralls = want_thralls
	var summons := [0]
	var defeats := [0]
	if full:
		boss = DmBenchFight.boss_of(area)
		var b := _arg("boss", "")
		if b != "":
			boss = "" if b == "none" else b
		every = 15
		DmBenchFight.arm(g, n, DmBenchmark.SEED)
		g.bosses.summoned.connect(func(_b: String, _p: int) -> void: summons[0] += 1)
		g.bosses.defeated.connect(func(_b: String, _k: int, _pos: Vector3) -> void: defeats[0] += 1)
	# warm the fight up, then fill the legion directly (the auto rotation may not raise any)
	for k in 4:
		await _seg(60, n)
	var host := DmBenchFight.raise_thralls(caster, want_thralls, at)
	for k in 4:
		await _seg(60, n)
	print("FB setup area=%s enemies=%d thralls=%d boss=%s nodes=%d" % [area, g.director.alive_count(), host.list().size(), boss if boss != "" else "none", int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	print("FB physics active=%d pairs=%d islands=%d" % [Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS), Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS), Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)])
	# enemy / thrall own profilers over one segment
	DmEnemy.profile = true
	DmThrall.profile = true
	var base: Dictionary = await _seg(seg, n)
	DmEnemy.profile = false
	DmThrall.profile = false
	print("FB base cpu=%.2f wall=%.2f p50=%.2f p95=%.2f" % [base.cpu, base.wall, base.p50, base.p95])
	print("FB enemy brain %.3f ms/frame (nav %.3f, %d ticks/frame, repaths %d)  thrall brain %.3f ms/frame (%d ticks/frame)" % [
		DmEnemy.prof_brain_us / 1000.0 / seg, DmEnemy.prof_nav_us / 1000.0 / seg, DmEnemy.prof_ticks / seg, DmEnemy.prof_repaths,
		DmThrall.prof_brain_us / 1000.0 / seg, DmThrall.prof_ticks / seg])
	var cen := _census()
	var keys := cen.keys()
	keys.sort_custom(func(a, b) -> bool: return cen[a].size() > cen[b].size())
	var line := ""
	for k in keys:
		line += "%s=%d " % [k, cen[k].size()]
	print("FB census ", line)
	# knock-out groups: [label, predicate on the class key]
	var groups := [
		["ALL enemies", func(k: String) -> bool: return k.begins_with("DmEnemy") and k != "DmEnemyFx"],
		["ALL thralls", func(k: String) -> bool: return k.begins_with("DmThrall") and k != "DmThrallHost"],
		["enemies physics", func(k: String) -> bool: return k.begins_with("DmEnemy") and k != "DmEnemyFx", "phys"],
		["enemies process", func(k: String) -> bool: return k.begins_with("DmEnemy") and k != "DmEnemyFx", "proc"],
		["thralls physics", func(k: String) -> bool: return k.begins_with("DmThrall") and k != "DmThrallHost", "phys"],
		["thralls process", func(k: String) -> bool: return k.begins_with("DmThrall") and k != "DmThrallHost", "proc"],
		["AnimationPlayer/Tree", func(k: String) -> bool: return k == "AnimationPlayer" or k == "AnimationTree"],
		["statuses+affixes", func(k: String) -> bool: return k == "DmStatusSet" or k == "DmAffixSet"],
		["HUD/UI", func(k: String) -> bool: return k.begins_with("DmHud") or k in ["DmGameUi", "DmCounselView", "DmNextUiHost", "DmNextChronicle", "DmNextMeta", "DmNextProgress"]],
		["FX", func(k: String) -> bool: return k in ["DmFxRuntime", "DmFx", "DmEnemyFx", "DmBossFx", "GPUParticles3D", "CPUParticles3D"] or k.begins_with("DmFx")],
		["audio+music", func(k: String) -> bool: return k in ["audio_director.gd", "DmMusicDirector", "DmAudioDirector"]],
		["input/autocombat", func(k: String) -> bool: return k == "DmNextInput"],
		["rite caster", func(k: String) -> bool: return k == "DmRiteCaster"],
		["world/dressing/gather", func(k: String) -> bool: return k in ["DmWorldDressing", "DmNextGather", "DmNextAcre", "DmDepths", "DmChapterhouse"]],
	]
	var only := _arg("groups", "")
	if only != "":
		groups = groups.filter(func(gr: Array) -> bool: return only.split(",").has(String(gr[0]).split(" ")[0] + "_" + String(gr[0]).split(" ")[-1]) or only.split(",").has(String(gr[0])))
	if _arg("classes", "0") == "1":
		for k in keys:
			groups.append([k, func(x: String) -> bool: return x == k])
	var rows: Array = []
	for rep in int(_arg("reps", "2")):
		for gr in groups:
			var c2 := _census()
			var nodes: Array = []
			for k in c2:
				if gr[1].call(k):
					nodes.append_array(c2[k])
			if nodes.is_empty():
				continue
			var saved := {}
			_set_on(nodes, false, saved, String(gr[2]) if gr.size() > 2 else "all")
			var off: Dictionary = await _seg(seg, n)
			_set_on(nodes, true, saved)
			var b2: Dictionary = await _seg(seg, n)
			var ref: float = (float(base.cpu) + float(b2.cpu)) / 2.0
			base = b2
			rows.append([gr[0], nodes.size(), ref - float(off.cpu)])
			print("FB off %-24s n=%3d  saves %.2f ms cpu  (base %.2f -> %.2f; wall %.2f)" % [gr[0], nodes.size(), ref - float(off.cpu), ref, off.cpu, off.wall])
	var awake := g.bosses.active_boss()
	print("FB done enemies=%d thralls=%d boss=%s woken %d defeated %d%s" % [g.director.alive_count(), host.list().size(), boss if boss != "" else "none", summons[0], defeats[0],
		", hp %.0f%% phase %d" % [awake.hp / awake.max_hp * 100.0, awake.phase] if awake != null else ""])
	quit(0)
