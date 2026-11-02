-- bone manipulation layer vs pac3's deferred bone api
dofile(ROOT .. "/tests/gmod_mock.lua")
function CreateClientConVar(name, def) local v = tonumber(def) or 0; return { GetFloat = function() return v end, GetBool = function() return v ~= 0 end, GetInt = function() return math.floor(v) end } end
function RunConsoleCommand() end
concommand = { Add = function() end }
function FrameNumber() return 1 end
function IsValid(e) return e ~= nil end
function LocalPlayer() return nil end
function Color() return {} end
istable = function(t) return type(t) == "table" end
isfunction = function(f) return type(f) == "function" end
dofile(ROOT .. "/lua/ik_foot/shared/sh_ik_foot_config.lua")
IKFoot.Runtime = nil
dofile(ROOT .. "/lua/ik_foot/client/runtime/cl_ik_foot_context.lua")
local RT = IKFoot.Runtime

local function makeEnt()
  local e = { pos = {}, ang = {} }
  function e:ManipulateBonePosition(b, v) self.pos[b] = Vector(v) end
  function e:GetManipulateBonePosition(b) return Vector(self.pos[b] or Vector()) end
  function e:ManipulateBoneAngles(b, a) self.ang[b] = Angle(a) end
  function e:GetManipulateBoneAngles(b) return Angle(self.ang[b] or Angle()) end
  return e
end

local fails = 0
local function check(name, cond, info) if not cond then fails = fails + 1; print("FAIL", name, info or "") end end

for _, withPac in ipairs({ false, true }) do
  local ply = makeEnt()
  local PART = Vector(0, 0, 2) -- a pac bone part adding +2 on the same bone
  if withPac then
    -- same as pac3's bones.lua: with parts, the value is only stored
    pac = { IsEnabled = function() return true end }
    function pac.ManipulateBonePosition(e, id, v)
      e.pac_boneanim = e.pac_boneanim or { positions = {}, angles = {} }
      e.pac_boneanim.positions[id] = v
      if not e.pac_has_parts then e:ManipulateBonePosition(id, v) end
    end
    function pac.ManipulateBoneAngles(e, id, v)
      e.pac_boneanim = e.pac_boneanim or { positions = {}, angles = {} }
      e.pac_boneanim.angles[id] = v
      if not e.pac_has_parts then e:ManipulateBoneAngles(id, v) end
    end
    ply.pac_has_parts = true
  else
    pac = nil
  end
  local function pacReset() -- what pac does in PreDrawOpaqueRenderables
    if not withPac then return end
    local store = ply.pac_boneanim
    ply:ManipulateBonePosition(0, (store and store.positions[0] or Vector()) + PART)
  end
  local function animPose() -- what SetupBones "sees": anim (0) + current manipulation
    return ply:GetManipulateBonePosition(0).z
  end
  local partZ = withPac and 2 or 0
  local drift = 0
  for frame = 1, 120 do
    pacReset()
    RT.ApplyBlendedBonePosition(ply, 0, Vector()) -- strip
    local clean = animPose()
    drift = math.max(drift, math.abs(clean - partZ))
    local want = -10 - math.sin(frame * 0.3) * 5
    RT.ApplyBlendedBonePosition(ply, 0, Vector(0, 0, want))
    local drawn = animPose()
    check("drawn this frame", math.abs(drawn - (partZ + want)) < 1e-6, drawn)
  end
  check("clean read never contains our offset", drift < 1e-6, drift)
  -- another addon overwrites the bone: we must not subtract our offset from it
  pacReset()
  if withPac then ply.pac_boneanim = ply.pac_boneanim or { positions = {}, angles = {} }; ply.pac_boneanim.positions[0] = Vector(0, 0, 7) else ply:ManipulateBonePosition(0, Vector(0, 0, 7)) end
  pacReset()
  RT.ApplyBlendedBonePosition(ply, 0, Vector())
  check("foreign value kept", math.abs(animPose() - (7 + partZ)) < 1e-6, animPose())
  print(string.format("pac=%s  max drift of the clean read: %.6f", tostring(withPac), drift))
end
PAC_FAILS = fails
print("pac test fails:", fails)
