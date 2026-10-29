if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

local RT = IKFoot.Runtime
RT.Apply = RT.Apply or {}
local Apply = RT.Apply

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
	for _, f in ipairs(bones.followers or {}) do
		list[#list + 1] = f.bone
	end
	return list
end

local function PositionBones(bones)
	local list = {}
	if bones.root then list[1] = bones.root end
	for _, aux in ipairs(bones.auxRoots or {}) do
		list[#list + 1] = aux
	end
	for _, f in ipairs(bones.followers or {}) do
		list[#list + 1] = f.bone
	end
	return list
end

function Apply.StripIKFromBones(ply, bones)
	-- remove our contribution before reading the animated pose. only what we
	-- added is removed, other addons' / pac parts' offsets stay
	if not ply.IKBlendState or not bones then return end
	for _, bone in ipairs(PositionBones(bones)) do
		RT.ApplyBlendedBonePosition(ply, bone, vector_origin)
	end
	for _, bone in ipairs(ManagedBones(bones)) do
		RT.ApplyBlendedBoneAngles(ply, bone, angle_zero)
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

	-- animated transforms of the foot followers and the rotation of the space
	-- their position manipulation lives in (parent bone, or model space)
	local followers = {}
	local entAng = ply.GetRenderAngles and ply:GetRenderAngles() or ply:GetAngles()
	for i, f in ipairs(bones.followers or {}) do
		local pos, ang = GetBoneWorldTransform(ply, f.bone, plyPos)
		local parentAng
		if f.parent >= 0 then
			local _, pa = GetBoneWorldTransform(ply, f.parent, plyPos)
			parentAng = pa
		else
			parentAng = Angle(0, entAng.y, 0)
		end
		if pos and parentAng then
			followers[i] = { pos = pos, ang = ang, parentAng = parentAng }
		end
	end

	return {
		followers = followers,
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

	for _, bone in ipairs(list) do
		RT.ZeroBone(ply, bone)
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

	for _, bone in ipairs(bones.root and { bones.root } or {}) do
		RT.ApplyBlendedBonePosition(ply, bone, offset)
	end
	for _, bone in ipairs(bones.auxRoots or {}) do
		RT.ApplyBlendedBonePosition(ply, bone, offset)
	end
	for i, f in ipairs(bones.followers or {}) do
		local out = result.followers and result.followers[i]
		local pos = out and IsFiniteVector(out.pos) and out.pos or Vector()
		local ang = out and IsFiniteAngle(out.ang) and out.ang or Angle()
		RT.ApplyBlendedBonePosition(ply, f.bone, pos)
		RT.ApplyBlendedBoneAngles(ply, f.bone, ang)
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
