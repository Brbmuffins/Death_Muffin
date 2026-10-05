class_name DmRiteCaster
extends Node
## Gravecaller rites on the rebuild's session structure (REBUILD D1: the host's game is authoritative). One DmRiteCaster is a child of every
## player body, on EVERY peer, at the same NodePath (name it "Rites"; use `DmRiteCaster.attach(body, world)`).
##
## Two rites, both from the existing data and rules (no new numbers):
##   - "bone_needle"  the Gravecaller primary (LMB, targeting enemy, 380 ms, free, +6 essence per hit);
##   - "miasma"       Miasma Circle, the grimoire's area rite (ground, 25 essence, 7 s, radius 3.8, a 6 s Withered cloud).
## Why these: bone_needle IS the primary; of the kit's rites (marrow_spear, exhume, miasma, black_litany, corpse_explosion) miasma is the only
## area rite that needs nothing else: exhume/black_litany/corpse_explosion need corpses or thralls (a later system), marrow_spear is a line.
##
## Flow:
##   owner client  request_cast(rite, aim, target_id)  --RPC intent-->  host `_apply_cast`
##   host validates (sender owns THIS body, finite aim, rite known, DmAbilities.cast_check: alive/unlocked/busy/cooldown/essence, range),
##        spends + starts the cooldown through DmAbilities.apply_cast_cost, rolls the numbers with DmAbilities (needle_cast / needle_hit /
##        miasma), flies the shot with the existing projectile speeds, and on arrival damages DmEnemy through take_damage;
##   host broadcasts EVENT dicts ("cast", "hit", "land") by RPC; EVERY peer (the host included, also solo) plays each event exactly once:
##        fx via DmRiteFx (the same code the current game draws these rites with), sound via AudioDirector.
##   host replicates {essence, max, cooldowns} to the owner for the HUD (`get_state()` + `state_changed`); a refusal goes back as `cast_rejected`.
## Casting is not predicted on the owner: it sees its own cast when the host's event arrives (one round trip).
##
## World contract: see godot/next/rites/README.md (DmRiteWorld).

signal state_changed(state: Dictionary)             ## owner: {essence, max_essence, cooldowns{id: remaining_ms}, alive}; fires on host for the host's own body too
signal cast_rejected(rite: String, reason: String)  ## owner: the host refused the cast ("cooldown", "essence", "range", "no_target", ...)
signal event_played(ev: Dictionary)                 ## every peer, once per event, after its fx/sfx ran
signal hit_number(pos: Vector3, amount: float, crit: bool)  ## every peer: the shell floats the damage number
signal hit_resolved(rite: String, enemy_id: int, amount: float, crit: bool, killed: bool)  ## HOST only: kill credit / rewards hook

const RITES: Array[String] = ["bone_needle", "miasma"]
const NEEDLE_SPEED := 26.0       ## sim_caster._fire_needle
const MIASMA_SPEED := 18.0       ## sim_caster._miasma projectile
const NEEDLE_TIP_Y := 1.4        ## sim_caster._tip default (over the head)
const NEEDLE_TARGET_Y := 1.0
const MIASMA_TARGET_Y := 0.2
const PICK_RADIUS := 1.5         ## aim point -> enemy when the client names no target (input tolerance, not a game number)
const STATE_HZ := 10.0
const DOT_STEP_S := 0.25         ## Withered damage is applied in lumps this long (one flash per lump, not per frame)
const HOLD_ACTIONS := {"rite_primary": "bone_needle", "rite_1": "miasma"}  ## optional InputMap actions (owner polls them if they exist)

var world: Object = null            ## DmRiteWorld (duck-typed)
var fx: DmRiteFx = null             ## shared visuals; `fx.fx` / `fx.audio` default to the Vfx / AudioDirector autoloads (tests swap them)
var random: Callable = Callable()   ## () -> float in [0,1): needle jitter + crit (tests inject constants)
var auto_step: bool = true          ## false: tests drive the host with step(dt)

# host-side state (meaningful on the host; on the owner only `_state` is kept)
var rejected_intents: int = 0       ## host: forged intents (not the owner / bad values)
var rejected_casts: int = 0         ## host: legitimate intents refused by the rules (cooldown, essence, range, ...)
var events_played: int = 0
var p: Dictionary = {}
var peer_id: int = 0

