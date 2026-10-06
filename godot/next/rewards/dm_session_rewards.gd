class_name DmSessionRewards
extends Node
## Host-side rewards for one party session (REBUILD D1/D4/D5; contract in README.md). Runs ONLY on the session host.
##
##  1. every spawned enemy's `died` -> who earned it (the current game's rule: a living member within DmGameRewards.KILL_REWARD_RANGE,
##     each at ITS OWN multipliers; the Kill Chain only for the killer, only in unsafe ground),
##  2. credit through the backend: session_open (host) / session_join + session_heartbeat (members, own API) / session_report (numbered
##     batches every `flush_interval` s and at the end) / session_end. XP and kill counts are applied from what the backend ACCEPTED,
##  3. loot: rolled with the same DmLoot rules, gear rolled by the member's own API (server RNG online, offline backend offline), landed in
##     THAT member's own DmLootView; walk-over pickup, 60 s expiry, loot never flies to anyone,
##  4. identical online/offline: the only difference is which DmApi each member carries.
## Gold and shards are drops (picked up by walking over them, as in the current game); their persistence is the member's save path, which
## the backend's kill ledger caps from these same reports.

signal session_opened(session_id: String)
signal session_failed(reason: String)       ## open refused / session lost (ended, not host): rewards stop crediting
signal session_closed
signal member_credited(character_id: int, delta: Dictionary)   ## {xp, kills, levels, batch}: applied from an accepted report
signal member_refused(character_id: int, reason: String)       ## the backend did not credit this member's part of a batch
signal batch_reported(batch: int, reply: Variant)
signal kill_earned(character_id: int, enemy_def: String, pos: Vector3)
signal boss_earned(character_id: int, boss_id: String, first: bool, pos: Vector3)   ## a member was paid for a boss kill
signal loot_dropped(character_id: int, drop: Dictionary, pos: Vector3)   ## also lets a shell replicate a member's drops to its peer
signal loot_picked(character_id: int, event: Dictionary)
signal loot_expired(character_id: int, drop: Dictionary, reason: String)

const MAX_GROUPS := 80            ## backend bound per member per report
const EARLY_FLUSH_GROUPS := 60    ## flush at once when a member's open batch gets this many groups
const HEARTBEAT_S := 20.0

## Seconds between kill-batch reports.
var flush_interval: float = 5.0
## false = the owner drives `tick(dt)` (tests); true = _process does.
var auto_tick: bool = true
## Rendering/pick-up peer on THIS process: a member's loot view is only visible when its peer_id matches.
var local_peer_id: int = 1
## World context for rewards (the shell keeps it current).
var difficulty: String = "medium"
var wave_tier: float = 0.0
var ascension: float = 0.0
var area_id: String = "graves"
## Optional (the Depths): Callable(area: String) -> String or null, the hunting ground whose loot table a kill in `area` rolls from (null = the area itself).
var loot_area_of: Callable = Callable()
## Deterministic rolls for tests: Callable() -> float in [0,1). Empty = randf.
var rng: Callable = Callable()
var now_ms: Callable = Callable()

var session_id: String = ""
var host_character_id: int = 0
var ended: bool = false
var batch_no: int = 0
var members: Dictionary = {}        ## character_id -> DmRewardsMember

var _rules := DmGameRewards.new(null)   ## the current game's proximity rule, reused as the single source
var _handled: Dictionary = {}
var _last_hit: Dictionary = {}
var _inflight: Dictionary = {}          ## the batch sent but not confirmed: re-sent under the SAME number until the backend answers
var _busy := false
var _flush_t := 0.0
var _hb_t := 0.0
var _gear_pending := 0


func _ready() -> void:
	set_process(auto_tick)


func _process(dt: float) -> void:
	if auto_tick:
		tick(dt)


# ================================================================================================================ wiring

## Subscribe to a shell (anything with `signal enemy_spawned(enemy)`); enemies that already exist can be passed to watch_enemy.
func attach_spawner(spawner: Object) -> void:
	if spawner.has_signal("enemy_spawned") and not spawner.is_connected("enemy_spawned", watch_enemy):
		spawner.connect("enemy_spawned", watch_enemy)


