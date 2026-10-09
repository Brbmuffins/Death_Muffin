class_name DmStatusSet
extends Node
## Status effects for one body (enemy, later player/thrall): a child named "Statuses" of its owner, on every peer, same path (see README.md).
## Host (authority) side: apply / remove, ticks on a fixed 0.1 s step, damage-over-time in 0.25 s lumps through the owner's take_damage
## (kill credit = the status's source), and it OWNS the derived multipliers: speed_mult / attack_rate_mult on the owner are written here
## and only here, recomputed only when the set of statuses changes. Replication: a 4-byte-per-status snapshot on change only.
## Every peer: status motes from the replicated ids. Rules/numbers come from DmSimData (the tables the old sim used), nothing retyped.

signal changed                                  ## set of ids / stacks changed (host and clients)
signal expired(id: StringName)                  ## host: a status ran out
signal dot_damage(id: StringName, amount: float, source: Node, killed: bool, target: Node)   ## host: one DoT lump was applied
signal withered_died(stacks: float, dps: float, source: Node, target: Node)   ## host: the owner died carrying Withered (Contagion / Plague Choir spread; fired before the set clears)

const NODE_NAME := "Statuses"
const TICK_S := 0.1
const FLUSH_S := 0.25            ## DoT lumps (one hit flash per lump, not per frame)
const FOREVER := 1.0e9
const NO_PARAMS := {}
## A record is [stacks, remaining_s, value (dps / barrier amount), source Node or null, dot accumulator].
const STK := 0
const REM := 1
const VAL := 2
const SRC := 3
const ACC := 4
## Index = wire id.
const IDS: Array[StringName] = [&"slow", &"ward_slow", &"chill", &"root", &"stun", &"silence", &"bleed", &"withered", &"fracture",
	&"hex", &"sanctified", &"incensed", &"frenzy", &"shrouded", &"barrier"]
## statuses_cleared (a ghoul digging in): sim_enemy_ai wipes exactly these
const CLEARED: Array[StringName] = [&"bleed", &"withered", &"root", &"slow", &"chill"]
const NEAR_FX := 30.0

static var _defs: Dictionary = {}      ## id -> {dur, move, atk, taken, dealt, tps, slow, root, dot, stack, max, bleed, barrier}
static var _motes: Dictionary = {}     ## id -> {rate, per_stack, y0, yr, o}
static var _wire: Dictionary = {}      ## id -> index

var _o: Node
var _rec: Dictionary = {}
var _gone: Array[StringName] = []
var _dots: Array[StringName] = []
var _acc: float = 0.0
var _flush_t: float = 0.0
var _net_dirty: bool = false
var _mults_dirty: bool = false
var _frenzy: int = -1
var _w_speed: bool = false
var _w_atk: bool = false
var _move := 1.0
var _atk := 1.0
var _taken := 1.0
var _dealt := 1.0
var _vfx: Node
var _near: bool = true
var _near_t: float = 0.0
var _shroud_on: bool = false
var replicate: bool = false      ## true for sets made by attach() (exist on every peer); ensure()d host-only sets never RPC
var _aura: Variant = null        ## the Censer Bearer's ground ring (DmEntityViews: same decal)
var _smoke_o: Dictionary = {}


# ============================================================================================ setup

