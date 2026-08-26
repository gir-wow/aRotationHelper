-- aRotationHelper / core/adapt.lua
--
-- The layer that turns "replicate a simulator" into "tell me what to press".
--
-- A simulator has to assume a fight length, a boss damage pattern, a gear level
-- and a target count. This addon knows none of those, but it can measure the real
-- ones. Everywhere the generated rotation carries a number that only meant
-- something at the sim's assumptions, the substitution lives here.
--
-- It also owns:
--   * the survival tier (Tier 0), which has no counterpart in the sim at all
--   * the playstyle profiles, expressed as modifiers over one good rotation
--     rather than as separate hand-maintained lists
--   * spell economics used for projection (see State:ApplyCast)

local ADDON_NAME, ns = ...

local Adapt = {}
Adapt.__index = Adapt
ns.Adapt = Adapt

-- ---------------------------------------------------------------------------
-- spell ids
-- ---------------------------------------------------------------------------
local S = {
    -- monk / brewmaster
    JAB = 100780,
    TIGER_PALM = 100787,
    BLACKOUT_KICK = 100784,
    KEG_SMASH = 121253,
    EXPEL_HARM = 115072,
    GUARD = 115295,
    PURIFYING_BREW = 119582,
    ELUSIVE_BREW = 115308,
    CHI_BREW = 115399,
    CHI_WAVE = 115098,
    CHI_BURST = 123986,
    ZEN_SPHERE = 124081,
    RUSHING_JADE_WIND = 116847,
    SPINNING_CRANE_KICK = 101546,
    BREATH_OF_FIRE = 115181,
    INVOKE_XUEN = 123904,
    GIFT_OF_THE_OX = 124507,
    FORTIFYING_BREW = 115203,
    DAMPEN_HARM = 122278,
    AVERT_HARM = 115213,
    ZEN_MEDITATION = 115176,
    HEALTHSTONE = 5512,
    -- auras
    SHUFFLE = 115307,
    TIGER_POWER = 125359,
    POWER_GUARD = 118636,
    ELUSIVE_BREW_STACKS = 128938,
    VENGEANCE_MONK = 120267,
    VENGEANCE_DK = 93099,
    -- death knight / blood
    DEATH_STRIKE = 49998,
    RUNE_STRIKE = 56815,
    SOUL_REAPER = 114867,
    HEART_STRIKE = 55050,
    BLOOD_BOIL = 48721,
    DEATH_AND_DECAY = 43265,
    RUNE_TAP = 48982,
    HORN_OF_WINTER = 57330,
    CRIMSON_SCOURGE = 81141,
    STAGGER_LIGHT = 124275,
    STAGGER_MODERATE = 124274,
    STAGGER_HEAVY = 124273,
}
ns.SpellIDs = S

-- ---------------------------------------------------------------------------
-- spell economics, used for projection only
-- ---------------------------------------------------------------------------
-- At runtime the game is authoritative for cooldowns (GetSpellCooldown) and often
-- for costs (GetSpellPowerCost). This table exists because projection has to
-- reason about a cast that has NOT happened yet, so there is nothing to query.
-- Values verified against the sim; see the report's Appendix A.
local ECON = {
    -- [spellId] = { energy=, chi=, gainChi=, cd=, applies={ [auraId]=duration } }
    [S.JAB]            = { energy = 40, gainChi = 1 },
    [S.TIGER_PALM]     = { applies = { [S.TIGER_POWER] = 20, [S.POWER_GUARD] = 30 } },
    [S.KEG_SMASH]      = { energy = 40, gainChi = 2, cd = 8 },
    [S.EXPEL_HARM]     = { energy = 40, gainChi = 1, cd = 15 },
    [S.BLACKOUT_KICK]  = { chi = 2, applies = { [S.SHUFFLE] = 6 } },
    [S.GUARD]          = { chi = 2, cd = 30 },
    [S.PURIFYING_BREW] = { chi = 1, cd = 1 },
    [S.ELUSIVE_BREW]   = { cd = 6 },
    [S.CHI_BREW]       = { gainChi = 2, cd = 45 },
    [S.CHI_WAVE]       = { cd = 15 },
    [S.CHI_BURST]      = { cd = 30 },
    [S.ZEN_SPHERE]     = { cd = 10 },
    [S.RUSHING_JADE_WIND] = { energy = 40, cd = 6 },
    [S.SPINNING_CRANE_KICK] = { energy = 40 },
    [S.BREATH_OF_FIRE] = { chi = 2, cd = 8 },
    [S.INVOKE_XUEN]    = { cd = 180 },
    [S.GIFT_OF_THE_OX] = {},
    -- Blood DK. Rune regeneration is represented by State, since it is a
    -- property of each individual rune rather than an action cooldown.
    [S.DEATH_STRIKE]   = { runes = { RuneFrost = 1, RuneUnholy = 1 }, gainRunicPower = 20 },
    [S.RUNE_STRIKE]    = { runicPower = 30 },
    [S.SOUL_REAPER]    = { runes = { RuneBlood = 1 }, gainRunicPower = 10 },
    [S.HEART_STRIKE]   = { runes = { RuneBlood = 1 }, gainRunicPower = 10 },
    [S.BLOOD_BOIL]     = { runes = { RuneBlood = 1 }, gainRunicPower = 10 },
    [S.DEATH_AND_DECAY]= { runes = { RuneUnholy = 1 }, gainRunicPower = 10 },
    [S.RUNE_TAP]       = { runes = { RuneBlood = 1 }, cd = 30 },
    [S.HORN_OF_WINTER] = { gainRunicPower = 10, cd = 20 },
}

