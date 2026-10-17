extends "res://tests/coop.gd"
## The six other bosses fight a PARTY (client/README.md "Co-op on the core" and "The bosses"), headless, over the same REAL local lobby and relay as tests/coop.gd (whose helpers it uses: the lobby
## service, the test tokens, the accounts on the in-memory mock, a SceneMultiplayer branch per player, the position comparison). One party serves all six: the host's game and the guest's are the whole
## world (the guest's seals are the host's) and the Bone Abbess, the Drowned Congregation, the Bell-Sworn Prelate, the Plague Saint, the Cinder Regent and the Mire Mother are summoned in turn, each twice.
## The brain, the state and the events are `DmBossHost`'s (GDScript, 20 Hz and reliable: the host runs the brain, the guest holds a puppet body); the adds, the niches and the pools are bodies and
## zones of the combat core and ride its wire. Both sides' boss fx draw into counting back-ends, so what the guest draws, plays and tells its HUD is compared with the host's, count for count.
##
## First summon of each boss (the GUEST asks for it at the boss's altar and pays with its own soul shards):
##   - the boss wakes on the host and the guest holds its body, awake, with the same health (the party's extra health counted for two heroes), its model up and its plate on the HUD; a second summon
##     while it is awake is refused to the guest in words;
##   - the guest can aim at it: its core host knows the boss by the id the host's core gave it, names it among the bodies near it, and its hover pick finds it under the cursor;
##   - a fight on the real clock, the guest's hero in front of the boss and the host's hero to the side: the attacks are provoked one after the other (the brain's own cooldowns), each lands twice, the
##     boss's blows reach the GUEST's hero (the host applies them, the guest's own client shows its health fall), the casts of both heroes hurt it (the guest's resolved on the host), the guest's copy
##     follows its state and shows its telegraphs, and its events, the shapes and sounds drawn for them and the banners told to the HUD are the host's, kind for kind and count for count;
##   - what the attacks do besides damage: the Flood Hymn's chill (a status on the guest's hero, replicated), the Drowning Grasp's and the Drowned Hands' root (the host's body of the guest's hero stands
##     still against its own move intent), the Congregation's wading water; the Saint's rot pools and the Regent's coals, firebreak and embers (the same zone events on the guest's puppet core, drawn there);
##     the Mire Mother's sinking (her state on the guest, untargetable);
##   - the phases at 60 and 30 %: the guest follows; the adds of each phase (and the Abbess's niches, broken by the heroes and then rebuilt, with the health the host gave them) are the same bodies on both
##     cores; every body the guest holds is the host's at the snapshot's tick; the last phase's own attack is played once more (Bone Communion over real corpses, the Drowned Rite raising Risen from
##     them, Conflagration, the rain);
##   - the defeat by a cast of the guest: `defeated` names the guest, the boss is dead on both sides and its model fades, its adds left silently and BOTH accounts are paid (each member's rewards and
##     report entry, the guest's drops and XP on its own account; a guest's first-kill bonus and trophy are its own backend's business, as in today's game).
## Second summon (the HOST asks): a wipe. Both heroes fall, the boss resets on both sides with nothing paid, its adds leave without a death, a corpse or a credit, both heroes get up and the bodies are freed
## on both sides.
## ZERO script errors or engine errors in the log. Bakes the robber, the hound and the legionnaire into a scratch folder first (about 25 s); a boss's own adds are drawn with the nearest baked model.
## Run (with --fixed-fps 60, about 70 s):
##   godot --headless --fixed-fps 60 --path client --script res://tests/coop_bosses.gd

const BOSSES := ["abbess", "congregation", "prelate", "saint", "regent", "mire"]
const DEAD_STATE := 6
const FIGHT_TICKS := 60 * 50           ## the longest a fight is given
const MIN_FIGHT_TICKS := 60 * 8        ## and the shortest: the state, the events and the bodies have to keep matching over time
## Per boss: the brain's cooldowns to zero one after the other while the heroes stand in front of it (`rot`; `side` is a telegraph that does not make the boss busy), the events its attacks make
## (`kinds`: each must land at least twice), where the guest's hero and the host's stand from the arena's centre, how many bodies each phase's wave adds, the kind of zone its pools make, and the
## attack of the last phase that is played once more (`late`, its `late_kinds`: Bone Communion devours corpses, the Drowned Rite raises them, Conflagration burns the arena).
const SPEC := {
	"abbess": {"rot": ["_grasp_cd", "_chorus_cd"], "side": "_lance_cd", "kinds": ["lance", "chorus", "grasp"], "guest": Vector3(3.0, 0.0, 0.0), "host": Vector3(-6.0, 0.0, 0.0), "p2": 0, "p3": 2, "late": "_communion_cd", "late_kinds": ["communion"]},
	"congregation": {"rot": ["_hymn_cd", "_grasp_cd", "_melee_cd"], "kinds": ["hymn", "grasp", "maul"], "guest": Vector3(2.5, 0.0, 0.0), "host": Vector3(-6.0, 0.0, 0.0), "p2": 6, "p3": 6, "late": "_hymn_cd", "late_kinds": ["hymn"]},
	"prelate": {"rot": ["_toll_cd", "_slam_cd"], "kinds": ["toll", "slam"], "guest": Vector3(3.0, 0.0, 0.0), "host": Vector3(-6.0, 0.0, 0.0), "p2": 4, "p3": 6, "late": "_rain_cd", "late_kinds": ["rain"]},
	"saint": {"rot": ["_rain_cd", "_swing_cd"], "kinds": ["rotRain", "swing"], "guest": Vector3(3.0, 0.0, 0.0), "host": Vector3(-6.0, 0.0, 0.0), "p2": 3, "p3": 4, "zone": "toxic", "late": "_rain_cd", "late_kinds": ["rotRain"]},
	"regent": {"rot": ["_coals_cd", "_cleave_cd"], "kinds": ["coals", "cleave"], "guest": Vector3(3.0, 0.0, 0.0), "host": Vector3(-6.0, 0.0, 0.0), "p2": 5, "p3": 4, "zone": "ember", "late": "_confl_cd", "late_kinds": ["conflagration"]},
	"mire": {"rot": ["_hands_cd", "_maul_cd", "_surface_cd"], "kinds": ["hands", "maul", "surface"], "guest": Vector3(5.0, 0.0, 0.0), "host": Vector3(-6.0, 0.0, 0.0), "p2": 6, "p3": 6, "late": "_rite_cd", "late_kinds": ["rite"]},
}

## Counting back-ends for the boss fx of each side (every Vfx / AudioDirector call the router makes), as tests/boss_base.gd has them: what is drawn and heard for the boss's events.
class Stub:
	extends Node
	var calls: Dictionary = {}
	var sfx: Array = []
	var particle_scale := 1.0
	var hitstop_scale := 1.0

	class Handle:
		extends RefCounted
		var alive := true

		func kill() -> void:
			alive = false

	func _count(n: String) -> void:
		calls[n] = int(calls.get(n, 0)) + 1

	func danger(cb: Callable, _keep: bool = false) -> void:
		_count("danger")
		cb.call()

	func play_sfx(name_: String, _pos: Variant = null, _i: float = 1.0) -> bool:
		sfx.append(name_)
		return true

	func decal(_o: Dictionary) -> Variant:
		_count("decal")
		return Handle.new()

	func emit(_o: Dictionary) -> void:
		_count("emit")

	func emit_smoke(_o: Dictionary) -> void:
		_count("emit")

	func light_flash(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null) -> void:
		_count("flash")

	func flash(_o: Dictionary) -> void:
		_count("flash")

	func spike_line(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null, _e: Variant = null, _f: Variant = null) -> void:
		_count("spike")

	func beam(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null, _e: Variant = null) -> void:
		_count("beam")

	func projectile(_o: Dictionary) -> void:
		_count("proj")

	func play(_id: String, _a: Variant = null, _b: Variant = null) -> Variant:
		_count("bb")
		return Handle.new()

	func _get(_prop: StringName) -> Variant:
		return null


