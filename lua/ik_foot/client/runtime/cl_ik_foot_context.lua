if SERVER then return end

if not IKFoot or not IKFoot.Config then return end

IKFoot.Runtime = IKFoot.Runtime or {}
local RT = IKFoot.Runtime

RT.REFERENCE_LEG_LENGTH = 45

RT.Colors = {
	white = Color(255, 255, 255),
	green = Color(0, 255, 0),
}

RT.CVars = RT.CVars or {}

for _, entry in ipairs(IKFoot.Config.entries) do
	local default = entry.default
	if entry.type == "bool" then default = default and 1 or 0 end
	RT.CVars[entry.key] = CreateClientConVar(entry.cvar, tostring(default), true, true, entry.desc)
end

-- one-time migration. older versions stored model-specific values in cvars
-- (leg length, double-scaled drops etc) that mean something else now
do
	local versionCvar = CreateClientConVar("ik_foot_config_version", "0", true, false, "Internal: IK Foot config layout version")
	if versionCvar:GetInt() < IKFoot.CONFIG_VERSION then
		local resetKeys = { "leg_length", "trace_start_offset", "max_body_drop", "foot_rotation_scale",
			"extra_body_drop", "extra_body_drop_uneven", "sole_offset", "stair_step_min_height", "stair_step_max_height" }
		for _, key in ipairs(resetKeys) do
			local entry = IKFoot.Config.byKey[key]
			if entry then
				local value = entry.default
				if entry.type == "bool" then value = value and 1 or 0 end
				RunConsoleCommand(entry.cvar, tostring(value))
			end
		end
		RunConsoleCommand("ik_foot_config_version", tostring(IKFoot.CONFIG_VERSION))
	end
end

function RT.GetIKParam(ply, key)
	local entry = IKFoot.Config.byKey[key]
	if ply == LocalPlayer() then
		local cvar = RT.CVars[key]
		if not cvar then return entry and tonumber(entry.default) or 0 end
		return entry and IKFoot.Config.ClampNumber(entry, cvar:GetFloat()) or cvar:GetFloat()
	end
	local default = entry and entry.default or 0
	if isbool(default) then default = default and 1 or 0 end
	return ply:GetNWFloat(IKFoot.Config.NWName(key), default)
end

function RT.GetIKParamBool(ply, key)
	local entry = IKFoot.Config.byKey[key]
	if ply == LocalPlayer() then
		local cvar = RT.CVars[key]
		if not cvar then return entry and entry.default and true or false end
		return cvar:GetBool()
	end
	-- default to the config default until the server has networked a value
	return ply:GetNWBool(IKFoot.Config.NWName(key), entry and entry.default and true or false)
end

-- all params for one player, read once per frame instead of ~30 lookups per call site
function RT.GetParams(ply)
	local frame = FrameNumber()
	local cache = ply.IKParamCache
	if cache and cache._frame == frame then return cache end
	cache = cache or {}
	for _, entry in ipairs(IKFoot.Config.entries) do
		if entry.type == "bool" then
			cache[entry.key] = RT.GetIKParamBool(ply, entry.key)
		else
			cache[entry.key] = RT.GetIKParam(ply, entry.key)
		end
	end
	cache._frame = frame
	ply.IKParamCache = cache
	return cache
end

-- pac3 compat. if pac is loaded we use its bone api instead
-- without this pac and ik fight each other and everything breaks

local function UsePAC()
	return istable(pac) and pac.IsEnabled and pac.IsEnabled()
		and isfunction(pac.ManipulateBonePosition) and isfunction(pac.ManipulateBoneAngles)
end

function RT.SetBonePosition(ply, bone, pos)
	if bone == nil then return end
	if UsePAC() then
		pac.ManipulateBonePosition(ply, bone, pos)
	else
		ply:ManipulateBonePosition(bone, pos)
	end
end

function RT.SetBoneAngles(ply, bone, ang)
	if bone == nil then return end
	if UsePAC() then
		pac.ManipulateBoneAngles(ply, bone, ang)
	else
		ply:ManipulateBoneAngles(bone, ang)
	end
