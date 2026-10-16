class_name DmNextJoiner
extends Node
## Child "Joiner" of DmNextGame on a party JOINER (not the host): the joiner's own character state, on its own backend account.
## The host's game decides what happened (kills, drops, XP: D1); everything that persists lands on THIS player's account through its own api:
##   - the character's xp / gold / shards / kills: a DmProgression + DmProgressSync exactly as the host's own character has (saved by this client),
##   - XP and kill counts the backend accepted for this member (`DmNextParty._rpc_credit`, applied here),
##   - loot the host sends for this member (`_rpc_loot`): gold/shards credited, items shown and picked up by a click, gear rolled by this
##     player's own api (`roll_loot`), the bag saved by DmInventory,
##   - the backend session: `session_join` with this player's own token and a heartbeat every 20 s, so the host's reports can credit this member.
## `member` is a real DmRewardsMember (api, prog, loot_view) so the HUD adapter treats a joiner and a host alike.
## The rebuild's port (client/code.list "Ported"): the bag is the game's `loot` (DmNextLoot), not the panels' adapter.

signal member_credited(character_id: int, delta: Dictionary)   ## the same signal the host's DmSessionRewards has (the HUD adapter listens to either)
signal event(id: String, ctx: Dictionary)                       ## game_event shape (banner / toast), like DmNextProgress.event; the HUD adapter adds the level_up toast
signal backend_state(ok: bool, why: String)

const HEARTBEAT_S := 20.0

var shell: DmNextGame
var member: DmRewardsMember
var prog: DmProgression
var psync: DmProgressSync
var hero_id: int = 0
var session_id: String = ""
var backend_ok := false
var kills_seen: int = 0
var drops_received: int = 0
var picked: Dictionary = {"gold": 0, "shards": 0, "items": 0}
var rolls_pending: int = 0
var notice := ""     ## a toast the player has not seen yet (the backend refused the session before the HUD existed); DmNextGame shows it at the end of start()

var _hb_t := 0.0
var _persist := true


func _ready() -> void:
	set_process(false)   # until setup() has built the progression


## Before the HUD: builds the member and loads the character's saved state from this player's own backend. Awaited under the loading cover.
func setup(shell_: DmNextGame, persist: bool) -> void:
	shell = shell_
	_persist = persist
	hero_id = int(shell.character.get("id", 0))
	var d := DmCharacterBuild.discipline_for(float(shell.character.get("class_index", 0)))
	member = DmRewardsMember.make(hero_id, shell.session.get_my_id(), shell.local_body(), shell.api, int(shell.character.get("level", 1)), {"id": d["id"], "family": d["family"]})
	prog = DmProgression.new(shell.character, DmProgressSync.load_local(hero_id) if persist else null)
	member.prog = prog
	add_child(member.loot_view)
	member.loot_view.visible = true
	member.loot_view.try_take = Callable(member, "try_take")
	member.loot_view.picked.connect(_on_picked)
	member.tape = DmDropTape.new(shell.api, hero_id)   # this player's own drop seeds (DECISIONS B20): it rolls its drops itself
	member.tape.refill()
	psync = DmProgressSync.new(shell.api, prog, hero_id, persist)
	psync.error.connect(func(msg: String) -> void: event.emit("toast", {"text": msg, "kind": "err"}))
	await psync.connect_server()
	set_process(true)


func _process(dt: float) -> void:
	psync.tick(dt)
	var b := member.body
	if b == null or not is_instance_valid(b):
		b = shell.local_body()
		member.body = b
	if b != null:
		for ev in member.loot_view.tick(dt, b.position if b.alive else Vector3(1e9, 0, 1e9)):
			match ev["kind"]:
				"gold":
					prog.add_gold(float(ev["amount"]))
					picked["gold"] += int(ev["amount"])
				"shard":
					prog.add_shards(int(ev["amount"]))
					picked["shards"] += int(ev["amount"])
				"item":
					picked["items"] += int(ev["amount"])
	if backend_ok:
		_hb_t += dt
		if _hb_t >= HEARTBEAT_S:
			_hb_t = 0.0
			shell.api.session_heartbeat(session_id, hero_id, kills_seen)


func _on_picked(_ev: Dictionary) -> void:
	pass   # the HUD adapter (DmNextUiHost._on_picked) draws the float / sound; the bag take is member.try_take


## The host's welcome carried its backend session: join it with THIS player's own account so the host's reports can credit this character.
func begin_backend(sid: String) -> void:
	session_id = sid
	if sid == "":
		_backend(false, "The host's session is not credited yet (older server): your kills will not count.")
		return
	var r: DmResult = await shell.api.session_join(sid, hero_id)
	if r.ok:
		backend_ok = true
		_hb_t = 0.0
		_backend(true, "")
	else:
		_backend(false, r.error if r.error != "" else "The backend would not let you into this session.")


