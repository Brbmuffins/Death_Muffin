extends SceneTree
## First-use stutters (ROADMAP Phase 1: "a test fails when an effect used in play is not warmed at load"): the real offline game scene (client/next/next_game.tscn) is
## started with its warm-up on (`"warmup": true`) and every material that turns up in the scene tree is written down by what makes its shader (below). Phase "warm" runs
## from the start of `DmNextGame.start` until it returns (the warm-up, `DmNextWarmup.run`, is its last step); every signature seen then counts as warmed. Phase "play" is
## everything after it. For each playable discipline (Gravecaller 2, Ossuary 1, Mourner 3, Rotweaver 4, the Reaper 11; a fresh game each):
##   - every slot of the kit's hotbar (`DmRiteHotbar.rite_for_slot`, slots 0 to 6) is cast at core enemies, with corpses and raised thralls where a rite needs them (a normal
##     cast, then a crit), the enemies are killed, and a few seconds of game time pass after each step so projectiles, beams, decals and fades play out;
##   - a fight with live enemies and three thralls; the hero takes a blow, a chill, a root and a heal; loot lies on the ground (every rarity, a name over each near one, one taken);
##   - the hero puts on every weapon and off-hand (the necromancers' in both tiers, the craftable sword and bow), the legendary set of his discipline (the aura, the helm, the
##     mantle, the body swap), a cape and each pet.
## The first necromancer (Gravecaller) and the Reaper also cast every other rite of their kit (the grimoire can slot them), and the Gravecaller fights the area's boss and thirty
## seconds of the wave director's waves.
## FAIL for every material of play whose signature was never seen while warming. Each is printed once with its node path, its script and scene, the discipline and the rite (or
## step) that was active, so the developer knows what to add to `DmNextWarmup` (or the system's own `warm()`).
##
## What a signature is (a material is the same as another when the GPU compiles the same program for it, not when it is the same object):
##   - ShaderMaterial: its Shader (the resource path, or a hash of its code when built in a scene or resource);
##   - StandardMaterial3D / ORMMaterial3D: its class, every mode and flag (transparency, shading, blend, cull, depth draw and test, diffuse, specular, billboard, texture filter,
##     alpha antialiasing, distance fade, emission operator, detail blend / uv, texture channels, every get_flag(i), every get_feature(i)) and which texture slots are set;
##   - ParticleProcessMaterial: the properties that change its generated shader (emission shape, particle flags, the curves and textures that are set, collision, sub-emitter
##     and turbulence modes, attractors);
##   - CanvasItemMaterial: blend, light mode, particles animation;
##   - the material after it (`next_pass`) is part of it. A Sprite3D / AnimatedSprite3D / Label3D has none of its own: the program is decided by its flags (billboard,
##     transparent, shaded, double sided, alpha cut, no depth test, fixed size, texture filter, alpha antialiasing, a multichannel font), and that is its signature.
## Where it looks: every node the tree gets (`SceneTree.node_added`; a node's materials are read a frame later, they are often set right after it enters) and the whole tree at
## the phase boundaries and after every step of play. A node's materials are the ones its draw uses: MeshInstance3D (override, surface override, mesh), MultiMeshInstance3D (the
## multimesh's mesh), GPUParticles3D (process material and draw passes), CPUParticles3D, SpriteBase3D, Label3D, FogVolume, an overlay, and a CanvasItem's material (the UI).
## Decals have no shader of their own (the decal atlas) and are skipped.
##
## The Vfx autoload and the static caches keep their pools from one game to the next in this process, so the warm set is the union of the games' warm phases (a player's first game
## starts with all of it empty; that is the case the first game here checks). ZERO script errors or engine errors in the log. Timings are INFO lines, never asserts.
## Run: godot --headless --fixed-fps 60 --path client --script res://tests/warm_coverage.gd   (PACED in the runner; `-- --list` after it prints every signature, what warmed
## it and how often play showed it)

