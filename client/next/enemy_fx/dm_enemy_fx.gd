class_name DmEnemyFx
extends Node
## The visuals and sounds of the combat core's enemies: telegraphs, strikes, deaths, voices, zones and the affixes' one-off moments. Ported to the core
## (client/code.list "Ported"): the same effects, colours and sounds as the node-based DmEnemyFx of godot/next/enemy_fx, through the same router
## (DmEventFx, the Vfx and AudioDirector autoloads), but driven by the signals of DmCoreHost instead of by a watcher on every enemy node. No node, no
## script and no signal connection exists per creature; what is remembered per creature is a few numbers in dictionaries keyed by id, only while it
## has something to play (a swing in its wind-up, a rise, a burrow, an elite's ring, its max health for the heavy-hit check).
##
## Exactly once per event: the host reads the core's event buffer once per tick. The impact of a swing is a timer started when its ATTACK event arrives
## (the wind-up length comes with it) and cancelled by any state change of that creature (a stun, a death); it runs on the rendered frame clock, as the
## old fx did. Telegraph shapes and colours come from DmEventFxTelegraph (the same module DmEventFx.handle uses), deaths and voices from DmEventFx.
## No new effect ids, textures or sounds, so DmWarmup's existing pass covers everything (EFFECT_IDS lists the Binbun ids used, SFX_IDS the sounds).
##
## The corpses' marks are DmEntityViews' (`corpse_added` / `corpse_gone`): a faint pale ring under every fresh corpse for its 26 s (at most CORPSE_MARKS_MAX at once,
## warm in the Fen), a violet one under a resonant corpse, a green disc under a toxic one for 5 s.
## An affixed elite's standing tells are DmEntityViews._dress_affix / _tick_affix': per affix a ground mark that follows the drawn body (the bell's ring, the hunger's
## glow, the shroud's haze, the vengeful cracks) and, near the hero, its motes on the ambient tick (drool, embers, shroud smoke while the shroud is up).
## Near the hero, on the same ambient tick, today's status tells (_tick_alive): marrow drips while it bleeds, frost motes while chilled, a priest-gold glint while
## sanctified, rot while withered, bone dust while fractured, bronze motes while incensed, blood motes while frenzied (the Flagellant under half health); and the fliers' and the wraith's hover motes. The bodies looked at are
## only those with a status (`status_changed`) or that fly.
## A body underground (a ghoul's BURROW and its eruption's wind-up) has today's dirt mound over it (`_mounds`, a node each: a few at most); a dying body raises
## dust where it comes to rest (the crowd says when: `DmCrowd.take_landings`); a corpse that goes plays today's puff for why, and one Corpse Explosion bursts is
## blown apart at once (`DmCrowd.shatter`). Every thrall stands on today's ground ring (`_thrall_rings`), the legion readable at a glance.
## The Drowned Nave's kinds: the Censer Bearer's incense cloud (`censer_incense`, following the drawn body; the ring and smoke under it and the hasted bodies' motes are the
## status tells'), the Lich Acolyte's crimson reach ring (drawn while a thrall stands within Unbind's range) and its Unbind thread and sigil, the Templar's shield glance (a
## spark and a chime), the Choir Wraith's mist when it falls (it leaves no body) and the Gargoyle's dive and the wraith's scream (telegraphs of the router).
## The Cinder Pyre's and the Mourning Fen's kinds: the sparks of the Husk's, the hound's and the Slag Brute's blows, the Husk's last embers, the burning ground (a zone of kind ember:
## the coal's, the slam's, the Husk's), the molten slam of the Slag Brute (the router picks it by the def of the body that swings), and the embers and marsh-lights they shed near the
## hero on the ambient tick (`_pfs`: the bodies that have such motes, with their state).
## The thralls' sounds are DmThrall's: `thrallRise` when one stands up (every `thrall_raised`, a guest's too) and `thrallDeath` when one is killed (`thrall_died` with reason
## "killed"; not one that crumbled at the cap, was sacrificed or decayed).
## Left out of this port (the ROADMAP's "Crowd looks" and "Crowd effects" items, native/README.md "Differences"): the shrouded body's fade (the crowd has no alpha yet),
## the elite's body glow, the Flagellant's frenzy motes, the Pyre's and the Fen's idle motes.
## The Weeping Seraph's blessing is the Deacon's cue (`sanctify`, a thread and a halo per ally), the Plague Doctor's flask is the router's telegraph (a rot-green ring and the lobbed
## flask, `flask`); its toxic pool has no visual of its own, as today (today's `DmEnemyFx` draws the dust and ember zones only).

const AMBIENT_S := 0.2
const NEAR_X := 24.0               ## ambient motes only near the hero (DmEntityViews near_fx)
const NEAR_Z := 20.0
const ELITE_AGGRO_RANGE := 40.0
const ELITE_COLOR := 0x9b5cff
const HEAVY_HIT := 0.22            ## DmEntityViews.HEAVY_HIT / HEAVY_HIT_ELITE / HITSTOP_RANGE: a hit this share of max health freezes the picture
const HEAVY_HIT_ELITE := 0.12
const HITSTOP_RANGE := 16.0
const RISE_S := 1.1                ## the rise (RISING state) the spawn dust lasts for
const DEAD := 6                    ## DmCoreEvents.State.DEAD
const CORPSE_MARKS_MAX := 8        ## DmEntityViews.CORPSE_MARKS_MAX: a wipe of 40 bodies does not add 40 decals
const RING_MS := 26000.0           ## a corpse ring's life (its decal's duration)
const HOVER := {"wraith": 0.45}    ## DmEntityViews.HOVER: the bodies that float without `flying`
const HEAD_Y := {"humanoid": 1.3, "robed": 1.35, "quadruped": 0.75, "bloat": 1.05}   ## DmEntityViews.HEAD_Y: where a body's motes start, by rig
const FIRE_DEFS: Array[String] = ["cinder_husk", "pyre_priest", "cinderhound", "slag_brute"]   ## the Cinder Pyre's dead: sparks, soot, ember tells
const FEN_DEFS: Array[String] = ["fen_wisp", "bog_hag", "drowned_sexton"]                       ## the Fen's: marsh-lights and drips (the leech's wiggle is the body's own)
const FEN_TEAL := 0x7fe0d0
const EFFECT_IDS: Array[String] = ["censer_incense", "vengeful_burst", "surge_eruption", "bonfire"]
const SFX_IDS: Array[String] = ["eliteAggro", "eliteDeath", "enemyDeath", "tellStrike", "tollSmall", "burst", "boneHit",
	"enemyAttackBeast", "enemyAttackHumanoid", "enemyAttackBrute", "enemyAttackSpirit",
	"enemyDeathBeast", "enemyDeathHumanoid", "enemyDeathBrute", "enemyDeathSpirit", "emberThrow", "emberBurst", "slagSlam", "curse", "raise", "toll", "thrallRise", "thrallDeath"]

class DefStub:
	extends RefCounted
	var def: String = ""


var vfx: Node                      ## the Vfx autoload (tests pass a counting stub)
var audio: Node                    ## the AudioDirector autoload (ditto)
var fx: DmEventFx                  ## the shared router half: telegraphs, deaths, voices, zone visuals
var host := DmEnemyFxHost.new()
var core_host: DmCoreHost
var player_pos := Callable()       ## () -> Vector3, the local hero; default: the camera's ground point
var stats := {"pf_mote": 0, "reach_ring": 0, "spawn": 0, "telegraph": 0, "strike": 0, "hit": 0, "death": 0, "erupt": 0, "dig": 0, "zone": 0, "cue": 0, "moment": 0, "corpse_mark": 0, "affix_mark": 0, "affix_mote": 0, "status_mote": 0, "hover_mote": 0, "landing": 0, "corpse_gone": 0, "shatter": 0, "thrall_ring": 0, "thrall_sound": 0}

