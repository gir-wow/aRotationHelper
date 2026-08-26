# aRotationHelper — driving a MoP Classic rotation addon from wowsims APLs

**Findings report.** Brewmaster Monk as the worked case study, Blood DK as the
second target, with a coverage and portability plan for all 34 specs (§7).
Repo: `mop-0.0.295` (wowsims MoP) · Reference WeakAura: `nomad-mop-monk.txt`

---

## 0. Verdict

**Yes — an addon is the right shape for this, and it's very achievable.**

The rotations in wowsims are not code, they're **data**: typed JSON priority lists.
The evaluation rule is a plain ordered first-match-wins loop. Both facts make the
logic portable to Lua.

Five findings shape the design:

1. **Brewmaster is unusually portable.** The default Brewmaster APL uses only
   **21 distinct condition types, and every one of them is readable from the live
   game API.** No fight-length dependency, no simulator-internal state. (Across
   all 75 shipped presets there are 103 condition types, including
   `remainingTime` used 268 times — that one is unknowable in-game. Brewmaster's
   `default` preset avoids it entirely.)

2. **The sim's presets are a starting point, not a specification.** A simulator
   *must* assume a fight length, a boss damage pattern, a gear level and a target
   count. An in-game helper knows none of those, but it can measure the real
   ones. Where the sim bakes in a number that only means something at its own
   assumptions, read the live equivalent instead. See §4.

3. **Survival is a separate concern from the priority list, and needs its own
   layer.** The sim's only survival control is a single blunt knob
   (`hpPercentForDefensives`, default 0.3). "Don't die" is not a line in a
   priority list — it's a tier that can pre-empt the whole list. See §5.

4. **Going wide is mostly a data problem, not an engine problem.** The engine
   interprets APL data, so it's spec-agnostic. Of 34 specs, 30 have presets, 17
   have a clean `default`, and 13 need one derived by intersecting their
   encounter variants. **Both of your specs land in the top portability tier** —
   Brewmaster and Blood both have zero unportable conditions. See §7.

5. **Levels 1-90 works by subtraction.** `sim/core/constants.go:9` is
   `const CharacterLevel = 90`, so every preset is a level-90 rotation. But
   dropping lines whose spells you haven't learned is exactly what the sim
   already does at parse time, and a priority list degrades gracefully under
   removal. Suboptimal at level 20, but present and sane. See §7.5.

Two concrete illustrations of why point 2 matters:

- The shipped **Offensive** Brewmaster preset has 10 of its 33 lines disabled,
  including *every* Jab, Expel Harm and Spinning Crane Kick line (§2.2). Ported
  literally, it would tell you to pool energy and never spend it. It is an
  experiment, not gospel.
- The reference WeakAura suppresses Tiger Palm at 0 chi because of a condition
  inherited from Windwalker — Brewmaster's Tiger Palm is **free**. That single
  bug is why it keeps suggesting Jab (§3.4).

---

## 1. How wowsims stores rotations

### 1.1 The data model

Rotations live as JSON, one file per preset:

```
ui/monk/brewmaster/apls/default.apl.json      <- "Generic"
ui/monk/brewmaster/apls/offensive.apl.json    <- "Offensive"
ui/monk/brewmaster/apls/horridon.apl.json     <- encounter-specific
ui/monk/brewmaster/apls/iron_juggernaut.apl.json
ui/monk/brewmaster/apls/sha.apl.json          (not currently registered)
ui/monk/brewmaster/apls/garajal.apl.json      (not currently registered)
```

75 such files exist across all classes. The schema is `proto/apl.proto`.

The shape is:

```jsonc
{
  "type": "TypeAPL",
  "prepullActions": [ { "action": {...}, "doAtValue": {"const":{"val":"-30s"}} } ],
  "priorityList":   [ { "action": {...}, "hide": false, "notes": "..." } ]
}
```

An `action` is one of ~22 kinds (overwhelmingly `castSpell`) with an optional
`condition`. A `condition` is a recursive tree of ~103 value kinds — `and`, `or`,
`not`, `cmp`, `math`, plus leaf readings like `auraRemainingTime`,
`spellTimeToReady`, `monkCurrentChi`.

### 1.2 The evaluation rule

`sim/core/apl.go:507`:

```go
func (apl *APLRotation) getNextAction(sim *Simulation) *APLAction {
    apl.evalGeneration++
    if len(apl.controllingActions) != 0 {
        return apl.controllingActions[len(apl.controllingActions)-1].GetNextAction(sim)
    }
    for _, action := range apl.priorityList {
        if action.IsReady(sim) { return action }
    }
    return nil
}
```

Ordered, first match wins. That's the whole thing. `IsReady` for a cast is
`spell.CanCastOrQueue(...)` plus a GCD check
(`sim/core/apl_actions_casting.go:30`) — meaning **cost, range and cooldown are
all part of readiness**, not just the written condition.

### 1.3 Two rules a port must not skip

- **`hide: true` means the line is disabled.** The Offensive preset relies on
  this heavily. Skip hidden lines.
- **Lines for spells you don't have are dropped, not failed.** At parse time
  `GetAPLSpell` returns nil and the line is discarded. This is why a single APL
  can list Rushing Jade Wind *and* Invoke Xuen (mutually exclusive level-90
  talents), and all three of Chi Wave / Chi Burst / Zen Sphere (mutually
  exclusive level-60 talents). Only the talented one is ever live. An in-game
  engine must filter by `IsSpellKnown` the same way, or it will suggest abilities
  you cannot cast.

The practical effect: the 25-line Generic list is only ~19 effective lines for
any given talent build.

### 1.4 Opcode census — how much surface a port actually needs

Counted across all 75 preset files:

| Actions (22 distinct) | Uses |
|---|---|
| `castSpell` | 1893 |
| `groupReference` | 98 |
| `autocastOtherCooldowns` | 76 |
| `schedule` | 49 |
| `strictSequence` | 44 |
| `channelSpell` | 43 |
| `sequence` | 37 |
| `wait` | 31 |
| everything else | < 25 each |

Top condition types: `const` 1983, `cmp` 1924, `and` 1217, `auraIsActive` 701,
`variableRef` 655, `or` 605, `not` 575, **`remainingTime` 268**,
`auraIsInactive` 248, `auraRemainingTime` 201, `auraNumStacks` 195,
`spellTimeToReady` 178, `spellIsReady` 162, `auraIsKnown` 156.

`remainingTime` at #8 is the single biggest portability obstacle in the general
case — it's "seconds left in the fight." See §8.

**But scoped to the Brewmaster `default` preset, the entire needed vocabulary is
21 items**, all live-readable:

```
cmp  const  and  or  math  spellId  tag
monkCurrentChi  monkMaxChi  currentEnergy  maxEnergy  currentHealthPercent
brewmasterMonkCurrentStaggerPercent
auraIsActive  auraIsInactive  auraIsKnown  auraRemainingTime  auraNumStacks
spellTimeToReady  spellGcdHastedDuration  energyTimeToTarget  gcdTimeToReady
inputDelay
```

---

## 2. The Brewmaster priority lists, decoded

Spell IDs resolved against `assets/database/db.json` (`spellIcons` provides
id to name).

### 2.1 "Generic" — `default.apl.json`

```
Prepull:  -30s Dampen Harm · -1s Stance of the Sturdy Ox · -0.1s Potion

 1. AutocastOtherCooldowns                    (sim abstraction: trinkets/racials)
 2. Purifying Brew   IF T15-4pc "Purifier"(138237) up
                        AND (stagger > 6% OR proc expiring within a GCD)
 3. Elusive Brew     IF Brewing: Elusive Brew(128938) >= 6 AND Elusive Brew down
 4. Chi Brew         IF chi == 0 OR (chi <= 1 AND KegSmash CD >= 1.5s)
 5. Guard            IF Shuffle > 2s AND chi >= 3
                        AND Power Guard up AND Vengeance >= 80000
 6. Blackout Kick    IF KegSmash CD <= 1.5s AND chi >= maxChi-1
 7. (hidden)
 8. Gift of the Ox   IF hp <= 60%
 9. Energy Sphere    IF T15-WW-2pc known AND energy-to-cap > GCD remaining
10. Keg Smash        (unconditional)
11. Rushing Jade Wind (unconditional)
12. Expel Harm       IF Shuffle <= 2s AND chi <= 1 AND hp < 95%
13. Jab              IF Shuffle <= 2s AND chi <= 1
14. Blackout Kick    IF Shuffle <= 1.5s
                        OR (KegSmash CD <= 2s AND chi >= maxChi-1)
15. Invoke Xuen
16. Purifying Brew   IF stagger >= 3%
17. Expel Harm       IF energy >= 80 AND hp < 95%
18. Jab              IF energy >= 80
19. Tiger Palm       IF Tiger Power <= 1.5s
20. Blackout Kick    IF chi >= 3
21. Chi Wave
22. Chi Burst
23. Zen Sphere       IF stacks < 2
24. (hidden)
25. Tiger Palm       (filler)
```