func watch_enemy(enemy: Node) -> void:
	if not enemy.has_signal("died") or enemy.is_connected("died", _on_enemy_died):
		return
	enemy.connect("died", _on_enemy_died)
	if enemy.has_signal("damaged"):
		var id := enemy.get_instance_id()
		enemy.connect("damaged", func(_a: float, _hp: float, from: Node) -> void: _last_hit[id] = from)


## Add a member (before or after start()). Joins the backend session when it is open.
func add_member(m: DmRewardsMember) -> void:
	members[m.character_id] = m
	if m.reporter == null:
		m.reporter = DmKillReporter.new(now_ms if now_ms.is_valid() else Callable(self, "_clock_ms"))
	if m.loot_view == null:
		m.loot_view = DmLootView.new()
	var lv := m.loot_view
	if lv.get_parent() == null:
		add_child(lv)
	lv.visible = m.peer_id == local_peer_id
	lv.try_take = Callable(m, "try_take")
	lv.picked.connect(func(ev: Dictionary) -> void: loot_picked.emit(m.character_id, ev))
	lv.expired.connect(func(d: Dictionary, reason: String) -> void: loot_expired.emit(m.character_id, d, reason))
	if session_id != "" and m.character_id != host_character_id:
		await _join(m)


## A member leaves (the host removes it or it disconnects): its pending part is reported first, then it leaves the session.
func remove_member(character_id: int) -> void:
	var m: DmRewardsMember = members.get(character_id)
	if m == null:
		return
	await flush()
	if session_id != "" and m.api != null and character_id != host_character_id:
		await m.api.session_leave(session_id, character_id)
	members.erase(character_id)
	if is_instance_valid(m.loot_view):
		m.loot_view.queue_free()


func _clock_ms() -> int:
	return int(now_ms.call()) if now_ms.is_valid() else Time.get_ticks_msec()


func _join(m: DmRewardsMember) -> bool:
	if m.api == null or m.joined:
		return true
	var r: DmResult = await m.api.session_join(session_id, m.character_id)
	m.joined = r.ok
	if not r.ok:
		m.blocked = "join_refused"
		member_refused.emit(m.character_id, "join_refused: " + r.error)
	return r.ok


# ================================================================================================================ session

## Open the backend session with the host's character (must have been add_member'd) and join the members already present.
func start(host_char_id: int) -> bool:
	host_character_id = host_char_id
	var h: DmRewardsMember = members.get(host_char_id)
	if h == null or h.api == null:
		session_failed.emit("no host member with an api")
		return false
	return await _open()


func _open() -> bool:
	var h: DmRewardsMember = members[host_character_id]
	var r: DmResult = await h.api.session_open(host_character_id)
	if not r.ok or not (r.data is Dictionary):
		session_failed.emit("open: " + r.error)
		return false
	session_id = String(r.data["sessionId"])
	h.joined = true
	session_opened.emit(session_id)
	for cid in members.keys():
		if cid != host_character_id:
			await _join(members[cid])
	return true


## Report everything pending now. Re-sends an unconfirmed batch (same number) before building a new one.
func flush() -> void:
	while _busy:
		await get_tree().process_frame
	_busy = true
	await _flush_inner()
	_busy = false


func _flush_inner() -> void:
	if ended:
		return
	if session_id == "":
		if members.has(host_character_id) and not await _open():
			return
		if session_id == "":
			return
	if _inflight.is_empty():
		_inflight = _seal()
		if _inflight.is_empty():
			return
	var h: DmRewardsMember = members.get(host_character_id)
	var r: DmResult = await h.api.session_report(session_id, int(_inflight["batch"]), _inflight["entries"])
	if not r.ok:
		_on_call_failed(r)
		return
	var inflight := _inflight
	_inflight = {}
	for m in members.values():
		m.reporter.ack(int(inflight["seqs"].get(m.character_id, 0)))
	batch_reported.emit(int(inflight["batch"]), r.data)
	await _apply(inflight, r.data)


