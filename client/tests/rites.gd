extends SceneTree
## The Gravecaller's rites on the combat core (client/next/rites/CORE-INTEGRATION.md): the real offline game scene (client/next/next_game.tscn)
## with a level-20 Gravecaller, no waves, headless. Every rite (the necromancer's and the Reaper's) is cast at least once against core enemies (static: stunned, harmless, a huge health pool unless a case
## needs a kill) and its effect is compared with today's rules, computed here with the copied rules code (DmAbilities, DmThralls, DmSimData, DmCombatData ...), never literals:
##   - damage numbers (the first blow on each target = the rite's formula x the target's damage-taken multiplier, here 1), who was hit and who was not (lane, cone, circle, edge distance);
##   - statuses with today's stacks and durations (the core's status wire: tenths of a second), DoT credit;
##   - corpses consumed (atomically) or kept, thralls raised with `DmThralls.raise_stats` / `colossus_stats`, rallied, sacrificed, moved, mended;
##   - cooldown, essence cost and cast lock of every accepted cast (`DmAbilities.apply_cast_cost`), and the refusals (range, no corpse, no thralls, no souls, a rite with no module);
##   - the synchronous-kill cases: Wailing Skull's extra leap on a kill (four hits against three), Bone Prison skipping the dead;
##   - the input: the kit's hotbar (LMB, 1-4, RMB, R), the click-to-attack chase;
##   - a short full fight where the hero clears a wave of sixteen with rites, with thralls raised, rallied and sacrificed on the way;
##   - the other three necromancers and the Reaper, each a real character in a fresh game (t_disciplines, t_reaper);
##   - ZERO script errors or engine errors in the log (an OS Logger counts them; warnings are not errors).
## Gets the robber, the hound and the Gravecaller's legionnaire into a scratch folder first (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd). Run: godot --headless --path client --script res://tests/rites.gd
## It plays about 90 s of game time: it takes that long in real time, and about 30 s with the engine argument `--fixed-fps 60` before `--path`.

const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://rites_test"
const BAKE := ["grave_robber", "bone_hound", "thrall_legionnaire"]
const BIG := 1000.0   ## health multiplier of a target that must survive the case
const WITHERED := &"withered"
const REAPER := 11


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var api_: DmApi   ## the mock's api: the disciplines' heroes are more characters of the same account
var mock_: DmMockBackend
var host: DmCoreHost
var core: RefCounted
var hero: DmHeroBody
var c: DmRiteCaster
var field: DmCoreCorpses
var origin := Vector3.ZERO
var dirv := Vector3(1, 0, 0)       ## the way the arena runs (clear ground of at least 16 m)
var side := Vector3(0, 0, 1)
var base_mods: Dictionary = {}
var rejected := ""
var dmg_log: Array = []            ## [id, source, amount, hp] from the core's enemy_damaged events
var hit_log: Array = []            ## [rite, enemy id, amount, crit, killed] from the caster's hit_resolved
var ev_log: Array = []             ## every rite event the caster played
var status_log: Array = []        ## ids of status_changed events
var cast_rites := {}               ## rite -> accepted casts
var t0_msec := 0


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL rites: " + what)


func near(a: float, b: float, tol := 1e-6) -> bool:
	return absf(a - b) <= tol * maxf(1.0, maxf(absf(a), absf(b)))


