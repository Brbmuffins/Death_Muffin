class_name DmBossHost
extends Node
## The bosses of the slice, one node per peer at the same path (`Bosses` under DmNextGame). Host: summon rules (soul shards at the boss's grave / altar / bell),
## spawns the DmBoss body (MultiplayerSpawner), turns the brain's events into consequences (player hurt, root, thrall damage, defeat -> rewards)
## and broadcasts the boss events + 20 Hz state to the other peers. Every peer: DmBossFx plays each event once, the boss music follows the local
## hero. Solo is the same code on the OfflineMultiplayerPeer.
## Seams on DmNextGame: `bosses` (this node).
## Ported to the combat core (client/code.list "Ported"): a boss body registers with the core's host as an external of kind 1 (DmBoss, `core_id`), whose queries include
## the living bosses after the enemies (so rites and the hover pick hit them), whose thralls' blows come back as `thrall_hit_external` (routed to the brain here) and
## whose adds are core bodies. The boss pools (`spawn_pool`, `toxic_zones`: the Saint's rot, the Regent's coals) are core zones (DmBossNodeWorld makes them with the boss as the source,
## DmEnemyFx draws them from the zone events), so none of that is here.

signal boss_spawned(boss: DmBoss)                 ## every peer, once in the tree
signal summoned(boss_id: String, by_peer: int)    ## host
signal summon_refused(boss_id: String, why: String, by_peer: int)   ## host
signal defeated(boss_id: String, killer_peer: int, pos: Vector3)    ## host: a real kill (not a wipe reset)
signal brain_event(ev: Dictionary, boss: DmBoss)  ## host: every event the brain emitted (hurt included), after its consequences
signal reset(boss_id: String)                     ## host: the party wiped / left, the boss went back to sleep

## The bosses this build knows (each in its own area, whichever the world has open; area-agnostic). One line per boss track. `served_areas` says which of them it wakes.
const LIVE := ["gravedigger", "abbess", "congregation", "prelate", "saint", "regent", "mire"]
const ID_BASE := 1000000                          ## dm_id of bosses (the director's ids are small)
const SUMMON_RANGE := 4.0                         ## metres from the site
const SEND_HZ := 20.0
const FREE_S := 8.0                               ## a defeated body stays this long (the view fades after 2.5 s)
const WHY := {"busy": "Another boss is awake.", "far": "Stand at its altar to wake it.", "shards": "%s demands %d soul shards%s. Elites carry them.",
	"dead": "You are dead.", "unknown": "Nothing sleeps here.", "area": "Nothing sleeps here."}

var game: Node                                    ## DmNextGame
var area_id: String = "graves"                    ## fallback area of an enemy that carries no `dm_area`
## Areas whose bosses this host wakes (each boss's own DmContent.boss(id).area is its arena; a boss in another area is "unknown" here): all seven. A boss of an area the game scene did
## not load wakes on a floor that is not there, so the game loads the area first (tests load the one they fight in).
var served_areas: Array = ["graves", "ossuary", "nave", "sanctum", "cloister", "pyre", "fen"]
var difficulty: String = "medium"                 ## DmNextMeta: Settings -> difficulty (the brains read it: hp, damage)
var vow_fx: Dictionary = {}                       ## DmNextMeta: the sworn world vows (levels: Elder Dead, echoes: Prelate Echoes)
var visual: bool = true                           ## false = no DmBossView (headless)
var audio_enabled: bool = false                   ## boss music on the local hero's area
var assume_area: String = ""                      ## tests without a world: players count as in this area
var rng := RandomNumberGenerator.new()
var bosses: Dictionary = {}                       ## dm_id -> DmBoss (every peer)
var fx: DmBossFx
var site_hook := Callable()                       ## DmBossMeta.use_site(boss_id): the Covenant Seal choice before a plain summon (host)
var packets_sent: int = 0
var states_applied: int = 0

var _holder: Node3D
var _spawner: MultiplayerSpawner
var _next: int = 1
var _acc: float = 0.0
var _slow: float = 0.0
var _music: bool = false
var _wade_t: float = 0.0
var _wading: bool = false


