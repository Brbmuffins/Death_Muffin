// The Drowned Nave's five kinds, as the old game's enemy kinds and states made them (the walk, the blows and the Gargoyle's dive are in world.cpp beside the others):
//   - the Censer Bearer (dm_enemy_censer.gd): every second its incense hastes every living enemy within CENSER.radius (itself too): the `incensed` status;
//   - the Lich Acolyte (dm_enemy_clst_acolyte.gd): UNBIND, a thrall of the player's that is KILLED near it is claimed and a Risen climbs out of its place a moment later;
//   - the Bell-Sworn Templar (dm_enemy_clst_templar.gd): a blow from the front passes TEMPLAR_SHIELD.passThrough of its damage, unless it is Fractured;
//   - the Belfry Gargoyle's sight line (dm_enemy_gargoyle.gd clear_line_to);
//   - the Choir Wraith (dm_enemy_wraith.gd) is the caster set with a scream ring: world.cpp, begin_attack and strike.
// Differences from the old game are noted in native/README.md.
#include "world.h"

#include <algorithm>

namespace dm {

// DmEnemyCenser._physics_process, after the base's: unless the body is rising (or dead: the caller), the countdown runs, and at zero it restarts at one second and
// every enemy not dead within the radius takes the status (the group `dm_enemy` is the whole table, in spawn order; a body born this tick is in it too).
void World::tick_aura(int32_t p_slot, double p_dt) {
	Enemy &e = enemies[p_slot];
	if (e.state == RISING) {
		return;
	}
	e.aura_t -= p_dt;
	if (e.aura_t > 0.0) {
		return;
	}
	e.aura_t = AURA_PULSE_S;
	const double r2 = tun.censer_r * tun.censer_r;
	const int32_t src = e.id;
	auto pulse = [&](Enemy &o) {
		if (o.state == DEAD) {
			return;
		}
		const float dx = o.x - e.x, dz = o.z - e.z;
		if (double(dx) * dx + double(dz) * dz <= r2) {
			apply_status(o, st_incensed, src, 1.0, tun.censer_haste_s, 0.0, -1.0, 0.0);
		}
	};
	for (Enemy &o : enemies) {
		pulse(o);
	}
	for (Enemy &o : pending_spawns) {
		pulse(o);
	}
}

Unbind *World::unbind_of(int32_t p_id) {
	for (Unbind &u : unbinds) {
		if (u.id == p_id) {
			return &u;
		}
	}
	return nullptr;
}

void World::drop_unbind(int32_t p_id) {
	for (size_t i = 0; i < unbinds.size(); i++) {
		if (unbinds[i].id == p_id) {
			unbinds.erase(unbinds.begin() + int64_t(i));
			return;
		}
	}
}

// DmEnemyClstAcolyte._physics_process, after the base's: the claim countdown, the claimed falls waiting to rise (from the last to the first), then every WATCH_S
// the acolyte connects to the thralls it has not seen yet (a thrall that fell before the acolyte's next look is not claimed).
void World::tick_unbind(int32_t p_slot, double p_dt) {
	Enemy &e = enemies[p_slot];
	if (e.state == RISING) {
		return;
	}
	Unbind *u = unbind_of(e.id);
	if (u == nullptr) {
		return;
	}
	u->cd -= p_dt;
	for (int32_t i = int32_t(u->pending.size()) - 1; i >= 0; i--) {
		u->pending[size_t(i)].left -= p_dt;
		if (u->pending[size_t(i)].left > 0.0) {
			continue;
		}
		const Unbind::Claim c = u->pending[size_t(i)];
		u->pending.erase(u->pending.begin() + i);
		// `unbind_rise`: the wave director spawns a "risen" at the fall as strong as its raiser, and the acolyte adopts it (it counts toward maxAlive)
		const auto it = def_index.find("risen");
		if (it != def_index.end()) {
			pending_spawns.push_back(make_enemy(it->second, c.x, c.z, e.level, e.hp_mult, e.damage_mult, false, e.area, true, 0));
			enter(pending_spawns.back(), -1);
			u->unbound.push_back(pending_spawns.back().id);
		}
	}
	u->watch_t -= p_dt;
	if (u->watch_t <= 0.0) {
		u->watch_t = WATCH_S;
		for (const Thrall &t : thralls) {
			if (t.dead) {
				continue;
			}
			bool known = false;
			for (const Unbind::Seen &s : u->seen) {
				if (s.thrall == t.id) {
					known = true;
					break;
				}
			}
			if (!known) {
				u->seen.push_back({ t.id, unbind_seq++ });
			}
		}
		u->seen.erase(std::remove_if(u->seen.begin(), u->seen.end(), [this](const Unbind::Seen &s) { return thrall_slot.find(s.thrall) == thrall_slot.end(); }), u->seen.end());
	}
}

// DmThrall.kill's `died` signal, heard by the acolytes that connected to it, in the order they did (the host's and the status set's listeners came first).
void World::thrall_fell(Thrall &t) {
	if (unbinds.empty()) {
		return;
	}
	unbind_order.clear();
	for (size_t k = 0; k < unbinds.size(); k++) {
		for (const Unbind::Seen &s : unbinds[k].seen) {
			if (s.thrall == t.id) {
				unbind_order.push_back({ s.seq, int32_t(k) });
				break;
			}
		}
	}
	std::sort(unbind_order.begin(), unbind_order.end());
	for (const auto &o : unbind_order) {
		unbind_heard(unbinds[size_t(o.second)], t);
	}
}

// DmEnemyClstAcolyte._on_thrall_died: a ready acolyte (not dead, rising or underground, off cooldown) claims a thrall that was KILLED (not crumbled, sacrificed or worn out)
// within UNBIND.range of it and not claimed by another, if fewer than maxAlive claims are pending or alive: the cooldown starts, the fall is remembered, the cue is told.
void World::unbind_heard(Unbind &u, Thrall &t) {
	const auto it = enemy_slot.find(u.id);
	if (it == enemy_slot.end()) {
		return;
	}
	Enemy &a = enemies[size_t(it->second)];
	if (a.state == DEAD || a.state == RISING || a.state == BURROW || u.cd > 0.0) {
		return;
	}
	if (t.dead_reason != DR_KILLED || t.unbind_claimed || flat_dist(a.x, a.z, t.x, t.z) > tun.unbind_range) {
		return;
	}
	if (int32_t(u.pending.size()) + alive_unbound(u) >= tun.unbind_max) {
		return;
	}
	t.unbind_claimed = true;
	u.cd = tun.unbind_cooldown_s;
	u.pending.push_back({ tun.unbind_delay_s, t.x, t.z });
	events.push(EV_CUE, a.id, { CUE_UNBIND }, { t.x, t.z, 0.0f });
}

// DmEnemyClstAcolyte._alive_unbound: the Risen it adopted that are still standing; the fallen and the gone are forgotten as they are counted.
int32_t World::alive_unbound(Unbind &u) {
	int32_t n = 0;
	for (int32_t i = int32_t(u.unbound.size()) - 1; i >= 0; i--) {
		const int32_t id = u.unbound[size_t(i)];
		const auto it = enemy_slot.find(id);
		bool alive;
		if (it != enemy_slot.end()) {
			alive = enemies[size_t(it->second)].state != DEAD;
		} else {  // made this tick and not in the table yet
			alive = std::any_of(pending_spawns.begin(), pending_spawns.end(), [id](const Enemy &p) { return p.id == id; });
		}
		if (alive) {
			n++;
		} else {
			u.unbound.erase(u.unbound.begin() + i);
		}
	}
	return n;
}

// Where a body that can be the source of a blow stands: a hero or a boss (an external), a thrall or an enemy.
bool World::body_place(int32_t p_id, float &r_x, float &r_z) const {
	if (p_id == 0) {
		return false;
	}
	for (const External &x : externals) {
		if (x.id == p_id) {
			r_x = x.x;
			r_z = x.z;
			return true;
		}
	}
	const auto tt = thrall_slot.find(p_id);
	if (tt != thrall_slot.end()) {
		r_x = thralls[size_t(tt->second)].x;
		r_z = thralls[size_t(tt->second)].z;
		return true;
	}
	const auto et = enemy_slot.find(p_id);
	if (et != enemy_slot.end()) {
		r_x = enemies[size_t(et->second)].x;
		r_z = enemies[size_t(et->second)].z;
		return true;
	}
	return false;
}

// DmEnemyClstTemplar.take_damage + shield_blocks, for a directed blow (the caller checks allow_stagger: a DoT tick is undirected): a blow from a body within halfArcDeg of
// where the templar faces does only `passThrough` of its damage, unless the body is Fractured. The glance cue is told at most every 0.25 s of game time. A blow with no
// source body, or from one that is not there, is not directed. Returns the damage that goes on to the base's take_damage.
double World::shield(Enemy &e, int32_t p_source, double p_amount) {
	float sx = 0, sz = 0;
	if (!body_place(p_source, sx, sz)) {
		return p_amount;
	}
	const float vx = sx - e.x, vz = sz - e.z;
	const double l2 = double(vx) * vx + double(vz) * vz;
	if (l2 < 0.0001) {
		return p_amount;
	}
	if (st_fracture >= 0 && e.st.find(st_fracture) >= 0) {
		return p_amount;
	}
	const double fx = std::sin(double(e.yaw)), fz = std::cos(double(e.yaw));
	if ((double(vx) * fx + double(vz) * fz) / std::sqrt(l2) < tun.shield_cos) {
		return p_amount;
	}
	if (clock >= e.block_at) {
		e.block_at = clock + SHIELD_GAP_S;
		events.push(EV_CUE, e.id, { CUE_SHIELD_BLOCK }, { e.x, e.z, 0.0f });
	}
	return p_amount * tun.shield_pass;
}

// DmEnemyGargoyle.clear_line_to: no wall between the body and the point. The old game cast a ray at hover height against the world's colliders; the core has no collision world, so a wall
// is an obstacle (the Ossuary Wall) crossing the straight line, or a stretch of it off the navmesh (the navmesh is cut round walls and what stands in the way): the line is
// sampled every LOS_STEP and a sample farther than LOS_NAV_PAD from the navmesh is a wall. Without a navmesh (a test arena) only obstacles count.
bool World::line_clear(float p_ax, float p_az, float p_bx, float p_bz) {
	for (const Obstacle &o : obstacles) {  // the segment against the box (Liang-Barsky in the box's frame: u along its length, v across)
		const double ax = double(p_ax) - o.x, az = double(p_az) - o.z, bx = double(p_bx) - o.x, bz = double(p_bz) - o.z;
		const double au = ax * o.ux + az * o.uz, av = -ax * o.uz + az * o.ux;
		const double bu = bx * o.ux + bz * o.uz, bv = -bx * o.uz + bz * o.ux;
		const double du = bu - au, dv = bv - av;
		double t0 = 0.0, t1 = 1.0;
		auto clip = [&](double p, double q) {  // keeps the part of the segment with p * t <= q
			if (p == 0.0) {
				return q >= 0.0;
			}
			const double r = q / p;
			if (p < 0.0) {
				if (r > t1) {
					return false;
				}
				t0 = std::max(t0, r);
			} else {
				if (r < t0) {
					return false;
				}
				t1 = std::min(t1, r);
			}
			return true;
		};
		if (clip(-du, au + o.half_len) && clip(du, o.half_len - au) && clip(-dv, av + o.half_thick) && clip(dv, o.half_thick - av)) {
			return false;
		}
	}
	const double dx = double(p_bx) - p_ax, dz = double(p_bz) - p_az;
	const int32_t n = int32_t(std::ceil(std::sqrt(dx * dx + dz * dz) / LOS_STEP));
	for (int32_t i = 1; i < n; i++) {
		float x = float(double(p_ax) + dx * i / n), z = float(double(p_az) + dz * i / n);
		const float px = x, pz = z;
		keep_on_nav(x, z);
		const double ex = double(x) - px, ez = double(z) - pz;
		if (ex * ex + ez * ez > LOS_NAV_PAD * LOS_NAV_PAD) {
			return false;
		}
	}
	return true;
}

} // namespace dm
