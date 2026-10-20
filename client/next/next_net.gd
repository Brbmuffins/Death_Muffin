class_name DmNextNet
extends Node
## 2-player co-op on the combat core (client/README.md "Co-op on the core"): the three messages of the core and the few that stay GDScript, over
## the session's relay peer (DmRelayPeer: the lobby WebSocket, or the UDP lane when the relay offers one). One node `Net` at the same path on every peer.
##
## HOST -> GUEST (a guest is a roster member; nothing is sent to a peer that has not said hello, whose game may still be loading)
##   snapshot   `_rpc_snapshot`   unreliable_ordered, 20 Hz: `core.snapshot_parts(tick, PART_MAX)`. The Full Party snapshot is 1.2 KB on average and reaches 1.7 KB, past the 1,392-byte
##              packet the old code stayed under (ENet fragments a bigger unreliable packet and one lost fragment loses all of it), so it is cut by BODY RANGES: the live enemies in spawn
##              order, then the thralls, as many messages as it takes to keep each under PART_MAX bytes. Every part is a complete snapshot message of its own bodies (header, counts,
##              ids from 0) with its own tick (`tick`, +1, +2 ...; the next frame starts after the last part). The guest APPLIES EACH PART AS IT ARRIVES: bodies are independent records, a
##              puppet ignores a tick that is not newer, and a lost part loses only its bodies' update for 50 ms (the next snapshot has them), so there is nothing to reassemble and no
##              frame to wait for. One part is the common case (a fight under 1,300 B is one packet).
##   reliable   `_rpc_reliable`   reliable, every tick that has content: `core.take_reliable()`, the numbered batch of the discrete events (spawns, deaths, zones, statuses, corpses,
##              thralls ...). A guest that sees a gap asks for a baseline.
##   baseline   `_rpc_baseline`   reliable, once to a new guest and again on request: `core.baseline()`, the whole present as records. The guest clears its presentation first.
##   heroes     `_rpc_heroes`     reliable: {peer id: the hero's external id in the host's core}, on every join and leave. The ids in the events (the owner of a thrall, the source of a
##              blow) are the host's; a guest's hero bodies adopt them (`DmCoreHost.adopt_hero`).
##   vitals     `_rpc_vitals`     unreliable_ordered, 20 Hz: every hero's [hp, max, resource, resource max, alive]. A fall in a guest's own health is its `hurt` (the damage number,
##              the flash and the sounds: DmHeroBody.apply_vitals). The same message carries the thralls' blows (below), so they cost no packet of their own.
##   effect     `_rpc_effect`     reliable: an enemy dragged the guest's hero (`hero_effect`): the guest's "Dragged!" and camera shake. A chill and a root are statuses, which replicate.
##   tier       `_rpc_tier`       reliable: the world's Wave Speed tier (the host's dial), on a join and whenever it changes, so a guest's window follows the host's world: the Nightfall light and the
##              milestones' banners (DmWaveMilestones, a guest has one too).
##   blows      (in `_rpc_vitals`)  [enemy id, damage, ...] for each blow a thrall landed since the last message, so the guest's HUD numbers every blow as the host's does (the puppet core derives
##              only the hit flash and the killing blow, and a derived event names no source). 8 bytes a blow, at most BLOWS_MAX a message.
##   The hero positions are the session's own snapshot (DmSession, 20 Hz), the King's state and events are DmBossHost's, the rites' events DmRiteCaster's.
## GUEST -> HOST: move intents (DmSession), `request_cast` (DmRiteCaster) and `_rpc_need_baseline` (a batch went missing). The host resolves a guest's rites on its core; the guest's
## thralls are the host's bodies, owned by the guest's hero external.
##
## Versions (DECISIONS B40): the session's hello carries the build and `DmCore.wire_version()` (DmSession); the core's own messages carry the wire version and a hash of the data
## tables, so a guest whose first message is refused for that reason (not for a gap) leaves with the core's words, which name the side to update.
## The host collects reliable events only while a guest is in (`set_replication`): solo play pays nothing.

signal baseline_applied                        ## guest: the host's whole present arrived (the crowd is cleared and rebuilt from it)
signal refused(reason: String)                 ## guest: the host's messages cannot be used (another version or other data): the game scene leaves the session with this text
signal thrall_blows(blows: PackedInt32Array)   ## guest: [enemy id, damage, ...] the thralls' blows since the last message (the HUD floats a number over each enemy)

