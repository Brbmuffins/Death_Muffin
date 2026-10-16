#pragma once
// The co-op wire format and the bookkeeping behind it (native/README.md "Co-op"): the numbers the host's writers (snapshot.cpp, reliable.cpp) and
// the guest's readers (snapshot.cpp, reliable.cpp, puppet.cpp) share. The host simulates; a guest's core is a puppet that shows what it is told.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "body.h"
#include "wire.h"

namespace dm {

constexpr uint8_t WIRE_MAGIC0 = 'D', WIRE_MAGIC1 = 'M';
// Bump when any layout in native/README.md "Co-op" changes: a build with another number refuses the message and says which side is behind (DECISIONS B40).
constexpr uint8_t WIRE_VERSION = 1;
enum WireKind : uint8_t { WK_SNAPSHOT = 1, WK_RELIABLE = 2, WK_BASELINE = 3 };
constexpr size_t WIRE_HEADER = 8;  // magic (2), kind, version, content hash (4)

// Records that exist only on the wire (the event numbers 1..32 are the events GDScript reads, events.h).
enum WireRecord : uint8_t {
	WR_NAME = 101,          // a string table entry: table (NameTable), index, length, bytes
	WR_THRALL_MAX_HP = 102, // id, max hp (f32): set_thrall_stats changed a thrall's maximum
};
enum NameTable : uint8_t { NT_AREA = 0, NT_REASON = 1 };

// Snapshot packing.
constexpr double POS_QUANTUM = 0.01;  // metres: int16 offsets from the area's centre cover +-327 m
constexpr uint32_t HP_ONE = 65535;    // health is a fraction of the maximum, 1..65535 while alive
constexpr uint32_t T_SATURATED = 255; // time in state in centiseconds; 255 = 2.55 s or more
// Enemy record flag byte: bits 0..3 state, then elite, dug in, has aim, has affix byte. Thrall: bits 0..2 state, rally, has aim.
constexpr uint32_t EF_ELITE = 0x10, EF_DUG_IN = 0x20, EF_AIM = 0x40, EF_AFFIXES = 0x80;
constexpr uint32_t TF_RALLY = 0x08, TF_AIM = 0x10;

// The puppet (today's puppets, dm_enemy.gd _puppet_step): exponential easing toward the last snapshot, a snap above 6 m, a speed smoothed at 10/s.
constexpr double PUPPET_EASE = 15.0, PUPPET_SPEED_RATE = 10.0, PUPPET_TELEPORT_SQ = 36.0, PUPPET_MIN_SPEED = 0.3;
constexpr double PUPPET_MIN_TELL_S = 0.05;   // dm_enemy.gd: announce_telegraph(maxf(0.05, windup_s - net_age))
constexpr double PUPPET_T_RESYNC_S = 0.1;    // the time in state is taken from a snapshot only when it is this far from the guest's own count
// What a guest accepts from the wire (a damaged or hostile message cannot make it grow without bound).
constexpr size_t PUPPET_MAX_ENEMIES = 4096, PUPPET_MAX_THRALLS = 1024, PUPPET_MAX_CORPSES = 512;
// A host that keeps collecting reliable events and never takes them (a guest left, set_replication(false) was forgotten) drops them at this size and
// skips a batch number, so a guest that is still listening sees the gap and asks for a baseline.
constexpr size_t REL_MAX_BYTES = 1 << 20;

struct Replica {
	// ---- host
	bool replicating = false;       // set_replication(true): the reliable events are being collected
	size_t ev_i = 0, ev_f = 0;      // how far into the event buffer the reliable encoder has read (take_events clears the buffer and zeroes these)
	uint32_t seq = 0;               // the number of the last reliable batch handed out
	std::vector<uint8_t> rel;       // records waiting for take_reliable()
	std::vector<uint8_t> base;      // scratch for write_baseline()
	std::vector<std::vector<uint8_t>> sealed;  // batches closed by write_baseline(), handed out by take_reliable() before anything newer
	uint32_t rel_count = 0;
	size_t areas_sent = 0, reasons_sent = 0;  // string table entries already in `rel` or sent
	// ---- guest
	bool have_tick = false;
	uint32_t last_tick = 0;
	uint32_t last_seq = 0;
	bool need_baseline = false;     // a reliable batch went missing: nothing more is applied until a baseline arrives
	bool have_clock = false;
	// ---- both
	std::string error;              // why the last apply_* said false ("" after a success)
	// counters (DmCore.replication_stats)
	uint64_t snapshots_built = 0, snapshot_frames = 0, batches_built = 0, records_built = 0, reliable_bytes = 0, positions_clamped = 0, overflows = 0;
	uint64_t snapshots_applied = 0, snapshots_stale = 0, snapshots_refused = 0, records_unknown = 0, records_dead = 0, desync = 0;
	uint64_t batches_applied = 0, batches_duplicate = 0, batches_refused = 0, baselines_applied = 0, events_derived = 0, commands_refused = 0;
	void reset_host() {
		replicating = false;
		ev_i = ev_f = 0;
		seq = 0;
		rel.clear();
		rel_count = 0;
		sealed.clear();
		areas_sent = reasons_sent = 0;
	}
	void reset_guest() {
		have_tick = false;
		last_tick = 0;
		last_seq = 0;
		need_baseline = false;
		have_clock = false;
	}
};

// One decoded snapshot record, positions already in metres (an enemy's flags byte or a thrall's).
struct SnapRec {
	int32_t id = 0, state = 0;
	bool elite = false, dug_in = false, rally = false, has_aim = false;
	uint32_t affixes = 0, hpq = HP_ONE, t = 0, swing = 0;
	float x = 0, z = 0, yaw = 0, aim_x = 0, aim_z = 0;
};

// Quantizers shared by the snapshot and the reliable spawn tails.
inline int32_t q_pos(double p_v, double p_origin, uint64_t &r_clamped) {
	const long q = std::lround((p_v - p_origin) / POS_QUANTUM);
	if (q > 32767 || q < -32768) {
		r_clamped++;
		return q > 0 ? 32767 : -32768;
	}
	return int32_t(q);
}
inline uint32_t q_yaw(float p_yaw) {  // 256 steps of a full turn (1.4 degrees)
	double a = std::fmod(double(p_yaw), TAU);
	if (a < 0.0) {
		a += TAU;
	}
	return uint32_t(std::lround(a / TAU * 256.0)) & 255u;
}
inline float d_yaw(uint32_t p_b) {  // [-pi, pi), the range the host's atan2 gives
	return float((p_b >= 128u ? double(p_b) - 256.0 : double(p_b)) * (TAU / 256.0));
}
inline uint32_t q_hp(double p_hp, double p_max) {  // 1..65535 while alive, so a living body never rounds to "dead"
	if (!(p_hp > 0.0)) {
		return 0;
	}
	const double f = p_max > 0.0 ? p_hp / p_max : 1.0;
	return uint32_t(std::clamp<long>(std::lround(f * HP_ONE), 1, long(HP_ONE)));
}
inline uint32_t q_t(double p_t) {  // centiseconds, saturating
	return uint32_t(std::clamp<long>(std::lround(p_t * 100.0), 0, long(T_SATURATED)));
}

// The part of a spawn record that says what the body is doing now (the event itself carries the spawn-time facts).
struct WireTail {
	uint32_t state = 0, hpq = HP_ONE, yaw = 0, t = 0, swing = 0;
	bool rally = false;
};

// Why a header is refused, in words a player can act on (empty when it is fine); the kind it carries comes back in r_kind.
std::string check_wire_header(ByteReader &r, uint32_t p_hash, uint32_t &r_kind);

inline void write_wire_header(ByteWriter &w, uint8_t p_kind, uint32_t p_hash) {
	w.u8(WIRE_MAGIC0);
	w.u8(WIRE_MAGIC1);
	w.u8(p_kind);
	w.u8(WIRE_VERSION);
	w.u32(p_hash);
}

} // namespace dm
