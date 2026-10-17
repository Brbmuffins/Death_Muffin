#pragma once
// DmMotes: the per-frame loop of today's CPU particle ring (client/fx/dm_fx_ring.gd, a port of godot/fx/dm_fx_ring.gd and Effects.ts ParticleSystem) in C++.
// The ring's motes live here as flat arrays; `emit` makes a burst's motes (each one's random start from the global generator, drawn in the order DmFxRing.emit drew them in
// GDScript, so the stream and every number are today's: client/tests/fx_motes.gd) and DmFxRing (GDScript) owns the MultiMeshes. `step` ages, moves and fades every live mote exactly as the GDScript loop did (the same double-precision arithmetic, stored as
// floats) and writes the instance buffer of the ring that is drawn; `upload` hands it to the RenderingServer.
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector3.hpp>

class DmMotes : public godot::RefCounted {
	GDCLASS(DmMotes, godot::RefCounted)

	int32_t capacity = 0;
	int32_t small_cap = 0;
	int32_t cursor = 0;
	int32_t live = 0;
	std::vector<float> pos, vel, col, life, inv_life, base_size, grav, drag, shrink;
	std::vector<int32_t> list;  // indices of live motes, in the order they came alive (compacted in place)
	godot::PackedFloat32Array buf_full, buf_small;  // 16 floats a mote (3x4 transform + colour); the off-diagonal slots stay 0

protected:
	static void _bind_methods();

public:
	void setup(int32_t p_capacity, int32_t p_small_cap);
	int64_t emit(const godot::Dictionary &p_o);   // the motes made (0 for a count of 0 or less)
	void put(const godot::Vector3 &p_pos, const godot::Vector3 &p_vel, const godot::Color &p_color, double p_life, double p_size, double p_gravity, double p_drag, double p_shrink);
	int32_t active() const { return live; }
	int32_t step(double p_dt, bool p_small);
	void upload(const godot::RID &p_multimesh, bool p_small);
	godot::PackedFloat32Array buffer(bool p_small) const { return p_small ? buf_small : buf_full; }
};
