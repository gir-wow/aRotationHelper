# aRotationHelper

Next-action rotation advice for MoP Classic, generated from the wowsims APL
presets in this repo and adapted to live game state.

Design rationale and the full research behind it: [`docs/ROTATION-ADDON-FINDINGS.md`](docs/ROTATION-ADDON-FINDINGS.md)

**Status: Phase 1. Brewmaster Monk only.**

---

## Install

For local development, run:

```powershell
.\scripts\deploy.ps1
```

Default destination:

```
C:\Program Files (x86)\World of Warcraft\_classic_\Interface\AddOns\aRotationHelper
```

The deployed addon supports:

```
/arh status                                   -- rotation, dropped lines, survival state
/arh runes                                    -- opens a copyable raw rune API snapshot for Blood DK support
/arh profile defensive|balanced|offensive
/arh lock                                     -- lock/unlock frame dragging
/arh debug
```

## Rotation source data

Rotation logic is **generated**, not hand-written. The Brewmaster source APL and
the small spell-name map required to build it are checked in under `data/`.
The local `wowsims/` folder remains excluded from Git; it is reference data and
contains the full MoP WowSims checkout plus the WeakAura export.

`rotations/monk_brewmaster_default.lua` must not be edited by hand. Rebuild and
verify it with Node.js 22 or later:

```bash
npm run addon           # generate + verify
npm run addon:build     # generate only
npm run addon:verify    # offline checks, no WoW client
npm run addon:lint      # lint the source APL without emitting
npm run addon:derive:blood # derive the Blood DK core from its encounter presets
```

Blood DK is data-preparation only for now: its derived core is deliberately not
compiled until the live rune API mapping has been verified in the MoP client.

The intended generator refuses to emit a rotation containing an opcode it does
not understand. A silently dropped priority line is the worst failure mode for a
rotation helper, so an unknown condition should be a build error with the exact JSON path:

```
priorityList[0].condition.and[0]: unimplemented value opcode 'bossCurrentTarget'.
```

It also lints for percentage-vs-absolute comparison bugs — the class of mistake
that makes Blood DK's `hpPct < (maxHealth * 0.1)` always true.

## How it works

```
ui/monk/brewmaster/apls/default.apl.json     the sim's priority list
        |
        |  tools/apl2lua  (validate, lint, resolve spell names,
        |                  collect referenced spells, drop hidden lines)
        v
rotations/monk_brewmaster_default.lua        a data tree, not code
        |
        |  core/rotation.lua   drop lines whose spells you have not learned
        |  core/state.lua      live snapshot, + Clone/ApplyCast for projection
        |  core/adapt.lua      sim assumptions -> live measurements
        |  core/threat.lua     damage rate -> predicted time-to-live
        v
core/engine.lua   tier walk -> one answer + a short forecast
        v
ui/display.lua
```

### Tiers

Evaluated top to bottom; the first that produces an action wins.

| Tier | What |
|---|---|
| 0 EMERGENCY | Predicted death within `emergencyTTL`. Strongest available mitigation. Collapses the display to one icon. |
| 2 ROTATION | The generated wowsims APL, adapted. |
| 3 FILLER | A free ability, so the display never blanks mid-combat. |

Tier 0 fires on **damage rate**, not current health, and counts the stagger pool
and absorbs as effective health. The sim's only survival control is
`hpPercentForDefensives` (default 0.3), which works there only because the sim
also simulates the healer.

### What is adapted rather than copied

| Sim | Here |
|---|---|
| `Vengeance >= 80000` | fraction of *your* max health (Vengeance is capped at max health, so this normalises cleanly) |
| `hpPercentForDefensives: 0.3` | predicted time-to-live from a rolling damage window |
| `stagger >= 3% / > 6%` | Moderate (`124274`) / Heavy (`124273`) aura presence — exactly the game's own thresholds |
| Expel Harm `hp < 95%` | missing health vs the *observed* heal size; damage is 50% of effective healing, so it is zero at full HP |
| `numberTargets` config field | nameplate count with hysteresis and a combat-log fallback |
| `autocastOtherCooldowns` | cooldown row, never the rotation slot |
| `inputDelay`, `channelClipDelay` | a constant |

### Levelling

The sim is hardcoded to level 90 (`sim/core/constants.go`), so every generated
rotation is a max-level list. `core/rotation.lua` drops lines whose spells you
have not learned — including spells referenced only in a line's *condition* — and
rebuilds on level-up, talent, glyph and gear changes. A priority list degrades
gracefully under removal, so this yields sane (if suboptimal) advice from level 1.

Verified: with 2 abilities known, 2 of 23 lines stay active and nothing unlearned
is ever suggested.

## Using it from a WeakAura

Keep your own visuals and just ask what to press:

```lua
local id     = aRotationHelper:NextAction()   -- spell id, or nil
local queue  = aRotationHelper:Queue(3)       -- {id, id, id}; [1] is advice, rest forecast
local why    = aRotationHelper:Reason()       -- "energy cap", "shuffle!", "purify heavy"
local panic  = aRotationHelper:IsEmergency()
local ttl    = aRotationHelper:TimeToLive()   -- seconds, or nil
```

## Verification

`npm run addon:verify` runs 102 checks with no game client:

- **Parity** — every registry opcode is implemented by both `core/engine.lua` and
  the offline interpreter, so the generator can never emit something the addon
  cannot read.
- **Scenarios** — asserted answers for the cases that actually matter: Tiger Palm
  wins when energy-starved (the reference WeakAura's bug), Jab appears only at the
  energy cap, Blackout Kick rescues Shuffle, Purifying Brew fires at Moderate but
  not Light stagger, Guard is held at zero Vengeance.
- **Levelling** — a 2-ability character still gets valid advice.
- **Projection** — three steps produced, and `Clone`/`ApplyCast` provably do not
  mutate live state.
- **Lua round-trip** — the emitted Lua is parsed back and compared structurally to
  the JSON, then driven through the interpreter to confirm it picks identically.

### Not yet verified

The **in-game Lua has not been run**. The generated data file is verified by
round-trip, and the engine's opcode coverage is verified by parity, but
`core/state.lua`'s WoW API calls, the display, and the keybind scanner need a real
client. Expect to fix API signature details on first load — `/arh debug` and
`/arh status` exist for that.

Most likely first-load issues:

- Aura scanning. All aura reads funnel through `forEachAura` in `core/state.lua`
  precisely so there is one place to fix if the signature differs.
- `UnitStagger` / `UnitGetTotalAbsorbs` availability. Both are guarded, and the
  stagger tier auras are the primary path.
- Vengeance stacks. The sim models 1 stack = 1 attack power; a real client may put
  the value only in the tooltip, in which case `Adapt:VengeanceFrac` needs a
  tooltip scan.

## Roadmap

Phase 1 (this): generator, interpreter, known-spell filter, adaptation layer,
survival tier, display, keybinds.

Phase 2: import your own wowsims export so the addon runs *your* priority list;
the intersection tool that derives a general rotation for the 13 specs shipping
only encounter presets; Blood DK, including the rune opcodes and their
frost/unholy mapping fix; then the remaining specs in portability order.
