#include "world.h"

#include <algorithm>
#include <cmath>

// A guest's core (native/README.md "Co-op"): no brains and no rules. Its bodies come from the host: a body appears from a reliable spawn event, is
// moved by snapshots (eased the way the old game's puppets were, dm_enemy.gd `_puppet_step`) and goes with a reliable removal. The events GDScript reads on
// the host are in the guest's buffer too: forwarded ones as they came, derived ones from state edges and health drops.
// The tables are the host's own tables, so queries and DmCrowd work on a puppet the way they do on the host.

namespace dm {

namespace {

constexpr double RALLY_VISIBLE_S = 0.3;  // dm_thrall.gd apply_net_state: `rally_t = 0.3 if rally else 0.0`

inline double hp_of(uint32_t p_hpq, double p_max) {
	return p_hpq >= HP_ONE ? p_max : p_max * double(p_hpq) / double(HP_ONE);
}

template <class T>
void ease(T &b, double p_dt, double p_k, double p_ks) {  // _puppet_step
	const float bx = b.x, bz = b.z;
	const float dx = b.net_x - bx, dz = b.net_z - bz;
	bool snapped = false;
	if (double(dx) * dx + double(dz) * dz > PUPPET_TELEPORT_SQ) {
		b.x = b.net_x;
		b.z = b.net_z;
		snapped = true;
	} else {
		b.x = bx + float(double(dx) * p_k);
		b.z = bz + float(double(dz) * p_k);
	}
	b.yaw = float(lerp_angle(b.yaw, b.net_yaw, p_k));
	if (!snapped) {  // a jump is not speed (the old game's puppet counted it; a walking clip would sprint for a moment)
		const double mx = double(b.x) - bx, mz = double(b.z) - bz;
		const double sp = std::sqrt(mx * mx + mz * mz) / std::max(p_dt, 0.0001);
		b.speed_smooth = float(double(b.speed_smooth) + (sp - double(b.speed_smooth)) * p_ks);
	}
	b.ground_speed = b.speed_smooth > PUPPET_MIN_SPEED ? double(b.speed_smooth) : 0.0;
}

void decay(StatusSet &s, double p_dt) {  // the chips' countdown; expiry itself comes from the host
	for (int32_t i = 0; i < s.n; i++) {
		if (s.rec[i].rem < 6.0e4) {
			s.rec[i].rem = std::max(0.0, s.rec[i].rem - p_dt);
		}
	}
}

} // namespace

void World::clear_bodies() {
	enemies.clear();
	enemy_slot.clear();
	pending_spawns.clear();
	unbinds.clear();
	thralls.clear();
	thrall_slot.clear();
	corpses.clear();
	zones.clear();
	rebuild_grid();
}

void World::set_puppet(bool p_on) {
	puppet = p_on;
	clear_bodies();
	events.clear();
	rep.reset_host();
	rep.reset_guest();
	rep.error.clear();
}

void World::step_puppet(double p_dt) {
	clock += p_dt;
	const double k = 1.0 - std::exp(-PUPPET_EASE * p_dt), ks = 1.0 - std::exp(-PUPPET_SPEED_RATE * p_dt);
	for (Enemy &e : enemies) {
		e.state_t += p_dt;
		if (e.st.n > 0) {
			decay(e.st, p_dt);
		}
		if (e.state == DEAD || !e.net_seen) {  // a dead body stays where it fell; one not yet in a snapshot stays where it was born
			e.ground_speed = 0.0;
			continue;
		}
		ease(e, p_dt, k, ks);
	}
	for (Thrall &t : thralls) {
		t.state_t += p_dt;
		if (t.st.n > 0) {
			decay(t.st, p_dt);
		}
		if (t.dead || !t.net_seen) {
			t.ground_speed = 0.0;
			continue;
		}
		ease(t, p_dt, k, ks);
	}
	rebuild_grid();
}

// ---------------------------------------------------------------------------------------------------------------- snapshot records

void World::puppet_apply_enemy(const SnapRec &s) {
	const auto it = enemy_slot.find(s.id);
	if (it == enemy_slot.end()) {  // its spawn event has not arrived yet (the two travel apart): the next snapshot will have it
		rep.records_unknown++;
		return;
	}
	Enemy &e = enemies[it->second];
	if (e.state == DEAD) {  // a death is final: a snapshot made before it must not raise the body again
		rep.records_dead++;
		return;
	}
	if (s.elite != e.elite) {
		rep.desync++;
	}
	e.affixes = uint8_t(s.affixes);
	const EnemyDef &kd = defs[size_t(e.def)];
	const bool support = kd.behavior == B_SUPPORT;
	e.dug_in = s.dug_in && !support && !kd.has_dive && !kd.pf.hook;   // bit 5 is a Deacon's raise in progress, a Gargoyle's dive or a Sexton's chain, not a dig
	e.swing_raise = s.dug_in && support;
	e.diving = s.dug_in && kd.has_dive;
	e.pf.hooking = s.dug_in && kd.pf.hook;
	e.net_x = s.x;
	e.net_z = s.z;
	e.net_yaw = s.yaw;
	if (s.has_aim) {
		e.aim_x = s.aim_x;
		e.aim_z = s.aim_z;
	}
	if (!e.net_seen) {  // the first snapshot places the body: it snaps
		e.net_seen = true;
		e.x = e.last_x = s.x;
		e.z = e.last_z = s.z;
		e.yaw = s.yaw;
	}
	// health: a drop is a hit the guest did not see (a `damaged` event and a flash from the hp difference); a rise (a meal) is just taken
	if (s.hpq < e.net_hpq) {
		const double lost = double(e.net_hpq - s.hpq) / double(HP_ONE) * e.max_hp;
		e.net_hpq = uint16_t(s.hpq);
		e.hp = hp_of(s.hpq, e.max_hp);
		events.push(EV_ENEMY_DAMAGED, e.id, { 0 }, { float(lost), float(e.hp) });
		rep.events_derived++;
	} else {
		e.net_hpq = uint16_t(s.hpq);
		e.hp = hp_of(s.hpq, e.max_hp);
	}
	const double t = double(s.t) / 100.0;
	if (s.state != e.state) {
		const int32_t prev = e.state;
		e.state = s.state;
		e.state_t = t;
		events.push(EV_ENEMY_STATE, e.id, { prev, s.state }, {});
		rep.events_derived++;
		const EnemyDef &d = defs[size_t(e.def)];
		if (s.state == ATTACK) {  // begin_attack + announce_telegraph: the swing and its warning, from the aim the host fixed
			const float ax = s.has_aim ? s.aim_x : e.x, az = s.has_aim ? s.aim_z : e.z;
			e.aim_x = ax;
			e.aim_z = az;
			const int32_t blow = e.diving ? BLOW_DIVE : (e.pf.hooking ? BLOW_HOOK : d.blow);   // a Gargoyle's swing is a dive, a Sexton's a chain, when bit 5 of its record says so (their `dv` and `hk`)
			e.phase = 0;
			events.push(EV_ENEMY_ATTACK, e.id, { blow }, { ax, az, float(e.windup_s) });
			const float left = float(std::max(PUPPET_MIN_TELL_S, e.windup_s - t));  // dm_enemy.gd: announce_telegraph(maxf(0.05, windup_s - net_age))
			switch (blow) {
				case BLOW_CONE:
					events.push(EV_TELEGRAPH, e.id, { TELL_CONE }, { s.x, s.z, ax, az, 0.0f, left });
					break;
				case BLOW_DUST:
					events.push(EV_TELEGRAPH, e.id, { TELL_DUST }, { s.x, s.z, ax, az, float(tun.dust_radius), left });
					break;
				case BLOW_SLAM:
					events.push(EV_TELEGRAPH, e.id, { TELL_SLAM }, { s.x, s.z, ax, az, float(d.slam_r), left });
					break;
				case BLOW_CURSE:
					events.push(EV_TELEGRAPH, e.id, { TELL_CURSE }, { s.x, s.z, ax, az, 0.0f, left });
					break;
				case BLOW_SCREAM:
					events.push(EV_TELEGRAPH, e.id, { TELL_SCREAM }, { s.x, s.z, ax, az, float(tun.scream_r), left });
					break;
				case BLOW_DIVE:
					events.push(EV_TELEGRAPH, e.id, { TELL_DIVE }, { s.x, s.z, ax, az, float(d.dive_r), left });
					break;
				case BLOW_FLASK:
					events.push(EV_TELEGRAPH, e.id, { TELL_FLASK }, { s.x, s.z, ax, az, float(tun.flask_r), left });
					break;
				case BLOW_EMBER:
					events.push(EV_TELEGRAPH, e.id, { TELL_EMBER }, { s.x, s.z, ax, az, float(tun.pf.ember_r), left });
					break;
				case BLOW_HEX:
					events.push(EV_TELEGRAPH, e.id, { TELL_HEX }, { s.x, s.z, ax, az, float(tun.pf.hex_r), left });
					break;
				case BLOW_PULSE:
					events.push(EV_TELEGRAPH, e.id, { TELL_PULSE }, { s.x, s.z, ax, az, float(tun.pf.pulse_r), left });
					break;
				case BLOW_HOOK:
					events.push(EV_TELEGRAPH, e.id, { TELL_HOOK }, { s.x, s.z, ax, az, float(tun.pf.hook_range), left });
					break;
				default:  // a Deacon's swing is a raise or a curse (bit 5 of the record); the plain melee swing has no telegraph
					if (d.behavior == B_SUPPORT) {
						events.push(EV_TELEGRAPH, e.id, { e.swing_raise ? TELL_RAISE : TELL_CURSE }, { s.x, s.z, ax, az, 0.0f, left });
					}
					break;
			}
			rep.events_derived += 2;
		} else if (s.state == ERUPT) {
			e.erupt_s = (e.in_graves ? tun.burrow_erupt_s_graves : tun.burrow_erupt_s) * (e.elite ? tun.elite_windup : 1.0);
			const float left = float(std::max(PUPPET_MIN_TELL_S, e.erupt_s - t));
			events.push(EV_TELEGRAPH, e.id, { TELL_ERUPT }, { s.x, s.z, s.has_aim ? s.aim_x : s.x, s.has_aim ? s.aim_z : s.z, float(tun.burrow_erupt_r), left });
			rep.events_derived++;
		}
	} else if (s.t < T_SATURATED && std::fabs(e.state_t - t) > PUPPET_T_RESYNC_S) {
		if (e.state == ATTACK && e.phase == 0 && t < e.state_t && e.state_t > e.windup_s - PUPPET_PHASE_SLACK_S) {
			e.phase = 1;  // the host restarted the count at the blow: a dive has landed and sits grounded (the crowd draws it so)
		}
		e.state_t = t;  // the host restarted the count (a swing's wind-up ended) or the guest drifted
	}
}

void World::puppet_apply_thrall(const SnapRec &s) {
	const auto it = thrall_slot.find(s.id);
	if (it == thrall_slot.end()) {
		rep.records_unknown++;
		return;
	}
	Thrall &t = thralls[it->second];
	if (t.dead) {
		rep.records_dead++;
		return;
	}
	t.net_x = s.x;
	t.net_z = s.z;
	t.net_yaw = s.yaw;
	t.rally_t = s.rally ? RALLY_VISIBLE_S : 0.0;
	if (!t.net_seen) {
		t.net_seen = true;
		t.x = s.x;
		t.z = s.z;
		t.yaw = s.yaw;
	}
	if (s.hpq < t.net_hpq) {
		const double lost = double(t.net_hpq - s.hpq) / double(HP_ONE) * t.max_hp;
		t.net_hpq = uint16_t(s.hpq);
		t.hp = hp_of(s.hpq, t.max_hp);
		events.push(EV_THRALL_DAMAGED, t.id, { 0 }, { float(lost), float(t.hp) });
		rep.events_derived++;
	} else {
		t.net_hpq = uint16_t(s.hpq);
		t.hp = hp_of(s.hpq, t.max_hp);
	}
	const double tt = double(s.t) / 100.0;
	if (s.state != t.state) {
		const int32_t prev = t.state;
		t.state = s.state;
		t.state_t = tt;
		events.push(EV_THRALL_STATE, t.id, { prev, s.state }, {});
		rep.events_derived++;
	} else if (s.t < T_SATURATED && std::fabs(t.state_t - tt) > PUPPET_T_RESYNC_S) {
		t.state_t = tt;
	}
	const uint32_t seen = uint32_t(t.swing_n) & 255u;
	if (s.swing != seen) {  // the attack visual fires when the counter changes (dm_thrall.gd `_swing_seen`)
		t.swing_n += int32_t((s.swing - seen) & 255u);
		if (s.has_aim) {
			t.aim_x = s.aim_x;
			t.aim_z = s.aim_z;
		}
		events.push(EV_THRALL_SWING, t.id, { t.swing_n, 0 }, { t.aim_x, t.aim_z, 0.0f });
		rep.events_derived++;
	}
}

void World::puppet_thrall_max_hp(int32_t p_id, float p_max_hp) {
	const auto it = thrall_slot.find(p_id);
	if (it != thrall_slot.end() && p_max_hp > 0.0f) {
		Thrall &t = thralls[it->second];
		t.max_hp = p_max_hp;
		t.hp = hp_of(t.net_hpq, t.max_hp);
	}
}

// ---------------------------------------------------------------------------------------------------------------- reliable records

bool World::puppet_event(int32_t p_type, int32_t p_id, const int32_t *I, int32_t p_ni, const float *F, int32_t p_nf, const WireTail &p_tail, const uint8_t *p_status_bytes, uint32_t p_status_n) {
	switch (p_type) {
		case EV_ENEMY_SPAWNED: {
			if (p_id <= 0 || I[0] < 0 || I[0] >= int32_t(defs.size()) || I[3] < 0 || I[3] >= int32_t(areas.size()) || p_tail.state > uint32_t(EMERGE) || !(F[2] > 0.0f) || enemies.size() >= PUPPET_MAX_ENEMIES) {
				return false;
			}
			if (enemy_slot.count(p_id)) {  // told twice: the first one stands
				rep.desync++;
				return true;
			}
			const EnemyDef &d = defs[size_t(I[0])];
			Enemy e;  // DmEnemy._ready without the dice: the per-body rolls (speed spread, flank side, phases) are the host's business
			e.id = p_id;
			e.def = I[0];
			e.level = I[1];
			e.elite = I[2] != 0;
			e.area = I[3];
			e.affixes = uint8_t(I[4]);
			e.frenzy = d.frenzy;
			e.in_graves = areas[size_t(e.area)] == "graves";
			e.x = e.home_x = e.last_x = e.net_x = F[0];
			e.z = e.home_z = e.last_z = e.net_z = F[1];
			e.max_hp = F[2];
			e.net_hpq = uint16_t(p_tail.hpq);
			e.hp = hp_of(p_tail.hpq, e.max_hp);
			e.damage = d.damage * (e.elite ? tun.elite_damage : 1.0);
			e.speed = d.speed;
			e.radius = d.radius * (e.elite ? tun.elite_radius : 1.0);
			e.attack_range = d.attack_range;
			e.windup_s = d.windup_s * (e.elite ? tun.elite_windup : 1.0);
			e.cooldown_s = d.cooldown_s * (e.elite ? tun.elite_cooldown : 1.0);
			e.state = int32_t(p_tail.state);
			e.state_t = double(p_tail.t) / 100.0;
			e.yaw = e.net_yaw = d_yaw(p_tail.yaw);
			e.slot = int32_t(enemies.size());
			enemy_slot[p_id] = e.slot;
			enemies.push_back(e);
			next_id = std::max(next_id, p_id + 1);
			break;
		}
		case EV_ENEMY_DIED: {
			const auto it = enemy_slot.find(p_id);
			if (it != enemy_slot.end() && enemies[it->second].state != DEAD) {
				Enemy &e = enemies[it->second];
				const int32_t prev = e.state;
				if (e.net_hpq > 0) {  // the blow that killed it: the last snapshot showed health left, and the guest sees it go as a damaged event
					events.push(EV_ENEMY_DAMAGED, p_id, { I[4] }, { float(e.hp), 0.0f });
					rep.events_derived++;
				}
				e.state = DEAD;
				e.dead = true;
				e.hp = 0.0;
				e.net_hpq = 0;
				e.state_t = 0.0;
				e.st.n = 0;
				events.push(EV_ENEMY_STATE, p_id, { prev, DEAD }, {});  // the host's change(DEAD) comes first in its buffer; here it rides in front of the death
				rep.events_derived++;
			}
			break;
		}
		case EV_ENEMY_REMOVED: {
			const auto it = enemy_slot.find(p_id);
			if (it != enemy_slot.end()) {
				const size_t k = size_t(it->second);
				enemy_slot.erase(it);
				enemies.erase(enemies.begin() + int64_t(k));
				for (size_t j = k; j < enemies.size(); j++) {
					enemies[j].slot = int32_t(j);
					enemy_slot[enemies[j].id] = int32_t(j);
				}
			}
			break;
		}
		case EV_STATUS_CHANGED: {
			Body *b = body(p_id);
			if (b != nullptr) {
				StatusSet &s = b->st;
				s.n = 0;
				for (uint32_t k = 0; k < p_status_n; k++) {
					const uint8_t *r = p_status_bytes + size_t(k) * 4;
					if (r[0] >= status_rules.size()) {
						continue;  // a status this build does not know
					}
					StatusRec &rec = s.rec[s.n++];
					rec = StatusRec();
					rec.id = r[0];
					rec.stk = r[1];
					const uint32_t deci = uint32_t(r[2]) | (uint32_t(r[3]) << 8);
					rec.rem = deci == 65535u ? STATUS_FOREVER : double(deci) / 10.0;
				}
				s.recompute(status_rules);  // the multipliers a HUD chip or a query reads
				b->speed_mult = s.move;
				b->attack_rate_mult = s.atk;
				b->taken_mult = s.taken;
			}
			break;
		}
		case EV_CORPSE_ADDED: {
			if (I[0] < 0 || I[0] >= int32_t(CK_NONE) || I[1] < ENEMY_RISEN || I[1] >= int32_t(defs.size()) || I[3] < 0 || I[3] >= int32_t(areas.size()) || corpses.size() >= PUPPET_MAX_CORPSES) {
				return false;
			}
			if (corpse_index(p_id) >= 0) {
				rep.desync++;
				return true;
			}
			Corpse c;
			c.id = p_id;
			c.kind = I[0];
			c.def = I[1];
			c.elite = I[2] != 0;
			c.area = I[3];
			c.x = F[0];
			c.z = F[1];
			c.facing = F[2];
			c.scale = F[3];
			c.born_at = corpse_time;  // lifetimes belong to the host: a corpse goes when its gone event comes
			corpses.push_back(c);
			break;
		}
		case EV_CORPSE_GONE: {
			const int32_t k = corpse_index(p_id);
			if (k >= 0) {
				corpses.erase(corpses.begin() + k);
			}
			break;
		}
		case EV_THRALL_RAISED: {
			if (p_id <= 0 || I[0] < 0 || I[0] >= TK_COUNT || p_tail.state >= uint32_t(TS_DEAD) || !(F[3] > 0.0f) || thralls.size() >= PUPPET_MAX_THRALLS) {
				return false;
			}
			if (thrall_slot.count(p_id)) {
				rep.desync++;
				return true;
			}
			Thrall t;
			t.id = p_id;
			t.is_thrall = true;
			t.kind = I[0];
			t.owner = I[1];
			t.formation_slot = I[2];
			t.empowered = I[3] != 0;
			t.champion = I[4] != 0;
			t.radius = t.kind == TK_COLOSSUS ? 0.8 : 0.4;
			t.x = t.net_x = F[0];
			t.z = t.net_z = F[1];
			t.yaw = t.net_yaw = F[2];
			t.max_hp = F[3];
			t.net_hpq = uint16_t(p_tail.hpq);
			t.hp = hp_of(p_tail.hpq, t.max_hp);
			t.state = int32_t(p_tail.state);
			t.state_t = double(p_tail.t) / 100.0;
			t.swing_n = int32_t(p_tail.swing);
			t.rally_t = p_tail.rally ? RALLY_VISIBLE_S : 0.0;
			t.slot = int32_t(thralls.size());
			thrall_slot[p_id] = t.slot;
			thralls.push_back(t);
			next_id = std::max(next_id, p_id + 1);
			break;
		}
		case EV_THRALL_DIED: {
			const auto it = thrall_slot.find(p_id);
			if (it != thrall_slot.end() && !thralls[it->second].dead) {
				Thrall &t = thralls[it->second];
				const int32_t prev = t.state;
				if (I[0] == DR_KILLED && t.net_hpq > 0) {  // killed (not crumbled or decayed): the same last damaged event
					events.push(EV_THRALL_DAMAGED, p_id, { I[3] }, { float(t.hp), 0.0f });
					rep.events_derived++;
				}
				t.dead = true;
				t.dead_reason = I[0];
				t.state = TS_DEAD;
				t.state_t = 0.0;
				t.hp = 0.0;
				t.net_hpq = 0;
				t.st.n = 0;
				events.push(EV_THRALL_STATE, p_id, { prev, TS_DEAD }, {});
				rep.events_derived++;
			}
			break;
		}
		case EV_THRALL_REMOVED: {
			const auto it = thrall_slot.find(p_id);
			if (it != thrall_slot.end()) {
				const size_t k = size_t(it->second);
				thrall_slot.erase(it);
				thralls.erase(thralls.begin() + int64_t(k));
				for (size_t j = k; j < thralls.size(); j++) {
					thralls[j].slot = int32_t(j);
					thrall_slot[thralls[j].id] = int32_t(j);
				}
			}
			break;
		}
		case EV_TELEGRAPH:
			if (I[0] != TELL_TOLL) {
				return false;
			}
			break;
		case EV_CUE:  // the effects index their name table with it
			if (I[0] < 0 || I[0] >= CUE_COUNT) {
				return false;
			}
			break;
		case EV_AFFIX_MOMENT: {
			const auto it = enemy_slot.find(p_id);
			if (I[0] == AM_UNVEIL && it != enemy_slot.end()) {
				enemies[it->second].affixes &= uint8_t(~(1 << AF_SHROUDED));
			}
			break;
		}
		default:  // cues, zones, statuses and corpse beats change no table: they are for the guest's effects
			break;
	}
	events.push_raw(p_type, p_id, I, p_ni, F, p_nf);
	return true;
}

} // namespace dm
