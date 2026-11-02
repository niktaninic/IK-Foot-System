if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

local RT = IKFoot.Runtime
local RESET_COOLDOWN = 0.5

local function Deactivate(ply, bones)
	-- only reset on the active -> inactive transition instead of every frame
	if ply.IKActive then
		RT.Apply.ResetPlayer(ply, bones)
		ply.IKActive = nil
	end
end

local function HandleFailure(ply, bones, threshold)
	ply.IKFailCount = (ply.IKFailCount or 0) + 1
	if ply.IKFailCount == threshold then
		RT.State.SoftRecover(ply)
	elseif ply.IKFailCount >= threshold * 2 then
		if (ply.IKLastResetTime or 0) + RESET_COOLDOWN <= CurTime() then
			if ply.IKFailCount >= threshold * 3 then
				RT.Apply.HardResetPlayer(ply)
				ply.IKFailCount = 0
			else
				RT.Apply.ResetPlayer(ply, bones)
			end
			ply.IKLastResetTime = CurTime()
		end
	end
end

-- read the pose, solve, apply. a plain function for pcall: an inline closure
-- was a new garbage object per player per frame
local function RunIK(ply, bones, params)
	local skeleton = RT.Apply.BuildSkeleton(ply, bones)
	if not skeleton then return nil end
	local result = RT.Controller.Calculate(ply, skeleton, bones, params)
	if not result then return nil end
	RT.Apply.ApplyResult(ply, bones, result)
	return result
end

local function ProcessPlayer(ply)
	-- respawned: remove our offsets through the blend layer and start the ik
	-- state fresh. the old hard reset zeroed every leg bone outright (other
	-- addons' manipulations too) and forgot the model, which re-ran the auto
	-- configuration and its chat message on every respawn
	local alive = ply:Alive()
	if ply.IKWasAlive == false and alive then
		RT.Apply.ResetPlayer(ply)
		ply.IKWasAlive = alive
		return
	end
	ply.IKWasAlive = alive
	if not alive then
		Deactivate(ply)
		return
	end

	-- other players: skipped entirely (not even their bone set is built) when
	-- this client turned that off or they are too far away to see the feet
	if ply ~= LocalPlayer() then
		local cv = RT.ClientCVars
		local maxDist = cv.max_distance:GetFloat()
		if not cv.others:GetBool() or ply:GetPos():DistToSqr(EyePos()) > maxDist * maxDist then
			Deactivate(ply)
			return
		end
	end

	local bones = RT.GetIKBones(ply)
	local params = RT.GetParams(ply)

	if not params.enabled or not bones.valid or not RT.CanManipulateBones(ply) then
		Deactivate(ply, bones)
		return
	end

	-- detect model swap and announce the auto configuration
	if ply == LocalPlayer() then
		local currentModel = ply:GetModel()
		if ply.IKLastKnownModel ~= currentModel then
			local hadModel = ply.IKLastKnownModel ~= nil
			ply.IKLastKnownModel = currentModel
			if params.auto_model_detect then
				timer.Simple(hadModel and 0.15 or 1, function()
					if IsValid(ply) and ply:GetModel() == currentModel then
						IKFoot.AutoApplyModelSettings(ply)
					end
				end)
			end
		end
	end

	-- read the clean animated pose: remove our offsets and rebuild the bones
	RT.Apply.StripIKFromBones(ply, bones)
	if ply.InvalidateBoneCache then ply:InvalidateBoneCache() end
	ply:SetupBones()

	local ok, errOrResult = pcall(RunIK, ply, bones, params)

	-- the bones were set up without our manipulations; force the draw that
	-- follows this hook to set them up again so the ik shows up THIS frame
	if ply.InvalidateBoneCache then ply:InvalidateBoneCache() end

	if not ok then
		if (ply.IKLastErrorPrint or 0) + 5 < RealTime() and RT.CVars.debug and RT.CVars.debug:GetInt() > 0 then
			ply.IKLastErrorPrint = RealTime()
			ErrorNoHalt("[IK Foot] " .. tostring(errOrResult) .. "\n")
		end
		if RT.Diag then RT.Diag.Event(ply, "process_error", nil, { error = tostring(errOrResult), fails = (ply.IKFailCount or 0) + 1 }) end
		HandleFailure(ply, bones, 5)
		return
	end

	if not errOrResult then
		-- skeleton came back empty. probably still loading
		if RT.Diag then RT.Diag.Event(ply, "no_skeleton", nil, { fails = (ply.IKFailCount or 0) + 1 }) end
		HandleFailure(ply, bones, 6)
		return
	end

	ply.IKActive = true
	ply.IKFailCount = 0
	ply.IKResult = errOrResult
	ply.IKResultFrame = FrameNumber()
	if RT.Diag then RT.Diag.OnResult(ply, errOrResult) end
end

-- PrePlayerDraw instead of PostPlayerDraw: the old hook computed the ik after
-- the model was drawn, so every pose was shown one frame late (visible as
-- feet trailing the ground at speed). runs once per frame even when the
-- player is drawn several times (mirrors, water reflections)
hook.Add("PrePlayerDraw", "IKFoot_PrePlayerDraw", function(ply)
	if not IsValid(ply) then return end
	local frame = FrameNumber()
	if ply.IKLastFrame == frame then return end
	ply.IKLastFrame = frame
	ProcessPlayer(ply)
end)

-- after the draw the bone cache holds what the engine actually rendered:
-- diagnostics compare it with what the solver asked for
hook.Add("PostPlayerDraw", "IKFoot_DiagReadback", function(ply)
	if RT.Diag and IsValid(ply) then RT.Diag.Readback(ply) end
end)

hook.Add("PostDrawTranslucentRenderables", "IKFoot_Debug3D", function(depth, skybox)
	if depth or skybox then return end
	local debugCvar = RT.CVars and RT.CVars.debug
	if not debugCvar or debugCvar:GetInt() <= 0 then return end
	local frame = FrameNumber()
	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) and ply.IKResult and (ply.IKResultFrame or 0) >= frame - 1 then
			RT.Controller.DrawDebug(ply, ply.IKResult)
		end
	end
end)

hook.Add("HUDPaint", "IKFoot_Debug2D", function()
	local debugCvar = RT.CVars and RT.CVars.debug
	if not debugCvar or debugCvar:GetInt() <= 0 then return end

	local debug2D = RT.Debug2D
	if not debug2D or not debug2D.lines then return end
	if (debug2D.expireAt or 0) < CurTime() then return end

	local x, y = 24, 92
	local lineH = 18
	local width = 0
	surface.SetFont("DermaDefaultBold")

	for _, line in ipairs(debug2D.lines) do
		local tw = surface.GetTextSize(line)
		width = math.max(width, tw)
	end

	local height = (#debug2D.lines * lineH) + 16
	draw.RoundedBox(6, x - 10, y - 8, width + 20, height, Color(15, 18, 24, 210))

	for idx, line in ipairs(debug2D.lines) do
		draw.SimpleText(line, "DermaDefaultBold", x, y + (idx - 1) * lineH, Color(220, 230, 245), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	end

	for _, label in ipairs(debug2D.labels or {}) do
		local scr = label.pos:ToScreen()
		if scr.visible then
			draw.SimpleTextOutlined(label.text, "DermaDefaultBold", scr.x + 12, scr.y, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, Color(0, 0, 0, 200))
		end
	end
end)
