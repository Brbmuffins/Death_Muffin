class_name DmRiteHotbar
extends RefCounted
## The slice's hotbar mapping, in ONE place for the HUD track to take over. DmNextInput emits `hotbar(slot, aim, enemy_id)`; this turns a slot into
## a rite and asks the local body's caster to cast it (the host validates). Slot 0 = LMB (the kit's default primary), 1-4 = the kit's
## `defaultLoadout` in order, 5 = RMB (the kit's `rmb`), 6 = R (the kit's signature for the body's discipline). The kit is `DmContent.kit(family)`; a rite with no module yet is refused locally as
## `unavailable` (cast_rejected), nothing is sent. The HUD's own hotbar UI should call `DmRiteHotbar.cast(game, slot, aim, enemy_id)` or its
## own request_cast with its sockets.

static func rite_for_slot(slot: int, family: String = "necromancer", discipline_id: String = "") -> String:
	var kit: Dictionary = DmContent.kit(family)
	if slot == 6:   # R: the discipline's signature (the current game's sixth hotbar slot)
		return String(kit.get("signatures", {}).get(discipline_id, ""))
	if slot == 0:
		return String(kit.get("defaultPrimary", ""))
	if slot == 5:
		return String(kit.get("rmb", ""))
	var lo: Array = kit.get("defaultLoadout", [])
	return String(lo[slot - 1]) if slot >= 1 and slot <= lo.size() else ""


## Connect the game's input seam. `game` is the DmNextGame (`input`, `local_body()`).
static func wire(game: Node) -> void:
	game.input.hotbar.connect(func(slot: int, aim: Vector3, enemy_id: int) -> void: cast(game, slot, aim, enemy_id))


static func cast(game: Node, slot: int, aim: Vector3, enemy_id: int) -> void:
	var body: Node = game.local_body()
	var caster: DmRiteCaster = body.get_node_or_null("Rites") as DmRiteCaster if body != null else null
	if caster == null:
		return
	var rite := rite_for_slot(slot, String(body.get("family")) if body.get("family") != null else "necromancer", String(body.get("discipline_id")))
	if rite != "":
		caster.request_cast(rite, aim, enemy_id if enemy_id != 0 else -1)