var _clock := 0.0                  ## ms of rendered-frame time
var _amb_t := 0.0
var _strikes: Dictionary = {}      ## id -> [due ms, blow, aim x, aim z, def, x, z]: a swing in its wind-up
var _next_due := INF               ## the earliest due time in _strikes
var _rising: Dictionary = {}       ## id -> [x, z, until ms]: a body climbing out of the ground (dust while it does)
var _burrowers: Dictionary = {}    ## id -> true: tunnelling underground (dirt where it is)
var _mounds: Dictionary = {}       ## id -> the dirt mound over a body underground (DmEntityViews._make_mound): BURROW and the eruption's wind-up
var _mound_mesh: SphereMesh
var _mound_mat: StandardMaterial3D
var _auras: Dictionary = {}        ## id -> the elite ring's handle
var _health: Dictionary = {}       ## id -> Vector2(max hp, 1 if elite): for the heavy-hit check, until the body is removed
var _tele := {}                    ## scratch telegraph event, reused (the router reads it synchronously)
var _tele_call := Callable()
var _death_ev := {}
var _zone := {"id": 0, "kind": "dust", "owner": "", "x": 0.0, "z": 0.0, "r": 1.0, "until": 0.0, "hostile": true, "creep": 0.0, "contagion": false}   ## scratch zone record
var _zones := {}                   ## zone id -> true while its visual is up
var _statused := {}                ## id -> its scale: a body that got a status (looked at on the ambient tick until it has none)
var _hovers := {}                  ## id -> its hover height: a flier or the wraith (the motes under it)
var _pfs := {}                     ## id -> [def, state, scale, hover height]: a Cinder Pyre or Mourning Fen body that sheds embers or marsh-lights near the hero, while it lives
var _burst_n := 0                  ## bursts made through the scratch dictionary (the tests read it as `stats.pf_mote` for the idle motes)
var _stub := DefStub.new()         ## stands in for the sim enemy record the telegraph router looks the def up in (the Slag Brute's slam)
var _incense := {}                 ## id -> the Censer Bearer's incense cloud (a Binbun handle), while it lives
var _reach := {}                   ## id -> the Lich Acolyte's reach ring (a decal handle, null while no thrall stands in it), while it lives
var _status_fx: Dictionary = {}    ## DmContent statuses STATUS_FX: the tells' colours
var _mote_o := {"count": 1}        ## the option record every status, flier and affix mote reuses
var _affixed := {}                 ## id -> [the affix marks' handles, the affix names, scale, head height]: an affixed body, while it lives
var _unveiled := {}                ## id -> true once its shroud lifted (`unveil`): no more shroud smoke
var _thrall_rings := {}            ## thrall id -> its ground ring's handle (DmEntityViews._make_thrall), while it lives
var _thrall_looks: Dictionary = {}  ## crowd_looks.json thrall_look (the plague bearer's and the colossus' larger rings)
var _corpse_at := {}               ## corpse id -> Vector2: where it lies (the puff when it goes)
var _corpse_rings := {}            ## corpse id -> [its ring's handle, when it ends (rendered-frame ms), pale]: until the corpse goes or the ring's 26 s are over
var _px := 0.0
var _pz := 0.0
var _amb_dust := {"x": 0.0, "y": 0.1, "z": 0.0, "count": 1, "color": 0x2a2230, "spread": 0.5, "speed": 0.5, "up": 0.6, "life": 1, "size": 0.9}
var _pf := {"x": 0.0, "y": 0.0, "z": 0.0, "count": 1, "color": 0, "spread": 0.3, "speed": 0.2, "up": 1.0, "life": 0.8, "size": 0.1, "gravity": 0.0}   ## scratch for the Templar's spark and the pyre / fen tells
var _amb_dirt := {"x": 0.0, "y": 0.15, "z": 0.0, "count": 2, "color": 0xffffff, "spread": 0.35, "speed": 0.9, "up": 1.2, "life": 0.4, "size": 0.12, "gravity": 9}
var _sp: Dictionary = {}           ## DmFxData spell_fx.affix: the affixes' colours


func _ready() -> void:
	DmSimData.ensure()
	var root := get_tree().root
	if vfx == null:
		vfx = root.get_node_or_null("Vfx")
	if audio == null:
		audio = root.get_node_or_null("AudioDirector")
	_sp = DmFxData.data().get("spell_fx", {}).get("affix", {})
	_rebuild_router()


## Listens to the host. One fx per game: it would play everything twice otherwise.
func bind(h: DmCoreHost) -> void:
	core_host = h
	h.enemy_spawned.connect(_on_spawned)
	h.enemy_state.connect(_on_state)
	h.enemy_damaged.connect(_on_damaged)
	h.enemy_died.connect(_on_died)
	h.enemy_removed.connect(_on_removed)
	h.enemy_attack.connect(_on_attack)
	h.telegraph.connect(_on_telegraph)
	h.cue.connect(_on_cue)
	h.zone.connect(_on_zone)
	h.zone_gone.connect(_on_zone_gone)
	h.affix_moment.connect(_on_affix_moment)
	h.status_changed.connect(_on_status_changed)
	h.thrall_raised.connect(_on_thrall_raised)
	h.thrall_died.connect(_on_thrall_died)
	h.thrall_removed.connect(_thrall_off)
	h.statuses_cleared.connect(func(id: int) -> void: _statused.erase(id))
	h.corpse_added.connect(_on_corpse_added)
	h.corpse_gone.connect(_on_corpse_gone)
	h.corpse_consumed.connect(func(id: int, _by: int, reason: String) -> void: _on_corpse_gone(id, reason, true))


## (Re)create the shared router against the current vfx / audio (tests swap them in before the first event).
func _rebuild_router() -> void:
	fx = DmEventFx.new()
	fx.setup(host)
	fx.vfx = vfx
	fx.audio = audio
	_tele_call = fx.telegraph_fx.telegraph.bind(_tele)
	_amb_dirt["color"] = fx.sp("enemy", "dirt")


## Use these instead of the autoloads (counting back-ends in tests).
func set_backends(p_vfx: Node, p_audio: Node) -> void:
	vfx = p_vfx
	audio = p_audio
	_rebuild_router()


## Creatures this fx is holding something for (a swing, a rise, a burrow, an elite ring): tests assert it stays small and empties.
func watched() -> int:
	return _strikes.size() + _rising.size() + _burrowers.size() + _auras.size() + _affixed.size() + _statused.size() + _hovers.size() + _mounds.size() + _incense.size() + _reach.size() + _pfs.size()


func clear() -> void:
	for h in _auras.values():
		_kill(h)
	_auras.clear()
	for h in _incense.values():
		_kill(h)
	_incense.clear()
	for h in _reach.values():
		_kill(h)
	_reach.clear()
	for r in _corpse_rings.values():
		_kill(r[0])
	_corpse_rings.clear()
	_corpse_at.clear()
	for id in _thrall_rings.keys():
		_thrall_off(id)
	for id in _affixed.keys():
		_affix_off(id)
	_unveiled.clear()
	_statused.clear()
	_hovers.clear()
	_pfs.clear()
	_strikes.clear()
	_rising.clear()
	_burrowers.clear()
	for id in _mounds.keys():
		_mound_off(id)
	_health.clear()
	_next_due = INF
	fx.clear()


static func _kill(h: Variant) -> void:
	if h != null:
		h.kill()


# ============================================================================================ events

