class_name DmRewardsMember
extends RefCounted
## One party member as the rewards node sees it: who (character id, peer), where (body), how it talks to the backend (its OWN DmApi/JWT),
## its character state (DmProgression), its OWN ground loot (a DmLootView only this member picks from) and the per-member bookkeeping
## of the kill reports. Built by the game shell; see README.md for the contract.

var character_id: int = 0
var peer_id: int = 1
## The player body. Position is read each tick (x/z). Optional `dm_alive() -> bool` (else always alive).
var body: Node3D
## This member's backend client (online: its JWT; offline: DmOffline.make_api over the local backend). null = the member's own
## client does session_join/heartbeat and rolls its own gear (remote peer): the host then cannot roll gear for it (plain base gear).
var api: DmApi
## Character + local progression state the rewards are applied to ({level, experience, gold, ...} in prog.character).
var prog: DmProgression
## This member's drops. Only the member the view belongs to renders/picks it up (per-member loot).
var loot_view: DmLootView
var discipline: Dictionary = {"id": "", "family": ""}
## Per-member reward multipliers the shell keeps current (brews, omen, ...).
var wisdom: float = 0.0          ## Tonic of wisdom: + share of XP
var fortune: float = 0.0         ## Fortune brew: + share of item chance
var omen_reward: float = 1.0
var omen_shard: float = 1.0
var bag: Array = []
var bag_cap: int = 24
## Called with the item drop; return false when the bag is full. Default: append to `bag` up to bag_cap.
var take_item: Callable = Callable()

# ---- bookkeeping owned by DmSessionRewards -------------------------------------------------------------------------------
var chain := DmKillChain.new()
var gold_pool := {"amount": 0, "kills": 0}
var reporter: DmKillReporter
var pending_xp: float = 0.0
var pending_areas: Array = []     ## the area of every kill in the open batch (one entry per kill)
var seen_kills: int = 0
var backend_accepted: int = 0     ## kills the backend has accepted for this member so far (as far as we applied)
var blocked: String = ""          ## non-empty after the backend said "left"/"not_member": no more rewards for this member
var last_refusal: String = ""
var stats := {"kills_earned": 0, "kills_accepted": 0, "xp_applied": 0, "levels": 0, "gold_picked": 0, "shards_picked": 0, "items_picked": 0, "refused_batches": 0, "bosses": 0}
var joined: bool = false
## Bosses this character has killed (first kill = trophy + bonus). In memory for the session; a shell that persists them sets `trophy_store`
## (Callable(boss_id) -> bool: true = first kill, and records it).
var trophies: Dictionary = {}
var trophy_store: Callable = Callable()


## The usual construction: a fresh character and local progression, its own loot view.
static func make(cid: int, peer: int, body_node: Node3D, member_api: DmApi, level: int = 1, discipline_info: Dictionary = {}) -> DmRewardsMember:
	var m := DmRewardsMember.new()
	m.character_id = cid
	m.peer_id = peer
	m.body = body_node
	m.api = member_api
	m.prog = DmProgression.new({"level": level, "experience": 0, "gold": 0}, null)
	m.loot_view = DmLootView.new()
	if not discipline_info.is_empty():
		m.discipline = discipline_info
	return m


func alive() -> bool:
	return body != null and is_instance_valid(body) and (not body.has_method("dm_alive") or bool(body.call("dm_alive")))


func pos() -> Vector3:
	return body.global_position if body != null and is_instance_valid(body) and body.is_inside_tree() else (body.position if body != null and is_instance_valid(body) else Vector3(1e9, 0, 1e9))


func owned_ids() -> Dictionary:
	var d := {}
	for it in bag:
		d[it["item_id"]] = true
	return d


func try_take(d: Dictionary) -> bool:
	if take_item.is_valid():
		return bool(take_item.call(d))
	if bag.size() >= bag_cap:
		return false
	bag.append(d)
	return true


## First kill of this boss by this character? Records it.
func claim_trophy(boss_id: String) -> bool:
	if trophy_store.is_valid():
		return bool(trophy_store.call(boss_id))
	if trophies.has(boss_id):
		return false
	trophies[boss_id] = true
	return true
