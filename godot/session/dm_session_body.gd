class_name DmSessionBody
extends Node3D
## One networked player body (flat-ground capsule). The HOST simulates it from validated intents (`step_host`); every other peer only
## renders it, interpolating between host snapshots (`push_sample`) a fixed delay in the past.

const CAPSULE_RADIUS := 0.4
const CAPSULE_HEIGHT := 1.8
const SNAP_JUMP := 4.0  ## a replicated position this far (m) from the last sample is a teleport: clients snap instead of gliding
const DASH_STEP := 0.25  ## veil_target's walk step (m)
const DIR_TTL := 0.25  ## a direction intent expires this long after the last one (lost "stop" packet cannot run a body forever)

var show_capsule: bool = true  ## false when a game dresses the body itself (set before setup())
var owner_peer: int = 0
var display_name: String = ""
var discipline_id: String = ""
var yaw: float = 0.0
var simulated: bool = false  ## true on the host only

var move_target: Vector3 = Vector3.ZERO
var has_target: bool = false
var move_dir: Vector3 = Vector3.ZERO
var _dir_ttl: float = 0.0
var _samples: Array = []  ## [time_s, Vector3, yaw], oldest first
var dashing: bool = false  ## host: a dash glide is running (movement intents wait until it ends)
var _dash_from := Vector3.ZERO
var _dash_to := Vector3.ZERO
var _dash_t: float = 0.0
var _dash_dur: float = 0.0


func setup(peer_id: int, nm: String, disc: String, pos: Vector3) -> void:
	owner_peer = peer_id
	display_name = nm
	discipline_id = disc
	position = pos
	name = "P%d" % peer_id
	if not show_capsule:
		return
	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = CAPSULE_RADIUS
	cap.height = CAPSULE_HEIGHT
	mi.mesh = cap
	mi.position.y = CAPSULE_HEIGHT * 0.5
	add_child(mi)


func set_move_target(p: Vector3) -> void:
	move_target = Vector3(p.x, 0.0, p.z)
	has_target = true
	move_dir = Vector3.ZERO
	_dir_ttl = 0.0


func set_move_dir(d: Vector3) -> void:
	d.y = 0.0
	if d.length() > 1.0:
		d = d.normalized()
	has_target = false
	move_dir = d
	_dir_ttl = DIR_TTL if d.length_squared() > 0.0 else 0.0


func stop() -> void:
	has_target = false
	move_dir = Vector3.ZERO
	_dir_ttl = 0.0


## Host: move the body instantly (blink rites, respawn). Clients snap to it (SNAP_JUMP) rather than glide across the room.
func teleport(to: Vector3) -> void:
	position = Vector3(to.x, 0.0, to.z)
	dashing = false
	stop()


## Host: true when the ground point is somewhere a body may stand. Plain bodies: inside the arena. DmHeroBody asks the navmesh.
func walkable(pt: Vector3) -> bool:
	return absf(pt.x) <= DmSession.ARENA_HALF and absf(pt.z) <= DmSession.ARENA_HALF


## Host: the area id of a point ("" = no areas); a dash never leaves the area it starts in.
func area_of_point(_pt: Vector3) -> String:
	return ""


## Host: `pt` itself when walkable, else the nearest walkable point.
func resolve_point(pt: Vector3) -> Vector3:
	return Vector3(clampf(pt.x, -DmSession.ARENA_HALF, DmSession.ARENA_HALF), 0.0, clampf(pt.z, -DmSession.ARENA_HALF, DmSession.ARENA_HALF))


## Host: the furthest valid point on the way to `to` (the sim's veil_target): walk in DASH_STEP steps, keep the last walkable point, stop at the
## first blocked one or when the area changes (a sealed door, a wall, the hall's edge).
func dash_point(to: Vector3) -> Vector3:
	var from := Vector3(position.x, 0.0, position.z)
	var area := area_of_point(from)
	var n := maxi(1, int(ceilf(from.distance_to(Vector3(to.x, 0.0, to.z)) / DASH_STEP)))
	var best := from
	for i in range(1, n + 1):
		var pt := from.lerp(Vector3(to.x, 0.0, to.z), float(i) / float(n))
		if not walkable(pt) or area_of_point(pt) != area:
			break
		best = pt
	return best


## Host: glide to `to` over `secs` (quadratic ease-out, the sim's dash). The caller validated the point (dash_point). Movement intents are
## ignored until it ends; the position replicates through the normal snapshots, clients interpolate it.
func dash(to: Vector3, secs: float) -> void:
	stop()
	_dash_from = Vector3(position.x, 0.0, position.z)
	_dash_to = Vector3(to.x, 0.0, to.z)
	_dash_t = 0.0
	_dash_dur = maxf(secs, 0.001)
	dashing = true
	var d := _dash_to - _dash_from
	if d.length_squared() > 0.0001:
		yaw = atan2(d.x, d.z)


## Host: advance a running dash by `delta`; true while it still owns the body's movement this tick.
func _step_dash(delta: float) -> bool:
	if not dashing:
		return false
	_dash_t += delta
	var k := minf(1.0, _dash_t / _dash_dur)
	position = _dash_from.lerp(_dash_to, 1.0 - (1.0 - k) * (1.0 - k))
	rotation.y = yaw
	if k >= 1.0:
		dashing = false
	return true


## Host-side authoritative step. `speed` and `half` (arena half-extent) are host constants, never client-supplied.
func step_host(delta: float, speed: float, half: float) -> void:
	if _step_dash(delta):
		return
	var vel := Vector3.ZERO
	if _dir_ttl > 0.0:
		_dir_ttl -= delta
		if _dir_ttl <= 0.0:
			move_dir = Vector3.ZERO
	if move_dir.length_squared() > 0.0001:
		vel = move_dir * speed
	elif has_target:
		var d := move_target - position
		d.y = 0.0
		var dist := d.length()
		if dist <= speed * delta:
			if dist > 0.001:
				yaw = atan2(d.x, d.z)
			position = Vector3(move_target.x, 0.0, move_target.z)
			has_target = false
		else:
			vel = d / dist * speed
	if vel != Vector3.ZERO:
		position += vel * delta
		position.x = clampf(position.x, -half, half)
		position.z = clampf(position.z, -half, half)
		position.y = 0.0
		yaw = atan2(vel.x, vel.z)
	rotation.y = yaw


func push_sample(t: float, pos: Vector3, y: float) -> void:
	if not _samples.is_empty() and (_samples[_samples.size() - 1][1] as Vector3).distance_to(pos) > SNAP_JUMP:
		_samples.clear()   # a teleport: no glide across the gap
	_samples.append([t, pos, y])
	if _samples.size() > 10:
		_samples.pop_front()


func _process(_delta: float) -> void:
	if simulated or _samples.is_empty():
		return
	var rt := Time.get_ticks_msec() / 1000.0 - DmSession.INTERP_DELAY
	var s: Array = _samples
	if rt <= s[0][0]:
		position = s[0][1]
		yaw = s[0][2]
	elif rt >= s[s.size() - 1][0]:
		position = s[s.size() - 1][1]
		yaw = s[s.size() - 1][2]
	else:
		for i in range(s.size() - 1):
			var a: Array = s[i]
			var b: Array = s[i + 1]
			if rt >= a[0] and rt <= b[0]:
				var k: float = (rt - a[0]) / maxf(b[0] - a[0], 0.0001)
				position = (a[1] as Vector3).lerp(b[1], k)
				yaw = lerp_angle(a[2], b[2], k)
				break
	rotation.y = yaw
