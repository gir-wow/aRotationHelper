-- aRotationHelper / aRotationHelper.lua
--
-- Wiring: saved variables, event registration, the update loop, and the public
-- API that a WeakAura can call instead of using our display.

local ADDON_NAME, ns = ...

ns.version = "0.1.0-phase1"

-- ---------------------------------------------------------------------------
-- debug
-- ---------------------------------------------------------------------------
function ns.Debug(msg)
    if ns.db and ns.db.debug then
        ns.Export:Add(msg)
    end
end

function ns.Log(msg)
    ns.Export:Add(msg)
    ns.Export:ShowLog()
end

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------
local engine, state, rotation
local rotationError
local UPDATE_THROTTLE = 0.1
local accum = 0
local lastQueue = {}

local frame = CreateFrame("Frame", "aRotationHelperCore")

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------
local function loadRotation()
    local data, err = ns.ResolveRotation()
    if not data then
        rotation = nil
        rotationError = err
        if engine then engine:SetRotation(nil) end
        ns.Debug("no rotation: " .. tostring(err))
        if ns.Display then ns.Display:Hide() end
        return false
    end
    rotation = ns.Rotation.New(data)
    rotationError = nil
    state:Refresh()
    rotation:Rehydrate(state)
    engine:SetRotation(rotation)
    return true
end
ns.LoadRotation = loadRotation

--- Rebuild the set of spells we know. Driven by learn/talent events, and the
--- mechanism that makes the addon usable while levelling.
local function refreshKnownSpells()
    if not state then return end
    wipe(state.knownSpells)
    -- Walk every spell referenced by the loaded rotation plus the adaptation
    -- layer's own list, rather than the whole spellbook: it is a much smaller set
    -- and it is exactly what we need to answer LineApplies.
    local function note(id)
        if not id then return end
        local known = (IsPlayerSpell and IsPlayerSpell(id)) or (IsSpellKnown and IsSpellKnown(id))
        state.knownSpells[id] = known and true or nil
    end
    if rotation then
        for _, line in ipairs(rotation.all) do
            if line.action.id then note(line.action.id) end
            for _, id in ipairs(line.spells or {}) do note(id) end
        end
        for _, p in ipairs(rotation.prepull) do
            if p.action.id then note(p.action.id) end
        end
    end
    for _, id in pairs(ns.SpellIDs) do note(id) end
end
ns.RefreshKnownSpells = refreshKnownSpells

-- ---------------------------------------------------------------------------
-- update loop
-- ---------------------------------------------------------------------------
local function update()
    if not engine or not rotation then return end
    state:Refresh()

    local depth = (ns.db and ns.db.queueDepth) or 3
    local _, classFile = UnitClass("player")
    if classFile == "DEATHKNIGHT" then depth = 1 end
    lastQueue = engine:Queue(state, depth)
    ns.Display:Render(lastQueue, state)

    if not InCombatLockdown() then
        ns.Display:RenderPrepull(rotation:PrepullPlan(state), state)
    end
end

frame:SetScript("OnUpdate", function(_, elapsed)
    accum = accum + elapsed
    if accum < UPDATE_THROTTLE then return end
    accum = 0
    update()
end)

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
local EVENTS = {
    "PLAYER_LOGIN",
    "PLAYER_ALIVE",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "COMBAT_LOG_EVENT_UNFILTERED",
    -- rotation rehydration (levelling, talents, glyphs, gear)
    "PLAYER_LEVEL_UP",
    "SPELLS_CHANGED",
    "LEARNED_SPELL_IN_TAB",
    "PLAYER_TALENT_UPDATE",
    "PLAYER_SPECIALIZATION_CHANGED",
    "GLYPH_UPDATED",
    "PLAYER_EQUIPMENT_CHANGED",
    -- keybinds
    "UPDATE_BINDINGS",
    "ACTIONBAR_SLOT_CHANGED",
    "ACTIONBAR_PAGE_CHANGED",
    -- immediate state invalidation
    "UNIT_POWER_UPDATE",
    "UNIT_AURA",
    "SPELL_UPDATE_COOLDOWN",
    "PLAYER_TARGET_CHANGED",
}

local REHYDRATE = {
    PLAYER_LEVEL_UP = true,
    SPELLS_CHANGED = true,
    LEARNED_SPELL_IN_TAB = true,
    PLAYER_TALENT_UPDATE = true,
    GLYPH_UPDATED = true,
    PLAYER_EQUIPMENT_CHANGED = true,
}

local KEYBIND_DIRTY = {
    UPDATE_BINDINGS = true,
    ACTIONBAR_SLOT_CHANGED = true,
    ACTIONBAR_PAGE_CHANGED = true,
}

