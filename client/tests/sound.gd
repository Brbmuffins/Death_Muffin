extends SceneTree
## Sound on the combat core's events (client/README.md "Sound"): the game scene as a player gets it (every area but the Depths,
## today's HUD, audio on), headless, with a RECORDING STAND-IN for the AudioDirector autoload: every call the game makes on it is logged, and it passes the calls on to the real
## director where a check needs the real thing (areas, music, footsteps). Checked:
##   - a scripted fight in the Hollow Graves plays the cues today's code would play, by name and count. The expectation is built from the core's own events with TODAY'S rules,
##     written out here from archive/old-game:godot/next/enemy_fx/dm_enemy_fx.gd, archive/old-game:godot/game/dm_event_fx*.gd, archive/old-game:godot/next/thralls/dm_thrall.gd, archive/old-game:godot/next/affixes/dm_affix_set.gd and
##     archive/old-game:godot/next/hud/dm_next_ui_host.gd, not from the client's code:
##       a rising elite within 40 m: eliteAggro; every telegraph: its sound by kind (cone and toll tollSmall, raise raise, curse curse, else tellStrike);
##       a swing that lands (not interrupted by a state change or the body leaving): the enemy's attack voice within 18 m, and boneHit for a slam;
##       a ghoul's eruption: burst; a death: enemyDeath or eliteDeath and the death voice within 26 m; the affixes' moments: toll (the bell), raise (a meal), burst (the vengeful);
##       a thrall standing up: thrallRise; one killed (not crumbled, sacrificed or decayed): thrallDeath; the hero hurt: hurt, and lowHealth under 30 %;
##   - each piece alone where one number says it (thrallRise at its place, thrallDeath only for "killed", the Exhume cast's own sound);
##   - the hero's world: footsteps on the real director (and the area passed with them), the area's bed and music for every area visited (set_area, the real director's cue),
##     the gate sound when a seal breaks (once per opening, at the door's centre, not before the hooks' first frame), the boss score while the King is awake;
##   - ZERO script errors or engine errors in the log.
## What the counts leave out: pictures and the sounds other systems own (rites, loot, panels: tests/rites.gd, value.gd, panels.gd). The hero stands still and cannot fall in the fight.
## Gets the robber and the hound into a scratch folder first (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd). Run: godot --headless --fixed-fps 60 --path client --script res://tests/sound.gd  (--fixed-fps 60 makes the fight run as fast as the CPU allows and keeps frames and ticks together)

class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


## The AudioDirector as the game sees it: every call recorded, and passed on to the real one when `real` is set.
class Proxy:
	extends Node
	var real: Node = null
	var plays: Array = []      ## [name, x, z, intensity] of every play_sfx
	var loops: Array = []
	var areas: Array = []      ## set_area ids, in order
	var bosses: Array = []     ## set_boss_music values, in order
	var foot: Array = []       ## [phase, x, z, area, wet, running] of hero_footfall
	var stopped := 0           ## hero_stopped calls
	var listener := Vector2.ZERO
	var applied := 0
	var partner := false

	func play_sfx(sfx_name: String, pos: Variant = null, intensity: float = 1.0) -> bool:
		var p := Vector2(NAN, NAN)
		if pos is Vector2:
			p = pos
		elif pos is Vector3:
			p = Vector2(pos.x, pos.z)
		plays.append([sfx_name, p.x, p.y, intensity])
		return real.play_sfx(sfx_name, pos, intensity) if real != null else true

	func play_loot(rarities: Array) -> void:
		plays.append(["loot:" + ",".join(PackedStringArray(rarities)), NAN, NAN, 1.0])
		if real != null:
			real.play_loot(rarities)

	func loop_sfx(sfx_name: String, ms: float, pos: Variant = null, follow: Callable = Callable()) -> int:
		loops.append(sfx_name)
		return real.loop_sfx(sfx_name, ms, pos, follow) if real != null else 0

	func stop_loop(handle: int) -> void:
		if real != null:
			real.stop_loop(handle)

	func set_listener(x: float, z: float) -> void:
		listener = Vector2(x, z)
		if real != null:
			real.set_listener(x, z)

	func set_area(area_id: String, force: bool = false) -> void:
		areas.append(area_id)
		if real != null:
			real.set_area(area_id, force)

	func stop_area() -> void:
		if real != null:
			real.stop_area()

	func set_boss_music(active: bool) -> void:
		bosses.append(active)
		if real != null:
			real.set_boss_music(active)

	func boss_bed_active() -> bool:
		return real.boss_bed_active() if real != null else (bosses.size() > 0 and bool(bosses[-1]))

	func hero_footfall(phase: float, x: float, z: float, area_id: String, wet: bool = false, running: bool = false) -> void:
		foot.append([phase, x, z, area_id, wet, running])
		if real != null:
			real.hero_footfall(phase, x, z, area_id, wet, running)

	func hero_stopped() -> void:
		stopped += 1
		if real != null:
			real.hero_stopped()

	func gather(skill: String, kind: String = "", pos: Variant = null) -> void:
		if real != null:
			real.gather(skill, kind, pos)

	func apply_settings(s: Dictionary) -> void:
		applied += 1
		if real != null:
			real.apply_settings(s)

	func current_area() -> String:
		return real.current_area() if real != null else (String(areas[-1]) if not areas.is_empty() else "")

	func music_cue() -> String:
		return real.music_cue() if real != null else ""

	func names() -> Array:
		return plays.map(func(p: Array) -> String: return p[0])

	func count(sfx_name: String) -> int:
		var n := 0
		for p in plays:
			if p[0] == sfx_name:
				n += 1
		return n


