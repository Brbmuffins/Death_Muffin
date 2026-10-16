class_name DmCounsel
extends RefCounted
## Covenant counsel: the first-time tip queue (archive/legacy-web:src/ui/Onboarding.ts class `Onboarding`). Pure logic, no nodes: one card at a time, each tip once per
## character, WHEN a queued tip may appear is DmCounselCadence's call, "Don't show tips" turns it off, `show_tips_again()` replays it.
## The view (DmCounselView) listens to the signals and draws the DmTipCard + the TIP_ANCHOR glow.
##
## Feeding it (see README.md for every event id -> web source line):
##   counsel.notify("enemy_spawned", {"def": "golem", "elite": false, "near": true, "area_safe": false})   # a game event
##   counsel.tick(delta, busy_dict)                                                                         # every frame; busy = calm state
## Time is the counsel's own millisecond clock, advanced only by tick()/advance_to() (so a paused game pauses counsel), like the web's
## injected game clock; queued shows with a delay and the 1 s re-check pump run on a deterministic internal timer queue.

signal card_shown(id: String, kind: String, title_html: String, body_html: String, ms: int)
signal card_hidden(id: String)         # the card closed (read, clicked, sent back or preempted)
signal card_removed                    # 220 ms after card_hidden: the view's fade-out is done
signal glow_changed(id: String)        # TIP_ANCHOR subject to light ("" = none, put the glow out)
signal tips_disabled                   # the card's "Don't show tips" was pressed: the integrator stores Settings no_tips = true
signal seen_changed

## Showing a tip also counts these as seen (Onboarding.ts ALSO_SEEN).
const ALSO_SEEN := {"welcome": ["acre"]}

## Set by the integrator (Onboarding.ts `busy`, `stale`, `keyFor`).
var busy: Callable = Callable()                  # () -> Busy dict; default: the last set_busy()/tick() value
var stale: Callable = Callable()                 # (id) -> bool: the tip's context has gone (the "first thrall" card with no thrall alive)
var key_for: Callable = Callable()               # (ability_id) -> String key ("" when the rite is not on the bar)
var auto_allowed: bool = false                   # renderText's {auto} gate (owner-only in the web)
var tips_enabled: bool = true                    # Settings `tips` (the web: !no_tips)
var record: bool = false                         # tests: keep a log of show/hide/glow/back/clear
var log: Array = []

var seen: Dictionary = {}                        # tip id -> true, insertion ordered (JS Set)
var queue: Array = []
var shown: Dictionary = {}                       # {id, kind, shown_at} or {}
var shown_entry: Dictionary = {}
var last_closed_at: float
var group_shown_at: Dictionary = {}
var pending: Dictionary = {}
var now_ms: float = 0.0

var _store: DmCounselStore
var _key: String
var _busy: Dictionary = DmCounselCadence.not_busy()
var _seq := 0
var _timers: Dictionary = {}
var _timer_seq := 0
var _pump_timer := 0
var _hide_timer := 0
var _has_card := false
var _hide_remaining := 0.0
var _hide_started := 0.0
var _paused := false
var _card_ms := 0


func _init(character_id: int = 0, store: DmCounselStore = null, start_ms: float = 0.0) -> void:
	_store = store if store != null else DmCounselStore.new()
	_key = "dm_tips_v1_%d" % character_id
	now_ms = start_ms
	# A fresh session may open with its first card after about three seconds, not twenty.
	last_closed_at = now_ms - float(DmCounselData.c("START_GAP_MS"))
	var raw := _store.get_item(_key)
	if raw != "":
		var list: Variant = JSON.parse_string(raw)
		if list is Array:
			for id in list:
				if id is String and DmCounselData.has_tip(id):
					seen[id] = true


# --- clock + timers (Onboarding.ts later()/cancel(); window.setTimeout) ---

func tick(delta_s: float, busy_state: Variant = null) -> void:
	if busy_state is Dictionary:
		set_busy(busy_state)
	advance_to(now_ms + delta_s * 1000.0)


## Run every timer due up to `t` in (due, creation) order, setting the clock to each one's due time.
func advance_to(t: float) -> void:
	while true:
		var best := 0
		var bd := INF
		for id in _timers:
			var due: float = _timers[id]["due"]
			if due <= t and (best == 0 or due < bd or (due == bd and id < best)):
				best = id
				bd = due
		if best == 0:
			break
		var cb: Callable = _timers[best]["cb"]
		_timers.erase(best)
		now_ms = maxf(now_ms, bd)
		cb.call()
	now_ms = maxf(now_ms, t)


func _later(cb: Callable, ms: float) -> int:
	_timer_seq += 1
	_timers[_timer_seq] = {"due": now_ms + maxf(0.0, ms), "cb": cb}
	return _timer_seq


