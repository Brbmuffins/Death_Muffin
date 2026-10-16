#pragma once
// Statuses on one body: a port of DmStatusSet (godot/next/status/dm_status_set.gd). One step per 0.1 s of accumulated time (the step's dt is
// the whole accumulator, so 7 ticks = 0.1167 s at 60 Hz), damage over time paid in 0.25 s lumps, records kept in insertion order (today's
// Dictionary order decides DoT lumps and expiry order). The rule table comes from GDScript (DmCore.load_status_defs), built from the same
// data files DmStatusSet.warm() reads, so no number is retyped here.
#include <cstdint>
#include <string>
#include <vector>

namespace dm {

constexpr int STATUS_MAX = 16;
constexpr double STATUS_TICK_S = 0.1, STATUS_FLUSH_S = 0.25, STATUS_FOREVER = 1.0e9;

struct StatusRule {  // DmStatusSet._defs entry
	std::string name;
	double dur = 0, move = 1, atk = 1, taken = 1, dealt = 1, tps = 0, max = 1.0e6;
	bool slow = false, root = false, dot = false, stack = false, bleed = false, barrier = false;
};

struct StatusRec {
	int32_t id = 0, src = 0;
	double stk = 0, rem = 0, val = 0, acc = 0;
};

struct StatusSet {
	StatusRec rec[STATUS_MAX];
	int32_t n = 0;
	double acc = 0, flush_t = 0;
	double move = 1, atk = 1, taken = 1, dealt = 1;

	int32_t find(int32_t p_id) const {
		for (int32_t i = 0; i < n; i++) {
			if (rec[i].id == p_id) {
				return i;
			}
		}
		return -1;
	}
	bool erase(int32_t p_id) {  // keeps insertion order
		const int32_t i = find(p_id);
		if (i < 0) {
			return false;
		}
		for (int32_t k = i; k < n - 1; k++) {
			rec[k] = rec[k + 1];
		}
		n--;
		return true;
	}
	void recompute(const std::vector<StatusRule> &p_rules) {  // DmStatusSet._recompute
		double slow = 1.0, mv = 1.0, at = 1.0, tk = 1.0, dl = 1.0;
		bool rooted = false;
		for (int32_t i = 0; i < n; i++) {
			const StatusRule &d = p_rules[rec[i].id];
			if (d.slow) {
				slow = d.move < slow ? d.move : slow;
			} else {
				mv *= d.move;
			}
			rooted = rooted || d.root;
			at *= d.atk;
			tk *= d.taken;
			dl *= d.dealt;
			if (d.tps != 0.0) {
				tk *= 1.0 + d.tps * rec[i].stk;
			}
		}
		move = rooted ? 0.0 : mv * slow;
		atk = at;
		taken = tk;
		dealt = dl;
	}
};

} // namespace dm
