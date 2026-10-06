class_name DmNextChronicle
extends Node
## The character's Chronicle on the rebuild (child "Chronicle" of DmNextGame, host): ONE DmChronicle for every system that feeds it (kills and peak wave
## through DmProgression, gold, gathering, the Depths, deaths, bosses, play / AFK time, peak level), loaded from the backend, flushed to it every
## 30 s while dirty and on leave (`/api/chronicle/add`, the same call as the current game's DmGame.flush_chronicle), and the Ascend archive post.
## Event driven: the only per-frame work is DmChronicle.time (two float adds).
##
## First-kill trophies live here too: the server whitelists `boss.<id>` as a lifetime counter, so "this character has killed it before" is
## `boss.<id> > 0` on the backend record (it survives a relaunch and a new machine, unlike the web's browser store). `claim_trophy` is the rewards
## member's `trophy_store`: it answers "first?" and counts the kill in the same step, then flushes at once so a crash cannot grant it twice.

const FLUSH_S := 30.0

var game: Node                                    ## DmNextGame
var chronicle := DmChronicle.new()
var hero_id: int = 0

var _t: float = FLUSH_S
var _flushing: bool = false


## Host. Loads the saved record (awaited under the loading cover, so a pending flush never double counts the view).
func setup(game_: Node) -> void:
	game = game_
	hero_id = int(game.character.get("id", 0))
	chronicle.max_("peak.level", float(game.character.get("level", 1)))
	var r: DmResult = await game.api.get_chronicle(hero_id)
	if r.ok and r.data is Dictionary:
		chronicle.set_data(r.data)
	game.hero_died.connect(func(b: DmHeroBody) -> void:
		if b == game.local_body():
			chronicle.add("deaths"))
	game.rewards.boss_earned.connect(func(cid: int, boss_id: String, _first: bool, _at: Vector3) -> void:
		if cid == hero_id and boss_id == "prelate":   # the area bosses are counted by claim_trophy (it needs the count BEFORE the kill)
			chronicle.add("boss.prelate"))
	var m: DmRewardsMember = game.rewards.members.get(hero_id)
	if m != null:
		m.trophy_store = Callable(self, "claim_trophy")
	set_process(true)


func _process(dt: float) -> void:
	var g: Node = game
	chronicle.time(dt, g.gather != null and g.gather.loop != null and g.gather.loop.afk)
	_t -= dt
	if _t <= 0.0:
		_t = FLUSH_S
		flush()


## The level reached (the progress node's level-up).
func level(lvl: float) -> void:
	chronicle.max_("peak.level", lvl)


## Lifetime count of `key` including what is not flushed yet.
func life(key: String) -> float:
	return float(chronicle.view()["life"].get(key, 0.0))


func has_trophy(boss_id: String) -> bool:
	return life("boss." + boss_id) > 0.0


## An area boss died under this character: true the first time ever (the trophy), and the kill is counted now. Saved at once.
func claim_trophy(boss_id: String) -> bool:
	var first := not has_trophy(boss_id)
	chronicle.add("boss." + boss_id)
	_t = minf(_t, 2.0)   # a plain kill rides the next flush; the first is also sent now
	if first:
		flush()
	return first


## Post what is pending (and an Ascend archive). Awaitable; DmNextGame.flush_all and the Depths call it.
func flush() -> void:
	if _flushing:
		return
	_flushing = true
	var batch := chronicle.flush_begin()
	if not batch.is_empty():
		var r: DmResult = await game.api.add_chronicle(hero_id, batch["sums"], batch["maxes"])
		chronicle.flush_done(batch, r.ok)
	while not chronicle.pending_ascends.is_empty():
		var rank: int = chronicle.pending_ascends.pop_front()
		await game.api.ascend_chronicle(hero_id, rank)
		var g: DmResult = await game.api.get_chronicle(hero_id)
		if g.ok and g.data is Dictionary:
			chronicle.set_data(g.data)
	_flushing = false
