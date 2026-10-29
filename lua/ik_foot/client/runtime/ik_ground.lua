if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

local RT = IKFoot.Runtime
RT.Ground = RT.Ground or {}
local Ground = RT.Ground

local WALKABLE_Z = 0.7 -- same as source's walkable slope (~45 deg)
local COLOR_LEFT  = Color(80, 190, 255)
local COLOR_RIGHT = Color(255, 165, 90)
-- only average samples within this many units of the highest hit.
-- prevents low-side (ground/air) samples from dragging the contact down
-- when the foot is half on a curb or step edge.
local CLUSTER_TOLERANCE = 2.0

local SAMPLE_WEIGHTS = { center = 4, toe = 2, heel = 2, inner = 1, outer = 1 }
local SAMPLE_NAMES = { "center", "toe", "heel", "inner", "outer" }

local HULL_MINS = Vector(-1.5, -1.5, 0)
local HULL_MAXS = Vector(1.5, 1.5, 2)

local function IsWalkable(normal)
	return normal and normal.z >= WALKABLE_Z
end
Ground.IsWalkable = IsWalkable

-- players are filtered with a table (much cheaper than a lua filter callback,
-- which runs for every entity the trace touches). rebuilt once per frame
local filterFrame, filterList = -1, {}
local function TraceFilter()
	local frame = FrameNumber()
	if frame ~= filterFrame then
		filterFrame = frame
		filterList = player.GetAll()
	end
	return filterList
end

local traceData = { mask = MASK_PLAYERSOLID }
local traceOut = {}

local function TraceDown(startPos, length, useHull)
	traceData.start = startPos
	traceData.endpos = startPos - Vector(0, 0, length)
	traceData.filter = TraceFilter()
	traceData.output = traceOut
	if useHull then
		traceData.mins = HULL_MINS
		traceData.maxs = HULL_MAXS
		util.TraceHull(traceData)
	else
		traceData.mins = nil
		traceData.maxs = nil
		util.TraceLine(traceData)
	end
	return traceOut
end
Ground.TraceDown = TraceDown

local function ClassifySurface(tr)
	if tr.HitWorld then return "world", true, NULL end
	local ent = tr.Entity
	if not IsValid(ent) then return "none", false, NULL end
	if ent:IsRagdoll() then return "ragdoll", true, ent end
	local class = ent:GetClass()
	if string.StartWith(class, "prop_") or class == "func_physbox" or string.StartWith(class, "func_") then
		return "prop", true, ent
	end
	return "other", true, ent
end

local function IsFiniteVec(v)
	return v.x == v.x and v.y == v.y and v.z == v.z
		and v.x > -math.huge and v.x < math.huge and v.z > -math.huge and v.z < math.huge
end

function Ground.TraceSample(startPos, groundDist, soleOffset, maxSurfaceSpeed, useHull)
	local tr = TraceDown(startPos, groundDist, useHull)

	if tr.Hit and not tr.StartSolid and IsWalkable(tr.HitNormal) then
		local normal = Vector(tr.HitNormal)
		local hitPos = tr.HitPos + vector_up * soleOffset
		if IsFiniteVec(hitPos) then
			local surfaceType, surfaceAllowed, surfaceEnt = ClassifySurface(tr)
			local surfaceSpeed = 0
			if IsValid(surfaceEnt) then
				surfaceSpeed = surfaceEnt:GetVelocity():Length()
			end
			return {
				hit = true,
				hitPos = hitPos,
				normal = normal,
				startPos = Vector(startPos),
				surfaceType = surfaceType,
				surfaceStable = surfaceType == "world" or (surfaceAllowed and surfaceSpeed <= maxSurfaceSpeed),
				entity = surfaceEnt,
			}
		end
	end

	return {
		hit = false,
		hitPos = startPos - Vector(0, 0, groundDist),
		normal = Vector(0, 0, 1),
		startPos = Vector(startPos),
		surfaceType = "none",
		surfaceStable = false,
		entity = NULL,
	}
end