func _cancel(id: int) -> void:
	_timers.erase(id)


func set_busy(partial: Dictionary) -> void:
	_busy = DmCounselCadence.busy_of(partial)


func _busy_now() -> Dictionary:
	if busy.is_valid():
		return DmCounselCadence.busy_of(busy.call())
	return _busy


func _cadence(last_closed: float = NAN) -> Dictionary:
	return {"now": now_ms, "last_closed_at": last_closed_at if is_nan(last_closed) else last_closed, "group_shown_at": group_shown_at, "busy": _busy_now()}


# --- public API ---

## Ask for a tip: once per character, never twice at the same time. `opts`: null, `true` (bump), or {kind?, bump?}
## (Onboarding.show: the Codex lectern is "asked", the Settings replay is "calm"). Whether and when it appears is the cadence's call.
func show(id: String, delay_ms: float = 0.0, opts: Variant = null) -> void:
	if not tips_enabled or seen.has(id) or pending.has(id) or _queued(id) or (not shown.is_empty() and shown["id"] == id):
		return
	if delay_ms > 0.0:
		pending[id] = true
		_later(func() -> void:
			pending.erase(id)
			show(id, 0.0, opts), delay_ms)
		return
	var o: Dictionary = {}
	if opts is bool:
		o = {"bump": opts}
	elif opts is Dictionary:
		o = opts
	_seq += 1
	var entry := DmCounselCadence.make_entry(id, now_ms, _seq, bool(o.get("bump", false)))
	if o.has("kind") and o["kind"] != null:
		entry["kind"] = o["kind"]
	queue.append(entry)
	_pump()


## A game event (see DmCounselEvents / README.md): resolves to one or more show() calls exactly as the web's call site makes them.
func notify(event_id: String, ctx: Dictionary = {}) -> void:
	for c in DmCounselEvents.calls(event_id, ctx):
		show(c["tip"], c["delay"], c["opts"])


## State-driven triggers the web re-checks every 400 ms (WorldScene.tickOnboarding); call it at that rate with the plain numbers it needs.
func notify_tick(ctx: Dictionary) -> void:
	for c in DmCounselEvents.tick_calls(ctx):
		show(c["tip"], c["delay"], c["opts"])


## Settings -> "Show tips again": forget what was seen, then walk the parts of the screen the player already has, one calm card each
## (WorldScene.ts:1316). ctx: {atlas_revealed: bool, spells_revealed: bool}.
func show_tips_again(ctx: Dictionary = {}) -> void:
	reset()
	for c in DmCounselEvents.calls("show_tips_again", ctx):
		show(c["tip"], c["delay"], c["opts"])


## Forget which tips this character has seen, so the whole sequence plays again.
func reset() -> void:
	clear()
	seen.clear()
	group_shown_at = {}
	_persist()
	seen_changed.emit()


## The Settings `tips` switch (the web's onSettingsChange: tips off hides the card and drops the queue).
func set_tips_enabled(on: bool) -> void:
	tips_enabled = on
	if not on:
		clear()


## The card's "Don't show tips" button.
func skip() -> void:
	set_tips_enabled(false)
	tips_disabled.emit()


## The card was clicked (or its time ran out).
func dismiss() -> void:
	if not _has_card:
		return
	if record:
		log.append([now_ms, "hide", shown.get("id", null)])
	_has_card = false
	_light("")
	_cancel(_hide_timer)
	var id: String = shown.get("id", "")
	_later(func() -> void: card_removed.emit(), 220.0)
	card_hidden.emit(id)
	shown = {}
	shown_entry = {}
	last_closed_at = now_ms
	_later(func() -> void: _pump(), 300.0)


## Pointer on the card (or dragging it) pauses its timer; leaving resumes it (Onboarding.ts pauseTimer/resumeTimer).
func pause_card() -> void:
	if not _has_card or _paused:
		return
	_paused = true
	_hide_remaining = maxf(0.0, _hide_remaining - (now_ms - _hide_started))
	_cancel(_hide_timer)


func resume_card(dragging: bool = false) -> void:
	if not _has_card or dragging or not _paused:
		return
	_paused = false
	_cancel(_hide_timer)
	_hide_started = now_ms
	_hide_timer = _later(func() -> void: dismiss(), _hide_remaining)


## How long the card has been up, counting only unpaused time (drives the draining timer line).
func card_elapsed_ms() -> float:
	if not _has_card:
		return 0.0
	var remaining := _hide_remaining if _paused else _hide_remaining - (now_ms - _hide_started)
	return clampf(float(_card_ms) - remaining, 0.0, float(_card_ms))


