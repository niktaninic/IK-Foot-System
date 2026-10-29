if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

local RT = IKFoot.Runtime
RT.Solver = RT.Solver or {}
local Solver = RT.Solver

-- analytical two-bone leg ik.
--
-- the old solver bent the knee with thigh = -k / calf = +k where
-- k = asin(lift / (leg/2)) * 1.7. that keeps the calf parallel to its
-- animated direction, so the foot moved forward by l*sin(k) and up by only
-- l*(1-cos(k)) - the 1.7 "boost" was there to hide the wrong formula.
--
-- this version solves the real triangle (law of cosines) for the exact
-- target position, keeps the knee in the animated bend plane, and converts
-- the world-space rotations into bone-local manipulation angles. nothing in
-- here assumes a particular rig axis convention.

local DEG = 180 / math.pi
local MIN_REACH_FRAC = 0.30 -- knee never folds tighter than this fraction of the leg
local MAX_REACH_FRAC = 0.999

-- every formula below assumes right-handed axis rotations. verify that once
-- against the engine instead of trusting it: +90 around +Z must turn +X into +Y
local HANDED = 1
do
	local probe = Angle(0, 0, 0)
	probe:RotateAroundAxis(Vector(0, 0, 1), 90)
	local v = Vector(1, 0, 0)
	v:Rotate(probe)
	if v.y < 0 then HANDED = -1 end
end

local function RotationBetween(a, b)
	local cross = a:Cross(b)
	local s = cross:Length()
	local c = a:Dot(b)
	if s < 1e-6 then
		return nil, 0
	end
	return cross / s, math.atan2(s, c) * DEG
end
Solver.RotationBetween = RotationBetween

local function RotateAngle(ang, axis, deg)
	local out = Angle(ang.p, ang.y, ang.r)
	if axis and deg ~= 0 then
		out:RotateAroundAxis(axis, deg * HANDED)
	end
	return out
end
Solver.RotateAngle = RotateAngle

local function RotateVector(vec, axis, deg)
	local out = Vector(vec)
	if axis and deg ~= 0 then
		local r = Angle(0, 0, 0)
		r:RotateAroundAxis(axis, deg * HANDED)
		out:Rotate(r)
	end
	return out
end
Solver.RotateVector = RotateVector

-- manipulation angles are applied in the bone's own frame (post-multiplied),
-- so the manip that turns orientation `from` into `to` is from^-1 * to
local function LocalDelta(from, to)
	local _, ang = WorldToLocal(vector_origin, to, vector_origin, from)
	return ang
end
Solver.LocalDelta = LocalDelta

-- rotation of `deg` around world `axis`, as a manipulation angle of a bone
-- whose world orientation is `boneAng`
local function AxisAngleLocal(boneAng, axis, deg)
	if not axis or deg == 0 then return Angle() end
	local localAxis = WorldToLocal(axis, angle_zero, vector_origin, boneAng)
	return RotateAngle(Angle(0, 0, 0), localAxis, deg)
end

-- distance limits from hip for a leg with segment lengths a, b
function Solver.ReachLimits(a, b)
	local total = a + b
	return math.max(math.abs(a - b) + 0.05 * total, MIN_REACH_FRAC * total), MAX_REACH_FRAC * total
end

-- H, K, F: animated hip, knee, ankle positions (world, already shifted by body drop)
-- T: desired ankle position (world)
-- poleHint: direction the knee should point when the leg is nearly straight
-- returns new knee and ankle positions
function Solver.SolveTwoBone(H, K, F, T, poleHint)
	local a = H:Distance(K)
	local b = K:Distance(F)
	if a < 0.01 or b < 0.01 then return nil end

	local toT = T - H
	local dist = toT:Length()
	if dist < 1e-3 then return nil end
	local dir = toT / dist

	local dMin, dMax = Solver.ReachLimits(a, b)
	local requested = dist
	dist = math.Clamp(dist, dMin, dMax)
	local limit = requested > dMax and "too_far" or (requested < dMin and "too_close" or nil)

	-- law of cosines: distance of the knee along hip->target, and off it
	local x = (a * a - b * b + dist * dist) / (2 * dist)
	local y = math.sqrt(math.max(a * a - x * x, 0))

	-- keep the knee in the plane the animation bent it in. blend toward the
	-- hint when the animated leg is almost straight and that plane is noise
	local hf = F - H
	local hfLen = hf:Length()
	local pole = Vector(poleHint)
	if hfLen > 1e-3 then
		local u = hf / hfLen
		local kh = K - H
		local offset = kh - u * kh:Dot(u)
		local offLen = offset:Length()
		local w = math.Clamp(offLen / (0.08 * a), 0, 1)
		if offLen > 1e-4 then
			pole = (offset / offLen) * w + poleHint * (1 - w)
		end
	end
	pole = pole - dir * pole:Dot(dir)
	if pole:LengthSqr() < 1e-6 then
		pole = poleHint - dir * poleHint:Dot(dir)
		if pole:LengthSqr() < 1e-6 then return nil end
	end
	pole:Normalize()

	return H + dir * x + pole * y, H + dir * dist, {
		upper = a, lower = b, requested = requested, minReach = dMin, maxReach = dMax, limit = limit,
	}