end

function RT.GetCurrentBonePosition(ply, bone)
	if bone == nil then return Vector() end
	if UsePAC() and ply.pac_boneanim and ply.pac_boneanim.positions then
		local pos = ply.pac_boneanim.positions[bone]
		if pos then return Vector(pos) end
	end
	return Vector(ply:GetManipulateBonePosition(bone) or Vector())
end

function RT.GetCurrentBoneAngles(ply, bone)
	if bone == nil then return Angle() end
	if UsePAC() and ply.pac_boneanim and ply.pac_boneanim.angles then
		local ang = ply.pac_boneanim.angles[bone]
		if ang then return Angle(ang) end
	end
	return Angle(ply:GetManipulateBoneAngles(bone) or Angle())
end

-- tracks what ik changed on each bone so we dont fight other addons
-- this took forever to get right

function RT.GetIKBlendState(ply)
	ply.IKBlendState = ply.IKBlendState or { pos = {}, ang = {} }
	return ply.IKBlendState
end

local NEAR_EPS_VEC = 0.01
local NEAR_EPS_ANG = 0.05

local function VecNear(a, b, eps)
	return math.abs(a.x - b.x) <= eps
		and math.abs(a.y - b.y) <= eps
		and math.abs(a.z - b.z) <= eps
end

local function AngNear(a, b, eps)
	return math.abs(math.AngleDifference(a.p, b.p)) <= eps
		and math.abs(math.AngleDifference(a.y, b.y)) <= eps
		and math.abs(math.AngleDifference(a.r, b.r)) <= eps
end

RT.VecNear = VecNear
RT.AngNear = AngNear

function RT.ApplyBlendedBonePosition(ply, bone, offset)
	if bone == nil then return end
	local state = RT.GetIKBlendState(ply)
	local entry = state.pos[bone]
	if not entry then
		entry = { applied = Vector(), final = nil }
		state.pos[bone] = entry
	end

	local current = RT.GetCurrentBonePosition(ply, bone)
	local base = current
	if entry.final and VecNear(current, entry.final, NEAR_EPS_VEC) then
		base = current - entry.applied
	end

	local final = base + offset
	RT.SetBonePosition(ply, bone, final)
	entry.applied = Vector(offset)
	entry.final = Vector(final)
end

function RT.ApplyBlendedBoneAngles(ply, bone, offset)
	if bone == nil then return end
	local state = RT.GetIKBlendState(ply)
	local entry = state.ang[bone]
	if not entry then
		entry = { applied = Angle(), final = nil }
		state.ang[bone] = entry
	end

	local current = RT.GetCurrentBoneAngles(ply, bone)
	local base = current
	if entry.final and AngNear(current, entry.final, NEAR_EPS_ANG) then
		base = Angle(current.p - entry.applied.p, current.y - entry.applied.y, current.r - entry.applied.r)
	end

	local final = Angle(base.p + offset.p, base.y + offset.y, base.r + offset.r)
	RT.SetBoneAngles(ply, bone, final)
	entry.applied = Angle(offset)
	entry.final = Angle(final)
end

-- =====================================================================
-- bone detection
-- =====================================================================
-- the old version assumed bone 0 is the body root and moved EVERY bone with
-- parent == -1 together with it. on models with extra bones (hair roots,
-- helper/ik/attachment bones, bones merged in from $includemodel) that meant
-- moving things that should never be touched. now:
--   * the body root is the topmost ancestor of the thigh bones
--   * extra roots only follow the body if mesh vertices are actually skinned
--     to them (or their children) and they are not obvious helper bones

