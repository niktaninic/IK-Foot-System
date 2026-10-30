if SERVER then return end
if not IKFoot or not IKFoot.Runtime then return end

-- =====================================================================
-- diagnostics
-- =====================================================================
-- everything here observes, nothing changes the ik state, so running any of
-- the commands keeps the problem being investigated intact.
--
-- stages in the recorded data:
--   anim   : bone transforms read after removing our manipulations (clean pose)
--   solver : what the solver computed and asked the engine to show
--   engine : bone transforms read back AFTER the model was drawn with our
--            manipulations (PostPlayerDraw). solver vs engine differences mean
--            something between our manipulation and the final bones did not
--            behave as assumed (another addon, pac, manipulation space)
--
-- commands:
--   ik_foot_diag                 short report + likely causes
--   ik_foot_dump                 full state to data/ik_foot/dump_*.json
--   ik_foot_capture [seconds]    record samples (30 Hz) to data/ik_foot/capture_*.json
--   ik_foot_capture_stop         stop and save the running capture
--   ik_foot_debug 0/1/2          overlay off / basic / detailed

local RT = IKFoot.Runtime
RT.Diag = RT.Diag or {}
local Diag = RT.Diag

local HISTORY_RATE = 15          -- Hz, always-on cheap history for the local player
local HISTORY_SIZE = 150         -- ~10 s
local EVENT_SIZE = 300
local PRINT_INTERVAL = 2         -- s, per event kind+side+bone
local CAPTURE_RATE = 30          -- Hz
local CAPTURE_MAX_SECONDS = 60
local CAPTURE_MAX_SAMPLES = CAPTURE_RATE * CAPTURE_MAX_SECONDS
local ERR_ENGINE = 1.5           -- units: solver vs engine mismatch worth an event
local ERR_FOLLOWER = 1.5

local cvHistory = CreateClientConVar("ik_foot_diag_history", "1", true, false, "Keep ~10 s of IK samples for ik_foot_dump (cheap, local player only)")
local cvPrint = CreateClientConVar("ik_foot_diag_print", "1", true, false, "Print rate-limited IK events to the console while ik_foot_debug > 0 or a capture runs")

Diag.events = Diag.events or {}
Diag.history = Diag.history or {}
Diag.stats = Diag.stats or {}
Diag.lastPrint = Diag.lastPrint or {}
Diag.suppressed = Diag.suppressed or {}

local function Level()
	local cv = RT.CVars and RT.CVars.debug
	return cv and cv:GetInt() or 0
end
Diag.Level = Level

local function IsTarget(ply)
	return IsValid(ply) and ply == LocalPlayer()
end
Diag.IsTarget = IsTarget

-- ---------------------------------------------------------------------
-- json friendly conversion
-- ---------------------------------------------------------------------

local function R(x, d)
	if not isnumber(x) then return x end
	if x ~= x then return "nan" end
	if x == math.huge then return "inf" end
	if x == -math.huge then return "-inf" end
	local m = 10 ^ (d or 2)
	return math.floor(x * m + 0.5) / m
end

local function V(v, d)
	if not isvector(v) then return nil end
	return { R(v.x, d), R(v.y, d), R(v.z, d) }
end

local function A(a, d)
	if not isangle(a) then return nil end
	return { R(a.p, d), R(a.y, d), R(a.r, d) }
end

-- converts arbitrary values (vectors, angles, entities, nested tables) into
-- plain json data. bounded depth so a stray reference can't explode a dump
local function Plain(value, depth)
	depth = depth or 0
	local t = type(value)
	if t == "number" then return R(value, 3) end
	if t == "string" or t == "boolean" then return value end
	if isvector(value) then return V(value, 3) end
	if isangle(value) then return A(value, 3) end
	if t == "table" and depth < 6 then
		local out = {}
		for k, v in pairs(value) do
			if type(v) ~= "function" then
				out[isnumber(k) and k or tostring(k)] = Plain(v, depth + 1)
			end
		end
		return out
	end
	if IsEntity and IsEntity(value) then return IsValid(value) and tostring(value) or "NULL" end
	return tostring(value)
end
Diag.Plain = Plain

local function Finite(x)
	return isnumber(x) and x == x and x > -math.huge and x < math.huge
end

local function FiniteVec(v)
	return isvector(v) and Finite(v.x) and Finite(v.y) and Finite(v.z)
end

-- ---------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------

