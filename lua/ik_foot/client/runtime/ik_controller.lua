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
	local dt = math.Clamp(FrameTime(), 1 / 300, 1 / 20)
	local now = RealTime()

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
	local crouch = State.UpdateCrouch(state, ply:Crouching(), dt)
	local body = state.body
	local wasOnGround = body.wasOnGround
	local jump = State.ConsumeOriginJump(state, origin.z, velZ, dt, onGround, scale)

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
	local restH
	if P.dynamic_sole and onGround and not crouch.inTransition and state.stepper.blend < 0.01 then
		restH = State.UpdateRestHeight(state, math.min(footH.left, footH.right), dt, seed)
	else
		restH = state.restHeight or seed
	end
	-- an ankle can't physically sit under the floor or at knee height. keeps a
	-- bad read (another addon moving bones behind our back) from poisoning it
	restH = math.Clamp(restH, 0.3 * scale, 10 * scale)
	state.restHeight = restH

	local plantW = {}
	for _, side in ipairs(SIDES) do
		plantW[side] = math.Clamp(1 - (footH[side] - restH) / (3 * scale), 0, 1)
	end

	local idle = State.UpdateIdle(state, onGround and P.stabilize_idle, vel2D, velZ, P.idle_velocity, dt)

	-- === stairs ===
	local groundEnt = ply:GetGroundEntity()
	local groundMoving = IsValid(groundEnt) and groundEnt:GetVelocity():Length() > maxSurfaceSpeed
	local stairsAllowed = P.stair_stepper and onGround and not groundMoving and not crouch.inTransition
	local scan = State.UpdateStairScan(state, now, origin, moveDir, scale, P, stairsAllowed)

	local function SampleGroundAt(pos)
		local s = RT.Ground.TraceSample(Vector(pos.x, pos.y, traceStartZ), groundDist, sole, maxSurfaceSpeed, true)
		return s.hit and s.hitPos.z or nil
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

	local proc, procBlend, treadsPerStep = State.UpdateStepper(state, {
		active = stairsAllowed and state.stairs.active,
		scan = scan,
		origin = origin,
		right = moveRight,
		speed = vel2D,
		idleSpeed = math.max(P.idle_velocity, 2),
		dt = dt,
		scale = scale,
		legLength = legLength,
		treadsPerStep = math.floor(P.stair_treads_per_step + 0.5),
		maxCadence = P.stair_max_cadence,
		lift = P.stair_step_lift * scale,
		animFeet = { left = sk.left.footPos, right = sk.right.footPos },
		lateral = lateral,
		sampleGround = SampleGroundAt,
	})

	-- === per foot ground offset ===
	local feet = {}
	local skipAnimSampling = procBlend >= 0.999 and proc.left and proc.right
	for _, side in ipairs(SIDES) do
		local leg = state.legs[side]
		local F = sk[side].footPos
		local foot = { contact = nil, plantW = plantW[side] }

		local speed = State.MeasureFootSpeed(leg, F, dt)
		local dRaw = 0
		if not skipAnimSampling then
			local samples = RT.Ground.SampleFoot(F, bodyFwd, traceStartZ, groundDist, side == "left", scale, sole, maxSurfaceSpeed)
			local contact = RT.Ground.ResolveContact(samples, F)
			foot.contact = contact

			local groundZ = P.anti_clip and contact.highestZ or contact.position.z
			local lockZ = State.UpdateFootLock(leg, {
				onGround = onGround and not crouch.inTransition,
				contact = contact,
				rawFootPos = F,
				footSpeed = speed,
				plantWeight = plantW[side],
				idleActive = idle.active,
				lockStrength = P.lock_strength,
				releaseSpeed = P.release_speed,
				scale = scale,
			})
			if lockZ then groundZ = lockZ end

			if onGround and contact.hasHit then
				dRaw = origin.z - groundZ
			end

			local nTarget = (onGround and contact.hasHit) and contact.normal or UP
			leg.normal = Lerp3(ExpBlend(dt, rotSmoothTime), leg.normal, nTarget)
			if leg.normal:LengthSqr() > 0.001 then leg.normal:Normalize() else leg.normal = Vector(UP) end
		end

		-- shift smoothed state with discrete origin jumps so the foot stays put in world
		if leg.drop then leg.drop = leg.drop + jump end
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

	local desired = 0
	if onGround then
		local diff = dHigh - dLow
		local unevenFactor = math.Clamp(diff / (6 * scale), 0, 1)
		local terrainNeed = math.Clamp(dHigh / (2 * scale), 0, 1)
		local extra = Lerp(unevenFactor, P.extra_body_drop, P.extra_body_drop_uneven) * scale * terrainNeed
			+ diff * P.uneven_drop_scale * 0.2

		desired = math.max(reachDrop, dLow) + extra
		-- dont crouch so low that the higher foot's knee would have to fold
		-- shut. when both cant be satisfied the supporting (lower) foot wins
		local foldLimit = math.min(maxL, maxR)
		desired = math.min(desired, math.max(foldLimit, reachDrop))

		local cap = math.min(P.max_body_drop * scale, legLength * 0.6)
		local floor = math.max(math.min(dLow, 0), -6 * scale)
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
	body.drop, body.vel = State.Spring(body.drop or desired, body.vel or 0, desired, bodySmooth, dt)
	-- a lagging body must never leave a supporting foot hanging: if the lower
	-- foot is out of reach, catch up much faster than the normal smoothing
	if onGround and body.drop < reachDrop then
		body.drop = body.drop + (reachDrop - body.drop) * ExpBlend(dt, 0.025)
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
		local animFootAng = AlignToNormal(skLeg.footAng, leg.normal, P.foot_rotation_scale * foot.plantW * groundW)
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
		legsOut[side] = {
			thigh = solved and solved.thigh or Angle(),
			calf = solved and solved.calf or Angle(),
			foot = solved and solved.foot or Angle(),
			knee = solved and solved.knee,
			ankle = solved and solved.ankle,
			reached = solved and solved.reached or false,
			targetPos = foot.target,
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

	-- === lean ===
	local leanManip
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
		},
	}
