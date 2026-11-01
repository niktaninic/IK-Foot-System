IKFoot = IKFoot or {}

IKFoot.VERSION = "0.51"
-- bump with every change that matters for a bug report: dumps record it
IKFoot.BUILD = "0.51-diag.8"

-- bump whenever the meaning of a cvar changes. clients with an older stored
-- version get the affected cvars reset once (see cl_ik_foot_context.lua)
IKFoot.CONFIG_VERSION = 2

-- distances marked "ref" are in reference-skeleton units (45 unit leg) and are
-- scaled at runtime by the measured leg length of the current model
IKFoot.Config = {
	entries = {
		{ key = "enabled",               cvar = "ik_foot",                        type = "bool",  default = true,  min = 0,   max = 1,   decimals = 0, desc = "Enable/Disable IK Foot" },
		{ key = "lean_enabled",          cvar = "ik_foot_lean",                   type = "bool",  default = false, min = 0,   max = 1,   decimals = 0, desc = "Enable/Disable Body Lean" },
		{ key = "debug",                 cvar = "ik_foot_debug",                  type = "float", default = 0,     min = 0,   max = 2,   decimals = 0, desc = "Debug overlay: 0 off, 1 basic, 2 detailed" },
		{ key = "ground_distance",       cvar = "ik_foot_ground_distance",        type = "float", default = 70,    min = 20,  max = 100, decimals = 0, desc = "Ground Trace Distance (ref)" },
		{ key = "smoothing",             cvar = "ik_foot_smoothing",              type = "float", default = 17,    min = 1,   max = 50,  decimals = 0, desc = "Smoothing Factor" },
		{ key = "leg_length",            cvar = "ik_foot_leg_length",             type = "float", default = 0,     min = 0,   max = 80,  decimals = 0, desc = "Leg Length Override (0 = auto)" },
		{ key = "trace_start_offset",    cvar = "ik_foot_trace_start_offset",     type = "float", default = 30,    min = 20,  max = 40,  decimals = 0, desc = "Trace Start Height (ref)" },
		{ key = "sole_offset",           cvar = "ik_foot_sole_offset",            type = "float", default = 0,     min = -3,  max = 5,   decimals = 2, desc = "Sole Contact Offset" },
		{ key = "uneven_drop_scale",     cvar = "ik_foot_uneven_drop_scale",      type = "float", default = 0.15,  min = 0,   max = 1,   decimals = 2, desc = "Height Diff Multiplier" },
		{ key = "extra_body_drop",       cvar = "ik_foot_extra_body_drop",        type = "float", default = 0.3,   min = 0,   max = 5,   decimals = 1, desc = "Body Drop (Flat, ref)" },
		{ key = "extra_body_drop_uneven",cvar = "ik_foot_extra_body_drop_uneven", type = "float", default = 1.2,   min = 0,   max = 10,  decimals = 1, desc = "Body Drop (Uneven, ref)" },
		{ key = "foot_rotation_scale",   cvar = "ik_foot_rotation_scale",         type = "float", default = 0.8,   min = 0,   max = 1,   decimals = 2, desc = "Foot Slope Alignment" },
		{ key = "lock_strength",         cvar = "ik_foot_lock_strength",          type = "float", default = 0.85,  min = 0.1, max = 2,   decimals = 2, desc = "Foot Lock Strength" },
		{ key = "release_speed",         cvar = "ik_foot_release_speed",          type = "float", default = 65,    min = 5,   max = 200, decimals = 0, desc = "Foot Release Speed" },
		{ key = "stair_stepper",         cvar = "ik_foot_stair_stepper",          type = "bool",  default = true,  min = 0,   max = 1,   decimals = 0, desc = "Procedural Stair Stepping" },
		{ key = "stair_step_min_height", cvar = "ik_foot_stair_step_min_height",  type = "float", default = 3,     min = 1,   max = 12,  decimals = 1, desc = "Minimum Stair Step Height (ref)" },
		{ key = "stair_step_max_height", cvar = "ik_foot_stair_step_max_height",  type = "float", default = 20,    min = 8,   max = 36,  decimals = 1, desc = "Maximum Stair Step Height (ref)" },
		{ key = "stair_treads_per_step", cvar = "ik_foot_stair_treads_per_step",  type = "float", default = 1,     min = 1,   max = 3,   decimals = 0, desc = "Stairs Per Step (minimum)" },
		{ key = "stair_max_cadence",     cvar = "ik_foot_stair_max_cadence",      type = "float", default = 8,     min = 3,   max = 16,  decimals = 1, desc = "Max Stair Steps Per Second" },
		{ key = "stair_step_lift",       cvar = "ik_foot_stair_step_lift",        type = "float", default = 3,     min = 0,   max = 10,  decimals = 1, desc = "Stair Foot Clearance (ref)" },
		{ key = "moving_surface_max_speed", cvar = "ik_foot_moving_surface_max_speed", type = "float", default = 45, min = 5, max = 180, decimals = 0, desc = "Max Surface Speed For Stable Contact" },
		{ key = "rotation_smoothing",    cvar = "ik_foot_rotation_smoothing",     type = "float", default = 20,    min = 1,   max = 60,  decimals = 0, desc = "Rotation Smoothing" },
		{ key = "max_body_drop",         cvar = "ik_foot_max_body_drop",          type = "float", default = 24,    min = 5,   max = 40,  decimals = 0, desc = "Maximum Body Drop (ref)" },
		{ key = "stabilize_idle",        cvar = "ik_foot_stabilize_idle",         type = "bool",  default = true,  min = 0,   max = 1,   decimals = 0, desc = "Stabilize Idle Feet" },
		{ key = "idle_velocity",         cvar = "ik_foot_idle_velocity",          type = "float", default = 5,     min = 1,   max = 20,  decimals = 0, desc = "Idle Velocity Threshold" },
		{ key = "auto_model_detect",     cvar = "ik_foot_auto_model_detect",      type = "bool",  default = true,  min = 0,   max = 1,   decimals = 0, desc = "Auto-detect Model Settings" },
		{ key = "anti_clip",             cvar = "ik_foot_anti_clip",              type = "bool",  default = true,  min = 0,   max = 1,   decimals = 0, desc = "Foot Anti-clip Guard" },
		{ key = "dynamic_sole",          cvar = "ik_foot_dynamic_sole",           type = "bool",  default = true,  min = 0,   max = 1,   decimals = 0, desc = "Dynamic Sole Calibration" },
	},
}