## Build the rule tables and mote templates once (call at load so the first status costs nothing).
static func warm() -> void:
	if not _defs.is_empty():
		return
	DmSimData.ensure()
	var S := DmSimData
	_defs = {
		&"slow": {"dur": 0.3, "move": S.MIASMA_SLOW, "slow": true},
		&"ward_slow": {"dur": 0.3, "move": S.WATCHMANS_WARD_SLOW, "slow": true},
		&"chill": {"dur": float(S.CHILL["durationS"]), "move": float(S.CHILL["moveMult"]), "atk": float(S.CHILL["attackRateMult"])},
		&"root": {"dur": float(S.BONE_PRISON["rootS"]), "root": true},
		&"stun": {"dur": 0.5},
		&"silence": {"dur": 1.0},
		&"bleed": {"dur": float(S.HEMORRHAGE["durationS"]), "dot": true, "bleed": true},
		&"withered": {"dur": float(S.WITHERED["durationMs"]) / 1000.0, "dot": true, "stack": true, "max": 1.0e6},
		&"fracture": {"dur": float(S.FRACTURE["durationMs"]) / 1000.0, "stack": true, "max": float(S.FRACTURE["maxStacks"]), "tps": float(S.FRACTURE["perStack"])},
		&"hex": {"dur": float(S.BONE_HEX["durationS"]), "dealt": float(S.BONE_HEX["damageMult"])},
		&"sanctified": {"dur": float(S.SANCTIFIED["durationS"]), "taken": float(S.SANCTIFIED["damageTakenMult"])},
		&"incensed": {"dur": float(S.CENSER["hasteS"]), "move": float(S.CENSER["moveMult"]), "atk": float(S.CENSER["attackRateMult"])},
		&"frenzy": {"dur": FOREVER, "move": float(S.FRENZY["moveMult"]), "atk": float(S.FRENZY["attackRateMult"])},
		&"shrouded": {"dur": FOREVER, "taken": float(S.AFFIX_TUNING["shrouded"]["damageTakenMult"])},
		&"barrier": {"dur": float(S.BONE_MANTLE["durationS"]), "barrier": true},
	}
	for i in IDS.size():
		_wire[IDS[i]] = i
	var st: Dictionary = DmContent.get_export("statuses", "STATUS_FX")
	var sp: Dictionary = DmFxData.data().get("spell_fx", {})
	var rot := int((sp.get("miasma", {}) as Dictionary).get("rot", 0xffffff))
	var dust := int((sp.get("needle", {}) as Dictionary).get("dust", 0xffffff))
	_motes = {   # the DmEntityViews tells, same numbers
		&"withered": _mote(1.0, 0.75, 0.8, 0.8, {"color": rot, "spread": 0.4, "speed": 0.2, "up": 0.7, "life": 0.9, "size": 0.2}),
		&"fracture": _mote(0.0, 1.5, 1.2, 0.0, {"color": dust, "spread": 0.3, "speed": 0.6, "up": 0.4, "life": 0.5, "size": 0.1, "gravity": 5}),
		&"bleed": _mote(4.0, 0.0, 0.7, 0.6, {"color": int(st["hemorrhage"]["crimson"]), "spread": 0.3, "speed": 0.1, "up": -0.2, "life": 0.6, "size": 0.12, "gravity": 8}),
		&"chill": _mote(3.0, 0.0, 0.3, 1.2, {"color": int(st["chill"]["frost"]), "spread": 0.45, "speed": 0.15, "up": 0.2, "life": 0.8, "size": 0.14, "drag": 0.5}),
		&"sanctified": _mote(2.0, 0.0, 1.9, 0.0, {"color": int(st["sanctified"]["gold"]), "spread": 0.35, "speed": 0.1, "up": 0.5, "life": 0.7, "size": 0.16}),
		&"frenzy": _mote(5.0, 0.0, 1.1, 0.0, {"color": 0x9a1b2a, "spread": 0.3, "speed": 0.4, "up": 0.4, "life": 0.5, "size": 0.14, "gravity": 6}),
		&"incensed": _mote(3.0, 0.0, 1.2, 0.0, {"color": int(st["incensed"]["bronze"]), "spread": 0.4, "speed": 0.2, "up": 0.6, "life": 0.8, "size": 0.14}),
	}


static func _mote(rate: float, per: float, y0: float, yr: float, o: Dictionary) -> Dictionary:
	o["count"] = 1
	o["x"] = 0.0
	o["y"] = 0.0
	o["z"] = 0.0
	return {"rate": rate, "per": per, "y0": y0, "yr": yr, "o": o}