var cid_h := 0                       ## the host's character id, and the guest's
var cid_g := 0
var rites_h: DmRiteCaster            ## the host's caster, the guest's own (a request and the picture) and the host's copy of the guest's (where its casts resolve)
var rites_g: DmRiteCaster
var rites_hg: DmRiteCaster
var stub_h := Stub.new()             ## what each side's boss fx drew and played
var astub_h := Stub.new()
var stub_g := Stub.new()
var astub_g := Stub.new()
var cur_core := 0                    ## the core id of the boss being fought: the source of its blows, the owner of its zones
var ev_h := {}                       ## "kind" (a telegraph) / "kind!" (an impact or a one-off) -> events the boss fx played on each side
var ev_g := {}
var zones_h := {}                    ## zone kind -> zone events of the boss's pools on each core
var zones_g := {}
var zfx_h := 0                       ## the zone visuals each side's enemy fx had drawn when the boss was woken
var zfx_g := 0
var blows_on := {1: 0, 2: 0}         ## hero peer -> blows of the boss that reached it (the host's bodies)
var hits_on := {"host": 0, "guest": 0}   ## casts resolved on the boss, by whose caster
var earned_log: Array = []           ## [character id, boss, first] from the host's rewards
var drops_h := {}                    ## character id -> drops the host's rewards made for it
var deaths := {"host": 0, "guest": 0}    ## enemy_died events of each core
var thrall_hits := 0                 ## blows of the guest's thralls on the boss (the core's EV_THRALL_HIT_EXTERNAL, the host's), and whether the guest got the credit
var thrall_credit := true
var swings_g := 0                    ## thrall swings the guest's puppet core showed
var toasts: Array = []              ## the toasts the guest's HUD was told
var hud_h: Array = []                ## "banner: title" / "toast: text" the boss fx and the boss host told each side's HUD
var hud_g: Array = []
var woke := [""]
var fell := [null]
var reset_n := [0]
var tele_kinds := {}                 ## telegraph kinds the guest's copy of the boss showed
var sunk_g := 0                      ## ticks the guest's copy was sunk, and how many of them it still counted as hittable
var sunk_bad := 0
var hp_dip := INF                    ## the lowest health the guest's own client showed for its hero
var hurt_events := {1: 0, 2: 0}      ## blows of any kind that hurt each hero on the host (`hurt`), and what each window's HUD had been told when the fight began (`tap`)
var tap0_h := {}
var tap0_g := {}
var chill_h := false                 ## the Flood Hymn's chill seen on the guest's hero as the host has it, and as the guest has it
var chill_g := false
var rootp := {"event": false, "left": 0.0, "probed": false, "free": 0.0, "held": -1.0}   ## the root probe: how far the guest's hero walked free, and how far while rooted


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL coop_bosses: " + what)


func _run() -> void:
	await process_frame
	OS.add_logger(errlog)
	rng.seed = 7
	DirAccess.make_dir_recursive_absolute(OUT)
	if not await start_services():
		stop_services()
		print("coop_bosses: SKIPPED (needs `node` and `cd server/death-muffin/lobby && npm ci`, and free ports)")
		print("0 checks (skipped)")
		quit(0)
		return
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, OUT.path_join(slug))
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			stop_services()
			quit(1)
			return
	mock = DmOffline.make_mock("")   # memory only: no file, no server
	await account("hostess", 101, 2, 20)
	await account("joiner", 102, 2, 20)
	open_seals("hostess")
	open_seals("joiner")
	cid_h = int(accounts["hostess"]["ch"]["id"])
	cid_g = int(accounts["joiner"]["ch"]["id"])
	await the_party()
	if g == null or not g.ready_:
		finish_early("the guest's game did not start")
		return
	for id in BOSSES:
		var t0 := Time.get_ticks_msec()
		await fight(id)
		await wipe(id)
		print("INFO coop_bosses %s: %d s of real time; the relay forwarded %d packets, its rate limits dropped %d" % [id, (Time.get_ticks_msec() - t0) / 1000, int(relay.stats["forwarded"]), relay.rate_drops])
	await finish()


func finish() -> void:
	for gm in [h, g]:
		if gm != null and is_instance_valid(gm):
			gm.process_mode = Node.PROCESS_MODE_DISABLED
	check(relay == null or relay.rate_drops == 0, "the relay's rate limits dropped no packet, counted in game time (%d: %s)" % [relay.rate_drops if relay != null else 0, str(relay.refusals if relay != null else [])])
	stop_services()
	check(errlog.errors.is_empty(), "zero script errors or engine errors in the log (%d: %s)" % [errlog.errors.size(), "; ".join(errlog.errors.slice(0, 3))])
	if fails == 0:
		print("PASS coop_bosses %d checks" % checks)
	else:
		print("FAIL coop_bosses: %d of %d checks failed" % [fails, checks])
	quit(1 if fails > 0 else 0)


func finish_early(why: String) -> void:
	printerr("coop_bosses: stopped early: " + why)
	check(false, why)
	stop_services()
	print("FAIL coop_bosses: %d of %d checks failed" % [fails, checks])
	quit(1)


# ------------------------------------------------------------------------------------------------------------------ the party and what is watched

