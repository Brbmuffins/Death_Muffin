#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

// The combat core: owns every enemy and thrall in flat arrays and steps them once per 60 Hz tick (ROADMAP "Now: the rebuild").
// Prep stage: only proves the build, the load and a call across the boundary.
class DmCore : public godot::RefCounted {
	GDCLASS(DmCore, godot::RefCounted)

protected:
	static void _bind_methods();

public:
	godot::String version() const;
	int64_t checksum(int64_t p_count) const;
};
