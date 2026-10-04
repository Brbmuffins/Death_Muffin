class_name DmRtReconnector
extends RefCounted
## Port of the TS `Reconnector` (src/net/reconnect.ts): runs `attempt` with backoff until it works, fails for good, or stop().
## attempt: Callable returning a DmResult (may be a coroutine; awaited). Timers come from the SceneTree, or from `timer_factory`
## (Callable(ms: int, fn: Callable) -> Variant, for tests).

signal retry(n: int, delay_ms: int, error: String)
signal gave_up(error: String)
signal succeeded(result: DmResult)

var mode: String = "first"  # "first" | "rejoin"
var attempt: Callable
var timer_factory: Callable = Callable()

var _n: int = 0
var _in_flight: bool = false
var _stopped: bool = false
var _finished: bool = false
var _timer_gen: int = 0
var _timer_armed: bool = false

func _init(p_mode: String, p_attempt: Callable) -> void:
	mode = p_mode
	attempt = p_attempt

func is_active() -> bool:
	return not _stopped and not _finished

func start() -> void:
	if is_active() and not _timer_armed and not _in_flight:
		_schedule("")

## Try right now (network came back). The backoff counter keeps going if it fails.
func kick() -> void:
	if not is_active() or _in_flight:
		return
	_clear()
	_run()

func stop() -> void:
	_stopped = true
	_clear()

func _delay() -> int:
	return DmRtClient.rejoin_delay_ms(_n) if mode == "rejoin" else DmRtClient.first_connect_delay_ms(_n)

func _schedule(err: String) -> void:
	var ms := _delay()
	retry.emit(_n, ms, err)
	_n += 1
	_timer_gen += 1
	_timer_armed = true
	var gen := _timer_gen
	var fire := func() -> void:
		if gen != _timer_gen:
			return
		_timer_armed = false
		_run()
	if timer_factory.is_valid():
		timer_factory.call(ms, fire)
	else:
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			tree.create_timer(ms / 1000.0).timeout.connect(fire)

func _clear() -> void:
	_timer_gen += 1
	_timer_armed = false

func _run() -> void:
	if not is_active() or _in_flight:
		return
	_in_flight = true
	var res: DmResult = await attempt.call()
	_in_flight = false
	if _stopped:
		return
	if res.ok:
		_finished = true
		succeeded.emit(res)
	elif DmRtClient.is_retryable_error(res.error, mode):
		_schedule(res.error)
	else:
		_finished = true
		gave_up.emit(res.error)