Structurally this is coherent: hard-CD defensives first, then chi dumping ahead
of Keg Smash coming off cooldown, then Keg Smash / RJW as the damage core, then
Shuffle maintenance, then energy dumping, then talent fillers, then free Tiger
Palm.

### 2.2 "Offensive" — `offensive.apl.json` (treat with caution)

33 lines, **10 hidden**. Verified hidden indices: 6, 7, 11, 16, 17, 18, 24, 25,
26, 27.

Notable differences from Generic:

- Keg Smash and **Rushing Jade Wind swap** — RJW moves *ahead* of Keg Smash.
- Chi Brew gains an energy-aware gate:
  `chi <= 2 AND KegSmash CD in [2s, 7s] AND energy <= maxEnergy - 2*regen`.
- Big Synapse Springs (126734) + potion + Invoke Xuen burst-alignment block,
  using `strictSequence` (lines 20-23).
- Vengeance gate on Guard raised to `>= 100000` — **but the Guard line is
  hidden**, so Guard never fires.
- `numberTargets >= 3` gating on Spinning Crane Kick — **also hidden**.
- **Every Jab, Expel Harm and Spinning Crane Kick line is hidden** (16/17/18 and
  25/26/27).

That last point deserves emphasis. Brewmaster's Tiger Palm is **free** (§3.4), so
the preset doesn't hard-lock; it falls through to free Tiger Palm forever. But
with no Jab (40 energy) and no Expel Harm, the only energy consumer left is Keg
Smash on its cooldown, so energy pools and is wasted, and chi comes only from Keg
Smash and Chi Brew.

**Conclusion: do not ship the Offensive preset as a recommended profile.** It
reads as work-in-progress.

### 2.3 The encounter presets

`horridon`, `iron_juggernaut` (and the unregistered `sha`, `garajal`) use
`bossSpellTimeToReady`, `bossSpellIsCasting` and `remainingTime`. These are
**out of scope** — they depend on scripted encounter timelines the addon has no
access to. Ship `default` only.

---

## 3. The reference WeakAura — how it works, and where it diverges

### 3.1 Structure

`nomad-mop-monk.txt` is a readable (non-deflated) JSON export: **92 sub-auras**,
German-localised, titled *"Nomad039 - Monk Rotation next action guide MoP"*.

```
[dynamicgroup] Upper monk           13 children   <- cooldown row (top of screenshot)
[group]        Base monk             2
[dynamicgroup] Windwalker monk Base 21
[dynamicgroup] Brewmaster monk Base 24            <- rotation row
[dynamicgroup] lower monk            4
[group]        Resources monk        1
[group]        Chi                   4            <- segmented chi bar
[group]        Balken monk          12            <- bars
[group]        Extras monk           5
```

The Brewmaster rotation group is `regionType: dynamicgroup`, `grow: RIGHT`,
`sort: ascending`, `limit: 5` (with `useLimit: false`).

**This is the key architectural difference.** Each of the 24 children is an
*independent* aura with its own triggers, and the dynamic group displays **every
one that currently matches**, laid out left-to-right in a hand-set manual order.
It answers *"which of my abilities are usable right now?"* — not *"what is the
single best thing to press?"*

Each child uses WeakAuras' native trigger system glued with small Lua, e.g.
Keg Smash:

```lua
-- triggers 1/2/3 = Cooldown Progress/Ready on Keg Smash (121253)
-- trigger 4      = Power, chi <= 2
function(trigger)
    return (trigger[1] or trigger[2] or trigger[3]) and trigger[4]
end
```

Some children do real work — the Rushing Jade Wind aura counts nearby enemies by
iterating `nameplate1..40`, which is a good precedent for live target counting
(§4.5).

### 3.2 Divergences from the sim

| | Sim (Generic) | WeakAura |
|---|---|---|
| **Model** | ordered, one answer | independent, shows all matches |
| **Purifying Brew** | `stagger >= 3%` (Moderate **or** Heavy) | requires debuff `124273` = **Heavy only**, and only if config `purifyingbrew == 2` |
| **Rushing Jade Wind** | **#11**, unconditional | **#20-21**, gated on nameplate count **and** chi < 4 (treated as AoE-only) |
| **Keg Smash** | **#10**, unconditional | gated `chi <= 2` (or `<= 3`) — hidden at high chi |
| **Guard** | Shuffle>2s AND chi>=3 AND Power Guard AND Vengeance>=80000 | `chi >= 2` + config flag only |
| **Chi Wave** | **#21**, last-resort filler | **#11**, high and unconditional |
| **Tiger Palm** | free filler, always available | **gated `chi >= 1` — a Windwalker condition (§3.4)** |
| **Jab** | only at `energy >= 80`, or Shuffle-critical | shows on `chi <= 3` with **no energy check at all** |
| **Prepull** | timed -30s / -1s / -0.1s sequence | none |

### 3.3 A translation worth stealing

The sim computes stagger as `damagePerTick / maxHealth`
(`sim/monk/brewmaster/stagger.go:73` sets aura stacks to `damagePerTick`), and
tests it at **3%** and **6%**. Those are exactly the game's own Light / Moderate /
Heavy Stagger breakpoints. So:

- `staggerPct >= 3%`  is equivalent to  Moderate Stagger (`124274`) **or** Heavy (`124273`) present
- `staggerPct > 6%`   is equivalent to  Heavy Stagger (`124273`) present

No arithmetic, no `UnitStagger` reliance — just an aura check. The WeakAura
already uses `124273`; it simply picked the stricter of the two thresholds.

### 3.4 Case study: why the WeakAura keeps saying Jab

This is worth walking through in full, because it's the clearest example of the
whole problem.

**The WeakAura's two conditions, verbatim:**

```
Tigerklaue Brewmaster  (Tiger Palm, group position 5)
  T6: unit/Power  power12 >= 1          <-- chi >= 1
  LOGIC: (T1 or T2 or T3) and (T4 or T5) and T6

Hieb Brewmaster Max Chi = 4  (Jab, group position 22)
  T4: unit/Power  power12 <= 3          <-- chi <= 3
  LOGIC: (T1 or T2 or T3) and T4        <-- note: NO energy check
```

**The bug:** Brewmaster's Tiger Palm costs **no chi and no energy**. Verified in
`sim/monk/tiger_palm.go` — `ExtraCastCondition` at line 110 returns
`isBrewmaster || ...` (always true for BM), the `SpendChi` call at line 120 is
wrapped in `if !isBrewmaster`, and `registerTigerPalm` passes a `Cast` config with
no `EnergyCost` and no `ManaCost` at all.

So `power12 >= 1` is a **Windwalker** condition — WW's Tiger Palm does cost 1 chi
— that has been applied to the Brewmaster aura by mistake. The consequence:
**at 0 chi, Tiger Palm is hidden.** Meanwhile Jab's condition (`chi <= 3`) is
satisfied, and it has no energy gate, so Jab shows even at 0 energy. That is
exactly the behaviour you noticed.

**What the numbers actually say.** From the sim, for Brewmaster in Stance of the
Sturdy Ox:

| Ability | Energy | Chi | `DamageMultiplier` | Extra |
|---|---|---|---|---|
| **Tiger Palm** | **0** | 0 | **3.0** | Tiger Power: ignore 30% armor, 20s |
| **Jab** | 40 | **+1** | 1.5 | — |
| **Keg Smash** | 40 | **+2** | (separate spell, much higher) | AoE, Weakened Blows |
| **Expel Harm** | 40 | **+1** | 7.0 heal, damage = 50% of *effective* heal | 15s CD, see §4.4 |
| **Blackout Kick** | 0 | **-2** | — | Shuffle |

Sources: `sim/monk/tiger_palm.go`, `sim/monk/jab.go:71-96`,
`sim/monk/brewmaster/keg_smash.go:23,64`, `sim/monk/expel_harm.go`,
`sim/monk/blackout_kick.go:70`.

Two things fall out of that table:

1. **Tiger Palm does twice Jab's damage, for free.** Jab's *only* value is the
   1 chi. So Jab is not a filler, it's a chi purchase priced at 40 energy.
2. **Keg Smash is exactly twice as chi-efficient as Jab** (2 chi vs 1 chi for the
   same 40 energy), and hits much harder. So Keg Smash is always the better
   place to spend energy when it's off cooldown.

**So your instinct matches the sim, and the WeakAura is the outlier.** The sim's
Generic APL only fires Jab at `energy >= 80` (line 18) — purely to avoid capping
energy, since Keg Smash and Expel Harm are the only other 40-energy sinks — or
when Shuffle is about to drop and chi is empty (line 13). Tiger Palm is the real
filler (line 25) plus a Tiger Power refresher (line 19).

**The one caveat on "let other mechanics gather chi":** chi buys Blackout Kick,
and Blackout Kick is what maintains **Shuffle** — parry plus 20% more stagger,
the core Brewmaster survival mechanic. Keg Smash alone supplies 2 chi per ~8s
cooldown, or 0.25 chi/sec, while keeping Shuffle up costs 2 chi per ~6s, or
0.33 chi/sec. That gap is why Jab exists at all. So the correct rule is not
"never Jab" but the sim's rule: **Tiger Palm by default, Jab only to avoid
wasting energy or to rescue Shuffle.** The addon should make the *reason* visible
so you can tell the two cases apart — see §6.5.

