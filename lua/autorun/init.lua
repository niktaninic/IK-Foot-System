AddCSLuaFile("autorun/ik_foot.lua")
AddCSLuaFile("autorun/client/cl_ik_foot_gui.lua")
AddCSLuaFile("ik_foot/shared/sh_ik_foot_config.lua")
AddCSLuaFile("ik_foot/client/cl_ik_foot_sync.lua")
AddCSLuaFile("ik_foot/client/runtime/cl_ik_foot_context.lua")
AddCSLuaFile("ik_foot/client/runtime/ik_ground.lua")
AddCSLuaFile("ik_foot/client/runtime/ik_state.lua")
AddCSLuaFile("ik_foot/client/runtime/ik_controller.lua")
AddCSLuaFile("ik_foot/client/runtime/ik_apply.lua")
AddCSLuaFile("ik_foot/client/runtime/cl_ik_foot_hooks.lua")

include("ik_foot/shared/sh_ik_foot_config.lua")

if SERVER then
	include("ik_foot/server/sv_ik_foot_sync.lua")
	return
end

include("ik_foot/client/cl_ik_foot_sync.lua")
include("ik_foot/client/runtime/cl_ik_foot_context.lua")
include("ik_foot/client/runtime/ik_ground.lua")
include("ik_foot/client/runtime/ik_state.lua")
include("ik_foot/client/runtime/ik_controller.lua")
include("ik_foot/client/runtime/ik_apply.lua")
include("ik_foot/client/runtime/cl_ik_foot_hooks.lua")
