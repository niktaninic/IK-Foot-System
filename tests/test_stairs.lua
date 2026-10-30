dofile(ROOT .. "/tests/gmod_mock.lua")
local SPEED = SPEED or 90
-- world: stairs along +x. tread 12 deep, 8 high, 10 steps, then a flat top
local TREAD, RISE, STEPS = TREAD or 12, RISE or 8, 10
local LEDGE_DROP = LEDGE_DROP or 30
-- visible geometry
local function H(x)
  if WORLD == "flat" then return 0 end
  if WORLD == "ramp" then return math.max(0, math.min(x, 120)) * 0.5 end
  if WORLD == "curb" then return x >= 0 and 6 or 0 end
  if WORLD == "ledge" then return x < 0 and 0 or -LEDGE_DROP end
  if x < 0 then return 0 end
  local k = math.floor(x / TREAD) + 1
  return math.min(k, STEPS) * RISE
end
-- "clipstairs": an invisible player clip ramp over the stairs, touching the
-- nosings (common on source maps). only the player's movement and
-- MASK_PLAYERSOLID traces collide with it
local function Clip(x)
  if WORLD ~= "clipstairs" then return -1e9 end
  return math.min(math.max((x + TREAD) * RISE / TREAD, 0), STEPS * RISE)
end
local function Phys(x) return math.max(H(x), Clip(x)) end
local function MaxOf(f, x0, x1) local m = -1e9 for x = x0, x1, 0.25 do m = math.max(m, f(x)) end return m end
local function HMax(x0, x1) return MaxOf(H, x0, x1) end

