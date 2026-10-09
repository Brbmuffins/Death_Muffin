class_name DmAccountPrefs
extends RefCounted
## Account preferences helpers (port of archive/legacy-web:src/net/accountPrefs.ts). The server keys must match DEFS in backend/prefs.cjs.
## reconcileLootRules / syncLootRulesWithAccount depend on the loot-filter rules (rules track) and are not ported here.

const PREF_ONLY_CRAFTABLE := "only_craftable"

static func loot_pref_key(tier: String) -> String:
	return "loot_" + tier

## The account's saved preferences, or null when they cannot be had (not signed in, server down): keep the local copy.
static func fetch(api: DmApi) -> Variant:
	var r := await api.get_account_prefs()
	return r.data if r.ok else null

## Save one preference. Never fails loudly: a failed save leaves the local copy, and the next change tries again.
static func save_one(api: DmApi, key: String, value: Variant) -> void:
	await api.set_account_prefs({key: value})

## The account wins when it has a boolean; when it has none and the local setting is on, push that up. -> {value, pushUp}
static func reconcile_bool(local: bool, remote: Variant, key: String) -> Dictionary:
	if not (remote is Dictionary):
		return {"value": local, "pushUp": false}
	var saved: Variant = remote.get(key)
	if saved is bool:
		return {"value": saved, "pushUp": false}
	return {"value": local, "pushUp": local}
