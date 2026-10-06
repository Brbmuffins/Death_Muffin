class_name DmNextProgress
extends Node
## Host-side character progression for the slice (child "Progress" of DmNextGame). Only the slice-side wiring lives here; the rules and the
## persistence are the current game's: DmProgression (xp / level / gold / shards / kills / upgrade tiers / unlocks) and DmProgressSync (the
## backend saves: urgent on a level-up or a purchase, 45 s when dirty, on an area change and on quit; local file fallback; write-behind, a
## save never blocks a frame). Online it talks to the VPS backend, offline to the local backend through the same DmApi (REBUILD D1 / D4).
##
## Value stays on the backend: XP and kills arrive only through the rewards node's accepted session reports (member_credited), gold and shards
## through ground pickups, and every purchase is priced by the backend's rules. This node reacts: level-ups (stats, banner, sound, Grimoire
## toasts), the Damage / Wave Speed tiers (stats, the wave director), seal unlocks, milestones and the belt.
## `event(id, ctx)` is the DmGame game_event shape (the HUD adapter forwards it to DmGameUi).

signal event(id: String, ctx: Dictionary)

const MILESTONE_KEY := "dm_milestones_"
const CHAIN_BEST_KEY := "dm_chain_best_"

var shell: DmNextGame
var member: DmRewardsMember
var prog: DmProgression
var psync: DmProgressSync
var belt: DmNextBelt
var store: DmCounselStore
var hero_id: int = 0

var _stats_key := ""
var _stats_dirty := false
var _claimed: Array = []
var _best_chain := 0


## Host. Builds the progression on the member (replacing the blank one the rewards made), loads the character's saved state from the
## backend and applies it (tiers -> stats and waves). The loading path awaits it.
func setup(shell_: DmNextGame, m: DmRewardsMember, persist: bool) -> void:
	shell = shell_
	member = m
	hero_id = int(shell.character.get("id", 0))
	store = shell.opts.get("store", null)
	if store == null:
		store = DmCounselStore.new("user://dm_local.json" if persist else "")
	prog = DmProgression.new(shell.character, DmProgressSync.load_local(hero_id) if persist else null)
	m.prog = prog
	psync = DmProgressSync.new(shell.api, prog, hero_id, persist)
	psync.error.connect(func(msg: String) -> void: event.emit("toast", {"text": msg, "kind": "err"}))
	belt = DmNextBelt.new()
	belt.body = m.body as DmHeroBody
	belt.prog = prog
	belt.say = func(text: String, kind: String, y: float) -> void: event.emit("float", {"world": belt.body.position + Vector3(0, y, 0), "text": text, "kind": kind})
	belt.sfx = Callable(self, "sfx")
	belt.toast = func(text: String) -> void: event.emit("toast", {"text": text, "kind": ""})
	shell.rewards.member_credited.connect(_on_credited)
	prog.synced.connect(apply_progress)   # the backend's reply to a purchase / save is the truth
	shell.area_changed.connect(func(_id: String) -> void: psync.flush())
	_load_claims()
	await psync.connect_server()
	apply_progress()
	set_process(true)


func _process(dt: float) -> void:
	psync.tick(dt)
	belt.tick(dt)
	if _stats_dirty:
		_stats_dirty = false
		var key := _equipped_key()
		if key != _stats_key:
			refresh_stats()


## The bag's rows (equipment feeds the stats); empty until the HUD's inventory exists.
func slots() -> Array:
	return shell.ui_host.inventory.slots if shell.ui_host != null and shell.ui_host.inventory != null else []


## The bag changed: re-read the stats on the next frame, only if what is worn changed.
func request_stats() -> void:
	_stats_dirty = true


func _equipped_key() -> String:
	var parts := PackedStringArray()
	for s in slots():
		if int(s.get("equipped", 0)) != 0:
			parts.append("%s:%s" % [s.get("item_id", ""), s.get("instance_id", "")])
	return ",".join(parts)


## Backend state adopted or a purchase made: the wave tier and the stats follow it.
func apply_progress() -> void:
	var tier := float(prog.local["waveTierActive"])
	shell.director.set_wave_tier(tier)
	shell.rewards.wave_tier = tier
	if shell.meta != null:
		shell.meta.sync()   # vows, boons and the Omen reach the director, the bosses, the corpses and the rewards
	refresh_stats()


## The host body's and caster's stats from the character + tiers + boons + vows + worn gear (DmGame.refresh_stats). Cooldowns and essence stay.
func refresh_stats() -> void:
	var b: DmHeroBody = shell.local_body()
	if b == null:
		return
	_stats_key = _equipped_key()
	var build := shell.build_for(shell.session.get_my_id())
	b.refresh_stats(build)
	var c := b.get_node_or_null("Rites") as DmRiteCaster
	if c != null:
		c.refresh_stats(build)
	if shell.ui_host != null:
		shell.ui_host.build_changed()


## The Damage / Wave Speed upgrades box. The backend prices and takes the gold (DmProgression queues the purchase for DmProgressSync).
func buy(kind: String) -> bool:
	var ok := prog.buy_damage() if kind == "damage" else prog.buy_wave()
	if ok:
		apply_progress()
		sfx("click")
	return ok


