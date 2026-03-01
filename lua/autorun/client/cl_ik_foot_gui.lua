if SERVER then return end

-- gui preset stuff
local PANEL = nil
local PRESETS = {}
local PRESET_FILE = "ik_foot_presets.txt"
local SavePresets

local function NormalizeConVarName(name)
	if not isstring(name) then return name end
	if string.StartWith(name, "player_ik_foot") then
		return string.Replace(name, "player_ik_foot", "ik_foot")
	end
	return name
end

-- cvar list
local CONVARS = {
	{name = "ik_foot", default = 1, min = 0, max = 1, decimals = 0, desc = "Enable/Disable IK Foot"},
	{name = "ik_foot_debug", default = 0, min = 0, max = 2, decimals = 0, desc = "Debug Visualization Level"},
	{name = "ik_foot_ground_distance", default = 45, min = 10, max = 100, decimals = 0, desc = "Ground Trace Distance"},
	{name = "ik_foot_smoothing", default = 17, min = 1, max = 50, decimals = 0, desc = "Smoothing Factor"},
	{name = "ik_foot_leg_length", default = 45, min = 20, max = 80, decimals = 0, desc = "Leg Length for IK"},
	{name = "ik_foot_trace_start_offset", default = 30, min = 10, max = 60, decimals = 0, desc = "Trace Start Height"},
	{name = "ik_foot_sole_offset", default = 0, min = -5, max = 5, decimals = 2, desc = "Sole Contact Offset"},
	{name = "ik_foot_uneven_drop_scale", default = 0, min = 0, max = 1, decimals = 2, desc = "Height Diff Multiplier"},
	{name = "ik_foot_extra_body_drop", default = 1, min = 0, max = 10, decimals = 1, desc = "Body Drop (Flat)"},
	{name = "ik_foot_extra_body_drop_uneven", default = 4, min = 0, max = 10, decimals = 1, desc = "Body Drop (Uneven)"},
	{name = "ik_foot_high_foot_bend_boost", default = 2.3, min = 1, max = 5, decimals = 2, desc = "High Foot Bend Boost"},
	{name = "ik_foot_rotation_scale", default = 0.15, min = 0, max = 1, decimals = 2, desc = "Foot Rotation Scale"},
	{name = "ik_foot_stabilize_idle", default = 1, min = 0, max = 1, decimals = 0, desc = "Stabilize Idle Feet"},
	{name = "ik_foot_idle_velocity", default = 5, min = 0, max = 50, decimals = 0, desc = "Idle Velocity Threshold"},
	{name = "ik_foot_idle_threshold", default = 0.5, min = 0, max = 5, decimals = 2, desc = "Idle Distance Threshold"},
}

-- load presets
local function LoadPresets()
	if not file.Exists(PRESET_FILE, "DATA") then
		PRESETS = {}
		return
	end
	
	local json = file.Read(PRESET_FILE, "DATA")
	if not json then
		PRESETS = {}
		return
	end
	
	local decoded = util.JSONToTable(json)
	PRESETS = decoded or {}

	local changed = false
	for presetName, settings in pairs(PRESETS) do
		if istable(settings) then
			local migrated = {}
			for name, value in pairs(settings) do
				local normalized = NormalizeConVarName(name)
				if normalized ~= name then
					changed = true
				end
				migrated[normalized] = value
			end
			PRESETS[presetName] = migrated
		end
	end

	if changed then
		SavePresets()
	end
end

SavePresets = function()
	local json = util.TableToJSON(PRESETS, true)
	file.Write(PRESET_FILE, json)
end

local function GetCurrentSettings()
	local settings = {}
	for _, cv in ipairs(CONVARS) do
		local cvar = GetConVar(cv.name)
		if cvar then
			settings[cv.name] = cvar:GetFloat()
		end
	end
	return settings
end

local function ApplySettings(settings)
	for name, value in pairs(settings) do
		local cvarName = NormalizeConVarName(name)
		if GetConVar(cvarName) then
			RunConsoleCommand(cvarName, tostring(value))
		end
	end
end

local function ResetToDefaults()
	for _, cv in ipairs(CONVARS) do
		RunConsoleCommand(cv.name, tostring(cv.default))
	end
	chat.AddText(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255), "Reset to default values")
end

