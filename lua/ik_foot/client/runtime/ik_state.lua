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
	return { plant = nil, swing = nil, starts = {}, lastReason = nil, blocked = nil }
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

-- height of the plane through `p` with normal `n` at the horizontal position of `q`
local function PlaneZ(p, n, q)
	n = n or vector_up -- a lock kept across a lua refresh from an older build
	return p.z - (n.x * (q.x - p.x) + n.y * (q.y - p.y)) / math.max(n.z, 0.5)
end
State.PlaneZ = PlaneZ

-- foot lock. while the animated foot is planted we keep using the ground it
-- was planted on instead of re-tracing every frame. this is what stops feet
-- flickering between two heights when they hover over a step edge or a seam
-- in the floor. the lock is the ground plane, not a fixed height: animations
-- let a planted foot slide a few units, and on a slope a fixed height left it
-- floating (or sunk) by slide * slope (4 units on a 27 deg ramp in the test)
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
		local heightJump = math.abs(data.groundZ - PlaneZ(footState.lockPos, footState.lockNormal, data.rawFootPos))
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
			-- same height the unlocked path uses (anti-clip highest point or the
			-- cluster average), otherwise acquiring the lock pops the foot
			footState.lockPos = Vector(data.rawFootPos.x, data.rawFootPos.y, data.groundZ)
			footState.lockNormal = Vector(contact.normal or vector_up)
			footState.lockTime = data.now
			footState.planted = true
		end
	end
	if not footState.lockPos then return nil end

	local lockZ = PlaneZ(footState.lockPos, footState.lockNormal, data.rawFootPos)
	-- drift guard: if the planted contact is far below/above what the traces
	-- see right under the foot by more than an acquire distance, re-plant
	if math.abs(data.groundZ - lockZ) > acquireDist and data.plantWeight > 0.85 then
		footState.lockPos = Vector(data.rawFootPos.x, data.rawFootPos.y, data.groundZ)
		footState.lockNormal = Vector(contact.normal or vector_up)
		lockZ = data.groundZ
	end
	return lockZ
end

-- source moves the player origin up/down a whole step in one tick when it
-- walks over a stair (and snaps down when walking off one). the old code fed
-- that straight into the body height, so the body popped a full step at a
-- time. here we detect those discrete jumps and return them so the smoothed
-- values can be shifted to stay put in world space.
-- velZ must include the velocity of whatever the player stands on, or a fast
-- lift looks like a stair pop every frame.
-- returns the jump and whether the move was a teleport (state must be reset)
function State.ConsumeOriginJump(runtimeState, origin, vel, dt, onGround, scale)
	local body = runtimeState.body
	local jump, teleport = 0, false
	if body.lastOrigin then
		local delta = origin - body.lastOrigin
		local unexplained = delta - vel * dt
		-- further than any step, slope or network correction can explain
		if unexplained:Length() > 48 * scale then
			teleport = true
		elseif onGround and body.wasOnGround and math.abs(unexplained.z) >= 2.5 * scale then
			jump = delta.z
		end
	end
	body.lastOrigin = Vector(origin)
	body.wasOnGround = onGround
	return jump, teleport
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
-- `expected` (bind pose ankle height, may be nil) bounds what is believable.
-- returns the new value and whether the sample was used (+ reason)
function State.UpdateRestHeight(runtimeState, footHeight, dt, seed, expected, scale)
	local rest = runtimeState.restHeight or expected or seed
	if not IsFiniteNumber(footHeight) then
		runtimeState.restHeight = rest
		return rest, false, "nan_sample"
	end
	if expected then
		-- a planted ankle far from the model's own ankle height is a bad read
		-- (wrong pose, another addon moving bones), not something to learn
		local lo, hi = expected * 0.5 - 0.5 * scale, expected * 1.6 + 1 * scale
		if footHeight < lo or footHeight > hi then
			runtimeState.restHeight = rest
			return rest, false, "outside_expected"
		end
	end
	-- a planted ankle that suddenly reads far from the learned value is only
	-- believed once it persists: a real change (different idle, crouch walk)
	-- stays, a bad read (pose glitch, another addon for a moment) does not
	if runtimeState.restHeight and math.abs(footHeight - rest) > 1.5 * scale then
		runtimeState.restOutlierTime = (runtimeState.restOutlierTime or 0) + dt
		if runtimeState.restOutlierTime < 1 then
			runtimeState.restHeight = rest
			return rest, false, "outlier_pending"
		end
	else
		runtimeState.restOutlierTime = 0
	end
	local rate = footHeight < rest and 1 / 0.6 or 1 / 3
	rest = rest + (footHeight - rest) * (1 - math.exp(-dt * rate))
	runtimeState.restHeight = rest
	return rest, true, "ok"
end

-- =====================================================================
-- stair stepper
-- =====================================================================
-- a proper stair gait: feet alternate and each foot lands on a real tread,
-- `treadsPerStep` treads ahead of the other foot. the old stepper only moved
-- the point where the ground was traced, the visible foot still followed
-- the walk cycle whose stride covers 2-4 treads - that was the long standing
-- "climbs several steps at once" bug.

