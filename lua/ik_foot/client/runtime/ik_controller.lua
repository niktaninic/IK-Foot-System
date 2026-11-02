if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

local RT = IKFoot.Runtime
RT.Controller = RT.Controller or {}
local Controller = RT.Controller

local UP = Vector(0, 0, 1)
local LAND_MIN_SPEED = 160
local LEAN_MAX_ROLL = 8
local LEAN_MAX_PITCH = 9
local SIDES = { "left", "right" }
-- the ik only runs while the player is drawn. a pause longer than this means
-- the state refers to a pose and place that are gone
local RESUME_GAP = 0.25
local REACH_RELEASE_TIME = 0.2
local STAIR_CROUCH_FORGET = 1.5

-- kept for api compatibility (old builds had a separate sole feedback loop,
-- its job is now done by the rest height calibration in State)
function Controller.ResetDynSole(ply)
	if not IsValid(ply) or not ply.IKRuntimeState then return end
	ply.IKRuntimeState.restHeight = nil
end

local function Lerp3(t, a, b)
	return Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
end

local function ExpBlend(dt, smoothTime)
	return 1 - math.exp(-dt / math.max(smoothTime, 0.001))
end

-- orientation of a foot aligned to a ground normal, `weight` 0..1
local function AlignToNormal(ang, normal, weight)
	if weight <= 0.001 then return Angle(ang.p, ang.y, ang.r) end
	local axis, deg = RT.Solver.RotationBetween(UP, normal)
	if not axis then return Angle(ang.p, ang.y, ang.r) end
	return RT.Solver.RotateAngle(ang, axis, deg * weight)
end

