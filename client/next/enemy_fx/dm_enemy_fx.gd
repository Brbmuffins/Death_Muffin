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
## Left out of this port (the ROADMAP's "Crowd looks" and "Crowd effects" items, native/README.md "Differences"): the shrouded body's fade (the crowd has no alpha yet),
## the elite's body glow, the fliers' hover motes, the censer, the Pyre's and the Fen's idle motes (those defs are not on the core yet), the acolyte's reach ring.

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
const HEAD_Y := {"humanoid": 1.3, "robed": 1.35, "quadruped": 0.75, "bloat": 1.05}   ## DmEntityViews.HEAD_Y: where a body's motes start, by rig
const EFFECT_IDS: Array[String] = ["censer_incense", "vengeful_burst", "surge_eruption", "bonfire"]
const SFX_IDS: Array[String] = ["eliteAggro", "eliteDeath", "enemyDeath", "tellStrike", "tollSmall", "burst", "boneHit",
	"enemyAttackBeast", "enemyAttackHumanoid", "enemyAttackBrute", "enemyAttackSpirit",
	"enemyDeathBeast", "enemyDeathHumanoid", "enemyDeathBrute", "enemyDeathSpirit", "emberThrow", "emberBurst", "slagSlam", "curse", "raise", "toll"]

var vfx: Node                      ## the Vfx autoload (tests pass a counting stub)
var audio: Node                    ## the AudioDirector autoload (ditto)
var fx: DmEventFx                  ## the shared router half: telegraphs, deaths, voices, zone visuals
var host := DmEnemyFxHost.new()
var core_host: DmCoreHost
var player_pos := Callable()       ## () -> Vector3, the local hero; default: the camera's ground point
var stats := {"spawn": 0, "telegraph": 0, "strike": 0, "hit": 0, "death": 0, "erupt": 0, "dig": 0, "zone": 0, "cue": 0, "moment": 0, "corpse_mark": 0, "affix_mark": 0, "affix_mote": 0}

var _clock := 0.0                  ## ms of rendered-frame time
var _amb_t := 0.0
var _strikes: Dictionary = {}      ## id -> [due ms, blow, aim x, aim z, def, x, z]: a swing in its wind-up
var _next_due := INF               ## the earliest due time in _strikes
var _rising: Dictionary = {}       ## id -> [x, z, until ms]: a body climbing out of the ground (dust while it does)
var _burrowers: Dictionary = {}    ## id -> true: tunnelling underground (dirt where it is)
var _auras: Dictionary = {}        ## id -> the elite ring's handle
var _health: Dictionary = {}       ## id -> Vector2(max hp, 1 if elite): for the heavy-hit check, until the body is removed
var _tele := {}                    ## scratch telegraph event, reused (the router reads it synchronously)
var _tele_call := Callable()
var _death_ev := {}
var _zone := {"id": 0, "kind": "dust", "owner": "", "x": 0.0, "z": 0.0, "r": 1.0, "until": 0.0, "hostile": true, "creep": 0.0, "contagion": false}   ## scratch zone record
var _zones := {}                   ## zone id -> true while its visual is up
var _affixed := {}                 ## id -> [the affix marks' handles, the affix names, scale, head height]: an affixed body, while it lives
var _unveiled := {}                ## id -> true once its shroud lifted (`unveil`): no more shroud smoke
var _corpse_rings := {}            ## corpse id -> [its ring's handle, when it ends (rendered-frame ms), pale]: until the corpse goes or the ring's 26 s are over
var _px := 0.0
var _pz := 0.0
var _amb_dust := {"x": 0.0, "y": 0.1, "z": 0.0, "count": 1, "color": 0x2a2230, "spread": 0.5, "speed": 0.5, "up": 0.6, "life": 1, "size": 0.9}
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
	h.corpse_added.connect(_on_corpse_added)
	h.corpse_gone.connect(func(id: int, _reason: String) -> void: _corpse_off(id))
	h.corpse_consumed.connect(func(id: int, _by: int, _reason: String) -> void: _corpse_off(id))


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
	return _strikes.size() + _rising.size() + _burrowers.size() + _auras.size() + _affixed.size()


func clear() -> void:
	for h in _auras.values():
		_kill(h)
	_auras.clear()
	for r in _corpse_rings.values():
		_kill(r[0])
	_corpse_rings.clear()
	for id in _affixed.keys():
		_affix_off(id)
	_unveiled.clear()
	_strikes.clear()
	_rising.clear()
	_burrowers.clear()
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


## The drawn ground position of a living body (null once it is dead or gone), for decals that follow it.
func _drawn_pos(id: int) -> Variant:
	var v: Dictionary = core_host.view.crowd.view_info(id)
	if v.is_empty() or int(v["state"]) == DEAD:
		return null
	var p: Vector3 = v["pos"]
	return Vector3(p.x, 0.0, p.z)


## A ground telegraph (a swing's wind-up, a ghoul's eruption, the bell's ring). The router draws the shape in the original game's colours and
## schedules its own landing flourishes; the sound is its `tellStrike` / `tollSmall`.
func _on_telegraph(_id: int, tell: int, from_x: float, from_z: float, aim_x: float, aim_z: float, radius: float, seconds: float) -> void:
	_telegraph(DmCoreEvents.TELLS[tell], from_x, from_z, aim_x, aim_z, radius, seconds)


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