local BONE_NAMES = {
	pelvis = { "ValveBiped.Bip01_Pelvis", "Bip01 Pelvis", "bip_pelvis", "mixamorig:Hips", "Hips", "pelvis" },
	lThigh = { "ValveBiped.Bip01_L_Thigh", "Bip01 L Thigh", "bip_hip_L", "mixamorig:LeftUpLeg", "LeftUpLeg", "thigh_l", "L_Thigh" },
	rThigh = { "ValveBiped.Bip01_R_Thigh", "Bip01 R Thigh", "bip_hip_R", "mixamorig:RightUpLeg", "RightUpLeg", "thigh_r", "R_Thigh" },
	lCalf  = { "ValveBiped.Bip01_L_Calf", "Bip01 L Calf", "bip_knee_L", "mixamorig:LeftLeg", "LeftLeg", "calf_l", "L_Calf" },
	rCalf  = { "ValveBiped.Bip01_R_Calf", "Bip01 R Calf", "bip_knee_R", "mixamorig:RightLeg", "RightLeg", "calf_r", "R_Calf" },
	lFoot  = { "ValveBiped.Bip01_L_Foot", "Bip01 L Foot", "bip_foot_L", "mixamorig:LeftFoot", "LeftFoot", "foot_l", "L_Foot" },
	rFoot  = { "ValveBiped.Bip01_R_Foot", "Bip01 R Foot", "bip_foot_R", "mixamorig:RightFoot", "RightFoot", "foot_r", "R_Foot" },
	lToe   = { "ValveBiped.Bip01_L_Toe0", "Bip01 L Toe0", "bip_toe_L", "mixamorig:LeftToeBase", "LeftToeBase", "ball_l" },
	rToe   = { "ValveBiped.Bip01_R_Toe0", "Bip01 R Toe0", "bip_toe_R", "mixamorig:RightToeBase", "RightToeBase", "ball_r" },
	spine  = { "ValveBiped.Bip01_Spine1", "ValveBiped.Bip01_Spine", "Bip01 Spine1", "bip_spine_1", "mixamorig:Spine1", "spine_01" },
}

-- names of bones that never carry visible body geometry worth moving
local HELPER_PATTERNS = { "attach", "weapon", "wpn", "^ik", "_ik", "camera", "cam_", "prop", "helper", "dummy", "null", "nub", "lock", "target", "forward", "physics" }

local function LookupFirst(ply, names)
	for _, name in ipairs(names) do
		local bone = ply:LookupBone(name)
		if bone and bone >= 0 then return bone end
	end
	return nil
end

local function IsAncestor(ply, ancestor, bone, maxDepth)
	local cur = bone
	for _ = 1, maxDepth do
		cur = ply:GetBoneParent(cur)
		if not cur or cur < 0 then return false end
		if cur == ancestor then return true end
	end
	return false
end

local function SideOf(lname)
	if string.find(lname, "left", 1, true) then return "l" end
	if string.find(lname, "right", 1, true) then return "r" end
	local padded = "_" .. string.gsub(lname, "[%s%.:]", "_") .. "_"
	if string.find(padded, "_l_", 1, true) then return "l" end
	if string.find(padded, "_r_", 1, true) then return "r" end
	return nil
end

local function IsTwistBone(lname)
	return string.find(lname, "twist", 1, true) or string.find(lname, "roll", 1, true)
		or string.find(lname, "helper", 1, true) or string.find(lname, "jiggle", 1, true)
end

-- fallback for rigs with unusual names: find a "foot" bone per side and walk up
-- the hierarchy (skipping twist helpers) to get calf and thigh
local function DetectLegChainByHierarchy(ply, side)
	local count = ply:GetBoneCount() or 0
	for i = 0, count - 1 do
		local lname = string.lower(ply:GetBoneName(i) or "")
		if (string.find(lname, "foot", 1, true) or string.find(lname, "ankle", 1, true)) and SideOf(lname) == side and not IsTwistBone(lname) then
			local calf = ply:GetBoneParent(i)
			while calf and calf >= 0 and IsTwistBone(string.lower(ply:GetBoneName(calf) or "")) do
				calf = ply:GetBoneParent(calf)
			end
			local thigh = calf and calf >= 0 and ply:GetBoneParent(calf) or nil
			while thigh and thigh >= 0 and IsTwistBone(string.lower(ply:GetBoneName(thigh) or "")) do
				thigh = ply:GetBoneParent(thigh)
			end
			if calf and calf >= 0 and thigh and thigh >= 0 then
				return thigh, calf, i
			end
		end
	end
	return nil