const BIG := 1000.0   ## health multiplier of a target that must survive the cast
const START := {"areas": ["graves"], "offline": true, "name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "warmup": true}
const RARITIES := ["common", "uncommon", "rare", "epic", "legendary"]
const CORPSE_RITES := ["exhume", "corpse_explosion", "grave_offering", "carrion_seed", "grave_step"]   ## aimed at a corpse


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


## The recorder: hears the scene tree, writes down what makes each material's program, and sorts it into warmed (phase "warm") and played (phase "play").
class Recorder:
	extends RefCounted
	const SKIP_PROPS := ["resource_local_to_scene", "resource_path", "resource_name", "script", "next_pass", "render_priority", "stencil_reference"]
	var tree: SceneTree
	var phase := "warm"
	var warmed := {}        ## signature -> path of the first node that showed it
	var played := {}        ## signature -> how many times play showed it
	var missing := {}       ## signature -> {node, class, script, scene, ctx}
	var ctx_list: Array = [{"disc": "", "rite": "", "step": "boot"}]
	var checked := 0        ## nodes looked at
	var scans := 0
	var _pend_ids := PackedInt64Array()
	var _pend_ctx := PackedInt32Array()
	var _defaults := {}     ## class -> a fresh instance (what "set" is measured against)
	var _props := {}        ## class -> [[name, type], ...] the properties that can change a program
	var _cache := {}
	var _caching := false
	var _flag_names := ClassDB.class_get_enum_constants("BaseMaterial3D", "Flags")
	var _feature_names := ClassDB.class_get_enum_constants("BaseMaterial3D", "Feature")
	var _texture_names := ClassDB.class_get_enum_constants("BaseMaterial3D", "TextureParam")
	var _particle_flag_names := ClassDB.class_get_enum_constants("ParticleProcessMaterial", "ParticleFlags")

	func start(t: SceneTree) -> void:
		tree = t
		tree.node_added.connect(_on_added)
		tree.process_frame.connect(_flush)

	func set_ctx(disc: String, rite: String, step: String) -> void:
		ctx_list.append({"disc": disc, "rite": rite, "step": step})

	func _on_added(n: Node) -> void:
		_pend_ids.append(n.get_instance_id())
		_pend_ctx.append(ctx_list.size() - 1)

	## The nodes that entered since the last frame, looked at now (a frame after they came in).
	func _flush() -> void:
		var ids := _pend_ids
		var cs := _pend_ctx
		_pend_ids = PackedInt64Array()
		_pend_ctx = PackedInt32Array()
		for i in ids.size():
			var n := instance_from_id(ids[i]) as Node
			if n != null and n.is_inside_tree():
				note(n, cs[i])

	## The whole tree (the boundaries of the phases and after every step of play: a material can be given to a node that has been there a while).
	func scan_all() -> void:
		_flush()
		scans += 1
		_cache.clear()
		_caching = true
		var ci := ctx_list.size() - 1
		var stack: Array[Node] = [tree.root]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			note(n, ci)
			stack.append_array(n.get_children())
		_caching = false
		_cache.clear()

	func end_warm() -> void:
		scan_all()
		phase = "play"

	func begin_warm() -> void:
		scan_all()
		phase = "warm"

	func note(n: Node, ci: int) -> void:
		checked += 1
		for sig in sigs_of(n):
			if phase == "warm":
				if not warmed.has(sig):
					warmed[sig] = str(n.get_path())
				continue
			played[sig] = int(played.get(sig, 0)) + 1
			if not warmed.has(sig) and not missing.has(sig):
				var o := origin_of(n)
				missing[sig] = {"node": str(n.get_path()), "class": n.get_class(), "script": o["script"], "scene": o["scene"], "ctx": ctx_list[ci]}

	## The script and the scene of a node: its own, else the nearest ancestor's.
	func origin_of(n: Node) -> Dictionary:
		var script_path := ""
		var scene_path := ""
		var cur: Node = n
		while cur != null:
			var sc: Script = cur.get_script()
			if script_path == "" and sc != null and sc.resource_path != "":
				script_path = sc.resource_path + ("" if cur == n else " (on %s)" % cur.name)
			if scene_path == "" and cur.scene_file_path != "":
				scene_path = cur.scene_file_path + ("" if cur == n else " (on %s)" % cur.name)
			cur = cur.get_parent()
		return {"script": script_path, "scene": scene_path}

	# ------------------------------------------------------------------------------------------------------------------ which materials a node draws with

	## The signatures of the materials this node draws with.
	func sigs_of(n: Node) -> PackedStringArray:
		var out := PackedStringArray()
		if n is Decal:
			return out
		if n is GeometryInstance3D:
			var gi := n as GeometryInstance3D
			var ov := gi.material_override
			if n is MeshInstance3D:
				var mi := n as MeshInstance3D
				if mi.mesh != null:
					for i in mi.mesh.get_surface_count():
						_add(out, mi.get_active_material(i))   # the override, else the surface override, else the mesh's own
			elif n is MultiMeshInstance3D:
				var mm := (n as MultiMeshInstance3D).multimesh
				if mm != null and mm.mesh != null:
					_add_mesh(out, mm.mesh, ov)
			elif n is GPUParticles3D:
				var gp := n as GPUParticles3D
				_add(out, gp.process_material)
				for k in gp.draw_passes:
					_add_mesh(out, gp.get_draw_pass_mesh(k), ov)
			elif n is CPUParticles3D:
				_add_mesh(out, (n as CPUParticles3D).mesh, ov)
			elif n is SpriteBase3D or n is Label3D:
				if ov != null:
					_add(out, ov)
				else:
					out.append(_sprite_sig(n))
			_add(out, gi.material_overlay)
		elif n is FogVolume:
			_add(out, (n as FogVolume).material)
		elif n is CanvasItem:
			var m := (n as CanvasItem).material
			if m != null:
				_add(out, m)
		return out

	func _add_mesh(out: PackedStringArray, mesh: Mesh, ov: Material) -> void:
		if mesh == null:
			return
		for i in mesh.get_surface_count():
			_add(out, ov if ov != null else mesh.surface_get_material(i))

	func _add(out: PackedStringArray, m: Material) -> void:
		if m == null:
			return
		var s := sig_of(m)
		if s != "":
			out.append(s)

	## The material the engine builds for a sprite or a label from its flags (BaseMaterial3D.get_material_for_2d): the same program for the same flags, whatever the node.
	func _sprite_sig(n: Node3D) -> String:
		var transparent: Variant = n.get("transparent")   # (a Label3D has none: it is transparent unless it cuts alpha)
		var msdf := false
		if n is Label3D:
			var f: Font = (n as Label3D).font
			while f is FontVariation:
				f = (f as FontVariation).base_font
			msdf = f is FontFile and (f as FontFile).multichannel_signed_distance_field
		return "Sprite/Label3D{billboard=%d transparent=%s shaded=%s double_sided=%s alpha_cut=%d no_depth_test=%s fixed_size=%s filter=%d alpha_aa=%d msdf=%s}" % [
			int(n.get("billboard")), str(true if transparent == null else bool(transparent)), str(n.get("shaded")), str(n.get("double_sided")), int(n.get("alpha_cut")),
			str(n.get("no_depth_test")), str(n.get("fixed_size")), int(n.get("texture_filter")), int(n.get("alpha_antialiasing_mode")), str(msdf)]

	# ------------------------------------------------------------------------------------------------------------------ what makes a material's program

	func sig_of(m: Material) -> String:
		var key := m.get_instance_id()
		if _caching and _cache.has(key):
			return _cache[key]
		var parts := PackedStringArray()
		var cur: Material = m
		var guard := 0
		while cur != null and guard < 6:
			parts.append(_one(cur))
			cur = cur.next_pass
			guard += 1
		var s := " > ".join(parts)
		if _caching:
			_cache[key] = s
		return s

	func _one(m: Material) -> String:
		if m is ShaderMaterial:
			var sh := (m as ShaderMaterial).shader
			if sh == null:
				return "ShaderMaterial{no shader}"
			var p := sh.resource_path
			if p == "" or p.contains("::"):
				return "ShaderMaterial{built-in code #%d, %d characters}" % [sh.code.hash(), sh.code.length()]
			return "ShaderMaterial{%s}" % p
		if m is BaseMaterial3D:
			var b := m as BaseMaterial3D
			var d := _diff(b)
			var ref := _ref_of(b) as BaseMaterial3D
			for i in BaseMaterial3D.FLAG_MAX:
				if b.get_flag(i) != ref.get_flag(i):
					d.append("flag:%s" % (String(_flag_names[i]).trim_prefix("FLAG_").to_lower() if i < _flag_names.size() else "#%d" % i))
			for i in BaseMaterial3D.FEATURE_MAX:
				if b.get_feature(i) != ref.get_feature(i):
					d.append("feature:%s" % (String(_feature_names[i]).trim_prefix("FEATURE_").to_lower() if i < _feature_names.size() else "#%d" % i))
			for i in BaseMaterial3D.TEXTURE_MAX:
				if (b.get_texture(i) != null) != (ref.get_texture(i) != null):
					d.append("texture:%s" % (String(_texture_names[i]).trim_prefix("TEXTURE_").to_lower() if i < _texture_names.size() else "#%d" % i))
			d = _unique(d)
			return "%s{%s}" % [b.get_class(), ", ".join(d)]
		if m is ParticleProcessMaterial:
			var pm := m as ParticleProcessMaterial
			var d := _diff(pm)
			var ref := _ref_of(pm) as ParticleProcessMaterial
			for i in ParticleProcessMaterial.PARTICLE_FLAG_MAX:
				if pm.get_particle_flag(i) != ref.get_particle_flag(i):
					d.append("particle_flag:%s" % (String(_particle_flag_names[i]).trim_prefix("PARTICLE_FLAG_").to_lower() if i < _particle_flag_names.size() else "#%d" % i))
			return "ParticleProcessMaterial{%s}" % ", ".join(_unique(d))
		if m is CanvasItemMaterial:
			return "CanvasItemMaterial{%s}" % ", ".join(_diff(m))
		var p2 := m.resource_path
		return "%s{%s}" % [m.get_class(), "" if p2 == "" or p2.contains("::") else p2]

	func _unique(d: PackedStringArray) -> PackedStringArray:
		var seen := {}
		var out := PackedStringArray()
		for s in d:
			if not seen.has(s):
				seen[s] = true
				out.append(s)
		return out

	## A fresh material of the same class: what "set" is measured against, so a signature lists only what differs from the default.
	func _ref_of(m: Material) -> Material:
		var cn := m.get_class()
		if not _defaults.has(cn):
			_defaults[cn] = ClassDB.instantiate(cn)
		return _defaults[cn]

	## The properties of `m` (modes, switches and which texture / curve slots are set) that differ from a default material's: the ones that change the generated shader.
	func _diff(m: Material) -> PackedStringArray:
		var cn := m.get_class()
		if not _props.has(cn):
			var list: Array = []
			for p: Dictionary in m.get_property_list():
				if (int(p["usage"]) & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR)) == 0 or String(p["name"]) in SKIP_PROPS or String(p["name"]).begins_with("metadata/"):
					continue
				var t := int(p["type"])
				if t == TYPE_BOOL or t == TYPE_INT or t == TYPE_OBJECT:
					list.append([String(p["name"]), t])
			_props[cn] = list
		var ref := _ref_of(m)
		var out := PackedStringArray()
		for e: Array in _props[cn]:
			var nm: String = e[0]
			if int(e[1]) == TYPE_OBJECT:
				if (m.get(nm) != null) != (ref.get(nm) != null):
					out.append("%s set" % nm)
			elif m.get(nm) != ref.get(nm):
				out.append("%s=%s" % [nm, str(m.get(nm))])
		return out


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var rec := Recorder.new()
var t0_msec := 0
var api_: DmApi
var mock_: DmMockBackend
var g: DmNextGame
var host: DmCoreHost
var core: RefCounted
var hero: DmHeroBody
var c: DmRiteCaster
var field: DmCoreCorpses
var origin := Vector3.ZERO
var dirv := Vector3(1, 0, 0)
var side := Vector3(0, 0, 1)
var base_mods: Dictionary = {}
var rejected := ""
var refused: Array = []             ## "discipline/rite: reason" of every cast the caster refused
var warm_log: Array = []            ## "discipline: ms (bodies, effects, rows)" of each game's warm-up
var scenes := 0                     ## games started
var cast_rites := {}                ## rite -> accepted casts
var blows_taken := 0                ## enemy blows that reached the hero (the live fights)
var waves_seen := 0                 ## waves the director sent


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL warm_coverage: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func secs(s: float) -> void:
	await ticks(int(round(s * 60.0)))


