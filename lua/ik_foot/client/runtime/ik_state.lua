if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

local RT = IKFoot.Runtime
RT.State = RT.State or {}
local State = RT.State

local IDLE_ACQUIRE_DELAY = 0.14
local CROUCH_TRANSITION_TIME = 0.3
local SCAN_INTERVAL = 0.12
local STAIR_EXIT_DELAY = 0.25
local SWING_MIN_TIME = 0.07
local SWING_MAX_TIME = 0.45

local function IsFiniteNumber(v)
	return isnumber(v) and v == v and v > -math.huge and v < math.huge
end

local function IsFiniteVector(vec)
	return isvector(vec) and IsFiniteNumber(vec.x) and IsFiniteNumber(vec.y) and IsFiniteNumber(vec.z)
end
State.IsFiniteNumber = IsFiniteNumber
State.IsFiniteVector = IsFiniteVector

local function NewFoot()
	return {
		lockPos = nil,     -- world contact point while the foot is planted
		lastRawPos = nil,
		footSpeed = 0,
		planted = false,
		released = false,
		drop = nil,        -- smoothed ground offset (origin z - ground z)
		dropVel = 0,
		normal = Vector(0, 0, 1),
		restLocalAng = nil, -- foot orientation relative to body yaw when flat on the ground
	}
end

local function NewStepperFoot()
	return { plant = nil, swing = nil }
end

local function NewState()
	return {
		idle = { active = false, candidateTime = 0 },
		legs = { left = NewFoot(), right = NewFoot() },
		crouch = { crouching = false, transitionTime = 0, inTransition = false },
		body = { drop = nil, vel = 0, lastOriginZ = nil, wasOnGround = false, landDip = 0 },
		stairs = { scan = nil, scanTime = -math.huge, active = false, lastSeen = -math.huge },
		stepper = { blend = 0, feet = { left = NewStepperFoot(), right = NewStepperFoot() } },
		restHeight = nil,
		lean = { roll = 0, pitch = 0, lastVel = nil },
	}
end

function State.Get(ply)
	local s = ply.IKRuntimeState
	if not s then
		s = NewState()
		ply.IKRuntimeState = s
	end
	return s
end

function State.Reset(ply)
	-- wipe everything. without this the character becomes a horror show
	ply.IKRuntimeState = nil
	ply.IKResult = nil
	ply.IKMeasuredLegLength = nil
	ply.IKMeasuredModel = nil
	ply.IKBlendState = nil
	ply.IKFailCount = nil
end

function State.HardReset(ply)
	-- nuclear wipe. clears absolutely everything including bone cache
	State.Reset(ply)
	ply.IKBones = nil
	ply.IKLastKnownModel = nil
	ply.IKActive = nil
end

function State.SoftRecover(ply)
	if not IsValid(ply) then return end
	local old = ply.IKRuntimeState
	local fresh = NewState()
	-- keep calibration that is still valid for this model
	if old then
		fresh.restHeight = old.restHeight
		fresh.legs.left.restLocalAng = old.legs.left.restLocalAng
		fresh.legs.right.restLocalAng = old.legs.right.restLocalAng
	end
	ply.IKRuntimeState = fresh
	ply.IKSoftRecoverCount = (ply.IKSoftRecoverCount or 0) + 1
end

function State.UpdateCrouch(runtimeState, isCrouching, dt)
	local crouch = runtimeState.crouch
	if crouch.crouching ~= isCrouching then
		crouch.crouching = isCrouching
		crouch.transitionTime = 0
		crouch.inTransition = true
		-- unlock feet during crouch or they get stuck in weird places
		for _, leg in pairs(runtimeState.legs) do
			leg.planted = false
			leg.lockPos = nil
		end
		runtimeState.idle.active = false
		runtimeState.idle.candidateTime = 0
	end
	if crouch.inTransition then
		crouch.transitionTime = crouch.transitionTime + dt
		if crouch.transitionTime >= CROUCH_TRANSITION_TIME then
			crouch.inTransition = false
		end
	end
	return crouch
end

function State.UpdateIdle(runtimeState, onGround, velocity2D, vertVel, idleVelocityThreshold, dt)
	local idle = runtimeState.idle
	local isCandidate = onGround and velocity2D <= idleVelocityThreshold and math.abs(vertVel) <= (idleVelocityThreshold * 0.5)

	if isCandidate then
		idle.candidateTime = idle.candidateTime + dt
	else
		idle.candidateTime = 0
		idle.active = false
	end

	if isCandidate and idle.candidateTime >= IDLE_ACQUIRE_DELAY then
		idle.active = true
	end

	return idle