## Seal every member's open kills into one numbered batch: {batch, entries, claims, seqs} or {} when nothing is pending.
func _seal() -> Dictionary:
	var entries: Array = []
	var claims := {}
	var seqs := {}
	for cid in members:
		var m: DmRewardsMember = members[cid]
		if not m.reporter.has_pending():
			continue
		var groups: Array = []
		var bosses: Array = []
		var seq := 0
		for b in m.reporter.batches():
			groups.append_array(b["groups"])
			bosses.append_array(b["bosses"])
			seq = maxi(seq, int(b["seq"]))
		var n := 0
		for g in groups:
			n += int(g["n"])
		if groups.size() > MAX_GROUPS:
			push_warning("DmSessionRewards: %d groups for %d exceeds the backend bound; flush more often" % [groups.size(), cid])
			groups = groups.slice(0, MAX_GROUPS)
		entries.append({"characterId": cid, "groups": groups, "bosses": bosses})
		claims[cid] = {"xp": m.pending_xp, "kills": m.pending_areas.size(), "areas": m.pending_areas.duplicate()}
		seqs[cid] = seq
		m.pending_xp = 0.0
		m.pending_areas = []
	if entries.is_empty():
		return {}
	batch_no += 1
	return {"batch": batch_no, "entries": entries, "claims": claims, "seqs": seqs}


## A failed call: transport/5xx/429 keep the batch for a retry; 403/404/409 mean the session is gone for us.
func _on_call_failed(r: DmResult) -> void:
	if r.status == 403 or r.status == 404 or r.status == 409:
		_inflight = {}
		_lose("%d %s" % [r.status, r.error])


func _lose(reason: String) -> void:
	if ended:
		return
	ended = true
	session_failed.emit(reason)


## Apply a reply: XP and kill counts for what the backend accepted, refusals for the rest.
func _apply(sent: Dictionary, data: Variant) -> void:
	if not (data is Dictionary):
		return
	if data.get("duplicate", false):
		# A re-send of a batch the backend already counted: our reply was lost. What it accepted is read back from the session's
		# per-member counters (accepted so far minus what we had already applied).
		data = await _reconstruct(sent)
		if data == null:
			return
	for e in data.get("members", []):
		var cid := int(e["characterId"])
		var m: DmRewardsMember = members.get(cid)
		var claim: Variant = sent["claims"].get(cid)
		if m == null or claim == null:
			continue
		if not bool(e.get("credited", false)):
			var reason := String(e.get("reason", "refused"))
			m.stats["refused_batches"] += 1
			m.last_refusal = reason
			if reason == "left" or reason == "not_member":
				m.blocked = reason
			member_refused.emit(cid, reason)
			continue
		var acc: Dictionary = e.get("accepted", {"kills": 0})
		var kills := clampi(int(acc.get("kills", 0)), 0, int(claim["kills"]))
		var frac := float(kills) / float(claim["kills"]) if int(claim["kills"]) > 0 else 0.0
		var xp := DmMath.js_round(float(claim["xp"]) * frac)
		var lv: int = m.prog.add_xp(float(xp))
		for i in kills:
			m.prog.record_kill(String(claim["areas"][i]), wave_tier)
		m.stats["kills_accepted"] += kills
		m.backend_accepted += kills
		m.stats["xp_applied"] += xp
		m.stats["levels"] += lv
		member_credited.emit(cid, {"xp": xp, "kills": kills, "levels": lv, "batch": int(sent["batch"])})


## The accepted part of `sent` after a lost reply, as a synthetic reply, from session_get (null when it cannot be read).
func _reconstruct(sent: Dictionary) -> Variant:
	var h: DmRewardsMember = members.get(host_character_id)
	var g: DmResult = await h.api.session_get(session_id)
	if not g.ok or not (g.data is Dictionary):
		return null
	var out: Array = []
	for e in g.data.get("members", []):
		var cid := int(e["characterId"])
		var m: DmRewardsMember = members.get(cid)
		if m == null or not sent["claims"].has(cid):
			continue
		var delta := maxi(0, int(e["acceptedKills"]) - m.backend_accepted)
		out.append({"characterId": cid, "credited": delta > 0 or String(e["status"]) == "active", "accepted": {"kills": delta, "bosses": 0}, "reason": String(e["status"])})
	return {"members": out}