-- Brewmaster's Tiger Palm is free: no chi and no energy. This is not an omission.
-- Verified at sim/monk/tiger_palm.go:110 (ExtraCastCondition returns true
-- unconditionally for Brewmaster) and :120 (the SpendChi call is wrapped in
-- `if !isBrewmaster`). The reference WeakAura gates Tiger Palm on chi >= 1, which
-- is a Windwalker condition, and that single mistake is why it keeps suggesting
-- Jab at 0 chi.

function Adapt:CostOf(id)
    local e = ECON[id]
    if not e then return nil end
    if not (e.energy or e.chi or e.runicPower) then return nil end
    return e
end
function Adapt:GainOf(id)
    local e = ECON[id]
    if not e then return nil end
    if not (e.gainChi or e.gainEnergy or e.gainRunicPower) then return nil end
    return { chi = e.gainChi, energy = e.gainEnergy, runicPower = e.gainRunicPower }
end
function Adapt:RuneCostOf(id, st)
    local e = ECON[id]
    if not e or not e.runes then return nil end
    -- Crimson Scourge makes the next Blood Boil or Death and Decay free.
    if (id == S.BLOOD_BOIL or id == S.DEATH_AND_DECAY) and st:AuraUp(S.CRIMSON_SCOURGE) then
        return nil
    end
    return e.runes
end
function Adapt:CooldownOf(id)
    local e = ECON[id]
    return e and e.cd or 0
end
function Adapt:AppliesAuras(id)
    local e = ECON[id]
    return e and e.applies or nil
end

-- ---------------------------------------------------------------------------
-- configuration + playstyle profiles
-- ---------------------------------------------------------------------------
-- Profiles are modifiers over one good rotation, not separate rotations. The sim
-- cannot work this way because it only ships two Brewmaster rotations and one of
-- them has every Jab, Expel Harm and Spinning Crane Kick line disabled.
ns.PROFILES = {
    defensive = {
        label = "Defensive",
        emergencyTTL = 6.0,
        cautionTTL = 12.0,
        purifyAtModerate = true,
        vengeanceGuardFrac = 0.05,
        preferChiOverDamage = true,
    },
    balanced = {
        label = "Balanced",
        emergencyTTL = 4.0,
        cautionTTL = 8.0,
        purifyAtModerate = true,
        vengeanceGuardFrac = 0.12,
        preferChiOverDamage = false,
    },
    offensive = {
        label = "Offensive",
        emergencyTTL = 2.5,
        cautionTTL = 5.0,
        purifyAtModerate = false,   -- wait for Heavy stagger
        vengeanceGuardFrac = 0.20,
        preferChiOverDamage = false,
    },
}

-- A floor no profile may cross. "Offensive" means a narrower safety margin, never
-- no safety net.
local EMERGENCY_TTL_FLOOR = 2.0

ns.DEFAULTS = {
    profile = "balanced",
    queueDepth = 3,
    -- Vengeance is modelled by the sim as 1 attack power per stack, capped at the
    -- player's max health (sim/core/vengeance.go:109). Because it is bounded by
    -- max health, the honest form of the sim's `Vengeance >= 80000` gate is a
    -- fraction of YOUR max health. Calibrate by opening the sim with your gear,
    -- reading its max health, and computing 80000/maxHP.
    vengeanceGuardFrac = nil,   -- nil = take it from the profile
    -- Expel Harm's damage is 50% of the EFFECTIVE heal, so it is zero at full
    -- health. We learn the real heal size by observation rather than guessing.
    expelHarmHealFracFallback = 0.08,
}

