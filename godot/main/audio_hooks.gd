class_name DmAudioHooks
extends Node
## Wires the game to the AudioDirector autoload (port of the web's audio.* call sites in WorldScene / AbilitySystem / EntityViews).
## Game scripts call the static one-liners (`DmAudioHooks.needle_cast(pos)`), which do nothing when no hooks node exists (tests, tools).
## The node itself, each frame: follows the hero (listener), keeps the area bed/music in step with `main.area_id`, drives hero
## footsteps from the walk loop's phase (water where the hero wades), watches the door gates for a seal breaking, and exposes the
## boss-music switch. Combat level for the music duck is derived by the AudioDirector from the sounds played, as in the web.

static var inst: DmAudioHooks = null

var main: Node
var ad: Node                      # the AudioDirector (injectable for tests)
var _area := ""
var _last_pos := Vector3.INF
var _water: Array = []
var _puddles: Array = []
var _doors: Dictionary = {}       # door id -> {x, z, open}
var _doors_primed := false
var _boss_on := false
var _still_t := 0.0

func setup(m: Node, director: Node = null) -> void:
	main = m
	ad = director if director != null else get_node_or_null("/root/AudioDirector")
	inst = self
	var w: Dictionary = DmData.world()
	for k in ["water", "bog", "ponds"]:
		_water.append_array(w.get(k, []))
	_puddles = w.get("puddles", [])
	for d in w.doors:
		_doors[d.id] = {"x": float(d.cx), "z": float(d.cz), "open": false}

func _exit_tree() -> void:
	if inst == self:
		inst = null
	if ad != null and is_instance_valid(ad):
		ad.stop_area()

func _process(dt: float) -> void:
	if ad == null or main == null or main.player == null or not main.ready_:
		return
	var p := Vector3(main.player.x, 0.0, main.player.z)
	ad.set_listener(p.x, p.z)
	if main.area_id != _area:
		_area = main.area_id
		ad.set_area(_area)
	_footsteps(p, dt)
	_gates()

# ----------------------------------------------------------------- hero footsteps
func is_wet(x: float, z: float) -> bool:
	for r in _water:
		if x >= r.x0 and x <= r.x1 and z >= r.z0 and z <= r.z1:
			return true
	for q in _puddles:
		var dx: float = x - float(q.x)
		var dz: float = z - float(q.z)
		var c := cos(float(q.rot))
		var s := sin(float(q.rot))
		var lx := (dx * c + dz * s) / (float(q.r) * float(q.sx))
		var lz := (-dx * s + dz * c) / float(q.r)
		if lx * lx + lz * lz <= 1.0:
			return true
	return false

func _footsteps(p: Vector3, dt: float) -> void:
	var moved := 0.0 if _last_pos == Vector3.INF else Vector2(p.x - _last_pos.x, p.z - _last_pos.z).length()
	_last_pos = p
	# Physics moves the hero at a fixed step, so single frames can show no movement: only a short standstill counts as stopped.
	_still_t = 0.0 if moved > 0.0005 else _still_t + dt
	if _still_t > 0.15:
		ad.hero_stopped()
		return
	var phase := -1.0
	var running := false
	# The avatar's walk loop gives the stride phase (else the distance fallback steps).
	var av = main.avatar
	if av != null and av.has_method("loop_phase"):
		phase = float(av.loop_phase())
		running = av.has_method("is_running") and bool(av.is_running())
	ad.hero_footfall(phase, p.x, p.z, _area, is_wet(p.x, p.z), running)

# ----------------------------------------------------------------- seals / gates
func _gates() -> void:
	var b = main.builder
	if b == null:
		return
	for id in _doors:
		var g: Variant = b.gates.get(id)
		if g == null:
			continue
		var open: bool = g.open
		var st: Dictionary = _doors[id]
		if open and not st.open and _doors_primed:
			ad.play_sfx("gate", Vector2(st.x, st.z))   # WorldScene.checkUnlocks: gate at the door's centre
		st.open = open
	_doors_primed = true

# ----------------------------------------------------------------- boss score
## The web: audio.setBossMusic(p.alive && boss.active && boss area == current area). The boss integration calls this each frame.
func set_boss_music(active: bool) -> void:
	if active != _boss_on or ad.boss_bed_active() != active:
		_boss_on = active
		ad.set_boss_music(active)