## Close the session: final batch (judged like any other) and session_end. Idempotent.
func end_session(summary: Dictionary = {}) -> void:
	if ended and session_id == "":
		return
	while _busy:
		await get_tree().process_frame
	_busy = true
	if session_id != "" and not ended:
		var h: DmRewardsMember = members.get(host_character_id)
		if _inflight.is_empty():
			_inflight = _seal()
		var final := {}
		if not _inflight.is_empty():
			final = {"batch": int(_inflight["batch"]), "members": _inflight["entries"]}
		var r: DmResult = await h.api.session_end(session_id, final, summary)
		if r.ok:
			var fin: Variant = r.data.get("final") if r.data is Dictionary else null
			if not _inflight.is_empty() and fin != null:
				await _apply(_inflight, fin)
				batch_reported.emit(int(_inflight["batch"]), fin)
			_inflight = {}
		else:
			push_warning("session_end failed: %s" % r.error)
	ended = true
	_busy = false
	session_closed.emit()


# ================================================================================================================ per frame

## Drive loot (pickup/expiry), the batch timer and heartbeats. `_process` calls it when auto_tick.
func tick(dt: float) -> void:
	for m in members.values():
		_tick_loot(m, dt)
	if session_id == "" and host_character_id == 0:
		return
	_flush_t += dt
	_hb_t += dt
	if _flush_t >= flush_interval:
		_flush_t = 0.0
		if not _busy:
			flush()
	if _hb_t >= HEARTBEAT_S:
		_hb_t = 0.0
		_heartbeats()


func _heartbeats() -> void:
	if session_id == "" or ended:
		return
	for m in members.values():
		if m.character_id != host_character_id and m.api != null and m.joined and m.blocked == "":
			m.api.session_heartbeat(session_id, m.character_id, int(m.stats["kills_earned"]))


func _tick_loot(m: DmRewardsMember, dt: float) -> void:
	var at := m.pos() if m.alive() else Vector3(1e9, 0, 1e9)   # a dead hero picks nothing up; drops still age
	for ev in m.loot_view.tick(dt, at):
		match ev["kind"]:
			"gold":
				m.prog.add_gold(float(ev["amount"]))
				m.stats["gold_picked"] += int(ev["amount"])
			"shard":
				m.prog.add_shards(int(ev["amount"]))
				m.stats["shards_picked"] += int(ev["amount"])
			"item":
				m.stats["items_picked"] += int(ev["amount"])


# ================================================================================================================ kills

func _on_enemy_died(enemy: Node) -> void:
	var id := enemy.get_instance_id()
	if _handled.has(id):
		return
	_handled[id] = true
	var killer: Variant = _last_hit.get(id)
	_last_hit.erase(id)
	var at: Vector3 = (enemy as Node3D).global_position if enemy is Node3D and enemy.is_inside_tree() else (enemy as Node3D).position
	var def_id := String(enemy.get("def_id")) if enemy.get("def_id") != null else "robber"
	var level := float(enemy.get_meta("dm_level", 1))
	var elite := bool(enemy.get_meta("dm_elite", false))
	var area := String(enemy.get_meta("dm_area", area_id))
	on_kill({"def": def_id, "area": area, "level": level, "elite": elite, "x": at.x, "z": at.z, "killer": killer})


## Decide who earned a kill and reward each. ev: {def, area, level, elite, x, z, killer: Node|null}. Public so a shell with its own
## death pipeline can call it directly. Mirrors DmGameRewards.on_kill per eligible member.
func on_kill(ev: Dictionary) -> void:
	if ended:
		return
	if DmContent.enemy(String(ev["def"])).get("inert", false) == true:
		return
	var kx := float(ev["x"])
	var kz := float(ev["z"])
	for cid in members:
		var m: DmRewardsMember = members[cid]
		if m.blocked != "":
			continue
		var dist := DmSimMath.hypot(kx - m.pos().x, kz - m.pos().z)
		if not _rules.boss_reward_eligible(m.alive(), dist):
			continue
		_reward(m, ev, ev.get("killer") != null and ev["killer"] == m.body)