function Adapt:Config()
    return ns.db or ns.DEFAULTS
end

function Adapt:Profile()
    local cfg = self:Config()
    return ns.PROFILES[cfg.profile or "balanced"] or ns.PROFILES.balanced
end

function Adapt:EmergencyTTL()
    local cfg, prof = self:Config(), self:Profile()
    local ttl = cfg.emergencyTTL or prof.emergencyTTL
    return math.max(EMERGENCY_TTL_FLOOR, ttl)
end

-- ---------------------------------------------------------------------------
-- Vengeance, normalised (report section 4.1)
-- ---------------------------------------------------------------------------
function Adapt:VengeanceSpellID()
    local _, classFile = UnitClass("player")
    if classFile == "DEATHKNIGHT" then return S.VENGEANCE_DK end
    return S.VENGEANCE_MONK
end

--- Vengeance attack power as a fraction of the player's own max health.
-- Absolute thresholds from the sim are meaningless on a real character and
-- unreachable while levelling; a fraction scales with gear for free.
function Adapt:VengeanceFrac(st)
    local stacks = st:AuraStacks(self:VengeanceSpellID())
    if stacks <= 0 then return 0 end
    return stacks / st:MaxHealth()
end

function Adapt:VengeanceIsHigh(st)
    local cfg, prof = self:Config(), self:Profile()
    local want = cfg.vengeanceGuardFrac or prof.vengeanceGuardFrac
    return self:VengeanceFrac(st) >= want
end

-- ---------------------------------------------------------------------------
-- Expel Harm quality (report section 4.4)
-- ---------------------------------------------------------------------------
-- Damage = 0.5 * min(rawHeal, missingHealth), and the damage cast is skipped
-- entirely when effective healing is zero. So at full health Expel Harm is a
-- 40-energy, 15-second-cooldown chi generator with no damage at all -- strictly
-- worse than free Tiger Palm. The sim's `hp < 95%` gate hides that there is a
-- precise full-value threshold.
Adapt.observedExpelHeal = nil

function Adapt:NoteExpelHarmHeal(amount)
    if not amount or amount <= 0 then return end
    -- Rolling average over observed casts: learn the real number instead of
    -- estimating it from attack power.
    if not self.observedExpelHeal then
        self.observedExpelHeal = amount
    else
        self.observedExpelHeal = self.observedExpelHeal * 0.7 + amount * 0.3
    end
end

function Adapt:ExpectedExpelHeal(st)
    if self.observedExpelHeal then return self.observedExpelHeal end
    local cfg = self:Config()
    return st:MaxHealth() * (cfg.expelHarmHealFracFallback or 0.08)
end

--- "full" | "partial" | "chionly"
function Adapt:ExpelHarmQuality(st)
    local missing = st:MaxHealth() - st:Health()
    if missing <= 0 then return "chionly", 0 end
    local raw = self:ExpectedExpelHeal(st)
    if missing >= raw then return "full", 1 end
    return "partial", missing / raw
end

-- ---------------------------------------------------------------------------
-- stagger, mapped to the game's own thresholds (report section 3.3)
-- ---------------------------------------------------------------------------
function Adapt:StaggerTier(st)
    if st:AuraUp(S.STAGGER_HEAVY) then return "heavy" end
    if st:AuraUp(S.STAGGER_MODERATE) then return "moderate" end
    if st:AuraUp(S.STAGGER_LIGHT) then return "light" end
    return "none"
end

function Adapt:ShouldPurify(st)
    local tier = self:StaggerTier(st)
    if tier == "heavy" then return true end
    if tier == "moderate" then return self:Profile().purifyAtModerate end
    return false
end

-- ---------------------------------------------------------------------------
-- Tier 0: the survival layer (report section 5.2)
-- ---------------------------------------------------------------------------
-- The sim's entire survival model is one knob: `hpPercentForDefensives`, default
-- 0.3, meaning "don't use survival cooldowns above 30% health"
-- (sim/core/major_cooldown.go:141). That works in a simulator because the sim
-- also simulates the healer via `healingModel`. Neither applies here, and current
-- health is a lagging indicator anyway -- by the time you are at 30% the decision
-- was needed two seconds ago.
--
-- So Tier 0 fires on predicted time-to-live instead, and counts stagger and
-- absorbs as effective health, which for a Brewmaster is most of your
-- survivability.

