#include "navgrid.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace dm {

namespace {

constexpr float INSIDE_EPS = 1e-6f;

inline float cross(float p_ax, float p_az, float p_bx, float p_bz) {
	return p_ax * p_bz - p_az * p_bx;
}

bool inside(const NavGrid::Tri &p_t, float p_x, float p_z) {
	const float d1 = cross(p_t.bx - p_t.ax, p_t.bz - p_t.az, p_x - p_t.ax, p_z - p_t.az);
	const float d2 = cross(p_t.cx - p_t.bx, p_t.cz - p_t.bz, p_x - p_t.bx, p_z - p_t.bz);
	const float d3 = cross(p_t.ax - p_t.cx, p_t.az - p_t.cz, p_x - p_t.cx, p_z - p_t.cz);
	const bool neg = d1 < -INSIDE_EPS || d2 < -INSIDE_EPS || d3 < -INSIDE_EPS;
	const bool pos = d1 > INSIDE_EPS || d2 > INSIDE_EPS || d3 > INSIDE_EPS;
	return !(neg && pos);
}

// The closest point of segment (a, b) to p, and its squared distance.
float seg_closest(float p_ax, float p_az, float p_bx, float p_bz, float p_x, float p_z, float &r_x, float &r_z) {
	const float dx = p_bx - p_ax, dz = p_bz - p_az;
	const float len2 = dx * dx + dz * dz;
	float t = len2 > 0.0f ? ((p_x - p_ax) * dx + (p_z - p_az) * dz) / len2 : 0.0f;
	t = std::clamp(t, 0.0f, 1.0f);
	r_x = p_ax + dx * t;
	r_z = p_az + dz * t;
	const float ex = p_x - r_x, ez = p_z - r_z;
	return ex * ex + ez * ez;
}

} // namespace

int32_t NavGrid::add_region(const float *p_xz, int32_t p_vertex_count, const int32_t *p_polys, int32_t p_poly_ints, bool p_enabled) {
	const int32_t region = int32_t(region_on.size());
	region_on.push_back(p_enabled ? 1 : 0);
	int32_t i = 0;
	while (i < p_poly_ints) {
		const int32_t n = p_polys[i];
		if (n < 3 || i + n >= p_poly_ints) {
			break;
		}
		const int32_t *v = p_polys + i + 1;
		bool ok = true;
		for (int32_t k = 0; k < n; k++) {
			ok = ok && v[k] >= 0 && v[k] < p_vertex_count;
		}
		if (ok) {
			for (int32_t k = 1; k + 1 < n; k++) {  // a fan over the convex polygon
				tris.push_back({p_xz[v[0] * 2], p_xz[v[0] * 2 + 1], p_xz[v[k] * 2], p_xz[v[k] * 2 + 1], p_xz[v[k + 1] * 2], p_xz[v[k + 1] * 2 + 1], region});
			}
		}
		i += n + 1;
	}
	dirty = true;
	return region;
}

void NavGrid::set_enabled(int32_t p_region, bool p_enabled) {
	if (p_region >= 0 && p_region < int32_t(region_on.size())) {
		region_on[size_t(p_region)] = p_enabled ? 1 : 0;
	}
}

void NavGrid::clear() {
	tris.clear();
	start.clear();
	items.clear();
	region_on.clear();
	nx = nz = 0;
	dirty = false;
}

int32_t NavGrid::cell_x(float p_x) const {
	return std::clamp(int32_t(std::floor((p_x - min_x) / cell)), 0, nx - 1);
}

int32_t NavGrid::cell_z(float p_z) const {
	return std::clamp(int32_t(std::floor((p_z - min_z) / cell)), 0, nz - 1);
}