end

-- =====================================================================
-- model profile (mesh analysis). cached per model path for everybody
-- =====================================================================

IKFoot.ModelAnalysisCache = IKFoot.ModelAnalysisCache or {}

local function IsHelperName(name)
	local lname = string.lower(name or "")
	for _, pattern in ipairs(HELPER_PATTERNS) do
		if string.find(lname, pattern) then return true end
	end
	return false
end

-- scans the mesh once: which bones actually deform vertices, and where the
-- soles of the feet are in bind pose
local function AnalyzeMesh(model, footBones)
	local result = { weighted = {}, hasWeights = false, footSoleZ = nil, lowestZ = nil, footLength = 0, footWidth = 0, footVerts = 0 }
	local meshes = util.GetModelMeshes(model)
	if not meshes then return result end

	local lowestZ = math.huge
	local footMinZ = math.huge
	local footMinX, footMaxX, footMinY, footMaxY = math.huge, -math.huge, math.huge, -math.huge
	local footVerts = 0

	for _, group in ipairs(meshes) do
		for _, v in ipairs(group.verticies or group.triangles or {}) do
			local pos = v.pos
			if pos then
				if pos.z < lowestZ then lowestZ = pos.z end
				local onFoot = false
				for _, w in ipairs(v.weights or {}) do
					local bone = w.bone
					if bone and (w.weight or 0) > 0.01 then
						result.weighted[bone] = true
						result.hasWeights = true
						if footBones[bone] and (w.weight or 0) >= 0.3 then onFoot = true end
					end
				end
				if onFoot then
					footVerts = footVerts + 1
					if pos.z < footMinZ then footMinZ = pos.z end
					if pos.x < footMinX then footMinX = pos.x end
					if pos.x > footMaxX then footMaxX = pos.x end
					if pos.y < footMinY then footMinY = pos.y end
					if pos.y > footMaxY then footMaxY = pos.y end
				end
			end
		end
	end

	if lowestZ < math.huge then result.lowestZ = lowestZ end
	if footVerts >= 8 then
		result.footSoleZ = footMinZ
		result.footVerts = footVerts
		-- playermodels face +X in model space. Y spans both feet
		result.footLength = footMaxX - footMinX
		result.footWidth = footMaxY - footMinY
	end
	return result
end