## Spawn / rise, elite ring. Runs once per spawn event (the body's stats are loaded).
func _on_spawned(id: int, def: String, _level: int, elite: bool, _area: String, _affixes: int, x: float, z: float, max_hp: float) -> void:
	_health[id] = Vector2(max_hp, 1.0 if elite else 0.0)
	var state := int(core_host.enemy_info(id).get("state", -1))   # RISING, or BURROW for a body that climbs in from underground (a ghoul); IDLE if it was not asked to rise
	var rising := state == DmCoreEvents.State.RISING or state == DmCoreEvents.State.BURROW
	if rising:
		stats["spawn"] += 1
		vfx.emit_smoke({"x": x, "y": 0.2, "z": z, "count": 10, "color": 0x2a2230, "spread": 0.7, "speed": 1, "up": 0.9, "life": 1.3, "size": 1.2, "shrink": -1})
		vfx.emit({"x": x, "y": 0.1, "z": z, "count": 4, "color": 0x5b2bb0, "spread": 0.5, "speed": 0.6, "up": 1.4, "life": 0.8, "size": 0.24})
		vfx.decal({"tex": "cracks", "color": 0x7c3aed, "x": x, "z": z, "r": 1.6 if elite else 1.1, "rot": randf() * 6.0, "duration": 2.2, "opacity": 0.8, "growFrom": 0.3})
		if state == DmCoreEvents.State.RISING:
			_rising[id] = [x, z, _clock + RISE_S * 1000.0]
	if elite:
		if rising and _dist(x, z) < ELITE_AGGRO_RANGE:
			fx.snd("eliteAggro", x, z)
		# the ring follows the drawn body (the crowd's interpolated position): by id, never a lambda capturing more than the id
		_auras[id] = vfx.decal({"danger": true, "tex": "ring", "color": ELITE_COLOR, "x": x, "z": z, "r": 1.1 * float(core_host.enemy_defs[def].get("scale", 1.0)) * float(DmSimData.ELITE["scale"]),
			"duration": 1e9, "opacity": 0.8, "pulse": 4.0, "follow": _drawn_pos.bind(id)})
	if _affixes != 0:
		_dress_affix(id, def, elite, _affixes, x, z)
	var d: Dictionary = core_host.enemy_defs.get(def, {})
	var hover := float(d.get("flying", HOVER.get(def, 0.0)))
	if hover > 0.0 and def != "fen_wisp":   # (the wisp's motes are its own marsh-lights)
		_hovers[id] = hover
	if FIRE_DEFS.has(def) or FEN_DEFS.has(def):
		_pfs[id] = [def, state, float(d.get("scale", 1.0)) * (float(DmSimData.ELITE["scale"]) if elite else 1.0), hover]
	if bool(d.get("aura", false)):   # the Censer Bearer's incense cloud (DmEnemyFx._on_ready)
		_incense[id] = fx.bb("censer_incense", x, z, {"follow": _drawn_pos.bind(id)})
	if bool(d.get("unbind", false)):   # the Lich Acolyte: its reach ring comes and goes with the thralls near it (`_ambient`)
		_reach[id] = null


## The drawn ground position of a living body (null once it is dead or gone), for decals that follow it.
func _drawn_pos(id: int) -> Variant:
	var p: Vector3 = core_host.view.crowd.ground_at(id)   # every frame for every mark that follows a body: the crowd's cheap read
	return null if p == Vector3.INF else p


## A ground telegraph (a swing's wind-up, a ghoul's eruption, the bell's ring). The router draws the shape in the original game's colours and
## schedules its own landing flourishes; the sound is its `tellStrike` / `tollSmall`.
func _on_telegraph(id: int, tell: int, from_x: float, from_z: float, aim_x: float, aim_z: float, radius: float, seconds: float) -> void:
	var kind := DmCoreEvents.TELLS[tell]
	if kind == &"slam":   # the router picks the Slag Brute's molten slam by the swinging body's def: lend it a stub for this synchronous call (the attack event came just before)
		var s: Variant = _strikes.get(id)
		if s != null:
			_stub.def = String(s[4])
			_tele["id"] = -7
			host.mirror.enemies[-7] = _stub
			_telegraph(kind, from_x, from_z, aim_x, aim_z, radius, seconds)
			host.mirror.enemies.erase(-7)
			_tele.erase("id")
			return
	_telegraph(kind, from_x, from_z, aim_x, aim_z, radius, seconds)


func _telegraph(kind: StringName, from_x: float, from_z: float, aim_x: float, aim_z: float, radius: float, seconds: float) -> void:
	stats["telegraph"] += 1
	_tele["kind"] = String(kind)
	_tele["x"] = from_x
	_tele["z"] = from_z
	_tele["tx"] = aim_x
	_tele["tz"] = aim_z
	_tele["ms"] = seconds * 1000.0
	if radius > 0.0:
		_tele["r"] = radius
	else:
		_tele.erase("r")
	vfx.danger(_tele_call)


## One-off cues, each a reliable event of the core (a guest draws them too). The Deacon's Sanctify is today's thread and halo (DmEventFx._sanctify; the blessed body's
## motes are the status tells'): a pale gold line from the Deacon, where it stands, to the ally (the cue's place) and a ring that settles on it. The Templar's shield
## glance is a spark off its front and a small chime; the Lich Acolyte's Unbind is a thread from it to the fallen thrall's place, a sigil there for the delay and the
## raise sound. The core's other cues (slam, erupt, dig_in, scream) have no visual of their own: their telegraphs and states draw them.
func _on_cue(id: int, kind: int, x: float, z: float, _radius: float) -> void:
	stats["cue"] += 1
	var p := core_host.enemy_position(id)
	if p == Vector3.INF:
		return
	match DmCoreEvents.CUES[kind]:
		&"sanctify":
			var gold := fx.status_fx("sanctified", "gold")
			fx.beam(Vector3(p.x, 1.9, p.z), Vector3(x, 1.6, z), gold, 0.04, 0.5)
			fx.decal({"tex": "ring", "color": gold, "x": x, "z": z, "r": 1.1, "duration": 0.8, "opacity": 0.8, "growFrom": 1.8})
		&"shield_block":
			var yaw := float(core_host.enemy_info(id).get("yaw", 0.0))
			_pf["color"] = fx.sp("enemy", "toll")
			_pf_burst(p.x + sin(yaw) * 0.6, 1.1, p.z + cos(yaw) * 0.6, 0.15, 2.6, 0.8, 0.3, 0.12, 6.0, 8)
			fx.snd("tollSmall", p.x, p.z)
		&"unbind":
			var curse := fx.sp("enemy", "curse")
			var delay := float(DmSimData.UNBIND["delayS"])
			fx.beam(Vector3(p.x, 1.6, p.z), Vector3(x, 0.3, z), curse, 0.06, delay)
			fx.decal({"tex": "sigil", "color": curse, "x": x, "z": z, "r": 1.0, "duration": delay + 0.3, "opacity": 0.85, "spin": 2.5, "fadeOut": 0.3})
			fx.snd("raise", x, z)


## One burst through the scratch dictionary: spread, speed, up, life, size, gravity (a drag is the caller's, in `_pf`).
func _pf_burst(x: float, y: float, z: float, spread: float, speed: float, up: float, life: float, size: float, gravity: float, count: int = 1) -> void:
	_pf["count"] = count
	_pf["x"] = x
	_pf["y"] = y
	_pf["z"] = z
	_pf["spread"] = spread
	_pf["speed"] = speed
	_pf["up"] = up
	_pf["life"] = life
	_pf["size"] = size
	_pf["gravity"] = gravity
	vfx.emit(_pf)
	_burst_n += 1


func _on_damaged(id: int, _source: int, amount: float, _hp: float) -> void:
	stats["hit"] += 1
	var h: Vector2 = _health.get(id, Vector2(1.0, 0.0))
	var frac := amount / maxf(1.0, h.x)
	if frac < (HEAVY_HIT_ELITE if h.y > 0.0 else HEAVY_HIT):
		return
	var p := core_host.enemy_position(id)
	if p != Vector3.INF and _dist(p.x, p.z) < HITSTOP_RANGE:
		host.hitstop(_hitstop_seconds(minf(1.0, frac * 1.6)))


## DmEntityViews.hitstop_seconds.
static func _hitstop_seconds(weight: float) -> float:
	return float(roundi(2.0 + clampf(weight, 0.0, 1.0) * 2.0)) / 60.0


func _on_state(id: int, _prev: int, next: int) -> void:
	_strikes.erase(id)   # any change interrupts a swing in flight (stun, death); the swing's own end is the timer
	var pf: Variant = _pfs.get(id)
	if pf != null:
		pf[1] = next
	if next != DmCoreEvents.State.RISING:
		_rising.erase(id)
	if next == DmCoreEvents.State.BURROW:
		_burrowers[id] = true
	else:
		_burrowers.erase(id)
	if next == DmCoreEvents.State.BURROW or next == DmCoreEvents.State.ERUPT:
		_mound_on(id)
	else:
		_mound_off(id)
	match next:
		DmCoreEvents.State.EMERGE:
			_erupt(id)
		DmCoreEvents.State.DIG:
			stats["dig"] += 1
			var p := core_host.enemy_position(id)
			if p != Vector3.INF:
				vfx.emit_smoke({"x": p.x, "y": 0.2, "z": p.z, "count": 4, "color": fx.sp("enemy", "dirt"), "spread": 0.5, "speed": 0.6, "up": 0.4, "life": 1, "size": 0.9})