const SEND_HZ := 20.0
const PRIORITY := 150                          ## after the core's tick (DmCoreHost.PRIORITY 100): the snapshot shows the state this tick ended in
## The most bytes of core snapshot in one packet. A game packet is this + the RPC frame (about 20 B) + the relay's 6-byte header, and ENet sends up to about 1,364 B in one unfragmented
## datagram (MTU 1,392). 1,300 leaves room for the frame and for a longer node path.
const PART_MAX := 1300
const ASK_EVERY_MS := 1000                     ## a guest asks for a baseline at most this often
const BLOWS_MAX := 32                          ## the most thrall blows one message carries (the HUD shows six thrall numbers at once; a Full Party sends about one a message)

var game: Node                                 ## DmNextGame
var part_max := PART_MAX                       ## tests cut smaller to exercise many parts
## Counters for the tests and the F3 overlay (host: what was sent; guest: what arrived).
var stats := {"frames": 0, "parts": 0, "snapshot_bytes": 0, "max_part": 0, "batches": 0, "reliable_bytes": 0, "baselines": 0, "baseline_bytes": 0, "vitals": 0,
		"heroes": 0, "asked": 0, "applied_parts": 0, "lost_parts": 0, "applied_batches": 0, "applied_baselines": 0, "refused_messages": 0,
		"blows": 0, "blow_msgs": 0, "blow_bytes": 0, "applied_blows": 0}

var _applied := {}                             ## guest: the ticks of the snapshot parts applied lately (the last 128): which parts of a frame arrived
var _last_tick := 0                            ## guest: the newest part applied
var _guests := {}                              ## host: peer id -> true (roster members that were sent their baseline)
var _thralls := {}                             ## host: core id -> true for every living thrall, kept once a guest is in (a blow of one is told to the guests)
var _blows := PackedInt32Array()               ## host: [enemy id, damage, ...] since the last send
var _watching := false
var _asked_by := {}                            ## host: peer id -> when it last asked for a baseline (ms)
var _acc := 0.0
var _tick := 1                                 ## host: the number of the next snapshot part
var _heroes_table := {}                        ## guest: peer id -> the host's external id of that player's hero
var _asked_at := 0
var _refused := false                          ## guest: the host's messages were refused for good


func _init() -> void:
	process_physics_priority = PRIORITY


# ---- host --------------------------------------------------------------------------------------------------------------------------------

func _core() -> RefCounted:
	return (game.get("core_host") as DmCoreHost).core if game != null and game.get("core_host") != null else null


func _is_host() -> bool:
	return game != null and multiplayer.is_server() and game.session.is_active()


## Host: a player was accepted into the session. It gets the whole present now, then the batches and snapshots.
func add_guest(peer: int) -> void:
	if not _is_host() or peer == 1 or _guests.has(peer):
		return
	var core := _core()
	if _guests.is_empty():
		core.set_replication(true)             # the first guest: from here on the reliable events are collected
		_watch_thralls()
	_guests[peer] = true
	var base: PackedByteArray = core.baseline()
	_rpc_baseline.rpc_id(peer, base)
	stats["baselines"] += 1
	stats["baseline_bytes"] += base.size()
	send_heroes()
	_send_world(peer)


## Host: what of the party's world is not the core's present, to one guest: its Wave Speed tier (Nightfall) and its seals and doors (DmNextParty).
## Sent with every baseline, the first and each one asked again: a message lost on the way (a relay drops a packet for a player it does not know yet)
## then heals with the present, as the core's state does; a guest left with the doors shut would walk into a sealed gate.
func _send_world(peer: int) -> void:
	if game.milestones != null and game.milestones.seen_tier >= 0.0:
		_rpc_tier.rpc_id(peer, game.milestones.seen_tier)
	if game.party != null:
		game.party.send_seals(peer)


## Host: a player left. The last one out turns the collecting off.
func remove_guest(peer: int) -> void:
	if _guests.erase(peer) and _guests.is_empty() and _core() != null:
		_core().set_replication(false)


func guests() -> Array:
	return _guests.keys()


## Host: the world's Wave Speed tier changed (DmWaveMilestones.on_tier): every guest's window follows it.
func send_tier(tier: float) -> void:
	if _is_host():
		for peer in _guests:
			_rpc_tier.rpc_id(peer, tier)


