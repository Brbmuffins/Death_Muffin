extends SceneTree
## The crowd's presentation (client/crowd/README.md "Driving the crowd", native/README.md "Drawing") against the view layer of today's game
## (archive/old-game:godot/game/dm_entity_views.gd, dm_creature.gd, dm_animator.gd), proven headless: DmCrowd takes plain rows (or the core's tables), advances a view
## per creature and writes the MultiMesh buffers, which `buffer()` hands back exactly as they would be uploaded.
## Mirrors of today's pure helpers sit below, line by line (turn_toward, smooth_speed, knock_impulse, step_knock, settle_depth, strike_timing, the
## stride plan, the body layer's pose); the C++ is held against them on random inputs and on the views' own clocks. Then: the clip of every state
## and the walk/run switch, the blends and the packing, the hit flash, the knock, the death into a corpse, the rise, the hover, the Gargoyle's dive, the shadow group,
## the level-of-detail split, interpolation, a Full Party crowd driven by a real DmCore (events not consumed, rows equal for a guest, no growth)
## and the time draw() takes (INFO only); the crowd's cost (README "Crowd cost"): bodies outside the camera's view not written (against the engine's own frustum planes, the drawn
## range packed, a caster kept while its shadow falls in), the animation bands (poses worked out per second per band, the same bytes near the hero), the shadow counters;
## and the alpha path (README "The alpha path"): a sinking body and a shrouded one drawn in the model's fade group at today's opacity, nothing else about their rows changed.
## Gets the models it needs into a scratch folder (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd).
## Run: godot --headless --path client --script res://tests/crowd_view.gd

const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://crowd_view_test"
const SLUGS := ["grave_robber", "bone_hound", "skeleton_thrall"]
const DT := 1.0 / 60.0
const CAM := Vector3(0, 22, 14)
const EV_DAMAGED := 3
const RISING := 0
const IDLE := 1
const CHASE := 2
const ATTACK := 3
const HURT := 4
const DEAD := 6
const BURROW := 8
const ERUPT := 9
const DIG := 10
const EMERGE := 11
const T_RISING := 0
const T_IDLE := 1
const T_MOVE := 2
const T_ATTACK := 3
const T_DEAD := 4
const F_ELITE := 1
const F_CASTER := 2
const F_INERT := 4
const F_MIST := 8
const F_FLYER := 16
const F_DIVING := 32
const F_GROUNDED := 64
const F_WOBBLE := 128
const F_SHROUDED := 256
const ENEMY := 0
const THRALL := 1
const ROBBER := 0   ## model slots, in SLUGS order
const HOUND := 1
const SKELETON := 2
# DmEntityViews / DmCreature / DmAnimator constants, as in the files they come from
const ENEMY_TURN_RATE := 9.0
const KNOCK_K := 140.0
const KNOCK_MAX := 0.6
const SETTLE_DEPTH := 0.06
const CHAMPION_SCALE := 1.35   ## the champion thrall's scale this test gives the view (an option of `setup`)

var fails := 0
var checks := 0
class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var errlog := ErrorLog.new()
var data_dir: String   ## this project's data/ (res://): the same files the game loads
var cam: Camera3D      ## the game's camera, for the crowd cost sections
var live_assets: String   ## where the models' sources are: this project's assets/
var rows_path: String     ## the model rows the baker reads (game/view_models.json)
var data := {}      ## model slug -> CrowdVatData
var keep := []      ## MultiMeshes the RIDs belong to
var lods := []      ## levels of detail per model slot
var clock_ms := 0.0 ## what the views' hover clock reads: the sum of the frame times drawn since the crowd was made


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL crowd_view: " + what)


func near(a: float, b: float, tol: float = 1e-6) -> bool:
	return absf(a - b) <= tol * maxf(1.0, maxf(absf(a), absf(b)))


# ---------------------------------------------------------------------------------------------------------------------- mirrors of today's code

## DmEntityViews.turn_toward
static func turn_toward(cur: float, target: float, dt: float, rate: float, max_rate: float = INF) -> float:
	var d := target - cur
	while d > PI:
		d -= TAU
	while d < -PI:
		d += TAU
	var lim := max_rate * dt
	return cur + maxf(-lim, minf(lim, d * minf(1.0, dt * rate)))


## DmEntityViews.smooth_speed
static func smooth_speed(prev: float, sample: float, dt: float, tau: float = 0.12) -> float:
	return prev + (sample - prev) * (1.0 - exp(-maxf(0.0, dt) / tau))


## DmEntityViews.knock_impulse
static func knock_impulse(frac: float, mass: float, dx: float, dz: float) -> Vector2:
	var l := sqrt(dx * dx + dz * dz)
	if l == 0.0:
		l = 1.0
	var push := pow(clampf(frac, 0.0, 1.0), 0.6) * 16.0 / maxf(0.6, mass)
	var v := minf(push, 20.0)
	return Vector2(dx / l * v, dz / l * v)


## DmEntityViews.step_knock
static func step_knock(k: Dictionary, dt: float) -> void:
	var n := maxi(1, ceili(dt / (1.0 / 120.0)))
	var h := dt / n
	var c := 2.0 * sqrt(KNOCK_K)
	for i in n:
		k.vx += (-KNOCK_K * k.x - c * k.vx) * h
		k.vz += (-KNOCK_K * k.z - c * k.vz) * h
		k.x += k.vx * h
		k.z += k.vz * h
	var d := sqrt(k.x * k.x + k.z * k.z)
	if d > KNOCK_MAX:
		k.x *= KNOCK_MAX / d
		k.z *= KNOCK_MAX / d
	if d < 1e-3 and sqrt(k.vx * k.vx + k.vz * k.vz) < 0.02:
		k.x = 0.0
		k.z = 0.0
		k.vx = 0.0
		k.vz = 0.0


## DmEntityViews.settle_depth
static func settle_depth(t: float, depth: float, dur: float = 0.45) -> float:
	var k := clampf(t / dur, 0.0, 1.0)
	return depth * k * k * (3.0 - 2.0 * k)


## DmAnimator.strike_timing
static func strike_timing(duration: float, impact: float, impact_in: float, follow: float) -> Dictionary:
	var peak := minf(duration, impact if impact >= 0.0 else duration * 0.35)
	var lead := maxf(0.08, impact_in)
	var speed := minf(2.2, maxf(0.7, peak / lead))
	var start_at := maxf(0.0, peak - lead * speed)
	return {"speed": speed, "startAt": start_at, "endAt": minf(duration, peak + follow * speed)}


## DmAnimator.walk_cap and plan_into: which loop and how fast so the planted feet match `ground`.
static func walk_cap(h: float) -> float:
	return minf(4.5, maxf(1.6, 3.0 * sqrt(2.0 / maxf(0.1, h))))


static func plan_loco(row: Dictionary, h: float, ground: float, hr: bool, was_run_now: bool) -> Dictionary:
	var walk_u: float = float(row.get("walk", 0.7)) * h
	var run_u: float = float(row.get("run", 0.0)) * h if hr else 0.0
	var run: bool = run_u > 0.0 and ground > walk_u * (1.6 if was_run_now else 2.0)
	var st: float = run_u if run else walk_u
	var mx: float = 2.4 if run else walk_cap(h)
	return {"clip": "run" if run else "walk", "timeScale": minf(mx, maxf(0.4, ground / st))}


## DmCreature._smooth
static func smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


## DmCreature._fx_step: the pose of the model node (pitch, roll, squash, forward offset) from the effect timers `i` (a view_info) holds.
static func fx_pose(i: Dictionary) -> Vector4:
	var pitch := 0.0
	var roll := 0.0
	var sq := 0.0
	var zo := 0.0
	if i.kick_t >= 0.0:
		var u: float = i.kick_t / 0.3
		var f := smooth(u / 0.16) if u < 0.16 else smooth(1.0 - (u - 0.16) / 0.84)
		pitch -= 0.11 * i.kick_amp * f
		roll += 0.04 * i.kick_amp * i.kick_side * f
		sq += 0.05 * i.kick_amp * f
	if i.lunge_t >= 0.0:
		var lead: float = i.lunge_in
		var k: float
		if i.lunge_t < lead * 0.65:
			k = -0.4 * smooth(i.lunge_t / (lead * 0.65))
		elif i.lunge_t < lead:
			k = lerpf(-0.4, 1.0, smooth((i.lunge_t - lead * 0.65) / (lead * 0.35)))
		else:
			k = 1.0 - smooth((i.lunge_t - lead) / 0.3)
		zo += i.lunge_len * k
		pitch += i.lunge_pitch * k
	if i.rise_k < 1.0:
		var r: float = 1.0 - i.rise_k
		pitch += 0.5 * r * r
	return Vector4(pitch, roll, sq, zo)


# ---------------------------------------------------------------------------------------------------------------------- fixtures

## A DmCrowd with the three baked models (robber 2 levels of detail, hound 1, skeleton 3), levels starting at 30 m and 60 m, each with its fade groups. `o`: "no_fade" (models with no
## alpha groups, as a caller of the older add_model had), "spectral" (slugs drawn as ghosts: their plain group is the see-through one), "bare" (slugs given
## only their idle, walk and run roles: a model with no strike, flinch or death clip, as the unrigged ones are).
func new_crowd(o := {}) -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCrowd")
	clock_ms = 0.0
	if lods.is_empty():
		for slug in SLUGS:
			lods.append(data[slug].meshes.size())
	for slug in SLUGS:
		var plain: Array = []
		var shadow: Array = []
		var fade: Array = []
		for lod in data[slug].meshes.size():
			var a: MultiMesh = data[slug].make_multimesh(0, lod)
			var b: MultiMesh = data[slug].make_multimesh(0, lod)
			var f: MultiMesh = data[slug].make_multimesh(0, lod)
			keep.append(a)
			keep.append(b)
			keep.append(f)
			plain.append(a.get_rid())
			shadow.append(b.get_rid())
			fade.append(f.get_rid())
		var cd: Dictionary = data[slug].crowd_data()
		cd["spectral"] = (o.get("spectral", []) as Array).has(slug)
		if (o.get("bare", []) as Array).has(slug):
			var loops := {}
			for role in ["idle", "walk", "run"]:
				if cd.roles.has(role):
					loops[role] = cd.roles[role]
			cd["roles"] = loops
		c.add_model(slug, cd, plain, shadow, PackedFloat32Array([30.0, 60.0]), [] if bool(o.get("no_fade", false)) else fade)
	return c


func body(id: int, kind: int, model: int, state: int, x: float, z: float, o := {}) -> Dictionary:
	var d := {"id": id, "kind": kind, "model": model, "state": state, "x": x, "z": z, "yaw": 0.0, "speed": 0.0, "state_t": 0.0, "action_s": 0.0, "scale": 1.0,
		"hover": 0.0, "flags": 0, "swing": 0, "def": 0, "tint": Color.WHITE}
	d.merge(o, true)
	return d


## One tick's rows into the crowd (sync_rows' layout: native/README.md).
func feed(c: RefCounted, bodies: Array, hits := [], corpses := []) -> void:
	var bi := PackedInt32Array()
	var bf := PackedFloat32Array()
	for b in bodies:
		bi.append_array(PackedInt32Array([b.id, b.kind, b.model, b.state, b.flags, b.swing, b.def, int(b.get("glow", 0))]))
		bf.append_array(PackedFloat32Array([b.x, b.z, b.yaw, b.speed, b.state_t, b.action_s, b.scale, b.hover, b.tint.r, b.tint.g, b.tint.b]))
	var hf := PackedFloat32Array()
	for h in hits:
		hf.append_array(PackedFloat32Array([h[0], h[1], h[2], h[3]]))
	var ci := PackedInt32Array()
	var cf := PackedFloat32Array()
	for k in corpses:
		ci.append_array(PackedInt32Array([k.id, k.model, k.def, int(k.get("glow", 0))]))
		cf.append_array(PackedFloat32Array([k.x, k.z, k.facing, k.scale, k.tint.r, k.tint.g, k.tint.b]))
	c.sync_rows(bi, bf, hf, ci, cf)


func draw(c: RefCounted, n: int, dt: float = DT, alpha: float = 0.0) -> void:
	for i in n:
		c.draw(dt, alpha, CAM)
		clock_ms += dt * 1000.0


## Every instance in every group (plain, shadow, fade), decoded: {model, lod, shadow, fade, xf, color, custom}.
func rows(c: RefCounted) -> Array:
	var out := []
	for m in lods.size():
		for l in lods[m]:
			for g in [[false, false], [true, false], [false, true]]:
				var buf: PackedFloat32Array = c.buffer(m, l, g[0], g[1])
				check(buf.size() == c.instance_count(m, l, g[0], g[1]) * 20, "buffer(%d, %d, %s, %s) holds count x 20 floats" % [m, l, g[0], g[1]])
				for i in buf.size() / 20:
					var o := i * 20
					var rows_ := Basis(Vector3(buf[o], buf[o + 1], buf[o + 2]), Vector3(buf[o + 4], buf[o + 5], buf[o + 6]), Vector3(buf[o + 8], buf[o + 9], buf[o + 10])).transposed()
					out.append({"model": m, "lod": l, "shadow": g[0], "fade": g[1], "xf": Transform3D(rows_, Vector3(buf[o + 3], buf[o + 7], buf[o + 11])),
						"color": Color(buf[o + 12], buf[o + 13], buf[o + 14], buf[o + 15]), "custom": Color(buf[o + 16], buf[o + 17], buf[o + 18], buf[o + 19])})
	return out


## The instance drawn at ground position (x, z).
func row_at(c: RefCounted, x: float, z: float) -> Dictionary:
	var best := {}
	var best_d := 0.05
	for r in rows(c):
		var d := Vector2(r.xf.origin.x - x, r.xf.origin.z - z).length()
		if d < best_d:
			best_d = d
			best = r
	return best


## The instance of creature `id`, found by where its view draws it.
func row_of(c: RefCounted, id: int) -> Dictionary:
	var p := Vector3(c.view_info(id).pos)
	return row_at(c, p.x, p.z)


func clip_len(slug: String, clip: String) -> float:
	return data[slug].clip_source_length[data[slug].clip_index(clip)]


func clip_impact(slug: String, clip: String) -> float:
	return data[slug].clip_impact[data[slug].clip_index(clip)]


# ---------------------------------------------------------------------------------------------------------------------- the tests

func _initialize() -> void:
	await process_frame   # the scene tree is live from the first frame; animation players need it
	OS.add_logger(errlog)
	data_dir = "res://"
	DirAccess.make_dir_recursive_absolute(OUT)
	live_assets = ProjectSettings.globalize_path("res://assets")
	rows_path = ProjectSettings.globalize_path("res://game/view_models.json")
	for slug in SLUGS:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"assets_dir": live_assets, "rows_path": rows_path})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
		data[slug] = ResourceLoader.load(OUT.path_join(slug).path_join("model.tres"), "", ResourceLoader.CACHE_MODE_REPLACE)
	make_camera()
	baked_data()
	pure_helpers()
	turning_and_legs()
	clips_by_state()
	walk_run()
	blends_and_packing()
	wobble()
	hits_and_flash()
	knockback()
	rise_hover_and_pose()
	the_dive()
	death_and_corpses()
	fades()
	body_only()
	shadows_and_lod()
	interpolation()
	culling_and_packing()
	shadow_reach()
	animation_bands()
	await full_party()
	await armed_variants()
	kit_looks()
	cam.get_parent().queue_free()
	_remove_dir(OUT)
	check(errlog.errors.is_empty(), "zero script errors or engine errors in the log (%d: %s)" % [errlog.errors.size(), "; ".join(errlog.errors.slice(0, 3))])
	print("INFO crowd_view: %d checks" % checks)
	if fails > 0:
		printerr("FAIL crowd_view: %d of %d checks failed" % [fails, checks])
		quit(1)
		return
	print("PASS crowd_view")
	quit(0)


## What the baker now writes for the views: the whole source length, the impact, the landing, the stride.
func baked_data() -> void:
	var rows_json: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(rows_path))
	for slug in SLUGS:
		var d: CrowdVatData = data[slug]
		var row: Dictionary = rows_json[slug]
		var n := d.clip_names.size()
		check(d.clip_source_length.size() == n and d.clip_impact.size() == n and d.clip_landing.size() == n, "%s: a length, an impact and a landing per clip" % slug)
		var stride: Variant = row.get("stride")
		check(near(d.stride_walk, float(stride.walk) if stride is Dictionary else 0.0, 1e-9) and near(d.stride_run, float(stride.run) if stride is Dictionary else 0.0, 1e-9), "%s: the model row's stride" % slug)
		var cd := d.crowd_data()
		check(cd.clip_loop.size() == n and cd.clip_names == d.clip_names and cd.roles == d.roles, "%s: crowd_data() carries the clip table" % slug)
		for c in n:
			var nm: String = d.clip_names[c]
			var timing: Variant = row.timings.get(nm)
			check(near(d.clip_impact[c], float(timing[1]) if timing is Array else -1.0, 1e-6), "%s/%s: impact from the row's timings" % [slug, nm])
			check(d.clip_source_length[c] >= d.clip_seconds[c] - 1e-4, "%s/%s: the source clip is at least as long as what is baked" % [slug, nm])
			if nm.rstrip("0123456789") == "death":
				check(d.clip_landing[c] > 0.0 and d.clip_landing[c] <= d.clip_source_length[c], "%s/%s: a death clip lands within its length (%.2f s)" % [slug, nm, d.clip_landing[c]])
			else:
				check(d.clip_landing[c] == -1.0, "%s/%s: only death clips have a landing" % [slug, nm])


func pure_helpers() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var c: RefCounted = ClassDB.instantiate("DmCrowd")
	var worst := 0.0
	for i in 400:
		var cur := rng.randf_range(-12.0, 12.0)
		var target := rng.randf_range(-12.0, 12.0)
		var dt: float = [1.0 / 60.0, 1.0 / 144.0, 0.05, 0.25][i % 4]
		worst = maxf(worst, absf(c.turn_toward(cur, target, dt, 10.0, ENEMY_TURN_RATE) - turn_toward(cur, target, dt, 10.0, ENEMY_TURN_RATE)))
		var a := rng.randf() * 6.0
		var b := rng.randf() * 6.0
		check(near(c.smooth_speed(a, b, dt, 0.18), smooth_speed(a, b, dt, 0.18), 1e-12), "smooth_speed(%f, %f, %f)" % [a, b, dt])
		var frac := rng.randf_range(-0.2, 1.4)
		var mass := rng.randf_range(0.1, 3.0)
		var dx := rng.randf_range(-9.0, 9.0) if i % 17 else 0.0
		var dz := rng.randf_range(-9.0, 9.0) if i % 17 else 0.0
		var ki: Vector2 = c.knock_impulse(frac, mass, dx, dz)
		var kw := knock_impulse(frac, mass, dx, dz)
		check(ki.distance_to(kw) < 1e-5, "knock_impulse(%f, %f, %f, %f) = %s, today %s" % [frac, mass, dx, dz, ki, kw])
		var t := rng.randf_range(-0.2, 0.8)
		check(near(c.settle_depth(t, 0.06), settle_depth(t, 0.06), 1e-12), "settle_depth(%f)" % t)
		var dur := rng.randf_range(0.3, 6.0)
		var imp := rng.randf_range(-1.0, dur)
		var imp_in := rng.randf_range(0.0, 1.5)
		var st: Dictionary = c.strike_timing(dur, imp, imp_in, 0.3)
		var sw := strike_timing(dur, imp, imp_in, 0.3)
		check(near(st.speed, sw.speed, 1e-12) and near(st.startAt, sw.startAt, 1e-12) and near(st.endAt, sw.endAt, 1e-12), "strike_timing(%f, %f, %f)" % [dur, imp, imp_in])
	check(worst < 1e-12, "turn_toward matches today's on 400 random turns (worst %s)" % worst)
	# the spring: from random states, at frame times from 144 Hz to a slow 4 fps frame, 90 steps each
	for i in 40:
		var dt: float = [1.0 / 144.0, 1.0 / 60.0, 0.05, 0.25][i % 4]
		var s := Vector4(rng.randf_range(-0.6, 0.6), rng.randf_range(-0.6, 0.6), rng.randf_range(-9.0, 9.0), rng.randf_range(-9.0, 9.0))
		var kd := {"x": s.x, "z": s.y, "vx": s.z, "vz": s.w}
		var ks := PackedFloat64Array([s.x, s.y, s.z, s.w])
		for step in 90:
			step_knock(kd, dt)
			ks = c.step_knock(ks, dt)
		check(absf(ks[0] - kd.x) + absf(ks[1] - kd.z) + absf(ks[2] - kd.vx) + absf(ks[3] - kd.vz) < 1e-9, "step_knock matches today's over 90 steps at dt %f" % dt)