func _initialize() -> void:
	await process_frame
	OS.add_logger(errlog)
	t0_msec = Time.get_ticks_msec()
	rec.start(self)
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	api_ = api
	mock_ = mock
	var reg := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(reg.data["token"])
	for d in _disciplines():
		await start_game(int(d[0]), String(d[1]))
		await play_discipline(String(d[1]))
	await finish()


# ------------------------------------------------------------------------------------------------------------------------ a game

## The playable disciplines from the data, as [class index, discipline id]: the Gravecaller first (its game also fights the boss and the waves), then the rest by class index.
func _disciplines() -> Array:
	var out: Array = []
	for d: Dictionary in (DmCombatData.disciplines()["disciplines"] as Dictionary).values():
		if DmCharacterBuild.is_playable(float(d["classIndex"])):
			out.append([int(d["classIndex"]), String(d["id"])])
	out.sort_custom(func(a: Array, b: Array) -> bool:
		if (a[1] == "gravecaller") != (b[1] == "gravecaller"):
			return a[1] == "gravecaller"
		return int(a[0]) < int(b[0]))
	return out


## Every rite of a family's kit, read from the data the way the game does (hotbar, grimoire, primaries, RMB, signatures).
func _kit_rites(family: String) -> Array:
	var kit: Dictionary = DmContent.kit(family)
	var out: Array = []
	for key in ["hotbar", "grimoire", "primaries"]:
		out.append_array(kit.get(key, []))
	if kit.has("rmb"):
		out.append(kit["rmb"])
	out.append_array((kit.get("signatures", {}) as Dictionary).values())
	return out