end

-- =====================================================================
-- debug
-- =====================================================================

function Controller.DrawDebug(ply, result)
	local debugCvar = RT.CVars.debug
	if not debugCvar then return end
	local level = debugCvar:GetInt()
	if level <= 0 then return end

	for _, side in ipairs(SIDES) do
		local leg = result[side]
		local isLeft = side == "left"
		local col = RT.Ground.DebugColors(isLeft)
		if leg.contact then
			RT.Ground.DrawSamples(leg.contact.samples, col, RT.Colors.green, level)
		end
		if leg.targetPos then
			render.DrawWireframeBox(leg.targetPos, angle_zero, Vector(-1.5, -1.5, -1.5), Vector(1.5, 1.5, 1.5), col, true)
		end
		if leg.knee and leg.ankle then
			render.DrawLine(leg.knee, leg.ankle, col, true)
		end
		if leg.lockPos then
			render.DrawWireframeBox(leg.lockPos, angle_zero, Vector(-1, -1, -0.25), Vector(1, 1, 0.25), RT.Colors.white, true)
		end
		if level > 1 and not leg.reached and leg.targetPos then
			render.DrawWireframeBox(leg.targetPos, angle_zero, Vector(-2.5, -2.5, -0.25), Vector(2.5, 2.5, 0.25), Color(255, 60, 60), true)
		end
	end

	if level > 1 then
		RT.Ground.DrawScan(result.scan)
		local bottom, top
		if ply:Crouching() then
			bottom, top = ply:GetHullDuck()
		else
			bottom, top = ply:GetHull()
		end
		render.DrawWireframeBox(ply:GetPos(), angle_zero, bottom, top, RT.Colors.white, true)
	end

	if ply == LocalPlayer() then
		local d = result.debug or {}
		local l, r = result.left, result.right
		RT.Debug2D = RT.Debug2D or {}
		RT.Debug2D.expireAt = CurTime() + 0.2
		RT.Debug2D.lines = {
			string.format("IK DEBUG [%s]", IsValid(ply) and ply:Nick() or "player"),
			string.format("VEL2D: %.1f  VELZ: %.1f  JUMP: %.1f  LAND: %.1f", d.velocity2D or 0, d.vertVel or 0, d.originJump or 0, d.landDip or 0),
			string.format("TRACE HITS L/R: %d/%d", d.lHitCount or 0, d.rHitCount or 0),
			string.format("L_REQ: %.1f  R_REQ: %.1f  DROP: %.1f", result.lRequiredDrop or 0, result.rRequiredDrop or 0, result.bodyDrop or 0),
			string.format("PLANTED L/R: %s/%s  REACHED L/R: %s/%s", l.planted and "Y" or "N", r.planted and "Y" or "N", l.reached and "Y" or "N", r.reached and "Y" or "N"),
			string.format("FOOT SPD L/R: %.1f / %.1f", l.footSpeed or 0, r.footSpeed or 0),
			string.format("IDLE: %s (%.2f)", d.idleActive and "ON" or "OFF", d.idleCandidateTime or 0),
			string.format("SCALE: %.2f  LEG: %.1f  REST H: %.2f  SOLE: %+.2f  EXTRA ROOTS: %d", d.modelScale or 1, d.measuredLeg or 0, d.restHeight or 0, d.soleCorrection or 0, d.auxRoots or 0),
			string.format("STAIRS: %s (%.0f%%)  %s  DEPTH: %.1f  RISE: %.1f  TREADS/STEP: %d", d.stairMode and "ON" or "OFF", (d.stairBlend or 0) * 100, d.stairAscending and "UP" or "DOWN", d.stairDepth or 0, d.stairRise or 0, d.treadsPerStep or 0),
			string.format("STEP L: %s %.2f   R: %s %.2f", l.procPhase, l.procT or 0, r.procPhase, r.procT or 0),
		}
	end
end
