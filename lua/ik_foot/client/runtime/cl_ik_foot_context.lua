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

-- =====================================================================
-- bone manipulation layer
-- =====================================================================
-- the ik only ever adds/removes its OWN contribution (a delta) on top of
-- whatever else is on a bone, so other addons keep working.
--
-- pac3: while a player wears pac parts, pac.ManipulateBone* does not touch
-- the entity, it only stores the value in ply.pac_boneanim. pac copies that
-- to the entity in PreDrawOpaqueRenderables (pac.ResetBones) and then adds
-- its bone parts on top. going through pac's api meant our "remove ik, read
-- the animated pose" step removed nothing until the next frame, so the ik was
-- computed on top of its own previous result (jittering feet, legs folding,
-- rest height drifting under the floor). so now the delta is applied to the
-- entity directly (effective right away) AND mirrored into pac_boneanim so
-- pac's next reset rebuilds the same state.

local function UsePAC()
	return istable(pac) and isfunction(pac.IsEnabled) and pac.IsEnabled()
end

local function PacStore(ply)
	if not UsePAC() then return nil end
	local store = ply.pac_boneanim
	if not store then
		store = { positions = {}, angles = {} }
		ply.pac_boneanim = store
	end
	store.positions = store.positions or {}
	store.angles = store.angles or {}
	return store
end

local POS_EPS = 0.05
local ANG_EPS = 0.1

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

function RT.GetIKBlendState(ply)
	ply.IKBlendState = ply.IKBlendState or { pos = {}, ang = {} }
	return ply.IKBlendState
end

-- is our last applied delta still part of the bone? if somebody overwrote
-- the bone in the meantime it is not, and we must not subtract it again
local function StillIncluded(entry, entValue, storeValue, near, eps)
	if not entry then return false end
	if entry.store and storeValue then
		return near(storeValue, entry.store, eps)
	end
	return entry.ent ~= nil and near(entValue, entry.ent, eps)
end

-- makes our contribution on `bone` equal to `offset`
function RT.ApplyBlendedBonePosition(ply, bone, offset)
	if bone == nil or bone < 0 then return end
	local state = RT.GetIKBlendState(ply)
	local entry = state.pos[bone]
	local store = PacStore(ply)
	local current = ply:GetManipulateBonePosition(bone) or Vector()
	local storeValue = store and store.positions[bone]

	local applied = StillIncluded(entry, current, storeValue, VecNear, POS_EPS) and entry.applied or vector_origin
	local delta = offset - applied

	local newEnt = current + delta
	ply:ManipulateBonePosition(bone, newEnt)
	local newStore
	if store then
		newStore = (storeValue or vector_origin) + delta
		store.positions[bone] = newStore
	end

	state.pos[bone] = { applied = Vector(offset), ent = Vector(newEnt), store = newStore and Vector(newStore) or nil }
end

function RT.ApplyBlendedBoneAngles(ply, bone, offset)
	if bone == nil or bone < 0 then return end
	local state = RT.GetIKBlendState(ply)
	local entry = state.ang[bone]
	local store = PacStore(ply)
	local current = ply:GetManipulateBoneAngles(bone) or Angle()
	local storeValue = store and store.angles[bone]

	local applied = StillIncluded(entry, current, storeValue, AngNear, ANG_EPS) and entry.applied or angle_zero
	local dp, dy, dr = offset.p - applied.p, offset.y - applied.y, offset.r - applied.r

	local newEnt = Angle(current.p + dp, current.y + dy, current.r + dr)
	ply:ManipulateBoneAngles(bone, newEnt)
	local newStore
	if store then
		local base = storeValue or angle_zero
		newStore = Angle(base.p + dp, base.y + dy, base.r + dr)
		store.angles[bone] = newStore
	end

	state.ang[bone] = { applied = Angle(offset), ent = Angle(newEnt), store = newStore and Angle(newStore) or nil }
end

