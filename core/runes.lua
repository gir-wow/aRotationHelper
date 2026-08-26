-- aRotationHelper / core/runes.lua
--
-- Live rune diagnostics. Blood DK support must use the client's actual rune
-- mapping: historical API enum documentation conflicts with the old WowSims
-- mapping, especially around the second rune type. Keep this raw until it has
-- been verified in the MoP Classic client.

local ADDON_NAME, ns = ...

local Runes = {}
ns.Runes = Runes

function Runes:Snapshot()
    if not GetRuneType or not GetRuneCooldown then return nil end

    local now = GetTime()
    local out = {}
    for slot = 1, 6 do
        local runeType = GetRuneType(slot)
        local start, duration, ready = GetRuneCooldown(slot)
        local remain = 0
        if not ready and start and duration then
            remain = math.max(0, start + duration - now)
        end
        out[slot] = { type = runeType, ready = ready and true or false, remain = remain }
    end
    return out
end

function Runes:PrintSnapshot()
    local snapshot = self:Snapshot()
    if not snapshot then
        ns.Export:Add("rune API unavailable on this client")
        ns.Export:ShowLog()
        return
    end
    local lines = { "aRotationHelper rune API snapshot", "", "slot: raw type, state" }
    for slot = 1, #snapshot do
        local rune = snapshot[slot]
        local state = rune.ready and "ready" or ("%.1fs"):format(rune.remain)
        lines[#lines + 1] = ("%d: type %s, %s"):format(slot, tostring(rune.type), state)
    end
    ns.Export:Add(table.concat(lines, "\n"))
    ns.Export:ShowLog()
end
