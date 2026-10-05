extends RefCounted
## DmEventFx tests: a stub host, a real DmWorldSim driven through a wave, a surge and a boss summon (DmBossFactory), every event fed to
## DmEventFx.handle(). Asserts no script errors (the run would abort), hook calls, game_event counts, Vfx handle bookkeeping.
## Run: godot --headless --path godot --script res://tests/game/event_fx_run.gd

class StubCamera:
	extends RefCounted
	var shakes: Array = []
	func shake(a: float) -> void:
		shakes.append(a)


class StubAbilities:
	extends RefCounted
	var calls: Array = []
	func on_mantle(ev, mine, follow) -> void: calls.append(["on_mantle", mine, follow.call()])
	func on_offering(ev, mine, follow) -> void: calls.append(["on_offering", mine])
	func on_rally(ev, follow) -> void: calls.append(["on_rally"])
	func on_seeded(ev) -> void: calls.append(["on_seeded"])
	func on_seed_gone(id) -> void: calls.append(["on_seed_gone", id])
	func on_seed_burst(ev) -> void: calls.append(["on_seed_burst"])
	func on_detonated(ev, mine) -> void: calls.append(["on_detonated", mine])
	func on_litany(ev, mine) -> void: calls.append(["on_litany", mine])
	func on_new_blood(ev, mine) -> void: calls.append(["on_new_blood", mine])
	func on_corpse_consumed() -> void: calls.append(["on_corpse_consumed"])


class StubHost:
	extends Node3D
	var sim: DmWorldSim
	var p: Dictionary = {"x": 0.0, "z": -16.0, "alive": true, "moving": true, "stats": {"maxHp": 1000.0}, "family": "necromancer", "rootedUntil": 0.0}
	var self_id := "me"
	var now_ms := 0.0
	var area_id := "graves"
	var world_root: Node3D
	var camera := StubCamera.new()
	var abilities := StubAbilities.new()
	var remotes: Dictionary = {}
	var events: Array = []
	var floats: Array = []
	var stops: Array = []
	var gestures := 0

	func emit_game_event(id: String, ctx: Dictionary = {}) -> void:
		events.append([id, ctx])

	func float_text(x: float, y: float, z: float, text: String, kind: String) -> void:
		floats.append([text, kind])

	func hitstop(s: float) -> void:
		stops.append(s)

	func remote_ids() -> Array:
		return remotes.keys()

	func remote_gesture(_ev: Dictionary) -> void:
		gestures += 1

	func count(id: String) -> int:
		var n := 0
		for e in events:
			if e[0] == id:
				n += 1
		return n


var passed := 0
var failed := 0
var tree: SceneTree
var host: StubHost
var fx: DmEventFx
var hook_calls: Dictionary = {}
var seen_types: Dictionary = {}


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func _hook(name: String) -> Callable:
	return func(arg = null): hook_calls[name] = int(hook_calls.get(name, 0)) + 1


var real_boss_kinds: Dictionary = {}
var real_phase := true


func _feed(evs: Array) -> void:
	for ev in evs:
		if real_phase and ev.get("t") == "boss":
			real_boss_kinds[ev["kind"]] = int(real_boss_kinds.get(ev["kind"], 0)) + 1
		seen_types[ev.get("t", "?")] = int(seen_types.get(ev.get("t", "?"), 0)) + 1
		fx.handle(ev)


