dofile(ROOT .. "/tests/gmod_mock.lua")
local SPEED = SPEED or 90
-- world: stairs along +x. tread 12 deep, 8 high, 10 steps, then a flat top
local TREAD, RISE, STEPS = 12, 8, 10
local function H(x)
  if WORLD == "flat" then return 0 end
  if WORLD == "ramp" then return math.max(0, math.min(x, 120)) * 0.5 end
  if WORLD == "curb" then return x >= 0 and 6 or 0 end
  if x < 0 then return 0 end
  local k = math.floor(x / TREAD) + 1
  return math.min(k, STEPS) * RISE
end
local function HMax(x0, x1) local m = -1e9 for x = x0, x1, 0.25 do m = math.max(m, H(x)) end return m end

local now, frame, dt = 0, 0, 1/60
function FrameTime() return dt end
function RealTime() return now end
function CurTime() return now end
function FrameNumber() return frame end
NULL = {}
function IsValid(e) return e ~= nil and e ~= NULL and type(e) == "table" and e.valid end
MASK_PLAYERSOLID = 1
player = { GetAll = function() return {} end }
string.StartWith = function(s, p) return s:sub(1, #p) == p end
function Color(r,g,b,a) return {r=r,g=g,b=b,a=a} end
util = {}
local function trace(t, hull)
  local out = t.output or {}
  local x = t.start.x
  local top = hull and HMax(x - 1.5, x + 1.5) or H(x)
  for k in pairs(out) do out[k] = nil end
  if t.start.z >= top and t.endpos.z <= top then
    out.Hit = true; out.HitPos = Vector(t.start.x, t.start.y, top); out.HitNormal = Vector(0,0,1)
    out.HitWorld = true; out.Entity = NULL; out.StartSolid = false
  else
    out.Hit = false; out.HitPos = Vector(t.endpos); out.HitNormal = Vector(0,0,1); out.HitWorld = false; out.Entity = NULL
  end
  return out
end
util.TraceLine = function(t) return trace(t, false) end
util.TraceHull = function(t) return trace(t, true) end

for _, f in ipairs({"shared/sh_ik_foot_config.lua"}) do dofile(ROOT.."/lua/ik_foot/"..f) end
IKFoot.Runtime = {}
local RT = IKFoot.Runtime
RT.REFERENCE_LEG_LENGTH = 45
RT.Colors = {}
RT.GetSoleCorrection = function() return 0 end
for _, f in ipairs({"ik_ground.lua", "ik_solver.lua", "ik_state.lua", "ik_controller.lua"}) do
  dofile(ROOT.."/lua/ik_foot/client/runtime/"..f)
end

local P = {}
for _, e in ipairs(IKFoot.Config.entries) do P[e.key] = e.type == "bool" and e.default or e.default end
P.auto_model_detect = false
if NOSTEP then P.stair_stepper = false end

local DIR = DIR or 1
local ply = { valid = true, pos = Vector(DIR > 0 and -60 or 220, 0, 0) }
function ply:GetPos() return Vector(self.pos) end
function ply:GetVelocity() return Vector(CURSPEED * DIR, 0, 0) end
function ply:OnGround() return true end
function ply:WaterLevel() return 0 end
function ply:Crouching() return false end
function ply:GetRenderAngles() return Angle(0, DIR > 0 and 0 or 180, 0) end
function ply:GetAngles() return Angle(0, DIR > 0 and 0 or 180, 0) end
function ply:GetGroundEntity() return NULL end
function ply:GetModelScale() return 1 end

local function frameAng(dir, hinge)
  local x = dir:GetNormalized(); local z = (hinge - x*hinge:Dot(x)):GetNormalized(); local y = z:Cross(x)
  return MOCK.toAng({{x.x,y.x,z.x},{x.y,y.y,z.y},{x.z,y.z,z.z}})
end

-- synthetic walk: stride 36 units (a normal anim stride covers 3 treads)
local STRIDE, REST = 36, 3
local function skeleton(o, phase)
  local legs = {}
  for i, side in ipairs({"left", "right"}) do
    local ph = phase + (i - 1) * math.pi
    local fx = math.sin(ph) * STRIDE * 0.5
    local lift = math.max(0, math.cos(ph)) * 4
    local y = (side == "left" and 4 or -4) * DIR
    local hip = o + Vector(0, y, 38)
    local foot = o + Vector(fx * DIR, y, REST + lift)
    -- place knee so both segments are 19.5 long and the knee points +x
    local d = foot - hip; local dl = d:Length(); local a = 19.5
    local mid = hip + d * 0.5
    local fwdv = Vector(DIR,0,0)
    local perp = fwdv - d:GetNormalized() * fwdv:Dot(d:GetNormalized())
    perp:Normalize()
    local knee = mid + perp * math.sqrt(math.max(a*a - (dl*0.5)^2, 0))
    foot = hip + (foot - hip):GetNormalized() * math.min(dl, 38.9)
    legs[side] = { thighPos = hip, calfPos = knee, footPos = foot,
      thighAng = frameAng(knee - hip, Vector(0,1,0)), calfAng = frameAng(foot - knee, Vector(0,1,0)),
      footAng = frameAng(Vector(DIR,0,-0.3), Vector(0,-DIR,0)) }
  end
  return { legLength = 39, left = legs.left, right = legs.right }
end

-- shoes skinned to bones parented to the pelvis (not to the feet)
local bones = { profile = {}, auxRoots = {}, leanBone = nil, followers = {
  { bone = 50, side = "left", parent = 0, shifted = true },
  { bone = 51, side = "right", parent = 0, shifted = true },
} }
local SHOE_OFFSET = Vector(1.5, 0, -2)
local maxShoeErr = 0
local phase = 0
local plants = { left = {}, right = {} }
local lastPhase = { left = "planted", right = "planted" }
local lastDrop, maxDropJump, maxPenetration, maxFloat = nil, 0, 0, 0
local maxSkip = 0
local maxAbsDropFlat, stairFrames = 0, 0
local maxFootErr = 0
for i = 1, 60 * 5 do
  now = now + dt; frame = frame + 1
  -- source movement: origin snaps to the highest ground under the 32x32 hull
  CURSPEED = (STOPAT and now > STOPAT) and 0 or SPEED
  ply.pos.x = ply.pos.x + CURSPEED * dt * DIR
  ply.pos.z = HMax(ply.pos.x - 16, ply.pos.x + 16)
  if CURSPEED > 0 then phase = phase + dt * CURSPEED / STRIDE * math.pi else phase = math.floor(phase / math.pi + 0.5) * math.pi + math.pi * 0.5 end
  local sk = skeleton(ply:GetPos(), phase)
  sk.followers = {}
  for i, side in ipairs({"left", "right"}) do
    local fl = sk[side]
    local pos, ang = LocalToWorld(SHOE_OFFSET, Angle(0, 0, 0), fl.footPos, fl.footAng)
    sk.followers[i] = { pos = pos, ang = ang, parentAng = Angle(0, DIR > 0 and 0 or 180, 0) }
  end
  local res = RT.Controller.Calculate(ply, sk, bones, P)
  for i, side in ipairs({"left", "right"}) do
    local f, out, leg = sk.followers[i], res.followers[i], res[side]
    -- forward: parent (pelvis) moved by -drop, plus our manip in parent space
    local final = f.pos + Vector(0, 0, -res.bodyDrop) + LocalToWorld(out.pos, Angle(), Vector(), f.parentAng)
    local expected = LocalToWorld(SHOE_OFFSET, Angle(), leg.footFinal, leg.footWorld)
    maxShoeErr = math.max(maxShoeErr, final:Distance(expected))
  end
  LASTRES = res
  local inStairs = res.debug.stairBlend >= 0.999
  if res.debug.stairBlend > 0 then stairFrames = stairFrames + 1 end
  maxAbsDropFlat = math.max(maxAbsDropFlat, math.abs(res.bodyDrop))
  -- in animation mode the foot must follow the anim foot + ground offset
  if res.debug.stairBlend == 0 then
    for _, side in ipairs({"left","right"}) do
      local leg = res[side]
      if leg.ankle and leg.reached then maxFootErr = math.max(maxFootErr, leg.ankle:Distance(leg.targetPos)) end
    end
  end
  if TRACE and i % 3 == 0 then local st = RT.State.Get(ply); local sc = st.stairs.scan; print(string.format("t=%.2f x=%.1f oz=%.0f act=%s blend=%.2f stairs=%s edges=%d depth=%.1f drop=%.1f L:%s %.2f ax=%.1f az=%.1f g=%.0f R:%s %.2f ax=%.1f az=%.1f g=%.0f reachL=%s", now, ply.pos.x, ply.pos.z, tostring(st.stairs.active), res.debug.stairBlend, tostring(sc and sc.isStairs), sc and sc.edges or -1, sc and sc.depth or -1, res.bodyDrop, res.left.procPhase, res.left.procT, res.left.ankle.x, res.left.ankle.z, H(res.left.ankle.x), res.right.procPhase, res.right.procT, res.right.ankle.x, res.right.ankle.z, H(res.right.ankle.x), tostring(res.left.reached))) end
  for _, side in ipairs({"left","right"}) do
    local leg = res[side]
    if inStairs and leg.procPhase == "planted" and lastPhase[side] == "swinging" then
      plants[side][#plants[side]+1] = leg.ankle.x
    end
    if inStairs and leg.procPhase == "planted" and leg.ankle then
      local g = H(leg.ankle.x)
      local h = leg.ankle.z - g - res.debug.restHeight
      maxPenetration = math.max(maxPenetration, -h)
      maxFloat = math.max(maxFloat, h)
      if TRACEF and h > 0.5 then print(string.format("FLOAT t=%.2f %s h=%.2f ax=%.1f az=%.1f g=%.0f reached=%s drop=%.1f oz=%.0f px=%.1f", now, side, h, leg.ankle.x, leg.ankle.z, H(leg.ankle.x), tostring(leg.reached), res.bodyDrop, ply.pos.z, ply.pos.x)) end
    end
    lastPhase[side] = leg.procPhase
  end
  -- body height in WORLD space must be continuous even though origin pops a full step
  local bodyZ = ply.pos.z - res.bodyDrop
  if lastDrop then maxDropJump = math.max(maxDropJump, math.abs(bodyZ - lastDrop)) end
  if TRACEB and math.abs(bodyZ - (lastDrop or bodyZ)) > (BTH or 4) then print(string.format("BODY t=%.3f x=%.1f oz=%.0f drop=%.2f jump=%.1f bz=%.2f blend=%.2f L=%.1f R=%.1f", now, ply.pos.x, ply.pos.z, res.bodyDrop, res.debug.originJump, bodyZ, res.debug.stairBlend, res.lRequiredDrop, res.rRequiredDrop)) end
  lastDrop = bodyZ
end

local allPlants = {}
for _, side in ipairs({"left","right"}) do for _, x in ipairs(plants[side]) do allPlants[#allPlants+1] = {x=x, side=side} end end
table.sort(allPlants, function(a,b) return a.x < b.x end)
local treadSeq = {}
for _, p in ipairs(allPlants) do treadSeq[#treadSeq+1] = string.format("%s:%d", p.side:sub(1,1), math.floor(p.x / TREAD)) end
print("speed", SPEED, "plants (side:tread):", table.concat(treadSeq, " "))
local skips = 0
for i = 2, #allPlants do
  local d = math.floor(allPlants[i].x / TREAD) - math.floor(allPlants[i-1].x / TREAD)
  maxSkip = math.max(maxSkip, d)
  if allPlants[i].side == allPlants[i-1].side then skips = skips + 1 end
end
print(string.format("max treads between consecutive footfalls: %d, same-foot-twice: %d", maxSkip, skips))
print(string.format("max planted foot penetration: %.2f  float: %.2f", maxPenetration, maxFloat))
if STOPAT then local st = RT.State.Get(ply); local res = LASTRES; for _, side in ipairs({'left','right'}) do local leg = res[side]; print(string.format('STOPPED %s phase=%s ankle z-ground-rest=%.2f tread=%d', side, leg.procPhase, leg.ankle.z - H(leg.ankle.x) - res.debug.restHeight, math.floor(leg.ankle.x / TREAD))) end print('stair blend', res.debug.stairBlend, 'drop', res.bodyDrop) end
print(string.format("max shoe-to-foot error: %.4f", maxShoeErr))
print(string.format("world=%s dir=%d stair frames=%d  max |drop|=%.2f  max solver err=%.3f", tostring(WORLD), DIR, stairFrames, maxAbsDropFlat, maxFootErr))
print(string.format("max per-frame world body height change: %.2f (origin pops %d per step)", maxDropJump, RISE))