func the_party() -> void:
	hq = new_branch()
	h = await game(hq, "hostess", {"areas": [], "waves": false})   # the whole world (every area but the Depths)
	check(h.ready_ and not h.is_guest and h.world.loaded.size() >= 9, "the host's game is up in the whole world (%d areas)" % h.world.loaded.size())
	hb = h.local_body()
	var hosted := [false]
	h.party.hosting_changed.connect(func(on: bool) -> void: hosted[0] = on)
	h.party.host_session("Boss party", true)
	await until(func() -> bool: return hosted[0], 10.0)
	check(hosted[0] and h.party.mode == DmNextParty.HOST, "the host made a Closed party (%s)" % h.party.code)
	gq = new_branch()
	var g0 := await game(gq, "joiner", {"areas": ["graves"]})
	var got: Array = await seat(g0, func() -> void: g0.party.join_by_code(h.party.code))
	if got.size() != 2:
		finish_early("the guest could not join")
		return
	g = await hand_over(g0, gq, "joiner", got[0], {"areas": []})
	if g == null or not g.ready_:
		return
	gb_h = h.body_of(2)
	gb_g = g.local_body()
	check(g.is_guest and g.core_host.puppet and g.world.loaded.size() == h.world.loaded.size(), "the guest's game is the host's whole world, with a puppet core")
	await until(func() -> bool: return gb_g.core_id == gb_h.core_id and g.body_of(1).core_id == hb.core_id, 5.0)
	var gm: DmRewardsMember = h.rewards.members.get(cid_g)
	check(await until(func() -> bool: return g.joiner != null and g.joiner.backend_ok and gm != null and gm.blocked == "" and gm.joined, 8.0), "the guest is a rewards member on its own account")
	await until(func() -> bool: return gb_h.get_node_or_null("Rites") != null and gb_g.get_node_or_null("Rites") != null and hb.get_node_or_null("Rites") != null, 5.0)
	rites_h = hb.get_node("Rites") as DmRiteCaster
	rites_g = gb_g.get_node("Rites") as DmRiteCaster
	rites_hg = gb_h.get_node("Rites") as DmRiteCaster
	sampler = Sampler.new()
	sampler.game = h
	h.add_child(sampler)
	h.director.enabled = false
	h.bosses.rng.seed = 20261017   # the brains' dice (a Chorus's direction, a rain's circles) the same every run; the host randomizes them in play
	# what the run watches, once: the casts that hurt the boss, its blows on each hero, the events and zones of both sides, the host's payments, the deaths
	rites_h.hit_resolved.connect(func(_r: String, id: int, _a: float, _c: bool, _k: bool) -> void: hits_on["host"] += 1 if cur_core != 0 and id == cur_core else 0)
	rites_hg.hit_resolved.connect(func(_r: String, id: int, _a: float, _c: bool, _k: bool) -> void: hits_on["guest"] += 1 if cur_core != 0 and id == cur_core else 0)
	hb.hurt.connect(func(_a: float, src: Variant) -> void: blows_on[1] += 1 if cur_core != 0 and src is int and int(src) == cur_core else 0)
	gb_h.hurt.connect(func(_a: float, src: Variant) -> void: blows_on[2] += 1 if cur_core != 0 and src is int and int(src) == cur_core else 0)
	hb.hurt.connect(func(_a: float, _src: Variant) -> void: hurt_events[1] += 1)
	gb_h.hurt.connect(func(_a: float, _src: Variant) -> void: hurt_events[2] += 1)
	tap_h = tap(h)
	tap_g = tap(g)
	for side: DmNextGame in [h, g]:
		var feed: Array = hud_h if side == h else hud_g
		var inner: Callable = side.bosses.fx.host.sink
		side.bosses.fx.host.sink = func(id: String, ctx: Dictionary) -> void:
			feed.append("%s: %s" % [id, String(ctx.get("title", ctx.get("text", "")))])
			inner.call(id, ctx)
	h.bosses.fx.set_backends(stub_h, astub_h)
	g.bosses.fx.set_backends(stub_g, astub_g)
	h.bosses.fx.played.connect(func(ev: Dictionary) -> void:
		_tally(ev_h, ev)
		# the Drowning Grasp and the Drowned Hands root whoever they caught, before the fx plays the event (DmBossHost._route): the guest's hero, as the host has it
		if float(ev.get("ms", 0.0)) == 0.0 and ev.get("root") != null and (ev.get("players", []) as Array).has("2") and not rootp["event"]:
			rootp["event"] = true
			rootp["left"] = float(gb_h.p["rootedUntil"]) - gb_h.clock_ms())
	g.bosses.fx.played.connect(func(ev: Dictionary) -> void: _tally(ev_g, ev))
	h.core_host.zone.connect(func(_id: int, kind: int, source: int, _x: float, _z: float, _r: float, _s: float) -> void:
		if cur_core != 0 and source == cur_core:
			_bump(zones_h, String(DmCoreEvents.ZONE_KINDS[kind])))
	g.core_host.zone.connect(func(_id: int, kind: int, source: int, _x: float, _z: float, _r: float, _s: float) -> void:
		if cur_core != 0 and source == cur_core:
			_bump(zones_g, String(DmCoreEvents.ZONE_KINDS[kind])))
	h.core_host.thrall_hit_external.connect(_on_thrall_hit_boss)
	g.core_host.thrall_swing.connect(func(_id: int, _sw: int, _t: int, _ax: float, _az: float, _d: float) -> void: swings_g += 1)
	h.core_host.enemy_died.connect(func(_id: int, _d: String, _l: int, _e: bool, _a: String, _s: int, _x: float, _z: float) -> void: deaths["host"] += 1)
	g.core_host.enemy_died.connect(func(_id: int, _d: String, _l: int, _e: bool, _a: String, _s: int, _x: float, _z: float) -> void: deaths["guest"] += 1)
	h.rewards.boss_earned.connect(func(cid: int, id: String, first: bool, _at: Vector3) -> void: earned_log.append([cid, id, first]))
	h.rewards.loot_dropped.connect(func(cid: int, _d: Dictionary, _p: Vector3) -> void: drops_h[cid] = int(drops_h.get(cid, 0)) + 1)
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void:
		if id == "toast":
			toasts.append(String(ctx.get("text", ""))))
	h.bosses.summoned.connect(func(id: String, by: int) -> void: woke[0] = "%s/%d" % [id, by])
	h.bosses.defeated.connect(func(id: String, killer: int, _p: Vector3) -> void: fell[0] = [id, killer])
	h.bosses.reset.connect(func(_id: String) -> void: reset_n[0] += 1)
	tough(hb)
	tough(gb_h)


## Every seal of the account open on the mock's server: a summon takes the shards from the account's own record, and the server refuses it for an area the account has not opened ("... is still
## sealed."), which gives the shards back (the host does not ask the guest's account whether it may wake what its own world has open).
func open_seals(nm: String) -> void:
	for k in mock.db["accounts"]:
		var acc: Dictionary = mock.db["accounts"][k]
		if String(acc.get("username", "")) == nm:
			var st: Dictionary = DmNecroRules.normalise(acc.get("necro", DmNecroRules.blank_state()))
			st["unlockedAreas"] = DmProgContent.area_order().duplicate()
			st["migrated"] = true   # (a record that is not migrated is replaced by the client's own on its first sync)
			acc["necro"] = st


## The banners and toasts a side's HUD was told, sorted (the guest's own refusal is for the guest alone).
func hud_feed(feed: Array) -> Array:
	var out := feed.filter(func(t: String) -> bool: return t != "toast: " + String(DmBossHost.WHY["busy"]))
	out.sort()
	return out


## A thrall's blow on the boss (the core's EV_THRALL_HIT_EXTERNAL, the host's): the guest's thralls count, and the boss's brain must have them credited to the guest.
func _on_thrall_hit_boss(tid: int, target: int, _kind: String, _damage: float) -> void:
	if cur_core == 0 or target != cur_core or int(h.core_host.core.thrall_info(tid).get("owner", 0)) != gb_h.core_id:
		return
	thrall_hits += 1
	var b := h.bosses.active_boss()
	thrall_credit = thrall_credit and b != null and b.brain != null and String(b.brain.last_hit_by) == "2"


func _tally(into: Dictionary, ev: Dictionary) -> void:
	_bump(into, "%s%s" % [ev["kind"], "" if float(ev.get("ms", 0.0)) > 0.0 else "!"])


func _bump(into: Dictionary, key: String) -> void:
	into[key] = int(into.get(key, 0)) + 1


func _sum(d: Dictionary) -> int:
	var n := 0
	for v in d.values():
		n += int(v)
	return n


## The living bodies of a core's table by def (the niches, the adds).
func defs_of(gm: DmNextGame) -> Dictionary:
	var out := {}
	var core: RefCounted = gm.core_host.core
	for id in core.enemy_ids():
		var info: Dictionary = core.enemy_info(id)
		if int(info["state"]) != DEAD_STATE:
			_bump(out, String(info["def"]))
	return out


func living(gm: DmNextGame) -> int:
	return _sum(defs_of(gm))


## The ids of the living bodies of one def on a core.
func ids_of(gm: DmNextGame, def: String) -> Array:
	var out: Array = []
	var core: RefCounted = gm.core_host.core
	for id in core.enemy_ids():
		var info: Dictionary = core.enemy_info(id)
		if int(info["state"]) != DEAD_STATE and String(info["def"]) == def:
			out.append(int(id))
	return out


## The (rounded) maximum health of the niches a core holds, sorted.
func niche_max(gm: DmNextGame) -> Array:
	var out: Array = []
	for id in ids_of(gm, "niche"):
		out.append(roundi(float(gm.core_host.core.enemy_info(id)["max_hp"])))
	out.sort()
	return out


func clear_enemies() -> void:
	for id in h.core_host.core.enemy_ids():
		h.core_host.remove_enemy(id)


