class_name DmCounselCadence
extends RefCounted
## Covenant counsel cadence (src/ui/counselCadence.ts): pure rules for WHEN a queued tip may appear. All times are milliseconds on one clock.
## A queued tip is {id, kind, priority, queued_at, seq}. State is {now, last_closed_at, group_shown_at: {group: ms}, busy: Busy}.
## Busy is {combat, hurt, talking, banner, dead, panel: bool, area: String ("" = unknown), safe: bool} (counselCadence.ts `Busy`).
## kind/group/priority/place come from the data exported from the TS (DmCounselData), so the web's lists are never retyped.

const KIND_RANK := {"urgent": 0, "danger": 1, "asked": 2, "calm": 3}


static func not_busy() -> Dictionary:
	return {"combat": false, "hurt": false, "talking": false, "banner": false, "dead": false, "panel": false, "area": "", "safe": false}


static func busy_of(partial: Dictionary) -> Dictionary:
	var b := not_busy()
	for k in partial:
		b[k] = partial[k]
	return b


static func make_entry(id: String, now: float, seq: int, bump: bool = false) -> Dictionary:
	return {"id": id, "kind": DmCounselData.kind_of(id), "priority": DmCounselData.priority_of(id) + (100 if bump else 0), "queued_at": now, "seq": seq}


static func _group_gap(g: String) -> float:
	var gaps: Dictionary = DmCounselData.c("GROUP_GAPS")
	return float(gaps[g]) if gaps.has(g) else float(DmCounselData.c("GROUP_GAP_MS"))


## May this queued tip be drawn right now (assuming no card is up)?
static func can_show(t: Dictionary, s: Dictionary) -> bool:
	var b: Dictionary = s["busy"]
	var kind: String = t["kind"]
	if kind == "urgent":
		return not b["dead"]
	if b["dead"] or b["talking"]:
		return false
	if kind == "danger" and (b["safe"] or b["panel"]):
		return false
	var here := DmCounselData.here_of(t["id"])
	if not here.is_empty() and String(b["area"]) != "" and not here.has(b["area"]):
		return false
	if float(s["now"]) - float(s["last_closed_at"]) < float((DmCounselData.c("GAP_MS") as Dictionary)[kind]):
		return false
	if kind == "calm":
		if b["banner"] or b["panel"] or b["hurt"]:
			return false
		if b["combat"] and float(s["now"]) - float(t["queued_at"]) < float(DmCounselData.c("STARVED_MS")):
			return false
	if kind != "asked":
		var g := DmCounselData.group_of(t["id"])
		if g != "":
			var shown: float = float((s["group_shown_at"] as Dictionary).get(g, -INF))
			if float(s["now"]) - shown < _group_gap(g):
				return false
	return true


## The best tip that may be shown now: by kind (urgent, danger, asked, calm), then priority, then arrival order. {} = none.
static func pick_next(queue: Array, s: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	for t in queue:
		if not can_show(t, s):
			continue
		if best.is_empty():
			best = t
			continue
		var tr: int = KIND_RANK[t["kind"]]
		var br: int = KIND_RANK[best["kind"]]
		if tr < br or (t["kind"] == best["kind"] and (t["priority"] > best["priority"] or (t["priority"] == best["priority"] and t["seq"] < best["seq"]))):
			best = t
	return best


static func max_age(t: Dictionary) -> float:
	var lessons: Array = DmCounselData.c("LESSONS")
	if t["kind"] == "danger" and lessons.has(t["id"]):
		return float(DmCounselData.c("LESSON_AGE_MS"))
	return float((DmCounselData.c("MAX_AGE_MS") as Dictionary)[t["kind"]])


## Drop what has gone stale, and cap the calm backlog (oldest/lowest first).
static func prune(queue: Array, now: float) -> Array:
	var live: Array = []
	for t in queue:
		if now - float(t["queued_at"]) <= max_age(t):
			live.append(t)
	var calm: Array = []
	for t in live:
		if t["kind"] == "calm":
			calm.append(t)
	var cap: int = int(DmCounselData.c("MAX_CALM_QUEUED"))
	if calm.size() <= cap:
		return live
	var ordered := DmStableSort.sorted(calm, func(a: Dictionary, b: Dictionary) -> bool:
		if a["priority"] != b["priority"]:
			return a["priority"] < b["priority"]
		return float(a["queued_at"]) > float(b["queued_at"]))
	var drop: Dictionary = {}
	for i in calm.size() - cap:
		drop[ordered[i]["seq"]] = true
	var out: Array = []
	for t in live:
		if not drop.has(t["seq"]):
			out.append(t)
	return out


## Should a waiting tip take the place of the card on screen ({id, kind, shown_at})? Hurt? may take any other card, a fight lesson only a calm one.
static func should_preempt(card: Dictionary, waiting: Dictionary, s: Dictionary) -> bool:
	if waiting.is_empty():
		return false
	var s2: Dictionary = s.duplicate()
	s2["last_closed_at"] = -INF
	if not can_show(waiting, s2):
		return false
	if float(s["now"]) - float(card["shown_at"]) < float(DmCounselData.c("PREEMPT_AFTER_MS")):
		return false
	if waiting["kind"] == "urgent":
		return card["kind"] != "urgent"
	return waiting["kind"] == "danger" and card["kind"] == "calm"


## A calm card up a while steps aside for a fight or a conversation; any card but Hurt? steps aside for the death screen; a place card leaves with the hero.
static func should_yield(card: Dictionary, s: Dictionary) -> bool:
	if card["kind"] == "urgent":
		return false
	var b: Dictionary = s["busy"]
	var up: float = float(s["now"]) - float(card["shown_at"])
	if b["dead"]:
		return up >= 1000.0
	var here := DmCounselData.here_of(card["id"])
	if not here.is_empty() and String(b["area"]) != "" and not here.has(b["area"]):
		return up >= 2000.0
	if card["kind"] == "asked" or up < float(DmCounselData.c("YIELD_AFTER_MS")):
		return false
	if b["panel"] or b["talking"]:
		return true
	return card["kind"] == "calm" and b["combat"]


## How long a card stays up (ms): calm and asked cards 25-40 s; fight-time cards a shorter read.
static func show_ms(kind: String, words: int) -> int:
	if kind == "danger" or kind == "urgent":
		return maxi(14000, 4000 + words * 450)
	return mini(40000, maxi(25000, 5000 + words * 400))
