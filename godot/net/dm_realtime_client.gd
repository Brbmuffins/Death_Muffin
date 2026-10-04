class_name DmRealtimeClient
extends RefCounted
## Interface stub for the Socket.IO co-op layer (see REALTIME.md for the protocol). Solo play never needs it: every method is safe to
## call while disconnected. The transport (Socket.IO v4 over WebSocketPeer) is NOT implemented yet; `connect_to_world` reports that.
## Keep this surface: the game scene wires these signals and calls these senders, and the real implementation drops in later.

signal player_joined(player: Dictionary)
signal player_left(id: String)
signal player_moved(update: Dictionary)
signal player_gear(update: Dictionary)
signal chat_received(message: Dictionary)
signal intent_received(envelope: Dictionary)
signal snapshot_received(snapshot: Dictionary)
signal events_received(batch: Array)
signal host_changed(host_id: String, snapshot: Variant)
signal disconnected
signal session_replaced

var instance: String = ""
var host_id: String = ""
var self_id: String = ""
## Message counters for QA / the debug overlay (same keys as the TS client).
var stats := {"snapIn": 0, "snapOut": 0, "evIn": 0, "evOut": 0, "intentIn": 0, "intentOut": 0, "moveIn": 0}

func is_connected_to_world() -> bool:
	return false

func is_host() -> bool:
	return is_connected_to_world() and host_id == self_id

## request: JoinRequest {instance?, characterId, classIndex, level?, x, z, facing, gear?}. Returns a DmResult whose data is the JoinResult
## {self, players, hostId, instance, solo?, snapshot}, or an error ("Co-op service unreachable - playing solo" is the retryable one).
func connect_to_world(_token: String, _request: Dictionary) -> DmResult:
	return DmResult.failure("Realtime co-op is not available in this build yet — playing solo", 0)

func send_move(_update: Dictionary) -> void: pass
func send_gear(_gear: Dictionary) -> void: pass
func send_intent(_intent: Dictionary) -> void: pass
func send_snapshot(_snapshot: Dictionary) -> void: pass
func send_events(_batch: Array) -> void: pass
func send_chat(_text: String) -> void: pass
func send_perf(_payload: Dictionary) -> void: pass
func disconnect_from_world() -> void: pass

# --- Reconnection policy (port of src/net/reconnect.ts; pure, used by whoever drives connect_to_world) ----------------------------

## After a dropped link: 1 s, 2 s, 4 s, 8 s, then every 15 s.
static func rejoin_delay_ms(attempt: int) -> int:
	return mini(15000, 1000 * (1 << maxi(0, attempt)))

## First connect found the service down: 10 s, 20 s, then every 30 s.
static func first_connect_delay_ms(attempt: int) -> int:
	return mini(30000, 10000 * (maxi(0, attempt) + 1))

## mode: "first" | "rejoin"
static func is_retryable_error(message: String, mode: String) -> bool:
	var m := message.to_lower()
	if m.contains("not configured") or m.contains("not authenticated"):
		return false
	for needle in ["unreachable", "timeout", "timed out", "xhr poll error", "websocket error", "transport", "network", "econnrefused", "failed to fetch"]:
		if m.contains(needle):
			return true
	return mode == "rejoin" and (m.contains("already in this world") or m.contains("already in a world"))