func info(c: RefCounted, id: int) -> Dictionary:
	return c.view_info(id)


## The displayed yaw turns toward the sim's at ENEMY_TURN_RATE; the smoothed ground speed follows today's smooth_speed.
func turning_and_legs() -> void:
	for dt in [DT, 1.0 / 144.0, 0.05]:
		var c := new_crowd()
		feed(c, [body(1, ENEMY, ROBBER, IDLE, 0, 0, {"yaw": 3.0})])
		feed(c, [body(1, ENEMY, ROBBER, IDLE, 0, 0, {"yaw": -3.0})])   # the shortest way round is across pi
		var yaw := 3.0
		var worst := 0.0
		var first_yaw := 0.0
		for f in 90:
			c.draw(dt, 1.0, CAM)
			yaw = turn_toward(yaw, -3.0, dt, 10.0, ENEMY_TURN_RATE)
			worst = maxf(worst, absf(info(c, 1).yaw - yaw))
			if f == 0:
				first_yaw = info(c, 1).yaw
		check(worst < 1e-6, "dt %.4f: the displayed yaw turns toward the sim's like turn_toward (worst %s)" % [dt, worst])
		check(first_yaw > 3.0 and absf(wrapf(info(c, 1).yaw + 3.0, -PI, PI)) < 1e-3, "dt %.4f: it went across pi, the short way, and arrived (%.3f)" % [dt, info(c, 1).yaw])
		var row := row_at(c, 0, 0)
		var shown := Basis(Vector3.UP, info(c, 1).yaw)
		check(not row.is_empty() and row.xf.basis.is_equal_approx(shown), "dt %.4f: the instance faces the displayed yaw" % dt)
	# a unit turn takes about a third of a second at 9 rad/s
	var c2 := new_crowd()
	feed(c2, [body(1, ENEMY, ROBBER, IDLE, 0, 0)])
	feed(c2, [body(1, ENEMY, ROBBER, IDLE, 0, 0, {"yaw": 1.0})])
	draw(c2, 1, DT, 1.0)
	check(near(info(c2, 1).yaw, turn_toward(0.0, 1.0, DT, 10.0, ENEMY_TURN_RATE), 1e-6), "one frame of a turn")
	# the legs: the pace the sim moves the body at from the first frame, then today's smoothing
	var c := new_crowd()
	feed(c, [body(2, ENEMY, ROBBER, IDLE, 0, 0)])
	draw(c, 3)
	check(info(c, 2).gs == 0.0 and info(c, 2).loop == "idle", "standing: speed 0, idle loop")
	feed(c, [body(2, ENEMY, ROBBER, CHASE, 0, 0, {"speed": 3.0})])
	draw(c, 1)
	check(near(info(c, 2).gs, 3.0, 1e-9) and info(c, 2).loop in ["walk", "run"], "walking starts at the pace the sim moves (%f)" % info(c, 2).gs)
	var gs := 3.0
	var worst := 0.0
	feed(c, [body(2, ENEMY, ROBBER, CHASE, 0, 0, {"speed": 1.0})])
	for f in 40:
		c.draw(DT, 0.0, CAM)
		gs = smooth_speed(gs, 1.0, DT, 0.18)
		worst = maxf(worst, absf(info(c, 2).gs - gs))
	check(worst < 1e-9, "the smoothed ground speed follows smooth_speed with tau 0.18 (worst %s)" % worst)
	feed(c, [body(2, ENEMY, ROBBER, CHASE, 0, 0, {"speed": 0.1})])   # under 0.2 m/s the legs stop
	draw(c, 2)
	check(info(c, 2).loop == "idle", "under 0.2 m/s the body idles")


## The clip of every state, with the timing today's code gives it.
func clips_by_state() -> void:
	var h := 1.7   # the robber, scale 1
	# IDLE: the loop; RISING: the loop too
	var c := new_crowd()
	feed(c, [body(1, ENEMY, ROBBER, IDLE, 0, 0), body(2, ENEMY, ROBBER, RISING, 5, 0)])
	draw(c, 2)
	check(info(c, 1).clip == "idle" and info(c, 1).one_shot == "" and near(info(c, 1).speed, info(c, 1).idle_k, 1e-9), "IDLE: the idle loop at its own rate (%.3f)" % info(c, 1).idle_k)
	check(info(c, 1).idle_k >= 0.92 and info(c, 1).idle_k <= 1.08 and info(c, 1).idle_k != info(c, 2).idle_k, "bodies idle at their own rate, +-8%")
	check(info(c, 2).clip == "idle", "RISING: the idle loop")
	# ATTACK: the strike, its impact on the end of the wind-up
	feed(c, [body(1, ENEMY, ROBBER, ATTACK, 0, 0, {"action_s": 0.42})])
	var i := info(c, 1)
	check(i.one_shot in ["attack", "attack2"], "ATTACK plays an attack clip (%s)" % i.one_shot)
	var t := strike_timing(clip_len("grave_robber", i.one_shot), clip_impact("grave_robber", i.one_shot), 0.42, 0.3)
	check(near(i.speed, t.speed, 1e-6) and near(i.time, t.startAt, 1e-6) and near(i.one_end, t.endAt, 1e-6), "ATTACK: the swing's impact frame lands when the wind-up ends (speed %.3f from %.3f to %.3f)" % [i.speed, i.time, i.one_end])
	check(i.prev_clip == "idle" and near(i.blend, 1.0, 1e-9), "ATTACK blends from the loop over a fraction of the wind-up")
	check(i.lunge_t == 0.0 and near(i.lunge_in, 0.42, 1e-6) and near(i.lunge_len, h * 0.07, 1e-6) and near(i.lunge_pitch, 0.07, 1e-9), "ATTACK: the body lunges with the clip's impact")
	var fade := clampf(0.42 * 0.3, 0.06, 0.14)
	draw(c, 1)
	check(near(info(c, 1).blend, 1.0 - DT / fade, 1e-6), "the strike blends in over %.3f s" % fade)
	# the swing ends at its end time and hands back to the loop over 0.2 s
	var frames := 0
	while info(c, 1).one_shot != "" and frames < 600:
		draw(c, 1)
		frames += 1
	check(frames > 5 and frames < 100, "the swing plays out (%d frames)" % frames)
	check(info(c, 1).clip == "idle" and info(c, 1).prev_clip.begins_with("attack") and near(info(c, 1).blend, 1.0, 1e-9), "and returns to the loop, fading the swing out over 0.2 s")
	draw(c, 14)
	check(info(c, 1).prev_clip == "" and info(c, 1).clip == "idle", "the return fade is over in 0.2 s")
	# a caster swings with the cast clip, which the robber resolves to its attack (DmCreature.FALLBACK)
	feed(c, [body(3, ENEMY, ROBBER, IDLE, 8, 0, {"flags": F_CASTER})])
	feed(c, [body(3, ENEMY, ROBBER, ATTACK, 8, 0, {"flags": F_CASTER, "action_s": 1.1})])
	check(info(c, 3).one_shot.begins_with("attack") and near(info(c, 3).lunge_len, 0.0) and near(info(c, 3).lunge_pitch, 0.05, 1e-9), "a caster's cast only leans")
	# HURT: the flinch, the first half-second of a hurt clip at 1.35x
	feed(c, [body(4, ENEMY, ROBBER, CHASE, 12, 0)])
	feed(c, [body(4, ENEMY, ROBBER, HURT, 12, 0)])
	i = info(c, 4)
	check(i.one_shot.begins_with("hurt") and near(i.speed, 1.35, 1e-9) and near(i.one_end, minf(clip_len("grave_robber", i.one_shot), 0.5 * 1.35), 1e-6), "HURT: a flinch (%s, to %.3f s)" % [i.one_shot, i.one_end])
	check(near(i.blend, 1.0, 1e-9) and i.kick_t == 0.0 and near(i.kick_amp, 0.85, 1e-9), "the flinch recoils the body at 0.85")
	# a second HURT while one plays, and a swing, do not restart it
	draw(c, 2)
	var t0: float = info(c, 4).time
	feed(c, [body(4, ENEMY, ROBBER, CHASE, 12, 0)])
	feed(c, [body(4, ENEMY, ROBBER, HURT, 12, 0)])
	check(info(c, 4).time >= t0, "a flinch that is already playing is not restarted")
	# DEAD: the death clip
	feed(c, [body(5, ENEMY, ROBBER, CHASE, 16, 0)])
	feed(c, [body(5, ENEMY, ROBBER, DEAD, 16, 0)])
	i = info(c, 5)
	check(i.mode == "dying" and i.death_clip in ["death", "death2"] and i.clip == i.death_clip and i.speed == 1.0 and near(i.blend, 1.0, 1e-9), "DEAD: a dying body plays a death clip (%s)" % i.death_clip)
	# BURROW / ERUPT: underground, not drawn; EMERGE: a swing; DIG: the dig clip (the skeleton has one; the robber's role resolves to its attack)
	feed(c, [body(6, ENEMY, ROBBER, BURROW, 20, 0), body(7, ENEMY, ROBBER, ERUPT, 24, 0), body(8, ENEMY, ROBBER, CHASE, 28, 0)])
	draw(c, 2)
	check(info(c, 6).hidden and info(c, 7).hidden and not info(c, 8).hidden and row_at(c, 20, 0).is_empty() and row_at(c, 24, 0).is_empty() and not row_at(c, 28, 0).is_empty(), "BURROW and ERUPT are underground: not drawn")
	feed(c, [body(7, ENEMY, ROBBER, EMERGE, 24, 0, {"action_s": 0.3})])
	draw(c, 1)
	check(not info(c, 7).hidden and info(c, 7).one_shot.begins_with("attack") and not row_at(c, 24, 0).is_empty(), "EMERGE surfaces and swings for the recovery")
	feed(c, [body(9, ENEMY, SKELETON, IDLE, 32, 0)])
	feed(c, [body(9, ENEMY, SKELETON, DIG, 32, 0, {"action_s": 0.8})])
	i = info(c, 9)
	check(i.one_shot == "dig" and near(i.speed, clip_len("skeleton_thrall", "dig") / 0.8, 1e-6) and i.time == 0.0, "DIG: the dig clip over the dig time (%.3f x)" % i.speed)
	# a body that dropped out of the rows (an area clear) sinks away
	var fading0: int = c.stats().fading
	feed(c, [])
	check(c.stats().fading > fading0 and c.stats().live == 0, "bodies that vanish from the rows without dying sink away")
	# thralls: RISING idles, a swing is the counter changing, DEAD dies
	feed(c, [body(20, THRALL, SKELETON, T_IDLE, 0, 5, {"swing": 3})])
	draw(c, 2)
	check(info(c, 20).clip == "idle", "a thrall idles")
	feed(c, [body(20, THRALL, SKELETON, T_IDLE, 0, 5, {"swing": 4, "action_s": 0.12})])
	i = info(c, 20)
	t = strike_timing(clip_len("skeleton_thrall", i.one_shot), clip_impact("skeleton_thrall", i.one_shot), 0.12, 0.3)
	check(i.one_shot in ["attack", "attack2"] and near(i.speed, t.speed, 1e-6) and near(i.time, t.startAt, 1e-6), "a thrall's swing opens the clip just before its impact (counter 3 -> 4)")
	feed(c, [body(20, THRALL, SKELETON, T_ATTACK, 0, 5, {"swing": 4})])
	check(info(c, 20).one_shot != "", "the swing is not cut by the state")
	feed(c, [body(20, THRALL, SKELETON, T_DEAD, 0, 5, {"swing": 4})])
	check(info(c, 20).mode == "dying" and info(c, 20).death_clip != "", "a fallen thrall plays its death")
	# bodies that stay where the rows put them at first sight: late joiners
	feed(c, [body(21, ENEMY, ROBBER, DEAD, 3, 3)])
	check(info(c, 21).mode == "dying" and near(info(c, 21).time, data["grave_robber"].clip_seconds[data["grave_robber"].clip_index(info(c, 21).death_clip)], 1e-6), "seen dead at first sight: the death clip is already over")


## The walk and the run: today's stride plan, with its hysteresis, and the step cycle carried across.
func walk_run() -> void:
	var c := new_crowd()
	feed(c, [body(1, ENEMY, ROBBER, IDLE, 0, 0)])
	var row: Dictionary = {"walk": data["grave_robber"].stride_walk, "run": data["grave_robber"].stride_run}
	var h := 1.7
	var was_run := false
	var wrong := 0
	var phases_ok := true
	var switches := 0
	# raw ground speeds the sim reports, in turn; the plan follows the smoothed speed
	for raw in [1.0, 1.0, 3.0, 3.0, 2.2, 2.2, 1.8, 1.8, 2.2, 2.2, 5.0, 0.0]:
		feed(c, [body(1, ENEMY, ROBBER, CHASE, 0, 0, {"speed": raw})])
		for f in 50:
			var before: Dictionary = info(c, 1)
			c.draw(DT, 0.0, CAM)
			var after: Dictionary = info(c, 1)
			if raw == 0.0:
				continue
			var plan := plan_loco(row, h, after.gs, true, was_run)
			was_run = plan.clip == "run"
			if after.clip != plan.clip or not near(after.speed, plan.timeScale, 1e-6):
				wrong += 1
			if before.clip != after.clip and before.clip in ["walk", "run"] and after.clip in ["walk", "run"]:
				switches += 1
				var len_old: float = data["grave_robber"].clip_seconds[data["grave_robber"].clip_index(before.clip)]
				var len_new: float = data["grave_robber"].clip_seconds[data["grave_robber"].clip_index(after.clip)]
				var want := fmod(before.time / len_old * len_new + DT * after.speed, len_new)
				if not near(after.time, want, 1e-4):
					phases_ok = false
	check(wrong == 0, "walk or run at the stride-matched speed on every frame (%d wrong)" % wrong)
	check(switches >= 3 and phases_ok, "walk and run swap in the same phase of the step cycle (%d swaps)" % switches)
	# 2.2 m/s: walks when coming from idle, still runs when coming from a run (1.6x vs 2x of the walking pace)
	var c2 := new_crowd()
	feed(c2, [body(1, ENEMY, ROBBER, CHASE, 0, 0, {"speed": 2.2})])
	draw(c2, 40)
	check(info(c2, 1).clip == "walk", "2.2 m/s from a standstill is a walk")
	feed(c2, [body(1, ENEMY, ROBBER, CHASE, 0, 0, {"speed": 3.4})])
	draw(c2, 60)
	check(info(c2, 1).clip == "run", "3.4 m/s is a run")
	feed(c2, [body(1, ENEMY, ROBBER, CHASE, 0, 0, {"speed": 2.2})])
	draw(c2, 120)
	check(info(c2, 1).clip == "run", "2.2 m/s from a run stays a run")
	feed(c2, [body(1, ENEMY, ROBBER, CHASE, 0, 0, {"speed": 1.5})])
	draw(c2, 120)
	check(info(c2, 1).clip == "walk", "1.5 m/s is a walk again")
	# a bigger body takes longer strides: the elite's scale is in the plan
	var c3 := new_crowd()
	feed(c3, [body(1, ENEMY, ROBBER, CHASE, 0, 0, {"speed": 2.0, "scale": 1.35}), body(2, ENEMY, ROBBER, CHASE, 5, 0, {"speed": 2.0})])
	draw(c3, 2)
	check(near(info(c3, 1).speed, plan_loco(row, 1.7 * 1.35, 2.0, true, false).timeScale, 1e-6) and info(c3, 1).speed < info(c3, 2).speed, "an elite's stride is longer: its legs turn slower at the same pace")
	# a thrall walks at the same plan (height x scale)
	var skel: Dictionary = {"walk": data["skeleton_thrall"].stride_walk, "run": data["skeleton_thrall"].stride_run}
	var c4 := new_crowd()
	feed(c4, [body(1, THRALL, SKELETON, T_MOVE, 0, 0, {"speed": 3.0, "scale": 1.1})])
	draw(c4, 3)
	check(near(info(c4, 1).speed, plan_loco(skel, 1.75 * 1.1, 3.0, true, false).timeScale, 1e-6), "a thrall's plan uses its look's scale")


## A Mire Leech slithers (DmEntityViews._fen_dead): the root rolls 0.12 w about Z and the scale is (1 + 0.12 w, 1 - 0.09 w, 1 + 0.1 w) of its own, w = sin(t / 85 ms + id * 1.7), a quarter as
## strong standing still; a body without the flag is drawn plain.
func wobble() -> void:
	for moving in [false, true]:
		var c := new_crowd()
		var state := CHASE if moving else IDLE
		var spd := 3.0 if moving else 0.0
		feed(c, [body(1, ENEMY, ROBBER, state, 1.0, 2.0, {"flags": F_WOBBLE, "yaw": 0.7, "scale": 1.2, "speed": spd}), body(2, ENEMY, ROBBER, state, 4.0, 2.0, {"yaw": 0.7, "scale": 1.2, "speed": spd})])
		draw(c, 30)
		var worst := 0.0
		var worst_plain := 0.0
		var swing := 0.0
		for f in 40:
			draw(c, 1)
			var yaw: float = info(c, 1).yaw
			var w := sin(clock_ms / 85.0 + 1.7) * (1.0 if moving else 0.25)
			swing = maxf(swing, absf(w))
			var want := Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, 0.12 * w) * Basis.from_scale(Vector3(1.0 + 0.12 * w, 1.0 - 0.09 * w, 1.0 + 0.1 * w) * 1.2)
			var got: Basis = row_of(c, 1).xf.basis
			worst = maxf(worst, maxf((got.x - want.x).length(), maxf((got.y - want.y).length(), (got.z - want.z).length())))
			var plain := Basis(Vector3.UP, float(info(c, 2).yaw)) * Basis.from_scale(Vector3.ONE * 1.2)
			var got2: Basis = row_of(c, 2).xf.basis
			worst_plain = maxf(worst_plain, maxf((got2.x - plain.x).length(), maxf((got2.y - plain.y).length(), (got2.z - plain.z).length())))
		check(worst < 1e-4 and swing > 0.1, "a %s Leech rolls and squashes as today's slither (worst basis error %s, w up to %.2f)" % ["moving" if moving else "standing", worst, swing])
		check(worst_plain < 1e-4, "a body without the flag is drawn plain (%s)" % worst_plain)


func blends_and_packing() -> void:
	var c := new_crowd()
	feed(c, [body(1, ENEMY, ROBBER, IDLE, 1, 2, {"tint": Color(0.5, 0.25, 1.0), "yaw": 0.7, "scale": 1.2})])
	draw(c, 3)
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 1, 2, {"speed": 1.5, "tint": Color(0.5, 0.25, 1.0), "yaw": 0.7, "scale": 1.2})])
	# the switch from idle to walk blends over FADE_LOCOMOTION = 0.28 s
	var i0: Dictionary = info(c, 1)
	check(i0.clip == "idle", "still idle until a frame has seen the new speed")
	var ok := true
	var weights := []
	for f in 22:
		c.draw(DT, 0.0, CAM)
		var i := info(c, 1)
		if f == 0:
			check(i.clip == "walk" and i.prev_clip == "idle", "idle -> walk crossfades")
		var want := maxf(0.0, 1.0 - float(f + 1) * DT / 0.28)
		if not near(i.blend, want, 1e-6):
			ok = false
		weights.append(snappedf(i.blend, 0.01))
		# the packed row: the custom data and colour as CrowdVatData packs them
		var r := row_at(c, 1, 2)
		var pc := CrowdVatData.pack_custom(data["grave_robber"].clip_index(i.clip), i.time, data["grave_robber"].clip_index(i.prev_clip) if i.prev_clip != "" else 0, i.prev_time if i.prev_clip != "" else 0.0, i.blend if i.prev_clip != "" else 0.0)
		var pk := CrowdVatData.pack_color(Color(0.5, 0.25, 1.0), 0.0)
		if r.is_empty() or not (r.custom.is_equal_approx(pc) or (absf(r.custom.r - pc.r) < 1e-6 and absf(r.custom.g - pc.g) < 1e-4 and absf(r.custom.b - pc.b) < 1e-6 and absf(r.custom.a - pc.a) < 1e-4)):
			ok = false
			printerr("  row ", r.get("custom"), " packed ", pc, " blend ", i.blend)
		if r.is_empty() or not r.color.is_equal_approx(pk):
			ok = false
	check(ok, "the blend weight falls linearly over 0.28 s and the rows pack as CrowdVatData.pack_custom / pack_color: %s" % str(weights.slice(0, 12)))
	check(info(c, 1).prev_clip == "" and row_at(c, 1, 2).custom.b == 0.0 and row_at(c, 1, 2).custom.a == 0.0, "after the blend the previous clip is off (weight 0)")
	# the transform: yaw, scale, position in the layout of MultiMesh.buffer (12 transform rows, 4 colour, 4 custom)
	var r := row_at(c, 1, 2)
	var want := Transform3D(Basis(Vector3.UP, info(c, 1).yaw) * Basis.from_scale(Vector3.ONE * 1.2), Vector3(1, 0, 2))
	check(r.xf.is_equal_approx(want), "the transform rows are the instance's Transform3D (rows, then origin)")
	check(rows(c).size() == 1, "one creature, one instance")
	var buf: PackedFloat32Array = c.buffer(ROBBER, 0, true) if c.instance_count(ROBBER, 0, true) > 0 else c.buffer(ROBBER, 0, false)
	check(buf.size() == 20 and near(buf[3], 1.0) and near(buf[11], 2.0) and near(buf[12], 0.5) and near(buf[13], 0.25) and near(buf[14], 1.0), "20 floats per instance: origin in 3, 7 and 11, the tint from 12")
	# the flash: eighths of 1, after today's 8 levels
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 1, 2, {"speed": 1.5})], [[1, 10.0, 90.0, 100.0]])
	draw(c, 1)
	check(near(row_at(c, 1, 2).color.a, round(info(c, 1).flash_v * 8.0) / 8.0, 1e-6), "the flash packs in eighths")


