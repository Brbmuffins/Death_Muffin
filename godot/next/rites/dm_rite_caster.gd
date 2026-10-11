class_name DmRiteCaster
extends Node
## Gravecaller rites on the rebuild's session structure (REBUILD D1: the host's game is authoritative). One DmRiteCaster is a child of every
## player body, on EVERY peer, at the same NodePath (name it "Rites"; use `DmRiteCaster.attach(body, world)`).
##
## The caster is the SHARED PLUMBING only. Each rite is its own small module (godot/next/rites/rite_<id>.gd, a DmRiteModule) registered in
## DmRiteRegistry (one line per rite); the recipe for adding one is in godot/next/rites/README.md. The rules numbers live in DmAbilities /
## DmSimData / DmFxData, the visuals in DmRiteFx (shared with the original game).
##
## Flow:
##   owner client  request_cast(rite, aim, target_id)  --RPC intent-->  host `_apply_cast`
##   host validates (sender owns THIS body, finite aim, rite registered, DmAbilities.cast_check: alive/unlocked/busy/cooldown/essence, then
##        module.validate: range / target / corpse), spends + starts the cooldown through DmAbilities.apply_cast_cost, then module.resolve
##        (rolls the numbers, schedules shots with `after`, damages through DmStatusSet.hit / DmEnemy.take_damage, consumes corpses);
##        a resolve that fails (e.g. the corpse was taken first) refunds the cost and cooldown;
##   host broadcasts EVENT dicts ({t, rite, ...}) by RPC; EVERY peer (the host included, also solo) plays each event exactly once
##        through module.play: fx via DmRiteFx (the same code the original game draws the rites with), sound via AudioDirector.
##   host replicates {essence, max, cooldowns} to the owner for the HUD (`get_state()` + `state_changed`); a refusal goes back as `cast_rejected`.
## Casting is not predicted on the owner: it sees its own cast when the host's event arrives (one round trip).
##
## World contract: see godot/next/rites/README.md (DmRiteWorld).

signal state_changed(state: Dictionary)             ## owner: {essence, max_essence, cooldowns{id: remaining_ms}, alive, souls (the soul bag / Soul Harvest count)}; fires on host for the host's own body too
signal cast_rejected(rite: String, reason: String)  ## owner: the host refused the cast ("cooldown", "essence", "range", "no_target", ...)
signal event_played(ev: Dictionary)                 ## every peer, once per event, after its fx/sfx ran
signal hit_number(pos: Vector3, amount: float, crit: bool)  ## every peer: the shell floats the damage number
signal shake_requested(amount: float)               ## every peer: a rite wants a camera shake (the shell decides whether to apply it)
signal hit_resolved(rite: String, enemy_id: int, amount: float, crit: bool, killed: bool)  ## HOST only: kill credit / rewards hook

const TIP_Y := 1.4               ## sim_caster._tip default (over the head)
const STATE_HZ := 10.0
const _BLOOM := preload("res://next/rites/rite_plague_bloom.gd")   ## Rotweaver's passive lives with her signature
const HOLD_ACTIONS := {"rite_primary": "bone_needle"}   ## optional InputMap action the owner polls (hold = repeat); the slice's hotbar is next/rites/dm_rite_hotbar.gd

var world: Object = null            ## DmRiteWorld (duck-typed)
var fx: DmRiteFx = null             ## shared visuals; `fx.fx` / `fx.audio` default to the Vfx / AudioDirector autoloads (tests swap them)
var random: Callable = Callable()   ## () -> float in [0,1): needle jitter + crit (tests inject constants)
var auto_step: bool = true          ## false: tests drive the host with step(dt)

# host-side state (meaningful on the host; on the owner only `_state` is kept)
var rejected_intents: int = 0       ## host: forged intents (not the owner / bad values)
var rejected_casts: int = 0         ## host: legitimate intents refused by the rules (cooldown, essence, range, ...)
var events_played: int = 0
var gestures_played: int = 0        ## every peer: hero cast gestures played (one per accepted cast, see DmRiteGestures)
var p: Dictionary = {}
var dev: bool = false               ## host only: the dev account's "Dev access" setting opens every rite (DmAbilities.cast_check `dev`); set by DmNextUiHost
var peer_id: int = 0