static func of(owner: Node) -> DmStatusSet:
	return owner.get_node_or_null(NODE_NAME) as DmStatusSet


## Add a set to `owner` (same call on every peer, right after the body spawns).
static func attach(owner: Node) -> DmStatusSet:   # replicated: call on every peer
	return _make(owner, true)


static func _make(owner: Node, rep: bool) -> DmStatusSet:
	var s := DmStatusSet.new()
	s.name = NODE_NAME
	s.replicate = rep
	owner.add_child(s)
	return s


static func ensure(owner: Node) -> DmStatusSet:
	var s := of(owner)
	return s if s != null else _make(owner, false)


## `amount` x the owner's damage-taken multiplier (sanctified, fracture, shrouded): THE one place it is applied. Every `take_damage` (enemy, thrall,
## hero) calls it once on entry, so any source (rites, thralls, DoTs, zones, enemy blows) gets the multiplier without opting in.
static func scale_taken(owner: Node, amount: float) -> float:
	var s := of(owner)
	return amount * s._taken if s != null else amount


## Damage through the owner's API. The multiplier is applied by the owner's take_damage (scale_taken), so this is only a convenience.
static func hit(target: Node, amount: float, from: Node = null, allow_stagger: bool = true) -> bool:
	return _deal(target, amount, from, allow_stagger, "")


## take_damage has two shapes: enemies/thralls (amount, from, allow_stagger) -> bool, the hero (amount, source, kind: String) -> float.
## Passing a bool as the hero's kind was a runtime error waiting for the first DoT on a player.
static func _deal(target: Node, amount: float, from: Node, allow_stagger: bool, kind: String) -> bool:
	if target is DmHeroBody:
		target.take_damage(amount, from, kind if kind != "" else "dot")
		return true
	dealing_dot = kind == "dot"
	var r: bool = target.take_damage(amount, from, allow_stagger)
	dealing_dot = false
	return r


## True while a DoT tick is being dealt (damage listeners such as lifesteal skip DoTs, as the original game did).
static var dealing_dot := false


func _ready() -> void:
	warm()
	_o = get_parent()
	_w_speed = &"speed_mult" in _o
	_w_atk = &"attack_rate_mult" in _o
	_acc = randf() * TICK_S   # spread the 100 ms ticks of a crowd across frames
	_vfx = get_node_or_null("/root/Vfx")
	if _o.has_signal(&"statuses_cleared"):
		_o.statuses_cleared.connect(_on_cleared)
	if _o.has_signal(&"died"):
		_o.died.connect(_on_died)
	if multiplayer.has_multiplayer_peer() and is_multiplayer_authority():
		multiplayer.peer_connected.connect(_on_peer)
	set_physics_process(is_multiplayer_authority())
	set_process(false)


func _is_host() -> bool:
	return is_inside_tree() and is_multiplayer_authority()


# ============================================================================================ queries

func has(id: StringName) -> bool:
	return _rec.has(id)

func stacks(id: StringName) -> int:
	var r: Variant = _rec.get(id)
	return int(r[STK]) if r != null else 0

func remaining(id: StringName) -> float:
	var r: Variant = _rec.get(id)
	return float(r[REM]) if r != null else 0.0

func source_of(id: StringName) -> Node:
	var r: Variant = _rec.get(id)
	return r[SRC] if r != null and is_instance_valid(r[SRC]) else null

func ids() -> Array:
	return _rec.keys()

func speed_mult() -> float:
	return _move

func attack_rate_mult() -> float:
	return _atk

func damage_taken_mult() -> float:
	return _taken

func damage_dealt_mult() -> float:
	return _dealt

func is_stunned() -> bool:
	return _rec.has(&"stun")

func is_silenced() -> bool:
	return _rec.has(&"silence")


# ============================================================================================ host: apply / remove

