// The Bell Sanctum's and Plague Cloister's new kinds, as the old game's enemy kinds and states made them:
//   - the Weeping Seraph (dm_enemy_clst_seraph.gd): a hovering support body. Every cooldown it BLESSES (the `sanctified` status) up to WARD.maxTargets of the most wounded living
//     bodies within WARD.range, all at once, and with nobody to bless it casts the curse (dm_enemy_clst_caster.gd, the Lich Acolyte's: BLOW_CURSE, in world.cpp) from range, keeping
//     4 m away (the Deacon's walk, `engage` in world.cpp: dm_state_clst_kite.gd with [0, 0.5, 4, 0.7] is dm_state_cath_support.gd's numbers);
//   - the Plague Doctor (dm_enemy_clst_caster.gd, attack "flask"): the cloister casters' walk (silence-aware, as the Acolyte's) and a lobbed flask, BLOW_FLASK: a ring at the aim fixed
//     when the wind-up began (world.cpp begin_attack), then everything within PLAGUE_FLASK.radius of it is hit (kind toxic) and a toxic pool lingers (below);
//   - the Flagellant (flagellant.tscn, the plain dm_enemy.gd) needs nothing here: frenzy below FRENZY.atFrac of its health is the status set's (world.cpp step_statuses).
// Differences from the old game are noted in native/README.md.
#include "world.h"

#include <algorithm>

namespace dm {

namespace {

// Godot's Array.sort_custom (core/templates/sort_array.h, 4.7): an introsort that cuts ranges with a median-of-three pivot while they are longer than 16, falls back to a heap
// sort when it goes too deep, and ends in an insertion sort. It is not stable above 16 elements, and which of several allies at the same health fraction the ward reaches
// depends on exactly that order, so the sort is reproduced rather than replaced by std::sort (client/tests/core_kinds.gd compares it with the engine's own on random lists with ties).
template <class Less>
class GodotSort {
	static constexpr int64_t THRESHOLD = 16;
	Less less;
	int32_t *a;

	static int64_t bitlog(int64_t n) {
		int64_t k = 0;
		for (; n != 1; n >>= 1) {
			++k;
		}
		return k;
	}

	int32_t median_of_3(int32_t x, int32_t y, int32_t z) const {
		if (less(x, y)) {
			if (less(y, z)) {
				return y;
			} else if (less(x, z)) {
				return z;
			}
			return x;
		} else if (less(x, z)) {
			return x;
		} else if (less(y, z)) {
			return z;
		}
		return y;
	}

	void push_heap(int64_t first, int64_t hole, int64_t top, int32_t value) {
		int64_t parent = (hole - 1) / 2;
		while (hole > top && less(a[first + parent], value)) {
			a[first + hole] = a[first + parent];
			hole = parent;
			parent = (hole - 1) / 2;
		}
		a[first + hole] = value;
	}

	void adjust_heap(int64_t first, int64_t hole, int64_t len, int32_t value) {
		const int64_t top = hole;
		int64_t child = 2 * hole + 2;
		while (child < len) {
			if (less(a[first + child], a[first + (child - 1)])) {
				child--;
			}
			a[first + hole] = a[first + child];
			hole = child;
			child = 2 * (child + 1);
		}
		if (child == len) {
			a[first + hole] = a[first + (child - 1)];
			hole = child - 1;
		}
		push_heap(first, hole, top, value);
	}

	void pop_heap(int64_t first, int64_t last, int64_t result, int32_t value) {
		a[result] = a[first];
		adjust_heap(first, 0, last - first, value);
	}

	void make_heap(int64_t first, int64_t last) {
		if (last - first < 2) {
			return;
		}
		const int64_t len = last - first;
		int64_t parent = (len - 2) / 2;
		while (true) {
			adjust_heap(first, parent, len, a[first + parent]);
			if (parent == 0) {
				return;
			}
			parent--;
		}
	}

	void sort_heap(int64_t first, int64_t last) {
		while (last - first > 1) {
			pop_heap(first, last - 1, last - 1, a[last - 1]);
			last--;
		}
	}

	void partial_sort(int64_t first, int64_t last, int64_t middle) {
		make_heap(first, middle);
		for (int64_t i = middle; i < last; i++) {
			if (less(a[i], a[first])) {
				pop_heap(first, middle, i, a[i]);
			}
		}
		sort_heap(first, middle);
	}

	int64_t partitioner(int64_t first, int64_t last, int32_t pivot) {
		while (true) {
			while (less(a[first], pivot)) {
				first++;
			}
			last--;
			while (less(pivot, a[last])) {
				last--;
			}
			if (!(first < last)) {
				return first;
			}
			std::swap(a[first], a[last]);
			first++;
		}
	}

	void introsort(int64_t first, int64_t last, int64_t max_depth) {
		while (last - first > THRESHOLD) {
			if (max_depth == 0) {
				partial_sort(first, last, last);
				return;
			}
			max_depth--;
			const int64_t cut = partitioner(first, last, median_of_3(a[first], a[first + (last - first) / 2], a[last - 1]));
			introsort(cut, last, max_depth);
			last = cut;
		}
	}

	void unguarded_linear_insert(int64_t last, int32_t value) {
		int64_t next = last - 1;
		while (less(value, a[next])) {
			a[last] = a[next];
			last = next;
			next--;
		}
		a[last] = value;
	}

