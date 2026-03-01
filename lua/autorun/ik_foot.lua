if CLIENT then
	-- per player sync stuff
	
	local COLOR_WHITE = Color(255, 255, 255, 255)
	local COLOR_RED = Color(255, 0, 0, 255)
	local COLOR_GREEN = Color(0, 255, 0, 255)

	-- client cvars
	local cvIkFoot = CreateClientConVar("ik_foot", 1, true, true, "enable/disable IK foot system")
	local cvIkFootLean = CreateClientConVar("ik_foot_lean", 0, true, true, "enable/disable body leaning")
	local cvGroundDistance = CreateClientConVar("ik_foot_ground_distance", 45, true, true, "ground detection range")
	local cvSmoothing = CreateClientConVar("ik_foot_smoothing", 17, true, true, "animation smoothing factor")
	local cvDebug = CreateClientConVar("ik_foot_debug", 0, true, true, "debug visualization level")
	local cvLegLength = CreateClientConVar("ik_foot_leg_length", 45, true, true, "leg length for calculations")
	local cvTraceStartOffset = CreateClientConVar("ik_foot_trace_start_offset", 30, true, true, "trace starting height offset")
	local cvSoleOffset = CreateClientConVar("ik_foot_sole_offset", 1.75, true, true, "sole contact point offset")
	local cvUnevenDropScale = CreateClientConVar("ik_foot_uneven_drop_scale", 0.35, true, true, "body drop scaling on uneven terrain")
	local cvExtraBodyDrop = CreateClientConVar("ik_foot_extra_body_drop", 0.3, true, true, "base body drop amount")
	local cvExtraBodyDropUneven = CreateClientConVar("ik_foot_extra_body_drop_uneven", 1.2, true, true, "additional body drop on slopes")
	local cvHighFootBendBoost = CreateClientConVar("ik_foot_high_foot_bend_boost", 1.45, true, true, "knee bend multiplier")
	local cvFootRotationScale = CreateClientConVar("ik_foot_rotation_scale", 0.15, true, true, "foot rotation intensity")
	local cvStabilizeIdle = CreateClientConVar("ik_foot_stabilize_idle", 1, true, true, "stabilize when idle")
	local cvIdleVelocityThreshold = CreateClientConVar("ik_foot_idle_velocity", 5, true, true, "idle detection threshold")
	local cvIdleDistanceThreshold = CreateClientConVar("ik_foot_idle_threshold", 0.5, true, true, "idle position tolerance")

	local function GetIKParam(ply, paramName, conVar)
		if ply == LocalPlayer() then
			return conVar:GetFloat()
		else
			local nwValue = ply:GetNWFloat("IK_" .. paramName, 0)
			return nwValue
		end
	end
	
	local function GetIKParamBool(ply, paramName, conVar)
		if ply == LocalPlayer() then
			return conVar:GetBool()
		else
			return ply:GetNWBool("IK_" .. paramName, false)
		end
	end

	local function UsePACBoneAPI()
		return istable(pac) and pac.IsEnabled and pac.IsEnabled() and 
		       isfunction(pac.ManipulateBonePosition) and isfunction(pac.ManipulateBoneAngles)
	end

	local function SetBonePosition(ply, bone, pos)
		if bone == nil then return end
		if UsePACBoneAPI() then
			pac.ManipulateBonePosition(ply, bone, pos)
		else
			ply:ManipulateBonePosition(bone, pos)
		end
	end

	local function SetBoneAngles(ply, bone, ang)
		if bone == nil then return end
		if UsePACBoneAPI() then
			pac.ManipulateBoneAngles(ply, bone, ang)
		else
			ply:ManipulateBoneAngles(bone, ang)
		end
	end

	local function GetIKBones(ply)
		local model = ply:GetModel()
		local bones = ply.IKBones

		if bones and bones.model == model then
			return bones
		end

		bones = {
			model = model,
			lFoot = ply:LookupBone("ValveBiped.Bip01_L_Foot"),
			rFoot = ply:LookupBone("ValveBiped.Bip01_R_Foot"),
			lCalf = ply:LookupBone("ValveBiped.Bip01_L_Calf"),
			rCalf = ply:LookupBone("ValveBiped.Bip01_R_Calf"),
			lThigh = ply:LookupBone("ValveBiped.Bip01_L_Thigh"),
			rThigh = ply:LookupBone("ValveBiped.Bip01_R_Thigh"),
		}

		ply.IKBones = bones
		return bones
	end

	local function CanManipulateBones(ply)
		if ply:InVehicle() then return false end
		if istable(ActionGmod) and ply:IsDive() then return false end
		if istable(prone) and ply:IsProne() then return false end
		return true
	end

	local function TraceGroundSample(ply, startPos, groundDist)
		local soleOffset = GetIKParam(ply, "sole_offset", cvSoleOffset)
		
		local trace = util.TraceHull({
			start = startPos,
			endpos = startPos - Vector(0, 0, groundDist),
			mins = Vector(-2, -2, 0),
			maxs = Vector(2, 2, 4),
			filter = ply
		})

		if trace.Hit then
			local normal = trace.HitNormal or vector_up
			local contactPos = trace.HitPos + normal * soleOffset
			local distance = math.Clamp(startPos.z - contactPos.z, 0, groundDist)
			return {
				hit = true,
				hitPos = contactPos,
				normal = normal,
				distance = distance,
				startPos = startPos,
			}
		end

		return {
			hit = false,
			hitPos = startPos - Vector(0, 0, groundDist),
			normal = vector_up,
			distance = groundDist,
			startPos = startPos,
		}
	end

	local function SampleFootGround(ply, footPos, footAng, traceStartZ, groundDist)
		local footForward = footAng:Forward()
		footForward.z = 0

		if footForward:LengthSqr() < 0.001 then
			footForward = Vector(1, 0, 0)
		else
			footForward:Normalize()
		end

		local footRight = footAng:Right()
		footRight.z = 0

		if footRight:LengthSqr() < 0.001 then
			footRight = Vector(0, 1, 0)
		else
			footRight:Normalize()
		end

		local baseStart = Vector(footPos.x, footPos.y, traceStartZ)
		local offsets = {
			center = Vector(0, 0, 0),
			toe = footForward * 8,
			heel = -footForward * 5,
			left = -footRight * 3,
			right = footRight * 3,
		}

		local samples = {}
		for name, offset in pairs(offsets) do
			samples[name] = TraceGroundSample(ply, baseStart + offset, groundDist)
		end

		return samples
	end

	-- main ik calc
	local function CalculateIK(ply, lFootPos, rFootPos, lFootAng, rFootAng)
		local groundDist = GetIKParam(ply, "ground_distance", cvGroundDistance)
		local legLength = GetIKParam(ply, "leg_length", cvLegLength)
		local traceStartOffset = GetIKParam(ply, "trace_start_offset", cvTraceStartOffset)
		local soleOffset = GetIKParam(ply, "sole_offset", cvSoleOffset)
		local unevenDropScale = GetIKParam(ply, "uneven_drop_scale", cvUnevenDropScale)
		local extraBodyDrop = GetIKParam(ply, "extra_body_drop", cvExtraBodyDrop)
		local extraBodyDropUneven = GetIKParam(ply, "extra_body_drop_uneven", cvExtraBodyDropUneven)
		local highFootBendBoost = GetIKParam(ply, "high_foot_bend_boost", cvHighFootBendBoost)
		local footRotationScale = GetIKParam(ply, "foot_rotation_scale", cvFootRotationScale)
		local ikFootLean = GetIKParamBool(ply, "lean_enabled", cvIkFootLean)
		
		local traceStartZ = ply:GetPos().z + traceStartOffset
		
		-- init foot lock state
		if not ply.IKFootState then
			ply.IKFootState = {
				left = { planted = false, lockPos = nil },
				right = { planted = false, lockPos = nil },
			}
		end
		if not ply.IKFootLastPos then
			ply.IKFootLastPos = { left = Vector(0, 0, 0), right = Vector(0, 0, 0) }
		end

		local lSamples = SampleFootGround(ply, lFootPos, lFootAng, traceStartZ, groundDist)
		local rSamples = SampleFootGround(ply, rFootPos, rFootAng, traceStartZ, groundDist)

		local lDist = lSamples.center.distance
		local rDist = rSamples.center.distance

		local midFootPos = (lFootPos + rFootPos) * 0.5
		local midSamples = SampleFootGround(ply, midFootPos, lFootAng, traceStartZ, groundDist)
		local midDist = midSamples.center.distance

		local velocity2D = ply:GetVelocity():Length2D()
		local vertVel = ply:GetVelocity().z

		local preRawMaxDist = math.max(lDist, rDist)
		local preRawMinDist = math.min(lDist, rDist)
		local preHeightDiff = preRawMaxDist - preRawMinDist
		local preMidToMinDiff = midDist - preRawMinDist
		local preMinToMaxDiff = preRawMaxDist - preRawMinDist
		local preStairsDetected = preHeightDiff > 10 and preMidToMinDiff < (preMinToMaxDiff * 0.4)
		local preHigherFoot = lDist > rDist and "left" or "right"
		
		local rawLFootPos = lFootPos
		local rawRFootPos = rFootPos

		if not ply.IKFootBoneLastPos then
			ply.IKFootBoneLastPos = { left = rawLFootPos, right = rawRFootPos }
		end

		local swingHorizontalThreshold = 4
		local swingVerticalThreshold = 3
		local minVelocityToConsiderSwing = 2

		local function isSwingStart(lastRaw, raw)
			local delta = raw - lastRaw
			local horiz = Vector(delta.x, delta.y, 0):Length()
			local vert = math.abs(delta.z)
			return (horiz > swingHorizontalThreshold or vert > swingVerticalThreshold)
		end

		if ply.IKFootState.left.planted and ply.IKFootState.left.lockPos then
			if isSwingStart(ply.IKFootBoneLastPos.left, rawLFootPos) and velocity2D > minVelocityToConsiderSwing then
				ply.IKFootState.left.planted = false
				ply.IKFootState.left.lockPos = nil
			end
		end

		if ply.IKFootState.right.planted and ply.IKFootState.right.lockPos then
			if isSwingStart(ply.IKFootBoneLastPos.right, rawRFootPos) and velocity2D > minVelocityToConsiderSwing then
				ply.IKFootState.right.planted = false
				ply.IKFootState.right.lockPos = nil
			end
		end

		-- landing detect
		local footContactThreshold = 4
		local velocityThreshold = 50
		local vertVelThreshold = 30
		local plantReleaseDistance = 10

		local lStance = ply:OnGround() and lDist < footContactThreshold and velocity2D < velocityThreshold and math.abs(vertVel) < vertVelThreshold
		if lStance and not ply.IKFootState.left.planted then
			ply.IKFootState.left.planted = true
			if preStairsDetected and preHigherFoot == "left" and midSamples and midSamples.center then
				ply.IKFootState.left.lockPos = Vector(midSamples.center.hitPos.x, midSamples.center.hitPos.y, midSamples.center.hitPos.z)
			else
				ply.IKFootState.left.lockPos = lSamples.center.hitPos
			end
		end

		local rStance = ply:OnGround() and rDist < footContactThreshold and velocity2D < velocityThreshold and math.abs(vertVel) < vertVelThreshold
		if rStance and not ply.IKFootState.right.planted then
			ply.IKFootState.right.planted = true
			if preStairsDetected and preHigherFoot == "right" and midSamples and midSamples.center then
				ply.IKFootState.right.lockPos = Vector(midSamples.center.hitPos.x, midSamples.center.hitPos.y, midSamples.center.hitPos.z)
			else
				ply.IKFootState.right.lockPos = rSamples.center.hitPos
			end
		end

		if ply.IKFootState.left.planted and ply.IKFootState.left.lockPos then
			local distFromLock = rawLFootPos:Distance(ply.IKFootState.left.lockPos)
			local shouldRelease = (lDist > footContactThreshold + 3) and (distFromLock > plantReleaseDistance * 1.2) and (velocity2D > velocityThreshold * 1.5)
			if shouldRelease then
				ply.IKFootState.left.planted = false
				ply.IKFootState.left.lockPos = nil
			end
		end

		if ply.IKFootState.right.planted and ply.IKFootState.right.lockPos then
			local distFromLock = rawRFootPos:Distance(ply.IKFootState.right.lockPos)
			local shouldRelease = (rDist > footContactThreshold + 3) and (distFromLock > plantReleaseDistance * 1.2) and (velocity2D > velocityThreshold * 1.5)
			if shouldRelease then
				ply.IKFootState.right.planted = false
				ply.IKFootState.right.lockPos = nil
			end
		end

		-- lock or clamp in 3d
		local maxHorizontalMovePerFrame = 2.5
		local maxVerticalMovePerFrame = 3

		if ply.IKFootState.left.planted and ply.IKFootState.left.lockPos then
			lFootPos = ply.IKFootState.left.lockPos
		else
			local lMoveDelta = rawLFootPos - (ply.IKFootLastPos and ply.IKFootLastPos.left or rawLFootPos)
			local lHorizontalDelta = Vector(lMoveDelta.x, lMoveDelta.y, 0)
			local lVerticalDelta = lMoveDelta.z
			local lHorizontalLen = lHorizontalDelta:Length()

			if lHorizontalLen > maxHorizontalMovePerFrame then
				lHorizontalDelta = lHorizontalDelta:GetNormalized() * maxHorizontalMovePerFrame
			end
			if math.abs(lVerticalDelta) > maxVerticalMovePerFrame then
				lVerticalDelta = math.Clamp(lVerticalDelta, -maxVerticalMovePerFrame, maxVerticalMovePerFrame)
			end

			lFootPos = (ply.IKFootLastPos and ply.IKFootLastPos.left or rawLFootPos) + lHorizontalDelta + Vector(0,0,lVerticalDelta)
		end

		if ply.IKFootState.right.planted and ply.IKFootState.right.lockPos then
			rFootPos = ply.IKFootState.right.lockPos
		else
			local rMoveDelta = rawRFootPos - (ply.IKFootLastPos and ply.IKFootLastPos.right or rawRFootPos)
			local rHorizontalDelta = Vector(rMoveDelta.x, rMoveDelta.y, 0)
			local rVerticalDelta = rMoveDelta.z
			local rHorizontalLen = rHorizontalDelta:Length()

			if rHorizontalLen > maxHorizontalMovePerFrame then
				rHorizontalDelta = rHorizontalDelta:GetNormalized() * maxHorizontalMovePerFrame
			end
			if math.abs(rVerticalDelta) > maxVerticalMovePerFrame then
				rVerticalDelta = math.Clamp(rVerticalDelta, -maxVerticalMovePerFrame, maxVerticalMovePerFrame)
			end

			rFootPos = (ply.IKFootLastPos and ply.IKFootLastPos.right or rawRFootPos) + rHorizontalDelta + Vector(0,0,rVerticalDelta)
		end

		ply.IKFootLastPos = ply.IKFootLastPos or {}
		ply.IKFootLastPos.left = lFootPos
		ply.IKFootLastPos.right = rFootPos

		ply.IKFootBoneLastPos.left = rawLFootPos
		ply.IKFootBoneLastPos.right = rawRFootPos
		
		lSamples = SampleFootGround(ply, lFootPos, lFootAng, traceStartZ, groundDist)
		rSamples = SampleFootGround(ply, rFootPos, rFootAng, traceStartZ, groundDist)
		lDist = lSamples.center.distance
		rDist = rSamples.center.distance

		local result = {
			basePos = Vector(0, 0, 0),
			baseAng = Angle(0, 0, 0),
			lCalf = Angle(0, 0, 0),
			rCalf = Angle(0, 0, 0),
			lThigh = Angle(0, 0, 0),
			rThigh = Angle(0, 0, 0),
			lFoot = Angle(0, 0, 0),
			rFoot = Angle(0, 0, 0),
			lDist = lDist,
			rDist = rDist,
			midDist = midDist,
			bodyDrop = 0,
			lSamples = lSamples,
			rSamples = rSamples,
			midSamples = midSamples,
		}

		if ply:OnGround() then
			-- body drop from ground
			local rawMaxDist = math.max(lDist, rDist)
			local rawMinDist = math.min(lDist, rDist)
			local rawHeightDiff = rawMaxDist - rawMinDist
			
			local stairThreshold = 10
			local midToMinDiff = midDist - rawMinDist
			local minToMaxDiff = rawMaxDist - rawMinDist
			local stairsDetected = rawHeightDiff > stairThreshold and midToMinDiff < (minToMaxDiff * 0.4)

			local effLDist = lDist
			local effRDist = rDist
			if stairsDetected then
				if lDist > rDist then
					effLDist = midDist
				else
					effRDist = midDist
				end
			end

			local maxDist = math.max(effLDist, effRDist)
			local minDist = math.min(effLDist, effRDist)
			local avgDist = (effLDist + effRDist) * 0.5
			local heightDiff = maxDist - minDist
			
			local unevenFactor = math.Clamp(heightDiff / 8, 0, 1)
			
			local stairsReduction = stairsDetected and 0.1 or (heightDiff > 15 and 0.2 or 1.0)
			local extraDrop = Lerp(unevenFactor, extraBodyDrop, extraBodyDropUneven) * stairsReduction
			
			local baseDrop = stairsDetected and midDist or maxDist
			local bodyDrop = math.max(baseDrop - traceStartOffset, 0)
			bodyDrop = bodyDrop + (heightDiff * unevenDropScale * (stairsDetected and 0.1 or 0.25)) + extraDrop
			bodyDrop = math.Clamp(bodyDrop, 0, groundDist * 0.4)
			
			if not ply.IKLastBodyDrop then
				ply.IKLastBodyDrop = bodyDrop
			else
				local maxDeltaPerFrame = 4
				bodyDrop = math.Clamp(bodyDrop, ply.IKLastBodyDrop - maxDeltaPerFrame, ply.IKLastBodyDrop + maxDeltaPerFrame)
			end
			ply.IKLastBodyDrop = bodyDrop

			result.bodyDrop = bodyDrop
			result.basePos = Vector(0, 0, -bodyDrop)

			-- knee bend
			local kneeRange = math.max(legLength * 0.33, 10)
			local bendBoost = highFootBendBoost
			local lDelta = avgDist - effLDist
			local rDelta = avgDist - effRDist

			local lAlpha = math.deg(math.asin(math.Clamp(lDelta / kneeRange, -1, 1)))
			local rAlpha = math.deg(math.asin(math.Clamp(rDelta / kneeRange, -1, 1)))

			if lAlpha > 0 then lAlpha = lAlpha * bendBoost end
			if rAlpha > 0 then rAlpha = rAlpha * bendBoost end

			lAlpha = math.Clamp(lAlpha, -30, 65)
			rAlpha = math.Clamp(rAlpha, -30, 65)

			result.lCalf = Angle(0, lAlpha, 0)
			result.lThigh = Angle(0, -lAlpha, 0)
			result.rCalf = Angle(0, rAlpha, 0)
			result.rThigh = Angle(0, -rAlpha, 0)

			-- foot rot from ground
			local rotScale = footRotationScale
			
			if rotScale > 0.01 then
				local lToeHeelLen = math.max(lSamples.toe.hitPos:Distance(lSamples.heel.hitPos), 0.01)
				local rToeHeelLen = math.max(rSamples.toe.hitPos:Distance(rSamples.heel.hitPos), 0.01)
				local lLeftRightLen = math.max(lSamples.right.hitPos:Distance(lSamples.left.hitPos), 0.01)
				local rLeftRightLen = math.max(rSamples.right.hitPos:Distance(rSamples.left.hitPos), 0.01)

				local lPitch = -math.deg(math.atan2(lSamples.toe.hitPos.z - lSamples.heel.hitPos.z, lToeHeelLen))
				local rPitch = -math.deg(math.atan2(rSamples.toe.hitPos.z - rSamples.heel.hitPos.z, rToeHeelLen))
				local lRoll = math.deg(math.atan2(lSamples.right.hitPos.z - lSamples.left.hitPos.z, lLeftRightLen))
				local rRoll = math.deg(math.atan2(rSamples.right.hitPos.z - rSamples.left.hitPos.z, rLeftRightLen))

				lPitch = lPitch * rotScale
				rPitch = rPitch * rotScale
				lRoll = lRoll * rotScale
				rRoll = rRoll * rotScale

				lPitch = math.Clamp(lPitch, -25, 25)
				rPitch = math.Clamp(rPitch, -25, 25)
				lRoll = math.Clamp(lRoll, -20, 20)
				rRoll = math.Clamp(rRoll, -20, 20)

				result.lFoot = Angle(0, lPitch, lRoll)
				result.rFoot = Angle(0, rPitch, rRoll)
			else
				result.lFoot = Angle(0, 0, 0)
				result.rFoot = Angle(0, 0, 0)
			end

			if ikFootLean then
				local plyVel = ply:GetVelocity()
				local plyAng = ply:GetAimVector():Angle()
				local leanY = math.Clamp(plyVel:Dot(plyAng:Right()) / 20, -4, 4)
				result.baseAng = Angle(0, leanY, 0)
			end
		end

		return result
	end

	-- debug draw
	local function DrawDebug(ply, ikResult, maxDrop)
		local debugLevel = cvDebug:GetInt()
		if debugLevel <= 0 or not CanManipulateBones(ply) then return end

		local mins = Vector(-3, -3, 0)
		local maxs = Vector(3, 3, 5)
		local COLOR_BLUE = Color(0, 100, 255, 255)

		local lCenter = ikResult.lSamples and ikResult.lSamples.center
		local rCenter = ikResult.rSamples and ikResult.rSamples.center
		local midCenter = ikResult.midSamples and ikResult.midSamples.center
		if not lCenter or not rCenter then return end

		render.DrawWireframeBox(lCenter.hitPos, Angle(), mins, maxs, COLOR_RED, true)
		render.DrawLine(lCenter.startPos, lCenter.hitPos, COLOR_RED)
		render.DrawLine(lCenter.hitPos, lCenter.hitPos + lCenter.normal * 6, COLOR_GREEN)

		render.DrawWireframeBox(rCenter.hitPos, Angle(), mins, maxs, COLOR_RED, true)
		render.DrawLine(rCenter.startPos, rCenter.hitPos, COLOR_RED)
		render.DrawLine(rCenter.hitPos, rCenter.hitPos + rCenter.normal * 6, COLOR_GREEN)

		if midCenter then
			render.DrawWireframeBox(midCenter.hitPos, Angle(), mins, maxs, COLOR_BLUE, true)
			render.DrawLine(midCenter.startPos, midCenter.hitPos, COLOR_BLUE)
			render.DrawLine(midCenter.hitPos, midCenter.hitPos + midCenter.normal * 6, COLOR_GREEN)
		end

		if debugLevel > 1 then
			local bottom, top = ply:GetHull()
			if ply:Crouching() then
				bottom, top = ply:GetHullDuck()
			end
			render.DrawWireframeBox(ply:GetPos(), Angle(), bottom, top, COLOR_WHITE, true)

			local textPos = ply:GetPos() + Vector(0, 0, 86)
			debugoverlay.Text(
				textPos,
				string.format("L_DIST: %.1f  R_DIST: %.1f  MID_DIST: %.1f  DROP: %.1f", ikResult.lDist, ikResult.rDist, ikResult.midDist or 0, maxDrop),
				FrameTime() * 2,
				false
			)
		end
	end

	-- main draw hook
	hook.Add("PostPlayerDraw", "IKFoot_PostPlayerDraw", function(ply)
		if not IsValid(ply) then return end
		
		local ikEnabled = GetIKParamBool(ply, "enabled", cvIkFoot)
		if not ikEnabled then return end
		if not CanManipulateBones(ply) then return end

		local bones = GetIKBones(ply)
		if not (bones.lFoot and bones.rFoot and bones.lCalf and bones.rCalf and bones.lThigh and bones.rThigh) then
			return
		end

		local lFootPos, lFootAng = ply:GetBonePosition(bones.lFoot)
		local rFootPos, rFootAng = ply:GetBonePosition(bones.rFoot)

		if not (lFootPos and rFootPos and lFootAng and rFootAng) then return end

		local ikResult = CalculateIK(ply, lFootPos, rFootPos, lFootAng, rFootAng)

		if not ply.IKResult then
			ply.IKResult = {
				basePos = Vector(0, 0, 0),
				baseAng = Angle(0, 0, 0),
				lCalf = Angle(0, 0, 0),
				rCalf = Angle(0, 0, 0),
				lThigh = Angle(0, 0, 0),
				rThigh = Angle(0, 0, 0),
				lFoot = Angle(0, 0, 0),
				rFoot = Angle(0, 0, 0),
			}
		end

		local smoothingFactor = GetIKParam(ply, "smoothing", cvSmoothing)
		local lerpTime = math.Clamp(FrameTime() * smoothingFactor, 0, 1)

		ply.IKResult.basePos = LerpVector(lerpTime, ply.IKResult.basePos, ikResult.basePos)
		ply.IKResult.baseAng = LerpAngle(lerpTime, ply.IKResult.baseAng, ikResult.baseAng)
		ply.IKResult.lCalf = LerpAngle(lerpTime, ply.IKResult.lCalf, ikResult.lCalf)
		ply.IKResult.rCalf = LerpAngle(lerpTime, ply.IKResult.rCalf, ikResult.rCalf)
		ply.IKResult.lThigh = LerpAngle(lerpTime, ply.IKResult.lThigh, ikResult.lThigh)
		ply.IKResult.rThigh = LerpAngle(lerpTime, ply.IKResult.rThigh, ikResult.rThigh)
		ply.IKResult.lFoot = LerpAngle(lerpTime, ply.IKResult.lFoot, ikResult.lFoot)
		ply.IKResult.rFoot = LerpAngle(lerpTime, ply.IKResult.rFoot, ikResult.rFoot)

		SetBonePosition(ply, 0, ply.IKResult.basePos)
		SetBoneAngles(ply, 0, ply.IKResult.baseAng)

		SetBoneAngles(ply, bones.lCalf, ply.IKResult.lCalf)
		SetBoneAngles(ply, bones.rCalf, ply.IKResult.rCalf)
		SetBoneAngles(ply, bones.lThigh, ply.IKResult.lThigh)
		SetBoneAngles(ply, bones.rThigh, ply.IKResult.rThigh)
		SetBoneAngles(ply, bones.lFoot, ply.IKResult.lFoot)
		SetBoneAngles(ply, bones.rFoot, ply.IKResult.rFoot)

		if cvDebug:GetInt() > 0 then
			DrawDebug(ply, ikResult, ikResult.bodyDrop or 0)
		end
	end)

	-- send local config
	local lastConfigSync = 0
	hook.Add("Think", "IKFoot_SyncConfigToServer", function()
		local now = UnPredictedCurTime()
		if now - lastConfigSync < 0.5 then return end
		lastConfigSync = now

		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		net.Start("IKFoot_ConfigUpdate")
			net.WriteBool(cvIkFoot:GetBool())
			net.WriteFloat(cvGroundDistance:GetFloat())
			net.WriteFloat(cvLegLength:GetFloat())
			net.WriteFloat(cvTraceStartOffset:GetFloat())
			net.WriteFloat(cvSoleOffset:GetFloat())
			net.WriteFloat(cvUnevenDropScale:GetFloat())
			net.WriteFloat(cvExtraBodyDrop:GetFloat())
			net.WriteFloat(cvExtraBodyDropUneven:GetFloat())
			net.WriteFloat(cvHighFootBendBoost:GetFloat())
			net.WriteFloat(cvFootRotationScale:GetFloat())
			net.WriteBool(cvIkFootLean:GetBool())
			net.WriteFloat(cvSmoothing:GetFloat())
			net.WriteBool(cvStabilizeIdle:GetBool())
			net.WriteFloat(cvIdleVelocityThreshold:GetFloat())
			net.WriteFloat(cvIdleDistanceThreshold:GetFloat())
		net.SendToServer()
	end)

	-- reset bones when off
	hook.Add("PostPlayerDraw", "IKFoot_ResetBones", function(ply)
		if not IsValid(ply) then return end
		
		local ikEnabled = GetIKParamBool(ply, "enabled", cvIkFoot)
		if ikEnabled or not CanManipulateBones(ply) then return end

		local bones = GetIKBones(ply)
		if not (bones.lFoot and bones.rFoot) then return end

		SetBonePosition(ply, 0, Vector())
		SetBoneAngles(ply, 0, Angle())
		SetBoneAngles(ply, bones.lCalf, Angle())
		SetBoneAngles(ply, bones.rCalf, Angle())
		SetBoneAngles(ply, bones.lThigh, Angle())
		SetBoneAngles(ply, bones.rThigh, Angle())
		SetBoneAngles(ply, bones.lFoot, Angle())
		SetBoneAngles(ply, bones.rFoot, Angle())
	end)
end