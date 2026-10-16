extends SceneTree
## The crowd's presentation (client/crowd/README.md "Driving the crowd", native/README.md "Drawing") against the view layer of today's game
## (godot/game/dm_entity_views.gd, dm_creature.gd, dm_animator.gd), proven headless: DmCrowd takes plain rows (or the core's tables), advances a view
## per creature and writes the MultiMesh buffers, which `buffer()` hands back exactly as they would be uploaded.
## Mirrors of today's pure helpers sit below, line by line (turn_toward, smooth_speed, knock_impulse, step_knock, settle_depth, strike_timing, the
## stride plan, the body layer's pose); the C++ is held against them on random inputs and on the views' own clocks. Then: the clip of every state
## and the walk/run switch, the blends and the packing, the hit flash, the knock, the death into a corpse, the rise, the hover, the shadow group,
## the level-of-detail split, interpolation, a Full Party crowd driven by a real DmCore (events not consumed, rows equal for a guest, no growth)
## and the time draw() takes (INFO only). Bakes the models it needs into a scratch folder (about 25 s).
## Run: godot --headless --path client --script res://tests/crowd_view.gd

const Baker := preload("res://crowd/crowd_baker.gd")
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

var fails := 0
var checks := 0
class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var errlog := ErrorLog.new()
var godot_dir: String
var live_assets: String   ## where the models' sources are: skeleton_thrall is not synced into client/assets yet
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

## A DmCrowd with the three baked models (robber 2 levels of detail, hound 1, skeleton 3), levels starting at 30 m and 60 m.
func new_crowd() -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCrowd")
	clock_ms = 0.0
	if lods.is_empty():
		for slug in SLUGS:
			lods.append(data[slug].meshes.size())
	for slug in SLUGS:
		var plain: Array = []
		var shadow: Array = []
		for lod in data[slug].meshes.size():
			var a: MultiMesh = data[slug].make_multimesh(0, lod)
			var b: MultiMesh = data[slug].make_multimesh(0, lod)
			keep.append(a)
			keep.append(b)
			plain.append(a.get_rid())
			shadow.append(b.get_rid())
		c.add_model(slug, data[slug].crowd_data(), plain, shadow, PackedFloat32Array([30.0, 60.0]))
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


