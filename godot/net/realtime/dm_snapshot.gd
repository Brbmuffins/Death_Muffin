class_name DmSnapshot
extends RefCounted
## Wire encoding of the host's WorldSnapshot rows (port of the encoding half of src/gameplay/sim/snapshot.ts) plus constants.
## Entities are plain Dictionaries with the same field names as the TS `Enemy` / `Thrall`. The sim track decides how its own
## nodes map onto them; `make_snapshot` takes already-collected lists so it has no dependency on the sim.

## Append-only (older snapshots must keep decoding).
const E_STATES: Array[String] = ["rising", "move", "windup", "recover", "channel", "dead", "burrow"]
const T_STATES: Array[String] = ["rising", "idle", "move", "attack", "dead"]
const AFFIX_ORDER: Array[String] = ["bellTolled", "hungering", "shrouded", "vengeful"]
const DIFFICULTY_ORDER: Array[String] = ["easy", "medium", "hard"]

# Enemy flag bits (row[8]); fracture << 4 (4 bits), withered << 8 (4 bits).
const F_ELITE := 1
const F_MOVING := 2
const F_SLOW := 4
const F_CHILL := 8
const F_BLEED := 4096
const F_SANCT := 8192
const F_HEX := 16384
const F_SILENCE := 32768
const F_INCENSE := 65536
const F_STUN := 131072
const F_ROOT := 262144
const F_DIVING := 524288

static func r2(n: float) -> float:
	return DmMath.js_round_f(n * 100.0) / 100.0

static func affix_code(affix: Variant) -> int:
	if affix == null or str(affix).is_empty():
		return 0
	return AFFIX_ORDER.find(str(affix)) + 1

static func affix_from(code: Variant) -> Variant:
	var c := int(code) if code != null else 0
	return AFFIX_ORDER[c - 1] if c > 0 and c <= AFFIX_ORDER.size() else null

static func _gt0(e: Dictionary, k: String) -> bool:
	return float(e.get(k, 0.0)) > 0.0

static func enemy_row(e: Dictionary) -> Array:
	var flags := 0
	if e.get("elite", false): flags |= F_ELITE
	if e.get("moving", false): flags |= F_MOVING
	if _gt0(e, "slowT") or _gt0(e, "wardSlowT"): flags |= F_SLOW
	if _gt0(e, "chillT"): flags |= F_CHILL
	if _gt0(e, "bleedT"): flags |= F_BLEED
	if _gt0(e, "sanctT"): flags |= F_SANCT
	if _gt0(e, "hexT"): flags |= F_HEX
	if _gt0(e, "silenceT"): flags |= F_SILENCE
	if _gt0(e, "incenseT"): flags |= F_INCENSE
	if _gt0(e, "stunT"): flags |= F_STUN
	if _gt0(e, "rootT"): flags |= F_ROOT
	if e.get("diving", false): flags |= F_DIVING
	flags |= (int(e.get("fracture", 0)) << 4) | (int(e.get("withered", 0)) << 8)
	return [int(e["id"]), e["def"], r2(e["x"]), r2(e["z"]), r2(e.get("facing", 0.0)), DmMath.js_round(float(e["hp"])), DmMath.js_round(float(e["maxHp"])),
		E_STATES.find(str(e.get("state", "move"))), flags, r2(e.get("stateT", 0.0)), r2(e.get("speed", 0.0)), r2(e.get("scale", 1.0)),
		e.get("area", ""), affix_code(e.get("affix")), int(e.get("level", 1))]

static func thrall_row(t: Dictionary) -> Array:
	var state := T_STATES.find(str(t.get("state", "idle"))) | (16 if t.get("moving", false) else 0)
	var fl := (1 if t.get("empowered", false) else 0) | (2 if _gt0(t, "rallyT") else 0) | (4 if _gt0(t, "cursedT") else 0) | (8 if t.get("champion", false) else 0)
	return [int(t["id"]), str(t.get("owner", "")), t["kind"], r2(t["x"]), r2(t["z"]), r2(t.get("facing", 0.0)), DmMath.js_round(float(t["hp"])),
		DmMath.js_round(float(t["maxHp"])), state, r2(t.get("stateT", 0.0)), fl, t.get("speed", 0.0), r2(t.get("damage", 0.0)), r2(t.get("attackInterval", 1.0))]

## sim: {time, waveTier, difficulty, ascension, vows, enemies: Array[Dict], thralls: Array[Dict], bossState: Dict, depleted: Array,
## zones: Array[Dict], corpses: Array[Dict]}. full = include corpses + zones (every Nth snapshot).
static func make_snapshot(sim: Dictionary, full: bool) -> Dictionary:
	var enemies: Array = []
	for e in sim.get("enemies", []):
		enemies.append(enemy_row(e))
	var thralls: Array = []
	for t in sim.get("thralls", []):
		thralls.append(thrall_row(t))
	var zpos: Array = []
	for z in sim.get("zones", []):
		if z.get("creep", false):
			zpos.append([int(z["id"]), r2(z["x"]), r2(z["z"])])
	var snap := {
		"t": sim.get("time", 0.0), "waveTier": sim.get("waveTier", 0), "difficulty": sim.get("difficulty", "medium"),
		"ascension": sim.get("ascension", 0), "enemies": enemies, "thralls": thralls,
		"boss": (sim.get("bossState", {}) as Dictionary).duplicate(), "depleted": sim.get("depleted", []),
	}
	if int(sim.get("ascension", 0)) != 0:
		snap["vows"] = sim.get("vows", {})
	if not zpos.is_empty():
		snap["zpos"] = zpos
	if full:
		snap["corpses"] = (sim.get("corpses", []) as Array).duplicate()
		snap["zones"] = (sim.get("zones", []) as Array).duplicate()
	return snap