local function CreatePreset(name)
	if name == "" or not name then
		chat.AddText(Color(255, 100, 100), "[IK Foot] ", Color(255, 255, 255), "Preset name cannot be empty!")
		return false
	end
	
	PRESETS[name] = GetCurrentSettings()
	SavePresets()
	chat.AddText(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255), "Preset '", Color(100, 200, 255), name, Color(255, 255, 255), "' saved!")
	return true
end

local function LoadPreset(name)
	if not PRESETS[name] then
		chat.AddText(Color(255, 100, 100), "[IK Foot] ", Color(255, 255, 255), "Preset '", name, "' not found!")
		return false
	end
	
	ApplySettings(PRESETS[name])
	chat.AddText(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255), "Preset '", Color(100, 200, 255), name, Color(255, 255, 255), "' loaded!")
	return true
end

local function DeletePreset(name)
	if not PRESETS[name] then
		chat.AddText(Color(255, 100, 100), "[IK Foot] ", Color(255, 255, 255), "Preset '", name, "' not found!")
		return false
	end
	
	PRESETS[name] = nil
	SavePresets()
	chat.AddText(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255), "Preset '", Color(100, 200, 255), name, Color(255, 255, 255), "' deleted!")
	return true
end

local function RefreshPresetList(listPanel)
	if not IsValid(listPanel) then return end
	
	listPanel:Clear()
	
	for name, _ in pairs(PRESETS) do
		local item = listPanel:Add("DPanel")
		item:Dock(TOP)
		item:DockMargin(5, 2, 5, 2)
		item:SetHeight(30)
		item.Paint = function(self, w, h)
			draw.RoundedBox(4, 0, 0, w, h, Color(50, 50, 60, 200))
		end
		
		local label = vgui.Create("DLabel", item)
		label:SetPos(10, 7)
		label:SetText(name)
		label:SetFont("DermaDefault")
		label:SetTextColor(Color(255, 255, 255))
		label:SizeToContents()
		
		local btnLoad = vgui.Create("DButton", item)
		btnLoad:SetPos(item:GetWide() - 150, 3)
		btnLoad:SetSize(70, 24)
		btnLoad:SetText("Load")
		btnLoad.DoClick = function()
			LoadPreset(name)
			if IsValid(PANEL) then
				PANEL:RefreshSliders()
			end
		end
		
		local btnDel = vgui.Create("DButton", item)
		btnDel:SetPos(item:GetWide() - 75, 3)
		btnDel:SetSize(70, 24)
		btnDel:SetText("Delete")
		btnDel.DoClick = function()
			DeletePreset(name)
			RefreshPresetList(listPanel)
		end
		
		item.PerformLayout = function(self)
			btnLoad:SetPos(self:GetWide() - 150, 3)
			btnDel:SetPos(self:GetWide() - 75, 3)
		end
	end
end

