-- aRotationHelper / core/state.lua
--
-- The live state snapshot the APL interpreter reads from.
--
-- Two responsibilities:
--   1. Cache everything the engine needs, refreshed on a throttle plus events,
--      so that evaluating 23 priority lines never calls a WoW API directly.
--   2. Support Clone() + ApplyCast(), which is what lets the engine project the
--      next 2-3 actions (see the report, section 5.4). Projection must not
--      touch the live snapshot.
--
-- Every reader here corresponds to an entry in tools/apl2lua/opcodes.mjs. If you
-- add an opcode there, add its reader here or the generator will refuse to build.

local ADDON_NAME, ns = ...

local State = {}
State.__index = State
ns.State = State

-- MoP power type indices
local POWER_ENERGY = 3
local POWER_RUNIC = 6
local POWER_CHI = 12

-- Live MoP Classic `/arh runes` verification:
-- slots 1-2 Blood (1), slots 3-4 Frost (3), slots 5-6 Unholy (2).
-- WowSims uses Frost=2 and Unholy=3, so keep the conversion here.
local LIVE_TO_APL_RUNE = {
    [1] = "RuneBlood",
    [2] = "RuneUnholy",
    [3] = "RuneFrost",
    [4] = "RuneDeath",
}

-- Stagger tier auras. The sim compares damagePerTick/maxHealth against 3% and
-- 6%, which are exactly these auras' thresholds -- so aura presence gives us the
-- comparison for free, with no arithmetic and no UnitStagger dependency.
local STAGGER_LIGHT, STAGGER_MODERATE, STAGGER_HEAVY = 124275, 124274, 124273

-- ---------------------------------------------------------------------------
-- aura scanning
-- ---------------------------------------------------------------------------
-- Client aura signatures have moved around across versions, so all aura reads
-- funnel through here. If auras ever come back empty, this is the one place to
-- fix.
local function forEachAura(unit, filter, fn)
    if AuraUtil and AuraUtil.ForEachAura then
        AuraUtil.ForEachAura(unit, filter, nil, function(...)
            local name, _, count, _, duration, expires = ...
            local spellId = select(10, ...)
            return fn(spellId, count, duration, expires, name)
        end)
        return
    end
    local get = (filter == "HELPFUL") and UnitBuff or UnitDebuff
    if not get then return end
    for i = 1, 40 do
        local name, _, count, _, duration, expires = get(unit, i)
        if not name then return end
        local spellId = select(10, get(unit, i))
        if fn(spellId, count, duration, expires, name) then return end
    end
end

local function haste()
    if GetHaste then return (GetHaste() or 0) / 100 end
    if UnitSpellHaste then return (UnitSpellHaste("player") or 0) / 100 end
    return 0
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
function State.New()
    local s = setmetatable({}, State)
    s.auras = {}        -- [spellId] = { remain, stacks }
    s.cds = {}          -- [spellId] = { remain, duration }
    s.knownSpells = {}  -- [spellId] = true
    s.knownAuras = {}   -- [spellId] = true  (aura seen at least once this session)
    s.chi, s.maxChi = 0, 4
    s.energy, s.maxEnergy, s.energyRegen = 0, 100, 10
    s.runicPower = 0
    s.runes = {}
    s.health, s.maxHealth = 1, 1
    s.staggerPct = 0
    s.gcdRemain = 0
    s.combatTime = 0
    s.numTargets = 1
    s.targetHealthPct = 1
    s.inFront = true
    s.moving = false
    s.inputDelay = 0.15
    s.baseGcd = 1.0
    s.projected = false
    return s
end

-- ---------------------------------------------------------------------------
-- live refresh
-- ---------------------------------------------------------------------------
function State:Refresh()
    local now = GetTime()

    self.chi = UnitPower("player", POWER_CHI) or 0
    self.maxChi = UnitPowerMax("player", POWER_CHI) or 4
    if self.maxChi == 0 then self.maxChi = 4 end

    self.energy = UnitPower("player", POWER_ENERGY) or 0
    self.maxEnergy = UnitPowerMax("player", POWER_ENERGY) or 100
    if self.maxEnergy == 0 then self.maxEnergy = 100 end
    self.energyRegen = 10 * (1 + haste())

    self.runicPower = UnitPower("player", POWER_RUNIC) or 0
    self:RefreshRunes(now)

    self.health = UnitHealth("player") or 1
    self.maxHealth = math.max(1, UnitHealthMax("player") or 1)

    -- auras
    wipe(self.auras)
    forEachAura("player", "HELPFUL", function(spellId, count, duration, expires)
        if not spellId then return end
        self.auras[spellId] = {
            remain = expires and expires > 0 and math.max(0, expires - now) or 3600,
            stacks = count or 0,
        }
        self.knownAuras[spellId] = true
    end)
    forEachAura("player", "HARMFUL", function(spellId, count, duration, expires)
        if not spellId then return end
        self.auras[spellId] = {
            remain = expires and expires > 0 and math.max(0, expires - now) or 3600,
            stacks = count or 0,
        }
        self.knownAuras[spellId] = true
    end)

    self.staggerPct = self:ComputeStaggerPct()
    self.gcdRemain = self:ComputeGcdRemain()

    -- target
    if UnitExists("target") and UnitCanAttack("player", "target") then
        local th, thm = UnitHealth("target"), UnitHealthMax("target")
        self.targetHealthPct = (thm and thm > 0) and (th / thm) or 1
    else
        self.targetHealthPct = 1
    end

    self.moving = (GetUnitSpeed and GetUnitSpeed("player") or 0) > 0
    self.combatTime = ns.Threat and ns.Threat:CombatTime() or 0
    self.numTargets = ns.Targets and ns.Targets:Count() or 1
