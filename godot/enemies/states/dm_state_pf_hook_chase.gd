class_name DmStatePfHookChase
extends DmStateChase
## Drowned Sexton (def `hook`): the plain brute chase, but a player standing 3.4-8.5 m away with a clear line and the 6.5 s hook cooldown up gets
## the chain first: ATTACK with `hooking` set (the slam is the fallback). Thralls are never hooked (sim: `target.player != null`).

func engage(tg: Node3D, d: float, dt: float) -> int:
	var h := enemy as DmEnemyPfHazard
	if h.hook_ready(tg, d):
		h.hooking = true
		h.hook_cd = float(DmSimData.SEXTON_HOOK["cooldownS"])
		return Id.ATTACK
	return super(tg, d, dt)
