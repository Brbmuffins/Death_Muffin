#pragma once
// Dense uniform grid over the current area's XZ bounds, rebuilt every tick by counting sort: no allocation after the first rebuild at
// a given size. Queries return candidate slots in ascending slot order (= spawn order); callers apply the exact distance test.
#include <cstdint>
#include <vector>

namespace dm {

struct Grid {
	float min_x = -64.0f, min_z = -64.0f, cell = 4.0f;
	int32_t nx = 32, nz = 32;
	std::vector<int32_t> start;  // nx * nz + 1 prefix offsets
	std::vector<int32_t> items;  // slots sorted by cell
	std::vector<int32_t> cell_of;  // per slot, its cell
	std::vector<int32_t> cursor;   // fill positions during a rebuild

	void set_bounds(float p_min_x, float p_min_z, float p_max_x, float p_max_z, float p_cell);
	void rebuild(const float *p_x, const float *p_z, int32_t p_count);
	// Slots whose cell overlaps the circle (x, z, r + pad), ascending. `out` is cleared first.
	void query(float p_x, float p_z, float p_r, std::vector<int32_t> &out);

private:
	int32_t cell_index(float p_x, float p_z) const;
};

} // namespace dm
