// The Cinder Pyre's and the Mourning Fen's eight kinds, as the old game's enemy kinds made them (dm_enemy_pf_melee, dm_enemy_pf_flanker, dm_enemy_pf_caster, dm_enemy_pf_hazard,
// dm_pf_util) and the states dm_state_pf_hook_chase and dm_state_pf_lure_kite. The walk, the swing and the fall are in world.cpp beside the others; this file holds what is
// theirs alone:
//   - burning ground (DmPfUtil.ember_pool): the Cinder Husk's last embers, the Pyre Priest's coal and the Slag Brute's slam leave a zone of kind ember;
//   - the Pyre Priest's coal, the Bog Hag's hex and the Fen Wisp's pulse (DmEnemyPfCaster.strike): a ring at the aim fixed when the wind-up began;
//   - the Bog Hag's aim (hex_aim): the thickest knot of thralls within reach;
//   - the Fen Wisp's retreat toward the open water (DmStatePfLureKite);
//   - the Drowned Sexton's chain (DmStatePfHookChase, DmEnemyPfHazard.hook_ready, _hook_strike, DmPfUtil.pull).
// What an enemy does to a hero besides damage (a chill, a root, a drag) is an event for GDScript (EV_TARGET_EFFECT), as a blow is. Differences from the old game are noted in native/README.md.
#include "world.h"

#include <algorithm>