var _body: Node3D
var _state: Dictionary = {}
var _now_ms: float = 0.0
var _rng := RandomNumberGenerator.new()
var _mods: Dictionary = {}
var _pending: Array = []            ## host: shots in flight {at, kind, ...}
var _zones: Array = []              ## host: {x, z, r, dps, until, tick, cap}
var _withered: Dictionary = {}      ## host: enemy_id -> {stacks, t, dps, acc, slow_until}
var _needle_casts: int = 0
var _state_acc: float = 0.0
var _last_sent_essence: float = -1.0
var _recv_ms: int = 0
var _hold_t: float = 0.0


## Add a DmRiteCaster named "Rites" to `body` (call on every peer for every body, same name).
static func attach(body: Node3D, rite_world: Object) -> DmRiteCaster:
	var c := DmRiteCaster.new()
	c.name = "Rites"
	c.world = rite_world
	body.add_child(c)
	return c


func _ready() -> void:
	DmSimData.ensure()
	_body = get_parent() as Node3D
	peer_id = int(_body.get("owner_peer")) if _body != null and _body.get("owner_peer") != null else 0
	fx = DmRiteFx.with_autoloads()
	_rng.randomize()
	if multiplayer.is_server():
		_init_host_state()
	set_physics_process(true)
	set_process(true)


func _rand() -> float:
	return float(random.call()) if random.is_valid() else _rng.randf()


func _is_host() -> bool:
	return multiplayer.is_server()


func is_owner_peer() -> bool:
	return peer_id != 0 and multiplayer.get_unique_id() == peer_id


# ---- public API: owner client ------------------------------------------------------------------------------------------------------------

## Ask the host to cast `rite` at `aim` (ground point). `target_id` = the enemy under the cursor (-1 = none; the host then picks the nearest
## enemy to the aim point). Only the body's owner may call this; on any other peer it is refused locally (and a forged RPC is refused by the host).
## `as_peer` exists so tests can forge intents; leave it 0.
func request_cast(rite: String, aim: Vector3, target_id: int = -1, as_peer: int = 0) -> void:
	if as_peer == 0 and not is_owner_peer():
		cast_rejected.emit(rite, "not_owner")
		return
	if _is_host():
		_apply_cast(multiplayer.get_unique_id() if as_peer == 0 else as_peer, rite, aim, target_id)
	else:
		_rpc_cast.rpc_id(1, rite, aim, target_id)


## The HUD view. cooldowns are remaining ms as of the last update, see cooldown_left() for a live number.
func get_state() -> Dictionary:
	return _state


func cooldown_left(rite: String) -> float:
	var cds: Dictionary = _state.get("cooldowns", {})
	if not cds.has(rite):
		return 0.0
	var age := float(Time.get_ticks_msec() - _recv_ms) if not _is_host() else 0.0
	return maxf(0.0, float(cds[rite]) - age)


# ---- public API: host --------------------------------------------------------------------------------------------------------------------

func set_alive(alive: bool) -> void:
	if p.is_empty():
		return
	p["alive"] = alive


func essence() -> float:
	return float(p["resource"]["value"]) if not p.is_empty() else float(_state.get("essence", 0.0))


## Advance the host simulation (shots, clouds, regen, state replication). Called from _physics_process when `auto_step`.
func step(dt: float) -> void:
	if p.is_empty():
		return
	_now_ms += dt * 1000.0
	_sync_pos()
	var res: Dictionary = p["resource"]
	var rate := DmResources.passive("necromancer", {"stats": p["stats"], "value": res["value"], "max": res["max"], "sinceHurtMs": 1e9, "sinceResourceGainMs": 1e9})
	res["value"] = clampf(float(res["value"]) + rate * dt, 0.0, float(res["max"]))
	_step_pending()
	_step_zones(dt)
	_step_withered(dt)
	_state_acc += dt
	if _state_acc >= 1.0 / STATE_HZ:
		_state_acc = fmod(_state_acc, 1.0 / STATE_HZ)
		_push_state(false)


# ---- host: setup -------------------------------------------------------------------------------------------------------------------------

func _init_host_state() -> void:
	var build: Dictionary = {}
	if world != null and world.has_method("rite_build"):
		build = world.rite_build(peer_id)
	if build.is_empty():
		build = DmCharacterBuild.build({"class_index": 0, "level": 1}, [], {})
		build["runes"] = {}
	var family: String = String(build["discipline"]["family"]) if build.has("discipline") else "necromancer"
	p = DmPlayerRules.new_state(build["stats"], family)
	p["loadout"] = build.get("loadout", DmWeaponLine.no_loadout())
	p["runes"] = build.get("runes", {})
	_mods = build["discipline"]["mods"]
	_sync_pos()
	_push_state(true)


