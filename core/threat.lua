-- aRotationHelper / core/threat.lua
--
-- Incoming damage rate, effective health, and predicted time-to-live.
--
-- This is the part with no counterpart in the simulator at all. The sim gates
-- defensives on current health (`hpPercentForDefensives`, default 0.3) and gets
-- away with it because it also simulates the healer. We cannot, and current
-- health is a lagging indicator regardless: at 30% the decision was needed two
-- seconds ago.
--
-- Time-to-live reacts to damage RATE, so it fires early during a spike and stays
-- quiet during slow attrition where 40% health is perfectly safe.

local ADDON_NAME, ns = ...

local Threat = {}
Threat.__index = Threat
ns.Threat = Threat

local WINDOW = 3.0          -- seconds of damage history used for the rate
local MAX_SAMPLES = 128

Threat.samples = {}         -- ring of { t = time, amount = damage }
Threat.head = 0
Threat.combatStart = nil
Threat.playerGUID = nil

function Threat:Init()
    self.playerGUID = UnitGUID and UnitGUID("player") or nil
    wipe(self.samples)
    self.head = 0
end

function Threat:OnCombatStart()
    self.combatStart = GetTime()
    wipe(self.samples)
    self.head = 0
end

function Threat:OnCombatEnd()
    self.combatStart = nil
    wipe(self.samples)
    self.head = 0
end

function Threat:CombatTime()
    if not self.combatStart then return 0 end
    return GetTime() - self.combatStart
end

--- Record a damage-taken event. Called from the combat log handler.
function Threat:AddDamage(amount)
    if not amount or amount <= 0 then return end
    self.head = (self.head % MAX_SAMPLES) + 1
    self.samples[self.head] = { t = GetTime(), amount = amount }
end

--- Damage taken per second over the trailing window.
function Threat:DamagePerSecond()
    local now = GetTime()
    local cutoff = now - WINDOW
    local total = 0
    for i = 1, MAX_SAMPLES do
        local s = self.samples[i]
        if s and s.t >= cutoff then total = total + s.amount end
    end
    return total / WINDOW
end

--- Effective health: raw health plus everything that will absorb damage before it
--- reaches the health bar. For a Brewmaster the stagger pool is most of your
--- survivability, so leaving it out badly understates you.
function Threat:EffectiveHealth(st)
    local hp = st and st:Health() or (UnitHealth("player") or 0)
    local stagger = 0
    if UnitStagger then stagger = UnitStagger("player") or 0 end
    local absorb = 0
    if UnitGetTotalAbsorbs then absorb = UnitGetTotalAbsorbs("player") or 0 end
    return hp + stagger + absorb
end

--- Seconds until death at the current damage rate, or nil when nothing is
--- happening. Returning nil rather than a huge number keeps callers honest about
--- the difference between "safe" and "no data".
function Threat:TimeToLive(st)
    local dps = self:DamagePerSecond()
    if dps <= 0 then return nil end
    return self:EffectiveHealth(st) / dps
end

-- ---------------------------------------------------------------------------
-- combat log
-- ---------------------------------------------------------------------------
local DAMAGE_EVENTS = {
    SWING_DAMAGE = true,
    RANGE_DAMAGE = true,
    SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true,
    SPELL_BUILDING_DAMAGE = true,
    ENVIRONMENTAL_DAMAGE = true,
}

function Threat:OnCombatLogEvent()
    local _, subEvent, _, _, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
    if destGUID ~= self.playerGUID then
        -- Also learn Expel Harm's real heal size, so the quality tiers in
        -- adapt.lua use an observed number instead of an estimate.
        return
    end

    if DAMAGE_EVENTS[subEvent] then
        local amount
        if subEvent == "SWING_DAMAGE" then
            amount = select(12, CombatLogGetCurrentEventInfo())
        elseif subEvent == "ENVIRONMENTAL_DAMAGE" then
            amount = select(13, CombatLogGetCurrentEventInfo())
        else
            amount = select(15, CombatLogGetCurrentEventInfo())
        end
        self:AddDamage(amount)
    end
end

--- Watch our own Expel Harm heals so adapt.lua can learn the real heal size.
function Threat:OnHealEvent()
    local _, subEvent, _, sourceGUID, _, _, _, _, _, _, _, spellId, _, _, amount, overheal =
        CombatLogGetCurrentEventInfo()
    if sourceGUID ~= self.playerGUID then return end
    if subEvent ~= "SPELL_HEAL" and subEvent ~= "SPELL_PERIODIC_HEAL" then return end
    if spellId ~= ns.SpellIDs.EXPEL_HARM then return end
    -- The sim uses EFFECTIVE healing to scale the damage component, so record the
    -- raw amount (effective + overheal) as the ability's potential.
    ns.Adapt:NoteExpelHarmHeal((amount or 0) + (overheal or 0))
end