## Host: from the first guest on, the thralls' blows on enemies are collected (the core's `enemy_damaged` with a thrall as the source) to be sent with the snapshot. The set of living thralls is
## seeded from the core and kept by its raise and removal events; nothing runs per frame and a solo game never gets here.
func _watch_thralls() -> void:
	if _watching:
		return
	_watching = true
	var ch := game.core_host as DmCoreHost
	for id in ch.core.thrall_ids():
		_thralls[id] = true
	ch.thrall_raised.connect(func(id: int, _k: String, _o: int, _sl: int, _em: bool, _c: bool, _x: float, _z: float, _y: float, _h: float) -> void: _thralls[id] = true)
	ch.thrall_removed.connect(func(id: int) -> void: _thralls.erase(id))
	ch.enemy_damaged.connect(_on_enemy_damaged)


func _on_enemy_damaged(id: int, source: int, amount: float, _hp: float) -> void:
	if _guests.is_empty() or not _thralls.has(source) or _blows.size() >= BLOWS_MAX * 2:
		return
	_blows.append(id)
	_blows.append(int(amount))


## Host: an enemy dragged the hero of guest `peer`: the guest's own HUD floats the word and shakes the camera, as the host's does for its own hero. Nothing for a peer that is not a guest.
func hero_effect(peer: int, kind: StringName) -> void:
	if _is_host() and _guests.has(peer):
		_rpc_effect.rpc_id(peer, String(kind))


## Host: the table of hero external ids, to every guest (on a join, a leave, a respawn that re-registered a body).
func send_heroes() -> void:
	if not _is_host() or _guests.is_empty():
		return
	var table := {}
	for b in game.session.get_bodies():
		var hb := b as DmHeroBody
		if hb != null and hb.core_id != 0:
			table[hb.owner_peer] = hb.core_id
	for peer in _guests:
		_rpc_heroes.rpc_id(peer, table)
	stats["heroes"] += 1


func _physics_process(delta: float) -> void:
	if _guests.is_empty() or not _is_host():
		return
	var core := _core()
	var rel: PackedByteArray = core.take_reliable()
	if not rel.is_empty():
		for peer in _guests:
			_rpc_reliable.rpc_id(peer, rel)
		stats["batches"] += 1
		stats["reliable_bytes"] += rel.size() * _guests.size()
	_acc += delta
	if _acc < 1.0 / SEND_HZ:
		return
	_acc = fmod(_acc, 1.0 / SEND_HZ)
	var parts: Array = core.snapshot_parts(_tick, part_max)
	_tick += parts.size()
	stats["frames"] += 1
	for part: PackedByteArray in parts:
		for peer in _guests:
			_rpc_snapshot.rpc_id(peer, part)
		stats["parts"] += 1
		stats["snapshot_bytes"] += part.size() * _guests.size()
		stats["max_part"] = maxi(int(stats["max_part"]), part.size())
	_send_vitals()


func _send_vitals() -> void:
	var ids := PackedInt32Array()
	var rows: Array = []
	for b in game.session.get_bodies():
		var hb := b as DmHeroBody
		if hb != null:
			ids.append(hb.owner_peer)
			rows.append(hb.vitals())
	for peer in _guests:
		_rpc_vitals.rpc_id(peer, ids, rows, _blows)
	stats["vitals"] += 1
	if not _blows.is_empty():
		stats["blows"] += _blows.size() >> 1
		stats["blow_msgs"] += 1
		stats["blow_bytes"] += _blows.size() * 4 * _guests.size()
		_blows.clear()


# ---- guest -------------------------------------------------------------------------------------------------------------------------------

## Guest: give every hero body the id the host knows it by. The table and the bodies (the session's spawner) arrive in either order, so a body that is not there yet is retried
## a few times a quarter second apart.
func apply_heroes(tries := 0) -> void:
	if game == null or game.get("core_host") == null:
		return
	var h := game.core_host as DmCoreHost
	var missing := false
	for peer in _heroes_table:
		var b := game.body_of(int(peer)) as DmHeroBody
		if b == null:
			missing = true
		elif b.core_id != int(_heroes_table[peer]):
			b.core_id = int(_heroes_table[peer])
			h.adopt_hero(b, b.core_id)
	if missing and tries < 40 and is_inside_tree():
		get_tree().create_timer(0.25).timeout.connect(apply_heroes.bind(tries + 1))


func _guest_core() -> RefCounted:
	return _core() if game != null and not multiplayer.is_server() else null