func _sync_pos() -> void:
	if _body != null and is_instance_valid(_body):
		var g := _body.global_position if _body.is_inside_tree() else _body.position
		p["x"] = g.x
		p["z"] = g.z


func _physics_process(delta: float) -> void:
	if auto_step and _is_host():
		step(delta)


func _process(delta: float) -> void:
	# Owner input (optional InputMap actions; the shell supplies aim): hold-to-cast, the host's cooldown does the pacing.
	if world == null or not is_owner_peer() or not world.has_method("aim_point"):
		return
	_hold_t -= delta
	if _hold_t > 0.0:
		return
	for a in HOLD_ACTIONS:
		if InputMap.has_action(a) and Input.is_action_pressed(a):
			_hold_t = 0.05
			var tid := int(world.aim_target_id()) if world.has_method("aim_target_id") else -1
			request_cast(HOLD_ACTIONS[a], world.aim_point(), tid)
			return


# ---- host: validation + resolution -------------------------------------------------------------------------------------------------------

func _refuse(sender: int, rite: String, reason: String) -> void:
	rejected_casts += 1
	if sender == multiplayer.get_unique_id():
		cast_rejected.emit(rite, reason)
	else:
		_rpc_rejected.rpc_id(sender, rite, reason)


func _forged() -> void:
	rejected_intents += 1


func _apply_cast(sender: int, rite: String, aim: Vector3, target_id: int) -> void:
	if not _is_host() or p.is_empty():
		return
	if sender != peer_id:
		_forged()
		return
	if not (is_finite(aim.x) and is_finite(aim.y) and is_finite(aim.z)) or not RITES.has(rite):
		_forged()
		return
	_sync_pos()
	var why := DmAbilities.cast_check(p, rite, float(p["stats"]["level"]), _now_ms)
	if why != "ok":
		_refuse(sender, rite, why)
		return
	var from := [float(p["x"]), NEEDLE_TIP_Y, float(p["z"])]
	if rite == "bone_needle":
		var foe := _pick_enemy(aim, target_id)
		if foe == null:
			_refuse(sender, rite, "no_target")
			return
		var fp := foe.global_position
		if DmAbilities.shortfall(p, rite, {"x": fp.x, "z": fp.z}, DmSimConsts.BOSS_RADIUS) > 0.0:
			_refuse(sender, rite, "range")
			return
		var rn := DmAbilities.rune(p, rite)
		if rn == "rune_volley":
			_needle_casts += 1
		var nc := DmAbilities.needle_cast(DmAbilities.sp(p, _now_ms), p["loadout"], rn, _needle_casts, _rand())
		var crit_roll := _rand()
		DmAbilities.apply_cast_cost(p, rite, _now_ms, false)
		var to := Vector3(fp.x, NEEDLE_TARGET_Y, fp.z)
		var eid := int(world.enemy_id(foe))
		_pending.append({"at": _now_ms + Vector3(from[0], from[1], from[2]).distance_to(to) / NEEDLE_SPEED * 1000.0, "kind": "needle",
			"enemy_id": eid, "dmg": nc["dmg"], "essence": nc["essence"], "crit_roll": crit_roll})
		_broadcast({"t": "cast", "rite": rite, "by": peer_id, "from": Vector3(from[0], from[1], from[2]), "to": to, "enemy_id": eid,
			"speed": NEEDLE_SPEED, "volley": nc["volley"]})
	else:
		var m := DmAbilities.miasma(DmAbilities.sp(p, _now_ms), _mods, DmAbilities.rune(p, rite), 1.0, {"x": p["x"], "z": p["z"]}, {"x": aim.x, "z": aim.z})
		DmAbilities.apply_cast_cost(p, rite, _now_ms, false)
		var to2 := Vector3(m["x"], MIASMA_TARGET_Y, m["z"])
		var tip := Vector3(from[0], from[1], from[2])
		_pending.append({"at": _now_ms + tip.distance_to(to2) / MIASMA_SPEED * 1000.0, "kind": "miasma", "m": m})
		_broadcast({"t": "cast", "rite": rite, "by": peer_id, "from": tip, "to": to2, "speed": MIASMA_SPEED, "arc": 12.0})
	_push_state(true)


## The enemy a needle is aimed at: the named one if it is a live enemy, else the nearest to the aim point within PICK_RADIUS.
func _pick_enemy(aim: Vector3, target_id: int) -> Node3D:
	if world == null:
		return null
	if target_id >= 0:
		var e := world.enemy_by_id(target_id) as Node3D
		if e != null and _alive(e):
			return e
	var best: Node3D = null
	var best_d := INF
	for n in world.enemies_in_radius(aim, PICK_RADIUS):
		var e2 := n as Node3D
		if e2 == null or not _alive(e2):
			continue
		var d := Vector2(e2.global_position.x - aim.x, e2.global_position.z - aim.z).length()
		if d < best_d:
			best_d = d
			best = e2
	return best


