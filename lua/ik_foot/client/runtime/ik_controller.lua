if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

local RT = IKFoot.Runtime
RT.Controller = RT.Controller or {}
local Controller = RT.Controller

local MAX_KNEE_BEND = 68
local MIN_KNEE_BEND = -30
local MAX_FOOT_PITCH = 25
local MAX_FOOT_ROLL = 20
local REFERENCE_LEG_LENGTH = 45
local CROUCH_BLEND_TIME = 0.3
local AIR_BODY_DROP_MAX = 6
local AIR_KNEE_MIN = 8
local AIR_KNEE_MAX = 24
local AIR_FOOT_PITCH_ASCEND = -6
local AIR_FOOT_PITCH_DESCEND = 14
local AIR_SWING_SPEED = 6
local AIR_SWING_AMP = 4

-- per-player sole correction. one of those things that took 3 days to debug
local DynSoleState = {}

local function GetDynSoleState(ply)
	local id = ply:EntIndex()
	if not DynSoleState[id] then
		DynSoleState[id] = { correction = 0 }
	end
	return DynSoleState[id]
end

function Controller.ResetDynSole(ply)
	if not IsValid(ply) then return end
	DynSoleState[ply:EntIndex()] = nil
end

local function DetermineSupportSide(leftContact, rightContact, leftState, rightState)
	if leftContact.hasHit and rightContact.hasHit then
		local zDelta = leftContact.position.z - rightContact.position.z
		if math.abs(zDelta) > 0.5 then
			return zDelta < 0 and "left" or "right"
		end
	end
	if leftState.planted and not rightState.planted then return "left" end
	if rightState.planted and not leftState.planted then return "right" end
	return leftContact.supportDistance >= rightContact.supportDistance and "left" or "right"
end

local function ComputeFootRotation(samples, scale)
	if scale <= 0.01 then return Angle() end

	local toe, heel = samples.toe, samples.heel
	local sLeft, sRight = samples.left, samples.right
	local pitch, roll = 0, 0

	if toe and heel and toe.hit and heel.hit then
		local len = math.max(toe.hitPos:Distance(heel.hitPos), 0.01)
		pitch = math.Clamp(-math.deg(math.atan2(toe.hitPos.z - heel.hitPos.z, len)) * scale, -MAX_FOOT_PITCH, MAX_FOOT_PITCH)
	end

	if sLeft and sRight and sLeft.hit and sRight.hit then
		local len = math.max(sRight.hitPos:Distance(sLeft.hitPos), 0.01)
		roll = math.Clamp(math.deg(math.atan2(sRight.hitPos.z - sLeft.hitPos.z, len)) * scale, -MAX_FOOT_ROLL, MAX_FOOT_ROLL)
	end

	return Angle(0, pitch, roll)
end

