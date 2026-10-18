// The combat core's crash note (native/README.md "Crash notes"). When the game crashes, a short plain-text file names, for each stack
// frame, the module and the offset into it, which Godot's own crash log cannot (it prints "???" for code it has no symbols for). The client
// puts the note into its next automatic crash report (DmCrashWatch); tools/crash/symbolize.mjs turns the core's offsets into source lines
// with the symbols kept for that build.
#pragma once

#include <cstddef>
#include <cstdint>

namespace dm::crash {

struct Frame {
	const char *module = "";  // the module's file name (UTF-8), "?" when unknown
	uint64_t offset = 0;      // the frame's address minus the module's load address
};

// Arms the note: `path` is the file it is written to (absolute, UTF-8), `build` names the game build. Windows: an unhandled-exception filter
// chained to the one already set (Godot's crash handler runs right after it). Linux (headless tests): handlers for SIGSEGV, SIGBUS, SIGFPE and
// SIGILL that write the note and hand the signal on to the handler that was there. A second call only changes the path and the build.
void arm(const char *path, const char *build);

// Writes one note into `out` (at most `cap` bytes, always terminated) and returns its length. No allocation: safe while crashing.
size_t format_note(char *out, size_t cap, const char *build, const char *what, const Frame *frames, int count);

// The tests' crash: a write to an invalid address from inside the core.
void crash_now();

}  // namespace dm::crash