void NavGrid::rebuild() {
	dirty = false;
	if (tris.empty()) {
		nx = nz = 0;
		return;
	}
	float lo_x = std::numeric_limits<float>::max(), lo_z = lo_x;
	float hi_x = std::numeric_limits<float>::lowest(), hi_z = hi_x;
	for (const Tri &t : tris) {
		lo_x = std::min({lo_x, t.ax, t.bx, t.cx});
		lo_z = std::min({lo_z, t.az, t.bz, t.cz});
		hi_x = std::max({hi_x, t.ax, t.bx, t.cx});
		hi_z = std::max({hi_z, t.az, t.bz, t.cz});
	}
	min_x = lo_x - cell;  // one empty cell all round: a body just off the mesh still falls inside the grid
	min_z = lo_z - cell;
	nx = int32_t(std::ceil((hi_x + cell - min_x) / cell)) + 1;
	nz = int32_t(std::ceil((hi_z + cell - min_z) / cell)) + 1;
	start.assign(size_t(nx) * size_t(nz) + 1, 0);
	auto span = [this](const Tri &t, int32_t &x0, int32_t &x1, int32_t &z0, int32_t &z1) {
		x0 = cell_x(std::min({t.ax, t.bx, t.cx}));
		x1 = cell_x(std::max({t.ax, t.bx, t.cx}));
		z0 = cell_z(std::min({t.az, t.bz, t.cz}));
		z1 = cell_z(std::max({t.az, t.bz, t.cz}));
	};
	int32_t x0, x1, z0, z1;
	for (const Tri &t : tris) {
		span(t, x0, x1, z0, z1);
		for (int32_t z = z0; z <= z1; z++) {
			for (int32_t x = x0; x <= x1; x++) {
				start[size_t(z * nx + x) + 1]++;
			}
		}
	}
	for (size_t c = 1; c < start.size(); c++) {
		start[c] += start[c - 1];
	}
	items.assign(size_t(start.back()), 0);
	std::vector<int32_t> fill(start.begin(), start.end() - 1);
	for (int32_t i = 0; i < int32_t(tris.size()); i++) {
		span(tris[size_t(i)], x0, x1, z0, z1);
		for (int32_t z = z0; z <= z1; z++) {
			for (int32_t x = x0; x <= x1; x++) {
				items[size_t(fill[size_t(z * nx + x)]++)] = i;
			}
		}
	}
}

bool NavGrid::clamp(float &r_x, float &r_z) {
	if (dirty) {
		rebuild();
	}
	if (tris.empty()) {
		return false;
	}
	const float px = r_x, pz = r_z;
	float best = std::numeric_limits<float>::max(), bx = px, bz = pz;
	const bool in_box = px >= min_x && pz >= min_z && px < min_x + float(nx) * cell && pz < min_z + float(nz) * cell;
	const int32_t cx = cell_x(px), cz = cell_z(pz);
	const int32_t rings = in_box ? std::max(nx, nz) : 0;
	auto visit = [&](int32_t p_cell) -> bool {  // true = p lies inside an enabled triangle
		for (int32_t k = start[size_t(p_cell)]; k < start[size_t(p_cell) + 1]; k++) {
			const Tri &t = tris[size_t(items[size_t(k)])];
			if (!region_on[size_t(t.region)]) {
				continue;
			}
			if (inside(t, px, pz)) {
				return true;
			}
			float qx, qz;
			const float edges[3][4] = {{t.ax, t.az, t.bx, t.bz}, {t.bx, t.bz, t.cx, t.cz}, {t.cx, t.cz, t.ax, t.az}};
			for (const auto &e : edges) {
				const float d = seg_closest(e[0], e[1], e[2], e[3], px, pz, qx, qz);
				if (d < best) {
					best = d;
					bx = qx;
					bz = qz;
				}
			}
		}
		return false;
	};
	if (!in_box) {  // far off the mesh (never in play): every cell
		for (int32_t c = 0; c < nx * nz; c++) {
			if (visit(c)) {
				return true;
			}
		}
	} else {
		for (int32_t r = 0; r <= rings; r++) {
			for (int32_t z = cz - r; z <= cz + r; z++) {
				if (z < 0 || z >= nz) {
					continue;
				}
				const bool edge_row = z == cz - r || z == cz + r;
				for (int32_t x = cx - r; x <= cx + r; x += (edge_row || r == 0) ? 1 : 2 * r) {
					if (x >= 0 && x < nx && visit(z * nx + x)) {
						return true;
					}
				}
			}
			// Every cell past ring r lies at least r cells from p (p is inside the centre cell): nothing there is nearer than `best` once best <= r * cell.
			const float bound = float(r) * cell;
			if (best <= bound * bound) {
				break;
			}
		}
	}
	if (best == std::numeric_limits<float>::max()) {
		return false;
	}
	r_x = bx;
	r_z = bz;
	return true;
}

} // namespace dm