## A boss died (the boss host calls it): ev {boss, x, z, killer: Node|null, empowered}. The normal-kill rule decides who is paid (alive, within
## KILL_REWARD_RANGE); each gets its own roll (DmLoot.roll_boss), a first-kill bonus (+2 shards, a rare relic, a trophy), the relic rune, XP now,
## and a boss entry in its report (the backend's kill ledger). Mirrors DmGameRewards.on_boss_defeated.
func on_boss_defeated(ev: Dictionary) -> void:
	var id := String(ev["boss"])
	if ended or ev.get("killer") == null:
		return
	var def: Dictionary = DmContent.boss(id)
	var at := Vector3(float(ev["x"]), 0, float(ev["z"]))
	var level := float(DmContent.area(String(def["area"]))["level"])
	for cid in members:
		var m: DmRewardsMember = members[cid]
		if m.blocked != "" or not _rules.boss_reward_eligible(m.alive(), DmSimMath.hypot(at.x - m.pos().x, at.z - m.pos().z)):
			continue
		var reward: Dictionary = DmLoot.roll_boss(wave_tier, rng, difficulty, String(def["area"]), float(def["shards"]), id, String(m.discipline["id"]), Callable(m, "owned_ids"))
		var first: bool = id != "prelate" and m.claim_trophy(id)   # the Prelate has no first-kill trophy: it is the run's boss (tally + Ascend instead)
		var first_item: Variant = null
		if first:
			reward["shards"] = int(reward["shards"]) + 2
			first_item = DmLoot.roll_first_kill_item(String(def["area"]), rng, String(m.discipline["id"]))
		var rune: Variant = DmLoot.roll_boss_rune(id, first, rng)
		if rune != null:
			reward["items"].append(rune)
		m.stats["bosses"] += 1
		m.reporter.boss({"boss": id, "tier": wave_tier, "diff": difficulty, "first": first})
		if id == "prelate":
			m.prog.record_prelate_kill()
		_ground(m, {"kind": "gold", "amount": int(reward["gold"]) + int(reward["materialGold"])}, at)
		_ground(m, {"kind": "shard", "amount": int(reward["shards"])}, at)
		_drop_items(m, at, reward["items"], level, "boss")
		if first_item != null:
			_drop_items(m, at, [first_item], level, "first_kill")
		m.stats["xp_applied"] += int(reward["xp"])
		m.stats["levels"] += m.prog.add_xp(float(reward["xp"]))
		boss_earned.emit(m.character_id, id, first, at)


## A Grave Surge was quelled (DmGraveSurge): every member the normal-kill rule pays gets a guaranteed item from the area's table plus bonus gold
## on the ground at the crypt. ev {area, x, z}. Mirrors DmGameRewards.on_surge_cleared.
func on_surge_cleared(ev: Dictionary) -> void:
	if ended:
		return
	var at := Vector3(float(ev["x"]), 0, float(ev["z"]))
	var level := float(DmContent.area(String(ev["area"]))["level"])
	var gold := DmMath.js_round((24.0 + 10.0 * level) * float(DmWaveUpgrades.wave_modifiers(wave_tier)["rewardMult"]) * float(DmContent.difficulty(difficulty)["rewardMult"]))
	for cid in members:
		var m: DmRewardsMember = members[cid]
		if m.blocked != "" or not _rules.boss_reward_eligible(m.alive(), DmSimMath.hypot(at.x - m.pos().x, at.z - m.pos().z)):
			continue
		_drop_items(m, at, [DmLoot.roll_surge_item(String(ev["area"]), rng, String(m.discipline["id"]))], level, "surge")
		_ground(m, {"kind": "gold", "amount": gold}, at)


