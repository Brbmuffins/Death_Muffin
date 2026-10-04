class_name DmChronicle
extends RefCounted
## Pure counter side of src/gameplay/chronicle.ts: lifetime/run counters, play time, the folded view, and the flush
## bookkeeping. The network call (net/ layer) is: b = flush_begin(); if b non-empty, POST it, then flush_done(b, ok).

var data: Dictionary = {"life": {}, "run": {}, "runNo": 1, "runStartedAt": null, "runs": []}
var sums: Dictionary = {}
var maxes: Dictionary = {}
var sending: Variant = null  # null or {sums, maxes}
var fraction: Dictionary = {"playSeconds": 0.0, "afkSeconds": 0.0}
var in_flight: bool = false
var loaded: bool = false
var disposed: bool = false
## Ascension ranks the net layer should post to /api/chronicle/ascend (after flushing), oldest first.
var pending_ascends: Array = []


func set_data(d: Dictionary) -> void:
	data = d
	loaded = true


func add(key: String, n: Variant = 1) -> void:
	var v: float = DmProgUtil.js_num(n)
	if not (v > 0.0):
		return
	sums[key] = DmProgUtil.ints(float(DmProgUtil.nn(sums.get(key), 0)) + v)


func max_(key: String, value: float) -> void:
	if value > float(DmProgUtil.nn(maxes.get(key), 0)):
		maxes[key] = value


## Play time (and AFK time) in whole seconds; fractions carry over.
func time(dt: float, afk: bool) -> void:
	fraction["playSeconds"] += dt
	if afk:
		fraction["afkSeconds"] += dt
	for k in ["playSeconds", "afkSeconds"]:
		var whole: float = floorf(fraction[k])
		if whole > 0.0:
			fraction[k] -= whole
			add(k, whole)


func _fold(base: Dictionary) -> Dictionary:
	var out: Dictionary = base.duplicate()
	var parts: Array = []
	if sending != null:
		parts.append(sending)
	parts.append({"sums": sums, "maxes": maxes})
	for part in parts:
		for k in part["sums"]:
			out[k] = float(DmProgUtil.nn(out.get(k), 0)) + float(part["sums"][k])
		for k in part["maxes"]:
			out[k] = maxf(float(DmProgUtil.nn(out.get(k), 0)), float(part["maxes"][k]))
	return out


## What the panel shows: the saved record plus anything not yet flushed.
func view() -> Dictionary:
	var v: Dictionary = data.duplicate()
	v["life"] = _fold(data["life"])
	v["run"] = _fold(data["run"])
	return v


func has_pending() -> bool:
	return sums.size() > 0 or maxes.size() > 0


## Start a flush: returns {sums, maxes} to send, or {} when nothing should go.
func flush_begin() -> Dictionary:
	if in_flight or (disposed and not has_pending()):
		return {}
	if not has_pending():
		return {}
	var batch: Dictionary = {"sums": sums, "maxes": maxes}
	sums = {}
	maxes = {}
	in_flight = true
	sending = batch
	return batch


func flush_done(batch: Dictionary, ok: bool) -> void:
	if ok:
		for k in batch["sums"]:
			data["life"][k] = float(DmProgUtil.nn(data["life"].get(k), 0)) + float(batch["sums"][k])
			data["run"][k] = float(DmProgUtil.nn(data["run"].get(k), 0)) + float(batch["sums"][k])
		for k in batch["maxes"]:
			data["life"][k] = maxf(float(DmProgUtil.nn(data["life"].get(k), 0)), float(batch["maxes"][k]))
			data["run"][k] = maxf(float(DmProgUtil.nn(data["run"].get(k), 0)), float(batch["maxes"][k]))
	else:
		for k in batch["sums"]:
			sums[k] = float(DmProgUtil.nn(sums.get(k), 0)) + float(batch["sums"][k])
		for k in batch["maxes"]:
			maxes[k] = maxf(float(DmProgUtil.nn(maxes.get(k), 0)), float(batch["maxes"][k]))
	sending = null
	in_flight = false


## The Altar burned the run: the net layer flushes, posts the rank, then reloads the record.
func ascend(rank: int) -> void:
	pending_ascends.append(rank)