end

function State:RefreshRunes(now)
    wipe(self.runes)
    if not GetRuneType or not GetRuneCooldown then return end
    for slot = 1, 6 do
        local rawType = GetRuneType(slot)
        local start, duration, ready = GetRuneCooldown(slot)
        self.runes[slot] = {
            kind = LIVE_TO_APL_RUNE[rawType],
            death = rawType == 4,
            ready = ready and true or false,
            remain = (not ready and start and duration) and math.max(0, start + duration - now) or 0,
        }
    end
end

--- Stagger as a fraction of max health, derived from the tier auras.
-- Returns a representative value inside the tier band so that the sim's
-- `>= 3%` and `> 6%` comparisons behave correctly.
function State:ComputeStaggerPct()
    if self.auras[STAGGER_HEAVY] then return 0.10 end
    if self.auras[STAGGER_MODERATE] then return 0.045 end
    if self.auras[STAGGER_LIGHT] then return 0.015 end
    -- Prefer a real reading when the client exposes one.
    if UnitStagger then
        local pool = UnitStagger("player")
        if pool and pool > 0 then
            -- Stagger ticks every second over 10s, so per-tick is pool/10.
            return (pool / 10) / self.maxHealth
        end
    end
    return 0
end

function State:ComputeGcdRemain()
    local start, duration = GetSpellCooldown(61304) -- the global-cooldown spell
    if start and duration and duration > 0 then
        return math.max(0, start + duration - GetTime())
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- readers used by the interpreter
-- ---------------------------------------------------------------------------
function State:AuraRemain(id) local a = self.auras[id]; return a and a.remain or 0 end
function State:AuraUp(id) return self:AuraRemain(id) > 0 end
function State:AuraDown(id) return self:AuraRemain(id) <= 0 end
function State:AuraStacks(id) local a = self.auras[id]; return a and a.stacks or 0 end

--- "Is this aura something my character can produce at all?"
-- Used by APL lines gated on set bonuses and talents (`auraIsKnown`). The sim
-- knows this from the equipped profile; we infer it from having seen the aura,
-- or from knowing the spell that applies it.
function State:AuraKnown(id)
    return self.knownAuras[id] == true or self.knownSpells[id] == true
end

function State:SpellKnown(id) return self.knownSpells[id] == true end

function State:CdRemain(id)
    local c = self.cds[id]
    if c then return c.remain end
    if self.projected then return 0 end
    local start, duration = GetSpellCooldown(id)
    if start and duration and duration > 0 then
        local remain = math.max(0, start + duration - GetTime())
        self.cds[id] = { remain = remain, duration = duration }
        return remain
    end
    self.cds[id] = { remain = 0, duration = 0 }
    return 0
end

function State:CdDuration(id)
    self:CdRemain(id)
    local c = self.cds[id]
    return c and c.duration or 0
end

function State:SpellReady(id) return self:CdRemain(id) <= 0 end
function State:GcdReady() return self.gcdRemain <= 0 end
function State:GcdRemain() return self.gcdRemain end
function State:HastedGcd() return self.baseGcd end
function State:InputDelay() return self.inputDelay end
function State:Chi() return self.chi end
function State:MaxChi() return self.maxChi end
function State:Energy() return self.energy end
function State:MaxEnergy() return self.maxEnergy end
function State:EnergyRegen() return self.energyRegen end
function State:RunicPower() return self.runicPower end
function State:RuneCount(kind)
    local count = 0
    for _, rune in pairs(self.runes) do
        if rune.ready and (rune.kind == kind or (kind ~= "RuneDeath" and rune.death)) then
            count = count + 1
        end
    end
    return count
end
function State:NonDeathRuneCount(kind)
    local count = 0
    for _, rune in pairs(self.runes) do
        if rune.ready and not rune.death and rune.kind == kind then count = count + 1 end
    end
    return count