end

function State.MeasureFootSpeed(footState, rawFootPos, dt)
	if dt > 0 and footState.lastRawPos and IsFiniteVector(rawFootPos) then
		local dx = rawFootPos.x - footState.lastRawPos.x
		local dy = rawFootPos.y - footState.lastRawPos.y
		local speed = math.sqrt(dx * dx + dy * dy) / dt
		footState.footSpeed = IsFiniteNumber(speed) and speed or 0
	else
		footState.footSpeed = 0
	end
	if IsFiniteVector(rawFootPos) then
		footState.lastRawPos = Vector(rawFootPos)
	end
	return footState.footSpeed
end

-- foot lock. while the animated foot is planted we keep using the contact
-- height it was planted on instead of re-tracing every frame. this is what
-- stops feet flickering between two heights when they hover over a step edge
-- or a seam in the floor. (the old lock only ever affected the debug overlay)
function State.UpdateFootLock(footState, data)
	footState.released = false
	local contact = data.contact

	if not data.onGround or not contact.hasHit then
		footState.planted = false
		footState.lockPos = nil
		return nil
	end

	local acquireDist = math.max(2, 3.5 * data.lockStrength) * data.scale
	local releaseDist = math.max(acquireDist * 1.5, (3 + data.lockStrength * 4) * data.scale)
	local releaseSpeed = math.max(data.releaseSpeed, 5)

	if footState.lockPos then
		local dx = data.rawFootPos.x - footState.lockPos.x
		local dy = data.rawFootPos.y - footState.lockPos.y
		local dist2D = math.sqrt(dx * dx + dy * dy)
		local heightJump = math.abs(contact.position.z - footState.lockPos.z)
		local wantsRelease = dist2D > releaseDist
			or (data.footSpeed > releaseSpeed and not data.idleActive)
			or (data.plantWeight < 0.4 and not data.idleActive)
			-- the ground under a planted foot moved a lot (door, lift, prop): follow it
			or heightJump > 6 * data.scale
		if wantsRelease then
			footState.lockPos = nil
			footState.planted = false
			footState.released = true
		end
	end

	if not footState.lockPos then
		local canAcquire = data.idleActive
			or (data.plantWeight > 0.85 and data.footSpeed <= releaseSpeed * 0.5)
		if canAcquire then
			footState.lockPos = Vector(data.rawFootPos.x, data.rawFootPos.y, contact.position.z)
			footState.planted = true
		end
	end

	-- drift guard: if the planted contact is far below/above what the traces
	-- see right under the foot by more than an acquire distance, re-plant
	if footState.lockPos and math.abs(contact.position.z - footState.lockPos.z) > acquireDist and data.plantWeight > 0.85 then
		footState.lockPos.z = contact.position.z
	end

	return footState.lockPos and footState.lockPos.z or nil
end

-- source moves the player origin up/down a whole step in one tick when it
-- walks over a stair (and snaps down when walking off one). the old code fed
-- that straight into the body height, so the body popped a full step at a
-- time. here we detect those discrete jumps and return them so the smoothed
-- values can be shifted to stay put in world space.
function State.ConsumeOriginJump(runtimeState, originZ, velZ, dt, onGround, scale)
	local body = runtimeState.body
	local jump = 0
	if body.lastOriginZ and onGround and body.wasOnGround then
		local dz = originZ - body.lastOriginZ
		local unexplained = dz - velZ * dt
		if math.abs(unexplained) >= 2.5 * scale and math.abs(dz) <= 40 * scale then
			jump = dz
		end
	end
	body.lastOriginZ = originZ
	body.wasOnGround = onGround
	return jump
end