## Apply a status (host only; a no-op elsewhere). `duration` < 0 = the rule's default. params: dps (bleed, withered), cap (withered stack cap,
## default unlimited), amount + cap (barrier). Re-applying follows the sim: slows/chill/hex/root/stun/sanctified/incensed keep the longer time;
## bleed resets its time and the stronger dps (and its owner) wins; withered adds stacks up to cap, resets its time, keeps the strongest dps and
## the last stacker owns the kill; fracture adds stacks up to its max.
func apply(id: StringName, source: Node = null, stacks_add: int = 1, duration: float = -1.0, params: Dictionary = NO_PARAMS) -> void:
	if not _is_host():
		return
	var d: Variant = _defs.get(id)
	if d == null:
		push_error("DmStatusSet: unknown status %s" % id)
		return
	var dur: float = duration if duration >= 0.0 else float(d["dur"])
	var r: Variant = _rec.get(id)
	var fresh := r == null
	if fresh:
		r = [0.0, 0.0, 0.0, null, 0.0]
		_rec[id] = r
	var old_rem: float = r[REM]
	var old_stk: float = r[STK]
	if d.has("stack"):
		r[STK] = minf(float(params.get("cap", d["max"])), old_stk + float(stacks_add))
		r[REM] = dur
		if d.has("dot"):
			r[VAL] = maxf(r[VAL], float(params.get("dps", 0.0)))
			r[SRC] = source
	elif d.has("bleed"):
		r[STK] = 1.0
		r[REM] = dur
		var dps := float(params.get("dps", 0.0))
		if fresh or dps >= float(r[VAL]):
			r[VAL] = dps
			r[SRC] = source
	elif d.has("barrier"):
		r[STK] = 1.0
		r[REM] = maxf(old_rem, dur)
		r[VAL] = minf(float(params.get("cap", 1.0e9)), float(r[VAL]) + float(params.get("amount", 0.0)))
	else:
		r[STK] = 1.0
		r[REM] = maxf(old_rem, dur)
		if fresh:
			r[SRC] = source
	if fresh or r[STK] != old_stk:
		_mults_dirty = true
		_net_dirty = true
		_recompute()
		changed.emit()
		_visual_state()
	if id == &"stun" and r[REM] > old_rem and _o.has_method(&"stun"):
		_o.stun(dur)
	set_physics_process(true)


func remove(id: StringName) -> void:
	if _is_host() and _rec.erase(id):
		_after_removal()


func clear() -> void:
	if not _rec.is_empty():
		_rec.clear()
		_after_removal()


## Damage soaked by a barrier: returns what is left of `dmg`.
func absorb(dmg: float) -> float:
	var r: Variant = _rec.get(&"barrier")
	if r == null:
		return dmg
	var a := minf(float(r[VAL]), dmg)
	r[VAL] -= a
	if r[VAL] <= 0.0:
		remove(&"barrier")
	return dmg - a


func _after_removal() -> void:
	_mults_dirty = true
	_net_dirty = true
	_recompute()
	changed.emit()
	_visual_state()


func _on_cleared() -> void:
	if not _is_host():
		return
	var any := false
	for id in CLEARED:
		any = _rec.erase(id) or any
	if any:
		_after_removal()


func _on_died(_e: Variant) -> void:
	var w: Variant = _rec.get(&"withered")
	if w != null and _is_host():
		withered_died.emit(w[STK], w[VAL], w[SRC] if is_instance_valid(w[SRC]) else null, _o)
	clear()


# ============================================================================================ host: tick

func _physics_process(delta: float) -> void:
	advance(delta)


## Accumulate time; runs one step per TICK_S. Public so deterministic tests can drive it.
func advance(delta: float) -> void:
	_acc += delta
	if _acc >= TICK_S:
		var dt := _acc
		_acc = 0.0
		_step(dt)


