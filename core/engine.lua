-- aRotationHelper / core/engine.lua
--
-- The APL interpreter and the tier walk.
--
-- The interpreter is a direct transcription of the sim's evaluation rule
-- (sim/core/apl.go:507): walk the priority list in order, return the first line
-- whose condition passes and whose action is castable. Everything else in this
-- file exists because a simulator does not have to answer "am I about to die".
--
-- Tiers, evaluated top to bottom; first one that produces an action wins:
--   0 EMERGENCY    predicted death - strongest mitigation available
--   1 MAINTENANCE  (reserved; currently folded into the rotation)
--   2 ROTATION     the generated wowsims APL
--   3 FILLER       a free ability so the display never goes blank

local ADDON_NAME, ns = ...

local Engine = {}
Engine.__index = Engine
ns.Engine = Engine

local TIER = { EMERGENCY = 0, MAINTENANCE = 1, ROTATION = 2, FILLER = 3 }
ns.TIER = TIER

-- ---------------------------------------------------------------------------
-- value interpreter
-- ---------------------------------------------------------------------------
local function truthy(v)
    return v ~= false and v ~= nil and v ~= 0
end
local function num(v)
    if v == true then return 1 end
    if v == false or v == nil then return 0 end
    return v
end

local CMP = {
    OpEq = function(a, b) return a == b end,
    OpNe = function(a, b) return a ~= b end,
    OpLt = function(a, b) return a < b end,
    OpLe = function(a, b) return a <= b end,
    OpGt = function(a, b) return a > b end,
    OpGe = function(a, b) return a >= b end,
}

local MATH = {
    OpAdd = function(a, b) return a + b end,
    OpSub = function(a, b) return a - b end,
    OpMul = function(a, b) return a * b end,
    OpDiv = function(a, b) if b == 0 then return 0 end return a / b end,
    OpMax = function(a, b) return math.max(a, b) end,
    OpMin = function(a, b) return math.min(a, b) end,
}

-- op -> State method. Mirrors the `lua` field in tools/apl2lua/opcodes.mjs.
local READER = {
    monkCurrentChi = "Chi",
    monkMaxChi = "MaxChi",
    brewmasterMonkCurrentStaggerPercent = "StaggerPct",
    currentEnergy = "Energy",
    maxEnergy = "MaxEnergy",
    energyRegenPerSecond = "EnergyRegen",
    currentHealth = "Health",
    maxHealth = "MaxHealth",
    currentHealthPercent = "HealthPct",
    currentRunicPower = "RunicPower",
    gcdIsReady = "GcdReady",
    gcdTimeToReady = "GcdRemain",
    currentTime = "CombatTime",
    numberTargets = "NumTargets",
    frontOfTarget = "InFrontOfTarget",
    unitIsMoving = "IsMoving",
    inputDelay = "InputDelay",
    channelClipDelay = "InputDelay",
    currentRuneCount = "RuneCount",
    currentNonDeathRuneCount = "NonDeathRuneCount",
}

-- ops that take a single spell/aura id
local ID_READER = {
    spellIsKnown = "SpellKnown",
    spellIsReady = "SpellReady",
    spellCanCast = "SpellCanCast",
    spellTimeToReady = "CdRemain",
    spellFullCooldown = "CdDuration",
    spellGcdHastedDuration = "HastedGcd",
    auraIsKnown = "AuraKnown",
    auraIsActive = "AuraUp",
    auraIsInactive = "AuraDown",
    auraRemainingTime = "AuraRemain",
    auraNumStacks = "AuraStacks",
    dotPercentIncrease = "DotPercentIncrease",
}

local EXECUTE = {
    ExecuteProportion20 = 0.20,
    ExecuteProportion25 = 0.25,
    ExecuteProportion35 = 0.35,
    ExecuteProportion45 = 0.45,
    ExecuteProportion90 = 0.90,
}

local eval

