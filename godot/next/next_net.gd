class_name DmNextNet
extends Node
## Per-tick state replication for what MultiplayerSpawner does not carry: enemy state (DmEnemy.get_net_state / apply_net_state) and hero
## vitals. The host sends batched unreliable_ordered RPCs at SEND_HZ; clients apply. In a solo session (no peers) nothing is sent, but the
## call sites are the same ones a 2-player session uses (no `if solo` anywhere in gameplay code).
## Must sit at the same NodePath on every peer (it does: a fixed child of the DmNextGame scene).

const SEND_HZ := 20.0
const CHUNK := 6                        ## enemies per packet: ~180 bytes each as a Dictionary, 8 measured 1428-1460 B, over the 1392 B MTU (ENet fragments; one lost fragment drops the packet)

var game: Node                          ## DmNextGame
var packets_sent: int = 0
var states_applied: int = 0

var _acc: float = 0.0


func _physics_process(delta: float) -> void:
	if game == null or not multiplayer.is_server() or not game.session.is_active() or multiplayer.get_peers().is_empty():
		return
	_acc += delta
	if _acc < 1.0 / SEND_HZ:
		return
	_acc = fmod(_acc, 1.0 / SEND_HZ)
	_send_enemies()
	_send_vitals()


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


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_vitals(ids: PackedInt32Array, rows: Array) -> void:
	for i in ids.size():
		var hb := game.session.get_body(ids[i]) as DmHeroBody
		if hb != null and not hb.simulated:
			hb.apply_vitals(rows[i])