func _step(dt: float) -> void:
	_flush_t += dt
	var flush := _flush_t >= FLUSH_S
	if flush:
		_flush_t = 0.0
	_gone.clear()
	_dots.clear()
	for id in _rec:
		var r: Array = _rec[id]
		var d: Dictionary = _defs[id]
		var rem: float = r[REM] - dt
		if d.has("dot"):
			r[ACC] += r[STK] * r[VAL] * minf(dt, r[REM])
			if flush or rem <= 0.0:
				_dots.append(id)
		r[REM] = rem
		if rem <= 0.0:
			_gone.append(id)
	for id in _dots:
		var r2: Variant = _rec.get(id)
		if r2 == null:
			continue   # the owner died during an earlier lump and cleared us
		var amt: float = r2[ACC]
		r2[ACC] = 0.0
		if amt > 0.0 and _o.has_method(&"take_damage"):
			var src: Node = r2[SRC] if is_instance_valid(r2[SRC]) else null
			if _deal(_o, amt, src, false, "dot"):   # the owner applies the damage-taken multiplier (scale_taken)
				dot_damage.emit(id, amt * _taken, src, float(_o.get("hp")) <= 0.0, _o)
	for id in _gone:
		if _rec.erase(id):
			_mults_dirty = true
			_net_dirty = true
			expired.emit(id)
	if _frenzy < 0:
		var df: Variant = _o.get("def")
		_frenzy = 1 if df is Dictionary and DmCombatData.truthy(df.get("frenzy")) else 0
	if _frenzy == 1 and _o.get("hp") != null:
		var on: bool = float(_o.get("hp")) < float(_o.get("max_hp")) * float(DmSimData.FRENZY["atFrac"])
		if on != _rec.has(&"frenzy"):
			if on:
				_rec[&"frenzy"] = [1.0, FOREVER, 0.0, null, 0.0]
			else:
				_rec.erase(&"frenzy")
			_mults_dirty = true
			_net_dirty = true
	if _mults_dirty:
		_recompute()
		changed.emit()
		_visual_state()
	if _net_dirty:
		_send()
	if _rec.is_empty() and _frenzy == 0:
		set_physics_process(false)


## The one place the derived multipliers are computed and written (only when the set changed).
## Slows do not stack on each other (the strongest wins, like the sim's min()); everything else multiplies.
func _recompute() -> void:
	_mults_dirty = false
	var mv := 1.0
	var slow := 1.0
	var rooted := false
	var at := 1.0
	var tk := 1.0
	var dl := 1.0
	for id in _rec:
		var d: Dictionary = _defs[id]
		if d.has("slow"):
			slow = minf(slow, float(d["move"]))
		else:
			mv *= float(d.get("move", 1.0))
		rooted = rooted or d.has("root")
		at *= float(d.get("atk", 1.0))
		tk *= float(d.get("taken", 1.0))
		dl *= float(d.get("dealt", 1.0))
		if d.has("tps"):
			tk *= 1.0 + float(d["tps"]) * float((_rec[id] as Array)[STK])
	_move = 0.0 if rooted else mv * slow
	_atk = at
	_taken = tk
	_dealt = dl
	if _w_speed:
		_o.set(&"speed_mult", _move)
	if _w_atk:
		_o.set(&"attack_rate_mult", _atk)


# ============================================================================================ replication (4 bytes per status, on change)

func encode() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(_rec.size() * 4)
	var i := 0
	for id in _rec:
		var r: Array = _rec[id]
		var deci := 65535 if r[REM] >= 6.0e4 else clampi(int(ceilf(r[REM] * 10.0)), 0, 65534)
		b[i] = _wire[id]
		b[i + 1] = clampi(int(r[STK]), 0, 255)
		b[i + 2] = deci & 255
		b[i + 3] = deci >> 8
		i += 4
	return b


func _send() -> void:
	_net_dirty = false
	if replicate and multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		_rpc_state.rpc(_wire_bytes())


## An empty array does not survive Godot's RPC argument check: send one pad byte (size % 4 != 0 = empty).
func _wire_bytes() -> PackedByteArray:
	var b := encode()
	if b.is_empty():
		b.append(255)
	return b


