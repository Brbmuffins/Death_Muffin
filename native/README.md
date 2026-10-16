# The combat core (C++)

A GDExtension that will own every enemy and thrall of the rebuilt client in flat arrays and step them once per 60 Hz tick (ROADMAP
"Now: the rebuild", DECISIONS B34). Prep stage: `DmCore` only proves the build, the load and a call across the boundary
(`client/tests/core_smoke.gd`).

- `native/src/`: the core. `register_types.cpp` registers the classes; entry symbol `dmcore_library_init` (`client/bin/dmcore.gdextension`).
- `SConstruct`: builds into `client/bin/libdmcore.<platform>.<target>.<arch>.<ext>`.
- `build.sh`: fetches godot-cpp into `thirdparty/` (not committed) at the pinned commit (1e79263, built for `api_version=4.7`) and builds
  Linux `template_debug` (what the headless tests load) and Windows `template_release` (the test build; mingw-w64, C++ runtime linked
  statically so players need no extra files). Runs at `nice -n 10` with 4 jobs; the first build of godot-cpp takes about 6 minutes, later
  builds only recompile what changed.

## Build machine (the VPS)

`g++` (system), SCons 4.11 (`python3 -m pip install --user scons`, `~/.local/bin/scons`) and `mingw-w64` (apt) switched to the posix
thread model (`update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix`, same for `gcc`), which the C++
standard thread types need.
