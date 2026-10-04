class_name DmMilestones
extends RefCounted
## Port of src/gameplay/milestones.ts. The list is generated from the TS (content.json "milestones").


static func list() -> Array:
	return DmProgContent.get_data()["milestones"]


static func reached(m: Dictionary, c: Dictionary) -> bool:
	match m["kind"]:
		"totalKills":
			return float(c.get("totalKills", 0)) >= float(m["n"])
		"bestChain":
			return float(c.get("bestChain", 0)) >= float(m["n"])
		"areaKills":
			var ak: Dictionary = DmProgUtil.dict_or_empty(c.get("areaKills"))
			return float(DmProgUtil.nn(ak.get(m["area"]), 0)) >= float(m["n"])
	return false


## Milestones newly reached (not in `claimed`), in list order. `c` = {totalKills, areaKills, bestChain}.
static func newly_reached(c: Dictionary, claimed: Array) -> Array:
	var out: Array = []
	for m in list():
		if not claimed.has(m["id"]) and reached(m, c):
			out.append(m)
	return out
