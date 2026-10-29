dofile(ROOT .. "/tests/gmod_mock.lua")
dofile(ROOT.."/lua/ik_foot/client/runtime/ik_solver.lua")
local S = IKFoot.Runtime.Solver
local M, mul, T, mv, toAng = MOCK.M, MOCK.mul, MOCK.T, MOCK.mv, MOCK.toAng

-- frame with X along `dir`, Z along `hinge` (orthogonalised)
local function frame(dir, hinge)
  local x = dir:GetNormalized(); local z = (hinge - x*hinge:Dot(x)):GetNormalized(); local y = z:Cross(x)
  return toAng({{x.x,y.x,z.x},{x.y,y.y,z.y},{x.z,y.z,z.z}})
end

-- forward kinematics with bone-local post-multiplied manipulations
local function FK(chain, mt, mc, mf)
  local Rt, Rc, Rf = M(chain.thighAng), M(chain.calfAng), M(chain.footAng)
  local Lc = mul(T(Rt), Rc); local Lf = mul(T(Rc), Rf)
  local pc = mv(T(Rt), chain.calfPos - chain.thighPos)
  local pf = mv(T(Rc), chain.footPos - chain.calfPos)
  local Rt2 = mul(Rt, M(mt)); local K = chain.thighPos + mv(Rt2, pc)
  local Rc2 = mul(mul(Rt2, Lc), M(mc)); local F = K + mv(Rc2, pf)
  local Rf2 = mul(mul(Rc2, Lf), M(mf))
  return K, F, toAng(Rf2)
end

local function angErr(a, b)
  local fa, fb = a:Forward(), b:Forward(); local ua, ub = a:Up(), b:Up()
  return math.deg(math.acos(math.min(1, fa:Dot(fb)))) + math.deg(math.acos(math.min(1, ua:Dot(ub))))
end

local fails = 0
local function check(name, cond, info) if not cond then fails = fails + 1 print("FAIL", name, info or "") end end

math.randomseed(7)
local worst = 0
for trial = 1, 400 do
  local yaw = math.random() * 360
  local body = Angle(0, yaw, 0)
  local fwd, right = body:Forward(), body:Right()
  local H = Vector(math.random()*100, math.random()*100, 38)
  local kneeFwd = 1 + math.random() * 4
  local K = H + fwd * kneeFwd - Vector(0,0,19 + math.random())
  local F = K - fwd * (kneeFwd * 0.6) - Vector(0,0,18 + math.random())
  -- random hinge sign to prove we dont depend on the rig's axis convention
  local hingeSign = math.random() < 0.5 and 1 or -1
  local chain = {
    thighPos = H, calfPos = K, footPos = F,
    thighAng = frame(K - H, right * hingeSign),
    calfAng = frame(F - K, right * hingeSign),
    footAng = frame(fwd - Vector(0,0,0.4), right * -hingeSign),
  }
  local drop = math.random() * 6
  local target = F + Vector(0, 0, -drop + (math.random() * 14 - 4)) + fwd * (math.random() * 8 - 4)
  local footTarget = Angle(chain.footAng); footTarget:RotateAroundAxis(right, math.random()*20-10)
  local res = S.SolveLeg(chain, drop, target, footTarget, fwd)
  check("solved", res ~= nil)
  if res then
    local shifted = { thighPos = H - Vector(0,0,drop), calfPos = K - Vector(0,0,drop), footPos = F - Vector(0,0,drop),
      thighAng = chain.thighAng, calfAng = chain.calfAng, footAng = chain.footAng }
    local K2, F2, Af = FK(shifted, res.thigh, res.calf, res.foot)
    local e = F2:Distance(res.ankle)
    worst = math.max(worst, e)
    check("fk matches solver ankle", e < 0.01, e)
    if res.reached then check("reached target", F2:Distance(target) < 0.5, F2:Distance(target)) end
    check("foot orientation", angErr(Af, footTarget) < 0.05, angErr(Af, footTarget))
    -- knee must stay in front of the hip-ankle line (no backwards knees)
    local hf = (F2 - shifted.thighPos):GetNormalized()
    local kh = K2 - shifted.thighPos
    local off = kh - hf * kh:Dot(hf)
    check("knee forward", off:Dot(fwd) > 0, off:Dot(fwd))
    check("bone lengths kept", math.abs(K2:Distance(F2) - K:Distance(F)) < 0.01 and math.abs(K2:Distance(shifted.thighPos) - K:Distance(H)) < 0.01)
  end
end

-- drop limits agree with reachability
local chain = { thighPos = Vector(0,0,38), calfPos = Vector(2,0,19), footPos = Vector(0,0,1),
  thighAng = Angle(), calfAng = Angle(), footAng = Angle() }
local target = Vector(0, 0, -6)
local minD = S.DropLimits(chain, target)
local a = chain.thighPos:Distance(chain.calfPos) + chain.calfPos:Distance(chain.footPos)
check("drop limit reach", math.abs((chain.thighPos.z - minD) - target.z - a * 0.999) < 0.01, minD)
print(string.format("trials done, worst fk error %.5f, fails %d", worst, fails))