## Absolute closeness (essence over a few ticks of regeneration).
func close(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func secs(s: float) -> void:
	await ticks(int(round(s * 60.0)))


func _initialize() -> void:
	await process_frame
	OS.add_logger(errlog)
	t0_msec = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	api_ = api
	mock_ = mock
	var reg := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	DmDevMock.set_level(mock, ch.data, 20)
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api, {"areas": ["graves"], "offline": true, "name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "baked_dir": OUT})
	host = g.core_host
	core = host.core
	hero = g.local_body()
	c = hero.get_node("Rites") as DmRiteCaster
	field = host.corpses
	check(g.ready_ and hero != null and c != null, "the game scene is up and the hero has his caster (Rites)")
	check(hero.get_node_or_null("Thralls") == null, "there is no Thralls node: the legion is the core's")
	origin = hero.position
	base_mods = c.mods.duplicate(true)
	c.random = func() -> float: return 0.5   # no crit, the middle of the needle's jitter
	_wire()
	find_arena()
	await the_catalogue()
	await t_input()
	await t_bone_needle()
	await t_bone_fan()
	await t_rot_lance()
	await t_marrow_spear()
	await t_exhume()
	await t_miasma()
	await t_black_litany()
	await t_corpse_explosion()
	await t_grave_offering()
	await t_bone_mantle()
	await t_carrion_seed()
	await t_wailing_skull()
	await t_ivory_cleave()
	await t_bone_storm()
	await t_soul_siphon()
	await t_grave_step()
	await t_veil_step()
	await t_grave_frost()
	await t_bone_prison()
	await t_grave_hands()
	await t_rally_dead()
	await t_ossuary_wall()
	await t_command_rend()
	await t_dirge()
	await t_plague_bloom()
	await t_legends()
	await t_dot_credit()
	await t_chase()
	await t_fight()
	await t_disciplines()
	await t_reaper()
	await finish()


func _wire() -> void:
	host.enemy_damaged.connect(func(id: int, source: int, amount: float, hp: float) -> void: dmg_log.append([id, source, amount, hp]))
	host.status_changed.connect(func(id: int) -> void: status_log.append(id))
	g.rite_hit.connect(func(rite: String, id: int, amount: float, crit: bool, killed: bool) -> void: hit_log.append([rite, id, amount, crit, killed]))
	c.cast_rejected.connect(func(_rite: String, why: String) -> void: rejected = why)
	c.event_played.connect(func(ev: Dictionary) -> void: ev_log.append(ev))


## The first direction from the hero along which the ground (the navigation mesh, flat distance) is clear for 16 m, and 3 m to either side.
func find_arena() -> void:
	var map: RID = g.world.nav_map()
	var best := -1.0
	for a in range(0, 360, 15):
		var d := Vector3(cos(deg_to_rad(a)), 0.0, sin(deg_to_rad(a)))
		var s := Vector3(-d.z, 0.0, d.x)
		var run := 0.0
		for k in range(1, 19):
			var ok := true
			for off in [-3.0, 0.0, 3.0]:
				var q: Vector3 = origin + d * float(k) + s * off
				var cp := NavigationServer3D.map_get_closest_point(map, q)
				if Vector2(cp.x - q.x, cp.z - q.z).length() > 0.3:
					ok = false
			if not ok:
				break
			run = float(k)
		if run > best:
			best = run
			dirv = d
			side = s
		if run >= 18.0:
			break
	check(best >= 16.0, "the arena: ground clear for %.0f m along (%.2f, %.2f)" % [best, dirv.x, dirv.z])


## A point `along` metres from the hero along the arena and `across` to the side.
func at(along: float, across := 0.0) -> Vector3:
	return origin + dirv * along + side * across


# ------------------------------------------------------------------------------------------------------------------------ the arena

## Puts everything back: the enemies dead and their corpses gone, the legion crumbled, the rites' timers and state cleared, the hero at his place with full health and essence and
## no cooldown, the runes and the weapon line bare, the build's mods as they were.
func reset() -> void:
	c._pending.clear()
	c._mem.clear()
	if c._legends != null:
		c._legends.wisps.clear()
	for id in core.enemy_ids():
		core.damage(id, 1.0e12, 0)
	for id in core.corpse_ids():
		core.corpse_consume(id, 0, "consumed")
	for id in core.thrall_ids():
		core.kill_thrall(id, "crumbled")
	hero.teleport(origin)
	hero.stop()
	c._set_mods(base_mods)
	var p := c.p
	p["hp"] = float(p["stats"]["maxHp"])
	p["resource"]["value"] = float(p["resource"]["max"])
	p["cooldowns"] = {}
	p["castUntil"] = 0.0
	p["rootedUntil"] = 0.0
	p["barrier"] = 0.0
	p["barrierPeak"] = 0.0
	p["runes"] = {}
	p["loadout"] = DmWeaponLine.no_loadout()
	for e in c.get_children():
		if String(e.name).begins_with("Ribs"):
			e.queue_free()
	dmg_log.clear()
	hit_log.clear()
	ev_log.clear()
	status_log.clear()
	rejected = ""


## A static enemy: stunned for an hour (it stands where it is), harmless, with health for the case.
func foe(def: String, pos: Vector3, hp_mult := BIG, elite := false) -> int:
	var id := host.spawn_enemy(def, pos, 1, hp_mult, 0.0, elite, "graves", false)
	core.stun(id, 3600.0)
	return id


func corpse(pos: Vector3, kind := "normal", enemy := "robber", elite := false) -> int:
	return field.add_corpse(pos.x, pos.z, kind, enemy, elite, 0.0, 1.0, "graves")


func hp_of(id: int) -> float:
	var i: Dictionary = core.enemy_info(id)
	return float(i["hp"]) if not i.is_empty() else -1.0


func pos_of(id: int) -> Vector3:
	return host.enemy_position(id)


## The first blow the core dealt enemy `id` since `mark` (an index into dmg_log): its amount, or -1.
func first_blow(id: int, mark := 0) -> float:
	for i in range(mark, dmg_log.size()):
		if int(dmg_log[i][0]) == id:
			return float(dmg_log[i][2])
	return -1.0


func blows(id: int, mark := 0) -> int:
	var n := 0
	for i in range(mark, dmg_log.size()):
		if int(dmg_log[i][0]) == id:
			n += 1
	return n


func hits_of(rite: String, mark := 0) -> Array:
	var out: Array = []
	for i in range(mark, hit_log.size()):
		if String(hit_log[i][0]) == rite:
			out.append(hit_log[i])
	return out


## A status of a body from the core's wire (4 bytes each: wire id, stacks, tenths of a second left): {stacks, left} in seconds, or {} when it has none.
func status_of(id: int, name: StringName) -> Dictionary:
	var b: PackedByteArray = core.statuses(id)
	var want := DmStatusSet.IDS.find(name)
	for i in range(0, b.size(), 4):
		if int(b[i]) == want:
			return {"stacks": int(b[i + 1]), "left": float(int(b[i + 2]) | (int(b[i + 3]) << 8)) / 10.0}
	return {}


func stacks_of(id: int, name: StringName) -> int:
	var s := status_of(id, name)
	return int(s["stacks"]) if not s.is_empty() else 0


## Essence regenerated since `frame` (the necromancer's passive, a rate a second).
func regen_since(r: Dictionary) -> float:
	return DmResources.passive("necromancer", {"stats": c.p["stats"], "value": 0.0, "max": c.p["resource"]["max"], "sinceHurtMs": 1e9, "sinceResourceGainMs": 1e9}) * float(Engine.get_physics_frames() - int(r["frame"])) / 60.0


func sp_now() -> float:
	return DmAbilities.sp(c.p, c.now_ms)


## Casts `rite` (as the owner does) and checks what every accepted cast pays as today: the essence cost, the cooldown and the cast lock. Returns {ok, reason, now, e0}.
func cast(rite: String, aim: Vector3, target := -1, cd_mult := 1.0) -> Dictionary:
	c.p["castUntil"] = 0.0
	c.p["cooldowns"].erase(rite)
	rejected = ""
	var e0 := c.essence()
	c.request_cast(rite, aim, target)
	var r := {"ok": rejected == "", "reason": rejected, "now": c.now_ms, "e0": e0, "frame": Engine.get_physics_frames()}
	if r["ok"]:
		cast_rites[rite] = int(cast_rites.get(rite, 0)) + 1
		var d := DmAbilities.def(rite)
		var lo: Dictionary = c.p["loadout"]
		check(near(e0 - c.essence(), float(d["essenceCost"]), 1e-6), "%s: paid %.1f essence (the cost %.1f)" % [rite, e0 - c.essence(), float(d["essenceCost"])])
		check(near(c.cooldown_left(rite), DmWeaponLine.ability_cooldown_ms(rite, float(d["cooldownMs"]), lo, DmAbilities.is_primary(rite)) * cd_mult, 1e-6), "%s: the cooldown runs (%.0f ms of %.0f)" % [rite, c.cooldown_left(rite), float(d["cooldownMs"])])
		check(near(float(c.p["castUntil"]) - c.now_ms, DmWeaponLine.ability_lock_ms(rite, float(DmAbilities.cast_flow(rite)["lockMs"]), lo), 1e-6), "%s: the cast lock is %.0f ms" % [rite, float(c.p["castUntil"]) - c.now_ms])
	return r


func accepted(r: Dictionary, what: String) -> bool:
	check(bool(r["ok"]), "%s: the cast is accepted (refused: %s)" % [what, r["reason"]])
	return bool(r["ok"])


func legion() -> DmCoreLegion:
	return c.thralls()


## Raises a thrall of the Gravecaller's kind at `pos` the way an exhume does (a corpse is laid, the legion raises from it): its id.
func raise_at(pos: Vector3, kind := "normal", enemy := "robber", elite := false) -> int:
	var cp := corpse(pos, kind, enemy, elite)
	var ex := {"kind": c.mods["thrallKind"], "cap": c.mods["thrallCap"], "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"], "attackSpeedMult": c.mods["thrallAttackSpeedMult"], "r": 0.8}
	var r: Dictionary = legion().raise(ex, pos)
	check(bool(r["ok"]) and (r["thralls"] as Array).size() == 1 and field.get_corpse(cp) == null, "a thrall rises from the corpse at %s" % str(pos))
	return int((r["thralls"] as Array)[0]) if bool(r["ok"]) else 0


# ------------------------------------------------------------------------------------------------------------------------ the catalogue

func the_catalogue() -> void:
	var ids := DmRiteRegistry.ids()
	# The rites of every playable class's kit, read from the data (hotbar, grimoire, primaries, RMB, signatures), never a typed count:
	# a new spell or a newly playable class needs no edit here.
	var families := {}
	for d in (DmCombatData.disciplines()["disciplines"] as Dictionary).values():
		if DmCharacterBuild.is_playable(float(d["classIndex"])):
			families[String(d["family"])] = true
	var want := {}
	for fam in families:
		var kit: Dictionary = DmContent.kit(String(fam))
		for key in ["hotbar", "grimoire", "primaries"]:
			for r in kit.get(key, []):
				want[String(r)] = fam
		if kit.has("rmb"):
			want[String(kit["rmb"])] = fam
		for r in (kit.get("signatures", {}) as Dictionary).values():
			want[String(r)] = fam
	check(not want.is_empty() and ids.size() == want.size(), "the registry holds exactly the playable kits' %d rites (%d registered)" % [want.size(), ids.size()])
	for rite in want:
		check(DmRiteRegistry.has(rite), "the %s kit's %s is registered" % [want[rite], rite])
	for rite in ids:
		check(want.has(String(rite)), "the registered %s is in a playable class's kit" % rite)
	for rite in ids:
		check(DmRiteRegistry.module(rite) != null and DmRiteRegistry.module(rite).id == rite, "%s has its module" % rite)
	check(DmRiteCaster.WITHERED_WIRE == DmStatusSet.IDS.find(&"withered"), "the caster reads Withered by its wire id")
	await reset_and_wait()
	var later := ""   # a rite only a kit that is not playable yet has (read from the data: a class that becomes playable needs no edit)
	for d in (DmCombatData.disciplines()["disciplines"] as Dictionary).values():
		if later == "" and not DmCharacterBuild.is_playable(float(d["classIndex"])) and not families.has(String(d["family"])):
			for r0 in DmContent.kit(String(d["family"])).get("hotbar", []):
				if later == "" and not want.has(String(r0)) and DmAbilities.defs().has(String(r0)):
					later = String(r0)
	if later == "":
		print("INFO every kit is playable: no rite of a later class to refuse")
	else:
		var r := cast(later, at(2.0))
		check(not r["ok"] and r["reason"] == "unavailable", "a rite of a kit that comes later (%s) is refused `unavailable` (%s)" % [later, r["reason"]])
	check(c.hero_id == hero.core_id and c.hero_id > 0, "the caster's hero id is the body's id in the core (%d)" % c.hero_id)
	check(c.p["stats"]["level"] == 20.0 and String(c.body.get("discipline_id")) == "gravecaller", "the hero is a level-20 Gravecaller")


func reset_and_wait() -> void:
	reset()
	await ticks(2)


# ------------------------------------------------------------------------------------------------------------------------ the input

## The kit's hotbar (LMB the primary, 1-4 the default loadout, RMB, R) and the click-to-attack path through today's DmNextInput / DmRiteHotbar.
func t_input() -> void:
	await reset_and_wait()
	var want := ["bone_needle", "marrow_spear", "exhume", "miasma", "black_litany", "corpse_explosion", "command_rend"]
	var slots := [0, 1, 2, 3, 4, 5, 6]
	for i in slots.size():
		check(g.rite_for_slot(slots[i]) == want[i], "slot %d is %s (%s)" % [slots[i], want[i], g.rite_for_slot(slots[i])])
	# keys go through the input's hotbar signal to the caster: key 1 at the cursor casts Marrow Spear
	g.input.cast_at(1, at(8.0), 0, true)
	check(rejected == "" and float(c.cooldown_left("marrow_spear")) > 0.0, "key 1 casts Marrow Spear through DmNextInput and DmRiteHotbar")
	await ticks(20)   # past the cast lock
	g.input.cast_at(5, at(8.0), 0, true)
	check(rejected == "no_corpse", "RMB asks for a corpse to explode (%s)" % rejected)
	await reset_and_wait()
	var e := foe("robber", at(6.0))
	g.input.cast_at(0, pos_of(e), e, true)
	await secs(0.5)
	check(float(c.cooldown_left("bone_needle")) >= 0.0 and hp_of(e) < float(core.enemy_info(e)["max_hp"]), "LMB on an enemy casts the primary at it")


# ------------------------------------------------------------------------------------------------------------------------ primaries

func t_bone_needle() -> void:
	await reset_and_wait()
	var e := foe("robber", at(6.0))
	c.p["resource"]["value"] = 50.0
	var sp := sp_now()
	var nc := DmAbilities.needle_cast(sp, c.p["loadout"], "", 0, 0.5)
	var hit := DmAbilities.needle_hit(nc["dmg"], 0.5)
	var m := dmg_log.size()
	var r := cast("bone_needle", at(6.0), e)
	if not accepted(r, "bone_needle"):
		return
	check(hp_of(e) == float(core.enemy_info(e)["max_hp"]), "the needle is still in flight: no damage at the cast")
	await secs(0.6)
	check(near(first_blow(e, m), float(hit["amount"])), "bone_needle: %.3f dealt (the formula %.3f)" % [first_blow(e, m), float(hit["amount"])])
	var h := hits_of("bone_needle")
	check(h.size() == 1 and not bool(h[0][3]) and not bool(h[0][4]), "bone_needle: one hit credited, not a crit, not a kill")
	check(close(c.essence(), 50.0 + float(nc["essence"]) + regen_since(r), 0.4), "bone_needle: +%.0f essence on the hit (%.2f)" % [float(nc["essence"]), c.essence() - 50.0])
	# out of reach: refused, nothing paid
	await reset_and_wait()
	var far := foe("robber", at(14.0))
	var e0 := c.essence()
	r = cast("bone_needle", at(14.0), far)
	check(not r["ok"] and r["reason"] == "range" and near(c.essence(), e0, 1e-9) and c.cooldown_left("bone_needle") == 0.0, "bone_needle at 14 m is refused `range` and costs nothing (%s)" % r["reason"])
	# a kill is known at once: a robber with a sliver of health dies to the needle, its corpse lies, the hit says killed
	await reset_and_wait()
	var weak := foe("robber", at(5.0), 0.001)
	r = cast("bone_needle", at(5.0), weak)
	await secs(0.5)
	var hk := hits_of("bone_needle")
	check(hk.size() == 1 and bool(hk[0][4]) and not host.enemy_alive(weak), "a needle that kills says so: killed, the body is dead")
	check(field.corpses_in_radius(at(5.0), 1.0).size() == 1, "and its corpse lies where it fell")
	# the weapon line: a Sickle's needle adds a Withered stack
	await reset_and_wait()
	var e2 := foe("robber", at(6.0))
	c.p["loadout"]["needleWithered"] = 1.0
	r = cast("bone_needle", at(6.0), e2)
	await secs(0.6)
	var w := status_of(e2, WITHERED)
	check(w.get("stacks", 0) == 1 and absf(float(w["left"]) - float(DmSimData.WITHERED["durationMs"]) / 1000.0) <= 0.3, "a Sickle's needle adds one Withered stack for %.1f s (%s)" % [float(DmSimData.WITHERED["durationMs"]) / 1000.0, str(w)])
	# the staff: the needle carries on through the enemy behind its target
	await reset_and_wait()
	var f1 := foe("robber", at(5.0))
	var f2 := foe("robber", at(8.0, 0.2))
	var lo: Dictionary = c.p["loadout"]
	lo["needlePierce"] = 1.0
	var m3 := dmg_log.size()
	r = cast("bone_needle", at(5.0), f1)
	await secs(0.7)
	var nc3 := DmAbilities.needle_cast(sp_now(), lo, "", 0, 0.5)
	check(blows(f2, m3) == 1 and near(first_blow(f2, m3), nc3["dmg"] * float(DmSimData.NECRO_WEAPON_TUNING["staff"]["pierceDamageMult"])), "a Staff's needle pierces on to the next enemy for the pierce fraction (%.3f)" % first_blow(f2, m3))
	# the Splinters rune: a shard to the nearest other enemy for its fraction
	await reset_and_wait()
	var s1 := foe("robber", at(5.0))
	var s2 := foe("robber", at(7.0, 1.0))
	var s3 := foe("robber", at(12.0, 6.0))
	c.p["runes"] = {"bone_needle": "rune_splinter"}
	var m4 := dmg_log.size()
	r = cast("bone_needle", at(5.0), s1)
	await secs(0.7)
	var nc4 := DmAbilities.needle_cast(sp_now(), c.p["loadout"], "rune_splinter", 0, 0.5)
	check(near(first_blow(s2, m4), DmAbilities.splinter_damage(nc4["dmg"])) and blows(s3, m4) == 0, "Splinters: a shard of %.3f flies to the nearest other enemy, not to the far one" % first_blow(s2, m4))
	# the Volley rune: every 4th needle is three, at the target and the enemies nearest it
	await reset_and_wait()
	var v: Array[int] = [foe("robber", at(5.0)), foe("robber", at(6.0, 1.5)), foe("robber", at(6.0, -1.5))]
	c.p["runes"] = {"bone_needle": "rune_volley"}
	for k in 3:
		cast("bone_needle", at(5.0), v[0])
		await ticks(30)
	var m5 := dmg_log.size()
	var h5 := hit_log.size()
	r = cast("bone_needle", at(5.0), v[0])
	var nc5 := DmAbilities.needle_cast(sp_now(), c.p["loadout"], "rune_volley", 4, 0.5)
	await secs(0.8)
	var volley_hits := hit_log.slice(h5).filter(func(x: Array) -> bool: return x[0] == "bone_needle")
	check(bool(nc5["volley"]) and volley_hits.size() == 3 and near(float(volley_hits[0][2]), float(nc5["dmg"])), "Volley: the 4th needle is %d, each %.3f" % [volley_hits.size(), float(nc5["dmg"])])
	var distinct := {}
	for x in volley_hits:
		distinct[x[1]] = true
	check(distinct.size() == 3 and m5 >= 0, "Volley: at three different enemies")
	# the Scythe: no needle, an arc that cuts everything in front of him at once
	await reset_and_wait()
	var a1 := foe("robber", at(2.0, 0.4))
	var a2 := foe("robber", at(2.2, -0.6))
	var behind := foe("robber", at(-2.0))
	c.p["loadout"]["reap"] = true
	var m6 := dmg_log.size()
	r = cast("bone_needle", at(2.0), a1)
	var rc := DmAbilities.reap_cast(sp_now(), "", 0.5, 2)
	await ticks(2)
	check(near(first_blow(a1, m6), float(rc["dmg"])) and near(first_blow(a2, m6), float(rc["dmg"])) and blows(behind, m6) == 0, "Scythe: the arc cut both enemies in front for %.3f, not the one behind him" % first_blow(a1, m6))


func t_bone_fan() -> void:
	await reset_and_wait()
	var t := foe("robber", at(6.0))
	var a := foe("robber", at(6.5, 0.8))      # 7 degrees off the line
	var b := foe("robber", at(7.0, -1.2))     # 9.7 degrees
	var d := foe("robber", at(6.0, 4.0))      # 34 degrees: outside the 15 degree half-cone
	c.p["resource"]["value"] = 50.0
	var dmg := DmAbilities.rite_damage(sp_now(), "bone_fan")
	var m := dmg_log.size()
	var r := cast("bone_fan", at(6.0), t)
	if not accepted(r, "bone_fan"):
		return
	await secs(0.7)
	for id in [t, a, b]:
		check(near(first_blow(id, m), dmg), "bone_fan: the sliver on enemy %d dealt %.3f (%.3f)" % [id, first_blow(id, m), dmg])
	check(blows(d, m) == 0, "bone_fan: the enemy outside the half-cone is not struck")
	var BF: Dictionary = DmCombatData.const_table("BONE_FAN")
	check(close(c.essence(), 50.0 + float(BF["essenceCap"]) + regen_since(r), 0.4), "bone_fan: three hits give the cap of %.0f essence (%.2f)" % [float(BF["essenceCap"]), c.essence() - 50.0])


func t_rot_lance() -> void:
	await reset_and_wait()
	var e1 := foe("robber", at(5.0))
	var e2 := foe("robber", at(8.0))
	var e3 := foe("robber", at(11.0))
	var off := foe("robber", at(8.0, 2.0))
	c.p["resource"]["value"] = 50.0
	var dmg := DmAbilities.rite_damage(sp_now(), "rot_lance")
	var m := dmg_log.size()
	var r := cast("rot_lance", at(5.0), e1)
	if not accepted(r, "rot_lance"):
		return
	await secs(0.8)
	var RL: Dictionary = DmCombatData.const_table("ROT_LANCE")
	for id in [e1, e2]:
		check(near(first_blow(id, m), dmg), "rot_lance: the lance dealt %.3f to the enemy in the lane (%.3f)" % [first_blow(id, m), dmg])
		var w := status_of(id, WITHERED)
		check(w.get("stacks", 0) == int(RL["withered"]) and absf(float(w["left"]) - float(DmSimData.WITHERED["durationMs"]) / 1000.0) <= 0.4, "rot_lance: %d Withered stack for %.1f s (%s)" % [int(RL["withered"]), float(DmSimData.WITHERED["durationMs"]) / 1000.0, str(w)])
	check(blows(e3, m) == 0 and blows(off, m) == 0, "rot_lance: only the first %d in the lane are pierced, not the third nor the one beside it" % int(RL["pierce"]))
	check(close(c.essence(), 50.0 + float(RL["essence"]) + regen_since(r), 0.4), "rot_lance: +%.0f essence once (%.2f)" % [float(RL["essence"]), c.essence() - 50.0])


# ------------------------------------------------------------------------------------------------------------------------ the grimoire

func t_marrow_spear() -> void:
	await reset_and_wait()
	var inl: Array[int] = [foe("robber", at(4.0)), foe("robber", at(7.0, 0.3)), foe("robber", at(10.0, -0.3))]
	var off := foe("robber", at(7.0, 3.0))
	var sp := DmAbilities.spear(sp_now(), "", 1.0)
	var H: Dictionary = DmSimData.HEMORRHAGE
	var m := dmg_log.size()
	var r := cast("marrow_spear", at(12.0))
	if not accepted(r, "marrow_spear"):
		return
	await secs(0.5)
	for id in inl:
		check(near(first_blow(id, m), float(sp["dmg"])), "marrow_spear: the line dealt %.3f (%.3f)" % [first_blow(id, m), float(sp["dmg"])])
		check(stacks_of(id, &"fracture") == 1 and stacks_of(id, &"bleed") == 1, "marrow_spear: +1 Fracture and a bleed on enemy %d" % id)
	check(blows(off, m) == 0, "marrow_spear: the enemy 3 m off the line is not struck")
	check(near(float(core.enemy_info(inl[0])["taken_mult"]), 1.0 + float(DmSimData.FRACTURE["perStack"]), 1e-9), "marrow_spear: Fracture raises the damage taken to x%.2f" % float(core.enemy_info(inl[0])["taken_mult"]))
	# Impale: stops at the first enemy, x1.5, roots it
	await reset_and_wait()
	var i1 := foe("robber", at(4.0))
	var i2 := foe("robber", at(7.0))
	c.p["runes"] = {"marrow_spear": "rune_impale"}
	var sp2 := DmAbilities.spear(sp_now(), "rune_impale", 1.0)
	m = dmg_log.size()
	r = cast("marrow_spear", at(12.0))
	await secs(0.5)
	check(near(first_blow(i1, m), float(sp2["impaleDmg"])) and blows(i2, m) == 0, "Impale: only the first enemy, for %.3f" % first_blow(i1, m))
	var root := status_of(i1, &"root")
	check(root.get("stacks", 0) == 1 and absf(float(root["left"]) - float(DmSimData.RUNE_TUNING["impale"]["rootS"])) <= 0.3, "Impale roots it for %.1f s (%s)" % [float(DmSimData.RUNE_TUNING["impale"]["rootS"]), str(root)])
	# the legendary spearRally: the legion turns on the nearest enemy hit, and hits it harder while the mark lasts
	await reset_and_wait()
	var th := raise_at(at(-2.0))
	await ticks(60)
	var mk := foe("robber", at(11.5))   # beyond what the thrall scans for on its own
	c._set_mods(_with(base_mods, {"spearRally": 0.5}))
	r = cast("marrow_spear", at(12.0))
	await secs(0.4)
	var ti: Dictionary = legion().info(th)
	check(int(ti["target"]) == mk, "spearRally: the legion's thrall is turned on the enemy the spear hit (target %d)" % int(ti["target"]))
	check(near(float(ti["mark_mult"]), 1.0 + 0.5, 1e-9), "spearRally: the thrall hits the marked enemy x%.2f" % float(ti["mark_mult"]))


func _with(mods: Dictionary, extra: Dictionary) -> Dictionary:
	var m := mods.duplicate(true)
	m.merge(extra, true)
	return m


func t_exhume() -> void:
	await reset_and_wait()
	var cp := corpse(at(4.0))
	var rec := field.get_corpse(cp)
	var ex := {"kind": c.mods["thrallKind"], "cap": c.mods["thrallCap"], "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"], "attackSpeedMult": c.mods["thrallAttackSpeedMult"]}
	var want := DmThralls.raise_stats(ex, {"kind": rec.kind, "enemy": rec.enemy, "elite": rec.elite}, 1.0, 1, float(c.legend.get("championEvery", 0.0)))
	var r := cast("exhume", at(4.0))
	if not accepted(r, "exhume"):
		return
	check(field.get_corpse(cp) == null, "exhume: the corpse is consumed")
	var ids := legion().list()
	check(ids.size() == 1, "exhume: one thrall rises (%d)" % ids.size())
	await ticks(2)
	check(ids.size() == 1 and g.enemy_fx._thrall_rings.has(ids[0]), "exhume: the thrall stands on its ground ring")
	if ids.size() == 1:
		var t: Dictionary = legion().info(ids[0])
		check(t["kind"] == want["kind"] and t["kind"] == "warrior", "exhume: a %s (the Gravecaller's kind)" % t["kind"])
		check(near(float(t["hp"]), float(want["hp"])) and near(float(t["max_hp"]), float(want["maxHp"])) and near(float(t["damage"]), float(want["damage"])), "exhume: health %.2f and blow %.3f are DmThralls.raise_stats'" % [float(t["max_hp"]), float(t["damage"])])
		check(near(float(t["interval"]), float(want["attackInterval"])) and near(float(t["range"]), float(want["range"])) and near(float(t["speed"]), float(want["speed"])), "exhume: swing every %.3f s, range %.1f, speed %.1f" % [float(t["interval"]), float(t["range"]), float(t["speed"])])
		check(int(t["state"]) == DmCoreEvents.ThrallState.RISING and int(t["owner"]) == c.hero_id, "exhume: it is rising, and the hero's")
		await secs(1.2)
		check(int(legion().info(ids[0])["state"]) != DmCoreEvents.ThrallState.RISING, "exhume: it stands after the rise (0.9 s)")
		var vi: Dictionary = host.view.crowd.view_info(ids[0])
		check(not vi.is_empty(), "exhume: the crowd draws the thrall (a view of its own in the MultiMesh crowd: %s)" % str(vi.keys().slice(0, 4)))
		# A decal that follows a body by id reads the crowd's drawn place in C++ (the callable beside it is only the fallback), and goes dark when the body is gone.
		var prims: DmFxPrims = g.enemy_fx.vfx.prims
		var ground: Vector3 = host.view.crowd.ground_at(ids[0])
		var mark: DmFxHandle = prims.decal({"tex": "ring", "x": 0.0, "z": 0.0, "r": 1.0, "duration": 5.0, "follow_body": ids[0], "follow": func() -> Variant: return Vector3(500.0, 0.0, 500.0)})
		var gone: DmFxHandle = prims.decal({"tex": "ring", "x": 0.0, "z": 0.0, "r": 1.0, "duration": 5.0, "follow_body": 999999, "follow": func() -> Variant: return Vector3(500.0, 0.0, 500.0)})
		var at_now: Dictionary = prims._dec.item_of(mark.id)
		var at_gone: Dictionary = prims._dec.item_of(gone.id)
		check(ground != Vector3.INF and absf(float(at_now["x"]) - ground.x) < 0.001 and absf(float(at_now["z"]) - ground.z) < 0.001 and float(at_now["opacity"]) >= 0.0, "exhume: a decal that follows the thrall by id stands where the crowd draws it (%.2f, %.2f), not where the fallback says" % [ground.x, ground.z])
		check(float(at_gone["opacity"]) == 0.0, "exhume: a decal that follows a body that is not there is dark")
		mark.kill()
		gone.kill()
	# other corpses, other thralls
	await reset_and_wait()
	var specs := [["swift", "hound", false, "hound"], ["resonant", "penitent", false, "archer"], ["toxic", "sac", false, "plaguebearer"], ["normal", "robber", true, "warrior"]]
	for s in specs:
		await reset_and_wait()
		var cid := corpse(at(4.0), s[0], s[1], s[2])
		var rc := field.get_corpse(cid)
		var w2 := DmThralls.raise_stats(ex, {"kind": rc.kind, "enemy": rc.enemy, "elite": rc.elite}, 1.0, 1, float(c.legend.get("championEvery", 0.0)))
		r = cast("exhume", at(4.0))
		var l := legion().list()
		if check_n(l.size() == 1, "exhume of a %s %s corpse raises one thrall" % [s[0], s[1]]):
			var t2: Dictionary = legion().info(l[0])
			check(t2["kind"] == s[3] and near(float(t2["max_hp"]), float(w2["maxHp"])) and bool(t2["empowered"]) == bool(w2["empowered"]), "exhume: a %s corpse rises as a %s (health %.2f, empowered %s)" % [s[1], t2["kind"], float(t2["max_hp"]), str(t2["empowered"])])
	# the cap: the oldest crumbles first
	await reset_and_wait()
	var cap := int(c.mods["thrallCap"])
	var first_id := 0
	for k in cap + 1:
		corpse(at(3.0 + 0.2 * k, 1.0))
		var rr := cast("exhume", at(3.0 + 0.2 * k, 1.0))
		if k == 0:
			first_id = int(legion().list()[0])
		await ticks(40)   # past the cast lock
	check(legion().count() == cap, "exhume: the legion stops at its cap of %d (%d)" % [cap, legion().count()])
	check(not (legion().list() as PackedInt32Array).has(first_id), "exhume: at the cap the oldest thrall crumbled to make room")
	# Mass Grave: three corpses, x0.75
	await reset_and_wait()
	c.p["runes"] = {"exhume": "rune_mass_grave"}
	for k in 3:
		corpse(at(4.0, 0.5 * k))
	var MG: Dictionary = DmSimData.RUNE_TUNING["massGrave"]
	r = cast("exhume", at(4.0, 0.5))
	var mass := legion().list()
	check(mass.size() == int(MG["count"]), "Mass Grave: %d thralls from three corpses" % mass.size())
	if mass.size() == 3:
		var solo := DmThralls.raise_stats(ex, {"kind": "normal", "enemy": "robber", "elite": false}, 1.0, 1, 0.0)
		check(near(float(legion().info(mass[0])["max_hp"]), float(solo["maxHp"]) * float(MG["statMult"])), "Mass Grave: each at x%.2f the health" % float(MG["statMult"]))
	# Bone Colossus: 3 corpses become one
	await reset_and_wait()
	c.p["runes"] = {"exhume": "rune_bone_colossus"}
	for k in 3:
		corpse(at(4.0, 0.6 * k))
	var C: Dictionary = DmSimData.RUNE_TUNING["colossus"]
	r = cast("exhume", at(4.0, 0.6), -1, float(C["cooldownMult"]))
	var big := legion().list()
	check(big.size() == 1 and legion().info(big[0])["kind"] == "colossus", "Bone Colossus: three corpses raise one colossus")
	if big.size() == 1:
		var cs := DmThralls.colossus_stats(ex, [{"kind": "normal"}, {"kind": "normal"}, {"kind": "normal"}])
		check(near(float(legion().info(big[0])["max_hp"]), float(cs["maxHp"])) and near(legion().places_used(), float(C["slots"])), "Bone Colossus: health %.1f, %.0f legion places" % [float(legion().info(big[0])["max_hp"]), legion().places_used()])
	# no corpse: refused, nothing spent
	await reset_and_wait()
	var e0 := c.essence()
	r = cast("exhume", at(4.0))
	check(not r["ok"] and r["reason"] == "no_corpse" and near(c.essence(), e0, 1e-9), "exhume with no corpse is refused `no_corpse` and costs nothing")