func hits_and_flash() -> void:
	for kind in [ENEMY, THRALL]:
		var rate := 6.0 if kind == ENEMY else 5.0
		var model := ROBBER if kind == ENEMY else SKELETON
		var c := new_crowd()
		var st := CHASE if kind == ENEMY else T_MOVE
		feed(c, [body(1, kind, model, st, 3, 0, {"speed": 2.0})])
		draw(c, 3)
		check(info(c, 1).flash == 0.0 and info(c, 1).kick_t == -1.0, "no flash, no recoil before a hit")
		feed(c, [body(1, kind, model, st, 3, 0, {"speed": 2.0})], [[1, 10.0, 90.0, 100.0]])
		var i := info(c, 1)
		check(i.flash == 1.0 and i.kick_t == 0.0, "a hit flashes to 1 and recoils the body")
		var base_h: float = 1.7 if kind == ENEMY else 1.75
		check(near(i.kick_amp, clampf(2.0 / maxf(base_h, 0.5), 0.35, 1.0), 1e-6), "the recoil is smaller for a taller body (%.3f)" % i.kick_amp)
		var flash := 1.0
		var worst := 0.0
		var shown := 1.0
		var level_ok := true
		for f in 20:
			c.draw(DT, 0.0, CAM)
			flash = maxf(0.0, flash - DT * rate)
			var ii := info(c, 1)
			worst = maxf(worst, absf(ii.flash - flash))
			if absf(flash - shown) >= 0.02:
				shown = flash   # DmCreature.set_flash ignores changes under 0.02
			if not near(ii.flash_v, shown, 1e-9):
				level_ok = false
			var r := row_of(c, 1)
			if r.is_empty() or not near(r.color.a, round(clampf(shown, 0.0, 1.0) * 8.0) / 8.0, 1e-6):
				level_ok = false
		check(worst < 1e-9, "%s flash decays by %s per second like today's (worst %s)" % ["enemy" if kind == ENEMY else "thrall", rate, worst])
		check(level_ok, "the flash is drawn in eighths of the value set_flash last took")
		check(info(c, 1).flash == 0.0, "and is gone after a fifth of a second")
		# the recoil pose follows the effect timers and is over after 0.3 s
		var c2 := new_crowd()
		feed(c2, [body(1, kind, model, st, 3, 0)])
		feed(c2, [body(1, kind, model, st, 3, 0)], [[1, 10.0, 90.0, 100.0]])
		var worst_pose := 0.0
		var peaked := 0.0
		for f in 24:
			c2.draw(DT, 0.0, CAM)
			var ii := info(c2, 1)
			var p := fx_pose(ii)
			worst_pose = maxf(worst_pose, (Vector4(ii.pose) - p).length())
			peaked = maxf(peaked, absf(ii.pose.x))
		check(worst_pose < 1e-5, "the recoil's pose is DmCreature._fx_step's (worst %s)" % worst_pose)
		check(peaked > 0.05 and info(c2, 1).kick_t == -1.0 and Vector4(info(c2, 1).pose).length() == 0.0, "it kicks back %.3f rad and settles within 0.3 s" % peaked)
		# a second hit while flash is above 0.5 does not recoil again; one after it fell below does
		var c3 := new_crowd()
		feed(c3, [body(1, kind, model, st, 3, 0)])
		feed(c3, [body(1, kind, model, st, 3, 0)], [[1, 5.0, 95.0, 100.0]])
		draw(c3, 2)
		var kt: float = info(c3, 1).kick_t
		feed(c3, [body(1, kind, model, st, 3, 0)], [[1, 5.0, 90.0, 100.0]])
		check(info(c3, 1).flash == 1.0 and near(info(c3, 1).kick_t, kt, 1e-9), "a hit on a flashing body refreshes the flash, the recoil runs on")
		draw(c3, 30)
		feed(c3, [body(1, kind, model, st, 3, 0)], [[1, 5.0, 85.0, 100.0]])
		check(info(c3, 1).kick_t == 0.0, "a hit after the last one faded recoils again")
	# the killing blow leaves no flash on the corpse
	var c := new_crowd()
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 3, 0)])
	feed(c, [body(1, ENEMY, ROBBER, DEAD, 3, 0)], [[1, 100.0, 0.0, 100.0]])
	check(info(c, 1).mode == "dying" and info(c, 1).flash == 0.0, "the killing blow sets no flash on the dying body")


func knockback() -> void:
	var c := new_crowd()
	c.set_focus(Vector2(0, 0))
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 4, 0), body(2, ENEMY, ROBBER, CHASE, 30, 0), body(3, ENEMY, ROBBER, CHASE, -3, 0, {"flags": F_INERT}),
		body(4, ENEMY, ROBBER, ATTACK, 0, 4, {"action_s": 0.42, "state_t": 0.1}), body(5, ENEMY, ROBBER, CHASE, 0, -4, {"scale": 1.35})])
	draw(c, 2)
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 4, 0), body(2, ENEMY, ROBBER, CHASE, 30, 0), body(3, ENEMY, ROBBER, CHASE, -3, 0, {"flags": F_INERT}),
		body(4, ENEMY, ROBBER, ATTACK, 0, 4, {"action_s": 0.42, "state_t": 0.1}), body(5, ENEMY, ROBBER, CHASE, 0, -4, {"scale": 1.35})],
		[[1, 20.0, 80.0, 100.0], [2, 20.0, 80.0, 100.0], [3, 20.0, 80.0, 100.0], [4, 20.0, 80.0, 100.0], [5, 20.0, 80.0, 100.0]])
	var imp := knock_impulse(0.2, 1.0, 4.0, 0.0)
	check(Vector2(info(c, 1).knock.z, info(c, 1).knock.w).distance_to(imp) < 1e-5, "a hit shoves the body away from the hero by knock_impulse (%s)" % imp)
	check(Vector4(info(c, 2).knock) == Vector4.ZERO, "far from the hero (over 24 m) there is no shove")
	check(Vector4(info(c, 3).knock) == Vector4.ZERO, "an inert body is never shoved")
	var committed := knock_impulse(0.2 * 0.4, 1.0, 0.0, 4.0)
	check(Vector2(info(c, 4).knock.z, info(c, 4).knock.w).distance_to(committed) < 1e-5, "a body mid wind-up is shoved 0.4x as hard")
	var heavy := knock_impulse(0.2, 1.35 * 1.35, 0.0, -4.0)
	check(Vector2(info(c, 5).knock.z, info(c, 5).knock.w).distance_to(heavy) < 1e-5 and heavy.length() < imp.length(), "an elite's mass (scale squared) shoves it less")
	# the spring, frame by frame, and the drawn position riding on it
	var k := {"x": 0.0, "z": 0.0, "vx": imp.x, "vz": imp.y}
	var worst := 0.0
	var pos_ok := true
	var peak := 0.0
	for f in 70:
		c.draw(DT, 0.0, CAM)
		step_knock(k, DT)
		var ii := info(c, 1)
		worst = maxf(worst, absf(ii.knock.x - k.x) + absf(ii.knock.y - k.z) + absf(ii.knock.z - k.vx) + absf(ii.knock.w - k.vz))
		peak = maxf(peak, absf(k.x))
		var r := row_at(c, 4.0 + k.x, 0.0 + k.z)
		if r.is_empty():
			pos_ok = false
	check(worst < 1e-5, "the knock spring runs like step_knock (worst %s)" % worst)
	check(pos_ok and peak > 0.05 and peak <= KNOCK_MAX, "the drawn position carries the offset (peak %.3f m, never over %.1f)" % [peak, KNOCK_MAX])
	check(Vector4(info(c, 1).knock) == Vector4.ZERO or near(Vector4(info(c, 1).knock).length(), 0.0, 1e-3), "and the spring settles")
	# the hitstop holds the picture
	var c2 := new_crowd()
	feed(c2, [body(1, ENEMY, ROBBER, CHASE, 4, 0, {"speed": 2.0})])
	draw(c2, 3)
	var t0: float = info(c2, 1).time
	c2.set_hitstop_scale(0.0)
	draw(c2, 5)
	check(near(info(c2, 1).time, t0, 1e-9), "a hitstop freezes an enemy's clip")
	c2.set_hitstop_scale(1.0)
	draw(c2, 5)
	check(info(c2, 1).time != t0, "and releases it")


func rise_hover_and_pose() -> void:
	var c := new_crowd()
	feed(c, [body(1, ENEMY, ROBBER, RISING, 0, 0, {"state_t": 0.55}), body(2, THRALL, SKELETON, T_RISING, 4, 0, {"state_t": 0.3, "scale": 1.0}), body(3, ENEMY, ROBBER, RISING, 8, 0, {"flags": F_FLYER, "hover": 1.1})])
	c.draw(DT, 0.5, CAM)
	clock_ms += DT * 1000.0
	var r1 := minf(1.0, (0.55 + 0.5 * DT) / 1.1)
	var i := info(c, 1)
	check(near(i.rise_k, r1, 1e-6) and near(i.pos.y, -0.9 * 1.7 * (1.0 - r1) * (1.0 - r1), 1e-5), "an enemy climbs out of the ground: rise %.3f, y %.3f" % [r1, i.pos.y])
	check(near(Vector4(i.pose).x, 0.5 * (1.0 - r1) * (1.0 - r1), 1e-6), "leaning into it (pitch %.3f)" % Vector4(i.pose).x)
	var r2 := minf(1.0, (0.3 + 0.5 * DT) / 0.9)
	check(near(info(c, 2).rise_k, r2, 1e-6) and near(info(c, 2).pos.y, -1.8 * (1.0 - r2) * (1.0 - r2), 1e-5), "a thrall's rise takes 0.9 s and 1.8 m")
	check(near(info(c, 3).pos.y, 1.1 + sin(clock_ms / 520.0 + 3.0) * 0.18, 1e-5), "a flying body does not sink: it hovers")
	# the end of the rise
	feed(c, [body(1, ENEMY, ROBBER, IDLE, 0, 0), body(2, THRALL, SKELETON, T_IDLE, 4, 0), body(3, ENEMY, ROBBER, IDLE, 8, 0, {"flags": F_FLYER, "hover": 1.1})])
	draw(c, 1)
	check(info(c, 1).rise_k == 1.0 and near(info(c, 1).pos.y, 0.0) and Vector4(info(c, 1).pose).length() < 1e-9, "standing: no offset, no lean")
	# hover: a def's flying height bobs 0.18, the wraith's 0.45 bobs 0.12, a floating thrall's 0.25 bobs 0.1 on its own beat
	var h := new_crowd()
	feed(h, [body(1, ENEMY, ROBBER, IDLE, 0, 0, {"hover": 0.45}), body(2, ENEMY, ROBBER, IDLE, 4, 0, {"hover": 1.5, "flags": F_FLYER}), body(3, THRALL, SKELETON, T_IDLE, 8, 0, {"hover": 0.25})])
	var ok := true
	for f in 90:
		h.draw(DT, 0.0, CAM)
		clock_ms += DT * 1000.0
		if not (near(info(h, 1).pos.y, 0.45 + sin(clock_ms / 520.0 + 1.0) * 0.12, 1e-4) and near(info(h, 2).pos.y, 1.5 + sin(clock_ms / 520.0 + 2.0) * 0.18, 1e-4) and near(info(h, 3).pos.y, 0.25 + sin(clock_ms / 400.0 + 3.0) * 0.1, 1e-4)):
			ok = false
	check(ok, "hover + sin(t / 520 + id) x 0.12 / 0.18, and a thrall's 0.25 + sin(t / 400 + id) x 0.1")
	# the lunge pose over a whole swing, against the effect timers
	var s := new_crowd()
	feed(s, [body(1, ENEMY, ROBBER, IDLE, 0, 0)])
	feed(s, [body(1, ENEMY, ROBBER, ATTACK, 0, 0, {"action_s": 0.42})])
	var worst := 0.0
	var top_zo := 0.0
	var low_zo := 0.0
	for f in 60:
		s.draw(DT, 0.0, CAM)
		var ii := info(s, 1)
		worst = maxf(worst, (Vector4(ii.pose) - fx_pose(ii)).length())
		top_zo = maxf(top_zo, Vector4(ii.pose).w)
		low_zo = minf(low_zo, Vector4(ii.pose).w)
	check(worst < 1e-5, "the lunge pose is DmCreature._fx_step's (worst %s)" % worst)
	check(low_zo < -0.01 and near(top_zo, 1.7 * 0.07, 2e-3) and info(s, 1).lunge_t == -1.0, "rocks back (%.3f m), drives forward (%.3f m), settles" % [low_zo, top_zo])
	# the pose and the tip-over in the instance: yaw, then Z, then scale, the forward offset under the scale
	var q := new_crowd()
	feed(q, [body(1, ENEMY, ROBBER, IDLE, 2, 3, {"yaw": 1.1, "scale": 1.3})])
	feed(q, [body(1, ENEMY, ROBBER, ATTACK, 2, 3, {"yaw": 1.1, "scale": 1.3, "action_s": 0.42})], [[1, 10.0, 90.0, 100.0]])
	draw(q, 12)
	var ii := info(q, 1)
	var pose := Vector4(ii.pose)
	var model_basis := Basis.from_euler(Vector3(pose.x, 0.0, pose.y)) * Basis.from_scale(Vector3(1.0 + pose.z * 0.6, 1.0 - pose.z, 1.0 + pose.z * 0.6))
	var root_basis := Basis.from_euler(Vector3(0.0, ii.yaw, 0.0)) * Basis.from_scale(Vector3.ONE * 1.3)
	var want := Transform3D(root_basis * model_basis, Vector3(ii.pos) + root_basis * Vector3(0, 0, pose.w))   # (the hit shoved it a little: pos has the knock)
	var r := row_at(q, want.origin.x, want.origin.z)
	check(not r.is_empty() and r.xf.is_equal_approx(want), "the instance is root(yaw, scale) x model(pitch, roll, squash, forward) as Godot's Node3D tree composes it")


## The Belfry Gargoyle's dive (DmEnemyGargoyle._process and play_attack): the swing in its wind-up climbs over the mark for the first half (hover + 3 m x progress), drops onto
## it ((hover + 1.5) x (1 - 2 x (progress - 0.5))^2) and, once the wind-up is over or the blow has landed, sits grounded at 0.05 m; the dive plays its clip over the wind-up and a
## fifth more with no lunge (the robber has no dive clip: its role resolves to its attack); a swing that is not a dive keeps the hover.
func the_dive() -> void:
	var c := new_crowd()
	var hover := 1.1
	var w := 0.9
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 0, 0, {"flags": F_FLYER, "hover": hover}), body(2, ENEMY, ROBBER, CHASE, 6, 0, {"flags": F_FLYER, "hover": hover})])
	draw(c, 2)
	feed(c, [body(1, ENEMY, ROBBER, ATTACK, 0, 0, {"flags": F_FLYER | F_DIVING, "hover": hover, "action_s": w}), body(2, ENEMY, ROBBER, ATTACK, 6, 0, {"flags": F_FLYER, "hover": hover, "action_s": w})])
	var i := info(c, 1)
	check(i.one_shot.begins_with("attack") and near(i.speed, clip_len("grave_robber", i.one_shot) / (w * 1.2), 1e-6) and i.lunge_t == -1.0 and i.time == 0.0,
		"DIVE: the dive clip (%s) over the wind-up and a fifth more (%.3f x), no lunge" % [i.one_shot, i.speed])
	check(info(c, 2).lunge_t >= 0.0, "and a bite from the same body is a plain strike, with its lunge")
	var worst := 0.0
	var ok := true
	for k in 70:
		var t := float(k) * DT
		feed(c, [body(1, ENEMY, ROBBER, ATTACK, 0, 0, {"flags": F_FLYER | F_DIVING, "hover": hover, "action_s": w, "state_t": t})])
		draw(c, 1)
		var kk := t / w
		var want := 0.05
		if kk < 1.0:
			want = hover + kk * 3.0 if kk < 0.5 else (hover + 1.5) * pow(1.0 - (kk - 0.5) * 2.0, 2.0)
		worst = maxf(worst, absf(info(c, 1).pos.y - want))
		ok = ok and absf(info(c, 1).pos.y - want) < 1e-5
	check(ok, "DIVE: climbs over the mark for the first half, drops onto it, and is grounded (0.05 m) when the wind-up is over (worst %.6f m off)" % worst)
	var peak := 0.0
	for k in 28:
		feed(c, [body(1, ENEMY, ROBBER, ATTACK, 0, 0, {"flags": F_FLYER | F_DIVING, "hover": hover, "action_s": w, "state_t": float(k) * DT})])
		draw(c, 1)
		peak = maxf(peak, info(c, 1).pos.y)
	check(peak > hover + 1.2, "DIVE: the climb is high (%.2f m over a hover of %.1f)" % [peak, hover])
	# The blow has landed (the sim restarts the swing's clock; the flag says so): grounded however the clock reads, then the hover again once the dive is over.
	feed(c, [body(1, ENEMY, ROBBER, ATTACK, 0, 0, {"flags": F_FLYER | F_GROUNDED, "hover": hover, "action_s": w, "state_t": 0.1})])
	draw(c, 1)
	check(near(info(c, 1).pos.y, 0.05, 1e-6), "DIVE: after the blow it sits grounded while it recovers")
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 0, 0, {"flags": F_FLYER, "hover": hover})])
	draw(c, 1)
	check(near(info(c, 1).pos.y, hover + sin(clock_ms / 520.0 + 1.0) * 0.18, 1e-4), "DIVE: and when it hunts again it hovers")