static func _alive(e: Node) -> bool:
	return is_instance_valid(e) and float(e.get("hp")) > 0.0


func _step_pending() -> void:
	var i := 0
	while i < _pending.size():
		var s: Dictionary = _pending[i]
		if _now_ms < float(s["at"]):
			i += 1
			continue
		_pending.remove_at(i)
		if not bool(p["alive"]):
			continue   # sim: a dead caster's shots do nothing
		if s["kind"] == "needle":
			_needle_arrive(s)
		else:
			_miasma_land(s["m"])


func _needle_arrive(s: Dictionary) -> void:
	var e := world.enemy_by_id(int(s["enemy_id"])) as Node3D
	if e == null or not _alive(e):
		return
	var hit := DmAbilities.needle_hit(float(s["dmg"]), float(s["crit_roll"]))
	var amount: float = hit["amount"]
	var applied: bool = e.take_damage(amount, _body)
	if not applied:
		return
	var res: Dictionary = p["resource"]
	res["value"] = minf(float(p["stats"]["maxEssence"]), float(res["value"]) + float(s["essence"]))
	var gp := e.global_position
	_broadcast({"t": "hit", "rite": "bone_needle", "by": peer_id, "enemy_id": int(s["enemy_id"]), "pos": Vector3(gp.x, NEEDLE_TARGET_Y, gp.z),
		"amount": amount, "crit": bool(hit["crit"])})
	hit_resolved.emit("bone_needle", int(s["enemy_id"]), amount, bool(hit["crit"]), float(e.get("hp")) <= 0.0)
	_push_state(true)


func _miasma_land(m: Dictionary) -> void:
	_zones.append({"x": float(m["x"]), "z": float(m["z"]), "r": float(m["r"]), "dps": float(m["dps"]), "until": _now_ms + float(m["durationMs"]),
		"tick": 0.0, "cap": float(m["witheredCap"])})
	_broadcast({"t": "land", "rite": "miasma", "by": peer_id, "x": float(m["x"]), "z": float(m["z"]), "r": float(m["r"])})


## The cloud, sim_zones.update_zones for a friendly miasma: every 1 s pulse each enemy inside gets +1 Withered stack (capped) and the
## strongest dps; enemies inside are slowed (MIASMA_SLOW) while they stand in it.
func _step_zones(dt: float) -> void:
	var i := 0
	while i < _zones.size():
		var z: Dictionary = _zones[i]
		if _now_ms >= float(z["until"]):
			_zones.remove_at(i)
			continue
		i += 1
		z["tick"] = float(z["tick"]) - dt
		var pulse: bool = z["tick"] <= 0.0
		if pulse:
			z["tick"] = 1.0
		for n in world.enemies_in_radius(Vector3(z["x"], 0.0, z["z"]), float(z["r"]) + 2.0):
			var e := n as Node3D
			if e == null or not _alive(e):
				continue
			var gp := e.global_position
			if Vector2(gp.x - float(z["x"]), gp.z - float(z["z"])).length() > float(z["r"]) + float(e.get("radius")):
				continue
			var eid := int(world.enemy_id(e))
			var w: Dictionary = _withered.get(eid, {"stacks": 0.0, "t": 0.0, "dps": 0.0, "acc": 0.0, "slow_until": 0.0})
			_withered[eid] = w
			e.speed_mult = DmSimData.MIASMA_SLOW
			w["slow_until"] = _now_ms + 300.0
			if pulse:
				w["stacks"] = minf(float(z["cap"]), float(w["stacks"]) + 1.0)
				w["t"] = float(DmSimData.WITHERED["durationMs"]) / 1000.0
				w["dps"] = maxf(float(w["dps"]), float(z["dps"]))