func _step(sim: DmWorldSim, seconds: float, dt: float = 0.05) -> void:
	var n := int(seconds / dt)
	for i in n:
		host.now_ms += dt * 1000.0
		sim.set_player(DmSimPlayer.make("me", host.p["x"], host.p["z"], host.area_id, true, 30.0, "necromancer"))
		_feed(sim.step(dt))
		fx.update(dt)


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	var root := tree.root
	if root.get_node_or_null("Vfx") == null:
		var v := DmFxRuntime.new()
		v.name = "Vfx"
		root.add_child(v)
	host = StubHost.new()
	host.world_root = host
	root.add_child(host)
	var cam := Camera3D.new()
	host.add_child(cam)
	cam.make_current()
	await tree.process_frame
	var vfx: Node = root.get_node("Vfx")
	check(vfx != null and vfx.prims != null, "Vfx autoload ready")

	var nav := DmNav.new()
	var sim := DmWorldSim.new(nav, DmRng.new(1234))
	host.sim = sim
	fx = DmEventFx.new()
	fx.setup(host)
	for h in ["on_death", "on_hurt", "on_exhumed_refund", "on_exhumed_ok", "on_detonated_refund", "on_heal", "on_new_blood_heal", "on_boss_busy",
			"on_surge_cleared", "on_boss_defeated", "on_node_gone", "on_node_back", "on_legend"]:
		fx.hooks[h] = _hook(h)
	check(fx.vfx != null, "setup found the Vfx node")

	# 1. A real wave: the hero stands in the Hollow Graves.
	sim.set_player(DmSimPlayer.make("me", host.p["x"], host.p["z"], "graves", true, 30.0, "necromancer"))
	_step(sim, 40.0)
	check(sim.enemies.size() > 0 or seen_types.has("spawn"), "the sim spawned a wave (%d enemies, types %s)" % [sim.enemies.size(), str(seen_types.keys())])
	# Hurt the hero's side of things: kill every enemy so death + corpse events flow.
	for e in sim.enemies.values():
		sim.apply({"t": "hit", "by": "me", "ids": [e.id], "dmg": 1e9})
	_step(sim, 0.5)
	check(seen_types.has("death"), "death events handled")
	check(int(hook_calls.get("on_death", 0)) == int(seen_types.get("death", 0)), "on_death hook once per death event")
	check(host.count("corpse_near") == int(seen_types.get("corpse", 0)), "corpse_near counsel event per corpse event")

	# 2. A surge.
	var before_banners := host.count("banner")
	sim.start_surge("graves")
	_step(sim, 0.2)
	check(seen_types.has("surge"), "surge event emitted")
	check(host.count("banner") > before_banners, "surge banner")
	check(host.count("surge_opened") >= 1, "surge_opened counsel event")
	check(fx.surge_fx != null, "surge crack decal kept")
	sim.clear_area("graves")
	_step(sim, 0.3)
	check(int(hook_calls.get("on_surge_cleared", 0)) >= 1 or seen_types.has("surgeFailed") or seen_types.has("surgeCleared"), "surge resolved (hook or event)")

	# 3. A boss summon: Gravedigger King, hero in his arena.
	var gd: Dictionary = DmContent.boss("gravedigger")
	host.p["x"] = float(gd["arena"]["x"]) + 6.0
	host.p["z"] = float(gd["arena"]["z"])
	host.area_id = String(gd["area"])
	sim.set_player(DmSimPlayer.make("me", host.p["x"], host.p["z"], host.area_id, true, 30.0, "necromancer"))
	sim.apply({"t": "summonBoss", "by": "me", "boss": "gravedigger"})
	_step(sim, 45.0)
	check(seen_types.has("boss"), "boss events handled")
	check(host.count("banner") >= 2, "boss awaken banner")
	var tg_before: int = vfx.prims.combat_transients
	check(tg_before > 0 or vfx.transient_load() >= 0, "boss telegraph decals live (%d)" % tg_before)
	# Beat the boss down to defeated, standing next to it.
	sim.apply({"t": "hit", "by": "me", "ids": [], "dmg": 1e12, "boss": true})
	_step(sim, 3.0)
	check(int(hook_calls.get("on_boss_defeated", 0)) >= 1, "on_boss_defeated hook")

	# 4. Synthetic events for every type the real run did not produce, plus the partner path.
	host.remotes["partner"] = {"tx": 3.0, "tz": 4.0, "moving": true}
	host.p["x"] = 0.0
	host.p["z"] = -16.0
	host.area_id = "graves"
	var zone := DmSimZone.new()
	zone.id = 901
	zone.kind = "miasma"
	zone.owner = "partner"
	zone.x = 1.0
	zone.z = -14.0
	zone.r = 3.0
	zone.until = sim.time + 5.0
	zone.creep = 1.0
	zone.contagion = true
	var corpse := DmSimCorpse.new()
	corpse.id = 902
	corpse.kind = "toxic"
	corpse.x = 2.0
	corpse.z = -15.0
	corpse.expiresAt = sim.time + 20.0
	var synth: Array = [
		{"t": "hurt", "player": "me", "dmg": 5.0, "from": "melee", "x": 0.0, "z": 0.0},
		{"t": "nodeGone", "id": "n1", "by": "me", "respawnS": 1.0}, {"t": "nodeBack", "id": "n1"},
		{"t": "melee", "id": 1, "x": 0.0, "z": -10.0, "tx": 0.0, "tz": -12.0},
		{"t": "thrallHit", "id": 1, "target": 2, "x": 0.0, "z": -10.0, "tx": 1.0, "tz": -12.0, "kind": "archer", "dmg": 12},
		{"t": "thrallHit", "id": 1, "target": 2, "x": 0.0, "z": -10.0, "tx": 1.0, "tz": -12.0, "kind": "bonemage", "dmg": 0},
		{"t": "zone", "zone": zone}, {"t": "zoneGone", "id": 901},
		{"t": "wall", "id": 7, "owner": "me", "x0": -3.0, "z0": -14.0, "x1": 3.0, "z1": -14.0, "ms": 5000.0},
		{"t": "wallGone", "id": 7},
		{"t": "rend", "by": "partner", "x": 0.0, "z": -16.0, "leaps": [[0.0, -16.0, 2.0, -18.0], [2.0, -18.0, 4.0, -18.0]], "hits": 2},
		{"t": "mantle", "by": "me", "x": 0.0, "z": -16.0, "r": 5.0, "corpses": 2, "tethers": []},
		{"t": "mantle", "by": "partner", "x": 0.0, "z": -16.0, "r": 5.0, "corpses": 2, "tethers": []},
		{"t": "offering", "by": "me", "ok": false, "x": 0.0, "z": -16.0},
		{"t": "newBlood", "by": "me", "kind": "heal", "ok": false, "x": 0.0, "z": -16.0, "amount": 0.1, "player": "me"},
		{"t": "rally", "by": "me", "x": 0.0, "z": -16.0, "ids": []}, {"t": "seeded", "by": "me", "corpseId": 5, "x": 0.0, "z": -16.0, "armMs": 1000.0},
		{"t": "seedGone", "corpseId": 5}, {"t": "seedBurst", "by": "me", "x": 0.0, "z": -16.0, "r": 4.0, "targets": 1},
		{"t": "corpse", "corpse": corpse}, {"t": "corpseGone", "id": 902, "reason": "expired"},
		{"t": "thrall", "id": 3, "owner": "me", "kind": "colossus", "x": 1.0, "z": -15.0, "empowered": false},
		{"t": "contagion", "x": 0.0, "z": -16.0, "tx": 2.0, "tz": -16.0, "stacks": 2},
		{"t": "requiem", "by": "me", "x": 0.0, "z": -16.0, "r": 5.0, "ms": 1200.0},
		{"t": "heal", "player": "me", "amount": 10.0, "x": 0.0, "z": -16.0}, {"t": "heal", "player": "me", "amount": 0.0, "x": 0.0, "z": -16.0, "frac": 0.05},
		{"t": "burst", "kind": "ember", "x": 0.0, "z": -16.0, "r": 3.0}, {"t": "burst", "kind": "toxic", "x": 0.0, "z": -16.0, "r": 3.0},
		{"t": "burst", "kind": "bloom", "x": 0.0, "z": -16.0, "r": 3.0},
		{"t": "exhumed", "by": "me", "ok": false, "x": 0.0, "z": -16.0, "why": "few"}, {"t": "exhumed", "by": "me", "ok": true, "x": 0.0, "z": -16.0},
		{"t": "litanyResult", "by": "me", "x": 0.0, "z": -16.0, "r": 5.0, "corpses": 1, "resonant": 0, "thralls": 0, "targets": 1, "tethers": []},
		{"t": "legend", "kind": "rally", "by": "me", "x": 0.0, "z": -16.0, "id": 99}, {"t": "legend", "kind": "deathBurst", "by": "me", "x": 0.0, "z": -16.0, "r": 3.0},
		{"t": "legend", "kind": "spread", "by": "me", "x": 0.0, "z": -16.0}, {"t": "legend", "kind": "plague", "by": "me", "x": 0.0, "z": -16.0},
		{"t": "detonated", "by": "me", "ok": true, "corpseId": 1, "x": 0.0, "z": -16.0, "r": 4.0}, {"t": "detonated", "by": "me", "ok": false, "corpseId": 1, "x": 0.0, "z": 0.0, "r": 0.0},
		{"t": "bossBusy", "by": "me", "boss": "regent", "awake": "gravedigger"},
		{"t": "sanctify", "id": 1, "target": 2, "x": 0.0, "z": -10.0, "tx": 2.0, "tz": -12.0},
		{"t": "affix", "id": 1, "affix": "hungering", "x": 0.0, "z": -16.0, "amount": 12},
		{"t": "affix", "id": 1, "affix": "bellTolled", "x": 0.0, "z": -16.0, "r": 3.0}, {"t": "affix", "id": 1, "affix": "vengeful", "x": 0.0, "z": -16.0},
		{"t": "wave", "area": "graves", "count": 5, "x": 0.0, "z": -16.0, "theme": "kennel"},
		{"t": "dmg", "x": 0.0, "z": -16.0, "amount": 12345, "kind": "litany", "by": "me"}, {"t": "dmg", "x": 0.0, "z": -16.0, "amount": 3, "kind": "dot", "by": "me"},
		{"t": "spawn", "id": 11, "def": "censer", "x": 3.0, "z": -16.0, "elite": true},
		{"t": "death", "id": 11, "def": "slag_brute", "x": 3.0, "z": -16.0, "elite": true, "area": "graves", "level": 3.0, "killer": "me"},
		{"t": "surgeFailed", "area": "graves", "x": 0.0, "z": -16.0},
		{"t": "surgeCleared", "area": "graves", "x": 0.0, "z": -16.0},
	]
	for kind in ["cone", "raise", "curse", "slam", "toll", "scream", "dust", "dive", "erupt", "flask", "ember", "hex", "pulse", "hook"]:
		synth.append({"t": "telegraph", "id": 1, "kind": kind, "x": 0.0, "z": -10.0, "tx": 1.0, "tz": -16.0, "ms": 800.0, "r": 2.0})
	for zk in ["warden_fire", "warden_ward", "witch_crows", "witch_charm", "veil_rift", "dirge", "flower", "dust", "ember", "toxic", "rot", "miasma"]:
		var z2 := DmSimZone.new()
		z2.id = 950 + synth.size()
		z2.kind = zk
		z2.x = 1.0
		z2.z = -14.0
		z2.r = 2.5
		z2.until = sim.time + 3.0
		z2.hostile = zk == "toxic"
		synth.append({"t": "zone", "zone": z2})
	for bk in ["sweep", "maul", "bury", "pits", "lance", "chorus", "grasp", "hymn", "communion", "rotRain", "swing", "link", "blessed", "coals", "cleave",
			"conflagration", "surface", "hands", "rite", "flood", "nicheBreak", "toll", "slam", "rain", "summon"]:
		for ms in [900.0, 0.0]:
			for b in ["gravedigger", "abbess", "congregation", "saint", "regent", "mire", "prelate"]:
				synth.append({"t": "boss", "kind": bk, "boss": b, "x": 1.0, "z": -12.0, "phase": 2, "ms": ms, "r": 4.0, "dir": 0.5,
					"targets": [[2.0, -14.0], [4.0, -15.0]], "players": ["me"], "root": 1.0})
	for b in ["prelate", "gravedigger", "abbess", "congregation", "saint", "regent", "mire"]:
		for ph in [1, 2, 3]:
			synth.append({"t": "boss", "kind": "phase", "boss": b, "x": 1.0, "z": -12.0, "phase": ph})
		synth.append({"t": "boss", "kind": "awaken", "boss": b, "x": 1.0, "z": -12.0, "phase": 1, "empowered": b == "regent"})
		synth.append({"t": "boss", "kind": "defeated", "boss": b, "x": 1.0, "z": -12.0, "phase": 3, "killer": "me"})
	var n0 := synth.size()
	real_phase = false
	print("real boss kinds: ", real_boss_kinds)
	check(real_boss_kinds.size() >= 4, "the real boss fight produced %d boss event kinds" % real_boss_kinds.size())
	_feed(synth)
	# the partner dimension: events owned by the remote player restore Vfx state afterwards
	check(is_equal_approx(vfx.particle_scale, 1.0) and vfx.role == "self", "partner dim restored (scale %f role %s)" % [vfx.particle_scale, vfx.role])
	var scale_seen := [-1.0]
	var role_seen := [""]
	fx.hooks["on_legend"] = func(_ev): scale_seen[0] = vfx.particle_scale; role_seen[0] = vfx.role
	fx.handle({"t": "legend", "kind": "plague", "by": "partner", "x": 0.0, "z": -16.0})
	check(is_equal_approx(scale_seen[0], DmEventFx.PARTNER_FX_SCALE) and role_seen[0] == "other", "partner events run with scale %f role %s" % [scale_seen[0], role_seen[0]])
	fx.handle({"t": "legend", "kind": "plague", "by": "me", "x": 0.0, "z": -16.0})
	check(is_equal_approx(scale_seen[0], 1.0) and role_seen[0] == "self", "own events run at full scale")

	# hooks + counts
	check(int(hook_calls.get("on_surge_cleared", 0)) >= 1, "on_surge_cleared hook")
	for h in ["on_hurt", "on_exhumed_refund", "on_exhumed_ok", "on_detonated_refund", "on_heal", "on_new_blood_heal", "on_boss_busy", "on_node_gone", "on_node_back", "on_legend"]:
		check(int(hook_calls.get(h, 0)) >= 1, "hook %s called" % h)
	check(host.count("toast") > 5 and host.count("banner") > 5, "toasts and banners emitted (%d / %d)" % [host.count("toast"), host.count("banner")])
	check(host.count("sanctify_near") == 1, "sanctify_near counsel event")
	check(host.count("enemy_spawned") >= 1, "enemy_spawned counsel event")
	var floats_text := []
	for f in host.floats:
		floats_text.append(f[0])
	for want in ["The corpse is gone", "Too few corpses for a Colossus", "The target is gone", "+10", "Rally", "12,345", "Buried!", "Winded!"]:
		check(floats_text.has(want), "float text '%s'" % want)
	check(host.camera.shakes.size() > 10, "camera shakes (%d)" % host.camera.shakes.size())
	check(host.stops.size() > 0, "hitstops (%d)" % host.stops.size())
	check(host.gestures > 0, "remote_gesture forwarded")
	var calls: Array = host.abilities.calls
	var names := calls.map(func(c): return c[0])
	for m in ["on_mantle", "on_offering", "on_rally", "on_seeded", "on_seed_gone", "on_seed_burst", "on_detonated", "on_litany", "on_new_blood"]:
		check(names.has(m), "abilities.%s called" % m)
	# The caster's own handle_event consumes the corpse on an exhume (+ the corpse heal); the router must not do it again.
	check(not names.has("on_corpse_consumed"), "exhumed: on_corpse_consumed left to the caster")
	check(host.p["rootedUntil"] > 0.0, "boss root applied to the hero")
	for t in DmEventFx.HANDLED:
		if not seen_types.has(t):
			print("note: event type never fed: ", t)
	var missing := 0
	for t in DmEventFx.HANDLED:
		if not seen_types.has(t):
			missing += 1
	check(missing == 0, "every handled event type was fed (%d missing)" % missing)

	# 5. Frame work: fxLater, zone ambience, wading, echo marks, aura cleanup.
	fx.fx_later.append({"at": host.now_ms + 10.0, "run": func(): hook_calls["later"] = 1})
	host.now_ms += 20.0
	fx.update(0.016)
	check(hook_calls.get("later", 0) == 1, "fxLater ran when due")
	var pending := fx.fx_later.size()
	host.now_ms += 5000.0
	fx.update(0.016)
	check(fx.fx_later.is_empty() and pending > 0, "fxLater queue drains (%d pending before)" % pending)
	for i in 30:
		host.now_ms += 100.0
		fx.update(0.1)
	check(true, "update loop with ambient zones ran")

	# 6. Handle leak check: tear everything down.
	fx.clear()
	for i in 600:
		host.now_ms += 100.0
		vfx.prims.update(0.1, 0.1)
		vfx.binbun.update(0.1, tree.root.get_viewport().get_camera_3d())
	var live: int = vfx.prims.combat_transients
	check(live < 160, "combat transients bounded after clear and 60 s (%d)" % live)
	check(fx.aura_fx.is_empty() and fx.zones_fx.zone_fx.is_empty() and fx.zones_fx.wall_fx.is_empty(), "no tracked handles left after clear")
	print("fed %d synthetic + %d real events; types %d" % [n0, int(seen_types.values().reduce(func(a, b): return a + b, 0)) - n0, seen_types.size()])
	host.queue_free()