func death_and_corpses() -> void:
	var c := new_crowd()
	c.set_focus(Vector2(0, 0))
	var d: CrowdVatData = data["grave_robber"]
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 6, 0, {"def": 7, "yaw": 0.4, "scale": 1.0}), body(2, ENEMY, ROBBER, CHASE, 14, 0, {"def": 7})])
	draw(c, 4)
	var pos := Vector3(info(c, 1).pos)
	# the killing tick: the row says DEAD and the corpse is in the core's table, 0.3 m off the final pose (another def's corpse 20 m away is not it)
	var corpse := {"id": 50, "model": ROBBER, "def": 7, "x": 6.3, "z": 0.0, "facing": 0.4, "scale": 1.0, "tint": Color.WHITE}
	var far_one := {"id": 51, "model": ROBBER, "def": 7, "x": 40.0, "z": 0.0, "facing": 0.0, "scale": 1.0, "tint": Color.WHITE}
	feed(c, [body(1, ENEMY, ROBBER, DEAD, 6, 0, {"def": 7, "yaw": 0.4}), body(2, ENEMY, ROBBER, CHASE, 14, 0, {"def": 7})], [[1, 100.0, 0.0, 100.0]], [corpse, far_one])
	var i := info(c, 1)
	check(i.mode == "corpse" and c.view_info(50, true).id == 1, "the dying body is adopted by the corpse within 1.2 m")
	check(c.view_info(51, true).mode == "corpse" and c.view_info(51, true).id < 0 and c.view_info(51, true).scale == 1.0, "a corpse with no dying body is laid down at its final pose")
	check(info(c, 2).mode == "live", "the other robber is untouched")
	var laid: Dictionary = c.view_info(51, true)
	check(laid.has_settle and Vector3(laid.pos).is_equal_approx(Vector3(40, 0, 0)) and near(laid.time, d.clip_seconds[d.clip_index(laid.death_clip)], 1e-6), "the laid corpse holds the last frame of its death and does not settle again")
	check(not i.shadow and not laid.shadow, "corpses never cast shadows")
	# the death clip, the landing, the settle ease and the end of the mixer
	var landing: float = d.clip_landing[d.clip_index(i.death_clip)]
	var seconds: float = d.clip_seconds[d.clip_index(i.death_clip)]
	var settle_at := -1.0
	var y_stand := 0.0
	var worst := 0.0
	var t := 0.0
	var prev_time := -1.0
	var time_stopped_at := -1.0
	for f in 600:
		c.draw(DT, 0.0, CAM)
		t += DT
		var ii: Dictionary = c.view_info(50, true)
		if ii.has_settle and settle_at < 0.0:
			settle_at = t
			y_stand = Vector3(ii.pos).y + settle_depth(ii.settle_t, SETTLE_DEPTH)   # where it stood when it landed
		if ii.has_settle:
			worst = maxf(worst, absf(Vector3(ii.pos).y - (y_stand - settle_depth(ii.settle_t, SETTLE_DEPTH))))
		if time_stopped_at < 0.0 and ii.time == prev_time:
			time_stopped_at = t
		prev_time = ii.time
	var ii: Dictionary = c.view_info(50, true)
	check(settle_at > 0.0 and absf(settle_at - landing) < 2.0 * DT, "the body settles when the death clip lands (clip says %.2f s, settled at %.2f s)" % [landing, settle_at])
	check(worst < 1e-5 and absf(y_stand) < 1e-9, "it eases %.2f m into the ground by settle_depth (worst %s)" % [SETTLE_DEPTH, worst])
	check(absf(Vector3(ii.pos).x - pos.x) < 1e-6 and absf(Vector3(ii.pos).z - pos.z) < 1e-6 and near(Vector3(ii.pos).y, -SETTLE_DEPTH, 1e-5), "and stays where it fell (%.2f, %.2f), %.2f m down" % [Vector3(ii.pos).x, Vector3(ii.pos).z, Vector3(ii.pos).y])
	check(time_stopped_at > 0.0 and ii.rest_t >= 0.35 and ii.time < seconds + 1e-6, "its clip stops 0.35 s after the landing (stopped at %.2f s, rest %.2f s)" % [time_stopped_at, ii.rest_t])
	check(absf(time_stopped_at - (landing + 0.35)) < 0.1 or time_stopped_at >= 5.9, "(landing %.2f s + 0.35 s, or at 6 s)" % landing)
	# the corpse leaves the table (consumed): it sinks for 0.9 s at 1.3 m/s and is gone (the dead row lingers in the core's table for 4 s)
	feed(c, [body(1, ENEMY, ROBBER, DEAD, 6, 0, {"def": 7, "yaw": 0.4}), body(2, ENEMY, ROBBER, CHASE, 14, 0, {"def": 7})], [], [far_one])
	check(info(c, 1).mode == "fading", "a corpse the core no longer holds sinks away")
	var y_before: float = Vector3(info(c, 1).pos).y
	draw(c, 15)
	check(info(c, 1).sink_t > 0.2 and near(Vector3(info(c, 1).pos).y, y_before - 15.0 * DT * 1.3, 1e-4), "it sinks 1.3 m/s (%.2f m after 0.25 s)" % (y_before - Vector3(info(c, 1).pos).y))
	draw(c, 45)
	check(info(c, 1).is_empty(), "and is gone after 0.9 s")
	check(c.stats().fading == 0, "nothing left fading")
	# Corpse Explosion blows a corpse apart: its body goes at the next frame, whether the core still lists it or it already began to sink
	var late := {"id": 52, "model": ROBBER, "def": 7, "x": -20.0, "z": 0.0, "facing": 0.0, "scale": 1.0, "tint": Color.WHITE}
	feed(c, [body(2, ENEMY, ROBBER, CHASE, 14, 0, {"def": 7})], [], [far_one, late])
	draw(c, 1)
	feed(c, [body(2, ENEMY, ROBBER, CHASE, 14, 0, {"def": 7})], [], [far_one])   # 52 left the table: it sinks
	check(c.view_info(52, true).is_empty() and c.stats().fading == 1, "a corpse that left the table begins to sink")
	check(c.shatter(51) and c.shatter(52) and not c.shatter(999), "shatter finds a lying corpse and a sinking one (and not one it never drew)")
	feed(c, [body(2, ENEMY, ROBBER, CHASE, 14, 0, {"def": 7})], [], [])
	draw(c, 1)
	check(c.view_info(51, true).is_empty() and c.stats().fading == 0, "both shattered bodies are gone at the next frame, nothing left to sink")
	# no corpse arrives (kind none): the dying body crumbles after 1.4 s
	feed(c, [body(9, ENEMY, ROBBER, CHASE, 3, 3, {"def": 3})])
	feed(c, [body(9, ENEMY, ROBBER, DEAD, 3, 3, {"def": 3})], [[9, 100.0, 0.0, 100.0]])
	draw(c, 80)
	check(info(c, 9).mode == "dying", "no corpse yet at 1.3 s")
	draw(c, 8)
	check(info(c, 9).mode == "fading", "no corpse by 1.4 s: it crumbles away")
	# a wraith leaves no body at all
	feed(c, [body(10, ENEMY, ROBBER, CHASE, 3, 3, {"def": 4, "flags": F_MIST})])
	feed(c, [body(10, ENEMY, ROBBER, DEAD, 3, 3, {"def": 4, "flags": F_MIST})])
	check(info(c, 10).mode == "fading", "a mist body thins away at once (no death clip, no corpse)")
	# a dying thrall: death clip then gone with its row after the 1.4 s
	feed(c, [body(11, THRALL, SKELETON, T_MOVE, 9, 9, {"speed": 3.0})])
	feed(c, [body(11, THRALL, SKELETON, T_DEAD, 9, 9)])
	draw(c, 60)
	check(info(c, 11).mode == "dying" and info(c, 11).time > 0.5, "a fallen thrall lies where it fell")
	draw(c, 30)
	check(info(c, 11).mode == "fading", "and sinks away after 1.4 s")


## What an instance row says of its opacity (crowd_vat.gdshader under FADE, line by line): INSTANCE_CUSTOM.x = the clip index + q / 64, q = (1 - opacity) in 63rds.
func fade_of(r: Dictionary) -> Dictionary:
	var x: float = r.custom.r
	var clip_f := floorf(x + 0.001)
	return {"clip": int(clip_f), "q": roundi((x - clip_f) * 64.0), "opacity": clampf(1.0 - (x - clip_f) * (64.0 / 63.0), 0.0, 1.0)}


## The alpha path (README "The alpha path"): a body that sinks away, and a body under the Shrouded ward, is drawn in its model's fade group at today's opacity and casts no shadow; nothing
## else about its row changes; a model with no fade group, or a ghost's, falls back as described; and a crowd of them costs one group a model and level, not one an instance.
func fades() -> void:
	var half := 0.5 / 63.0 + 1e-6   # one step of the instance's opacity is 1/63: the row is within half a step of the view's
	var c := new_crowd()
	c.set_focus(Vector2(0, 0))
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 6, 0, {"def": 7}), body(2, ENEMY, ROBBER, CHASE, 9, 0, {"def": 7})])
	draw(c, 4)
	var solid := row_of(c, 2)
	check(not solid.is_empty() and not solid.fade and solid.custom.r == floorf(solid.custom.r) and info(c, 2).opacity == 1.0 and info(c, 2).fade_q == 0,
		"a solid body's row has a whole clip index and sits in a plain or shadow group")
	# --- a corpse the core no longer holds sinks for 0.9 s (DmEntityViews: set_opacity(max(0, 1 - sink_t / 0.9)), 1.3 m/s)
	var corpse := {"id": 50, "model": ROBBER, "def": 7, "x": 6.0, "z": 0.0, "facing": 0.0, "scale": 1.0, "tint": Color.WHITE}
	var dead_row := body(1, ENEMY, ROBBER, DEAD, 6, 0, {"def": 7})
	var other := body(2, ENEMY, ROBBER, CHASE, 9, 0, {"def": 7})
	feed(c, [dead_row, other], [[1, 100.0, 0.0, 100.0]], [corpse])
	draw(c, 120)
	check(info(c, 1).mode == "corpse" and info(c, 1).opacity == 1.0 and not row_of(c, 1).fade, "a corpse lying there is solid, in a plain group")
	feed(c, [dead_row, other], [], [])
	check(info(c, 1).mode == "fading" and c.stats().fading == 1, "a corpse the core no longer holds sinks")
	var frames := 0
	var seen := 0
	var in_fade := 0
	var worst := 0.0
	var exact := true
	var no_shadow := true
	var clip_kept := true
	var y_ok := true
	for f in 60:
		draw(c, 1)
		var inf := info(c, 1)
		if inf.is_empty() or inf.mode != "fading":
			break
		frames += 1
		var want := maxf(0.0, 1.0 - float(inf.sink_t) / 0.9)
		exact = exact and near(inf.opacity, want, 1e-9) and inf.fade_q == roundi((1.0 - want) * 63.0)
		var r := row_of(c, 1)
		if r.is_empty():
			continue   # (sunk to nothing: not written)
		seen += 1
		in_fade += 1 if r.fade else 0
		no_shadow = no_shadow and not r.shadow
		worst = maxf(worst, absf(fade_of(r).opacity - want))
		clip_kept = clip_kept and fade_of(r).clip == int(inf.clip_index)
		y_ok = y_ok and near(r.xf.origin.y, Vector3(inf.pos).y, 1e-5)
	check(frames >= 52 and frames <= 56 and exact, "it sinks for 0.9 s (%d frames) and the view's opacity is 1 - sink_t / 0.9 on every one, as today's" % frames)
	check(seen >= frames - 2 and in_fade == seen and no_shadow, "every frame it is written it is in the fade group and never in a shadow group (%d of %d frames; a body sunk to nothing is not written)" % [in_fade, frames])
	check(worst <= half, "its row carries that opacity within half a step of a 63rd (worst %.4f)" % worst)
	check(clip_kept and y_ok, "and the clip index and the place of the row are the body's own")
	draw(c, 3)
	check(info(c, 1).is_empty() or info(c, 1).mode != "fading", "it is gone after the 0.9 s")
	check(c.stats().fading == 0 and c.stats().faded == 0 and c.stats().groups_faded == 0, "nothing is left in the fade groups once it has sunk")
	# --- a body that leaves the rows (the area cleared) sinks the same way, through the same group
	feed(c, [body(5, ENEMY, ROBBER, CHASE, 3, 0, {"def": 7}), other])
	draw(c, 3)
	feed(c, [other])
	draw(c, 20)
	var swept := row_at(c, 3.0, 0.0)
	check(c.stats().fading == 1 and c.stats().faded == 1 and not swept.is_empty() and swept.fade and absf(fade_of(swept).opacity - (1.0 - 20.0 * DT / 0.9)) <= half,
		"a body that left the rows fades the same way (%.2f after a third of a second, 1 - 0.33 / 0.9)" % fade_of(swept).opacity)
	draw(c, 60)
	# --- a thrall casts while it lies there, and not once it sinks
	c = new_crowd()
	c.set_focus(Vector2(0, 0))
	other = body(2, ENEMY, ROBBER, CHASE, 9, 0, {"def": 7})
	feed(c, [body(3, THRALL, SKELETON, T_MOVE, -8, 0, {"speed": 3.0}), other])
	draw(c, 3)
	feed(c, [body(3, THRALL, SKELETON, T_DEAD, -8, 0), other])
	draw(c, 60)
	var shadows := func() -> int:
		var n := 0
		for l in lods[SKELETON]:
			n += c.instance_count(SKELETON, l, true)
		return n
	check(info(c, 3).mode == "dying" and shadows.call() == 1 and c.stats().casting_thralls == 1 and c.stats().faded == 0, "a fallen thrall still casts while it lies there (it is in a shadow group)")
	draw(c, 30)
	check(info(c, 3).mode == "fading" and shadows.call() == 0 and c.stats().casting_thralls == 0 and c.stats().faded == 1 and c.stats().groups_faded == 1,
		"once it sinks it has left the shadow group for the fade group (%d casting, %d faded)" % [c.stats().casting_thralls, c.stats().faded])
	# --- the Shrouded ward: the body eases to 0.38 at 6 a second while it is up, and back to solid when it is down (DmEntityViews._tick_affix)
	c = new_crowd()
	c.set_focus(Vector2(0, 0))
	var veiled := body(1, ENEMY, ROBBER, IDLE, 5, 2, {"def": 7, "flags": F_SHROUDED})
	var plain_one := body(2, ENEMY, ROBBER, IDLE, 8, 2, {"def": 7})
	feed(c, [veiled, plain_one])
	var o := 1.0
	var mirror_ok := true
	var groups_ok := true
	var worst_s := 0.0
	var first_fade := -1
	for f in 150:
		draw(c, 1)
		o += (0.38 - o) * minf(1.0, DT * 6.0)
		var inf := info(c, 1)
		mirror_ok = mirror_ok and near(inf.opacity, o, 1e-12)
		var q := roundi((1.0 - o) * 63.0)
		var r := row_of(c, 1)
		groups_ok = groups_ok and r.fade == (q > 0) and not (r.fade and r.shadow) and fade_of(r).q == q
		worst_s = maxf(worst_s, absf(fade_of(r).opacity - o))
		if first_fade < 0 and r.fade:
			first_fade = f
	check(mirror_ok, "the ward's ease is today's: opacity += (0.38 - opacity) x min(1, 6 dt) every frame (%.4f after 2.5 s)" % info(c, 1).opacity)
	check(groups_ok and first_fade == 0 and worst_s <= half, "the body is in the fade group from its first see-through frame, at the opacity of the view within half a step (%.4f)" % worst_s)
	check(info(c, 1).veiled and info(c, 1).opacity > 0.379 and info(c, 1).opacity < 0.381 and not info(c, 2).veiled and info(c, 2).opacity == 1.0, "it settles at 0.38; a plain body next to it stays solid")
	check(c.stats().faded == 1 and c.stats().groups_faded == 1 and c.stats().casting == 1, "one instance in one fade group; the plain body is the only one casting (%d faded, %d casting)" % [c.stats().faded, c.stats().casting])
	feed(c, [body(1, ENEMY, ROBBER, IDLE, 5, 2, {"def": 7}), plain_one])   # a Miasma covers it (or the ward is stripped): the bit goes
	var back_at := -1
	mirror_ok = true
	for f in 120:
		draw(c, 1)
		o += (1.0 - o) * minf(1.0, DT * 6.0)
		o = 1.0 if o > 0.999 else o
		mirror_ok = mirror_ok and near(info(c, 1).opacity, o, 1e-12)
		if back_at < 0 and not row_of(c, 1).fade:
			back_at = f
	check(mirror_ok and not info(c, 1).veiled and info(c, 1).opacity == 1.0 and info(c, 1).fade_q == 0, "with the ward down it eases back to exactly solid")
	check(back_at > 30 and back_at < 55, "and is drawn solid again from frame %d (a step under half a percent), %.2f s after the ward went" % [back_at, float(back_at) * DT])
	var again := row_of(c, 1)
	check(not again.fade and again.custom.r == floorf(again.custom.r) and c.stats().faded == 0 and c.stats().casting == 2, "back in a plain or shadow group with a whole clip index, casting again (%d casting)" % c.stats().casting)
	# a ward that holds when a shrouded body dies: it falls solid (DmEntityViews._on_death sets the opacity back to 1)
	feed(c, [veiled, plain_one])
	draw(c, 40)
	check(info(c, 1).opacity < 0.5 and row_of(c, 1).fade, "the ward is up again")
	feed(c, [body(1, ENEMY, ROBBER, DEAD, 5, 2, {"def": 7, "flags": F_SHROUDED}), plain_one])
	check(info(c, 1).mode == "dying" and info(c, 1).opacity == 1.0 and info(c, 1).fade_q == 0, "a shrouded body that dies is solid where it falls")
	draw(c, 2)
	var fell := row_of(c, 1)
	check(not fell.is_empty() and not fell.fade and fell.custom.r == floorf(fell.custom.r), "and its row is in a solid group")
	# --- the same rows with and without the ward: the fade group's row is the solid group's, but for the opacity
	var a := new_crowd()
	var b := new_crowd()
	a.set_focus(Vector2(0, 0))
	b.set_focus(Vector2(0, 0))
	feed(a, [body(1, ENEMY, ROBBER, CHASE, 5, 2, {"def": 7, "speed": 3.0, "state_t": 1.0}), body(2, THRALL, SKELETON, T_MOVE, -6, 2, {"speed": 3.0})])
	feed(b, [body(1, ENEMY, ROBBER, CHASE, 5, 2, {"def": 7, "speed": 3.0, "state_t": 1.0, "flags": F_SHROUDED}), body(2, THRALL, SKELETON, T_MOVE, -6, 2, {"speed": 3.0})])
	var same_rows := true
	var compared := 0
	for f in 40:
		a.draw(DT, 0.0, CAM)
		b.draw(DT, 0.0, CAM)
		clock_ms += DT * 1000.0
		var ra := row_of(a, 1)
		var rb := row_of(b, 1)
		compared += 1
		same_rows = same_rows and not ra.is_empty() and not rb.is_empty() and rb.fade and ra.xf.is_equal_approx(rb.xf) and ra.color == rb.color \
			and ra.custom.g == rb.custom.g and ra.custom.b == rb.custom.b and ra.custom.a == rb.custom.a and fade_of(rb).clip == fade_of(ra).clip
	check(same_rows and compared == 40, "a body under the ward is drawn exactly as without it (transform, tint and glow, flash, clip times and blend), but for the opacity (%d frames)" % compared)
	var thrall_same := true
	for l in lods[SKELETON]:
		thrall_same = thrall_same and a.buffer(SKELETON, l, true) == b.buffer(SKELETON, l, true) and a.buffer(SKELETON, l, false) == b.buffer(SKELETON, l, false)
	check(thrall_same and a.stats().drawn == b.stats().drawn, "and the thrall beside it is the same bytes (%d instances in both)" % a.stats().drawn)
	# --- animation bands: the ward's ease is by time, so a far body reaches the same place
	var far := new_crowd()
	far.set_anim_lod(true, 5.0, 24.0, 10.0, 10.0)
	far.set_focus(Vector2(0, 0))
	feed(far, [body(1, ENEMY, ROBBER, IDLE, 40, 0, {"def": 7, "flags": F_SHROUDED})])
	for f in 180:
		far.draw(DT, 0.0, CAM)
	check(info(far, 1).band == 2 and absf(float(info(far, 1).opacity) - 0.38) < 0.01 and row_of(far, 1).fade and absf(fade_of(row_of(far, 1)).opacity - 0.38) <= 0.01, "a body in the far band (10 poses a second) is at 0.38 after 3 s all the same (%.3f)" % info(far, 1).opacity)
	# --- no fade group (an older caller of add_model), and a ghost's model: the fallbacks
	var plain_only := new_crowd({"no_fade": true})
	plain_only.set_focus(Vector2(0, 0))
	feed(plain_only, [body(1, ENEMY, ROBBER, IDLE, 5, 2, {"def": 7, "flags": F_SHROUDED}), body(2, ENEMY, ROBBER, CHASE, 9, 0, {"def": 7})])
	draw(plain_only, 30)
	feed(plain_only, [body(1, ENEMY, ROBBER, IDLE, 5, 2, {"def": 7, "flags": F_SHROUDED})])
	draw(plain_only, 10)
	var all_whole := true
	for r in rows(plain_only):
		all_whole = all_whole and not r.fade and r.custom.r == floorf(r.custom.r)
	check(plain_only.stats().fading == 1 and info(plain_only, 1).fade_q == 0 and all_whole and plain_only.stats().faded == 0 and plain_only.stats().drawn == 2,
		"a model with no fade group keeps drawing its shrouded and sinking bodies solid, in its plain groups (%d drawn)" % plain_only.stats().drawn)
	var ghost := new_crowd({"spectral": ["grave_robber"]})
	ghost.set_focus(Vector2(0, 0))
	feed(ghost, [body(1, ENEMY, ROBBER, CHASE, 5, 2, {"def": 4, "flags": F_MIST}), body(2, ENEMY, ROBBER, CHASE, 9, 0, {"def": 7})])
	draw(ghost, 4)
	check(fade_of(row_of(ghost, 1)).q == 0 and ghost.instance_count(ROBBER, 0, false, true) == 0, "a ghost's live row is a whole clip index (its own 0.55 is the material's)")
	feed(ghost, [body(1, ENEMY, ROBBER, DEAD, 5, 2, {"def": 4, "flags": F_MIST}), body(2, ENEMY, ROBBER, CHASE, 9, 0, {"def": 7})])
	draw(ghost, 20)
	var gr := row_of(ghost, 1)
	var gwant := maxf(0.0, 1.0 - float(info(ghost, 1).sink_t) / 0.9)
	check(info(ghost, 1).mode == "fading" and not gr.fade and absf(fade_of(gr).opacity - gwant) <= half and fade_of(gr).q > 0 and ghost.stats().groups_faded == 0,
		"a ghost that thins away stays in its plain group, whose shader is see-through already, and carries the opacity there (%.3f)" % fade_of(gr).opacity)
	# --- the cost: bodies sinking together share one fade group a model and level
	var many := new_crowd()
	many.set_focus(Vector2(0, 0))
	var crowd_rows: Array = []
	for k in 12:
		crowd_rows.append(body(100 + k, ENEMY, ROBBER, IDLE, -5.0 + 0.8 * k, 1, {"def": 7}))
	for k in 6:
		crowd_rows.append(body(200 + k, ENEMY, HOUND, IDLE, -4.0 + 1.1 * k, 4, {"def": 3}))
	for k in 8:
		crowd_rows.append(body(300 + k, THRALL, SKELETON, T_IDLE, -4.0 + k, -3))
	feed(many, crowd_rows)
	draw(many, 12)
	var used_solid: int = many.stats().groups_used
	check(many.stats().faded == 0 and used_solid >= 3, "26 solid bodies of three models: %d groups drawing (plain and shadow ones)" % used_solid)
	feed(many, [])
	draw(many, 10)
	check(many.stats().faded == 26 and many.stats().groups_faded == 3 and many.stats().groups_used == 3 and many.stats().casting == 0,
		"26 bodies sinking together draw %d groups, one fade group a model and level (%d instances), none casting" % [many.stats().groups_faded, many.stats().faded])
	feed(many, crowd_rows.slice(0, 12))   # twelve robbers stand again (new views) while the 26 are still sinking
	draw(many, 2)
	check(many.stats().groups_faded == 3 and many.stats().groups_used > 3 and many.stats().faded == 26, "a standing group and the sinking ones draw side by side (%d groups, %d sinking)" % [many.stats().groups_used, many.stats().faded])
	draw(many, 60)
	check(many.stats().fading == 0 and many.stats().groups_faded == 0, "and the fade groups empty once the bodies are gone")


