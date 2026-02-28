if CLIENT then
	local COLOR_WHITE = Color(255, 255, 255, 255)
	local COLOR_RED = Color(255, 0, 0, 255)
	local COLOR_GREEN = Color(0, 255, 0, 255)

	-- configuration variables
	local cvIkFoot = CreateClientConVar("ik_foot", 1, true, true, "enable/disable IK foot system")
	local cvIkFootLean = CreateClientConVar("ik_foot_lean", 0, true, true, "enable/disable body leaning")
	local cvGroundDistance = CreateClientConVar("ik_foot_ground_distance", 45, true, true, "ground detection range")
	local cvSmoothing = CreateClientConVar("ik_foot_smoothing", 17, true, true, "animation smoothing factor")
	local cvDebug = CreateClientConVar("ik_foot_debug", 0, true, true, "debug visualization level")
	local cvLegLength = CreateClientConVar("ik_foot_leg_length", 45, true, true, "leg length for calculations")
	local cvTraceStartOffset = CreateClientConVar("ik_foot_trace_start_offset", 30, true, true, "trace starting height offset")
	local cvSoleOffset = CreateClientConVar("ik_foot_sole_offset", 1.75, true, true, "sole contact point offset")
	local cvUnevenDropScale = CreateClientConVar("ik_foot_uneven_drop_scale", 0.35, true, true, "body drop scaling on uneven terrain")
	local cvExtraBodyDrop = CreateClientConVar("ik_foot_extra_body_drop", 1.0, true, true, "base body drop amount")
	local cvExtraBodyDropUneven = CreateClientConVar("ik_foot_extra_body_drop_uneven", 4.0, true, true, "additional body drop on slopes")
	local cvHighFootBendBoost = CreateClientConVar("ik_foot_high_foot_bend_boost", 1.45, true, true, "knee bend multiplier")
	local cvFootRotationScale = CreateClientConVar("ik_foot_rotation_scale", 0.15, true, true, "foot rotation intensity")
	local cvStabilizeIdle = CreateClientConVar("ik_foot_stabilize_idle", 1, true, true, "stabilize when idle")
	local cvIdleVelocityThreshold = CreateClientConVar("ik_foot_idle_velocity", 5, true, true, "idle detection threshold")
	local cvIdleDistanceThreshold = CreateClientConVar("ik_foot_idle_threshold", 0.5, true, true, "idle position tolerance")

	-- pac3 compatibility check
	local function UsePACBoneAPI()
		return istable(pac) and pac.IsEnabled and pac.IsEnabled() and 
		       isfunction(pac.ManipulateBonePosition) and isfunction(pac.ManipulateBoneAngles)
	end

	-- bone position manipulation
	local function SetBonePosition(ply, bone, pos)
		if bone == nil then return end
		if UsePACBoneAPI() then
			pac.ManipulateBonePosition(ply, bone, pos)
		else
			ply:ManipulateBonePosition(bone, pos)
		end
	end

	-- bone angle manipulation
	local function SetBoneAngles(ply, bone, ang)
		if bone == nil then return end
		if UsePACBoneAPI() then
			pac.ManipulateBoneAngles(ply, bone, ang)
		else
			ply:ManipulateBoneAngles(bone, ang)
		end
	end

	-- retrieve bone indices from model
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

	-- check if manipulation is allowed
	local function CanManipulateBones(ply)
		if ply:InVehicle() then return false end
		if istable(ActionGmod) and ply:IsDive() then return false end
		if istable(prone) and ply:IsProne() then return false end
		return true
	end

	local function TraceGroundSample(ply, startPos, groundDist)
		local trace = util.TraceHull({
			start = startPos,
			endpos = startPos - Vector(0, 0, groundDist),
			mins = Vector(-2, -2, 0),
			maxs = Vector(2, 2, 4),
			filter = ply
		})

		if trace.Hit then
			local normal = trace.HitNormal or vector_up
			local contactPos = trace.HitPos + normal * cvSoleOffset:GetFloat()
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

	-- compute ik positions and angles
	local function CalculateIK(ply, lFootPos, rFootPos, lFootAng, rFootAng)
		local groundDist = cvGroundDistance:GetFloat()
		local legLength = cvLegLength:GetFloat()
		local traceStartZ = ply:GetPos().z + cvTraceStartOffset:GetFloat()

		local lSamples = SampleFootGround(ply, lFootPos, lFootAng, traceStartZ, groundDist)
		local rSamples = SampleFootGround(ply, rFootPos, rFootAng, traceStartZ, groundDist)

		local lDist = lSamples.center.distance
		local rDist = rSamples.center.distance

		-- reduce jitter when standing still
		if cvStabilizeIdle:GetBool() then
			local velocity2D = ply:GetVelocity():Length2D()
			local isIdle = velocity2D < cvIdleVelocityThreshold:GetFloat()
			
			if isIdle and ply.IKLastDist then
				local threshold = cvIdleDistanceThreshold:GetFloat()
				local lChange = math.abs(lDist - ply.IKLastDist.l)
				local rChange = math.abs(rDist - ply.IKLastDist.r)
				
				-- maintain previous values within threshold
				if lChange < threshold then
					lDist = ply.IKLastDist.l
				end
				if rChange < threshold then
					rDist = ply.IKLastDist.r
				end
			end
			
			-- cache for next iteration
			ply.IKLastDist = {l = lDist, r = rDist}
		end

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
			bodyDrop = 0,
			lSamples = lSamples,
			rSamples = rSamples,
		}

		if ply:OnGround() then
			-- adjust body position based on terrain
			local avgDist = (lDist + rDist) * 0.5
			local heightDiff = math.abs(lDist - rDist)
			
			-- dynamic body drop calculation
			local unevenFactor = math.Clamp(heightDiff / 8, 0, 1)
			local extraDrop = Lerp(unevenFactor, cvExtraBodyDrop:GetFloat(), cvExtraBodyDropUneven:GetFloat())
			
			local bodyDrop = math.max(avgDist - cvTraceStartOffset:GetFloat(), 0)
			bodyDrop = bodyDrop + (heightDiff * cvUnevenDropScale:GetFloat()) + extraDrop
			bodyDrop = math.Clamp(bodyDrop, 0, groundDist)

			result.bodyDrop = bodyDrop
			result.basePos = Vector(0, 0, -bodyDrop)

			-- calculate knee bend angles
			local kneeRange = math.max(legLength * 0.33, 10)
			local bendBoost = cvHighFootBendBoost:GetFloat()
			local lDelta = avgDist - lDist
			local rDelta = avgDist - rDist

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

			-- calculate foot rotation from ground geometry
			local rotScale = cvFootRotationScale:GetFloat()
			
			if rotScale > 0.01 then
				local lToeHeelLen = math.max(lSamples.toe.hitPos:Distance(lSamples.heel.hitPos), 0.01)
				local rToeHeelLen = math.max(rSamples.toe.hitPos:Distance(rSamples.heel.hitPos), 0.01)
				local lLeftRightLen = math.max(lSamples.right.hitPos:Distance(lSamples.left.hitPos), 0.01)
				local rLeftRightLen = math.max(rSamples.right.hitPos:Distance(rSamples.left.hitPos), 0.01)

				local lPitch = -math.deg(math.atan2(lSamples.toe.hitPos.z - lSamples.heel.hitPos.z, lToeHeelLen))
				local rPitch = -math.deg(math.atan2(rSamples.toe.hitPos.z - rSamples.heel.hitPos.z, rToeHeelLen))
				local lRoll = math.deg(math.atan2(lSamples.right.hitPos.z - lSamples.left.hitPos.z, lLeftRightLen))
				local rRoll = math.deg(math.atan2(rSamples.right.hitPos.z - rSamples.left.hitPos.z, rLeftRightLen))

				-- apply rotation dampening
				lPitch = lPitch * rotScale
				rPitch = rPitch * rotScale
				lRoll = lRoll * rotScale
				rRoll = rRoll * rotScale

				-- limit rotation angles
				lPitch = math.Clamp(lPitch, -25, 25)
				rPitch = math.Clamp(rPitch, -25, 25)
				lRoll = math.Clamp(lRoll, -20, 20)
				rRoll = math.Clamp(rRoll, -20, 20)

				result.lFoot = Angle(0, lPitch, lRoll)
				result.rFoot = Angle(0, rPitch, rRoll)
			else
				-- keep feet flat
				result.lFoot = Angle(0, 0, 0)
				result.rFoot = Angle(0, 0, 0)
			end

			-- apply body lean
			if cvIkFootLean:GetBool() then
				local plyVel = ply:GetVelocity()
				local plyAng = ply:GetAimVector():Angle()
				local leanY = math.Clamp(plyVel:Dot(plyAng:Right()) / 20, -4, 4)
				result.baseAng = Angle(0, leanY, 0)
			end
		end

		return result
	end

	-- render debug information
	local function DrawDebug(ply, ikResult, maxDrop)
		local debugLevel = cvDebug:GetInt()
		if debugLevel <= 0 or not CanManipulateBones(ply) then return end

		local mins = Vector(-3, -3, 0)
		local maxs = Vector(3, 3, 5)

		local lCenter = ikResult.lSamples and ikResult.lSamples.center
		local rCenter = ikResult.rSamples and ikResult.rSamples.center
		if not lCenter or not rCenter then return end

		render.DrawWireframeBox(lCenter.hitPos, Angle(), mins, maxs, COLOR_RED, true)
		render.DrawLine(lCenter.startPos, lCenter.hitPos, COLOR_RED)
		render.DrawLine(lCenter.hitPos, lCenter.hitPos + lCenter.normal * 6, COLOR_GREEN)

		render.DrawWireframeBox(rCenter.hitPos, Angle(), mins, maxs, COLOR_RED, true)
		render.DrawLine(rCenter.startPos, rCenter.hitPos, COLOR_RED)
		render.DrawLine(rCenter.hitPos, rCenter.hitPos + rCenter.normal * 6, COLOR_GREEN)

		-- render additional debug info
		if debugLevel > 1 then
			local bottom, top = ply:GetHull()
			if ply:Crouching() then
				bottom, top = ply:GetHullDuck()
			end
			render.DrawWireframeBox(ply:GetPos(), Angle(), bottom, top, COLOR_WHITE, true)

			-- display debug values
			local textPos = ply:GetPos() + Vector(0, 0, 86)
			debugoverlay.Text(
				textPos,
				string.format("L_DIST: %.1f  R_DIST: %.1f  DROP: %.1f", ikResult.lDist, ikResult.rDist, maxDrop),
				FrameTime() * 2,
				false
			)
		end
	end

	-- main update hook
	hook.Add("PostPlayerDraw", "IKFoot_PostPlayerDraw", function(ply)
		if not IsValid(ply) then return end
		if not cvIkFoot:GetBool() then return end
		if not CanManipulateBones(ply) then return end

		local bones = GetIKBones(ply)
		if not (bones.lFoot and bones.rFoot and bones.lCalf and bones.rCalf and bones.lThigh and bones.rThigh) then
			return
		end

		-- retrieve current bone transforms
		local lFootPos, lFootAng = ply:GetBonePosition(bones.lFoot)
		local rFootPos, rFootAng = ply:GetBonePosition(bones.rFoot)

		if not (lFootPos and rFootPos and lFootAng and rFootAng) then return end

		-- compute ik result
		local ikResult = CalculateIK(ply, lFootPos, rFootPos, lFootAng, rFootAng)

		-- initialize state tracking
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

		-- smooth transitions
		local smoothingFactor = cvSmoothing:GetFloat()
		
		-- enhance smoothing when idle
		if cvStabilizeIdle:GetBool() then
			local velocity2D = ply:GetVelocity():Length2D()
			if velocity2D < cvIdleVelocityThreshold:GetFloat() then
				smoothingFactor = smoothingFactor * 0.2
			end
		end
		
		local lerpTime = math.Clamp(FrameTime() * smoothingFactor, 0, 1)

		ply.IKResult.basePos = LerpVector(lerpTime, ply.IKResult.basePos, ikResult.basePos)
		ply.IKResult.baseAng = LerpAngle(lerpTime, ply.IKResult.baseAng, ikResult.baseAng)
		ply.IKResult.lCalf = LerpAngle(lerpTime, ply.IKResult.lCalf, ikResult.lCalf)
		ply.IKResult.rCalf = LerpAngle(lerpTime, ply.IKResult.rCalf, ikResult.rCalf)
		ply.IKResult.lThigh = LerpAngle(lerpTime, ply.IKResult.lThigh, ikResult.lThigh)
		ply.IKResult.rThigh = LerpAngle(lerpTime, ply.IKResult.rThigh, ikResult.rThigh)
		ply.IKResult.lFoot = LerpAngle(lerpTime, ply.IKResult.lFoot, ikResult.lFoot)
		ply.IKResult.rFoot = LerpAngle(lerpTime, ply.IKResult.rFoot, ikResult.rFoot)

		-- apply transformations
		SetBonePosition(ply, 0, ply.IKResult.basePos)
		SetBoneAngles(ply, 0, ply.IKResult.baseAng)

		SetBoneAngles(ply, bones.lCalf, ply.IKResult.lCalf)
		SetBoneAngles(ply, bones.rCalf, ply.IKResult.rCalf)
		SetBoneAngles(ply, bones.lThigh, ply.IKResult.lThigh)
		SetBoneAngles(ply, bones.rThigh, ply.IKResult.rThigh)
		SetBoneAngles(ply, bones.lFoot, ply.IKResult.lFoot)
		SetBoneAngles(ply, bones.rFoot, ply.IKResult.rFoot)

		-- render debug overlays
		if cvDebug:GetInt() > 0 then
			DrawDebug(ply, ikResult, ikResult.bodyDrop or 0)
		end
	end)

	-- cleanup hook
	hook.Add("PostPlayerDraw", "IKFoot_ResetBones", function(ply)
		if not IsValid(ply) then return end
		if cvIkFoot:GetBool() or not CanManipulateBones(ply) then return end

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