-- 5 traces per foot (was 9 hull traces with lua filters). center uses a small
-- hull so it doesnt slip through thin gaps, the rest are lines
function Ground.SampleFoot(footPos, forward, traceStartZ, groundDist, isLeft, scale, soleOffset, maxSurfaceSpeed)
	local fwd = Vector(forward.x, forward.y, 0)
	if fwd:LengthSqr() < 0.001 then fwd = Vector(1, 0, 0) else fwd:Normalize() end
	local right = Vector(fwd.y, -fwd.x, 0)

	local sideSign = isLeft and -1 or 1
	local base = Vector(footPos.x, footPos.y, traceStartZ)
	local toeLen, heelLen, halfW = 5 * scale, 3 * scale, 2 * scale

	local offsets = {
		center = vector_origin,
		toe    = fwd * toeLen,
		heel   = fwd * -heelLen,
		outer  = right * (halfW * sideSign),
		inner  = right * (-halfW * sideSign),
	}

	local samples = {}
	for _, name in ipairs(SAMPLE_NAMES) do
		samples[name] = Ground.TraceSample(base + offsets[name], groundDist, soleOffset, maxSurfaceSpeed, name == "center")
	end
	samples._forward = fwd
	samples._right = right
	return samples
end

function Ground.ResolveContact(samples, fallbackPos)
	-- find the highest valid hit first so we can cluster around it.
	-- this stops low-side samples (the "air" side of a curb) from dragging
	-- the contact position down into geometry or off into space.
	local highestZ = -math.huge
	for _, name in ipairs(SAMPLE_NAMES) do
		local s = samples[name]
		if s and s.hit and s.hitPos.z > highestZ then
			highestZ = s.hitPos.z
		end
	end
	local clusterFloor = highestZ - CLUSTER_TOLERANCE

	local totalWeight, hitCount, stableWeight = 0, 0, 0
	local zSum = 0
	local normalSum = Vector()
	local surfaceWeights = {}
	local bestEntity, bestEntityWeight = NULL, 0

	for _, name in ipairs(SAMPLE_NAMES) do
		local s = samples[name]
		if s and s.hit and s.hitPos.z >= clusterFloor then
			local w = SAMPLE_WEIGHTS[name] or 1
			totalWeight = totalWeight + w
			zSum = zSum + s.hitPos.z * w
			normalSum:Add(s.normal * w)
			hitCount = hitCount + 1
			surfaceWeights[s.surfaceType] = (surfaceWeights[s.surfaceType] or 0) + w
			if s.surfaceStable then stableWeight = stableWeight + w end
			if IsValid(s.entity) and w > bestEntityWeight then
				bestEntity = s.entity
				bestEntityWeight = w
			end
		end
	end

	local pos = Vector(fallbackPos)
	local normal = Vector(0, 0, 1)
	if totalWeight > 0 then
		pos.z = zSum / totalWeight
		if normalSum:LengthSqr() > 0.001 then
			normal = normalSum:GetNormalized()
		end
	end

	local dominant, dominantWeight = "none", 0
	for surfaceType, weight in pairs(surfaceWeights) do
		if weight > dominantWeight then
			dominant, dominantWeight = surfaceType, weight
		end
	end

	return {
		hasHit = hitCount > 0,
		hitCount = hitCount,
		position = pos,
		-- top of whatever is under the foot. used by anti-clip so a foot that
		-- straddles an edge rests on the edge instead of sinking into it
		highestZ = hitCount > 0 and highestZ or pos.z,
		normal = normal,
		samples = samples,
		surfaceType = dominant,
		surfaceStable = totalWeight > 0 and stableWeight >= totalWeight * 0.5,
		surfaceEntity = bestEntity,
	}
end

-- =====================================================================
-- stair profile scanner
-- =====================================================================
-- samples ground height along the movement direction and splits it into
-- flat treads separated by step edges. the stepper uses the treads to put
-- each foot on a real step instead of wherever the walk animation lands.

