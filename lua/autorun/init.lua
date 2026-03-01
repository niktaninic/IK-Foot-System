-- load ik stuff

AddCSLuaFile("ik_foot.lua")

if SERVER then
	-- server side
	util.AddNetworkString("IKFoot_ConfigUpdate")
	
	local function ValidateIKValue(value, min, max)
		return math.Clamp(tonumber(value) or 0, min, max)
	end
	
	net.Receive("IKFoot_ConfigUpdate", function(len, ply)
		if not IsValid(ply) then return end
		
		local enabled = net.ReadBool()
		local groundDistance = ValidateIKValue(net.ReadFloat(), 20, 100)
		local legLength = ValidateIKValue(net.ReadFloat(), 30, 60)
		local traceStartOffset = ValidateIKValue(net.ReadFloat(), 20, 40)
		local soleOffset = ValidateIKValue(net.ReadFloat(), 0, 5)
		local unevenDropScale = ValidateIKValue(net.ReadFloat(), 0, 1)
		local extraBodyDrop = ValidateIKValue(net.ReadFloat(), 0, 5)
		local extraBodyDropUneven = ValidateIKValue(net.ReadFloat(), 0, 10)
		local highFootBendBoost = ValidateIKValue(net.ReadFloat(), 1, 2)
		local footRotationScale = ValidateIKValue(net.ReadFloat(), 0, 1)
		local leanEnabled = net.ReadBool()
		local smoothing = ValidateIKValue(net.ReadFloat(), 1, 50)
		local stabilizeIdle = net.ReadBool()
		local idleVelocity = ValidateIKValue(net.ReadFloat(), 1, 20)
		local idleThreshold = ValidateIKValue(net.ReadFloat(), 0.1, 5)
		
		ply:SetNWBool("IK_enabled", enabled)
		ply:SetNWFloat("IK_ground_distance", groundDistance)
		ply:SetNWFloat("IK_leg_length", legLength)
		ply:SetNWFloat("IK_trace_start_offset", traceStartOffset)
		ply:SetNWFloat("IK_sole_offset", soleOffset)
		ply:SetNWFloat("IK_uneven_drop_scale", unevenDropScale)
		ply:SetNWFloat("IK_extra_body_drop", extraBodyDrop)
		ply:SetNWFloat("IK_extra_body_drop_uneven", extraBodyDropUneven)
		ply:SetNWFloat("IK_high_foot_bend_boost", highFootBendBoost)
		ply:SetNWFloat("IK_foot_rotation_scale", footRotationScale)
		ply:SetNWBool("IK_lean_enabled", leanEnabled)
		ply:SetNWFloat("IK_smoothing", smoothing)
		ply:SetNWBool("IK_stabilize_idle", stabilizeIdle)
		ply:SetNWFloat("IK_idle_velocity", idleVelocity)
		ply:SetNWFloat("IK_idle_threshold", idleThreshold)
	end)
	
	hook.Add("PlayerInitialSpawn", "IKFoot_InitDefaults", function(ply)
		ply:SetNWBool("IK_enabled", true)
		ply:SetNWFloat("IK_ground_distance", 45)
		ply:SetNWFloat("IK_leg_length", 45)
		ply:SetNWFloat("IK_trace_start_offset", 30)
		ply:SetNWFloat("IK_sole_offset", 1.75)
		ply:SetNWFloat("IK_uneven_drop_scale", 0.35)
		ply:SetNWFloat("IK_extra_body_drop", 0.3)
		ply:SetNWFloat("IK_extra_body_drop_uneven", 1.2)
		ply:SetNWFloat("IK_high_foot_bend_boost", 1.45)
		ply:SetNWFloat("IK_foot_rotation_scale", 0.15)
		ply:SetNWBool("IK_lean_enabled", false)
		ply:SetNWFloat("IK_smoothing", 17)
		ply:SetNWBool("IK_stabilize_idle", true)
		ply:SetNWFloat("IK_idle_velocity", 5)
		ply:SetNWFloat("IK_idle_threshold", 0.5)
	end)
end

if CLIENT then
	include("ik_foot.lua")
end