func _reward(m: DmRewardsMember, ev: Dictionary, is_killer: bool) -> void:
	var at := Vector3(float(ev["x"]), 0, float(ev["z"]))
	var area := String(ev["area"])
	var level := float(ev["level"])
	var elite := bool(ev["elite"])
	m.stats["kills_earned"] += 1
	kill_earned.emit(m.character_id, String(ev["def"]), at)
	var loot_area := area
	if loot_area_of.is_valid():
		var la: Variant = loot_area_of.call(area)
		if la != null:
			loot_area = String(la)
	var reward: Dictionary = DmLoot.roll_kill(String(ev["def"]), loot_area, level, elite, wave_tier, rng, difficulty, 1.0 + m.fortune, Callable(), Callable(), String(m.discipline["id"]), Callable(m, "owned_ids"))
	var chain_mult := 1.0
	var area_def: Dictionary = DmContent.area(area)
	var combat: bool = not bool(area_def["safe"])
	if is_killer and combat:
		m.chain.hit(float(_clock_ms()))
		chain_mult = m.chain.mult()
	var asc := DmAscension.ascension_reward_mult(ascension) * chain_mult * (m.omen_reward if combat else 1.0)
	if int(reward["shards"]) > 0 and combat:
		reward["shards"] = int(ceil(float(reward["shards"]) * m.omen_shard))
	reward["gold"] = DmMath.js_round(float(reward["gold"]) * asc)
	reward["xp"] = DmMath.js_round(float(reward["xp"]) * asc * (1.0 + m.wisdom))
	# Gold pools over a few kills into one bigger pile; elites always pay out.
	m.gold_pool["amount"] += int(reward["gold"]) + int(reward["materialGold"])
	m.gold_pool["kills"] += 1
	if elite or int(m.gold_pool["kills"]) >= int(DmLoot.KILL_LOOT["goldEveryKills"]):
		_ground(m, {"kind": "gold", "amount": int(m.gold_pool["amount"])}, at)
		m.gold_pool = {"amount": 0, "kills": 0}
	if int(reward["shards"]) > 0:
		_ground(m, {"kind": "shard", "amount": int(reward["shards"])}, at)
	# Ordinary kills drop half as often, so their gear rolls at elite quality (as in the current game).
	_drop_items(m, at, reward["items"], level, "elite")
	if combat:
		var nb := DmEnemyStats.new_blood_xp_mult(String(m.discipline["family"]), float(m.prog.character["level"]))
		m.reporter.kill({"area": area, "def": ev["def"], "level": level, "elite": elite, "tier": wave_tier, "diff": difficulty, "rank": ascension,
			"xpMult": asc * (1.0 + m.wisdom) * nb, "goldMult": asc, "shardMult": m.omen_shard})
		m.pending_xp += float(DmMath.js_round(float(reward["xp"]) * nb))
		m.pending_areas.append(area)
		if m.reporter._groups.size() >= EARLY_FLUSH_GROUPS and not _busy:
			flush()


func _ground(m: DmRewardsMember, d: Dictionary, at: Vector3) -> void:
	m.loot_view.drop(d, at)
	loot_dropped.emit(m.character_id, d, at)


## Items from a source other than a kill (a Depths floor, its chest) for one member: the same landing path (gear rolled by the member's backend).
func drop_items_for(m: DmRewardsMember, at: Vector3, items: Array, level: float, source: String) -> void:
	_drop_items(m, at, items, level, source)


## Materials land at once; gear first gets its roll from the member's own backend (server RNG online, the offline backend offline).
func _drop_items(m: DmRewardsMember, at: Vector3, items: Array, level: float, source: String) -> void:
	var gear: Array = []
	for d in items:
		if DmAffixes.can_roll(d["item_id"]):
			gear.append(d)
		else:
			_ground(m, d, at)
	if not gear.is_empty():
		_land_gear(m, at, gear, level, source)


func _land_gear(m: DmRewardsMember, at: Vector3, gear: Array, level: float, source: String) -> void:
	_gear_pending += 1
	if m.api != null:
		for batch in DmLootRoll.batches(gear):
			var r: DmResult = await m.api.roll_loot(m.character_id, DmLootRoll.request(batch, level, source))
			if r.ok and r.data is Array:
				DmLootRoll.apply(batch, r.data)
	_gear_pending -= 1
	if not is_instance_valid(m.loot_view) or not members.has(m.character_id):
		return
	for item in gear:   # a failed roll leaves plain base gear: nothing is invented client-side
		_ground(m, item, at)


## Gear rolls still in flight (tests wait on this).
func gear_pending() -> int:
	return _gear_pending
