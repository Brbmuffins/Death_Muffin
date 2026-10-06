class_name DmBossHost
extends Node
## The bosses of the slice, one node per peer at the same path (`Bosses` under DmNextGame). Host: summon rules (soul shards at the boss's grave),
## spawns the DmBoss body (MultiplayerSpawner), turns the brain's events into consequences (player hurt, root, thrall damage, defeat -> rewards)
## and broadcasts the boss events + 20 Hz state to the other peers. Every peer: DmBossFx plays each event once, the boss music follows the local
## hero. Solo is the same code on the OfflineMultiplayerPeer.
## Seams on DmNextGame: `bosses` (this node), `enemies_in_radius / enemy_by_id` include living bosses (so rites and the hover pick hit them).

signal boss_spawned(boss: DmBoss)                 ## every peer, once in the tree
signal summoned(boss_id: String, by_peer: int)    ## host
signal summon_refused(boss_id: String, why: String, by_peer: int)   ## host
signal defeated(boss_id: String, killer_peer: int, pos: Vector3)    ## host: a real kill (not a wipe reset)
signal brain_event(ev: Dictionary, boss: DmBoss)  ## host: every event the brain emitted (hurt included), after its consequences
signal reset(boss_id: String)                     ## host: the party wiped / left, the boss went back to sleep

const SCENE := "res://next/bosses/boss.tscn"
const ID_BASE := 1000000                          ## dm_id of bosses (the director's ids are small)
const SUMMON_RANGE := 4.0                         ## metres from the grave
const SEND_HZ := 20.0
const FREE_S := 8.0                               ## a defeated body stays this long (the view fades after 2.5 s)
const WHY := {"busy": "Another boss is awake.", "far": "Stand at the grave to wake it.", "shards": "The grave demands soul shards. Elites carry them.",
	"dead": "You are dead.", "unknown": "Nothing sleeps here.", "area": "Nothing sleeps here."}

var game: Node                                    ## DmNextGame
var area_id: String = "graves"
var difficulty: String = "medium"
var visual: bool = true                           ## false = no DmBossView (headless)
var audio_enabled: bool = false                   ## boss music on the local hero's area
var assume_area: String = ""                      ## tests without a world: players count as in this area
var rng := RandomNumberGenerator.new()
var bosses: Dictionary = {}                       ## dm_id -> DmBoss (every peer)
var fx: DmBossFx
var packets_sent: int = 0
var states_applied: int = 0

var _holder: Node3D
var _spawner: MultiplayerSpawner
var _next: int = 1
var _acc: float = 0.0
var _slow: float = 0.0
var _music: bool = false
var _prompted: bool = false


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
	if not InputMap.has_action(&"dm_interact"):
		InputMap.add_action(&"dm_interact")
		var k := InputEventKey.new()
		k.physical_keycode = KEY_E
		InputMap.action_add_event(&"dm_interact", k)


## Loading time: the model of every boss of this area is read once, the fx shapes warmed (never mid-fight).
func warm(at: Vector3) -> void:
	for id in DmContent.get_export("bosses", "BOSS_IDS"):
		var bd: Dictionary = DmContent.boss(String(id))
		if bd["area"] == area_id:
			DmCreature.new(String(bd["modelSlug"]), {}).root.free()
	fx.warm(at)


# ---- queries (every peer) ------------------------------------------------------------------------------------------------------

## Awake, hittable bosses.
func living() -> Array[DmBoss]:
	var out: Array[DmBoss] = []
	for b in bosses.values():
		if is_instance_valid(b) and (b as DmBoss).is_hittable():
			out.append(b)
	return out


func active_boss() -> DmBoss:
	var l := living()
	return l[0] if not l.is_empty() else null


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


## The boss of this area whose grave / altar is within `r` of `pos` ("" = none): the E key and the prompt use it.
func site_near(pos: Vector3, r: float) -> String:
	for id in DmContent.get_export("bosses", "BOSS_IDS"):
		if id != "prelate" and String(DmContent.boss(String(id))["area"]) == area_id:
			var s := site_pos(String(id))
			if s != Vector3.INF and Vector2(pos.x - s.x, pos.z - s.z).length() <= r:
				return String(id)
	return ""


# ---- summon (host rules; any peer may ask) ---------------------------------------------------------------------------------------

## Ask to wake `boss_id` (the local hero, at its grave). Any peer; the host decides.
func request_summon(boss_id: String) -> void:
	if multiplayer.is_server():
		var me: int = game.session.get_my_id()
		var why := try_summon(me, boss_id)
		if why != "":
			_say("toast", {"text": WHY.get(why, why), "kind": "err"})
	else:
		_rpc_summon.rpc_id(1, boss_id)