namespace dm {

// DmPfUtil.ember_pool: a burning pool of kind ember at (x, z), owned by the body (it hurts as "burn", once a second like every zone). The host's is damaging; a guest draws the
// host's zone from the reliable event.
void World::ember_pool(Enemy &e, float p_x, float p_z, double p_r, double p_seconds, double p_dps) {
	Zone z;
	z.id = next_id++;
	z.kind = ZONE_EMBER;
	z.source = e.id;
	z.hit_kind = HK_BURN;
	z.x = p_x;
	z.z = p_z;
	z.radius = p_r;
	z.lifetime = p_seconds;
	z.dps = p_dps;
	zones.push_back(z);
	events.push(EV_ZONE, z.id, { z.kind, z.source }, { z.x, z.z, float(z.radius), float(z.lifetime) });
}

void World::target_effect(Enemy &e, int32_t p_target, int32_t p_effect, double p_seconds, float p_x, float p_z) {
	events.push(EV_TARGET_EFFECT, e.id, { p_target, p_effect }, { float(p_seconds), p_x, p_z });
}

// DmEnemyPfCaster.strike for the three late casters: what this blow is worth is the body's damage x the status set's damage dealt (Bone Hex softens it: DmPfUtil.blow).
// - ember (Pyre Priest): everything within EMBER_BOLT.radius of the aim takes the blow as "ember", and the ground burns there;
// - hex (Bog Hag): every body within HAG_HEX.radius takes blowMult x the blow as "curse"; a thrall is cursed for durationS (it hits softer), a hero is chilled;
// - pulse (Fen Wisp): every body within WISP_PULSE.radius takes the blow as "dust"; a hero is chilled.
void World::pf_strike(Enemy &e) {
	const PfTuning &P = tun.pf;
	const double dmg = e.damage * e.st.dealt;
	switch (defs[e.def].blow) {
		case BLOW_EMBER:
			each_target([&](const Tgt &x) {
				if (flat_dist(e.aim_x, e.aim_z, x.x, x.z) <= P.ember_r) {
					hit_target(e, x.id, dmg, HK_EMBER);
				}
			});
			ember_pool(e, e.aim_x, e.aim_z, P.ember_r, P.ember_pool_s, dmg * P.ember_pool_dps);
			break;
		case BLOW_HEX:
			each_target([&](const Tgt &x) {
				if (flat_dist(e.aim_x, e.aim_z, x.x, x.z) > P.hex_r) {
					return;
				}
				hit_target(e, x.id, dmg * P.hex_blow, HK_CURSE);
				const auto it = thrall_slot.find(x.id);
				if (it != thrall_slot.end()) {
					Thrall &t = thralls[size_t(it->second)];
					if (t.alive_target()) {  // `if target_valid(tg)`: the blow may have killed it
						t.cursed_t = P.hex_s;
					}
				} else {
					target_effect(e, x.id, TE_CHILL, P.hex_chill_s, 0.0f, 0.0f);
				}
			});
			break;
		case BLOW_PULSE:
			each_target([&](const Tgt &x) {
				if (flat_dist(e.aim_x, e.aim_z, x.x, x.z) > P.pulse_r) {
					return;
				}
				hit_target(e, x.id, dmg, HK_DUST);
				if (thrall_slot.find(x.id) == thrall_slot.end()) {
					target_effect(e, x.id, TE_CHILL, P.pulse_chill_s, 0.0f, 0.0f);
				}
			});
			break;
		default:
			break;
	}
}

// DmEnemyPfCaster.hex_aim: the thrall in the thickest knot (most living thralls, itself included, within HAG_HEX.radius of it) among the ones within attackRange of the hag, the
// first in raise order on a tie; the target itself when there are none; else a metre ahead of the body.
void World::hex_aim(Enemy &e) {
	const double r2 = tun.pf.hex_r * tun.pf.hex_r;
	int32_t best = -1, best_n = 0;
	for (size_t i = 0; i < thralls.size(); i++) {
		const Thrall &t = thralls[i];
		if (!t.alive_target() || flat_dist(e.x, e.z, t.x, t.z) > e.attack_range) {
			continue;
		}
		int32_t cnt = 0;
		for (const Thrall &o : thralls) {
			if (!o.alive_target()) {
				continue;
			}
			const double dx = double(o.x) - double(t.x), dz = double(o.z) - double(t.z);
			if (dx * dx + dz * dz <= r2) {
				cnt++;
			}
		}
		if (cnt > best_n) {
			best_n = cnt;
			best = int32_t(i);
		}
	}
	if (best >= 0) {
		e.aim_x = thralls[size_t(best)].x;
		e.aim_z = thralls[size_t(best)].z;
		return;
	}
	Tgt tg;
	if (target_at(e.target, tg)) {
		e.aim_x = tg.x;
		e.aim_z = tg.z;
	} else {
		e.aim_x = e.x + float(std::sin(double(e.yaw)));
		e.aim_z = e.z + float(std::cos(double(e.yaw)));
	}
}

// DmStatePfLureKite.engage's retreat: the plain kite's back-off, but toward the open water: the heading is LURE_AWAY of the way from the target and LURE_TOWARD of the way to the
// lure, aimed LURE_AHEAD metres ahead. (The state is the kite whenever it would cast, walk in or stand; only the back-off differs.)
void World::lure_goal(const Enemy &e, float p_tx, float p_tz, double p_d, float &r_gx, float &r_gz) const {
	const double dd = std::max(p_d, 0.001);
	const double ax = (double(e.x) - double(p_tx)) / dd, az = (double(e.z) - double(p_tz)) / dd;
	const double lx = tun.pf.lure_x - double(e.x), lz = tun.pf.lure_z - double(e.z);
	const double ll = std::max(std::sqrt(lx * lx + lz * lz), 0.001);
	r_gx = float(double(e.x) + (ax * LURE_AWAY + lx / ll * LURE_TOWARD) * LURE_AHEAD);
	r_gz = float(double(e.z) + (az * LURE_AWAY + lz / ll * LURE_TOWARD) * LURE_AHEAD);
}

// DmEnemyPfHazard.hook_ready: the chain is for a hero (never a thrall) between SEXTON_HOOK.minRange and range away with a clear line, when both the swing's cooldown and the
// chain's own are up.
bool World::hook_ready(const Enemy &e, double p_d, float p_tx, float p_tz) {
	return e.attack_cd <= 0.0 && e.pf.hook_cd <= 0.0 && thrall_slot.find(e.target) == thrall_slot.end() && p_d >= tun.pf.hook_min && p_d <= tun.pf.hook_range &&
			line_clear(e.x, e.z, p_tx, p_tz);
}

// DmPfUtil.pull: drag a hero `m` metres toward the sexton (never closer than PULL_CLOSEST to it, and not at all for under PULL_MIN_STEP), then root it.
void World::pull_target(Enemy &e, const Tgt &p_target, float p_tox, float p_toz, double p_m, double p_root_s) {
	const float dx = p_tox - p_target.x, dz = p_toz - p_target.z;
	const double len = std::sqrt(double(dx) * dx + double(dz) * dz);
	const double step = std::min(p_m, std::max(0.0, len - PULL_CLOSEST));
	if (step > PULL_MIN_STEP) {
		target_effect(e, p_target.id, TE_PULL, 0.0, float(double(p_target.x) + dx / len * step), float(double(p_target.z) + dz / len * step));
	}
	target_effect(e, p_target.id, TE_ROOT, p_root_s, 0.0f, 0.0f);
}

// DmEnemyPfHazard._hook_strike: the chain flies along the aim fixed at the wind-up's start, reach SEXTON_HOOK.range + 0.6 m, half a width of halfWidth + 0.3 m: every body in that
// strip with a clear line from the sexton takes hook_blow x the blow, and a hero is dragged toward the sexton and rooted. The cue is told at the aim, SEXTON_HOOK.range wide.
void World::hook_strike(Enemy &e) {
	const PfTuning &P = tun.pf;
	float dx = e.aim_x - e.x, dz = e.aim_z - e.z;
	double ln = std::sqrt(double(dx) * dx + double(dz) * dz);
	if (ln < 0.001) {
		dx = float(std::sin(double(e.yaw)));
		dz = float(std::cos(double(e.yaw)));
		ln = 1.0;
	}
	const double ux = dx / ln, uz = dz / ln;
	const double reach = P.hook_range + HOOK_REACH_PAD, half = P.hook_half + HOOK_HALF_PAD;
	const double dmg = e.damage * e.st.dealt * P.hook_blow;
	const int32_t kind = defs[e.def].hit_kind;
	each_target([&](const Tgt &x) {
		const double vx = double(x.x) - double(e.x), vz = double(x.z) - double(e.z);
		const double along = vx * ux + vz * uz;
		if (along < 0.0 || along > reach || std::abs(vx * uz - vz * ux) > half || !line_clear(e.x, e.z, x.x, x.z)) {
			return;
		}
		hit_target(e, x.id, dmg, kind);
		// `not is_thrall(tg) and target_valid(tg)`: a hero's blow is an event the host applies later, so the body is alive here; the hero's own refusal of an effect when dead is the same answer
		if (thrall_slot.find(x.id) == thrall_slot.end()) {
			pull_target(e, x, e.x, e.z, P.hook_pull, P.hook_root_s);
		}
	});
	events.push(EV_CUE, e.id, { CUE_HOOK }, { e.aim_x, e.aim_z, float(P.hook_range) });
}

} // namespace dm