func busy_state() -> Dictionary:
	return _busy_now()


## Test helper: the recorded log with times relative to `t0`.
func record_log_rel(t0: float) -> Array:
	var out: Array = []
	for e in log:
		var r: Array = e.duplicate()
		r[0] = float(r[0]) - t0
		out.append(r)
	return out


func is_card_up() -> bool:
	return _has_card


func shown_id() -> String:
	return String(shown.get("id", ""))


func has_seen(id: String) -> bool:
	return seen.has(id)


func dispose() -> void:
	clear()


# --- internals ---

func _queued(id: String) -> bool:
	for t in queue:
		if t["id"] == id:
			return true
	return false


## Decide, now, whether the card on screen should step aside and whether the next waiting tip may open; re-check in a second.
func _pump() -> void:
	_cancel(_pump_timer)
	_pump_timer = 0
	if not tips_enabled:
		return
	queue = DmCounselCadence.prune(queue, now_ms)
	if stale.is_valid():
		var kept: Array = []
		for t in queue:
			if not bool(stale.call(t["id"])):
				kept.append(t)
		queue = kept
	if _has_card and not shown.is_empty() and not shown_entry.is_empty():
		var s := _cadence()
		var waiting := DmCounselCadence.pick_next(queue, _cadence(-INF))
		if DmCounselCadence.should_preempt(shown, waiting, s) and not waiting.is_empty():
			# The urgent tip takes the place at once (it must not wait out the gap the swap itself starts, or the old card would return).
			_send_back()
			queue = queue.filter(func(t: Dictionary) -> bool: return t["seq"] != waiting["seq"])
			_present(waiting)
		elif DmCounselCadence.should_yield(shown, s):
			_send_back()
	if not _has_card:
		var nxt := DmCounselCadence.pick_next(queue, _cadence())
		if not nxt.is_empty():
			queue = queue.filter(func(t: Dictionary) -> bool: return t["seq"] != nxt["seq"])
			_present(nxt)
	if not queue.is_empty():
		_pump_timer = _later(func() -> void: _pump(), float(DmCounselData.c("PUMP_MS")))


## The card on screen leaves before it was read (a fight began, something urgent came): it returns at the front of the line.
func _send_back() -> void:
	if record:
		log.append([now_ms, "back", shown.get("id", null)])
	if not shown_entry.is_empty():
		var entry := shown_entry
		seen.erase(entry["id"])
		for extra in ALSO_SEEN.get(entry["id"], []):
			seen.erase(extra)
		_persist()
		seen_changed.emit()
		if not (stale.is_valid() and bool(stale.call(entry["id"]))):
			var back := entry.duplicate()
			back["queued_at"] = now_ms
			queue.push_front(back)
	dismiss()


func _present(entry: Dictionary) -> void:
	var id: String = entry["id"]
	if not tips_enabled or seen.has(id):
		return
	seen[id] = true
	for extra in ALSO_SEEN.get(id, []):
		seen[extra] = true
	_persist()
	seen_changed.emit()
	shown = {"id": id, "kind": entry["kind"], "shown_at": now_ms}
	shown_entry = entry
	var group := DmCounselData.group_of(id)
	if group != "":
		group_shown_at[group] = now_ms
	var body := DmCounselData.render_text(DmCounselData.body(id), key_for, auto_allowed)
	var title_html := DmCounselData.render_text(DmCounselData.title(id), Callable(), auto_allowed)
	# Give each card at least 25 seconds and longer counsel more reading time.
	var ms := DmCounselCadence.show_ms(entry["kind"], DmCounselData.word_count(body))
	_has_card = true
	_paused = false
	_card_ms = ms
	if record:
		log.append([now_ms, "show", id, entry["kind"], "%dms" % ms])
	card_shown.emit(id, entry["kind"], title_html, body, ms)
	_light(id)
	_hide_remaining = float(ms)
	_hide_started = now_ms
	_hide_timer = _later(func() -> void: dismiss(), _hide_remaining)


## Hide the current card and drop everything queued (tips turned off).
func clear() -> void:
	if record:
		log.append([now_ms, "clear"])
	queue = []
	pending.clear()
	var had := _has_card
	var id := String(shown.get("id", ""))
	shown = {}
	shown_entry = {}
	_pump_timer = 0
	_timers.clear()
	_has_card = false
	if had:
		card_hidden.emit(id)
		card_removed.emit()
	_light("")


func _light(id: String) -> void:
	if record:
		log.append([now_ms, "glow", id if id != "" else null])
	glow_changed.emit(id)


func _persist() -> void:
	_store.set_item(_key, JSON.stringify(seen.keys()))