function Ground.ScanStairs(origin, dir, scale, minStep, maxStep, soleOffset)
	local stepLen = 2 * scale
	local sMin, sMax = -28 * scale, 52 * scale
	local topZ = origin.z + maxStep + 6 * scale
	local length = maxStep * 3 + 12 * scale
	local flatTol = math.max(0.6, 0.25 * scale)

	local heights = {}
	local n = 0
	for s = sMin, sMax, stepLen do
		n = n + 1
		local tr = TraceDown(Vector(origin.x + dir.x * s, origin.y + dir.y * s, topZ), length, false)
		if tr.Hit and not tr.StartSolid and IsWalkable(tr.HitNormal) then
			heights[n] = { s = s, z = tr.HitPos.z + soleOffset }
		else
			heights[n] = { s = s, z = nil }
		end
	end

	-- group into treads
	local treads = {}
	local cur = nil
	local function Close(edgeAfter)
		if cur then
			cur.edgeAfter = edgeAfter
			treads[#treads + 1] = cur
			cur = nil
		end
	end
	for i = 1, n do
		local h = heights[i]
		if not h.z then
			Close(false)
		elseif not cur then
			cur = { s0 = h.s, s1 = h.s, z = h.z, zMin = h.z, zMax = h.z, count = 1, edgeBefore = false }
		else
			local dz = h.z - cur.z
			if math.abs(dz) <= flatTol then
				cur.s1 = h.s
				cur.count = cur.count + 1
				cur.zMin = math.min(cur.zMin, h.z)
				cur.zMax = math.max(cur.zMax, h.z)
				-- running mean keeps slightly noisy treads together
				cur.z = cur.z + (h.z - cur.z) / cur.count
			else
				local isEdge = math.abs(dz) >= minStep * 0.8 and math.abs(dz) <= maxStep
				Close(isEdge)
				cur = { s0 = h.s, s1 = h.s, z = h.z, zMin = h.z, zMax = h.z, count = 1, edgeBefore = isEdge }
			end
		end
	end
	Close(false)

	-- the edge sits halfway between the last sample of one tread and the
	-- first of the next. extend treads to it so they tile the profile
	for i = 1, #treads - 1 do
		local a, b = treads[i], treads[i + 1]
		if a.edgeAfter and b.edgeBefore then
			local mid = (a.s1 + b.s0) * 0.5
			a.s1, b.s0 = mid, mid
		end
	end

	-- count consistent edges near the player
	local edges, upCount, downCount = 0, 0, 0
	local riseSum, depthSum, depthCount = 0, 0, 0
	for i = 1, #treads - 1 do
		local a, b = treads[i], treads[i + 1]
		if a.edgeAfter and b.edgeBefore and b.s0 > -20 * scale and a.s1 < 44 * scale then
			edges = edges + 1
			local rise = b.z - a.z
			riseSum = riseSum + math.abs(rise)
			if rise > 0 then upCount = upCount + 1 else downCount = downCount + 1 end
			-- inner treads (bounded by edges on both sides) give the depth
			if b.edgeAfter and i + 1 < #treads then
				depthSum = depthSum + (b.s1 - b.s0)
				depthCount = depthCount + 1
			end
		end
	end

	local consistent = math.max(upCount, downCount)
	local depth = depthCount > 0 and depthSum / depthCount or 0
	local isStairs = consistent >= 2 and depthCount >= 1
		and depth >= 5 * scale and depth <= 40 * scale

	return {
		isStairs = isStairs,
		treads = treads,
		origin = Vector(origin),
		dir = Vector(dir),
		rise = edges > 0 and riseSum / edges or 0,
		depth = depth,
		ascending = upCount >= downCount,
		edges = edges,
		samples = heights,
	}
end

-- along-track coordinate of a world position in a scan
function Ground.ScanCoord(scan, pos)
	return (pos.x - scan.origin.x) * scan.dir.x + (pos.y - scan.origin.y) * scan.dir.y
end

function Ground.TreadIndexAt(scan, s)
	local treads = scan.treads
	local best, bestDist = nil, math.huge
	for i, t in ipairs(treads) do
		if s >= t.s0 and s <= t.s1 then return i end
		local d = s < t.s0 and (t.s0 - s) or (s - t.s1)
		if d < bestDist then best, bestDist = i, d end
	end
	return best
end

function Ground.DrawSamples(samples, boxColor, normalColor, debugLevel)
	for _, name in ipairs(SAMPLE_NAMES) do
		local s = samples[name]
		local isCenter = name == "center"
		if s and s.hit and (isCenter or debugLevel > 1) then
			local col = isCenter and boxColor or Color(boxColor.r, boxColor.g, boxColor.b, 110)
			render.DrawWireframeBox(s.hitPos, angle_zero, HULL_MINS, HULL_MAXS, col, true)
			render.DrawLine(s.startPos, s.hitPos, col)
			render.DrawLine(s.hitPos, s.hitPos + s.normal * 6, normalColor)
		end
	end
end

function Ground.DrawScan(scan)
	if not scan then return end
	local colTread = scan.isStairs and Color(80, 255, 120) or Color(160, 160, 160)
	for _, t in ipairs(scan.treads) do
		local a = scan.origin + scan.dir * t.s0
		local b = scan.origin + scan.dir * t.s1
		a.z, b.z = t.z, t.z
		render.DrawLine(a, b, colTread, true)
	end
end

function Ground.DebugColors(isLeft)
	return isLeft and COLOR_LEFT or COLOR_RIGHT
end