-- build main gui
local function CreateGUI()
	if IsValid(PANEL) then
		PANEL:Remove()
	end
	
	LoadPresets()
	
	local frame = vgui.Create("DFrame")
	frame:SetSize(700, 650)
	frame:Center()
	frame:SetTitle("IK Foot Settings")
	frame:SetVisible(true)
	frame:SetDraggable(true)
	frame:ShowCloseButton(true)
	frame:MakePopup()
	PANEL = frame
	
	local tabs = vgui.Create("DPropertySheet", frame)
	tabs:Dock(FILL)
	
	-- settings tab
	local settingsPanel = vgui.Create("DPanel", tabs)
	settingsPanel:Dock(FILL)
	settingsPanel.Paint = function(self, w, h)
		draw.RoundedBox(0, 0, 0, w, h, Color(40, 40, 50))
	end
	
	local settingsScroll = vgui.Create("DScrollPanel", settingsPanel)
	settingsScroll:Dock(FILL)
	settingsScroll:DockMargin(5, 5, 5, 45)
	
	frame.Sliders = {}
	
	for _, cv in ipairs(CONVARS) do
		local slider = vgui.Create("DNumSlider", settingsScroll)
		slider:Dock(TOP)
		slider:DockMargin(5, 2, 5, 2)
		slider:SetText(cv.desc)
		slider:SetMin(cv.min)
		slider:SetMax(cv.max)
		slider:SetDecimals(cv.decimals)
		slider:SetConVar(cv.name)
		slider.CVarName = cv.name
		local cvar = GetConVar(cv.name)
		if cvar then
			slider:SetValue(cvar:GetFloat())
		end
		
		table.insert(frame.Sliders, slider)
	end
	
	local btnPanel = vgui.Create("DPanel", settingsPanel)
	btnPanel:Dock(BOTTOM)
	btnPanel:SetHeight(35)
	btnPanel.Paint = nil
	
	local btnReset = vgui.Create("DButton", btnPanel)
	btnReset:Dock(FILL)
	btnReset:DockMargin(5, 5, 5, 5)
	btnReset:SetText("Reset to Defaults")
	btnReset.DoClick = function()
		ResetToDefaults()
		frame:RefreshSliders()
	end
	
	tabs:AddSheet("Settings", settingsPanel, "icon16/cog.png")
	
	-- presets tab
	local presetsPanel = vgui.Create("DPanel", tabs)
	presetsPanel:Dock(FILL)
	presetsPanel.Paint = function(self, w, h)
		draw.RoundedBox(0, 0, 0, w, h, Color(40, 40, 50))
	end
	
	local newPresetPanel = vgui.Create("DPanel", presetsPanel)
	newPresetPanel:Dock(TOP)
	newPresetPanel:SetHeight(80)
	newPresetPanel:DockMargin(5, 5, 5, 5)
	newPresetPanel.Paint = function(self, w, h)
		draw.RoundedBox(4, 0, 0, w, h, Color(50, 50, 60, 150))
	end
	
	local lblNew = vgui.Create("DLabel", newPresetPanel)
	lblNew:SetPos(10, 10)
	lblNew:SetText("Create New Preset:")
	lblNew:SetFont("DermaDefaultBold")
	lblNew:SetTextColor(Color(255, 255, 255))
	lblNew:SizeToContents()
	
	local txtPresetName = vgui.Create("DTextEntry", newPresetPanel)
	txtPresetName:SetPos(10, 35)
	txtPresetName:SetSize(400, 30)
	txtPresetName:SetPlaceholderText("Enter preset name...")
	
	local btnSave = vgui.Create("DButton", newPresetPanel)
	btnSave:SetPos(420, 35)
	btnSave:SetSize(100, 30)
	btnSave:SetText("Save Preset")
	btnSave.DoClick = function()
		local name = txtPresetName:GetValue()
		if CreatePreset(name) then
			txtPresetName:SetValue("")
			RefreshPresetList(presetsPanel.PresetList)
		end
	end
	
	local listScroll = vgui.Create("DScrollPanel", presetsPanel)
	listScroll:Dock(FILL)
	listScroll:DockMargin(5, 5, 5, 5)
	
	presetsPanel.PresetList = listScroll
	RefreshPresetList(listScroll)
	
	tabs:AddSheet("Presets", presetsPanel, "icon16/disk.png")
	
	frame.RefreshSliders = function(self)
		for _, slider in ipairs(self.Sliders) do
			local cvar = slider.CVarName and GetConVar(slider.CVarName) or nil
			if cvar then
				slider:SetValue(cvar:GetFloat())
			end
		end
	end
	
	return frame
end

-- console cmd
concommand.Add("ik_foot_menu", function()
	CreateGUI()
end)

-- chat cmd
hook.Add("OnPlayerChat", "IKFoot_ChatCommand", function(ply, text)
	if ply ~= LocalPlayer() then return end
	
	local lower = string.lower(text)
	if lower == "!ikfoot" or lower == "/ikfoot" then
		CreateGUI()
		return true
	end
end)

-- spawnmenu entry
hook.Add("PopulateToolMenu", "IKFoot_Menu", function()
	spawnmenu.AddToolMenuOption("Utilities", "User", "IKFoot", "IK Foot Settings", "", "", function(panel)
		panel:ClearControls()
		
		panel:Help("IK Foot System - Adjust leg positioning on terrain")
		panel:Help("Use presets to quickly switch between different settings")
		panel:Help(" ")
		
		local btn = panel:Button("Open IK Foot Menu")
		btn.DoClick = function()
			CreateGUI()
		end
		
		panel:Help(" ")
		panel:Help("Chat Commands: !ikfoot or /ikfoot")
		panel:Help("Console Command: ik_foot_menu")
	end)
end)

print("[IK Foot GUI] Loaded - Use !ikfoot, /ikfoot, or ik_foot_menu to open")
