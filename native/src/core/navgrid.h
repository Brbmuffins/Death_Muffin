#pragma once
// The navmesh's polygons (as triangles) on a uniform XZ grid, for the per-tick "keep to the navmesh" step: a point inside an enabled polygon stays, a point
// outside moves to the closest point of the nearest one. That is what NavigationServer3D.map_get_closest_point answers on these flat navmeshes, without
// walking every polygon of the map (its cost grew with every area loaded). Regions switch on and off with the world's seals and doors.
#include <cstdint>
#include <vector>

namespace dm {

struct NavGrid {
	struct Tri {
		float ax, az, bx, bz, cx, cz;
		int32_t region;
	};

	float cell = 2.0f;
	float min_x = 0, min_z = 0;
	int32_t nx = 0, nz = 0;
	std::vector<Tri> tris;
	std::vector<int32_t> start;  // nx * nz + 1 prefix offsets into items
	std::vector<int32_t> items;  // triangle indices by cell
	std::vector<uint8_t> region_on;
	bool dirty = false;

	// One region's polygons: `xz` = its vertices (x, z pairs, world space), `polys` = [n, i0 .. i(n-1), n, ...] (convex polygons, fanned into triangles).
	// Returns the region's index.
	int32_t add_region(const float *p_xz, int32_t p_vertex_count, const int32_t *p_polys, int32_t p_poly_ints, bool p_enabled);
	// Gives an existing region new polygons (a Depths floor changing: the old floor's triangles go, nothing piles up); empty polygons empty it. False for an unknown region.
	bool replace_region(int32_t p_region, const float *p_xz, int32_t p_vertex_count, const int32_t *p_polys, int32_t p_poly_ints, bool p_enabled);
	void set_enabled(int32_t p_region, bool p_enabled);
	void clear();
	bool empty() const { return tris.empty(); }
	// The closest point of an enabled triangle to (x, z), written back; true when one exists (else x, z are unchanged).
	bool clamp(float &r_x, float &r_z);
	int32_t triangle_count() const { return int32_t(tris.size()); }

private:
	void append_region(int32_t p_region, const float *p_xz, int32_t p_vertex_count, const int32_t *p_polys, int32_t p_poly_ints);
	void rebuild();
	int32_t cell_x(float p_x) const;
	int32_t cell_z(float p_z) const;
};

} // namespace dm