var _body: Node3D
var _shared: bool = false           ## host: `p` IS the body's DmPlayerRules state (one pool of hp / essence / barrier / brews, one clock), see _init_host_state
var _state: Dictionary = {}
var _now_ms: float = 0.0
var _rng := RandomNumberGenerator.new()
var _mods: Dictionary = {}
var _legends: DmRiteLegends = null  ## host: Requiem Wraiths' wisps and nova, made only when the worn set has them
var _legend: Dictionary = {}        ## DmLegend.sim_legend_of(_mods), resolved when the mods change (never per tick); the legion's copy is DmThrallHost.legend
var _pending: Array = []            ## host: timed callbacks {at, fn} (shots in flight, delayed bursts), see after()
var _mem: Dictionary = {}           ## host: per-rite scratch state (rite id -> Dictionary), see mem()
var _state_acc: float = 0.0
var _last_sent_essence: float = -1.0
var _last_sent_souls: int = -1
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
	if as_peer == 0 and not DmRiteRegistry.has(rite):
		cast_rejected.emit(rite, "unavailable")   # a rite of the kit that has no module yet
		return
	if _is_host():
		_apply_cast(multiplayer.get_unique_id() if as_peer == 0 else as_peer, rite, aim, target_id)
	else:
		_rpc_cast.rpc_id(1, rite, aim, target_id)


## Host: true when this caster works on its body's own vitals (one essence / hp / brew pool, see _init_host_state); the body then owns regen and brews.
func shares_vitals() -> bool:
	return _shared


## The HUD view. cooldowns are remaining ms as of the last update, see cooldown_left() for a live number.
func get_state() -> Dictionary:
	return _state


func cooldown_left(rite: String) -> float:
	if _is_host() and not p.is_empty():
		# The host reads its own timeline. The replicated `_state` snapshot is only re-sent when the essence changes, so a free rite (the
		# primary at a full pool) kept its last-sent cooldown for ever and DmCombatInput's hold-repeat stalled after one cast.
		return maxf(0.0, float(p["cooldowns"].get(rite, 0.0)) - _now_ms)
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
	if _shared:
		_now_ms = float(_body.call(&"clock_ms"))   # the body's clock: its tick_vitals regenerates the one pool, brews / cooldowns / barrier share the timeline
	else:
		_now_ms += dt * 1000.0
	_sync_pos()
	if not _shared:   # a body-less caster (tests) regenerates its own essence; a shared one is regenerated by the body (tick_vitals), once
		var res: Dictionary = p["resource"]
		var rate := DmResources.passive("necromancer", {"stats": p["stats"], "value": res["value"], "max": res["max"], "sinceHurtMs": 1e9, "sinceResourceGainMs": 1e9})
		if p["brews"].get("tonic") != null:   # Tonic of grave dust / ghostwalk: more essence regen (the old game's tick_vitals; regen is linear)
			rate *= 1.0 + DmPlayerRules.brew_value(p, "essence", _now_ms)
		res["value"] = clampf(float(res["value"]) + rate * dt, 0.0, float(res["max"]))
	_step_pending()
	for m: DmRiteModule in DmRiteRegistry.steppers():
		if _mem.has(m.id):
			m.step(self, dt)
	if _legends != null and not _legends.wisps.is_empty():
		_legends.tick()
	if _mods.get("miasmaBurstsCorpses", false):   # Rotweaver passive: the corpses in her Miasma burst (rite_plague_bloom.gd)
		_BLOOM.miasma_bursts(self, dt)
	_state_acc += dt
	if _state_acc >= 1.0 / STATE_HZ:
		_state_acc = fmod(_state_acc, 1.0 / STATE_HZ)
		_push_state(false)


# ---- host: setup -------------------------------------------------------------------------------------------------------------------------

## Host: re-read the body's build (its character was bound after the caster attached, or gear / level changed). Starts a fresh state: call it
## before play, not mid-fight (cooldowns and essence reset).
func rebuild() -> void:
	if _is_host() and _body != null:
		_init_host_state()


## Host: take new stats after a level-up, an upgrade or a gear change. Unlike rebuild() the cooldowns and essence stay.
func refresh_stats(build: Dictionary) -> void:
	if p.is_empty():
		return
	DmPlayerRules.set_stats(p, build["stats"])
	p["loadout"] = build.get("loadout", p.get("loadout"))
	_set_mods(build["discipline"]["mods"])