func body_only() -> void:
	# a model with no attack, hurt or death clip (the hound's bake with its loops alone): the body does it alone
	var c := new_crowd({"bare": [SLUGS[HOUND]]})
	feed(c, [body(1, ENEMY, HOUND, CHASE, 3, 0, {"def": 2, "speed": 4.4})])
	draw(c, 20)
	check(info(c, 1).clip in ["walk", "run"], "it walks and runs")
	feed(c, [body(1, ENEMY, HOUND, ATTACK, 3, 0, {"def": 2, "action_s": 0.25})])
	var i := info(c, 1)
	check(i.one_shot == "" and near(i.lunge_len, 1.05 * 0.22, 1e-6) and near(i.lunge_pitch, 0.2, 1e-9) and near(i.lunge_in, 0.25, 1e-6), "no attack clip: it lunges and bites with the body (%.3f m, %.2f rad)" % [i.lunge_len, i.lunge_pitch])
	draw(c, 30)
	feed(c, [body(1, ENEMY, HOUND, HURT, 3, 0, {"def": 2})])
	i = info(c, 1)
	check(i.one_shot == "" and i.kick_t == 0.0 and near(i.kick_amp, 0.85 * clampf(2.0 / 1.05, 0.35, 1.0), 1e-6), "no hurt clip: only the recoil")
	draw(c, 30)
	# no death clip: it tips over, 3 per second, and lands at 0.8
	feed(c, [body(1, ENEMY, HOUND, DEAD, 3, 0, {"def": 2, "yaw": 0.5})], [], [{"id": 5, "model": HOUND, "def": 2, "x": 3.0, "z": 0.0, "facing": 0.5, "scale": 1.0, "tint": Color.WHITE}])
	i = info(c, 1)
	check(i.mode == "corpse" and near(i.toppled, 0.0001, 1e-9) and i.death_clip == "", "no death clip: it starts to topple")
	var topple := 0.0001
	var ok := true
	var landed_t := -1.0
	for f in 40:
		c.draw(DT, 0.0, CAM)
		topple = minf(1.0, topple + DT * 3.0)
		var ii := info(c, 1)
		if not near(ii.toppled, topple, 1e-9):
			ok = false
		if ii.has_settle and landed_t < 0.0:
			landed_t = float(f + 1) * DT
	check(ok, "toppled rises by dt x 3 to 1")
	check(landed_t > 0.0 and absf(landed_t - 0.8 / 3.0) < 2 * DT, "it has landed at toppled 0.8 (%.3f s) and settles" % landed_t)
	i = info(c, 1)
	check(near(Vector3(i.pos).y, 0.2 - settle_depth(i.settle_t, SETTLE_DEPTH), 1e-5), "lying 0.2 m up, eased %.3f m into the ground" % settle_depth(i.settle_t, SETTLE_DEPTH))
	var r := row_at(c, 3, 0)
	var want := Basis(Vector3.UP, i.yaw) * Basis(Vector3.BACK, PI / 2.0)
	check(not r.is_empty() and r.xf.basis.is_equal_approx(want), "the instance is turned a quarter about Z: lying on its side")
	# one laid down by a corpse alone is already down
	feed(c, [], [], [{"id": 6, "model": HOUND, "def": 2, "x": 12.0, "z": 0.0, "facing": 0.0, "scale": 1.0, "tint": Color.WHITE}])
	check(c.view_info(6, true).toppled == 1.0, "a laid corpse of a model without a death clip lies flat")


func shadows_and_lod() -> void:
	var c := new_crowd()
	c.set_focus(Vector2.ZERO)
	var bodies := []
	for k in 20:   # 20 living enemies at 1..20 m from the hero, the farthest first in the rows
		bodies.append(body(100 + k, ENEMY, ROBBER, CHASE, float(20 - k), 0.0, {"def": 7}))
	bodies.append(body(1, THRALL, SKELETON, T_IDLE, 30.0, 5.0))
	bodies.append(body(2, ENEMY, ROBBER, IDLE, 0.5, 0.5, {"flags": F_MIST}))
	feed(c, bodies)
	draw(c, 1)
	check(info(c, 100).shadow and info(c, 1).shadow, "a new body casts until the first ranking")
	draw(c, 9)
	var casters := 0
	var wrong := 0
	for k in 20:
		var cast: bool = info(c, 100 + k).shadow
		casters += 1 if cast else 0
		if cast != (float(20 - k) <= 11.0):   # 21 enemies are ranked, the spectral one first: 12 slots, 11 for real bodies
			wrong += 1
	check(wrong == 0 and casters == 11, "the nearest 12 ranked enemies cast, the rest do not (%d casters, %d off)" % [casters, wrong])
	check(not info(c, 2).shadow, "a spectral body takes a slot and never casts")
	check(info(c, 1).shadow, "thralls always cast, as today")
	check(c.instance_count(ROBBER, 0, true) + c.instance_count(ROBBER, 1, true) == casters and c.instance_count(SKELETON, 0, true) + c.instance_count(SKELETON, 1, true) + c.instance_count(SKELETON, 2, true) == 1,
		"the shadow groups hold exactly the casters")
	var plain: int = c.instance_count(ROBBER, 0, false) + c.instance_count(ROBBER, 1, false)
	check(plain == 21 - casters and c.stats().drawn == 22, "everything else is drawn without shadows (%d), 22 in all" % plain)
	# crowded: 32 or more enemies in the field
	var many := []
	for k in 40:
		many.append(body(200 + k, ENEMY, ROBBER, CHASE, float(1 + k), 0.0, {"def": 7}))
	feed(c, many)
	draw(c, 10)
	var n := 0
	var nearest := true
	for k in 40:
		if info(c, 200 + k).shadow:
			n += 1
			if k >= 8:
				nearest = false
	check(n == 8 and nearest, "32 or more enemies in the field: only the nearest 8 cast (%d)" % n)
	c.set_shadow_policy(3, 2, false)
	draw(c, 10)
	n = 0
	for k in 40:
		n += 1 if info(c, 200 + k).shadow else 0
	check(n == 2, "the budgets are settable (%d)" % n)
	# the level of detail by distance from the camera: the robber has 2 levels (the second from 30 m), the skeleton 3 (30 m and 60 m)
	var l := new_crowd()
	l.set_shadow_policy(0, 0, false)
	var spots := {ROBBER: [Vector2(0, 10), Vector2(2, -9), Vector2(4, -70)], SKELETON: [Vector2(0, 12), Vector2(2, -20), Vector2(4, -45), Vector2(6, -90)]}
	var id := 1
	var all := []
	for m in spots:
		for p in spots[m]:
			all.append(body(id, ENEMY if m == ROBBER else THRALL, m, IDLE if m == ROBBER else T_IDLE, p.x, p.y))
			id += 1
	feed(l, all)
	draw(l, 12)
	for m in spots:
		for p in spots[m]:
			var dist := Vector3(p.x - CAM.x, CAM.y, p.y - CAM.z).length()
			var want := 0 if dist < 30.0 else (1 if dist < 60.0 or m == ROBBER else 2)
			var rr := row_at(l, p.x, p.y)
			check(not rr.is_empty() and rr.model == m and rr.lod == want and not rr.shadow, "%s %.0f m from the camera is level %d" % ["robber" if m == ROBBER else "skeleton", dist, want])
	check(l.instance_count(ROBBER, 0) == 1 and l.instance_count(ROBBER, 1) == 2 and l.instance_count(SKELETON, 0) == 1 and l.instance_count(SKELETON, 1) == 1 and l.instance_count(SKELETON, 2) == 2,
		"the groups hold the split: robber 1 + 2, skeleton 1 + 1 + 2")


func interpolation() -> void:
	var c := new_crowd()
	c.set_shadow_policy(0, 0, false)
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 0, 0, {"speed": 3.0}), body(2, ENEMY, ROBBER, CHASE, 10, 10, {"speed": 3.0, "yaw": 0.0})])
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 0.05, 0.0, {"speed": 3.0}), body(2, ENEMY, ROBBER, CHASE, 10.0, 10.05, {"speed": 3.0})])
	draw(c, 12)   # past the first ranking: nothing casts
	for a in [0.0, 0.5, 1.0]:
		c.draw(0.0, a, CAM)
		var r1 := row_at(c, 0.05 * a, 0.0)
		var r2 := row_at(c, 10.0, 10.0 + 0.05 * a)
		check(not r1.is_empty() and near(r1.xf.origin.x, 0.05 * a, 1e-5) and not r2.is_empty() and near(r2.xf.origin.z, 10.0 + 0.05 * a, 1e-5), "alpha %.1f: the body is %.0f%% of the way between the last two ticks" % [a, a * 100.0])
	# the next tick: the old current becomes the previous
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 0.1, 0.0, {"speed": 3.0}), body(2, ENEMY, ROBBER, CHASE, 10.0, 10.1, {"speed": 3.0})])
	c.draw(0.0, 0.5, CAM)
	check(near(info(c, 1).pos.x, 0.075, 1e-5), "after another tick the pair is (0.05, 0.1): halfway is 0.075")
	# a jump over 3 m is not glided: teleports, a surfacing
	feed(c, [body(1, ENEMY, ROBBER, CHASE, 20.0, 0.0, {"speed": 3.0}), body(2, ENEMY, ROBBER, CHASE, 10.0, 10.1, {"speed": 3.0})])
	c.draw(0.0, 0.5, CAM)
	check(near(info(c, 1).pos.x, 20.0, 1e-5), "a body that jumps 20 m is drawn at the new place, not slid across the field")
	feed(c, [body(3, ENEMY, ROBBER, ERUPT, 0.0, 30.0)])
	feed(c, [body(3, ENEMY, ROBBER, EMERGE, 2.0, 30.0)])
	c.draw(0.0, 0.0, CAM)
	check(near(info(c, 3).pos.x, 2.0, 1e-5), "a burrower that surfaces appears at the aim (no glide from where it went under)")
	# the yaw interpolates the short way
	feed(c, [body(4, ENEMY, ROBBER, IDLE, 30, 0, {"yaw": 3.0})])
	feed(c, [body(4, ENEMY, ROBBER, IDLE, 30, 0, {"yaw": -3.0})])
	var worst := 0.0
	for f in 30:
		c.draw(DT, 0.5, CAM)
	check(absf(sin(info(c, 4).yaw)) < 0.3, "yaw is interpolated across pi (%.2f)" % info(c, 4).yaw)


# ---------------------------------------------------------------------------------------------------------------------- crowd cost

## The game's camera (world.json: fov 40, near 0.5, far 260, 22 m away at 0.82 up and 0.6 back, looking just past the hero): a real Camera3D, so the view the crowd gets and the planes
## it is held against are the engine's own, as CrowdView passes them.
func make_camera() -> void:
	var screen := SubViewport.new()   # a 16:9 screen (the headless window is square)
	screen.size = Vector2i(1280, 720)
	root.add_child(screen)
	cam = Camera3D.new()
	cam.fov = 40.0
	cam.near = 0.5
	cam.far = 260.0
	cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF   # as DmCameraRig: it is moved from _process, and its transform is its place
	screen.add_child(cam)
	cam.global_position = Vector3(0.0, 22.0 * 0.82, 22.0 * 0.6)
	cam.look_at(Vector3(0.0, 0.6, -1.5), Vector3.UP)


func cam_xf() -> Transform3D:
	return cam.get_camera_transform()


## What CrowdView hands DmCrowd.draw: the camera's projection times the inverse of its transform.
func view_proj() -> Projection:
	return cam.get_camera_projection() * Projection(cam.get_camera_transform().affine_inverse())


## draw() with the game camera's view, `n` frames.
func draw_view(c: RefCounted, n: int, dt: float = DT, alpha: float = 0.0) -> void:
	var vp := view_proj()
	var at := cam_xf().origin
	for i in n:
		c.draw(dt, alpha, at, vp)
		clock_ms += dt * 1000.0


## The position a row is drawn at, as a key (centimetres): rows carry no id.
func spot(x: float, z: float) -> Vector2i:
	return Vector2i(roundi(x * 100.0), roundi(z * 100.0))


## The worst (largest) distance beyond any of the engine's frustum planes: <= 0 inside, > 0 outside by that much.
func outside_by(planes: Array, p: Vector3) -> float:
	var worst := -INF
	for pl: Plane in planes:
		worst = maxf(worst, pl.distance_to(p))
	return worst


## Bodies outside the camera's view are not written: against the engine's own frustum planes on random bodies (a body inside is always drawn, one farther out than its bounding
## sphere never is), the drawn range packed (buffer() holds exactly the drawn rows), the counters adding up, and no view or culling off drawing everything.
func culling_and_packing() -> void:
	var planes: Array = cam.get_frustum()
	check(planes.size() == 6 and planes.all(func(pl: Plane) -> bool: return pl.distance_to(Vector3(0.0, 0.6, -1.5)) <= 0.0), "the engine's frustum planes face outward (the look-at point is inside all six)")
	var c := new_crowd()
	c.set_shadow_policy(0, 0, false)
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var bodies := []
	var spots: Array[Vector2] = []
	for i in 240:
		var p := Vector2(rng.randf_range(-45.0, 45.0), rng.randf_range(-45.0, 45.0))
		spots.append(p)
		bodies.append(body(1000 + i, ENEMY, ROBBER, IDLE, p.x, p.y))
	feed(c, bodies)
	draw_view(c, 12)   # past the first ranking: nobody casts
	var rr: float = data["grave_robber"].bounding_radius() + 0.75   # the body's sphere at scale 1, and the slack for its body layer
	var drawn_at := {}
	for r in rows(c):
		drawn_at[spot(r.xf.origin.x, r.xf.origin.z)] = true
	var inside := 0
	var beyond := 0
	var margin := 0
	var wrong := 0
	for p in spots:
		var d := outside_by(planes, Vector3(p.x, 0.0, p.y))
		var drawn: bool = drawn_at.has(spot(p.x, p.y))
		if d <= 0.0:
			inside += 1
			wrong += 0 if drawn else 1
		elif d > rr + 0.01:
			beyond += 1
			wrong += 1 if drawn else 0
		else:
			margin += 1
	var st: Dictionary = c.stats()
	check(wrong == 0, "no body in view is culled and none beyond its sphere is drawn (%d wrong)" % wrong)
	check(inside >= 10 and beyond >= 100 and margin >= 5, "the random field has bodies inside (%d), beyond the margin (%d) and in it (%d)" % [inside, beyond, margin])
	check(st.drawn == drawn_at.size() and st.drawn + st.culled == 240 and st.culled >= beyond, "drawn %d + culled %d = 240 bodies, none lost (%d beyond the margin)" % [st.drawn, st.culled, beyond])
	var counted := 0
	for l in lods[ROBBER]:
		counted += c.instance_count(ROBBER, l, false)
		check(c.buffer(ROBBER, l, false).size() == c.instance_count(ROBBER, l, false) * 20, "level %d: the buffer holds exactly its drawn rows (packed, no gap)" % l)
	check(counted == st.drawn, "the groups hold the %d drawn instances" % st.drawn)
	var tris := 0
	var used := 0
	for l in lods[ROBBER]:
		tris += c.instance_count(ROBBER, l, false) * int(data["grave_robber"].lod_triangles[l])
		used += 1 if c.instance_count(ROBBER, l, false) > 0 else 0
	check(st.triangles == tris and st.casting_triangles == 0 and st.groups_used == used and st.groups_casting == 0 and tris > 0, "the counters name the triangles (%d) and the MultiMeshes (%d) drawn, none casting" % [st.triangles, st.groups_used])
	print("INFO culling: %d of 240 random bodies drawn (%d inside the frustum, %d in the margin)" % [st.drawn, inside, margin])
	# no view: everything is drawn; culling off: the view is ignored
	c.draw(DT, 0.0, cam_xf().origin)
	check(c.stats().drawn == 240 and c.stats().culled == 0, "a draw without a view writes every body")
	c.set_culling(false)
	draw_view(c, 1)
	check(c.stats().drawn == 240 and c.stats().culled == 0, "culling off writes every body whatever the view")
	c.set_culling(true)
	draw_view(c, 1)
	check(c.stats().drawn == drawn_at.size(), "culling back on culls again")
	# a body walks out of the view and back: it is not drawn while out, and drawn again at once
	var w := new_crowd()
	w.set_shadow_policy(0, 0, false)
	feed(w, [body(1, ENEMY, ROBBER, IDLE, 0.0, 0.0)])
	draw_view(w, 12)
	check(w.instance_count(ROBBER, 0) + w.instance_count(ROBBER, 1) == 1, "a body in front of the camera is drawn")
	feed(w, [body(1, ENEMY, ROBBER, IDLE, 90.0, 0.0)])   # 90 m to the side in one tick (a teleport: not glided)
	draw_view(w, 1)
	check(w.stats().drawn == 0 and w.stats().culled == 1, "a body 90 m to the side is not drawn")
	feed(w, [body(1, ENEMY, ROBBER, IDLE, 0.0, 0.0)])
	draw_view(w, 1)
	check(w.stats().drawn == 1 and w.stats().culled == 0, "and drawn again the frame it is back")
	# a model's bounding sphere: the baked bounds' farthest corner from the feet
	for slug in SLUGS:
		var d: CrowdVatData = data[slug]
		var lo := d.aabb.position
		var hi := d.aabb.end
		var far := Vector3(maxf(absf(lo.x), absf(hi.x)), maxf(absf(lo.y), absf(hi.y)), maxf(absf(lo.z), absf(hi.z))).length()
		check(near(d.bounding_radius(), far, 1e-5) and near(d.crowd_data().radius, far, 1e-5) and d.bounding_radius() >= d.height * 0.5, "%s: bounding radius %.2f m (height %.2f m, bounds %s)" % [slug, d.bounding_radius(), d.height, d.aabb])


