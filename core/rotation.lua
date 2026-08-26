-- aRotationHelper / core/rotation.lua
--
-- Turns a generated rotation table into the subset of lines that apply to THIS
-- character, right now.
--
-- This is the mechanism that makes the addon work while levelling. The sim is
-- hardcoded to level 90 (sim/core/constants.go: `const CharacterLevel = 90`), so
-- every generated rotation is a max-level list. But a priority list degrades
-- gracefully under removal: drop the lines whose spells you have not learned and
-- the remaining order still holds. That is also exactly what the sim itself does
-- at parse time -- GetAPLSpell returns nil and the line is discarded -- so we are
-- matching its behaviour, not inventing one.
--
-- The same filter handles talents, glyphs and tier set bonuses at level 90, which
-- is why it earns its keep immediately rather than only while levelling.

local ADDON_NAME, ns = ...

local Rotation = {}
Rotation.__index = Rotation
ns.Rotation = Rotation

function Rotation.New(data)
    local r = setmetatable({}, Rotation)
    r.data = data
    r.all = data.lines or {}
    r.prepull = data.prepull or {}
    r.active = {}
    r.dropped = {}
    return r
end

local function spellUsable(id)
    if not id then return false end
    -- IsPlayerSpell covers spells in the spellbook including talent-granted ones.
    if IsPlayerSpell and IsPlayerSpell(id) then return true end
    if IsSpellKnown and IsSpellKnown(id) then return true end
    -- Some APL references are auras or set-bonus procs rather than castable
    -- spells; those are resolved separately via State:AuraKnown.
    return false
end

--- Is every spell this line references available to us?
-- Deliberately checks spells referenced in the CONDITION too, not just the cast
-- target. A line gated on Shuffle's remaining time is meaningless before you have
-- Blackout Kick, so treat an unknown referenced spell as "condition
-- unsatisfiable, drop the line" -- which is what the sim does.
function Rotation:LineApplies(line, S)
    local action = line.action
    if action.op == "castSpell" then
        if action.id and not spellUsable(action.id) then
            return false, "unlearned: " .. (action.name or action.id)
        end
        if action.other then
            -- Sim abstractions like OtherActionPotion: handled by the cooldown
            -- row, never the rotation slot.
            return false, "sim abstraction: " .. action.other
        end
        if action.item then
            return false, "item action (not yet supported)"
        end
    elseif action.passive then
        return false, "passive (cooldown row)"
    end

    for i = 1, #(line.spells or {}) do
        local id = line.spells[i]
        if id ~= (action.id or 0) then
            -- A referenced spell counts as available if we know the spell OR we
            -- have seen its aura (covers set-bonus procs like the T15 4pc
            -- "Purifier", which is an aura we never cast).
            if not spellUsable(id) and not (S and S:AuraKnown(id)) then
                return false, "condition references unavailable spell " .. id
            end
        end
    end
    return true
end

--- Rebuild the active line set. Cheap enough to call on any learn/talent event.
function Rotation:Rehydrate(S)
    wipe(self.active)
    wipe(self.dropped)
    for i = 1, #self.all do
        local line = self.all[i]
        local ok, why = self:LineApplies(line, S)
        if ok then
            self.active[#self.active + 1] = line
        else
            self.dropped[#self.dropped + 1] = { idx = line.idx, why = why }
        end
    end
    ns.Debug(("rotation %s: %d/%d lines active"):format(self.data.key or "?", #self.active, #self.all))
    return #self.active
end

--- Prepull checklist, filtered the same way. Sorted earliest-first.
function Rotation:PrepullPlan(S)
    local out = {}
    for i = 1, #self.prepull do
        local p = self.prepull[i]
        local ok = true
        if p.action.op == "castSpell" and p.action.id then ok = spellUsable(p.action.id) end
        if p.action.other then ok = false end
        if ok then out[#out + 1] = p end
    end
    table.sort(out, function(a, b) return (a.at or 0) < (b.at or 0) end)
    return out
end

-- ---------------------------------------------------------------------------
-- registry
-- ---------------------------------------------------------------------------
-- spec key -> rotation table key. Extend as specs are added; the engine itself
-- does not change per spec, only the data.
ns.SPEC_ROTATIONS = {
    -- [classFilename][specIndex] = rotation key
    MONK = { [1] = "MONK_BREWMASTER_DEFAULT" },
}

--- Pick the rotation for the current class + spec, or nil if unsupported.
function ns.ResolveRotation()
    local _, classFile = UnitClass("player")
    local specIndex = GetSpecialization and GetSpecialization() or nil
    local byClass = ns.SPEC_ROTATIONS[classFile]
    if not byClass then return nil, ("no rotations for class %s"):format(tostring(classFile)) end
    if not specIndex then return nil, "no specialization yet (below level 10)" end
    local key = byClass[specIndex]
    if not key then return nil, ("no rotation for %s spec %d"):format(classFile, specIndex) end
    local data = ns.Rotations and ns.Rotations[key]
    if not data then return nil, ("rotation data %s not loaded"):format(key) end
    return data
end
