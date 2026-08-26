-- aRotationHelper / ui/export.lua
--
-- Small copyable text dialog for diagnostics and future exports.

local ADDON_NAME, ns = ...

local Export = {}
ns.Export = Export

local entries = {}
local MAX_ENTRIES = 200

function Export:Add(text)
    entries[#entries + 1] = date("%H:%M:%S") .. "  " .. tostring(text)
    if #entries > MAX_ENTRIES then table.remove(entries, 1) end
    if self.frame and self.frame:IsShown() then self:ShowLog() end
end

function Export:ShowLog()
    self:Show("aRotationHelper — Log", table.concat(entries, "\n"))
end

function Export:Show(title, text)
    if not self.frame then
        local frame = CreateFrame("Frame", "aRotationHelperExportFrame", UIParent, "BasicFrameTemplateWithInset")
        frame:SetSize(560, 330)
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        frame:SetFrameStrata("DIALOG")
        self.frame = frame

        local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", frame.InsetBg or frame, "TOPLEFT", 8, -30)
        scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 42)
        frame.scroll = scroll

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject("GameFontHighlightSmall")
        edit:SetWidth(scroll:GetWidth() - 10)
        edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        scroll:SetScrollChild(edit)
        frame.edit = edit

        local select = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        select:SetSize(90, 22)
        select:SetPoint("BOTTOM", frame, "BOTTOM", 0, 10)
        select:SetText("Select All")
        select:SetScript("OnClick", function()
            edit:SetFocus()
            edit:HighlightText()
        end)
    end

    self.frame.TitleText:SetText(title)
    self.frame.edit:SetText(text or "")
    self.frame.edit:SetCursorPosition(0)
    self.frame.edit:SetFocus()
    self.frame.edit:HighlightText()
    self.frame:Show()
end
