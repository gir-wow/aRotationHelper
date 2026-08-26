-- aRotationHelper / core/keybind.lua
--
-- Resolve spellID -> the key the player actually presses.
--
-- Two paths, because custom bar addons defeat the simple one:
--   1. Blizzard bars: map action slot -> binding name -> GetBindingKey.
--   2. Anything else (Bartender4, ElvUI, Dominos): read the hotkey text off the
--      real button frame. This is the approach Hekili uses on retail, and it is
--      the only thing that survives a rebinding addon.

local ADDON_NAME, ns = ...

local Keybind = {}
Keybind.__index = Keybind
ns.Keybind = Keybind

Keybind.map = {}     -- [spellId] = "S2"
Keybind.dirty = true

-- Blizzard action-slot -> binding name. Keyed by the slot block's base offset.
local BAR_BINDING = {
    [0]  = "ACTIONBUTTON%d",           -- slots  1-12  (current page)
    [24] = "MULTIACTIONBAR3BUTTON%d",  -- slots 25-36  (right bar 1)
    [36] = "MULTIACTIONBAR4BUTTON%d",  -- slots 37-48  (right bar 2)
    [48] = "MULTIACTIONBAR2BUTTON%d",  -- slots 49-60  (bottom right)
    [60] = "MULTIACTIONBAR1BUTTON%d",  -- slots 61-72  (bottom left)
}

-- Button name patterns used by the common bar addons. `%d` slots vary in meaning
-- per addon, so we always confirm via GetAttribute("action") rather than assuming.
local BUTTON_PATTERNS = {
    "ActionButton%d",
    "MultiBarBottomLeftButton%d",
    "MultiBarBottomRightButton%d",
    "MultiBarRightButton%d",
    "MultiBarLeftButton%d",
    "BT4Button%d",
    "DominosActionButton%d",
}

local ABBREV = {
    { "MOUSE WHEEL DOWN", "WD" }, { "MOUSE WHEEL UP", "WU" },
    { "MOUSEWHEELDOWN", "WD" }, { "MOUSEWHEELUP", "WU" },
    { "SHIFT%-", "S" }, { "CTRL%-", "C" }, { "ALT%-", "A" },
    { "BUTTON", "M" }, { "NUMPAD", "N" }, { "SPACE", "Sp" },
}

local function abbreviate(key)
    if not key or key == "" then return nil end
    local out = key:upper()
    local modifier = ""
    if out:find("SHIFT", 1, true) then modifier = modifier .. "S" end
    if out:find("CTRL", 1, true) then modifier = modifier .. "C" end
    if out:find("ALT", 1, true) then modifier = modifier .. "A" end
    -- Do this as a direct classification. Hotkey text from bar addons is not a
    -- stable binding token: it can be "MOUSE WHEEL DOWN", "MOUSEWHEELDOWN",
    -- or a localized display string with embedded whitespace.
    if out:find("MOUSE", 1, true) then
        if out:find("DOWN", 1, true) then return modifier .. "WD" end
        if out:find("UP", 1, true) then return modifier .. "WU" end
        local button = out:match("BUTTON%s*(%d+)") or out:match("MOUSE%s*(%d+)")
        return modifier .. "M" .. (button or "")
    end
    -- ElvUI may supply this as text with variable whitespace rather than the
    -- binding token (MOUSEWHEELDOWN), so normalise it before the generic map.
    out = out:gsub("MOUSE%s*WHEEL%s*DOWN", "WD")
    out = out:gsub("MOUSE%s*WHEEL%s*UP", "WU")
    for _, rule in ipairs(ABBREV) do out = out:gsub(rule[1], rule[2]) end
    return out
end

--- Spell behind an action slot, resolving macros to their spell.
local function slotSpell(slot)
    local kind, id = GetActionInfo(slot)
    if kind == "spell" then return id end
    if kind == "macro" and GetMacroSpell then
        local sid = GetMacroSpell(id)
        if sid then return sid end
    end
    return nil
end

function Keybind:ScanBlizzardBars()
    for slot = 1, 120 do
        local spellId = slotSpell(slot)
        if spellId then
            local base = math.floor((slot - 1) / 12) * 12
            local fmt = BAR_BINDING[base]
            if fmt then
                local key = GetBindingKey(fmt:format(slot - base))
                if key then
                    self.map[spellId] = abbreviate(GetBindingText and GetBindingText(key, "KEY_") or key)
                end
            end
        end
    end
end

--- Read hotkey text straight off button frames. Wins over the Blizzard mapping
--- because it reflects whatever the player's bar addon actually did.
function Keybind:ScanButtonFrames()
    -- LibActionButton-backed addons (ElvUI, Bartender4) register their buttons.
    local lab = LibStub and LibStub("LibActionButton-1.0", true)
    if lab and lab.GetAllButtons then
        for button in pairs(lab:GetAllButtons()) do
            local ok, slot = pcall(function() return button:GetAttribute("action") end)
            if ok and slot then
                local spellId = slotSpell(slot)
                local hk = button.HotKey
                if spellId and hk then
                    local text = hk:GetText()
                    if text and text ~= "" and text ~= RANGE_INDICATOR then
                        self.map[spellId] = abbreviate(text)
                    end
                end
            end
        end
    end

    for _, pat in ipairs(BUTTON_PATTERNS) do
        for i = 1, 12 do
            local b = _G[pat:format(i)]
            if b and b.GetAttribute then
                local ok, slot = pcall(function() return b:GetAttribute("action") end)
                if ok and slot then
                    local spellId = slotSpell(slot)
                    local hk = b.HotKey
                    if spellId and hk then
                        local text = hk:GetText()
                        if text and text ~= "" and text ~= RANGE_INDICATOR then
                            self.map[spellId] = abbreviate(text)
                        end
                    end
                end
            end
        end
    end
end

function Keybind:Rebuild()
    wipe(self.map)
    self:ScanBlizzardBars()
    self:ScanButtonFrames()   -- second, so it overrides where it disagrees
    self.dirty = false
end

function Keybind:For(spellId)
    if self.dirty then self:Rebuild() end
    return self.map[spellId]
end

function Keybind:Invalidate()
    self.dirty = true
end