func sfx(sound: String) -> void:
	var a := get_node_or_null("/root/AudioDirector")
	if a != null and bool(shell.opts.get("audio", DisplayServer.get_name() != "headless")):
		a.play_sfx(sound)


## Everything saved before the game closes or the session ends: "" on success, else why not.
func flush_all() -> String:
	return await psync.save_before_class_change()


# ---- rewards: what an accepted batch changed ------------------------------------------------------------------------------------------

func _on_credited(cid: int, delta: Dictionary) -> void:
	if cid != hero_id:
		return
	var gained := int(delta.get("levels", 0))
	if gained > 0:
		_level_up(gained)
	_check_unlocks()
	_check_milestones()


## XP that does not come from a kill report (a Depths floor or chest, as DmGameRewards.gain_xp): new-blood catch-up, then the level-up path.
func grant_xp(xp: float) -> int:
	var x := DmMath.js_round(xp * DmEnemyStats.new_blood_xp_mult(String(member.discipline["family"]), float(shell.character["level"])))
	var gained := prog.add_xp(float(x))
	member.stats["xp_applied"] += x
	member.stats["levels"] += gained
	if gained > 0:
		_level_up(gained)
	return gained


func _level_up(gained: int) -> void:
	var lvl := float(shell.character["level"])
	refresh_stats()
	var b := member.body as DmHeroBody
	b.restore_vitals()
	var c := b.get_node_or_null("Rites") as DmRiteCaster
	if c != null and not c.p.is_empty():
		c.p["resource"]["value"] = c.p["resource"]["max"]
	event.emit("banner", {"title": "Level %d" % int(lvl), "sub": "The dead answer you more readily", "ms": 2600})
	var kit := DmAbilities.kit_for(b.family)
	var learned: Array = []
	for id in kit["primaries"] + kit["grimoire"]:
		if DmAbilities.unlock_level(id) > lvl - gained and DmAbilities.unlock_level(id) <= lvl and not learned.has(id):
			learned.append(id)
	if not learned.is_empty():
		var names: Array = []
		for id in learned.slice(0, 3):
			names.append(DmAbilities.def(id)["name"])
		var nm := ", ".join(names)
		if learned.size() > 3:
			nm = "%s and %d more" % [nm, learned.size() - 3]
		event.emit("toast", {"text": "%s %s your Grimoire. Click here, press L or use the Grimoire button to place it." % [nm, "join" if learned.size() > 1 else "joins"], "kind": "good", "action": "grimoire"})
	var grim := false
	for id in kit["grimoire"]:
		if DmAbilities.unlock_level(id) <= lvl and DmAbilities.unlock_level(id) > 1:
			grim = true
	event.emit("level_up", {"level": int(lvl), "grimoire_unlocked": grim, "family": b.family, "learned_rites": learned.size()})
	sfx("levelUp")


## A seal opens once its area's kills are in (the banked truth). With the hub present it owns seals (doors, navmesh, the banner):
## breaking it here first left the hub finding it already open (no door, no banner). Without the hub: bank it and toast.
func _check_unlocks() -> void:
	if shell != null and shell.chapterhouse != null:
		if not shell.chapterhouse.check_seals().is_empty():
			psync.flush()
		return
	for id in DmContent.area_order():
		var u: Variant = DmContent.area(id).get("unlock")
		if u == null or prog.really_unlocked(id):
			continue
		if prog.kills(String(u["area"])) >= prog.unlock_kills(float(u["kills"])) and prog.unlock(id):
			event.emit("toast", {"text": "A seal breaks: %s lies open" % DmContent.area(id)["name"], "kind": "good"})
			psync.flush()


func _load_claims() -> void:
	var raw := store.get_item(MILESTONE_KEY + str(hero_id))
	if raw != "":
		var parsed: Variant = JSON.parse_string(raw)
		if parsed is Array:
			_claimed = parsed
	var best := store.get_item(CHAIN_BEST_KEY + str(hero_id))
	if best != "":
		_best_chain = int(best)


## Pays a newly reached milestone once per character. The gold is a ground drop like any other (the rewards path: picked up -> add_gold ->
## the progress save), so whatever the backend does with it applies here too.
func _check_milestones() -> void:
	var best := maxi(_best_chain, member.chain.best)
	var hit := DmMilestones.newly_reached({"totalKills": prog.local["totalKills"], "areaKills": prog.local["areaKills"], "bestChain": best}, _claimed)
	if best > _best_chain:
		_best_chain = best
		store.set_item(CHAIN_BEST_KEY + str(hero_id), str(best))
	if hit.is_empty():
		return
	var at := member.pos()
	for m in hit:
		_claimed.append(m["id"])
		member.loot_view.gold(at, int(m["gold"]))
		event.emit("toast", {"text": "Milestone: %s. %s (+%d gold)" % [m["title"], m["text"], int(m["gold"])], "kind": "good"})
		sfx("skillUp")
	store.set_item(MILESTONE_KEY + str(hero_id), JSON.stringify(_claimed))
