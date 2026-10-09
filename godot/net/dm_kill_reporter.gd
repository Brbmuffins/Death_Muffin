class_name DmKillReporter
extends RefCounted
## Server authority step 2 (port of archive/legacy-web:src/net/killReporter.ts, docs/SERVER-AUTHORITY.md): count kills as they happen, seal them into
## numbered batches, and keep each batch until the server confirms it, so a retry after a lost reply is recognised as a repeat.
## A batch rides along with the next save-progress (`killReports`) or is posted alone with DmApi.report_kills.
##
## Kill input: {area, def, level, elite, tier, diff, rank, xpMult, goldMult, shardMult}. Report: {seq, groups, bosses, floors}.

const MAX_UNACKED := 4

var _now: Callable
var _groups: Dictionary = {}
var _bosses: Dictionary = {}
var _floors: Array = []
## Sealed batches the server has not confirmed yet, oldest first.
var _sealed: Array = []
var _last_seq: int = 0

func _init(now_ms: Callable = Callable()) -> void:
	_now = now_ms if now_ms.is_valid() else Callable(DmKillReporter, "_wall_ms")

static func _wall_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)

static func _round2(n: float) -> float:
	return floorf(n * 100.0 + 0.5) / 100.0

## A kill the hero is paid for. Multipliers are rounded to two places so a chain ticking up does not make a group per kill.
func kill(input: Dictionary) -> void:
	var k := input.duplicate()
	k["xpMult"] = _round2(float(input["xpMult"]))
	k["goldMult"] = _round2(float(input["goldMult"]))
	k["shardMult"] = _round2(float(input["shardMult"]))
	var key := "%s|%s|%s|%d|%s|%s|%s|%s|%s|%s" % [k["area"], k["def"], k["level"], 1 if k["elite"] else 0, k["tier"], k["diff"], k["rank"], k["xpMult"], k["goldMult"], k["shardMult"]]
	if _groups.has(key):
		_groups[key]["n"] += 1
	else:
		k["n"] = 1
		_groups[key] = k

## input: {boss, tier, diff, first, summon?}
func boss(input: Dictionary) -> void:
	var key := "%s|%s|%s|%d|%s" % [input["boss"], input["tier"], input["diff"], 1 if input.get("first", false) else 0, input.get("summon", 0)]
	if _bosses.has(key):
		_bosses[key]["n"] += 1
	else:
		var b := input.duplicate()
		b["n"] = 1
		_bosses[key] = b

## f: {depth, mult, ...}
func floor_clear(f: Dictionary) -> void:
	var c := f.duplicate()
	c["mult"] = _round2(float(f["mult"]))
	_floors.append(c)

## Anything not yet sealed or confirmed.
func has_pending() -> bool:
	return _groups.size() > 0 or _bosses.size() > 0 or _floors.size() > 0 or _sealed.size() > 0

## True when the open batch is big enough that it should go now (the server caps a report's groups).
func crowded() -> bool:
	return _groups.size() >= 120

## Seal the open batch (if it holds anything) and return every unconfirmed batch, oldest first.
func batches() -> Array:
	if _groups.size() > 0 or _bosses.size() > 0 or _floors.size() > 0:
		var seq := maxi(_last_seq + 1, int(_now.call()))
		_last_seq = seq
		_sealed.append({"seq": seq, "groups": _groups.values(), "bosses": _bosses.values(), "floors": _floors})
		_groups = {}
		_bosses = {}
		_floors = []
		# A server that never confirms must not make the client hold an unbounded pile: the oldest batches are dropped first.
		while _sealed.size() > MAX_UNACKED:
			_sealed.pop_front()
	return _sealed.duplicate()

## The server has seen every batch up to and including `seq`.
func ack(seq: int) -> void:
	_sealed = _sealed.filter(func(b): return int(b["seq"]) > seq)

## The server cannot take reports at all (an older server without the route): stop holding them.
func discard() -> void:
	_groups = {}
	_bosses = {}
	_floors = []
	_sealed = []
