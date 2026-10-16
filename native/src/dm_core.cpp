#include "dm_core.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void DmCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("version"), &DmCore::version);
	ClassDB::bind_method(D_METHOD("checksum", "count"), &DmCore::checksum);
}

String DmCore::version() const {
	return "dmcore 0.1";
}

// Sum of 0..count-1: a call with an argument and a result, checked by client/tests/core_smoke.gd.
int64_t DmCore::checksum(int64_t p_count) const {
	int64_t total = 0;
	for (int64_t i = 0; i < p_count; i++) {
		total += i;
	}
	return total;
}