## check() that returns its result.
func check_n(ok: bool, what: String) -> bool:
	check(ok, what)
	return ok


func t_miasma() -> void:
	await reset_and_wait()
	var inside1 := foe("robber", at(7.0, 1.0))
	var inside2 := foe("robber", at(7.0, -2.5))
	var outside := foe("robber", at(7.0, 6.0))
	var aim := at(7.0)
	var caster := {"x": c.p["x"], "z": c.p["z"]}
	var mz := DmAbilities.miasma(sp_now(), c.mods, "", 1.0, caster, {"x": aim.x, "z": aim.z})
	var r := cast("miasma", aim)
	if not accepted(r, "miasma"):
		return
	await secs(0.9)   # the lob lands at 0.4 s: the first pulse is at the landing
	var zones: Array = c.mem("miasma").get("zones", [])
	check(zones.size() == 1 and near(float(zones[0]["r"]), float(mz["r"])) and near(float(zones[0]["dps"]), float(mz["dps"])), "miasma: one cloud of radius %.2f and %.2f dps" % [float(zones[0]["r"]) if zones.size() > 0 else -1.0, float(zones[0]["dps"]) if zones.size() > 0 else -1.0])
	for id in [inside1, inside2]:
		var w := status_of(id, WITHERED)
		check(w.get("stacks", 0) == 1 and float(w["left"]) <= float(DmSimData.WITHERED["durationMs"]) / 1000.0 and float(w["left"]) > float(DmSimData.WITHERED["durationMs"]) / 1000.0 - 1.0, "miasma: a Withered stack for %.1f s on an enemy inside (%s)" % [float(DmSimData.WITHERED["durationMs"]) / 1000.0, str(w)])
		check(stacks_of(id, &"slow") == 1, "miasma: slowed while it stands in the cloud")
	check(status_of(outside, WITHERED).is_empty() and status_of(outside, &"slow").is_empty(), "miasma: the enemy outside the cloud is untouched")
	await secs(1.0)   # the next pulse, at 1 s
	check(stacks_of(inside1, WITHERED) == 2, "miasma: +1 stack each second (%d)" % stacks_of(inside1, WITHERED))
	# the DoT is the core's: lumps of stacks x dps, with the kill credit to the hero
	var lumps := 0
	for d in dmg_log:
		if int(d[0]) == inside1 and int(d[1]) == c.hero_id:
			lumps += 1
	check(lumps >= 1, "miasma: Withered burns the enemy in lumps, credited to the hero (%d)" % lumps)
	await secs(5.5)
	check((c.mem("miasma").get("zones", []) as Array).is_empty(), "miasma: the cloud is gone after %.0f s" % (float(mz["durationMs"]) / 1000.0))
	# Contagion: a withered enemy of the cloud that dies hands its stacks on
	await reset_and_wait()
	c.p["runes"] = {"miasma": "rune_contagion"}
	var a := foe("robber", at(7.0))
	var nb := foe("robber", at(8.5, 1.0))     # inside the cloud, within the rune's reach of `a`
	var far := foe("robber", at(7.0, 8.0))
	r = cast("miasma", at(7.0))
	await secs(2.6)   # the landing at 0.4 s, pulses at 0.4, 1.4, 2.4: three stacks
	var C: Dictionary = DmSimData.RUNE_TUNING["contagion"]
	var sa := stacks_of(a, WITHERED)
	var before := stacks_of(nb, WITHERED)
	check(sa >= int(C["minStacks"]), "Contagion: the enemy has %d stacks (it hands on from %d)" % [sa, int(C["minStacks"])])
	core.damage(a, 1.0e9, c.hero_id)   # it dies carrying its stacks
	await ticks(3)                      # the core's event reaches the rite at the end of the tick
	check(stacks_of(nb, WITHERED) >= maxi(before, sa - 1), "Contagion: its neighbour carries %d stacks (it had %d, the dead one %d)" % [stacks_of(nb, WITHERED), before, sa])
	check(stacks_of(far, WITHERED) == 0, "Contagion: one out of reach is not infected")


func t_black_litany() -> void:
	await reset_and_wait()
	var ex := {"kind": c.mods["thrallKind"], "cap": c.mods["thrallCap"], "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"], "attackSpeedMult": c.mods["thrallAttackSpeedMult"], "r": 0.8}
	var t1 := raise_at(at(1.0))
	var t2 := raise_at(at(1.0, 1.0))
	await ticks(60)
	for k in 3:
		corpse(at(3.0 + k, 1.5))
	corpse(at(4.0, -2.0), "resonant", "penitent")
	var far_corpse := corpse(at(11.0))
	var e1 := foe("robber", at(3.0))
	var e2 := foe("robber", at(5.0, 2.0))
	var e3 := foe("robber", at(12.0))
	c.p["hp"] = float(c.p["stats"]["maxHp"]) * 0.5
	c._set_mods(_with(base_mods, {"litanyBarrier": 0.02, "corpseHeal": 0.03}))   # so that its barrier and heal are worth checking
	var sp := DmAbilities.litany_spell_power(sp_now(), "")
	var thr := legion().near(origin, 7.0).size()
	var dmg := sp * DmAbilities.litany_mult(3, 1, thr)
	var gains := DmAbilities.litany_gains(c.max_hp(), c.mods, {"corpses": 3, "resonant": 1, "thralls": thr})
	var m := dmg_log.size()
	var hp0 := float(c.p["hp"])
	var r := cast("black_litany", origin)
	if not accepted(r, "black_litany"):
		return
	await ticks(2)   # the core's events (the blows) reach the log at the end of the tick
	check(thr == 2, "black_litany: the two thralls are within 7 m")
	check(near(first_blow(e1, m), dmg) and near(first_blow(e2, m), dmg), "black_litany: every enemy within 7 m took %.3f (the formula %.3f)" % [first_blow(e1, m), dmg])
	check(blows(e3, m) == 0, "black_litany: the enemy 12 m away is untouched")
	check(field.get_corpse(far_corpse) != null and field.count() == 3 and field.corpses_in_radius(origin, 7.0).size() == 2, "black_litany: the four corpses within 7 m are consumed, the far one stays, and the Gravecaller's litany leaves a corpse where each thrall fell (%d lie)" % field.count())
	check(legion().count() == 0 and not host.core.thrall_info(t1).get("alive", false) and not host.core.thrall_info(t2).get("alive", false), "black_litany: both thralls were sacrificed")
	check(float(gains["barrier"]) > 0.0 and float(gains["heal"]) > 0.0 and close(float(c.p["barrier"]), float(gains["barrier"]), 1.0) and close(float(c.p["hp"]), hp0 + float(gains["heal"]), 2.0), "black_litany: barrier %.1f of %.1f and heal %.1f of %.1f, paid once" % [float(c.p["barrier"]), float(gains["barrier"]), float(c.p["hp"]) - hp0, float(gains["heal"])])
	var ev: Dictionary = {}
	for x in ev_log:
		if x.get("t") == "litany":
			ev = x
	check(ev.get("corpses", -1) == 3 and ev.get("resonant", -1) == 1 and ev.get("thralls", -1) == 2 and ev.get("targets", -1) == 2, "black_litany: the event counts 3 corpses, 1 resonant, 2 thralls, 2 targets (%s)" % str([ev.get("corpses"), ev.get("resonant"), ev.get("thralls"), ev.get("targets")]))
	# Hollow Choir spares the thralls (at x0.6); Legion of the Unburied lays a corpse where a sacrificed thrall falls
	await reset_and_wait()
	c.p["runes"] = {"black_litany": "rune_hollow_choir"}
	var s1 := raise_at(at(1.0))
	var s2 := raise_at(at(1.0, 1.0))
	await ticks(60)
	var en := foe("robber", at(3.0))
	var sp2 := DmAbilities.litany_spell_power(sp_now(), "rune_hollow_choir")
	var n2 := legion().near(origin, 7.0).size()
	m = dmg_log.size()
	r = cast("black_litany", origin)
	await ticks(2)
	check(legion().count() == 2 and near(first_blow(en, m), sp2 * DmAbilities.litany_mult(0, 0, n2)), "Hollow Choir: the thralls are spared and the burst is %.3f" % first_blow(en, m))
	# Requiem: the burst comes after its delay, over a circle 1.7 times as wide
	await reset_and_wait()
	c.p["runes"] = {"black_litany": "rune_requiem"}
	var RQ: Dictionary = DmSimData.RUNE_TUNING["requiem"]
	var wide := foe("robber", at(9.5))      # outside 7 m, inside 7 x the rune's radius
	var sp3 := DmAbilities.litany_spell_power(sp_now(), "rune_requiem")
	m = dmg_log.size()
	r = cast("black_litany", origin)
	await ticks(2)
	check(blows(wide, m) == 0, "Requiem: nothing happens at the cast")
	await secs(float(RQ["delayMs"]) / 1000.0 + 0.3)
	check(near(first_blow(wide, m), sp3 * DmAbilities.litany_mult(0, 0, 0)), "Requiem: after %.1f s the burst hits an enemy 9.5 m away for %.3f" % [float(RQ["delayMs"]) / 1000.0, first_blow(wide, m)])
	for leaves in [true, false]:
		await reset_and_wait()
		c._set_mods(_with(base_mods, {"sacrificeLeavesCorpse": leaves}))
		raise_at(at(1.0))
		raise_at(at(1.0, 1.0))
		await ticks(60)
		r = cast("black_litany", origin)
		check(legion().count() == 0 and field.count() == (2 if leaves else 0), "sacrificeLeavesCorpse %s: %d corpse(s) lie where the sacrificed thralls fell" % [str(leaves), field.count()])


func t_corpse_explosion() -> void:
	await reset_and_wait()
	var cp := corpse(at(5.0))
	var near_e := foe("robber", at(5.5, 1.0))
	var far_e := foe("robber", at(5.0, 5.0))
	var rec := {"kind": "normal", "elite": false, "scale": 1.0}
	var blast := DmAbilities.detonate_blast(DmAbilities.detonate_claim(sp_now()), rec)
	var m := dmg_log.size()
	var shatters := int(g.enemy_fx.stats["shatter"])
	var r := cast("corpse_explosion", at(5.0))
	if not accepted(r, "corpse_explosion"):
		return
	await ticks(2)
	check(field.get_corpse(cp) == null, "corpse_explosion: the corpse is consumed (burst)")
	check(int(g.enemy_fx.stats["shatter"]) == shatters + 1, "corpse_explosion: the body is blown apart at once, not left to sink (DmCrowd.shatter)")
	check(near(first_blow(near_e, m), float(blast["dmg"])) and blows(far_e, m) == 0, "corpse_explosion: %.3f to the enemy within %.1f m, nothing to the one 5 m off" % [first_blow(near_e, m), float(blast["radius"])])
	# an elite's corpse hits harder; a toxic one leaves a rot cloud
	await reset_and_wait()
	corpse(at(5.0), "normal", "robber", true)
	var e := foe("robber", at(5.0, 1.0))
	var blast_e := DmAbilities.detonate_blast(DmAbilities.detonate_claim(sp_now()), {"kind": "normal", "elite": true, "scale": 1.0})
	m = dmg_log.size()
	r = cast("corpse_explosion", at(5.0))
	await ticks(2)
	check(near(first_blow(e, m), float(blast_e["dmg"])) and float(blast_e["dmg"]) > float(blast["dmg"]), "corpse_explosion: an elite's corpse hits for %.3f (x%.1f)" % [first_blow(e, m), float(blast_e["dmg"]) / float(blast["dmg"])])
	await reset_and_wait()
	corpse(at(5.0), "toxic", "sac")
	var inside := foe("robber", at(5.0, 1.0))
	var bt := DmAbilities.detonate_blast(DmAbilities.detonate_claim(sp_now()), {"kind": "toxic", "elite": false, "scale": 1.0})
	r = cast("corpse_explosion", at(5.0))
	var zs: Array = c.mem("miasma").get("zones", [])
	check(zs.size() == 1 and zs[0]["kind"] == "rot" and near(float(zs[0]["r"]), float(bt["rotRadius"])) and near(float(zs[0]["dps"]), float(bt["rotDps"])), "corpse_explosion: a toxic corpse leaves a rot cloud of radius %.2f" % (float(zs[0]["r"]) if zs.size() > 0 else -1.0))
	await secs(0.5)
	check(stacks_of(inside, WITHERED) >= 1, "corpse_explosion: the rot cloud withers the enemy in it")


