class_name DmContractsPanel
extends DmPanelB
## The Sexton's Contracts (src/ui/ContractsPanel.ts + contractsView.ts): three delivery orders a day, easy to hard.
##
## Data in:  set_board(board)  board = GET /api/contracts reply: {day, resetsAt (ISO), contracts:[{slot, itemId, name, qty, rarity, skill,
##           rewardGold, rewardItem:{name, qty}|null, done}], bonus:{gold, item:{name}, claimed}, streak}
##           set_counts({item_id: count in the bag}); set_busy(bool); set_error(text).
## Signals:  deliver_requested(slot)   -> DmApi.deliver_contract(character_id, slot) under the inventory-exclusive guard, then
##                                        DmApi.get_inventory(character_id); feed the reply to set_board() (its `gold` is credited by the caller).
##           refresh_requested         -> DmApi.get_contracts(character_id) (the daily board expired: the web re-fetches every 30 s tick).

signal deliver_requested(slot: int)
signal refresh_requested

const SLOT_NAMES := ["Easy", "Steady", "Hard"]

var board: Dictionary = {}
var counts: Dictionary = {}
var busy := false
## Test hook: a fixed "now" (epoch ms); -1 = the real clock.
var now_override_ms := -1
## Computed per-contract view (what is drawn): {slot, title, skill, pct, progress, reward, done, ready, deliver_enabled}.
var rows: Array[Dictionary] = []
var deliver_buttons: Dictionary = {}
var _tick: Timer


func _init() -> void:
	super._init()
	title = "Sexton’s Contracts"
	panel_width = 680


func _ready() -> void:
	_tick = Timer.new()
	_tick.wait_time = 30.0
	_tick.timeout.connect(tick)
	add_child(_tick)
	_tick.start()
	rebuild()


func _inputs() -> Variant:
	return [board, counts, busy, error_text, reset_text()]


func set_board(b: Dictionary) -> void:
	board = b
	rebuild()


func set_counts(c: Dictionary) -> void:
	counts = c
	rebuild()


func set_busy(v: bool) -> void:
	busy = v
	rebuild()


func _now() -> int:
	return now_override_ms if now_override_ms >= 0 else int(Time.get_unix_time_from_system() * 1000.0)


## contractsView.boardExpired: stale once the server's reset time has passed.
static func board_expired(resets_at: String, now: int) -> bool:
	var t := parse_iso_ms(resets_at)
	return t >= 0 and now >= t


## "2026-10-05T00:00:00.000Z" -> epoch ms (UTC); -1 when unparseable.
static func parse_iso_ms(s: String) -> int:
	var core := s.split(".")[0].rstrip("Z")
	if core.length() < 19:
		return -1
	var secs := Time.get_unix_time_from_datetime_string(core)
	var frac := 0
	if s.contains("."):
		frac = int(s.split(".")[1].rstrip("Z").substr(0, 3).rpad(3, "0"))
	return int(secs) * 1000 + frac


func reset_text() -> String:
	if board.is_empty():
		return ""
	var ms := maxi(0, parse_iso_ms(String(board.get("resetsAt", ""))) - _now())
	return "%dh %dm" % [ms / 3600000, (ms % 3600000) / 60000]


## The 30 s tick: ask for a fresh board once the old one expired (never mid-delivery), then refresh the countdown.
func tick() -> void:
	if not board.is_empty() and not busy and board_expired(String(board.get("resetsAt", "")), _now()):
		refresh_requested.emit()
	if is_inside_tree() and not DmPb.pointer_busy(self):
		rebuild()


func _build() -> void:
	rows.clear()
	deliver_buttons.clear()
	if board.is_empty():
		add_child(DmPb.hint(error_text if error_text != "" else "The Sexton is checking his ledger…"))
		return
	var note := DmPb.rich("The Sexton wants goods from the grave, and pays for them. New orders every day (in <b>%s</b>). Fill all three for a bonus." % reset_text(), 12)
	add_child(note)
	var list := DmPb.vbox(8)
	add_child(list)
	for c: Dictionary in board.get("contracts", []):
		_contract_card(list, c)
	var b: Dictionary = board.get("bonus", {})
	var foot := HFlowContainer.new()
	foot.add_theme_constant_override("h_separation", 14)
	var l1 := DmPb.text("Bonus for all three: %sg + %s%s" % [DmPb.num(b.get("gold", 0)), String(b.get("item", {}).get("name", "")), " (claimed today)" if b.get("claimed", false) else ""], 12)
	l1.name = "BonusLine"
	var streak := int(board.get("streak", 0))
	var l2 := DmPb.text("Streak: %d day%s" % [streak, "" if streak == 1 else "s"], 12)
	l2.name = "StreakLine"
	foot.add_child(l1)
	foot.add_child(l2)
	add_child(foot)
	_error_row()


func _contract_card(parent: Control, c: Dictionary) -> void:
	var slot := int(c["slot"])
	var qty := int(c["qty"])
	var have: int = int(counts.get(c["itemId"], 0))
	var ready := have >= qty
	var done: bool = c.get("done", false)
	var pct := mini(100, DmMath.js_round(float(have) / float(qty) * 100.0))
	var rarity := String(c.get("rarity", "common"))
	var rc := DmUi.rarity_color(rarity)
	var reward := "%sg" % DmPb.num(c.get("rewardGold", 0))
	var ri: Variant = c.get("rewardItem")
	if ri is Dictionary:
		reward += " + %s%s" % ["%d× " % int(ri.get("qty", 1)) if int(ri.get("qty", 1)) > 1 else "", ri.get("name", "")]
	var skill := DmPb.skill_name(String(c.get("skill", "")))
	var title_s := "%s · %s× %s" % [SLOT_NAMES[slot] if slot < SLOT_NAMES.size() else "Order", DmPb.num(qty), c.get("name", "")]
	var progress := "Filled" if done else "%s / %s in your bag" % [DmPb.num(mini(have, qty)), DmPb.num(qty)]

	var card := DmPb.card(parent, DmUi.BORDER, Color(0, 0, 0, 0), Vector2(10, 8))
	(card.get_meta("panel") as Control).modulate.a = 0.55 if done else 1.0
	var row := DmPb.hbox(10)
	card.add_child(row)
	row.add_child(DmPb.icon(rarity, 44.0, null, false, String(c.get("itemId", ""))))
	var txt := DmPb.vbox(3)
	row.add_child(txt)
	var hd := DmPb.hbox(10)
	var t := DmPb.text(title_s, 14, DmUi.BONE_100, "body_bold")
	t.name = "Title"
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.clip_text = true
	hd.add_child(t)
	hd.add_child(DmPb.text(DmUi.upper(skill), 11, DmUi.TEXT_FAINT, "body"))
	txt.add_child(hd)
	var bar := DmPbBar.new(5.0)
	bar.fill = rc
	bar.pct = 100.0 if done else float(pct)
	txt.add_child(bar)
	var rw := DmPb.hbox(0)
	rw.add_child(DmPb.text("%s · Pays " % progress, 12))
	rw.add_child(DmPb.text(reward, 12, DmUi.GOLD, "body_bold"))
	txt.add_child(rw)
	var btn := DmPb.button("✓" if done else "Deliver", false, done or not ready or busy)
	btn.custom_minimum_size = Vector2(84, 0)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(func() -> void: deliver_requested.emit(slot))
	row.add_child(btn)
	deliver_buttons[slot] = btn
	rows.append({"slot": slot, "title": title_s, "skill": skill, "pct": 100 if done else pct, "progress": progress, "reward": reward, "done": done, "ready": ready, "deliver_enabled": not btn.disabled})
