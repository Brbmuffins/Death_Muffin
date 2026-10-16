#include "world.h"

#include <algorithm>
#include <cmath>

// The reliable half of the co-op wire (native/README.md "Co-op" has the byte layout): the discrete events a guest needs, encoded from the same event
// buffer GDScript reads (a cursor, like DmCrowd's: the buffer is never consumed here), and the baseline that brings a late guest up to date.
// The events a guest derives itself from snapshots (state edges, attack telegraphs, damage, thrall swings) and the ones only the host acts on
// (blows on heroes, hits on bosses, Withered's spread, the plague pool and the bell's heal) are not on this wire.

namespace dm {

namespace {

// The events GDScript reads that go to guests as they are (the others: see the file comment). The bell's toll telegraph is the only telegraph
// on the wire: a guest derives the attack and erupt telegraphs from the state edge.
bool on_the_wire(int32_t p_type, int32_t p_first_int) {
	switch (p_type) {
		case EV_ENEMY_SPAWNED:
		case EV_ENEMY_DIED:
		case EV_ENEMY_REMOVED:
		case EV_CUE:
		case EV_ZONE:
		case EV_ZONE_PULSE:
		case EV_ZONE_GONE:
		case EV_STATUSES_CLEARED:
		case EV_STATUS_CHANGED:
		case EV_STATUS_DOT:
		case EV_STATUS_EXPIRED:
		case EV_CORPSE_ADDED:
		case EV_CORPSE_CONSUMED:
		case EV_CORPSE_GONE:
		case EV_CORPSE_RUPTURED:
		case EV_THRALL_RAISED:
		case EV_THRALL_DIED:
		case EV_THRALL_REMOVED:
		case EV_THRALL_STATUS:
		case EV_AFFIX_MOMENT:
			return true;
		case EV_TELEGRAPH:
			return p_first_int == TELL_TOLL;
		default:
			return false;
	}
}

// The ints and floats a record must carry at least (a damaged message cannot make the guest read past what its handler indexes).
void arity(int32_t p_type, int32_t &r_ints, int32_t &r_floats) {
	r_ints = r_floats = 0;
	switch (p_type) {
		case EV_ENEMY_SPAWNED: r_ints = 5; r_floats = 3; break;
		case EV_ENEMY_DIED: r_ints = 5; r_floats = 2; break;
		case EV_CUE: r_ints = 1; r_floats = 3; break;
		case EV_ZONE: r_ints = 2; r_floats = 4; break;
		case EV_STATUS_DOT: r_ints = 3; r_floats = 1; break;
		case EV_STATUS_EXPIRED: r_ints = 1; break;
		case EV_CORPSE_ADDED: r_ints = 4; r_floats = 4; break;
		case EV_CORPSE_CONSUMED: r_ints = 2; break;
		case EV_CORPSE_GONE: r_ints = 1; break;
		case EV_CORPSE_RUPTURED: r_ints = 1; r_floats = 3; break;
		case EV_THRALL_RAISED: r_ints = 5; r_floats = 4; break;
		case EV_THRALL_DIED: r_ints = 4; r_floats = 2; break;
		case EV_THRALL_STATUS: r_ints = 2; r_floats = 1; break;
		case EV_AFFIX_MOMENT: r_ints = 1; r_floats = 5; break;
		case EV_TELEGRAPH: r_ints = 1; r_floats = 6; break;
		default: break;
	}
}

void put_event(ByteWriter &w, int32_t p_type, int32_t p_id, const int32_t *p_ints, int32_t p_ni, const float *p_floats, int32_t p_nf) {
	w.u8(uint32_t(p_type));
	w.uvar(uint32_t(p_id));
	w.u8(uint32_t(p_ni << 4 | p_nf));
	for (int32_t k = 0; k < p_ni; k++) {
		w.svar(p_ints[k]);
	}
	for (int32_t k = 0; k < p_nf; k++) {
		w.f32(p_floats[k]);
	}
}

// DmCore.statuses() layout: wire id, stacks, tenths of a second left (65535 = for good), 4 bytes each.
void put_statuses(ByteWriter &w, const StatusSet *p_set) {
	const int32_t n = p_set ? p_set->n : 0;
	w.u8(uint32_t(n));
	for (int32_t k = 0; k < n; k++) {
		const StatusRec &r = p_set->rec[k];
		const int32_t deci = r.rem >= 6.0e4 ? 65535 : std::clamp(int32_t(std::ceil(r.rem * 10.0)), 0, 65534);
		w.u8(uint32_t(r.id));
		w.u8(uint32_t(std::clamp(int32_t(r.stk), 0, 255)));
		w.u16(uint32_t(deci));
	}
}

void put_name(ByteWriter &w, uint32_t p_table, size_t p_index, const std::string &p_name) {
	w.u8(WR_NAME);
	w.u8(p_table);
	w.uvar(uint32_t(p_index));
	w.uvar(uint32_t(p_name.size()));
	w.bytes(reinterpret_cast<const uint8_t *>(p_name.data()), p_name.size());
}

void put_enemy_tail(const World &p_world, ByteWriter &w, int32_t p_id) {  // what the body does now; a body already dead is told as a fresh one, its death follows
	uint32_t state = IDLE, hp = HP_ONE, yaw = 0, t = 0;
	const auto it = p_world.enemy_slot.find(p_id);
	if (it != p_world.enemy_slot.end() && p_world.enemies[it->second].state != DEAD) {
		const Enemy &e = p_world.enemies[it->second];
		state = uint32_t(e.state);
		hp = q_hp(e.hp, e.max_hp);
		yaw = q_yaw(e.yaw);
		t = q_t(e.state_t);
	}
	w.u8(state);
	w.u16(hp);
	w.u8(yaw);
	w.u8(t);
}

void put_thrall_tail(const World &p_world, ByteWriter &w, int32_t p_id) {
	uint32_t state = TS_IDLE, hp = HP_ONE, yaw = 0, t = 0, swing = 0, rally = 0;
	const auto it = p_world.thrall_slot.find(p_id);
	if (it != p_world.thrall_slot.end() && !p_world.thralls[it->second].dead) {
		const Thrall &th = p_world.thralls[it->second];
		state = uint32_t(th.state);
		hp = q_hp(th.hp, th.max_hp);
		yaw = q_yaw(th.yaw);
		t = q_t(th.state_t);
		swing = uint32_t(th.swing_n);
		rally = th.rally_t > 0.0 ? 1u : 0u;
	}
	w.u8(state);
	w.u16(hp);
	w.u8(yaw);
	w.u8(t);
	w.uvar(swing);
	w.u8(rally);
}

} // namespace

// ---------------------------------------------------------------------------------------------------------------- the host

void World::set_replication(bool p_on) {
	rep.reset_host();
	rep.replicating = p_on;
	if (p_on) {
		rep.ev_i = events.ints.size();  // whatever is in the buffer already happened before the guest was told about the world
		rep.ev_f = events.floats.size();
		rep.reasons_sent = sizeof(CORPSE_REASON_NAMES) / sizeof(CORPSE_REASON_NAMES[0]);  // those six are built in on both sides
	}
}

void World::pump_reliable() {
	if (!rep.replicating) {
		return;
	}
	if (rep.rel.size() > REL_MAX_BYTES) {
		rep.rel.clear();
		rep.rel_count = 0;
		rep.seq++;
		rep.overflows++;
	}
	ByteWriter w(rep.rel);
	for (; rep.areas_sent < areas.size(); rep.areas_sent++) {  // the string tables only grow, and a name goes before the first record that uses it
		put_name(w, NT_AREA, rep.areas_sent, areas[rep.areas_sent]);
		rep.rel_count++;
	}
	for (; rep.reasons_sent < reasons.size(); rep.reasons_sent++) {
		put_name(w, NT_REASON, rep.reasons_sent, reasons[rep.reasons_sent]);
		rep.rel_count++;
	}
	const std::vector<int32_t> &I = events.ints;
	const std::vector<float> &F = events.floats;
	size_t i = rep.ev_i, f = rep.ev_f;
	while (i + 4 <= I.size()) {
		const int32_t type = I[i], id = I[i + 1], ni = I[i + 2], nf = I[i + 3];
		const int32_t *pi = I.data() + i + 4;
		const float *pf = F.data() + f;
		i += 4 + size_t(ni);
		f += size_t(nf);
		if (!on_the_wire(type, ni > 0 ? pi[0] : -1) || ni > 15 || nf > 15) {
			continue;
		}
		put_event(w, type, id, pi, ni, pf, nf);
		switch (type) {
			case EV_ENEMY_SPAWNED:
				put_enemy_tail(*this, w, id);
				break;
			case EV_THRALL_RAISED:
				put_thrall_tail(*this, w, id);
				break;
			case EV_STATUS_CHANGED: {  // the set as it is when the batch is made: a later change in the same batch is told by its own record
				const Body *b = body(id);
				put_statuses(w, b ? &b->st : nullptr);
				break;
			}
			default:
				break;
		}
		rep.rel_count++;
	}
	rep.ev_i = i;
	rep.ev_f = f;
}

void World::queue_thrall_max_hp(int32_t p_id) {
	if (!rep.replicating) {
		return;
	}
	pump_reliable();  // the events before the change come before it
	const auto it = thrall_slot.find(p_id);
	if (it == thrall_slot.end()) {
		return;
	}
	ByteWriter w(rep.rel);
	w.u8(WR_THRALL_MAX_HP);
	w.uvar(uint32_t(p_id));
	w.f32(float(thralls[it->second].max_hp));
	rep.rel_count++;
}

bool World::take_reliable(std::vector<uint8_t> &r_out) {
	pump_reliable();
	r_out.clear();
	if (!rep.sealed.empty()) {  // a baseline closed a batch: it goes out first, so the numbers stay in order
		r_out = std::move(rep.sealed.front());
		rep.sealed.erase(rep.sealed.begin());
		return true;
	}
	if (rep.rel_count == 0) {
		return false;
	}
	rep.seq++;
	ByteWriter w(r_out);
	write_wire_header(w, WK_RELIABLE, content_hash());
	w.u32(rep.seq);
	w.uvar(rep.rel_count);
	w.bytes(rep.rel.data(), rep.rel.size());
	rep.batches_built++;
	rep.records_built += rep.rel_count;
	rep.reliable_bytes += r_out.size();
	rep.rel.clear();
	rep.rel_count = 0;
	return true;
}

// Only a baseline needs this (a rare call, so it may allocate): the events not yet handed out are in the baseline's picture of the world, so they become
// the batch the baseline's number covers, and what happens after it starts the next one. A guest that took the baseline ignores that batch.
void World::seal_pending() {
	if (rep.rel_count == 0) {
		return;
	}
	rep.seq++;
	std::vector<uint8_t> batch;
	ByteWriter w(batch);
	write_wire_header(w, WK_RELIABLE, content_hash());
	w.u32(rep.seq);
	w.uvar(rep.rel_count);
	w.bytes(rep.rel.data(), rep.rel.size());
	rep.batches_built++;
	rep.records_built += rep.rel_count;
	rep.reliable_bytes += batch.size();
	rep.sealed.push_back(std::move(batch));
	rep.rel.clear();
	rep.rel_count = 0;
}

// The present as the records that would have built it: every name, then each live enemy and thrall as a spawn (with what it is doing now), the
// corpses, the zones still burning and the statuses. Applying it replaces everything the guest knew.
void World::write_baseline(std::vector<uint8_t> &r_out) {
	pump_reliable();
	seal_pending();  // the baseline already shows the effects of the events not yet handed out: they become the batch its number covers
	r_out.clear();
	std::vector<uint8_t> &body_bytes = rep.base;
	body_bytes.clear();
	ByteWriter b(body_bytes);
	uint32_t count = 0;
	for (size_t k = 0; k < areas.size(); k++) {
		put_name(b, NT_AREA, k, areas[k]);
		count++;
	}
	for (size_t k = sizeof(CORPSE_REASON_NAMES) / sizeof(CORPSE_REASON_NAMES[0]); k < reasons.size(); k++) {
		put_name(b, NT_REASON, k, reasons[k]);
		count++;
	}
	for (const Enemy &e : enemies) {
		if (e.state == DEAD) {
			continue;
		}
		const int32_t ints[5] = { e.def, e.level, e.elite ? 1 : 0, e.area, int32_t(e.affixes) };
		const float fl[3] = { e.x, e.z, float(e.max_hp) };
		put_event(b, EV_ENEMY_SPAWNED, e.id, ints, 5, fl, 3);
		put_enemy_tail(*this, b, e.id);
		count++;
	}
	for (const Thrall &t : thralls) {
		if (t.dead) {
			continue;
		}
		const int32_t ints[5] = { t.kind, t.owner, t.formation_slot, t.empowered ? 1 : 0, t.champion ? 1 : 0 };
		const float fl[4] = { t.x, t.z, t.yaw, float(t.max_hp) };
		put_event(b, EV_THRALL_RAISED, t.id, ints, 5, fl, 4);
		put_thrall_tail(*this, b, t.id);
		count++;
	}
	for (const Corpse &c : corpses) {
		const int32_t ints[4] = { c.kind, c.def, c.elite ? 1 : 0, c.area };
		const float fl[4] = { float(c.x), float(c.z), float(c.facing), float(c.scale) };
		put_event(b, EV_CORPSE_ADDED, c.id, ints, 4, fl, 4);
		count++;
	}
	for (const Zone &z : zones) {
		const int32_t ints[2] = { z.kind, z.source };
		const float fl[4] = { z.x, z.z, float(z.radius), float(std::max(0.0, z.lifetime - z.age)) };
		put_event(b, EV_ZONE, z.id, ints, 2, fl, 4);
		count++;
	}
	for (const Enemy &e : enemies) {
		if (e.state != DEAD && e.st.n > 0) {
			put_event(b, EV_STATUS_CHANGED, e.id, nullptr, 0, nullptr, 0);
			put_statuses(b, &e.st);
			count++;
		}
	}
	for (const Thrall &t : thralls) {
		if (!t.dead && t.st.n > 0) {
			put_event(b, EV_STATUS_CHANGED, t.id, nullptr, 0, nullptr, 0);
			put_statuses(b, &t.st);
			count++;
		}
	}
	ByteWriter w(r_out);
	write_wire_header(w, WK_BASELINE, content_hash());
	w.u32(rep.seq);
	w.f64(clock);
	w.uvar(count);
	w.bytes(body_bytes.data(), body_bytes.size());
}

// ---------------------------------------------------------------------------------------------------------------- the guest

namespace {

bool refuse(Replica &r, const std::string &p_why) {
	r.error = p_why;
	return false;
}

// One record. False: damaged or not something a host sends (the caller stops there).
bool read_record(World &w, ByteReader &r, std::string &r_why) {
	const uint32_t type = r.u8();
	if (r.bad) {
		r_why = "damaged message (a record ran past the end)";
		return false;
	}
	if (type == WR_NAME) {
		const uint32_t table = r.u8(), index = r.uvar(), len = r.uvar();
		if (len > 64) {
			r.bad = true;
		}
		const uint8_t *s = r.bad ? nullptr : r.take(len);
		if (r.bad || (table == NT_AREA && index > 255) || (table == NT_REASON && index > 1023) || table > NT_REASON) {
			r_why = "damaged message (a name)";
			return false;
		}
		const std::string name(reinterpret_cast<const char *>(s), len);
		std::vector<std::string> &names = table == NT_AREA ? w.areas : w.reasons;
		if (names.size() <= index) {
			names.resize(size_t(index) + 1);
		}
		names[index] = name;
		if (table == NT_AREA) {
			w.area_index[name] = int32_t(index);
		}
		return true;
	}
	if (type == WR_THRALL_MAX_HP) {
		const uint32_t id = r.uvar();
		const float mx = r.f32();
		if (r.bad) {
			r_why = "damaged message (a maximum)";
			return false;
		}
		w.puppet_thrall_max_hp(int32_t(id), mx);
		return true;
	}
	int32_t mi = 0, mf = 0;
	arity(int32_t(type), mi, mf);
	if (type < 1 || type > EV_AFFIX_MOMENT || !on_the_wire(int32_t(type), EV_TELEGRAPH == int32_t(type) ? TELL_TOLL : 0)) {
		r_why = "unknown record type " + std::to_string(type);
		return false;
	}
	const uint32_t id = r.uvar();
	const uint32_t counts = r.u8();
	const int32_t ni = int32_t(counts >> 4), nf = int32_t(counts & 15u);
	int32_t ints[15];
	float floats[15];
	for (int32_t k = 0; k < ni; k++) {
		ints[k] = r.svar();
	}
	for (int32_t k = 0; k < nf; k++) {
		floats[k] = r.f32();
		if (!std::isfinite(floats[k])) {  // a number the guest would compute with: nothing in the game is NaN or infinite
			r.bad = true;
		}
	}
	WireTail tail;
	const uint8_t *st_bytes = nullptr;
	uint32_t st_n = 0;
	if (type == EV_ENEMY_SPAWNED || type == EV_THRALL_RAISED) {
		tail.state = r.u8();
		tail.hpq = r.u16();
		tail.yaw = r.u8();
		tail.t = r.u8();
		if (type == EV_THRALL_RAISED) {
			tail.swing = r.uvar();
			tail.rally = r.u8() != 0;
		}
	} else if (type == EV_STATUS_CHANGED) {
		st_n = r.u8();
		st_bytes = st_n <= STATUS_MAX ? r.take(size_t(st_n) * 4) : nullptr;
		if (st_n > STATUS_MAX) {
			r.bad = true;
		}
	}
	if (r.bad || ni < mi || nf < mf) {
		r_why = "damaged message (event " + std::to_string(type) + ")";
		return false;
	}
	if (!w.puppet_event(int32_t(type), int32_t(id), ints, ni, floats, nf, tail, st_bytes, st_n)) {
		r_why = "event " + std::to_string(type) + " does not fit this guest's world";
		return false;
	}
	return true;
}

} // namespace

bool World::read_reliable(const uint8_t *p_data, size_t p_size) {
	rep.error.clear();
	if (!puppet) {
		rep.batches_refused++;
		return refuse(rep, "this core is not a puppet (set_puppet(true) on a guest)");
	}
	ByteReader r(p_data, p_size);
	uint32_t kind = 0;
	const std::string why = check_wire_header(r, content_hash(), kind);
	if (!why.empty()) {
		rep.batches_refused++;
		return refuse(rep, why);
	}
	if (kind != WK_RELIABLE && kind != WK_BASELINE) {
		rep.batches_refused++;
		return refuse(rep, "expected reliable records, got message kind " + std::to_string(kind));
	}
	const uint32_t seq = r.u32();
	const double clk = kind == WK_BASELINE ? r.f64() : 0.0;
	const uint32_t count = r.uvar();
	if (r.bad || count > r.left()) {  // a record is at least 2 bytes
		rep.batches_refused++;
		return refuse(rep, "damaged message (header)");
	}
	if (kind == WK_RELIABLE) {
		if (rep.need_baseline) {
			rep.batches_refused++;
			return refuse(rep, "waiting for a baseline: a reliable batch went missing earlier");
		}
		if (int32_t(seq - rep.last_seq) <= 0) {  // already applied (a baseline covered it, or the transport repeated it)
			rep.batches_duplicate++;
			return true;
		}
		if (seq != rep.last_seq + 1) {
			rep.need_baseline = true;
			rep.batches_refused++;
			return refuse(rep, "a reliable batch went missing (expected " + std::to_string(rep.last_seq + 1) + ", got " + std::to_string(seq) + "): ask the host for a baseline");
		}
	} else {
		clear_bodies();  // the baseline is the whole truth; the caller clears its own presentation first
		areas.clear();
		area_index.clear();
		reasons.resize(std::min(reasons.size(), sizeof(CORPSE_REASON_NAMES) / sizeof(CORPSE_REASON_NAMES[0])));
		rep.need_baseline = true;  // until it has been read to the end
	}
	for (uint32_t k = 0; k < count; k++) {
		std::string bad;
		if (!read_record(*this, r, bad)) {
			rep.need_baseline = true;
			rep.batches_refused++;
			return refuse(rep, bad);
		}
	}
	if (kind == WK_BASELINE) {
		clock = clk;
		rep.have_clock = true;
		rep.have_tick = false;  // the snapshot numbering may start over with the new world
		rep.need_baseline = false;
		rep.baselines_applied++;
	} else {
		rep.batches_applied++;
	}
	rep.last_seq = seq;
	return true;
}

} // namespace dm
