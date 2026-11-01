if SERVER then return end

if not IKFoot or not IKFoot.Config then
	include("ik_foot/shared/sh_ik_foot_config.lua")
end

if not IKFoot or not IKFoot.Config then return end

-- =====================================================================
-- settings menu: ik_foot_menu, !ikfoot / /ikfoot, spawn menu > Utilities
-- =====================================================================
-- every control reads its cvar when it is drawn, so the menu always shows
-- the current values (console, presets, auto config) without refreshing

local OPEN_MENU_NET = "IKFoot_OpenMenu"
local PRESET_FILE = "ik_foot_presets.txt"
local ENTRIES = IKFoot.Config.entries
local BY_KEY = IKFoot.Config.byKey

local C = {
	bg = Color(17, 19, 24),
	header = Color(22, 25, 31),
	side = Color(22, 25, 31),
	card = Color(28, 32, 40),
	row = Color(34, 39, 48),
	rowHover = Color(40, 46, 57),
	line = Color(54, 61, 75),
	lineHover = Color(66, 74, 90),
	input = Color(22, 25, 31),
	text = Color(233, 237, 243),
	muted = Color(146, 156, 173),
	accent = Color(86, 164, 255),
	accentSoft = Color(86, 164, 255, 38),
	white = Color(255, 255, 255),
	knob = Color(222, 228, 238),
	good = Color(78, 201, 120),
	warn = Color(240, 172, 64),
	bad = Color(232, 84, 84),
	off = Color(120, 128, 142),
}

surface.CreateFont("IKFoot.Title", { font = "Roboto", size = 22, weight = 700, extended = true })
surface.CreateFont("IKFoot.H2", { font = "Roboto", size = 17, weight = 700, extended = true })
surface.CreateFont("IKFoot.Body", { font = "Roboto", size = 15, weight = 600, extended = true })
surface.CreateFont("IKFoot.Small", { font = "Roboto", size = 13, weight = 500, extended = true })
surface.CreateFont("IKFoot.Mono", { font = "Courier New", size = 14, weight = 600, extended = true })

local function Runtime() return IKFoot.Runtime end

