-- bone set detection: body root, extra roots, foot followers and why every
-- other bone near the feet was rejected
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

local fails = 0
local function check(name, cond, info)
  if not cond then fails = fails + 1; print("FAIL", name, info or "") end
end

-- a box of 9 vertices around (x, y, z) with half extents, skinned to one bone
local function blob(name, x, y, z, hx, hy, hz)
  hx, hy, hz = hx or 1, hy or 1, hz or 1
  local list = { { name, x, y, z } }
  for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
    list[#list + 1] = { name, x + sx * hx, y + sy * hy, z + sz * hz }
  end end end
  return list
end

local modelId = 0
local function makeModel(def)
  modelId = modelId + 1
  local names, parents = {}, {}
  for i, b in ipairs(def.bones) do names[i - 1] = b[1]; parents[i - 1] = b[2] end
  local byName = {}
  for i, n in pairs(names) do byName[n] = i end
  local ply = {}
  function ply:GetModel() return "models/test/" .. modelId .. ".mdl" end
  function ply:GetBoneCount() return #def.bones end
  function ply:GetBoneName(i) return names[i] end
  function ply:GetBoneParent(i) return parents[i] end
  function ply:LookupBone(n) return byName[n] end
  function ply:GetBoneMatrix() return nil end
  util = { GetModelMeshes = function()
    local verts = {}
    for _, group in ipairs(def.mesh or {}) do
      for _, w in ipairs(group) do
        verts[#verts + 1] = { pos = Vector(w[2], w[3], w[4]), weights = { { bone = byName[w[1]], weight = 1 } } }
      end
    end
    return { { verticies = verts } }
  end }
  return ply
end

local function verdicts(ply, b)
  local out = {}
  for _, a in ipairs(b.followerAnalysis or {}) do out[a.name] = a.verdict end
  return out
end

local function followerByName(b, name)
  for _, f in ipairs(b.followers or {}) do if f.name == name then return f end end
end

local function show(title, ply, b)
  local fol, aux = {}, {}
  for _, f in ipairs(b.followers or {}) do fol[#fol + 1] = f.name .. "->" .. f.side .. "/" .. f.kind end
  for _, i in ipairs(b.auxRoots or {}) do aux[#aux + 1] = ply:GetBoneName(i) end
  print(string.format("%-38s valid=%-5s root=%-24s followers=[%s] extra roots=[%s]", title, tostring(b.valid),
    b.root and ply:GetBoneName(b.root) or "-", table.concat(fol, ", "), table.concat(aux, ", ")))
end

local VB = "ValveBiped.Bip01_"
local function legs(pelvisParent)
  return {
    { VB .. "Pelvis", pelvisParent or -1 }, { VB .. "Spine", 0 }, { VB .. "Spine1", 1 },
    { VB .. "L_Thigh", 0 }, { VB .. "L_Calf", 3 }, { VB .. "L_Foot", 4 }, { VB .. "L_Toe0", 5 },
    { VB .. "R_Thigh", 0 }, { VB .. "R_Calf", 7 }, { VB .. "R_Foot", 8 }, { VB .. "R_Toe0", 9 },
  }
end
local function bonesWith(extra)
  local list = legs()
  for _, b in ipairs(extra) do list[#list + 1] = b end
  return list
end
local function feetMesh()
  return { blob(VB .. "L_Foot", 2, 4, 2, 4, 1.5, 1.5), blob(VB .. "R_Foot", 2, -4, 2, 4, 1.5, 1.5),
    blob(VB .. "Spine1", 0, 0, 45, 5, 5, 5) }
end
local function meshWith(extra)
  local m = feetMesh()
  for _, g in ipairs(extra) do m[#m + 1] = g end
  return m
end

-- 1. shoes hanging off the pelvis (the case seen in game)
do
  local ply = makeModel({ bones = bonesWith({ { "shoe_L", 0 }, { "shoe_L_lace", 11 }, { "shoe_R", 0 } }),
    mesh = meshWith({ blob("shoe_L", 3, 4, 1.5, 4.5, 2, 1.5), blob("shoe_L_lace", 4, 4, 3.5, 1, 1, 0.5), blob("shoe_R", 3, -4, 1.5, 4.5, 2, 1.5) }) })
  local b = RT.GetIKBones(ply)
  show("shoes parented to pelvis", ply, b)
  local v = verdicts(ply, b)
  check("shoe_L follower", followerByName(b, "shoe_L") and followerByName(b, "shoe_L").kind == "body" and followerByName(b, "shoe_L").side == "left")
  check("shoe_R follower", followerByName(b, "shoe_R") and followerByName(b, "shoe_R").side == "right")
  check("lace nested", v["shoe_L_lace"] == "nested_follower", v["shoe_L_lace"])
  check("toe inherits foot", v[VB .. "L_Toe0"] == nil or v[VB .. "L_Toe0"] == "inherits_foot" or v[VB .. "L_Toe0"] == "chain_bone", v[VB .. "L_Toe0"])
end

-- 2. no vertices on the foot bones at all: centre comes from the lowest mesh region
do
  local ply = makeModel({ bones = bonesWith({ { "boot_L", 0 }, { "boot_R", 0 } }),
    mesh = { blob(VB .. "Spine1", 0, 0, 45, 5, 5, 5), blob("boot_L", 2, 4, 2, 4.5, 2, 2), blob("boot_R", 2, -4, 2, 4.5, 2, 2) } })
  local b = RT.GetIKBones(ply)
  show("foot bones without vertices", ply, b)
  check("centre source low region", b.footCentreSource.left == "mesh_low_region", b.footCentreSource.left)
  check("boot_L follower", followerByName(b, "boot_L") ~= nil)
  check("boot_R follower", followerByName(b, "boot_R") ~= nil)
end

-- 3. things that must NOT be caught
do
  local ply = makeModel({ bones = bonesWith({
      { "skirt_hem", 0 },            -- between the feet
      { "hair_long", 2 },            -- under spine1 -> under lean bone anyway
      { "coat_tail", 0 },            -- tall: from the knees to the floor behind
      { "ik_foot_target_L", 0 },     -- helper by name
      { VB .. "L_Foot_sock", 5 },    -- child of the foot: already follows
      { "ankle_ring_R", 8 },         -- child of the RIGHT calf but sits at the LEFT foot (bad weights)
    }),
    mesh = meshWith({
      blob("skirt_hem", 2, 0, 4, 6, 6, 1),
      blob("hair_long", -3, 0, 6, 2, 2, 2),
      blob("coat_tail", -3, 4, 14, 2, 2, 12),
      blob("ik_foot_target_L", 2, 4, 2, 1, 1, 1),
      blob(VB .. "L_Foot_sock", 1, 4, 4, 1.5, 1.5, 1.5),
      blob("ankle_ring_R", 0, 4, 4, 1, 1, 1),
    }) })
  local b = RT.GetIKBones(ply)
  show("false positive candidates", ply, b)
  local v = verdicts(ply, b)
  check("no followers", #b.followers == 0, #b.followers)
  check("skirt ambiguous", v["skirt_hem"] == "ambiguous_side", v["skirt_hem"])
  check("hair under lean bone", v["hair_long"] == "under_lean_bone", v["hair_long"])
  check("coat too tall or far", v["coat_tail"] == "too_tall" or v["coat_tail"] == "too_far", v["coat_tail"])
  check("helper rejected", v["ik_foot_target_L"] == "helper_name", v["ik_foot_target_L"])
  check("sock inherits foot", v[VB .. "L_Foot_sock"] == "inherits_foot", v[VB .. "L_Foot_sock"])
  check("ring other leg", v["ankle_ring_R"] == "other_leg", v["ankle_ring_R"])
end

-- 4. shoe parented to the calf (follows calf rotation, must get the foot's)
do
  local ply = makeModel({ bones = bonesWith({ { "shoe_L", 4 }, { "shoe_R", 8 } }),
    mesh = meshWith({ blob("shoe_L", 2.5, 4, 1.8, 4, 2, 1.5), blob("shoe_R", 2.5, -4, 1.8, 4, 2, 1.5) }) })
  local b = RT.GetIKBones(ply)
  show("shoes parented to calf", ply, b)
  local f = followerByName(b, "shoe_L")
  check("calf follower", f and f.kind == "calf", f and f.kind)
end

-- 5. shoe as its own root bone (model space), not doubled as an extra root
do
  local ply = makeModel({ bones = bonesWith({ { "shoe_L", -1 }, { "shoe_R", -1 } }),
    mesh = meshWith({ blob("shoe_L", 3, 4, 1.5, 4.5, 2, 1.5), blob("shoe_R", 3, -4, 1.5, 4.5, 2, 1.5) }) })
  local b = RT.GetIKBones(ply)
  show("shoes as root bones", ply, b)
  local f = followerByName(b, "shoe_L")
  check("model follower", f and f.kind == "model", f and f.kind)
  check("not an extra root", #b.auxRoots == 0, #b.auxRoots)
end

-- 6. earlier regression set: body root not bone 0, twist bones, broken chains
do
  local ply = makeModel({ bones = {
      { "hair_root", -1 }, { VB .. "Pelvis", -1 }, { VB .. "Spine", 1 }, { VB .. "Spine1", 2 },
      { VB .. "L_Thigh", 1 }, { VB .. "L_Calf", 4 }, { VB .. "L_Foot", 5 },
      { VB .. "R_Thigh", 1 }, { VB .. "R_Calf", 7 }, { VB .. "R_Foot", 8 },
      { "hair_01", 0 }, { "weapon_attach", -1 }, { "anm_extra_root", -1 },
    }, mesh = { blob("hair_01", 0, 0, 60), blob(VB .. "Spine1", 0, 0, 40), blob(VB .. "L_Foot", 2, 4, 1), blob(VB .. "R_Foot", 2, -4, 1) } })
  local b = RT.GetIKBones(ply)
  show("hair root as bone 0", ply, b)
  check("root is pelvis", ply:GetBoneName(b.root) == VB .. "Pelvis")
  check("hair root follows body", #b.auxRoots == 1 and ply:GetBoneName(b.auxRoots[1]) == "hair_root")
end
do
  local ply = makeModel({ bones = {
      { "root", -1 }, { "mixamorig:Hips", 0 }, { "mixamorig:Spine1", 1 },
      { "upperleg_twist_l", 1 }, { "UpperLeg_L", 3 }, { "knee_l", 4 }, { "shin_twist_l", 5 }, { "Foot_L", 6 },
      { "UpperLeg_R", 1 }, { "knee_r", 8 }, { "Foot_R", 9 },
    }, mesh = { blob("Foot_L", 2, 4, 1), blob("Foot_R", 2, -4, 1) } })
  local b = RT.GetIKBones(ply)
  show("mixamo names + twist", ply, b)
  check("chain found", b.valid and ply:GetBoneName(b.lThigh) == "UpperLeg_L" and ply:GetBoneName(b.lCalf) == "knee_l")
end
do
  local ply = makeModel({ bones = {
      { VB .. "Pelvis", -1 }, { VB .. "L_Thigh", 0 }, { VB .. "L_Calf", 1 }, { VB .. "L_Foot", 0 },
      { VB .. "R_Thigh", 0 }, { VB .. "R_Calf", 4 }, { VB .. "R_Foot", 5 },
    }, mesh = {} })
  local b = RT.GetIKBones(ply)
  show("broken hierarchy", ply, b)
  check("rejected", not b.valid)
end

-- a model without usable legs is analysed once, not every frame
do
  local ply = makeModel({ bones = { { "root", -1 }, { "spine", 0 }, { "head", 1 } }, mesh = {} })
  local lookups = 0
  local lookup = ply.LookupBone
  function ply:LookupBone(n) lookups = lookups + 1; return lookup(self, n) end
  local b1 = RT.GetIKBones(ply)
  local before = lookups
  local b2 = RT.GetIKBones(ply)
  check("model without legs: invalid", not b1.valid)
  check("model without legs: bone set kept between frames", b1 == b2 and lookups == before, lookups - before)
end

-- the bind pose reader (expected REST H) must never leak its hidden model,
-- also when the engine errors half way
do
  local made = {}
  ClientsideModel = function()
    local ent = { removed = false }
    function ent:SetNoDraw() end
    function ent:LookupSequence(n) return n == "reference" and 0 or -1 end
    function ent:ResetSequence() end
    function ent:SetCycle() end
    function ent:SetupBones() if BIND_FAIL then error("setup failed") end end
    function ent:LookupBone(n) return n:find("L_Foot", 1, true) and 1 or 2 end
    function ent:GetBoneMatrix(b) return { GetTranslation = function() return Vector(0, 0, b == 1 and 3.5 or 3.7) end } end
    function ent:GetPos() return Vector(0, 0, 0) end
    function ent:Remove() self.removed = true end
    made[#made + 1] = ent
    return ent
  end
  BIND_FAIL = true
  local b = RT.GetIKBones(makeModel({ bones = legs(), mesh = feetMesh() }))
  check("bind read error: hidden model removed", #made == 1 and made[1].removed, #made)
  check("bind read error: no expected rest", b.profile.bindAnkle == nil)
  BIND_FAIL = false
  local b2 = RT.GetIKBones(makeModel({ bones = legs(), mesh = feetMesh() }))
  local bind = b2.profile.bindAnkle
  check("bind read: hidden model removed", #made == 2 and made[2].removed)
  check("bind read: ankle heights", bind and math.abs(bind.left - 3.5) < 1e-6 and math.abs(bind.right - 3.7) < 1e-6)
  check("expected rest from bind pose", math.abs((RT.GetExpectedRestHeight(b2.profile, 2) or 0) - 7.2) < 1e-6, RT.GetExpectedRestHeight(b2.profile, 2))
  ClientsideModel = nil
  print("bind pose reader: removed after error", made[1].removed, "after success", made[2].removed)
end

BONES_FAILS = fails
print("bones test fails:", fails)