function Controller.Calculate(ply, skeleton)
	-- the big brain function. takes skeleton and figures out how to bend everything
	-- should produce natural looking legs. actually produces... close enough
	local groundDist      = RT.GetIKParam(ply, "ground_distance")
	local legLength       = RT.GetIKParam(ply, "leg_length")
	local traceStartOff   = RT.GetIKParam(ply, "trace_start_offset")
	local unevenDropScale = RT.GetIKParam(ply, "uneven_drop_scale")
	local extraDrop       = RT.GetIKParam(ply, "extra_body_drop")
	local extraDropUneven = RT.GetIKParam(ply, "extra_body_drop_uneven")
	local bendBoost       = RT.GetIKParam(ply, "high_foot_bend_boost")
	local footRotScale    = RT.GetIKParam(ply, "foot_rotation_scale")
	local idleVelThresh   = RT.GetIKParam(ply, "idle_velocity")
	local lockStrength    = RT.GetIKParam(ply, "lock_strength")
	local releaseSpeed    = RT.GetIKParam(ply, "release_speed")
	local maxBodyDropCVar = RT.GetIKParam(ply, "max_body_drop")
	local soleOffset      = RT.GetIKParam(ply, "sole_offset")
	local leanEnabled     = RT.GetIKParamBool(ply, "lean_enabled")
	local stabilizeIdle   = RT.GetIKParamBool(ply, "stabilize_idle")
	local antiClip        = RT.GetIKParamBool(ply, "anti_clip")
	local dynamicSole     = RT.GetIKParamBool(ply, "dynamic_sole")

	-- scale params to model size. tiny models get tiny numbers
	local modelScale = math.Clamp((skeleton.measuredLegLength or REFERENCE_LEG_LENGTH) / REFERENCE_LEG_LENGTH, 0.4, 2.5)
	groundDist      = groundDist * modelScale
	legLength       = legLength * modelScale
	traceStartOff   = traceStartOff * modelScale
	extraDrop       = extraDrop * modelScale
	extraDropUneven = extraDropUneven * modelScale
	maxBodyDropCVar = maxBodyDropCVar * modelScale

	local state = RT.State.Get(ply)
	local dt = math.Clamp(FrameTime(), 1 / 300, 1 / 20)
	local vel = ply:GetVelocity()
	local vel2D = vel:Length2D()
	local velZ = vel.z
	local onGround = ply:OnGround()
	local traceStartZ = ply:GetPos().z + traceStartOff

	local isCrouching = ply:Crouching()
	local crouch = RT.State.UpdateCrouch(state, isCrouching)

	local lSamples = RT.Ground.SampleFoot(ply, skeleton.left.footPos, skeleton.left.footAng, traceStartZ, groundDist, true)
	local rSamples = RT.Ground.SampleFoot(ply, skeleton.right.footPos, skeleton.right.footAng, traceStartZ, groundDist, false)
	local lContact = RT.Ground.ResolveContact(lSamples, skeleton.left.footPos, vector_up)
	local rContact = RT.Ground.ResolveContact(rSamples, skeleton.right.footPos, vector_up)

	-- validate contacts. always runs for debug but only corrects with anticlip on
	local lValidation = RT.Ground.ValidateContact(lContact, lSamples, skeleton.left.footPos.z, soleOffset)
	local rValidation = RT.Ground.ValidateContact(rContact, rSamples, skeleton.right.footPos.z, soleOffset)

	local idle = RT.State.UpdateIdle(state, onGround and stabilizeIdle, vel2D, velZ, idleVelThresh, skeleton.left.footPos, skeleton.right.footPos)
	local lFoot, rFoot = state.legs.left, state.legs.right
	local lSpeed = RT.State.MeasureFootSpeed(lFoot, skeleton.left.footPos, dt)
	local rSpeed = RT.State.MeasureFootSpeed(rFoot, skeleton.right.footPos, dt)

	-- anti-clip hack. if foot is inside ground dont lock it there
	if antiClip then
		if not lValidation.isValid and lValidation.invalidReason == "penetrating" then
			lFoot.planted = false
			lFoot.lockPos = nil
		end
		if not rValidation.isValid and rValidation.invalidReason == "penetrating" then
			rFoot.planted = false
			rFoot.lockPos = nil
		end
	end

	local support = DetermineSupportSide(lContact, rContact, lFoot, rFoot)
	local effectiveOnGround = onGround and not crouch.inTransition
	local footData = function(contact, rawPos, speed, side)
		return { onGround = effectiveOnGround, idleActive = idle.active and not crouch.inTransition, isSupportFoot = support == side,
			contact = contact, rawFootPos = rawPos, footSpeed = speed, lockStrength = lockStrength, releaseSpeed = releaseSpeed }
	end
	local lResult = RT.State.UpdateFoot(lFoot, footData(lContact, skeleton.left.footPos, lSpeed, "left"))
	local rResult = RT.State.UpdateFoot(rFoot, footData(rContact, skeleton.right.footPos, rSpeed, "right"))

	local bodyDrop, lReqDrop, rReqDrop = 0, 0, 0
	local lKnee, rKnee = 0, 0
	local lFootRot, rFootRot = Angle(), Angle()
	local dynSoleCorr = 0
	local penetrationCorrL, penetrationCorrR = 0, 0

	if onGround then
		local lDist = lContact.hasHit and lContact.supportDistance or traceStartOff
		local rDist = rContact.hasHit and rContact.supportDistance or traceStartOff
		lReqDrop = math.max(lDist - traceStartOff, 0)
		rReqDrop = math.max(rDist - traceStartOff, 0)

		-- dynamic sole. if feet keep clipping through ground this slowly pushes them up
		if dynamicSole then
			local dynState = GetDynSoleState(ply)
			local lPen = lValidation.penetrationCount
			local rPen = rValidation.penetrationCount
			local totalPen = lPen + rPen

			if totalPen > 2 then
				dynState.correction = dynState.correction + 0.04 * dt * 60
			elseif totalPen > 0 then
				dynState.correction = dynState.correction + 0.01 * dt * 60
			else
				dynState.correction = dynState.correction * (1 - 0.8 * dt)
			end
			dynState.correction = math.Clamp(dynState.correction, 0, 1.5)
			dynSoleCorr = dynState.correction

			lReqDrop = math.max(lReqDrop - dynSoleCorr, 0)
			rReqDrop = math.max(rReqDrop - dynSoleCorr, 0)
		end


		local lTraceExcess = math.max(skeleton.left.footPos.z + 8 - traceStartZ, 0)
		local rTraceExcess = math.max(skeleton.right.footPos.z + 8 - traceStartZ, 0)
		lReqDrop = math.max(lReqDrop - lTraceExcess, 0)
		rReqDrop = math.max(rReqDrop - rTraceExcess, 0)

		-- figure out body drop. too little = floating. too much = underground. fun times
		local avgDrop = (lReqDrop + rReqDrop) * 0.5
		local maxDrop = math.max(lReqDrop, rReqDrop)
		local heightDiff = math.abs(lReqDrop - rReqDrop)

		local dropBias = math.Clamp(0.75 + (heightDiff / math.max(legLength * 0.2, 6)) * 0.25, 0.75, 1.0)
		local reqDrop = Lerp(dropBias, avgDrop, maxDrop)

		-- make sure body drops enough for lower foot to reach ground
		local kneeRange = math.max(legLength * 0.50, 10)
		local maxKneeExtRad = math.rad(math.abs(MIN_KNEE_BEND))
		local maxKneeExtDist = math.sin(maxKneeExtRad) * kneeRange
		local minRequiredDrop = math.max(maxDrop - maxKneeExtDist * 0.85, 0)
		reqDrop = math.max(reqDrop, minRequiredDrop)

		local unevenFactor = math.Clamp(heightDiff / 10, 0, 1)
		local terrainNeed = math.Clamp(maxDrop / math.max(extraDrop * 0.5, 0.3), 0, 1)
		local desiredDrop = reqDrop + Lerp(unevenFactor, extraDrop, extraDropUneven) * terrainNeed + heightDiff * unevenDropScale * 0.2
		local dropCap = math.min(groundDist * 0.95, legLength * 0.95, maxBodyDropCVar)
		desiredDrop = math.Clamp(desiredDrop, 0, math.max(dropCap, 2))

		if state.bodyDrop then
			local maxStep = math.max(10 * dt * 60, 1.5)
			if crouch.inTransition then
				maxStep = maxStep * 0.35
				-- ease in during crouch or it looks janky
				local transitionBlend = math.Clamp(crouch.transitionTime / CROUCH_BLEND_TIME, 0, 1)
				desiredDrop = desiredDrop * transitionBlend
			end
			desiredDrop = math.Clamp(desiredDrop, state.bodyDrop - maxStep, state.bodyDrop + maxStep)
		end
		state.bodyDrop = desiredDrop
		bodyDrop = desiredDrop

		-- knee bend via asin. should be simple but nothing here ever is
		lKnee = math.deg(math.asin(math.Clamp((bodyDrop - lReqDrop) / kneeRange, -1, 1)))
		rKnee = math.deg(math.asin(math.Clamp((bodyDrop - rReqDrop) / kneeRange, -1, 1)))
		if lKnee > 0 then lKnee = lKnee * bendBoost end
		if rKnee > 0 then rKnee = rKnee * bendBoost end
		lKnee = math.Clamp(lKnee, MIN_KNEE_BEND, MAX_KNEE_BEND)
		rKnee = math.Clamp(rKnee, MIN_KNEE_BEND, MAX_KNEE_BEND)

		-- if knee maxes out the foot gets shoved underground. prevent that
		if antiClip then
			local maxBendAngle = MAX_KNEE_BEND / math.max(bendBoost, 1)
			local maxBendDist = math.sin(math.rad(maxBendAngle)) * kneeRange

			local lExcess = bodyDrop - lReqDrop - maxBendDist
			local rExcess = bodyDrop - rReqDrop - maxBendDist

			if lExcess > 0.5 and lKnee >= MAX_KNEE_BEND - 1 then
				penetrationCorrL = lExcess
			end
			if rExcess > 0.5 and rKnee >= MAX_KNEE_BEND - 1 then
				penetrationCorrR = rExcess
			end

			local maxCorr = math.max(penetrationCorrL, penetrationCorrR)
			if maxCorr > 0.5 then
				bodyDrop = math.max(bodyDrop - maxCorr * 0.6, 0)
				state.bodyDrop = bodyDrop

				lKnee = math.deg(math.asin(math.Clamp((bodyDrop - lReqDrop) / kneeRange, -1, 1)))
				rKnee = math.deg(math.asin(math.Clamp((bodyDrop - rReqDrop) / kneeRange, -1, 1)))
				if lKnee > 0 then lKnee = lKnee * bendBoost end
				if rKnee > 0 then rKnee = rKnee * bendBoost end
				lKnee = math.Clamp(lKnee, MIN_KNEE_BEND, MAX_KNEE_BEND)
				rKnee = math.Clamp(rKnee, MIN_KNEE_BEND, MAX_KNEE_BEND)
			end
		end

		lFootRot = ComputeFootRotation(lContact.samples, footRotScale)
		rFootRot = ComputeFootRotation(rContact.samples, footRotScale)
	else
		local airBlend = math.Clamp(math.abs(velZ) / 260, 0, 1)
		local moveBlend = math.Clamp(vel2D / 160, 0, 1)
		local airCycle = CurTime() * (AIR_SWING_SPEED + moveBlend * 3)
		local swing = math.sin(airCycle) * AIR_SWING_AMP * moveBlend

		bodyDrop = math.min((state.bodyDrop or 0) * (1 - dt * 4), AIR_BODY_DROP_MAX * modelScale)
		if bodyDrop <= 0.05 then
			bodyDrop = 0
			state.bodyDrop = nil
		else
			state.bodyDrop = bodyDrop
		end

		local airKnee = Lerp(airBlend, AIR_KNEE_MIN, AIR_KNEE_MAX) + moveBlend * 3
		lKnee = math.Clamp(airKnee + swing, AIR_KNEE_MIN, AIR_KNEE_MAX)
		rKnee = math.Clamp(airKnee - swing, AIR_KNEE_MIN, AIR_KNEE_MAX)

		local footPitch = Lerp(math.Clamp((velZ + 250) / 500, 0, 1), AIR_FOOT_PITCH_DESCEND, AIR_FOOT_PITCH_ASCEND)
		lFootRot = Angle(0, footPitch + swing * 0.4, 0)
		rFootRot = Angle(0, footPitch - swing * 0.4, 0)

		-- in the air. slowly forget sole correction
		if dynamicSole then
			local dynState = GetDynSoleState(ply)
			dynState.correction = dynState.correction * 0.95
		end
	end

	-- nan safety. if any value is nan we're screwed but at least dont crash
	if bodyDrop ~= bodyDrop then bodyDrop = 0; state.bodyDrop = nil end
	if lKnee ~= lKnee then lKnee = 0 end
	if rKnee ~= rKnee then rKnee = 0 end

	local baseAng = Angle()
	if leanEnabled then
		local lateral = vel:Dot(ply:GetAngles():Right())
		baseAng = Angle(0, 0, -math.Clamp(lateral / 16, -7, 7))
	end

	return {
		basePos = Vector(0, 0, -bodyDrop),
		baseAng = baseAng,
		bodyDrop = bodyDrop,
		lRequiredDrop = lReqDrop,
		rRequiredDrop = rReqDrop,
		left = {
			thigh = Angle(0, -lKnee, 0), calf = Angle(0, lKnee, 0), foot = lFootRot,
			targetPos = lResult.targetPos, contact = lContact,
			planted = lResult.planted, lockPos = lResult.lockPos, footSpeed = lSpeed,
			validation = lValidation,
		},
		right = {
			thigh = Angle(0, -rKnee, 0), calf = Angle(0, rKnee, 0), foot = rFootRot,
			targetPos = rResult.targetPos, contact = rContact,
			planted = rResult.planted, lockPos = rResult.lockPos, footSpeed = rSpeed,
			validation = rValidation,
		},
		debug = {
			velocity2D = vel2D, vertVel = velZ,
			lHitCount = lContact.hitCount, rHitCount = rContact.hitCount,
			leftPlanted = lResult.planted, rightPlanted = rResult.planted,
			leftReleased = lResult.released, rightReleased = rResult.released,
			leftLockDist = lResult.lockPos and skeleton.left.footPos:Distance(lResult.lockPos) or -1,
			rightLockDist = rResult.lockPos and skeleton.right.footPos:Distance(rResult.lockPos) or -1,
			leftGap = skeleton.left.footPos:Distance(lContact.position),
			rightGap = skeleton.right.footPos:Distance(rContact.position),
			idleActive = idle.active, idleCandidateTime = idle.candidateTime or 0,
			supportSide = support, leftFootSpeed = lSpeed, rightFootSpeed = rSpeed,
			modelScale = modelScale, measuredLeg = skeleton.measuredLegLength or REFERENCE_LEG_LENGTH,
			dynSoleCorr = dynSoleCorr,
			penetrationCorrL = penetrationCorrL,
			penetrationCorrR = penetrationCorrR,
			lPenetrationCount = lValidation.penetrationCount,
			rPenetrationCount = rValidation.penetrationCount,
			lNormalVariance = lValidation.normalVariance,
			rNormalVariance = rValidation.normalVariance,
		},
	}