func reset_watch() -> void:
	ev_h.clear()
	ev_g.clear()
	zones_h.clear()
	zones_g.clear()
	zfx_h = int(h.enemy_fx.stats["zone"])
	zfx_g = int(g.enemy_fx.stats["zone"])
	blows_on = {1: 0, 2: 0}
	hits_on = {"host": 0, "guest": 0}
	tele_kinds.clear()
	sunk_g = 0
	sunk_bad = 0
	hp_dip = INF
	hurt_events = {1: 0, 2: 0}
	tap0_h = tap_h.duplicate(true)
	tap0_g = tap_g.duplicate(true)
	thrall_hits = 0
	thrall_credit = true
	swings_g = 0
	hud_h.clear()
	hud_g.clear()
	for st in [stub_h, stub_g, astub_h, astub_g]:
		st.calls.clear()
		st.sfx.clear()
	chill_h = false
	chill_g = false
	rootp = {"event": false, "left": 0.0, "probed": false, "free": 0.0, "held": -1.0}
	reset_cmp()


## Both heroes alive at the boss's altar, sturdy, the guest's body there too (the session's snapshots tell it), every seal of the host's open on both sides.
func to_site(id: String) -> void:
	h.director.enabled = false
	clear_enemies()
	for t in h.core_host.core.thrall_ids():
		h.core_host.core.kill_thrall(t, "killed")
	h.world.set_unlocked(h.world.loaded.duplicate())
	h.party.send_seals()
	await until(func() -> bool: return hb.alive and gb_h.alive, 12.0)
	var site := h.bosses.site_pos(id)
	hb.teleport(site + Vector3(2.0, 0.0, 0.0))
	gb_h.teleport(site + Vector3(-2.0, 0.0, 0.0))
	tough(hb)
	tough(gb_h)
	await until(func() -> bool: return gb_g.position.distance_to(site) < 4.5 and gb_g.alive, 5.0)
	await ticks(10)


## Heroes that outlast a long fight but still show a blow: the health pool regrows 0.4 % of its maximum a second in a fight, so a 10 million pool would refill within a frame (the guest's own client could
## never be seen to lose any).
func tough(b: DmHeroBody) -> void:
	b.p["stats"]["maxHp"] = 2.0e5
	b.p["hp"] = 2.0e5
	b._mirror_from_state()


func arena_of(id: String) -> Vector3:
	var a: Dictionary = DmContent.boss(id)["arena"]
	return Vector3(float(a["x"]), 0.0, float(a["z"]))


## The heroes where the fight is: the guest's hero in front of the boss, the host's to the side.
func stand(id: String) -> void:
	var sp: Dictionary = SPEC[id]
	var arena := arena_of(id)
	hb.teleport(arena + (sp["host"] as Vector3))
	gb_h.teleport(arena + (sp["guest"] as Vector3))
	await until(func() -> bool: return gb_g.position.distance_to(arena + (sp["guest"] as Vector3)) < 1.0, 3.0)


## Both heroes cast at the boss as a click on it does: the host's with its id, the guest's with the id its own core host names for it, aimed at the place the guest sees it.
func cast_at_boss(bh: DmBoss) -> void:
	rites_h.request_cast("bone_needle", bh.global_position, bh.core_id)
	var at := g.core_host.enemy_position(bh.core_id)
	rites_g.request_cast("bone_needle", at if at != Vector3.INF else bh.global_position, bh.core_id)


## A boss body that is still there (a defeated or reset one is freed a few seconds after, and a wait may outlast it).
func here(b: Node) -> bool:
	return b != null and is_instance_valid(b)


## The guest holds the host's state of the boss: its health within 3 % of the maximum, the phase, the state.
func same_state(bh: DmBoss, bg: DmBoss) -> bool:
	return absf(bg.hp - bh.hp) <= bh.max_hp * 0.03 and bg.phase == bh.phase and bg.bstate.state == bh.bstate.state and bg.bstate.active == bh.bstate.active


## How far the guest's hero walks in a third of a second when it asks the host to walk it away from the boss (a held direction, as the keys send): free, it walks about 2 m; rooted, not at all.
func probe_move() -> float:
	var p0 := gb_h.position
	for i in 20:
		if i % 4 == 0:
			g.session.request_move_dir(Vector3(1.0, 0.0, 0.0))
		await physics_frame
	g.session.request_move_dir(Vector3.ZERO)
	await ticks(2)
	return gb_h.position.distance_to(p0)


# ------------------------------------------------------------------------------------------------------------------ the first summon: the fight, the phases, the defeat

