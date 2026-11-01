-- settings menu smoke test on a mock of derma: builds the window, every
-- page, the search results and the spawn menu panel, then paints, lays out
-- and clicks everything. drawing checks its arguments (a boolean where a
-- colour belongs is an error), unknown panel methods are listed so they can
-- be checked against the real derma api
dofile(ROOT .. "/tests/gmod_mock.lua")

local fails = 0
local function check(name, cond, info)
  if not cond then fails = fails + 1; print("FAIL", name, info or "") end
end

-- ---------------------------------------------------------------- globals
function isnumber(v) return type(v) == "number" end
function isbool(v) return type(v) == "boolean" end
function isstring(v) return type(v) == "string" end
function istable(v) return type(v) == "table" end
function tobool(v) return not (v == nil or v == false or v == 0 or v == "0" or v == "" or v == "false") end
function Lerp(t, a, b) return a + (b - a) * t end
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a or 255, __color = true } end
string.Trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
string.GetFileFromFilename = function(p) return p:match("([^/]+)$") end
local now = 1
function RealTime() return now end
function FrameTime() return 1 / 60 end
function FrameNumber() return 100 end
function ScrW() return 1920 end
function ScrH() return 1080 end
MOUSE_LEFT = 107
gui = { MouseX = function() return 500 end, MouseY = function() return 300 end }
NOTIFY_GENERIC, NOTIFY_ERROR = 0, 1
TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP, TEXT_ALIGN_BOTTOM = 0, 1, 2, 3, 4
TOP, BOTTOM, LEFT, RIGHT, FILL = 1, 2, 3, 4, 5

local function isColor(c) return type(c) == "table" and c.r and c.g and c.b end
local function num(v) return type(v) == "number" and v == v end

