#pragma once
// PCG32 (O'Neill), one stream per entity, so a seeded scenario replays bit for bit (native/README.md "Design").
#include <cstdint>

namespace dm {

struct Rng {
	uint64_t state = 0x853c49e6748fea9bULL;
	uint64_t inc = 0xda3e39cb94b95bdbULL;

	void seed(uint64_t p_seed, uint64_t p_stream) {
		state = 0;
		inc = (p_stream << 1u) | 1u;
		next_u32();
		state += p_seed;
		next_u32();
	}
	uint32_t next_u32() {
		const uint64_t old = state;
		state = old * 6364136223846793005ULL + inc;
		const uint32_t xorshifted = uint32_t(((old >> 18u) ^ old) >> 27u);
		const uint32_t rot = uint32_t(old >> 59u);
		return (xorshifted >> rot) | (xorshifted << ((-rot) & 31u));
	}
	// [0, 1), like GDScript's randf().
	double next_double() { return next_u32() * (1.0 / 4294967296.0); }
};

} // namespace dm
