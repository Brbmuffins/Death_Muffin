class_name DmFloatBudget
extends RefCounted
## Caps the combat numbers alive on screen so a legion plus a poison cloud cannot bury the fight in digits (the old game has no cap; each number is a Label with
## three tweens). Per class, a number counts for its lifetime; once the class is full the next one is dropped, except that a crit may displace nothing but is
## only refused by the hard total. Hurt / gold / shard / xp / heal / info / skill floats are never limited (they are about the player and rare).
## One call per number: a few float compares on arrays of at most ~14 entries, no allocation after warm-up.

const LIFE_MS := {"hit": 850.0, "crit": 1100.0, "dot": 850.0, "thrall": 850.0}
const CLASS_CAP := {"hit": 14, "dot": 5, "thrall": 6}   ## hero hits and crits share "hit"
const TOTAL_CAP := 22

var _live := {"hit": [], "dot": [], "thrall": []}
var dropped := 0


## True when the number may be shown (and is then counted); false = drop it.
func allow(kind: String, now_ms: float) -> bool:
	if not LIFE_MS.has(kind):
		return true
	var cls := "hit" if kind == "crit" else kind
	var total := 0
	for k in _live:
		var a: Array = _live[k]
		while not a.is_empty() and a[0] <= now_ms:
			a.pop_front()
		total += a.size()
	var mine: Array = _live[cls]
	# a crit is the number worth reading: it gets the room the total cap leaves, a little past its class's
	var cap: int = int(CLASS_CAP[cls]) + (4 if kind == "crit" else 0)
	if mine.size() >= cap or total >= TOTAL_CAP + (4 if kind == "crit" else 0):
		dropped += 1
		return false
	mine.append(now_ms + float(LIFE_MS[kind]))
	return true