-- a scan is 41 traces. it used to run every 0.12 s (and every 6 units) also
-- while standing still or walking on flat ground, which doubled the traces
-- per frame. now: near steps it stays as fresh as before; over smooth ground
-- it looks again once the player got as close to the end of the scanned
-- window as still leaves the stepper time to blend in (~0.2 s) before
-- stairs found there, or after a second (doors, props)
function State.UpdateStairScan(runtimeState, now, origin, dir, scale, params, enabled, speed)
	local stairs = runtimeState.stairs
	if not enabled then
		stairs.active = false
		stairs.scan = nil
		return nil
	end

	local scan = stairs.scan
	local needScan = not scan
	local aheadOnly = false
	if scan then
		local along = math.abs(RT.Ground.ScanCoord(scan, origin))
		local turned = scan.dir.x * dir.x + scan.dir.y * dir.y < 0.96
		local age = now - stairs.scanTime
		if scan.edges > 0 or stairs.active then
			needScan = turned or along > 6 * scale or (age >= SCAN_INTERVAL and along > 0.5 * scale)
		else
			-- stairs are recognised once their second edge is within 44 units:
			-- rescanning every D units finds them >= 32 - D units ahead
			local lookAgain = math.Clamp(32 * scale - 0.2 * (speed or 0), 6 * scale, 16 * scale)
			needScan = turned or along > lookAgain or age >= 1
			aheadOnly = true
		end
	end

	if needScan then
		local minStep, maxStep = params.stair_step_min_height * scale, params.stair_step_max_height * scale
		local sole = params.sole_offset + (params.soleCorrection or 0)
		scan = RT.Ground.ScanStairs(origin, dir, scale, minStep, maxStep, sole, aheadOnly)
		-- found steps: the stepper needs the whole profile, behind the player too
		if aheadOnly and scan.edges > 0 then
			scan = RT.Ground.ScanStairs(origin, dir, scale, minStep, maxStep, sole, false)
		end
		stairs.scan = scan
		stairs.scanTime = now
		if scan.isStairs then stairs.lastSeen = now end
	end

	stairs.active = scan ~= nil and (scan.isStairs or (now - stairs.lastSeen) < STAIR_EXIT_DELAY)
	return scan
end