--- Evaluate an IR value node against a state. Returns a number or boolean.
function eval(node, S)
    if node == nil then return true end
    local op = node.op

    if op == "const" then return node.v end

    if op == "and" then
        for i = 1, #node.vals do
            if not truthy(eval(node.vals[i], S)) then return false end
        end
        return true
    end
    if op == "or" then
        for i = 1, #node.vals do
            if truthy(eval(node.vals[i], S)) then return true end
        end
        return false
    end
    if op == "not" then return not truthy(eval(node.val, S)) end

    if op == "cmp" then
        local f = CMP[node.cmpOp]
        if not f then return false end
        return f(num(eval(node.lhs, S)), num(eval(node.rhs, S)))
    end
    if op == "math" then
        local f = MATH[node.mathOp]
        if not f then return 0 end
        return f(num(eval(node.lhs, S)), num(eval(node.rhs, S)))
    end
    if op == "max" or op == "min" then
        local acc
        for i = 1, #node.vals do
            local v = num(eval(node.vals[i], S))
            if acc == nil then acc = v
            elseif op == "max" then acc = math.max(acc, v)
            else acc = math.min(acc, v) end
        end
        return acc or 0
    end

    local reader = READER[op]
    if reader then return S[reader](S) end

    reader = ID_READER[op]
    if reader then return S[reader](S, node.id or node.item or 0) end

    if op == "currentRuneCount" then return S:RuneCount(node.runeType) end
    if op == "currentNonDeathRuneCount" then return S:NonDeathRuneCount(node.runeType) end

    if op == "energyTimeToTarget" then return S:EnergyTimeTo(num(eval(node.target, S))) end
    if op == "isExecutePhase" then return S:ExecutePhase(EXECUTE[node.threshold] or 0.20) end

    -- An unrecognised op should never reach here: the generator refuses to emit
    -- opcodes it does not know. If it does, fail visibly rather than silently
    -- treating the line as satisfied.
    ns.Debug("engine: unhandled opcode '" .. tostring(op) .. "'")
    return false
end
ns.EvalValue = eval

-- ---------------------------------------------------------------------------
-- action readiness
-- ---------------------------------------------------------------------------
local function actionReady(action, S)
    if action.passive then return false end
    if action.op == "castSpell" then
        if not action.id then return false end
        return S:SpellCanCast(action.id)
    end
    return false
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
function Engine.New()
    local e = setmetatable({}, Engine)
    e.rotation = nil
    return e
end

function Engine:SetRotation(rotation)
    self.rotation = rotation
end

-- ---------------------------------------------------------------------------
-- the rotation tier: a direct transcription of sim/core/apl.go:507
-- ---------------------------------------------------------------------------
function Engine:Rotation(S)
    local rot = self.rotation
    if not rot or not rot.active then return nil end
    for i = 1, #rot.active do
        local line = rot.active[i]
        if (not ns.Adapt or ns.Adapt:AllowRotation(line.action, S))
            and truthy(eval(line.cond, S)) and actionReady(line.action, S) then
            return {
                action = line.action,
                tier = TIER.ROTATION,
                lineIdx = line.idx,
                reason = ns.Adapt and ns.Adapt:ReasonFor(line, S) or nil,
            }
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- the full tier walk
-- ---------------------------------------------------------------------------
function Engine:Evaluate(S)
    -- Tier 0: survival pre-empts everything.
    local emergency = ns.Adapt and ns.Adapt:Emergency(S) or nil
    if emergency then return emergency end

    local maintenance = ns.Adapt and ns.Adapt:Maintenance(S) or nil
    if maintenance then return maintenance end

    local pick = self:Rotation(S)
    if pick then return pick end

    -- Tier 3: never leave the display blank mid-combat.
    local filler = ns.Adapt and ns.Adapt:Filler(S) or nil
    if filler then return filler end

    return nil
end

--- Project the next `depth` actions.
-- The result is a forecast, not a commitment: it is recomputed from scratch every
-- refresh, and it deliberately cannot see incoming damage, which is why depth is
-- capped. When Tier 0 fires the caller should collapse the display to one icon.
function Engine:Queue(S, depth)
    depth = math.min(depth or 3, 3)
    local out = {}

    -- The projected snapshot must inherit every relevant live cooldown. If we
    -- only query the first chosen action, a later queue slot can incorrectly
    -- treat an unqueried spell (for example Horn of Winter) as ready.
    if not S.projected then
        if self.rotation and self.rotation.active then
            for i = 1, #self.rotation.active do
                local action = self.rotation.active[i].action
                if action and action.id then S:CdRemain(action.id) end
            end
        end
        if ns.SpellIDs then
            for _, id in pairs(ns.SpellIDs) do S:CdRemain(id) end
        end
    end
    local scratch = S:Clone()
    for i = 1, depth do
        local pick = self:Evaluate(scratch)
        if not pick then break end
        pick.step = i
        out[i] = pick
        -- An emergency answer is not projectable: we cannot model what the boss
        -- does next, so anything after it would be fiction.
        if pick.tier == TIER.EMERGENCY then break end
        scratch:ApplyCast(pick.action)
    end
    return out
end