func fight(id: String) -> void:
	var sp: Dictionary = SPEC[id]
	var bd: Dictionary = DmContent.boss(id)
	var cost := int(bd["shards"])
	var tag := String(bd["name"])
	await to_site(id)
	cur_core = 0
	reset_watch()
	earned_log.clear()
	fell[0] = null
	# ---- the summon: the guest asks, pays with its own shards, the host wakes it
	var s0 := int(g.joiner.prog.local["shards"])
	g.joiner.prog.add_shards(cost)
	woke[0] = ""
	g.bosses.request_summon(id)
	check(await until(func() -> bool: return woke[0] != "", 4.0) and woke[0] == "%s/2" % id, "%s: the guest's request woke it on the host (%s)" % [tag, woke[0]])
	check(await until(func() -> bool: return int(g.joiner.prog.local["shards"]) == s0, 2.0), "%s: the guest's own %d soul shards paid for it (%d before, %d now)" % [tag, cost, s0, int(g.joiner.prog.local["shards"])])
	check(await until(func() -> bool: return h.bosses.active_boss() != null and h.bosses.active_boss().is_hittable(), 12.0), "%s: awake and can be hurt" % tag)
	var bh := h.bosses.active_boss()
	if bh == null or bh.boss_id != id:
		finish_early("%s did not wake" % tag)
		return
	cur_core = bh.core_id
	check(await until(func() -> bool: return g.bosses.active_boss() != null and g.bosses.active_boss().boss_id == id, 8.0), "%s: the guest holds its body, awake" % tag)
	var bg := g.bosses.active_boss()
	if bg == null or bg.boss_id != id:
		finish_early("%s did not reach the guest" % tag)
		return
	var solo_hp: float = float(DmContent.get_export("bosses", "BOSSES")[id]["baseHp"]) * (1.0 + 0.22 * (float(bh.brain.state["level"]) - 1.0)) \
		* float(DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]["enemyHpMult"])
	check(absf(bh.max_hp - solo_hp * (1.0 + DmEnemyStats.BOSS_PARTY_HP_PER_EXTRA)) < 1.0, "%s: two heroes give it the party's extra health (%.0f, one hero %.0f)" % [tag, bh.max_hp, solo_hp])
	check(await until(func() -> bool: return absf(bg.max_hp - bh.max_hp) < 1.0 and absf(bg.hp - bh.hp) < 1.0 and bg.bstate.active, 4.0), "%s: and the guest's copy has its health (%.0f of %.0f)" % [tag, bg.hp, bg.max_hp])
	check(await until(func() -> bool: return int(ev_g.get("awaken!", 0)) == 1 and int(ev_h.get("awaken!", 0)) == 1, 4.0), "%s: its awakening was played on both sides" % tag)
	check(await until(func() -> bool: return bg.view != null and bg.view.is_shown(), 4.0), "%s: and its model is up on the guest" % tag)
	var plate: Array = [null]   # (a lambda copies a plain variable: it writes into this)
	check(await until(func() -> bool:
		plate[0] = g.ui_host.hud_state()["boss"]
		return plate[0] != null and String(plate[0]["name"]) == String(bd["name"]) and int(plate[0]["phase"]) == 1 and absf(float(plate[0]["max_hp"]) - bh.max_hp) < 1.0, 3.0), "%s: the guest's HUD shows its plate" % tag)
	# ---- the guest can aim at it: its own core host knows the boss by the id the host's core gave it, so the hover pick finds it
	await stand(id)
	await ticks(20)
	check(await until(func() -> bool: return bg.core_id == bh.core_id and g.core_host.enemies_in_radius(bg.global_position, 3.0).has(bh.core_id), 5.0), "%s: the guest's core host knows it by the host's id (%d) and names it among the bodies near it" % [tag, bh.core_id])
	var chest := Vector3(bg.global_position.x, 1.7, bg.global_position.z)
	check(await until(func() -> bool: return g.input.pick_enemy(g.camera.unproject_position(chest)) == bh.core_id, 3.0), "%s: and the guest's hover pick finds it under the cursor" % tag)
	var info: Array = [{}]
	check(await until(func() -> bool:
		info[0] = g.core_host.enemy_info(bh.core_id)
		return not info[0].is_empty() and bool(info[0].get("boss", false)) and int(info[0]["state"]) != DmCoreEvents.State.DEAD and absf(float(info[0]["hp"]) - bh.hp) <= bh.max_hp * 0.03, 3.0), "%s: the guest's record of it is alive, with its health (%.0f)" % [tag, float(info[0].get("hp", -1.0))])
	if id == "abbess":
		g.joiner.prog.add_shards(int(DmContent.boss("gravedigger")["shards"]))
		var held := int(g.joiner.prog.local["shards"])
		toasts.clear()
		g.bosses.request_summon("gravedigger")
		check(await until(func() -> bool: return toasts.has(String(DmBossHost.WHY["busy"])), 5.0), "%s: a second summon while it is awake is refused to the guest in words (%s)" % [tag, str(toasts)])
		check(int(g.joiner.prog.local["shards"]) == held and h.bosses.active_boss() == bh, "%s: and costs the guest nothing" % tag)
	# ---- the fight on the real clock
	rootp["free"] = await probe_move()   # a control: nothing holds the guest's hero, its move intent walks it
	await stand(id)
	var legion_at: Vector3 = arena_of(id) + (sp["guest"] as Vector3) + Vector3(0.0, 0.0, -3.0)   # the guest's legion: a thrall of its hero, a body of the host's core, beside it
	h.core_host.core.raise_thrall(thrall_stats("warrior", 1.0e6, 30.0), gb_h.core_id, Vector2(legion_at.x, legion_at.z), 0.0, 120.0)
	await fight_loop(id, bh, bg)
	for k in sp["kinds"]:
		check(int(ev_h.get(k + "!", 0)) >= 2, "%s: its %s landed (%d impacts, %d telegraphs)" % [tag, k, int(ev_h.get(k + "!", 0)), int(ev_h.get(k, 0))])
	check(int(hits_on["guest"]) >= 3 and int(hits_on["host"]) >= 2, "%s: the casts of both heroes hurt it: the host's hero %d hits, the guest's %d (resolved on the host)" % [tag, hits_on["host"], hits_on["guest"]])
	check(int(blows_on[2]) >= 3, "%s: its blows reached the guest's hero (%d, the host's hero %d)" % [tag, blows_on[2], blows_on[1]])
	check(thrall_hits >= 1 and thrall_credit and swings_g >= 1, "%s: the guest's thrall hurt it through the core (%d blows, credited to the guest; the guest's puppet saw %d swings)" % [tag, thrall_hits, swings_g])
	check(not tele_kinds.is_empty() and tele_kinds.keys().all(func(k: String) -> bool: return ev_h.has(k)), "%s: the guest's copy showed its telegraphs (%s)" % [tag, str(tele_kinds.keys())])
	bh.set_physics_process(false)   # the brain waits while the two sides are compared
	await ticks(60)
	check(await until(func() -> bool: return same_state(bh, bg), 3.0), "%s: the guest's copy follows its state (%.0f against %.0f hp, phase %d against %d, %s against %s)" % [tag, bg.hp, bh.hp, bg.phase, bh.phase, bg.bstate.state, bh.bstate.state])
	check(await until(func() -> bool: return ev_h == ev_g, 3.0), "%s: its events were played on both sides, kind for kind (%d on the host, %d on the guest)" % [tag, _sum(ev_h), _sum(ev_g)])
	if ev_h != ev_g:
		print("INFO coop_bosses events differ: host %s guest %s" % [str(ev_h), str(ev_g)])
	check(bg.global_position.distance_to(bh.global_position) < 0.6, "%s: the guest's copy stands where it does (%.2f m apart)" % [tag, bg.global_position.distance_to(bh.global_position)])
	check(stub_h.calls == stub_g.calls and int(stub_h.calls.get("decal", 0)) >= 3, "%s: the guest drew what the host drew for it: %d telegraph shapes and impacts on the ground, %s against %s" % [tag, int(stub_g.calls.get("decal", 0)), str(stub_g.calls), str(stub_h.calls)])
	var sh := astub_h.sfx.duplicate()
	var sg := astub_g.sfx.duplicate()
	sh.sort()
	sg.sort()
	check(sh == sg and not sh.is_empty(), "%s: and played the same sounds (%d)" % [tag, sh.size()])
	check(hp_dip < gb_g.max_hp - 1.0, "%s: the guest's own client showed its hero hurt (down to %.0f of %.0f)" % [tag, hp_dip, gb_g.max_hp])
	# the guest's window: a number, the red flash and the hurt sound for what hurt its hero (the vitals' falls: a few blows within 50 ms are one), and the host's own window only for the host's hero
	var hurt_g := tapped(tap_g, "floats", "hurt") - tapped(tap0_g, "floats", "hurt")
	var hurt_h := tapped(tap_h, "floats", "hurt") - tapped(tap0_h, "floats", "hurt")
	check(hurt_g >= 1 and hurt_g <= int(hurt_events[2]), "%s: its blows on the guest's hero were hurt numbers on the guest's window (%d for %d blows of all kinds)" % [tag, hurt_g, hurt_events[2]])
	check(tap_g["flash"] - tap0_g["flash"] == hurt_g and tapped(tap_g, "sfx", "hurt") - tapped(tap0_g, "sfx", "hurt") == hurt_g, "%s: each with the red flash (%d) and the hurt sound (%d)" % [tag, tap_g["flash"] - tap0_g["flash"], tapped(tap_g, "sfx", "hurt") - tapped(tap0_g, "sfx", "hurt")])
	check(hurt_h == int(hurt_events[1]) and tap_h["flash"] - tap0_h["flash"] == hurt_h, "%s: the host's window numbered and flashed the blows on the host's hero only (%d of %d)" % [tag, hurt_h, hurt_events[1]])
	check(cmp["frames"] >= 100 and cmp["bad"] == 0, "%s: every body the guest holds is the host's at that tick (%d bodies in %d snapshots, %d off)" % [tag, cmp["bodies"], cmp["frames"], cmp["bad"]])
	await specifics(id, bh, bg, tag)
	bh.set_physics_process(true)
	# ---- the phases
	var adds0 := living(h) - int(defs_of(h).get("niche", 0))
	await to_phase(id, bh, bg, 0.55, 2, tag)
	if id == "abbess":
		await abbess_breaks(bh, bg, tag)
	await to_phase(id, bh, bg, 0.25, 3, tag)
	await ticks(60)
	var adds1 := living(h) - int(defs_of(h).get("niche", 0))
	if id == "abbess":
		check(ids_of(h, "niche").size() == 4, "%s: she rebuilt the two niches (%d stand)" % [tag, ids_of(h, "niche").size()])
	else:
		check(adds1 >= adds0 + int(sp["p2"]) + int(sp["p3"]), "%s: its waves are in the core (%d new bodies, %d wanted)" % [tag, adds1 - adds0, int(sp["p2"]) + int(sp["p3"])])
	check(await until(func() -> bool: return defs_of(h) == defs_of(g), 4.0), "%s: and the guest's core holds the same bodies (%s)" % [tag, str(defs_of(g))])
	check(await until(func() -> bool: return ev_h == ev_g, 3.0), "%s: the phases' events were played on both sides, kind for kind (%d and %d)" % [tag, _sum(ev_h), _sum(ev_g)])
	if id == "abbess":
		check(niche_max(h).size() == 4 and await until(func() -> bool: return niche_max(g) == niche_max(h), 3.0), "%s: the guest knows the niches' health the host gave them (%s)" % [tag, str(niche_max(h))])
	check(cmp["bad"] == 0, "%s: and through the phases every body the guest holds was the host's (%d bodies in %d snapshots, %d off)" % [tag, cmp["bodies"], cmp["frames"], cmp["bad"]])
	var banners_g := hud_feed(hud_g).filter(func(t: String) -> bool: return t.begins_with("banner: "))
	var phase_names: Array = [String(bd["name"])]
	if id == "prelate":
		phase_names.append_array(["The Procession", "The Bell Breaks"])
	else:
		phase_names.append_array([String(bd["phases"][1]), String(bd["phases"][2])])
	check(hud_feed(hud_h) == hud_feed(hud_g) and phase_names.all(func(n: String) -> bool: return banners_g.has("banner: " + n)), "%s: the guest's HUD was told what the host's was: its awakening and both phases' banners (%s)" % [tag, str(banners_g)])
	await late_fight(id, bh, bg, tag)
	await defeat(id, bh, bg, tag)


