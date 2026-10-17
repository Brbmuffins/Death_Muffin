#include "world.h"

#include <algorithm>
#include <cmath>

// The 20 Hz snapshot (native/README.md "Co-op" has the byte layout): every live body's changing fields, quantized. The host writes one message per
// send; a puppet applies it (puppet.cpp turns the records into eased bodies and derived events). Spawn-time facts (def, level, area, kind, owner)
// are not repeated here: they travel once, in the reliable spawn events.

namespace dm {

namespace {

struct Fnv {  // FNV-1a, 32 bit
	uint32_t h = 2166136261u;
	void bytes(const void *p, size_t n) {
		const uint8_t *b = static_cast<const uint8_t *>(p);
		for (size_t i = 0; i < n; i++) {
			h = (h ^ b[i]) * 16777619u;
		}
	}
	void str(const std::string &s) {
		bytes(s.data(), s.size());
		bytes("\0", 1);
	}
	void num(double v) { bytes(&v, sizeof(v)); }
};

} // namespace

// What two builds must agree on for a message to mean the same thing: the tables the numbers index into, and the numbers a puppet derives events from.
uint32_t World::content_hash() const {
	Fnv f;
	for (const EnemyDef &d : defs) {
		f.str(d.id);
		for (const double v : { d.hp, d.damage, d.speed, d.radius, d.attack_range, d.windup_s, d.cooldown_s, d.scale, d.slam_r, double(d.blow), double(d.behavior), d.frenzy ? 1.0 : 0.0,
					 // the Nave's kinds: what a guest draws a dive's telegraph with, and the flags that make a def the Censer, the Templar, the Acolyte or a silenceable caster
					 d.has_dive ? d.dive_r : 0.0, d.aura ? 1.0 : 0.0, d.shield ? 1.0 : 0.0, d.unbind ? 1.0 : 0.0, d.silence_aware ? 1.0 : 0.0,
					 // the Sanctum's and Cloister's kinds: the Seraph's flag (it blesses and casts the curse)
					 d.ward ? 1.0 : 0.0 }) {
			f.num(v);
		}
	}
	for (const StatusRule &r : status_rules) {
		f.str(r.name);
	}
	for (const char *n : THRALL_KIND_NAMES) {
		f.str(n);
	}
	for (const char *n : AFFIX_NAMES) {
		f.str(n);
	}
	for (const double v : { tun.elite_windup, tun.elite_radius, tun.elite_damage, tun.elite_scale, tun.dust_radius, tun.burrow_erupt_r, tun.burrow_erupt_s,
				 tun.burrow_erupt_s_graves, tun.burrow_dig_s, tun.bell_r, tun.bell_windup, tun.scream_r, tun.flask_r }) {
		f.num(v);
	}
	// the Pyre's and the Fen's kinds: the flags that make a def the Husk, the Slag Brute, the Sexton or the Wisp, and the rings and the chain a guest draws telegraphs with
	for (const EnemyDef &d : defs) {
		for (const double v : { d.pf.ember_death ? 1.0 : 0.0, d.pf.slam_pool ? 1.0 : 0.0, d.pf.hook ? 1.0 : 0.0, d.pf.lure ? 1.0 : 0.0 }) {
			f.num(v);
		}
	}
	for (const double v : { tun.pf.ember_r, tun.pf.hex_r, tun.pf.pulse_r, tun.pf.hook_range }) {
		f.num(v);
	}
	return f.h;
}

// One enemy's or thrall's record, shared by the whole-message writer and the parts writer so the bytes are the same either way. `r_prev` is the previous record's
// id in this list (the ids travel as differences); positions are relative to the area's middle (`p_ox`, `p_oz`).
void World::put_snap_enemy(ByteWriter &w, const Enemy &e, int32_t &r_prev, double p_ox, double p_oz) {
	w.svar(e.id - r_prev);
	r_prev = e.id;
	const bool aim = e.state == ATTACK || e.state == ERUPT;
	w.u8(uint32_t(e.state) | (e.elite ? EF_ELITE : 0u) | ((e.dug_in || ((e.swing_raise || e.diving || e.pf.hooking) && e.state == ATTACK)) ? EF_DUG_IN : 0u) | (aim ? EF_AIM : 0u) | (e.affixes ? EF_AFFIXES : 0u));
	if (e.affixes) {
		w.u8(e.affixes);
	}
	w.u16(uint32_t(q_pos(e.x, p_ox, rep.positions_clamped)) & 0xffffu);
	w.u16(uint32_t(q_pos(e.z, p_oz, rep.positions_clamped)) & 0xffffu);
	w.u8(q_yaw(e.yaw));
	w.u16(q_hp(e.hp, e.max_hp));
	w.u8(q_t(e.state_t));
	if (aim) {
		w.u16(uint32_t(q_pos(e.aim_x, p_ox, rep.positions_clamped)) & 0xffffu);
		w.u16(uint32_t(q_pos(e.aim_z, p_oz, rep.positions_clamped)) & 0xffffu);
	}
}

void World::put_snap_thrall(ByteWriter &w, const Thrall &t, int32_t &r_prev, double p_ox, double p_oz) {
	w.svar(t.id - r_prev);
	r_prev = t.id;
	const bool aim = t.state == TS_ATTACK;
	w.u8(uint32_t(t.state) | (t.rally_t > 0.0 ? TF_RALLY : 0u) | (aim ? TF_AIM : 0u));
	w.u16(uint32_t(q_pos(t.x, p_ox, rep.positions_clamped)) & 0xffffu);
	w.u16(uint32_t(q_pos(t.z, p_oz, rep.positions_clamped)) & 0xffffu);
	w.u8(q_yaw(t.yaw));
	w.u16(q_hp(t.hp, t.max_hp));
	w.u8(q_t(t.state_t));
	w.u8(uint32_t(t.swing_n) & 255u);
	if (aim) {
		w.u16(uint32_t(q_pos(t.aim_x, p_ox, rep.positions_clamped)) & 0xffffu);
		w.u16(uint32_t(q_pos(t.aim_z, p_oz, rep.positions_clamped)) & 0xffffu);
	}
}

void World::write_snapshot(std::vector<uint8_t> &r_out, uint32_t p_tick) {
	r_out.clear();
	ByteWriter w(r_out);
	write_wire_header(w, WK_SNAPSHOT, content_hash());
	w.u32(p_tick);
	w.f64(clock);
	// Positions are int16 centimetres from the middle of the area (the grid's bounds, set_area_bounds), so +-327 m of it can be told.
	const double ox = double(grid.min_x) + double(grid.nx) * double(grid.cell) * 0.5;
	const double oz = double(grid.min_z) + double(grid.nz) * double(grid.cell) * 0.5;
	w.f32(float(ox));
	w.f32(float(oz));
	uint32_t ne = 0, nt = 0;
	for (const Enemy &e : enemies) {
		ne += e.state != DEAD ? 1 : 0;
	}
	for (const Thrall &t : thralls) {
		nt += t.dead ? 0 : 1;
	}
	w.uvar(ne);
	w.uvar(nt);
	int32_t prev = 0;
	for (const Enemy &e : enemies) {
		if (e.state != DEAD) {  // a death is a reliable event, not a record
			put_snap_enemy(w, e, prev, ox, oz);
		}
	}
	prev = 0;
	for (const Thrall &t : thralls) {
		if (!t.dead) {
			put_snap_thrall(w, t, prev, ox, oz);
		}
	}
	rep.snapshots_built++;
	rep.snapshot_frames++;
}

// The same snapshot cut into messages of at most `p_max_bytes` each (a UDP packet must stay under the path's MTU or its fragments are lost together): the live enemies in
// spawn order, then the live thralls in raise order, in as many messages as it takes. Every part is a complete snapshot message of its own (the header, the counts of ITS
// records, ids as differences from 0), so a guest applies each as it arrives, in any order that is newer-first: the ticks of the parts are `p_first_tick`, +1, +2 ... and
// a puppet ignores a tick that is not newer than the last one it applied. Bodies are independent records, so a lost part loses only its bodies' update for 50 ms.
// There is always at least one part (an empty snapshot still carries the clock). Returns how many parts it made; `r_parts` keeps its inner buffers between calls.
size_t World::write_snapshot_parts(std::vector<std::vector<uint8_t>> &r_parts, uint32_t p_first_tick, size_t p_max_bytes) {
	const double ox = double(grid.min_x) + double(grid.nx) * double(grid.cell) * 0.5;
	const double oz = double(grid.min_z) + double(grid.nz) * double(grid.cell) * 0.5;
	constexpr size_t HEADER_MAX = WIRE_HEADER + 4 + 8 + 4 + 8 + 2;  // magic and version, tick, clock, origin, and both counts at most one byte more than a 2-byte varint
	const size_t budget = p_max_bytes > HEADER_MAX + 16 ? p_max_bytes - HEADER_MAX : 16;
	size_t parts = 0;
	size_t ei = 0, ti = 0;
	for (;;) {
		uint32_t ne = 0, nt = 0;
		snap_body.clear();
		ByteWriter bw(snap_body);
		int32_t prev = 0;
		while (ei < enemies.size()) {
			if (enemies[ei].state == DEAD) {
				ei++;
				continue;
			}
			const size_t before = snap_body.size();
			put_snap_enemy(bw, enemies[ei], prev, ox, oz);
			if (snap_body.size() > budget && ne + nt > 0) {  // does not fit: it opens the next part (a part always takes at least one record)
				snap_body.resize(before);
				break;
			}
			ne++;
			ei++;
		}
		prev = 0;
		const bool enemies_done = ei >= enemies.size();
		while (enemies_done && ti < thralls.size()) {
			if (thralls[ti].dead) {
				ti++;
				continue;
			}
			const size_t before = snap_body.size();
			put_snap_thrall(bw, thralls[ti], prev, ox, oz);
			if (snap_body.size() > budget && ne + nt > 0) {
				snap_body.resize(before);
				break;
			}
			nt++;
			ti++;
		}
		if (r_parts.size() <= parts) {
			r_parts.emplace_back();
		}
		std::vector<uint8_t> &out = r_parts[parts];
		out.clear();
		ByteWriter w(out);
		write_wire_header(w, WK_SNAPSHOT, content_hash());
		w.u32(p_first_tick + uint32_t(parts));
		w.f64(clock);
		w.f32(float(ox));
		w.f32(float(oz));
		w.uvar(ne);
		w.uvar(nt);
		w.bytes(snap_body.data(), snap_body.size());
		parts++;
		rep.snapshots_built++;
		while (ei < enemies.size() && enemies[ei].state == DEAD) {
			ei++;
		}
		while (ti < thralls.size() && thralls[ti].dead) {
			ti++;
		}
		if (ei >= enemies.size() && ti >= thralls.size()) {
			break;
		}
	}
	rep.snapshot_frames++;
	return parts;
}

namespace {

bool fail(Replica &r, const std::string &p_why) {
	r.error = p_why;
	return false;
}

inline float d_pos(ByteReader &r, double p_origin) {
	const int32_t q = int16_t(r.u16());
	return float(p_origin + double(q) * POS_QUANTUM);
}

} // namespace

// Why a header is refused, in words a player can act on (B28: which side is behind and what to do). Empty when it is fine.
std::string check_wire_header(ByteReader &r, uint32_t p_hash, uint32_t &r_kind) {
	if (r.left() < WIRE_HEADER) {
		return "message too short (" + std::to_string(r.n) + " bytes)";
	}
	const uint32_t m0 = r.u8(), m1 = r.u8();
	r_kind = r.u8();
	const uint32_t ver = r.u8();
	const uint32_t hash = r.u32();
	if (m0 != WIRE_MAGIC0 || m1 != WIRE_MAGIC1) {
		return "not a Death Muffin core message (bad magic)";
	}
	if (ver != WIRE_VERSION) {
		if (ver > WIRE_VERSION) {
			return "co-op format mismatch: the host sent version " + std::to_string(ver) + ", this build speaks " + std::to_string(WIRE_VERSION) +
					" (this build is older: restart it from the launcher)";
		}
		return "co-op format mismatch: the host sent version " + std::to_string(ver) + ", this build speaks " + std::to_string(WIRE_VERSION) +
				" (the host's build is older: it must restart from the launcher)";
	}
	if (hash != p_hash) {
		return "co-op data mismatch: the host's enemy and status tables differ from this build's (different game data)";
	}
	return std::string();
}

bool World::read_snapshot(const uint8_t *p_data, size_t p_size) {
	rep.error.clear();
	if (!puppet) {
		rep.snapshots_refused++;
		return fail(rep, "this core is not a puppet (set_puppet(true) on a guest)");
	}
	ByteReader r(p_data, p_size);
	uint32_t kind = 0;
	const std::string why = check_wire_header(r, content_hash(), kind);
	if (!why.empty()) {
		rep.snapshots_refused++;
		return fail(rep, why);
	}
	if (kind != WK_SNAPSHOT) {
		rep.snapshots_refused++;
		return fail(rep, "expected a snapshot, got message kind " + std::to_string(kind));
	}
	const uint32_t tick = r.u32();
	const double clk = r.f64();
	const double ox = r.f32(), oz = r.f32();
	const uint32_t ne = r.uvar(), nt = r.uvar();
	if (r.bad || !std::isfinite(ox) || !std::isfinite(oz) || !std::isfinite(clk) || (size_t(ne) + size_t(nt)) * 8u > r.left()) {  // every record is at least 8 bytes
		rep.snapshots_refused++;
		return fail(rep, "damaged snapshot (header or counts)");
	}
	if (rep.have_tick && int32_t(tick - rep.last_tick) <= 0) {  // a late or repeated packet: nothing to learn from it, nothing wrong with it
		rep.snapshots_stale++;
		return true;
	}
	if (!rep.have_clock || clk > clock) {  // the guest's clock never runs backwards
		clock = clk;
		rep.have_clock = true;
	}
	SnapRec s;
	int32_t prev = 0;
	for (uint32_t i = 0; i < ne && !r.bad; i++) {
		s = SnapRec();
		prev += r.svar();
		s.id = prev;
		const uint32_t f = r.u8();
		s.state = int32_t(f & 15u);
		s.elite = (f & EF_ELITE) != 0;
		s.dug_in = (f & EF_DUG_IN) != 0;
		s.has_aim = (f & EF_AIM) != 0;
		s.affixes = (f & EF_AFFIXES) ? r.u8() : 0u;
		s.x = d_pos(r, ox);
		s.z = d_pos(r, oz);
		s.yaw = d_yaw(r.u8());
		s.hpq = r.u16();
		s.t = r.u8();
		if (s.has_aim) {
			s.aim_x = d_pos(r, ox);
			s.aim_z = d_pos(r, oz);
		}
		if (!r.bad) {
			puppet_apply_enemy(s);
		}
	}
	prev = 0;
	for (uint32_t i = 0; i < nt && !r.bad; i++) {
		s = SnapRec();
		prev += r.svar();
		s.id = prev;
		const uint32_t f = r.u8();
		s.state = int32_t(f & 7u);
		s.rally = (f & TF_RALLY) != 0;
		s.has_aim = (f & TF_AIM) != 0;
		s.x = d_pos(r, ox);
		s.z = d_pos(r, oz);
		s.yaw = d_yaw(r.u8());
		s.hpq = r.u16();
		s.t = r.u8();
		s.swing = r.u8();
		if (s.has_aim) {
			s.aim_x = d_pos(r, ox);
			s.aim_z = d_pos(r, oz);
		}
		if (!r.bad) {
			puppet_apply_thrall(s);
		}
	}
	if (r.bad) {
		rep.snapshots_refused++;
		return fail(rep, "damaged snapshot (a record ran past the end)");
	}
	rep.last_tick = tick;
	rep.have_tick = true;
	rep.snapshots_applied++;
	return true;
}

} // namespace dm