-- preferS: where along the stairs the foot wants to be (a foot that already
-- stands on this tread: seeding, re-planting, settling under the hips). it
-- stays there, only kept a foot's length off the tread's real edges. the old
-- code used the "near the edge we came from" rule for these too, and on the
-- floor before the stairs the start of that long tread is just where the
-- scan window begins: both feet were seeded 20 units behind the body and the
-- body crouched 5 units on flat ground to keep them in reach
local function PlacementOnTread(scan, tread, lateral, right, footLen, preferS)
	local center = (tread.s0 + tread.s1) * 0.5
	local width = tread.s1 - tread.s0
	local s
	if preferS then
		local lo = tread.edgeBefore and tread.s0 + footLen * 0.45 or -math.huge
		local hi = tread.edgeAfter and tread.s1 - footLen * 0.55 or math.huge
		s = lo <= hi and math.Clamp(preferS, lo, hi) or center
	elseif width <= footLen * 1.2 or not tread.edgeBefore then
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
--       animLifted = {left = bool, right = bool} (the animation has that foot in the air),
--       groundAt(pos) -> z, flat (ground under a placement, heel/centre/toe agree)
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
	local now = data.now or 0
	local function NoteStart(f, reason)
		f.lastReason = reason
		f.blocked = nil
		f.starts[#f.starts + 1] = now
		while #f.starts > 6 do table.remove(f.starts, 1) end
	end
	local function Place(side, treadIndex, preferS)
		local tread = scan.treads[math.Clamp(treadIndex, 1, #scan.treads)]
		local pos, s = PlacementOnTread(scan, tread, data.lateral[side], data.right, footLen, preferS)
		-- the traces right under the foot are the truth: the scan only samples
		-- its centre line, and with the body turned the foot's lateral offset
		-- and its own length can cross a tread edge (old code: kept the scan's
		-- height and buried the foot a step deep; a single hull trace: picked
		-- the upper tread and left the foot hanging over the lower one).
		-- slide along the stairs until heel, centre and toe share one surface
		local fallbackZ
		for _, off in ipairs({ 0, 2, -2, 4, -4, 6, -6 }) do
			local p = pos + scan.dir * (off * data.scale)
			local z, flat = data.groundAt(p)
			if z and not fallbackZ then fallbackZ = z end
			if z and flat then
				p.z = z
				return p, s + off * data.scale
			end
		end
		if fallbackZ then pos.z = fallbackZ end
		return pos, s
	end

	-- seed plants from where the animation currently has the feet, but never
	-- further from the body than a comfortable half stride
	local seedRange = data.legLength * 0.4
	for _, side in ipairs({ "left", "right" }) do
		local f = stepper.feet[side]
		if not f.plant and not f.swing then
			local s = math.Clamp(RT.Ground.ScanCoord(scan, data.animFeet[side]), sBody - seedRange, sBody + seedRange)
			f.plant = Place(side, RT.Ground.TreadIndexAt(scan, s) or 1, s)
			f.lastReason = "seed"
			-- the animation already lifted this foot: when it is the trailing
			-- one it steps right away instead of waiting for its turn, while
			-- the body runs away from it (at a run it was left 25 units
			-- behind, out of reach even with the body crouched to its limit)
			f.stepNow = data.animLifted and data.animLifted[side] and now + 0.3 or nil
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
				f.plant = Place(side, RT.Ground.TreadIndexAt(scan, s) or 1, s)
				-- a teleport of the foot: visible pop, worth knowing about
				f.lastReason = "replant_out_of_reach"
				if data.onEvent then data.onEvent(side, "replant", { dist = math.sqrt(dx * dx + dy * dy), reach = reach }) end
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
		-- right after seeding the animation decides which foot moves first:
		-- its lifted foot may just be passing the planted one, i.e. be a
		-- little ahead of it. stepping the planted one instead put the gait
		-- out of phase and left the lifted foot behind until it had to hop
		for _, f in pairs(stepper.feet) do
			if f.stepNow and (f.swing or now > f.stepNow) then f.stepNow = nil end
		end
		if stepper.feet[leadSide].stepNow and not stepper.feet[trailSide].stepNow then
			leadSide, trailSide, sLead, sTrail = trailSide, leadSide, sTrail, sLead
		end
		local trail, lead = stepper.feet[trailSide], stepper.feet[leadSide]

		local behind = sBody - sTrail
		-- the trailing foot may lift while the lead is still landing when it is
		-- getting far behind, and must lift (both feet briefly in the air, a
		-- hop) before it would fall out of reach and have to be teleported
		local leadReady = not lead.swing or (lead.swing.t >= 0.65 and behind > reach * 0.55) or behind > reach * 0.8
		local wantsStep = sBody >= sLead - 0.25 * strideAdvance or behind > reach * 0.7 or trail.stepNow
		-- a settle step started while standing should finish with the body
		-- once the player walks off again
		for _, f in pairs(stepper.feet) do
			if f.swing and f.swing.settle then
				f.swing.settle = nil
				f.swing.bodyStart = Vector(data.origin)
				f.swing.dir = Vector(scan.dir)
				f.swing.bodyTravel = 0.5 * depth
			end
		end
		if trail.swing then
			trail.blocked = nil
		elseif not leadReady then
			trail.blocked = "waiting_for_lead_swing"
		elseif not wantsStep then
			trail.blocked = "body_not_over_lead"
		end
		if not trail.swing and leadReady and wantsStep then
			local leadIdx = RT.Ground.TreadIndexAt(scan, sLead) or 1
			local targetIdx = leadIdx + treadsPerStep
			if trail.stepNow then
				-- the first step of a foot that is already in the air: the
				-- farthest tread ahead it can reach, not the gait's full stride
				while targetIdx > leadIdx + 1 and targetIdx <= #scan.treads
					and (scan.treads[targetIdx].s0 + scan.treads[targetIdx].s1) * 0.5 - sBody >= reach do
					targetIdx = targetIdx - 1
				end
			end
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
			-- the lead foot still stands on the floor (or a landing) and the
			-- first step is further away than a stride and a half: walk on the
			-- floor up to it. the stepper takes over as soon as stairs are in
			-- sight, 25-40 units early; sending the first foot all the way onto
			-- the first step left the other one 24 units behind the body
			local leadTread = scan.treads[leadIdx]
			local stepLen = math.max(strideAdvance, 0.3 * data.legLength)
			if leadTread and sTo - sLead > 1.6 * stepLen then
				local sFloor = sLead + stepLen
				if leadTread.edgeAfter then sFloor = math.min(sFloor, leadTread.s1 - footLen * 0.55) end
				if sFloor > sTrail + 0.5 * stepLen then
					toPos, sTo = Place(trailSide, leadIdx, sFloor)
				end
			end
			-- never step further than the leg can reach from where the body will be
			if sTo - sBody >= reach then
				trail.blocked = "target_out_of_reach"
			else
				NoteStart(trail, behind > reach * 0.7 and "gait_far_behind" or (lead.swing and "gait_overlap" or "gait"))
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
			local toPos, sTo = Place(worstSide, RT.Ground.TreadIndexAt(scan, sBody) or 1, sBody)
			-- only if it is a real improvement (long landings place the foot
			-- near the edge, which must not cause an endless re-step)
			if math.abs(sTo - sBody) >= worstDist - 1 then
				f.blocked = "settle_no_better_spot"
			else
				NoteStart(f, "settle")
				f.swing = {
					settle = true,
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
