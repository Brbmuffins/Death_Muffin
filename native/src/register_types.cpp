// Registers the Death Muffin combat core (DmCore), the crowd (DmCrowd) and the particle ring's loop (DmMotes) with Godot. Entry symbol: dmcore_library_init (client/bin/dmcore.gdextension).
#include "register_types.h"

#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "dm_core.h"
#include "dm_crowd.h"
#include "dm_motes.h"

using namespace godot;

void initialize_dmcore_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(DmCore);
	GDREGISTER_CLASS(DmCrowd);
	GDREGISTER_CLASS(DmMotes);
}

void uninitialize_dmcore_module(ModuleInitializationLevel p_level) {
}

extern "C" {
GDExtensionBool GDE_EXPORT dmcore_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_dmcore_module);
	init_obj.register_terminator(uninitialize_dmcore_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