## A swing began: its impact is a timer from now (the wind-up is in the event). What it needs at the impact is read now: the body stands still while it winds up.
func _on_attack(id: int, blow: int, aim_x: float, aim_z: float, windup_s: float) -> void:
	var info: Dictionary = core_host.enemy_info(id)
	if info.is_empty():
		return
	var pos: Vector2 = info["pos"]
	var due := _clock + windup_s * 1000.0
	_strikes[id] = [due, blow, aim_x, aim_z, String(info["def"]), pos.x, pos.y]
	_next_due = minf(_next_due, due)


## The swing lands (timer): the enemy's voice, plus the kind's impact beat. Telegraph landings (rings, cracks, shakes) are the router's.
func _impact(s: Array) -> void:
	stats["strike"] += 1
	var blow: int = s[1]
	var ax: float = s[2]
	var az: float = s[3]
	var def: String = s[4]
	fx.foe_voice("attack", def, float(s[5]), float(s[6]), 18.0)
	match DmCoreEvents.BLOWS[blow]:
		&"slam", &"hook":   # the hazards (sac, golem, the Slag Brute, the Drowned Sexton's slam and chain): a puff of smoke and chips where the fist lands
			var r := float(core_host.enemy_defs[def]["slamRadius"]) if core_host.enemy_defs[def].has("slamRadius") else 1.9
			vfx.emit_smoke({"x": ax, "y": 0.3, "z": az, "count": 4, "color": 0x3b3440, "spread": r * 0.45, "speed": 1.2, "up": 0.5, "life": 0.8, "size": 1.0})
			vfx.emit({"x": ax, "y": 0.2, "z": az, "count": 10, "color": 0x8a8378, "spread": 0.8, "speed": 2.2, "up": 1.8, "life": 0.5, "size": 0.13, "gravity": 9})
			fx.snd("boneHit", ax, az, 0.8)
		&"dust":   # the moth: a ring and a burst of dust (the cloud itself is a zone event)
			var r2 := float(DmSimData.DUST["radius"])
			var dust := fx.sp("enemy", "dust")
			vfx.emit({"x": ax, "y": 0.4, "z": az, "count": 18, "color": dust, "spread": r2 * 0.5, "speed": 1.6, "up": 0.9, "life": 0.7, "size": 0.2, "drag": 0.5})
			vfx.decal({"tex": "ring", "color": dust, "x": ax, "z": az, "r": r2 * 1.2, "duration": 0.45, "opacity": 0.9, "growFrom": 0.3})
		&"cone", &"curse", &"scream", &"flask", &"ember", &"hex", &"pulse":   # the casters' blows (the penitent's cone, the acolyte's curse, the wraith's scream, the plague doctor's flask, the priest's coal, the hag's hex, the wisp's pulse) have no beat of their own beyond their telegraph
			pass
		_:
			vfx.emit_smoke({"x": ax, "y": 0.3, "z": az, "count": 2, "color": 0x3a3340, "spread": 0.3, "speed": 0.8, "up": 0.3, "life": 0.5, "size": 0.6})
	if def == "cinder_husk" or def == "cinderhound" or def == "slag_brute":   # the Pyre's dead strike in a shower of sparks (DmEventFx._melee)
		_pf["color"] = fx.sp("enemy", "emberCore")
		_pf_burst(ax, 0.9, az, 0.3, 3.0, 1.6, 0.4, 0.1, 8.0, 12 if def == "slag_brute" else 7)


func _erupt(id: int) -> void:
	stats["erupt"] += 1
	var info: Dictionary = core_host.enemy_info(id)
	if info.is_empty():
		return
	var a: Vector2 = info["aim"]
	var dirt := fx.sp("enemy", "dirt")
	var r := float(DmSimData.BURROW["eruptR"])
	vfx.emit({"x": a.x, "y": 0.3, "z": a.y, "count": 22, "color": dirt, "spread": r * 0.5, "speed": 3.2, "up": 3, "life": 0.7, "size": 0.2, "gravity": 10})
	vfx.emit({"x": a.x, "y": 0.4, "z": a.y, "count": 8, "color": 0xe0d6c2, "spread": r * 0.4, "speed": 2.4, "up": 2.6, "life": 0.6, "size": 0.12, "gravity": 10})
	vfx.emit_smoke({"x": a.x, "y": 0.3, "z": a.y, "count": 5, "color": 0x2a1a10, "spread": r * 0.4, "speed": 1, "up": 0.6, "life": 1, "size": 1.1})
	vfx.decal({"tex": "cracks", "color": dirt, "x": a.x, "z": a.y, "r": r, "rot": randf() * 6.0, "duration": 1.6, "opacity": 0.8, "growFrom": 0.5, "fadeOut": 0.5})
	fx.snd("burst", a.x, a.y)


func _on_died(id: int, def: String, _level: int, elite: bool, _area: String, _source: int, x: float, z: float) -> void:
	stats["death"] += 1
	_kill(_auras.get(id))
	_auras.erase(id)
	_incense_off(id)
	_affix_off(id)
	_mound_off(id)
	_statused.erase(id)
	_hovers.erase(id)
	_pfs.erase(id)
	_death_ev["id"] = id
	_death_ev["x"] = x
	_death_ev["z"] = z
	_death_ev["elite"] = elite
	_death_ev["def"] = def
	fx._death(_death_ev)   # death + elite-death sound, death voice (<= 26 m), elite hitstop, water ripple, fire-death flare
	if bool(core_host.enemy_defs.get(def, {}).get("emberDeath", false)):   # the Cinder Husk's last embers (the pool itself is a zone event)
		_death_ev["kind"] = "ember"
		_death_ev["r"] = float(DmSimData.EMBER_DEATH["radius"])
		fx._burst(_death_ev)
		_death_ev.erase("kind")
		_death_ev.erase("r")
	if def == "wraith":   # leaves no body: it thins to mist (the crowd sinks it) and nothing else is drawn
		vfx.emit({"x": x, "y": 1.4, "z": z, "count": 22, "color": 0xb9cbe6, "spread": 0.6, "speed": 0.9, "up": 1.2, "life": 1.1, "size": 0.3, "drag": 1})
		return
	vfx.emit_smoke({"x": x, "y": 0.3, "z": z, "count": 6, "color": 0x3b3440, "spread": 0.6, "speed": 0.8, "up": 0.4, "life": 1, "size": 1})
	if elite:
		vfx.emit({"x": x, "y": 1, "z": z, "count": 40, "color": 0xb58cff, "spread": 0.8, "speed": 3, "up": 2, "life": 1.1, "size": 0.35})
		vfx.light_flash(Vector3(x, 1.5, z), DmFxData.hex(0xa26bff), 25.0, 0.5)


func _on_removed(id: int) -> void:
	_strikes.erase(id)   # a body that leaves alive (a boss's adds go with him) swings no more: today's slot went with its node
	_health.erase(id)
	_incense_off(id)
	_mound_off(id)
	_affix_off(id)
	_statused.erase(id)
	_hovers.erase(id)
	_pfs.erase(id)


## The Censer Bearer's cloud and the Lich Acolyte's ring go with the body.
func _incense_off(id: int) -> void:
	_kill(_incense.get(id))
	_incense.erase(id)
	_kill(_reach.get(id))
	_reach.erase(id)


func _on_status_changed(id: int) -> void:
	if _statused.has(id) or not _health.has(id):   # an enemy of this fx (a thrall's or a boss's statuses are not its)
		return
	var info: Dictionary = core_host.enemy_info(id)
	_statused[id] = float(core_host.enemy_defs.get(String(info.get("def", "")), {}).get("scale", 1.0)) * (float(DmSimData.ELITE["scale"]) if _health[id].y > 0.0 else 1.0)


