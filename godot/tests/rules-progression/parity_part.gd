extends "res://tests/common/dm_parity_part.gd"
## Client / server parity for godot/rules/progression: replays the fixtures the server's vitest writes (see dm_parity_part.gd).


func fixtures() -> Array:
	return [["rules-progression", "xp"], ["rules-progression", "necro"], ["rules-progression", "upgrades"], ["rules-progression", "kill_chain"]]


func call_fn(fn: String, a: Variant) -> Variant:
	match fn:
		"xpToNext": return DmProgression.xp_to_next(int(a[0]))
		"splitXp": return DmProgression.carry_xp(1, int(a[0]))
		"damageCost": return _nul(DmNecroRules.damage_cost(a[0]))
		"waveCost": return _nul(DmNecroRules.wave_cost(a[0]))
		"legionCost": return _nul(DmNecroRules.legion_cost(a[0]))
		"runHeat": return DmNecroRules.run_heat(a[0])
		"ashesOnAscend": return DmNecroRules.ashes_on_ascend(a[0])
		"unlockKills": return _nul(DmNecroRules.unlock_kills(a[0], a[1]))
		"normalise": return DmNecroRules.normalise(a[0])
		"applySave": return DmNecroRules.apply_save(a[0], a[1], a[2])
		"purchase": return DmNecroRules.purchase(a[0], float(a[1]), a[2])
		"summonPrelate": return DmNecroRules.summon_prelate(a[0], a[1])
		"summonAreaBoss": return DmNecroRules.summon_area_boss(a[0], a[1], a[2])
		"ascend": return DmNecroRules.ascend(a[0])
		"swearVows": return DmNecroRules.swear_vows(a[0], a[1])
		"unlockEntry": return DmNecroRules.unlock_entry(a[0], a[1])
		"buyBoon": return DmNecroRules.buy_boon(a[0], a[1])
		"importLocal": return DmNecroRules.import_local(a[0], a[1])
		"vowSteps": return DmAscension.vow_steps(a[0], a[1])
		"sanitizeVows": return DmAscension.sanitize_vows(a[0])
		"vowHeat": return DmAscension.vow_heat(a[0])
		"worldVows": return DmAscension.world_vows(a[0])
		"vowEffects": return DmAscension.vow_effects(a[0])
		"ascensionRewardMult": return DmAscension.ascension_reward_mult(a[0])
		"ascensionLevels": return DmAscension.ascension_levels(a[0])
		"legacyVows": return DmAscension.legacy_vows(a[0])
		"boonEffects": return DmAscension.boon_effects(a[0])
		"boonBlocked":
			var b := DmAscension.boon_blocked(a[0], a[1], a[2], a[3])
			return null if b == "" else b
		"boonCost": return _nul(DmAscension.boon_cost(a[0], a[1]))
		"isUnlocked": return DmAscension.is_unlocked(a[0], a[1])
		"unlockCost": return _nul(DmAscension.unlock_cost(a[0]))
		"ashesForRun": return DmAscension.ashes_for_run(a[0], a[1])
		"damageUpgradeCost": return DmUpgrades.damage_cost(int(a[0]))
		"legionUpgradeCost": return DmUpgrades.legion_cost(int(a[0]))
		"waveUpgradeCost": return DmUpgrades.wave_cost(int(a[0]))
		"damageBonusPct": return DmUpgrades.damage_bonus_pct(float(a[0]))
		"densityTier": return DmUpgrades.density_tier(float(a[0]))
		"waveModifiers": return DmUpgrades.wave_modifiers(float(a[0]))
		"milestones": return DmUpgrades.milestones(float(a[0]), float(a[1]))
		"milestoneActive": return DmUpgrades.milestone_active(a[0], float(a[1]))
		"tierFor": return DmKillChain.tier_for(int(a[0]))
		"chainRun":
			var kc := DmKillChain.new()
			var out: Array = []
			for st: Array in a[0]:
				var now := float(st[1])
				var o: Variant = null
				match String(st[0]):
					"hit": o = kc.hit(now)
					"tick": o = kc.tick(now)
					"frac": o = kc.frac(now)
					"reset": kc.reset()
				out.append({"out": o, "count": kc.count, "best": kc.best, "mult": kc.mult(), "active": kc.active(), "tier": kc.tier(), "frac": kc.frac(now)})
			return out
	return "UNKNOWN FN " + fn


## The ports return -1 for "none" where the TypeScript returns null.
func _nul(v: int) -> Variant:
	return null if v == -1 else v