function Controller.Calculate(ply, sk, bones, P)
	local State = RT.State
	local Solver = RT.Solver
	local state = State.Get(ply)
	-- every integrator below is stable for large steps, so only guard against
	-- 0 and hitches. the old 1/20 cap made feet and springs run in slow motion
	-- below 20 fps
	local dt = math.Clamp(FrameTime(), 1 / 1000, 0.1)
	local now = RealTime()
	local Diag = RT.Diag
	local function Event(side, kind, values)
		if Diag then Diag.Event(ply, kind, side, values) end
	end

	-- after a pause (first person, out of view, ik toggled off, model loading)
	-- the locks, springs and the last origin still describe where the player
	-- was back then. resuming from them sweeps the feet and the body across
	-- the gap, or reads the whole walk as one stair pop. start fresh instead
	-- and keep the calibration
	local frameNo = FrameNumber()
	if state.lastFrame and frameNo - state.lastFrame > 1 and now - (state.lastTime or now) > RESUME_GAP then
		Event(nil, "resume_after_gap", { frames = frameNo - state.lastFrame, seconds = now - state.lastTime })
		State.SoftRecover(ply)
		state = State.Get(ply)
	end
	state.lastFrame, state.lastTime = frameNo, now

	local legLength = P.leg_length > 0 and P.leg_length or sk.legLength
	local scale = math.Clamp(legLength / RT.REFERENCE_LEG_LENGTH, 0.4, 2.5)
	local soleCorr = P.auto_model_detect and RT.GetSoleCorrection(bones.profile, ply:GetModelScale()) or 0
	P.soleCorrection = soleCorr
	local sole = P.sole_offset + soleCorr

	local origin = ply:GetPos()
	local vel = ply:GetVelocity()
	local vel2D = vel:Length2D()
	local velZ = vel.z
	local onGround = ply:OnGround() and ply:WaterLevel() < 2
	local groundEnt = ply:GetGroundEntity()
	local groundVel = IsValid(groundEnt) and groundEnt:GetVelocity() or vector_origin
	-- the teleport test needs the real frame time: after a hitch (loading, alt
	-- tab) the capped dt would make normal movement look like a teleport
	local frameDt = math.max(FrameTime(), 1 / 1000)
	local prevOrigin = state.body.lastOrigin
	-- vertical motion of the origin relative to the ground it stands on
	-- (walking up a slope, a stair pop; not a lift carrying the player)
	local originRise = prevOrigin and (origin.z - prevOrigin.z - groundVel.z * frameDt) or 0
	local jump, teleport = State.ConsumeOriginJump(state, origin, vel + groundVel, frameDt, onGround, scale)
	if teleport then
		-- respawn nearby, teleporter, admin goto, big network correction: all
		-- smoothed state refers to the old place. keep only the calibration
		Event(nil, "teleport", { origin = origin })
		State.SoftRecover(ply)
		state = State.Get(ply)
		State.ConsumeOriginJump(state, origin, vel + groundVel, frameDt, onGround, scale)
		jump, originRise = 0, 0
	end
	local crouch = State.UpdateCrouch(state, ply:Crouching(), dt)
	local body = state.body
	local wasOnGround = body.prevOnGround
	body.prevOnGround = onGround

	local smoothTime = 1.2 / math.max(P.smoothing, 1)
	local rotSmoothTime = 1.2 / math.max(P.rotation_smoothing, 1)
	local traceStartZ = origin.z + P.trace_start_offset * scale
	local groundDist = P.ground_distance * scale
	local maxSurfaceSpeed = P.moving_surface_max_speed > 0 and P.moving_surface_max_speed or 45

	local renderAng = ply.GetRenderAngles and ply:GetRenderAngles() or ply:GetAngles()
	local yawAng = Angle(0, renderAng.y, 0)
	local bodyFwd = yawAng:Forward()
	local bodyRight = yawAng:Right()

	local moveDir
	if vel2D > 5 then
		moveDir = Vector(vel.x / vel2D, vel.y / vel2D, 0)
	else
		moveDir = Vector(bodyFwd.x, bodyFwd.y, 0)
	end
	local moveRight = Vector(moveDir.y, -moveDir.x, 0)

	-- === rest height: how high the animated ankle sits when the foot is down ===
	local footH = {
		left = sk.left.footPos.z - origin.z,
		right = sk.right.footPos.z - origin.z,
	}
	local seed = math.Clamp(math.min(footH.left, footH.right), 0.5 * scale, 10 * scale)
	local modelScale = math.max(ply:GetModelScale() or 1, 0.01)
	local expectedRest = RT.GetExpectedRestHeight(bones.profile, modelScale)
	local restH
	local prevRest = state.restHeight
	-- learn only from a foot that is really planted in the animation (barely
	-- moving in the world), never from transitions or a foot mid-swing
	local lowSide = footH.left <= footH.right and "left" or "right"
	local lowPlanted = (state.legs[lowSide].footSpeed or math.huge) < 25 * scale
	local restUsed, restReason = false, nil
	if not P.dynamic_sole then
		restReason = "dynamic_sole_off"
	elseif not onGround then
		restReason = "in_air"
	elseif not lowPlanted then
		restReason = "foot_not_planted"
	elseif crouch.inTransition then
		restReason = "crouch_transition"
	elseif state.stepper.blend >= 0.01 then
		restReason = "stair_stepper_active"
	end
	if restReason then
		-- without runtime calibration the model's own ankle height is the best
		-- answer, the per-frame seed only when the model gave us nothing
		restH = state.restHeight or expectedRest or seed
	else
		restH, restUsed, restReason = State.UpdateRestHeight(state, footH[lowSide], dt, seed, expectedRest, scale)
	end
	-- an ankle can't physically sit under the floor or at knee height. keeps a
	-- bad read (another addon moving bones behind our back) from poisoning it
	if expectedRest then
		restH = math.Clamp(restH, expectedRest * 0.5, expectedRest * 1.6 + scale)
	end
	restH = math.Clamp(restH, 0.3 * scale, 10 * scale)
	state.restHeight = restH
	-- learning is rate limited (0.6 s / 3 s time constants); anything faster
	-- than ~1 unit per 0.1 s came from somewhere else
	if prevRest and math.abs(restH - prevRest) > (10 * dt + 0.25) * scale then
		Event(lowSide, "rest_jump", { from = prevRest, to = restH, sample = footH[lowSide], reason = restReason })
	end
	local restInfo = { value = restH, expected = expectedRest, sample = footH[lowSide], sampleSide = lowSide,
		used = restUsed, reason = restReason, seed = seed }

	local plantW = {}
	for _, side in ipairs(SIDES) do
		plantW[side] = math.Clamp(1 - (footH[side] - restH) / (3 * scale), 0, 1)
	end

	local idle = State.UpdateIdle(state, onGround and P.stabilize_idle, vel2D, velZ, P.idle_velocity, dt)

	-- === stairs ===
	local groundMoving = groundVel:Length() > maxSurfaceSpeed
	local stairsAllowed = P.stair_stepper and onGround and not groundMoving and not crouch.inTransition
	local scan = State.UpdateStairScan(state, now, origin, moveDir, scale, P, stairsAllowed, vel2D)

	-- ground height under a stepper placement and whether heel, centre and
	-- toe (along the body's facing) rest on the same surface
	local function GroundAt(pos)
		local function Z(p)
			local s = RT.Ground.TraceSample(Vector(p.x, p.y, traceStartZ), groundDist, sole, maxSurfaceSpeed, false)
			return s.hit and s.hitPos.z or nil
		end
		local zc = Z(pos)
		if not zc then return nil, false end
		local zt = Z(pos + bodyFwd * (4 * scale))
		local zh = Z(pos - bodyFwd * (3 * scale))
		local tol = 1 * scale
		return zc, zt ~= nil and zh ~= nil and math.abs(zt - zc) <= tol and math.abs(zh - zc) <= tol
	end

	local lateral = {}
	local facingSign = bodyRight:Dot(moveRight) >= 0 and 1 or -1
	for _, side in ipairs(SIDES) do
		local f = sk[side].footPos
		local lat = (f.x - origin.x) * moveRight.x + (f.y - origin.y) * moveRight.y
		local defaultSign = (side == "left" and -1 or 1) * facingSign
		if math.abs(lat) < 1.5 * scale then lat = defaultSign * 2.5 * scale end
		lateral[side] = math.Clamp(lat, -8 * scale, 8 * scale)
	end

	-- the stepper can start or finish at most one step per call. at low frame
	-- rates that is slower than the gait needs and the feet fall behind, so
	-- big frames are split into <= 1/30 s sub steps along the origin's path
	local prevStepOrigin = state.stepperOrigin or origin
	state.stepperOrigin = Vector(origin)
	local subSteps = math.Clamp(math.ceil(dt * 30 - 0.001), 1, 4)
	if prevStepOrigin:DistToSqr(origin) > (48 * scale) ^ 2 then prevStepOrigin = origin end
	local proc, procBlend, treadsPerStep
	for k = 1, subSteps do
		local subOrigin = subSteps > 1 and Lerp3(k / subSteps, prevStepOrigin, origin) or origin
		proc, procBlend, treadsPerStep = State.UpdateStepper(state, {
		active = stairsAllowed and state.stairs.active,
		scan = scan,
		origin = subOrigin,
		right = moveRight,
		speed = vel2D,
		idleSpeed = math.max(P.idle_velocity, 2),
		dt = dt / subSteps,
		scale = scale,
		legLength = legLength,
		treadsPerStep = math.floor(P.stair_treads_per_step + 0.5),
		maxCadence = P.stair_max_cadence,
		lift = P.stair_step_lift * scale,
		animFeet = { left = sk.left.footPos, right = sk.right.footPos },
		animLifted = { left = plantW.left < 0.6, right = plantW.right < 0.6 },
		lateral = lateral,
		groundAt = GroundAt,
		now = now,
		onEvent = function(side, kind, values) Event(side, kind, values) end,
	})
	end

	-- === per foot ground offset ===
	-- ground more than a stair step below the player is either the way down
	-- a staircase or a drop-off: a foot over a ledge or a gap. reaching for a
	-- drop-off crouched the body to its limit with the leg still dangling in
	-- the air; such a foot keeps its animated height instead, like the player
	-- standing on the edge it physically stands on. the two are told apart by
	-- walking the ground from where the player stands to the foot: stairs get
	-- there in steps the player can walk (its step size, in world units, the
	-- model's size does not change the map), a drop-off in one fall
	local stepSize = (ply.GetStepSize and ply:GetStepSize() or 18) + 1
	local hullHalf = 16
	if ply.GetHull then
		local _, maxs = ply:GetHull()
		if maxs then hullHalf = math.max(maxs.x, 1) end
	end
	local function GroundZ(x, y)
		local s = RT.Ground.TraceSample(Vector(x, y, traceStartZ), groundDist, sole, maxSurfaceSpeed, false)
		return s.hit and s.hitPos.z or nil
	end
	local function SteppedDown(footPos, footZ)
		-- the hull rests on the highest ground under it, which is an edge or a
		-- corner when the ground falls away (going down stairs, standing on a
		-- ledge). the hull is axis aligned: start the walk at its highest corner
		local inset = hullHalf - 1
		local fromX, fromY, prevZ
		for _, c in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
			local x, y = origin.x + c[1] * inset, origin.y + c[2] * inset
			local z = GroundZ(x, y)
			if z and (not prevZ or z > prevZ) then fromX, fromY, prevZ = x, y, z end
		end
		if not prevZ then return false end
		local dx, dy = footPos.x - fromX, footPos.y - fromY
		local n = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) / 6))
		for k = 1, n - 1 do
			local z = GroundZ(fromX + dx * k / n, fromY + dy * k / n)
			if not z or prevZ - z > stepSize then return false end
			prevZ = z
		end
		return prevZ - footZ <= stepSize
	end
	-- standing at a ledge asks the same question every frame: keep the
	-- answer while the player and the foot stay where they were
	local function IsDropOff(leg, footPos, footZ)
		local c = leg.dropOffCache
		if c and math.abs(c.x - origin.x) + math.abs(c.y - origin.y) + math.abs(c.z - origin.z) < 1
			and math.abs(c.fx - footPos.x) + math.abs(c.fy - footPos.y) < 1 and math.abs(c.fz - footZ) < 1 then
			return c.result
		end
		local result = not SteppedDown(footPos, footZ)
		leg.dropOffCache = { x = origin.x, y = origin.y, z = origin.z, fx = footPos.x, fy = footPos.y, fz = footZ, result = result }
		return result
	end
	local feet = {}
	local skipAnimSampling = procBlend >= 0.999 and proc.left and proc.right
	for _, side in ipairs(SIDES) do
		local leg = state.legs[side]
		local F = sk[side].footPos
		local foot = { contact = nil, plantW = plantW[side] }

		local speed = State.MeasureFootSpeed(leg, F, dt)
		local dRaw = 0
		local slide = 0
		if not skipAnimSampling then
			local samples = RT.Ground.SampleFoot(F, bodyFwd, traceStartZ, groundDist, side == "left", scale, sole, maxSurfaceSpeed)
			-- the sole gets turned toward the ground normal by about this much
			-- (see the foot angle below): heights are compared along that plane
			local soleNormal = Lerp3(onGround and P.foot_rotation_scale * plantW[side] or 0, UP, leg.normal)
			if soleNormal:LengthSqr() > 0.001 then soleNormal:Normalize() else soleNormal = Vector(UP) end
			local contact = RT.Ground.ResolveContact(samples, F, soleNormal)
			local depth = origin.z - contact.highestZ
			if contact.hasHit and onGround and depth > stepSize and IsDropOff(leg, F, contact.highestZ) then
				contact.hasHit = false
				contact.dropOff = depth
			end
			foot.contact = contact

			local groundZ = P.anti_clip and contact.highestZ or contact.position.z
			-- the ankle sits restH above the sole along the sole's normal, so
			-- above a tilted sole it is restH / cos(tilt) high
			groundZ = groundZ + restH * (1 / math.max(soleNormal.z, 0.7) - 1)
			if leg.hadContact and not contact.hasHit and onGround then
				Event(side, "contact_lost", { foot = F, samples = contact.hitCount, drop_off = contact.dropOff })
			end
			leg.hadContact = contact.hasHit
			local lockZ = State.UpdateFootLock(leg, {
				onGround = onGround and not crouch.inTransition,
				contact = contact,
				groundZ = groundZ,
				now = now,
				rawFootPos = F,
				footSpeed = speed,
				plantWeight = plantW[side],
				idleActive = idle.active,
				lockStrength = P.lock_strength,
				releaseSpeed = P.release_speed,
				scale = scale,
			})
			if lockZ then groundZ = lockZ end
			-- the ground under a foot moving along the plane it stood on last
			-- frame (a slope; a planted foot the animation slides a little)
			-- changes continuously and is carried over as it is: smoothing it
			-- only made the foot lag behind the slope. what that plane does not
			-- explain (an edge, a seam, a new lock) is what gets smoothed
			if onGround and contact.hasHit then
				if leg.lastGround then
					slide = State.PlaneZ(leg.lastGround, leg.lastGroundNormal, F) - leg.lastGround.z
				end
				leg.lastGround = Vector(F.x, F.y, groundZ)
				leg.lastGroundNormal = Vector(lockZ and leg.lockNormal or contact.normal)
			else
				leg.lastGround = nil
			end

			if onGround and contact.hasHit then
				dRaw = origin.z - groundZ
			end

			local nTarget = (onGround and contact.hasHit) and contact.normal or UP
			leg.normal = Lerp3(ExpBlend(dt, rotSmoothTime), leg.normal, nTarget)
			if leg.normal:LengthSqr() > 0.001 then leg.normal:Normalize() else leg.normal = Vector(UP) end
		else
			-- the stepper places this foot: the ground plane it remembers goes stale
			leg.lastGround = nil
		end

		-- the smoothing is for the ground (seams, edges), not for the player
		-- moving. while this foot stands on the ground the smoothed value moves
		-- with the origin, so a planted foot stays put in world space: on a
		-- slope the origin climbs every frame and the lagging value used to
		-- lift the foot ~2 units walking up (and sink it walking down). in the
		-- air only the discrete pops (stairs) are carried over
		local grounded = not skipAnimSampling and onGround and foot.contact ~= nil and foot.contact.hasHit
		if leg.drop then
			leg.drop = leg.drop + ((grounded and leg.wasGrounded) and (originRise - slide) or jump)
		end
		leg.wasGrounded = grounded
		leg.drop, leg.dropVel = State.Spring(leg.drop or dRaw, leg.dropVel or 0, dRaw, smoothTime * 0.6, dt)

		foot.dAnim = leg.drop
		foot.targetAnim = Vector(F.x, F.y, F.z - leg.drop)
		foot.speed = speed

		local p = proc[side]
		if p and procBlend > 0 then
			foot.proc = p
			foot.targetProc = Vector(p.ground.x, p.ground.y, p.ground.z + restH + (p.lift or 0))
			foot.dProc = origin.z - (p.supportZ or p.ground.z)
			foot.target = Lerp3(procBlend, foot.targetAnim, foot.targetProc)
			foot.d = Lerp(procBlend, foot.dAnim, foot.dProc)
			-- a stepping foot is in the air and carries no weight
			local procSupport = p.phase == "swinging" and math.Clamp(math.abs(p.t - 0.5) * 6 - 2, 0, 1) or 1
			foot.support = Lerp(procBlend, plantW[side], procSupport)
		else
			foot.target = foot.targetAnim
			foot.d = foot.dAnim
			foot.support = plantW[side]
		end
		feet[side] = foot
	end

	-- remember a "flat" foot orientation (relative to body yaw) for the stepper
	if onGround and procBlend < 0.01 then
		for _, side in ipairs(SIDES) do
			local leg = state.legs[side]
			if plantW[side] > 0.95 and leg.normal.z > 0.97 then
				local _, localAng = WorldToLocal(vector_origin, sk[side].footAng, vector_origin, yawAng)
				leg.restLocalAng = localAng
			end
		end
	end

	-- === body drop ===
	-- only feet that carry weight decide how low the body goes. a foot in the
	-- air that cant reach its target simply stays a bit more bent, it must not
	-- yank the whole body down for a frame or two
	local minL, maxL = Solver.DropLimits(sk.left, feet.left.target)
	local minR, maxR = Solver.DropLimits(sk.right, feet.right.target)
	-- everything is weighted continuously by support so nothing pops when a
	-- foot lifts off or lands
	local sL, sR = feet.left.support, feet.right.support
	local dL = Lerp(sL, feet.right.d, feet.left.d)
	local dR = Lerp(sR, feet.left.d, feet.right.d)
	local dLow, dHigh = math.min(dL, dR), math.max(dL, dR)
	-- lowest body position at which the supporting feet still reach their
	-- ground, with a little slack so the leg isnt locked dead straight.
	-- unsupported feet are relaxed by up to 12 units
	local relax = 12 * scale
	local reachDrop = math.max(minL - (1 - sL) * relax, minR - (1 - sR) * relax) + 0.6 * scale
	-- a supporting foot that lifts off drops its reach limit within a couple
	-- of frames, and the body shot up by all that foot had held it down: 10
	-- units per step walking up a steep slope. the limit is let go of
	-- gradually instead; tightening (a foot that needs the body lower) still
	-- applies at once. kept in world space across origin motion. only for the
	-- animation's own feet: with the stair stepper fully in charge it held the
	-- body low into the next stair pop and made climbing jerkier
	local reachHeld = reachDrop
	if onGround and body.reachHold and procBlend < 0.999 then
		local held = body.reachHold + originRise
		reachHeld = math.max(reachDrop, held + (reachDrop - held) * ExpBlend(dt, REACH_RELEASE_TIME * (1 - procBlend)))
	end
	body.reachHold = onGround and reachHeld or nil

	local desired = 0
	local dropLimiter = "in_air"
	local stairLead = 0 -- rate the stair target moves at (drop units / s)
	if onGround then
		local diff = dHigh - dLow
		local unevenFactor = math.Clamp(diff / (6 * scale), 0, 1)
		local terrainNeed = math.Clamp(dHigh / (2 * scale), 0, 1)
		local extra = Lerp(unevenFactor, P.extra_body_drop, P.extra_body_drop_uneven) * scale * terrainNeed
			+ diff * P.uneven_drop_scale * 0.2

		desired = math.max(reachHeld, dLow) + extra
		dropLimiter = reachHeld >= dLow and (reachHeld > reachDrop + 0.1 and "reach_release" or "reach") or "lowest_foot"

		-- stairs: the body follows the staircase itself, not the feet. the
		-- requirements above change in jumps whenever a foot lifts off or
		-- lands, so the body went up and down stairs in bursts (3 units in a
		-- frame walking down, 7 running). the profile under the hips averaged
		-- over one tread depth is a straight ramp through the tread centres;
		-- the body rides that ramp, crouched as far as the feet turned out to
		-- need (taken at once, forgotten slowly, so after the first step the
		-- reach limit stops kicking in). the foot requirements stay a floor
		if procBlend > 0 and scan and scan.samples then
			local depth = scan.depth > 0 and scan.depth or 12 * scale
			local half = depth * 0.5
			local sBody = RT.Ground.ScanCoord(scan, origin)
			local lineZ = RT.Ground.ProfileAverage(scan, sBody - half, sBody + half)
			if lineZ then
				local lineDrop = origin.z - lineZ + extra
				local need = math.max(reachDrop - lineDrop, 0)
				-- peak hold: going down the need shows for a frame or two as each
				-- foot lands, a smoothed learner hardly noticed it. it starts from
				-- what the geometry suggests (a foot half a step's rise below the
				-- ramp) so the very first step is covered too
				local crouch = body.stairCrouch or math.max(need, 0.5 * (treadsPerStep or 1) * (scan.rise or 0))
				crouch = math.max(need, crouch + (need - crouch) * ExpBlend(dt, STAIR_CROUCH_FORGET))
				body.stairCrouch = crouch
				local stairDesired = math.max(lineDrop + crouch, reachDrop)
				desired = Lerp(procBlend, desired, stairDesired)
				dropLimiter = stairDesired > reachDrop + 0.1 and "stair_line" or "reach"
				-- the ramp moves under a walking body: aim ahead by what the
				-- spring would lag behind it (slope * speed along the stairs,
				-- minus whatever the origin itself climbs smoothly, e.g. on a
				-- clip ramp; stair pops are absorbed separately)
				local q = depth * 0.25
				local zBack = RT.Ground.ProfileAverage(scan, sBody - half - q, sBody + half - q)
				local zFront = RT.Ground.ProfileAverage(scan, sBody - half + q, sBody + half + q)
				if zBack and zFront then
					local along = vel.x * scan.dir.x + vel.y * scan.dir.y
					stairLead = procBlend * ((originRise - jump) / dt - (zFront - zBack) / (2 * q) * along)
				end
			end
		else
			body.stairCrouch = nil
		end
		-- dont crouch so low that the higher foot's knee would have to fold
		-- shut. when both cant be satisfied the supporting (lower) foot wins
		local foldLimit = math.min(maxL, maxR)
		if desired > math.max(foldLimit, reachDrop) then
			desired = math.max(foldLimit, reachDrop)
			dropLimiter = "knee_fold"
		end

		local cap = math.min(P.max_body_drop * scale, legLength * 0.6)
		local floor = math.max(math.min(dLow, 0), -6 * scale)
		if desired > math.max(cap, floor) then dropLimiter = "max_body_drop" end
		if desired < floor then dropLimiter = "floor" end
		desired = math.Clamp(desired, floor, math.max(cap, floor))

		-- landing: absorb the impact in the knees
		if not wasOnGround and (body.fallSpeed or 0) > LAND_MIN_SPEED then
			body.landDip = math.min((body.fallSpeed - LAND_MIN_SPEED) * 0.025, 7) * scale
		end
		body.fallSpeed = 0
	else
		body.fallSpeed = math.max(body.fallSpeed or 0, -velZ)
	end
	body.landDip = (body.landDip or 0) * math.exp(-dt * 7)
	desired = desired + body.landDip

	-- how fast the origin is climbing through discrete pops (stairs). a fixed
	-- smoothing time lags behind a steady climb by about rate * smoothTime,
	-- so shorten it on fast climbs to keep the lag below one step
	local maxLag = 9 * scale
	body.climbRate = (body.climbRate or 0) + (jump / dt - (body.climbRate or 0)) * ExpBlend(dt, 0.3)
	local bodySmooth = math.min(smoothTime, 0.35 * maxLag / math.max(math.abs(body.climbRate), 1))

	if body.drop then
		-- absorb the origin pop so the body stays put in world space. the
		-- adaptive smoothing above keeps the lag bounded on long climbs, this
		-- clamp is only a safety net
		body.drop = math.Clamp(body.drop + jump, desired - 2 * maxLag, desired + 2 * maxLag)
	end
	-- leading the moving stair target never aims above what the feet reach
	local springTarget = desired
	if stairLead ~= 0 then
		springTarget = desired + stairLead * bodySmooth
		if onGround then springTarget = math.max(springTarget, reachDrop) end
	end
	body.drop, body.vel = State.Spring(body.drop or desired, body.vel or 0, springTarget, bodySmooth, dt)
	-- a lagging body must never leave a supporting foot hanging: if the lower
	-- foot is out of reach, catch up much faster than the normal smoothing
	if onGround and body.drop < reachDrop then
		body.drop = body.drop + (reachDrop - body.drop) * ExpBlend(dt, 0.025)
		dropLimiter = dropLimiter .. "+reach_catchup"
	end
	body.drop = math.Clamp(body.drop, -8 * scale, legLength * 0.8)
	local drop = body.drop

	-- === solve legs ===
	local legsOut = {}
	for _, side in ipairs(SIDES) do
		local foot = feet[side]
		local skLeg = sk[side]
		local leg = state.legs[side]

		local groundW = onGround and 1 or 0
		local alignW = P.foot_rotation_scale * foot.plantW * groundW
		local animFootAng = AlignToNormal(skLeg.footAng, leg.normal, alignW)
		local footAng = animFootAng
		if foot.proc then
			local procAng = skLeg.footAng
			if leg.restLocalAng then
				local _, a = LocalToWorld(vector_origin, leg.restLocalAng, vector_origin, yawAng)
				procAng = a
			end
			if foot.proc.phase == "swinging" and foot.proc.ascending then
				procAng = RT.Solver.RotateAngle(procAng, bodyRight, 12 * math.sin(foot.proc.t * math.pi))
			end
			footAng = LerpAngle(procBlend, animFootAng, procAng)
		end

		local solved = Solver.SolveLeg(skLeg, drop, foot.target, footAng, bodyFwd)
		if not solved then Event(side, "solver_failed", { target = foot.target, drop = drop }) end
		local stepFoot = state.stepper.feet[side]
		legsOut[side] = {
			solved = solved,
			animFoot = skLeg.footPos,
			animAng = skLeg.footAng,
			hip = solved and solved.hip or (skLeg.thighPos - Vector(0, 0, drop)),
			reach = solved and solved.reach,
			support = foot.support,
			plantW = foot.plantW,
			dropLimits = { min = side == "left" and minL or minR, max = side == "left" and maxL or maxR },
			lockAge = leg.lockPos and leg.lockTime and (now - leg.lockTime) or nil,
			stepReason = stepFoot and stepFoot.lastReason,
			stepBlocked = stepFoot and stepFoot.blocked,
			stepStarts = stepFoot and stepFoot.starts,
			stepIdleStarts = stepFoot and stepFoot.idleStarts,
			footWorld = solved and footAng or skLeg.footAng,
			footFinal = solved and solved.ankle or (skLeg.footPos - Vector(0, 0, drop)),
			thigh = solved and solved.thigh or Angle(),
			calf = solved and solved.calf or Angle(),
			foot = solved and solved.foot or Angle(),
			knee = solved and solved.knee,
			ankle = solved and solved.ankle,
			reached = solved and solved.reached or false,
			targetPos = foot.target,
			targetAnim = foot.targetAnim,
			targetProc = foot.targetProc,
			stepBlend = foot.proc and procBlend or 0,
			alignW = alignW,
			groundNormal = leg.normal,
			contact = foot.contact,
			lockPos = leg.lockPos and Vector(leg.lockPos) or nil,
			planted = leg.planted,
			released = leg.released,
			footSpeed = foot.speed,
			requiredDrop = foot.d,
			procPhase = foot.proc and foot.proc.phase or "off",
			procT = foot.proc and foot.proc.t or 0,
		}
	end

	-- === foot followers (shoes etc. that do not inherit the foot's motion) ===
	-- desired: keep each one where it sits relative to the animated foot, but
	-- relative to the solved foot. what it inherits without help depends on
	-- its parent: nothing (model / static), the body drop (body), or the
	-- thigh / calf rotation of its leg. the manipulation is the difference,
	-- expressed in the parent's ik frame (position) and its own frame (angle)
	local followersOut = {}
	local dropVec = Vector(0, 0, -drop)
	for i, f in ipairs(bones.followers or {}) do
		local fsk = sk.followers and sk.followers[i]
		local leg = legsOut[f.side]
		if fsk and leg then
			local skLeg = sk[f.side]
			local relPos, relAng = WorldToLocal(fsk.pos, fsk.ang, skLeg.footPos, skLeg.footAng)
			local ikPos, ikAng = LocalToWorld(relPos, relAng, leg.footFinal, leg.footWorld)

			local inheritedPos, inheritedAng, parentIKAng = fsk.pos, fsk.ang, fsk.parentAng
			local sol = leg.solved
			if f.kind == "body" then
				inheritedPos = fsk.pos + dropVec
			elseif (f.kind == "thigh" or f.kind == "calf") and sol then
				-- the same rigid motion the solver gave the thigh (about the hip)
				-- and, for the calf, the extra rotation about the new knee
				local function Move(pos)
					local p = sol.hip + Solver.RotateVector(pos + dropVec - sol.hip, sol.thighAxis, sol.thighDeg)
					if f.kind == "calf" then
						p = sol.knee + Solver.RotateVector(p - sol.knee, sol.calfAxis, sol.calfDeg)
					end
					return p
				end
				local function Turn(ang)
					local a = Solver.RotateAngle(ang, sol.thighAxis, sol.thighDeg)
					if f.kind == "calf" then a = Solver.RotateAngle(a, sol.calfAxis, sol.calfDeg) end
					return a
				end
				inheritedPos, inheritedAng, parentIKAng = Move(fsk.pos), Turn(fsk.ang), Turn(fsk.parentAng)
			elseif f.kind == "thigh" or f.kind == "calf" then
				inheritedPos = fsk.pos + dropVec
			end

			local localDelta = WorldToLocal(ikPos - inheritedPos, angle_zero, vector_origin, parentIKAng)
			followersOut[i] = {
				pos = localDelta / modelScale,
				ang = Solver.LocalDelta(inheritedAng, ikAng),
				expectedPos = ikPos,
				expectedAng = ikAng,
			}
		end
	end

	-- === lean ===
	local leanManip
	if not P.lean_enabled then state.lean.lastVel = nil end
	if P.lean_enabled and bones.leanBone and sk.spineAng then
		local lean = state.lean
		local accel = Vector()
		if lean.lastVel then accel = (vel - lean.lastVel) / dt end
		lean.lastVel = Vector(vel)
		local latAccel = accel.x * bodyRight.x + accel.y * bodyRight.y
		local fwdAccel = accel.x * bodyFwd.x + accel.y * bodyFwd.y
		local fwdSpeed = vel.x * bodyFwd.x + vel.y * bodyFwd.y

		-- lean into turns / sideways acceleration, slightly forward when running
		-- and when climbing stairs
		local rollTarget = math.Clamp(latAccel * 0.01, -LEAN_MAX_ROLL, LEAN_MAX_ROLL)
		local pitchTarget = fwdSpeed / 400 * 4 + fwdAccel * 0.004
		if procBlend > 0 and scan and scan.ascending then pitchTarget = pitchTarget + 4 * procBlend end
		if not onGround then rollTarget, pitchTarget = 0, 0 end
		pitchTarget = math.Clamp(pitchTarget, -LEAN_MAX_PITCH * 0.5, LEAN_MAX_PITCH)

		local k = ExpBlend(dt, 0.18)
		lean.roll = lean.roll + (rollTarget - lean.roll) * k
		lean.pitch = lean.pitch + (pitchTarget - lean.pitch) * k

		local desiredSpine = RT.Solver.RotateAngle(sk.spineAng, bodyFwd, lean.roll)
		desiredSpine = RT.Solver.RotateAngle(desiredSpine, bodyRight, -lean.pitch)
		leanManip = RT.Solver.LocalDelta(sk.spineAng, desiredSpine)
	end

	local leftC, rightC = feet.left.contact, feet.right.contact
	return {
		bodyDrop = drop,
		leanAng = leanManip,
		lRequiredDrop = feet.left.d,
		rRequiredDrop = feet.right.d,
		left = legsOut.left,
		right = legsOut.right,
		followers = followersOut,
		scan = scan,
		debug = {
			velocity2D = vel2D, vertVel = velZ,
			lHitCount = leftC and leftC.hitCount or -1, rHitCount = rightC and rightC.hitCount or -1,
			idleActive = idle.active, idleCandidateTime = idle.candidateTime or 0,
			modelScale = scale, measuredLeg = legLength,
			restHeight = restH, soleCorrection = soleCorr,
			stairMode = state.stairs.active, stairBlend = procBlend,
			stairDepth = scan and scan.depth or 0, stairRise = scan and scan.rise or 0,
			stairAscending = scan and scan.ascending or false,
			treadsPerStep = treadsPerStep or 0,
			originJump = jump, landDip = body.landDip,
			auxRoots = #bones.auxRoots,
			followers = #(bones.followers or {}),
			dropLimiter = dropLimiter,
			stairCrouch = body.stairCrouch,
			desiredDrop = desired,
			reachDrop = reachDrop,
			onGround = onGround,
			crouching = crouch.crouching,
			teleport = teleport,
			restInfo = restInfo,
			dt = dt,
		},
	}
end

-- =====================================================================
-- debug (drawing lives in ik_diag.lua, kept here for api compatibility)
-- =====================================================================

function Controller.DrawDebug(ply, result)
	if RT.Diag and RT.Diag.DrawDebug then RT.Diag.DrawDebug(ply, result) end
end