## Every instance in every group, decoded: {model, lod, shadow, xf, color, custom}.
func rows(c: RefCounted) -> Array:
	var out := []
	for m in lods.size():
		for l in lods[m]:
			for s in [false, true]:
				var buf: PackedFloat32Array = c.buffer(m, l, s)
				check(buf.size() == c.instance_count(m, l, s) * 20, "buffer(%d, %d, %s) holds count x 20 floats" % [m, l, s])
				for i in buf.size() / 20:
					var o := i * 20
					var rows_ := Basis(Vector3(buf[o], buf[o + 1], buf[o + 2]), Vector3(buf[o + 4], buf[o + 5], buf[o + 6]), Vector3(buf[o + 8], buf[o + 9], buf[o + 10])).transposed()
					out.append({"model": m, "lod": l, "shadow": s, "xf": Transform3D(rows_, Vector3(buf[o + 3], buf[o + 7], buf[o + 11])),
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
	godot_dir = ProjectSettings.globalize_path("res://").path_join("../godot")
	DirAccess.make_dir_recursive_absolute(OUT)
	live_assets = godot_dir.path_join("assets")
	for slug in SLUGS:
		var r: Dictionary = Baker.bake(root, slug, OUT.path_join(slug), {"assets_dir": live_assets})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
		data[slug] = ResourceLoader.load(OUT.path_join(slug).path_join("model.tres"), "", ResourceLoader.CACHE_MODE_REPLACE)
	baked_data()
	pure_helpers()
	turning_and_legs()
	clips_by_state()
	walk_run()
	blends_and_packing()
	hits_and_flash()
	knockback()
	rise_hover_and_pose()
	death_and_corpses()
	the_hound()
	shadows_and_lod()
	interpolation()
	full_party()
	armed_variants()
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
	var rows_json: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(godot_dir.path_join("game/view_models.json")))
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


func the_hound() -> void:
	# the hound has no attack, hurt or death clip: the body does it alone
	var c := new_crowd()
	feed(c, [body(1, ENEMY, HOUND, CHASE, 3, 0, {"def": 2, "speed": 4.4})])
	draw(c, 20)
	check(info(c, 1).clip in ["walk", "run"], "the hound walks and runs")
	feed(c, [body(1, ENEMY, HOUND, ATTACK, 3, 0, {"def": 2, "action_s": 0.25})])
	var i := info(c, 1)
	check(i.one_shot == "" and near(i.lunge_len, 1.05 * 0.22, 1e-6) and near(i.lunge_pitch, 0.2, 1e-9) and near(i.lunge_in, 0.25, 1e-6), "no attack clip: the hound lunges and bites with the body (%.3f m, %.2f rad)" % [i.lunge_len, i.lunge_pitch])
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
	# a hound laid down by a corpse alone is already down
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


# ---------------------------------------------------------------------------------------------------------------------- the Full Party

const THRALL_BASE := {"warrior": [1.3, 1.0, 5.6], "shieldbearer": [1.3, 1.25, 5.2], "hound": [1.2, 0.7, 7.2], "wraith": [5.5, 1.1, 5.8],
	"archer": [7.5, 1.3, 5.4], "bonemage": [6.5, 1.8, 5.2], "plaguebearer": [1.3, 1.2, 4.8]}


func full_party() -> void:
	var enemies_json: Dictionary = DmCoreData.json(godot_dir.path_join("data/content/enemies.json"))
	var core: RefCounted = ClassDB.instantiate("DmCore")
	core.set_seed(77)
	DmCoreData.load_all(core, godot_dir)
	core.set_wander(false)
	core.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	var view := CrowdView.new()
	view.auto_sync = false
	root.add_child(view)
	view.setup(core, enemies_json["ENEMIES"], Vector2(-60, -60), Vector2(60, 60), {"baked_dir": OUT, "assets_dir": live_assets, "champion_scale": 1.35})
	var crowd: RefCounted = view.crowd
	check(view.model_slots() == {"grave_robber": 0, "bone_hound": 1, "skeleton_thrall": 2}, "the view's model slots are the ones this test knows (%s)" % str(view.model_slots()))
	var guest := new_crowd_from(view)   # the co-op guest: the same models, fed the rows instead of the core
	# the models: an unbaked one falls back to the nearest baked one, once, with a warning
	var w := Array(view.warnings)
	var unique := {}
	for s in w:
		unique[s] = true
	check(unique.size() == w.size(), "each fallback is listed once (%d)" % w.size())
	check(w.has("no baked model for barrow_ghoul: drawn as grave_robber"), "the ghoul falls back to the robber, as today's rig fallback does")
	check(w.has("no baked model for censer_bearer: drawn as skeleton_thrall"), "a model with no baked stand-in of its rig is drawn as the skeleton")
	check(w.has("no baked model for skull_rat: drawn as bone_hound"), "the rat (a quadruped) falls back to the hound")
	check(not w.any(func(s: String) -> bool: return s.contains("grave_robber") and s.contains("no baked model for grave_robber")), "baked models are not listed")
	print("INFO %d model fallbacks, e.g. %s" % [w.size(), w[0]])
	# the party: 4 heroes, 8 thralls each, 72 enemies. Nobody can hurt anybody, so the crowd stays 104 strong while it moves, swings and flinches.
	var heroes := []
	for h in 4:
		var id: int = core.add_external(0, 0.4, 1.0)
		core.set_external(id, Vector2(-6.0 + 4.0 * h, 0.0), true)
		heroes.append(id)
	var legions := ["ossuary", "gravecaller", "rotweaver", "mourner"]
	var kinds := ["warrior", "warrior", "warrior", "shieldbearer", "hound", "wraith", "archer", "bonemage"]
	for h in 4:
		view.set_owner_legion(heroes[h], legions[h])
		for k in 8:
			var b: Array = THRALL_BASE[kinds[k]]
			var tid: int = core.raise_thrall({"kind": kinds[k], "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": b[1], "range": b[0], "speed": b[2], "empowered": false,
				"champion": h == 1 and k == 0, "allyHeal": 0.0}, heroes[h], Vector2(-6.0 + 4.0 * h + float(k) - 3.0, 3.0), 0.0, 20.0)
			check(tid != 0, "thrall raised")
	var defs := ["robber", "robber", "hound", "ghoul", "wraith", "robber", "hound", "robber"]
	var ids := []
	for e in 72:
		var a := float(e) / 72.0 * TAU
		var pos := Vector2(cos(a), sin(a)) * (12.0 + float(e % 5) * 1.5)
		ids.append(core.spawn_enemy(defs[e % defs.size()], pos, 1, 1000.0, 0.0, e % 24 == 5, "graves", e % 9 == 0))
	view.focus = Vector2(0, 0)
	for f in 150:   # warm up: the rise is over, the fight is on
		lockstep(core, view, guest, 0.5)
	var st: Dictionary = crowd.stats()
	check(st.bodies == 104 and st.live == 104, "all 104 bodies have a view (%d)" % st.bodies)
	var drawn := 0
	for m in 3:
		for l in lods[m]:
			drawn += crowd.instance_count(m, l, false) + crowd.instance_count(m, l, true)
	var hidden := 0
	for id in ids:
		hidden += 1 if crowd.view_info(id).hidden else 0
	check(drawn == 104 - hidden and st.drawn == drawn, "104 creatures, 104 instances (%d drawn, %d underground)" % [drawn, hidden])
	# looks: an elite is larger, a champion thrall bigger, a risen one dull
	var elite_id: int = ids[5]
	check(near(crowd.view_info(elite_id).scale, 1.0 * 1.35, 1e-6), "an elite is drawn 1.35x (%s)" % crowd.view_info(elite_id).scale)
	var seen_champion := false
	for tid in core.thrall_ids():
		if near(crowd.view_info(tid).scale, 1.35, 1e-6):
			seen_champion = true
	check(seen_champion, "a champion thrall is drawn 1.35x")
	glows(view, crowd, core, ids, heroes)
	# the time draw() takes: Full Party, the core stepping, one tick and one frame each
	var us := PackedFloat64Array()
	var sync_us := PackedFloat64Array()
	var regrows0: int = crowd.stats().regrows
	var same := true
	var rows_seen := 0
	var states := {}
	for f in 300:
		core.step(DT)
		var t0 := Time.get_ticks_usec()
		view.sync()
		var t1 := Time.get_ticks_usec()
		var alpha := float(f % 4) / 4.0
		crowd.draw(DT, alpha, CAM)
		var t2 := Time.get_ticks_usec()
		sync_us.append(t1 - t0)
		us.append(t2 - t1)
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
	us.sort()
	sync_us.sort()
	var sum := 0.0
	var ssum := 0.0
	for v in us:
		sum += v
	for v in sync_us:
		ssum += v
	print("INFO draw(): Full Party (%d bodies, %d drawn) over %d frames: mean %.0f us, p95 %.0f us, max %.0f us" % [crowd.stats().bodies, crowd.stats().drawn, us.size(), sum / us.size(), us[int(us.size() * 0.95)], us[us.size() - 1]])
	print("INFO sync(): mean %.0f us, p95 %.0f us (the core's whole budget is 4000 us a frame)" % [ssum / sync_us.size(), sync_us[int(sync_us.size() * 0.95)]])
	# a steady crowd: the same bodies for 300 frames (no tick, the frame time and interpolation changing): the buffers do not grow
	var before: Dictionary = crowd.stats()
	for f in 300:
		crowd.draw([DT, 0.004, 0.03, 0.0][f % 4], float(f % 7) / 7.0, CAM)
	var after: Dictionary = crowd.stats()
	check(after.capacity_floats == before.capacity_floats and after.regrows == before.regrows and after.drawn == before.drawn, "no growth in the buffers over 300 steady frames (%d floats, %d regrows)" % [after.capacity_floats, after.regrows])
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
	view.queue_free()
	await process_frame


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
	check(on_mat is PackedVector4Array and (on_mat as PackedVector4Array).size() == 64 and Vector4(pal[1].r, pal[1].g, pal[1].b, pal[1].a).is_equal_approx((on_mat as PackedVector4Array)[1]),
		"every model's material has the palette")


## Thralls with hand props (DmEntityViews._make_thrall): a warrior with no legion or an armed one is drawn with the "<model>+warrior" variant when it is baked;
## a Rotweaver's (unarmed legion) stays bare; a kind whose variant is not baked keeps its plain body and says so once. A variant is never a stand-in for another model.
func armed_variants() -> void:
	var r: Dictionary = Baker.bake(root, "skeleton_thrall+warrior", OUT.path_join("skeleton_thrall+warrior"), {"assets_dir": live_assets})
	check(r.ok, "bake skeleton_thrall+warrior: %s" % r.get("error", ""))
	if not r.ok:
		return
	var enemies_json: Dictionary = DmCoreData.json(godot_dir.path_join("data/content/enemies.json"))
	var core: RefCounted = ClassDB.instantiate("DmCore")
	DmCoreData.load_all(core, godot_dir)
	core.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	var view := CrowdView.new()
	view.auto_sync = false
	root.add_child(view)
	view.setup(core, enemies_json["ENEMIES"], Vector2(-60, -60), Vector2(60, 60), {"baked_dir": OUT, "assets_dir": live_assets})
	var slots := view.model_slots()
	check(slots.has("skeleton_thrall+warrior"), "the warrior's variant is a model of the view (%s)" % str(slots.keys()))
	check(not Array(view.warnings).any(func(w: String) -> bool: return w.contains("drawn as skeleton_thrall+")), "a variant is never a stand-in for another model")
	check(view.warnings.has("no baked variant skeleton_thrall+archer: drawn without its hand props"), "an archer without its baked variant keeps its plain body, said once")
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
			for s in [false, true]:
				if a.buffer(m, l, s) != b.buffer(m, l, s):
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
		for lod in d.meshes.size():
			var a: MultiMesh = d.make_multimesh(0, lod)
			var b: MultiMesh = d.make_multimesh(0, lod)
			keep.append(a)
			keep.append(b)
			plain.append(a.get_rid())
			shadow.append(b.get_rid())
		var slot: int = g.add_model(slug, d.crowd_data(), plain, shadow, view.lod_distances)
		check(slot == slots[slug], "the guest's model slot of %s equals the view's" % slug)
	return g


func _remove_dir(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(d))
	DirAccess.remove_absolute(path)