func _ready() -> void:
	rng.randomize()
	_holder = Node3D.new()
	_holder.name = "Bodies"
	add_child(_holder)
	_spawner = MultiplayerSpawner.new()
	_spawner.name = "Spawner"
	add_child(_spawner)
	_spawner.spawn_path = NodePath("../Bodies")
	_spawner.spawn_function = Callable(self, "_spawn_boss")
	fx = DmBossFx.new()
	fx.name = "Fx"
	fx.host.hide_view = _hide_view
	add_child(fx)
	var ch := core_host()
	if ch != null:
		ch.thrall_hit_external.connect(_on_thrall_hit)
	if not InputMap.has_action(&"dm_interact"):
		InputMap.add_action(&"dm_interact")
		var k := InputEventKey.new()
		k.physical_keycode = KEY_E
		InputMap.action_add_event(&"dm_interact", k)


## Loading time: the model of every boss this host wakes is read once, the fx shapes warmed (never mid-fight). The adds are crowd bodies, baked with the crowd.
func warm(at: Vector3) -> void:
	for id in LIVE:
		var bd: Dictionary = DmContent.boss(String(id))
		if served_areas.has(bd["area"]):
			DmCreature.new(String(bd["modelSlug"]), {}).root.free()
	fx.warm(at)


# ---- queries (every peer) ------------------------------------------------------------------------------------------------------

## The game scene's combat core host (null in a harness without one).
func core_host() -> DmCoreHost:
	return game.get("core_host") as DmCoreHost if game != null else null


## Awake AND hittable bosses (a sunk Mire Mother is awake but not here).
func living() -> Array[DmBoss]:
	var out: Array[DmBoss] = []
	for b in bosses.values():
		if is_instance_valid(b) and (b as DmBoss).is_hittable():
			out.append(b)
	return out


## The awake boss (hittable or not: a sunk Mire Mother still blocks a second summon and keeps the bar / music).
func active_boss() -> DmBoss:
	for b in bosses.values():
		if is_instance_valid(b) and (b as DmBoss).is_awake():
			return b
	return null


func _area_for(peer: int) -> String:
	var a: String = game.area_of(peer)
	return a if a != "" else assume_area


## The area of a ground point (the world's; `assume_area` where there is no world / outside every area).
func area_at(x: float, z: float) -> String:
	var a: String = game.area_at(x, z)
	return a if a != "" else assume_area


func arena_area(boss_id: String) -> String:
	return String(DmContent.boss(boss_id)["area"])


func boss_by_id(id: int) -> DmBoss:
	var b: Variant = bosses.get(id)
	return b if b != null and is_instance_valid(b) else null


func heroes() -> Array:
	var out: Array = []
	for b in game.session.get_bodies():
		if b is DmHeroBody:
			out.append(b)
	return out


## The grave's position (the area's interactable named by the boss's summonId).
func site_pos(boss_id: String) -> Vector3:
	var sid := String(DmContent.boss(boss_id)["summonId"])
	for it in DmContent.area(String(DmContent.boss(boss_id)["area"])).get("interactables", []):
		if String(it["id"]) == sid:
			return Vector3(float(it["x"]), 0.0, float(it["z"]))
	return Vector3.INF


## The live boss whose grave / altar / bell is within `r` of `pos` ("" = none): the E key and the hub prompt use it.
func site_near(pos: Vector3, r: float) -> String:
	for id in LIVE:
		if served_areas.has(String(DmContent.boss(String(id))["area"])):
			var s := site_pos(String(id))
			if s != Vector3.INF and Vector2(pos.x - s.x, pos.z - s.z).length() <= r:
				return String(id)
	return ""


# ---- summon (host rules; any peer may ask) ---------------------------------------------------------------------------------------

## Ask to wake `boss_id` (the local hero, at its site). Any peer; the host decides. On the host the BossMeta node's altar choice (Covenant
## Seal) comes first when it has one to offer (`site_hook`).
func request_summon(boss_id: String) -> void:
	if site_hook.is_valid() and multiplayer.is_server():
		site_hook.call(boss_id)
	else:
		request_summon_plain(boss_id)


