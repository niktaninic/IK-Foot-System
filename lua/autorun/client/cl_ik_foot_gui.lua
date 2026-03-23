if SERVER then return end

if not IKFoot or not IKFoot.Config then
	include("ik_foot/shared/sh_ik_foot_config.lua")
end

if not IKFoot or not IKFoot.Config then return end

local OPEN_MENU_NET = "IKFoot_OpenMenu"

local PANEL = nil
local PRESETS = {}
local PRESET_FILE = "ik_foot_presets.txt"
local SavePresets

local CONVARS = IKFoot.Config.entries

local UI = {
	bg = Color(25, 28, 34, 245),
	panel = Color(36, 40, 48, 235),
	panelSoft = Color(46, 51, 61, 220),
	accent = Color(90, 170, 255, 255),
	accentSoft = Color(90, 170, 255, 35),
	text = Color(235, 240, 245),
	muted = Color(165, 175, 190),
}

local CATEGORIES = {
	{
		title = "General",
		keys = { "enabled", "lean_enabled", "debug", "smoothing" },
	},
	{
		title = "Ground Detection",
		keys = { "ground_distance", "trace_start_offset", "sole_offset" },
	},
	{
		title = "Leg & Foot",
		keys = { "leg_length", "high_foot_bend_boost", "foot_rotation_scale" },
	},
	{
		title = "Body & Stability",
		keys = {
			"uneven_drop_scale", "extra_body_drop", "extra_body_drop_uneven", "max_body_drop",
			"lock_strength", "release_speed", "rotation_smoothing",
			"stabilize_idle", "idle_velocity",
		},
	},
	{
		title = "Automation & Safety",
		keys = { "auto_model_detect", "anti_clip", "dynamic_sole" },
	},
}

local function BuildCategoryEntryLookup()
	local map = {}
	for _, entry in ipairs(CONVARS) do
		map[entry.key] = entry
	end
	return map
end

local function PaintRounded(rectColor, radius)
	radius = radius or 6
	return function(_, w, h)
		draw.RoundedBox(radius, 0, 0, w, h, rectColor)
	end
end

local function StyleButton(button, colorIdle, colorHover)
	button:SetTextColor(UI.text)
	button.Paint = function(self, w, h)
		local bg = self:IsHovered() and colorHover or colorIdle
		draw.RoundedBox(6, 0, 0, w, h, bg)
	end
end

local function StyleTextEntry(entry)
	entry:SetFont("DermaDefault")
	entry:SetTextColor(UI.text)
	entry:SetCursorColor(UI.text)
	entry:SetHighlightColor(UI.accent)

	entry.Paint = function(self, w, h)
		local border = self:HasFocus() and UI.accent or Color(74, 84, 100, 255)
		draw.RoundedBox(6, 0, 0, w, h, Color(30, 34, 42, 255))
		surface.SetDrawColor(border)
		surface.DrawOutlinedRect(0, 0, w, h, 1)
		self:DrawTextEntryText(UI.text, UI.accent, UI.text)

		if self:GetValue() == "" and not self:HasFocus() then
			draw.SimpleText(self:GetPlaceholderText() or "", "DermaDefault", 8, h * 0.5, UI.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end
end

local function AddTitle(labelParent, text, y, font, color)
	local label = vgui.Create("DLabel", labelParent)
	label:SetPos(12, y)
	label:SetText(text)
	label:SetFont(font or "DermaDefaultBold")
	label:SetTextColor(color or UI.text)
	label:SizeToContents()
	return label
end

local function GetConsoleValue(entry)
	if entry.type == "bool" then
		return entry.default and "1" or "0"
	end

	return tostring(entry.default)
end

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


end

SavePresets = function()
	local json = util.TableToJSON(PRESETS, true)
	file.Write(PRESET_FILE, json)
end

local function GetCurrentSettings()
	local settings = {}
	for _, cv in ipairs(CONVARS) do
		local cvar = GetConVar(cv.cvar)
		if cvar then
			settings[cv.cvar] = cvar:GetFloat()
		end
	end
	return settings
end

local function ApplySettings(settings)
	for name, value in pairs(settings) do
		if GetConVar(name) then
			RunConsoleCommand(name, tostring(value))
		end
	end
end

local function ResetToDefaults()
	for _, cv in ipairs(CONVARS) do
		RunConsoleCommand(cv.cvar, GetConsoleValue(cv))
	end
	chat.AddText(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255), "Reset to default values")
end

