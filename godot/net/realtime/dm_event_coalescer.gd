class_name DmEventCoalescer
extends RefCounted
## Port of src/net/eventCoalescer.ts: keeps the host's event batches under the relay's 60/s budget, chunked to the 400-event cap.
var _send: Callable
var _held: Array = []
var _last_send: float = -INF
var _gap_ms: float
var _max_batch: int

func _init(send: Callable, per_sec: float = 40.0, max_batch: int = 200) -> void:
	_send = send
	_gap_ms = 1000.0 / per_sec
	_max_batch = max_batch

## Call once per frame (empty list when nothing happened) so held events get their turn.
func push(events: Array, now_ms: float) -> void:
	if not events.is_empty():
		_held.append_array(events)
	if _held.is_empty() or now_ms - _last_send < _gap_ms:
		return
	_last_send = now_ms
	var n := mini(_max_batch, _held.size())
	var batch := _held.slice(0, n)
	_held = _held.slice(n)
	_send.call(batch)

func clear() -> void:
	_held = []
	_last_send = -INF

func waiting() -> int:
	return _held.size()
