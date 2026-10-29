dofile(ROOT .. "/tests/gmod_mock.lua")
function CreateClientConVar(name, def) local v = tonumber(def) or 0; return { GetFloat = function() return v end, GetBool = function() return v ~= 0 end, GetInt = function() return math.floor(v) end } end
function RunConsoleCommand() end
concommand = { Add = function() end }
function FrameNumber() return 1 end
function IsValid(e) return e ~= nil end
function LocalPlayer() return nil end
function Color() return {} end
MOVETYPE_NOCLIP, MOVETYPE_LADDER = 8, 9
dofile(ROOT .. "/lua/ik_foot/shared/sh_ik_foot_config.lua")
IKFoot.Runtime = nil
dofile(ROOT .. "/lua/ik_foot/client/runtime/cl_ik_foot_context.lua")
local RT = IKFoot.Runtime

local function makeModel(def)
  local names, parents = {}, {}
  for i, b in ipairs(def.bones) do names[i - 1] = b[1]; parents[i - 1] = b[2] end
  local byName = {}
  for i, n in pairs(names) do byName[n] = i end
  local ply = {}
  function ply:GetModel() return def.model end
  function ply:GetBoneCount() return #def.bones end
  function ply:GetBoneName(i) return names[i] end
  function ply:GetBoneParent(i) return parents[i] end
  function ply:LookupBone(n) return byName[n] end
  util = { GetModelMeshes = function()
    local verts = {}
    for _, w in ipairs(def.weighted) do
      verts[#verts + 1] = { pos = Vector(0, 0, w[2] or 10), weights = { { bone = byName[w[1]], weight = 1 } } }
    end
    return { { verticies = verts } }
  end }
  return ply, byName
end

local function show(title, ply, byName)
  local b = RT.GetIKBones(ply)
  local aux = {}
  for _, i in ipairs(b.auxRoots or {}) do aux[#aux + 1] = ply:GetBoneName(i) end
  print(string.format("%-34s valid=%s root=%s lean=%s legsL=%s/%s/%s  moved extra roots: [%s]", title, tostring(b.valid),
    b.root and ply:GetBoneName(b.root) or "-", b.leanBone and ply:GetBoneName(b.leanBone) or "-",
    b.lThigh and ply:GetBoneName(b.lThigh) or "-", b.lCalf and ply:GetBoneName(b.lCalf) or "-", b.lFoot and ply:GetBoneName(b.lFoot) or "-",
    table.concat(aux, ", ")))
  return b
end

local VB = "ValveBiped.Bip01_"
local legs = {
  { VB.."Pelvis", -2 }, -- parent filled below
}
-- model 1: bone 0 is a hair root (parent -1), pelvis is bone 1, plus helper and anm bones
local m1 = { model = "models/test/hairy.mdl", bones = {
  { "hair_root", -1 },          -- 0  skinned, must follow body
  { VB.."Pelvis", -1 },         -- 1  real body root
  { VB.."Spine", 1 },           -- 2
  { VB.."Spine1", 2 },          -- 3
  { VB.."L_Thigh", 1 },         -- 4
  { VB.."L_Calf", 4 },          -- 5
  { VB.."L_Foot", 5 },          -- 6
  { VB.."L_Toe0", 6 },          -- 7
  { VB.."R_Thigh", 1 },         -- 8
  { VB.."R_Calf", 8 },          -- 9
  { VB.."R_Foot", 9 },          -- 10
  { VB.."R_Toe0", 10 },         -- 11
  { "hair_01", 0 },             -- 12 child of hair root
  { "weapon_attach", -1 },      -- 13 unskinned helper root
  { "ik_target_r", -1 },        -- 14 helper root by name (even if skinned)
  { "anm_extra_root", -1 },     -- 15 bone from $includemodel, no verts
} , weighted = { { "hair_01", 60 }, { VB.."Spine1", 40 }, { VB.."L_Foot", -1.5 }, { VB.."R_Toe0", -1 }, { "ik_target_r", 5 } } }
local p1, n1 = makeModel(m1)
local b1 = show("hair root as bone 0", p1, n1)
print("   sole correction from mesh:", RT.GetSoleCorrection(b1.profile, 1))

-- model 2: plain citizen-like model, nothing extra
local m2 = { model = "models/test/plain.mdl", bones = {
  { VB.."Pelvis", -1 }, { VB.."Spine", 0 }, { VB.."Spine1", 1 },
  { VB.."L_Thigh", 0 }, { VB.."L_Calf", 3 }, { VB.."L_Foot", 4 },
  { VB.."R_Thigh", 0 }, { VB.."R_Calf", 6 }, { VB.."R_Foot", 7 },
}, weighted = { { VB.."Spine1" }, { VB.."L_Foot", 0 } } }
local p2, n2 = makeModel(m2)
show("plain model", p2, n2)

-- model 3: non-valve names with twist bones, a "root" above the pelvis
local m3 = { model = "models/test/mixamo.mdl", bones = {
  { "root", -1 }, { "mixamorig:Hips", 0 }, { "mixamorig:Spine1", 1 },
  { "upperleg_twist_l", 1 }, { "UpperLeg_L", 3 }, { "knee_l", 4 }, { "shin_twist_l", 5 }, { "Foot_L", 6 },
  { "UpperLeg_R", 1 }, { "knee_r", 8 }, { "Foot_R", 9 },
  { "Cape_root", -1 },
}, weighted = { { "Cape_root", 30 }, { "Foot_L", 0 } } }
local p3, n3 = makeModel(m3)
show("mixamo-ish names + twist + root", p3, n3)

-- model 4: broken (foot not under calf) must be rejected, not half-applied
local m4 = { model = "models/test/broken.mdl", bones = {
  { VB.."Pelvis", -1 }, { VB.."L_Thigh", 0 }, { VB.."L_Calf", 1 }, { VB.."L_Foot", 0 },
  { VB.."R_Thigh", 0 }, { VB.."R_Calf", 4 }, { VB.."R_Foot", 5 },
}, weighted = {} }
local p4, n4 = makeModel(m4)
show("broken hierarchy", p4, n4)