local function CreatePreset(name)
	name = string.Trim(tostring(name or ""))
	if name == "" or not name then
		chat.AddText(Color(255, 100, 100), "[IK Foot] ", Color(255, 255, 255), "Preset name cannot be empty!")
		return false
	end
	
	local existed = PRESETS[name] ~= nil
	PRESETS[name] = GetCurrentSettings()
	SavePresets()
	if existed then
		chat.AddText(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255), "Preset '", Color(100, 200, 255), name, Color(255, 255, 255), "' updated!")
	else
		chat.AddText(Color(100, 255, 100), "[IK Foot] ", Color(255, 255, 255), "Preset '", Color(100, 200, 255), name, Color(255, 255, 255), "' saved!")
	end
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

	local hasAny = false
	
	local sortedNames = {}
	for name, _ in pairs(PRESETS) do
		sortedNames[#sortedNames + 1] = name
	end
	table.sort(sortedNames, function(a, b)
		return string.lower(a) < string.lower(b)
	end)

	for _, name in ipairs(sortedNames) do
		hasAny = true

		local item = listPanel:Add("DPanel")
		item:Dock(TOP)
		item:DockMargin(6, 4, 6, 4)
		item:SetHeight(38)
		item.Paint = function(self, w, h)
			draw.RoundedBox(6, 0, 0, w, h, UI.panelSoft)
			draw.RoundedBox(6, 0, 0, 4, h, UI.accent)
		end
		
		local label = vgui.Create("DLabel", item)
		label:SetPos(12, 11)
		label:SetText(name)
		label:SetFont("DermaDefaultBold")
		label:SetTextColor(UI.text)
		label:SizeToContents()
		
		local btnLoad = vgui.Create("DButton", item)
		btnLoad:SetPos(item:GetWide() - 172, 6)
		btnLoad:SetSize(80, 26)
		btnLoad:SetText("Load")
		StyleButton(btnLoad, Color(55, 115, 175), Color(70, 140, 210))
		btnLoad.DoClick = function()
			LoadPreset(name)
			if IsValid(PANEL) then
				PANEL:RefreshSliders()
			end
		end
		
		local btnDel = vgui.Create("DButton", item)
		btnDel:SetPos(item:GetWide() - 86, 6)
		btnDel:SetSize(80, 26)
		btnDel:SetText("Delete")
		StyleButton(btnDel, Color(150, 70, 70), Color(185, 85, 85))
		btnDel.DoClick = function()
			DeletePreset(name)
			RefreshPresetList(listPanel)
		end
		
		item.PerformLayout = function(self)
			btnLoad:SetPos(self:GetWide() - 172, 6)
			btnDel:SetPos(self:GetWide() - 86, 6)
		end
	end

	if not hasAny then
		local empty = listPanel:Add("DLabel")
		empty:Dock(TOP)
		empty:DockMargin(8, 10, 8, 0)
		empty:SetText("No presets yet. Save your current setup to create one.")
		empty:SetFont("DermaDefault")
		empty:SetTextColor(UI.muted)
		empty:SetTall(22)
	end
end

local function BuildSettingsContent(frame, parent)
	parent.Paint = PaintRounded(UI.bg, 0)

	local topCard = vgui.Create("DPanel", parent)
	topCard:Dock(TOP)
	topCard:DockMargin(8, 8, 8, 6)
	topCard:SetTall(74)
	topCard.Paint = function(_, w, h)
		draw.RoundedBox(8, 0, 0, w, h, UI.panel)
		draw.RoundedBox(8, 0, 0, 5, h, UI.accent)
	end

	AddTitle(topCard, "IK Foot Settings", 10, "DermaLarge", UI.text)
	AddTitle(topCard, "Tune behavior in clear sections below.", 42, "DermaDefault", UI.muted)

	local actions = vgui.Create("DPanel", parent)
	actions:Dock(BOTTOM)
	actions:DockMargin(8, 6, 8, 8)
	actions:SetTall(40)
	actions.Paint = nil

	local btnReset = vgui.Create("DButton", actions)
	btnReset:Dock(LEFT)
	btnReset:DockMargin(0, 0, 6, 0)
	btnReset:SetWide(170)
	btnReset:SetText("Reset to Defaults")
	StyleButton(btnReset, Color(62, 69, 84), Color(75, 84, 102))
	btnReset.DoClick = function()
		ResetToDefaults()
		frame:RefreshSliders()
	end

	local btnSuggest = vgui.Create("DButton", actions)
	btnSuggest:Dock(LEFT)
	btnSuggest:DockMargin(0, 0, 6, 0)
	btnSuggest:SetWide(200)
	btnSuggest:SetText("Suggest for Model")
	StyleButton(btnSuggest, Color(50, 130, 80), Color(65, 160, 100))
	btnSuggest.DoClick = function()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		if not IKFoot.MeasureModel then
			chat.AddText(Color(255, 100, 100), "[IK Foot] ", Color(255, 255, 255), "Measurement function not available. Reload the addon.")
			return
		end

		local suggested, err, info = IKFoot.MeasureModel(ply)
		if not suggested then
			chat.AddText(Color(255, 100, 100), "[IK Foot] ", Color(255, 255, 255), "Cannot measure model: " .. (err or "unknown error"))
			return
		end

		local byKey = IKFoot.Config.byKey
		for key, value in pairs(suggested) do
			local entry = byKey[key]
			if entry then
				RunConsoleCommand(entry.cvar, tostring(value))
			end
		end

		frame:RefreshSliders()

		local modelShort = string.GetFileFromFilename(info.model or "unknown") or "model"
		chat.AddText(
			Color(100, 255, 100), "[IK Foot] ",
			Color(255, 255, 255), "Suggested settings applied for ",
			Color(100, 200, 255), modelShort
		)
		chat.AddText(
			Color(100, 255, 100), "[IK Foot] ",
			Color(180, 180, 180), string.format("  Leg=%.1f  Sole=%.2f  Scale=%.2f  MeshZ=%.1f", info.legLength, info.soleOffset, info.scale, info.meshBottomZ or 0)
		)
		if info.meshFootLength and info.meshFootLength > 0 then
			chat.AddText(
				Color(100, 255, 100), "[IK Foot] ",
				Color(180, 180, 180), string.format("  FootLen=%.1f  FootWid=%.1f  Verts=%d", info.meshFootLength, info.meshFootWidth or 0, info.meshFootVertCount or 0)
			)
		end
	end

	local btnHardReset = vgui.Create("DButton", actions)
	btnHardReset:Dock(LEFT)
	btnHardReset:DockMargin(0, 0, 6, 0)
	btnHardReset:SetWide(170)
	btnHardReset:SetText("Reset Character")
	StyleButton(btnHardReset, Color(150, 70, 70), Color(185, 85, 85))
	btnHardReset.DoClick = function()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		if IKFoot.HardReset then
			IKFoot.HardReset(ply)
		end
		frame:RefreshSliders()
	end

	local hint = vgui.Create("DLabel", actions)
	hint:Dock(FILL)
	hint:SetText("Changes apply immediately and sync to server.")
	hint:SetFont("DermaDefault")
	hint:SetTextColor(UI.muted)
	hint:SetContentAlignment(4)

	local settingsScroll = vgui.Create("DScrollPanel", parent)
	settingsScroll:Dock(FILL)
	settingsScroll:DockMargin(8, 0, 8, 0)

	frame.Sliders = {}
	local byKey = BuildCategoryEntryLookup()

	for _, category in ipairs(CATEGORIES) do
		local cat = vgui.Create("DCollapsibleCategory", settingsScroll)
		cat:Dock(TOP)
		cat:DockMargin(0, 0, 0, 8)
		cat:SetLabel(category.title)
		cat:SetExpanded(true)
		cat.Header:SetTall(28)
		cat.Header:SetFont("DermaDefaultBold")
		cat.Header:SetTextColor(UI.text)
		cat.Header.Paint = function(self, w, h)
			draw.RoundedBox(6, 0, 0, w, h, UI.panel)
			draw.RoundedBox(6, 0, 0, 4, h, UI.accent)
		end

		local content = vgui.Create("DPanel")
		content.Paint = function(_, w, h)
			draw.RoundedBox(6, 0, 0, w, h, UI.panelSoft)
		end
		content:DockPadding(6, 6, 6, 4)
		cat:SetContents(content)

		for _, key in ipairs(category.keys) do
			local cv = byKey[key]
			if cv then
				local slider = vgui.Create("DNumSlider", content)
				slider:Dock(TOP)
				slider:DockMargin(4, 2, 4, 2)
				slider:SetText(cv.desc)
				slider:SetMin(cv.min)
				slider:SetMax(cv.max)
				slider:SetDecimals(cv.decimals)
				slider:SetConVar(cv.cvar)
				slider.CVarName = cv.cvar
				local cvar = GetConVar(cv.cvar)
				if cvar then
					slider:SetValue(cvar:GetFloat())
				end

				table.insert(frame.Sliders, slider)
			end
		end
	end
end

local function BuildPresetsContent(frame, parent)
	parent.Paint = PaintRounded(UI.bg, 0)

	local topCard = vgui.Create("DPanel", parent)
	topCard:Dock(TOP)
	topCard:DockMargin(8, 8, 8, 6)
	topCard:SetTall(96)
	topCard.Paint = function(_, w, h)
		draw.RoundedBox(8, 0, 0, w, h, UI.panel)
		draw.RoundedBoxEx(8, 0, 0, w, 30, UI.accentSoft, true, true, false, false)
		draw.RoundedBox(8, 0, 0, 4, h, UI.accent)
	end

	AddTitle(topCard, "Preset Manager", 10, "DermaLarge", UI.text)
	AddTitle(topCard, "Save and switch between favorite configurations.", 42, "DermaDefault", UI.muted)

	local txtPresetName = vgui.Create("DTextEntry", topCard)
	txtPresetName:SetPos(12, 64)
	txtPresetName:SetSize(390, 24)
	txtPresetName:SetPlaceholderText("Preset name...")
	StyleTextEntry(txtPresetName)

	local btnSave = vgui.Create("DButton", topCard)
	btnSave:SetPos(408, 63)
	btnSave:SetSize(130, 26)
	btnSave:SetText("Save Current")
	StyleButton(btnSave, Color(55, 115, 175), Color(70, 140, 210))
	btnSave.DoClick = function()
		local name = txtPresetName:GetValue()
		if CreatePreset(name) then
			txtPresetName:SetValue("")
			RefreshPresetList(parent.PresetList)
		end
	end
	txtPresetName.OnEnter = function()
		btnSave:DoClick()
	end

	local listTitle = vgui.Create("DLabel", parent)
	listTitle:Dock(TOP)
	listTitle:DockMargin(14, 2, 8, 2)
	listTitle:SetText("Saved presets")
	listTitle:SetFont("DermaDefaultBold")
	listTitle:SetTextColor(UI.text)
	listTitle:SetTall(20)

	local listScroll = vgui.Create("DScrollPanel", parent)
	listScroll:Dock(FILL)
	listScroll:DockMargin(8, 0, 8, 8)

	parent.PresetList = listScroll
	RefreshPresetList(listScroll)
end

local function BuildCreditsContent(parent)
	parent.Paint = PaintRounded(UI.bg, 0)

	local card = vgui.Create("DPanel", parent)
	card:Dock(FILL)
	card:DockMargin(8, 8, 8, 8)
	card.Paint = function(_, w, h)
		draw.RoundedBox(10, 0, 0, w, h, UI.panel)
		draw.RoundedBox(10, 0, 0, 5, h, UI.accent)
	end

	AddTitle(card, "Credits", 16, "DermaLarge", UI.text)
	AddTitle(card, "IK Foot System", 56, "DermaDefaultBold", UI.text)
	AddTitle(card, "Created by: nikt_ani_nic", 84, "DermaDefault", UI.text)
	AddTitle(card, "Inspiration: steamcommunity.com/sharedfiles/filedetails/?id=1605334558", 106, "DermaDefault", UI.muted)
	AddTitle(card, "Thanks for using and testing the addon.", 140, "DermaDefault", UI.muted)
	AddTitle(card, "Command: ik_foot_menu  |  Chat: !ikfoot / /ikfoot", 172, "DermaDefault", UI.muted)
end

local function CreateGUI()
	if IsValid(PANEL) then
		PANEL:Remove()
	end
	
	LoadPresets()
	
	local frame = vgui.Create("DFrame")
	frame:SetSize(820, 700)
	frame:Center()
	frame:SetTitle("IK Foot System")
	frame:SetVisible(true)
	frame:SetDraggable(true)
	frame:ShowCloseButton(true)
	frame:MakePopup()
	frame.Paint = function(self, w, h)
		draw.RoundedBox(8, 0, 0, w, h, UI.bg)
		draw.RoundedBox(8, 0, 0, w, 24, UI.panel)
	end
	PANEL = frame
	
	local tabs = vgui.Create("DPropertySheet", frame)
	tabs:Dock(FILL)
	tabs:DockMargin(6, 6, 6, 6)
	
	local settingsPanel = vgui.Create("DPanel", tabs)
	settingsPanel:Dock(FILL)
	BuildSettingsContent(frame, settingsPanel)
	tabs:AddSheet("Settings", settingsPanel, "icon16/cog.png")
	
	local presetsPanel = vgui.Create("DPanel", tabs)
	presetsPanel:Dock(FILL)
	BuildPresetsContent(frame, presetsPanel)
	tabs:AddSheet("Presets", presetsPanel, "icon16/disk.png")

	local creditsPanel = vgui.Create("DPanel", tabs)
	creditsPanel:Dock(FILL)
	BuildCreditsContent(creditsPanel)
	tabs:AddSheet("Credits", creditsPanel, "icon16/information.png")
	
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

IKFoot.OpenMenu = CreateGUI

net.Receive(OPEN_MENU_NET, function()
	if not IKFoot or not IKFoot.OpenMenu then return end
	IKFoot.OpenMenu()
end)

concommand.Add("ik_foot_menu", function()
	IKFoot.OpenMenu()
end)

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