## The attacks one after the other until everything wanted has happened, or the time is up. The heroes cast at the boss every half second.
func fight_loop(id: String, bh: DmBoss, bg: DmBoss) -> void:
	var sp: Dictionary = SPEC[id]
	var rot: Array = sp["rot"]
	var kinds: Array = sp["kinds"]
	var rot_n := 0
	for i in FIGHT_TICKS:
		await physics_frame
		compare_sample()
		for t in bg.telegraphs:
			tele_kinds[String(t[0])] = true
		hp_dip = minf(hp_dip, gb_g.hp)
		if bg.bstate.state == "sunk":
			sunk_g += 1
			sunk_bad += 1 if bg.is_hittable() else 0
		var st := DmStatusSet.of(gb_h)
		chill_h = chill_h or (st != null and st.has(&"chill"))
		var sg := DmStatusSet.of(gb_g)
		chill_g = chill_g or (sg != null and sg.has(&"chill"))
		if i % 30 == 0:
			cast_at_boss(bh)
		if i % 20 == 0:
			if sp.has("side") and i % 160 == 0:
				bh.brain.set(StringName(sp["side"]), 0.0)
			if bh.brain.pending.is_empty():
				bh.brain.set(StringName(String(rot[rot_n % rot.size()])), 0.0)
				rot_n += 1
		if rootp["event"] and not rootp["probed"]:
			rootp["probed"] = true
			rootp["held"] = await probe_move()
		if i >= MIN_FIGHT_TICKS and kinds.all(func(k: String) -> bool: return int(ev_h.get(k + "!", 0)) >= 2) and int(hits_on["guest"]) >= 3 and int(hits_on["host"]) >= 2 and int(blows_on[2]) >= 3 and not tele_kinds.is_empty() and thrall_hits >= 1 and swings_g >= 1 and needs_met(id):
			break


## What a boss's fight must also have shown before the loop ends.
func needs_met(id: String) -> bool:
	match id:
		"congregation":
			return chill_h and chill_g and rootp["probed"]
		"mire":
			return rootp["probed"] and sunk_g > 0
		"saint", "regent":
			return int(zones_h.get(SPEC[id]["zone"], 0)) >= 3
	return true


## The checks of what a boss's attacks do besides damage, on the state the loop ended in (the brain is waiting).
func specifics(id: String, bh: DmBoss, bg: DmBoss, tag: String) -> void:
	if id == "congregation" or id == "mire":
		check(rootp["probed"] and float(rootp["left"]) >= 900.0, "%s: its %s rooted the guest's hero on the host for a second (%.0f ms left when it landed)" % [tag, "Drowning Grasp" if id == "congregation" else "Drowned Hands", rootp["left"]])
		check(float(rootp["free"]) > 0.8 and float(rootp["held"]) >= 0.0 and float(rootp["held"]) < 0.3, "%s: and the guest's move intent did not walk it (%.1f m free, %.1f m rooted)" % [tag, rootp["free"], rootp["held"]])
	if id == "congregation":
		check(chill_h and chill_g, "%s: the Flood Hymn chilled the guest's hero, and the guest's copy of the status shows it (host %s, guest %s)" % [tag, chill_h, chill_g])
	if id == "mire":
		check(sunk_g > 0 and sunk_bad == 0, "%s: she sank on the guest's copy too, untargetable there (%d ticks, %d of them counted hittable)" % [tag, sunk_g, sunk_bad])
	if SPEC[id].has("zone"):
		var kind := String(SPEC[id]["zone"])
		await until(func() -> bool: return int(zones_g.get(kind, 0)) == int(zones_h.get(kind, 0)), 2.0)
		check(int(zones_h.get(kind, 0)) >= 1 and zones_h.get(kind, 0) == zones_g.get(kind, -1), "%s: its %s pools are zones of the core with the boss as their source: %d on the host, %d on the guest" % [tag, kind, int(zones_h.get(kind, 0)), int(zones_g.get(kind, 0))])
		var dh := int(h.enemy_fx.stats["zone"]) - zfx_h
		var dg := int(g.enemy_fx.stats["zone"]) - zfx_g
		check(dh >= 1 and dg == dh, "%s: and the guest's effects drew them as the host's did (%d visuals, %d on the host)" % [tag, dg, dh])


## The boss to `frac` of its health through a blow of the guest's hero (so the guest has the credit), and the phase `n` on both sides.
func to_phase(id: String, bh: DmBoss, bg: DmBoss, frac: float, n: int, tag: String) -> void:
	await until(func() -> bool: return bh.is_hittable(), 12.0)   # the Mire Mother cannot be hurt while she is sunk
	if bh.hp > bh.max_hp * frac:
		bh.take_damage(bh.hp - bh.max_hp * frac, gb_h)
	check(await until(func() -> bool: return bh.phase == n and bg.phase == n, 6.0), "%s: at %d %% of its health it is in phase %d on the host and on the guest (%d, %d)" % [tag, int(frac * 100.0), n, bh.phase, bg.phase])
	await ticks(30)
	if id == "congregation":   # the nave's water rises each phase: whoever wades outside her dais is slower, the host's body of the guest's hero included
		var C: Dictionary = DmContent.get_export("bosses", "CONGREGATION")["water"]
		var arena := arena_of(id)
		gb_h.teleport(arena + Vector3(float(C["dais"]) + 3.0, 0.0, 0.0))
		await ticks(20)
		var want := float(C["slowP3"]) if n >= 3 else float(C["slowP2"])
		check(absf(gb_h.wade_mult - want) < 1e-6, "%s: the water at phase %d slows the guest's hero outside the dais (x%.2f, wanted x%.2f)" % [tag, n, gb_h.wade_mult, want])
		await stand(id)