-- Ordered strongest-first. The first one that is actually castable wins.
local EMERGENCY_ORDER = {
    S.FORTIFYING_BREW,
    S.GUARD,
    S.ELUSIVE_BREW,
    S.DAMPEN_HARM,
    S.ZEN_MEDITATION,
    S.AVERT_HARM,
    S.HEALTHSTONE,
}

function Adapt:Emergency(st)
    if not ns.Threat then return nil end
    local ttl = ns.Threat:TimeToLive(st)
    if ttl == nil or ttl > self:EmergencyTTL() then return nil end

    for i = 1, #EMERGENCY_ORDER do
        local id = EMERGENCY_ORDER[i]
        if st:SpellCanCast(id) then
            return {
                action = { op = "castSpell", id = id, name = GetSpellInfo and GetSpellInfo(id) or nil },
                tier = ns.TIER.EMERGENCY,
                reason = ("SURVIVE %.1fs"):format(ttl),
                ttl = ttl,
            }
        end
    end
    -- Nothing mitigating is available. Purifying Brew still sheds real damage.
    if st:SpellCanCast(S.PURIFYING_BREW) and self:StaggerTier(st) ~= "none" then
        return {
            action = { op = "castSpell", id = S.PURIFYING_BREW, name = "Purifying Brew" },
            tier = ns.TIER.EMERGENCY,
            reason = ("SURVIVE %.1fs"):format(ttl),
            ttl = ttl,
        }
    end
    return nil
end

--- True when things are getting dangerous but not yet critical. Does not override
--- the rotation; the display uses it to warn, and it pulls Guard/Purify forward.
function Adapt:Caution(st)
    if not ns.Threat then return false end
    local ttl = ns.Threat:TimeToLive(st)
    if ttl == nil then return false end
    return ttl <= (self:Config().cautionTTL or self:Profile().cautionTTL)
end

-- ---------------------------------------------------------------------------
-- Tier 3: filler
-- ---------------------------------------------------------------------------
-- Never leave the display blank mid-combat. For Brewmaster this is Tiger Palm,
-- which is free and does twice Jab's damage.
local FILLER_BY_CLASS = {
    MONK = { S.TIGER_PALM, S.JAB },
}

function Adapt:Filler(st)
    local _, classFile = UnitClass("player")
    local list = FILLER_BY_CLASS[classFile]
    if not list then return nil end
    for i = 1, #list do
        local id = list[i]
        if st:SpellCanCast(id) then
            return {
                action = { op = "castSpell", id = id, name = GetSpellInfo and GetSpellInfo(id) or nil },
                tier = ns.TIER.FILLER,
                reason = "filler",
            }
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- reason tags (report section 6.5)
-- ---------------------------------------------------------------------------
-- Showing WHY a line fired is what turns the display from a parrot into something
-- you learn from. It matters most exactly where the WeakAura misleads you: is Jab
-- showing because energy is about to overflow, or because Shuffle is dropping?
local REASON_BY_SPELL = {
    [S.PURIFYING_BREW] = "purify",
    [S.GUARD] = "guard",
    [S.ELUSIVE_BREW] = "dodge",
    [S.BLACKOUT_KICK] = "shuffle",
    [S.KEG_SMASH] = "keg",
    [S.EXPEL_HARM] = "heal+chi",
    [S.JAB] = "chi",
    [S.TIGER_PALM] = "filler",
    [S.CHI_BREW] = "chi!",
    [S.INVOKE_XUEN] = "burst",
    [S.RUSHING_JADE_WIND] = "aoe",
}

function Adapt:ReasonFor(line, st)
    local a = line.action
    if not a or a.op ~= "castSpell" or not a.id then return nil end
    local id = a.id

    -- Cases where the specific reason is worth distinguishing.
    if id == S.JAB then
        if st:Energy() >= 80 then return "energy cap" end
        if st:AuraRemain(S.SHUFFLE) <= 2 then return "shuffle!" end
        return "chi"
    end
    if id == S.BLACKOUT_KICK then
        if st:AuraRemain(S.SHUFFLE) <= 2 then return "shuffle!" end
        if st:CdRemain(S.KEG_SMASH) <= 2 then return "dump before keg" end
        return "shuffle"
    end
    if id == S.EXPEL_HARM then
        local q = self:ExpelHarmQuality(st)
        if q == "chionly" then return "chi only" end
        if q == "full" then return "heal+dmg" end
        return "heal (partial)"
    end
    if id == S.PURIFYING_BREW then
        return "purify " .. self:StaggerTier(st)
    end
    return REASON_BY_SPELL[id]
end