---

## 4. Sim assumptions to live measurements

**This is the core of the design.** For each place the sim had to assume
something, here is the live substitute. This is the layer that turns "replicate a
simulator" into "tell me what to press."

### 4.1 Vengeance — the worked example

The sim's Guard line says `Vengeance stacks >= 80000`. That number is meaningless
on your character, because it came out of the sim's assumed gear and the sim's
assumed boss damage.

What the sim actually models (`sim/core/vengeance.go`):

- The Vengeance buff (`120267`) is modelled as **discrete stacks, 1 attack power
  per stack** (line 14-25), purely so it's easy to read in APLs.
- Value updates as a decaying average of damage taken, `VengeanceScaling = 0.018`
  of pre-mitigation damage, x2.5 for non-armor-mitigated hits.
- **It is capped at the player's max health** (`newVengeance = min(newVengeance,
  result.Target.MaxHealth())`, line 109).

That cap is the gift. Because Vengeance is bounded by max health, the honest
normalisation is **Vengeance AP as a fraction of your own max health**:

```lua
local vengAP = GetVengeanceAP()          -- stacks, or tooltip-scraped value
local frac   = vengAP / UnitHealthMax("player")
-- Guard when frac >= threshold  (default calibrated from the sim, user-tunable)
```

Calibrate the default once: open the Brewmaster sim with the P5 BIS profile, read
the character's max health, and compute `80000 / maxHP`. Ship that ratio as the
default and expose it in the addon options. Then it scales with the player's
actual gear instead of pretending they're wearing the sim's.

**Implementation caveat:** in MoP the Vengeance buff's attack power is presented
in the tooltip; the aura's `count` field is not reliably the AP value the way the
sim models it. Plan for a tooltip scan of the `120267` buff (cache it, refresh on
`UNIT_AURA`), with a fallback of tracking your own AP delta.

A further live improvement the sim can't make: Guard's absorb scales with attack
power *at cast time*, and by 15% more while Power Guard is up
(`sim/monk/brewmaster/guard.go:48`). So rather than a fixed gate, the addon can
show a live "Guard absorb approx X" estimate and prompt when it crosses a useful
fraction of your health — which is the actual decision a tank is making.

### 4.2 The rest of the table

| Sim construct | Why it's an assumption | Live substitute |
|---|---|---|
| `remainingTime`, `currentTime`, `remainingTimePercent` | sim knows fight length; you don't | **Drop.** Not used by BM `default`. For other specs, treat the line as always-true or always-false and mark it in the UI. |
| `isExecutePhase` | derived from `encounter.executeProportion*` | `UnitHealth(target)/UnitHealthMax(target) <= 0.20` etc. — genuinely better live |
| `numberTargets` | a sim config field | live nameplate count in range, see §4.5 |
| `Vengeance >= 80000` | tuned to sim gear + sim boss damage | fraction of live max health (§4.1) |
| `hpPercentForDefensives` (default 0.3) | one blunt global knob | replace with the survival layer (§5) |
| `healingModel` (`Hps`, `CadenceSeconds`, `AbsorbFrac`) | sim *simulates* your healers | you can see your real health bar; use incoming-damage rate instead (§5.2) |
| `autocastOtherCooldowns` | sim auto-fires trinkets/racials/tinkers optimally | explicit user-configured list, shown in the cooldown row rather than the rotation row |
| `schedule`, timed prepull `doAtValue` | sim knows when the pull happens | out-of-combat checklist; optionally driven by a pull timer (DBM/BigWigs `BigWigs_StartPull`) |
| `inputDelay`, `channelClipDelay` | latency model (`reactionTimeMs` in the profile) | replace with a constant, or real latency via `GetNetStats()` |
| `includeReactionTime` on aura reads | deliberately delays the sim's reaction to be human-like | ignore — you *are* the human |
| `spellGcdHastedDuration` | computed from sim haste | `1.0 / (1 + haste)` from `UnitSpellHaste("player")`, floored at 1.0s for BM |
| `energyTimeToTarget` | sim regen model | `(target - UnitPower(...)) / regen`, regen from `GetPowerRegen()` |
| `spellTimeToReady` | sim timers | `GetSpellCooldown(id)` then `start + duration - GetTime()` |
| `auraNumStacks`, `auraRemainingTime` | sim aura tracking | `AuraUtil.FindAuraBySpellID` / `UnitBuff` scan by spell ID |
| `stagger >= 3% / > 6%` | `damagePerTick / maxHealth` | Moderate (`124274`) / Heavy (`124273`) debuff presence — exact, see §3.3 |
| T15 4pc "Purifier" (`138237`) gate | sim knows the equipped set | buff presence check; the line self-disables via `auraIsKnown` if you lack the set |
| `hp < 95%` on Expel Harm | crude proxy for "the heal won't be wasted" | missing health vs expected heal, see §4.4 |
| trinket-proc aggregate values | sim knows every equipped proc's ICD | scan equipped trinket buffs; low priority, only 15 uses repo-wide |

### 4.3 Things the sim does that you should deliberately *not* copy

- **Perfect cooldown alignment.** `strictSequence` blocks that chain
  potion then Synapse Springs then Invoke Xuen assume the sim's foreknowledge of
  the pull. In-game, surface these as "burst window ready" suggestions, not
  forced sequences.
- **Optimal-play assumptions in general.** The sim never misses a GCD. A helper
  that assumes you didn't will give bad advice one GCD later. Always re-evaluate
  from live state — never precompute a plan (§6.4).
- **A simulated healer.** `healingModel` lets the sim assume a steady HPS stream.
  Your real healer is distracted, dead, or moving. Never let a survival decision
  depend on healing that hasn't landed.

### 4.4 Expel Harm — the health-scaled special case

Your read of this ability is exactly right, and the sim models it faithfully
(`sim/monk/expel_harm.go`):

```go
hpBefore := spell.Unit.CurrentHealth()
spell.CalcAndDealHealing(sim, spell.Unit, baseDamage, spell.OutcomeHealing)
hpAfter := spell.Unit.CurrentHealth()
healingDone = hpAfter - hpBefore          // EFFECTIVE healing, not raw

if healingDone > 0 {
    expelHarmDamageSpell.Cast(sim, monk.CurrentTarget)
}
```

and the damage spell carries `DamageMultiplier: 0.5` over `healingDone` as its
base. So:

```
ExpelHarmDamage = 0.5 * min(rawHeal, missingHealth)
```

Three consequences the crude `hp < 95%` gate misses entirely:

1. **At full health the damage is literally zero** — the `if healingDone > 0`
   guard skips the damage cast. Expel Harm at full HP is a 40-energy, 15s-cooldown
   1-chi generator and nothing else. That's worse than Keg Smash and worse than
   free Tiger Palm.
2. **The damage scales linearly with missing health**, up to a ceiling. It stops
   improving once `missingHealth >= rawHeal`.
3. **So there is a precise "full value" threshold**: Expel Harm is at maximum
   worth when your missing health exceeds its raw heal amount. That's the
   condition to show, not an arbitrary 95%.

```lua
-- Estimate rawHeal from AP; calibrate the coefficient once against a live cast.
local missing  = UnitHealthMax("player") - UnitHealth("player")
local rawHeal  = EstimateExpelHarmHeal()
if     missing >= rawHeal then  quality = "full"     -- heal + max damage + chi
elseif missing >  0       then  quality = "partial"  -- damage scales with missing
else                            quality = "chi only" -- zero damage
end
```

This is the single best argument for the whole approach in this document: it's an
ability where **survival and damage point the same way**, and the sim's
simplification hides that. Surface the quality tier on the icon and you're
strictly better informed than either the sim or the WeakAura.

*One correction to note:* the sim models Expel Harm's damage as **single-target**
to the current target within 10 yards (`expelHarmDamageSpell.Cast(sim,
monk.CurrentTarget)`, `MaxRange: 10`, with a source comment reading "Should be
the closest target"). If it splashes in the live game, that's a sim
simplification rather than something the APL is exploiting — worth confirming
in-game before building AoE logic on it.

### 4.5 Am I in an AoE fight or a single-target fight?

The sim just reads `encounter.targets` — a config field. Live, you have to
measure it, and the reference WeakAura already shows how: its Rushing Jade Wind
aura iterates `nameplate1..40` and counts. Reuse that, with three refinements:

```lua
-- Requires nameplates to be visible; degrade gracefully when they aren't.
local function CountEnemiesInRange(range)
    local n = 0
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) and UnitCanAttack("player", u) and not UnitIsDead(u)
           and CheckInteractDistance(u, 3)            -- ~10y proxy
        then n = n + 1 end
    end
    return n