end

-- full leg solve -> manipulation angles for thigh, calf and foot.
-- leg: { thighPos, thighAng, calfPos, calfAng, footPos, footAng } (animated, world)
-- drop: vertical body offset applied to the whole chain
-- target: desired ankle position (world)
-- footTargetAng: desired world orientation of the foot (nil = keep animated)
function Solver.SolveLeg(leg, drop, target, footTargetAng, poleHint)
	local shift = Vector(0, 0, -drop)
	local H = leg.thighPos + shift
	local K = leg.calfPos + shift
	local F = leg.footPos + shift

	local K2, F2, reach = Solver.SolveTwoBone(H, K, F, target, poleHint)
	if not K2 then return nil end

	local axT, angT = RotationBetween((K - H):GetNormalized(), (K2 - H):GetNormalized())
	local calfDir1 = RotateVector(F - K, axT, angT):GetNormalized()
	local calfDir2 = (F2 - K2):GetNormalized()
	local axC, angC = RotationBetween(calfDir1, calfDir2)

	-- a world rotation R applied to a bone with orientation O equals the local
	-- manipulation O^-1 R O: same angle, axis expressed in the bone's frame.
	-- building it from the axis directly never goes through world-space euler
	-- angles, which are degenerate for leg bones (they point straight down)
	local thighManip = AxisAngleLocal(leg.thighAng, axT, angT)
	-- the calf frame has already been carried by the thigh rotation:
	-- local axis = calf^-1 * thighRot^-1 * axC
	local calfManip = axC and AxisAngleLocal(leg.calfAng, RotateVector(axC, axT, -angT), angC) or Angle()
	-- foot: undo both parent rotations from the wanted orientation, then take
	-- the remaining difference to the animated foot
	local footWorld = footTargetAng or leg.footAng
	local footUndone = RotateAngle(RotateAngle(footWorld, axC, -angC), axT, -angT)

	return {
		thigh = thighManip,
		calf = calfManip,
		foot = LocalDelta(leg.footAng, footUndone),
		knee = K2,
		ankle = F2,
		hip = H,
		reached = F2:DistToSqr(target) < 0.25,
		reach = reach,
		-- world rotations applied to the chain, for anything that has to move
		-- with the thigh or calf (foot followers parented inside the leg)
		thighAxis = axT, thighDeg = angT,
		calfAxis = axC, calfDeg = angC,
	}
end

-- lowest / highest body drop at which `target` is still reachable by this leg
function Solver.DropLimits(leg, target)
	local a = leg.thighPos:Distance(leg.calfPos)
	local b = leg.calfPos:Distance(leg.footPos)
	local dMin, dMax = Solver.ReachLimits(a, b)
	local dx = target.x - leg.thighPos.x
	local dy = target.y - leg.thighPos.y
	local horiz2 = dx * dx + dy * dy
	local dz = target.z - leg.thighPos.z -- negative: foot below hip

	-- (dz + drop)^2 + horiz^2 <= dMax^2  ->  drop >= -sqrt(dMax^2 - horiz^2) - dz
	local minDrop = -math.sqrt(math.max(dMax * dMax - horiz2, 0)) - dz
	-- (dz + drop)^2 + horiz^2 >= dMin^2  ->  drop <= -sqrt(dMin^2 - horiz^2) - dz
	local maxDrop = math.huge
	if horiz2 < dMin * dMin then
		maxDrop = -math.sqrt(dMin * dMin - horiz2) - dz
	end
	return minDrop, maxDrop
end