## The last phase's own attack once more, with the heroes casting: Bone Communion devours the corpses lying in her arena, the Drowned Rite raises them as Risen, Conflagration burns the arena,
## the Prelate's and the Saint's rain falls on every hero. What it made (events, bodies, zones, corpses) is the same on the guest.
func late_fight(id: String, bh: DmBoss, bg: DmBoss, tag: String) -> void:
	var sp: Dictionary = SPEC[id]
	var arena := arena_of(id)
	var area := String(DmContent.boss(id)["area"])
	var corpses := id == "abbess" or id == "mire"
	if corpses:
		for k in 3:
			h.core_host.corpses.add_corpse(arena.x + 3.0 + float(k), arena.z + 4.0 - float(k) * 2.0, "normal", "robber", false, 0.0, 1.0, area)
		check(await until(func() -> bool: return h.core_host.core.corpse_count() == 3 and g.core_host.core.corpse_count() == 3, 3.0), "%s: three corpses lie in its arena, on both cores" % tag)
	var kinds: Array = sp["late_kinds"]
	var before := {}
	for k in kinds:
		before[k] = int(ev_h.get(k + "!", 0))
	await stand(id)
	for i in 60 * 30:
		await physics_frame
		compare_sample()
		if i % 30 == 0:
			cast_at_boss(bh)
		if i % 20 == 0 and bh.brain.pending.is_empty():
			bh.brain.set(StringName(String(sp["late"])), 0.0)
		if kinds.all(func(k: String) -> bool: return int(ev_h.get(k + "!", 0)) > int(before[k])):
			break
	for k in kinds:
		check(int(ev_h.get(k + "!", 0)) > int(before[k]), "%s: its %s of the last phase landed" % [tag, k])
	bh.set_physics_process(false)
	await ticks(60)
	if corpses:
		check(await until(func() -> bool: return h.core_host.core.corpse_count() == 0 and g.core_host.core.corpse_count() == 0, 4.0), "%s: the corpses were %s on both cores" % [tag, "devoured" if id == "abbess" else "raised"])
	if id == "mire":
		check(ids_of(h, "risen").size() >= 3 and await until(func() -> bool: return ids_of(g, "risen").size() == ids_of(h, "risen").size(), 3.0), "%s: and three Risen stand where they lay, on both cores (%d, %d)" % [tag, ids_of(h, "risen").size(), ids_of(g, "risen").size()])
	check(await until(func() -> bool: return ev_h == ev_g, 3.0), "%s: and its events were played on both sides, kind for kind (%d and %d)" % [tag, _sum(ev_h), _sum(ev_g)])
	check(await until(func() -> bool: return defs_of(h) == defs_of(g), 3.0), "%s: the bodies are the same on both cores (%s)" % [tag, str(defs_of(g))])
	check(stub_h.calls == stub_g.calls, "%s: the guest drew what the host drew: %s against %s" % [tag, str(stub_g.calls), str(stub_h.calls)])
	if sp.has("zone"):
		await until(func() -> bool: return int(zones_g.get(sp["zone"], 0)) == int(zones_h.get(sp["zone"], 0)), 2.0)
		check(int(zones_h.get(sp["zone"], 0)) >= 1 and zones_h.get(sp["zone"], 0) == zones_g.get(sp["zone"], -1), "%s: the %s zones are the same on both cores (%d, %d)" % [tag, sp["zone"], int(zones_h.get(sp["zone"], 0)), int(zones_g.get(sp["zone"], 0))])
	check(cmp["bad"] == 0, "%s: and every body the guest holds was the host's (%d bodies in %d snapshots, %d off)" % [tag, cmp["bodies"], cmp["frames"], cmp["bad"]])
	bh.set_physics_process(true)


## The Abbess's niches, broken by the heroes: one by a cast of the guest at the niche it found on its own core, one by a blow of the guest's hero on the host's core. Each tears at her and
## says so (`nicheBreak`) on both sides, and the niche leaves both tables without a corpse.
func abbess_breaks(bh: DmBoss, bg: DmBoss, tag: String) -> void:
	var niches := ids_of(h, "niche")
	check(niches.size() == 4, "%s: four niches stand on the host" % tag)
	if niches.size() < 2:
		return
	check(await until(func() -> bool: return ids_of(g, "niche").size() == 4, 3.0), "%s: and on the guest" % tag)
	var corpses0: int = h.core_host.core.corpse_count()
	var hp0 := bh.hp
	var a: int = niches[0]
	var b: int = niches[1]
	h.core_host.core.set_enemy_hp(a, 1.0, 1.0)   # (a niche has 7 % of her health: weakened so one needle breaks it)
	await until(func() -> bool: return float(g.core_host.core.enemy_info(a)["hp"]) <= 1.0, 3.0)
	var at := g.core_host.enemy_position(a)
	for i in 30:   # the guest aims at the niche it sees on its own core
		if int(h.core_host.core.enemy_info(a)["state"]) == DEAD_STATE:
			break
		rites_g.request_cast("bone_needle", at, a)
		await ticks(10)
	check(int(h.core_host.core.enemy_info(a)["state"]) == DEAD_STATE, "%s: the guest's cast broke a niche on the host" % tag)
	h.core_host.damage(b, 1.0e9, gb_h.core_id)
	check(await until(func() -> bool: return ids_of(h, "niche").size() == 2 and ids_of(g, "niche").size() == 2, 3.0), "%s: two niches left both cores (%d and %d)" % [tag, ids_of(h, "niche").size(), ids_of(g, "niche").size()])
	check(await until(func() -> bool: return int(ev_h.get("nicheBreak!", 0)) == 2 and int(ev_g.get("nicheBreak!", 0)) == 2, 3.0), "%s: each said so on both sides (%d, %d)" % [tag, int(ev_h.get("nicheBreak!", 0)), int(ev_g.get("nicheBreak!", 0))])
	check(bh.hp < hp0 and h.core_host.core.corpse_count() == corpses0 and g.core_host.core.corpse_count() == corpses0, "%s: they tore at her and lay no corpse" % tag)