## Host: the worn legendaries' sim mechanics (thrallDeathBurst, championEvery, ...), kept current on the legion and read by the withered rites.
## Runs once per gear / level / boon change (build time), so no cast or tick looks anything up.
func _set_mods(m: Dictionary) -> void:
	_mods = m
	_legend = DmLegend.sim_legend_of(m)
	push_legend()
	if _legends == null and (float(m.get("corpseWisp", 0.0)) > 0.0 or float(m.get("wraithNova", 0.0)) > 0.0) and _is_host():
		_legends = DmRiteLegends.new(self)
	if _legends != null:
		_legends.attach()


## The legend as of the last build.
var legend: Dictionary:
	get: return _legend


## Host: hand the legend to this body's legion (also called by the legion when it attaches after the caster).
func push_legend() -> void:
	var th := thralls()
	if th != null:
		th.set_legend(_legend)


## Host, from the body's take_damage (only when the worn set reacts to hits): Colossus Mantle's wardReflect and litanyShatter, resolved by the litany module.
func legend_hurt(raw: float, ward: float, source: Node, broke: float) -> void:
	if _is_host() and not p.is_empty():
		(DmRiteRegistry.module("black_litany") as DmRiteModule).call(&"hurt_legend", self, raw, ward, source, broke)


## Host: a drunk brew on this caster's clock (damage / haste / essence brews act through `p["brews"]`). Returns DmBrews.apply_brew's result.
func apply_brew(id: String) -> Dictionary:
	return DmBrews.apply_brew(p["brews"], id, _now_ms)


## Host: the character's socketed runes ({rite: rune_id}, DmRunes.sockets_of the bag): every rune variant a rite module implements reads them.
func set_runes(runes: Dictionary) -> void:
	if not p.is_empty():
		p["runes"] = runes


func _init_host_state() -> void:
	var build: Dictionary = {}
	if world != null and world.has_method("rite_build"):
		build = world.rite_build(peer_id)
	if build.is_empty():
		build = DmCharacterBuild.build({"class_index": 0, "level": 1}, [], {})
		build["runes"] = {}
	var family: String = String(build["discipline"]["family"]) if build.has("discipline") else "necromancer"
	var bp: Variant = _body.get("p") if _body != null else null
	_shared = bp is Dictionary and not (bp as Dictionary).is_empty() and _body.has_method(&"clock_ms")
	if _shared:
		p = bp   # ONE pool: what the HUD reads (body.resource / hp / alive) is what rites spend, brews act on and a death ends
		_now_ms = float(_body.call(&"clock_ms"))
	else:
		p = DmPlayerRules.new_state(build["stats"], family)
	p["loadout"] = build.get("loadout", DmWeaponLine.no_loadout())
	p["runes"] = build.get("runes", {})
	_set_mods(build["discipline"]["mods"])
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
	if not (is_finite(aim.x) and is_finite(aim.y) and is_finite(aim.z)) or not DmRiteRegistry.has(rite):
		_forged()
		return
	_sync_pos()
	var why := DmAbilities.cast_check(p, rite, float(p["stats"]["level"]), _now_ms, dev)
	if why != "ok":
		_refuse(sender, rite, why)
		return
	var m := DmRiteRegistry.module(rite)
	var intent := {"rite": rite, "aim": aim, "target_id": target_id, "sender": sender}
	why = m.validate(self, intent)
	if why != "":
		_refuse(sender, rite, why)
		return
	var at := _body.position if _body != null else Vector3.ZERO
	var snap := _cost_snapshot(rite)
	var emp := DmAbilities.empowered(p, rite)   # Soul Harvest: charged souls pay this cast instead of essence, and it is 1.5x as wide
	if emp:
		intent["mult"] = DmAbilities.soul_area_mult(true)
	DmAbilities.apply_cast_cost(p, rite, _now_ms, emp, bool(intent.get("colossus_cast", false)))
	why = m.resolve(self, intent)
	if why == "" and emp and _legends != null:
		_legends.nova()   # Requiem 5: a Soul Harvest cast sets every wisp and wraith off
	if why != "":
		_restore_cost(rite, snap)   # the rite did not happen (lost a race for its corpse): nothing was spent
		_refuse(sender, rite, why)
		_push_state(true)
		return
	_face_aim(aim, at)
	_gesture_cast(rite)
	_push_state(true)


## Host: a standing hero turns to its cast (the original game faces the aim), so the gesture and the picture agree. A rite that moved the
## body (a step, a dash) keeps the heading it set.
func _face_aim(aim: Vector3, from: Vector3) -> void:
	if _body == null or not _body.has_method("set_facing") or _body.position != from or bool(_body.get("dashing")):
		return
	var dx := aim.x - from.x
	var dz := aim.z - from.z
	if dx * dx + dz * dz > 0.0625:
		_body.set_facing(atan2(dx, dz))