-- names and explanations for the settings menu (label, help)
local TEXT = {
	enabled = { "Foot IK", "Turns the whole system on or off for your character." },
	lean_enabled = { "Body lean", "Leans the upper body into turns, acceleration and up stairs." },
	debug = { "Debug overlay", "Draws feet, targets and ground contacts. Detailed adds traces, the stair profile and followers." },
	ground_distance = { "Ground search depth", "How far below the trace start the feet look for ground. Longer finds lower ground but can reach through gaps." },
	smoothing = { "Body smoothing", "How fast the body and feet follow the ground. Higher reacts faster, lower is softer." },
	leg_length = { "Leg length", "Leg length used to scale everything. 0 measures it from your model (recommended)." },
	trace_start_offset = { "Trace start height", "Where above your feet the ground search starts. Raise it if feet ignore tall steps." },
	sole_offset = { "Sole offset", "Extra height between the foot bone and the ground. Raise if feet sink in, lower if they float." },
	uneven_drop_scale = { "Uneven ground crouch", "How much the body lowers when the feet stand at different heights." },
	extra_body_drop = { "Knee bend on flat ground", "A little extra bend in the knees while standing on level ground." },
	extra_body_drop_uneven = { "Knee bend on rough ground", "Extra bend in the knees on uneven ground and stairs." },
	foot_rotation_scale = { "Foot tilt on slopes", "How much the feet turn to lie flat on a slope. 1 = flat on it, 0 = keep the animation's angle." },
	lock_strength = { "Foot lock", "How firmly a planted foot stays where it landed." },
	release_speed = { "Foot release speed", "How fast the animation has to move a planted foot before it is let go." },
	stair_stepper = { "Stair stepping", "Puts every foot on a real stair tread instead of letting the walk animation float over them." },
	stair_step_min_height = { "Smallest stair step", "Height differences below this are not treated as stair steps." },
	stair_step_max_height = { "Tallest stair step", "Height differences above this are ledges, not stair steps." },
	stair_treads_per_step = { "Stairs per step", "At least this many treads per step. 2 takes stairs two at a time." },
	stair_max_cadence = { "Max steps per second", "Moving faster than this takes more treads per step; much faster goes back to the animation." },
	stair_step_lift = { "Step clearance", "How high a stepping foot lifts over the edge of the next tread." },
	moving_surface_max_speed = { "Moving ground limit", "Ground moving faster than this (lifts, vehicles) is not used for stair steps or foot locks." },
	rotation_smoothing = { "Foot turn smoothing", "How fast the feet turn to match the ground. Higher reacts faster." },
	max_body_drop = { "Deepest crouch", "The furthest the body may lower to keep both feet on the ground." },
	stabilize_idle = { "Steady feet when standing", "Keeps the feet firmly planted while you stand still." },
	idle_velocity = { "Standing speed", "Below this speed you count as standing still." },
	auto_model_detect = { "Auto-detect models", "Measures every new player model and applies matching settings." },
	anti_clip = { "Edge guard", "A foot over an edge rests on top of it instead of sinking in." },
	dynamic_sole = { "Learn ankle height", "Learns how high the ankle sits on a planted foot, for each model." },
}

IKFoot.Config.byKey = {}
for _, entry in ipairs(IKFoot.Config.entries) do
	IKFoot.Config.byKey[entry.key] = entry
	local text = TEXT[entry.key]
	entry.label = text and text[1] or entry.desc
	entry.help = text and text[2] or ""
	-- "(ref)": a distance in reference skeleton units, scaled with the leg length
	entry.scaled = string.find(entry.desc, "(ref)", 1, true) ~= nil
end

function IKFoot.Config.NWName(key)
	return "IK_" .. key
end

function IKFoot.Config.ClampNumber(entry, value)
	value = tonumber(value)
	-- nan passes straight through math.Clamp. it can come from a broken cvar
	-- or a crafted net message, and the server forwards these values to
	-- every client
	if not value or value ~= value then
		value = tonumber(entry.default) or entry.min
	end
	return math.Clamp(value, entry.min, entry.max)
end
