class_name DmAnimator
extends RefCounted
## Animation driver for one creature, the port of Creature.ts locomotion + one-shots: stride-matched walk/run (graphics/locomotion.ts
## planLocomotion over content/strideSpeeds.json), timed strikes (strikeTiming over clipTimings.json), hurt flinch and death.
## Use: var a := DmAnimator.new(anim_player, model_entry, world_height); a.loco(ground_speed); a.strike("attack", 0.4); a.hurt(); a.death(); a.tick(dt).

const DEFAULT_WALK := 0.7
const LOCO_MIN := 0.4
const WALK_MAX := 3.0
const WALK_HARD_MAX := 4.5
const RUN_MAX := 2.4
const RUN_UP := 2.0
const RUN_DOWN := 1.6
const IDLE_STAND_IN := 0.2    # walk-only rigs (the quadrupeds) idle as a slow shuffle
const FLINCH_SECONDS := 0.5
const FLINCH_SPEED := 1.35

var ap: AnimationPlayer
var entry: Dictionary
var height: float
var stride: Dictionary
var has_run := false
var was_run := false
var loop := "idle"
var _oneshot := ""
var _oneshot_end := -1.0      # clip time at which a strike hands back to the loop (-1 = play to the end)
var _flinch_t := 0.0
var dead := false
var last_plan := {"clip": "idle", "timeScale": 1.0, "stride": 0.0, "residual": 0.0}

func _init(player: AnimationPlayer, model_entry: Dictionary, world_height: float) -> void:
	ap = player
	entry = model_entry
	height = world_height
	var s: Variant = model_entry.get("stride")
	stride = s if s is Dictionary else {}
	has_run = ap != null and ap.has_animation("run")

func valid() -> bool:
	return ap != null

static func walk_cap(h: float) -> float:
	return minf(WALK_HARD_MAX, maxf(1.6, WALK_MAX * sqrt(2.0 / maxf(0.1, h))))

## planLocomotion: which loop and how fast so the planted feet match `ground` (units/s). `row` = {walk, run} body-heights per second.
static func plan_loco(row: Dictionary, h: float, ground: float, hr: bool, was_run_now: bool) -> Dictionary:
	var walk_u: float = float(row.get("walk", DEFAULT_WALK)) * h
	var run_u: float = float(row.get("run", 0.0)) * h if hr else 0.0
	var run: bool = run_u > 0.0 and ground > walk_u * (RUN_DOWN if was_run_now else RUN_UP)
	var st: float = run_u if run else walk_u
	var mx: float = RUN_MAX if run else walk_cap(h)
	var ts: float = minf(mx, maxf(LOCO_MIN, ground / st))
	var residual: float = absf(ground - ts * st) / ground if ground > 1e-3 else 0.0
	return {"clip": "run" if run else "walk", "timeScale": ts, "stride": st, "residual": residual}

func plan(ground: float, was_run_now: bool) -> Dictionary:
	return plan_loco(stride, height, ground, has_run, was_run_now)

## strikeTiming: the clip's impact frame (`impact` < 0 = unmeasured, 35% of the clip) lands `impact_in` seconds from now.
static func strike_timing(duration: float, impact: float, impact_in: float, follow: float) -> Dictionary:
	var peak := minf(duration, impact if impact >= 0.0 else duration * 0.35)
	var lead := maxf(0.08, impact_in)
	var speed := minf(2.2, maxf(0.7, peak / lead))
	var start_at := maxf(0.0, peak - lead * speed)
	return {"speed": speed, "startAt": start_at, "endAt": minf(duration, peak + follow * speed), "impactAfter": (peak - start_at) / speed}

func _has(n: String) -> bool:
	return ap != null and ap.has_animation(n)

func _variant(base: String) -> String:
	var opts: Array[String] = []
	if _has(base):
		opts.append(base)
	for i in range(2, 6):
		if _has("%s%d" % [base, i]):
			opts.append("%s%d" % [base, i])
	if opts.is_empty():
		return ""
	return opts[randi() % opts.size()]

## Looping clip (idle/walk/run) at `speed`. Walk and run share a step cycle: the new clip lands in the same phase.
func set_loop(clip: String, speed: float) -> void:
	if ap == null:
		return
	var stand_in := false
	var name := clip
	if not _has(name):
		if clip == "idle" and _has("walk"):
			name = "walk"
			stand_in = true
		else:
			return
	var sp := IDLE_STAND_IN if stand_in else speed
	loop = clip
	if _oneshot != "":
		return
	if ap.current_animation == name and ap.is_playing():
		ap.speed_scale = sp
		return
	var phase := -1.0
	var old := ap.current_animation
	if (old == "walk" and name == "run") or (old == "run" and name == "walk"):
		var oa := ap.get_animation(old)
		if oa != null and oa.length > 0.0:
			phase = ap.current_animation_position / oa.length
	ap.speed_scale = sp
	ap.play(name, 0.15, 1.0)
	if phase >= 0.0:
		ap.seek(phase * ap.get_animation(name).length, true)

## Every frame the body moves (or stands): picks idle / walk / run and the stride-matched playback speed.
func loco(ground: float) -> void:
	if ap == null or dead:
		return
	if ground < 0.05:
		was_run = false
		set_loop("idle", 1.0)
		return
	var p := plan(ground, was_run)
	was_run = p.clip == "run"
	last_plan = p
	set_loop(p.clip, p.timeScale)

## A timed strike (attack/cast): the clip's measured impact frame lands `impact_in` seconds from now (Creature.playStrike).
func strike(anim: String, impact_in: float, follow_through := 0.3) -> bool:
	if ap == null or dead:
		return false
	var name := _variant(anim)
	if name == "":
		return false
	var a := ap.get_animation(name)
	var dur := a.length
	var timing: Variant = (entry.get("timings", {}) as Dictionary).get(name)
	var impact: float = float(timing[1]) if timing is Array and timing.size() > 1 else -1.0
	var tm := strike_timing(dur, impact, impact_in, follow_through)
	var speed: float = tm.speed
	var start_at: float = tm.startAt
	_oneshot = name
	_oneshot_end = tm.endAt
	_flinch_t = 0.0
	ap.speed_scale = speed
	ap.play(name, 0.08, 1.0)
	if start_at > 0.0:
		ap.seek(start_at, true)
	return true

## Hit reaction: the first half-second of the hurt clip, never over a strike or a death.
func hurt() -> bool:
	if ap == null or dead or _oneshot != "":
		return false
	var name := _variant("hurt")
	if name == "":
		return false
	_oneshot = name
	_oneshot_end = minf(ap.get_animation(name).length, FLINCH_SECONDS * FLINCH_SPEED)
	ap.speed_scale = FLINCH_SPEED
	ap.play(name, 0.06, 1.0)
	return true

## Death clip, held on its last frame. Returns false for rigs with no death clip (the owner tips the body over instead).
func death() -> bool:
	if ap == null:
		return false
	var name := _variant("death")
	dead = true
	if name == "":
		return false
	_oneshot = name
	_oneshot_end = -1.0
	ap.speed_scale = 1.0
	ap.play(name, 0.05, 1.0)
	return true

func tick(_dt: float) -> void:
	if ap == null or _oneshot == "" or dead:
		return
	var over := false
	if not ap.is_playing():
		over = true
	elif _oneshot_end >= 0.0 and ap.current_animation_position >= _oneshot_end:
		over = true
	if over:
		_oneshot = ""
		_oneshot_end = -1.0
		var n := loop
		var sp: float = float(last_plan.timeScale) if loop != "idle" else 1.0
		ap.stop()
		set_loop(n, sp)
