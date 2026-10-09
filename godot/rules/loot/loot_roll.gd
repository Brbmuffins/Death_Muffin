class_name DmLootRoll
extends RefCounted
## Client side of server item rolls (port of archive/legacy-web:src/gameplay/lootRoll.ts, the pure half).
##
## WHAT THE SERVER DECIDES vs THE CLIENT
## - Server (POST /api/loot/roll-gear, server/death-muffin loot.cjs using the shared affixRules): the item level (item_level_for of
##   the dropper's level, clamped to the character's reach by clamp_drop_level), the affix count/ids/values (roll_instance), and
##   the instance id it will later accept in a bag save. The server rejects any instance it did not mint for the account.
## - Client: decides WHAT drops (DmLoot.roll_* with the item tables) and which drops are gear (DmAffixes.can_roll). It sends
##   {item_id, level, source} per gear drop (12 per request), attaches the answer as drop.instance = {id, ilvl, affixes}, and
##   the bag save names the roll by instance_id only. If the server cannot roll (offline, too many unclaimed relics, error) the drop
##   stays plain base gear: nothing is invented client-side. (DmAffixRules.roll_instance exists for dev-offline mode/tests only.)
## This class holds the batching + answer-matching; the net track performs the HTTP call between the two steps:
##   var batches := DmLootRoll.batches(drops)
##   for b in batches: var answer = await net.roll_gear(char_id, DmLootRoll.request(b, level, source)); DmLootRoll.apply(b, answer)

const BATCH := 12  # the server's MAX_DROPS

## Gear drops that still need a roll, split into request-sized batches (Arrays of the SAME Dictionary objects, so apply() mutates the drops).
static func batches(drops: Array) -> Array:
	var gear: Array = []
	for d in drops:
		if DmAffixes.can_roll(d["item_id"]) and d.get("instance") == null:
			gear.append(d)
	var out: Array = []
	var i := 0
	while i < gear.size():
		out.append(gear.slice(i, i + BATCH))
		i += BATCH
	return out

## [{item_id, level, source}] for one batch.
static func request(batch: Array, level: float, source: String) -> Array:
	var out: Array = []
	for d in batch:
		out.append({"item_id": d["item_id"], "level": level, "source": source})
	return out

## Attach the server's answer ([{item_id, instance_id, ilvl, affixes}], possibly short or with nulls) to the batch's drops in place.
static func apply(batch: Array, answer: Array) -> void:
	for n in batch.size():
		var a: Variant = answer[n] if n < answer.size() else null
		if a is Dictionary and a.get("item_id") == batch[n]["item_id"] and a.get("instance_id") != null and not DmLoot.is_integer_zero(a.get("instance_id")):
			batch[n]["instance"] = {"id": a["instance_id"], "ilvl": a["ilvl"], "affixes": a["affixes"]}