## Guest: a batch or a snapshot was refused. A gap is repaired by a baseline; anything else (another version, other data) is for good.
func _refuse_or_ask(core: RefCounted, what: String) -> void:
	stats["refused_messages"] += 1
	var st: Dictionary = core.replication_stats()
	if bool(st["need_baseline"]):
		var now := Time.get_ticks_msec()
		if now - _asked_at >= ASK_EVERY_MS:
			_asked_at = now
			stats["asked"] += 1
			_rpc_need_baseline.rpc_id(1)
		return
	if what == "snapshot" and int(st["snapshots_applied"]) > 0:
		return                                  # one damaged snapshot of a running game: the next replaces it
	if not _refused:
		_refused = true
		var why := String(core.replication_error())
		printerr("[coop] guest: refused the host's %s: %s" % [what, why])
		refused.emit(why)


# ---- RPCs --------------------------------------------------------------------------------------------------------------------------------

@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_snapshot(part: PackedByteArray) -> void:
	var core := _guest_core()
	if core == null or _refused:
		return
	if core.apply_snapshot(part):
		stats["applied_parts"] += 1
		_note_tick(part.decode_u32(8))
	else:
		_refuse_or_ask(core, "snapshot")


## The parts of a frame have consecutive ticks, so a hole in them is a part the network lost (unreliable: the next snapshot repairs it); counted for the overlay and the tests.
func _note_tick(tick: int) -> void:
	if _last_tick != 0 and tick > _last_tick + 1:
		stats["lost_parts"] += tick - _last_tick - 1
	_last_tick = maxi(_last_tick, tick)
	_applied[tick] = true
	if _applied.size() > 128:
		_applied.erase(_applied.keys()[0])


## Guest: whether the snapshot part with this tick was applied (of the last 128).
func has_applied(tick: int) -> bool:
	return _applied.has(tick)


@rpc("authority", "call_remote", "reliable")
func _rpc_reliable(batch: PackedByteArray) -> void:
	var core := _guest_core()
	if core == null or _refused:
		return
	if core.apply_reliable(batch):
		stats["applied_batches"] += 1
	else:
		_refuse_or_ask(core, "batch")


@rpc("authority", "call_remote", "reliable")
func _rpc_baseline(base: PackedByteArray) -> void:
	var core := _guest_core()
	if core == null or _refused:
		return
	(game.core_host as DmCoreHost).view.clear()   # the baseline replaces everything the guest knew, without removal events: the presentation starts over
	if core.apply_reliable(base):
		stats["applied_baselines"] += 1
		apply_heroes()
		baseline_applied.emit()
	else:
		_refuse_or_ask(core, "baseline")


@rpc("authority", "call_remote", "reliable")
func _rpc_heroes(table: Dictionary) -> void:
	if _guest_core() == null:
		return
	_heroes_table = table
	apply_heroes()


## Guest: the host's world is at this Wave Speed tier (on joining, quietly: the state it was given; later a banner when a milestone is crossed).
@rpc("authority", "call_remote", "reliable")
func _rpc_tier(tier: float) -> void:
	if _guest_core() != null and game.milestones != null:
		game.milestones.on_tier(tier)


## Guest: the host's word of a drag on the local hero (the only effect the HUD acts on): the body says it as the host's does.
@rpc("authority", "call_remote", "reliable")
func _rpc_effect(kind: String) -> void:
	var b: DmHeroBody = game.local_body() if _guest_core() != null else null
	if b != null and kind == "pull":
		b.enemy_effect.emit(&"pull")


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_vitals(ids: PackedInt32Array, rows: Array, blows: PackedInt32Array) -> void:
	if _guest_core() == null:
		return
	for i in ids.size():
		var hb := game.session.get_body(ids[i]) as DmHeroBody
		if hb != null and not hb.simulated:
			hb.apply_vitals(rows[i])
	if not blows.is_empty():   # the thralls' blows since the host's last message (the HUD numbers each over its enemy, as the host's does for the blows it sees)
		stats["applied_blows"] += blows.size() >> 1
		thrall_blows.emit(blows)


## Guest -> host: a batch went missing; send the whole present again (the host answers at most once a second per guest).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_need_baseline() -> void:
	if not _is_host():
		return
	var peer := multiplayer.get_remote_sender_id()
	if not _guests.has(peer):
		return
	var now := Time.get_ticks_msec()
	if now - int(_asked_by.get(peer, 0)) < ASK_EVERY_MS / 2:
		return
	_asked_by[peer] = now
	var base: PackedByteArray = _core().baseline()
	_rpc_baseline.rpc_id(peer, base)
	stats["baselines"] += 1
	stats["baseline_bytes"] += base.size()
	_send_world(peer)