## A fresh game with a level-20 hero of class `cls`, started with the warm-up on. Everything the tree gets until `start` returns is warm.
func start_game(cls: int, disc: String) -> void:
	var ch := await api_.load_or_create_character(cls)
	DmDevMock.set_level(mock_, ch.data, 20)
	if g != null:
		g.process_mode = Node.PROCESS_MODE_DISABLED
		await g.leave()
		g.queue_free()
		await process_frame
		check_effects_dropped()
		root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	rec.set_ctx(disc, "", "start")
	rec.begin_warm()
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	DmNextWarmup.last_ms = 0
	var t1 := Time.get_ticks_msec()
	await g.start(ch.data, api_, START)
	rec.end_warm()
	scenes += 1
	# (the effects' pools stay built from one game to the next in this process: only the first game builds and draws every Binbun effect again)
	check(DmNextWarmup.last_ms > 0 and DmNextWarmup.models > 0 and DmNextWarmup.crowd_rows > 0 and (scenes > 1 or DmNextWarmup.effects > 0), "%s: the warm-up ran (%d bodies, %d effects, %d rows)" % [disc, DmNextWarmup.models, DmNextWarmup.effects, DmNextWarmup.crowd_rows])
	warm_log.append("%s: warm-up %d ms (%d bodies, %d effects, %d crowd rows), the whole start %d ms" % [disc, DmNextWarmup.last_ms, DmNextWarmup.models, DmNextWarmup.effects, DmNextWarmup.crowd_rows, Time.get_ticks_msec() - t1])
	host = g.core_host
	core = host.core
	hero = g.local_body()
	c = hero.get_node("Rites") as DmRiteCaster
	field = host.corpses
	origin = hero.position
	base_mods = c.mods.duplicate(true)
	c.random = func() -> float: return 0.5   # no crit, the middle of the needle's jitter
	c.cast_rejected.connect(func(_rite: String, why: String) -> void: rejected = why)
	g.hero_hit.connect(func(_enemy: int, _kind: String, _damage: float) -> void: blows_taken += 1)
	find_arena()
	await ticks(2)   # the avatar is made a frame after the body enters the tree