local function PushRing(list, item, size)
	list[#list + 1] = item
	if #list > size then table.remove(list, 1) end
end

local function ValuesText(values)
	if not values then return "" end
	local parts = {}
	for k, v in SortedPairs(values) do
		local s
		if isvector(v) then
			s = string.format("(%.1f %.1f %.1f)", v.x, v.y, v.z)
		elseif isnumber(v) then
			s = string.format("%.2f", v)
		else
			s = tostring(v)
		end
		parts[#parts + 1] = k .. "=" .. s
	end
	return table.concat(parts, " ")
end

Diag.openEvents = Diag.openEvents or {}

function Diag.Event(ply, kind, side, values, key)
	if not IsTarget(ply) then return end
	local now = RealTime()
	key = kind .. ":" .. tostring(side or "-") .. ":" .. tostring(key or "")
	Diag.stats["event_" .. kind] = (Diag.stats["event_" .. kind] or 0) + 1

	-- a condition that holds for many frames is one event with a count and
	-- first/last time, not hundreds of entries pushing everything else out
	local open = Diag.openEvents[key]
	if open and now - open.t_last <= 1 then
		open.count = open.count + 1
		open.t_last = R(now, 3)
		open.frame_last = FrameNumber()
		open.values = Plain(values)
	else
		local e = {
			t = R(now, 3), t_last = R(now, 3), curtime = R(CurTime(), 3), frame = FrameNumber(), frame_last = FrameNumber(),
			kind = kind, side = side, count = 1, values = Plain(values),
		}
		Diag.openEvents[key] = e
		PushRing(Diag.events, e, EVENT_SIZE)
		if Diag.capture then
			local ev = Diag.capture.events
			if #ev < 2000 then ev[#ev + 1] = e end
		end
	end

	if cvPrint:GetBool() and (Level() > 0 or Diag.capture) then
		if now - (Diag.lastPrint[key] or -math.huge) >= PRINT_INTERVAL then
			local extra = Diag.suppressed[key] and Diag.suppressed[key] > 0 and string.format(" (+%d similar)", Diag.suppressed[key]) or ""
			MsgC(Color(255, 180, 80), "[IK Foot] ", Color(220, 220, 220),
				string.format("%.2f %s%s %s%s\n", now, kind, side and (" " .. side) or "", ValuesText(values), extra))
			Diag.lastPrint[key] = now
			Diag.suppressed[key] = 0
		else
			Diag.suppressed[key] = (Diag.suppressed[key] or 0) + 1
		end
	end
end

-- called by the bone layer when a value we wrote was changed by someone else
function Diag.ForeignWrite(ply, bone, what)
	if not IsTarget(ply) then return end
	local name = ply:GetBoneName(bone) or tostring(bone)
	Diag.stats.foreignWrites = (Diag.stats.foreignWrites or 0) + 1
	Diag.stats.foreignBones = Diag.stats.foreignBones or {}
	Diag.stats.foreignBones[name] = (Diag.stats.foreignBones[name] or 0) + 1
	Diag.Event(ply, "foreign_write", nil, { bone = name, channel = what }, name .. what)
end

-- ---------------------------------------------------------------------
-- samples
-- ---------------------------------------------------------------------

local function ContactSample(c)
	if not c then return nil end
	return {
		hit = c.hasHit, hits = c.hitCount, pos = V(c.position), highestZ = R(c.highestZ),
		drop_off = R(c.dropOff), -- ground found, but down a ledge / gap: not used
		normal = V(c.normal, 3), surface = c.surfaceType, stable = c.surfaceStable,
	}
end

local function LegSample(leg, readback, detail)
	if not leg then return nil end
	local reach = leg.reach
	local out = {
		anim_foot = V(leg.animFoot),
		target = V(leg.targetPos),                 -- requested by contacts / stepper
		target_anim = V(leg.targetAnim),           -- what the animation + ground alone asks for
		target_step = V(leg.targetProc),           -- what the stair stepper asks for
		blend = { step = R(leg.stepBlend), align = R(leg.alignW) }, -- stepper share of target, foot-to-ground tilt weight
		ground_normal = V(leg.groundNormal, 3),    -- smoothed normal the foot is tilted to
		solver_ankle = V(leg.ankle),               -- after reach limits
		solver_knee = V(leg.knee),
		hip = V(leg.hip),
		target_miss = leg.ankle and leg.targetPos and R(leg.ankle:Distance(leg.targetPos)) or nil,
		reached = leg.reached,
		reach = reach and {
			upper = R(reach.upper), lower = R(reach.lower), requested = R(reach.requested),
			min = R(reach.minReach), max = R(reach.maxReach), limit = reach.limit,
		} or nil,
		req = R(leg.requiredDrop),
		support = R(leg.support), plant_w = R(leg.plantW),
		drop_limits = leg.dropLimits and { min = R(leg.dropLimits.min), max = R(leg.dropLimits.max) } or nil,
		contact = ContactSample(leg.contact),
		lock = leg.lockPos and { pos = V(leg.lockPos), age = R(leg.lockAge) } or nil,
		foot_speed = R(leg.footSpeed),
		step = { phase = leg.procPhase, t = R(leg.procT), reason = leg.stepReason, blocked = leg.stepBlocked },
	}
	if readback then
		out.engine_ankle = V(readback.ankle)
		out.engine_knee = V(readback.knee)
		out.engine_ankle_err = R(readback.ankleErr)
		out.engine_knee_err = R(readback.kneeErr)
	end
	if detail then
		out.anim_ang = A(leg.animAng)
		out.foot_world_ang = A(leg.footWorld)
		out.manip = { thigh = A(leg.thigh), calf = A(leg.calf), foot = A(leg.foot) }
		if leg.contact and leg.contact.samples then
			local samples = {}
			for name, s in pairs(leg.contact.samples) do
				if istable(s) and s.hitPos then
					samples[name] = { hit = s.hit, pos = V(s.hitPos), normal = V(s.normal, 3), surface = s.surfaceType }
				end
			end
			out.contact_samples = samples
		end
	end
	return out
end

function Diag.BuildSample(ply, detail)
	local res = ply.IKResult
	if not res then return nil end
	local d = res.debug or {}
	-- the latest engine read back may be a few frames older than the result
	-- (it runs at the history rate); its errors were computed against the
	-- result of its own frame, so they stay valid and are reported with age
	local rb = ply.IKDiagReadback
	local seq = ply:GetSequence()
	local sample = {
		t = R(RealTime(), 3), curtime = R(CurTime(), 3), frame = FrameNumber(),
		result_frame = ply.IKResultFrame, readback_frame = rb and rb.frame or nil,
		readback_age_frames = rb and ply.IKResultFrame and (ply.IKResultFrame - rb.frame) or nil,
		model = ply:GetModel(), model_scale = R(ply:GetModelScale(), 3),
		seq = seq, seq_name = ply:GetSequenceName(seq), cycle = R(ply:GetCycle(), 3), playback = R(ply:GetPlaybackRate(), 2),
		pos = V(ply:GetPos()), vel = V(ply:GetVelocity()), speed2d = R(d.velocity2D),
		on_ground = d.onGround, crouching = d.crouching, movetype = ply:GetMoveType(), dt = R(d.dt, 4),
		drop = {
			applied = R(res.bodyDrop), desired = R(d.desiredDrop), reach = R(d.reachDrop),
			limiter = d.dropLimiter, land_dip = R(d.landDip), origin_jump = R(d.originJump),
		},
		rest = d.restInfo and {
			value = R(d.restInfo.value), expected = R(d.restInfo.expected), sample = R(d.restInfo.sample),
			side = d.restInfo.sampleSide, used = d.restInfo.used, reason = d.restInfo.reason,
		} or nil,
		idle = d.idleActive,
		stairs = {
			active = d.stairMode, blend = R(d.stairBlend), depth = R(d.stairDepth), rise = R(d.stairRise),
			ascending = d.stairAscending, treads_per_step = d.treadsPerStep,
		},
		legs = {
			left = LegSample(res.left, rb and rb.legs.left, detail),
			right = LegSample(res.right, rb and rb.legs.right, detail),
		},
	}
	local bones = ply.IKBones
	if bones and bones.followers and #bones.followers > 0 then
		local list = {}
		for i, f in ipairs(bones.followers) do
			local out = res.followers and res.followers[i]
			local frb = rb and rb.followers and rb.followers[i]
			list[#list + 1] = {
				i = i, name = f.name, side = f.side, kind = f.kind,
				expected = out and V(out.expectedPos) or nil,
				engine = frb and V(frb.pos) or nil,
				engine_err = frb and R(frb.err) or nil,
				engine_ang_err = frb and R(frb.angErr) or nil,
				manip_pos = detail and out and V(out.pos) or nil,
				manip_ang = detail and out and A(out.ang) or nil,
			}
		end
		sample.followers = list
	end
	return sample
end

-- ---------------------------------------------------------------------
-- per frame hooks (called from cl_ik_foot_hooks.lua)
-- ---------------------------------------------------------------------

local function CheckNaN(ply, res)
	local bad = nil
	if not Finite(res.bodyDrop) then bad = "bodyDrop" end
	for _, side in ipairs({ "left", "right" }) do
		local leg = res[side]
		if leg then
			for _, key in ipairs({ "targetPos", "ankle", "knee" }) do
				if leg[key] ~= nil and not FiniteVec(leg[key]) then bad = side .. "." .. key end
			end
		end
	end
	if bad then Diag.Event(ply, "nan", nil, { field = bad }, bad) end
end

function Diag.OnResult(ply, res)
	if not IsTarget(ply) then return end
	local now = RealTime()
	CheckNaN(ply, res)

	local d = res.debug or {}
	local ri = d.restInfo
	if ri then
		local st = Diag.stats
		st.restSamples = st.restSamples or {}
		st.restSamples[ri.reason or "?"] = (st.restSamples[ri.reason or "?"] or 0) + 1
	end

	for _, side in ipairs({ "left", "right" }) do
		local leg = res[side]
		if leg then
			-- a supporting foot the solver could not put where it was asked
			if leg.ankle and leg.targetPos and (leg.support or 0) >= 0.5 then
				local miss = leg.ankle:Distance(leg.targetPos)
				if miss > ERR_ENGINE then
					Diag.Event(ply, "solver_miss", side, {
						miss = miss, limit = leg.reach and leg.reach.limit or "?",
						requested = leg.reach and leg.reach.requested, max = leg.reach and leg.reach.maxReach,
						drop = res.bodyDrop, limiter = d.dropLimiter,
					})
				end
			end
			-- the same foot starting steps over and over while standing
			local starts = leg.stepStarts
			if starts and #starts >= 3 and (d.velocity2D or 0) < 10 then
				local recent = 0
				for _, t in ipairs(starts) do
					if now - t < 2 then recent = recent + 1 end
				end
				if recent >= 3 then
					Diag.Event(ply, "restep_loop", side, { steps_2s = recent, reason = leg.stepReason, blocked = leg.stepBlocked })
				end
			end
		end
	end

	Diag.needReadback = false
	if cvHistory:GetBool() and now - (Diag.lastHistory or -math.huge) >= 1 / HISTORY_RATE then
		Diag.lastHistory = now
		Diag.needReadback = true
		Diag.pendingHistory = true
	end
	local cap = Diag.capture
	if cap then
		if now >= cap.stopAt or #cap.samples >= CAPTURE_MAX_SAMPLES then
			Diag.StopCapture("time")
		elseif now - (cap.last or -math.huge) >= 1 / CAPTURE_RATE then
			cap.last = now
			Diag.needReadback = true
			Diag.pendingCapture = true
		end
	end
	if Level() > 0 then Diag.needReadback = true end
end

local function AngleError(a, b)
	local fa, fb, ua, ub = a:Forward(), b:Forward(), a:Up(), b:Up()
	return math.deg(math.acos(math.Clamp(fa:Dot(fb), -1, 1))) + math.deg(math.acos(math.Clamp(ua:Dot(ub), -1, 1)))
end

-- PostPlayerDraw: bones now hold the transforms the engine actually drew
function Diag.Readback(ply)
	if not IsTarget(ply) or not Diag.needReadback then return end
	local frame = FrameNumber()
	if ply.IKResultFrame ~= frame then return end
	if Diag.readbackFrame == frame then return end
	Diag.readbackFrame = frame

	local res, bones = ply.IKResult, ply.IKBones
	if not res or not bones or not bones.valid then return end
	local get = RT.Apply.GetBoneWorldTransform
	local plyPos = ply:GetPos()
	local maxDist = 260 * math.max(ply:GetModelScale() or 1, 1)
	local rb = { frame = frame, legs = {}, followers = {} }

	for side, ids in pairs({ left = { bones.lCalf, bones.lFoot }, right = { bones.rCalf, bones.rFoot } }) do
		local leg = res[side]
		local knee = get(ply, ids[1], plyPos, maxDist)
		local ankle = get(ply, ids[2], plyPos, maxDist)
		local entry = { knee = knee, ankle = ankle }
		if ankle and leg.ankle then entry.ankleErr = ankle:Distance(leg.ankle) end
		if knee and leg.knee then entry.kneeErr = knee:Distance(leg.knee) end
		rb.legs[side] = entry
		if entry.ankleErr and entry.ankleErr > ERR_ENGINE then
			Diag.Event(ply, "engine_mismatch", side, { bone = "foot", err = entry.ankleErr, solver = leg.ankle, engine = ankle })
		end
	end

	for i, f in ipairs(bones.followers or {}) do
		local out = res.followers and res.followers[i]
		local pos, ang = get(ply, f.bone, plyPos, maxDist)
		if out and pos then
			local entry = { pos = pos, err = pos:Distance(out.expectedPos) }
			if ang and out.expectedAng then entry.angErr = AngleError(ang, out.expectedAng) end
			rb.followers[i] = entry
			if entry.err > ERR_FOLLOWER then
				Diag.Event(ply, "follower_error", f.side, { follower = f.name, kind = f.kind, err = entry.err, ang_err = entry.angErr }, f.name)
			end
		end
	end
	ply.IKDiagReadback = rb

	if Diag.pendingHistory then
		Diag.pendingHistory = false
		local s = Diag.BuildSample(ply, false)
		if s then PushRing(Diag.history, s, HISTORY_SIZE) end
	end
	if Diag.pendingCapture and Diag.capture then
		Diag.pendingCapture = false
		local s = Diag.BuildSample(ply, Level() >= 2 or Diag.capture.detail)
		if s then Diag.capture.samples[#Diag.capture.samples + 1] = s end
	end
end

-- ---------------------------------------------------------------------
-- files
-- ---------------------------------------------------------------------

local function WriteJSON(prefix, data)
	file.CreateDir("ik_foot")
	local name = string.format("ik_foot/%s_%s.json", prefix, os.date("%Y%m%d_%H%M%S"))
	local json = util.TableToJSON(data, true)
	if not json then
		MsgC(Color(255, 90, 90), "[IK Foot] could not serialise diagnostics\n")
		return nil
	end
	file.Write(name, json)
	return name, #json
end

local function Header(ply)
	return {
		addon = "IK Foot System",
		version = IKFoot.VERSION or "?",
		build = IKFoot.BUILD or "?",
		date = os.date("%Y-%m-%d %H:%M:%S"),
		map = game.GetMap(),
		gamemode = engine.ActiveGamemode and engine.ActiveGamemode() or "?",
		pac = istable(pac) and isfunction(pac.IsEnabled) and pac.IsEnabled() or false,
		pac_has_parts = ply.pac_has_parts and true or false,
		fps = R(1 / math.max(RealFrameTime(), 1e-4), 1),
		stages = "anim = clean pose without ik, solver = computed, engine = read back after draw",
	}
end

local function ParamsTable(ply)
	local out = {}
	for _, entry in ipairs(IKFoot.Config.entries) do
		out[entry.cvar] = entry.type == "bool" and RT.GetIKParamBool(ply, entry.key) or R(RT.GetIKParam(ply, entry.key), 3)
	end
	return out
end

local function BonesTable(ply, bones)
	if not bones then return nil end
	local followers = {}
	for i, f in ipairs(bones.followers or {}) do
		followers[i] = { index = f.bone, name = f.name, parent = f.parentName, side = f.side, kind = f.kind, reason = f.reason }
	end
	local analysis = {}
	for i, a in ipairs(bones.followerAnalysis or {}) do
		analysis[i] = { index = a.bone, name = a.name, verdict = a.verdict, side = a.side, dist = R(a.dist), verts = a.verts, kind = a.kind }
	end
	local aux = {}
	for i, b in ipairs(bones.auxRoots or {}) do aux[i] = ply:GetBoneName(b) or tostring(b) end
	local prof = bones.profile or {}
	local mesh = prof.mesh or {}
	return {
		valid = bones.valid,
		bone_count = bones.boneCount,
		names = bones.names,
		aux_roots = aux,
		followers = followers,
		follower_radius = R(bones.followerRadius),
		foot_centre = { left = V(bones.footCentre and bones.footCentre.left), right = V(bones.footCentre and bones.footCentre.right) },
		foot_centre_source = bones.footCentreSource,
		candidates = analysis,
		mesh = {
			has_weights = mesh.hasWeights, foot_sole_z = R(mesh.footSoleZ), lowest_z = R(mesh.lowestZ),
			foot_length = R(mesh.footLength), foot_width = R(mesh.footWidth), foot_verts = mesh.footVerts,
		},
		bind_ankle = prof.bindAnkle and { left = R(prof.bindAnkle.left), right = R(prof.bindAnkle.right) } or nil,
	}
end

function Diag.Dump(ply)
	ply = ply or LocalPlayer()
	if not IsValid(ply) then return end
	local data = Header(ply)
	data.player = ply:Nick()
	data.params = ParamsTable(ply)
	data.bones = BonesTable(ply, ply.IKBones)
	data.active = ply.IKActive and true or false
	data.fail_count = ply.IKFailCount or 0
	data.current = Diag.BuildSample(ply, true)
	data.history = Diag.history
	data.events = Diag.events
	data.stats = Plain(Diag.stats)
	local name, size = WriteJSON("dump", data)
	if name then
		MsgC(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255),
			string.format("dump written: garrysmod/data/%s (%d KB, %d history samples, %d events)\n", name, math.ceil(size / 1024), #Diag.history, #Diag.events))
	end
	return name
end

function Diag.StartCapture(seconds, detail)
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	if Diag.capture then Diag.StopCapture("restart") end
	seconds = math.Clamp(tonumber(seconds) or 10, 1, CAPTURE_MAX_SECONDS)
	Diag.capture = {
		startedAt = RealTime(), stopAt = RealTime() + seconds, seconds = seconds,
		samples = {}, events = {}, detail = detail and true or false,
		header = Header(ply), params = ParamsTable(ply), bones = BonesTable(ply, ply.IKBones),
	}
	MsgC(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255),
		string.format("capturing %d s at %d Hz%s... (ik_foot_capture_stop to end early)\n", seconds, CAPTURE_RATE, detail and " with detail" or ""))
end

function Diag.StopCapture(why)
	local cap = Diag.capture
	if not cap then
		MsgC(Color(255, 180, 80), "[IK Foot] no capture running\n")
		return
	end
	Diag.capture = nil
	local data = cap.header
	data.capture_seconds = R(RealTime() - cap.startedAt, 2)
	data.stopped_by = why or "command"
	data.params = cap.params
	data.bones = cap.bones
	data.samples = cap.samples
	data.events = cap.events
	data.stats = Plain(Diag.stats)
	local name, size = WriteJSON("capture", data)
	if name then
		MsgC(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255),
			string.format("capture written: garrysmod/data/%s (%d samples, %d events, %d KB)\n", name, #cap.samples, #cap.events, math.ceil(size / 1024)))
	end
	return name
end

-- ---------------------------------------------------------------------
-- report
-- ---------------------------------------------------------------------

local function Line(col, text)
	MsgC(col, text .. "\n")
end

function Diag.Report(ply)
	ply = ply or LocalPlayer()
	if not IsValid(ply) then return end
	local white, grey, warn, good, head = Color(235, 235, 235), Color(160, 160, 160), Color(255, 170, 70), Color(120, 255, 120), Color(110, 190, 255)
	local res, bones = ply.IKResult, ply.IKBones
	local rb = ply.IKDiagReadback
	local suspects = {}
	local rbAge = rb and ply.IKResultFrame and (ply.IKResultFrame - rb.frame) or nil

	Line(head, string.format("==== IK Foot diag  v%s (%s)  %s ====", IKFoot.VERSION or "?", IKFoot.BUILD or "?", os.date("%H:%M:%S")))
	Line(white, string.format("model %s  scale %.2f  seq %s  cycle %.2f  active %s  pac %s",
		ply:GetModel(), ply:GetModelScale(), ply:GetSequenceName(ply:GetSequence()) or "?", ply:GetCycle(),
		tostring(ply.IKActive and true or false), tostring(ply.pac_has_parts and "parts" or (istable(pac) and "loaded" or "no"))))

	if not bones or not bones.valid then
		Line(warn, "bone set INVALID: legs not found or hierarchy rejected - ik is off for this model")
		return
	end
	if not res then
		Line(warn, "no ik result yet (player not drawn? third person needed: the ik runs in PrePlayerDraw)")
		return
	end

	local d = res.debug or {}
	local ri = d.restInfo or {}
	Line(white, string.format("leg %.1f  scale %.2f  drop %.2f (desired %.2f, limiter %s)  ground %s  speed %.0f",
		d.measuredLeg or 0, d.modelScale or 0, res.bodyDrop or 0, d.desiredDrop or 0, tostring(d.dropLimiter), tostring(d.onGround), d.velocity2D or 0))
	Line(white, string.format("REST H %.2f  expected %s  last sample %.2f (%s, %s)",
		ri.value or 0, ri.expected and string.format("%.2f", ri.expected) or "unknown", ri.sample or 0, tostring(ri.reason), ri.used and "used" or "not used"))
	if ri.expected and ri.value and (ri.value < ri.expected * 0.7 or ri.value > ri.expected * 1.4) then
		suspects[#suspects + 1] = string.format("REST H %.2f is far from the model's bind pose ankle height %.2f: planted foot reads are off (see rest samples / foreign writes)", ri.value, ri.expected)
	end
	if not ri.expected then
		suspects[#suspects + 1] = "model gave no bind pose ankle height, REST H is learned from the animation only"
	end

	for _, side in ipairs({ "left", "right" }) do
		local leg = res[side]
		local lrb = rb and rb.legs[side]
		local reach = leg.reach or {}
		Line(white, string.format("%-5s req %6.2f  support %.2f  step %s %.2f (%s%s)  reach %.1f/%.1f%s  contact %s  engine err %s",
			side, leg.requiredDrop or 0, leg.support or 0, leg.procPhase, leg.procT or 0, tostring(leg.stepReason),
			leg.stepBlocked and (", blocked: " .. leg.stepBlocked) or "",
			reach.requested or 0, reach.maxReach or 0, reach.limit and (" " .. reach.limit) or "",
			leg.contact and (leg.contact.hasHit and string.format("%d hits", leg.contact.hitCount) or "NO HIT") or "stepper",
			lrb and lrb.ankleErr and string.format("%.2f", lrb.ankleErr) or "n/a"))
		Line(grey, string.format("      blend: stepper %.2f  ground tilt %.2f   lock age %s",
			leg.stepBlend or 0, leg.alignW or 0, leg.lockAge and string.format("%.2fs", leg.lockAge) or "-"))
		if lrb and lrb.ankleErr and lrb.ankleErr > ERR_ENGINE then
			suspects[#suspects + 1] = string.format("%s foot is drawn %.1fu away from where the solver put it: something else writes leg bones after us (foreign writes: %d)", side, lrb.ankleErr, Diag.stats.foreignWrites or 0)
		end
		if (leg.support or 0) >= 0.5 and leg.ankle and leg.targetPos and leg.ankle:Distance(leg.targetPos) > ERR_ENGINE then
			suspects[#suspects + 1] = string.format("%s supporting foot misses its ground target by %.1fu (%s): body drop limited by %s", side, leg.ankle:Distance(leg.targetPos), tostring(reach.limit), tostring(d.dropLimiter))
		end
	end

	Line(grey, rbAge and string.format("engine read back %d frame(s) before this result", rbAge) or "engine read back: none yet (needs ik_foot_diag_history 1 or ik_foot_debug > 0)")
	Line(white, string.format("stairs %s blend %.2f depth %.1f rise %.1f treads/step %s",
		tostring(d.stairMode), d.stairBlend or 0, d.stairDepth or 0, d.stairRise or 0, tostring(d.treadsPerStep)))

	local fol = bones.followers or {}
	Line(white, string.format("foot followers: %d   foot centre L/R from %s / %s",
		#fol, tostring(bones.footCentreSource and bones.footCentreSource.left), tostring(bones.footCentreSource and bones.footCentreSource.right)))
	for i, f in ipairs(fol) do
		local frb = rb and rb.followers[i]
		Line(grey, string.format("  #%d %s (parent %s, %s, %s foot) engine err %s  - %s",
			f.bone, f.name, f.parentName, f.kind, f.side, frb and string.format("%.2f", frb.err) or "n/a", f.reason))
		if frb and frb.err > ERR_FOLLOWER then
			suspects[#suspects + 1] = string.format("follower %s is drawn %.1fu from its expected spot (kind %s): its manipulation is not applied as computed", f.name, frb.err, f.kind)
		end
	end
	local near = {}
	for _, a in ipairs(bones.followerAnalysis or {}) do
		if a.verdict ~= "follower" and a.verdict ~= "inherits_foot" and a.verdict ~= "chain_bone" and (a.dist or math.huge) < (bones.followerRadius or 7) * 2 then
			near[#near + 1] = string.format("%s:%s(%.1f)", a.name, a.verdict, a.dist or -1)
		end
		if #near >= 5 then break end
	end
	if #near > 0 then Line(grey, "  rejected near the feet: " .. table.concat(near, "  ")) end
	if #fol == 0 and #near > 0 then
		suspects[#suspects + 1] = "no foot followers but bones near the feet were rejected (see above) - if shoes detach, send ik_foot_dump"
	end

	if (Diag.stats.foreignWrites or 0) > 0 then
		local list = {}
		for name, n in pairs(Diag.stats.foreignBones or {}) do list[#list + 1] = name .. "x" .. n end
		suspects[#suspects + 1] = "other code overwrote bones the ik manages: " .. table.concat(list, ", ")
	end

	local recent = {}
	for i = #Diag.events, math.max(1, #Diag.events - 7), -1 do
		local e = Diag.events[i]
		recent[#recent + 1] = string.format("  %.2f%s %s %s %s", e.t, (e.count or 1) > 1 and string.format("-%.2f x%d", e.t_last, e.count) or "", e.kind, e.side or "", util.TableToJSON(e.values or {}) or "")
	end
	Line(head, string.format("last events (%d stored):", #Diag.events))
	for _, l in ipairs(recent) do Line(grey, l) end

	Line(head, "likely causes:")
	if #suspects == 0 then
		Line(good, "  nothing suspicious in the current frame")
	else
		for _, s in ipairs(suspects) do Line(warn, "  - " .. s) end
	end
	Line(grey, "full data: ik_foot_dump   recording: ik_foot_capture 10")
end

concommand.Add("ik_foot_diag", function() Diag.Report(LocalPlayer()) end, nil, "IK Foot: print a short diagnostic report")
concommand.Add("ik_foot_dump", function() Diag.Dump(LocalPlayer()) end, nil, "IK Foot: write the full ik state to data/ik_foot/dump_*.json")
concommand.Add("ik_foot_capture", function(_, _, args)
	Diag.StartCapture(args[1], args[2] == "detail")
end, nil, "IK Foot: record ik samples for N seconds (default 10, max 60). add 'detail' for manipulation and trace data")
concommand.Add("ik_foot_capture_stop", function() Diag.StopCapture("command") end, nil, "IK Foot: stop and save the running capture")

-- ---------------------------------------------------------------------
-- overlay
-- ---------------------------------------------------------------------

local COL = {
	anim = Color(170, 170, 170),     -- foot from the animation
	target = Color(255, 220, 60),    -- requested target
	ik = Color(60, 255, 90),         -- solver result
	engine = Color(255, 60, 255),    -- engine read back
	contact = Color(60, 220, 255),   -- ground contact
	knee = Color(255, 140, 40),      -- knee bend direction
	follower = Color(255, 120, 120),
	miss = Color(255, 50, 50),
}
Diag.Colors = COL

local function Box(pos, size, col)
	if not pos then return end
	render.DrawWireframeBox(pos, angle_zero, Vector(-size, -size, -size), Vector(size, size, size), col, true)
end

function Diag.DrawDebug(ply, res)
	local level = Level()
	if level <= 0 or not res then return end
	local rb = ply.IKDiagReadback
	if rb and rb.frame ~= ply.IKResultFrame then rb = nil end

	for _, side in ipairs({ "left", "right" }) do
		local leg = res[side]
		if leg then
			Box(leg.animFoot, 0.8, COL.anim)
			Box(leg.targetPos, 1.2, COL.target)
			Box(leg.ankle, 1.6, COL.ik)
			if leg.hip and leg.knee and leg.ankle then
				render.DrawLine(leg.hip, leg.knee, COL.ik, true)
				render.DrawLine(leg.knee, leg.ankle, COL.ik, true)
				-- knee bend direction: from the hip-ankle line out through the knee
				local hf = leg.ankle - leg.hip
				local len = hf:Length()
				if len > 0.01 then
					local u = hf / len
					local kh = leg.knee - leg.hip
					local mid = leg.hip + u * kh:Dot(u)
					local dir = leg.knee - mid
					if dir:LengthSqr() > 1e-4 then
						render.DrawLine(leg.knee, leg.knee + dir:GetNormalized() * 6, COL.knee, true)
					end
				end
			end
			if leg.contact and leg.contact.hasHit then
				render.DrawWireframeBox(leg.contact.position, angle_zero, Vector(-2, -2, -0.1), Vector(2, 2, 0.1), COL.contact, true)
				render.DrawLine(leg.contact.position, leg.contact.position + leg.contact.normal * 6, COL.contact, true)
			end
			local lrb = rb and rb.legs[side]
			if lrb and lrb.ankle then
				Box(lrb.ankle, 0.6, COL.engine)
			end
			if level > 1 then
				if leg.contact then RT.Ground.DrawSamples(leg.contact.samples, RT.Ground.DebugColors(side == "left"), COL.contact, level) end
				if leg.lockPos then
					render.DrawWireframeBox(leg.lockPos, angle_zero, Vector(-1, -1, -0.25), Vector(1, 1, 0.25), RT.Colors.white, true)
				end
				if not leg.reached and leg.targetPos and leg.ankle then
					render.DrawLine(leg.ankle, leg.targetPos, COL.miss, true)
				end
			end
		end
	end

	if level > 1 then
		RT.Ground.DrawScan(res.scan)
		local bones = ply.IKBones
		for i, f in ipairs(bones and bones.followers or {}) do
			local out = res.followers and res.followers[i]
			if out and out.expectedPos then
				Box(out.expectedPos, 0.7, COL.follower)
				local frb = rb and rb.followers[i]
				if frb and frb.pos then
					Box(frb.pos, 0.4, COL.engine)
					render.DrawLine(out.expectedPos, frb.pos, COL.miss, true)
				end
			end
		end
		local bottom, top
		if ply:Crouching() then bottom, top = ply:GetHullDuck() else bottom, top = ply:GetHull() end
		render.DrawWireframeBox(ply:GetPos(), angle_zero, bottom, top, RT.Colors.white, true)
	end

	if ply == LocalPlayer() then Diag.BuildHUD(ply, res, level) end
end

function Diag.BuildHUD(ply, res, level)
	local d = res.debug or {}
	local l, r = res.left, res.right
	local ri = d.restInfo or {}
	local rb = ply.IKDiagReadback
	if rb and rb.frame ~= ply.IKResultFrame then rb = nil end
	local function eng(side)
		local e = rb and rb.legs[side]
		return e and e.ankleErr and string.format("%.2f", e.ankleErr) or "--"
	end
	RT.Debug2D = RT.Debug2D or {}
	RT.Debug2D.expireAt = CurTime() + 0.2
	local lines = {
		string.format("IK DEBUG %d  v%s  [%s]", level, IKFoot.VERSION or "?", ply:Nick()),
		string.format("VEL2D %.0f  GROUND %s  DROP %.1f -> %.1f (%s)", d.velocity2D or 0, d.onGround and "Y" or "N", d.desiredDrop or 0, res.bodyDrop or 0, tostring(d.dropLimiter)),
		string.format("REQ L/R %.1f / %.1f   SUPPORT %.2f / %.2f", res.lRequiredDrop or 0, res.rRequiredDrop or 0, l.support or 0, r.support or 0),
		string.format("REST H %.2f (exp %s) sample %.2f %s", ri.value or 0, ri.expected and string.format("%.2f", ri.expected) or "?", ri.sample or 0, ri.used and "USED" or ("skip: " .. tostring(ri.reason))),
		string.format("STEP L %s %.2f %s   R %s %.2f %s", l.procPhase, l.procT or 0, tostring(l.stepBlocked or l.stepReason or ""), r.procPhase, r.procT or 0, tostring(r.stepBlocked or r.stepReason or "")),
		string.format("STAIRS %s %.0f%%  DEPTH %.1f RISE %.1f  T/STEP %s", d.stairMode and "ON" or "OFF", (d.stairBlend or 0) * 100, d.stairDepth or 0, d.stairRise or 0, tostring(d.treadsPerStep)),
		string.format("ENGINE ERR L/R %s / %s   FOLLOWERS %d   EVENTS %d", eng("left"), eng("right"), d.followers or 0, #Diag.events),
	}
	if level > 1 then
		local lr, rr = l.reach or {}, r.reach or {}
		lines[#lines + 1] = string.format("REACH L %.1f/%.1f %s  R %.1f/%.1f %s", lr.requested or 0, lr.maxReach or 0, lr.limit or "", rr.requested or 0, rr.maxReach or 0, rr.limit or "")
		lines[#lines + 1] = string.format("SCALE %.2f LEG %.1f SOLE %+.2f ROOTS %d  dt %.4f", d.modelScale or 1, d.measuredLeg or 0, d.soleCorrection or 0, d.auxRoots or 0, d.dt or 0)
		local e = Diag.events[#Diag.events]
		if e then lines[#lines + 1] = string.format("LAST EVENT %.1fs ago: %s %s", RealTime() - e.t, e.kind, e.side or "") end
		lines[#lines + 1] = "gray=anim yellow=target green=ik magenta=engine cyan=contact orange=knee"
	end
	RT.Debug2D.lines = lines

	-- labels next to the feet (drawn in HUDPaint)
	RT.Debug2D.labels = {}
	for _, side in ipairs({ "left", "right" }) do
		local leg = res[side]
		if leg and leg.ankle then
			RT.Debug2D.labels[#RT.Debug2D.labels + 1] = {
				pos = Vector(leg.ankle),
				text = string.format("%s %s%s", side == "left" and "L" or "R", leg.procPhase ~= "off" and leg.procPhase or (leg.planted and "locked" or "free"),
					leg.reached and "" or " MISS"),
			}
		end
	end
end