## One-off cues. The core's (slam, erupt, dig_in) have no visual of their own: their telegraphs and states draw them.
func _on_cue(_id: int, _kind: int, _x: float, _z: float, _radius: float) -> void:
	stats["cue"] += 1


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
	if next != DmCoreEvents.State.RISING:
		_rising.erase(id)
	if next == DmCoreEvents.State.BURROW:
		_burrowers[id] = true
	else:
		_burrowers.erase(id)
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
		&"slam":   # the hazards (sac, golem): a puff of smoke and chips where the fist lands
			var r := float(core_host.enemy_defs[def]["slamRadius"]) if core_host.enemy_defs[def].has("slamRadius") else 1.9
			vfx.emit_smoke({"x": ax, "y": 0.3, "z": az, "count": 4, "color": 0x3b3440, "spread": r * 0.45, "speed": 1.2, "up": 0.5, "life": 0.8, "size": 1.0})
			vfx.emit({"x": ax, "y": 0.2, "z": az, "count": 10, "color": 0x8a8378, "spread": 0.8, "speed": 2.2, "up": 1.8, "life": 0.5, "size": 0.13, "gravity": 9})
			fx.snd("boneHit", ax, az, 0.8)
		&"dust":   # the moth: a ring and a burst of dust (the cloud itself is a zone event)
			var r2 := float(DmSimData.DUST["radius"])
			var dust := fx.sp("enemy", "dust")
			vfx.emit({"x": ax, "y": 0.4, "z": az, "count": 18, "color": dust, "spread": r2 * 0.5, "speed": 1.6, "up": 0.9, "life": 0.7, "size": 0.2, "drag": 0.5})
			vfx.decal({"tex": "ring", "color": dust, "x": ax, "z": az, "r": r2 * 1.2, "duration": 0.45, "opacity": 0.9, "growFrom": 0.3})
		&"cone":   # the penitent's cone has no beat of its own beyond its telegraph
			pass
		_:
			vfx.emit_smoke({"x": ax, "y": 0.3, "z": az, "count": 2, "color": 0x3a3340, "spread": 0.3, "speed": 0.8, "up": 0.3, "life": 0.5, "size": 0.6})


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
	_affix_off(id)
	_death_ev["id"] = id
	_death_ev["x"] = x
	_death_ev["z"] = z
	_death_ev["elite"] = elite
	_death_ev["def"] = def
	fx._death(_death_ev)   # death + elite-death sound, death voice (<= 26 m), elite hitstop, water ripple, fire-death flare
	vfx.emit_smoke({"x": x, "y": 0.3, "z": z, "count": 6, "color": 0x3b3440, "spread": 0.6, "speed": 0.8, "up": 0.4, "life": 1, "size": 1})
	if elite:
		vfx.emit({"x": x, "y": 1, "z": z, "count": 40, "color": 0xb58cff, "spread": 0.8, "speed": 3, "up": 2, "life": 1.1, "size": 0.35})
		vfx.light_flash(Vector3(x, 1.5, z), DmFxData.hex(0xa26bff), 25.0, 0.5)


func _on_removed(id: int) -> void:
	_health.erase(id)
	_affix_off(id)


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


## A dust cloud (the moth's): the router's zone visual. The toxic pool of a burst corpse has no visual of its own today either (its aura is the corpse's).
func _on_zone(id: int, kind: int, _source: int, x: float, z: float, radius: float, seconds: float) -> void:
	if DmCoreEvents.ZONE_KINDS[kind] != &"dust":
		return
	stats["zone"] += 1
	_zone["id"] = id
	_zone["kind"] = "dust"
	_zone["x"] = x
	_zone["z"] = z
	_zone["r"] = radius
	_zone["until"] = host.mirror.time + seconds
	_zones[id] = true
	vfx.danger(fx.zones_fx.zone_visual.bind(_zone), true)


func _on_zone_gone(id: int) -> void:
	if _zones.erase(id):
		fx.zones_fx.zone_gone(id)


## A corpse on the ground (DmEntityViews._on_corpse): every fresh corpse is a necromancer's resource and a toppled body is dark on dark ground, so a faint pale ring
## marks it for the 26 s it lasts, capped so a wipe does not add a decal per body; a resonant corpse's violet ring always shows (outside the cap); a toxic corpse's green disc for 5 s.
func _on_corpse_added(id: int, kind: int, _def: String, _elite: bool, area: String, x: float, z: float, _facing: float, scale: float) -> void:
	var k := DmCoreEvents.CORPSE_KINDS[kind] if kind >= 0 and kind < DmCoreEvents.CORPSE_KINDS.size() else "normal"
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
	for kind in [&"cone", &"slam", &"dust", &"erupt", &"ember", &"hex", &"pulse", &"hook"]:
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
	vfx.decal({"tex": "sigil", "color": 0xffffff, "x": at.x, "z": at.z, "r": 1.0, "duration": 0.3, "opacity": 0.5, "spin": 2.5})
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
	if not _rising.is_empty() or not _burrowers.is_empty() or not _affixed.is_empty():
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
					vfx.emit({"x": p.x + sin(f) * 0.3 * sc, "y": head, "z": p.z + cos(f) * 0.3 * sc, "count": 1, "color": _col("drool"), "spread": 0.06, "speed": 0.1, "up": -0.3, "life": 0.7, "size": 0.13, "gravity": 7})
					stats["affix_mote"] += 1
			"vengeful":
				if randf() < AMBIENT_S * 3.0:
					vfx.emit({"x": p.x, "y": 0.3 + randf() * head, "z": p.z, "count": 1, "color": _col("vengeful"), "spread": 0.35 * sc, "speed": 0.2, "up": 1.1, "life": 0.7, "size": 0.12})
					stats["affix_mote"] += 1
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