## The soul-shard summon, no altar choice.
func request_summon_plain(boss_id: String) -> void:
	if multiplayer.is_server():
		var me: int = game.session.get_my_id()
		var why := try_summon(me, boss_id)
		if why != "":
			_say("toast", {"text": why_text(why, boss_id, me), "kind": "err"})
	else:
		# A party guest pays with its own shards (its DmNextJoiner progression, saved on its own account): too few is refused here, the host
		# checks the rest (far, busy, dead) and answers `_rpc_summoned`, then the shards are spent.
		var jp := _guest_prog()
		if jp != null and int(jp.local["shards"]) < _shard_cost(boss_id):
			_say("toast", {"text": String(WHY["shards"]) % [DmContent.boss(boss_id)["summonLabel"], _shard_cost(boss_id), " (you have %d)" % int(jp.local["shards"])], "kind": "err"})
			return
		_rpc_summon.rpc_id(1, boss_id)


## The soul shards a summon of `boss_id` costs (the Prelate's bell, else the area boss's own price).
func _shard_cost(boss_id: String) -> int:
	return int(DmContent.boss("prelate")["shards"]) if boss_id == "prelate" else int(DmContent.boss(boss_id)["shards"])


## A party guest's own progression (its shards), null on the host or solo.
func _guest_prog() -> DmProgression:
	var j: Variant = game.get("joiner")
	return j.prog if j != null and j.prog != null else null


## HOST. "" = woken; else the refusal: busy / far / shards / dead / unknown. Spends the boss's soul shards from the summoner's progression
## (an Empowered call pays the Seal and gold instead: no shards) (the Prelate's bell takes `spend_shards`, which also owes the run a Prelate summon; the area bosses `spend_boss_shards`).
func try_summon(peer: int, boss_id: String, empowered: bool = false) -> String:
	var why := _check(peer, boss_id)
	if why == "":
		var m := member_of(peer)
		# a remote member (party guest) paid with its own shards on its own client (request_summon_plain / _rpc_summoned): the host's copy of it holds none
		if m != null and not empowered and not m.remote and not (m.prog.spend_shards(int(DmContent.boss("prelate")["shards"])) if boss_id == "prelate" else m.prog.spend_boss_shards(boss_id)):
			why = "shards"
	if why != "":
		summon_refused.emit(boss_id, why, peer)
		return why
	_spawner.spawn({"boss": boss_id, "id": ID_BASE + _next, "emp": empowered, "by": peer})
	_next += 1
	summoned.emit(boss_id, peer)
	return ""


func _check(peer: int, boss_id: String) -> String:
	if not LIVE.has(boss_id) or not served_areas.has(String(DmContent.boss(boss_id)["area"])):
		return "unknown"
	var hb: DmHeroBody = game.body_of(peer)
	if hb == null or not hb.alive:
		return "dead"
	if active_boss() != null:
		return "busy"
	var s := site_pos(boss_id)
	if s == Vector3.INF or Vector2(hb.position.x - s.x, hb.position.z - s.z).length() > SUMMON_RANGE:
		return "far"
	return ""


func member_of(peer: int) -> DmRewardsMember:
	if game.rewards == null:
		return null
	for m in game.rewards.members.values():
		if (m as DmRewardsMember).peer_id == peer:
			return m
	return null


@rpc("any_peer", "call_remote", "reliable")
func _rpc_summon(boss_id: String) -> void:
	if not multiplayer.is_server():
		return
	var from := multiplayer.get_remote_sender_id()
	var why := try_summon(from, boss_id)
	if why != "":
		_rpc_refused.rpc_id(from, why, boss_id)
	else:
		_rpc_summoned.rpc_id(from, boss_id)


## Guest: the host woke the boss we asked for: our own shards pay for it (saved and checked by our backend, which credits the party's drops).
@rpc("authority", "call_remote", "reliable")
func _rpc_summoned(boss_id: String) -> void:
	var jp := _guest_prog()
	if jp == null:
		return
	var paid := jp.spend_shards(_shard_cost(boss_id)) if boss_id == "prelate" else jp.spend_boss_shards(boss_id)
	if not paid:
		push_warning("[coop] summoned %s but the shards were gone by the host's answer" % boss_id)


@rpc("authority", "call_remote", "reliable")
func _rpc_refused(why: String, boss_id: String) -> void:
	_say("toast", {"text": why_text(why, boss_id, game.session.get_my_id()), "kind": "err"})


## The refusal in words (the shard one names the site and the member's own count).
func why_text(why: String, boss_id: String, peer: int) -> String:
	if why != "shards" or not LIVE.has(boss_id):
		return String(WHY.get(why, why))
	var m := member_of(peer)
	return String(WHY["shards"]) % [DmContent.boss(boss_id)["summonLabel"], int(DmContent.boss(boss_id)["shards"]), " (you have %d)" % int(m.prog.local["shards"]) if m != null else ""]


