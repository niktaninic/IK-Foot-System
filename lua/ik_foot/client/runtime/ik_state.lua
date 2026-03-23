if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

local RT = IKFoot.Runtime
RT.State = RT.State or {}
local State = RT.State

local IDLE_ACQUIRE_DELAY = 0.14
local CROUCH_TRANSITION_TIME = 0.3

local function IsFiniteNumber(v)
	return isnumber(v) and v == v and v > -math.huge and v < math.huge
end

local function IsFiniteVector(vec)
	return isvector(vec) and IsFiniteNumber(vec.x) and IsFiniteNumber(vec.y) and IsFiniteNumber(vec.z)
end

local function EnsureFootState(container, side)
	container.legs = container.legs or {}
	container.legs[side] = container.legs[side] or {
		planted = false,
		lockPos = nil,
		lastRawPos = nil,
		lastTargetPos = nil,
		footSpeed = 0,
		released = false,
	}
	return container.legs[side]
end

function State.Get(ply)
	ply.IKRuntimeState = ply.IKRuntimeState or {
		idle = { active = false, candidateTime = 0 },
		legs = {},
		crouch = { crouching = false, transitionTime = 0, inTransition = false },
	}
	EnsureFootState(ply.IKRuntimeState, "left")
	EnsureFootState(ply.IKRuntimeState, "right")
	if not ply.IKRuntimeState.crouch then
		ply.IKRuntimeState.crouch = { crouching = false, transitionTime = 0, inTransition = false }
	end
	return ply.IKRuntimeState
end

function State.Reset(ply)
	-- wipe everything. without this the character becomes a horror show
	ply.IKRuntimeState = nil
	ply.IKResult = nil
	ply.IKFootLastPos = nil
	ply.IKFootBoneLastPos = nil
	ply.IKLastBodyDrop = nil
	ply.IKMeasuredLegLength = nil
	ply.IKMeasuredModel = nil
	ply.IKApplyState = nil
	ply.IKBlendState = nil
	ply.IKFailCount = nil
end

function State.HardReset(ply)
	-- nuclear wipe. clears absolutely everything including bone cache
	State.Reset(ply)
	ply.IKBones = nil
	ply.IKLastKnownModel = nil
	if IsValid(ply) and RT.Controller and RT.Controller.ResetDynSole then
		RT.Controller.ResetDynSole(ply)
	end
end

function State.UpdateCrouch(runtimeState, isCrouching)
	local crouch = runtimeState.crouch
	if crouch.crouching ~= isCrouching then
		crouch.crouching = isCrouching
		crouch.transitionTime = 0
		crouch.inTransition = true
		-- unlock feet during crouch or they get stuck in weird places
		for _, side in ipairs({"left", "right"}) do
			local leg = runtimeState.legs[side]
			if leg then
				leg.planted = false
				leg.lockPos = nil
				leg.lastRawPos = nil
			end
		end
		runtimeState.idle.active = false
		runtimeState.idle.candidateTime = 0
	end
	if crouch.inTransition then
		crouch.transitionTime = crouch.transitionTime + FrameTime()
		if crouch.transitionTime >= CROUCH_TRANSITION_TIME then
			crouch.inTransition = false
		end
	end
	return crouch
end

function State.UpdateIdle(runtimeState, onGround, velocity2D, vertVel, idleVelocityThreshold, leftRawPos, rightRawPos)
	local idle = runtimeState.idle
	local isCandidate = onGround and velocity2D <= idleVelocityThreshold and math.abs(vertVel) <= (idleVelocityThreshold * 0.5)

	if isCandidate then
		idle.candidateTime = idle.candidateTime + FrameTime()
	else
		idle.candidateTime = 0
		idle.active = false
	end

	if isCandidate and idle.candidateTime >= IDLE_ACQUIRE_DELAY then
		idle.active = true
		idle.leftRaw = Vector(leftRawPos)
		idle.rightRaw = Vector(rightRawPos)
	end

	return idle, isCandidate
end

function State.MeasureFootSpeed(footState, rawFootPos, frameDt)
	if footState.lastRawPos and IsFiniteVector(rawFootPos) and IsFiniteVector(footState.lastRawPos) then
		local speed = rawFootPos:Distance(footState.lastRawPos) / math.max(frameDt, 1 / 300)
		footState.footSpeed = IsFiniteNumber(speed) and speed or 0
	else
		footState.footSpeed = 0
	end
	if IsFiniteVector(rawFootPos) then
		footState.lastRawPos = Vector(rawFootPos)
	end
	return footState.footSpeed
end

function State.UpdateFoot(footState, data)
	-- decides if foot should lock to ground or release
	-- the most fragile part of the whole system. dont touch
	footState.released = false

	if data.contact.hasHit and not IsFiniteVector(data.contact.position) then
		data.contact.hasHit = false
	end

	if not data.onGround then
		footState.planted = false
		footState.lockPos = nil
	end

	-- if lock drifted way too far from foot something went wrong. let go
	if footState.lockPos then
		local lockDist = data.rawFootPos:Distance(footState.lockPos)
		if lockDist > math.max(40, data.lockStrength * 25) then
			footState.planted = false
			footState.lockPos = nil
			footState.released = true
		end
	end

	local acquireDistance = math.max(4, 8 * data.lockStrength)
	local releaseDistance = math.max(acquireDistance * 1.3, 6 + data.lockStrength * 6)
	local releaseSpeed = math.max(data.releaseSpeed, 5)
	local shouldAcquire = data.contact.hasHit and data.onGround and (
		data.idleActive
		or (data.footSpeed <= releaseSpeed * 0.55 and data.rawFootPos:Distance(data.contact.position) <= acquireDistance)
		or (data.isSupportFoot and data.rawFootPos:Distance(data.contact.position) <= acquireDistance * 1.2)
	)

	if footState.lockPos then
		local distToLock = data.rawFootPos:Distance(footState.lockPos)
		local wantsStrideRelease = data.footSpeed > releaseSpeed and distToLock > releaseDistance * 0.5

		if not data.idleActive and (wantsStrideRelease or distToLock > releaseDistance) then
			footState.planted = false
			footState.lockPos = nil
			footState.released = true
		end
	end

	if not footState.lockPos and shouldAcquire then
		footState.lockPos = Vector(data.contact.position)
		footState.planted = true
	elseif footState.lockPos then
		footState.planted = true
	end

	if data.idleActive and data.contact.hasHit then
		if not footState.lockPos then
			footState.lockPos = Vector(data.contact.position)
		end
		footState.planted = true
	end

	local desiredPos
	if footState.lockPos then
		desiredPos = Vector(footState.lockPos)
	elseif data.contact.hasHit then
		desiredPos = Vector(data.contact.position)
	else
		desiredPos = Vector(data.rawFootPos)
	end

	if not IsFiniteVector(desiredPos) then
		desiredPos = IsFiniteVector(data.rawFootPos) and Vector(data.rawFootPos) or Vector(0, 0, 0)
	end

	footState.lastTargetPos = Vector(desiredPos)

	return {
		planted = footState.planted and footState.lockPos ~= nil,
		lockPos = footState.lockPos and Vector(footState.lockPos) or nil,
		targetPos = desiredPos,
		footSpeed = footState.footSpeed,
		released = footState.released,
	}
end