## A shadow caster just outside the view stays while its shadow falls in: the light-space test (the sphere swept along the light to the ground), and the margin when the
## light's direction is not known. A body that does not cast is culled as any other.
func shadow_reach() -> void:
	var planes: Array = cam.get_frustum()
	var rr: float = data["grave_robber"].bounding_radius() + 0.75
	var spot_x := -32.0   # well beyond the left edge of the view at the hero's depth (about -14 m)
	check(outside_by(planes, Vector3(spot_x, 0.0, 0.0)) > rr + 4.0, "the test spot is outside the view by more than its sphere (%.1f m)" % outside_by(planes, Vector3(spot_x, 0.0, 0.0)))
	var cases := [
		{"what": "the light travels toward the view", "light": Vector3(1.0, -0.15, 0.0), "casts": true, "drawn": true},
		{"what": "the light travels away from the view", "light": Vector3(-1.0, -0.15, 0.0), "casts": true, "drawn": false},
		{"what": "the same light, a body that does not cast", "light": Vector3(1.0, -0.15, 0.0), "casts": false, "drawn": false},
		{"what": "a light from straight above", "light": Vector3(0.0, -1.0, 0.0), "casts": true, "drawn": false},
	]
	for k in cases:
		var c := new_crowd()
		c.set_focus(Vector2(spot_x, 0.0))
		c.set_shadow_policy(1 if k.casts else 0, 1 if k.casts else 0, false)
		c.set_shadow_light(k.light)
		feed(c, [body(1, ENEMY, ROBBER, IDLE, spot_x, 0.0)])
		draw_view(c, 12)
		check(info(c, 1).shadow == k.casts, "%s: the body %s" % [k.what, "casts" if k.casts else "does not cast"])
		check((c.stats().drawn == 1) == k.drawn, "%s: the body is %s (%d drawn)" % [k.what, "drawn" if k.drawn else "culled", c.stats().drawn])
		if k.casts and k.drawn:
			check(c.instance_count(ROBBER, 0, true) + c.instance_count(ROBBER, 1, true) == 1 and c.stats().casting == 1, "%s: it is drawn in a shadow group" % k.what)
	# the light's direction is not known: a caster is kept within 12 m past the edge, culled beyond it
	for k in [{"x": -20.0, "drawn": true}, {"x": -50.0, "drawn": false}]:
		var c := new_crowd()
		c.set_focus(Vector2(k.x, 0.0))
		c.set_shadow_policy(1, 1, false)
		feed(c, [body(1, ENEMY, ROBBER, IDLE, k.x, 0.0)])
		draw_view(c, 12)
		check(info(c, 1).shadow and (c.stats().drawn == 1) == k.drawn, "no light known: a caster %.0f m to the side is %s (outside by %.1f m)" % [k.x, "kept" if k.drawn else "culled", outside_by(planes, Vector3(k.x, 0.0, 0.0))])
	# the thralls that always cast: counted, and the setting takes them out
	var c := new_crowd()
	var thr := []
	for i in 12:
		thr.append(body(10 + i, THRALL, SKELETON, T_IDLE, float(i) - 6.0, 2.0))
	feed(c, thr)
	draw_view(c, 12)
	check(c.stats().casting == 12 and c.stats().casting_thralls == 12, "12 thralls cast: the counter says %d (%d thralls)" % [c.stats().casting, c.stats().casting_thralls])
	var per_thrall: int = data["skeleton_thrall"].lod_triangles[0]
	check(c.stats().casting_triangles == 12 * per_thrall and c.stats().triangles == 12 * per_thrall and c.stats().groups_casting == 1 and c.stats().groups_used == 1,
		"and the shadow pass takes their %d triangles in %d MultiMesh" % [c.stats().casting_triangles, c.stats().groups_casting])
	c.set_shadow_policy(12, 8, false)
	draw_view(c, 1)
	check(c.stats().casting == 0 and c.stats().casting_thralls == 0 and c.stats().casting_triangles == 0 and c.stats().groups_casting == 0 and c.stats().triangles == 12 * per_thrall,
		"thralls set not to cast: the counter says %d, and the same %d triangles are drawn" % [c.stats().casting, c.stats().triangles])
	check(not c.settings().thrall_shadows and c.settings().shadow_casters == 12 and c.settings().shadow_casters_crowded == 8, "the settings say what is in force")
	c.set_shadow_policy(12, 8, true)
	draw_view(c, 1)
	check(c.stats().casting == 12, "and back on: %d cast" % c.stats().casting)


## The pose of a body far from the camera is worked out less often: 24 times a second beyond 32 m, 10 beyond 60 m, every frame nearer; the body is placed every frame
## whatever its band; a tick that changes its state, look or health shows at once; one that was outside the view keeps the far rate and is brought up to date on its way back.
func animation_bands() -> void:
	var near_z := -5.0    # distance to the camera (0, 22, 14): 29 m, 40 m, 63 m
	var mid_z := -20.0
	var far_z := -45.0
	check(Vector3(0.0, 22.0, near_z - 14.0).length() < 32.0 and Vector3(0.0, 22.0, mid_z - 14.0).length() > 32.0 and Vector3(0.0, 22.0, mid_z - 14.0).length() < 60.0 and Vector3(0.0, 22.0, far_z - 14.0).length() > 60.0, "the three test spots are in the near, mid and far band")
	var c := new_crowd()
	c.set_shadow_policy(0, 0, false)
	c.set_anim_lod(true, 32.0, 24.0, 60.0, 10.0)
	var twin := new_crowd()   # the same bodies with the bands off: every frame, as ever
	twin.set_shadow_policy(0, 0, false)
	feed(c, [body(1, ENEMY, ROBBER, IDLE, 0.0, near_z), body(2, ENEMY, ROBBER, IDLE, 3.0, mid_z), body(3, ENEMY, ROBBER, IDLE, 6.0, far_z)])
	feed(twin, [body(1, ENEMY, ROBBER, IDLE, 0.0, near_z), body(2, ENEMY, ROBBER, IDLE, 3.0, mid_z), body(3, ENEMY, ROBBER, IDLE, 6.0, far_z)])
	var frames := 120
	var times := {1: [], 2: [], 3: []}
	var twin_times := {1: [], 2: [], 3: []}
	var place := {1: Vector2(0.0, near_z), 2: Vector2(3.0, mid_z), 3: Vector2(6.0, far_z)}
	var bands_ok := true
	for f in frames:
		c.draw(DT, 0.0, CAM)
		twin.draw(DT, 0.0, CAM)
		clock_ms += DT * 1000.0
		bands_ok = bands_ok and c.stats().band_near == 1 and c.stats().band_mid == 1 and c.stats().band_far == 1
		for id in place:
			times[id].append(row_at(c, place[id].x, place[id].y).custom.g)
			twin_times[id].append(row_at(twin, place[id].x, place[id].y).custom.g)
	check(bands_ok, "one live body in each band, every frame")
	var steps := {}
	for id in [1, 2, 3]:
		var n := 0
		for i in range(1, frames):
			n += 1 if not is_equal_approx(times[id][i], times[id][i - 1]) else 0
		steps[id] = n
	var upd := {1: info(c, 1).pose_updates, 2: info(c, 2).pose_updates, 3: info(c, 3).pose_updates}
	check(upd[1] == frames, "the near body works its pose out every frame (%d of %d)" % [upd[1], frames])
	check(upd[2] >= 48 and upd[2] <= 50, "the mid body 24 times a second: %d pose updates in %d frames at 60 Hz (48 + its first)" % [upd[2], frames])
	check(upd[3] >= 20 and upd[3] <= 22, "the far body 10 times a second: %d pose updates in %d frames (20 + its first)" % [upd[3], frames])
	check(steps[1] == frames - 1 and absi(steps[2] - 48) <= 2 and absi(steps[3] - 20) <= 2, "the time written to the instance steps %d, %d and %d times (every frame, 24 Hz, 10 Hz)" % [steps[1], steps[2], steps[3]])
	# the time a throttled body writes is the time the full-rate twin had at that moment, a little behind: never ahead, and by less than the gap between its updates
	var lag := {2: 0.0, 3: 0.0}
	var ahead := false
	for id in [2, 3]:
		for i in frames:
			var gap: float = twin_times[id][i] - times[id][i]
			if absf(gap) > 5.0:   # a loop wrapped between the two
				continue
			ahead = ahead or gap < -1e-4
			lag[id] = maxf(lag[id], gap)
	print("INFO animation bands over %d frames at 60 Hz: pose updates near %d, mid %d, far %d; the written time lags at most %.3f s (mid), %.3f s (far)" % [frames, upd[1], upd[2], upd[3], lag[2], lag[3]])
	check(not ahead and lag[2] <= 0.06 and lag[3] <= 0.12 and lag[3] > 0.0, "a throttled body's time is never ahead of the full-rate body's and lags by at most %.3f s (24 Hz) and %.3f s (10 Hz)" % [lag[2], lag[3]])
	# the number of poses worked out a frame is spread, not bunched: 30 mid bodies, a tick of frames
	var m := new_crowd()
	m.set_shadow_policy(0, 0, false)
	m.set_anim_lod(true, 32.0, 24.0, 60.0, 10.0)
	var herd := []
	for i in 30:
		herd.append(body(100 + i, ENEMY, ROBBER, IDLE, float(i) * 1.5 - 20.0, mid_z))
	feed(m, herd)
	m.draw(DT, 0.0, CAM)
	check(m.stats().pose_updates == 30, "the first frame brings every body's pose up (%d)" % m.stats().pose_updates)
	var peak := 0
	var total := 0
	for f in 120:
		m.draw(DT, 0.0, CAM)
		peak = maxi(peak, m.stats().pose_updates)
		total += m.stats().pose_updates
	print("INFO 30 mid-band bodies: %d pose updates in 120 frames, at most %d in one frame" % [total, peak])
	check(peak <= 18 and absi(total - 30 * 48) <= 30 * 2, "30 mid bodies: at most %d poses a frame (of 30), %d over 120 frames (30 x 48 = 1440)" % [peak, total])
	# placed every frame: a far body walking draws at its interpolated place each frame, its pose rate notwithstanding
	var p := new_crowd()
	p.set_shadow_policy(0, 0, false)
	p.set_anim_lod(true, 32.0, 24.0, 60.0, 10.0)
	feed(p, [body(1, ENEMY, ROBBER, CHASE, 0.0, far_z, {"speed": 3.0})])
	feed(p, [body(1, ENEMY, ROBBER, CHASE, 0.05, far_z, {"speed": 3.0})])
	var smooth := true
	var pose_steps := 0
	var last_t := -1.0
	for f in 24:
		p.draw(DT, float(f % 4) / 4.0, CAM)
		var want := 0.05 * float(f % 4) / 4.0
		smooth = smooth and near(info(p, 1).pos.x, want, 1e-5)
		var r := row_at(p, want, far_z)
		smooth = smooth and not r.is_empty()
		if not r.is_empty():
			pose_steps += 1 if not is_equal_approx(r.custom.g, last_t) else 0
			last_t = r.custom.g
	check(smooth and pose_steps < 12, "a far walking body is drawn at its interpolated place every frame while its pose steps %d times in 24 frames" % pose_steps)
	# a tick that changes the state shows at once: a swing begins, a hit flashes
	var e := new_crowd()
	e.set_shadow_policy(0, 0, false)
	e.set_anim_lod(true, 32.0, 24.0, 60.0, 10.0)
	feed(e, [body(1, ENEMY, ROBBER, IDLE, 0.0, far_z), body(2, ENEMY, ROBBER, IDLE, 4.0, far_z)])
	e.draw(DT, 0.0, CAM)
	for f in 7:   # settle on an off-beat frame of the 10 Hz band
		e.draw(DT, 0.0, CAM)
	feed(e, [body(1, ENEMY, ROBBER, ATTACK, 0.0, far_z, {"action_s": 0.5}), body(2, ENEMY, ROBBER, IDLE, 4.0, far_z)], [[2, 5.0, 20.0, 30.0]])
	e.draw(DT, 0.0, CAM)
	var swing_clip: int = data["grave_robber"].clip_index(info(e, 1).clip)
	check(info(e, 1).clip.begins_with("attack") and int(row_at(e, 0.0, far_z).custom.r) == swing_clip, "a far body's swing is in the buffer on the frame its tick says so (%s, clip %d)" % [info(e, 1).clip, swing_clip])
	check(near(row_at(e, 4.0, far_z).color.a, 0.875, 1e-6), "and a far body's hit flashes on that frame, worn down by that frame only (%.3f)" % row_at(e, 4.0, far_z).color.a)
	# a swing, a flinch, a recoil is always every frame (DmCreature.busy), and the rate comes back when it is over
	var u0: int = info(e, 1).pose_updates
	for f in 24:
		e.draw(DT, 0.0, CAM)
	check(info(e, 1).one_shot != "" and info(e, 1).pose_updates - u0 == 24, "a far body in a swing works its pose out every frame (%d of 24)" % (info(e, 1).pose_updates - u0))
	for f in 120:
		e.draw(DT, 0.0, CAM)
	u0 = info(e, 1).pose_updates
	for f in 60:
		e.draw(DT, 0.0, CAM)
	check(info(e, 1).one_shot == "" and info(e, 1).pose_updates - u0 == 10, "and 10 times a second again once the swing is over (%d in 60 frames)" % (info(e, 1).pose_updates - u0))
	# near the hero nothing changes: the bands on or off write the same bytes
	var a := new_crowd()
	var b := new_crowd()
	a.set_shadow_policy(0, 0, false)
	b.set_shadow_policy(0, 0, false)
	a.set_anim_lod(true, 32.0, 24.0, 60.0, 10.0)
	var act := [body(1, ENEMY, ROBBER, CHASE, 0.0, -2.0, {"speed": 3.0}), body(2, THRALL, SKELETON, T_MOVE, 4.0, -8.0, {"speed": 4.0}), body(3, ENEMY, ROBBER, IDLE, -6.0, -6.0)]
	feed(a, act)
	feed(b, act)
	var same := true
	for f in 90:
		if f == 30:
			act[0].state = ATTACK
			act[0].action_s = 0.4
			feed(a, act, [[3, 4.0, 10.0, 30.0]])
			feed(b, act, [[3, 4.0, 10.0, 30.0]])
		clock_ms += 0.0
		a.draw(DT, float(f % 4) / 4.0, CAM)
		b.draw(DT, float(f % 4) / 4.0, CAM)
		same = same and buffers_equal(a, b)
	check(same and a.stats().band_near == 3, "bodies in the near band write the same buffers with the bands on or off (90 frames, a swing and a hit)")
	# outside the view: the far rate, and brought up to date on the way back
	var o := new_crowd()
	var ref := new_crowd()
	for q in [o, ref]:
		q.set_shadow_policy(0, 0, false)
	o.set_anim_lod(true, 32.0, 24.0, 60.0, 10.0)
	var away := [body(1, ENEMY, ROBBER, IDLE, 90.0, 0.0), body(2, ENEMY, ROBBER, IDLE, 0.0, -5.0)]
	feed(o, away)
	feed(ref, away)
	var vp := view_proj()
	var at := cam_xf().origin
	for f in 120:
		o.draw(DT, 0.0, at, vp)
		ref.draw(DT, 0.0, at)   # (no view, no bands: every body, every frame)
		clock_ms += DT * 1000.0
	check(o.stats().culled == 1 and o.stats().drawn == 1, "one body in view, one outside (%d drawn, %d culled)" % [o.stats().drawn, o.stats().culled])
	check(info(o, 1).pose_updates >= 20 and info(o, 1).pose_updates <= 22 and info(o, 2).pose_updates == 120, "outside the view: %d pose updates in 120 frames (the far rate, 10 a second); in view: %d" % [info(o, 1).pose_updates, info(o, 2).pose_updates])
	feed(o, [body(1, ENEMY, ROBBER, IDLE, 0.0, -4.0), body(2, ENEMY, ROBBER, IDLE, 0.0, -5.0)])
	feed(ref, [body(1, ENEMY, ROBBER, IDLE, 0.0, -4.0), body(2, ENEMY, ROBBER, IDLE, 0.0, -5.0)])
	o.draw(DT, 0.0, at, vp)
	ref.draw(DT, 0.0, at)
	check(o.stats().culled == 0 and o.stats().drawn == 2 and near(info(o, 1).time, info(ref, 1).time, 1e-4), "back in view: drawn at once, its clip time up to date (%.4f against %.4f)" % [info(o, 1).time, info(ref, 1).time])
	# the setting round trip and CrowdView's defaults
	var s: Dictionary = o.settings()
	check(s.anim_lod and s.culling and s.anim_mid_m == 32.0 and s.anim_mid_hz == 24.0 and s.anim_far_m == 60.0 and s.anim_far_hz == 10.0, "the settings say what is in force: %s" % str(s))
	var bare := new_crowd()
	check(not bare.settings().anim_lod and bare.settings().culling, "a bare DmCrowd draws every body every frame (the bands are CrowdView's to switch on)")


# ---------------------------------------------------------------------------------------------------------------------- the Full Party

const THRALL_BASE := {"warrior": [1.3, 1.0, 5.6], "shieldbearer": [1.3, 1.25, 5.2], "hound": [1.2, 0.7, 7.2], "wraith": [5.5, 1.1, 5.8],
	"archer": [7.5, 1.3, 5.4], "bonemage": [6.5, 1.8, 5.2], "plaguebearer": [1.3, 1.2, 4.8]}


var ally_owners: Array = []   # core hero ids whose thralls are another player's (full_party)