func t_grave_offering() -> void:
	await reset_and_wait()
	var cp := corpse(at(5.0), "resonant", "penitent", true)
	c.p["hp"] = float(c.p["stats"]["maxHp"]) * 0.5
	c.p["resource"]["value"] = 20.0
	var G: Dictionary = DmSimData.GRAVE_OFFERING
	var essence := (float(G["essence"]) + float(G["resonantBonus"])) * float(G["eliteMult"])
	var heal := c.max_hp() * (float(G["healFrac"]) + float(c.mods.get("corpseHeal", 0.0)))
	var hp0 := float(c.p["hp"])
	var r := cast("grave_offering", at(5.0))
	if not accepted(r, "grave_offering"):
		return
	check(field.get_corpse(cp) == null, "grave_offering: the corpse is consumed")
	await secs(0.6)   # the orb flies 14 m/s
	check(close(c.essence(), 20.0 + essence + regen_since(r), 0.4), "grave_offering: +%.1f essence for a resonant elite corpse (%.2f)" % [essence, c.essence() - 20.0])
	check(float(c.p["hp"]) >= hp0 + heal - 0.01, "grave_offering: healed %.1f" % (float(c.p["hp"]) - hp0))


func t_bone_mantle() -> void:
	await reset_and_wait()
	for k in 3:
		corpse(at(1.5 + 0.3 * k, 1.0))
	var far_c := corpse(at(9.0))
	var near_e := foe("robber", at(1.4))
	var far_e := foe("robber", at(6.0))
	var pv := {"stats": c.p["stats"], "barrier": 0.0, "barrierPeak": 0.0, "barrierHoldUntil": 0.0}
	DmAbilities.mantle_apply(pv, 3.0, 0.0)
	var barrier_val: float = pv["barrier"]
	var shard := DmAbilities.mantle_shard_damage(sp_now())
	var m := dmg_log.size()
	var r := cast("bone_mantle", origin)
	if not accepted(r, "bone_mantle"):
		return
	check(field.count() == 1 and field.get_corpse(far_c) != null, "bone_mantle: the three corpses within 6 m are drawn in, the far one is not")
	check(near(float(c.p["barrier"]), barrier_val, 1e-6), "bone_mantle: a barrier of %.1f (10%% + 7%% a corpse of %.0f health)" % [float(c.p["barrier"]), c.max_hp()])
	await secs(0.6)   # the first shards at 0.5 s
	check(blows(near_e, m) == 1 and near(first_blow(near_e, m), shard), "bone_mantle: the shards hit the enemy beside him for %.3f" % first_blow(near_e, m))
	check(blows(far_e, m) == 0, "bone_mantle: not the one 6 m off")


func t_carrion_seed() -> void:
	await reset_and_wait()
	var cp := corpse(at(6.0))
	var far_e := foe("robber", at(10.0, 6.0))
	var CS: Dictionary = DmSimData.CARRION_SEED
	var dmg := minf(1.0e5, sp_now() * float(DmAbilities.def("carrion_seed")["power"]))
	var r := cast("carrion_seed", at(6.0))
	if not accepted(r, "carrion_seed"):
		return
	var note := field.notes(cp)
	check(str(note.get("seedOwner")) == str(c.peer_id) and near(float(note["seedDmg"]), dmg), "carrion_seed: the seed holds %.3f of the caster's spell power" % float(note.get("seedDmg", -1.0)))
	await secs(float(CS["armS"]) + 0.1)
	check(field.get_corpse(cp) != null, "carrion_seed: it waits for an enemy (armed after %.1f s)" % float(CS["armS"]))
	var trigger := foe("robber", at(6.5, 1.0))
	var m := dmg_log.size()
	await secs(0.4)
	check(field.get_corpse(cp) == null, "carrion_seed: an enemy within %.1f m sets it off and the corpse bursts" % float(CS["triggerR"]))
	check(near(first_blow(trigger, m), dmg) and blows(far_e, m) == 0, "carrion_seed: %.3f to the enemy beside it, nothing to the far one" % first_blow(trigger, m))
	var w := status_of(trigger, WITHERED)
	check(w.get("stacks", 0) == int(CS["withered"]), "carrion_seed: %d Withered stacks (%s)" % [int(CS["withered"]), str(w)])


func t_wailing_skull() -> void:
	# a chain of five along the line, 3 m apart: the first dies to the skull. A kill earns another leap: four blows, not three.
	var counts := []
	for weak in [true, false]:
		await reset_and_wait()
		var chain: Array[int] = []
		for k in 5:
			chain.append(foe("robber", at(5.0 + 3.0 * k), 0.001 if (weak and k == 0) else BIG))
		var W: Dictionary = DmCombatData.const_table("WAILING_SKULL")
		var dmg := DmAbilities.rite_damage(sp_now(), "wailing_skull")
		var r := cast("wailing_skull", at(5.0), chain[0])
		if not accepted(r, "wailing_skull"):
			return
		await secs(2.0)
		var h := hits_of("wailing_skull")
		counts.append(h.size())
		check(h.size() == (4 if weak else 3), "wailing_skull: %d blows on a chain of five when the first %s (the skull leaps %d times, one more for a kill)" % [h.size(), "dies" if weak else "survives", int(W["hops"])])
		for k in h.size():
			check(near(float(h[k][2]), dmg * pow(float(W["falloff"]), k)), "wailing_skull: leap %d dealt %.3f (x%.1f a leap)" % [k + 1, float(h[k][2]), float(W["falloff"])])
		check(bool(h[0][4]) == weak and h[0][1] == chain[0], "wailing_skull: the first blow %s" % ("kills (known at once)" if weak else "does not kill"))
		check(hp_of(chain[4]) == float(core.enemy_info(chain[4])["max_hp"]), "wailing_skull: the fifth enemy is out of the chain")
	check(counts == [4, 3], "wailing_skull: the kill earned the extra leap (%s)" % str(counts))


func t_ivory_cleave() -> void:
	await reset_and_wait()
	var a := foe("robber", at(2.5, 0.5))
	var b := foe("robber", at(3.0, -2.0))     # 34 degrees off the line: inside the 60 degree half-angle
	var behind := foe("robber", at(-2.0))
	var beyond := foe("robber", at(6.0))
	var IC: Dictionary = DmCombatData.const_table("IVORY_CLEAVE")
	var dmg := DmAbilities.rite_damage(sp_now(), "ivory_cleave")
	var m := dmg_log.size()
	var r := cast("ivory_cleave", at(5.0))
	if not accepted(r, "ivory_cleave"):
		return
	await ticks(2)
	check(near(first_blow(a, m), dmg) and near(first_blow(b, m), dmg), "ivory_cleave: both enemies in the crescent took %.3f" % first_blow(a, m))
	check(blows(behind, m) == 0 and blows(beyond, m) == 0, "ivory_cleave: not the one behind him nor the one past the %.1f m reach" % float(IC["reach"]))
	check(stacks_of(a, &"fracture") == int(IC["fracture"]) and stacks_of(b, &"fracture") == int(IC["fracture"]), "ivory_cleave: +%d Fracture on each" % int(IC["fracture"]))


func t_bone_storm() -> void:
	await reset_and_wait()
	corpse(at(8.0, 1.0))
	corpse(at(8.0, -1.0))
	var e := foe("robber", at(9.0))
	var life := DmAbilities.bone_storm_life_s(2.0)
	var dmg := DmAbilities.rite_damage(sp_now(), "bone_storm")
	var m := dmg_log.size()
	var r := cast("bone_storm", at(8.0))
	if not accepted(r, "bone_storm"):
		return
	var storms: Array = c.mem("bone_storm").get("storms", [])
	check(storms.size() == 1 and near(float(storms[0]["until"]) - float(r["now"]), life * 1000.0, 1e-6), "bone_storm: it lasts %.1f s (4 s and 0.6 s a corpse under it); the corpses are only counted (%d lie)" % [life, field.count()])
	check(field.count() == 2, "bone_storm: only counts the corpses under it")
	await secs(1.0)   # a tick every 0.4 s: two by now
	check(blows(e, m) == 2 and near(first_blow(e, m), dmg), "bone_storm: the funnel hit the enemy in it twice by 1 s, %.3f each (%d)" % [first_blow(e, m), blows(e, m)])
	var storm: Dictionary = (c.mem("bone_storm").get("storms", []) as Array)[0]
	check(Vector2(float(storm["x"]) - at(8.0).x, float(storm["z"]) - at(8.0).z).length() > 0.5, "bone_storm: it drifts toward the nearest enemy (%.2f m so far)" % Vector2(float(storm["x"]) - at(8.0).x, float(storm["z"]) - at(8.0).z).length())


func t_soul_siphon() -> void:
	await reset_and_wait()
	var e := foe("robber", at(6.0))
	var S: Dictionary = DmCombatData.const_table("SOUL_SIPHON")
	c.p["hp"] = float(c.p["stats"]["maxHp"]) * 0.5
	c.p["resource"]["value"] = 40.0
	var dmg := DmAbilities.rite_damage(sp_now(), "soul_siphon")
	var hp0 := float(c.p["hp"])
	var m := dmg_log.size()
	var r := cast("soul_siphon", at(6.0), e)
	if not accepted(r, "soul_siphon"):
		return
	var tethers: Array = c.mem("soul_siphon").get("tethers", [])
	check(tethers.size() == 1 and near(float(tethers[0]["until"]) - float(r["now"]), float(S["durationS"]) * 1000.0, 1e-6), "soul_siphon: the tether lasts %.0f s" % float(S["durationS"]))
	await secs(1.25)   # drains at 0.5 s and 1.0 s
	check(blows(e, m) == 2 and near(first_blow(e, m), dmg), "soul_siphon: two drains of %.3f by 1.25 s (%d)" % [first_blow(e, m), blows(e, m)])
	var healed := float(c.p["hp"]) - hp0
	check(healed >= 2.0 * dmg * float(S["healFrac"]) - 0.01, "soul_siphon: healed %.2f (%.0f%% of two drains is %.2f)" % [healed, 100.0 * float(S["healFrac"]), 2.0 * dmg * float(S["healFrac"])])


func t_grave_step() -> void:
	await reset_and_wait()
	var cp := corpse(at(8.0))
	var near_e := foe("robber", at(8.5, 1.0))
	var home_e := foe("robber", at(1.0))
	var G: Dictionary = DmCombatData.const_table("GRAVE_STEP")
	var dmg := DmAbilities.rite_damage(sp_now(), "grave_step")
	var bleed := minf(dmg * float(DmSimData.HEMORRHAGE["dpsFrac"]), dmg * float(DmSimData.HEMORRHAGE["maxFrac"]))
	var m := dmg_log.size()
	var r := cast("grave_step", at(8.0))
	if not accepted(r, "grave_step"):
		return
	await ticks(2)
	check(Vector2(hero.position.x - at(8.0).x, hero.position.z - at(8.0).z).length() < 0.8, "grave_step: the hero blinked onto the corpse (%.2f m from it)" % Vector2(hero.position.x - at(8.0).x, hero.position.z - at(8.0).z).length())
	check(field.get_corpse(cp) != null, "grave_step: the corpse stays for the next rite")
	check(near(first_blow(near_e, m), dmg) and blows(home_e, m) == 0, "grave_step: %.3f within %.1f m of where he re-forms, nothing where he was" % [first_blow(near_e, m), float(G["burstRadius"])])
	var bl := status_of(near_e, &"bleed")
	check(bl.get("stacks", 0) == 1 and bleed > 0.0, "grave_step: and a bleed (%s)" % str(bl))


func t_veil_step() -> void:
	await reset_and_wait()
	var r := cast("veil_step", at(9.0))
	if not accepted(r, "veil_step"):
		return
	await secs(0.5)
	var moved := Vector2(hero.position.x - origin.x, hero.position.z - origin.z).length()
	check(absf(moved - float(DmAbilities.def("veil_step")["range"])) < 0.8, "veil_step: a glide of %.2f m toward the cursor (the range %.1f)" % [moved, float(DmAbilities.def("veil_step")["range"])])
	check(c.cooldown_left("veil_step") > 6000.0, "veil_step: free, 7 s")


func t_grave_frost() -> void:
	await reset_and_wait()
	var a := foe("robber", at(4.0, 0.5))
	var b := foe("robber", at(6.0, -1.5))
	var out_side := foe("robber", at(2.0, 3.0))   # 56 degrees off the line
	var beyond := foe("robber", at(9.5))
	var G: Dictionary = DmSimData.GRAVE_FROST
	var dmg := DmAbilities.rite_damage(sp_now(), "grave_frost")
	var m := dmg_log.size()
	var r := cast("grave_frost", at(7.0))
	if not accepted(r, "grave_frost"):
		return
	await secs(0.5)
	check(near(first_blow(a, m), dmg) and near(first_blow(b, m), dmg), "grave_frost: the cone dealt %.3f" % first_blow(a, m))
	check(blows(out_side, m) == 0 and blows(beyond, m) == 0, "grave_frost: not the one outside the %.0f degrees nor the one past 7 m" % float(G["halfAngleDeg"]))
	var ch := status_of(a, &"chill")
	check(ch.get("stacks", 0) == 1 and absf(float(ch["left"]) - float(G["chillS"])) <= 0.3, "grave_frost: Chilled for %.0f s (%s)" % [float(G["chillS"]), str(ch)])
	# a second bolt on an enemy that is already chilled shatters it
	var m2 := dmg_log.size()
	c.p["castUntil"] = 0.0
	r = cast("grave_frost", at(7.0))
	await secs(0.5)
	var seen := first_blow(a, m2)
	check(near(seen, dmg * float(G["shatterMult"])), "grave_frost: a chilled enemy shatters for x%.1f (%.3f)" % [float(G["shatterMult"]), seen])
	var crits := 0
	for h in hits_of("grave_frost"):
		if bool(h[3]):
			crits += 1
	check(crits >= 2, "grave_frost: the shatter is credited as such (%d)" % crits)


func t_bone_prison() -> void:
	await reset_and_wait()
	var a := foe("robber", at(8.0, 0.5))
	var b := foe("robber", at(8.0, -1.0))
	var doomed := foe("robber", at(8.5, 0.0), 0.001)
	var out_e := foe("robber", at(8.0, 4.0))
	var P: Dictionary = DmSimData.BONE_PRISON
	var dmg := DmAbilities.rite_damage(sp_now(), "bone_prison")
	var m := dmg_log.size()
	var sm := status_log.size()
	var r := cast("bone_prison", at(8.0))
	if not accepted(r, "bone_prison"):
		return
	await ticks(2)
	check(near(first_blow(a, m), dmg) and near(first_blow(b, m), dmg), "bone_prison: the ring dealt %.3f to the survivors" % first_blow(a, m))
	check(blows(out_e, m) == 0, "bone_prison: not the enemy 4 m from its centre")
	var root := status_of(a, &"root")
	check(root.get("stacks", 0) == 1 and absf(float(root["left"]) - float(P["rootS"])) <= 0.3 and stacks_of(a, &"fracture") == int(P["fracture"]), "bone_prison: Rooted %.1f s and +%d Fracture (%s)" % [float(P["rootS"]), int(P["fracture"]), str(root)])
	# the synchronous kill: the one the blow kills is skipped (no root, no fracture applied at all)
	var h := hits_of("bone_prison")
	var killed_h := h.filter(func(x: Array) -> bool: return x[1] == doomed)
	check(killed_h.size() == 1 and bool(killed_h[0][4]) and not host.enemy_alive(doomed), "bone_prison: the weak enemy dies to the blow, known at once")
	var touched := 0
	for i in range(sm, status_log.size()):
		if status_log[i] == doomed:
			touched += 1
	check(touched == 0, "bone_prison: the dead are skipped: no status was put on the one that fell (%d)" % touched)