end
```

1. **Hysteresis.** Do not flip modes on a single frame. Require the count to hold
   for ~1.5s before switching, and use different thresholds for entering and
   leaving AoE mode (e.g. enter at >= 3, leave at <= 2). Otherwise the display
   flickers between rotations as adds die.
2. **Range matters, and differs per ability.** Rushing Jade Wind and Spinning
   Crane Kick hit 8y; Keg Smash and Breath of Fire have their own cones and
   radii; Expel Harm's damage is 10y. Count per-ability rather than keeping one
   global "target count".
3. **Nameplates can lie.** They must be enabled and in view. Fall back to a
   combat-log-derived count (distinct hostile GUIDs that have swung at you in the
   last 5s) when the nameplate count reads implausibly low while you're clearly
   tanking a pack.

Where this feeds in: `numberTargets` conditions in the APL (the hidden Spinning
Crane Kick lines in the Offensive preset use `>= 3`), plus your own AoE-vs-ST
profile selection (§5.3). Note that the Generic preset casts Rushing Jade Wind
**unconditionally** at #11 — the sim considers it worth pressing at one target
too, which is the opposite of the WeakAura's AoE-only gating.

---

## 5. Survival, playstyle, and the adaptive sequence

The priority list answers "what is the best damage action given my resources."
It does not answer "am I about to die." Those are different questions and they
need different machinery.

### 5.1 What the sim does, and why it isn't enough

The sim's entire survival model is one knob. `sim/core/major_cooldown.go:141`:

```go
if mcd.Type.Matches(CooldownTypeSurvival) && character.cooldownConfigs.HpPercentForDefensives != 0 {
    if character.CurrentHealthPercent() > character.cooldownConfigs.HpPercentForDefensives {
        // don't use it yet
    }
}
```

The Brewmaster preset sets `hpPercentForDefensives: 0.3`. That's it: "don't use
survival cooldowns above 30% health." It works in a simulator because the sim
also *simulates the healer* via `healingModel` (`Hps`, `CadenceSeconds`,
`AbsorbFrac` — `sim/core/health.go:183`) and knows the boss's damage pattern in
advance. Neither is true for you.

It's also the wrong shape. Current health is a *lagging* indicator. By the time
you're at 30%, the decision needed to be made two seconds ago.

### 5.2 A survival tier that pre-empts the list

Structure the engine as **tiers**, not one list. Evaluate top to bottom; the
first tier that produces an action wins:

```
Tier 0  EMERGENCY     -- about to die: strongest available mitigation / heal
Tier 1  MAINTENANCE   -- Shuffle, Purifying Brew, Elusive Brew: cheap, always worth it
Tier 2  ROTATION      -- the wowsims APL, adapted per §4
Tier 3  FILLER        -- free Tiger Palm
```

Tier 0 fires on **predicted** health, not current health:

```lua
-- Rolling incoming-damage rate over a short window, from COMBAT_LOG_EVENT_UNFILTERED
local dtps       = DamageTakenPerSecond(3.0)         -- last 3 seconds
local effHP      = UnitHealth("player") + StaggerPoolRemaining() + AbsorbsOnMe()
local ttl        = effHP / math.max(dtps, 1)         -- seconds to live at this rate

if ttl < config.emergencyTTL then                     -- default ~4s
    return StrongestAvailable{
        "Guard", "Fortifying Brew", "Elusive Brew",
        "Dampen Harm", "Zen Meditation", "Healthstone", "Healing Sphere",
    }
end
```

Why this is better than an HP threshold:

- **It reacts to damage rate, so it fires early during a spike** and stays quiet
  during a slow attrition phase where 40% health is perfectly safe.
- **It counts stagger and absorbs as effective health**, which for a Brewmaster
  is most of your survivability. Your real HP bar understates you.
- **It degrades gracefully.** With no recent damage, `dtps` is near zero, `ttl` is
  huge, and Tier 0 never fires.

Make `emergencyTTL` the primary user-facing survival setting, and let the
playstyle profile set its default (§5.3). Also worth a second, softer band —
"caution" at, say, `ttl < 8s` — which doesn't override the rotation but re-orders
within it, pulling Guard and Purifying Brew forward and pushing Jab back.

### 5.3 Playstyle profiles that layer on top

Keep the sim's playstyle concept, but express it as **modifiers over the priority
list**, not as separate hand-maintained lists. The sim can't do this because it
only has two Brewmaster rotations and one of them is broken (§2.2).

| Profile | `emergencyTTL` | Guard / Purifying Brew | Jab vs Tiger Palm | Offensive CDs |
|---|---|---|---|---|
| **Defensive** | 6s | eager: purify at Moderate, Guard on cooldown | prefer chi (Shuffle uptime) | only when safe |
| **Balanced** (default) | 4s | sim's Generic thresholds | sim's rule (§3.4) | on cooldown |
| **Offensive** | 2.5s | purify at Heavy only, Guard held for high Vengeance | prefer free Tiger Palm | aligned into burst windows |

Two important properties:

- **The profile is a choice, and the survival tier is not.** Tier 0 always exists;
  the profile only tunes *when* it triggers. Offensive should mean "I accept a
  narrower safety margin," never "disable the safety net." Cap `emergencyTTL` at
  a floor so no profile can turn it off entirely.
- **It composes with the AoE/ST mode** from §4.5, giving a small matrix
  (3 profiles x 2 target modes) implemented as condition overrides rather than
  six separate rotations.

### 5.4 The adaptive sequence

You want to see what's after the next button, and you want that to keep up with
what's happening. Both are achievable, but they pull against each other, so be
explicit about the contract:

**Every frame, recompute from scratch.** Never carry a plan forward. The queue
you show is a *projection*, not a commitment, and it's allowed to change
completely between frames — because reality did.

To project ahead N steps, run the tier evaluation against a **speculative state
clone**:

```lua
function Engine:Queue(depth)
    local out, s = {}, State:Clone()
    for i = 1, depth do
        local action = self:Evaluate(s)          -- full tier walk, not just Tier 2
        if not action then break end
        out[i] = action
        s:ApplyCast(action)   -- deduct cost, start CD, advance GCD, apply own buffs
    end
    return out
end
```

`ApplyCast` needs to model, at minimum: resource cost, the ability's own
cooldown, the GCD advance, energy regen over that GCD, and buffs the ability
applies to *you* (Shuffle from Blackout Kick, Tiger Power from Tiger Palm, Power
Guard from Tiger Palm). It should **not** try to model what the boss does next.

**Keep depth at 2-3.** Error compounds fast, and crucially, projection cannot
anticipate incoming damage — so a projected step 3 can be invalidated by a single
boss ability. Show the uncertainty honestly:

- Step 1: full size, glowing, keybind shown. This is advice.
- Steps 2-3: smaller, ~60% alpha. This is a forecast.
- When Tier 0 fires, **collapse the queue to one icon** and change its border
  colour. In an emergency, a forecast is noise — you want one unambiguous button.

That last rule is the whole design in miniature: the display should communicate
not just *what* to press but *how confident* the recommendation is, and a
survival override is the one case where confidence is total and everything else
should get out of the way.

---

## 6. Addon design

### 6.1 Why an addon rather than a WeakAura

A WeakAura *can* do this, but it fights the tool:

- WeakAuras' model is "N independent auras, each decides whether to show." An
  ordered priority list with a pre-empting survival tier needs one controller
  evaluating everything and emitting a single answer — which means one big
  custom-Lua aura, at which point you've written an addon inside a WeakAura with
  none of the tooling.
- A rolling damage-taken window, a speculative state clone, and action-bar
  keybind scanning are all natural in an addon and painful in a WA.
- Generating a WeakAura *import string* offline is awkward: `!WA:2!` +
  LibDeflate + LibSerialize. Reproducible, but fiddly and version-fragile.

**Recommended: addon, with an optional bridge.** Expose
`aRotationHelper:NextAction()` and `aRotationHelper:Queue(n)` globally so anyone who
prefers the WeakAura's visuals can call it from a custom trigger and keep their
existing layout. Best of both.

### 6.2 Components

```
aRotationHelper/
  aRotationHelper.toc
  core/
    engine.lua       -- tier walk + APL interpreter (opcode dispatch tables)
    state.lua        -- cached live state; Clone()/ApplyCast() for projection
    threat.lua       -- rolling damage-taken window, effective HP, time-to-live
    adapt.lua        -- the §4 substitution layer + user thresholds
    targets.lua      -- nameplate counting with hysteresis (§4.5)
    keybind.lua      -- spell -> keybind resolution
  ui/
    display.lua      -- icon frames, glow, keybind text, prepull panel
    options.lua      -- profile picker, thresholds, bar selection
  rotations/
    brewmaster_generic.lua   -- GENERATED from default.apl.json
