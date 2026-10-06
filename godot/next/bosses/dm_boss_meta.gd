class_name DmBossMeta
extends Node
## Boss meta-progression of the rebuild (child "BossMeta" of DmNextGame, host; the local hero's own account): the altar's Covenant Seal choice, the
## Empowered summon and the Seal's prize. The rules are the current game's (DmGameActions.open_altar / summon_boss_normal / call_empowered,
## DmGameRewards.claim_empowered) and the money is the BACKEND's (`/api/boss-key/*` takes the Seal and the gold, remembers the open summon, rolls
## the prize): nothing here prices or rolls anything.
##
## Flow: E at an altar / a click on it -> DmBossHost.request_summon -> `use_site`. A boss that can be Empowered, with a Seal in the bag (or a summon
## already bound by an earlier lost fight), opens the HUD's BossKeyPrompt (`boss_key_offer`, the HUD calls back summon_boss / summon_boss_empowered
## on the HUD adapter -> `summon_normal` / `call_empowered`); anything else wakes it with soul shards at once, synchronously, as before.
## The brain does the rest (DmBossBrain.awaken(empowered): +6 levels +15 %, hp x1.4, glow); the kill's report carries the summon id (rewards) and the
## prize is claimed from the backend right after the reports are flushed, then dropped at the corpse.

signal offered(ctx: Dictionary)                    ## the BossKeyPrompt's payload (the HUD adapter forwards it)
signal empowered(boss_id: String, cost: int, reused: bool)   ## the Seal was spent (or a bound summon answered) and the boss is waking
signal prize(boss_id: String, prize: Dictionary)   ## the Seal's prize dropped at the corpse

var game: Node                                     ## DmNextGame
var pending: String = ""                           ## the Empowered boss awake right now ("" = none)
var summon_id: int = 0
var bound: Dictionary = {}                         ## boss id -> true: the backend holds an open Empowered summon of it (lost fight): the next call is free
var hero_id: int = 0
var busy: bool = false

var _member: DmRewardsMember


func setup(game_: Node) -> void:
	game = game_
	hero_id = int(game.character.get("id", 0))
	_member = game.rewards.members.get(hero_id)
	game.bosses.site_hook = Callable(self, "use_site")
	game.bosses.defeated.connect(_on_defeated)
	game.bosses.reset.connect(_on_reset)
	game.rewards.boss_earned.connect(_on_earned)
	await refresh_bound()


## The backend's open summons (a startup read, and after anything that changes them).
func refresh_bound() -> void:
	var r: DmResult = await game.api.boss_key_status(hero_id)
	if r.ok and r.data is Dictionary:
		bound.clear()
		for id in r.data.get("bound", []):
			bound[String(id)] = true


func seals() -> int:
	var ui: Node = game.get("ui_host")
	return int(ui.inventory.count(DmGoldSink.COVENANT_SEAL)) if ui != null and ui.inventory != null else 0


# ---- the altar -------------------------------------------------------------------------------------------------------------------

## E at an altar / a click on it (the local hero). Synchronous unless a Seal choice is offered.
func use_site(id: String) -> void:
	var b: DmBossHost = game.bosses
	var why := b._check(game.session.get_my_id(), id)
	if (why != "" and why != "shards") or not DmGoldSink.can_empower(id) or (seals() < 1 and not bound.has(id)):
		b.request_summon_plain(id)   # refusals, the Prelate and the Seal-less summon are the plain path (its toast, its shard spend)
		return
	var ctx := {"boss": id, "seals": seals(), "gold": int(game.character.get("gold", 0)), "shards": int(_member.prog.local["shards"]), "bound": bound.has(id)}
	offered.emit(ctx)
	var ui: Node = game.get("ui_host")
	if ui != null:
		ui.game_event.emit("boss_key_offer", ctx)


## The plain choice (soul shards).
func summon_normal(id: String) -> void:
	game.bosses.request_summon_plain(id)