## The game's face as DmAudioHooks asks for it, to see its first frame (tests/sound.gd `_gates`).
class FakeWorld:
	extends Node
	signal door_opened(id: String)


class FakeMain:
	extends Node
	var world := FakeWorld.new()
	var player: Node3D
	var ready_ := true
	var area_id := "graves"
	var avatar: Node = null
	var builder: Node = null

	func _init() -> void:
		add_child(world)


const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://sound_test"
const BAKE := ["grave_robber", "bone_hound"]
const RISING := DmCoreEvents.State.RISING
const BURROW := DmCoreEvents.State.BURROW
const EMERGE := DmCoreEvents.State.EMERGE
const SLAM := 3                     ## DmCoreEvents.BLOWS index of &"slam"
const GAP := 2                      ## ticks of doubt between the physics clock and the frame clock the strike timers run on
## The names the fight's expectation speaks for (the enemies', the thralls' and the hero's cues; the voices come with their family).
const OWN := ["eliteAggro", "tellStrike", "tollSmall", "raise", "curse", "boneHit", "burst", "toll", "enemyDeath", "eliteDeath", "thrallRise", "thrallDeath", "hurt", "lowHealth",
	"enemyAttackBeast", "enemyAttackHumanoid", "enemyAttackBrute", "enemyAttackSpirit", "enemyDeathBeast", "enemyDeathHumanoid", "enemyDeathBrute", "enemyDeathSpirit"]

var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var proxy: Proxy
var real: Node
var g: DmNextGame
var host: DmCoreHost
var core: RefCounted
var hero: DmHeroBody
var caster: DmRiteCaster
var evs: Array = []                 ## the core's events as the fight saw them, in order: {t (tick), k, ...}
var orig_max_hp := 0.0
var stepped: Array = []             ## the real director's sfx_played names


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL sound: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_ticks: int) -> bool:
	var end := Engine.get_physics_frames() + limit_ticks
	while not bool(cond.call()) and Engine.get_physics_frames() < end:
		await physics_frame
	return bool(cond.call())