-- invisible container (Paint = nil would fall back to the skin's background)
local function NoPaint() end

local function LerpColor(t, a, b)
	return Color(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
end

local materials = {}
local function Icon(path)
	materials[path] = materials[path] or Material(path)
	return materials[path]
end

local function Notify(text, kind)
	notification.AddLegacy("[IK Foot] " .. text, kind or NOTIFY_GENERIC, 3)
	surface.PlaySound("garrysmod/ui_click.wav")
end

-- ---------------------------------------------------------------------
-- settings: config entries plus a few client-only preferences
-- ---------------------------------------------------------------------

local CLIENT_SPECS = {
	others = { cvar = "ik_foot_others", type = "bool", default = true,
		label = "IK on other players", help = "Run the foot IK on other players too. Off saves the most time on full servers." },
	max_distance = { cvar = "ik_foot_max_distance", type = "float", default = 3000, min = 300, max = 10000, decimals = 0,
		label = "IK distance for other players", help = "Players further away than this keep their plain animation." },
	diag_history = { cvar = "ik_foot_diag_history", type = "bool", default = true,
		label = "Keep diagnostic history", help = "Keeps the last ~10 s of your IK data for ik_foot_dump. Cheap, your character only." },
	diag_print = { cvar = "ik_foot_diag_print", type = "bool", default = true,
		label = "Print events to the console", help = "While the overlay is on or a recording runs, unusual events are printed (rate limited)." },
}

local function CvarValue(spec)
	local cv = GetConVar(spec.cvar)
	if not cv then return nil end
	if spec.type == "bool" then return cv:GetBool() and 1 or 0 end
	return cv:GetFloat()
end

local function DefaultValue(spec)
	if spec.type == "bool" then return spec.default and 1 or 0 end
	return tonumber(spec.default) or 0
end

local function IsDefault(spec)
	local value = CvarValue(spec)
	if value == nil then return true end
	return math.abs(value - DefaultValue(spec)) <= 0.5 * 10 ^ -(spec.decimals or 2)
end

local function SetValue(spec, value)
	if spec.type == "bool" then
		RunConsoleCommand(spec.cvar, value ~= 0 and "1" or "0")
	else
		RunConsoleCommand(spec.cvar, tostring(value))
	end
end

local function FormatValue(spec, value)
	if spec.type == "bool" then return value ~= 0 and "on" or "off" end
	return string.format("%." .. (spec.decimals or 2) .. "f", value)
end

local function Tooltip(spec)
	local lines = { spec.help or "" }
	lines[#lines + 1] = string.format("Default: %s   Console: %s", FormatValue(spec, DefaultValue(spec)), spec.cvar)
	if spec.scaled then lines[#lines + 1] = "Measured for a 45 unit leg, scaled with your model's legs." end
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------
-- pages
-- ---------------------------------------------------------------------

local PAGES = {
	{ id = "quick", title = "Quick setup", icon = "icon16/lightning.png" },
	{ id = "ground", title = "Ground", icon = "icon16/world.png",
		blurb = "How the feet find the ground under them.",
		keys = { "ground_distance", "trace_start_offset", "sole_offset", "anti_clip" } },
	{ id = "legs", title = "Legs & feet", icon = "icon16/user.png",
		blurb = "How planted feet hold on and how they turn to the ground.",
		keys = { "foot_rotation_scale", "rotation_smoothing", "lock_strength", "release_speed", "stabilize_idle", "idle_velocity", "leg_length" } },
	{ id = "stairs", title = "Stairs", icon = "icon16/arrow_up.png",
		blurb = "One foot per tread, the way people walk up and down stairs.",
		keys = { "stair_stepper", "stair_treads_per_step", "stair_max_cadence", "stair_step_lift", "stair_step_min_height", "stair_step_max_height", "moving_surface_max_speed" } },
	{ id = "body", title = "Body", icon = "icon16/user_go.png",
		blurb = "How low the body goes to keep both feet on the ground.",
		keys = { "smoothing", "lean_enabled", "uneven_drop_scale", "extra_body_drop", "extra_body_drop_uneven", "max_body_drop" } },
	{ id = "auto", title = "Automation", icon = "icon16/wand.png",
		blurb = "What the addon works out on its own for each model.",
		keys = { "auto_model_detect", "dynamic_sole" } },
	{ id = "perf", title = "Performance", icon = "icon16/computer.png",
		blurb = "Only on this computer: how much work goes into other players.",
		client = { "others", "max_distance" } },
	{ id = "presets", title = "Presets", icon = "icon16/disk.png" },
	{ id = "diag", title = "Diagnostics", icon = "icon16/bug.png" },
	{ id = "about", title = "About", icon = "icon16/information.png" },
}
IKFoot.MenuPages = PAGES

local QUICK_KEYS = { "enabled", "stair_stepper", "lean_enabled", "auto_model_detect", "debug" }

-- style presets: absolute, every tunable goes back to its default first.
-- on/off switches, the debug overlay and model specific values stay as they are
local STYLE_KEYS = {}
for _, entry in ipairs(ENTRIES) do
	if entry.type ~= "bool" and entry.key ~= "debug" and entry.key ~= "leg_length" and entry.key ~= "sole_offset" then
		STYLE_KEYS[#STYLE_KEYS + 1] = entry.key
	end
end

local STYLES = {
	{ name = "Default", desc = "The balanced setup the addon ships with.", values = {} },
	{ name = "Subtle", desc = "Less crouch and foot tilt, softer motion.",
		values = { foot_rotation_scale = 0.5, extra_body_drop = 0.2, extra_body_drop_uneven = 0.8, uneven_drop_scale = 0.1, smoothing = 12, stair_step_lift = 2 } },
	{ name = "Responsive", desc = "Quicker reactions, feet stick harder.",
		values = { smoothing = 26, rotation_smoothing = 32, lock_strength = 1.1, release_speed = 80 } },
	{ name = "Grounded", desc = "Feet flat on slopes, deeper knees on rough ground.",
		values = { foot_rotation_scale = 1, extra_body_drop_uneven = 1.8, uneven_drop_scale = 0.25, stair_step_lift = 3.5 } },
}
IKFoot.MenuStyles = STYLES

local function StyleValue(style, key)
	local v = style.values[key]
	if v ~= nil then return v end
	return DefaultValue(BY_KEY[key])
end

local function StyleActive(style)
	for _, key in ipairs(STYLE_KEYS) do
		local entry = BY_KEY[key]
		local current = CvarValue(entry)
		if current == nil or math.abs(current - StyleValue(style, key)) > 0.5 * 10 ^ -(entry.decimals or 2) then
			return false
		end
	end
	return true
end

local function ApplyStyle(style)
	for _, key in ipairs(STYLE_KEYS) do
		SetValue(BY_KEY[key], StyleValue(style, key))
	end
	Notify("Style \"" .. style.name .. "\" applied")
end

-- ---------------------------------------------------------------------
-- saved presets (same file and format as before: { name = { cvar = value } })
-- ---------------------------------------------------------------------

local PRESETS = {}

local OWN_CVARS = {}
for _, entry in ipairs(ENTRIES) do OWN_CVARS[entry.cvar] = entry end

local function LoadPresets()
	local json = file.Exists(PRESET_FILE, "DATA") and file.Read(PRESET_FILE, "DATA")
	local decoded = json and util.JSONToTable(json)
	PRESETS = istable(decoded) and decoded or {}
end

local function SavePresets()
	file.Write(PRESET_FILE, util.TableToJSON(PRESETS, true))
end

local function CurrentSettings()
	local settings = {}
	for _, entry in ipairs(ENTRIES) do
		local value = CvarValue(entry)
		if value ~= nil then settings[entry.cvar] = value end
	end
	return settings
end

-- only the addon's own cvars: a preset file is plain json in data/ and must
-- not be able to set anything else
local function ApplySettings(settings)
	for name, value in pairs(settings) do
		local entry = OWN_CVARS[name]
		if entry and GetConVar(name) and (isnumber(value) or isbool(value) or isstring(value)) then
			if entry.type == "bool" then
				RunConsoleCommand(name, tobool(value) and "1" or "0")
			else
				RunConsoleCommand(name, tostring(IKFoot.Config.ClampNumber(entry, value)))
			end
		end
	end
end

local function SortedPresetNames()
	local names = {}
	for name in pairs(PRESETS) do names[#names + 1] = name end
	table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
	return names
end

-- ---------------------------------------------------------------------
-- live status
-- ---------------------------------------------------------------------

-- "good" / "warn" / "bad" / "off", text
local function IKStatus()
	local ply = LocalPlayer()
	local RT = Runtime()
	if not IsValid(ply) or not RT then return "warn", "Waiting for your player" end
	local cv = GetConVar("ik_foot")
	if cv and not cv:GetBool() then return "off", "Turned off" end
	if not ply:Alive() then return "warn", "Paused while dead" end
	local bones = ply.IKBones
	if bones and not bones.valid then return "bad", "This model has no usable leg bones" end
	if RT.CanManipulateBones and not RT.CanManipulateBones(ply) then return "warn", "Paused (vehicle, noclip or ladder)" end
	if not ply.IKResult or FrameNumber() - (ply.IKResultFrame or 0) > 2 then
		return "warn", "Waiting: your model is not drawn (first person?)"
	end
	return "good", "Active"
end

local function StatusColor(kind)
	return (kind == "good" and C.good) or (kind == "bad" and C.bad) or (kind == "off" and C.off) or C.warn
end

-- a few readable lines about what the ik is doing right now
local function StatusLines()
	local ply = LocalPlayer()
	if not IsValid(ply) then return {} end
	local lines = {}
	local bones = ply.IKBones
	lines[#lines + 1] = "Model: " .. (string.GetFileFromFilename(ply:GetModel() or "") or "?")
	if bones and bones.valid then
		lines[#lines + 1] = string.format("Bones: %d   foot followers (shoes): %d   extra body roots: %d",
			bones.boneCount or 0, #(bones.followers or {}), #(bones.auxRoots or {}))
	end
	local res = ply.IKResult
	local d = res and res.debug
	if d then
		local ri = d.restInfo or {}
		lines[#lines + 1] = string.format("Ankle height (REST H): %.2f   model: %s", ri.value or 0,
			ri.expected and string.format("%.2f", ri.expected) or "unknown")
		lines[#lines + 1] = string.format("Body lowered by %.1f   limited by: %s", res.bodyDrop or 0, tostring(d.dropLimiter))
		lines[#lines + 1] = string.format("Stairs: %s   %d%% stepping   %s tread(s) per step",
			d.stairMode and "yes" or "no", math.floor((d.stairBlend or 0) * 100 + 0.5), tostring(d.treadsPerStep or 0))
		lines[#lines + 1] = string.format("Leg %.1f units, scale %.2f, speed %.0f", d.measuredLeg or 0, d.modelScale or 1, d.velocity2D or 0)
	end
	return lines
end

-- ---------------------------------------------------------------------
-- controls
-- ---------------------------------------------------------------------

local function StyleEntry(entry)
	entry:SetFont("IKFoot.Small")
	entry.Paint = function(self, w, h)
		draw.RoundedBox(6, 0, 0, w, h, C.input)
		if self:HasFocus() then
			surface.SetDrawColor(C.accent)
			surface.DrawOutlinedRect(0, 0, w, h, 1)
		end
		self:DrawTextEntryText(C.text, C.accent, C.text)
		if self:GetValue() == "" and not self:HasFocus() and self.placeholder then
			draw.SimpleText(self.placeholder, "IKFoot.Small", 10, h * 0.5, C.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end
end

local function FlatButton(parent, text, color, onClick, icon)
	local b = vgui.Create("DButton", parent)
	b:SetText("")
	b.Paint = function(self, w, h)
		local base = color or C.line
		local col = self:IsHovered() and LerpColor(0.25, base, C.white) or base
		if self:GetDisabled() then col = C.row end
		draw.RoundedBox(7, 0, 0, w, h, col)
		local x = w * 0.5
		if icon then
			surface.SetFont("IKFoot.Small")
			local tw = surface.GetTextSize(text)
			x = (w - tw - 20) * 0.5 + 20
			surface.SetMaterial(Icon(icon))
			surface.SetDrawColor(255, 255, 255, 255)
			surface.DrawTexturedRect(x - 20, h * 0.5 - 8, 16, 16)
			draw.SimpleText(text, "IKFoot.Small", x, h * 0.5, C.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		else
			draw.SimpleText(text, "IKFoot.Small", x, h * 0.5, C.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		return true
	end
	b.DoClick = function(self)
		surface.PlaySound("garrysmod/ui_click.wav")
		if onClick then onClick(self) end
	end
	return b
end

local function Toggle(parent, cvarName)
	local b = vgui.Create("DButton", parent)
	b:SetText("")
	local cv = GetConVar(cvarName)
	b.anim = (cv and cv:GetBool()) and 1 or 0
	b.Paint = function(self, w, h)
		local c = GetConVar(cvarName)
		local on = c and c:GetBool()
		self.anim = Lerp(math.min(FrameTime() * 14, 1), self.anim, on and 1 or 0)
		draw.RoundedBox(h * 0.5, 0, 0, w, h, LerpColor(self.anim, self:IsHovered() and C.lineHover or C.line, C.accent))
		local d = h - 6
		draw.RoundedBox(d * 0.5, 3 + (w - d - 6) * self.anim, 3, d, d, C.white)
		return true
	end
	b.DoClick = function()
		local c = GetConVar(cvarName)
		RunConsoleCommand(cvarName, (c and c:GetBool()) and "0" or "1")
		surface.PlaySound("garrysmod/ui_click.wav")
	end
	return b
end

-- one button per value, the current one highlighted
local function Segmented(parent, cvarName, options)
	local p = vgui.Create("DPanel", parent)
	p.Paint = function(_, w, h) draw.RoundedBox(7, 0, 0, w, h, C.line) end
	local buttons = {}
	for i, opt in ipairs(options) do
		local b = vgui.Create("DButton", p)
		b:SetText("")
		b.Paint = function(self, w, h)
			local c = GetConVar(cvarName)
			local selected = c and c:GetInt() == opt.value
			if selected then
				draw.RoundedBox(6, 2, 2, w - 4, h - 4, C.accent)
			elseif self:IsHovered() then
				draw.RoundedBox(6, 2, 2, w - 4, h - 4, C.lineHover)
			end
			draw.SimpleText(opt.label, "IKFoot.Small", w * 0.5, h * 0.5, selected and C.white or C.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			return true
		end
		b.DoClick = function()
			RunConsoleCommand(cvarName, tostring(opt.value))
			surface.PlaySound("garrysmod/ui_click.wav")
		end
		buttons[i] = b
	end
	p.PerformLayout = function(_, w, h)
		local bw = w / #buttons
		for i, b in ipairs(buttons) do
			b:SetPos(math.floor((i - 1) * bw), 0)
			b:SetSize(math.floor(bw), h)
		end
	end
	return p
end

local function Slider(parent, spec)
	local s = vgui.Create("DNumSlider", parent)
	s:SetText("")
	s:SetMin(spec.min)
	s:SetMax(spec.max)
	s:SetDecimals(spec.decimals or 2)
	s:SetConVar(spec.cvar)
	local cv = GetConVar(spec.cvar)
	if cv then s:SetValue(cv:GetFloat()) end
	-- the row shows the name, the slider only needs its track and number box
	if IsValid(s.Label) then s.Label:SetVisible(false) end
	s.PerformLayout = function(self)
		if IsValid(self.Label) then self.Label:SetWide(0) end
	end
	if IsValid(s.TextArea) then
		s.TextArea:SetWide(62)
		StyleEntry(s.TextArea)
	end
	local track = s.Slider
	if IsValid(track) then
		track.Paint = function(self, w, h)
			local x0, x1 = 7, w - 7
			draw.RoundedBox(2, x0, h * 0.5 - 2, x1 - x0, 4, C.line)
			draw.RoundedBox(2, x0, h * 0.5 - 2, (x1 - x0) * math.Clamp(self:GetSlideX(), 0, 1), 4, C.accent)
		end
		if IsValid(track.Knob) then
			track.Knob:SetSize(14, 14)
			track.Knob.Paint = function(self, w, h)
				draw.RoundedBox(w * 0.5, 0, 0, w, h, (self:IsHovered() or self:IsDown()) and C.white or C.knob)
				return true
			end
		end
	end
	return s
end

local DEBUG_OPTIONS = { { value = 0, label = "Off" }, { value = 1, label = "Basic" }, { value = 2, label = "Detailed" } }

-- one setting: name, explanation, control, "back to default" button. a blue
-- bar on the left marks values that differ from the default
local function SettingRow(parent, spec)
	local isBool = spec.type == "bool"
	local isChoice = spec.key == "debug"
	local row = vgui.Create("DPanel", parent)
	row:Dock(TOP)
	row:DockMargin(0, 0, 0, 6)
	row:SetTall((isBool or isChoice) and 64 or 92)
	row:SetTooltip(Tooltip(spec))
	row.Paint = function(self, w, h)
		draw.RoundedBox(8, 0, 0, w, h, (self:IsHovered() or self:IsChildHovered()) and C.rowHover or C.row)
		if not IsDefault(spec) then draw.RoundedBox(2, 0, 12, 3, h - 24, C.accent) end
	end

	local title = vgui.Create("DLabel", row)
	title:SetFont("IKFoot.Body")
	title:SetTextColor(C.text)
	title:SetText(spec.label or spec.desc or spec.cvar)

	local help = vgui.Create("DLabel", row)
	help:SetFont("IKFoot.Small")
	help:SetTextColor(C.muted)
	help:SetText(spec.help or "")
	help:SetWrap(true)
	help:SetContentAlignment(7)

	local reset = vgui.Create("DButton", row)
	reset:SetText("")
	reset:SetSize(22, 22)
	reset:SetTooltip("Back to the default (" .. FormatValue(spec, DefaultValue(spec)) .. ")")
	reset.Paint = function(self, w, h)
		if self:IsHovered() then draw.RoundedBox(6, 0, 0, w, h, C.lineHover) end
		surface.SetMaterial(Icon("icon16/arrow_undo.png"))
		surface.SetDrawColor(255, 255, 255, self:IsHovered() and 255 or 170)
		surface.DrawTexturedRect(w * 0.5 - 8, h * 0.5 - 8, 16, 16)
		return true
	end
	reset.DoClick = function()
		SetValue(spec, DefaultValue(spec))
		surface.PlaySound("garrysmod/ui_click.wav")
	end
	reset.Think = function(self)
		local show = not IsDefault(spec)
		if self:IsVisible() ~= show then self:SetVisible(show) end
	end

	local control
	if isChoice then
		control = Segmented(row, spec.cvar, DEBUG_OPTIONS)
	elseif isBool then
		control = Toggle(row, spec.cvar)
	else
		control = Slider(row, spec)
	end

	row.PerformLayout = function(_, w, h)
		local pad = 14
		local controlW = (isChoice and 216) or (isBool and 46) or 0
		local textW = w - pad * 2 - controlW - 34
		title:SetPos(pad, 9)
		title:SetSize(textW, 20)
		help:SetPos(pad, 30)
		help:SetSize(textW, 30)
		if isChoice then
			control:SetPos(w - pad - controlW, math.floor((h - 28) * 0.5))
			control:SetSize(controlW, 28)
			reset:SetPos(w - pad - controlW - 30, math.floor((h - 22) * 0.5))
		elseif isBool then
			control:SetPos(w - pad - controlW, math.floor((h - 24) * 0.5))
			control:SetSize(controlW, 24)
			reset:SetPos(w - pad - controlW - 30, math.floor((h - 22) * 0.5))
		else
			control:SetPos(pad - 6, h - 32)
			control:SetSize(w - pad * 2 + 6, 24)
			reset:SetPos(w - pad - 22, 8)
		end
	end
	return row
end

local function Card(parent, title, subtitle)
	local card = vgui.Create("DPanel", parent)
	card:Dock(TOP)
	card:DockMargin(0, 0, 0, 12)
	card:DockPadding(14, title and (subtitle and 58 or 40) or 14, 14, 8)
	card.Paint = function(_, w, h)
		draw.RoundedBox(10, 0, 0, w, h, C.card)
		if title then draw.SimpleText(title, "IKFoot.H2", 14, 12, C.text) end
		if subtitle then draw.SimpleText(subtitle, "IKFoot.Small", 14, 34, C.muted) end
	end
	return card
end

-- a card's height from its docked children (they all have fixed heights)
local function FitCard(card)
	local _, top, _, bottom = card:GetDockPadding()
	local h = top + bottom
	for _, child in ipairs(card:GetChildren()) do
		local _, mt, _, mb = child:GetDockMargin()
		h = h + child:GetTall() + mt + mb
	end
	card:SetTall(h)
	return card
end

local function TextLine(parent, text, font, color, tall)
	local l = vgui.Create("DLabel", parent)
	l:Dock(TOP)
	l:SetTall(tall or 20)
	l:SetFont(font or "IKFoot.Small")
	l:SetTextColor(color or C.muted)
	l:SetText(text)
	l:SetWrap(true)
	l:SetContentAlignment(7)
	return l
end

-- a panel that redraws a list of lines from fn() a few times a second
local function LiveLines(parent, fn, count)
	local p = vgui.Create("DPanel", parent)
	p:Dock(TOP)
	p:SetTall(count * 20 + 4)
	p.lines = fn()
	p.nextUpdate = 0
	p.Think = function(self)
		if RealTime() < self.nextUpdate then return end
		self.nextUpdate = RealTime() + 0.3
		self.lines = fn()
	end
	p.Paint = function(self)
		for i, line in ipairs(self.lines) do
			draw.SimpleText(line, "IKFoot.Small", 0, (i - 1) * 20 + 2, C.text)
		end
	end
	return p
end

local function ButtonGrid(parent, columns, buttons)
	local grid = vgui.Create("DPanel", parent)
	grid:Dock(TOP)
	grid:DockMargin(0, 4, 0, 4)
	local rows = math.ceil(#buttons / columns)
	grid:SetTall(rows * 40 - 6)
	grid.Paint = NoPaint
	local panels = {}
	for i, def in ipairs(buttons) do
		panels[i] = FlatButton(grid, def[1], def[2], def[3], def[4])
		if def[5] then panels[i]:SetTooltip(def[5]) end
	end
	grid.PerformLayout = function(_, w)
		local bw = (w - (columns - 1) * 8) / columns
		for i, b in ipairs(panels) do
			local col, r = (i - 1) % columns, math.floor((i - 1) / columns)
			b:SetPos(math.floor(col * (bw + 8)), r * 40)
			b:SetSize(math.floor(bw), 34)
		end
	end
	return grid
end

-- ---------------------------------------------------------------------
-- page builders
-- ---------------------------------------------------------------------

local Build = {}

local function SpecOf(key)
	return BY_KEY[key] or CLIENT_SPECS[key]
end

local function SettingsCard(parent, title, subtitle, keys)
	local card = Card(parent, title, subtitle)
	for _, key in ipairs(keys) do
		local spec = SpecOf(key)
		if spec then SettingRow(card, spec) end
	end
	return FitCard(card)
end

function Build.quick(scroll)
	SettingsCard(scroll, "Essentials", "The switches most people need.", QUICK_KEYS)

	local styles = Card(scroll, "Style", "A starting point for the feel. Only tuning values change, your switches stay.")
	local grid = vgui.Create("DPanel", styles)
	grid:Dock(TOP)
	grid:SetTall(math.ceil(#STYLES / 2) * 70 - 8)
	grid.Paint = NoPaint
	-- which style matches the current values, re-checked four times a second
	grid.active = {}
	grid.nextCheck = 0
	grid.Think = function(self)
		if RealTime() < self.nextCheck then return end
		self.nextCheck = RealTime() + 0.25
		for i, style in ipairs(STYLES) do self.active[i] = StyleActive(style) end
	end
	local tiles = {}
	for i, style in ipairs(STYLES) do
		local tile = vgui.Create("DButton", grid)
		tile:SetText("")
		tile.Paint = function(self, w, h)
			local active = grid.active[i]
			draw.RoundedBox(8, 0, 0, w, h, active and C.accentSoft or (self:IsHovered() and C.rowHover or C.row))
			if active then
				surface.SetDrawColor(C.accent)
				surface.DrawOutlinedRect(0, 0, w, h, 1)
			end
			draw.SimpleText(style.name .. (active and "  (current)" or ""), "IKFoot.Body", 12, 12, C.text)
			draw.SimpleText(style.desc, "IKFoot.Small", 12, 36, C.muted)
			return true
		end
		tile.DoClick = function() ApplyStyle(style) end
		tiles[i] = tile
	end
	grid.PerformLayout = function(_, w)
		local tw = (w - 8) / 2
		for i, tile in ipairs(tiles) do
			local col, r = (i - 1) % 2, math.floor((i - 1) / 2)
			tile:SetPos(math.floor(col * (tw + 8)), r * 70)
			tile:SetSize(math.floor(tw), 62)
		end
	end
	FitCard(styles)

	local status = Card(scroll, "Right now", nil)
	LiveLines(status, StatusLines, 6)
	FitCard(status)
end

local function CategoryPage(page, scroll)
	local keys = {}
	for _, key in ipairs(page.keys or page.client or {}) do keys[#keys + 1] = key end
	SettingsCard(scroll, page.title, page.blurb, keys)
end

function Build.auto(scroll, page)
	CategoryPage(page, scroll)
	local card = Card(scroll, "Your model", "What the addon measured on your current player model.")
	local info = TextLine(card, "Press \"Measure my model\" to see the numbers.", "IKFoot.Small", C.muted, 66)
	ButtonGrid(card, 2, {
		{ "Measure my model", C.line, function()
			local ply = LocalPlayer()
			if not IKFoot.MeasureModel or not IsValid(ply) then return end
			local suggested, err, m = IKFoot.MeasureModel(ply)
			if not suggested then
				info:SetText("Cannot measure this model: " .. tostring(err))
				return
			end
			info:SetText(string.format("%s\nleg %.1f units (%.1f + %.1f), scale %.2f, sole correction %+.2f\n%d bones, %d foot followers, %d extra body roots, root bone %s",
				string.GetFileFromFilename(m.model or "") or "?", m.legLength, m.upperLegLength, m.lowerLegLength, m.scale, m.soleOffset,
				m.boneCount or 0, m.followerCount or 0, m.auxRootCount or 0, tostring(m.rootBone)))
		end, "icon16/magnifier.png", "Measure the legs, feet and extra bones of your model" },
		{ "Re-detect and apply", C.line, function()
			local ply = LocalPlayer()
			if IKFoot.AutoApplyModelSettings and IsValid(ply) then IKFoot.AutoApplyModelSettings(ply) end
		end, "icon16/wand.png", "Measure the model again and apply the automatic settings" },
	})
	FitCard(card)
end

function Build.perf(scroll, page)
	CategoryPage(page, scroll)
	local card = Card(scroll, "Good to know", nil)
	TextLine(card, "Your own character always gets the IK. These settings only change what this computer does for other players; they are not sent to the server.", "IKFoot.Small", C.muted, 40)
	FitCard(card)
end

function Build.presets(scroll)
	LoadPresets()
	local card = Card(scroll, "Save the current settings", "Presets are stored in garrysmod/data/" .. PRESET_FILE .. ".")
	local bar = vgui.Create("DPanel", card)
	bar:Dock(TOP)
	bar:SetTall(32)
	bar.Paint = NoPaint
	local name = vgui.Create("DTextEntry", bar)
	name:Dock(FILL)
	name:DockMargin(0, 0, 8, 0)
	name.placeholder = "Preset name..."
	StyleEntry(name)
	local listCard
	local function Refresh() if IsValid(scroll) and scroll.Rebuild then scroll:Rebuild() end end
	local save = FlatButton(bar, "Save", C.accent, function()
		local value = string.Trim(name:GetValue() or "")
		if value == "" then
			Notify("Give the preset a name first", NOTIFY_ERROR)
			return
		end
		local existed = PRESETS[value] ~= nil
		PRESETS[value] = CurrentSettings()
		SavePresets()
		Notify(string.format("Preset \"%s\" %s", value, existed and "updated" or "saved"))
		Refresh()
	end, "icon16/disk.png")
	save:Dock(RIGHT)
	save:SetWide(110)
	name.OnEnter = function() save:DoClick() end
	FitCard(card)

	listCard = Card(scroll, "Saved presets", nil)
	local names = SortedPresetNames()
	if #names == 0 then
		TextLine(listCard, "No presets yet. Save your current setup to create one.", "IKFoot.Small", C.muted, 24)
	end
	for _, presetName in ipairs(names) do
		local row = vgui.Create("DPanel", listCard)
		row:Dock(TOP)
		row:DockMargin(0, 0, 0, 6)
		row:SetTall(42)
		row.Paint = function(self, w, h)
			draw.RoundedBox(8, 0, 0, w, h, (self:IsHovered() or self:IsChildHovered()) and C.rowHover or C.row)
			draw.SimpleText(presetName, "IKFoot.Body", 14, h * 0.5, C.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
		local del = FlatButton(row, "Delete", C.bad, function()
			PRESETS[presetName] = nil
			SavePresets()
			Notify(string.format("Preset \"%s\" deleted", presetName))
			Refresh()
		end)
		del:Dock(RIGHT)
		del:DockMargin(0, 6, 6, 6)
		del:SetWide(80)
		local load = FlatButton(row, "Load", C.accent, function()
			ApplySettings(PRESETS[presetName] or {})
			Notify(string.format("Preset \"%s\" loaded", presetName))
		end)
		load:Dock(RIGHT)
		load:DockMargin(0, 6, 6, 6)
		load:SetWide(80)
	end
	FitCard(listCard)

	local reset = Card(scroll, "Start over", nil)
	ButtonGrid(reset, 2, {
		{ "Reset all settings to defaults", C.line, function()
			for _, entry in ipairs(ENTRIES) do SetValue(entry, DefaultValue(entry)) end
			Notify("All settings back to their defaults")
		end, "icon16/arrow_undo.png" },
	})
	FitCard(reset)
end

function Build.diag(scroll)
	local status = Card(scroll, "Status", nil)
	local headline = vgui.Create("DPanel", status)
	headline:Dock(TOP)
	headline:SetTall(26)
	headline.Paint = function(_, w, h)
		local kind, text = IKStatus()
		draw.RoundedBox(5, 0, 7, 12, 12, StatusColor(kind))
		draw.SimpleText(text, "IKFoot.Body", 20, h * 0.5, C.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	LiveLines(status, function()
		local lines = StatusLines()
		local RT = Runtime()
		local diag = RT and RT.Diag
		if diag then
			local e = diag.events and diag.events[#diag.events]
			lines[#lines + 1] = e and string.format("Last event: %s %s (%.0f s ago)", e.kind, e.side or "", RealTime() - (e.t_last or e.t or 0))
				or "No unusual events recorded"
			if diag.capture then
				lines[#lines + 1] = string.format("Recording: %.0f s left", math.max((diag.capture.stopAt or 0) - RealTime(), 0))
			end
		end
		return lines
	end, 8)
	FitCard(status)

	local overlay = Card(scroll, "Overlay", "Shows what the IK does on your character (third person).")
	SettingRow(overlay, BY_KEY.debug)
	FitCard(overlay)

	local tools = Card(scroll, "Reports", "Files are written to garrysmod/data/ik_foot/ - attach them to a bug report.")
	ButtonGrid(tools, 2, {
		{ "Print report to console", C.line, function() RunConsoleCommand("ik_foot_diag") Notify("Report printed to the console") end,
			"icon16/page_white_text.png", "ik_foot_diag: a short summary with likely causes" },
		{ "Save a dump", C.line, function() RunConsoleCommand("ik_foot_dump") Notify("Dump saved to data/ik_foot/") end,
			"icon16/disk.png", "ik_foot_dump: everything the IK knows right now plus the last ~10 s" },
		{ "Record 10 seconds", C.line, function() RunConsoleCommand("ik_foot_capture", "10") Notify("Recording 10 s") end,
			"icon16/control_play.png", "ik_foot_capture 10: record while you reproduce the problem" },
		{ "Record 10 s in detail", C.line, function() RunConsoleCommand("ik_foot_capture", "10", "detail") Notify("Recording 10 s in detail") end,
			"icon16/control_play_blue.png", "ik_foot_capture 10 detail: also bone angles and every ground trace" },
		{ "Stop recording", C.line, function() RunConsoleCommand("ik_foot_capture_stop") end,
			"icon16/control_stop.png", "ik_foot_capture_stop: save the running recording now" },
		{ "Reset character", C.bad, function()
			local ply = LocalPlayer()
			if IKFoot.HardReset and IsValid(ply) then IKFoot.HardReset(ply) Notify("IK state and model analysis reset") end
		end, "icon16/arrow_refresh.png", "Forget everything about your model and start fresh" },
	})
	FitCard(tools)

	SettingsCard(scroll, "Recording", nil, { "diag_history", "diag_print" })
end

function Build.about(scroll)
	local card = Card(scroll, "IK Foot System", string.format("Version %s, build %s", IKFoot.VERSION or "?", IKFoot.BUILD or "?"))
	TextLine(card, "Places your character's feet on the ground: slopes, curbs, stairs one tread at a time, shoes that stay on the feet.", "IKFoot.Small", C.text, 36)
	TextLine(card, "Created by nikt_ani_nic. Inspired by steamcommunity.com/sharedfiles/filedetails/?id=1605334558", "IKFoot.Small", C.muted, 22)
	FitCard(card)

	local cmds = Card(scroll, "Commands", nil)
	for _, line in ipairs({
		"ik_foot_menu  /  !ikfoot in chat - this menu",
		"ik_foot_debug 0/1/2 - overlay off / basic / detailed",
		"ik_foot_diag - short report in the console",
		"ik_foot_dump - save everything to data/ik_foot/",
		"ik_foot_capture 10 [detail] - record 10 seconds, ik_foot_capture_stop ends early",
		"ik_foot_hard_reset - forget your model and start fresh",
	}) do
		TextLine(cmds, line, "IKFoot.Mono", C.text, 22)
	end
	FitCard(cmds)
end

-- every setting whose name, explanation or console name contains the query
function Build.search(scroll, _, query)
	local q = string.lower(query)
	local matches = {}
	local function Consider(spec, where)
		local hay = string.lower((spec.label or "") .. " " .. (spec.help or "") .. " " .. spec.cvar .. " " .. where)
		if string.find(hay, q, 1, true) then matches[#matches + 1] = spec end
	end
	local seen = {}
	for _, page in ipairs(PAGES) do
		for _, key in ipairs(page.keys or page.client or {}) do
			local spec = SpecOf(key)
			if spec and not seen[spec] then seen[spec] = true Consider(spec, page.title) end
		end
	end
	for _, key in ipairs(QUICK_KEYS) do
		local spec = SpecOf(key)
		if spec and not seen[spec] then seen[spec] = true Consider(spec, "quick") end
	end
	for _, key in ipairs({ "diag_history", "diag_print" }) do
		local spec = SpecOf(key)
		if not seen[spec] then seen[spec] = true Consider(spec, "diagnostics") end
	end

	local card = Card(scroll, "Search", #matches == 0 and ("Nothing matches \"" .. query .. "\"")
		or string.format("%d setting(s) match \"%s\"", #matches, query))
	for _, spec in ipairs(matches) do SettingRow(card, spec) end
	FitCard(card)
end

-- ---------------------------------------------------------------------
-- window
-- ---------------------------------------------------------------------

local PANEL
local lastPage = "quick"

local function CreateGUI()
	if IsValid(PANEL) then PANEL:Remove() end

	local w = math.min(980, ScrW() - 40)
	local h = math.min(680, ScrH() - 40)
	local frame = vgui.Create("DFrame")
	frame:SetSize(w, h)
	frame:Center()
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:SetDraggable(true)
	frame:SetSizable(false)
	frame:DockPadding(0, 0, 0, 0)
	frame:MakePopup()
	frame.Paint = function(_, pw, ph)
		draw.RoundedBox(10, 0, 0, pw, ph, C.bg)
	end
	PANEL = frame

	-- header: title, version, status, close
	local header = vgui.Create("DPanel", frame)
	header:Dock(TOP)
	header:SetTall(58)
	header.status, header.statusText = IKStatus()
	header.nextUpdate = 0
	header.Think = function(self)
		if self.dragX then
			-- the header covers the frame's own drag strip: move the window here
			local x = math.Clamp(gui.MouseX() - self.dragX, 0, ScrW() - frame:GetWide())
			local y = math.Clamp(gui.MouseY() - self.dragY, 0, ScrH() - frame:GetTall())
			frame:SetPos(x, y)
		end
		if RealTime() < self.nextUpdate then return end
		self.nextUpdate = RealTime() + 0.25
		self.status, self.statusText = IKStatus()
	end
	header.OnMousePressed = function(self, code)
		if code ~= MOUSE_LEFT then return end
		local fx, fy = frame:GetPos()
		self.dragX, self.dragY = gui.MouseX() - fx, gui.MouseY() - fy
		self:MouseCapture(true)
	end
	header.OnMouseReleased = function(self)
		self.dragX, self.dragY = nil, nil
		self:MouseCapture(false)
	end
	header.Paint = function(self, pw, ph)
		draw.RoundedBoxEx(10, 0, 0, pw, ph, C.header, true, true, false, false)
		surface.SetMaterial(Icon("icon16/user_go.png"))
		surface.SetDrawColor(255, 255, 255, 255)
		surface.DrawTexturedRect(20, ph * 0.5 - 8, 16, 16)
		draw.SimpleText("IK Foot System", "IKFoot.Title", 46, ph * 0.5 - 1, C.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		surface.SetFont("IKFoot.Title")
		local tw = surface.GetTextSize("IK Foot System")
		draw.SimpleText("v" .. (IKFoot.VERSION or "?") .. "  " .. (IKFoot.BUILD or ""), "IKFoot.Small", 56 + tw, ph * 0.5 + 2, C.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		-- status pill
		surface.SetFont("IKFoot.Small")
		local sw = surface.GetTextSize(self.statusText)
		local px = pw - 60 - sw - 34
		draw.RoundedBox(13, px, ph * 0.5 - 13, sw + 34, 26, C.row)
		draw.RoundedBox(5, px + 12, ph * 0.5 - 5, 10, 10, StatusColor(self.status))
		draw.SimpleText(self.statusText, "IKFoot.Small", px + 28, ph * 0.5, C.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		surface.SetDrawColor(C.line)
		surface.DrawLine(0, ph - 1, pw, ph - 1)
	end
	local close = vgui.Create("DButton", header)
	close:SetText("")
	close:Dock(RIGHT)
	close:DockMargin(0, 14, 14, 14)
	close:SetWide(30)
	close.Paint = function(self, pw, ph)
		if self:IsHovered() then draw.RoundedBox(6, 0, 0, pw, ph, C.bad) end
		surface.SetDrawColor(C.text)
		local m = 10
		surface.DrawLine(m, m, pw - m, ph - m)
		surface.DrawLine(pw - m, m, m, ph - m)
		return true
	end
	close.DoClick = function() frame:Close() end

	-- sidebar
	local side = vgui.Create("DPanel", frame)
	side:Dock(LEFT)
	side:SetWide(196)
	side:DockPadding(10, 12, 10, 12)
	side.Paint = function(_, pw, ph)
		draw.RoundedBoxEx(10, 0, 0, pw, ph, C.side, false, false, true, false)
	end

	-- content: search on top, the page below
	local body = vgui.Create("DPanel", frame)
	body:Dock(FILL)
	body:DockPadding(16, 12, 16, 12)
	body.Paint = NoPaint

	local search = vgui.Create("DTextEntry", body)
	search:Dock(TOP)
	search:SetTall(32)
	search:DockMargin(0, 0, 0, 12)
	search.placeholder = "Search settings..."
	search:SetUpdateOnType(true)
	StyleEntry(search)

	local scroll = vgui.Create("DScrollPanel", body)
	scroll:Dock(FILL)
	local bar = scroll:GetVBar()
	if IsValid(bar) then
		bar:SetWide(8)
		bar.Paint = NoPaint
		if IsValid(bar.btnUp) then bar.btnUp.Paint = function() return true end end
		if IsValid(bar.btnDown) then bar.btnDown.Paint = function() return true end end
		if IsValid(bar.btnGrip) then
			bar.btnGrip.Paint = function(_, pw, ph)
				draw.RoundedBox(4, 0, 0, pw, ph, C.line)
				return true
			end
		end
	end

	local current = lastPage
	local function Show(id)
		current = id
		lastPage = id
		scroll:Clear()
		local query = string.Trim(search:GetValue() or "")
		if query ~= "" then
			Build.search(scroll, nil, query)
		else
			for _, page in ipairs(PAGES) do
				if page.id == id then
					local builder = Build[id] or CategoryPage
					if builder == CategoryPage then CategoryPage(page, scroll) else builder(scroll, page) end
				end
			end
		end
		scroll:InvalidateLayout()
	end
	scroll.Rebuild = function() Show(current) end
	search.OnValueChange = function() Show(current) end

	for _, page in ipairs(PAGES) do
		local nav = vgui.Create("DButton", side)
		nav:Dock(TOP)
		nav:DockMargin(0, 0, 0, 4)
		nav:SetTall(34)
		nav:SetText("")
		nav.Paint = function(self, pw, ph)
			local active = current == page.id and string.Trim(search:GetValue() or "") == ""
			if active then
				draw.RoundedBox(7, 0, 0, pw, ph, C.accentSoft)
				draw.RoundedBox(2, 0, 8, 3, ph - 16, C.accent)
			elseif self:IsHovered() then
				draw.RoundedBox(7, 0, 0, pw, ph, C.row)
			end
			surface.SetMaterial(Icon(page.icon))
			surface.SetDrawColor(255, 255, 255, active and 255 or 200)
			surface.DrawTexturedRect(12, ph * 0.5 - 8, 16, 16)
			draw.SimpleText(page.title, "IKFoot.Body", 38, ph * 0.5, active and C.text or C.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			return true
		end
		nav.DoClick = function()
			if string.Trim(search:GetValue() or "") ~= "" then
				-- SetValue does nothing while the box has keyboard focus
				search:KillFocus()
				search:SetValue("")
			end
			Show(page.id)
			surface.PlaySound("garrysmod/ui_click.wav")
		end
	end

	Show(current)
	return frame
end

IKFoot.OpenMenu = CreateGUI

net.Receive(OPEN_MENU_NET, function()
	if IKFoot and IKFoot.OpenMenu then IKFoot.OpenMenu() end
end)

concommand.Add("ik_foot_menu", function()
	IKFoot.OpenMenu()
end, nil, "IK Foot: open the settings menu")

hook.Add("PopulateToolMenu", "IKFoot_Menu", function()
	spawnmenu.AddToolMenuOption("Utilities", "User", "IKFoot", "IK Foot", "", "", function(panel)
		panel:ClearControls()
		panel:Help("Puts your character's feet on the ground: slopes, curbs and stairs one tread at a time.")
		panel:Button("Open the IK Foot menu", "ik_foot_menu")
		panel:CheckBox("Foot IK", "ik_foot")
		panel:CheckBox("Stair stepping", "ik_foot_stair_stepper")
		panel:CheckBox("Body lean", "ik_foot_lean")
		panel:CheckBox("IK on other players", "ik_foot_others")
		panel:NumSlider("Debug overlay (0 off, 1 basic, 2 detailed)", "ik_foot_debug", 0, 2, 0)
		panel:Help("Chat: !ikfoot or /ikfoot    Console: ik_foot_menu")
	end)
end)