## Host: the hero's cast gesture for an accepted cast, once on every peer (its own RPC, not an event: events_played stays the rites' own).
func _gesture_cast(rite: String) -> void:
	if not DmRiteGestures.has(rite):
		return
	if rite == "bone_needle" and bool(p["loadout"]["reap"]):
		rite = DmRiteGestures.REAP_KEY   # the Scythe swings instead of casting
	var yaw := float(_body.get("yaw")) if _body != null and _body.get("yaw") != null else 0.0
	_play_gesture(rite, yaw)
	if not multiplayer.get_peers().is_empty():
		_rpc_gesture.rpc(rite, yaw)


func _play_gesture(rite: String, yaw: float) -> void:
	var av: Variant = _body.get("avatar") if _body != null else null
	if DmRiteGestures.play(av, rite, yaw):
		gestures_played += 1


## What apply_cast_cost touches, so a failed resolve can hand it back.
func _cost_snapshot(rite: String) -> Array:
	return [float(p["resource"]["value"]), float(p["castUntil"]), float(p["rootedUntil"]), p["cooldowns"].get(rite), p["souls"]]


func _restore_cost(rite: String, snap: Array) -> void:
	p["resource"]["value"] = snap[0]
	p["castUntil"] = snap[1]
	p["rootedUntil"] = snap[2]
	p["souls"] = snap[4]
	if snap[3] == null:
		p["cooldowns"].erase(rite)
	else:
		p["cooldowns"][rite] = snap[3]


func _step_pending() -> void:
	var i := 0
	while i < _pending.size():
		var s: Dictionary = _pending[i]
		if _now_ms < float(s["at"]):
			i += 1
			continue
		_pending.remove_at(i)
		if bool(p["alive"]):   # sim: a dead caster's shots do nothing
			(s["fn"] as Callable).call()


# ---- module API (what rite_<id>.gd uses; see README) ---------------------------------------------------------------------------------------

var body: Node3D:
	get: return _body
var mods: Dictionary:
	get: return _mods
var now_ms: float:
	get: return _now_ms


func rand() -> float:
	return _rand()


## Per-rite scratch state of this caster (host): the module keeps its counters / zones here, never in its own fields (modules are shared).
func mem(rite: String) -> Dictionary:
	if not _mem.has(rite):
		_mem[rite] = {}
	return _mem[rite]


## Host: run `fn` after `delay_ms` of host clock (a projectile's flight). Skipped when the caster is dead by then.
func after(delay_ms: float, fn: Callable) -> void:
	_pending.append({"at": _now_ms + delay_ms, "fn": fn})


## The staff tip a shot leaves from.
func tip() -> Vector3:
	return Vector3(float(p["x"]), TIP_Y, float(p["z"]))


## The caster's ground position (host: from the replicated body).
func pos() -> Vector3:
	return Vector3(float(p["x"]), 0.0, float(p["z"]))


## The world's corpse field (DmCorpseField contract: pick_corpse / corpses_in_radius / consume / get_corpse / time) or null.
func corpses() -> Object:
	return world.get("corpses") if world != null else null


## The area this caster stands in ("" = no area filter).
func area() -> String:
	return String(world.area_of(peer_id)) if world != null and world.has_method("area_of") else ""


## This caster's legion (DmThrallHost, child "Thralls" of the body) or null.
func thralls() -> DmThrallHost:
	return _body.get_node_or_null("Thralls") as DmThrallHost if _body != null else null


## Host: the caster's essence (clamped to max).
func gain_essence(amount: float) -> void:
	var res: Dictionary = p["resource"]
	res["value"] = minf(float(p["stats"]["maxEssence"]), float(res["value"]) + amount)


## Host: the vitals that take barrier / healing: the body's own DmPlayerRules state when it has one (DmHeroBody), else the caster's.
func _vitals() -> Dictionary:
	var bp: Variant = _body.get("p") if _body != null and is_instance_valid(_body) else null
	return bp if bp is Dictionary and not (bp as Dictionary).is_empty() else p


## The clock the vitals' barrier hold runs on (the body's, else the caster's).
func _vitals_clock() -> float:
	var c: Variant = _body.get("_clock_ms") if _body != null and is_instance_valid(_body) else null
	return float(c) if c != null and _body.get("p") is Dictionary and not (_body.get("p") as Dictionary).is_empty() else _now_ms