func _say(id: String, ctx: Dictionary) -> void:
	fx.host.emit_game_event(id, ctx)


# ---- spawn (every peer) ------------------------------------------------------------------------------------------------------------

func _spawn_boss(data: Variant) -> Node:
	var id := String(data["boss"])
	DmBoss.ensure_def(id)
	var b := DmBoss.new()
	var dm_id := int(data["id"])
	b.name = "B%d" % dm_id
	b.boss_id = id
	b.def_id = DmBoss.def_key(id)
	b.empowered = bool(data["emp"])
	b.summoner = int(data["by"])
	b.host_node = self
	b.visual = visual
	var arena: Dictionary = DmContent.boss(id)["arena"]
	b.position = Vector3(float(arena["x"]), 0.0, float(arena["z"]))
	b.set_meta(&"dm_id", dm_id)
	b.set_meta(&"dm_area", String(arena_area(id)))
	b.set_multiplayer_authority(1)
	bosses[dm_id] = b
	b.tree_exiting.connect(func() -> void: bosses.erase(dm_id))
	b.ready.connect(func() -> void: boss_spawned.emit(b))
	return b


# ---- thralls' blows (host) ---------------------------------------------------------------------------------------------------------

## The core's EV_THRALL_HIT_EXTERNAL: a thrall's swing (or its Colossus's cleave) landed on boss `target`. It goes to the boss's damage path as the thrall node's did,
## with the thrall's owner as the credit (the brain's `last_hit_by` is its peer).
func _on_thrall_hit(thrall_id: int, target: int, _kind: String, damage: float) -> void:
	var ch := core_host()
	var b := ch.boss_for(target) as DmBoss
	if b == null:
		return
	b.take_damage(damage, ch.hero_for(int(ch.core.thrall_info(thrall_id).get("owner", 0))))


# ---- brain events (host) -----------------------------------------------------------------------------------------------------------

## Every event the brain emits: `hurt` is a consequence here (never sent), `boss` events are played here and sent to the other peers.
func on_brain_event(ev: Dictionary, boss: DmBoss) -> void:
	_route(ev, boss)
	brain_event.emit(ev, boss)


func _route(ev: Dictionary, boss: DmBoss) -> void:
	if String(ev["t"]) == "hurt":
		var hb: DmHeroBody = game.body_of(int(ev["player"]))
		if hb != null:
			hb.take_damage(float(ev["dmg"]), boss.core_id)   # the boss's id in the core, like any enemy's (its place, and Colossus Mantle's reflect back at it)
			if ev.get("chillMs") != null:   # the Flood Hymn chills whoever it hits
				hb.dm_enemy_effect(&"chill", {"seconds": float(ev["chillMs"]) / 1000.0, "from": boss})
		return
	if String(ev["t"]) != "boss":
		return
	var kind := String(ev["kind"])
	if float(ev.get("ms", 0.0)) == 0.0 and ev.get("root") != null:   # hands = the Mire Mother's Drowned Hands
		for pid in ev.get("players", []):
			var hb2: DmHeroBody = game.body_of(int(pid))
			if hb2 != null:
				hb2.root_for(float(ev["root"]))
	fx.play(ev)
	if not multiplayer.get_peers().is_empty():
		_rpc_event.rpc(ev)
	if kind == "defeated":
		_on_defeated(boss, ev)


@rpc("authority", "call_remote", "reliable")
func _rpc_event(ev: Dictionary) -> void:
	fx.play(ev)


func _on_defeated(boss: DmBoss, ev: Dictionary) -> void:
	var killer := String(ev.get("killer", ""))
	var at := Vector3(float(ev["x"]), 0.0, float(ev["z"]))
	boss.finish(killer != "")
	var free_t := Timer.new()   # a child of the body, so it goes with it (a SceneTreeTimer's lambda would call a freed boss)
	free_t.one_shot = true
	free_t.wait_time = FREE_S
	boss.add_child(free_t)
	free_t.timeout.connect(boss.queue_free)   # the spawner despawns it everywhere
	free_t.start()
	if killer == "":
		reset.emit(boss.boss_id)
		return
	defeated.emit(boss.boss_id, int(killer), at)
	if game.rewards != null:
		game.rewards.on_boss_defeated({"boss": boss.boss_id, "x": at.x, "z": at.z, "killer": game.body_of(int(killer)), "empowered": bool(ev.get("empowered", false))})
		var m := member_of(int(killer))
		if boss.boss_id == "prelate" and m != null and m.prog.can_ascend():
			_say("can_ascend", {})