local function BuildBoneSet(ply, model)
	local bones = { model = model, valid = false }

	bones.lThigh = LookupFirst(ply, BONE_NAMES.lThigh)
	bones.rThigh = LookupFirst(ply, BONE_NAMES.rThigh)
	bones.lCalf  = LookupFirst(ply, BONE_NAMES.lCalf)
	bones.rCalf  = LookupFirst(ply, BONE_NAMES.rCalf)
	bones.lFoot  = LookupFirst(ply, BONE_NAMES.lFoot)
	bones.rFoot  = LookupFirst(ply, BONE_NAMES.rFoot)

	if not (bones.lThigh and bones.lCalf and bones.lFoot) then
		bones.lThigh, bones.lCalf, bones.lFoot = DetectLegChainByHierarchy(ply, "l")
	end
	if not (bones.rThigh and bones.rCalf and bones.rFoot) then
		bones.rThigh, bones.rCalf, bones.rFoot = DetectLegChainByHierarchy(ply, "r")
	end

	if not (bones.lThigh and bones.lCalf and bones.lFoot and bones.rThigh and bones.rCalf and bones.rFoot) then
		return bones
	end

	-- reject garbage chains (e.g. a name match on an unrelated bone)
	if not (IsAncestor(ply, bones.lThigh, bones.lCalf, 3) and IsAncestor(ply, bones.lCalf, bones.lFoot, 3)
		and IsAncestor(ply, bones.rThigh, bones.rCalf, 3) and IsAncestor(ply, bones.rCalf, bones.rFoot, 3)) then
		return bones
	end

	bones.lToe = LookupFirst(ply, BONE_NAMES.lToe)
	bones.rToe = LookupFirst(ply, BONE_NAMES.rToe)
	bones.pelvis = LookupFirst(ply, BONE_NAMES.pelvis)
	bones.leanBone = LookupFirst(ply, BONE_NAMES.spine)

	-- body root = topmost ancestor of the legs. NOT blindly bone 0
	local root = bones.lThigh
	for _ = 1, 256 do
		local parent = ply:GetBoneParent(root)
		if not parent or parent < 0 then break end
		root = parent
	end
	bones.root = root

	-- lean bone must sit between the root and the head, never inside a leg chain
	if bones.leanBone and (bones.leanBone == bones.lThigh or bones.leanBone == bones.rThigh) then
		bones.leanBone = nil
	end

	local footBones = { [bones.lFoot] = true, [bones.rFoot] = true }
	if bones.lToe then footBones[bones.lToe] = true end
	if bones.rToe then footBones[bones.rToe] = true end

	local profile = IKFoot.ModelAnalysisCache[model]
	if not profile then
		profile = { mesh = AnalyzeMesh(model, footBones) }
		IKFoot.ModelAnalysisCache[model] = profile
	end
	bones.profile = profile

	-- extra root bones that must follow the body drop
	local count = ply:GetBoneCount() or 0
	local auxRoots = {}
	local mesh = profile.mesh
	if mesh.hasWeights then
		-- a root counts as "visible" if it or any bone under it is skinned
		local visibleRoot = {}
		for bone in pairs(mesh.weighted) do
			local cur, guard = bone, 0
			while cur and cur >= 0 and guard < 256 do
				local parent = ply:GetBoneParent(cur)
				if not parent or parent < 0 then
					visibleRoot[cur] = true
					break
				end
				cur = parent
				guard = guard + 1
			end
		end
		for i = 0, count - 1 do
			if i ~= root and ply:GetBoneParent(i) == -1 and visibleRoot[i] and not IsHelperName(ply:GetBoneName(i)) then
				auxRoots[#auxRoots + 1] = i
			end
		end
	end
	-- without weight data we cant tell hair from helpers, so we leave them alone
	bones.auxRoots = auxRoots
	bones.boneCount = count
	bones.valid = true
	return bones
end

function RT.GetIKBones(ply)
	local model = ply:GetModel()
	local bones = ply.IKBones
	if bones and bones.model == model and bones.boneCount == (ply:GetBoneCount() or 0) then return bones end

	-- model changed: undo whatever we did to the OLD bone indices before forgetting them,
	-- manipulations are stored per index and would otherwise corrupt the new model
	if bones and RT.Apply and RT.Apply.StripIKFromBones then
		RT.Apply.StripIKFromBones(ply, bones)
	end
	if bones then
		ply.IKBlendState = nil
		if RT.State then RT.State.Reset(ply) end
	end

	bones = BuildBoneSet(ply, model)
	ply.IKBones = bones
	return bones
end

function RT.CanManipulateBones(ply)
	if ply:InVehicle() then return false end
	if ply:GetMoveType() == MOVETYPE_NOCLIP or ply:GetMoveType() == MOVETYPE_LADDER then return false end
	if isfunction(ply.IsDive) and ply:IsDive() then return false end
	if isfunction(ply.IsProne) and ply:IsProne() then return false end
	return true
end

function IKFoot.InvalidateModelCache(model)
	if model then
		IKFoot.ModelAnalysisCache[model] = nil
	else
		IKFoot.ModelAnalysisCache = {}
	end
end

-- describes the current model. used by auto-detect and the "suggest" button
function IKFoot.MeasureModel(ply)
	if not IsValid(ply) then return nil, "Invalid player" end
	local model = ply:GetModel()
	if not model or model == "" then return nil, "No model" end

	local bones = RT.GetIKBones(ply)
	if not bones.valid then return nil, "Model has no usable leg bones" end

	ply:SetupBones()
	local function Pos(bone)
		local m = bone and ply:GetBoneMatrix(bone)
		return m and m:GetTranslation()
	end
	local lThigh, lCalf, lFoot = Pos(bones.lThigh), Pos(bones.lCalf), Pos(bones.lFoot)
	local rThigh, rCalf, rFoot = Pos(bones.rThigh), Pos(bones.rCalf), Pos(bones.rFoot)
	if not (lThigh and lCalf and lFoot and rThigh and rCalf and rFoot) then
		return nil, "Could not read bone positions"
	end

	local upper = (lThigh:Distance(lCalf) + rThigh:Distance(rCalf)) * 0.5
	local lower = (lCalf:Distance(lFoot) + rCalf:Distance(rFoot)) * 0.5
	local legLength = upper + lower
	local modelScale = math.max(ply:GetModelScale() or 1, 0.01)
	local mesh = bones.profile.mesh
	local soleCorrection = RT.GetSoleCorrection(bones.profile, modelScale)

	-- every model-specific value is derived at runtime now, so the
	-- suggestion is simply "auto" for those cvars
	local suggested = {
		leg_length = 0,
		sole_offset = 0,
	}

	local info = {
		model = model,
		legLength = legLength,
		upperLegLength = upper,
		lowerLegLength = lower,
		scale = math.Clamp(legLength / RT.REFERENCE_LEG_LENGTH, 0.4, 2.5),
		soleOffset = soleCorrection,
		meshBottomZ = mesh.footSoleZ or mesh.lowestZ or 0,
		meshFootLength = mesh.footLength or 0,
		meshFootWidth = mesh.footWidth or 0,
		meshFootVertCount = mesh.footVerts or 0,
		auxRootCount = #bones.auxRoots,
		boneCount = bones.boneCount,
		rootBone = ply:GetBoneName(bones.root) or tostring(bones.root),
	}
	bones.profile.info = info
	return suggested, nil, info
end

-- how much the feet must be raised (+) or lowered (-) so the mesh soles,
-- not the foot bones, touch the ground. derived from bind pose foot vertices
function RT.GetSoleCorrection(profile, modelScale)
	if not profile or not profile.mesh then return 0 end
	local soleZ = profile.mesh.footSoleZ
	if not soleZ then return 0 end
	return math.Clamp(-soleZ * (modelScale or 1), -3, 4)
end

-- auto applies settings on model change. without this everything looks wrong after playermodel swap
function IKFoot.AutoApplyModelSettings(ply)
	if not IsValid(ply) or ply ~= LocalPlayer() then return end

	local suggested, _, info = IKFoot.MeasureModel(ply)
	if not suggested then return end

	local byKey = IKFoot.Config.byKey
	for key, value in pairs(suggested) do
		local entry = byKey[key]
		local cvar = entry and RT.CVars[key]
		if cvar and cvar:GetFloat() ~= value then
			RunConsoleCommand(entry.cvar, tostring(value))
		end
	end

	if RT.State then RT.State.SoftRecover(ply) end

	local modelShort = string.GetFileFromFilename(info.model or "unknown") or "model"
	chat.AddText(
		Color(100, 255, 100), "[IK Foot] ",
		Color(255, 255, 255), "Auto-configured for ",
		Color(100, 200, 255), modelShort,
		Color(255, 255, 255), string.format(" (leg=%.0f, sole=%+.2f, scale=%.2f, extra roots=%d)", info.legLength, info.soleOffset, info.scale, info.auxRootCount)
	)
end

function IKFoot.HardReset(ply)
	if not IsValid(ply) then return end
	IKFoot.InvalidateModelCache(ply:GetModel())
	RT.Apply.HardResetPlayer(ply)
end

function IKFoot.HardResetAll()
	IKFoot.InvalidateModelCache()
	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) then
			RT.Apply.HardResetPlayer(ply)
		end
	end
end

concommand.Add("ik_foot_hard_reset", function()
	local ply = LocalPlayer()
	if IsValid(ply) then
		IKFoot.HardReset(ply)
		chat.AddText(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255), "Hard reset complete - all IK state cleared")
	end
end)