```

Plus a generator living in this repo (`tools/apl2lua`) that reads
`ui/*/*/apls/*.json` + `assets/database/db.json` and emits the
`rotations/*.lua` tables. **This is the whole point of the exercise:**
hand-porting 25 lines is a weekend, hand-maintaining them across every sim update
is forever. Wire it into the makefile next to the existing `db` target.

### 6.3 The interpreter

Two dispatch tables mirroring the two proto oneofs. Note every reader takes the
state explicitly, so projection (§5.4) works without globals:

```lua
local V = {}  -- value evaluators
V["const"] = function(o, s) return parseConst(o.val) end
V["and"]   = function(o, s) for _,v in ipairs(o.vals) do if not eval(v, s) then return false end end return true end
V["cmp"]   = function(o, s) return CMP[o.op](eval(o.lhs, s), eval(o.rhs, s)) end
V["monkCurrentChi"]    = function(o, s) return s.chi end
V["auraRemainingTime"] = function(o, s) return s:auraRemain(o.auraId.spellId) end
V["spellTimeToReady"]  = function(o, s) return s:cdRemain(o.spellId.spellId) end
V["brewmasterMonkCurrentStaggerPercent"] = function(o, s) return s:staggerPct() end
-- ~25 entries total for Brewmaster

local A = {}  -- action readiness
A["castSpell"] = function(o, s)
    local id = o.spellId.spellId
    return s:known(id) and s:usable(id) and s:offCooldown(id)
end
```

The Tier 2 walk is then a direct transcription of §1.2:

```lua
function Engine:Rotation(s)
    for _, line in ipairs(self.rotation) do
        if not line.hide
           and (not line.condition or eval(line.condition, s))
           and A[line.kind](line.action, s) then
            return line
        end
    end
end
```

**Performance:** rebuild the live state cache on a throttled `OnUpdate` (~0.1s),
plus immediate refresh on `UNIT_POWER_UPDATE`, `UNIT_AURA`,
`SPELL_UPDATE_COOLDOWN`, `PLAYER_TARGET_CHANGED`. Feed `threat.lua` from
`COMBAT_LOG_EVENT_UNFILTERED` filtered to `destGUID == UnitGUID("player")`. Never
call `GetSpellCooldown` from inside `eval` — read from the cache.

### 6.4 Keybinds on the icons

Build a `spellID -> keytext` map, rebuilt on `UPDATE_BINDINGS`,
`ACTIONBAR_SLOT_CHANGED` and `ACTIONBAR_PAGE_CHANGED`:

```lua
local BAR_BINDING = {
    [0]  = "ACTIONBUTTON%d",           -- slots  1-12  (current page)
    [24] = "MULTIACTIONBAR3BUTTON%d",  -- slots 25-36  (right bar 1)
    [36] = "MULTIACTIONBAR4BUTTON%d",  -- slots 37-48  (right bar 2)
    [48] = "MULTIACTIONBAR2BUTTON%d",  -- slots 49-60  (bottom right)
    [60] = "MULTIACTIONBAR1BUTTON%d",  -- slots 61-72  (bottom left)
}

for slot = 1, 120 do
    local kind, id = GetActionInfo(slot)
    if kind == "macro" then id = GetMacroSpell(id); kind = id and "spell" end
    if kind == "spell" and id then
        local base = math.floor((slot - 1) / 12) * 12
        local fmt = BAR_BINDING[base]
        if fmt then
            local key = GetBindingKey(fmt:format(slot - base))
            if key then map[id] = abbreviate(GetBindingText(key, "KEY_")) end
        end
    end
end
```

**Custom bar addons override this.** Bartender4, ElvUI and Dominos re-bind via
their own frames, so `GetBindingKey` on the Blizzard binding name returns nothing
useful. The robust fallback — the approach Hekili uses on retail — is to read the
hotkey text off the actual button frame:

```lua
-- try LibActionButton first
local lab = LibStub and LibStub("LibActionButton-1.0", true)
-- else scan known button name patterns and read :GetAttribute("action") + .HotKey
for _, pat in ipairs({"ActionButton%d", "MultiBarBottomLeftButton%d",
                      "BT4Button%d", "ElvUI_Bar%dButton%d", "DominosActionButton%d"}) do
    ...  -- match GetAttribute("action") to slot, take button.HotKey:GetText()
end
```

Abbreviate for display (`SHIFT-` to `S`, `CTRL-` to `C`, `ALT-` to `A`,
`BUTTON4` to `M4`) and render as a small top-right `FontString` on each icon,
matching the game's own hotkey styling.

### 6.5 Display

Mirroring the screenshot's layout, which is a good design:

- **Top row — cooldowns.** The sim's `autocastOtherCooldowns` plus explicit
  long-CD lines. Desaturate when unavailable, glow when it's the recommended
  moment. Advisory; doesn't need to be ordered.
- **Main row — the adaptive sequence** (§5.4). Slot 1 large, glowing, keybind
  shown. Slots 2-3 smaller and dimmer, because they're a forecast. Collapse to a
  single icon with a distinct border when Tier 0 fires.
- **Show the *reason*, not just the icon.** This is what turns the tool from a
  parrot into something you learn from, and it matters most exactly where the
  WeakAura misleads you. A one-word tag under slot 1 — `energy cap`, `shuffle!`,
  `purify`, `filler`, `SURVIVE` — tells you whether Jab is showing because energy
  is about to overflow or because Shuffle is dropping (§3.4). Cheap to implement:
  the generator can emit the source line index and its `notes` field, and you
  already have both.
- **Quality tiers on scaling abilities.** Expel Harm should look different at
  "full value" vs "chi only" (§4.4) — a small corner pip or a desaturated icon.
- **Bars.** Segmented chi bar (`UnitPower("player", 12)` /
  `UnitPowerMax("player", 12)`) and energy bar — already solved in the WeakAura's
  `Chi` and `Balken monk` groups. Consider adding a stagger bar; it's the number
  the Purifying Brew decision hangs on.
- **Out of combat — prepull panel.** Render `prepullActions` as a checklist with
  their `doAtValue` offsets: *"Dampen Harm at -30s · Stance of the Sturdy Ox at
  -1s · Potion at -0.1s."* Tick items off as their buffs appear. Hook
  `BigWigs_StartPull` / DBM's pull timer to turn it into a live countdown.
- **Range and usability.** Desaturate + red tint when out of range
  (`IsSpellInRange`), matching what the WeakAura already does via its
  `spellInRange` conditions.

### 6.6 Which profile is the user on?

Three tiers, best first.

**Tier 1 — import the user's own export. This is the real answer.**

The `*.build.json` files in `ui/monk/brewmaster/builds/` are **full wowsims
exports**, and they contain the rotation. Verified on
`iron_juggernaut_default.build.json`:

```
top-level:  apiVersion, raidBuffs, debuffs, tanks, partyBuffs,
            player, encounter, targetDummies
player:     name, race, class, equipment, consumables, bonusStats, itemSwap,
            buffs, brewmasterMonk, talentsString, glyphs, profession1,
            profession2, cooldowns, rotation, reactionTimeMs,
            inFrontOfTarget, distanceFromTarget, healingModel
player.rotation.type          = "TypeAPL"
player.rotation.priorityList  = 32 entries
```

So the export you already produce from the sim UI **contains your exact priority
list**. Ship an import box: paste it, the addon reads
`player.rotation.priorityList`, and there is nothing to guess. It also gives you
`talentsString`, `glyphs` and `equipment` for free, so the addon can warn when the
in-game character doesn't match the profile the rotation was written for — and it
gives you `player.cooldowns.hpPercentForDefensives` as a hint for the initial
survival profile (§5.3).

Practical notes: a full export is large, so offer a rotation-only paste path, and
either bundle a small Lua JSON decoder or accept a compact Base64+Deflate blob
via `LibDeflate` (already a common addon dependency).

**Tier 2 — ship the presets and let them pick.** From
`ui/monk/brewmaster/presets.ts`, the registered Brewmaster rotations are exactly:

```
ROTATION_PRESET                 'Generic'          <- default.apl.json
ROTATION_OFFENSIVE_PRESET       'Offensive'        <- offensive.apl.json   (see §2.2)
ROTATION_HORRIDON_PRESET        'Horridon'         <- encounter, out of scope
ROTATION_IRON_JUGGERNAUT_PRESET 'Iron Juggernaut'  <- encounter, out of scope
```

For Brewmaster that's a two-item list, and given §2.2 you should default to
Generic and label Offensive as experimental.

**Important:** in wowsims, "offensive vs defensive" is mostly a **gear and
stat-weight** choice, not a rotation choice. The sim ships
`P5 - BIS (Balanced)` / `P5 - BIS (Offensive)` gear presets and matching EP
weights, but only one alternate rotation — and it's unfinished. So don't model
playstyle by picking between sim rotations. Model it as the modifier layer in
§5.3, over the Generic list.

**Tier 3 — auto-detect what you can.** You cannot detect *intent*, but you can
detect what makes lines live, which is what actually matters:

- Talents (`GetTalentInfo`) — which of RJW / Xuen and Chi Wave / Chi Burst /
  Zen Sphere are real.
- Equipped set bonuses — whether the T15 4pc `Purifier` line (`138237`) can ever
  fire; whether the T15 WW 2pc Energy Sphere line applies.
- Glyphs — e.g. Glyph of Fortifying Brew changes its behaviour.
- Equipped gear profile — comparing your gear against the sim's Balanced vs
  Offensive presets gives a decent *suggestion* for the initial playstyle default.

Do this filtering at load, exactly as the sim does at parse time (§1.3), and grey
out or drop the dead lines.

---

## 7. Going wide: every class and spec

The engine is spec-agnostic — it interprets APL data. So "support everything" is
really three separate questions: which specs have usable data, what to do where
they don't, and how any of it behaves below level 90.

### 7.1 Coverage inventory

MoP has **34 specs**. Of those:

- **30 have at least one APL preset.**
- **4 have none at all** — every pure healer spec except the priest ones:
  `druid/restoration`, `monk/mistweaver`, `paladin/holy`, `shaman/restoration`.
  These need hand-authored lists or should be left out.
- **17 have a `default.apl.json`**; **13 have only encounter-specific or variant
  presets** and need a general list derived (§7.3).
- One trap: `priest/discipline` *has* a `default.apl.json` but its
  `priorityList` is **empty** — a stub, not a rotation. Check line counts, not
  file existence.

### 7.2 Portability ranking, and the rollout order

I classified every condition type in each spec's primary preset into three
buckets:

- **HARD** — no live equivalent. Effectively just `remainingTime` /
  `remainingTimePercent`: "seconds left in the fight." Unknowable.
- **DBM** — needs a boss-mod integration to mean anything. Just
  `bossSpellTimeToReady`.
- **live-subst** — readable in-game, needs a §4 substitution written. Note that
  `currentTime` belongs here, not in HARD: it's seconds since the pull, which you
  can track off `PLAYER_REGEN_DISABLED`. Same for `bossCurrentTarget`
  (`UnitIsUnit("boss1target","player")`) and `bossSpellIsCasting`
  (`UnitCastingInfo("boss1")`).

Counts are against `default.apl.json` where one exists, otherwise across all of
that spec's presets (so the 13 without a default show inflated line counts).

| Spec | apls | default | lines | hidden | HARD | DBM | live-subst |
|---|---|---|---|---|---|---|---|
| priest/discipline | 1 | Y | **0** | 0 | 0 | 0 | 0 |
| druid/guardian | 12 | Y | 21 | 0 | **0** | 0 | 3 |
| priest/shadow | 2 | Y | 21 | 0 | **0** | 0 | 2 |
| **monk/brewmaster** | 6 | Y | 25 | 2 | **0** | 0 | 2 |
| warrior/protection | 5 | Y | 25 | 0 | **0** | 0 | 3 |
| rogue/combat | 1 | - | 10 | 0 | **0** | 0 | 1 |
| rogue/subtlety | 1 | - | 15 | 0 | **0** | 0 | 1 |
| mage/fire | 3 | - | 57 | 0 | 1 | 0 | 2 |
| druid/balance | 1 | - | 10 | 0 | 2 | 0 | 3 |
| rogue/assassination | 1 | - | 11 | 0 | 2 | 0 | 3 |
| mage/frost | 2 | - | 28 | 0 | 2 | 0 | 3 |
| **death_knight/blood** | 3 | - | 117 | 6 | **0** | 3 | 7 |
| warlock/demonology | 1 | Y | 14 | 0 | 4 | 0 | 3 |
| shaman/enhancement | 2 | Y | 22 | 0 | 4 | 0 | 3 |
| priest/holy | 3 | Y | 14 | 2 | 5 | 0 | 3 |
| monk/windwalker | 1 | Y | 32 | 2 | 5 | 0 | 7 |
| druid/feral | 5 | Y | 10 | 0 | 6 | 0 | 5 |
| warlock/affliction | 2 | Y | 23 | 1 | 6 | 0 | 6 |
| paladin/protection | 3 | - | 80 | 0 | **0** | 6 | 6 |
| shaman/elemental | 5 | Y | 16 | 0 | 7 | 0 | 2 |
| warlock/destruction | 1 | Y | 22 | 0 | 7 | 0 | 8 |
| mage/arcane | 3 | Y | 26 | 0 | 7 | 0 | 4 |
| paladin/retribution | 1 | Y | 29 | 1 | 11 | 0 | 4 |
| death_knight/frost | 2 | - | 80 | 0 | 13 | 0 | 4 |
| hunter/marksmanship | 2 | - | 22 | 0 | 17 | 0 | 4 |
| warrior/fury | 1 | Y | 31 | 0 | 18 | 0 | 8 |
| hunter/survival | 1 | - | 20 | 0 | 18 | 0 | 4 |
| hunter/beast_mastery | 1 | - | 33 | 0 | 19 | 0 | 4 |
| warrior/arms | 1 | - | 41 | 0 | 23 | 0 | 11 |
| death_knight/unholy | 2 | Y | 32 | 0 | 26 | 0 | 6 |

**The happy result: both of your specs are in the top tier.** Brewmaster has zero
HARD blockers and a clean `default`. Blood has zero HARD blockers too — its only
obstacles are three `bossSpellTimeToReady` references and the missing `default`,
both solvable (§7.3, §7.4).

Suggested rollout:

1. **monk/brewmaster** — 0 blockers, clean default, and it's your main. Proves the
   whole pipeline.
2. **death_knight/blood** — your second spec. Needs the derived default and the
   rune opcode family, which is the last big vocabulary gap (§7.4).
3. **warrior/protection, druid/guardian, paladin/protection** — the other tanks.
   All near-zero blockers, and they reuse the survival tier you already built for
   Brewmaster. Highest value per unit of work.
4. **priest/shadow, rogue/combat, rogue/subtlety, mage/fire** — clean DPS specs.
5. Everything with a HARD count in double digits — only after you've decided how a
   dropped `remainingTime` line should behave (§8).
6. The four healer specs — last, and only with hand-authored lists.

### 7.3 Deriving a `default` where none exists

For the 13 specs with only encounter presets, **intersect them.** Lines common to
every encounter variant are the general rotation; lines unique to one are that
fight's tuning. This is mechanical and belongs in the generator.

Verified on Blood DK's three presets (`iron_juggernaut`, `horridon`, `sha`):

```
files: 3    lines in iron_juggernaut: 38
COMMON to all 3: 18     UNIQUE to iron_juggernaut: 20

COMMON  (candidate general core):
  #11 #15 #20 #21 #22 #23 #24 #25 #26 #30 #31 #32 #33 #34 #35 #36 #37 #38
UNIQUE  (encounter tuning):
  #1 #2 #3 #4 #5 #6 #10  <- all boss-dependent
  #7 #8 #9 #12 #13 #14 #16 #17 #18 #19 #27 #28 #29
```

Every `bossCurrentTarget` / `bossSpellTimeToReady` line landed in the unique set,
and the 18 common lines are exactly the recognisable Blood core: Rune Tap on Will
of the Necropolis, Blood Tap, Empower Rune Weapon, Death Strike for Blood Shield,
Rune Strike at high runic power, Soul Reaper in execute, Heart Strike, Outbreak /
Pestilence disease upkeep, Crimson Scourge Blood Boil and Death and Decay, and
Horn of Winter as the do-nothing filler.

The unique-but-not-boss-dependent lines are almost all health-threshold defensive
tuning (Vampiric Blood at 70%, Icebound at 50%, Death Pact at 30%). **Don't port
those.** That is precisely what the §5 survival tier replaces, and doing it with a
damage-rate model is strictly better than three sets of per-encounter HP numbers.

### 7.4 Blood DK specifics

**The rune opcode family** is the one substantial vocabulary gap left. Used
across the DK presets: `currentRuneCount`, `currentNonDeathRuneCount`,
`currentRuneDeath`, `currentRuneActive`, `runeCooldown`, `nextRuneCooldown`,
`runeSlotCooldown`, `fullRuneCooldown`, plus `currentRunicPower`. All are live
readable via `GetRuneCount`, `GetRuneCooldown(slot)`, `GetRuneType(slot)` and
`UnitPower("player", 6)`.

**But there is a nasty gotcha.** The sim's enums and the WoW API disagree about
frost and unholy — in *both* the type enum and the slot ordering.

`proto/apl.proto:582` and `:588`:

```
APLValueRuneType:  RuneBlood=1  RuneFrost=2   RuneUnholy=3  RuneDeath=4
APLValueRuneSlot:  LeftBlood=1  RightBlood=2  LeftFrost=3   RightFrost=4
                                              LeftUnholy=5  RightUnholy=6
```

The in-game constants are `RUNETYPE_BLOOD=1`, `RUNETYPE_UNHOLY=2`,
`RUNETYPE_FROST=3`, `RUNETYPE_DEATH=4`, and the slot order is Blood, Blood,
**Unholy, Unholy, Frost, Frost**. So a naive port would tell a Blood DK to spend
the wrong runes — and it would look *almost* right, which is worse than obviously
broken. Put the mapping in one place in the generator, and verify it against a
live `GetRuneType` sweep before trusting anything downstream.

**Vengeance is a different spell ID** — `93099` for DKs, not the monk's `120267`
— and the Blood APL gates Dancing Rune Weapon on `Vengeance >= 250000`. Same
treatment as §4.1: normalise to a fraction of max health.

**A preset bug worth knowing about,** as another data point for §0's point 2.
Line 13 of the Blood iron_juggernaut list reads:

```
IF (currentNonDeathRuneCount(RuneBlood) >= 1 AND hpPct < (maxHealth * 0.1))
   -> Cast Rune Tap
```

`currentHealthPercent` returns a **0-1 fraction**, while `maxHealth * 0.1` is an
absolute value in the tens of thousands. So the comparison is **always true**, and
line 13 silently becomes "Rune Tap whenever a blood rune is up" — overriding the
`hp <= 50%` gate on line 12 above it. The generator should flag comparisons
between a percentage-typed value and an absolute-typed one; the proto carries
enough type information (`APLValueType`) to catch this class of mistake
automatically.

### 7.5 Levels 1 through 90

The sim cannot help here at all: `sim/core/constants.go:9` is
`const CharacterLevel = 90`, and it's referenced straight from the base-stat
tables. **Every preset is a level-90 rotation and the sim has no concept of any
other level.**

The fix is the one you proposed, and it's the right one: **filter out abilities
you haven't learned and drop those lines.** This works better than it sounds,
because it's already exactly what the sim does at parse time (§1.3) — the APL
format is *built* to have lines fall out. A priority list is naturally
degradable: remove entries and the remaining order still holds.

Mechanically:

```lua
-- At load, and on PLAYER_LEVEL_UP / SPELLS_CHANGED / talent + glyph changes,
-- rebuild the active line set.
function Rotation:Rehydrate()
    self.active = {}
    for _, line in ipairs(self.all) do
        if not line.hide and self:AllSpellsKnown(line) then
            table.insert(self.active, line)
        end
    end
end
```

`AllSpellsKnown` must check the spells referenced in the *condition* too, not just
the cast target — a line gated on `auraRemainingTime[Shuffle]` is meaningless
before you have Blackout Kick. Treat an unknown spell inside a condition as
"condition unsatisfiable, drop the line," which matches the sim's behaviour.

Events to rebuild on: `PLAYER_LEVEL_UP`, `SPELLS_CHANGED`, `LEARNED_SPELL_IN_TAB`,
`PLAYER_TALENT_UPDATE`, `PLAYER_SPECIALIZATION_CHANGED`, `GLYPH_UPDATED`.

Honest caveats, none of them blocking:

- **The *order* is still tuned for level 90.** Keg Smash outranks Jab partly
  because of level-90 scaling. The ordering mostly survives, but treat low-level
  output as a decent suggestion rather than an optimum. Suboptimal-but-present
  beats absent, which matches your experience with the WeakAura.
- **Below level 10 there is no spec**, so no APL applies. Show the class's basic
  attack and nothing else, or hide the display entirely.
- **Absolute thresholds degrade badly.** `Vengeance >= 80000` is unreachable at
  level 40. The §4.1 normalisation to a fraction of max health fixes this for
  free — one more reason to do it that way rather than porting the constant.
- **The list gets very thin early.** At level 20 a Brewmaster has maybe four
  usable lines. That's fine and honest; just make sure the Tier 3 filler always
  has something to fall back on so the display never goes blank mid-combat.
- **Stance and form gating matters more while levelling.** Several Brewmaster
  costs branch on `StanceMatches(WiseSerpent)` vs Sturdy Ox (`sim/monk/jab.go:72`).
  Read the live stance rather than assuming the level-90 one.

---

## 8. Scope boundaries

**Ship, in this order** (full ranking in §7.2):
- Brewmaster `default` ("Generic"), adapted per §4, with the survival tier from
  §5 and the profile modifiers from §5.3.
- Blood DK, from the derived core in §7.3, plus the rune opcodes and their
  frost/unholy mapping fix (§7.4).
- The other tanks — warrior/protection, druid/guardian, paladin/protection. Near
  zero blockers, and they reuse the survival tier already built.
- Then the clean DPS specs: priest/shadow, rogue/combat, rogue/subtlety,
  mage/fire, monk/windwalker.

**Don't ship:**
- The encounter APLs as *rotations* (`horridon`, `iron_juggernaut`, `sha`,
  `garajal`) — they need boss timelines. Do mine them for a derived core (§7.3).
- The per-encounter defensive HP thresholds inside them — the survival tier
  replaces those, and does it better (§7.3).
- The Offensive Brewmaster preset as a rotation (§2.2). Its *intent* lives on as
  the Offensive profile modifiers instead.
- `priest/discipline`'s `default.apl.json` — it exists but has zero priority
  lines (§7.1).
- The four healer specs with no presets at all: `druid/restoration`,
  `monk/mistweaver`, `paladin/holy`, `shaman/restoration`.
- Any spec with a double-digit HARD count (§7.2) until you've decided how a
  dropped `remainingTime` line should behave.

**Decide once, early:** what a dropped `remainingTime` condition means. Treating
it as always-true and as always-false give opposite rotations, and 268 uses across
the repo depend on the answer. Recommendation: treat `remainingTime` comparisons
as **false** when the intent is "save this cooldown for later" and **true** when
the intent is "burn everything now" — which in practice means tagging those lines
in the generator rather than guessing at runtime.

**Known-hard, defer:**
- `strictSequence` / `sequence` / `resetSequence` — stateful, and the sim's
  version assumes no missed GCDs.
- `itemSwap` (17 uses repo-wide) — irrelevant in combat.
- `channelSpell` with `interruptIf` — matters for Crackling Jade Lightning; needs
  care but is doable.
- The trinket-proc aggregate values — low value, 15 uses total.
- Projection depth beyond 3 (§5.4) — the error compounds and it cannot see
  incoming damage.

---

## 9. Suggested build order

Phase 1 — make one spec genuinely good:

1. **Generator** (`tools/apl2lua`, in this repo). Read `default.apl.json` +
   `db.json`, emit a Lua table carrying each line's index and `notes` (needed for
   the reason tags in §6.5). Respect `hide`. Fail loudly on an unknown opcode —
   silent omission is how a rotation helper starts lying. Add the type-mismatch
   check from §7.4 while you're here.
2. **State + interpreter** for the 21 Brewmaster opcodes. Standalone-testable:
   feed a fake state table, assert which line wins. Build `Clone()`/`ApplyCast()`
   here, not later — projection is much harder to retrofit.
3. **Known-spell filter** (§7.5) — `Rehydrate()` plus its event hooks. Build it
   now, not as a levelling afterthought: it's the same mechanism that handles
   talents and set bonuses at 90, so it earns its keep immediately.
4. **Adaptation layer** (§4): the Vengeance normalisation, the stagger aura
   mapping, and the Expel Harm quality tiers, with every threshold in options.
5. **Survival tier** (§5.2): the damage-taken window, effective HP including
   stagger and absorbs, and time-to-live. This is the part that has no
   counterpart in the sim, so it needs the most live tuning.
6. **Display**: one icon, correct answer, keybind text, reason tag. Then the
   projected queue, the cooldown row, the prepull panel.
7. **Target counting + profiles** (§4.5, §5.3).
8. **Import** (§6.6 Tier 1) — this is what makes it *yours* rather than *a
   preset's*.

Phase 2 — go wide (§7):

9. **Intersection tool** in the generator (§7.3), producing derived defaults for
   the 13 specs that lack one.
10. **Blood DK**: the rune opcode family plus the frost/unholy mapping fix
    (§7.4). This is the last significant vocabulary gap — after runes, most
    remaining specs need only spec-resource opcodes, which are one-liners.
11. **Remaining specs in §7.2 order**, each a data drop plus whatever
    spec-specific opcodes it needs. The engine shouldn't change.
12. **Bridge**: expose `aRotationHelper:NextAction()` so the existing WeakAura can
    consume it and you keep the visuals you already like.

Validation is its own topic — see §10. In short: don't diff against the sim, diff
against real logs.

---

## 10. Validating against Warcraft Logs

**Yes, this is possible, and it's the best validation available.** Better than a
target dummy and much better than diffing against the sim, because it compares the
engine's advice to what a human actually pressed in a real encounter.

### 10.1 The mechanism

Warcraft Logs has a public GraphQL API. For Classic it's
`https://classic.warcraftlogs.com/api/v2/client`, authenticated with OAuth2
client-credentials against `https://www.warcraftlogs.com/oauth/token`. You create
a client at `warcraftlogs.com/api/clients` to get an id and secret. Everything in
a report URL is a query parameter:
`.../reports/<code>?fight=<id>&source=<actorID>`.

```graphql
{
  reportData {
    report(code: "REPORT_CODE") {
      fights(fightIDs: [4]) { id name startTime endTime encounterID kill }
      # what they pressed, in order
      casts: events(fightIDs: [4], sourceID: 20, dataType: Casts, limit: 10000) {
        data nextPageTimestamp
      }
      # state needed to replay conditions
      buffs:  events(fightIDs: [4], sourceID: 20, dataType: Buffs,     limit: 10000) { data nextPageTimestamp }
      debuffs:events(fightIDs: [4], targetID: 20, dataType: Debuffs,   limit: 10000) { data nextPageTimestamp }
      dmg:    events(fightIDs: [4], targetID: 20, dataType: DamageTaken, limit: 10000) { data nextPageTimestamp }
      # gear, talents and glyphs at the pull
      info:   events(fightIDs: [4], dataType: CombatantInfo) { data }
    }
  }
}
```

`events` returns raw event objects — `timestamp`, `type`, `abilityGameID`,
`sourceID` — and pages via `nextPageTimestamp`. The API is rate-limited on an
hourly points budget, so cache aggressively; one fight is a handful of queries.

### 10.2 What you can reconstruct, and what you can't

| Needed for replay | Recoverable? | How |
|---|---|---|
| Cast sequence and timing | **Yes, exactly** | `Casts` events; this is the ground truth you're diffing against |
| Buffs: Shuffle, Elusive Brew, Power Guard, Tiger Power | **Yes** | `Buffs` events — `applybuff` / `refreshbuff` / `removebuff` |
| Stagger tier | **Yes** | Light/Moderate/Heavy Stagger are real auras (`124275`/`124274`/`124273`); their presence gives you the 3%/6% thresholds directly (§3.3) |
| Vengeance amount | **Yes** | `applybuffstack` on `120267`; stacks are the AP value, matching the sim's model (§4.1) |
| Talents, glyphs, gear, set bonuses | **Yes** | `CombatantInfo` at pull — this is how you filter to the lines that were actually live (§1.3, §7.5) |
| Incoming damage rate | **Yes** | `DamageTaken` events — enough to replay the survival tier's time-to-live (§5.2) |
| Target count over time | **Yes, approximately** | count distinct enemy actors taking your damage in a rolling window |
| Chi and energy | **Only with advanced combat logging** | resource fields on cast events. If the logger didn't have it enabled, the offline replay must *simulate* the resource economy forward from the cast sequence using Appendix A's costs |
| Cooldown state | **Derivable** | cast timestamps plus known cooldowns |
| GCD state | **Derivable** | cast timestamps plus haste from `CombatantInfo` |

This is an **offline Warcraft Logs replay** limitation only. The live addon reads
both resources directly with `UnitPower("player", 3)` / `UnitPowerMax("player", 3)`
for Energy and `UnitPower("player", 12)` / `UnitPowerMax("player", 12)` for Chi.

The chi/energy row is the only real offline replay gap, and it's tractable: given the cast
sequence and the costs in Appendix A, you can integrate resources forward and
check for contradictions (a cast that would have been unaffordable means your
model drifted — which is itself a useful signal).

### 10.3 The harness

```
log fight -> event stream -> state timeline -> at each cast:
    engine.Next(stateAt(t))  vs  whatTheyActuallyCast(t)
                          -> agree / disagree + reason
```

Report it as an **agreement rate plus a disagreement breakdown**, not a pass/fail.
The disagreements are the whole point. For each one you want to know which of
three things happened:

1. **The engine is wrong** — a condition ported badly, a threshold mis-tuned, a
   missing spell. Fix the engine.
2. **The log is suboptimal** — even a 100 parse has mistakes, missed GCDs and
   reaction-time gaps. Confirms nothing needs fixing.
3. **The engine is right but for a reason the sim never modelled** — the player
   pre-positioned a cooldown for an incoming mechanic. These are the interesting
   ones, and they're candidates for the survival tier or for a DBM integration.

Concretely, the questions worth asking of a Brewmaster log:

- Did they press **Tiger Palm or Jab** as filler, and at what energy? This
  settles §3.4 empirically.
- Did they **purify at Moderate stagger or wait for Heavy**? Sim says Moderate
  (3%); the WeakAura says Heavy. The log will show which the top players do.
- Was **Rushing Jade Wind** used on single-target? Sim says yes unconditionally
  (line 11); the WeakAura gates it to AoE. Straight factual question.
- At what **Vengeance** did Guard actually go out? That calibrates §4.1's
  threshold from real play instead of from the sim's assumed gear.

### 10.4 An important caveat about "100 parse"

Two things to be careful of before treating a top parse as a rotational target.

**A parse percentile is not a rotation score.** It's damage-done versus other logs
of that spec on that fight, and it folds in gear, raid buffs, fight duration, add
timing and lucky procs. A rotationally sloppy player in better gear with
Stormlash and Skull Banner uptime will out-parse a technically better one.

**For a tank this is doubly true, and specifically for Brewmaster.** Brewmaster
damage scales with **Vengeance**, and Vengeance is generated by *taking damage*
(`sim/core/vengeance.go`: 1.8% of pre-mitigation damage taken, ×2.5 for
non-armor-mitigated, capped at max health). So a 100-parse damage log can partly
reflect **taking more damage** — tanking the harder half of the fight, holding
more adds, or mitigating less — rather than pressing better buttons. Do not tune
your Guard threshold or your survival profile from a damage parse without also
looking at that log's damage-taken and deaths.

So: use logs to answer *specific factual questions* about ability choice, as in
§10.3. Don't use the percentile itself as a target. And sample several logs from
several players rather than one — agreement across logs is signal, a single log is
anecdote.

**On the assumption that top players use wowsims:** treat that as unproven. MoP
Classic rotational practice comes largely from community guides, prior expansion
experience and iteration, and this simulator is one input among several — the
Offensive preset being unfinished (§2.2) is a hint that the sim's Brewmaster
presets aren't a widely-battle-tested artifact. Which is the argument for this
whole section: the log is evidence, the sim is a hypothesis.

---

## Appendix A: Brewmaster ability economy

All values from the sim, Stance of the Sturdy Ox.

| Ability | Energy | Chi | Notes |
|---|---|---|---|
| Tiger Palm (100787) | **0** | 0 | `DamageMultiplier: 3.0`. Grants Tiger Power (30% armor ignore, 20s) and Power Guard. Free — no chi cost for BM. |
| Jab (100780) | 40 | **+1** | `DamageMultiplier: 1.5`. Half Tiger Palm's damage; you're buying chi. |
| Keg Smash (121253) | 40 | **+2** | Twice Jab's chi for the same energy. ~8s CD. |
| Expel Harm (115072) | 40 | **+1** | 15s CD. Damage = 50% of *effective* heal; zero at full HP (§4.4). |
| Blackout Kick (100784) | 0 | **-2** | Grants Shuffle. Tag 1 = yours, not an SEF clone. |
| Chi Brew (115399) | 0 | **+2** | Talent. |
| Guard (115295) | 0 | -2 | Absorb scales with AP; +15% while Power Guard is up. |

## Appendix B: spell ID reference

| ID | Name | | ID | Name |
|---|---|---|---|---|
| 100780 | Jab | | 121253 | Keg Smash |
| 100784 | Blackout Kick | | 122278 | Dampen Harm |
| 100787 | Tiger Palm (free for BM) | | 123904 | Invoke Xuen, the White Tiger |
| 101546 | Spinning Crane Kick | | 123986 | Chi Burst |
| 115069 | Stance of the Sturdy Ox | | 124081 | Zen Sphere |
| 115072 | Expel Harm | | 124255 | Stagger |
| 115098 | Chi Wave | | 124273 | Heavy Stagger (> 6%) |
| 115129 | Expel Harm damage component | | 124274 | Moderate Stagger (3-6%) |
| 115213 | Avert Harm | | 124275 | Light Stagger (< 3%) |
| 115295 | Guard | | 124507 | Gift of the Ox |
| 115307 | Shuffle | | 125359 | Tiger Power |
| 115308 | Elusive Brew | | 126456 | Fortifying Brew |
| 115399 | Chi Brew | | 126734 | Synapse Springs (engi tinker) |
| 116847 | Rushing Jade Wind | | 138177 / 138310 | T15 WW 2pc — Energy Sphere |
| 118636 | Power Guard | | 138237 | T15 BM 4pc — "Purifier" proc |
| 119582 | Purifying Brew | | 128938 | Brewing: Elusive Brew |
| 120267 | Vengeance (1 stack = 1 AP, capped at max HP) | | | |

Power type `3` = Energy, `12` = Chi.

## Appendix C: key source locations

| What | Where |
|---|---|
| APL schema | `proto/apl.proto` |
| Evaluation loop | `sim/core/apl.go:507` |
| Cast readiness | `sim/core/apl_actions_casting.go:30` |
| Chi / max chi values | `sim/monk/apl_values.go` |
| Stagger percent value | `sim/monk/brewmaster/apl_values.go` |
| Stagger stacks = damage/tick | `sim/monk/brewmaster/stagger.go:73` |
| Vengeance model + HP cap | `sim/core/vengeance.go:14`, `:109` |
| Survival CD gating | `sim/core/major_cooldown.go:141` |
| Healing model | `sim/core/health.go:183` |
| Tiger Palm free for BM | `sim/monk/tiger_palm.go:110`, `:120` |
| Jab cost + chi gain | `sim/monk/jab.go:71`, `:96` |
| Keg Smash cost + chi gain | `sim/monk/brewmaster/keg_smash.go:23`, `:64` |
| Expel Harm heal-to-damage | `sim/monk/expel_harm.go` |
| Guard absorb + Power Guard | `sim/monk/brewmaster/guard.go:48` |
| T15 set bonuses | `sim/monk/items.go:80`, `:203` |
| Synapse Springs | `sim/common/mop/enchants.go:232` |
| Preset registration | `ui/monk/brewmaster/presets.ts` |
| Spell id to name | `assets/database/db.json` -> `spellIcons[]` |
| APL authoring docs | `tools/APL.md` |
| Sim CLI | `cmd/wowsimcli` |