## The defeat by a cast of the guest, and what both accounts get.
func defeat(id: String, bh: DmBoss, bg: DmBoss, tag: String) -> void:
	await stand(id)
	await until(func() -> bool: return bh.is_hittable() and hb.alive and gb_h.alive, 12.0)
	for t in h.core_host.core.thrall_ids():   # (the guest's thrall would take the last point itself)
		h.core_host.core.kill_thrall(t, "killed")
	bh.set_physics_process(false)   # nothing heals or hits while the last point is taken
	if String(bh.brain.state["state"]) == "sunk":
		bh.brain.state["state"] = "idle"
		bh.bstate.state = "idle"
	bh.brain.state["hp"] = 1.0
	bh.hp = 1.0
	await ticks(3)
	var hm: DmRewardsMember = h.rewards.members.get(cid_h)
	var gm: DmRewardsMember = h.rewards.members.get(cid_g)
	var jm: DmRewardsMember = g.joiner.member
	var xp_h := int(hm.stats["xp_applied"])
	var xp_g := int(jm.stats["xp_applied"])
	var bosses_h := int(hm.stats["bosses"])
	var bosses_g := int(gm.stats["bosses"])
	var dh := int(drops_h.get(cid_h, 0))
	var dg := int(drops_h.get(cid_g, 0))
	var received := g.joiner.drops_received
	var d0 := deaths.duplicate()
	var corpses0: int = h.core_host.core.corpse_count()
	var adds := living(h)
	var killed := [false]
	var cb := func(_r: String, hid: int, _a: float, _c: bool, k: bool) -> void: killed[0] = killed[0] or (hid == bh.core_id and k)
	rites_hg.hit_resolved.connect(cb)
	for i in 300:
		if bh.dead:
			break
		if i % 10 == 0:
			rites_g.request_cast("bone_needle", bh.global_position, -1)
		await physics_frame
	rites_hg.hit_resolved.disconnect(cb)
	check(bh.dead and killed[0], "%s: the guest's cast on the host's core took its last point" % tag)
	if not bh.dead:
		bh.take_damage(1.0e9, gb_h)
	var pending_both: bool = hm.reporter.has_pending() and gm.reporter.has_pending()   # (the host's reports go out on its own clock)
	check(await until(func() -> bool: return fell[0] != null, 3.0) and fell[0][0] == id and fell[0][1] == 2, "%s: `defeated` names the guest (%s)" % [tag, str(fell[0])])
	check(await until(func() -> bool: return here(bg) and bg.bstate.state == "dead" and bg.hp <= 0.0 and not bg.bstate.active and g.bosses.active_boss() == null, 5.0), "%s: it is dead on the guest too (%s, %.0f hp)" % [tag, bg.bstate.state if here(bg) else "gone", bg.hp if here(bg) else 0.0])
	check(await until(func() -> bool: return ev_h == ev_g and int(ev_g.get("defeated!", 0)) == 1, 3.0), "%s: the defeat was played on both sides (%d, %d events in all)" % [tag, _sum(ev_h), _sum(ev_g)])
	check(g.ui_host.hud_state()["boss"] == null, "%s: the guest's plate is gone" % tag)
	check(await until(func() -> bool: return not here(bg) or bg.view == null or not bg.view.is_shown(), 8.0), "%s: and its model fades out on the guest" % tag)
	# both accounts are paid
	var by_cid := {}
	for e in earned_log:
		by_cid[int(e[0])] = e
	check(by_cid.has(cid_h) and by_cid.has(cid_g) and earned_log.size() == 2, "%s: both members were paid for the kill (%s)" % [tag, str(earned_log)])
	if by_cid.has(cid_h):
		check(bool(by_cid[cid_h][2]) == (id != "prelate"), "%s: the host's account got its first-kill bonus and trophy (the Prelate has none: its kill is the run's tally)" % tag)
	if by_cid.has(cid_g):
		check(not bool(by_cid[cid_g][2]), "%s: the guest's first-kill trophy is its own backend's business (later), as in today's game: no bonus" % tag)
	check(int(hm.stats["bosses"]) == bosses_h + 1 and int(gm.stats["bosses"]) == bosses_g + 1, "%s: each member's kill count and report entry took the boss (%d, %d)" % [tag, int(hm.stats["bosses"]), int(gm.stats["bosses"])])
	check(pending_both, "%s: both reports held the boss as it fell" % tag)
	check(int(drops_h.get(cid_h, 0)) - dh >= 2 and int(drops_h.get(cid_g, 0)) - dg >= 2, "%s: gold and shards fell for each (%d for the host's, %d for the guest's)" % [tag, int(drops_h.get(cid_h, 0)) - dh, int(drops_h.get(cid_g, 0)) - dg])
	check(await until(func() -> bool: return g.joiner.drops_received - received >= 3, 4.0), "%s: and reached the guest's own client, its drop event among them (%d)" % [tag, g.joiner.drops_received - received])
	check(await until(func() -> bool: return int(jm.stats["xp_applied"]) > xp_g, 4.0) and int(hm.stats["xp_applied"]) > xp_h, "%s: both got the boss's XP, the guest's on its own account (%d, the host's %d)" % [tag, int(jm.stats["xp_applied"]) - xp_g, int(hm.stats["xp_applied"]) - xp_h])
	await h.rewards.flush()
	check(not hm.reporter.has_pending() and not gm.reporter.has_pending(), "%s: and the backend's party session took both reports" % tag)
	if id == "prelate":
		print("INFO coop_bosses prelate: the run's Prelate tally: the host's member %s, the guest's own progression %s, the guest's stand-in on the host %s" % [str(hm.prog.can_ascend()), str(g.joiner.prog.can_ascend()), str(gm.prog.can_ascend())])
	# what it called left without a death
	check(await until(func() -> bool: return living(h) == 0 and living(g) == 0, 3.0), "%s: its %d bodies left both cores" % [tag, adds])
	check(deaths["host"] == d0["host"] and deaths["guest"] == d0["guest"] and h.core_host.core.corpse_count() == corpses0, "%s: with no death, no corpse and no credit" % tag)


# ------------------------------------------------------------------------------------------------------------------ the second summon: a wipe

func wipe(id: String) -> void:
	var bd: Dictionary = DmContent.boss(id)
	var cost := int(bd["shards"])
	var tag := String(bd["name"])
	await to_site(id)
	cur_core = 0
	reset_watch()
	earned_log.clear()
	fell[0] = null
	reset_n[0] = 0
	h.my_member().prog.add_shards(cost)
	check(h.bosses.try_summon(1, id) == "", "%s: the host woke it again with its own shards (an earlier body may still lie there)" % tag)
	check(await until(func() -> bool: return h.bosses.active_boss() != null and h.bosses.active_boss().is_hittable() and g.bosses.active_boss() != null, 12.0), "%s: awake on both sides" % tag)
	var bh := h.bosses.active_boss()
	var bg := g.bosses.active_boss()
	if bh == null or bg == null:
		finish_early("%s did not wake for the wipe" % tag)
		return
	cur_core = bh.core_id
	check(bg != null and bg.bstate.active and bh.dead == false, "%s: a fresh body" % tag)
	await stand(id)
	await to_phase(id, bh, bg, 0.55, 2, tag)
	var adds := living(h)
	check(adds >= 1 or id == "abbess", "%s: its wave is out (%d bodies)" % [tag, adds])
	check(await until(func() -> bool: return defs_of(h) == defs_of(g), 4.0), "%s: on both cores" % tag)
	var d0 := deaths.duplicate()
	var corpses0: int = h.core_host.core.corpse_count()
	var earned0 := earned_log.size()
	var ev0 := _sum(ev_h)
	gb_h.take_damage(1.0e9, 0)
	hb.take_damage(1.0e9, 0)
	check(not gb_h.alive and not hb.alive, "%s: both heroes fell" % tag)
	check(await until(func() -> bool: return reset_n[0] == 1, 3.0), "%s: it reset on the host" % tag)
	check(await until(func() -> bool: return g.bosses.active_boss() == null and (not here(bg) or (not bg.bstate.active and bg.bstate.state == "idle")), 5.0), "%s: and on the guest (%s)" % [tag, bg.bstate.state if here(bg) else "gone"])
	check(await until(func() -> bool: return living(h) == 0 and living(g) == 0, 3.0), "%s: its bodies left both cores" % tag)
	check(await until(func() -> bool: return not here(bg) or bg.view == null or not bg.view.is_shown(), 8.0), "%s: and its model is gone on the guest" % tag)
	check(deaths["host"] == d0["host"] and deaths["guest"] == d0["guest"] and h.core_host.core.corpse_count() == corpses0 and g.core_host.core.corpse_count() == corpses0, "%s: without a death, a corpse or a credit" % tag)
	check(fell[0] == null and earned_log.size() == earned0, "%s: and nothing was paid" % tag)
	check(await until(func() -> bool: return ev_h == ev_g and _sum(ev_h) > ev0, 3.0), "%s: the reset was played on both sides, kind for kind (%d and %d events)" % [tag, _sum(ev_h), _sum(ev_g)])
	check(await until(func() -> bool: return hb.alive and gb_h.alive and gb_g.alive, 10.0), "%s: both heroes got up again, on both sides" % tag)
	check(await until(func() -> bool: return h.bosses.bosses.is_empty() and g.bosses.bosses.is_empty(), 14.0), "%s: and its bodies were freed on both sides (%d, %d)" % [tag, h.bosses.bosses.size(), g.bosses.bosses.size()])