## Host: max health of the vitals that take barrier / heals.
func max_hp() -> float:
	return float(_vitals()["stats"]["maxHp"])


## Host: add a barrier (DmAbilities.add_barrier keeps the peak).
func add_barrier(amount: float) -> void:
	DmAbilities.add_barrier(_vitals(), amount)


## Host: the Mantle's barrier from `corpses` (max with the current one, held for its duration). Returns the end time on the vitals clock.
func set_mantle_barrier(corpses: float) -> float:
	return DmAbilities.mantle_apply(_vitals(), corpses, _vitals_clock())


## Host: heal the body (hp lives on the body's vitals when it has them).
func heal(amount: float) -> void:
	if not is_same(_vitals(), p) and _body.has_method("heal"):
		_body.heal(amount)
	else:
		DmPlayerRules.heal(p, amount)


## Host: listen to DoT ticks of a status set (kill credit for Withered stacked by this caster).
func watch_dots(ss: DmStatusSet) -> void:
	if not ss.dot_damage.is_connected(_on_dot):
		ss.dot_damage.connect(_on_dot)
		ss.withered_died.connect(_on_withered_died)


## An enemy this caster withered died: Contagion / Plague Choir hand its stacks on (rite_miasma.gd owns both).
func _on_withered_died(stacks: float, dps: float, source: Node, target: Node) -> void:
	if source == _body and _is_host():
		(DmRiteRegistry.module("miasma") as DmRiteModule).call(&"withered_death", self, stacks, dps, target)


## Withered burns through DmStatusSet (stacks x dps, 0.25 s lumps); the caster that stacked it gets the kill credit.
func _on_dot(id: StringName, amount: float, source: Node, killed: bool, target: Node) -> void:
	if id == &"withered" and source == _body:
		hit_resolved.emit("miasma", int(world.enemy_id(target)), amount, false, killed)


static func alive_enemy(e: Node) -> bool:
	return is_instance_valid(e) and float(e.get("hp")) > 0.0


# ---- host: replication -------------------------------------------------------------------------------------------------------------------

## Host: an event to every peer (the host plays it too, once). `ev` needs `t` and `rite`; vectors and numbers only (it goes over RPC).
func broadcast(ev: Dictionary) -> void:
	_play_event(ev)   # the host sees it through the same path as everyone else, once
	if not multiplayer.get_peers().is_empty():
		_rpc_event.rpc(ev)


## Host: send the owner its HUD state now (essence / cooldowns changed).
func push_state() -> void:
	_push_state(true)


func _push_state(force: bool) -> void:
	var res: Dictionary = p["resource"]
	if not force and absf(float(res["value"]) - _last_sent_essence) < 0.01 and int(p["souls"]) == _last_sent_souls:
		return
	_last_sent_essence = float(res["value"])
	_last_sent_souls = int(p["souls"])
	var cds := {}
	for id in p["cooldowns"]:
		var left: float = float(p["cooldowns"][id]) - _now_ms
		if left > 0.0:
			cds[id] = left
	var st := {"essence": float(res["value"]), "max_essence": float(res["max"]), "cooldowns": cds, "alive": bool(p["alive"]), "souls": int(p["souls"])}
	if peer_id == multiplayer.get_unique_id():
		_adopt_state(st)
	elif peer_id in multiplayer.get_peers():
		_rpc_state.rpc_id(peer_id, st)


func _adopt_state(st: Dictionary) -> void:
	_state = st
	_recv_ms = Time.get_ticks_msec()
	state_changed.emit(st)


# ---- every peer: events -> visuals + sound -----------------------------------------------------------------------------------------------

## Once per event per peer. All fx/sfx go through DmRiteFx .
func _play_event(ev: Dictionary) -> void:
	events_played += 1
	var m := DmRiteRegistry.module(String(ev.get("rite", "")))
	if m != null:
		m.play(self, ev)
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
func _rpc_gesture(rite: String, yaw: float) -> void:
	_play_gesture(rite, yaw)


@rpc("authority", "call_remote", "reliable")
func _rpc_state(st: Dictionary) -> void:
	_adopt_state(st)


@rpc("authority", "call_remote", "reliable")
func _rpc_rejected(rite: String, reason: String) -> void:
	cast_rejected.emit(rite, reason)