func t_grave_hands() -> void:
	await reset_and_wait()
	corpse(at(7.0, 1.0))
	corpse(at(7.0, -1.0))
	var e := foe("robber", at(7.0, 0.5))
	var G: Dictionary = DmSimData.GRAVE_HANDS
	var h := DmAbilities.grave_hands(sp_now(), 2.0)
	var m := dmg_log.size()
	var r := cast("grave_hands", at(7.0))
	if not accepted(r, "grave_hands"):
		return
	await secs(1.25)   # rakes at 60 ms, 560 ms, 1060 ms
	check(blows(e, m) == 3 and near(first_blow(e, m), float(h["dmg"])), "grave_hands: three rakes of %.3f by 1.25 s (%d), x%.2f for the two corpses in the field" % [first_blow(e, m), blows(e, m), float(h["dmg"]) / DmAbilities.rite_damage(sp_now(), "grave_hands")])
	check(stacks_of(e, &"slow") == 1, "grave_hands: and it is slowed")
	check(field.count() == 2, "grave_hands: the corpses stay")
	await secs(2.2)
	check((c.mem("grave_hands").get("zones", []) as Array).is_empty(), "grave_hands: the field is gone after %.0f s" % float(G["durationS"]))


func t_rally_dead() -> void:
	await reset_and_wait()
	var r := cast("rally_dead", at(6.0))
	check(not r["ok"] and r["reason"] == "no_thralls", "rally_dead with no legion is refused `no_thralls` (%s)" % r["reason"])
	var t1 := raise_at(at(1.0))
	var t2 := raise_at(at(1.0, 1.0))
	await ticks(60)
	core.set_thrall_stats(t1, {"hp": 5.0})
	var e := foe("robber", at(6.0))
	var RL: Dictionary = DmSimData.RALLY
	var max_hp := float(legion().info(t1)["max_hp"])
	r = cast("rally_dead", at(6.0))
	if not accepted(r, "rally_dead"):
		return
	var secs_r := float(RL["durationS"]) + float(RL["gravecallerBonusS"])
	for t in [t1, t2]:
		var ti: Dictionary = legion().info(t)
		check(absf(float(ti["rally_t"]) - secs_r) <= 0.1, "rally_dead: rallied for %.0f s (the Gravecaller's +%.0f): %.2f" % [secs_r, float(RL["gravecallerBonusS"]), float(ti["rally_t"])])
		check(int(ti["target"]) == e, "rally_dead: the thrall turns on the enemy nearest the cursor")
	check(near(float(legion().info(t1)["hp"]), minf(max_hp, 5.0 + max_hp * float(RL["healFrac"]))), "rally_dead: healed %.0f%% of its health (%.2f of %.2f)" % [100.0 * float(RL["healFrac"]), float(legion().info(t1)["hp"]), max_hp])
	check(c.cooldown_left("rally_dead") > 11000.0, "rally_dead: 12 s")


func t_ossuary_wall() -> void:
	await reset_and_wait()
	var W: Dictionary = DmSimData.SIGNATURE["wall"]
	var r := cast("ossuary_wall", at(8.0))
	if not accepted(r, "ossuary_wall"):
		return
	var walls: Array = c.mem("ossuary_wall").get("walls", [])
	check(walls.size() == 1 and near(float(walls[0]["until"]) - float(r["now"]), float(W["durationS"]) * 1000.0, 1e-6), "ossuary_wall: it stands %.0f s" % float(W["durationS"]))
	var raise_ev: Dictionary = {}
	for x in ev_log:
		if x.get("t") == "raise":
			raise_ev = x
	var len := Vector2(float(raise_ev.get("x1", 0.0)) - float(raise_ev.get("x0", 0.0)), float(raise_ev.get("z1", 0.0)) - float(raise_ev.get("z0", 0.0))).length()
	check(near(len, float(W["length"]), 1e-4), "ossuary_wall: %.1f m of wall" % len)
	check(c.get_node_or_null("Ribs1") != null, "ossuary_wall: its ribs stand")
	# Solid for the core's enemies: one placed in the middle of it is put out of the 7 m by 0.8 m box.
	var a := Vector2(float(raise_ev.get("x0", 0.0)), float(raise_ev.get("z0", 0.0)))
	var b := Vector2(float(raise_ev.get("x1", 0.0)), float(raise_ev.get("z1", 0.0)))
	var e := foe("robber", Vector3((a.x + b.x) / 2.0, 0.0, (a.y + b.y) / 2.0))
	await ticks(3)
	var info: Dictionary = host.enemy_info(e)
	var p: Vector2 = info.get("pos", Vector2.ZERO)
	var off := Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p)
	check(off >= float(W["thickness"]) / 2.0 + float(info.get("radius", 0.0)) - 0.02, "ossuary_wall: an enemy inside the wall is put out of it (%.2f m from its line)" % off)
	await secs(float(W["durationS"]) + 0.3)
	check((c.mem("ossuary_wall").get("walls", []) as Array).is_empty() and c.get_node_or_null("Ribs1") == null, "ossuary_wall: it falls after its time and the ribs are gone")


func t_command_rend() -> void:
	await reset_and_wait()
	var r := cast("command_rend", at(10.0))
	check(not r["ok"] and r["reason"] == "no_thralls", "command_rend with no legion is refused `no_thralls` (%s)" % r["reason"])
	var ts: Array[int] = [raise_at(at(1.0)), raise_at(at(1.0, 1.0)), raise_at(at(1.0, -1.0))]
	await ticks(60)
	var e1 := foe("robber", at(10.0, 0.5))
	var e2 := foe("robber", at(10.0, -1.0))
	var e3 := foe("robber", at(10.0, 8.0))
	var R: Dictionary = DmSimData.SIGNATURE["rend"]
	var infos := {}
	for t in ts:
		infos[t] = legion().info(t)
	var m := dmg_log.size()
	r = cast("command_rend", at(10.0))
	if not accepted(r, "command_rend"):
		return
	var after := {}
	for t in ts:
		after[t] = legion().info(t)   # the leap is made inside the cast: read before the thralls move on
	await ticks(2)
	var dmg := float(infos[ts[0]]["damage"]) * float(R["damageMult"])
	for t in ts:
		var ti: Dictionary = after[t]
		var p: Vector2 = ti["pos"]
		check(absf(Vector2(p.x - at(10.0).x, p.y - at(10.0).z).length() - 1.2) < 0.05, "command_rend: the thrall leapt to the ring 1.2 m round the point (%.2f)" % Vector2(p.x - at(10.0).x, p.y - at(10.0).z).length())
		check(near(float(ti["hp"]), maxf(1.0, float(infos[t]["hp"]) - float(infos[t]["max_hp"]) * float(R["hpCost"]))), "command_rend: it paid %.0f%% of its health" % (100.0 * float(R["hpCost"])))
		check(int(ti["target"]) == 0, "command_rend: and let go of its target")
	var from_thralls := 0
	for i in range(m, dmg_log.size()):
		if ts.has(int(dmg_log[i][1])):
			from_thralls += 1
	check(blows(e1, m) == 3 and blows(e2, m) == 3 and near(first_blow(e1, m), dmg), "command_rend: each thrall cleaved both enemies for %.3f (3 blows each: %d, %d)" % [first_blow(e1, m), blows(e1, m), blows(e2, m)])
	check(blows(e3, m) == 0 and from_thralls == 6, "command_rend: the blows carry the thralls as their source (%d), the far enemy is untouched" % from_thralls)
	var rev: Dictionary = {}
	for x in ev_log:
		if x.get("t") == "rend":
			rev = x
	check(rev.get("hits", -1) == 2 and (rev.get("leaps", []) as Array).size() == 3, "command_rend: the event counts 2 enemies hit and 3 leaps")


func t_dirge() -> void:
	await reset_and_wait()
	var t1 := raise_at(at(1.0))
	await ticks(60)
	core.set_thrall_stats(t1, {"hp": 10.0})
	var e := foe("robber", at(4.0))
	var far_e := foe("robber", at(9.0))
	var D: Dictionary = DmSimData.SIGNATURE["dirge"]
	c.p["hp"] = float(c.p["stats"]["maxHp"]) * 0.5
	var heal := sp_now() * float(DmAbilities.def("dirge")["power"])
	var hp0 := float(c.p["hp"])
	var max_hp := float(legion().info(t1)["max_hp"])
	var r := cast("dirge", origin)
	if not accepted(r, "dirge"):
		return
	await secs(0.5)
	check(float(c.p["hp"]) >= hp0 + heal - 0.01, "dirge: the pulse mended the hero by %.2f (the formula %.2f)" % [float(c.p["hp"]) - hp0, heal])
	check(near(float(legion().info(t1)["hp"]), 10.0 + max_hp * float(D["thrallHealFrac"]), 1e-4), "dirge: and the thrall by %.0f%% of its health" % (100.0 * float(D["thrallHealFrac"])))
	var sil := status_of(e, &"silence")
	check(sil.get("stacks", 0) == 1 and float(sil["left"]) <= float(D["silenceS"]) + 0.05, "dirge: the enemy inside is Silenced (%s)" % str(sil))
	check(status_of(far_e, &"silence").is_empty(), "dirge: the one outside the %.0f m is not" % float(D["radius"]))


func t_plague_bloom() -> void:
	await reset_and_wait()
	var e := foe("robber", at(8.0))
	var out_e := foe("robber", at(8.0, 4.0))
	corpse(at(8.0, 4.5))
	var dps := sp_now() * float(DmAbilities.def("plague_bloom")["power"])
	var r := cast("plague_bloom", at(8.0))
	if not accepted(r, "plague_bloom"):
		return
	await secs(1.3)   # the first pulse at once, the second at 1 s
	var w := status_of(e, WITHERED)
	check(w.get("stacks", 0) == 2, "plague_bloom: +1 Withered a second (%s)" % str(w))
	check(stacks_of(e, &"slow") == 1 and status_of(out_e, WITHERED).is_empty(), "plague_bloom: it slows the enemy in it and spares the one 4 m off")
	var zones: Array = c.mem("plague_bloom").get("zones", [])
	check(zones.size() >= 1 and near(float(zones[0]["dps"]), dps), "plague_bloom: %.2f dps from the caster's spell power" % (float(zones[0]["dps"]) if zones.size() > 0 else -1.0))
	await secs(1.2)   # the spread, every 2 s: the corpse 4.5 m away seeds a child bloom
	zones = c.mem("plague_bloom").get("zones", [])
	check(field.count() == 0 and zones.size() == 2 and int(zones[1]["gen"]) == 1, "plague_bloom: the nearest corpse is consumed to seed a child bloom (%d flowers, %d corpses)" % [zones.size(), field.count()])


func t_legends() -> void:
	# Colossus Mantle: Bone Ward turned back at the attacker
	await reset_and_wait()
	var attacker := foe("robber", at(3.0))
	c._set_mods(_with(base_mods, {"wardReflect": 0.5}))
	var back := DmLegend.ward_reflect_damage(100.0, 0.4, 0.5)
	var m := dmg_log.size()
	c.legend_hurt(100.0, 0.4, attacker, 0.0)
	await ticks(2)
	check(back >= 1.0 and near(first_blow(attacker, m), back), "Colossus Mantle: %.2f of the blow goes back at the enemy that struck (%.2f)" % [back, first_blow(attacker, m)])
	# Requiem Wraiths: a corpse of yours consumed raises a healing wisp
	await reset_and_wait()
	c._set_mods(_with(base_mods, {"corpseWisp": 8.0}))
	corpse(at(4.0))
	var r := cast("exhume", at(4.0))
	await ticks(3)   # the consume event reaches the legend at the end of the tick
	check(c._legends != null and c._legends.wisps.size() == 1, "Requiem Wraiths: the corpse that rose as a thrall raised a wisp (%d)" % (c._legends.wisps.size() if c._legends != null else -1))
	# Requiem Wraiths 5: a Soul Harvest cast sets every wraith thrall off in a nova
	await reset_and_wait()
	c._set_mods(_with(base_mods, {"wraithNova": 2.0}))
	var exw := {"kind": "wraith", "cap": 5, "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"], "attackSpeedMult": 1.0}
	corpse(at(2.0))
	var rw: Dictionary = legion().raise(exw, at(2.0))
	await ticks(60)
	var wid := int((rw["thralls"] as Array)[0])
	var wp: Vector2 = legion().info(wid)["pos"]
	var near_wraith := foe("robber", Vector3(wp.x + 1.0, 0.0, wp.y))
	var nova_dmg := sp_now() * 2.0
	var hn := hit_log.size()
	c._legends.nova()
	var nh := hit_log.slice(hn).filter(func(x: Array) -> bool: return x[0] == "black_litany" and x[1] == near_wraith)
	check(legion().info(wid)["kind"] == "wraith" and nh.size() == 1 and near(float(nh[0][2]), nova_dmg), "Requiem Wraiths: the wraith's nova struck the enemy beside it for %.3f (spell power x the mod)" % (float(nh[0][2]) if nh.size() > 0 else -1.0))
	# Legion of the Unburied: the legion's burst fraction reaches the core
	await reset_and_wait()
	c._set_mods(_with(base_mods, {"thrallDeathBurst": 0.5}))
	var t := raise_at(at(1.5))
	check(near(float(legion().info(t)["death_burst_frac"]), 0.5), "Legion of the Unburied: a thrall raised later carries the burst fraction (%.2f)" % float(legion().info(t)["death_burst_frac"]))


func t_dot_credit() -> void:
	await reset_and_wait()
	var e := foe("robber", at(5.0), 0.5)   # 34 health
	c.apply_status(e, WITHERED, 3.0, -1.0, {"dps": 60.0, "cap": 5.0})
	await secs(0.8)   # the first lump, 0.35 s in, is 3 x 60 x 0.35
	var h := hits_of("miasma")
	check(h.size() >= 1 and h[h.size() - 1][1] == e and bool(h[h.size() - 1][4]), "Withered's kill is credited to the hero through the core's events (%s)" % str(h))
	check(not host.enemy_alive(e), "the enemy died of it")


# ------------------------------------------------------------------------------------------------------------------------ a click to attack

## Click an enemy beyond the needle's reach: the hero walks into range (today's DmCombatInput) and casts the primary until it dies; a ground click ends the chase.
func t_chase() -> void:
	await reset_and_wait()
	var e := foe("robber", at(15.0), 0.02)
	g.input.attack(e, false)
	var d0 := Vector2(hero.position.x - pos_of(e).x, hero.position.z - pos_of(e).z).length()
	await secs(4.0)
	var d1 := Vector2(hero.position.x - pos_of(e).x, hero.position.z - pos_of(e).z).length()
	check(d0 > 14.0 and d1 < d0 - 3.0, "click to attack: the hero walked into range (%.1f m to %.1f m)" % [d0, d1])
	check(not host.enemy_alive(e), "click to attack: and cast the primary until the enemy died")
	check(g.input.combat.target_id == 0, "click to attack: the target is forgotten with its death")


# ------------------------------------------------------------------------------------------------------------------------ a fight