## sim_enemy_ai: Withered burns stacks x dps per second for WITHERED.durationMs after the last pulse.
func _step_withered(dt: float) -> void:
	for eid in _withered.keys():
		var w: Dictionary = _withered[eid]
		var e := world.enemy_by_id(int(eid)) as Node3D
		if e == null or not _alive(e):
			_withered.erase(eid)
			continue
		if float(w["slow_until"]) > 0.0 and _now_ms >= float(w["slow_until"]):
			w["slow_until"] = 0.0
			if is_equal_approx(float(e.speed_mult), DmSimData.MIASMA_SLOW):
				e.speed_mult = 1.0
		if float(w["t"]) > 0.0 and float(w["stacks"]) > 0.0:
			w["t"] = float(w["t"]) - dt
			w["acc"] = float(w["acc"]) + float(w["stacks"]) * float(w["dps"]) * dt
			if float(w["t"]) <= 0.0 or _now_ms - float(w.get("last", 0.0)) >= DOT_STEP_S * 1000.0:
				var amt := float(w["acc"])
				w["acc"] = 0.0
				w["last"] = _now_ms
				if amt > 0.0 and e.take_damage(amt, _body, false):
					var killed := float(e.get("hp")) <= 0.0
					hit_resolved.emit("miasma", int(eid), amt, false, killed)
			if float(w["t"]) <= 0.0:
				w["stacks"] = 0.0
				w["dps"] = 0.0
		if float(w["stacks"]) <= 0.0 and float(w["slow_until"]) <= 0.0:
			_withered.erase(eid)


# ---- host: replication -------------------------------------------------------------------------------------------------------------------

func _broadcast(ev: Dictionary) -> void:
	_play_event(ev)   # the host sees it through the same path as everyone else, once
	if not multiplayer.get_peers().is_empty():
		_rpc_event.rpc(ev)


func _push_state(force: bool) -> void:
	var res: Dictionary = p["resource"]
	if not force and absf(float(res["value"]) - _last_sent_essence) < 0.01:
		return
	_last_sent_essence = float(res["value"])
	var cds := {}
	for id in p["cooldowns"]:
		var left: float = float(p["cooldowns"][id]) - _now_ms
		if left > 0.0:
			cds[id] = left
	var st := {"essence": float(res["value"]), "max_essence": float(res["max"]), "cooldowns": cds, "alive": bool(p["alive"])}
	if peer_id == multiplayer.get_unique_id():
		_adopt_state(st)
	elif peer_id in multiplayer.get_peers():
		_rpc_state.rpc_id(peer_id, st)


func _adopt_state(st: Dictionary) -> void:
	_state = st
	_recv_ms = Time.get_ticks_msec()
	state_changed.emit(st)


# ---- every peer: events -> visuals + sound -----------------------------------------------------------------------------------------------

## Once per event per peer. All fx/sfx go through DmRiteFx (shared with the current game's DmAbilitySystem).
func _play_event(ev: Dictionary) -> void:
	events_played += 1
	match String(ev["t"]):
		"cast":
			var from: Vector3 = ev["from"]
			var to: Vector3 = ev["to"]
			if ev["rite"] == "bone_needle":
				fx.needle_cast([from.x, from.y, from.z], from.x, from.z, bool(ev.get("volley", false)))
				var eid := int(ev["enemy_id"])
				var last := [to]
				var w := world   # captured by value: the shot may outlive this node
				var follow := func() -> Variant:
					var e := w.enemy_by_id(eid) as Node3D if w != null else null
					if e != null and is_instance_valid(e):
						last[0] = Vector3(e.global_position.x, NEEDLE_TARGET_Y, e.global_position.z)
					return last[0]
				fx.shot(from, follow, float(ev["speed"]), 0.0, "needle", DmFxData.spell("needle", "trail"))
			else:
				fx.shot(from, to, float(ev["speed"]), float(ev["arc"]), "orb", DmFxData.spell("miasma", "rot"))
		"hit":
			var pos: Vector3 = ev["pos"]
			fx.needle_hit([pos.x, pos.y, pos.z], bool(ev["crit"]))
			hit_number.emit(pos, float(ev["amount"]), bool(ev["crit"]))
		"land":
			fx.miasma_land(float(ev["x"]), float(ev["z"]), float(ev["r"]))
	if world != null and world.has_method("on_rite_event"):
		world.on_rite_event(ev)
	event_played.emit(ev)


# ---- RPCs --------------------------------------------------------------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _rpc_cast(rite: String, aim: Vector3, target_id: int) -> void:
	if _is_host():
		_apply_cast(multiplayer.get_remote_sender_id(), rite, aim, target_id)


@rpc("authority", "call_remote", "reliable")
func _rpc_event(ev: Dictionary) -> void:
	_play_event(ev)


@rpc("authority", "call_remote", "reliable")
func _rpc_state(st: Dictionary) -> void:
	_adopt_state(st)


@rpc("authority", "call_remote", "reliable")
func _rpc_rejected(rite: String, reason: String) -> void:
	cast_rejected.emit(rite, reason)
