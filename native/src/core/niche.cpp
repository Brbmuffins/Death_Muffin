// The Skull Niche (the old game's dm_enemy_niche.gd, the Bone Abbess's shrines): a "support" body marked `inert` in enemies.json. It only stands: the Abbess's brain
// heals through it and fires her lances from it, so it never targets, walks, strikes, staggers or stuns. Its state machine has three states, RISING (the spawn rise, 1.1 s),
// IDLE and DEAD; a hit changes none of them (DmEnemyStateMachine.change ignores a state the kind did not add). Its health is the boss's to set (World::set_enemy_hp). It is not
// in the crowd's spacing (its body is no avoidance agent, and enemies' masks do not include its layer) and is never moved (it has no velocity, so move_and_slide never runs on it).
// The crowd hides its body at once when it falls (CrowdView::die: DmEnemyNiche.on_death), it lays no corpse (def corpse "none") and pays nothing (the rewards skip `inert` defs).
// Differences from the old game are noted in native/README.md.
#include "world.h"

namespace dm {

// DmStateRising until RISE_TIME, then IDLE for good (DmEnemyNiche._physics_process returns while it stands). The status set keeps running (it was a node of its own in the old game).
int32_t World::tick_inert(int32_t p_slot) {
	const Enemy &e = enemies[p_slot];
	return e.state == RISING && e.state_t >= RISE_S ? IDLE : -1;
}

} // namespace dm