-- critically damped spring (same formula as unity's SmoothDamp)
function State.Spring(current, velocity, target, smoothTime, dt)
	if not (IsFiniteNumber(current) and IsFiniteNumber(velocity) and IsFiniteNumber(target)) then
		return IsFiniteNumber(target) and target or 0, 0
	end
	smoothTime = math.max(smoothTime, 0.0001)
	local omega = 2 / smoothTime
	local x = omega * dt
	local exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local change = current - target
	local temp = (velocity + omega * change) * dt
	local newVelocity = (velocity - omega * temp) * exp
	local newValue = target + (change + temp) * exp
	if not IsFiniteNumber(newValue) then return target, 0 end
	if not IsFiniteNumber(newVelocity) then newVelocity = 0 end
	return newValue, newVelocity
end

-- tracks how high the animated foot bone sits above the ground when the foot
-- is planted. converges to the lowest planted height of the animation.
function State.UpdateRestHeight(runtimeState, footHeight, dt, seed)
	local rest = runtimeState.restHeight or seed
	if not IsFiniteNumber(footHeight) then
		runtimeState.restHeight = rest
		return rest
	end
	local rate = footHeight < rest and 1 / 0.6 or 1 / 3
	rest = rest + (footHeight - rest) * (1 - math.exp(-dt * rate))
	runtimeState.restHeight = rest
	return rest
end

-- =====================================================================
-- stair stepper
-- =====================================================================
-- a proper stair gait: feet alternate and each foot lands on a real tread,
-- `treadsPerStep` treads ahead of the other foot. the old stepper only moved
-- the point where the ground was traced, the visible foot still followed
-- the walk cycle whose stride covers 2-4 treads - that was the long standing
-- "climbs several steps at once" bug.

function State.UpdateStairScan(runtimeState, now, origin, dir, scale, params, enabled)
	local stairs = runtimeState.stairs
	if not enabled then
		stairs.active = false
		stairs.scan = nil
		return nil
	end

	local scan = stairs.scan
	local needScan = not scan or (now - stairs.scanTime) >= SCAN_INTERVAL
	if scan and not needScan then
		local moved = math.abs(RT.Ground.ScanCoord(scan, origin))
		local dot = scan.dir.x * dir.x + scan.dir.y * dir.y
		needScan = moved > 6 * scale or dot < 0.96
	end

	if needScan then
		scan = RT.Ground.ScanStairs(origin, dir, scale,
			params.stair_step_min_height * scale, params.stair_step_max_height * scale,
			params.sole_offset + (params.soleCorrection or 0))
		stairs.scan = scan
		stairs.scanTime = now
		if scan.isStairs then stairs.lastSeen = now end
	end

	stairs.active = scan ~= nil and (scan.isStairs or (now - stairs.lastSeen) < STAIR_EXIT_DELAY)
	return scan
end

local function PlacementOnTread(scan, tread, lateral, right, footLen)
	local center = (tread.s0 + tread.s1) * 0.5
	local width = tread.s1 - tread.s0
	local s
	if width <= footLen * 1.2 then
		s = center
	else
		-- long tread (landing / top of stairs): stand near the edge we came from
		if scan.ascending then
			s = math.min(center, tread.s0 + footLen * 0.55)
		else
			s = math.min(center, tread.s0 + footLen * 0.45)
		end
	end
	local pos = scan.origin + scan.dir * s + right * lateral
	pos.z = tread.z
	return pos, s
end

local function Smoothstep(x)
	x = math.Clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- returns world ground positions (sole contact) for each foot, plus info.
-- data: scan, origin, dir, right, speed, dt, scale, legLength, treadsPerStep,
--       maxCadence, lift, animFeet = {left = pos, right = pos}, lateral = {left, right},
--       sampleGround(pos) -> z or nil (precise ground at a placement)
function State.UpdateStepper(runtimeState, data)
	local stepper = runtimeState.stepper
	local scan = data.scan
	local active = data.active and scan ~= nil and #scan.treads > 0

	local footLen = 9 * data.scale
	local depth = (scan and scan.depth > 0) and scan.depth or 12 * data.scale
	local maxCadence = math.max(data.maxCadence, 1)

	-- the body advances `treadsPerStep * depth` per step and a foot ends up at
	-- most ~0.75 of that in front of / behind the hip, which must stay within
	-- ~0.6 leg lengths -> at most 0.8 leg lengths of advance per step
	local maxTreads = math.max(1, math.floor(data.legLength * 0.8 / depth))

	-- treads per step: honour the minimum, go up when one tread per step would
	-- need more than the allowed cadence. hysteresis so the depth estimate
	-- jittering by half a unit cant flip it every frame
	local needed = data.speed / maxCadence / depth - 0.15
	local tps = stepper.treadsPerStep or math.max(math.ceil(needed), 1)
	if needed > tps + 0.15 then
		tps = tps + 1
	elseif needed < tps - 1.15 then
		tps = math.max(math.ceil(needed), 1)
	end
	tps = math.Clamp(math.max(tps, data.treadsPerStep), 1, maxTreads)
	stepper.treadsPerStep = tps
	local treadsPerStep = tps
	local strideAdvance = treadsPerStep * depth

	-- sprinting: no believable one-foot-per-stair gait exists, blend the legs
	-- back to the animation (which still gets the per-foot height correction)
	local cadenceNeeded = data.speed / (maxTreads * depth)
	local limit = stepper.tooFast and 1.25 or 1.4
	stepper.tooFast = cadenceNeeded > maxCadence * limit
	if stepper.tooFast then active = false end

	local rate = active and 7 or -5
	stepper.blend = math.Clamp(stepper.blend + data.dt * rate, 0, 1)

	if not active then
		if stepper.blend <= 0 then
			stepper.feet.left = NewStepperFoot()
			stepper.feet.right = NewStepperFoot()
		end
		-- keep the last positions while blending out
		local out = {}
		for side, f in pairs(stepper.feet) do
			if f.swing then
				f.plant = f.swing.to
				f.swing = nil
			end
			out[side] = f.plant and { ground = f.plant, phase = "planted", t = 0 } or nil
		end
		return out, stepper.blend, treadsPerStep
	end

	local sBody = RT.Ground.ScanCoord(scan, data.origin)
	local function Place(side, treadIndex)
		local tread = scan.treads[math.Clamp(treadIndex, 1, #scan.treads)]
		local pos, s = PlacementOnTread(scan, tread, data.lateral[side], data.right, footLen)
		local z = data.sampleGround(pos)
		if z and math.abs(z - tread.z) < 4 * data.scale then pos.z = z end
		return pos, s
	end

	-- seed plants from where the animation currently has the feet, but never
	-- further from the body than a comfortable half stride
	local seedRange = data.legLength * 0.4
	for _, side in ipairs({ "left", "right" }) do
		local f = stepper.feet[side]
		if not f.plant and not f.swing then
			local s = math.Clamp(RT.Ground.ScanCoord(scan, data.animFeet[side]), sBody - seedRange, sBody + seedRange)
			f.plant = Place(side, RT.Ground.TreadIndexAt(scan, s) or 1)
		end
	end

	local left, right = stepper.feet.left, stepper.feet.right
	local reach = data.legLength * 0.85

	-- safety: a planted foot that ended up out of reach (teleport, very high
	-- speed, scan glitch) is re-planted under the animated foot
	for _, side in ipairs({ "left", "right" }) do
		local f = stepper.feet[side]
		if f.plant and not f.swing then
			local dx, dy = f.plant.x - data.origin.x, f.plant.y - data.origin.y
			if dx * dx + dy * dy > reach * reach then
				local s = math.Clamp(RT.Ground.ScanCoord(scan, data.animFeet[side]), sBody - seedRange, sBody + seedRange)
				f.plant = Place(side, RT.Ground.TreadIndexAt(scan, s) or 1)
			end
		end
	end

	-- start a swing for the trailing foot once the body is over the lead foot.
	-- a foot that is still in the air counts at its landing spot; once it is
	-- most of the way there the other foot may already lift (otherwise a slow
	-- swing leaves the trailing foot stranded far behind the body)
	local function FootCoord(f)
		return RT.Ground.ScanCoord(scan, f.plant or f.swing.to)
	end
	if data.speed > data.idleSpeed then
		local sL, sR = FootCoord(left), FootCoord(right)
		local leadSide, trailSide = "left", "right"
		local sLead, sTrail = sL, sR
		if sR > sL then leadSide, trailSide, sLead, sTrail = "right", "left", sR, sL end
		local trail, lead = stepper.feet[trailSide], stepper.feet[leadSide]

		local behind = sBody - sTrail
		local leadReady = not lead.swing or (lead.swing.t >= 0.65 and behind > reach * 0.55)
		local wantsStep = sBody >= sLead - 0.25 * strideAdvance or behind > reach * 0.7
		if not trail.swing and leadReady and wantsStep then
			local leadIdx = RT.Ground.TreadIndexAt(scan, sLead) or 1
			local targetIdx = leadIdx + treadsPerStep
			local toPos, sTo
			if targetIdx <= #scan.treads then
				toPos, sTo = Place(trailSide, targetIdx)
			else
				-- scan ran out: extrapolate one stride along the slope
				local lastTread = scan.treads[#scan.treads]
				sTo = sLead + strideAdvance
				toPos = scan.origin + scan.dir * sTo + data.right * data.lateral[trailSide]
				toPos.z = lastTread.z
			end
			-- never step further than the leg can reach from where the body will be
			if sTo - sBody < reach then
				trail.swing = {
					from = trail.plant,
					to = toPos,
					t = 0,
					-- world space: the scan is rebuilt every few frames, its
					-- coordinates are not stable across a whole step
					bodyStart = Vector(data.origin),
					dir = Vector(scan.dir),
					bodyTravel = math.max(0.375 * (sTo - sTrail), 0.5 * depth),
					ascending = toPos.z > trail.plant.z + 0.5,
					descending = toPos.z < trail.plant.z - 0.5,
				}
				trail.plant = nil
			end
		end
	elseif not left.swing and not right.swing then
		-- standing still: a foot left far from under the body (stopped mid
		-- stride, turned around) takes one calm step onto the tread under the
		-- hips, one foot at a time. otherwise it stays planted far away and
		-- the leg ends up stretched out sideways or backwards
		local settleDist = data.legLength * 0.22
		local worstSide, worstDist = nil, settleDist
		for _, side in ipairs({ "left", "right" }) do
			local d = math.abs(FootCoord(stepper.feet[side]) - sBody)
			if d > worstDist then worstSide, worstDist = side, d end
		end
		if worstSide then
			local f = stepper.feet[worstSide]
			local toPos, sTo = Place(worstSide, RT.Ground.TreadIndexAt(scan, sBody) or 1)
			-- only if it is a real improvement (long landings place the foot
			-- near the edge, which must not cause an endless re-step)
			if math.abs(sTo - sBody) < worstDist - 1 then
				f.swing = {
					from = f.plant,
					to = toPos,
					t = 0,
					bodyStart = Vector(data.origin),
					dir = Vector(scan.dir),
					bodyTravel = math.huge, -- purely time based
					ascending = toPos.z > f.plant.z + 0.5,
					descending = toPos.z < f.plant.z - 0.5,
				}
				f.plant = nil
			end
		end
	end

	local out = {}
	for _, side in ipairs({ "left", "right" }) do
		local f = stepper.feet[side]
		local swing = f.swing
		if swing then
			-- progress follows the body, but never slower than SWING_MAX_TIME
			-- (so a stopping player doesnt leave a foot hanging) nor faster than
			-- SWING_MIN_TIME (so it never teleports)
			local moved = (data.origin.x - swing.bodyStart.x) * swing.dir.x + (data.origin.y - swing.bodyStart.y) * swing.dir.y
			local tBody = moved / swing.bodyTravel
			local tNew = math.max(tBody, swing.t + data.dt / SWING_MAX_TIME)
			tNew = math.min(tNew, swing.t + data.dt / SWING_MIN_TIME)
			swing.t = math.Clamp(tNew, 0, 1)
			if swing.t >= 1 then
				f.plant = swing.to
				f.swing = nil
				out[side] = { ground = Vector(f.plant), phase = "planted", t = 0 }
			else
				local t = swing.t
				-- going up the foot rises first and moves forward late,
				-- going down it moves forward first and drops late
				local hT, vT
				if swing.ascending then
					hT, vT = Smoothstep((t - 0.15) / 0.85), Smoothstep(t / 0.6)
				elseif swing.descending then
					hT, vT = Smoothstep(t / 0.8), Smoothstep((t - 0.35) / 0.65)
				else
					hT, vT = Smoothstep(t), Smoothstep(t)
				end
				local from, to = swing.from, swing.to
				local ground = Vector(
					from.x + (to.x - from.x) * hT,
					from.y + (to.y - from.y) * hT,
					from.z + (to.z - from.z) * vT
				)
				local supportZ = from.z + (to.z - from.z) * t
				out[side] = {
					ground = ground,
					supportZ = supportZ,
					lift = math.sin(t * math.pi) * data.lift,
					phase = "swinging",
					t = t,
					ascending = swing.ascending,
				}
			end
		elseif f.plant then
			out[side] = { ground = Vector(f.plant), phase = "planted", t = 0 }
		end
	end

	return out, stepper.blend, treadsPerStep
end