## An affixed body's standing tells (DmEntityViews._dress_affix): one ground mark per affix, following the drawn body, in the affix's colour.
func _dress_affix(id: int, def: String, elite: bool, mask: int, x: float, z: float) -> void:
	var d: Dictionary = core_host.enemy_defs.get(def, {})
	var sc := float(d.get("scale", 1.0)) * (float(DmSimData.ELITE["scale"]) if elite else 1.0)
	var fol := _drawn_pos.bind(id)
	var names := DmCoreEvents.affix_list(mask)
	var marks: Array = []
	for a in names:
		match a:
			"bellTolled":
				marks.append(vfx.decal({"danger": true, "tex": "ring", "color": _col("bell"), "x": x, "z": z, "r": 1.55 * sc, "duration": 1e9, "opacity": 0.6, "pulse": 2.5, "follow": fol}))
			"hungering":
				marks.append(vfx.decal({"danger": true, "tex": "glow", "color": _col("drool"), "x": x, "z": z, "r": 1.2 * sc, "duration": 1e9, "opacity": 0.45, "follow": fol}))
			"shrouded":
				marks.append(vfx.decal({"danger": true, "tex": "glow", "color": _col("shroud"), "x": x, "z": z, "r": 1.5 * sc, "duration": 1e9, "opacity": 0.7, "blending": "mix", "follow": fol}))
			"vengeful":
				marks.append(vfx.decal({"danger": true, "tex": "cracks", "color": _col("vengeful"), "x": x, "z": z, "r": 1.3 * sc, "duration": 1e9, "opacity": 0.75, "pulse": 3.0, "spin": 0.2, "follow": fol}))
	stats["affix_mark"] += marks.size()
	_affixed[id] = [marks, names, sc, float(HEAD_Y.get(String(d.get("rig", "humanoid")), 1.3)) * sc]


func _affix_off(id: int) -> void:
	var a: Variant = _affixed.get(id)
	if a == null:
		return
	for h in a[0]:
		_kill(h)
	_affixed.erase(id)
	_unveiled.erase(id)


## Marks showing now (tests).
func affix_marks() -> int:
	var n := 0
	for a in _affixed.values():
		n += (a[0] as Array).size()
	return n


## A dust cloud (the moth's), burning ground (a boss's coals, the firebreak and the embers, the coal's, the slag slam's, the Husk's embers) and a boss's rot pool: the router's zone visual.
## The toxic pool of a burst corpse has no visual of its own today either (its aura is the corpse's), nor has a flask's (the Plague Doctor's): a boss's pool is the toxic one whose
## source is not a body of the core's table (a boss is an external of it, on a guest too); a corpse's has no source and a thrower's is its own body.
func _on_zone(id: int, kind: int, source: int, x: float, z: float, radius: float, seconds: float) -> void:
	var zk: StringName = DmCoreEvents.ZONE_KINDS[kind]
	if zk != &"dust" and zk != &"ember" and (zk != &"toxic" or source == 0 or not core_host.core.enemy_info(source).is_empty()):
		return
	stats["zone"] += 1
	_zone["id"] = id
	_zone["kind"] = String(zk)
	_zone["x"] = x
	_zone["z"] = z
	_zone["r"] = radius
	_zone["until"] = host.mirror.time + seconds
	_zones[id] = true
	vfx.danger(fx.zones_fx.zone_visual.bind(_zone), true)


func _on_zone_gone(id: int) -> void:
	if _zones.erase(id):
		fx.zones_fx.zone_gone(id)


## Dust where a dying body comes to rest (DmEntityViews._landing_dust: the crowd reports the moment, `DmCrowd.take_landings`), near the hero only.
func _landing_dust(x: float, z: float, k: float) -> void:
	if absf(x - _px) > NEAR_X or absf(z - _pz) > NEAR_Z:
		return
	vfx.emit_smoke({"x": x, "y": 0.1, "z": z, "count": 3, "color": 0x5d544a, "spread": 0.45 * k, "speed": 0.7, "up": 0.25, "life": 0.8, "size": 0.9 * k})
	vfx.emit({"x": x, "y": 0.1, "z": z, "count": 5, "color": 0x7a6f60, "spread": 0.4 * k, "speed": 1.1, "up": 0.7, "life": 0.4, "size": 0.1, "gravity": 8})
	stats["landing"] += 1


## The dirt mound over a body underground (DmEntityViews._make_mound: a flattened dark hemisphere, no shadow), so the player sees where the ghoul digs.
func _mound_on(id: int) -> void:
	if _mounds.has(id) or not is_inside_tree() or not get_parent() is Node3D:
		return
	if _mound_mesh == null:
		_mound_mesh = SphereMesh.new()
		_mound_mesh.radius = 0.55
		_mound_mesh.height = 1.1
		_mound_mesh.is_hemisphere = true
		_mound_mesh.radial_segments = 14
		_mound_mesh.rings = 5
		_mound_mat = StandardMaterial3D.new()
		_mound_mat.albedo_color = Color.html("33251a")
		_mound_mat.roughness = 1.0
	var m := MeshInstance3D.new()
	m.name = "Mound%d" % id
	m.mesh = _mound_mesh
	m.material_override = _mound_mat
	m.scale = Vector3(1.0, 0.4, 1.3)
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var p := core_host.enemy_position(id)
	if p != Vector3.INF:
		m.position = Vector3(p.x, 0.0, p.z)
	get_parent().add_child(m)
	_mounds[id] = m


func _mound_off(id: int) -> void:
	var m: Variant = _mounds.get(id)
	if m != null:
		if is_instance_valid(m):
			(m as Node).queue_free()
		_mounds.erase(id)


## A corpse on the ground (DmEntityViews._on_corpse): every fresh corpse is a necromancer's resource and a toppled body is dark on dark ground, so a faint pale ring
## marks it for the 26 s it lasts, capped so a wipe does not add a decal per body; a resonant corpse's violet ring always shows (outside the cap); a toxic corpse's green disc for 5 s.
func _on_corpse_added(id: int, kind: int, _def: String, _elite: bool, area: String, x: float, z: float, _facing: float, scale: float) -> void:
	var k := DmCoreEvents.CORPSE_KINDS[kind] if kind >= 0 and kind < DmCoreEvents.CORPSE_KINDS.size() else "normal"
	_corpse_at[id] = Vector2(x, z)
	if k == "toxic":
		_decal({"tex": "disc", "color": 0x6f8f3a, "x": x, "z": z, "r": 2.4 * scale, "duration": 5, "opacity": 0.35, "pulse": 6.0, "growFrom": 0.6})
	if _corpse_rings.has(id):
		return
	if k == "resonant":
		_corpse_rings[id] = [_decal({"tex": "ring", "color": 0xc6a4ff, "x": x, "z": z, "r": 1.2, "duration": 26, "opacity": 0.6, "pulse": 3.0}), _clock + RING_MS, false]
		stats["corpse_mark"] += 1
		return
	if corpse_marks(true) >= CORPSE_MARKS_MAX:   # the pale rings, counted by each ring's own end (today's counted handles, which only turn alive a frame later, so a wipe slipped past)
		return
	var marsh := area == "fen"
	_corpse_rings[id] = [_decal({"tex": "ring", "color": 0xffe6b0 if marsh else 0xd8cdf2, "x": x, "z": z, "r": (1.1 if marsh else 0.8) * maxf(1.0, scale), "duration": 26,
		"opacity": 0.85 if marsh else 0.4, "fadeIn": 0.8, "pulse": 2.0}), _clock + RING_MS, true]
	stats["corpse_mark"] += 1


## A thrall's ground ring (DmEntityViews._make_thrall): the spirit colour (a champion's gold, a wraith's blue), brighter when empowered, larger for a champion, the
## plague bearer and the colossus; an ally's thralls get the dimmer "other" ring. It follows the drawn body and goes when the thrall does.
func _on_thrall_raised(id: int, kind: String, owner: int, _slot: int, empowered: bool, champion: bool, x: float, z: float, _yaw: float, _max_hp: float) -> void:
	_sfx("thrallRise", x, z)   # DmThrall._rise_fx: every thrall that stands up, a guest's puppets too
	stats["thrall_sound"] += 1
	if _thrall_rings.has(id) or vfx == null:
		return
	if _thrall_looks.is_empty():
		var looks: Variant = JSON.parse_string(FileAccess.get_file_as_string(CrowdView.LOOKS_PATH))
		_thrall_looks = (looks as Dictionary).get("thrall_look", {}) if looks is Dictionary else {}
	var look: Dictionary = _thrall_looks.get(kind, {})
	var wraith := kind == "wraith"
	var r := (float(look["ring"]) if look.has("ring") else (0.6 if kind == "hound" else 0.5)) * (1.3 if champion else 1.0)
	var game := get_parent()
	var me: Node = game.local_body() if game != null and game.has_method("local_body") else null
	var own: Variant = null if me == null else int(me.get("core_id")) == owner
	_thrall_rings[id] = vfx.decal({"other": own == false, "tex": "ring", "color": 0xd9a441 if champion else (0x8fb4ff if wraith else fx.sp("exhume", "spirit")),
		"x": x, "z": z, "r": r, "duration": 1e9, "opacity": 1.0 if empowered else 0.7, "follow": _drawn_pos.bind(id)})
	stats["thrall_ring"] += 1