func update_boss(player_alive: bool, boss_active: bool, boss_area: String) -> void:
	set_boss_music(player_alive and boss_active and boss_area == _area)

# ----------------------------------------------------------------- static one-liners
static func _play(id: String, pos: Variant = null, intensity: float = 1.0) -> void:
	if inst != null and inst.ad != null:
		inst.ad.play_sfx(id, pos, intensity)

static func _near(pos: Vector3, range_: float) -> bool:
	if inst == null or inst.main == null or inst.main.player == null:
		return false
	var h := Vector3(inst.main.player.x, 0.0, inst.main.player.z)
	return Vector2(pos.x - h.x, pos.z - h.z).length() <= range_

static func click() -> void:
	_play("click")

static func error() -> void:
	_play("error")

static func panel_open() -> void:
	_play("panelOpen")

static func panel_close() -> void:
	_play("panelClose")

static func needle_cast(pos: Vector3) -> void:
	_play("needleCast", pos)

static func needle_hit(pos: Vector3, crit: bool = false) -> void:
	_play("needleHit", pos, 1.4 if crit else 1.0)

## The enemy's telegraph (WorldScene.telegraph): a generic strike tell at its windup.
static func enemy_windup(pos: Vector3) -> void:
	_play("tellStrike", pos)

## The 'melee' event: the enemy's attack grunt by voice family, only near the hero (18 m).
static func enemy_strike(enemy_id: String, pos: Vector3) -> void:
	var fam := DmAudioMap.enemy_voice(enemy_id)
	if fam != "" and _near(pos, 18.0):
		_play(DmAudioMap.voice_attack(fam), pos)

## The 'death' event: enemyDeath (eliteDeath for elites) + the family death cry within 26 m.
static func enemy_died(enemy_id: String, pos: Vector3, elite: bool = false) -> void:
	_play("eliteDeath" if elite else "enemyDeath", pos)
	var fam := DmAudioMap.enemy_voice(enemy_id)
	if fam != "" and _near(pos, 26.0):
		_play(DmAudioMap.voice_death(fam), pos)

## WorldScene.onHurt: 'hurt' (head-relative), plus 'lowHealth' under 30% hp.
static func hero_hurt(hp: float, max_hp: float) -> void:
	_play("hurt")
	if hp > 0.0 and hp < max_hp * 0.3:
		_play("lowHealth")

## Exhume: 'exhume' at the corpse on the cast; 'thrallRise' when the thrall stands (0.9 s later, the rise time).
static func thrall_raised(pos: Vector3) -> void:
	_play("exhume", pos)
	if inst != null and inst.is_inside_tree():
		inst.get_tree().create_timer(0.9).timeout.connect(func() -> void: _play("thrallRise", pos))

static func thrall_hit(kind: String, target: Vector3) -> void:
	_play("thrallShot" if kind == "archer" else "thrallMagic" if kind == "wraith" or kind == "bonemage" else "thrallMelee", target)

## A thrall killed (not one that crumbled at the cap): a soft crack when within 24 m of the camera focus.
static func thrall_died(pos: Vector3) -> void:
	if _near(pos, 24.0):
		_play("thrallDeath", pos)

## LootView drop sound by rarity (legendary / epic / rare, else the plain drop).
static func loot_drop(rarity: String, pos: Vector3) -> void:
	_play("lootDropLegendary" if rarity == "legendary" else "lootDropEpic" if rarity == "epic" else "lootDropRare" if rarity == "rare" else "lootDrop", pos)

## Items went into the bag (WorldScene.collected).
static func loot_collected(rarities: Array) -> void:
	if inst != null and inst.ad != null:
		inst.ad.play_loot(rarities)

## One gathering work cycle (WorldScene.onGatherCycle): 'reel' on a fishing success, else the skill's cycle sound at the node.
static func gather_cycle(skill: String, kind: String, success: bool, pos: Vector3) -> void:
	if inst != null and inst.ad != null:
		if success and skill == "fishing":
			inst.ad.play_sfx("reel", pos)
		else:
			inst.ad.gather(skill, kind, pos)

## Boss integration: the web's per-frame switch.
static func boss_music(player_alive: bool, boss_active: bool, boss_area: String) -> void:
	if inst != null and inst.ad != null:
		inst.update_boss(player_alive, boss_active, boss_area)
