if SERVER then return end

if not IKFoot or not IKFoot.Config then
	include("ik_foot/shared/sh_ik_foot_config.lua")
end

if not IKFoot or not IKFoot.Config then return end

include("ik_foot/client/runtime/cl_ik_foot_context.lua")
include("ik_foot/client/runtime/ik_ground.lua")
include("ik_foot/client/runtime/ik_state.lua")
include("ik_foot/client/runtime/ik_controller.lua")
include("ik_foot/client/runtime/ik_apply.lua")
include("ik_foot/client/runtime/cl_ik_foot_hooks.lua")
