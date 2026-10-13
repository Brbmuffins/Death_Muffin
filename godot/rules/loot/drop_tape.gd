class_name DmDropTape
extends RefCounted
## One character's drop tape (server-decided drops, DECISIONS B20; backend drops.cjs): the server deals the next seed of every drop kind
## (kill, elite, boss, surge) ahead of time, so a kill rolls its drop at once (DmLoot.roll_event) and the pickup is a claim the server
## checks by rolling the same seed. `take(kind)` hands out the next event {n, seed} (or {} while nothing is dealt: the caller rolls the old
## way), and tops the tape up in the background when it runs low. Event driven: no per-frame work.

const LOW := {"kill": 48, "elite": 16, "boss": 3, "surge": 3}

var api: DmApi
var character_id := 0
var kinds := {}   ## kind -> {from, seeds, next}
var _fetching := false


func _init(api_: DmApi = null, character_id_: int = 0) -> void:
	api = api_
	character_id = character_id_


func ready_for(kind: String) -> bool:
	var k: Variant = kinds.get(kind)
	return k != null and int(k["next"]) - int(k["from"]) < (k["seeds"] as Array).size()


## Fetch (or top up) the tape. Safe to call again while a fetch runs.
func refill() -> void:
	if api == null or character_id <= 0 or _fetching:
		return
	_fetching = true
	var next := {}
	for kind in kinds:
		next[kind] = int(kinds[kind]["next"])
	var r: DmResult = await api.drops_tape(character_id, next)
	_fetching = false
	if not r.ok or not (r.data is Dictionary) or not (r.data.get("tape") is Dictionary):
		return
	var tape: Dictionary = r.data["tape"]
	for kind in tape:
		var t: Dictionary = tape[kind]
		var had: int = int(kinds[kind]["next"]) if kinds.has(kind) else 0
		kinds[kind] = {"from": int(t["from"]), "seeds": t["seeds"], "next": maxi(int(t["from"]), had)}


## The next event of `kind`: {n, seed}, or {} when the tape has nothing dealt for it.
func take(kind: String) -> Dictionary:
	if not ready_for(kind):
		refill()
		return {}
	var k: Dictionary = kinds[kind]
	var n := int(k["next"])
	k["next"] = n + 1
	if (k["seeds"] as Array).size() - (n + 1 - int(k["from"])) < int(LOW.get(kind, 4)):
		refill()
	return {"n": n, "seed": k["seeds"][n - int(k["from"])]}
