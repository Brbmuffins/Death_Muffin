extends "res://tests/common/dm_parity_part.gd"
## Client / server parity for client/rules/gathering: replays the fixtures the server's vitest writes (see dm_parity_part.gd).

const G := preload("res://rules/gathering/gathering_rules.gd")
const Sal := preload("res://rules/gathering/salvage_rules.gd")
const GS := preload("res://rules/gathering/gold_sink_rules.gd")
const Lab := preload("res://rules/gathering/labor_rules.gd")
const Gar := preload("res://rules/gathering/garden_rules.gd")
const Con := preload("res://rules/gathering/contract_rules.gd")
const A := preload("res://rules/loot/affix_rules.gd")
const Vault := preload("res://rules/inventory/vault_rules.gd")


func fixtures() -> Array:
	return [["rules_gathering", "gather"], ["rules_gathering", "salvage"], ["rules_gathering", "gold_sink"], ["rules_gathering", "labor"], ["rules_gathering", "garden"], ["rules_gathering", "contracts"], ["rules_gathering", "vault"], ["rules_gathering", "cosmetics"]]


## The ports answer "" where the TypeScript answers null.
func _s(v: String) -> Variant:
	return null if v == "" else v


func call_fn(fn: String, a: Variant) -> Variant:
	match fn:
		# --- gather
		"xpToNextLive": return G.xp_to_next_live(int(a[0]))
		"xpToNextCurve": return G.xp_to_next_curve(int(a[0]))
		"totalXpFor": return G.total_xp_for(int(a[0]), bool(a[1]))
		"addSkillXp": return G.add_skill_xp(a[0], a[1])
		"successChance": return G.success_chance(G.node_def(a[0]), int(a[1]), int(a[2]))
		"xpPerHour": return G.xp_per_hour(G.node_def(a[0]), int(a[1]), int(a[2]))
		"actionMs": return G.action_ms(G.node_def(a[0]))
		"rollGatherRun":
			var rng := DmDropStream.rand(a[3])
			var out: Array = []
			for i in 6:
				out.append(G.roll_gather(G.node_def(a[0]), int(a[1]), rng, int(a[2])))
			return out
		"rollBatch": return G.roll_batch(G.node_def(a[0]), a[1], int(a[2]), DmDropStream.rand(a[5]), int(a[3]), int(a[4]))
		"checkBudget": return G.check_budget(G.node_def(a[0]), a[1], a[2], int(a[3]), bool(a[4]))
		"toolItemId": return G.tool_item_id(a[0], int(a[1]))
		"toolTierFor": return G.tool_tier_for(a[0], a[1])
		"bestToolPerKind": return G.best_tool_per_kind(a[0])
		"toolKindOf": return _s(G.tool_kind_of(a[0]))
		"beltSlotOf": return G.belt_slot_of(a[0])
		"isBeltSlot": return G.is_belt_slot(int(a[0])) if float(a[0]) == floorf(float(a[0])) else false
		"beltSlotKind": return _s(G.belt_slot_kind(int(a[0])))
		"placeItems":
			var table: Dictionary = a[2]
			return G.place_items(a[0], a[1], func(id: String) -> int: return int(table.get(id, 1)))
		# --- salvage
		"salvageTypes": return {"gear": Sal.is_salvage_gear(a[0]), "rune": Sal.is_salvage_rune(a[0]), "any": Sal.is_salvageable(a[0])}
		"salvageItemIds":
			var ids: Array = Sal.item_ids()
			ids.sort()
			return ids
		"yieldsPlanks": return Sal.yields_planks(a[0])
		"instanceYieldBonus": return Sal.instance_yield_bonus(a[0])
		"salvagePreview": return Sal.preview(a[0])
		"salvageYield": return Sal.yield_for(a[0], a[1], DmDropStream.rand(a[2]))
		"mergeGrants": return Sal.merge_grants(a[0])
		# --- gold sink
		"reforgeCost": return GS.reforge_cost(float(a[0]), a[1], int(a[2]), a[3])
		"reforgeProblem":
			var idx := int(a[1]) if float(a[1]) == floorf(float(a[1])) else -1
			return _s(GS.reforge_problem(a[0], idx, func(id: String, ilvl: Variant) -> Variant: return A.affix_range(id, ilvl)))
		"reforgeValue": return GS.reforge_value(a[0], int(a[1]), DmDropStream.rand(a[2]), func(id: String, ilvl: Variant) -> Variant: return A.affix_range(id, ilvl))
		"canEmpower": return GS.can_empower(a[0])
		"empowerGold": return GS.empower_gold(int(a[0]))
		"empoweredLevel": return GS.empowered_level(int(a[0]))
		# --- labor
		"laborSlots": return Lab.labor_slots(int(a[0]))
		"totalGatherLevel": return Lab.total_gather_level(a[0])
		"postsFor":
			var posts: Array = []
			for n in Lab.posts_for(a[0]):
				posts.append(n["id"])
			return posts
		"assignBlocker": return _s(Lab.assign_blocker(a[0], a[1]))
		"laborActions": return Lab.labor_actions(G.node_def(a[0]), float(a[1]))
		"estimate": return Lab.estimate(G.node_def(a[0]), int(a[1]), float(a[2]))
		"hashSeed": return Lab.hash_seed(a[0])
		"rollLabor":
			var r: Object = Lab.claim_rng(int(a[3]))
			return Lab.roll_labor(G.node_def(a[0]), a[1], float(a[2]), r.as_callable())
		# --- garden
		"stateOf": return Gar.state_of(a[0], int(a[1]))
		"growMs": return Gar.grow_ms(Gar.seed_def(a[0]), bool(a[1]))
		"rollHarvest": return Gar.roll_harvest(Gar.seed_def(a[0]), DmDropStream.rand(a[1]))
		"plantBlocker": return _s(Gar.plant_blocker(Gar.plot_def(a[0]), a[1], int(a[2]), a[3], int(a[4])))
		"remainingText": return Gar.remaining_text(a[0])
		# --- contracts
		"candidatesFor": return Con.candidates_for(a[0])
		"generateBoard": return Con.generate_board(int(a[0]), a[1], a[2])
		"bonusFor": return Con.bonus_for(a[0])
		"orderInfo":
			var oi: Dictionary = Con.order_info(a[0])
			return null if oi.is_empty() else oi
		"dayKey": return Con.day_key(int(a[0]))
		"nextResetMs": return Con.next_reset_ms(int(a[0]))
		"streakOf": return Con.streak_of(a[0], a[1])
		# --- cosmetics (the offline backend's port)
		"totalLevel": return DmOfflineCosmetics.total_level(a[0])
		"unlockedCapes":
			var ids: Array = []
			for c in DmOfflineCosmetics.capes():
				if DmOfflineCosmetics.cape_progress(c, a[0])["unlocked"]:
					ids.append(c["id"])
			return ids
		"capeProgress": return DmOfflineCosmetics.cape_progress(DmOfflineCosmetics.cape_def(a[0]), a[1])
		"capeUnlocked": return DmOfflineCosmetics.cape_unlocked(a[0], a[1])
		# --- vault (the last argument of each is the item table the case ran against)
		"depositStack": return Vault.deposit_stack(a[0], a[1], int(a[2]), a[3], _info(a[4]))
		"withdrawStack": return Vault.withdraw_stack(a[0], a[1], int(a[2]), a[3], _info(a[4]))
		"moveToSlot": return Vault.move_to_slot(a[0], a[1], a[2], int(a[3]), a[4], int(a[5]), a[6], _info(a[7]))
		"depositMany": return Vault.deposit_many(a[0], a[1], a[2], a[3], _info(a[4]))
		"sortVault": return Vault.sort_vault(a[0], _info(a[1]))
		"sortBag":
			var locked: Array = []
			for l in a[1]:
				locked.append(int(l))  # JSON numbers are floats; Array.has(int) does not match a float
			var sb := Vault.sort_bag(a[0], _info(a[2]), locked)
			var moves := {}
			for k in sb["moves"]:
				moves[str(k)] = sb["moves"][k]  # JSON object keys are strings
			return {"bag": sb["bag"], "moves": moves}
		"addGrants": return Vault.add_grants(a[0], a[1], _info(a[2]))
		"useItems": return Vault.use_items(a[0], a[1], _info(a[2]))
	return "UNKNOWN FN " + fn


func _info(table: Dictionary) -> Callable:
	return func(id: String) -> Dictionary: return table.get(id, {"maxStack": 1, "itemType": "material", "rarity": "common"})
