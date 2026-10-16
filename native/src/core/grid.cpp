#include "grid.h"

#include <algorithm>
#include <cmath>

namespace dm {

void Grid::set_bounds(float p_min_x, float p_min_z, float p_max_x, float p_max_z, float p_cell) {
	cell = p_cell > 0.5f ? p_cell : 0.5f;
	min_x = p_min_x;
	min_z = p_min_z;
	nx = std::max(1, int32_t(std::ceil((p_max_x - p_min_x) / cell)));
	nz = std::max(1, int32_t(std::ceil((p_max_z - p_min_z) / cell)));
	start.assign(size_t(nx) * size_t(nz) + 1, 0);
}

int32_t Grid::cell_index(float p_x, float p_z) const {
	// Anything outside the bounds is clamped into the edge cells, so it is still found.
	const int32_t cx = std::clamp(int32_t(std::floor((p_x - min_x) / cell)), 0, nx - 1);
	const int32_t cz = std::clamp(int32_t(std::floor((p_z - min_z) / cell)), 0, nz - 1);
	return cz * nx + cx;
}

void Grid::rebuild(const float *p_x, const float *p_z, int32_t p_count) {
	const size_t cells = size_t(nx) * size_t(nz);
	if (start.size() != cells + 1) {
		start.assign(cells + 1, 0);
	} else {
		std::fill(start.begin(), start.end(), 0);
	}
	if (cell_of.size() < size_t(p_count)) {
		cell_of.resize(p_count);
	}
	items.resize(p_count);
	for (int32_t i = 0; i < p_count; i++) {
		cell_of[i] = cell_index(p_x[i], p_z[i]);
		start[cell_of[i] + 1]++;
	}
	for (size_t c = 0; c < cells; c++) {
		start[c + 1] += start[c];
	}
	// Fill in ascending slot order, so every cell lists its slots ascending.
	cursor.assign(start.begin(), start.end() - 1);
	for (int32_t i = 0; i < p_count; i++) {
		items[cursor[cell_of[i]]++] = i;
	}
}

void Grid::query(float p_x, float p_z, float p_r, std::vector<int32_t> &out) {
	out.clear();
	const int32_t x0 = std::clamp(int32_t(std::floor((p_x - p_r - min_x) / cell)), 0, nx - 1);
	const int32_t x1 = std::clamp(int32_t(std::floor((p_x + p_r - min_x) / cell)), 0, nx - 1);
	const int32_t z0 = std::clamp(int32_t(std::floor((p_z - p_r - min_z) / cell)), 0, nz - 1);
	const int32_t z1 = std::clamp(int32_t(std::floor((p_z + p_r - min_z) / cell)), 0, nz - 1);
	for (int32_t cz = z0; cz <= z1; cz++) {
		for (int32_t cx = x0; cx <= x1; cx++) {
			const int32_t c = cz * nx + cx;
			for (int32_t k = start[c]; k < start[c + 1]; k++) {
				out.push_back(items[k]);
			}
		}
	}
	std::sort(out.begin(), out.end());
}

} // namespace dm