func _backend(ok: bool, why: String) -> void:
	shell.party.report_backend(ok, why)
	backend_state.emit(ok, why)
	if not ok:
		notice = "Your kills in this session will not be credited: %s" % why
		if shell.ready_:   # live; during loading the end of start() shows it
			event.emit("toast", {"text": notice, "kind": "err"})
			notice = ""


## The host's accepted report for this member: the XP share and the kill counts (the same rule as DmSessionRewards._credit).
func on_credit(delta: Dictionary) -> void:
	var xp := float(delta.get("xp", 0))
	var kills := int(delta.get("kills", 0))
	var lv := prog.add_xp(xp)
	var areas: Array = delta.get("areas", [])
	for i in kills:
		prog.record_kill(String(areas[i]) if i < areas.size() else shell.area_id, -1.0, true)
	kills_seen += kills
	member.stats["xp_applied"] += int(xp)
	member.stats["kills_accepted"] += kills
	member.stats["levels"] += lv
	if lv > 0:
		var lvl := int(prog.character["level"])
		event.emit("banner", {"title": "Level %d" % lvl, "sub": "The dead answer you more readily", "ms": 2600})
	_check_unlocks()
	member_credited.emit(hero_id, delta)


## A seal on THIS player's account breaks once its own kills are in (the same rule as DmNextProgress for a host): the party's kills the host
## credited to this member count towards it, so a joiner opens its own doors by playing in someone else's world.
func _check_unlocks() -> void:
	for id in DmContent.area_order():
		var u: Variant = DmContent.area(String(id)).get("unlock")
		if u == null or prog.really_unlocked(String(id)):
			continue
		if prog.kills(String(u["area"])) >= prog.unlock_kills(float(u["kills"])) and prog.unlock(String(id)):
			event.emit("toast", {"text": "A seal breaks: %s lies open" % DmContent.area(String(id))["name"], "kind": "good"})
			psync.flush()


## One drop of THIS member from the host: gold / shards are credited and materials land at once; gear is rolled by this player's own backend first
## (a failed roll leaves plain base gear: nothing is invented client-side).
func on_loot(drop: Dictionary, pos: Vector3) -> void:
	drops_received += 1
	var roll: Variant = drop.get("roll")
	if roll is Dictionary:
		drop.erase("roll")
		rolls_pending += 1
		for batch in DmLootRoll.batches([drop]):
			var r: DmResult = await shell.api.roll_loot(hero_id, DmLootRoll.request(batch, float(roll["level"]), String(roll["source"])), session_id)
			if r.ok and r.data is Array:
				DmLootRoll.apply(batch, r.data)
		rolls_pending -= 1
		if not is_instance_valid(member.loot_view) or not is_inside_tree():
			return
	member.loot_view.drop(drop, pos)


## A drop event of THIS member from the host (server-decided drops, DECISIONS B20): rolled here from this player's own tape, so the drop shows at
## once and the pickup is this player's claim (with the party session: the host's ground counts as carried). Wave Speed is this player's own
## at most, as the server reads it.
func on_drop_event(kind: String, facts: Dictionary, pos: Vector3) -> void:
	drops_received += 1
	if member.tape == null:
		return
	var waited := 0
	while not member.tape.ready_for(kind) and waited < 120:   # the first seeds are still on their way (or a top-up is): at most ~2 s
		member.tape.refill()
		await get_tree().process_frame
		waited += 1
		if not is_instance_valid(member.loot_view) or not is_inside_tree():
			return
	var slot := member.tape.take(kind)
	if slot.is_empty():
		return
	var f := facts.duplicate()
	if f.has("waveTier"):
		f["waveTier"] = minf(float(f["waveTier"]), float(prog.local.get("waveTierOwned", 0)))
	if kind == "elite":   # the rising rune chance is this player's own (the host cannot see which runes it owns)
		f["runePity"] = DmLootRunes.pity_mult(member.rune_dry)
	var sent := f.duplicate()
	f.merge(member.drop_context(), true)
	var items: Array = DmLoot.roll_event(kind, f, DmLoot.event_streams(kind, slot["seed"]))["items"]
	if kind == "elite" and not DmLootRunes.area_pool(String(f.get("area", ""))).is_empty():
		var lv := member.loot_view
		var fresh := items.any(func(d: Dictionary) -> bool: return DmRunes.is_rune_id(d["item_id"]) and not (lv.rune_owned.is_valid() and bool(lv.rune_owned.call(d))))
		member.rune_dry = 0 if fresh else member.rune_dry + 1
	for i in items.size():
		items[i]["claim"] = {"kind": kind, "n": int(slot["n"]), "index": i, "facts": sent, "expect": String(items[i]["item_id"])}
		member.loot_view.drop(items[i], pos)


## Save everything this player earned (the leave path): progression and the bag; tell the backend we left.
func flush_all() -> void:
	if psync != null:
		await psync.save_before_class_change()
	if shell.loot != null and shell.loot.inventory != null:
		await shell.loot.inventory.flush()
	if backend_ok:
		backend_ok = false
		await shell.api.session_leave(session_id, hero_id)
