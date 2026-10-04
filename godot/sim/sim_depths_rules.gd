class_name DmSimDepthsRules
extends RefCounted
## The Catacomb Depths formulas of src/content/depths.ts that the sim needs (the data lives in godot/data/content/depths.json).

## [{from, add: [{id, weight}]}] (src/content/depths.ts BANDS).
const BANDS: Array = [
	{"from": 1, "add": [["rat", 30], ["robber", 22], ["ghoul", 14], ["bat", 12], ["sac", 10], ["hound", 8]]},
	{"from": 5, "add": [["penitent", 12], ["deacon", 8], ["acolyte", 6], ["wraith", 6], ["moth", 6]]},
	{"from": 10, "add": [["templar", 8], ["censer", 6], ["gargoyle", 8], ["seraph", 6], ["plague_doctor", 8], ["flagellant", 8]]},
	{"from": 15, "add": [["golem", 5], ["cinder_husk", 8], ["cinderhound", 8], ["pyre_priest", 6], ["slag_brute", 5], ["bog_hag", 7], ["drowned_sexton", 4]]},
]


static func floor_kills(depth: float) -> float:
	return minf(30.0, 9.0 + maxf(1.0, floorf(depth)))


static func extra_affixes(depth: float) -> int:
	var D: Dictionary = DmSimData.DEPTHS
	return mini(int(D["maxExtraAffixes"]), int(floorf(maxf(0.0, depth) / float(D["extraAffixEvery"]))))


static func depth_elite_bonus(depth: float) -> float:
	return minf(0.14, 0.005 * maxf(0.0, depth))


static func depth_wave_size(depth: float) -> float:
	return minf(9.0, 5.0 + floorf(depth / 6.0))


static func depth_wave_gap_s(depth: float) -> float:
	return maxf(2.4, 4.4 - 0.05 * depth)


## Which of the pool's affixes a new elite on `depth` carries beyond its first (distinct, never the one it has). `rand` returns [0, 1).
static func pick_extra_affixes(depth: float, primary: String, rand: Callable) -> Array:
	var pool: Array = []
	for a in DmSimData.AFFIX_ORDER:
		if a != primary:
			pool.append(a)
	var out: Array = []
	var n := mini(extra_affixes(depth), pool.size())
	while out.size() < n and not pool.is_empty():
		var i := int(floorf(float(rand.call()) * pool.size()))
		out.append(pool[i])
		pool.remove_at(i)
	return out


## The weighted roster of a floor: [{id, weight}] (Map insertion order, like the TS).
static func depth_roster(depth: float) -> Array:
	var out: Dictionary = {}
	for b: Dictionary in BANDS:
		if depth < float(b["from"]):
			continue
		for e: Array in b["add"]:
			out[e[0]] = float(e[1])
	var bands := 0
	for b: Dictionary in BANDS:
		if depth >= float(b["from"]):
			bands += 1
	var fade := pow(0.6, maxf(0.0, float(bands - 1)))
	for e: Array in BANDS[0]["add"]:
		out[e[0]] = maxf(3.0, DmMath.js_round_f(float(e[1]) * fade))
	var res: Array = []
	for k in out:
		res.append({"id": k, "weight": out[k]})
	return res
