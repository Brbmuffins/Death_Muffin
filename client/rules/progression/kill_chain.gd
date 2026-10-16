class_name DmKillChain
extends RefCounted
## Port of server/rules/gameplay/killChain.ts: your kills chain while each lands within windowMs of the last.
## `now` is milliseconds from any monotonic clock.

var count: int = 0
var best: int = 0
var until: float = 0.0


static func tier_for(n: int) -> Variant:
	var t: Variant = null
	for tier in DmProgContent.get_data()["chain"]["tiers"]:
		if n >= int(tier["at"]):
			t = tier
	return t


func tier() -> Variant:
	return tier_for(count)


## XP and gold multiplier for the NEXT reward.
func mult() -> float:
	var t: Variant = tier()
	return 1.0 + (float(t["bonus"]) if t != null else 0.0)


func active() -> bool:
	return count > 0


func frac(now: float) -> float:
	if count == 0:
		return 0.0
	var w: float = float(DmProgContent.get_data()["chain"]["windowMs"])
	return maxf(0.0, minf(1.0, (until - now) / w))


## Register a kill; returns the tier reached if this kill crossed into a new one, else null.
func hit(now: float) -> Variant:
	var w: float = float(DmProgContent.get_data()["chain"]["windowMs"])
	if count > 0 and now > until:
		count = 0
	var before: Variant = tier()
	count += 1
	until = now + w
	best = maxi(best, count)
	var after: Variant = tier()
	if after != null and (before == null or after["at"] != before["at"]):
		return after
	return null


## Call every frame. Returns the length of a chain that just broke (0 when nothing did).
func tick(now: float) -> int:
	if count > 0 and now > until:
		var broke: int = count
		count = 0
		return broke
	return 0


func reset() -> void:
	count = 0