end
function State:DotPercentIncrease(id) return 0 end
function State:Health() return self.health end
function State:MaxHealth() return self.maxHealth end
function State:HealthPct() return self.health / self.maxHealth end
function State:StaggerPct() return self.staggerPct end
function State:CombatTime() return self.combatTime end
function State:NumTargets() return self.numTargets end
function State:InFrontOfTarget() return self.inFront ~= false end
function State:IsMoving() return self.moving == true end

function State:EnergyTimeTo(target)
    local regen = self.energyRegen
    if regen <= 0 then return 3600 end
    return math.max(0, (target - self.energy) / regen)
end

function State:ExecutePhase(threshold)
    return self.targetHealthPct <= (threshold or 0.20)
end

--- The sim's cast readiness: cost, cooldown and range all count.
function State:SpellCanCast(id)
    if not self.knownSpells[id] then return false end
    if self:CdRemain(id) > 0 then return false end
    local cost = ns.Adapt and ns.Adapt:CostOf(id) or nil
    if cost then
        if cost.energy and self.energy < cost.energy then return false end
        if cost.chi and self.chi < cost.chi then return false end
        if cost.runicPower and self.runicPower < cost.runicPower then return false end
    end
    if not self.projected then
        -- IsUsableSpell covers stance, form and resource checks the client knows
        -- about; treat "no mana/energy" as usable-but-not-yet so the projection
        -- path stays consistent with the live path.
        if IsUsableSpell then
            local usable, noResource = IsUsableSpell(id)
            if not usable and not noResource then return false end
            if noResource and not cost then return false end
        end
        if IsSpellInRange and UnitExists("target") then
            local inRange = IsSpellInRange(id, "target")
            if inRange == 0 then return false end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- projection (report section 5.4)
-- ---------------------------------------------------------------------------
--- Shallow-copy with independent aura/cd tables, so ApplyCast cannot leak into
--- the live snapshot.
function State:Clone()
    local c = setmetatable({}, State)
    for k, v in pairs(self) do c[k] = v end
    c.auras, c.cds = {}, {}
    for id, a in pairs(self.auras) do c.auras[id] = { remain = a.remain, stacks = a.stacks } end
    for id, d in pairs(self.cds) do c.cds[id] = { remain = d.remain, duration = d.duration } end
    c.knownSpells = self.knownSpells
    c.knownAuras = self.knownAuras
    c.projected = true
    return c
end

--- Advance the projected state as if `action` had just been cast.
-- Deliberately models only what the player's own cast does: resources, its own
-- cooldown, the GCD, energy regen over that GCD, and self-buffs it applies. It
-- does NOT try to predict what the boss does -- that is why projection depth is
-- capped at 2-3.
function State:ApplyCast(action)
    if not action or action.op ~= "castSpell" or not action.id then return end
    local id = action.id
    local adapt = ns.Adapt

    local cost = adapt and adapt:CostOf(id)
    if cost then
        if cost.energy then self.energy = math.max(0, self.energy - cost.energy) end
        if cost.chi then self.chi = math.max(0, self.chi - cost.chi) end
        if cost.runicPower then self.runicPower = math.max(0, self.runicPower - cost.runicPower) end
    end
    local gain = adapt and adapt:GainOf(id)
    if gain then
        if gain.chi then self.chi = math.min(self.maxChi, self.chi + gain.chi) end
        if gain.energy then self.energy = math.min(self.maxEnergy, self.energy + gain.energy) end
    end

    local cd = adapt and adapt:CooldownOf(id) or 0
    if cd > 0 then self.cds[id] = { remain = cd, duration = cd } end

    -- self-applied auras (Shuffle from Blackout Kick, Tiger Power from Tiger Palm)
    local applies = adapt and adapt:AppliesAuras(id)
    if applies then
        for auraId, dur in pairs(applies) do
            local existing = self.auras[auraId]
            self.auras[auraId] = {
                remain = dur,
                stacks = existing and existing.stacks or 1,
            }
        end
    end

    -- advance time by one GCD
    local step = math.max(self.baseGcd, self.gcdRemain)
    self:AdvanceTime(step)
end

function State:AdvanceTime(dt)
    if dt <= 0 then return end
    self.combatTime = self.combatTime + dt
    self.energy = math.min(self.maxEnergy, self.energy + self.energyRegen * dt)
    self.gcdRemain = 0
    for _, a in pairs(self.auras) do a.remain = math.max(0, a.remain - dt) end
    for id, a in pairs(self.auras) do if a.remain <= 0 then self.auras[id] = nil end end
    for _, c in pairs(self.cds) do c.remain = math.max(0, c.remain - dt) end
end
