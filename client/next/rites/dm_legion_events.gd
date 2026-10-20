class_name DmLegionEvents
extends RefCounted
## What two of the legion's moments do in the game. The combat core tells them as events (`DmCoreHost.thrall_bell_heal`, `thrall_plague_pool`; native/README.md "Thralls");
## this listens, on the host only (a guest's core never tells them: the host's heal reaches a guest's hero through its vitals, the pool through the caster's event).
##   - The Mourning Bell (a Mourner's off-hand): each blow of a wraith raised with it mends every living hero within the bell's range of the wraith, the owner and the party,
##     for the event's share of THEIR maximum health (the old game's bellHeal). The thralls are not mended.
##   - A plague bearer that falls other than crumbling (the core has burst it for damage) leaves a rot pool where it stood: the owner's friendly rot cloud, by the rules of the
##     toxic Corpse Explosion's (`rite_miasma.gd` `plague_pool`: it slows and withers what stands in it, the owner is credited, every peer draws it).
## Held by DmNextGame (`legion_events`); its connections last as long as it does.

var _game: Node                  ## DmNextGame
var _bell_range := 0.0           ## the Mourning Bell's reach (necro_weapons tuning mourning_bell.allyHealRange)


func _init(game: Node) -> void:
	_game = game
	_bell_range = float(DmCombatData.load_json("necro_weapons")["tuning"]["mourning_bell"]["allyHealRange"])
	var host: DmCoreHost = game.core_host
	host.thrall_bell_heal.connect(_on_bell_heal)
	host.thrall_plague_pool.connect(_on_plague_pool)


## A wraith with a bell struck at (x, z): `fraction` of their maximum health to every living hero within the bell's range of it.
func _on_bell_heal(_thrall: int, x: float, z: float, fraction: float) -> void:
	for n in _game.session.get_bodies():
		var b := n as DmHeroBody
		if b != null and b.alive and Vector2(b.position.x - x, b.position.z - z).length() <= _bell_range:
			b.heal(b.max_hp * fraction)


## Plague bearer `thrall` fell at (x, z): its owner's caster keeps the pool (`radius` wide, `seconds` long, `dps` a second of Withered). Nobody's when the owner has left.
func _on_plague_pool(thrall: int, x: float, z: float, radius: float, seconds: float, dps: float) -> void:
	var host: DmCoreHost = _game.core_host
	var owner_body := host.hero_for(int(host.core.thrall_info(thrall).get("owner", 0))) as DmHeroBody
	var caster := owner_body.get_node_or_null("Rites") as DmRiteCaster if owner_body != null else null
	if caster != null:
		(DmRiteRegistry.module("miasma") as Object).call("plague_pool", caster, x, z, radius, dps, seconds)