## A thrall fell (DmThrall._death_fx): a soft crack of bone when it was killed, not when it crumbled at the cap, was sacrificed or decayed. The ring goes with it.
func _on_thrall_died(id: int, reason: String, _owner: int, _kind: String, _source: int, x: float, z: float) -> void:
	_thrall_off(id)
	if reason == "killed":
		stats["thrall_sound"] += 1
		_sfx("thrallDeath", x, z)


func _thrall_off(id: int) -> void:
	var h: Variant = _thrall_rings.get(id)
	if h != null:
		_kill(h)
		_thrall_rings.erase(id)


## A corpse goes (DmEntityViews._on_corpse_gone): its ring with it, and today's puff for why. `consumed`: someone took it (Exhume's spirit, the Litany, a raise,
## a hungry elite's meal, Corpse Explosion's burst, which blows the body apart at once: `DmCrowd.shatter`; the blast is the rite's); else it expired or burst by itself
## (a toxic corpse's rupture: rot).
func _on_corpse_gone(id: int, reason: String, consumed := false) -> void:
	var at: Vector2 = _corpse_at.get(id, Vector2.INF)
	_corpse_at.erase(id)
	_corpse_off(id)
	if at == Vector2.INF:
		return
	match reason:
		"consumed":
			vfx.emit({"x": at.x, "y": 0.4, "z": at.y, "count": 22, "color": fx.sp("exhume", "spirit"), "spread": 0.6, "speed": 0.8, "up": 2.6, "life": 0.9, "size": 0.35})
		"litany":
			vfx.emit({"x": at.x, "y": 0.4, "z": at.y, "count": 18, "color": fx.sp("litany", "core"), "spread": 0.6, "speed": 0.8, "up": 2.2, "life": 0.8, "size": 0.35})
		"raised":
			vfx.emit({"x": at.x, "y": 0.4, "z": at.y, "count": 18, "color": fx.sp("enemy", "rot"), "spread": 0.6, "speed": 0.8, "up": 2, "life": 1, "size": 0.35})
		"devoured":   # torn apart and swallowed: olive gore, no spirit left to rise
			vfx.emit({"x": at.x, "y": 0.4, "z": at.y, "count": 22, "color": _col("drool"), "spread": 0.5, "speed": 1.6, "up": 1.4, "life": 0.7, "size": 0.26, "gravity": 5})
			vfx.emit_smoke({"x": at.x, "y": 0.3, "z": at.y, "count": 3, "color": 0x2b3317, "spread": 0.4, "speed": 0.6, "up": 0.4, "life": 1, "size": 1})
		"burst":
			if consumed:
				if core_host != null and core_host.view != null:
					core_host.view.crowd.shatter(id)
				stats["shatter"] += 1
			else:
				vfx.emit({"x": at.x, "y": 0.5, "z": at.y, "count": 20, "color": fx.sp("miasma", "rot"), "spread": 0.6, "speed": 2.5, "up": 1.5, "life": 0.7, "size": 0.3})
		_:
			return
	stats["corpse_gone"] += 1


func _corpse_off(id: int) -> void:
	var r: Variant = _corpse_rings.get(id)
	if r != null:
		_kill(r[0])
		_corpse_rings.erase(id)


## Rings showing now (`pale_only`: the capped ones, without the resonant corpses' violet rings); rings whose 26 s are over are forgotten here.
func corpse_marks(pale_only := false) -> int:
	var n := 0
	for id in _corpse_rings.keys():
		var r: Array = _corpse_rings[id]
		if float(r[1]) <= _clock:
			_corpse_rings.erase(id)
		elif bool(r[2]) or not pale_only:
			n += 1
	return n


func _decal(o: Dictionary) -> Variant:
	return vfx.decal(o) if vfx != null else null


## The affixes' one-off beats (DmAffixSet._burst, same numbers and sounds): the bell sounds, a corpse is eaten, the body bursts. `tell` is the bell's
## wind-up (its ring is the toll telegraph), `unveil` the shroud lifting (its smoke stops; the haze under it stays, as today's).
func _on_affix_moment(id: int, moment: int, at_x: float, at_z: float, to_x: float, to_z: float, amount: float) -> void:
	stats["moment"] += 1
	match DmCoreEvents.AFFIX_MOMENTS[moment]:
		&"unveil":
			_unveiled[id] = true
		&"toll":
			var bell := _col("bell")
			_sfx("toll", at_x, at_z)
			for k in 3:
				vfx.decal({"tex": "ring", "color": bell, "x": at_x, "z": at_z, "r": amount * (0.75 + k * 0.2), "duration": 0.5, "opacity": 1.0 - k * 0.25, "growFrom": 0.15, "delay": k * 0.07})
			vfx.emit({"x": at_x, "y": 0.8, "z": at_z, "count": 36, "color": bell, "spread": amount * 0.3, "speed": 5, "up": 0.8, "life": 0.5, "size": 0.28})
			vfx.light_flash(Vector3(at_x, 1.5, at_z), DmFxData.hex(bell), 30.0, 0.4)
		&"hungering":
			var drool := _col("drool")
			_sfx("raise", to_x, to_z)
			vfx.beam(Vector3(to_x, 0.3, to_z), func() -> Vector3: return Vector3(at_x, 1.1, at_z), drool, 0.07, 0.45)
			vfx.emit({"x": at_x, "y": 1.1, "z": at_z, "count": 14, "color": drool, "spread": 0.3, "speed": 0.8, "up": 0.4, "life": 0.8, "size": 0.2, "gravity": 4})
		&"vengeful":
			var veng := _col("vengeful")
			_sfx("burst", at_x, at_z)
			vfx.decal({"tex": "cracks", "color": veng, "x": at_x, "z": at_z, "r": amount * 1.4, "rot": randf() * 6.0, "duration": 2, "opacity": 0.9, "growFrom": 0.3})
			vfx.decal({"tex": "ring", "color": int(DmFxData.data().get("spell_fx", {}).get("detonate", {}).get("ember", 0xffffff)), "x": at_x, "z": at_z, "r": amount, "duration": 0.5, "opacity": 1, "growFrom": 0.2})
			vfx.emit({"x": at_x, "y": 0.6, "z": at_z, "count": 40, "color": veng, "spread": 0.5, "speed": 3.5, "up": 2.2, "life": 0.8, "size": 0.3})
			vfx.emit_smoke({"x": at_x, "y": 0.4, "z": at_z, "count": 6, "color": int(DmFxData.data().get("spell_fx", {}).get("detonate", {}).get("smoke", 0x333333)), "spread": 0.8, "speed": 1, "up": 0.8, "life": 1.2, "size": 1.3})
			vfx.light_flash(Vector3(at_x, 1.2, at_z), DmFxData.hex(veng), 32.0, 0.5)


func _col(key: String) -> int:
	return int(_sp.get(key, 0xffffff))


func _sfx(id: String, x: float, z: float) -> void:
	if audio != null:
		audio.play_sfx(id, Vector2(x, z), 1.0)


# ============================================================================================ warm-up