	void insertion_sort(int64_t first, int64_t last) {
		if (first == last) {
			return;
		}
		for (int64_t i = first + 1; i != last; i++) {
			const int32_t value = a[i];
			if (less(value, a[first])) {
				for (int64_t k = i; k > first; k--) {
					a[k] = a[k - 1];
				}
				a[first] = value;
			} else {
				unguarded_linear_insert(i, value);
			}
		}
	}

public:
	GodotSort(int32_t *p_array, Less p_less) :
			less(p_less), a(p_array) {}

	void sort(int64_t n) {
		if (n == 0) {
			return;
		}
		introsort(0, n, bitlog(n) * 2);
		if (n > THRESHOLD) {
			insertion_sort(0, THRESHOLD);
			for (int64_t i = THRESHOLD; i < n; i++) {
				unguarded_linear_insert(i, a[i]);
			}
		} else {
			insertion_sort(0, n);
		}
	}
};

} // namespace

// DmEnemyClstSeraph._physics_process, the part before the base's: the retry countdown runs every tick (the body acts), and when the cooldown is up, the retry is over and the
// body is not winding up, flinching, fallen or rising, and is not silenced, it looks for allies to bless. The cooldown it reads is the one the last tick left (the base's tick,
// which takes this tick's share off it, comes after).
void World::tick_ward(int32_t p_slot, double p_dt) {
	Enemy &e = enemies[p_slot];
	e.ward_t -= p_dt;
	if (e.attack_cd > 0.0 || e.ward_t > 0.0) {
		return;
	}
	if (e.state == ATTACK || e.state == HURT || e.state == DEAD || e.state == RISING) {
		return;
	}
	if (silenced(e)) {
		return;
	}
	ward(p_slot);
}

// DmEnemyClstSeraph._ward: every living body but itself within WARD.range (centre to centre, fallen, rising and underground bodies skipped, whatever its kind or health)
// that is not blessed already is a candidate; the most wounded first (Godot's sort, ties as it leaves them), up to WARD.maxTargets get `sanctified` from the seraph and a
// `sanctify` cue at their place, and the cooldown is spent. With no candidate it looks again in WARD_RETRY_S.
void World::ward(int32_t p_slot) {
	const double r2 = tun.ward_range * tun.ward_range;
	ward_scratch.clear();
	{
		const Enemy &e = enemies[p_slot];
		for (const Enemy &o : enemies) {  // the group `dm_enemy`: the whole table in spawn order (a body born this tick is rising, so it is skipped)
			if (o.id == e.id || o.state == DEAD || o.state == RISING || o.state == BURROW) {
				continue;
			}
			const float dx = o.x - e.x, dz = o.z - e.z;
			if (double(dx) * dx + double(dz) * dz > r2) {
				continue;
			}
			if (st_sanctified >= 0 && o.st.find(st_sanctified) >= 0) {
				continue;
			}
			ward_scratch.push_back(o.slot);
		}
	}
	if (ward_scratch.empty()) {
		enemies[p_slot].ward_t = WARD_RETRY_S;
		return;
	}
	const std::vector<Enemy> &table = enemies;
	auto wounded_first = [&table](int32_t x, int32_t y) { return table[size_t(x)].hp / table[size_t(x)].max_hp < table[size_t(y)].hp / table[size_t(y)].max_hp; };
	GodotSort<decltype(wounded_first)>(ward_scratch.data(), wounded_first).sort(int64_t(ward_scratch.size()));
	const int32_t n = std::min(int32_t(ward_scratch.size()), tun.ward_max);
	const int32_t src = enemies[p_slot].id;
	for (int32_t k = 0; k < n; k++) {
		Enemy &o = enemies[size_t(ward_scratch[size_t(k)])];
		apply_status(o, st_sanctified, src, 1.0, -1.0, 0.0, -1.0, 0.0);  // the rule's duration (SANCTIFIED.durationS)
		events.push(EV_CUE, src, { CUE_SANCTIFY }, { o.x, o.z, 0.0f });
	}
	enemies[p_slot].attack_cd = enemies[p_slot].cooldown_s;
}

// DmEnemyClstCaster.strike for a flask, at the end of the wind-up: every hero and thrall within PLAGUE_FLASK.radius of the aim fixed when the wind-up began takes the body's damage
// (hit kind toxic), then a toxic pool stays there for poolS, pulsing every second (DmHostileZone) for damage x poolDpsMult a second to whoever stands in it (radius + 0.45), and the
// flask's cue is told at the aim.
void World::strike_flask(Enemy &e) {
	const double r = tun.flask_r;
	const int32_t src = e.id;
	const float ax = e.aim_x, az = e.aim_z;
	const double dmg = e.damage;
	each_target([&](const Tgt &x) {
		if (flat_dist(ax, az, x.x, x.z) <= r) {
			hit_id(src, x.id, dmg, HK_TOXIC);
		}
	});
	Zone z;
	z.id = next_id++;
	z.kind = ZONE_TOXIC;
	z.source = src;
	z.hit_kind = HK_TOXIC;
	z.x = ax;
	z.z = az;
	z.radius = r;
	z.lifetime = tun.flask_pool_s;
	z.dps = dmg * tun.flask_pool_dps;
	zones.push_back(z);
	events.push(EV_ZONE, z.id, { z.kind, z.source }, { z.x, z.z, float(z.radius), float(z.lifetime) });
	events.push(EV_CUE, src, { CUE_FLASK }, { ax, az, float(r) });
}

} // namespace dm