## After a game is freed nothing it played is left running (DmNextGame._exit_tree clears the Vfx autoload, which outlives the game: an Unleash
## Souls orbit still circling would otherwise call its `follow` closure on the freed hero every frame).
func check_effects_dropped() -> void:
	var vfx := root.get_node_or_null("Vfx")
	if vfx == null:
		return
	var left: int = vfx.binbun._live.size() if vfx.binbun != null else 0
	left += vfx.prims._transients.size() if vfx.prims != null else 0
	check(left == 0, "freeing a game stops its effects (%d left running)" % left)


## The first direction from the hero along which the ground is clear for 16 m, and 3 m to either side (rites.gd's).
func find_arena() -> void:
	var map: RID = g.world.nav_map()
	var best := -1.0
	for a in range(0, 360, 15):
		var d := Vector3(cos(deg_to_rad(a)), 0.0, sin(deg_to_rad(a)))
		var s := Vector3(-d.z, 0.0, d.x)
		var run := 0.0
		for k in range(1, 19):
			var ok := true
			for off in [-3.0, 0.0, 3.0]:
				var q: Vector3 = origin + d * float(k) + s * off
				var cp := NavigationServer3D.map_get_closest_point(map, q)
				if Vector2(cp.x - q.x, cp.z - q.z).length() > 0.3:
					ok = false
			if not ok:
				break
			run = float(k)
		if run > best:
			best = run
			dirv = d
			side = s
		if run >= 18.0:
			break
	check(best >= 16.0, "the arena: ground clear for %.0f m" % best)


func at(along: float, across := 0.0) -> Vector3:
	return origin + dirv * along + side * across


# ------------------------------------------------------------------------------------------------------------------------ the arena

## Puts everything back (rites.gd's reset): the enemies dead and their corpses gone, the legion crumbled, the rites' timers and state cleared, the hero at his place with full health,
## essence and souls and no cooldown.
func reset() -> void:
	c._pending.clear()
	c._mem.clear()
	if c._legends != null:
		c._legends.wisps.clear()
	for id in core.enemy_ids():
		core.damage(id, 1.0e12, 0)
	for id in core.corpse_ids():
		core.corpse_consume(id, 0, "consumed")
	for id in core.thrall_ids():
		core.kill_thrall(id, "crumbled")
	hero.teleport(origin)
	hero.stop()
	c._set_mods(base_mods)
	refill()
	var p := c.p
	p["hp"] = float(p["stats"]["maxHp"])
	p["cooldowns"] = {}
	p["castUntil"] = 0.0
	p["rootedUntil"] = 0.0
	p["barrier"] = 0.0
	p["barrierPeak"] = 0.0
	p["runes"] = {}
	p["loadout"] = DmWeaponLine.no_loadout()
	p.erase("weaveStroke")
	p["harvestAmp"] = false
	p["lastHurtAt"] = 1.0e12
	for e in c.get_children():
		if String(e.name).begins_with("Ribs"):
			e.queue_free()
	rejected = ""


## Full essence and, for the Reaper, a full soul bag.
func refill() -> void:
	c.p["resource"]["value"] = float(c.p["resource"]["max"])
	if hero.family == "reaper":
		c.p["souls"] = int(c.p["soulsMax"])


func foe(def: String, pos: Vector3, hp_mult := BIG, elite := false) -> int:
	var id := host.spawn_enemy(def, pos, 1, hp_mult, 0.0, elite, "graves", false)
	core.stun(id, 3600.0)   # static and harmless
	return id


func corpse(pos: Vector3, kind := "normal", enemy := "robber") -> int:
	return field.add_corpse(pos.x, pos.z, kind, enemy, false, 0.0, 1.0, "graves")


## A thrall of the hero's kind raised at `pos` the way an exhume does (a corpse is laid, the legion raises from it).
func raise_at(pos: Vector3) -> bool:
	corpse(pos)
	var ex := {"kind": c.mods["thrallKind"], "cap": c.mods["thrallCap"], "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"], "attackSpeedMult": c.mods["thrallAttackSpeedMult"], "r": 0.8}
	var r: Dictionary = c.thralls().raise(ex, pos)
	return bool(r["ok"])


# ------------------------------------------------------------------------------------------------------------------------ play

func play_discipline(disc: String) -> void:
	check(String(hero.discipline_id) == disc or (disc == "reaper" and hero.family == "reaper"), "%s: the hero is a %s (%s)" % [disc, disc, hero.discipline_id])
	for slot in 7:
		var rite := DmRiteHotbar.rite_for_slot(slot, hero.family, hero.discipline_id)
		check(rite != "" and DmRiteRegistry.has(rite), "%s: slot %d is a rite (%s)" % [disc, slot, rite])
		if rite != "":
			await play_rite(disc, rite)
	# the rites of the kit the hotbar does not hold (the grimoire can slot them), once per kit: the first necromancer's game and the Reaper's
	if disc == "gravecaller" or disc == "reaper":
		for rite: String in DmRiteRegistry.ids():
			if not cast_rites.has(rite) and (rite in _kit_rites(String(hero.family))):
				await play_rite(disc, rite)
	await play_fight(disc)
	if disc == "gravecaller":
		await play_boss(disc)
		await play_waves(disc)
	await play_gear(disc)
	await play_hurt(disc)
	await play_loot(disc)
	rec.scan_all()


