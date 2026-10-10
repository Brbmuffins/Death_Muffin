extends SceneTree
## Combat-feel parity seams on the rebuild (the behaviour itself is exercised in depth by tests/next_feel). godot --headless --path godot --script res://tests/next_combat_feel/run.gd
##   1 click-chase + hold + held keys wired    2 queued cast on a busy caster    3 gesture + weapon clip per rite    4 hitstop wired (enemy fx, bosses), picture-only    5 frame cost

const DT := 1.0 / 60.0
var passed := 0
var failed := 0
var g: DmNextGame
var hero: DmHeroBody
var caster: DmRiteCaster


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("cf%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(0)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"dressing": false, "persist": false, "waves": false})
	hero = g.local_body()
	await ticks(3)
	caster = hero.get_node("Rites") as DmRiteCaster
	caster.p["stats"]["level"] = 60.0
	var combat: DmCombatInput = g.input.combat
	combat.shift_probe = func() -> bool: return false

	# 1: the input owner exposes the chase / hold / held-key state machine and starts idle (zero per-frame work)
	check(combat != null and combat.idle() and g.input.has_method("attack"), "1: DmCombatInput owns click-chase, hold repeat and held keys and starts idle")
	check(DmCombatInput.HOLD_MS > 0.0 and DmCombatInput.QUEUE_MS > 0.0, "1: hold delay and queue window are defined")

	# 2: a busy refusal is queued by the input layer (the caster itself stays a strict validator)
	var reasons: Array = []
	caster.cast_rejected.connect(func(_rite: String, why: String) -> void: reasons.append(why))
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	var aim := hero.position + Vector3(0, 0, -6)
	caster.request_cast("miasma", aim)
	await ticks(2)
	caster.request_cast("miasma", aim)
	await ticks(2)
	check(reasons.has("busy") or reasons.has("cooldown"), "2: the caster refuses a second cast during the lock (%s)" % [reasons])

	# 3: every rite has a gesture row with a real cast-flow, and the weapon clip id is the rite id (castClips.json by ability)
	var bad: Array = []
	for rite in DmRiteGestures.TABLE:
		var row: Array = DmRiteGestures.TABLE[rite]
		if String(row[3]) != "" and String(row[3]) != String(rite):
			bad.append(rite)
	check(bad.is_empty(), "3: weapon-clip ability id matches the rite (%s differ)" % [bad])
	var g0 := caster.gestures_played
	caster.p["castUntil"] = 0.0
	caster.p["cooldowns"].clear()
	caster.request_cast("miasma", aim)
	await ticks(3)
	check(caster.gestures_played == g0 + 1, "3: an accepted cast plays one gesture on the hero avatar")

	# 4: hitstop callbacks are wired and only drive the picture (no Engine.time_scale -> the host's sim is never slowed)
	check(g.enemy_fx.host.hitstop_cb.is_valid() and g.bosses.fx.host.hitstop_cb.is_valid(), "4: enemy fx and boss fx hitstop callbacks are set")
	var n0 := g.hitstopper.count
	g.hitstop(0.05)
	check(g.hitstopper.count == n0 + 1, "4: a hitstop request is counted")
	g.hitstopper.reset()
	check(is_equal_approx(Engine.time_scale, 1.0), "4: Engine.time_scale untouched (hitstop is picture-only, safe online)")

	# 5: frame cost of the idle combat tick
	var t0 := Time.get_ticks_usec()
	for i in 20000:
		combat.tick(float(i))
	var idle_us := float(Time.get_ticks_usec() - t0) / 20000.0
	perf_info(idle_us < 2.0, "5: combat.tick idle %.3f us/frame" % idle_us)
	var fc := DmFrameCost.attach(root)
	await ticks(5)
	fc.reset()
	await ticks(120)
	print("perf: idle combat tick %.3f us; frame median %.2f ms (worst %.1f)" % [idle_us, fc.median_ms(), fc.worst_ms()])
	fc.queue_free()

	g.queue_free()
	await ticks(3)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
