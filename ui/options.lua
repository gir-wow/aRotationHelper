-- aRotationHelper / ui/options.lua

local ADDON_NAME, ns = ...

local Options = {}
ns.Options = Options

local function checkbox(panel, y, label, key)
    local box = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    box:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, y)
    box.Text:SetText(label)
    box:SetScript("OnShow", function(self) self:SetChecked(ns.db[key] and true or false) end)
    box:SetScript("OnClick", function(self) ns.db[key] = self:GetChecked() and true or false end)
    return box
end

function Options:Init()
    if self.panel then return end
    local panel = CreateFrame("Frame", "aRotationHelperOptions")
    panel.name = "aRotationHelper"
    self.panel = panel

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("aRotationHelper")

    local description = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    description:SetText("Next-action advice for Brewmaster Monk and Blood Death Knight.")

    local profile = CreateFrame("Frame", nil, panel, "UIDropDownMenuTemplate")
    profile:SetPoint("TOPLEFT", description, "BOTTOMLEFT", -16, -16)
    UIDropDownMenu_SetWidth(profile, 140)
    UIDropDownMenu_SetText(profile, "Profile")
    UIDropDownMenu_Initialize(profile, function(_, level)
        for _, key in ipairs({ "defensive", "balanced", "offensive" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = ns.PROFILES[key].label
            info.checked = ns.db.profile == key
            info.func = function()
                ns.db.profile = key
                UIDropDownMenu_SetText(profile, ns.PROFILES[key].label)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    panel:SetScript("OnShow", function()
        UIDropDownMenu_SetText(profile, ns.Adapt:Profile().label)
    end)

    checkbox(panel, -118, "Lock display position", "locked")
    checkbox(panel, -148, "Enable debug logging", "debug")

    local queueLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    queueLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -188)
    queueLabel:SetText("Queue depth")
    local queue = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
    queue:SetPoint("TOPLEFT", queueLabel, "BOTTOMLEFT", 0, -16)
    queue:SetMinMaxValues(1, 3)
    queue:SetValueStep(1)
    queue:SetObeyStepOnDrag(true)
    queue:SetWidth(180)
    queue.Low:SetText("1")
    queue.High:SetText("3")
    queue:SetScript("OnShow", function(self) self:SetValue(ns.db.queueDepth or 3) end)
    queue:SetScript("OnValueChanged", function(_, value)
        if ns.db then ns.db.queueDepth = math.floor(value + 0.5) end
    end)

    local log = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    log:SetPoint("TOPLEFT", queue, "BOTTOMLEFT", 0, -24)
    log:SetSize(140, 22)
    log:SetText("Open Log Window")
    log:SetScript("OnClick", function() ns.Export:ShowLog() end)

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    elseif Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    end
end