## One rite at six core enemies (two weak ones die to it, one is an elite), with corpses and three raised thralls near (exhume gets corpses and no legion), cast
## and cast again as a crit, then every enemy killed (their death effects and corpses).
func play_rite(disc: String, rite: String) -> void:
	rec.set_ctx(disc, rite, "setup")
	reset()
	await ticks(2)
	var foes: Array = []
	foes.append(foe("robber", at(6.0)))
	foes.append(foe("hound", at(7.5, 2.2)))
	foes.append(foe("robber", at(8.0, -2.0), BIG, true))
	foes.append(foe("ghoul", at(9.5, 0.5)))
	foes.append(foe("robber", at(5.0, -1.5), 0.001))
	foes.append(foe("robber", at(6.5, 3.0), 0.001))
	var corpses: Array = [at(6.5, 1.0), at(8.5, -0.5), at(3.0, 2.5), at(4.0, -2.5)]
	for k in corpses.size():
		corpse(corpses[k], "toxic" if k == 1 else "normal")
	if rite != "exhume":
		var raised := 0
		for p in [at(2.0, 2.0), at(2.5, -2.0), at(1.5, 0.0)]:
			raised += 1 if raise_at(p) else 0
		check(raised == 3, "%s/%s: three thralls rise (%d)" % [disc, rite, raised])
		await secs(1.6)   # (a rising thrall cannot act yet: Command: Rend and Rally the Dead need the legion on its feet)
	await ticks(3)
	var target := int(foes[0])
	var aim: Vector3 = host.enemy_position(target)   # at an enemy, as the cursor on one is
	if rite == "wraith_walk":
		aim = at(16.0)
	elif rite in CORPSE_RITES:
		aim = corpses[0]
	await do_cast(disc, rite, aim, target, "cast")
	await secs(1.0)
	if rite in CORPSE_RITES:
		aim = corpses[1]
	c.random = func() -> float: return 0.0   # the second cast crits
	await do_cast(disc, rite, aim, target, "cast again (a crit)")
	c.random = func() -> float: return 0.5
	await secs(1.5)
	rec.set_ctx(disc, rite, "enemies killed")
	for id in core.enemy_ids():
		core.damage(id, 1.0e12, hero.core_id)
	await secs(2.5)
	rec.scan_all()


## Casts `rite` the way the owner does and notes a refusal (a refused cast would leave its effects uncovered: a failure).
func do_cast(disc: String, rite: String, aim: Vector3, target: int, step: String) -> void:
	rec.set_ctx(disc, rite, step)
	refill()
	c.p["castUntil"] = 0.0
	c.p["cooldowns"].erase(rite)
	rejected = ""
	c.request_cast(rite, aim, target)
	if rejected != "":
		refused.append("%s/%s: %s" % [disc, rite, rejected])
	check(rejected == "", "%s: %s is accepted (%s)" % [disc, rite, rejected])
	if rejected == "":
		cast_rites[rite] = int(cast_rites.get(rite, 0)) + 1


## Keeps the hero standing and in essence (a fight he cannot lose: only what the effects look like matters here).
func keep_up() -> void:
	c.p["hp"] = c.max_hp()
	refill()


## The hero fights for `secs` seconds: every quarter second he is kept standing and casts one of his rites at the nearest enemy (his primary most of the time).
func fight_for(secs_: float) -> void:
	var slots := [0, 1, 3, 0, 5, 0]
	for i in int(secs_ * 4.0):
		keep_up()
		var nearest := -1
		var best := INF
		for id in core.enemy_ids():
			var d := host.enemy_position(id).distance_to(hero.position)
			if d < best:
				best = d
				nearest = id
		if nearest > 0:
			var rite := DmRiteHotbar.rite_for_slot(int(slots[i % slots.size()]), hero.family, hero.discipline_id)
			c.p["castUntil"] = 0.0
			c.request_cast(rite, host.enemy_position(nearest), nearest)
		await secs(0.25)


## Three thralls rise next to the hero.
func raise_legion() -> void:
	for p in [at(2.0, 2.0), at(2.5, -2.0), at(1.5, 0.0)]:
		raise_at(p)
	await secs(1.6)


## A real fight: three thralls and six live enemies (the Graves' roster, one elite) that walk up and attack, the hero casting at the nearest one.
func play_fight(disc: String) -> void:
	rec.set_ctx(disc, "", "a fight with live enemies")
	reset()
	await ticks(2)
	await raise_legion()
	var k := 0
	for def in ["robber", "hound", "ghoul", "penitent", "sac", "robber"]:
		host.spawn_enemy(def, at(9.0 + float(k % 3) * 1.5, float(k) - 2.5), 1, 1.0, 0.0, k == 5, "graves", false)
		k += 1
	await fight_for(6.0)
	rec.set_ctx(disc, "", "the fight is won")
	for id in core.enemy_ids():
		core.damage(id, 1.0e12, hero.core_id)
	await secs(2.5)
	rec.scan_all()


