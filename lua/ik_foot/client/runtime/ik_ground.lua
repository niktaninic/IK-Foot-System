if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

local RT = IKFoot.Runtime
RT.Ground = RT.Ground or {}
local Ground = RT.Ground

local WALKABLE_Z = 0.35
local COLOR_LEFT  = Color(80, 190, 255)
local COLOR_RIGHT = Color(255, 165, 90)

local SAMPLE_WEIGHTS = {
	center = 4, toe = 2, heel = 2,
	left = 2, right = 2,
	toeInner = 1, toeOuter = 1, inner = 1, outer = 1,
}

local function IsWalkable(normal)
	return normal and normal.z >= WALKABLE_Z
end

function Ground.TraceSample(ply, startPos, groundDist)
	-- shoots a trace down to find ground. sometimes finds it sometimes not
	local soleOffset = RT.GetIKParam(ply, "sole_offset")
	local endPos = startPos - Vector(0, 0, groundDist)

	local trace = util.TraceHull({
		start = startPos, endpos = endPos,
		mins = Vector(-2, -2, 0), maxs = Vector(2, 2, 4),
		filter = function(ent) return ent ~= ply and not ent:IsPlayer() end,
	})

	if trace.Hit and not IsWalkable(trace.HitNormal) then
		local fallback = util.TraceLine({
			start = startPos, endpos = endPos,
			filter = function(ent) return ent ~= ply and not ent:IsPlayer() end,
		})
		if fallback.Hit and IsWalkable(fallback.HitNormal) then
			trace = fallback
		else
			trace.Hit = false
		end
	end

	if trace.Hit then
		local normal = trace.HitNormal or vector_up
		local hitPos = trace.HitPos + normal * soleOffset
		-- if trace gave us nan pretend nothing happened
		if not (isvector(hitPos) and hitPos.x == hitPos.x and hitPos.y == hitPos.y and hitPos.z == hitPos.z) then
			return { hit = false, hitPos = endPos, normal = vector_up, distance = groundDist, startPos = startPos }
		end
		return { hit = true, hitPos = hitPos, normal = normal, distance = math.max(startPos.z - hitPos.z, 0), startPos = startPos }
	end

	return { hit = false, hitPos = endPos, normal = vector_up, distance = groundDist, startPos = startPos }
end

function Ground.SampleFoot(ply, footPos, footAng, traceStartZ, groundDist, isLeft)
	-- traces a bunch of points around the foot to figure out where ground is
	-- center toe heel and sides. probably overkill but whatever
	local fwd = footAng:Forward()
	fwd.z = 0
	if fwd:LengthSqr() < 0.001 then fwd = Vector(1, 0, 0) else fwd:Normalize() end

	local right = footAng:Right()
	right.z = 0
	if right:LengthSqr() < 0.001 then right = Vector(0, 1, 0) else right:Normalize() end

	local sideSign = isLeft and -1 or 1
	local outer = right * (2.5 * sideSign)
	local inner = -outer
	local startZ = math.max(traceStartZ, footPos.z + 8)
	local base = Vector(footPos.x, footPos.y, startZ)

	local offsets = {
		center   = Vector(),
		toe      = fwd * 5.5,
		heel     = -fwd * 3.5,
		left     = -right * 2.25,
		right    = right * 2.25,
		toeInner = fwd * 4 + inner * 0.75,
		toeOuter = fwd * 4 + outer * 0.75,
		outer    = outer,
		inner    = inner,
	}

	local samples = {}
	for name, offset in pairs(offsets) do
		samples[name] = Ground.TraceSample(ply, base + offset, groundDist)
	end
	return samples
end

