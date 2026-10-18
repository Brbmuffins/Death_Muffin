class_name DmTestBag
extends RefCounted
## Tests put items in a hero's bag the way a GM does (DECISIONS B25: only the server writes a bag): the item is placed like a pickup, the
## whole bag is saved to the (mock) backend and its answer is shown. Returns false when it does not fit or the backend refused it.


static func give(inv: DmInventory, drop: Dictionary) -> bool:
	await inv.commit()   # queued sips first: the answer below is the truth they would otherwise be applied to twice
	if not inv.add(drop):
		return false
	var rows: Array = []
	for s in inv.all():
		if int(s["slot_index"]) < DmLoot.bag_size():
			rows.append({"slot_index": int(s["slot_index"]), "item_id": s["item_id"], "quantity": int(s["quantity"]), "equipped": int(s.get("equipped", 0)),
				"instance_id": s.get("instance_id")})
	var r: DmResult = await inv.api.save_inventory(inv.character_id, rows, DmLoot.bag_size())
	if not r.ok:
		print("DmTestBag.give: ", r.error)
		return false
	inv.replace(r.data)
	return true