func _hide_view(id: String) -> void:
	for b in bosses.values():
		if is_instance_valid(b) and (b as DmBoss).boss_id == id and (b as DmBoss).view != null:
			(b as DmBoss).view.hide()


## A late joiner's first snapshot of a phase-3 Gravedigger: the open graves have no event left to wait for.
func replay_pits(boss: DmBoss) -> void:
	if boss.boss_id != "gravedigger":
		return
	var spots: Array = []
	for p in DmContent.get_export("bosses", "GRAVEDIGGER_PITS"):
		spots.append([float(p[0]), float(p[1])])
	fx.play({"t": "boss", "kind": "pits", "x": boss.global_position.x, "z": boss.global_position.z, "phase": 3, "boss": boss.boss_id, "targets": spots,
		"r": float(DmContent.get_export("bosses", "GRAVEDIGGER")["pits"]["r"])})


# ---- replication (20 Hz) ----------------------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_wade(delta)
	if not multiplayer.is_server() or multiplayer.get_peers().is_empty() or bosses.is_empty():
		return
	_acc += delta
	if _acc < 1.0 / SEND_HZ:
		return
	_acc = fmod(_acc, 1.0 / SEND_HZ)
	var ids := PackedInt32Array()
	var states: Array = []
	for id in bosses:
		var b := bosses[id] as DmBoss
		if is_instance_valid(b) and b.is_inside_tree():
			ids.append(id)
			states.append(b.get_net_state())
	if not ids.is_empty():
		_rpc_state.rpc(ids, states)
		packets_sent += 1


## The Drowned Congregation: the nave water rises each phase; wading outside her dais is slower. Host, 10 Hz, only while
## she is awake or a body is still slowed.
func _wade(dt: float) -> void:
	_wade_t -= dt
	if _wade_t > 0.0:
		return
	_wade_t = 0.1
	if bosses.is_empty() and not _wading:
		return
	var b := active_boss()
	if b != null and b.boss_id != "congregation":
		b = null
	var awake := b != null and b.phase >= 2
	if not awake and not _wading:
		return
	_wading = false
	var arena: Dictionary = DmContent.boss("congregation")["arena"]
	var C: Dictionary = DmContent.get_export("bosses", "CONGREGATION")["water"]
	for hb in heroes():
		var d := Vector2(hb.position.x - float(arena["x"]), hb.position.z - float(arena["z"])).length()
		var at: String = game.area_of(hb.owner_peer)
		var in_nave: bool = (at if at != "" else assume_area) == "nave"
		var m := 1.0
		if awake and in_nave and d <= float(arena["r"]) and d > float(C["dais"]):
			m = float(C["slowP3"]) if b.phase >= 3 else float(C["slowP2"])
			_wading = true
		hb.wade_mult = m


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_state(ids: PackedInt32Array, states: Array) -> void:
	for i in ids.size():
		var b := boss_by_id(ids[i])
		if b != null and b.is_inside_tree():
			b.apply_net_state(states[i])
			states_applied += 1


# ---- local hero: music, E ---------------------------------------------------------------------------------------------------

func _process(dt: float) -> void:
	_slow -= dt
	if _slow > 0.0 or game == null or not game.ready_:
		return
	_slow = 0.5
	var me: DmHeroBody = game.local_body()
	var fighting := false
	if me != null and me.alive:
		var b := active_boss()
		fighting = b != null and String(DmContent.boss(b.boss_id)["area"]) == _area_for(me.owner_peer)
	if fighting != _music and audio_enabled:
		_music = fighting
		var a := get_node_or_null("/root/AudioDirector")
		if a != null:
			a.set_boss_music(fighting)


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.is_action_pressed(&"dm_interact") and game != null and game.local_body() != null:
		var id := site_near(game.local_body().position, SUMMON_RANGE)
		if id != "":
			request_summon(id)
