-- whole per-frame pipeline on a tiny "engine": real hooks, real bone layer,
-- real diagnostics. the fake entity computes bone matrices from animated
-- local transforms + manipulations (position added in parent space, angles
-- post-multiplied) and InvalidateBoneCache really drops the cache, so a stale
-- read or a manipulation that is not removed shows up as an error.
dofile(ROOT .. "/tests/gmod_mock.lua")
local M, mul, T, mv, toAng = MOCK.M, MOCK.mul, MOCK.T, MOCK.mv, MOCK.toAng

local SPEED = SPEED or 90
local now, frame, dt = 0, 0, 1 / 60
function FrameTime() return dt end
function RealFrameTime() return dt end
function RealTime() return now end
function CurTime() return now end
function FrameNumber() return frame end
NULL = {}
function IsValid(e) return e ~= nil and e ~= NULL and type(e) == "table" and (e.valid ~= false) end
MASK_PLAYERSOLID, MASK_SOLID, RENDERGROUP_OTHER = 1, 2, 0
MOVETYPE_NOCLIP, MOVETYPE_LADDER, MOVETYPE_WALK = 8, 9, 2
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a } end
string.StartWith = function(s, p) return s:sub(1, #p) == p end
string.GetFileFromFilename = function(p) return p:match("([^/]+)$") end
function EyePos() return Vector(0, 0, 64) end
game = { GetMap = function() return "test_map" end }
engine = { ActiveGamemode = function() return "sandbox" end }
chat = { AddText = function() end }
timer = { Simple = function() end }
render = setmetatable({}, { __index = function() return function() end end })

local hooks = {}
hook = { Add = function(event, name, fn) hooks[event] = hooks[event] or {}; hooks[event][name] = fn end }
local function CallHook(event, ...) for _, fn in pairs(hooks[event] or {}) do fn(...) end end
local commands = {}
concommand = { Add = function(name, fn) commands[name] = fn end }
local cvars = {}
function CreateClientConVar(name, def)
  cvars[name] = tostring(def)
  return {
    GetFloat = function() return tonumber(cvars[name]) or 0 end,
    GetBool = function() return (tonumber(cvars[name]) or 0) ~= 0 end,
    GetInt = function() return math.floor(tonumber(cvars[name]) or 0) end,
    GetString = function() return cvars[name] end,
  }
end
function RunConsoleCommand(name, value) cvars[name] = tostring(value) end
function GetConVar(name) return cvars[name] and CreateClientConVar(name, cvars[name]) end

FILES = {}
file = { CreateDir = function() end, Write = function(name, data) FILES[name] = data end }

-- minimal json encoder (enough for the diagnostics, validated by python)
local function enc(v, out)
  local t = type(v)
  if t == "nil" then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null" else out[#out + 1] = string.format("%.6g", v) end
  elseif t == "string" then out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
  elseif t == "table" then
    local n = #v
    local isArray = n > 0 or next(v) == nil
    if isArray then for k in pairs(v) do if type(k) ~= "number" then isArray = false break end end end
    if isArray then
      out[#out + 1] = "["
      for i = 1, n do if i > 1 then out[#out + 1] = "," end enc(v[i], out) end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for k, val in pairs(v) do
        if not first then out[#out + 1] = "," end
        first = false
        enc(tostring(k), out); out[#out + 1] = ":"; enc(val, out)
      end
      out[#out + 1] = "}"
    end
  else out[#out + 1] = '"' .. tostring(v) .. '"' end
end

-- world: stairs along +x (12 deep, 8 high)
local function H(x)
  if WORLD == "flat" then return 0 end
  if x < 0 then return 0 end
  return math.min(math.floor(x / 12) + 1, 10) * 8
end
local function HMax(x0, x1) local m = -1e9 for x = x0, x1, 0.25 do m = math.max(m, H(x)) end return m end
local function trace(t, hull)
  local out = t.output or {}
  for k in pairs(out) do out[k] = nil end
  local x = t.start.x
  local top = hull and HMax(x - 1.5, x + 1.5) or H(x)
  if t.start.z >= top and t.endpos.z <= top then
    out.Hit, out.HitPos, out.HitNormal, out.HitWorld, out.Entity, out.StartSolid = true, Vector(t.start.x, t.start.y, top), Vector(0, 0, 1), true, NULL, false
  else
    out.Hit, out.HitPos, out.HitNormal, out.HitWorld, out.Entity = false, Vector(t.endpos), Vector(0, 0, 1), false, NULL
  end
  return out
end

-- skeleton
local VB = "ValveBiped.Bip01_"
local BONES = {
  { VB .. "Pelvis", -1 }, { VB .. "L_Thigh", 0 }, { VB .. "L_Calf", 1 }, { VB .. "L_Foot", 2 },
  { VB .. "R_Thigh", 0 }, { VB .. "R_Calf", 4 }, { VB .. "R_Foot", 5 },
  { "shoe_L", 0 }, { "shoe_R", 0 }, { VB .. "Spine1", 0 },
}
local IDX = {}
for i, b in ipairs(BONES) do IDX[b[1]] = i - 1 end

local function blob(name, x, y, z, hx, hy, hz)
  local list = { { name, x, y, z } }
  for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
    list[#list + 1] = { name, x + sx * hx, y + sy * hy, z + sz * hz }
  end end end
  return list
end
util = {
  TraceLine = function(t) return trace(t, false) end,
  TraceHull = function(t) return trace(t, true) end,
  TableToJSON = function(tbl) local out = {} enc(tbl, out) return table.concat(out) end,
  GetModelMeshes = function()
    local verts = {}
    for _, g in ipairs({ blob(VB .. "L_Foot", 2, 4, 2, 4, 1.5, 1.5), blob(VB .. "R_Foot", 2, -4, 2, 4, 1.5, 1.5),
      blob("shoe_L", 3, 4, 1.5, 4.5, 2, 1.5), blob("shoe_R", 3, -4, 1.5, 4.5, 2, 1.5), blob(VB .. "Spine1", 0, 0, 45, 5, 5, 5) }) do
      for _, w in ipairs(g) do verts[#verts + 1] = { pos = Vector(w[2], w[3], w[4]), weights = { { bone = IDX[w[1]], weight = 1 } } } end
    end
    return { { verticies = verts } }
  end,
}

local ply = { valid = true, pos = Vector(-60, 0, 0), manipPos = {}, manipAng = {}, world = nil, anim = {}, __isEntity = true }
function ply:GetModel() return "models/test/pipeline.mdl" end
function ply:GetBoneCount() return #BONES end
function ply:GetBoneName(i) return BONES[i + 1] and BONES[i + 1][1] end
function ply:GetBoneParent(i) return BONES[i + 1] and BONES[i + 1][2] end
function ply:LookupBone(n) return IDX[n] end
function ply:ManipulateBonePosition(i, v) self.manipPos[i] = Vector(v) end
function ply:GetManipulateBonePosition(i) return Vector(self.manipPos[i] or Vector()) end
function ply:ManipulateBoneAngles(i, a) self.manipAng[i] = Angle(a) end
function ply:GetManipulateBoneAngles(i) return Angle(self.manipAng[i] or Angle()) end
function ply:InvalidateBoneCache() self.world = nil end
function ply:SetupBones()
  local world = {}
  local entRot = M(Angle(0, 0, 0))
  for i = 0, #BONES - 1 do
    local a = self.anim[i]
    local parent = BONES[i + 1][2]
    local pPos, pRot = self.pos, entRot
    if parent >= 0 then pPos, pRot = world[parent].pos, world[parent].rot end
    local lp = a.pos + (self.manipPos[i] or Vector())
    local lr = mul(a.rot, M(self.manipAng[i] or Angle()))
    world[i] = { pos = pPos + mv(pRot, lp), rot = mul(pRot, lr) }
  end
  self.world = world
end
function ply:GetBoneMatrix(i)
  if not self.world or not self.world[i] then return nil end
  local w = self.world[i]
  return { GetTranslation = function() return Vector(w.pos) end, GetAngles = function() return toAng(w.rot) end }
end
function ply:GetPos() return Vector(self.pos) end
function ply:GetVelocity() return Vector(SPEED, 0, 0) end
function ply:OnGround() return true end
function ply:WaterLevel() return 0 end
function ply:Crouching() return false end
function ply:GetRenderAngles() return Angle(0, 0, 0) end
function ply:GetAngles() return Angle(0, 0, 0) end
function ply:GetGroundEntity() return NULL end
function ply:GetModelScale() return 1 end
function ply:Alive() return true end
function ply:InVehicle() return false end
function ply:GetMoveType() return MOVETYPE_WALK end
function ply:Nick() return "tester" end
function ply:GetSequence() return 3 end
function ply:GetSequenceName() return "walk_all" end
function ply:GetCycle() return (now * 1.3) % 1 end
function ply:GetPlaybackRate() return 1 end
function ply:GetHull() return Vector(-16, -16, 0), Vector(16, 16, 72) end
function ply:GetHullDuck() return Vector(-16, -16, 0), Vector(16, 16, 36) end
function ply:GetNWFloat(_, d) return d end
function ply:GetNWBool(_, d) return d end
function LocalPlayer() return ply end
player = { GetAll = function() return { ply } end }

local function frameAng(dir, hinge)
  local x = dir:GetNormalized(); local z = (hinge - x * hinge:Dot(x)):GetNormalized(); local y = z:Cross(x)
  return toAng({ { x.x, y.x, z.x }, { x.y, y.y, z.y }, { x.z, y.z, z.z } })
end

-- animated world transforms -> local (parent relative) transforms
local SHOE_OFFSET, SHOE_ROT = Vector(1.5, 0.3, -2), Angle(5, 10, -3)
local phase = 0
local function Animate()
  local o = ply.pos
  local world = {}
  local pelvisAng = Angle(3 * math.sin(phase), 15 * math.sin(phase * 0.5), 6 * math.cos(phase))
  world[0] = { pos = o + Vector(0, 0, 38), ang = pelvisAng }
  world[9] = { pos = o + Vector(0, 0, 45), ang = Angle(-90, 0, 0) }
  for k, side in ipairs({ "L", "R" }) do
    local ph = phase + (k - 1) * math.pi
    local fx = math.sin(ph) * 18
    local lift = math.max(0, math.cos(ph)) * 4
    if SPEED == 0 then fx, lift = 0, 0 end
    local y = side == "L" and 4 or -4
    local hip = o + Vector(0, y, 38)
    local foot = o + Vector(fx, y, 3 + lift)
    local d = foot - hip
    local dl = d:Length()
    local perp = Vector(1, 0, 0) - d:GetNormalized() * Vector(1, 0, 0):Dot(d:GetNormalized())
    perp:Normalize()
    local knee = hip + d * 0.5 + perp * math.sqrt(math.max(19.5 * 19.5 - (dl * 0.5) ^ 2, 0))
    foot = hip + d:GetNormalized() * math.min(dl, 38.9)
    local base = side == "L" and 1 or 4
    world[base] = { pos = hip, ang = frameAng(knee - hip, Vector(0, 1, 0)) }
    world[base + 1] = { pos = knee, ang = frameAng(foot - knee, Vector(0, 1, 0)) }
    world[base + 2] = { pos = foot, ang = frameAng(Vector(1, 0, -0.3), Vector(0, -1, 0)) }
    local sp, sa = LocalToWorld(SHOE_OFFSET, SHOE_ROT, foot, world[base + 2].ang)
    world[side == "L" and 7 or 8] = { pos = sp, ang = sa }
  end
  for i = 0, #BONES - 1 do
    local parent = BONES[i + 1][2]
    local pPos, pRot = o, M(Angle(0, 0, 0))
    if parent >= 0 then pPos, pRot = world[parent].pos, M(world[parent].ang) end
    ply.anim[i] = { pos = mv(T(pRot), world[i].pos - pPos), rot = mul(T(pRot), M(world[i].ang)) }
  end
end

-- pac3 with parts worn: values are stored, applied in PreDrawOpaqueRenderables
-- + a bone part adding +2 z on the pelvis (exactly like pac3's part_pool/bones)
if WITH_PAC then
  pac = { IsEnabled = function() return true end }
  ply.pac_has_parts = true
  function pac.ManipulateBonePosition(e, id, v) e.pac_boneanim = e.pac_boneanim or { positions = {}, angles = {} }; e.pac_boneanim.positions[id] = v end
  function pac.ManipulateBoneAngles(e, id, v) e.pac_boneanim = e.pac_boneanim or { positions = {}, angles = {} }; e.pac_boneanim.angles[id] = v end
end
local function PacReset()
  if not WITH_PAC then return end
  local store = ply.pac_boneanim or { positions = {}, angles = {} }
  for i = 0, #BONES - 1 do
    ply.manipPos[i] = Vector(store.positions[i] or Vector())
    ply.manipAng[i] = Angle(store.angles[i] or Angle())
  end
  ply.manipPos[0] = ply.manipPos[0] + Vector(0, 0, 2)
  if PAC_THIGH_PART then
    -- a pac bone part on one of OUR bones: pac adds it per euler component
    local i = IDX[VB .. "L_Thigh"]
    local a = ply.manipAng[i]
    ply.manipAng[i] = Angle(a.p + PAC_THIGH_PART.p, a.y + PAC_THIGH_PART.y, a.r + PAC_THIGH_PART.r)
  end
end

-- load the real client runtime
dofile(ROOT .. "/lua/ik_foot/shared/sh_ik_foot_config.lua")
for _, f in ipairs({ "cl_ik_foot_context.lua", "ik_ground.lua", "ik_solver.lua", "ik_state.lua", "ik_controller.lua", "ik_apply.lua", "ik_diag.lua", "cl_ik_foot_hooks.lua" }) do
  dofile(ROOT .. "/lua/ik_foot/client/runtime/" .. f)
end
local RT = IKFoot.Runtime
cvars.ik_foot_debug = DEBUG_LEVEL or "0"

local fails = 0
local function check(name, cond, info) if not cond then fails = fails + 1; print("FAIL", name, info or "") end end

local maxAnkleErr, maxKneeErr, maxFollowerErr, maxAnimDrift = 0, 0, 0, 0
local function Frame()
  now = now + dt; frame = frame + 1
  ply.pos.x = ply.pos.x + SPEED * dt
  ply.pos.z = HMax(ply.pos.x - 16, ply.pos.x + 16)
  phase = phase + dt * SPEED / 36 * math.pi
  Animate()
  -- engine order for one frame
  PacReset()
  ply.world = nil -- new frame: bone cache is stale
  CallHook("PrePlayerDraw", ply)
  -- the "clean" pose the runtime read must equal the pure animation
  if ply.IKResult and ply.IKResultFrame == frame then
    local a = ply.IKResult.left.animFoot
    ply:SetupBones() -- the draw (cache was invalidated by the runtime)
    local saved = { manipPos = ply.manipPos, manipAng = ply.manipAng }
    -- pure animation reference: no manipulations except pac's own part
    ply.manipPos, ply.manipAng = {}, {}
    if WITH_PAC then ply.manipPos[0] = Vector(0, 0, 2) end
    if PAC_THIGH_PART then ply.manipAng[IDX[VB .. "L_Thigh"]] = Angle(PAC_THIGH_PART.p, PAC_THIGH_PART.y, PAC_THIGH_PART.r) end
    local drawn = ply.world
    ply:SetupBones()
    local pure = ply.world[IDX[VB .. "L_Foot"]].pos
    maxAnimDrift = math.max(maxAnimDrift, a:Distance(pure))
    ply.manipPos, ply.manipAng, ply.world = saved.manipPos, saved.manipAng, drawn
  else
    ply:SetupBones()
  end
  CallHook("PostPlayerDraw", ply)
  if (tonumber(cvars.ik_foot_debug) or 0) > 0 then
    CallHook("PostDrawTranslucentRenderables", false, false)
    CallHook("HUDPaint")
  end
  local rb = ply.IKDiagReadback
  if rb and rb.frame == frame then
    for _, side in ipairs({ "left", "right" }) do
      maxAnkleErr = math.max(maxAnkleErr, rb.legs[side].ankleErr or 0)
      maxKneeErr = math.max(maxKneeErr, rb.legs[side].kneeErr or 0)
    end
    for _, f in pairs(rb.followers) do maxFollowerErr = math.max(maxFollowerErr, f.err) end
  end
end

for _ = 1, 150 do Frame() end
local bones = ply.IKBones
check("bones valid", bones and bones.valid)
check("two followers", bones and #bones.followers == 2, bones and #bones.followers)
check("ik active", ply.IKActive)
print(string.format("engine vs solver: ankle %.4f  knee %.4f  follower %.4f   clean-read drift %.4f", maxAnkleErr, maxKneeErr, maxFollowerErr, maxAnimDrift))
-- formula errors show as whole units; euler manipulation angles near pitch
-- 90 (a ~90 deg ik turn of the calf) keep only a few hundredths of a unit
check("ankle engine err", maxAnkleErr < 0.05, maxAnkleErr)
check("knee engine err", maxKneeErr < 0.01, maxKneeErr)
check("knee engine err", maxKneeErr < 0.01, maxKneeErr)
check("follower engine err", maxFollowerErr < 0.01, maxFollowerErr)
check("clean read is pure animation", maxAnimDrift < 0.01, maxAnimDrift)

local function countEvents(kind)
  local n = 0
  for _, e in ipairs(RT.Diag.events) do if e.kind == kind then n = n + 1 end end
  return n
end
check("no process errors", countEvents("process_error") == 0, countEvents("process_error"))
check("no foreign writes", countEvents("foreign_write") == 0, countEvents("foreign_write"))
check("no engine mismatch", countEvents("engine_mismatch") == 0)
check("no replant pops", countEvents("replant") == 0, countEvents("replant"))

-- another addon overwrites the left thigh between our frames
-- (big rotation on purpose: euler addition instead of composition errs by inches)
ply.manipAng[IDX[VB .. "L_Thigh"]] = Angle(25, 30, -20)
if WITH_PAC then ply.pac_boneanim.angles[IDX[VB .. "L_Thigh"]] = Angle(25, 30, -20) end
FOREIGN_THIGH = Angle(25, 30, -20)
maxAnkleErr, maxKneeErr = 0, 0
cvars.ik_foot_debug = "1" -- read back every frame from here on
for _ = 1, 10 do Frame() end
check("foreign write detected", countEvents("foreign_write") >= 1, countEvents("foreign_write"))
print(string.format("with a foreign thigh rotation: engine vs solver ankle %.4f knee %.4f", maxAnkleErr, maxKneeErr))
check("composition exact with foreign rotation", maxAnkleErr < 0.01, maxAnkleErr)
cvars.ik_foot_debug = DEBUG_LEVEL or "0"

-- commands: report, dump, capture
commands["ik_foot_diag"]()
FILES = {}
commands["ik_foot_dump"]()
local dumpName = next(FILES)
check("dump written", dumpName ~= nil)
DUMP_JSON = dumpName and FILES[dumpName]
FILES = {}
commands["ik_foot_capture"](nil, nil, { "1" })
for _ = 1, 75 do Frame() end
local capName = next(FILES)
check("capture auto saved", capName ~= nil)
CAPTURE_JSON = capName and FILES[capName]

-- settings arrive over the network (the server forwards each player's own
-- values to everyone): nan must not get through, inf clamps
local smoothing = IKFoot.Config.byKey.smoothing
local nanValue = IKFoot.Config.ClampNumber(smoothing, 0 / 0)
check("nan setting falls back to its default", nanValue == smoothing.default, nanValue)
check("inf setting clamps to max", IKFoot.Config.ClampNumber(smoothing, math.huge) == smoothing.max)
local other = setmetatable({ GetNWFloat = function() return 0 / 0 end }, { __index = ply })
local remote = RT.GetIKParam(other, "smoothing")
check("another player's nan setting", remote == smoothing.default, remote)
local far = setmetatable({ GetNWFloat = function() return 1e9 end }, { __index = ply })
check("another player's out of range setting", RT.GetIKParam(far, "smoothing") == smoothing.max, RT.GetIKParam(far, "smoothing"))
PIPELINE_FAILS = fails
print("pipeline test fails:", fails)