## Loading-time pre-warm (silent, ~0.3 s of effects at `at`, which should be in front of the camera): one of every telegraph shape, the
## spawn / death / eruption bursts, so their pooled slots, textures and shaders exist before the first fight.
## Everything is an existing effect, so DmWarmup's all-effects pass (old game) already covers the Binbun scenes; the next game has no
## DmWarmup, so DmNextGame calls this once at the end of start().
func warm(at: Vector3) -> void:
	var quiet := fx.audio
	fx.audio = null
	for kind in [&"cone", &"slam", &"dust", &"erupt", &"ember", &"hex", &"pulse", &"hook", &"raise", &"curse", &"scream", &"dive", &"flask"]:
		_telegraph(kind, at.x, at.z, at.x, at.z + 2.5, 0.0 if kind == &"cone" else 1.8, 0.3)
	for id in ["vengeful_burst", "surge_eruption", "bonfire"]:   # the pyre's bursts and burning pools
		var hb = fx.bb(id, at.x, at.z, {"scale": 0.5})
		if hb != null:
			hb.kill()
	vfx.emit_smoke({"x": at.x, "y": 0.2, "z": at.z, "count": 10, "color": 0x2a2230, "spread": 0.7, "speed": 1, "up": 0.9, "life": 0.3, "size": 1.2, "shrink": -1})
	vfx.emit({"x": at.x, "y": 0.1, "z": at.z, "count": 4, "color": 0x5b2bb0, "spread": 0.5, "speed": 0.6, "up": 1.4, "life": 0.3, "size": 0.24})
	vfx.decal({"tex": "cracks", "color": 0x7c3aed, "x": at.x, "z": at.z, "r": 1.1, "duration": 0.3, "opacity": 0.8, "growFrom": 0.3})
	vfx.decal({"danger": true, "tex": "ring", "color": ELITE_COLOR, "x": at.x, "z": at.z, "r": 1.1, "duration": 0.3, "opacity": 0.8, "pulse": 4.0})
	vfx.light_flash(Vector3(at.x, 1.5, at.z), DmFxData.hex(0xa26bff), 25.0, 0.3)
	var incense = fx.bb("censer_incense", at.x, at.z)   # the censer's cloud
	if incense != null:
		incense.kill()
	vfx.decal({"tex": "sigil", "color": 0xffffff, "x": at.x, "z": at.z, "r": 1.0, "duration": 0.3, "opacity": 0.5, "spin": 2.5})   # the Unbind sigil + thread
	fx.beam(Vector3(at.x, 1.6, at.z), Vector3(at.x + 1.0, 0.3, at.z), 0xffffff, 0.04, 0.2)
	fx.audio = quiet
	stats["telegraph"] = 0


# ============================================================================================ frame

func _process(dt: float) -> void:
	_clock += dt * 1000.0
	host.now_ms = _clock
	host.mirror.time = _clock / 1000.0
	var pp: Vector3 = _hero()
	_px = pp.x
	_pz = pp.z
	host.p["x"] = _px
	host.p["z"] = _pz
	fx.update(dt)
	if _clock >= _next_due:
		_run_due()
	if core_host != null and core_host.view != null and core_host.view.crowd != null:
		var lands: PackedFloat32Array = core_host.view.crowd.take_landings()
		for i in range(0, lands.size(), 3):
			_landing_dust(lands[i], lands[i + 1], lands[i + 2])
	for id in _mounds:   # a mound rides over its digger (a few at most)
		var p := core_host.enemy_position(id)
		if p != Vector3.INF:
			(_mounds[id] as MeshInstance3D).position = Vector3(p.x, 0.0, p.z)
	if not _rising.is_empty() or not _burrowers.is_empty() or not _affixed.is_empty() or not _statused.is_empty() or not _hovers.is_empty() or not _reach.is_empty() or not _pfs.is_empty():
		_amb_t += dt
		if _amb_t >= AMBIENT_S:
			_ambient()
			_amb_t = 0.0


## Plays the swings whose wind-up is over and finds the next due time.
func _run_due() -> void:
	var next := INF
	for id in _strikes.keys():
		var s: Array = _strikes[id]
		if _clock >= float(s[0]):
			_strikes.erase(id)
			_impact(s)
		else:
			next = minf(next, float(s[0]))
	_next_due = next


func _hero() -> Vector3:
	if player_pos.is_valid():
		return player_pos.call()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position if cam != null else Vector3.ZERO


func _dist(x: float, z: float) -> float:
	return sqrt((x - _px) * (x - _px) + (z - _pz) * (z - _pz))


## Dust of the bodies climbing out of the ground and dirt of the ones tunnelling, only near the hero. Only those bodies are looked at.
func _ambient() -> void:
	for id in _rising.keys():
		var r: Array = _rising[id]
		if _clock >= float(r[2]):
			_rising.erase(id)
		elif absf(float(r[0]) - _px) <= NEAR_X and absf(float(r[1]) - _pz) <= NEAR_Z:
			_burst(_amb_dust, float(r[0]), 0.1, float(r[1]), true)
	for id in _burrowers.keys():
		var p := core_host.enemy_position(id)
		if p != Vector3.INF and absf(p.x - _px) <= NEAR_X and absf(p.z - _pz) <= NEAR_Z:
			_burst(_amb_dirt, p.x, 0.15, p.z, false)
	for id in _affixed.keys():
		_affix_motes(id)
	for id in _hovers.keys():
		var p := core_host.enemy_position(id)
		if p != Vector3.INF and absf(p.x - _px) <= NEAR_X and absf(p.z - _pz) <= NEAR_Z and randf() < AMBIENT_S * 4.0:
			_mote(p.x, float(_hovers[id]) + 0.2, p.z, 0xb9cbe6, 0.35, 0.1, -0.3, 0.7, 0.18, 0.0, 0.0, "hover_mote")
	for id in _statused.keys():
		_status_motes(id)
	for id in _reach.keys():
		_reach_ring(id)
	var motes := _burst_n
	for id in _pfs.keys():
		var pf: Array = _pfs[id]
		var p := core_host.enemy_position(id)
		if p != Vector3.INF and absf(p.x - _px) <= NEAR_X and absf(p.z - _pz) <= NEAR_Z:
			if FIRE_DEFS.has(pf[0]):
				_fire_idle(String(pf[0]), int(pf[1]), p, float(pf[2]))
			else:
				_fen_idle(String(pf[0]), int(pf[1]), p, float(pf[2]), float(pf[3]))
	stats["pf_mote"] += _burst_n - motes


## Ember shedding of the Cinder Pyre's dead (DmEntityViews._fire_dead, same rates a second, here per ambient tick).
func _fire_idle(def: String, st: int, p: Vector3, s: float) -> void:
	var ember := fx.sp("enemy", "ember")
	var core := fx.sp("enemy", "emberCore")
	var deep := fx.sp("enemy", "emberDeep")
	var dt := AMBIENT_S
	_pf["drag"] = 0.5
	match def:
		"cinder_husk":
			if randf() < dt * 7.0:
				_pf["color"] = ember if randf() < 0.6 else core
				_pf_burst(p.x, 0.9 + randf() * 0.9, p.z, 0.3, 0.15, 1.1, 0.9, 0.1, 0.0)
		"pyre_priest":
			var wind := st == DmCoreEvents.State.ATTACK
			if randf() < dt * (22.0 if wind else 5.0):
				_pf["color"] = core
				_pf_burst(p.x, 0.9 * s, p.z, 0.2, 0.2, 1.2, 0.7, 0.18 if wind else 0.11, 0.0)
			if randf() < dt * 2.0:
				_burst_smoke(p.x, 1.5, p.z, 0x8a8680, 0.3, 0.15, 0.3, 1.6, 0.7)
		"cinderhound":
			var moving := st == DmCoreEvents.State.CHASE
			if moving and randf() < dt * 14.0:
				_pf["color"] = ember if randf() < 0.5 else core
				_pf_burst(p.x, 0.35, p.z, 0.15, 0.4, 0.8, 0.55, 0.09, 2.0)
			if moving and randf() < dt * 4.0:
				_burst_smoke(p.x, 0.5, p.z, deep, 0.2, 0.2, 0.3, 0.8, 0.6)
		"slag_brute":
			if randf() < dt * 6.0:
				_pf["color"] = ember
				_pf_burst(p.x, 1.0 + randf() * 1.6, p.z, 0.6, 0.15, 1.0, 1.1, 0.16, 0.0)
			if randf() < dt * 2.5:
				_burst_smoke(p.x, 2.2, p.z, deep, 0.4, 0.2, 0.6, 1.6, 1.1)
	_pf.erase("drag")