local now, frame, dt = 0, 0, LOWFPS and 0.1 or 1/60
function FrameTime() return dt end
function RealTime() return now end
function CurTime() return now end
function FrameNumber() return frame end
NULL = {}
function IsValid(e) return e ~= nil and e ~= NULL and type(e) == "table" and e.valid end
MASK_PLAYERSOLID, MASK_SOLID = 1, 2
player = { GetAll = function() return {} end }
string.StartWith = function(s, p) return s:sub(1, #p) == p end
function Color(r,g,b,a) return {r=r,g=g,b=b,a=a} end
util = {}
local function trace(t, hull)
  local out = t.output or {}
  local x = t.start.x
  local f = t.mask == MASK_PLAYERSOLID and Phys or H
  local top = hull and MaxOf(f, x - 1.5, x + 1.5) or f(x)
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
RT.GetExpectedRestHeight = function() return EXPECTED_REST end
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
local facingYaw = (DIR > 0 and 0 or 180) + (STRAFE and 90 or 0)
function ply:GetRenderAngles() return Angle(0, facingYaw, 0) end
function ply:GetAngles() return Angle(0, facingYaw, 0) end
function ply:GetGroundEntity() return NULL end
function ply:GetModelScale() return MODELSCALE or 1 end
function ply:GetStepSize() return 18 end
function ply:GetHull() return Vector(-16, -16, 0), Vector(16, 16, 72) end

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
    if (CURSPEED or SPEED) == 0 then fx, lift = 0, 0 end -- standing: feet together, on the ground
    local y = (side == "left" and 4 or -4) * DIR
    local hip = o + Vector(0, y, 38)
    local rest = (REST_DIP and now > 1.0 and now < 1.5) and 0.3 or REST
    local foot = o + Vector(fx * DIR, y, rest + lift)
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

-- shoes that do not inherit the foot: left one under a rotating pelvis
-- ("body"), right one under the calf ("calf"). checked with an independent
-- forward kinematics pass below, not with the controller's own formulas
local FOLLOWER_KIND = FOLLOWER_KIND or "mixed"
local bones = { profile = {}, auxRoots = {}, leanBone = nil, followers = {
  { bone = 50, side = "left", parent = 0, kind = FOLLOWER_KIND == "calf" and "calf" or "body", name = "shoe_L" },
  { bone = 51, side = "right", parent = 9, kind = FOLLOWER_KIND == "body" and "body" or "calf", name = "shoe_R" },
} }
local SHOE_OFFSET = Vector(1.5, 0.3, -2)
local SHOE_ROT = Angle(5, 10, -3)
local maxShoeErr, maxShoeAngErr = 0, 0
local M, mul, T, mv, toAng = MOCK.M, MOCK.mul, MOCK.T, MOCK.mv, MOCK.toAng
local function angErr(a, b)
  local fa, fb, ua, ub = a:Forward(), b:Forward(), a:Up(), b:Up()
  return math.deg(math.acos(math.min(1, fa:Dot(fb)))) + math.deg(math.acos(math.min(1, ua:Dot(ub))))
end
-- engine-style fk of one leg with our manipulations: returns calf and foot world transforms
local function LegFK(sk, res, side, drop)
  local leg, out = sk[side], res[side]
  local dz = Vector(0, 0, -drop)
  local H = leg.thighPos + dz
  local Rt, Rc, Rf = M(leg.thighAng), M(leg.calfAng), M(leg.footAng)
  local Lc, Lf = mul(T(Rt), Rc), mul(T(Rc), Rf)
  local pc, pf = mv(T(Rt), leg.calfPos - leg.thighPos), mv(T(Rc), leg.footPos - leg.calfPos)
  local Rt2 = mul(Rt, M(out.thigh))
  local K = H + mv(Rt2, pc)
  local Rc2 = mul(mul(Rt2, Lc), M(out.calf))
  local F = K + mv(Rc2, pf)
  local Rf2 = mul(mul(Rc2, Lf), M(out.foot))
  return K, Rc2, F, Rf2
end
local phase = 0
local plants = { left = {}, right = {} }
local lastPhase = { left = "planted", right = "planted" }
local lastDrop, maxDropJump, maxPenetration, maxFloat = nil, 0, 0, 0
local maxSkip = 0
local maxAbsDropFlat, stairFrames = 0, 0
local minRest, maxRest, restReasons = math.huge, -math.huge, {}
local idleBothSwing, nanFrames, maxBehind, restepLoops = 0, 0, 0, 0
local startLog = { left = {}, right = {} }
local lastStartCount = { left = 0, right = 0 }
local maxFootErr = 0
local replants, lastReason = 0, {}
resumeDropErr, wasHidden = nil, false
ledgeDrop, ledgeAnkleMin = -math.huge, math.huge
maxContactDepth, dropOffFrames = -math.huge, 0
for i = 1, 60 * 5 do
  now = now + dt; frame = frame + 1
  -- source movement: origin snaps to the highest ground under the 32x32 hull
  CURSPEED = (STOPAT and now > STOPAT and not (RESUMEAT and now > RESUMEAT)) and 0 or SPEED
  if TURN and STOPAT and now > STOPAT then facingYaw = facingYaw + 90 * dt end
  if TELEPORT_AT and not TELEPORTED and now > TELEPORT_AT then ply.pos.x = ply.pos.x + 300; TELEPORTED = true end
  ply.pos.x = ply.pos.x + CURSPEED * dt * DIR
  -- the hull rests on the highest solid under it, player clips included
  ply.pos.z = MaxOf(Phys, ply.pos.x - 16, ply.pos.x + 16)
  if CURSPEED > 0 then phase = phase + dt * CURSPEED / STRIDE * math.pi else phase = math.floor(phase / math.pi + 0.5) * math.pi + math.pi * 0.5 end
  -- not drawn (first person, out of view): the ik does not run, the player
  -- keeps moving
  local hidden = HIDE_AT and now > HIDE_AT and now <= HIDE_AT + (HIDE_FOR or 0.5)
  if hidden then lastDrop = nil; wasHidden = true; goto continue end
  local sk = skeleton(ply:GetPos(), phase)
  -- pelvis wobbles in the animation: yaw/roll change every frame
  local pelvisAng = Angle(3 * math.sin(phase), (DIR > 0 and 0 or 180) + 15 * math.sin(phase * 0.5), 6 * math.cos(phase))
  local pelvisPos = ply:GetPos() + Vector(0, 0, 38)
  sk.followers = {}
  for i, side in ipairs({"left", "right"}) do
    local fl = sk[side]
    local pos, ang = LocalToWorld(SHOE_OFFSET, SHOE_ROT, fl.footPos, fl.footAng)
    local f = bones.followers[i]
    if f.kind == "calf" then
      sk.followers[i] = { pos = pos, ang = ang, parentPos = fl.calfPos, parentAng = fl.calfAng }
    else
      sk.followers[i] = { pos = pos, ang = ang, parentPos = pelvisPos, parentAng = pelvisAng }
    end
  end
  local res = RT.Controller.Calculate(ply, sk, bones, P)
  LASTRES = res
  if wasHidden then
    -- a fresh start puts the body where it belongs right away, a stale state
    -- carries the old drop (+ the whole hidden walk read as a stair pop)
    resumeDropErr = math.abs(res.bodyDrop - res.debug.desiredDrop)
    wasHidden = false
  end
  for _, side in ipairs({"left", "right"}) do
    local reason = res[side].stepReason
    if reason == "replant_out_of_reach" and lastReason[side] ~= reason then replants = replants + 1 end
    lastReason[side] = reason
  end
  for _, side in ipairs({"left", "right"}) do
    local c = res[side].contact
    if c and c.hasHit then maxContactDepth = math.max(maxContactDepth, ply.pos.z - c.highestZ) end
    if c and c.dropOff then dropOffFrames = dropOffFrames + 1 end
  end
  if WORLD == "ledge" and STOPAT and now > STOPAT + 0.5 then
    ledgeDrop = math.max(ledgeDrop, res.bodyDrop)
    for _, side in ipairs({"left", "right"}) do
      if res[side].ankle then ledgeAnkleMin = math.min(ledgeAnkleMin, res[side].ankle.z) end
    end
  end
  local ms = MODELSCALE or 1
  for i, side in ipairs({"left", "right"}) do
    local f, fsk, out = bones.followers[i], sk.followers[i], res.followers[i]
    local K, Rc2, F, Rf2 = LegFK(sk, res, side, res.bodyDrop)
    -- what the engine would draw for the follower
    local finalPos, finalRot
    if f.kind == "calf" then
      local Rc = M(fsk.parentAng)
      local lp = mv(T(Rc), fsk.pos - fsk.parentPos)
      local lr = mul(T(Rc), M(fsk.ang))
      finalPos = K + mv(Rc2, lp + out.pos * ms)
      finalRot = mul(mul(Rc2, lr), M(out.ang))
    else
      local Rp = M(fsk.parentAng)
      local lp = mv(T(Rp), fsk.pos - fsk.parentPos)
      local lr = mul(T(Rp), M(fsk.ang))
      finalPos = fsk.parentPos + Vector(0, 0, -res.bodyDrop) + mv(Rp, lp + out.pos * ms)
      finalRot = mul(mul(Rp, lr), M(out.ang))
    end
    -- where it should be: same place relative to the foot the engine draws
    local expectedPos, expectedAng = LocalToWorld(SHOE_OFFSET, SHOE_ROT, F, toAng(Rf2))
    maxShoeErr = math.max(maxShoeErr, finalPos:Distance(expectedPos))
    maxShoeAngErr = math.max(maxShoeAngErr, angErr(toAng(finalRot), expectedAng))
  end
  local inStairs = res.debug.stairBlend >= 0.999
  if res.bodyDrop ~= res.bodyDrop then nanFrames = nanFrames + 1 end
  if now > 0.5 then
    minRest = math.min(minRest, res.debug.restHeight)
    maxRest = math.max(maxRest, res.debug.restHeight)
  end
  local rr = res.debug.restInfo and res.debug.restInfo.reason or "?"
  restReasons[rr] = (restReasons[rr] or 0) + 1
  if CURSPEED == 0 and res.left.procPhase == "swinging" and res.right.procPhase == "swinging" then idleBothSwing = idleBothSwing + 1 end
  for _, side in ipairs({"left", "right"}) do
    local leg = res[side]
    if leg.ankle ~= leg.ankle or (leg.ankle and leg.ankle.x ~= leg.ankle.x) then nanFrames = nanFrames + 1 end
    if inStairs and leg.procPhase == "planted" and leg.ankle then
      local dx, dy = leg.ankle.x - ply.pos.x, leg.ankle.y - ply.pos.y
      maxBehind = math.max(maxBehind, math.sqrt(dx * dx + dy * dy))
    end
    local starts = leg.stepStarts or {}
    if #starts ~= lastStartCount[side] or (starts[#starts] and starts[#starts] ~= startLog[side][#startLog[side]]) then
      if starts[#starts] then startLog[side][#startLog[side] + 1] = starts[#starts] end
      lastStartCount[side] = #starts
    end
  end
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
  if lastDrop and not res.debug.teleport then maxDropJump = math.max(maxDropJump, math.abs(bodyZ - lastDrop)) end
  if TRACEB and math.abs(bodyZ - (lastDrop or bodyZ)) > (BTH or 4) then print(string.format("BODY t=%.3f x=%.1f oz=%.0f drop=%.2f jump=%.1f bz=%.2f blend=%.2f L=%.1f R=%.1f", now, ply.pos.x, ply.pos.z, res.bodyDrop, res.debug.originJump, bodyZ, res.debug.stairBlend, res.lRequiredDrop, res.rRequiredDrop)) end
  lastDrop = bodyZ
  ::continue::
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
-- the same foot starting 3+ steps within 2 s while standing = a re-step loop
for _, side in ipairs({"left", "right"}) do
  local log = startLog[side]
  for i = 3, #log do
    if log[i] - log[i - 2] < 2 and STOPAT and log[i - 2] > STOPAT + 0.5 and not (RESUMEAT and log[i] > RESUMEAT) then restepLoops = restepLoops + 1 end
  end
end
local rl = {}
for k, v in pairs(restReasons) do rl[#rl + 1] = k .. "=" .. v end
table.sort(rl)
print(string.format("REST H range after 0.5 s: %.2f .. %.2f (anim rest %.1f, expected %s)  samples: %s", minRest, maxRest, 3, tostring(EXPECTED_REST), table.concat(rl, " ")))
RESULT = { nan = nanFrames, restepLoops = restepLoops, idleBothSwing = idleBothSwing, penetration = maxPenetration,
  float = maxFloat, maxSkip = maxSkip, sameFootTwice = skips, shoeErr = maxShoeErr, shoeAngErr = maxShoeAngErr,
  minRest = minRest, maxRest = maxRest, stairFrames = stairFrames, replants = replants,
  resumeDropErr = resumeDropErr, ledgeDrop = ledgeDrop, ledgeAnkleMin = ledgeAnkleMin, maxDropJump = maxDropJump,
  maxContactDepth = maxContactDepth, dropOffFrames = dropOffFrames }
print(string.format("deepest foot contact below the origin %.1f, frames with the foot over a drop-off %d", maxContactDepth, dropOffFrames))
if HIDE_AT then print(string.format("resumed after %.2f s hidden: |drop - desired| on the first frame %.2f, replants %d", HIDE_FOR or 0.5, resumeDropErr or -1, replants)) end
if WORLD == "ledge" then print(string.format("ledge %.0f deep: max body drop %.2f, lowest ankle z %.2f", LEDGE_DROP, ledgeDrop, ledgeAnkleMin)) end
print(string.format("nan frames %d  idle both-feet swings %d  restep loops %d  max planted foot distance %.1f (leg %.1f)", nanFrames, idleBothSwing, restepLoops, maxBehind, 39))
print(string.format("max shoe-to-foot error: %.4f  angle %.3f deg (followers %s, model scale %.2f)", maxShoeErr, maxShoeAngErr, FOLLOWER_KIND, MODELSCALE or 1))
print(string.format("world=%s dir=%d stair frames=%d  max |drop|=%.2f  max solver err=%.3f", tostring(WORLD), DIR, stairFrames, maxAbsDropFlat, maxFootErr))
print(string.format("max per-frame world body height change: %.2f (origin pops %d per step)", maxDropJump, RISE))
