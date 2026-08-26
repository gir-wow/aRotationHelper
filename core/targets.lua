-- aRotationHelper / core/targets.lua
--
-- Live enemy counting, with hysteresis.
--
-- The sim just reads `encounter.targets`, a config field. Live we have to measure
-- it. The reference WeakAura already counts nameplates for its Rushing Jade Wind
-- aura, which is the right idea, but a raw per-frame count makes the display
-- flicker between single-target and AoE as adds die.
--
-- Three refinements over a naive count:
--   1. Hysteresis: separate enter/leave thresholds, and the count must hold for a
--      dwell time before the mode flips.
--   2. Per-ability range: Rushing Jade Wind and Spinning Crane Kick are 8y, Keg
--      Smash and Expel Harm are 10y. One global "target count" is wrong.
--   3. A combat-log fallback, because nameplates must be enabled and in view.

local ADDON_NAME, ns = ...

local Targets = {}
Targets.__index = Targets
ns.Targets = Targets

local ENTER_AOE_AT = 3
local LEAVE_AOE_AT = 2
local DWELL = 1.5           -- seconds a new count must hold before the mode flips

Targets.lastCount = 1
Targets.mode = "single"     -- "single" | "aoe"
Targets.pendingMode = nil
Targets.pendingSince = nil

-- Recently-seen hostile GUIDs that have damaged us, as a nameplate fallback.
Targets.recentAttackers = {}
local ATTACKER_TTL = 5.0

--- Count hostile nameplates within `range` yards.
-- CheckInteractDistance index 3 is roughly 10 yards, which is the closest usable
-- proxy in this API. For 8-yard abilities we accept the slight over-count rather
-- than pretend to a precision the API does not offer.
function Targets:CountNameplates(range)
    local n = 0
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) and UnitCanAttack("player", u) and not UnitIsDead(u) then
            local close = true
            if range and range <= 10 and CheckInteractDistance then
                close = CheckInteractDistance(u, 3) and true or false
            end
            if close then n = n + 1 end
        end
    end
    return n
end

function Targets:NoteAttacker(guid)
    if guid then self.recentAttackers[guid] = GetTime() end
end

function Targets:CountRecentAttackers()
    local now, n = GetTime(), 0
    for guid, t in pairs(self.recentAttackers) do
        if now - t > ATTACKER_TTL then
            self.recentAttackers[guid] = nil
        else
            n = n + 1
        end
    end
    return n
end

--- Best available enemy count for an ability of the given range.
function Targets:Count(range)
    local plates = self:CountNameplates(range)
    local attackers = self:CountRecentAttackers()
    -- Nameplates can read implausibly low when they are disabled or off-screen
    -- while we are clearly tanking a pack. Trust the higher of the two.
    local n = math.max(plates, attackers, UnitExists("target") and 1 or 0)
    self.lastCount = n
    self:UpdateMode(n)
    return n
end

--- Hysteresis: only flip mode when the new state has held for DWELL seconds.
function Targets:UpdateMode(n)
    local want = self.mode
    if self.mode == "single" and n >= ENTER_AOE_AT then
        want = "aoe"
    elseif self.mode == "aoe" and n <= LEAVE_AOE_AT then
        want = "single"
    end

    if want == self.mode then
        self.pendingMode, self.pendingSince = nil, nil
        return self.mode
    end

    local now = GetTime()
    if self.pendingMode ~= want then
        self.pendingMode, self.pendingSince = want, now
        return self.mode
    end
    if now - self.pendingSince >= DWELL then
        self.mode = want
        self.pendingMode, self.pendingSince = nil, nil
        ns.Debug("target mode -> " .. self.mode)
    end
    return self.mode
end

function Targets:IsAoE()
    return self.mode == "aoe"
end

function Targets:Reset()
    wipe(self.recentAttackers)
    self.mode, self.lastCount = "single", 1
    self.pendingMode, self.pendingSince = nil, nil
end