for _, e in ipairs(EVENTS) do
    local ok = pcall(frame.RegisterEvent, frame, e)
    if not ok then ns.Debug("could not register event " .. e) end
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        ns.Threat:OnCombatLogEvent()
        ns.Threat:OnHealEvent()
        return
    end

    if event == "PLAYER_LOGIN" then
        aRotationHelperDB = aRotationHelperDB or {}
        ns.db = setmetatable(aRotationHelperDB, { __index = ns.DEFAULTS })
        state = ns.State.New()
        engine = ns.Engine.New()
        ns.Threat:Init()
        ns.Display:Init()
        ns.Options:Init()
        loadRotation()
        refreshKnownSpells()
        if rotation then rotation:Rehydrate(state) end
        ns.Export:Add(("%s loaded."):format(ns.version))
        return
    end

    if not state then return end

    if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_ALIVE" then
        loadRotation()
        refreshKnownSpells()
        if rotation then rotation:Rehydrate(state) end
        return
    end

    if REHYDRATE[event] then
        refreshKnownSpells()
        if rotation then rotation:Rehydrate(state) end
        return
    end

    if KEYBIND_DIRTY[event] then
        ns.Keybind:Invalidate()
        return
    end

    if event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" and rotation then
            state:Refresh()
            rotation:Rehydrate(state)
        end
        return
    end

    if event == "PLAYER_REGEN_DISABLED" then
        ns.Threat:OnCombatStart()
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        ns.Threat:OnCombatEnd()
        ns.Targets:Reset()
        return
    end

    if event == "SPELL_UPDATE_COOLDOWN" then
        wipe(state.cds)
        return
    end
end)

-- ---------------------------------------------------------------------------
-- public API (for WeakAuras and other addons)
-- ---------------------------------------------------------------------------
-- Exposed globally so the existing WeakAura can keep its visuals and just ask us
-- what to press:
--     local id = aRotationHelper:NextAction()
_G.aRotationHelper = {
    --- Spell id to press right now, or nil.
    NextAction = function()
        local pick = lastQueue and lastQueue[1]
        return pick and pick.action and pick.action.id or nil
    end,
    --- Array of up to `n` spell ids. Index 1 is advice; 2+ are a forecast.
    Queue = function(_, n)
        local out = {}
        for i = 1, math.min(n or 3, #(lastQueue or {})) do
            local p = lastQueue[i]
            if p and p.action then out[i] = p.action.id end
        end
        return out
    end,
    --- Short label explaining why the primary suggestion fired.
    Reason = function()
        local pick = lastQueue and lastQueue[1]
        return pick and pick.reason or nil
    end,
    --- True while the survival tier is overriding the rotation.
    IsEmergency = function()
        local pick = lastQueue and lastQueue[1]
        return pick and pick.tier == ns.TIER.EMERGENCY or false
    end,
    --- Predicted seconds-to-live, or nil when nothing is hitting us.
    TimeToLive = function()
        return state and ns.Threat:TimeToLive(state) or nil
    end,
}

-- ---------------------------------------------------------------------------
-- slash command
-- ---------------------------------------------------------------------------
SLASH_AROTATIONHELPER1 = "/arh"
SlashCmdList["AROTATIONHELPER"] = function(msg)
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "profile" and ns.PROFILES[arg] then
        ns.db.profile = arg
        ns.Log("profile -> " .. ns.PROFILES[arg].label)
    elseif cmd == "debug" then
        ns.db.debug = not ns.db.debug
        ns.Log("debug " .. (ns.db.debug and "on" or "off"))
    elseif cmd == "lock" then
        ns.db.locked = not ns.db.locked
        ns.Log(ns.db.locked and "locked" or "unlocked (drag to move)")
    elseif cmd == "status" then
        local lines = { ns.version, ("profile: %s (emergency TTL %.1fs)"):format(ns.Adapt:Profile().label, ns.Adapt:EmergencyTTL()) }
        if rotation then
            lines[#lines + 1] = ("rotation: %s -- %d/%d lines active"):format(rotation.data.key, #rotation.active, #rotation.all)
            for _, d in ipairs(rotation.dropped) do lines[#lines + 1] = ("  dropped #%d: %s"):format(d.idx, d.why) end
        else
            lines[#lines + 1] = "rotation: none loaded -- " .. tostring(rotationError or "unknown reason")
        end
        local ttl = state and ns.Threat:TimeToLive(state)
        lines[#lines + 1] = ("targets: %d (%s)  ttl: %s"):format(ns.Targets.lastCount, ns.Targets.mode, ttl and ("%.1fs"):format(ttl) or "n/a")
        ns.Log(table.concat(lines, "\n"))
    elseif cmd == "runes" then
        ns.Runes:PrintSnapshot()
    elseif cmd == "log" then
        ns.Export:ShowLog()
    else
        ns.Log("commands:\n/arh profile defensive|balanced|offensive\n/arh lock\n/arh status\n/arh runes\n/arh log\n/arh debug")
    end
end
