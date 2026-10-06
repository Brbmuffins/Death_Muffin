class_name DmNextNet
extends Node
## Per-tick state replication for what MultiplayerSpawner does not carry: enemy state (DmEnemy.get_net_state / apply_net_state) and hero
## vitals. The host sends batched unreliable_ordered RPCs at SEND_HZ; clients apply. In a solo session (no peers) nothing is sent, but the
## call sites are the same ones a 2-player session uses (no `if solo` anywhere in gameplay code).
## Must sit at the same NodePath on every peer (it does: a fixed child of the DmNextGame scene).

const SEND_HZ := 20.0
const CUES: Array[StringName] = [&"shield_block", &"sanctify", &"unbind"]   ## the enemy `cue`s that have a visual; wire id = index (append-only)
const CUE_MAX := 16                     ## queued cues per send tick; more are dropped (each source is rate-limited already: shield 4/s, sanctify / unbind cooldowns)
const CHUNK := 6                        ## enemies per packet: ~180 bytes each as a Dictionary, 8 measured 1428-1460 B, over the 1392 B MTU (ENet fragments; one lost fragment drops the packet)

var game: Node                          ## DmNextGame
var packets_sent: int = 0
var states_applied: int = 0
var cues_applied: int = 0

var _acc: float = 0.0
var _cue_ids := PackedInt32Array()      ## host: cues waiting for the next 20 Hz send
var _cue_kinds := PackedByteArray()
var _cue_at := PackedVector3Array()


func _physics_process(delta: float) -> void:
	if game == null or not multiplayer.is_server() or not game.session.is_active() or multiplayer.get_peers().is_empty():
		return
	_acc += delta
	if _acc < 1.0 / SEND_HZ:
		return
	_acc = fmod(_acc, 1.0 / SEND_HZ)
	_send_enemies()
	_send_vitals()
	_send_cues()


## Host: queue the replicable cues of this enemy (`cue` is emitted on the host only; clients re-emit it on their puppet so DmEnemyFx draws it once per peer).
func watch_enemy(e: DmEnemy) -> void:
	e.cue.connect(_on_cue.bind(e))


func _on_cue(kind: StringName, at: Vector3, _radius: float, e: DmEnemy) -> void:
	var k := CUES.find(kind)
	if k < 0 or _cue_ids.size() >= CUE_MAX or multiplayer.get_peers().is_empty():
		return
	_cue_ids.append(DmWaveDirector.id_of(e))
	_cue_kinds.append(k)
	_cue_at.append(at)


func _send_cues() -> void:
	if _cue_ids.is_empty():
		return
	_rpc_cues.rpc(_cue_ids, _cue_kinds, _cue_at)
	packets_sent += 1
	_cue_ids = PackedInt32Array()
	_cue_kinds = PackedByteArray()
	_cue_at = PackedVector3Array()


func _send_enemies() -> void:
	var ids := PackedInt32Array()
	var states: Array = []
	for id in game.director.enemies:
		var e := game.director.enemies[id] as DmEnemy
		if e == null or not is_instance_valid(e) or not e.is_inside_tree():
			continue
		ids.append(id)
		states.append(e.get_net_state())
		if ids.size() >= CHUNK:
			_rpc_enemies.rpc(ids, states)
			packets_sent += 1
			ids = PackedInt32Array()
			states = []
	if not ids.is_empty():
		_rpc_enemies.rpc(ids, states)
		packets_sent += 1


func _send_vitals() -> void:
	var ids := PackedInt32Array()
	var rows: Array = []
	for b in game.session.get_bodies():
		var hb := b as DmHeroBody
		if hb != null:
			ids.append(hb.owner_peer)
			rows.append(hb.vitals())
	_rpc_vitals.rpc(ids, rows)
	packets_sent += 1


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_enemies(ids: PackedInt32Array, states: Array) -> void:
	for i in ids.size():
		var e: DmEnemy = game.director.enemy_by_id(ids[i])
		if e != null and e.is_inside_tree():
			e.apply_net_state(states[i])
			states_applied += 1


@rpc("authority", "call_remote", "reliable")
func _rpc_cues(ids: PackedInt32Array, kinds: PackedByteArray, ats: PackedVector3Array) -> void:
	for i in ids.size():
		var e: DmEnemy = game.director.enemy_by_id(ids[i])
		if e != null and e.is_inside_tree() and kinds[i] < CUES.size():
			e.cue.emit(CUES[kinds[i]], ats[i], 0.0)
			cues_applied += 1


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_vitals(ids: PackedInt32Array, rows: Array) -> void:
	for i in ids.size():
		var hb := game.session.get_body(ids[i]) as DmHeroBody
		if hb != null and not hb.simulated:
			hb.apply_vitals(rows[i])
