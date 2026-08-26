-- aRotationHelper / ui/display.lua
--
-- The overlay: one primary icon plus a dimmer forecast and a keybind.
--
-- Two deliberate design rules:
--   * The queue is a FORECAST, not a commitment. Steps 2-3 are drawn smaller and
--     dimmer so their lower confidence is visible, because projection cannot see
--     incoming damage.
--   * When the survival tier fires, the queue COLLAPSES to a single icon with a
--     distinct border. In an emergency a forecast is noise; you want one
--     unambiguous button.

local ADDON_NAME, ns = ...

local Display = {}
Display.__index = Display
ns.Display = Display

local ICON_MAIN = 52
local ICON_QUEUE = 34
local PAD = 6

local COLOR_NORMAL = { 0, 0, 0, 0.75 }
local COLOR_EMERGENCY = { 0.9, 0.1, 0.1, 1 }
local COLOR_CAUTION = { 0.95, 0.7, 0.1, 1 }

-- ---------------------------------------------------------------------------
-- frame construction
-- ---------------------------------------------------------------------------
local function makeIcon(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)

    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    f.border = f:CreateTexture(nil, "BACKGROUND")
    f.border:SetPoint("TOPLEFT", -2, 2)
    f.border:SetPoint("BOTTOMRIGHT", 2, -2)
    f.border:SetColorTexture(0, 0, 0, 0.8)

    f.key = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.key:SetPoint("TOPRIGHT", -1, -1)
    f.key:SetTextColor(1, 1, 1, 1)

    f.cooldown = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.cooldown:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.cooldown:SetTextColor(1, 1, 1, 1)

    f:Hide()
    return f
end

function Display:Init()
    local root = CreateFrame("Frame", "aRotationHelperFrame", UIParent)
    root:SetSize(ICON_MAIN + (ICON_QUEUE + PAD) * 2, ICON_MAIN)
    root:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 1100, 585)
    root:SetMovable(true)
    root:EnableMouse(true)
    root:RegisterForDrag("LeftButton")
    root:SetScript("OnDragStart", function(s) if not ns.db.locked then s:StartMoving() end end)
    root:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        local p, _, rp, x, y = s:GetPoint()
        ns.db.pos = { p, rp, x, y }
    end)
    self.root = root

    self.main = makeIcon(root, ICON_MAIN)
    self.main:SetPoint("LEFT", root, "LEFT", 0, 0)

    self.idle = root:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.idle:SetPoint("CENTER", self.main, "CENTER", 0, 0)
    self.idle:SetTextColor(0.8, 0.8, 0.8, 1)
    self.idle:Hide()

    self.queue = {}
    for i = 1, 2 do
        local f = makeIcon(root, ICON_QUEUE)
        local anchor = (i == 1) and self.main or self.queue[i - 1]
        f:SetPoint("LEFT", anchor, "RIGHT", PAD, 0)
        f.tex:SetAlpha(0.55)
        self.queue[i] = f
    end

    -- Out-of-combat prepull checklist
    local pre = CreateFrame("Frame", nil, root)
    pre:SetPoint("BOTTOMLEFT", root, "TOPLEFT", 0, 8)
    pre:SetSize(240, 60)
    pre.lines = {}
    for i = 1, 5 do
        local fs = pre:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", pre, "TOPLEFT", 0, -(i - 1) * 13)
        fs:SetJustifyH("LEFT")
        pre.lines[i] = fs
    end
    pre:Hide()
    self.prepull = pre

    -- Earlier versions saved the initial far-left placement, which means a
    -- changed default never reaches existing users. Move that one-time layout
    -- to the player's unit-frame area; later drag positions remain untouched.
    if not ns.db.positionVersion or ns.db.positionVersion < 3 then
        ns.db.pos = { "BOTTOMLEFT", "BOTTOMLEFT", 1100, 585 }
        ns.db.positionVersion = 3
    end
    if ns.db.pos then
        root:ClearAllPoints()
        root:SetPoint(ns.db.pos[1], UIParent, ns.db.pos[2], ns.db.pos[3], ns.db.pos[4])
    end
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------
local function iconFor(action)
    if action.id then
        local _, _, icon = GetSpellInfo(action.id)
        return icon
    end
    return nil
end

local function paint(frame, pick, isEmergency, caution, st)
    if not pick then
        frame:Hide()
        return
    end
    local icon = iconFor(pick.action)
    if not icon then
        frame:Hide()
        return
    end
    frame.tex:SetTexture(icon)
    frame.key:SetText(pick.action.id and ns.Keybind:For(pick.action.id) or nil)
    local remain = pick.action.id and st and st:CdRemain(pick.action.id) or 0
    frame.cooldown:SetText(remain and remain > 0 and ("%.1f"):format(remain) or "")

    local c = COLOR_NORMAL
    if isEmergency then c = COLOR_EMERGENCY
    elseif caution then c = COLOR_CAUTION end
    frame.border:SetColorTexture(c[1], c[2], c[3], c[4])
    frame:Show()
end

function Display:Render(queue, st)
    if not self.root then return end

    local primary = queue and queue[1]
    if not primary then
        self.idle:Hide()
        -- Keep a previous icon only while its real cooldown recovers. A stale
        -- resource-bound action (such as Rune Strike after its RP was spent)
        -- must never look like a live recommendation.
        local function showCooldown(frame, pick)
            if pick and pick.action and pick.action.id and st:CdRemain(pick.action.id) > 0 then
                paint(frame, pick, false, false, st)
            else
                frame:Hide()
            end
        end
        if st and st:HasTarget() and self.lastQueue and self.lastQueue[1] then
            showCooldown(self.main, self.lastQueue[1])
            for i = 1, #self.queue do showCooldown(self.queue[i], self.lastQueue[i + 1]) end
        else
            self.main:Hide()
            for i = 1, #self.queue do self.queue[i]:Hide() end
        end
        return
    end

    self.idle:Hide()
    self.lastQueue = queue

    local isEmergency = primary.tier == ns.TIER.EMERGENCY
    local caution = (not isEmergency) and ns.Adapt:Caution(st) or false

    paint(self.main, primary, isEmergency, caution, st)

    -- An emergency collapses the forecast: one unambiguous button.
    if isEmergency then
        for i = 1, #self.queue do self.queue[i]:Hide() end
        return
    end

    for i = 1, #self.queue do
        paint(self.queue[i], queue[i + 1], false, false, st)
    end
end

--- Out-of-combat prepull checklist, with each item's timing offset.
function Display:RenderPrepull(plan, st)
    if not self.prepull then return end
    if not plan or #plan == 0 or InCombatLockdown() then
        self.prepull:Hide()
        return
    end
    for i = 1, #self.prepull.lines do
        local fs = self.prepull.lines[i]
        local p = plan[i]
        if not p then
            fs:SetText("")
        else
            local name = p.action.name or (p.action.id and GetSpellInfo(p.action.id)) or "?"
            local at = p.at and ("%.1fs"):format(p.at) or "?"
            -- Tick off items whose buff is already up.
            local done = p.action.id and st and st:AuraUp(p.action.id)
            fs:SetText(("%s %s at %s"):format(done and "|cff40ff40*|r" or "|cff888888-|r", name, at))
        end
    end
    self.prepull:Show()
end

function Display:Hide()
    if self.root then
        self.main:Hide()
        for i = 1, #self.queue do self.queue[i]:Hide() end
        self.idle:Hide()
        self.prepull:Hide()
    end
end