draw = {
  RoundedBox = function(r, x, y, w, h, col)
    check("RoundedBox numbers", num(r) and num(x) and num(y) and num(w) and num(h), debug.traceback())
    check("RoundedBox colour", isColor(col), debug.traceback())
  end,
  RoundedBoxEx = function(r, x, y, w, h, col) check("RoundedBoxEx colour", isColor(col), debug.traceback()) end,
  SimpleText = function(text, font, x, y, col)
    check("SimpleText text", type(text) == "string" or type(text) == "number", debug.traceback())
    check("SimpleText font", type(font) == "string", debug.traceback())
    check("SimpleText colour", col == nil or isColor(col), debug.traceback())
  end,
}
local FONTS = {}
surface = {
  CreateFont = function(name) FONTS[name] = true end,
  SetFont = function(name) check("font exists " .. tostring(name), FONTS[name] or name == "DermaDefault", debug.traceback()) end,
  GetTextSize = function(text) return #tostring(text) * 7, 14 end,
  SetMaterial = function(m) check("material", type(m) == "table") end,
  SetDrawColor = function(r) check("draw colour", isColor(r) or num(r), debug.traceback()) end,
  DrawTexturedRect = function() end,
  DrawLine = function() end,
  DrawOutlinedRect = function() end,
  PlaySound = function() end,
}
function Material(path) return { path = path } end
local NOTES = {}
notification = { AddLegacy = function(text) NOTES[#NOTES + 1] = text end }

local cvars, COMMANDS = {}, {}
local function cvarObj(name)
  return {
    GetFloat = function() return tonumber(cvars[name]) or 0 end,
    GetBool = function() return (tonumber(cvars[name]) or 0) ~= 0 end,
    GetInt = function() return math.floor(tonumber(cvars[name]) or 0) end,
  }
end
function GetConVar(name) return cvars[name] ~= nil and cvarObj(name) or nil end
function RunConsoleCommand(name, ...)
  local args = { ... }
  COMMANDS[#COMMANDS + 1] = name .. (#args > 0 and (" " .. table.concat(args, " ")) or "")
  if cvars[name] ~= nil then cvars[name] = tostring(args[1]) end
end

local STORE, stored = {}, 0
file = {
  Exists = function(name) return STORE[name] ~= nil end,
  Read = function(name) return STORE[name] end,
  Write = function(name, data) STORE[name] = data end,
}
local JSON = {}
util = {
  TableToJSON = function(t) stored = stored + 1; JSON["json#" .. stored] = t; return "json#" .. stored end,
  JSONToTable = function(s) return JSON[s] end,
}

local NETS, HOOKS, CONCMDS = {}, {}, {}
net = { Receive = function(name, fn) NETS[name] = fn end }
hook = { Add = function(event, name, fn) HOOKS[event] = fn end }
concommand = { Add = function(name, fn) CONCMDS[name] = fn end }
include = function() end

-- ---------------------------------------------------------------- derma
local KNOWN = {}
for _, m in ipairs({ "SetSize", "SetPos", "GetWide", "GetTall", "SetTall", "SetWide", "Dock", "DockMargin", "DockPadding",
  "GetDockPadding", "GetDockMargin", "Center", "SetTitle", "ShowCloseButton", "SetDraggable", "SetSizable", "MakePopup",
  "Remove", "Close", "SetText", "SetFont", "SetTextColor", "SetWrap", "SetContentAlignment", "SetTooltip", "SetVisible",
  "IsVisible", "IsHovered", "IsChildHovered", "IsDown", "GetDisabled", "SetMin", "SetMax", "SetDecimals", "SetConVar",
  "SetValue", "GetValue", "SetUpdateOnType", "HasFocus", "DrawTextEntryText", "Clear", "InvalidateLayout", "GetVBar",
  "GetChildren", "GetSlideX", "IsValid", "SetMouseInputEnabled", "GetPos", "MouseCapture", "KillFocus" }) do KNOWN[m] = true end
local UNKNOWN = {}
local ALL = {}

local Panel = {}
Panel.__index = function(t, k)
  local m = rawget(Panel, k)
  if m then return m end
  if type(k) == "string" and k:match("^%u") then
    UNKNOWN[k] = true
    return function() end
  end
  return nil
end
function Panel:SetSize(w, h) self.w, self.h = w, h end
function Panel:SetPos(x, y) self.x, self.y = x, y end
function Panel:GetWide() return self.w or 400 end
function Panel:GetTall() return self.h or 24 end
function Panel:SetTall(h) self.h = h end
function Panel:SetWide(w) self.w = w end
function Panel:Dock(d) self.dock = d end
function Panel:DockMargin(l, t, r, b) self.margin = { l, t, r, b } end
function Panel:DockPadding(l, t, r, b) self.padding = { l, t, r, b } end
function Panel:GetDockPadding() local p = self.padding or { 0, 0, 0, 0 } return p[1], p[2], p[3], p[4] end
function Panel:GetDockMargin() local p = self.margin or { 0, 0, 0, 0 } return p[1], p[2], p[3], p[4] end
function Panel:Center() end
function Panel:SetTitle() end
function Panel:ShowCloseButton() end
function Panel:SetDraggable() end
function Panel:SetSizable() end
function Panel:MakePopup() end
-- removing a panel removes everything inside it
local function MarkRemoved(p)
  p.removed = true
  for _, c in ipairs(p.children or {}) do MarkRemoved(c) end
  if p.canvas then MarkRemoved(p.canvas) end
end
function Panel:Remove() MarkRemoved(self) end
function Panel:Close() MarkRemoved(self) end
function Panel:SetText(t) check("SetText string", type(t) == "string", debug.traceback()) self.text = t end
function Panel:SetFont(f) check("SetFont exists " .. tostring(f), FONTS[f], debug.traceback()) end
function Panel:SetTextColor(c) check("SetTextColor colour", isColor(c), debug.traceback()) end
function Panel:SetWrap() end
function Panel:SetContentAlignment() end
function Panel:SetTooltip(t) check("SetTooltip string", type(t) == "string", debug.traceback()) end
function Panel:SetVisible(v) self.hidden = not v end
function Panel:IsVisible() return not self.hidden end
function Panel:IsHovered() return HOVER == true end
function Panel:IsChildHovered() return false end
function Panel:IsDown() return false end
function Panel:GetDisabled() return false end
function Panel:SetMin(v) check("SetMin number", num(v)) end
function Panel:SetMax(v) check("SetMax number", num(v)) end
function Panel:SetDecimals(v) check("SetDecimals number", num(v)) end
function Panel:SetConVar(name) check("SetConVar exists " .. tostring(name), cvars[name] ~= nil) self.convar = name end
function Panel:SetValue(v) self.value = v end
function Panel:GetValue() return self.value or "" end
function Panel:SetUpdateOnType() end
function Panel:HasFocus() return false end
function Panel:DrawTextEntryText() end
function Panel:Clear()
  local list = self.children
  for _, c in ipairs(list) do MarkRemoved(c) end
  for k in pairs(list) do list[k] = nil end
end
function Panel:InvalidateLayout() end
function Panel:GetVBar() return self.vbar end
function Panel:GetChildren()
  local out = {}
  for _, c in ipairs(self.children or {}) do if not c.removed then out[#out + 1] = c end end
  return out
end
function Panel:GetSlideX() return 0.4 end
function Panel:GetPos() return self.x or 0, self.y or 0 end
function Panel:MouseCapture() end
function Panel:KillFocus() end
function Panel:IsValid() return not self.removed end

local function NewPanel(class, parent)
  local p = setmetatable({ class = class, children = {} }, Panel)
  ALL[#ALL + 1] = p
  if parent then
    local host = parent.canvas or parent
    host.children[#host.children + 1] = p
    p.parent = host
  end
  if class == "DNumSlider" then
    p.Label = NewPanel("DLabel", p)
    p.TextArea = NewPanel("DTextEntry", p)
    p.Slider = NewPanel("DSlider", p)
    p.Slider.Knob = NewPanel("DButton", p.Slider)
  elseif class == "DScrollPanel" then
    p.canvas = NewPanel("DPanel", nil)
    p.children = p.canvas.children
    p.vbar = NewPanel("DVScrollBar", p)
    p.vbar.btnUp, p.vbar.btnDown, p.vbar.btnGrip = NewPanel("DButton", p.vbar), NewPanel("DButton", p.vbar), NewPanel("DButton", p.vbar)
  end
  return p
end
function IsValid(p) return p ~= nil and p ~= false and (type(p) ~= "table" or not p.removed) end
vgui = { Create = function(class, parent) return NewPanel(class, parent) end }

local FORM = {}
spawnmenu = { AddToolMenuOption = function(tab, cat, class, name, cmd, config, fn) FORM.builder = fn end }

-- ---------------------------------------------------------------- addon
dofile(ROOT .. "/lua/ik_foot/shared/sh_ik_foot_config.lua")
for _, e in ipairs(IKFoot.Config.entries) do
  cvars[e.cvar] = tostring(e.type == "bool" and (e.default and 1 or 0) or e.default)
end
cvars.ik_foot_others, cvars.ik_foot_max_distance = "1", "3000"
cvars.ik_foot_diag_history, cvars.ik_foot_diag_print = "1", "1"

local ply = {
  IKBones = { valid = true, boneCount = 60, followers = { {}, {} }, auxRoots = { 1 } },
  IKResultFrame = 100,
  IKResult = { bodyDrop = 2.5, debug = { restInfo = { value = 3.1, expected = 3.0 }, dropLimiter = "stair_line",
    stairMode = true, stairBlend = 1, treadsPerStep = 1, measuredLeg = 39, modelScale = 0.87, velocity2D = 90 } },
}
function ply:GetModel() return "models/player/kleiner.mdl" end
function ply:Alive() return true end
function LocalPlayer() return ply end
IKFoot.Runtime = { CanManipulateBones = function() return true end,
  Diag = { events = { { kind = "replant", side = "left", t = 0.5, t_last = 0.6 } }, capture = { stopAt = 5 } } }
local measured, autoApplied, hardReset = 0, 0, 0
IKFoot.MeasureModel = function() measured = measured + 1
  return { leg_length = 0 }, nil, { model = "models/player/kleiner.mdl", legLength = 39, upperLegLength = 19.5,
    lowerLegLength = 19.5, scale = 0.87, soleOffset = 0.4, boneCount = 60, followerCount = 2, auxRootCount = 1, rootBone = "pelvis" } end
IKFoot.AutoApplyModelSettings = function() autoApplied = autoApplied + 1 end
IKFoot.HardReset = function() hardReset = hardReset + 1 end

local ok, err = pcall(dofile, ROOT .. "/lua/autorun/client/cl_ik_foot_gui.lua")
check("gui file loads", ok, err)

-- every setting is reachable from some page
local placed = {}
for _, page in ipairs(IKFoot.MenuPages or {}) do
  for _, key in ipairs(page.keys or {}) do placed[key] = true end
end
for _, key in ipairs({ "enabled", "stair_stepper", "lean_enabled", "auto_model_detect", "debug" }) do placed[key] = true end
for _, e in ipairs(IKFoot.Config.entries) do
  check("setting on a page: " .. e.key, placed[e.key])
  check("setting has a label: " .. e.key, e.label and e.label ~= e.desc)
  check("setting has help: " .. e.key, e.help and #e.help > 10)
end

-- paint, lay out and think every live panel (several passes: hover on/off)
local function Exercise()
  for pass = 1, 2 do
    HOVER = pass == 2
    for _, p in ipairs(ALL) do
      if not p.removed then
        local w, h = p:GetWide(), p:GetTall()
        for _, fn in ipairs({ "PerformLayout", "Think", "Paint" }) do
          local f = rawget(p, fn)
          if f then
            local ok2, e2 = pcall(f, p, w, h)
            check(p.class .. ":" .. fn, ok2, e2)
          end
        end
      end
    end
  end
  HOVER = false
  now = now + 1
end

local function Buttons()
  local out = {}
  for _, p in ipairs(ALL) do
    if not p.removed and p.class == "DButton" and rawget(p, "DoClick") then out[#out + 1] = p end
  end
  return out
end

local function ran(prefix)
  for _, c in ipairs(COMMANDS) do if c:sub(1, #prefix) == prefix then return true end end
  return false
end

local frame
ok, err = pcall(function() frame = IKFoot.OpenMenu() end)
check("menu opens", ok and frame, err)
Exercise()
for _, p in ipairs(ALL) do
  if p.class == "DPanel" and p.h == 58 then
    p:OnMousePressed(MOUSE_LEFT)
    p:Think()
    p:OnMouseReleased(MOUSE_LEFT)
    check("window dragged by its header", frame.x ~= nil, tostring(frame.x))
  end
end

-- the sidebar: one button per page
local side
for _, p in ipairs(ALL) do
  if p.class == "DPanel" and p.w == 196 then side = p end
end
check("sidebar found", side)
local navs = side and side:GetChildren() or {}
check("one nav button per page", #navs == #(IKFoot.MenuPages or {}), #navs)

local header
for _, p in ipairs(ALL) do
  if p.class == "DPanel" and p.h == 58 then header = p end
end
check("header found", header)

for i, nav in ipairs(navs) do
  ok, err = pcall(nav.DoClick, nav)
  check("open page " .. i, ok, err)
  Exercise()
  -- click everything on the page except navigation and the close button
  -- (a click can rebuild the page: skip what it removed)
  for _, b in ipairs(Buttons()) do
    if not b.removed and not b.hidden and b.parent ~= side and b.parent ~= header then
      local ok3, e3 = pcall(b.DoClick, b)
      check("click on page " .. i, ok3, e3)
    end
  end
  if i == 1 then
    -- quick page: the style tiles come last, "Grounded" was clicked last
    check("style tile applies its values", cvars.ik_foot_rotation_scale == "1" and cvars.ik_foot_extra_body_drop_uneven == "1.8",
      tostring(cvars.ik_foot_rotation_scale))
    check("debug level buttons", ran("ik_foot_debug 2") and ran("ik_foot_debug 0"))
  end
  Exercise()
end

check("diag report button", ran("ik_foot_diag"))
check("dump button", ran("ik_foot_dump"))
check("capture button", ran("ik_foot_capture 10"))
check("capture detail button", ran("ik_foot_capture 10 detail"))
check("capture stop button", ran("ik_foot_capture_stop"))
check("measure button", measured > 0)
check("re-detect button", autoApplied > 0)
check("reset character button", hardReset > 0)
check("notifications shown", #NOTES > 0)

-- the stairs page: its one toggle flips the stepper on and off, a changed
-- slider value shows a reset button that brings back the default
navs[4]:DoClick()
cvars.ik_foot_stair_stepper = "1"
cvars.ik_foot_stair_step_lift = "7"
Exercise()
local toggles, resets = {}, {}
for _, b in ipairs(Buttons()) do
  if not b.removed and rawget(b, "anim") ~= nil then toggles[#toggles + 1] = b end
  if not b.removed and not b.hidden and b.w == 22 and b.h == 22 then resets[#resets + 1] = b end
end
check("stairs page has one toggle", #toggles == 1, #toggles)
if toggles[1] then
  toggles[1]:DoClick()
  check("toggle turns the stepper off", cvars.ik_foot_stair_stepper == "0", cvars.ik_foot_stair_stepper)
  toggles[1]:DoClick()
  check("toggle turns it back on", cvars.ik_foot_stair_stepper == "1", cvars.ik_foot_stair_stepper)
end
check("one reset button for the changed value", #resets == 1, #resets)
if resets[1] then
  resets[1]:DoClick()
  check("reset brings back the default", cvars.ik_foot_stair_step_lift == "3", cvars.ik_foot_stair_step_lift)
end
Exercise()

-- styles: applying one makes it the current one
local styles = IKFoot.MenuStyles or {}
check("styles defined", #styles >= 3)

-- search shows matching settings only
local search
for _, p in ipairs(ALL) do
  if not p.removed and p.class == "DTextEntry" and p.placeholder == "Search settings..." then search = p end
end
check("search box", search)
if search then
  search:SetValue("stair")
  ok, err = pcall(search.OnValueChange, search)
  check("search runs", ok, err)
  Exercise()
  local rows = 0
  for _, p in ipairs(ALL) do
    if not p.removed and p.class == "DPanel" and p.h and (p.h == 64 or p.h == 92) then rows = rows + 1 end
  end
  check("search finds the stair settings", rows >= 7, rows)
  search:SetValue("zzzz-nothing")
  search.OnValueChange(search)
  Exercise()
  search:SetValue("")
  search.OnValueChange(search)
end

-- presets: save, load, delete through the page
cvars.ik_foot_smoothing = "33"
local presetsNav = navs[8]
if presetsNav then
  presetsNav:DoClick()
  local name
  for _, p in ipairs(ALL) do
    if not p.removed and p.class == "DTextEntry" and p.placeholder == "Preset name..." then name = p end
  end
  check("preset name box", name)
  if name then
    name:SetValue("mine")
    name.OnEnter(name)
    check("preset saved", STORE["ik_foot_presets.txt"] ~= nil)
    local saved = JSON[STORE["ik_foot_presets.txt"]]
    check("preset holds the value", saved and saved.mine and saved.mine.ik_foot_smoothing == 33)
  end
end

-- spawn menu panel
local form = setmetatable({}, { __index = function(_, k) return function() return NewPanel("DButton") end end })
ok, err = pcall(HOOKS.PopulateToolMenu)
check("spawn menu hook", ok, err)
ok, err = pcall(FORM.builder or function() error("no builder") end, form)
check("spawn menu panel", ok, err)

check("open command", CONCMDS.ik_foot_menu ~= nil)
check("open net message", NETS.IKFoot_OpenMenu ~= nil)

local unknown = {}
for k in pairs(UNKNOWN) do unknown[#unknown + 1] = k end
table.sort(unknown)
print("panel methods outside the mock's list: " .. (#unknown > 0 and table.concat(unknown, ", ") or "none"))
print("gui test fails:", fails)
GUI_FAILS = fails
GUI_UNKNOWN = table.concat(unknown, ",")
