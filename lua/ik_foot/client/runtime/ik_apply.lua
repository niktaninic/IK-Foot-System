if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

local RT = IKFoot.Runtime
RT.Apply = RT.Apply or {}
local Apply = RT.Apply

local STRIP_POS_EPS = 0.1
local STRIP_ANG_EPS = 0.15

local function IsFiniteNumber(value)
	return isnumber(value) and value == value and value > -math.huge and value < math.huge
end

local function IsFiniteVector(vec)
	return isvector(vec) and IsFiniteNumber(vec.x) and IsFiniteNumber(vec.y) and IsFiniteNumber(vec.z)
end

local function IsFiniteAngle(ang)
	return isangle(ang) and IsFiniteNumber(ang.p) and IsFiniteNumber(ang.y) and IsFiniteNumber(ang.r)
end

local function GetBoneWorldTransform(ply, bone, plyPos)
	if not bone or bone < 0 then return nil, nil end
	local matrix = ply:GetBoneMatrix(bone)
	if not matrix then return nil, nil end
	local pos = matrix:GetTranslation()
	local ang = matrix:GetAngles()
	if IsFiniteVector(pos) and ang and pos:DistToSqr(plyPos) <= (260 * 260) then
		return pos, ang
	end
	return nil, nil
end

-- every bone the ik may touch for this bone set
local function ManagedBones(bones)
	local list = { bones.lThigh, bones.rThigh, bones.lCalf, bones.rCalf, bones.lFoot, bones.rFoot }
	if bones.leanBone then list[#list + 1] = bones.leanBone end
	return list
end

local function PositionBones(bones)
	local list = {}
	if bones.root then list[1] = bones.root end
	for _, aux in ipairs(bones.auxRoots or {}) do
		list[#list + 1] = aux
	end
	return list
end

function Apply.StripIKFromBones(ply, bones)
	-- undo what ik did to the bones before reading the animated pose.
	-- only strips values that are still exactly what we wrote, anything
	-- another addon changed in between is left alone
	local blendState = ply.IKBlendState
	if not blendState or not bones then return end

	for _, bone in ipairs(PositionBones(bones)) do
		local entry = blendState.pos[bone]
		if entry and entry.final then
			local current = RT.GetCurrentBonePosition(ply, bone)
			if RT.VecNear(current, entry.final, STRIP_POS_EPS) then
				RT.SetBonePosition(ply, bone, current - entry.applied)
				entry.final = current - entry.applied
				entry.applied = Vector()
			end
		end
	end

	for _, bone in ipairs(ManagedBones(bones)) do
		local entry = bone and blendState.ang[bone]
		if entry and entry.final then
			local current = RT.GetCurrentBoneAngles(ply, bone)
			if RT.AngNear(current, entry.final, STRIP_ANG_EPS) then
				local base = Angle(current.p - entry.applied.p, current.y - entry.applied.y, current.r - entry.applied.r)
				RT.SetBoneAngles(ply, bone, base)
				entry.final = base
				entry.applied = Angle()
			end
		end
	end
end

function Apply.BuildSkeleton(ply, bones)
	-- reads the animated pose (ik must be stripped and bones set up first)
	local plyPos = ply:GetPos()
	local legs = {}
	for side, ids in pairs({ left = { bones.lThigh, bones.lCalf, bones.lFoot }, right = { bones.rThigh, bones.rCalf, bones.rFoot } }) do
		local thighPos, thighAng = GetBoneWorldTransform(ply, ids[1], plyPos)
		local calfPos, calfAng = GetBoneWorldTransform(ply, ids[2], plyPos)
		local footPos, footAng = GetBoneWorldTransform(ply, ids[3], plyPos)
		if not (thighPos and calfPos and footPos) then return nil end
		legs[side] = {
			thighPos = thighPos, thighAng = thighAng,
			calfPos = calfPos, calfAng = calfAng,
			footPos = footPos, footAng = footAng,
		}
	end

	-- bone lengths are rigid, measure once per model. only cache sane values,
	-- on the very first frame the matrices can still be garbage
	if ply.IKMeasuredModel ~= bones.model then
		local l, r = legs.left, legs.right
		local measured = (l.thighPos:Distance(l.calfPos) + l.calfPos:Distance(l.footPos)
			+ r.thighPos:Distance(r.calfPos) + r.calfPos:Distance(r.footPos)) * 0.5
		if measured > 8 then
			ply.IKMeasuredLegLength = measured
			ply.IKMeasuredModel = bones.model
		end
	end

	local spineAng
	if bones.leanBone then
		local _, ang = GetBoneWorldTransform(ply, bones.leanBone, plyPos)
		spineAng = ang
	end

	return {
		legLength = ply.IKMeasuredLegLength or RT.REFERENCE_LEG_LENGTH,
		left = legs.left,
		right = legs.right,
		spineAng = spineAng,
	}
end

function Apply.ResetPlayer(ply, bones)
	-- remove our offsets (keeping other addons' ones) and forget the state
	bones = bones or ply.IKBones
	if bones and bones.valid then
		for _, bone in ipairs(PositionBones(bones)) do
			RT.ApplyBlendedBonePosition(ply, bone, Vector())
		end
		for _, bone in ipairs(ManagedBones(bones)) do
			RT.ApplyBlendedBoneAngles(ply, bone, Angle())
		end
	end
	RT.State.Reset(ply)
end

function Apply.HardResetPlayer(ply)
	-- the nuclear reset. bypasses the blend layer and zeros every bone we
	-- could ever have touched, on this model and on the bone set we cached
	local list = {}
	for _, set in ipairs({ ply.IKBones or {}, RT.GetIKBones(ply) }) do
		if set.valid then
			for _, b in ipairs(PositionBones(set)) do list[#list + 1] = b end
			for _, b in ipairs(ManagedBones(set)) do list[#list + 1] = b end
		end
	end

	local usePac = istable(pac) and isfunction(pac.ManipulateBonePosition) and isfunction(pac.ManipulateBoneAngles)
	for _, bone in ipairs(list) do
		ply:ManipulateBonePosition(bone, Vector())
		ply:ManipulateBoneAngles(bone, Angle())
		if usePac then
			pcall(pac.ManipulateBonePosition, ply, bone, Vector())
			pcall(pac.ManipulateBoneAngles, ply, bone, Angle())
		end
	end

	RT.State.HardReset(ply)

	if IsValid(ply) then
		if ply.InvalidateBoneCache then ply:InvalidateBoneCache() end
		ply:SetupBones()
	end
end

function Apply.ApplyResult(ply, bones, result)
	local drop = result.bodyDrop
	if not IsFiniteNumber(drop) then drop = 0 end

	-- position manipulation of a root bone is in model space, which is
	-- scaled by the entity's model scale
	local modelScale = math.max(ply:GetModelScale() or 1, 0.01)
	local offset = Vector(0, 0, -drop / modelScale)

	for _, bone in ipairs(PositionBones(bones)) do
		RT.ApplyBlendedBonePosition(ply, bone, offset)
	end

	for _, side in ipairs({ "left", "right" }) do
		local leg = result[side]
		local prefix = side == "left" and "l" or "r"
		local thigh = IsFiniteAngle(leg.thigh) and leg.thigh or Angle()
		local calf = IsFiniteAngle(leg.calf) and leg.calf or Angle()
		local foot = IsFiniteAngle(leg.foot) and leg.foot or Angle()
		RT.ApplyBlendedBoneAngles(ply, bones[prefix .. "Thigh"], thigh)
		RT.ApplyBlendedBoneAngles(ply, bones[prefix .. "Calf"], calf)
		RT.ApplyBlendedBoneAngles(ply, bones[prefix .. "Foot"], foot)
	end

	if bones.leanBone then
		local lean = result.leanAng
		RT.ApplyBlendedBoneAngles(ply, bones.leanBone, IsFiniteAngle(lean) and lean or Angle())
	end
end
