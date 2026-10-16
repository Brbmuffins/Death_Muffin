#pragma once
// Byte buffers for the co-op wire format (native/README.md "Co-op"): little-endian fixed-width numbers and LEB128 varints. The writer appends to a
// vector the caller keeps and reuses (no allocation once it has grown). The reader never reads past its end: a short or damaged message sets `bad`
// and every later read returns 0, so a decoder checks `bad` once at the end of a record.
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace dm {

struct ByteWriter {
	std::vector<uint8_t> &b;
	explicit ByteWriter(std::vector<uint8_t> &p_buf) : b(p_buf) {}
	void u8(uint32_t v) { b.push_back(uint8_t(v)); }
	void u16(uint32_t v) {
		b.push_back(uint8_t(v));
		b.push_back(uint8_t(v >> 8));
	}
	void u32(uint32_t v) {
		for (int i = 0; i < 4; i++) {
			b.push_back(uint8_t(v >> (8 * i)));
		}
	}
	void f32(float v) {
		uint32_t u;
		std::memcpy(&u, &v, 4);
		u32(u);
	}
	void f64(double v) {
		uint64_t u;
		std::memcpy(&u, &v, 8);
		u32(uint32_t(u));
		u32(uint32_t(u >> 32));
	}
	void uvar(uint32_t v) {  // 7 bits per byte, low group first, the high bit says "more"
		while (v >= 0x80) {
			b.push_back(uint8_t(v | 0x80));
			v >>= 7;
		}
		b.push_back(uint8_t(v));
	}
	void svar(int32_t v) { uvar((uint32_t(v) << 1) ^ uint32_t(v >> 31)); }  // zigzag: 0, -1, 1, -2 ... -> 0, 1, 2, 3 ...
	void bytes(const uint8_t *p, size_t n) { b.insert(b.end(), p, p + n); }
};

struct ByteReader {
	const uint8_t *p;
	size_t n, i = 0;
	bool bad = false;
	ByteReader(const uint8_t *p_data, size_t p_size) : p(p_data), n(p_size) {}
	size_t left() const { return n - i; }
	uint32_t u8() {
		if (i + 1 > n) {
			bad = true;
			return 0;
		}
		return p[i++];
	}
	uint32_t u16() {
		if (i + 2 > n) {
			bad = true;
			i = n;
			return 0;
		}
		const uint32_t v = uint32_t(p[i]) | (uint32_t(p[i + 1]) << 8);
		i += 2;
		return v;
	}
	uint32_t u32() {
		if (i + 4 > n) {
			bad = true;
			i = n;
			return 0;
		}
		const uint32_t v = uint32_t(p[i]) | (uint32_t(p[i + 1]) << 8) | (uint32_t(p[i + 2]) << 16) | (uint32_t(p[i + 3]) << 24);
		i += 4;
		return v;
	}
	float f32() {
		const uint32_t u = u32();
		float v;
		std::memcpy(&v, &u, 4);
		return v;
	}
	double f64() {
		const uint64_t lo = u32();
		const uint64_t hi = u32();
		const uint64_t u = lo | (hi << 32);
		double v;
		std::memcpy(&v, &u, 8);
		return v;
	}
	uint32_t uvar() {
		uint32_t v = 0;
		for (int shift = 0; shift < 35; shift += 7) {
			const uint32_t c = u8();
			if (bad) {
				return 0;
			}
			v |= (c & 0x7f) << shift;
			if (!(c & 0x80)) {
				return v;
			}
		}
		bad = true;  // more than 5 bytes: not one of ours
		return 0;
	}
	int32_t svar() {
		const uint32_t u = uvar();
		return int32_t(u >> 1) ^ -int32_t(u & 1);
	}
	const uint8_t *take(size_t count) {
		if (i + count > n) {
			bad = true;
			i = n;
			return nullptr;
		}
		const uint8_t *r = p + i;
		i += count;
		return r;
	}
};

} // namespace dm