end

function Controller.DrawDebug(ply, result)
	local debugCvar = RT.CVars.debug
	if not debugCvar then return end
	local level = debugCvar:GetInt()
	if level <= 0 or not RT.CanManipulateBones(ply) then return end

	RT.Ground.DrawSamples(result.left.contact.samples, RT.Ground.DebugColors(true), RT.Colors.green, level)
	RT.Ground.DrawSamples(result.right.contact.samples, RT.Ground.DebugColors(false), RT.Colors.green, level)

	local colorRed = Color(255, 60, 60)
	local colorGreen = Color(60, 255, 60)
	local colorYellow = Color(255, 220, 60)
	local soleOffset = RT.GetIKParam(ply, "sole_offset")

	for _, leg in ipairs({result.left, result.right}) do
		if not leg.targetPos then continue end
		local isLeft = leg == result.left
		local col = RT.Ground.DebugColors(isLeft)
		render.DrawWireframeBox(leg.targetPos, angle_zero, Vector(-2, -2, -1), Vector(2, 2, 1), col, true)

		if leg.contact and leg.contact.position then
			render.DrawLine(leg.contact.position, leg.contact.position + leg.contact.normal * 8, RT.Colors.green)
			if soleOffset > 0.01 then
				local rawGround = leg.contact.position - leg.contact.normal * soleOffset
				render.DrawLine(rawGround, leg.contact.position, colorYellow)
			end
		end

		if leg.lockPos then
			render.DrawWireframeBox(leg.lockPos, angle_zero, Vector(-1.5, -1.5, -1.5), Vector(1.5, 1.5, 1.5), RT.Colors.white, true)
		end

		if level > 1 and leg.validation then
			if leg.validation.penetrationCount > 0 then
				local warnPos = leg.contact and leg.contact.position or leg.targetPos
				if warnPos then
					render.DrawWireframeBox(warnPos, angle_zero, Vector(-3, -3, -0.5), Vector(3, 3, 0.5), colorRed, true)
				end
			end
			if leg.validation.highestValidZ > -math.huge and leg.contact and leg.contact.position then
				local corrPos = Vector(leg.contact.position.x, leg.contact.position.y, leg.validation.highestValidZ)
				render.DrawWireframeBox(corrPos, angle_zero, Vector(-1, -1, -0.5), Vector(1, 1, 0.5), colorGreen, true)
			end
		end
	end

	if level > 1 and IKFoot.ModelAnalysisCache then
		local analysis = IKFoot.ModelAnalysisCache[ply:GetModel()]
		if analysis and analysis.info then
			local plyPos = ply:GetPos()
			local meshWorldZ = plyPos.z + (analysis.info.meshBottomZ or 0)
			local center = Vector(plyPos.x, plyPos.y, meshWorldZ)
			local colorOrange = Color(255, 128, 0)
			render.DrawLine(center + Vector(-10, 0, 0), center + Vector(10, 0, 0), colorOrange)
			render.DrawLine(center + Vector(0, -10, 0), center + Vector(0, 10, 0), colorOrange)
		end
	end

	if level > 1 then
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
		RT.Debug2D = RT.Debug2D or {}
		RT.Debug2D.expireAt = CurTime() + 0.2
		RT.Debug2D.lines = {
			string.format("IK DEBUG [%s]", IsValid(ply) and ply:Nick() or "player"),
			string.format("VEL2D: %.1f  VELZ: %.1f", d.velocity2D or 0, d.vertVel or 0),
			string.format("TRACE HITS L/R: %d/%d", d.lHitCount or 0, d.rHitCount or 0),
			string.format("L_REQ: %.1f  R_REQ: %.1f  DROP: %.1f", result.lRequiredDrop or 0, result.rRequiredDrop or 0, result.bodyDrop or 0),
			string.format("PLANTED L/R: %s/%s  RELEASE L/R: %s/%s", d.leftPlanted and "Y" or "N", d.rightPlanted and "Y" or "N", d.leftReleased and "Y" or "N", d.rightReleased and "Y" or "N"),
			string.format("LOCK DIST L/R: %s / %s", d.leftLockDist >= 0 and string.format("%.1f", d.leftLockDist) or "--", d.rightLockDist >= 0 and string.format("%.1f", d.rightLockDist) or "--"),
			string.format("FOOT GAP L/R: %.1f / %.1f", d.leftGap or 0, d.rightGap or 0),
			string.format("FOOT SPD L/R: %.1f / %.1f", d.leftFootSpeed or 0, d.rightFootSpeed or 0),
			string.format("SUPPORT: %s  IDLE: %s (%.2f)", string.upper(d.supportSide or "none"), d.idleActive and "ON" or "OFF", d.idleCandidateTime or 0),
			string.format("MODEL SCALE: %.2f  LEG: %.1f", d.modelScale or 1, d.measuredLeg or 0),
			string.format("DYN SOLE: %.2f  PEN L/R: %d/%d", d.dynSoleCorr or 0, d.lPenetrationCount or 0, d.rPenetrationCount or 0),
			string.format("PEN CORR L/R: %.1f/%.1f  NVAR: %.2f/%.2f", d.penetrationCorrL or 0, d.penetrationCorrR or 0, d.lNormalVariance or 0, d.rNormalVariance or 0),
		}
	end
end