-- nuclear: zero the bone everywhere, ignoring the blend bookkeeping
function RT.ZeroBone(ply, bone)
	if bone == nil or bone < 0 then return end
	ply:ManipulateBonePosition(bone, Vector())
	ply:ManipulateBoneAngles(bone, Angle())
	local store = ply.pac_boneanim
	if istable(store) then
		if store.positions then store.positions[bone] = nil end
		if store.angles then store.angles[bone] = nil end
	end
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
	local result = { weighted = {}, hasWeights = false, footSoleZ = nil, lowestZ = nil, footLength = 0, footWidth = 0, footVerts = 0, centroids = {} }
	local sums, counts = {}, {}
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
						if (w.weight or 0) >= 0.3 then
							local sum = sums[bone]
							if sum then sum:Add(pos) else sums[bone] = Vector(pos) end
							counts[bone] = (counts[bone] or 0) + 1
						end
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

	-- bind pose centre of the geometry each bone mainly drives
	for bone, sum in pairs(sums) do
		result.centroids[bone] = sum / counts[bone]
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

	-- foot followers: geometry skinned around a foot (shoes, socks, heels,
	-- anklets) to bones that are NOT children of the foot. some models hang
	-- those bones straight off the pelvis; the animation keeps them on the foot,
	-- but when the ik moves the foot they would be left behind (shoes floating
	-- under the stairs). they get the same transform the foot gets.
	local followers = {}
	local centroids = mesh.centroids or {}
	local function FootCentre(foot, toe)
		if centroids[foot] then return centroids[foot] end
		if toe and centroids[toe] then return centroids[toe] end
		-- nothing skinned to the foot itself: use where the bone is right now,
		-- in model space
		local m = ply:GetBoneMatrix(foot)
		if not m then return nil end
		local ang = ply.GetRenderAngles and ply:GetRenderAngles() or ply:GetAngles()
		local localPos = WorldToLocal(m:GetTranslation(), angle_zero, ply:GetPos(), Angle(0, ang.y, 0))
		return localPos / math.max(ply:GetModelScale() or 1, 0.01)
	end
	local footCentre = { left = FootCentre(bones.lFoot, bones.lToe), right = FootCentre(bones.rFoot, bones.rToe) }
	if mesh.hasWeights and (footCentre.left or footCentre.right) then
		local radius = mesh.footLength and mesh.footLength > 0 and math.Clamp(mesh.footLength * 0.8, 4, 14) or 7
		local legBones = { [bones.lThigh] = true, [bones.rThigh] = true, [root] = true }
		local candidates = {}
		for bone, centre in pairs(centroids) do
			local inLeg = legBones[bone]
				or IsAncestor(ply, bones.lThigh, bone, 256) or IsAncestor(ply, bones.rThigh, bone, 256)
				or (bones.leanBone and (bone == bones.leanBone or IsAncestor(ply, bones.leanBone, bone, 256)))
			if bone < count and not inLeg and not IsHelperName(ply:GetBoneName(bone)) then
				local bestSide, bestDist = nil, radius
				for side, fc in pairs(footCentre) do
					local d = centre:Distance(fc)
					if d < bestDist then bestSide, bestDist = side, d end
				end
				if bestSide then candidates[bone] = bestSide end
			end
		end

		local auxSet = {}
		for _, b in ipairs(auxRoots) do auxSet[b] = true end
		for bone, side in pairs(candidates) do
			-- only the topmost bone of a follower chain, its children come along
			local nested = false
			local top, cur = bone, ply:GetBoneParent(bone)
			while cur and cur >= 0 do
				if candidates[cur] then nested = true end
				top = cur
				cur = ply:GetBoneParent(cur)
			end
			if not nested then
				local parent = ply:GetBoneParent(bone)
				local rootLevel = not parent or parent < 0
				followers[#followers + 1] = {
					bone = bone,
					side = side,
					parent = rootLevel and -1 or parent,
					-- its parent already moves down with the body drop
					shifted = not rootLevel and (top == root or auxSet[top] == true),
				}
				if rootLevel and auxSet[bone] then
					auxSet[bone] = nil
					for i = #auxRoots, 1, -1 do
						if auxRoots[i] == bone then table.remove(auxRoots, i) end
					end
				end
			end
		end
	end
	bones.followers = followers
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
		followerCount = #bones.followers,
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
		Color(255, 255, 255), string.format(" (leg=%.0f, sole=%+.2f, scale=%.2f, extra roots=%d, foot followers=%d)", info.legLength, info.soleOffset, info.scale, info.auxRootCount, info.followerCount)
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