func _initialize() -> void:
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DmUiConfig.dir = ""   # in-memory stores: the run reads and leaves nothing in the user folder
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
	DmSimData.ensure()
	real = root.get_node("AudioDirector")
	real.name = "AudioDirectorReal"
	proxy = Proxy.new()
	proxy.name = "AudioDirector"
	root.add_child(proxy)
	real.sfx_played.connect(func(n: String) -> void: stepped.append(n))
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("sound%d" % (Time.get_ticks_usec() % 100000), "s@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	DmDevMock.set_level(mock, ch.data, 20)
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api, {"name": "tester", "hud": true, "audio": true, "seed": 20261016, "waves": false, "wander": false, "persist": false, "baked_dir": OUT})
	host = g.core_host
	core = host.core
	hero = g.local_body()
	caster = hero.get_node("Rites") as DmRiteCaster
	check(g.ready_ and g.get_node_or_null("AudioHooks") != null, "the game scene is up with the audio hooks (audio: true)")
	_record()
	await ticks(10)
	await _start_up()
	await _to_the_graves()
	await _deaths()
	await _elite_aggro()
	await _the_fight()
	await _thralls()
	await _hero_hurt()
	_the_fight_against_today()
	await _the_hero_world()
	g.queue_free()   # leaving the world: the area's bed and score stop
	await until(func() -> bool: return proxy.current_area() == "", 120)
	check(proxy.current_area() == "", "leaving the world stops the area (stop_area)")
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d: %s)" % [errlog.errors.size(), str(errlog.errors.slice(0, 3))])
	print("%s sound %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	await process_frame
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------------------------------------------ the record of the fight

func _hero_at() -> Vector2:
	return Vector2(hero.position.x, hero.position.z)


func _record() -> void:
	host.enemy_spawned.connect(func(id: int, def: String, _lv: int, el: bool, _ar: String, _af: int, x: float, z: float, _hp: float) -> void:
		var st := int(host.enemy_info(id).get("state", -1))
		evs.append({"t": host.ticks, "k": "spawn", "id": id, "def": def, "elite": el, "at": Vector2(x, z), "hero": _hero_at(), "rising": st == RISING or st == BURROW}))
	host.enemy_state.connect(func(id: int, _p: int, next: int) -> void: evs.append({"t": host.ticks, "k": "state", "id": id, "next": next}))
	host.enemy_removed.connect(func(id: int) -> void: evs.append({"t": host.ticks, "k": "removed", "id": id}))
	host.enemy_attack.connect(func(id: int, blow: int, _ax: float, _az: float, windup: float) -> void:
		var info: Dictionary = host.enemy_info(id)
		evs.append({"t": host.ticks, "k": "attack", "id": id, "blow": blow, "wind": windup, "def": String(info.get("def", "")), "at": info.get("pos", Vector2.ZERO), "hero": _hero_at()}))
	host.telegraph.connect(func(_id: int, tell: int, fx: float, fz: float, _ax: float, _az: float, _r: float, _s: float) -> void:
		evs.append({"t": host.ticks, "k": "tele", "kind": String(DmCoreEvents.TELLS[tell]), "at": Vector2(fx, fz)}))
	host.enemy_died.connect(func(id: int, def: String, _lv: int, el: bool, _ar: String, _src: int, x: float, z: float) -> void:
		evs.append({"t": host.ticks, "k": "died", "id": id, "def": def, "elite": el, "at": Vector2(x, z), "hero": _hero_at()}))
	host.affix_moment.connect(func(_id: int, moment: int, ax: float, az: float, _tx: float, _tz: float, _amt: float) -> void:
		evs.append({"t": host.ticks, "k": "moment", "name": String(DmCoreEvents.AFFIX_MOMENTS[moment]), "at": Vector2(ax, az)}))
	host.thrall_raised.connect(func(id: int, _kind: String, _o: int, _sl: int, _em: bool, _ch: bool, x: float, z: float, _yaw: float, _hp: float) -> void:
		evs.append({"t": host.ticks, "k": "t_raised", "id": id, "at": Vector2(x, z)}))
	host.thrall_died.connect(func(id: int, reason: String, _o: int, _kind: String, _src: int, x: float, z: float) -> void:
		evs.append({"t": host.ticks, "k": "t_died", "id": id, "reason": reason, "at": Vector2(x, z)}))
	hero.hurt.connect(func(_amount: float, _source: Variant) -> void:
		evs.append({"t": host.ticks, "k": "hurt", "low": hero.alive and hero.hp < hero.max_hp * 0.3}))


## The hero cannot fall while a fight is read from his stillness; `mortal` gives him his own health back.
func _immortal(on: bool) -> void:
	if on:
		orig_max_hp = float(hero.p["stats"]["maxHp"])
		hero.p["stats"]["maxHp"] = 1.0e9
		hero.p["hp"] = 1.0e9
		hero._mirror_from_state()
	else:
		hero.p["stats"]["maxHp"] = orig_max_hp
		hero.restore_vitals()


func _clear_enemies() -> void:
	for id in core.enemy_ids():
		if host.enemy_alive(id):
			host.remove_enemy(id)


# ------------------------------------------------------------------------------------------------------------------ the scripted fight

func _start_up() -> void:
	check(proxy.applied >= 1, "Settings reached the AudioDirector at the start (apply_settings, %d)" % proxy.applied)
	check(proxy.areas.size() >= 1 and proxy.areas[0] == g.area_id, "the first area the hooks told the director of is the one the hero starts in (%s, %s)" % [g.area_id, str(proxy.areas)])
	var applied := proxy.applied
	g.ui.update_setting({"vol_music": 0.3})
	check(proxy.applied > applied, "a volume slider in Settings reaches the director at once (apply_settings, %d -> %d)" % [applied, proxy.applied])
	check(proxy.listener != Vector2.ZERO and proxy.listener.distance_to(_hero_at()) < 0.5, "the listener follows the hero (%s, he stands at %s)" % [str(proxy.listener), str(_hero_at())])
	check(not g.get_node("AudioHooks").is_wet(hero.position.x, hero.position.z), "the Chapterhouse start is dry (his strides carry no wet flag there)")


func _to_the_graves() -> void:
	hero.teleport(_area_mid("graves"))
	await until(func() -> bool: return g.area_id == "graves", 120)
	check(g.area_id == "graves" and proxy.areas[-1] == "graves", "the hero is in the Hollow Graves and the director was told (%s)" % str(proxy.areas))
	await ticks(30)
	_immortal(true)
	evs.clear()
	proxy.plays.clear()


func _spawn(def: String, off: Vector3, elite := false, rising := false, affixes := PackedStringArray()) -> int:
	return host.spawn_enemy(def, hero.position + off, 1, 1.0, 1.0, elite, "graves", rising, affixes)


## Deaths: a body of each voice family near, a far one (the death cry is heard to 26 m), an elite; each killed once.
func _deaths() -> void:
	var ids: Array = []
	ids.append(_spawn("robber", Vector3(5.0, 0.0, 0.0)))
	ids.append(_spawn("hound", Vector3(-6.0, 0.0, 0.0)))
	ids.append(_spawn("sac", Vector3(0.0, 0.0, 7.0)))
	ids.append(_spawn("moth", Vector3(0.0, 0.0, -8.0)))
	ids.append(_spawn("bat", Vector3(8.0, 0.0, 8.0)))
	ids.append(_spawn("penitent", Vector3(22.0, 0.0, 0.0)))
	ids.append(_spawn("robber", Vector3(0.0, 0.0, 29.0)))
	ids.append(_spawn("robber", Vector3(-9.0, 0.0, -9.0), true))
	await ticks(2)
	for id in ids:
		host.damage(id, 1.0e9, hero.core_id, false)
	await ticks(4)
	_clear_enemies()


## Elites that rise: within the aggro range the aggro sound, past it none; a plain body, an elite that was not rising (a Vengeful's Risen) none.
func _elite_aggro() -> void:
	_spawn("robber", Vector3(10.0, 0.0, 0.0), true, true)
	_spawn("hound", Vector3(-12.0, 0.0, 6.0), true, true)
	_spawn("robber", Vector3(DmEnemyFx.ELITE_AGGRO_RANGE + 1.0, 0.0, 0.0), true, true)   # past the aggro range
	_spawn("robber", Vector3(6.0, 0.0, 6.0), false, true)
	_spawn("robber", Vector3(-6.0, 0.0, 6.0), true, false)
	await ticks(2)
	_clear_enemies()


## A nine-second fight with the hero standing still: every blow's telegraph and swing, the ghoul's dig and eruption, the bell's toll, a meal, a Vengeful's death.
func _the_fight() -> void:
	var ids := {}
	ids["penitent"] = _spawn("penitent", Vector3(0.0, 0.0, -3.5))
	ids["moth"] = _spawn("moth", Vector3(4.0, 0.0, -4.0))
	ids["sac"] = _spawn("sac", Vector3(-4.0, 0.0, -3.0))
	ids["robber"] = _spawn("robber", Vector3(2.5, 0.0, 2.5))
	ids["hound"] = _spawn("hound", Vector3(-3.0, 0.0, 3.0))
	ids["ghoul"] = _spawn("ghoul", Vector3(0.0, 0.0, -7.0))
	ids["bell"] = _spawn("robber", Vector3(6.0, 0.0, 6.0), true, false, PackedStringArray(["bellTolled"]))
	ids["vengeful"] = _spawn("robber", Vector3(-6.0, 0.0, -5.0), true, false, PackedStringArray(["vengeful"]))
	ids["hungry"] = _spawn("hound", Vector3(7.0, 0.0, 0.0), true, false, PackedStringArray(["hungering"]))
	core.corpse_add(Vector2(hero.position.x + 1.5, hero.position.z - 1.0), "normal", "robber", false, 0.0, 1.0, "graves")   # the hungry one eats it, hurt, within 5 m
	await ticks(3)
	host.damage(ids["ghoul"], float(host.enemy_info(ids["ghoul"])["max_hp"]) * 0.6, hero.core_id)   # under half its health it digs in
	host.damage(ids["hungry"], float(host.enemy_info(ids["hungry"])["max_hp"]) * 0.2, hero.core_id)
	for t in 540:
		await physics_frame
		if t == 300 and host.enemy_alive(ids["vengeful"]):
			host.damage(ids["vengeful"], 1.0e9, hero.core_id, false)
	# (an enemy that swings or tolls less often than the nine seconds is no reason to fail: the fight goes on, up to a minute more, until it has shown every cue it is here for)
	var more := 0
	while more < 3600 and not _fight_cues_seen():
		await ticks(60)
		more += 60
	_clear_enemies()
	await ticks(3)


## True when today's rules have a reason for every cue the scripted fight is for.
func _fight_cues_seen() -> bool:
	var lo: Dictionary = _expected()["lo"]
	for n in ["tellStrike", "tollSmall", "boneHit", "burst", "toll", "raise"]:
		if int(lo.get(n, 0)) < 1:
			return false
	return true


## Thralls: four raised through the core, one by an Exhume cast; then killed, crumbled, sacrificed and decayed.
func _thralls() -> void:
	var cap := 20.0
	var stats := {"kind": "warrior", "hp": 40.0, "maxHp": 40.0, "damage": 1.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false, "allyHeal": 0.0}
	var ids: Array = []
	for i in 4:
		ids.append(int(core.raise_thrall(stats, hero.core_id, Vector2(hero.position.x + float(i) * 1.5, hero.position.z + 3.0), 0.0, cap)))
	await ticks(3)
	check(core.kill_thrall(ids[0], "killed") and core.kill_thrall(ids[1], "crumbled") and core.kill_thrall(ids[2], "sacrificed") and core.kill_thrall(ids[3], "decayed"), "four thralls go, one way each")
	await ticks(3)
	var before := proxy.count("exhume")
	var pos := hero.position + Vector3(4.0, 0.0, -1.0)
	core.corpse_add(Vector2(pos.x, pos.z), "normal", "robber", false, 0.0, 1.0, "graves")
	caster.p["castUntil"] = 0.0
	caster.p["cooldowns"].erase("exhume")
	caster.p["resource"]["value"] = 100.0
	caster.request_cast("exhume", pos, -1)
	await ticks(3)
	check(proxy.count("exhume") == before + 1, "the Exhume cast plays its own sound once (exhume)")
	var risen: PackedInt32Array = core.thralls_in_radius(_hero_at(), 60.0, hero.core_id)   # the living (the four that went linger a moment)
	check(risen.size() == 1, "the cast raised one thrall (%d)" % risen.size())
	for id in risen:
		core.kill_thrall(id, "killed")
	await ticks(3)


## The hero hurt: hurt each time, lowHealth once under 30 % of his health.
func _hero_hurt() -> void:
	_immortal(false)
	await ticks(2)
	hero.take_damage(hero.max_hp * 0.2)
	await ticks(2)
	hero.take_damage(hero.max_hp * 0.55)
	await ticks(2)
	hero.restore_vitals()
	await ticks(2)


# ------------------------------------------------------------------------------------------------------------------ today's rules, against what was played

## What today's code plays for the events of the fight: {name: [least, most]}. A swing is certain, impossible or in doubt (within GAP ticks of its landing or of what ended it).
func _expected() -> Dictionary:
	var lo := {}
	var hi := {}
	var add := func(n: String, both := true) -> void:
		hi[n] = int(hi.get(n, 0)) + 1
		if both:
			lo[n] = int(lo.get(n, 0)) + 1
	var swings := {}
	var end: int = host.ticks
	var settle := func(id: int, cancel: int) -> void:
		if not swings.has(id):
			return
		var s: Dictionary = swings[id]
		swings.erase(id)
		var due_lo: float = float(s["t"]) - GAP + 60.0 * float(s["wind"])
		var due_hi: float = float(s["t"]) + GAP + 60.0 * float(s["wind"])
		if due_lo >= cancel or due_lo > end:
			return   # cut short, or not yet landed
		var sure: bool = due_hi < cancel and due_hi <= end
		var fam := DmAudioMap.enemy_voice(String(s["def"]))
		if fam != "" and (s["hero"] as Vector2).distance_to(s["at"]) <= 18.0:
			add.call(DmAudioMap.voice_attack(fam), sure)
		if int(s["blow"]) == SLAM:
			add.call("boneHit", sure)
	for e: Dictionary in evs:
		match e["k"]:
			"spawn":
				if e["elite"] and e["rising"] and (e["hero"] as Vector2).distance_to(e["at"]) < DmEnemyFx.ELITE_AGGRO_RANGE:
					add.call("eliteAggro")
			"tele":
				add.call("tollSmall" if e["kind"] == "cone" or e["kind"] == "toll" else ("raise" if e["kind"] == "raise" else ("curse" if e["kind"] == "curse" else "tellStrike")))
			"attack":
				swings[e["id"]] = e
			"state":
				settle.call(e["id"], e["t"])
				if int(e["next"]) == EMERGE:
					add.call("burst")
			"removed":
				settle.call(e["id"], e["t"])
			"died":
				settle.call(e["id"], e["t"])
				add.call("eliteDeath" if e["elite"] else "enemyDeath")
				var fam := DmAudioMap.enemy_voice(String(e["def"]))
				if fam != "" and (e["hero"] as Vector2).distance_to(e["at"]) <= 26.0:
					add.call(DmAudioMap.voice_death(fam))
			"moment":
				match String(e["name"]):
					"toll":
						add.call("toll")
					"hungering":
						add.call("raise")
					"vengeful":
						add.call("burst")
			"t_raised":
				add.call("thrallRise")
			"t_died":
				if e["reason"] == "killed":
					add.call("thrallDeath")
			"hurt":
				add.call("hurt")
				if e["low"]:
					add.call("lowHealth")
	for id in swings.keys():
		settle.call(id, 1 << 40)
	return {"lo": lo, "hi": hi}


func _the_fight_against_today() -> void:
	var want := _expected()
	var lo: Dictionary = want["lo"]
	var hi: Dictionary = want["hi"]
	var got := {}
	for p in proxy.plays:
		if OWN.has(p[0]):
			got[p[0]] = int(got.get(p[0], 0)) + 1
	var names := {}
	for n in lo:
		names[n] = true
	for n in hi:
		names[n] = true
	for n in got:
		names[n] = true
	for n: String in names:
		var g_n := int(got.get(n, 0))
		check(g_n >= int(lo.get(n, 0)) and g_n <= int(hi.get(n, 0)), "%s: played %d, today's code plays %d%s" % [n, g_n, int(lo.get(n, 0)), "" if int(hi.get(n, 0)) == int(lo.get(n, 0)) else " to %d" % int(hi.get(n, 0))])
	# the fight really had everything in it (a fight that never swung would match an empty expectation)
	for n in ["eliteAggro", "tellStrike", "tollSmall", "boneHit", "burst", "toll", "raise", "enemyDeath", "eliteDeath", "thrallRise", "thrallDeath", "hurt", "lowHealth"]:
		check(int(lo.get(n, 0)) >= 1, "the fight gave today's code a reason for %s (%d)" % [n, int(lo.get(n, 0))])
	check(int(lo.get("enemyAttackHumanoid", 0)) + int(lo.get("enemyAttackBeast", 0)) + int(lo.get("enemyAttackBrute", 0)) >= 3, "swings landed and were heard: attack voices")
	check(int(lo.get("enemyDeathHumanoid", 0)) + int(lo.get("enemyDeathBeast", 0)) + int(lo.get("enemyDeathBrute", 0)) + int(lo.get("enemyDeathSpirit", 0)) >= 4, "deaths were heard: death cries")
	# the places: a thrall rises where it stands, a death is heard where it fell
	for e: Dictionary in evs:
		if e["k"] == "t_raised":
			var found := false
			for p in proxy.plays:
				if p[0] == "thrallRise" and Vector2(p[1], p[2]).distance_to(e["at"]) < 0.01:
					found = true
			check(found, "thrall %d: thrallRise at its place %s" % [e["id"], str(e["at"])])
		if e["k"] == "t_died" and e["reason"] == "killed":
			var found2 := false
			for p in proxy.plays:
				if p[0] == "thrallDeath" and Vector2(p[1], p[2]).distance_to(e["at"]) < 0.01:
					found2 = true
			check(found2, "thrall %d: thrallDeath at its place %s" % [e["id"], str(e["at"])])
	var tr := evs.filter(func(e: Dictionary) -> bool: return e["k"] == "t_died")
	var reasons: Array = tr.map(func(e: Dictionary) -> String: return e["reason"])
	check(reasons.has("killed") and reasons.has("crumbled") and reasons.has("sacrificed") and reasons.has("decayed"), "all four ways a thrall can go were seen (%s)" % str(reasons))
	check(proxy.count("thrallDeath") == reasons.count("killed"), "thrallDeath only for the killed (%d of %d)" % [proxy.count("thrallDeath"), reasons.count("killed")])


# ------------------------------------------------------------------------------------------------------------------ the hero's world

func _the_hero_world() -> void:
	_clear_enemies()
	await ticks(3)
	proxy.real = real   # from here the real director hears everything too, and starts where the game stands
	real.set_area(g.area_id)
	real.set_listener(hero.position.x, hero.position.z)
	proxy.plays.clear()
	proxy.areas.clear()
	stepped.clear()
	# footsteps: he walks; the director gets the stride and the area
	var from := hero.position
	hero.set_move_target(from + Vector3(8.0, 0.0, 0.0))
	await until(func() -> bool: return stepped.any(func(n: String) -> bool: return n.begins_with("step")), 900)
	check(proxy.foot.size() > 0 and String(proxy.foot[-1][3]) == "graves", "the hero's strides reach the director with the area he walks in (%d, %s)" % [proxy.foot.size(), str(proxy.foot[-1][3]) if not proxy.foot.is_empty() else "-"])
	check(stepped.any(func(n: String) -> bool: return n.begins_with("step")), "footsteps sound while he walks (%s)" % str(stepped.slice(0, 4)))
	await until(func() -> bool: return proxy.stopped > 0, 120)
	check(proxy.stopped > 0, "and the director hears when he stops")
	# ambience and music: the bed and the score follow the area
	var visited: Array = []
	for id: String in ["ossuary", "pyre", "chapterhouse", "graves"]:
		hero.teleport(_area_mid(id))
		var ok := await until(func() -> bool: return g.area_id == id, 120)
		check(ok and proxy.areas.has(id) and proxy.current_area() == id, "%s: the director is told of the area (%s)" % [id, str(proxy.areas)])
		var cue := DmMusicState.cue_for(id)
		var started := await until(func() -> bool: return proxy.music_cue() == cue, 1500)
		check(started, "%s: the score is %s (%s)" % [id, cue, proxy.music_cue()])
		visited.append(id)
	check(proxy.areas == visited, "the director heard each area once, in the order walked (%s)" % str(proxy.areas))
	await _gates()
	await _the_boss_score()


func _area_mid(id: String) -> Vector3:
	var r: Dictionary = DmContent.area(id)["rect"]
	return Vector3((float(r["x0"]) + float(r["x1"])) * 0.5, 0.0, (float(r["z0"]) + float(r["z1"])) * 0.5)


## A seal breaks: the gate sound at the door's centre, once for each opening, none for a door already open or one that closes.
func _gates() -> void:
	var door := ""
	for id: String in g.world.gates:
		if not bool(g.world.gates[id].open):
			door = id
			break
	check(door != "", "a sealed door exists to open")
	if door == "":
		return
	var centre := Vector2.ZERO
	for d: Dictionary in DmData.world()["doors"]:
		if String(d["id"]) == door:
			centre = Vector2(float(d["cx"]), float(d["cz"]))
	proxy.plays.clear()
	g.world.set_door_open(door, true)
	await ticks(3)
	var gates := proxy.plays.filter(func(p: Array) -> bool: return p[0] == "gate")
	check(gates.size() == 1 and Vector2(gates[0][1], gates[0][2]).distance_to(centre) < 0.01, "%s opens: one gate sound at the door's centre %s (%s)" % [door, str(centre), str(proxy.names())])
	g.world.set_door_open(door, true)
	g.world.set_door_open(door, false, true)
	await ticks(3)
	check(proxy.count("gate") == 1, "an open door opened again and a door closing are silent")
	g.world.set_door_open(door, true, true)
	await ticks(3)
	check(proxy.count("gate") == 2, "it rises again: the sound again (%d)" % proxy.count("gate"))
	# a door that rises while the world loads, before the hooks' first full frame, is silent
	var old := DmAudioHooks.inst
	var fake := FakeMain.new()
	var stub := Proxy.new()
	var hooks := DmAudioHooks.new()
	fake.player = hero
	g.add_child(fake)
	fake.add_child(hooks)
	hooks.setup(fake, stub)
	fake.world.door_opened.emit(door)
	check(stub.count("gate") == 0, "a door that rises before the hooks' first frame is silent")
	hooks._process(0.016)
	fake.world.door_opened.emit(door)
	fake.world.door_opened.emit("no_such_door")
	check(stub.count("gate") == 1 and stub.listener.distance_to(_hero_at()) < 0.01, "and after it the same door is heard (one gate sound; an unknown door is not)")
	DmAudioHooks.inst = old
	fake.queue_free()
	stub.free()
	await process_frame


## The King wakes: the boss score on; he falls out of the world: the area's score again.
func _the_boss_score() -> void:
	hero.teleport(g.bosses.site_pos("gravedigger") + Vector3(0.0, 0.0, 2.0))
	await until(func() -> bool: return g.area_id == "graves", 120)
	g.my_member().prog.add_shards(int(DmContent.boss("gravedigger")["shards"]) * 2)
	_immortal(true)
	proxy.bosses.clear()
	proxy.plays.clear()
	var why := g.bosses.try_summon(g.session.get_my_id(), "gravedigger")
	check(why == "", "the King wakes (%s)" % why)
	var boss := g.bosses.active_boss()
	await until(func() -> bool: return proxy.bosses.has(true), 200)
	check(proxy.bosses.has(true) and proxy.count("bossAwaken") == 1, "the boss score starts when he wakes, and bossAwaken is heard once (%s, %d)" % [str(proxy.bosses), proxy.count("bossAwaken")])
	check(await until(func() -> bool: return proxy.music_cue() == "boss", 1500), "the director's score is the boss cue (%s)" % proxy.music_cue())
	if boss != null:
		boss.queue_free()
	await until(func() -> bool: return proxy.bosses.size() > 0 and proxy.bosses[-1] == false, 200)
	check(proxy.bosses.size() > 0 and proxy.bosses[-1] == false, "the boss score ends with him (%s)" % str(proxy.bosses))
	check(await until(func() -> bool: return proxy.music_cue() == "graves", 1500), "and the Graves' score returns (%s)" % proxy.music_cue())