## The Empowered choice. Returns "" when the boss is waking, else why not ("busy far dead unknown" before anything is spent, "refused" after a
## failed call or when the boss would not wake and the Seal and gold went back).
func call_empowered(id: String) -> String:
	var b: DmBossHost = game.bosses
	var me: int = game.session.get_my_id()
	if busy or not DmGoldSink.can_empower(id):
		return "unknown"
	var why := b._check(me, id)   # BEFORE the Seal is taken (the current game spent it first and refunded a refusal)
	if why != "":
		b._say("toast", {"text": b.why_text(why, id, me), "kind": "err"})
		return why
	busy = true
	var ui: Node = game.get("ui_host")
	var inv: Object = ui.inventory if ui != null else null
	var work := func() -> DmResult:
		var res: DmResult = await game.progress.psync.spend_on_server(func() -> DmResult: return await game.api.boss_key_summon(hero_id, id))
		if res.ok and res.data is Dictionary and res.data.has("bag") and inv != null:
			inv.replace(res.data["bag"])
		return res
	var r: DmResult = await (inv.exclusive(work) if inv != null else work.call())
	if not r.ok:
		busy = false
		b._say("toast", {"text": r.error if r.error != "" else "The Seal would not take.", "kind": "err"})
		return "refused"
	var reused := bool(r.data.get("reused", false))
	var cost := int(r.data.get("cost", 0))
	var woke := b.try_summon(me, id, true)   # a boss woke meanwhile: give the Seal and gold back
	if woke != "":
		await _refund(id)
		busy = false
		b._say("toast", {"text": "%s Your Seal and gold are returned." % b.why_text(woke, id, me), "kind": "err"})
		return woke
	bound.erase(id)
	pending = id
	summon_id = int(r.data.get("summon_id", 0))
	_member.empower_pending = id
	_member.empower_summon_id = summon_id
	busy = false
	b._say("toast", {"text": "Your bound summon answers, free." if reused else "The Seal is spent (%d gold)." % cost, "kind": "good"})
	empowered.emit(id, cost, reused)
	return ""


func _refund(id: String) -> void:
	var ui: Node = game.get("ui_host")
	var inv: Object = ui.inventory if ui != null else null
	var work := func() -> DmResult:
		var res: DmResult = await game.progress.psync.spend_on_server(func() -> DmResult: return await game.api.boss_key_refund(hero_id, id))
		if res.ok and res.data is Dictionary and res.data.has("bag") and inv != null:
			inv.replace(res.data["bag"])
		return res
	await (inv.exclusive(work) if inv != null else work.call())


# ---- the kill / the wipe ---------------------------------------------------------------------------------------------------------

## A wipe or a leave: the fight is lost but the backend keeps the summon bound ("a fight you lose can be tried again free").
func _on_reset(id: String) -> void:
	if pending == id:
		bound[id] = true
		pending = ""
		_member.empower_pending = ""


## The kill. The boss host reports it to the rewards AFTER this signal, so the claim waits for the rewards' own `boss_earned` (the kill's report, with
## the summon id, is then in the batch). A hero that is not paid (dead or far) leaves the summon bound on the backend.
func _on_defeated(id: String, _killer_peer: int, _at: Vector3) -> void:
	if pending == id:
		pending = ""
		bound[id] = true


func _on_earned(character_id: int, id: String, _first: bool, at: Vector3) -> void:
	if character_id == hero_id and bound.has(id) and _member.empower_pending == id:
		bound.erase(id)
		_claim(id, at)


## The kill of an Empowered boss this hero called: one server-rolled prize, dropped at the corpse like any loot. The kill report goes first
## (the backend ties the summon to it).
func _claim(id: String, at: Vector3) -> void:
	await game.rewards.flush()
	var level: float = float(DmContent.area(String(DmContent.boss(id)["area"]))["level"]) + float(game.rewards.vow_levels)
	var r: DmResult = await game.api.boss_key_claim(hero_id, id, String(_member.discipline["id"]), int(level))
	_member.empower_pending = ""
	if not is_inside_tree():
		return
	if not r.ok:
		game.bosses._say("toast", {"text": r.error if r.error != "" else "The Seal's prize could not be rolled.", "kind": "err"})
		return
	var p: Dictionary = r.data
	_member.loot_view.item(at, {"item_id": p["item_id"], "quantity": 1, "instance": {"id": p["instance_id"], "ilvl": p["ilvl"], "affixes": p["affixes"]}})
	var nm := String(DmContent.item(p["item_id"])["name"])
	game.bosses._say("toast", {"text": "The Seal's prize: %s, a legendary" % nm if p.get("legendary", false) else "The Seal's prize: %s" % nm, "kind": "good"})
	prize.emit(id, p)