## The Fen's dead: the wisp's marsh-light, the hag's drips, the sexton's water (DmEntityViews._fen_dead).
func _fen_idle(def: String, st: int, p: Vector3, s: float, hover: float) -> void:
	var dt := AMBIENT_S
	match def:
		"fen_wisp":
			if randf() < dt * 9.0:
				_pf["color"] = FEN_TEAL if randf() < 0.6 else 0xeaffff
				_pf["drag"] = 0.6
				_pf_burst(p.x, hover + 0.2 + randf() * 0.6, p.z, 0.25, 0.15, -0.2, 0.8, 0.12, 0.0)
				_pf.erase("drag")
		"bog_hag":
			var wind := st == DmCoreEvents.State.ATTACK
			if randf() < dt * (20.0 if wind else 3.0):
				_pf["color"] = fx.sp("enemy", "hex") if wind else 0x6fb4a8
				_pf_burst(p.x, 1.0 + randf() * 0.8, p.z, 0.3, 0.2, 1.2 if wind else -0.4, 0.8, 0.14, -0.3 if wind else 5.0)
		"drowned_sexton":
			if randf() < dt * 6.0:
				_pf["color"] = 0x3a5a54
				_pf_burst(p.x + (randf() - 0.5) * 0.8, 1.6 * s, p.z + (randf() - 0.5) * 0.8, 0.1, 0.1, -0.3, 0.6, 0.1, 9.0)


## One smoke puff through the scratch dictionary.
func _burst_smoke(x: float, y: float, z: float, color: int, spread: float, speed: float, up: float, life: float, size: float) -> void:
	_pf["count"] = 1
	_pf["x"] = x
	_pf["y"] = y
	_pf["z"] = z
	_pf["color"] = color
	_pf["spread"] = spread
	_pf["speed"] = speed
	_pf["up"] = up
	_pf["life"] = life
	_pf["size"] = size
	_pf["shrink"] = -0.5
	_pf["gravity"] = 0.0
	vfx.emit_smoke(_pf)
	_pf.erase("shrink")
	_burst_n += 1


## The Lich Acolyte's crimson reach (DmEntityViews): drawn only while a thrall stands inside Unbind's range (the core says which are near), following the drawn body, near the hero.
func _reach_ring(id: int) -> void:
	var p := core_host.enemy_position(id)
	var ring: Variant = _reach.get(id)
	var any := false
	if p != Vector3.INF and absf(p.x - _px) <= NEAR_X and absf(p.z - _pz) <= NEAR_Z:
		any = not core_host.core.thralls_in_radius(Vector2(p.x, p.z), float(DmSimData.UNBIND["range"]), 0).is_empty()
	if any and ring == null:
		_reach[id] = vfx.decal({"danger": true, "tex": "ring", "color": fx.sp("enemy", "curse"), "x": p.x, "z": p.z,
			"r": float(DmSimData.UNBIND["range"]), "duration": 1e9, "opacity": 0.15, "pulse": 1.5, "follow": _drawn_pos.bind(id)})
		stats["reach_ring"] += 1
	elif not any and ring != null:
		_kill(ring)
		_reach[id] = null


## A body's status tells near the hero (DmEntityViews._tick_alive, today's rates a second, here per ambient tick). Reads the core's packed records:
## [status id, stacks, tenths of a second left (2 bytes)] per status, in DmStatusRules.IDS order.
func _status_motes(id: int) -> void:
	var p := core_host.enemy_position(id)
	if p == Vector3.INF or absf(p.x - _px) > NEAR_X or absf(p.z - _pz) > NEAR_Z:
		return   # far bodies cost a position read only
	var recs: PackedByteArray = core_host.core.statuses(id)
	if recs.is_empty():
		_statused.erase(id)
		return
	if _status_fx.is_empty():
		_status_fx = DmContent.get_export("statuses", "STATUS_FX")
	var sc := float(_statused[id])
	for i in range(0, recs.size(), 4):
		var sid := int(recs[i])
		if sid >= DmStatusRules.IDS.size():
			continue
		var stacks := float(recs[i + 1])
		match DmStatusRules.IDS[sid]:
			"bleed":
				if randf() < AMBIENT_S * 4.0:
					_mote(p.x, 0.7 + randf() * 0.6, p.z, _st("hemorrhage", "crimson") if randf() < 0.7 else _st("hemorrhage", "ember"), 0.3, 0.1, -0.2, 0.6, 0.12, 8.0)
			"chill":
				if randf() < AMBIENT_S * 3.0:
					_mote(p.x, 0.3 + randf() * 1.2, p.z, _st("chill", "frost"), 0.45, 0.15, 0.2, 0.8, 0.14, 0.0, 0.5)
			"sanctified":
				if randf() < AMBIENT_S * 2.0:
					_mote(p.x, 1.9 * sc, p.z, _st("sanctified", "gold"), 0.35, 0.1, 0.5, 0.7, 0.16)
			"withered":
				if randf() < AMBIENT_S * (1.0 + stacks * 0.75):
					_mote(p.x, 0.8 + randf() * 0.8, p.z, fx.sp("miasma", "rot"), 0.4, 0.2, 0.7, 0.9, 0.2)
			"fracture":
				if randf() < AMBIENT_S * 1.5 * stacks:
					_mote(p.x, 1.2, p.z, fx.sp("needle", "dust"), 0.3, 0.6, 0.4, 0.5, 0.1, 5.0)
			"incensed":
				if randf() < AMBIENT_S * 3.0:
					_mote(p.x, 1.2 * sc, p.z, _st("incensed", "bronze"), 0.4, 0.2, 0.6, 0.8, 0.14)
			"frenzy":   # the Flagellant below half health sheds blood motes (DmEntityViews: hp below half, 5 a second)
				if randf() < AMBIENT_S * 5.0:
					_mote(p.x, 1.1, p.z, 0x9a1b2a, 0.3, 0.4, 0.4, 0.5, 0.14, 6.0)


## One mote through a reused option record (the emitter copies what it keeps): no dictionary is built per mote.
func _mote(x: float, y: float, z: float, color: int, spread: float, speed: float, up: float, life: float, size: float, gravity := 0.0, drag := 0.0, stat := "status_mote") -> void:
	var o := _mote_o
	o["x"] = x
	o["y"] = y
	o["z"] = z
	o["color"] = color
	o["spread"] = spread
	o["speed"] = speed
	o["up"] = up
	o["life"] = life
	o["size"] = size
	if gravity > 0.0:
		o["gravity"] = gravity
	else:
		o.erase("gravity")
	if drag > 0.0:
		o["drag"] = drag
	else:
		o.erase("drag")
	vfx.emit(o)
	stats[stat] += 1


func _st(group: String, key: String) -> int:
	return int((_status_fx.get(group, {}) as Dictionary).get(key, 0xffffff))


## An affixed body's motes near the hero (DmEntityViews._tick_affix, at today's rates: drool 4, embers 3 and shroud smoke 2 a second, here per ambient tick).
func _affix_motes(id: int) -> void:
	var v: Dictionary = core_host.view.crowd.view_info(id)
	if v.is_empty() or int(v["state"]) == DEAD:
		return
	var p: Vector3 = v["pos"]
	if absf(p.x - _px) > NEAR_X or absf(p.z - _pz) > NEAR_Z:
		return
	var a: Array = _affixed[id]
	var sc := float(a[2])
	var head := float(a[3])
	for name in a[1]:
		match name:
			"hungering":
				if randf() < AMBIENT_S * 4.0:
					var f := float(v.get("yaw", 0.0))
					_mote(p.x + sin(f) * 0.3 * sc, head, p.z + cos(f) * 0.3 * sc, _col("drool"), 0.06, 0.1, -0.3, 0.7, 0.13, 7.0, 0.0, "affix_mote")
			"vengeful":
				if randf() < AMBIENT_S * 3.0:
					_mote(p.x, 0.3 + randf() * head, p.z, _col("vengeful"), 0.35 * sc, 0.2, 1.1, 0.7, 0.12, 0.0, 0.0, "affix_mote")
			"shrouded":
				if not _unveiled.has(id) and randf() < AMBIENT_S * 2.0:
					vfx.emit_smoke({"x": p.x, "y": 0.4 + randf() * head, "z": p.z, "count": 1, "color": _col("shroud"), "spread": 0.4 * sc, "speed": 0.15, "up": 0.4, "life": 1.2, "size": 0.9, "shrink": -0.6})
					stats["affix_mote"] += 1


func _burst(o: Dictionary, x: float, y: float, z: float, smoke: bool) -> void:
	o["x"] = x
	o["y"] = y
	o["z"] = z
	if smoke:
		vfx.emit_smoke(o)
	else:
		vfx.emit(o)