## A wave of sixteen (level-14 robbers and hounds with four times the health) walks in from 8 to 12 m while a scripted player fights with the rites the way the kit is played: the primary on the nearest, Marrow Spear down the
## line, Miasma on the crowd, Exhume on a fresh corpse, Rally the Dead and Black Litany when it presses. The hero clears it; thralls are raised, rallied and sacrificed on the way.
func t_fight() -> void:
	await reset_and_wait()
	var wave: Array[int] = []
	for k in 16:
		var ang := TAU * float(k) / 16.0
		var dist := 9.0 + 4.0 * float(k % 3) / 2.0
		var p := origin + Vector3(cos(ang), 0.0, sin(ang)) * dist
		wave.append(host.spawn_enemy("robber" if k % 4 != 0 else "hound", p, 14, 4.0, 1.0, false, "graves", false))
	await ticks(2)
	var kills := [0]
	var died_conn := func(_id: int, _d: String, _l: int, _e: bool, _a: String, _s: int, _x: float, _z: float) -> void: kills[0] += 1
	host.enemy_died.connect(died_conn)
	var raised := [0]
	var raised_conn := func(_id: int, _k: String, _o: int, _s: int, _em: bool, _ch: bool, _x: float, _z: float, _y: float, _h: float) -> void: raised[0] += 1
	host.thrall_raised.connect(raised_conn)
	var sacrificed := [0]
	var sac_conn := func(_id: int, reason: String, _o: int, _k: String, _s: int, _x: float, _z: float) -> void:
		if reason == "sacrificed":
			sacrificed[0] += 1
	host.thrall_died.connect(sac_conn)
	var casts := {}
	var min_hp := float(c.p["hp"])
	var waited := 0
	var rites_used := {}
	while host.alive_count() > 0 and waited < 90 * 60 / 4 and bool(c.p["alive"]):
		await ticks(4)
		waited += 1
		min_hp = minf(min_hp, float(c.p["hp"]))
		var near_foes := host.foes_in_radius(hero.position, 14.0)
		if near_foes.is_empty():
			continue
		var tgt: DmFoe = near_foes[0]
		var best := INF
		for f in near_foes:
			var d := Vector2(f.x - hero.position.x, f.z - hero.position.z).length()
			if d < best:
				best = d
				tgt = f
		var press := host.foes_in_radius(hero.position, 6.0).size()
		var aim := tgt.pos()
		var did := ""
		if press >= 3 and legion().count() >= 2 and can_cast("black_litany"):
			did = "black_litany"
			c.request_cast("black_litany", hero.position)
		elif legion().count() > 0 and press >= 2 and can_cast("rally_dead"):
			did = "rally_dead"
			c.request_cast("rally_dead", aim)
		else:
			var cps := field.corpses_in_radius(hero.position, 9.0)
			if not cps.is_empty() and legion().count() < int(c.mods["thrallCap"]) and can_cast("exhume"):
				did = "exhume"
				c.request_cast("exhume", cps[0].x * Vector3.RIGHT + cps[0].z * Vector3.BACK)
			elif not cps.is_empty() and press >= 2 and can_cast("corpse_explosion"):
				did = "corpse_explosion"
				c.request_cast("corpse_explosion", cps[0].x * Vector3.RIGHT + cps[0].z * Vector3.BACK)
			elif press >= 3 and can_cast("miasma"):
				did = "miasma"
				c.request_cast("miasma", aim)
			elif can_cast("marrow_spear"):
				did = "marrow_spear"
				c.request_cast("marrow_spear", aim)
			elif can_cast("bone_needle") and best < 10.5:
				did = "bone_needle"
				c.request_cast("bone_needle", aim, tgt.id)
		if did != "":
			casts[did] = int(casts.get(did, 0)) + 1
			if rejected == "":
				rites_used[did] = true
			rejected = ""
	host.enemy_died.disconnect(died_conn)
	host.thrall_raised.disconnect(raised_conn)
	host.thrall_died.disconnect(sac_conn)
	print("INFO rites fight: %d kills in %.1f s, %d thralls raised, %d sacrificed, the hero's lowest health %.0f of %.0f, casts %s" % [kills[0], float(waited) * 4.0 / 60.0, raised[0], sacrificed[0], min_hp, float(c.p["stats"]["maxHp"]), str(casts)])
	check(host.alive_count() == 0 and kills[0] >= 16, "fight: the hero cleared the wave of 16 (%d killed, %d left)" % [kills[0], host.alive_count()])
	check(bool(c.p["alive"]), "fight: and lived")
	check(raised[0] >= 1, "fight: thralls rose from the corpses (%d)" % raised[0])
	check(rites_used.size() >= 4, "fight: %d different rites cast (%s)" % [rites_used.size(), str(rites_used.keys())])
	var stats: Dictionary = host.view.stats()
	check(not stats.is_empty(), "fight: the crowd drew the fight (%s)" % str(stats))


func can_cast(rite: String) -> bool:
	return DmAbilities.ready(c.p, rite, float(c.p["stats"]["level"]), c.now_ms)


# ------------------------------------------------------------------------------------------------------------------------ end

func finish() -> void:
	for rite in DmRiteRegistry.ids():
		check(int(cast_rites.get(rite, 0)) >= 1, "%s was cast at least once" % rite)
	check(cast_rites.size() == DmRiteRegistry.ids().size(), "all %d rites were cast (%d)" % [DmRiteRegistry.ids().size(), cast_rites.size()])
	g.queue_free()
	await ticks(5)
	await process_frame
	print("INFO rites: %d checks in %.0f s" % [checks, float(Time.get_ticks_msec() - t0_msec) / 1000.0])
	check(errlog.errors.is_empty(), "ZERO script errors or engine errors in the log (%d)" % errlog.errors.size())
	for e in errlog.errors:
		printerr("ERROR LOG: " + e)
	if fails == 0:
		print("PASS rites (%d checks)" % checks)
		quit(0)
	else:
		printerr("FAIL rites: %d of %d checks failed" % [fails, checks])
		quit(1)



# ------------------------------------------------------------------------------------------------------------------------ the disciplines

## The other three necromancers, each a real level-20 character of its discipline in a fresh game (not mods set on the Gravecaller): its own hero model, the
## signature on R, the thralls Exhume raises (kind, cap, health) and the discipline's rules through the ported paths, each against the Gravecaller's
## number and today's formula (DmCharacterBuild's mods, DmLegend, DmAbilities): the Ossuary's tougher hero, thralls and Bone Ward; the Mourner's faster essence
## and the heal from a corpse; the Rotweaver's tougher hero, wider Miasma that bursts corpses and Withered up to 8 stacks.
func t_disciplines() -> void:
	# the Gravecaller's numbers first, on the game the suite ran
	await reset_and_wait()
	var gc := {"max_hp": c.max_hp(), "thrall_hp": float(c.p["stats"]["thrallHp"]), "regen": _regen_rate(), "miasma_r": _miasma_radius()}
	gc["withered"] = await _withered_cap()
	for d in [[1, "ossuary"], [3, "mourner"], [4, "rotweaver"]]:
		await _play_as(int(d[0]))
		await ticks(2)   # the avatar is made a frame after the body enters the tree
		var disc: String = d[1]
		var mods: Dictionary = DmCharacterBuild.build({"class_index": float(d[0]), "level": 20}, [], {})["discipline"]["mods"]
		check(String(hero.discipline_id) == disc and hero.avatar != null and hero.avatar.c != null and String(hero.avatar.c.rig_slug) == String(hero.avatar.c.slug)
			and String(hero.avatar.c.slug).contains(disc), "%s: the hero is a %s in its own model (%s)" % [disc, disc, hero.avatar.c.slug if hero.avatar != null and hero.avatar.c != null else "none"])
		check(near(c.max_hp(), float(gc.max_hp) * float(mods["maxHpMult"]), 0.5), "%s: health %.0f = the Gravecaller's %.0f x %.2f" % [disc, c.max_hp(), float(gc.max_hp), float(mods["maxHpMult"])])
		check(near(_regen_rate(), float(gc.regen) * float(mods["essenceRegenMult"]), 0.01), "%s: essence %.2f a second = the Gravecaller's x %.2f" % [disc, _regen_rate(), float(mods["essenceRegenMult"])])
		check(near(float(c.p["stats"]["thrallHp"]), float(gc.thrall_hp) * float(mods["thrallHpMult"]), 0.5), "%s: thrall health %.0f = the Gravecaller's x %.1f" % [disc, float(c.p["stats"]["thrallHp"]), float(mods["thrallHpMult"])])
		# Exhume: the discipline's kind, up to its cap, at its health
		await reset_and_wait()
		var raised: Array = []
		for k in int(mods["thrallCap"]) + 1:
			var cp := corpse(at(3.0 + float(k), 1.5 * float(k % 2)))
			var r := cast("exhume", at(3.0 + float(k), 1.5 * float(k % 2)))
			if r["ok"]:
				raised.append(cp)
			await ticks(2)
		var ids := legion().list()
		check(ids.size() == int(mods["thrallCap"]), "%s: Exhume raises up to the cap of %d (%d)" % [disc, int(mods["thrallCap"]), ids.size()])
		var kinds_ok := true
		var hp_ok := true
		for tid in ids:
			var info: Dictionary = legion().info(tid)
			kinds_ok = kinds_ok and String(info["kind"]) == String(mods["thrallKind"])
			hp_ok = hp_ok and near(float(info["max_hp"]), float(c.p["stats"]["thrallHp"]), 0.5)
		check(kinds_ok and hp_ok, "%s: every thrall is a %s at its health" % [disc, mods["thrallKind"]])
		# the signature on R
		var sig := g.rite_for_slot(6)
		check(sig == DmRiteHotbar.rite_for_slot(6, "necromancer", disc) and DmRiteRegistry.has(sig), "%s: R is its signature %s" % [disc, sig])
		var target := foe("robber", at(5.0))
		corpse(at(4.0))
		var rs := cast(sig, at(5.0), target)
		check(bool(rs["ok"]) or String(rs["reason"]) not in ["unavailable", ""], "%s: the signature %s casts (or says why: %s)" % [disc, sig, rs["reason"]])
		match disc:
			"ossuary":   # Bone Ward: 10 % less damage a living thrall, capped
				await reset_and_wait()
				hero.restore_vitals()
				var bare := hero.take_damage(100.0, 0, "melee")
				hero.restore_vitals()
				for k in int(mods["thrallCap"]):
					raise_at(at(2.0 + float(k)))
				var n := legion().count()
				var warded := hero.take_damage(100.0, 0, "melee")
				var want := DmLegend.damage_taken_mult(float(mods["wardPerThrall"]) * float(n), 0.0) / DmLegend.damage_taken_mult(0.0, 0.0)
				check(n > 0 and near(warded / maxf(bare, 0.001), want, 0.01), "ossuary: Bone Ward: with %d thralls a blow lands at %.0f %% (%.1f of %.1f)" % [n, 100.0 * want, warded, bare])
			"mourner":   # a corpse heals: Grave Offering's heal + corpseHeal
				await reset_and_wait()
				corpse(at(5.0))
				c.p["hp"] = c.max_hp() * 0.5
				var G: Dictionary = DmSimData.GRAVE_OFFERING
				var hp0 := float(c.p["hp"])
				var ro := cast("grave_offering", at(5.0))
				await secs(0.6)
				check(bool(ro["ok"]) and float(c.p["hp"]) >= hp0 + c.max_hp() * (float(G["healFrac"]) + float(mods["corpseHeal"])) - 0.01, "mourner: a corpse heals %.0f %% (healFrac + corpseHeal)" % (100.0 * (float(G["healFrac"]) + float(mods["corpseHeal"]))))
			"rotweaver":   # a wider Miasma that bursts corpses, Withered up to 8
				check(near(_miasma_radius(), float(gc.miasma_r) * float(mods["miasmaRadiusMult"]), 0.02), "rotweaver: Miasma's radius %.2f = the Gravecaller's x %.1f" % [_miasma_radius(), float(mods["miasmaRadiusMult"])])
				var wc: int = await _withered_cap()
				check(wc == int(DmLegend.effective_withered_cap(mods)) and wc > int(gc.withered), "rotweaver: Withered stacks up to %d (the Gravecaller %d)" % [wc, int(gc.withered)])
				await reset_and_wait()
				var cp := corpse(at(7.0, 0.5))
				var mr := cast("miasma", at(7.0))
				await secs(1.5)
				check(bool(mr["ok"]) and field.get_corpse(cp) == null, "rotweaver: Miasma bursts the corpse in its cloud")