## HOST. "" = woken; else the refusal: busy / far / shards / dead / unknown. Spends the boss's soul shards from the summoner's progression.
func try_summon(peer: int, boss_id: String, empowered: bool = false) -> String:
	var why := _check(peer, boss_id)
	if why == "":
		var m := _member(peer)
		if m != null and not m.prog.spend_boss_shards(boss_id):
			why = "shards"
	if why != "":
		summon_refused.emit(boss_id, why, peer)
		return why
	_spawner.spawn({"boss": boss_id, "id": ID_BASE + _next, "emp": empowered, "by": peer})
	_next += 1
	summoned.emit(boss_id, peer)
	return ""


func _check(peer: int, boss_id: String) -> String:
	if not DmContent.get_export("bosses", "BOSS_IDS").has(boss_id) or boss_id == "prelate" or String(DmContent.boss(boss_id)["area"]) != area_id:
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


func _member(peer: int) -> DmRewardsMember:
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
		_rpc_refused.rpc_id(from, why)


@rpc("authority", "call_remote", "reliable")
func _rpc_refused(why: String) -> void:
	_say("toast", {"text": WHY.get(why, why), "kind": "err"})


func _say(id: String, ctx: Dictionary) -> void:
	fx.host.emit_game_event(id, ctx)


# ---- spawn (every peer) ------------------------------------------------------------------------------------------------------------

func _spawn_boss(data: Variant) -> Node:
	var id := String(data["boss"])
	DmBoss.ensure_def(id)
	var b: DmBoss = load(SCENE).instantiate()
	var dm_id := int(data["id"])
	b.name = "B%d" % dm_id
	b.boss_id = id
	b.def_id = DmBoss.def_key(id)
	b.empowered = bool(data["emp"])
	b.summoner = int(data["by"])
	b.host_node = self
	b.with_visual = false          # DmEnemy's own creature is not used: DmBossView draws the boss
	b.visual = visual
	var arena: Dictionary = DmContent.boss(id)["arena"]
	b.position = Vector3(float(arena["x"]), 0.0, float(arena["z"]))
	b.set_meta(&"dm_id", dm_id)
	b.set_meta(&"dm_area", area_id)
	b.set_multiplayer_authority(1)
	bosses[dm_id] = b
	b.tree_exiting.connect(func() -> void: bosses.erase(dm_id))
	b.ready.connect(func() -> void: boss_spawned.emit(b))
	return b


# ---- brain events (host) -----------------------------------------------------------------------------------------------------------

## Every event the brain emits: `hurt` is a consequence here (never sent), `boss` events are played here and sent to the other peers.
func on_brain_event(ev: Dictionary, boss: DmBoss) -> void:
	_route(ev, boss)
	brain_event.emit(ev, boss)


func _route(ev: Dictionary, boss: DmBoss) -> void:
	if String(ev["t"]) == "hurt":
		var hb: DmHeroBody = game.body_of(int(ev["player"]))
		if hb != null:
			hb.take_damage(float(ev["dmg"]), boss)
		return
	if String(ev["t"]) != "boss":
		return
	var kind := String(ev["kind"])
	if kind == "bury" and float(ev.get("ms", 0.0)) == 0.0 and ev.get("root") != null:
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
	get_tree().create_timer(FREE_S).timeout.connect(func() -> void:
		if is_instance_valid(boss):
			boss.queue_free())   # the spawner despawns it everywhere
	if killer == "":
		reset.emit(boss.boss_id)
		return
	defeated.emit(boss.boss_id, int(killer), at)
	if game.rewards != null:
		game.rewards.on_boss_defeated({"boss": boss.boss_id, "x": at.x, "z": at.z, "killer": game.body_of(int(killer)), "empowered": bool(ev.get("empowered", false))})


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


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_state(ids: PackedInt32Array, states: Array) -> void:
	for i in ids.size():
		var b := boss_by_id(ids[i])
		if b != null and b.is_inside_tree():
			b.apply_net_state(states[i])
			states_applied += 1


# ---- local hero: music, the grave prompt, E -----------------------------------------------------------------------------------------

func _process(dt: float) -> void:
	_slow -= dt
	if _slow > 0.0 or game == null or not game.ready_:
		return
	_slow = 0.5
	var me: DmHeroBody = game.local_body()
	var near := false
	var near_id := ""
	var fighting := false
	if me != null and me.alive:
		var b := active_boss()
		fighting = b != null and String(DmContent.boss(b.boss_id)["area"]) == game.area_of(me.owner_peer)
		near_id = site_near(me.position, SUMMON_RANGE + 1.0)
		near = active_boss() == null and near_id != ""
	if fighting != _music and audio_enabled:
		_music = fighting
		var a := get_node_or_null("/root/AudioDirector")
		if a != null:
			a.set_boss_music(fighting)
	if near and not _prompted:
		_prompted = true
		var bd: Dictionary = DmContent.boss(near_id)
		_say("toast", {"text": "%s: press E to wake it (%d soul shards)." % [bd["summonLabel"], int(bd["shards"])], "kind": "info"})
	elif not near:
		_prompted = false


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.is_action_pressed(&"dm_interact") and game != null and game.local_body() != null:
		var id := site_near(game.local_body().position, SUMMON_RANGE)
		if id != "":
			request_summon(id)