func full_party() -> void:
	var enemies_json: Dictionary = DmCoreData.json(data_dir.path_join("data/content/enemies.json"))
	var core: RefCounted = ClassDB.instantiate("DmCore")
	core.set_seed(77)
	DmCoreData.load_all(core, data_dir)
	core.set_wander(false)
	core.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	var view := CrowdView.new()
	view.auto_sync = false
	root.add_child(view)
	view.setup(core, enemies_json["ENEMIES"], Vector2(-60, -60), Vector2(60, 60), {"baked_dir": OUT, "assets_dir": live_assets, "champion_scale": CHAMPION_SCALE})
	var crowd: RefCounted = view.crowd
	check(view.model_slots() == {"grave_robber": 0, "bone_hound": 1, "skeleton_thrall": 2}, "the view's model slots are the ones this test knows (%s)" % str(view.model_slots()))
	var guest := new_crowd_from(view)   # the co-op guest: the same models, fed the rows instead of the core
	# the models: an unbaked one falls back to the nearest baked one, once, with a warning
	var w := Array(view.warnings)
	var unique := {}
	for s in w:
		unique[s] = true
	check(unique.size() == w.size(), "each fallback is listed once (%d)" % w.size())
	var looks_json: Dictionary = DmCoreData.json("res://crowd/crowd_looks.json")
	var stand_in := func(def: String) -> String:   # (the looks' own rig fallback, when it is one of the baked models)
		return "no baked model for %s: drawn as %s" % [looks_json["enemy_model"][def], looks_json["enemy_fallback"][def]]
	check(w.has(stand_in.call("ghoul")), "the ghoul falls back to its rig fallback in the looks (%s)" % stand_in.call("ghoul"))
	check(w.has("no baked model for censer_bearer: drawn as skeleton_thrall"), "a model with no baked stand-in of its rig is drawn as the skeleton")
	check(w.has(stand_in.call("rat")), "the rat (a quadruped) falls back to its rig fallback in the looks (%s)" % stand_in.call("rat"))
	check(not w.any(func(s: String) -> bool: return s.contains("grave_robber") and s.contains("no baked model for grave_robber")), "baked models are not listed")
	print("INFO %d model fallbacks, e.g. %s" % [w.size(), w[0]])
	# the party: 4 heroes, 8 thralls each, the global enemy cap of enemies. Nobody can hurt anybody, so the crowd stays that strong while it moves, swings and flinches.
	var n_enemies := int(DmCoreData.json(data_dir.path_join("data/content/areas.json"))["GLOBAL_ENEMY_CAP"])
	var n_bodies := n_enemies + 4 * 8
	var heroes := []
	for h in 4:
		var id: int = core.add_external(0, 0.4, 1.0)
		core.set_external(id, Vector2(-6.0 + 4.0 * h, 0.0), true)
		heroes.append(id)
	var legions := ["ossuary", "gravecaller", "rotweaver", "mourner"]
	var kinds := ["warrior", "warrior", "warrior", "shieldbearer", "hound", "wraith", "archer", "bonemage"]
	for h in 4:
		view.set_owner_legion(heroes[h], legions[h])
		view.set_owner_ally(heroes[h], h >= 2)   # the Rotweaver's and the Mourner's thralls are other players' (a weaker rim)
		if h >= 2:
			ally_owners.append(heroes[h])
		for k in 8:
			var b: Array = THRALL_BASE[kinds[k]]
			var tid: int = core.raise_thrall({"kind": kinds[k], "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": b[1], "range": b[0], "speed": b[2], "empowered": false,
				"champion": h == 1 and k == 0, "allyHeal": 0.0}, heroes[h], Vector2(-6.0 + 4.0 * h + float(k) - 3.0, 3.0), 0.0, 20.0)
			check(tid != 0, "thrall raised")
	var defs := ["robber", "robber", "hound", "ghoul", "wraith", "robber", "hound", "robber"]
	var ids := []
	for e in n_enemies:
		var a := float(e) / float(n_enemies) * TAU
		var pos := Vector2(cos(a), sin(a)) * (12.0 + float(e % 5) * 1.5)
		ids.append(core.spawn_enemy(defs[e % defs.size()], pos, 1, 1000.0, 0.0, e % 24 == 5, "graves", e % 9 == 0))
	view.focus = Vector2(0, 0)
	for f in 150:   # warm up: the rise is over, the fight is on
		lockstep(core, view, guest, 0.5)
	var st: Dictionary = crowd.stats()
	check(st.bodies == n_bodies and st.live == n_bodies, "all %d bodies have a view (%d)" % [n_bodies, st.bodies])
	var drawn := 0
	for m in 3:
		for l in lods[m]:
			drawn += crowd.instance_count(m, l, false) + crowd.instance_count(m, l, true) + crowd.instance_count(m, l, false, true)
	var hidden := 0
	for id in ids:
		hidden += 1 if crowd.view_info(id).hidden else 0
	check(drawn == n_bodies - hidden and st.drawn == drawn, "%d creatures, %d instances (%d drawn, %d underground)" % [n_bodies, n_bodies, drawn, hidden])
	# looks: an elite is larger, a champion thrall bigger, a risen one dull
	var elite_id: int = ids[5]
	var elite_scale := float(enemies_json["ELITE"]["scale"])
	check(near(crowd.view_info(elite_id).scale, 1.0 * elite_scale, 1e-6), "an elite is drawn ELITE.scale x (%s)" % crowd.view_info(elite_id).scale)
	var seen_champion := false
	for tid in core.thrall_ids():
		if near(crowd.view_info(tid).scale, CHAMPION_SCALE, 1e-6):
			seen_champion = true
	check(seen_champion, "a champion thrall is drawn %sx (the option the view was given)" % CHAMPION_SCALE)
	glows(view, crowd, core, ids, heroes)
	# Full Party, the core stepping, one tick and one frame each
	var regrows0: int = crowd.stats().regrows
	var same := true
	var rows_seen := 0
	var states := {}
	for f in 300:
		core.step(DT)
		view.sync()
		var alpha := float(f % 4) / 4.0
		crowd.draw(DT, alpha, CAM)
		clock_ms += DT * 1000.0
		var lf: Dictionary = crowd.last_feed()
		guest.sync_rows(lf.body_ints, lf.body_floats, lf.hits, lf.corpse_ints, lf.corpse_floats)
		guest.draw(DT, alpha, CAM)
		core.take_events()
		if f % 10 == 0:
			rows_seen += int(crowd.stats().drawn)
			same = same and buffers_equal(crowd, guest)
		if f % 15 == 0:
			for id in ids:
				var vv: Dictionary = crowd.view_info(id)
				states[vv.clip + ("*" if vv.one_shot != "" else "")] = true
	check(same and rows_seen > 1500, "a crowd fed the same rows (a co-op guest's snapshots) draws the same buffers (%d instance rows compared)" % rows_seen)
	check(states.has("walk") and states.has("idle") and states.keys().any(func(k: String) -> bool: return k.begins_with("attack") and k.ends_with("*")), "the party fights: %s" % str(states.keys()))
	print("INFO the Full Party run grew the buffers %d times (a new peak in a group)" % (crowd.stats().regrows - regrows0))
	# a steady crowd: the same bodies for 300 frames (no tick, the frame time and interpolation changing): the buffers do not grow
	var before: Dictionary = crowd.stats()
	for f in 300:
		crowd.draw([DT, 0.004, 0.03, 0.0][f % 4], float(f % 7) / 7.0, CAM)
	var after: Dictionary = crowd.stats()
	check(after.capacity_floats == before.capacity_floats and after.regrows == before.regrows and after.drawn == before.drawn, "no growth in the buffers over 300 steady frames (%d floats, %d regrows)" % [after.capacity_floats, after.regrows])
	crowd_cost_in_the_party(crowd)
	cost_options(view)
	# sync reads the events and leaves them for take_events
	core.step(DT)
	core.damage(ids[3], 30.0, heroes[0])
	core.damage(ids[4], 30.0, heroes[0])
	view.sync()
	var raw: Array = core.take_events()
	var evs: PackedInt32Array = raw[0]
	var damaged := 0
	var k := 0
	while k < evs.size():
		damaged += 1 if evs[k] == EV_DAMAGED else 0
		k += 4 + evs[k + 2]
	check(damaged == 2, "sync leaves the events for take_events (%d damaged events came out)" % damaged)
	var hit: Dictionary = crowd.view_info(ids[4])
	check(hit.flash == 1.0 and hit.kick_t >= 0.0, "the hit flashed and recoiled the body it hit")
	var kn1 := Vector4(hit.knock)
	view.sync()   # nothing was taken and nothing new added in between: the same hit must not count twice
	check(Vector4(crowd.view_info(ids[4]).knock) == kn1, "a second sync over the same buffer does not apply a hit again")
	core.take_events()
	core.step(DT)
	core.damage(ids[4], 1.0, heroes[0])
	view.sync()
	check(near(Vector4(crowd.view_info(ids[4]).knock).z, kn1.z, 1.0) and crowd.view_info(ids[4]).flash == 1.0, "after take_events the next hits are read from the start of the buffer")
	core.take_events()
	# a kill: the dying body and the core's corpse become one view
	var victim: int = ids[10]
	var vdef: String = core.enemy_info(victim).def
	core.damage(victim, 1.0e9, heroes[0])
	core.step(DT)
	view.sync()
	core.take_events()
	var cids: PackedInt32Array = core.corpse_ids()
	var adopted := 0
	for cid in cids:
		var cv: Dictionary = crowd.view_info(cid, true)
		adopted += 1 if not cv.is_empty() and cv.id == victim else 0
	check(vdef == "hound" and adopted == 1, "the core's corpse took the dying %s (%d corpses, %d adopted)" % [vdef, cids.size(), adopted])
	check(crowd.view_info(victim).mode in ["corpse", "fading", "dying"], "the killed enemy is no longer live")
	# the corpse is consumed: the view sinks
	for cid in cids:
		core.corpse_consume(cid, heroes[0])
	view.sync()
	core.take_events()
	check(crowd.stats().corpses == 0 and crowd.stats().fading >= (1 if adopted == 1 else 0), "a consumed corpse sinks away")
	# the node itself: its physics step syncs once per core step and its process draws
	view.auto_sync = true
	var bodies0: int = crowd.stats().bodies
	var frames0: int = crowd.stats().frames
	core.spawn_enemy("robber", Vector2(3, 3), 1, 1.0, 0.0, false, "graves", false)
	core.step(DT)
	await physics_frame
	await process_frame
	check(crowd.stats().bodies == bodies0 + 1, "the node syncs by itself after the core's step (%d bodies, one more)" % crowd.stats().bodies)
	check(crowd.stats().frames > frames0, "and draws every rendered frame")
	groups_follow_instances(view, crowd)
	view.queue_free()
	await process_frame


## The Full Party at the game's camera, and with the camera 10 m to the side (a part of the party out of the view): what culling and the thralls' shadows do to the counts
## (deterministic; the same numbers on any machine).
func crowd_cost_in_the_party(crowd: RefCounted) -> void:
	var xf := cam_xf()
	var aside := Transform3D(xf.basis, xf.origin + Vector3(10.0, 0.0, 0.0))
	var vp_aside := cam.get_camera_projection() * Projection(aside.affine_inverse())
	crowd.draw(DT, 0.0, xf.origin)
	var all: Dictionary = crowd.stats()
	crowd.draw(DT, 0.0, xf.origin, view_proj())
	var home: Dictionary = crowd.stats()
	check(home.drawn + home.culled == all.drawn and all.culled == 0, "the Full Party at the game's camera: %d of %d bodies drawn, %d outside the view" % [home.drawn, all.drawn, home.culled])
	crowd.draw(DT, 0.0, aside.origin, vp_aside)
	var cut: Dictionary = crowd.stats()
	check(cut.culled > 0 and cut.drawn > 0 and cut.drawn + cut.culled == all.drawn, "the camera 10 m to the side: %d of %d bodies drawn, %d outside the view" % [cut.drawn, all.drawn, cut.culled])
	var shadow_rows := 0
	for m in 3:
		for l in lods[m]:
			shadow_rows += crowd.instance_count(m, l, true)
	check(cut.casting == shadow_rows and cut.casting_thralls <= 32 and cut.casting >= cut.casting_thralls, "the casting counter (%d, %d of them thralls) is the shadow groups' instances (%d)" % [cut.casting, cut.casting_thralls, shadow_rows])
	var crowded_casters := int(crowd.settings().shadow_casters_crowded)   # the party is a crowd (32 or more enemies): that many enemies cast
	check(all.casting == crowded_casters + 32 and all.casting_thralls == 32, "uncut, %d enemies and 32 thralls cast (%d, %d thralls)" % [crowded_casters, all.casting, all.casting_thralls])
	crowd.set_shadow_policy(12, 8, false)
	crowd.draw(DT, 0.0, xf.origin)
	var bare: Dictionary = crowd.stats()
	check(bare.casting_thralls == 0 and bare.casting == all.casting - all.casting_thralls and bare.drawn == all.drawn, "thralls not casting: %d instances cast (%d with them), the same %d drawn" % [bare.casting, all.casting, bare.drawn])
	crowd.set_shadow_policy(12, 8, true)
	crowd.draw(DT, 0.0, xf.origin)
	check(crowd.stats().casting == all.casting, "and casting again: %d" % crowd.stats().casting)
	print("INFO Full Party: %d bodies; at the game's camera %d drawn, %d outside; the camera 10 m aside %d drawn, %d outside; %d instances cast shadows (%d thralls), %d without the thralls'; poses worked out %d of %d (bands near/mid/far %d/%d/%d)" % [
		all.bodies, home.drawn, home.culled, cut.drawn, cut.culled, all.casting, all.casting_thralls, bare.casting, cut.pose_updates, cut.band_near + cut.band_mid + cut.band_far, cut.band_near, cut.band_mid, cut.band_far])
	print("INFO Full Party shadows: %d MultiMeshes of %d, %d k triangles drawn and %d k of them again in the shadow pass; the thralls' shadows are %d k of those, %d MultiMeshes" % [
		all.groups_casting, all.groups_used, all.triangles / 1000, all.casting_triangles / 1000, (all.casting_triangles - bare.casting_triangles) / 1000, all.groups_casting - bare.groups_casting])


## CrowdView's cost options (setup, or a benchmark's `--bench-crowd`): each key changes the crowd's settings, a key that is not there takes its default, and the thrall shadows
## override beats the graphics preset's whether thralls cast.
func cost_options(view: CrowdView) -> void:
	var s: Dictionary = view.crowd.settings()
	check(s.culling and s.anim_lod and s.anim_mid_m == 32.0 and s.anim_mid_hz == 24.0 and s.anim_far_m == 60.0 and s.anim_far_hz == 10.0 and s.thrall_shadows and s.reserve == CrowdView.RESERVE and view.thrall_shadows == -1,
		"CrowdView's defaults: culling on, the bands 24 Hz from 32 m and 10 Hz from 60 m, the preset's thrall shadows, %d reserved (%s)" % [CrowdView.RESERVE, str(s)])
	view.apply_cost({"cull": false, "anim_lod": {"mid_hz": 12.0, "far_m": 80.0}, "thrall_shadows": false})
	s = view.crowd.settings()
	check(not s.culling and not view.cull and s.anim_lod and s.anim_mid_hz == 12.0 and s.anim_far_m == 80.0 and s.anim_far_hz == 10.0 and s.anim_mid_m == 32.0 and view.thrall_shadows == 0, "options: no culling, a 12 Hz mid band to 80 m (%s)" % str(s))
	view.set_shadow_policy(12, 8, true)   # the preset says thralls cast; the override says no
	check(not view.crowd.settings().thrall_shadows, "the thrall shadows override beats the graphics preset")
	view.apply_cost({"anim_lod": false})
	s = view.crowd.settings()
	check(view.cull and s.culling and not s.anim_lod and view.thrall_shadows == -1, "anim_lod false switches the bands off; a key that is not there takes its default (culling back on, the preset's thrall shadows)")
	view.set_shadow_policy(12, 8, true)
	check(view.crowd.settings().thrall_shadows, "and the preset decides the thrall shadows again")
	view.set_light_direction(Vector3(0.4, -0.86, -0.34))
	check(view.crowd.settings().light_known, "the moon's direction is known to the crowd")
	view.apply_cost({})


## The core steps once, the crowd reads it, the guest takes the same rows, both draw the frame, then the events are taken as the game layer does.
## Today's glows per body (DmEntityViews._enemy_opts / _make_thrall) through the palette: the slot in COLOR.a (slot * 2 + flash), the palette's colour and strength.
func glows(view: CrowdView, crowd: RefCounted, core: RefCounted, ids: Array, heroes: Array) -> void:
	var looks: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CrowdView.LOOKS_PATH))
	var pal: PackedColorArray = crowd.glow_palette()
	var glow_of := func(id: int) -> Color:
		var r: Dictionary = row_of(crowd, id)
		if r.is_empty():
			return Color(-1, -1, -1, -1)
		var slot := int(floor(float(r.color.a) * 0.5 + 0.001))
		return pal[slot] if slot > 0 and slot < pal.size() else Color(0, 0, 0, 0)
	var want := func(pair: Array, add := 0.0) -> Color:
		var c := CrowdView._glow(pair)
		c.a += add
		return c
	var same := func(a: Color, b: Color) -> bool: return a.is_equal_approx(b)
	check(pal.size() >= 2 and pal[0] == Color(0, 0, 0, 0), "the glow palette has slot 0 empty and the glows in play after it (%d)" % pal.size())
	check(same.call(glow_of.call(ids[5]), want.call(looks.enemy_glow.elite)), "an elite glows purple, as today (0x4a1f8a, 0.14): %s" % glow_of.call(ids[5]))
	check(same.call(glow_of.call(ids[4]), want.call(looks.enemy_glow.wraith)), "a wraith glows pale blue (0x9fb6d8, 0.35): %s" % glow_of.call(ids[4]))
	check(glow_of.call(ids[0]).a == 0.0, "a plain robber has no glow of its own")
	# the thralls (a body in a swing is drawn lunged, away from its place): the slots their instances use
	var tg: Dictionary = looks.thrall_glow
	var used := {}
	for r in rows(crowd):
		var slot := int(floor(float(r.color.a) * 0.5 + 0.001))
		if slot > 0 and slot < pal.size():
			used[pal[slot]] = true
	var has := func(c: Color) -> bool: return used.keys().any(func(k: Color) -> bool: return k.is_equal_approx(c))
	var gc_glow: Color = want.call([looks.legion.gravecaller.emissive, looks.legion.gravecaller.glow])
	check(has.call(gc_glow) and has.call(want.call([looks.legion.gravecaller.emissive, looks.legion.gravecaller.glow], float(tg.champion))),
		"a Gravecaller's thralls glow violet (0x6a3fc0, 0.16), its champion stronger (+0.35)")
	check(has.call(want.call(tg.wraith)), "a wraith thrall glows its own blue at 1.1")
	check(has.call(want.call([looks.legion.ossuary.emissive, looks.legion.ossuary.glow])) and has.call(want.call([looks.thrall_look.bonemage.emissive, looks.thrall_look.bonemage.glow])),
		"the Ossuary's thralls glow bronze (0x6b4a1f, 0.12), a bone mage its own (0xb07a2a, 0.35)")
	view._push_glows()
	var on_mat: Variant = view._materials[0].get_shader_parameter("glow_palette")
	check(on_mat is PackedVector4Array and (on_mat as PackedVector4Array).size() == CrowdView.SLOTS and Vector4(pal[1].r, pal[1].g, pal[1].b, pal[1].a).is_equal_approx((on_mat as PackedVector4Array)[1]),
		"every model's material has the glow palette (%d slots)" % CrowdView.SLOTS)
	rims(view, crowd, core, ids)


## The friend rim (DmEntityViews._make_thrall, DmCreatureMat): the palette slot of every thrall's instance carries the spirit colour at 0.9 for this player's thralls, 0.6 for
## another player's, a champion's gold at 1.4; no enemy has one; the materials have the rim palette; and the one palette slot channel does it all in the same MultiMeshes
## (a rim in a material of its own would split each group by its rim: the count is printed).
func rims(view: CrowdView, crowd: RefCounted, core: RefCounted, enemy_ids: Array) -> void:
	var looks: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CrowdView.LOOKS_PATH))
	var spirit := int(DmFxData.data()["spell_fx"]["exhume"]["spirit"])
	check(looks.thrall_rim.colour == "%06x" % spirit, "crowd_looks.json's rim colour is the spirit ring's, SPELL_FX exhume.spirit (0x%06x)" % spirit)
	check(looks.thrall_rim.own == 0.9 and looks.thrall_rim.ally == 0.6 and looks.thrall_rim.champion == 1.4 and looks.thrall_rim.champion_colour == "d9a441",
		"the strengths are today's THRALL_RIM_OWN 0.9, THRALL_RIM_ALLY 0.6, a champion's gold 1.4")
	var rim_pal: PackedColorArray = crowd.rim_palette()
	var glow_pal: PackedColorArray = crowd.glow_palette()
	check(rim_pal.size() == glow_pal.size() and rim_pal[0] == Color(0, 0, 0, 0), "the rim palette has the glow palette's slots, slot 0 empty (%d)" % rim_pal.size())
	var rim_of := func(id: int) -> Color:
		var r: Dictionary = row_of(crowd, id)
		if r.is_empty():
			return Color(-1, -1, -1, -1)
		return rim_pal[int(floor(float(r.color.a) * 0.5 + 0.001))]
	var spirit_c := CrowdView._color(looks.thrall_rim.colour)
	var gold_c := CrowdView._color(looks.thrall_rim.champion_colour)
	var bad := 0
	var seen := {}
	var drawn_thralls := 0
	for tid in core.thrall_ids():
		var info: Dictionary = core.thrall_info(tid)
		var got: Color = rim_of.call(tid)
		if got.a < 0.0:
			continue   # hidden or sinking: not an instance
		drawn_thralls += 1
		var ally: bool = int(info.owner) in ally_owners
		var want := Color(gold_c.r, gold_c.g, gold_c.b, 1.4) if bool(info.champion) else Color(spirit_c.r, spirit_c.g, spirit_c.b, 0.6 if ally else 0.9)
		if not got.is_equal_approx(want):
			bad += 1
	check(drawn_thralls > 0 and bad == 0, "every thrall's instance picks its rim: %d thralls found at their drawn places, %d wrong" % [drawn_thralls, bad])
	for r in rows(crowd):   # every instance (a thrall in a swing is drawn lunged, away from its place, and the lookup above skips it)
		var slot := int(floor(float(r.color.a) * 0.5 + 0.001))
		if rim_pal[slot].a > 0.0:
			seen[roundi(rim_pal[slot].a * 100.0)] = true
	check(seen.has(90) and seen.has(60) and seen.has(140), "all three rims are in play: this player's 0.9, another's 0.6, a champion's 1.4 (%s)" % str(seen.keys()))
	var enemy_rims := 0
	for id in enemy_ids:
		var got: Color = rim_of.call(id)
		enemy_rims += 1 if got.a > 0.0 else 0
	check(enemy_rims == 0, "no enemy has a rim (%d do)" % enemy_rims)
	var on_mat: Variant = view._materials[0].get_shader_parameter("rim_palette")
	var rr := rim_pal[1]
	check(on_mat is PackedVector4Array and (on_mat as PackedVector4Array).size() == CrowdView.SLOTS and Vector4(rr.r, rr.g, rr.b, rr.a).is_equal_approx((on_mat as PackedVector4Array)[1]),
		"every model's material has the rim palette")
	# The measure behind the choice of a channel: MultiMesh groups holding instances now, and what a material per rim would need (each group split by the rims in it).
	var now := 0
	var split := 0
	for m in lods.size():
		for l in lods[m]:
			for sh in [false, true]:
				var buf: PackedFloat32Array = crowd.buffer(m, l, sh)
				var variants := {}
				for i in buf.size() / 20:
					variants[rim_pal[int(floor(buf[i * 20 + 15] * 0.5 + 0.001))]] = true
				now += 1 if buf.size() > 0 else 0
				split += variants.size()
	check(split >= now, "the rim channel keeps %d MultiMeshes drawing (a material per rim would need %d, one instance float each stays the same 20)" % [now, split])
	print("INFO rim as a channel: %d draw groups, as a material per rim: %d" % [now, split])