## The real wave director for thirty seconds: waves breach in, the hero and his legion fight them; then it is switched off again.
func play_waves(disc: String) -> void:
	rec.set_ctx(disc, "", "waves of enemies")
	reset()
	await ticks(2)
	await raise_legion()
	g.director.enabled = true
	await fight_for(30.0)
	g.director.enabled = false
	waves_seen += g.director.waves_spawned
	check(g.director.waves_spawned > 0, "%s: the director sent waves (%d)" % [disc, g.director.waves_spawned])
	rec.set_ctx(disc, "", "the waves are beaten")
	for id in core.enemy_ids():
		core.damage(id, 1.0e12, hero.core_id)
	await secs(2.5)
	rec.scan_all()


## The area's boss woken at his grave and fought for twenty seconds (his telegraphs, zones and adds), then beaten.
func play_boss(disc: String) -> void:
	rec.set_ctx(disc, "", "the boss fight")
	reset()
	await ticks(2)
	var me := g.session.get_my_id()
	g.my_member().prog.add_shards(int(DmContent.boss("gravedigger")["shards"]) * 4)
	hero.teleport(g.bosses.site_pos("gravedigger") + Vector3(0.0, 0.0, 2.0))
	await ticks(2)
	for p in [Vector3(1.5, 0.0, 3.0), Vector3(-1.5, 0.0, 3.5), Vector3(0.0, 0.0, 4.0)]:
		raise_at(g.bosses.site_pos("gravedigger") + p)
	await secs(1.6)
	var why: String = g.bosses.try_summon(me, "gravedigger")
	check(why == "", "%s: the King wakes (%s)" % [disc, why])
	var boss: DmBoss = g.bosses.active_boss()
	if boss == null:
		return
	for i in 80:   # twenty seconds
		keep_up()
		if is_instance_valid(boss):
			c.p["castUntil"] = 0.0
			var rite := DmRiteHotbar.rite_for_slot([0, 1, 3, 0, 5][i % 5], hero.family, hero.discipline_id)
			c.request_cast(rite, boss.global_position, -1)
		await secs(0.25)
	rec.set_ctx(disc, "", "the boss is beaten")
	if is_instance_valid(boss):
		boss.take_damage(1.0e9, hero)
	await secs(4.0)
	rec.scan_all()


## What the hero wears: every weapon and off-hand (the necromancers' in two tiers, the craftable sword and bow), a full legendary set (its aura and its look), then a cape and each pet.
func play_gear(disc: String) -> void:
	rec.set_ctx(disc, "", "the hero puts on gear")
	reset()
	await ticks(2)
	var items: Dictionary = DmContent.items()
	var weapons: Array = []   # the necromancers' weapons and off-hands in two tiers (bone: the model's own look, hell: the emissive tier dress), and the craftable ones
	var offhands: Array = []
	var sets := {}            # a set's id -> its legendary pieces {item_type: id}
	for id: String in items:
		var meta: Dictionary = items[id]
		var t := String(meta.get("type", ""))
		if not DmGearProps.necro_by_id(id).is_empty() and (id.ends_with("_bone") or id.ends_with("_hell")):
			(weapons if t == "weapon" else offhands).append(id)
		elif t == "weapon" and DmGearProps.necro_by_id(id).is_empty():
			weapons.append(id)   # (the craftable sword and bow: stand-ins built in code)
		var armor := DmGearProps.armor_by_id(id)
		if not armor.is_empty() and String(meta.get("rarity", "")) == "legendary":
			var sid := String(armor["setId"])
			if not sets.has(sid):
				sets[sid] = {}
			sets[sid][t] = id
	var av: DmAvatar = hero.avatar
	for k in weapons.size():   # every weapon kind in both tiers, with an off-hand
		var wear := {"main_hand": {"item_id": weapons[k], "rarity": "epic" if String(weapons[k]).ends_with("_hell") else String(items[weapons[k]].get("rarity", "common"))}}
		if not offhands.is_empty():
			var oh: String = offhands[k % offhands.size()]
			wear["off_hand"] = {"item_id": oh, "rarity": "epic" if oh.ends_with("_hell") else "common"}
		av.set_equipment(wear)
		await secs(0.5)
	var best: Dictionary = {}   # the discipline's own legendary set if it has one (its body replaces the hero's), else the fullest
	for sid in sets:
		if DmGearModels.legendary_discipline(String(sid)) == String(hero.discipline_id):
			best = sets[sid]
	if best.is_empty():
		for sid in sets:
			if (sets[sid] as Dictionary).size() > best.size():
				best = sets[sid]
	var staff := ""   # the set is worn with a hell-tier necromancer weapon at the top rarity (the most motes)
	for id: String in weapons:
		if staff == "" and id.ends_with("_hell") and not DmGearProps.necro_by_id(id).is_empty():
			staff = id
	var set_wear := {"main_hand": {"item_id": staff, "rarity": "legendary"}}
	for t: String in best:
		set_wear[String(t).trim_prefix("armor_")] = {"item_id": best[t], "rarity": "legendary"}
	av.set_equipment(set_wear)
	await secs(1.5)
	rec.scan_all()
	var capes: Array = DmContent.get_export("cosmetics", "CAPES")
	var pets: Array = DmContent.get_export("cosmetics", "PETS")
	for k in pets.size():   # every pet, with a cape
		g.look.set_cosmetics({"cape": String(capes[k % capes.size()]["id"]), "pet": String(pets[k]["id"])})
		await secs(1.2)
		rec.scan_all()
	g.look.set_cosmetics({"cape": "", "pet": ""})
	av.set_equipment({})
	await secs(0.5)