function Ground.ResolveContact(samples, fallbackPos, fallbackNormal)
	-- average all samples into one contact point. weighted because some matter more
	local totalWeight, hitCount = 0, 0
	local posSum = Vector()
	local normalSum = Vector()
	local distSum = 0

	for name, s in pairs(samples) do
		if s.hit and IsWalkable(s.normal) then
			local w = SAMPLE_WEIGHTS[name] or 1
			totalWeight = totalWeight + w
			posSum = posSum + s.hitPos * w
			normalSum = normalSum + s.normal * w
			distSum = distSum + s.distance * w
			hitCount = hitCount + 1
		end
	end

	local pos, normal, dist = fallbackPos, fallbackNormal or vector_up, 0

	if totalWeight > 0 then
		pos = posSum / totalWeight
		normal = normalSum / totalWeight
		if normal:LengthSqr() < 0.001 then normal = vector_up else normal:Normalize() end
		dist = distSum / totalWeight
		-- weighted average went nan somehow. fall back to defaults
		if pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z then
			pos = fallbackPos
			hitCount = 0
		end
		if normal.x ~= normal.x or normal.y ~= normal.y or normal.z ~= normal.z then
			normal = vector_up
		end
	end

	return {
		hasHit = hitCount > 0,
		hitCount = hitCount,
		position = Vector(pos),
		normal = Vector(normal),
		supportDistance = dist,
		samples = samples,
	}
end

function Ground.ValidateContact(contact, samples, footBoneZ, soleOffset, tolerance)
	-- checks if contact makes sense or if foot is stuck in geometry
	-- this is the last line of defense against cursed terrain
	tolerance = tolerance or 0.5

	local result = {
		isValid = true,
		penetrationCount = 0,
		correctionZ = 0,
		highestValidZ = -math.huge,
		lowestHitZ = math.huge,
		invalidReason = nil,
		normalVariance = 0,
	}

	if not contact.hasHit then
		result.isValid = false
		result.invalidReason = "no_hit"
		return result
	end

	local expectedSoleZ = footBoneZ - soleOffset
	local totalHits = 0
	local belowSole = 0
	local penetrating = 0
	local normals = {}

	for _, s in pairs(samples) do
		if not s.hit then continue end
		totalHits = totalHits + 1
		normals[#normals + 1] = s.normal

		local rawHitZ = s.hitPos.z - soleOffset

		-- foot is inside the ground. this is bad
		if rawHitZ > footBoneZ + tolerance then
			penetrating = penetrating + 1
		end

		if rawHitZ < expectedSoleZ - tolerance * 2 then
			belowSole = belowSole + 1
		end

		if rawHitZ <= footBoneZ + tolerance and s.hitPos.z > result.highestValidZ then
			result.highestValidZ = s.hitPos.z
		end

		if s.hitPos.z < result.lowestHitZ then
			result.lowestHitZ = s.hitPos.z
		end
	end

	result.penetrationCount = penetrating

	-- most samples say foot is underground. time to correct
	if totalHits > 0 and penetrating / totalHits > 0.4 then
		result.isValid = false
		result.invalidReason = "penetrating"
		if result.highestValidZ > -math.huge then
			result.correctionZ = result.highestValidZ + soleOffset - footBoneZ
		else
			result.correctionZ = contact.position.z - footBoneZ
		end
	end

	if totalHits > 0 and belowSole / totalHits > 0.6 then
		result.invalidReason = result.invalidReason or "below_sole"
	end

	-- check if normals agree. if they dont the surface is sketchy
	if #normals >= 3 then
		local avgNormal = Vector()
		for _, n in ipairs(normals) do avgNormal:Add(n) end
		avgNormal:Div(#normals)
		if avgNormal:LengthSqr() > 0.001 then avgNormal:Normalize() end

		local variance = 0
		for _, n in ipairs(normals) do
			variance = variance + (1 - n:Dot(avgNormal))
		end
		result.normalVariance = variance / #normals

		if result.normalVariance > 0.35 then
			result.invalidReason = result.invalidReason or "inconsistent_normals"
		end
	end

	if contact.normal.z < WALKABLE_Z then
		result.isValid = false
		result.invalidReason = result.invalidReason or "steep_surface"
	end

	return result
end

function Ground.DrawSamples(samples, boxColor, normalColor, debugLevel)
	for name, s in pairs(samples) do
		if not s.hit then continue end
		local isCenter = name == "center"
		if debugLevel <= 1 and not isCenter then continue end
		local col = isCenter and boxColor or Color(boxColor.r, boxColor.g, boxColor.b, 110)
		render.DrawWireframeBox(s.hitPos, angle_zero, Vector(-2, -2, 0), Vector(2, 2, 4), col, true)
		render.DrawLine(s.startPos, s.hitPos, col)
		render.DrawLine(s.hitPos, s.hitPos + s.normal * 6, normalColor)
	end
end

function Ground.DebugColors(isLeft)
	return isLeft and COLOR_LEFT or COLOR_RIGHT
end