## Thralls with hand props (DmEntityViews._make_thrall): a warrior with no legion or an armed one is drawn with the "<model>+warrior" variant when it is baked;
## a Rotweaver's (unarmed legion) stays bare; a kind whose variant is not baked keeps its plain body and says so once. A variant is never a stand-in for another model.
func armed_variants() -> void:
	var r: Dictionary = DmTestBake.bake(root, "skeleton_thrall+warrior", OUT.path_join("skeleton_thrall+warrior"), {"assets_dir": live_assets, "rows_path": rows_path})
	check(r.ok, "bake skeleton_thrall+warrior: %s" % r.get("error", ""))
	if not r.ok:
		return
	var enemies_json: Dictionary = DmCoreData.json(data_dir.path_join("data/content/enemies.json"))
	var core: RefCounted = ClassDB.instantiate("DmCore")
	DmCoreData.load_all(core, data_dir)
	core.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	var view := CrowdView.new()
	view.auto_sync = false
	root.add_child(view)
	view.setup(core, enemies_json["ENEMIES"], Vector2(-60, -60), Vector2(60, 60), {"baked_dir": OUT, "assets_dir": live_assets})
	var slots := view.model_slots()
	check(slots.has("skeleton_thrall+warrior"), "the warrior's variant is a model of the view (%s)" % str(slots.keys()))
	check(not Array(view.warnings).any(func(w: String) -> bool: return w.contains("drawn as skeleton_thrall+")), "a variant is never a stand-in for another model")
	check(view.warnings.has("no baked variant skeleton_thrall+archer: drawn without its hand props"), "an archer without its baked variant keeps its plain body, said once")
	# the variant draws with its plain body's very textures (one upload for both), its props through the track, and costs no extra MultiMesh: three a level (plain, shadow, fade), as a body
	var vd: CrowdVatData = view.data_of("skeleton_thrall+warrior")
	var pd: CrowdVatData = view.data_of("skeleton_thrall")
	var vmat := (view.get_node_or_null("skeleton_thrall+warrior_lod0") as MultiMeshInstance3D).material_override as ShaderMaterial
	check(vd.track_tex != null and vd.prop_count == 2 and pd.track_tex == null and vd.pos_tex == pd.pos_tex and vd.nrm_tex == pd.nrm_tex, "the warrior's variant draws with the plain body's very textures and a track of its own")
	check(vmat != null and vmat.get_shader_parameter("vat_pos") == pd.pos_tex and vmat.get_shader_parameter("vat_track") == vd.track_tex and (vmat.get_shader_parameter("trk_clips") as PackedVector4Array)[0] == vd.track_table[0],
		"its material has the body's textures, its track and the track's clip table")
	var groups := 0
	for c in view.get_children():
		groups += 1 if c.name.begins_with("skeleton_thrall+warrior_lod") else 0
	check(groups == 3 * vd.meshes.size(), "the variant is drawn in three MultiMeshes a level of detail (plain, shadow, fade), as a plain body: its props add none (%d)" % groups)
	var bare: int = core.add_external(0, 0.4, 1.0)
	var rot: int = core.add_external(0, 0.4, 1.0)
	view.set_owner_legion(rot, "rotweaver")
	var b: Array = THRALL_BASE["warrior"]
	var stats := {"kind": "warrior", "hp": 100.0, "maxHp": 100.0, "damage": 0.0, "attackInterval": b[1], "range": b[0], "speed": b[2], "empowered": false, "champion": false, "allyHeal": 0.0}
	var t_bare: int = core.raise_thrall(stats, bare, Vector2(0, 0), 0.0, 20.0)
	var t_rot: int = core.raise_thrall(stats, rot, Vector2(3, 0), 0.0, 20.0)
	for f in 3:
		core.step(DT)
		view.sync()
		view.crowd.draw(DT, 0.0, CAM)
		core.take_events()
	check(int(view.crowd.view_info(t_bare).model) == int(slots["skeleton_thrall+warrior"]), "a warrior with no legion carries its sword and shield (the variant)")
	check(int(view.crowd.view_info(t_rot).model) != int(slots["skeleton_thrall+warrior"]), "a Rotweaver's warrior is bare: its legion is unarmed")
	view.queue_free()
	# the Mourner's wraiths: a spectral model is see-through (the SPECTRAL shader) and never casts into the moon's shadow
	var rw: Dictionary = DmTestBake.bake(root, "wraith_thrall", OUT.path_join("wraith_thrall"), {"assets_dir": live_assets, "rows_path": rows_path})
	check(rw.ok, "bake wraith_thrall: %s" % rw.get("error", ""))
	if not rw.ok:
		return
	var v2 := CrowdView.new()
	v2.auto_sync = false
	root.add_child(v2)
	v2.setup(core, enemies_json["ENEMIES"], Vector2(-60, -60), Vector2(60, 60), {"baked_dir": OUT, "assets_dir": live_assets})
	var mourner: int = core.add_external(0, 0.4, 1.0)
	v2.set_owner_legion(mourner, "mourner")
	var wb: Array = THRALL_BASE["wraith"]
	var tw: int = core.raise_thrall({"kind": "wraith", "hp": 100.0, "maxHp": 100.0, "damage": 0.0, "attackInterval": wb[1], "range": wb[0], "speed": wb[2], "empowered": false,
		"champion": false, "allyHeal": 0.0}, mourner, Vector2(6, 0), 0.0, 20.0)
	for f in 3:
		core.step(DT)
		v2.sync()
		v2.crowd.draw(DT, 0.0, CAM)
		core.take_events()
	var slot := int(v2.model_slots().get("wraith_thrall", -1))
	check(slot >= 0 and int(v2.crowd.view_info(tw).model) == slot, "a Mourner's wraith is drawn with its own spectral model")
	var spectral := true
	var no_shadow := true
	for n in v2.get_children():
		var mmi := n as MultiMeshInstance3D
		if mmi != null and String(mmi.name).begins_with("wraith_thrall_"):
			spectral = spectral and (mmi.material_override as ShaderMaterial).shader.code.contains("#define SPECTRAL")
			no_shadow = no_shadow and mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	check(spectral and no_shadow, "its groups use the see-through shader and cast no shadow")
	var fades := 0
	for n in v2.get_children():
		fades += 1 if String(n.name).begins_with("wraith_thrall_") and String(n.name).ends_with("_fade") else 0
	check(fades == 0, "and it has no fade group: its plain group is see-through already (%d)" % fades)
	v2.queue_free()



## The Legion kit the thralls wear (the old game's `legion_kit_for`, now `CrowdView.set_owner_kit`): the warriors, shield bearers, archers and bone mages of an owner with a kit have a palette slot of their own
## that names the kit (`kit_of_slot`), whose entries (`kit_palette`) are the armour piece's tier colour at the looks' strength, its glow and the weapon's tier colour; a hound and an owner without a kit stay bare, owners with
## the same kit share a slot, and a kit survives `clear()` (the guest's baseline) as the legion and the ally mark do.
func kit_looks() -> void:
	var enemies_json: Dictionary = DmCoreData.json(data_dir.path_join("data/content/enemies.json"))
	var looks: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CrowdView.LOOKS_PATH))
	var core: RefCounted = ClassDB.instantiate("DmCore")
	DmCoreData.load_all(core, data_dir)
	core.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	var view := CrowdView.new()
	view.auto_sync = false
	root.add_child(view)
	view.setup(core, enemies_json["ENEMIES"], Vector2(-60, -60), Vector2(60, 60), {"baked_dir": OUT, "assets_dir": live_assets})
	var crowd: RefCounted = view.crowd
	var armor_id := "set_gravecaller_chest"
	var weapon_id := "sword_gold"
	var armor := DmGearProps.tier(armor_id, "epic")
	var weapon := DmGearProps.tier(weapon_id, "")
	var full := {"armor": [armor_id, "epic"], "weapon": [weapon_id, ""]}
	var owners := {}
	var thralls := {}
	for o in ["full", "armor", "bare"]:
		owners[o] = core.add_external(0, 0.4, 1.0)
		view.set_owner_legion(owners[o], "gravecaller")
		core.set_external(owners[o], Vector2(-12.0 + 12.0 * owners.size(), 0.0), true)
		for kind in ["warrior", "archer", "hound"]:
			var b: Array = THRALL_BASE[kind]
			thralls[o + "/" + kind] = core.raise_thrall({"kind": kind, "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": b[1], "range": b[0], "speed": b[2],
				"empowered": false, "champion": false, "allyHeal": 0.0}, owners[o], Vector2(-12.0 + 12.0 * owners.size() + 2.5 * float(thralls.size() % 3), 4.0), 0.0, 20.0)
	view.set_owner_kit(owners.full, full)
	view.set_owner_kit(owners.armor, {"armor": [armor_id, "epic"]})
	var settle := func() -> void:
		for f in 4:
			core.step(DT)
			view.sync()
			crowd.draw(DT, 0.0, CAM)
			core.take_events()
	for f in 70:   # the rise
		settle.call()
	var slot_of := func(key: String) -> int:
		var r: Dictionary = row_of(crowd, thralls[key])
		return int(floor(float(r.color.a) * 0.5 + 0.001)) if not r.is_empty() else -1
	var kit_of := func(key: String) -> int:
		var s: int = slot_of.call(key)
		var of: PackedFloat32Array = crowd.kit_of_slot()
		return int(of[s]) if s >= 0 and s < of.size() else -1
	var pal: PackedColorArray = crowd.kit_palette()
	var full_kit: int = kit_of.call("full/warrior")
	var armor_kit: int = kit_of.call("armor/warrior")
	check(full_kit > 0 and armor_kit > 0 and full_kit != armor_kit, "an owner's warriors wear a kit of their own (%d), a different kit from the armour-only owner's (%d)" % [full_kit, armor_kit])
	check(kit_of.call("full/archer") == full_kit and kit_of.call("armor/archer") == armor_kit, "its archers wear the same kit")
	check(kit_of.call("full/hound") == 0 and kit_of.call("bare/warrior") == 0 and kit_of.call("bare/archer") == 0, "a hound is bare whatever its owner wears, and so is an owner with no kit")
	check(pal.size() == CrowdView.KIT_SLOTS * 3 or pal.size() == 48, "the kit palette holds three entries a kit (%d)" % pal.size())
	if full_kit > 0 and armor_kit > 0:
		var want_armor := CrowdView._color("%06x" % int(armor.color))
		var strength := float(looks.kit.armor_strength)
		var a: Color = pal[full_kit * 3]
		check(Vector3(a.r, a.g, a.b).is_equal_approx(Vector3(want_armor.r, want_armor.g, want_armor.b)) and is_equal_approx(a.a, strength), "the armour piece's tier colour tints the chest and hands at the looks' strength (%s)" % str(a))
		var g: Color = pal[full_kit * 3 + 1]
		if int(armor.glow) >= 0:
			var wg := CrowdView._color("%06x" % int(armor.glow)) * float(looks.kit.glow_k)
			check(Vector3(g.r, g.g, g.b).is_equal_approx(Vector3(wg.r, wg.g, wg.b)) and g.a == 1.0, "a glowing piece lights the trim at the looks' fraction of its glow (%s)" % str(g))
		else:
			check(g.a == 0.0, "a piece with no glow lights nothing")
		var want_weapon := CrowdView._color("%06x" % int(weapon.color))
		var w: Color = pal[full_kit * 3 + 2]
		check(Vector3(w.r, w.g, w.b).is_equal_approx(Vector3(want_weapon.r, want_weapon.g, want_weapon.b)) and w.a == 1.0, "the weapon piece's tier colour goes to the thrall's weapon (%s)" % str(w))
		check((pal[armor_kit * 3 + 2] as Color).a == 0.0 and (pal[armor_kit * 3] as Color).a > 0.0, "an owner with only armour on its legion shows no weapon colour")
	# the slots are the palette's: two owners with the same kit share a slot; the materials hold the palette
	var armor_slot: int = slot_of.call("armor/warrior")
	view.set_owner_kit(owners.bare, {"armor": [armor_id, "epic"]})
	for f in 8:
		settle.call()
	check(slot_of.call("bare/warrior") == armor_slot and kit_of.call("bare/warrior") == armor_kit, "owners with the same kit share one palette slot (%d)" % armor_slot)
	view._push_glows()
	var mat_slots: Variant = view._materials[0].get_shader_parameter("kit_slot")
	var mat_kits: Variant = view._materials[0].get_shader_parameter("kit_pal")
	var of: PackedFloat32Array = crowd.kit_of_slot()
	check(mat_slots is PackedVector4Array and (mat_slots as PackedVector4Array).size() == CrowdView.SLOTS / 4 and mat_kits is PackedVector4Array and (mat_kits as PackedVector4Array).size() == pal.size(),
		"every model's material has the kit of each slot and the kit palette")
	if mat_slots is PackedVector4Array and armor_slot > 0:
		check(int((mat_slots as PackedVector4Array)[armor_slot / 4][armor_slot % 4]) == armor_kit and int(of[armor_slot]) == armor_kit, "and the slot names its kit in the material")
	# taking the kit off puts the thralls back on the bare slot; a change in the slot refreshes the instance whatever its animation band
	var worn_slot: int = slot_of.call("full/warrior")
	view.set_owner_kit(owners.full, {})
	for f in 8:
		settle.call()
	check(kit_of.call("full/warrior") == 0 and slot_of.call("full/warrior") != worn_slot, "taking the kit off dresses the thralls bare again (a slot of no kit: %d, was %d)" % [slot_of.call("full/warrior"), worn_slot])
	# the guest's baseline clears the crowd's creatures, not its owners: the kit, the legion and the ally mark come back with the creatures
	view.set_owner_ally(owners.armor, true)
	view.clear()
	for f in 70:
		settle.call()
	check(kit_of.call("armor/warrior") == armor_kit and kit_of.call("bare/warrior") == armor_kit, "after clear() the kits are still worn")
	check(view._owners[owners.armor].get("legion") == "gravecaller" and view._owners[owners.armor].get("ally") == true, "and the legion and the ally mark of an owner are put back too")
	view.queue_free()

## A group is drawn only while it holds instances (`DmCrowd.set_group_nodes`): the renderer draws a MultiMesh with none all the same, one draw call, and one for every shadow cascade a caster meets.
## Its node is shown the frame its first instance is written and hidden once it has been empty for half a second (a body crossing a level of detail back and forth does not rebuild the instance).
func groups_follow_instances(view: CrowdView, crowd: RefCounted) -> void:
	var slots := view.model_slots()
	var groups: Array = []
	for c in view.get_children():
		if c is MultiMeshInstance3D:
			var parts := String(c.name).split("_lod")
			groups.append({"node": c, "model": int(slots[parts[0]]), "lod": int(parts[1]), "shadow": String(parts[1]).ends_with("_shadow"), "fade": String(parts[1]).ends_with("_fade")})
	var holding := 0
	var shown := 0
	var empty_shown := 0
	var holding_hidden := 0
	for g: Dictionary in groups:
		var n: int = crowd.instance_count(g.model, g.lod, g.shadow, g.fade)
		holding += 1 if n > 0 else 0
		shown += 1 if g.node.visible else 0
		empty_shown += 1 if n == 0 and g.node.visible else 0
		holding_hidden += 1 if n > 0 and not g.node.visible else 0
	var levels := 0
	for m in 3:
		levels += int(lods[m])
	check(groups.size() == 3 * levels and holding > 0 and holding < groups.size(), "the party's models have %d groups (3 models, %d levels of detail, each in plain, with shadows and the fade group) and %d of them hold instances" % [groups.size(), levels, holding])
	check(holding_hidden == 0 and empty_shown <= 2 and shown == holding + empty_shown, "a group is shown while it holds instances, and only the ones emptied within the last half second are shown empty (%d shown, %d hold, %d hold and hide, %d empty and shown)" % [shown, holding, holding_hidden, empty_shown])
	# the fade groups: the alpha shader (the same material parameters as the solid one's), no shadow, and the closed bodies' cull-back variant
	var fade_nodes := 0
	var fade_ok := true
	for c in view.get_children():
		if c is MultiMeshInstance3D and String(c.name).ends_with("_fade"):
			fade_nodes += 1
			var fm := (c as MultiMeshInstance3D).material_override as ShaderMaterial
			var sm := (view.get_node(String(c.name).trim_suffix("_fade")) as MultiMeshInstance3D).material_override as ShaderMaterial
			fade_ok = fade_ok and fm.shader == CrowdVatData.fade_shader(false) and fm.shader.code.contains("#define FADE") and not fm.shader.code.contains("#define SPECTRAL") \
				and (c as MultiMeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and fm != sm and fm.get_shader_parameter("vat_pos") == sm.get_shader_parameter("vat_pos") \
				and fm.get_shader_parameter("albedo_tex") == sm.get_shader_parameter("albedo_tex") and (fm.get_shader_parameter("vat_clips") as PackedVector4Array) == (sm.get_shader_parameter("vat_clips") as PackedVector4Array)
	check(fade_nodes == levels and fade_ok, "each level of each model has a fade node: the fade shader on the model's own textures and clips, casting no shadow (%d nodes)" % fade_nodes)
	view.clear()   # every body forgotten: every group empties
	for f in 20:
		crowd.draw(DT, 0.5, CAM)
	var still := 0
	for g: Dictionary in groups:
		still += 1 if g.node.visible else 0
	check(still == shown, "an emptied group stays drawn for half a second (%d of %d shown after a third of a second)" % [still, shown])
	for f in 20:
		crowd.draw(DT, 0.5, CAM)
	var left := 0
	for g: Dictionary in groups:
		left += 1 if g.node.visible else 0
	check(left == 0, "and goes after that (%d shown after a second)" % left)
	view.sync()   # the core still holds the party: the views come back with it
	crowd.draw(DT, 0.5, CAM)
	var back := 0
	var back_hidden := 0
	for g: Dictionary in groups:
		var n: int = crowd.instance_count(g.model, g.lod, g.shadow, g.fade)
		back += 1 if g.node.visible else 0
		back_hidden += 1 if n > 0 and not g.node.visible else 0
	check(back > 0 and back_hidden == 0, "a group is shown the frame its first instance is written (%d shown, %d holding and hidden)" % [back, back_hidden])


func lockstep(core: RefCounted, view: CrowdView, guest: RefCounted, alpha: float) -> void:
	core.step(DT)
	view.sync()
	var lf: Dictionary = view.crowd.last_feed()
	guest.sync_rows(lf.body_ints, lf.body_floats, lf.hits, lf.corpse_ints, lf.corpse_floats)
	view.crowd.draw(DT, alpha, CAM)
	guest.draw(DT, alpha, CAM)
	clock_ms += DT * 1000.0
	core.take_events()


func buffers_equal(a: RefCounted, b: RefCounted) -> bool:
	for m in lods.size():
		for l in lods[m]:
			for g in [[false, false], [true, false], [false, true]]:
				if a.buffer(m, l, g[0], g[1]) != b.buffer(m, l, g[0], g[1]):
					return false
	return true


## A second crowd with the same models as `view`'s, for the guest path (the rows decide everything, the looks are not needed).
func new_crowd_from(view: CrowdView) -> RefCounted:
	var g: RefCounted = ClassDB.instantiate("DmCrowd")
	var slots := view.model_slots()
	for slug in slots:
		var d: CrowdVatData = view.data_of(slug)
		var plain: Array = []
		var shadow: Array = []
		var fade: Array = []
		for lod in d.meshes.size():
			var a: MultiMesh = d.make_multimesh(0, lod)
			var b: MultiMesh = d.make_multimesh(0, lod)
			var f: MultiMesh = d.make_multimesh(0, lod)
			keep.append(a)
			keep.append(b)
			keep.append(f)
			plain.append(a.get_rid())
			shadow.append(b.get_rid())
			fade.append(f.get_rid())
		var cd: Dictionary = d.crowd_data()
		var ghost: bool = (view._looks.get("spectral_models", []) as Array).has(slug)
		cd["spectral"] = ghost
		var slot: int = g.add_model(slug, cd, plain, shadow, view.lod_distances, [] if ghost else fade)
		check(slot == slots[slug], "the guest's model slot of %s equals the view's" % slug)
	var cost: Dictionary = view.crowd.settings()   # the same cost settings: the rows decide everything, the animation bands among it
	g.set_anim_lod(cost.anim_lod, cost.anim_mid_m, cost.anim_mid_hz, cost.anim_far_m, cost.anim_far_hz)
	g.set_culling(cost.culling)
	return g


func _remove_dir(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(d))
	DirAccess.remove_absolute(path)