## The hero takes a blow, a chill and a root, and is healed.
func play_hurt(disc: String) -> void:
	rec.set_ctx(disc, "", "the hero is hurt")
	reset()
	await ticks(2)
	hero.restore_vitals()
	hero.take_damage(c.max_hp() * 0.25, 0, "melee")
	await secs(0.7)
	hero.dm_enemy_effect(&"chill", {"seconds": 1.5})
	await secs(1.0)
	hero.dm_enemy_effect(&"root", {"seconds": 1.0})
	await secs(1.0)
	rec.set_ctx(disc, "", "the hero is healed")
	hero.heal(c.max_hp() * 0.2)
	await secs(1.0)
	rec.scan_all()


## Loot on the ground at the hero's feet: one drop of every rarity (the names show over the near ones), gold and shards, and the hero takes one.
func play_loot(disc: String) -> void:
	rec.set_ctx(disc, "", "loot on the ground")
	reset()
	await ticks(2)
	var m: DmRewardsMember = g.my_member()
	var lv: DmLootView = m.loot_view
	var items: Dictionary = DmContent.items()
	var k := 0
	for rarity in RARITIES:
		for id: String in items:
			var meta: Dictionary = items[id]
			if String(meta.get("rarity", "")) == rarity and String(meta.get("type", "")) != "rune" and not DmRunes.is_rune_id(id):
				lv.drop({"item_id": id, "quantity": 1}, hero.position + side * (0.9 + 0.7 * float(k)) + dirv * 0.8, true)
				k += 1
				break
	lv.drop({"kind": "gold", "amount": 25}, hero.position)
	lv.drop({"kind": "shard", "amount": 3}, hero.position)
	check(lv.count() >= 3, "%s: loot lies on the ground (%d)" % [disc, lv.count()])
	await secs(2.0)
	rec.scan_all()
	if lv.count() > 0:
		rec.set_ctx(disc, "", "loot is picked up")
		var d: Dictionary = lv._drops[0]
		lv.request_pickup(d)
		hero.teleport(Vector3(float(d["x"]), hero.position.y, float(d["z"])))
		await secs(1.5)
	rec.scan_all()


# ------------------------------------------------------------------------------------------------------------------------ end

func finish() -> void:
	for rite: String in DmRiteRegistry.ids():
		check(int(cast_rites.get(rite, 0)) >= 1, "%s was cast at least once" % rite)
	g.queue_free()
	await ticks(5)
	await process_frame
	check_effects_dropped()
	rec.scan_all()
	var secs_run := float(Time.get_ticks_msec() - t0_msec) / 1000.0
	for line in warm_log:
		print("INFO warm_coverage: " + String(line))
	print("INFO warm_coverage: %d waves, %d enemy blows on the hero, %d rites cast" % [waves_seen, blows_taken, cast_rites.size()])
	print("INFO warm_coverage: %d games, %d materials warmed, %d seen in play (%d nodes looked at in %d tree scans)" % [scenes, rec.warmed.size(), rec.played.size(), rec.checked, rec.scans])
	for line in refused:
		printerr("REFUSED " + String(line))
	if "--list" in OS.get_cmdline_user_args():   # every signature: where it was first warmed and how often play showed it
		var all: Array = rec.warmed.keys()
		for sig: String in rec.played:
			if not rec.warmed.has(sig):
				all.append(sig)
		all.sort()
		for sig: String in all:
			print("LIST %5d in play, warmed by %s: %s" % [int(rec.played.get(sig, 0)), rec.warmed.get(sig, "nothing"), sig])
	var gaps: Array = rec.missing.keys()
	gaps.sort()
	for sig: String in gaps:
		var e: Dictionary = rec.missing[sig]
		var cx: Dictionary = e["ctx"]
		printerr("MISSING from the warm-up: %s\n    node %s (%s)  script %s  scene %s\n    in play: %s / %s / %s" % [sig, e["node"], e["class"], e["script"] if e["script"] != "" else "-", e["scene"] if e["scene"] != "" else "-",
			cx["disc"] if cx["disc"] != "" else "-", cx["rite"] if cx["rite"] != "" else "-", cx["step"]])
	check(gaps.is_empty(), "every material of play was drawn while warming (%d missing)" % gaps.size())
	print("INFO warm_coverage: %d checks in %.0f s" % [checks, secs_run])
	check(errlog.errors.is_empty(), "ZERO script errors or engine errors in the log (%d)" % errlog.errors.size())
	for e in errlog.errors:
		printerr("ERROR LOG: " + e)
	if fails == 0:
		print("PASS warm_coverage (%d checks)" % checks)
		quit(0)
	else:
		printerr("FAIL warm_coverage: %d of %d checks failed" % [fails, checks])
		quit(1)