func _on_peer(pid: int) -> void:
	if replicate and not _rec.is_empty():
		_rpc_state.rpc_id(pid, encode())


@rpc("authority", "call_remote", "reliable")
func _rpc_state(b: PackedByteArray) -> void:
	_rec.clear()
	for i in range(0, b.size() - 3, 4):
		var deci := b[i + 2] | (b[i + 3] << 8)
		_rec[IDS[b[i]]] = [float(b[i + 1]), FOREVER if deci == 65535 else float(deci) / 10.0, 0.0, null, 0.0]
	_mults_dirty = false
	_recompute_taken_only()
	changed.emit()
	_visual_state()


## Clients only read stacks / has() for visuals; keep the pure multiplier getters right too (no owner writes).
func _recompute_taken_only() -> void:
	var w := _w_speed
	var a := _w_atk
	_w_speed = false
	_w_atk = false
	_recompute()
	_w_speed = w
	_w_atk = a


# ============================================================================================ visuals (every peer)

func _visual_state() -> void:
	set_process(_vfx != null and not _rec.is_empty())
	var sh := _rec.has(&"shrouded")
	if sh != _shroud_on:
		_shroud_on = sh
		var cr: Variant = _o.get("creature")
		if cr != null:
			cr.set_opacity(0.38 if sh else 1.0)
	var df: Variant = _o.get("def")
	if _vfx != null and df is Dictionary and bool(df.get("aura", false)):
		var inc := _rec.has(&"incensed")
		if inc and _aura == null:
			var p := (_o as Node3D).global_position
			_aura = _vfx.decal({"danger": true, "tex": "ring", "color": int(_motes[&"incensed"]["o"]["color"]), "x": p.x, "z": p.z,
				"r": float(DmSimData.CENSER["radius"]), "duration": 1e9, "opacity": 0.22, "pulse": 2.5, "follow": _follow_pos})
		elif not inc and _aura != null:
			_aura.kill()
			_aura = null


func _follow_pos() -> Variant:
	return Vector3((_o as Node3D).global_position.x, 0.0, (_o as Node3D).global_position.z) if is_instance_valid(_o) else null


func _process(delta: float) -> void:
	_near_t -= delta
	if _near_t <= 0.0:
		_near_t = 0.5
		var cam := get_viewport().get_camera_3d()
		var n3 := _o as Node3D
		_near = cam == null or n3 == null or cam.global_position.distance_to(n3.global_position) < NEAR_FX
	if not _near:
		return
	var n := _o as Node3D
	if n == null or not n.visible:
		return
	var p := n.global_position
	var sc := n.scale.y
	for id in _rec:
		var m: Variant = _motes.get(id)
		if m == null:
			continue
		var rate: float = float(m["rate"]) + float(m["per"]) * float((_rec[id] as Array)[STK])
		if randf() < delta * rate:
			var o: Dictionary = m["o"]
			o["x"] = p.x
			o["y"] = (float(m["y0"]) + randf() * float(m["yr"])) * (sc if id == &"sanctified" or id == &"incensed" else 1.0)
			o["z"] = p.z
			_vfx.emit(o)
	if _aura != null and randf() < delta * 2.0:   # the bearer trails incense smoke
		if _smoke_o.is_empty():
			_smoke_o = {"count": 1, "color": int(DmContent.get_export("statuses", "STATUS_FX")["incensed"]["smoke"]), "spread": 0.3, "speed": 0.3,
				"up": 0.5, "life": 1.4, "size": 0.9, "shrink": -0.5, "x": 0.0, "y": 1.1, "z": 0.0}
		_smoke_o["x"] = p.x
		_smoke_o["z"] = p.z
		_vfx.emit_smoke(_smoke_o)


func _exit_tree() -> void:
	if _aura != null:
		_aura.kill()
		_aura = null