## A fresh game with a level-20 hero of class `cls`, the suite's globals pointed at it.
func _play_as(cls: int) -> void:
	var ch := await api_.load_or_create_character(cls)
	DmDevMock.set_level(mock_, ch.data, 20)
	g.process_mode = Node.PROCESS_MODE_DISABLED
	await g.leave()
	g.queue_free()
	await process_frame
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api_, {"areas": ["graves"], "offline": true, "name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "baked_dir": OUT})
	host = g.core_host
	core = host.core
	hero = g.local_body()
	c = hero.get_node("Rites") as DmRiteCaster
	field = host.corpses
	origin = hero.position
	base_mods = c.mods.duplicate(true)
	c.random = func() -> float: return 0.5
	_wire()
	find_arena()


## Essence a second from the necromancer's passive with these stats (DmResources).
func _regen_rate() -> float:
	return DmResources.passive("necromancer", {"stats": c.p["stats"], "value": 0.0, "max": c.p["resource"]["max"], "sinceHurtMs": 1e9, "sinceResourceGainMs": 1e9})


## The radius of a Miasma cast now (DmAbilities.miasma with the hero's mods).
func _miasma_radius() -> float:
	var aim := at(7.0)
	return float(DmAbilities.miasma(sp_now(), c.mods, "", 1.0, {"x": c.p["x"], "z": c.p["z"]}, {"x": aim.x, "z": aim.z})["r"])


## The most Withered stacks this hero's Miasma puts on one enemy: two clouds over it (a stack a pulse each; one cloud's six pulses would not reach a cap of 8),
## so the cap is what stops the count.
func _withered_cap() -> int:
	await reset_and_wait()
	var id := foe("robber", at(7.0))
	var r := cast("miasma", at(7.0))
	if not r["ok"]:
		return -1
	await secs(1.0)
	cast("miasma", at(7.0))
	var most := 0
	for k in 20:
		await secs(0.5)
		most = maxi(most, stacks_of(id, WITHERED))
	return most


# ------------------------------------------------------------------------------------------------------------------------ the Reaper

## The Reaper (class 11), a real level-20 character in a fresh game, replaying the first game's archive/old-game:godot/tests/rites/reaper_part.gd on core enemies: the class (her model,
## the soul bag, the kit on the hotbar, more health, less damage taken, the scythe gestures), the nine rites (who is struck, the damage with the bag's and the
## spent souls' bonuses, souls paid and refused, the life steal), Unleash Souls' wisps, Soul Harbinger's Raiment, a kill banking a soul and the easy
## auto-combat's pick. Numbers come from the REAPER constants and DmAbilities.
func t_reaper() -> void:
	await _play_as(REAPER)
	await ticks(2)   # the avatar is made a frame after the body enters the tree
	await _reaper_class()
	await _reaper_swings()
	await _reaper_spenders()
	await _reaper_walk()
	await _reaper_unleash()
	await _reaper_raiment()
	await _reaper_undeath()
	await _reaper_auto()


## Everything reset, the hero `along` metres down the arena with a full bag, no Soul Harvest mark, and in combat for good (only the in-combat trickle of
## health regenerates, so a heal shows).
func reaper_reset(along := 0.0) -> void:
	await reset_and_wait()
	hero.teleport(at(along))
	c.p["souls"] = int(c.p["soulsMax"])
	c.p["harvestAmp"] = false
	c.p.erase("weaveStroke")
	c.p["lastHurtAt"] = 1.0e12


## The events rite `rite` played with type `t`.
func evs(rite: String, t: String) -> Array:
	return ev_log.filter(func(ev: Dictionary) -> bool: return String(ev.get("rite", "")) == rite and String(ev.get("t", "")) == t)


## All the damage the core dealt enemy `id` since `mark`.
func taken(id: int, mark := 0) -> float:
	var sum := 0.0
	for i in range(mark, dmg_log.size()):
		if int(dmg_log[i][0]) == id:
			sum += float(dmg_log[i][2])
	return sum


func souls() -> int:
	return int(c.p["souls"])


func _reaper_class() -> void:
	var K := DmReaperRites.k()
	check(String(hero.discipline_id) == "reaper" and hero.family == "reaper" and c.p["family"] == "reaper" and c.p["resource"]["kind"] == "reaper", "reaper: the hero is a Reaper (her family and resource)")
	var slug := String(hero.avatar.c.slug) if hero.avatar != null and hero.avatar.c != null else "none"
	check(slug.contains("reaper"), "reaper: she is in her own model (%s)" % slug)
	check(souls() == int(K["soulsStart"]) and int(c.p["soulsMax"]) == int(K["soulBagMax"]), "reaper: she starts with %d souls in a bag of %d (%d of %d)" % [int(K["soulsStart"]), int(K["soulBagMax"]), souls(), int(c.p["soulsMax"])])
	var want := ["scythe_sweep", "scythe_throw", "reap", "wraith_walk", "soul_burst", "harvest_spin", "unleash_souls"]
	for i in want.size():
		check(g.rite_for_slot(i) == want[i] and DmRiteRegistry.has(want[i]), "reaper: slot %d is %s (%s)" % [i, want[i], g.rite_for_slot(i)])
	var bare: Dictionary = DmCharacterBuild.build({"class_index": float(REAPER), "level": 20}, [], {})["stats"]
	var mourner: Dictionary = DmCharacterBuild.build({"class_index": 3.0, "level": 20}, [], {})["stats"]
	check(near(float(bare["maxHp"]) / float(mourner["maxHp"]), 1.3, 0.02), "reaper: 30 %% more health than a Mourner (%.0f against %.0f, nothing worn)" % [float(bare["maxHp"]), float(mourner["maxHp"])])
	var mine_hp := float(g.build_for(g.session.get_my_id())["stats"]["maxHp"])
	check(near(c.max_hp(), mine_hp), "reaper: the hero's health is her build's (%.0f of %.0f)" % [c.max_hp(), mine_hp])
	await reset_and_wait()
	var mine := hero.take_damage(100.0, 0, "melee")
	var necro := DmPlayerRules.take_damage(DmPlayerRules.new_state(c.p["stats"], "necromancer"), 100.0, 0.0, 1000.0)
	check(near(mine, necro * float(K["damageTakenMult"]), 1e-4), "reaper: she takes %.0f %% of a blow (%.1f against a necromancer's %.1f)" % [100.0 * float(K["damageTakenMult"]), mine, necro])
	check(hero.avatar != null and hero.avatar.weapon_gesture() == "scythe", "reaper: she gestures with the scythe")
	var sc := DmGearProps.scythe_model()   # the asset list once left it out: her hand was empty in the test build (2026-10-17)
	check(sc != null and hero.avatar != null and hero.avatar.get("_staff") != null, "reaper: she holds today's scythe model (%s is in the build)" % DmGearProps.SCYTHE_FILE)
	if sc != null:
		sc.free()
	var no_clip: Array = []
	for rite: String in DmAvatar.REAPER_CLIPS:
		if hero.avatar == null or hero.avatar._cast_clip_for("scythe", rite) == null:
			no_clip.append(rite)
	check(no_clip.is_empty(), "reaper: every rite plays its scythe clip on her rig (not: %s)" % str(no_clip))
	# the bag on the HUD, a key through the hotbar, a kill banking a soul
	await reaper_reset()
	g.input.cast_at(1, at(8.0), 0, true)
	check(rejected == "" and souls() == int(K["soulBagMax"]) - DmAbilities.soul_cost(c.p, "scythe_throw"), "reaper: key 1 throws the scythe through the hotbar and pays its souls (%s, %d left)" % [rejected, souls()])
	var st := c.get_state()
	check(int(st.get("souls", -1)) == souls() and int(st.get("soulsMax", -1)) == int(K["soulBagMax"]), "reaper: the HUD's state carries the bag (%s)" % str(st.get("souls")))
	var hs: Dictionary = g.ui_host.hud_state()
	check(int(hs["essence"]) == souls() and int(hs["max_essence"]) == int(K["soulBagMax"]), "reaper: her orb on the HUD is the soul bag (%s of %s)" % [str(hs["essence"]), str(hs["max_essence"])])
	await reaper_reset(8.0)
	c.p["souls"] = 5
	var weak := foe("robber", at(10.0), 0.01)
	cast("scythe_sweep", at(14.0))
	await ticks(3)
	check(core.enemy_info(weak).is_empty() or float(core.enemy_info(weak)["hp"]) <= 0.0, "reaper: the sweep kills the weak robber")
	for _i in 900:   # the soul is banked when its wisp reaches her
		if souls() >= 6:
			break
		await g.get_tree().process_frame
	check(souls() == 6, "reaper: the kill banks one soul in her bag (%d)" % souls())


## The free swings: Scythe Sweep, Scythe Weave, Harvest Spin, and the life steal of a swing.
func _reaper_swings() -> void:
	var K := DmReaperRites.k()
	await reaper_reset(8.0)
	var front := foe("robber", at(10.5))
	var behind := foe("robber", at(5.5))
	var wide := foe("robber", at(8.4, 2.9))   # 82 degrees off the aim: outside the sweep's half angle
	var s0 := souls()
	var dmg := DmAbilities.rite_damage(sp_now(), "scythe_sweep")
	var m := dmg_log.size()
	if accepted(cast("scythe_sweep", at(14.0)), "scythe_sweep"):
		await ticks(2)   # the core reports its blows on its next tick
		check(near(first_blow(front, m), dmg) and blows(behind, m) == 0 and blows(wide, m) == 0, "sweep: hits the enemy in front (%.1f of %.1f), not the one behind or off to the side" % [first_blow(front, m), dmg])
		check(souls() == s0 - DmAbilities.soul_cost(c.p, "scythe_sweep"), "sweep: pays its %d souls" % DmAbilities.soul_cost(c.p, "scythe_sweep"))
	c.p["souls"] = 0
	var sweep_free := DmAbilities.soul_cost(c.p, "scythe_sweep") == 0
	check(bool(cast("scythe_sweep", at(14.0))["ok"]) == sweep_free, "sweep: with an empty bag it %s (its cost from the data)" % ("swings" if sweep_free else "is refused"))
	check(evs("scythe_sweep", "sweep").size() == (2 if sweep_free else 1), "sweep: one event a swing")
	var r := cast("scythe_sweep", hero.position)
	check(not r["ok"] and r["reason"] == "no_target", "sweep: refused with the cursor on her (%s)" % r["reason"])
	await ticks(2)   # the last swing's blow reported
	# Harvest Spin: the full circle, 2 souls
	c.p["souls"] = 30
	m = dmg_log.size()
	if accepted(cast("harvest_spin", at(14.0)), "harvest_spin"):
		await ticks(2)
		check(blows(front, m) == 1 and blows(behind, m) == 1 and blows(wide, m) == 1, "spin: hits all round her, behind too (%d %d %d blows)" % [blows(front, m), blows(behind, m), blows(wide, m)])
		check(souls() == 30 - DmAbilities.soul_cost(c.p, "harvest_spin"), "spin: pays %d souls (%d left)" % [DmAbilities.soul_cost(c.p, "harvest_spin"), souls()])
	# Scythe Weave: the nearest enemy in the narrow cone only, the strokes alternate, free
	var front2 := foe("robber", at(11.3))   # farther along the same line
	c.p["souls"] = 12
	var wd := DmAbilities.rite_damage(sp_now(), "scythe_weave")
	m = dmg_log.size()
	if accepted(cast("scythe_weave", at(14.0)), "scythe_weave"):
		await ticks(2)
		check(near(first_blow(front, m), wd) and blows(front, m) == 1 and blows(front2, m) + blows(wide, m) + blows(behind, m) == 0, "weave: one blow (%.1f) to the nearest enemy in front, nobody else" % wd)
		check(int(c.p["weaveStroke"]) == 0, "weave: the first stroke is the overhead chop")
	cast("scythe_weave", at(14.0))
	await ticks(2)
	check(int(c.p["weaveStroke"]) == 1 and blows(front, m) == 2, "weave: the next press is the rising cut and hits again")
	check(souls() == 12 - 2 * DmAbilities.soul_cost(c.p, "scythe_weave") and evs("scythe_weave", "weave").size() == 2, "weave: pays its %d souls a stroke, one event a stroke" % DmAbilities.soul_cost(c.p, "scythe_weave"))
	r = cast("scythe_weave", hero.position)
	check(not r["ok"] and r["reason"] == "no_target", "weave: refused with the cursor on her (%s)" % r["reason"])
	# Haunting Wraith: its souls and cooldown from the data; walks toward the cursor and hurts what it passes through every quarter second
	await reaper_reset()
	var hw_in := foe("robber", at(6.0))
	var hw_out := foe("robber", at(6.0, 9.0))
	c.p["souls"] = 12
	m = dmg_log.size()
	if accepted(cast("haunting_wraith", at(14.0)), "haunting_wraith"):
		var hw_cd := float(DmAbilities.def("haunting_wraith")["cooldownMs"])
		check(souls() == 12 - DmAbilities.soul_cost(c.p, "haunting_wraith") and (c.cooldown_left("haunting_wraith") > 0.0) == (hw_cd > 0.0),
			"wraith: pays its %d souls (%d left), and goes on cooldown only when its data has one (%.0f ms)" % [DmAbilities.soul_cost(c.p, "haunting_wraith"), souls(), hw_cd])
		await secs(2.5)
		check(blows(hw_in, m) >= 2 and blows(hw_out, m) == 0, "wraith: hurts the enemy in its path more than once, not the one off to the side (%d, %d)" % [blows(hw_in, m), blows(hw_out, m)])
		check(evs("haunting_wraith", "rise").size() == 1 and evs("haunting_wraith", "walk").size() >= 2, "wraith: one rise event, then one event each step")
		var s_before := souls()
		check(accepted(cast("haunting_wraith", at(14.0)), "haunting_wraith") and souls() == s_before - 5, "wraith: cast again at once while there are souls to spend (%d of %d left)" % [souls(), s_before])
	r = cast("haunting_wraith", hero.position)
	check(not r["ok"] and r["reason"] != "", "wraith: refused with the cursor on her (%s)" % r["reason"])
	# life steal: each enemy a swing strikes heals leechPerHit of her health, at most leechSwingCap a swing; the thrown scythe heals nothing
	await reaper_reset(8.0)
	var mx := c.max_hp()
	foe("robber", at(10.5))
	c.p["hp"] = mx * 0.5
	cast("scythe_sweep", at(14.0))
	check(near(float(c.p["hp"]), mx * (0.5 + float(K["leechPerHit"]))), "leech: one enemy struck heals %.1f %% (%.1f of %.1f)" % [100.0 * float(K["leechPerHit"]), float(c.p["hp"]), mx])
	for i in 6:
		foe("robber", at(8.0 + 1.5 * cos(float(i)), 1.5 * sin(float(i))))
	c.p["hp"] = mx * 0.5
	cast("harvest_spin", at(14.0))
	check(near(float(c.p["hp"]), mx * (0.5 + float(K["leechSwingCap"]))), "leech: a spin through seven heals the %.0f %% cap (%.1f)" % [100.0 * float(K["leechSwingCap"]), float(c.p["hp"])])
	await reaper_reset()
	var t1 := foe("robber", at(9.0))
	c.p["hp"] = mx * 0.5
	cast("scythe_throw", at(9.0))
	await secs(2.6)
	var gain := float(c.p["hp"]) - mx * 0.5
	check(blows(t1) > 0 and gain < mx * float(K["leechPerHit"]), "leech: the thrown scythe cuts but heals nothing (%.1f back: the in-combat regeneration)" % gain)


## The rites that pay souls: Soul Harvest (fills the bag), Reap, Soul Burst, Scythe Throw; every rite but the swings refused one soul short.
func _reaper_spenders() -> void:
	var K := DmReaperRites.k()
	var mx := c.max_hp()
	# Soul Harvest: 9 m all round, a soul and a little health for each enemy struck, free; marks her next spell
	await reaper_reset()
	var a := foe("robber", at(2.5))
	var b := foe("robber", at(5.0, 2.0))
	var far := foe("robber", at(8.0))
	var out := foe("robber", at(14.0))
	c.p["souls"] = 0
	c.p["hp"] = 1.0
	var m := dmg_log.size()
	if accepted(cast("soul_harvest", hero.position), "soul_harvest"):
		check(souls() == 3, "harvest: one soul for each of the three struck (%d)" % souls())
		check(near(float(c.p["hp"]), 1.0 + mx * minf(3.0 * float(K["harvestHealPerMob"]), float(K["harvestHealCap"]))), "harvest: heals %.0f %% of her health for each (%.1f)" % [100.0 * float(K["harvestHealPerMob"]), float(c.p["hp"])])
		await ticks(2)
		check(blows(a, m) + blows(b, m) + blows(far, m) == 3 and blows(out, m) == 0, "harvest: reaches the enemy 8 m away, not the one at 14 m")
		check(evs("soul_harvest", "harvest").size() == 1 and bool(c.p.get("harvestAmp", false)), "harvest: one event, and her next spell is marked")
		var amped := sp_now()
		c.p["harvestAmp"] = false
		check(near(amped, float(K["harvestNextMult"]) * sp_now()), "harvest: the mark doubles her spell power")
		c.p["harvestAmp"] = true
	# Reap: the cone, 5 souls, every soul paid adds reapPerSoul
	var cost := DmAbilities.soul_cost(c.p, "reap")
	var r1 := foe("robber", at(5.0, 0.5))
	c.p["souls"] = cost - 1
	m = dmg_log.size()
	var r := cast("reap", at(8.0))
	await ticks(2)
	check(not r["ok"] and r["reason"] == "souls" and souls() == cost - 1 and blows(r1, m) == 0, "reap: refused one soul short, nothing spent (%s)" % r["reason"])
	c.p["souls"] = 0
	var sp_empty := sp_now()   # the bag once the price is paid, doubled by the Soul Harvest mark
	c.p["souls"] = cost
	m = dmg_log.size()
	if accepted(cast("reap", at(8.0)), "reap"):
		await ticks(2)
		var want := DmAbilities.rite_damage(sp_empty, "reap") * (1.0 + float(K["reapPerSoul"]) * float(cost))
		check(souls() == 0 and near(first_blow(r1, m), want), "reap: %d souls pay for it and add %.0f %% (%.1f of %.1f, doubled by Soul Harvest)" % [cost, 100.0 * float(K["reapPerSoul"]) * float(cost), first_blow(r1, m), want])
		check(not bool(c.p.get("harvestAmp", false)), "reap: the doubled spell spends the mark")
	c.p["souls"] = cost
	var sp_five := sp_now()
	c.p["souls"] = 2 * cost
	m = dmg_log.size()
	cast("reap", at(8.0))
	await ticks(2)
	check(souls() == cost and near(first_blow(r1, m), DmAbilities.rite_damage(sp_five, "reap") * (1.0 + float(K["reapPerSoul"]) * float(cost))), "reap: a fuller bag hits harder (%.1f), %d souls left" % [first_blow(r1, m), souls()])
	# Soul Burst: needs 6, empties the bag, burstPerSoul for every soul
	await reaper_reset()
	cost = DmAbilities.soul_cost(c.p, "soul_burst")
	var rb := foe("robber", at(5.5))
	c.p["souls"] = cost - 1
	r = cast("soul_burst", hero.position)
	await ticks(2)
	check(not r["ok"] and r["reason"] == "souls" and souls() == cost - 1 and blows(rb) == 0, "burst: refused one soul short (%s)" % r["reason"])
	c.p["souls"] = 1
	var sp1 := sp_now()   # one soul left once the price is paid
	c.p["souls"] = cost + 1
	m = dmg_log.size()
	if accepted(cast("soul_burst", hero.position), "soul_burst"):
		await ticks(2)
		var want := DmAbilities.rite_damage(sp1, "soul_burst") * (1.0 + float(K["burstPerSoul"]) * float(cost + 1))
		check(souls() == 0 and near(first_blow(rb, m), want), "burst: empties the bag, %d souls add %.0f %% (%.1f of %.1f), 5.5 m out" % [cost + 1, 100.0 * float(K["burstPerSoul"]) * float(cost + 1), first_blow(rb, m), want])
	# Scythe Throw: spins where it lands, a cut every throwTickS for throwLifeS, inside its radius only; an aim past 12 m lands at 12 m
	await reaper_reset()
	var inside := foe("robber", at(9.0, 1.5))
	var outside := foe("robber", at(14.0))
	if accepted(cast("scythe_throw", at(9.0)), "scythe_throw"):
		check(souls() == int(c.p["soulsMax"]) - DmAbilities.soul_cost(c.p, "scythe_throw"), "throw: pays %d souls" % DmAbilities.soul_cost(c.p, "scythe_throw"))
	await secs(2.6)
	var n := evs("scythe_throw", "tick").size()
	var want_n := int(float(K["throwLifeS"]) / float(K["throwTickS"]))
	check(n >= want_n - 1 and n <= want_n, "throw: about %d cuts over %.0f s (%d)" % [want_n, float(K["throwLifeS"]), n])
	check(blows(inside) > 0 and blows(outside) == 0, "throw: cuts the enemy inside the ring, not the one outside")
	var after := blows(inside)
	await secs(1.0)
	check(blows(inside) == after, "throw: the scythe is gone after %.0f s" % float(K["throwLifeS"]))
	ev_log.clear()
	cast("scythe_throw", at(40.0))
	var te := evs("scythe_throw", "throw")
	var land := Vector2(float(te[0]["x"]) - hero.position.x, float(te[0]["z"]) - hero.position.z).length() if te.size() == 1 else -1.0
	check(near(land, float(DmAbilities.def("scythe_throw")["range"]), 1e-3), "throw: an aim past 12 m lands at 12 m (%.2f)" % land)
	# every rite that pays souls is refused one short, and her energy plays no part
	var short: Array = []
	for rite in ["scythe_throw", "reap", "wraith_walk", "soul_burst", "harvest_spin", "unleash_souls"]:
		c.p["souls"] = DmAbilities.soul_cost(c.p, rite) - 1
		c.p["resource"]["value"] = float(c.p["resource"]["max"])
		r = cast(rite, at(8.0))
		if r["ok"] or r["reason"] != "souls" or souls() != DmAbilities.soul_cost(c.p, rite) - 1:
			short.append(rite)
	check(short.is_empty(), "every rite that pays souls is refused one short, energy or not (not: %s)" % str(short))
	c.p["souls"] = 0
	c.p["resource"]["value"] = 0.0
	check(bool(cast("scythe_sweep", at(8.0))["ok"]), "sweep: needs neither energy nor souls")


## Wraith Walk: the rush (untouchable, at most 9 m, the body glides), the green flame on the lane, 4 souls.
func _reaper_walk() -> void:
	var K := DmReaperRites.k()
	await reaper_reset()
	var la := foe("robber", at(4.0, 0.5))
	var lb := foe("robber", at(7.0, -1.0))
	var off := foe("robber", at(4.0, 2.9))
	var cost := DmAbilities.soul_cost(c.p, "wraith_walk")
	c.p["souls"] = cost
	var dps := DmAbilities.rite_damage(sp_now(), "wraith_walk") * (1.0 + float(K["wraithPerSoul"]) * float(cost))   # the bag once the price is paid
	c.p["souls"] = 2 * cost
	var m := dmg_log.size()
	var r := cast("wraith_walk", at(20.0))
	if not accepted(r, "wraith_walk"):
		return
	check(near(float(c.p["phasedUntil"]), float(r["now"]) + float(K["wraithDashS"]) * 1000.0) and hero.take_damage(100.0, 0, "melee") == 0.0, "walk: untouchable for the %.2f s rush" % float(K["wraithDashS"]))
	var we := evs("wraith_walk", "walk")
	var dash := Vector2(float(we[0]["tx"]) - float(we[0]["fx"]), float(we[0]["tz"]) - float(we[0]["fz"])).length() if we.size() == 1 else -1.0
	check(we.size() == 1 and dash > 0.0 and dash <= float(DmAbilities.def("wraith_walk")["range"]) + 0.01 and hero.dashing, "walk: one event, a dash of %.1f m (at most 9), the body glides" % dash)
	check(souls() == cost, "walk: pays %d souls (%d left)" % [cost, souls()])
	var fa := status_of(la, &"wraithfire")
	check(not fa.is_empty() and close(float(fa["left"]), float(K["wraithCurseS"]), 0.15) and not status_of(lb, &"wraithfire").is_empty(), "walk: both enemies in the lane burn for %.0f s (%s)" % [float(K["wraithCurseS"]), str(fa)])
	check(status_of(off, &"wraithfire").is_empty(), "walk: the one off the lane does not")
	await secs(float(K["wraithCurseS"]) + 0.5)
	check(taken(la, m) > 0.0 and taken(lb, m) > 0.0 and blows(off, m) == 0, "walk: the green flame burns as a damage over time, the one off the lane untouched")
	check(close(taken(la, m), dps * float(K["wraithCurseS"]), dps * 0.6), "walk: the flame deals its %.1f a second for %.0f s (%.1f of %.1f)" % [dps, float(K["wraithCurseS"]), taken(la, m), dps * float(K["wraithCurseS"])])
	var credited := true
	for i in range(m, dmg_log.size()):
		if int(dmg_log[i][0]) == la and int(dmg_log[i][1]) != hero.core_id:
			credited = false
	check(credited, "walk: every burn is credited to her")
	r = cast("wraith_walk", hero.position)
	check(not r["ok"] and r["reason"] == "no_target", "walk: the cursor on her makes no dash (%s)" % r["reason"])


## Unleash Souls: the whole bag as wisps that fly out in a ring, circle her with nothing to hunt, then share out the enemies.
func _reaper_unleash() -> void:
	await reaper_reset()
	c.p["souls"] = 0
	var r := cast("unleash_souls", hero.position)
	check(not r["ok"] and r["reason"] == "souls", "unleash: refused with an empty bag (%s)" % r["reason"])
	c.p["souls"] = 7
	var sp7 := sp_now()   # seven left once the price is paid
	c.p["souls"] = 8
	if not accepted(cast("unleash_souls", hero.position), "unleash_souls"):
		return
	var wisps: Array = c.mem("unleash_souls")["wisps"]
	check(souls() == 0 and wisps.size() == 8 and evs("unleash_souls", "release").size() == 1, "unleash: all 8 souls leave the bag as wisps, one release event")
	await secs(2.0)
	check(wisps.size() == 8 and evs("unleash_souls", "hit").is_empty(), "unleash: with no enemies the 8 wisps circle her and strike nothing")
	var f := foe("robber", at(9.0))
	var m := dmg_log.size()
	await secs(2.0)
	var expect := 8.0 * DmAbilities.rite_damage(sp7, "unleash_souls")
	check(wisps.is_empty() and near(taken(f, m), expect, 1e-4), "unleash: an enemy shows up and every wisp finds it (%.1f of %.1f)" % [taken(f, m), expect])
	check(not evs("unleash_souls", "hit").is_empty() and not evs("unleash_souls", "end").is_empty(), "unleash: hit and end events were played")
	await reaper_reset(9.0)
	c.p["souls"] = 6
	var ahead := foe("robber", at(13.0))
	var back := foe("robber", at(0.0))
	cast("unleash_souls", hero.position)
	var ring: Array = c.mem("unleash_souls")["wisps"]
	await secs(0.3)
	check(ring.size() == 6 and blows(ahead) + blows(back) == 0, "unleash: the wisps fly outward first, nothing is struck yet")
	await secs(3.0)
	check(blows(ahead) > 0 and blows(back) > 0 and ring.is_empty(), "unleash: the wisps share out both enemies (%d / %d blows)" % [blows(ahead), blows(back)])


## Soul Harbinger's Raiment (DmReaperSet): 2 pieces double the throw's radius, 4 turn the wisps' damage into a shield, 5 leave scythes where the souls land.
func _reaper_raiment() -> void:
	var mods_of := func(n: int) -> Dictionary:
		var slots: Array = []
		for i in n:
			var part: String = DmReaperSet.PARTS[i]
			slots.append({"slot_index": i, "equipped": true, "item_id": DmReaperSet.item_id(part), "item_type": "armor_" + part})
		return DmCharacterBuild.build({"class_index": float(REAPER), "level": 20}, slots, {})["discipline"]["mods"]
	var m1: Dictionary = mods_of.call(1)
	var m2: Dictionary = mods_of.call(2)
	var m4: Dictionary = mods_of.call(4)
	var m5: Dictionary = mods_of.call(5)
	check(not m1.has("scytheRadiusMult") and float(m2.get("scytheRadiusMult", 0.0)) == DmReaperSet.SCYTHE_RADIUS_MULT and not m2.has("soulShield") and bool(m4.get("soulShield", false)) and not m4.has("soulScythes")
		and int(m5.get("soulScythes", 0)) == DmReaperSet.MAX_SCYTHES, "raiment: 2 pieces widen the throw, 4 add the shield, 5 the scythes (one piece nothing)")
	await reaper_reset()
	cast("scythe_throw", at(5.0))
	var base_r := float(evs("scythe_throw", "throw")[0]["r"])
	var mods := base_mods.duplicate(true)
	mods["scytheRadiusMult"] = 2.0
	c._set_mods(mods)
	cast("scythe_throw", at(5.0))
	var thr := evs("scythe_throw", "throw")
	check(thr.size() == 2 and near(float(thr[1]["r"]), base_r * 2.0), "raiment: the thrown scythe's radius doubles (%.1f -> %.1f)" % [base_r, float(thr[-1]["r"])])
	c.mem("scythe_throw")["spins"].clear()
	# the shield: what the wisps dealt, refreshed (not stacked) by the next release
	var f := foe("robber", at(6.0))
	mods["soulShield"] = true
	c._set_mods(mods)
	c.p["barrier"] = 0.0
	c.p["souls"] = 4
	var sp4 := sp_now()   # four left once the price is paid
	c.p["souls"] = 5
	var m := dmg_log.size()
	cast("unleash_souls", hero.position)
	await secs(3.0)
	var total := 5.0 * DmAbilities.rite_damage(sp4, "unleash_souls")
	var shield1 := float(c.p["barrier"])
	check(shield1 > 0.0 and close(taken(f, m), total, 0.01) and shield1 <= total + 0.01, "raiment: the shield is what the souls dealt (%.1f of %.1f)" % [shield1, total])
	c.p["souls"] = 5
	cast("unleash_souls", hero.position)
	check(float(c.p["barrier"]) < shield1 * 0.01 + 0.01, "raiment: a new release takes the old shield back first (%.1f)" % float(c.p["barrier"]))
	await secs(3.0)
	check(float(c.p["barrier"]) > 0.0 and float(c.p["barrier"]) <= total + 0.01, "raiment: the second shield refreshes, it does not stack (%.1f)" % float(c.p["barrier"]))
	# the scythes: one a landed soul, at most the cap, each a full Scythe Throw
	mods["soulShield"] = false
	mods["soulScythes"] = 3.0
	c._set_mods(mods)
	c.p["souls"] = 8
	cast("unleash_souls", hero.position)
	await secs(1.6)
	var radii: Array = []
	for sp: Dictionary in c.mem("scythe_throw").get("spins", []):
		if bool(sp.get("soul", false)):
			radii.append(float(sp["r"]))
	check(radii.size() == 3 and radii.all(func(x: float) -> bool: return near(x, base_r * 2.0)), "raiment: 8 landed souls leave the capped 3 scythes, doubled by the 2-piece bonus (%s)" % str(radii))
	c._set_mods(base_mods)


## The Scythe of Undeath (DmUndeathScythe): its mods only while it is in her hand, three wraiths in a cone, more damage and less damage taken for each soul, and a free Wraith
## from a soul earned with a full bag.
func _reaper_undeath() -> void:
	var mods_with := func(item_id: String) -> Dictionary:
		var slots: Array = [] if item_id == "" else [{"slot_index": 0, "equipped": true, "item_id": item_id, "item_type": "weapon"}]
		return DmCharacterBuild.build({"class_index": float(REAPER), "level": 20}, slots, {})["discipline"]["mods"]
	var worn: Dictionary = mods_with.call(DmUndeathScythe.ITEM_ID)
	var keys := ["wraithCount", "wraithSpreadDeg", "soulMight", "soulWard", "soulWraith"]
	var other: Dictionary = mods_with.call("scythe_iron")
	var bare: Dictionary = mods_with.call("")
	check(keys.all(func(k: String) -> bool: return worn.has(k) and not other.has(k) and not bare.has(k)), "undeath: its five mods come with the scythe in her hand and with nothing else")
	var mods := base_mods.duplicate(true)
	for k: String in keys:
		mods[k] = worn[k]
	# damage and defense for each soul
	await reaper_reset()
	var per := float(DmReaperRites.k()["damagePerSoul"])
	c.p["souls"] = 10
	var sp0 := sp_now()
	c._set_mods(mods)
	check(near(sp_now() / sp0, (1.0 + (per + DmUndeathScythe.MIGHT_PER_SOUL) * 10.0) / (1.0 + per * 10.0)), "undeath: each soul adds %.0f %% more rite damage on top of the bag's" % (100.0 * DmUndeathScythe.MIGHT_PER_SOUL))
	c.p["hp"] = c.max_hp()
	var hit10 := hero.take_damage(100.0, 0, "melee")
	c.p["hp"] = c.max_hp()
	c.p["souls"] = 0
	var hit0 := hero.take_damage(100.0, 0, "melee")
	check(hit0 > 0.0 and near(hit10 / hit0, 1.0 - DmUndeathScythe.WARD_PER_SOUL * 10.0, 1e-4), "undeath: ten souls cut %.0f %% of the damage she takes (%.2f against %.2f)" % [100.0 * DmUndeathScythe.WARD_PER_SOUL * 10.0, hit10, hit0])
	# three wraiths in a cone, the price of one
	await reaper_reset()
	c._set_mods(mods)
	c.p["souls"] = 12
	if accepted(cast("haunting_wraith", at(14.0)), "haunting_wraith"):
		var rises := evs("haunting_wraith", "rise")
		check(souls() == 7 and rises.size() == DmUndeathScythe.WRAITHS and (c.mem("haunting_wraith")["walkers"] as Array).size() == DmUndeathScythe.WRAITHS, "undeath: one cast raises %d wraiths for one price (%d souls left, %d raised)" % [DmUndeathScythe.WRAITHS, souls(), rises.size()])
		if rises.size() == DmUndeathScythe.WRAITHS:
			var d0 := Vector2(float(rises[0]["dx"]), float(rises[0]["dz"]))
			var d1 := Vector2(float(rises[1]["dx"]), float(rises[1]["dz"]))
			var d2 := Vector2(float(rises[2]["dx"]), float(rises[2]["dz"]))
			check(d1.is_equal_approx(Vector2(dirv.x, dirv.z).normalized()) and near(rad_to_deg(d0.angle_to(d1)), DmUndeathScythe.SPREAD_DEG, 1e-3) and near(rad_to_deg(d1.angle_to(d2)), DmUndeathScythe.SPREAD_DEG, 1e-3)
				and bool(rises[0]["first"]) and not bool(rises[1]["first"]) and not bool(rises[2]["first"]), "undeath: the middle wraith goes where she aims, the others %.0f degrees either side" % DmUndeathScythe.SPREAD_DEG)
	# a soul earned with a full bag: nothing without the scythe, a free cone with it (no souls, no cooldown), one for every such soul
	await reaper_reset(8.0)
	foe("robber", at(14.0))
	foe("robber", at(10.0), 0.01)
	cast("scythe_sweep", at(14.0))
	await ticks(3)
	check(evs("haunting_wraith", "rise").is_empty(), "undeath: without the scythe a soul at a full bag raises nothing")
	await reaper_reset(8.0)
	c._set_mods(mods)
	foe("robber", at(14.0))
	foe("robber", at(10.0), 0.01)
	cast("scythe_sweep", at(14.0))
	await ticks(3)
	check(evs("haunting_wraith", "rise").size() == DmUndeathScythe.WRAITHS and souls() == int(c.p["soulsMax"]) and c.cooldown_left("haunting_wraith") == 0.0, "undeath: a soul at a full bag casts a free Haunting Wraith (%d raised, %d souls, cooldown %.0f)" % [evs("haunting_wraith", "rise").size(), souls(), c.cooldown_left("haunting_wraith")])
	foe("robber", at(10.0), 0.01)
	cast("scythe_sweep", at(14.0))
	await ticks(3)
	check(evs("haunting_wraith", "rise").size() == 2 * DmUndeathScythe.WRAITHS, "undeath: every soul at a full bag raises its own free Wraith (%d raised)" % evs("haunting_wraith", "rise").size())


## The easy auto-combat's pick for her (DmAutoCombat's Reaper branch, fed by the ported DmNextAutoCombat from the core's arrays).
func _reaper_auto() -> void:
	var auto: DmNextAutoCombat = g.input.auto
	await reaper_reset()
	c.p["souls"] = 0
	foe("robber", at(2.5))
	await ticks(2)
	var act: Variant = DmAutoCombat.select_action(auto._fill(hero, c, hero.position, DmNextAutoCombat.clock_ms()))
	check(act != null and String(act["id"]) == "scythe_sweep", "auto: one foe in reach and an empty bag = the free Scythe Sweep (%s)" % str(act))
	await reaper_reset()
	for i in 4:
		foe("robber", at(3.0, 0.6 * float(i) - 0.9))
	c.p["souls"] = 8
	await ticks(2)
	act = DmAutoCombat.select_action(auto._fill(hero, c, hero.position, DmNextAutoCombat.clock_ms()))
	check(act != null and String(act["id"]) == "reap", "auto: a knot of four in the cone and 8 souls = Reap (%s)" % str(act))
