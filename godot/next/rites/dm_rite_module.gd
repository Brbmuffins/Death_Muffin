class_name DmRiteModule
extends RefCounted
## One rite of the DmRiteCaster. A module is a shared, stateless singleton (see DmRiteRegistry): keep per-caster state in `c.mem(id)`, never in fields.
## Subclass as `rite_<id>.gd`, set `id`, override what the rite needs, add ONE line to dm_rite_registry.gd. Recipe: godot/next/rites/README.md.
##
## The caster does the shared work (owner / finite aim / DmAbilities.cast_check: dead, locked, busy, cooldown, essence / cost / events / state);
## the module does only what is particular to its rite.

var id: String = ""
var steps: bool = false   ## true: `step` runs every host tick while the caster holds `mem(id)` state


## HOST. After the shared checks, before anything is spent. Return "" to go ahead or a refusal reason ("range", "no_target", "no_corpse", ...);
## a refusal costs nothing. May stash what it found in `intent` (e.g. the picked enemy / corpse id) for `resolve`. `intent` = {rite, aim, target_id, sender}.
## Set `intent["colossus_cast"] = true` when the cast earns the Colossus cooldown (DmAbilities.apply_cast_cost).
func validate(_c: DmRiteCaster, _intent: Dictionary) -> String:
	return ""


## HOST. The cost is paid and the cooldown runs. Do the rite: roll with DmAbilities, `c.after(ms, fn)` for flight time, damage through
## DmStatusSet.hit, take corpses only through DmCorpseField.consume, then `c.broadcast({t, rite, ...})`. Return "" when it happened, or a reason
## when it could not (the caster hands the cost and cooldown back and reports the reason to the owner).
func resolve(_c: DmRiteCaster, _intent: Dictionary) -> String:
	return ""


## EVERY PEER, exactly once per broadcast event (the host included, also solo): fx via `c.fx` (DmRiteFx), floating numbers via `c.hit_number`.
## Must not touch host state: a client only has the event dictionary.
func play(_c: DmRiteCaster, _ev: Dictionary) -> void:
	pass


## HOST, every physics tick while `steps` and the caster has `mem(id)` state (zones, armed seeds, tethers).
func step(_c: DmRiteCaster, _dt: float) -> void:
	pass
