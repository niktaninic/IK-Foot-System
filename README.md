# IK Foot System

**Version 0.42** - Weapon holdtype foot levitation fix and reliability improvements

Inverse kinematics foot placement system for Garry's Mod that makes player models adapt to terrain naturally.

## Features

- Dynamic foot placement on uneven terrain
- Critically damped spring smoothing for body and leg response
- Body position adjustment based on ground height
- Multi-point per-foot ground sampling for stable contact
- Per-foot world-space planting and swing detection
- Configurable foot rotation to match surface angles
- Idle stabilization to prevent jittering
- PAC3 compatibility (additive bone blending)
- Debug visualization modes
- Preset system for quick configuration switching
- Analytical 2-bone leg solving with consistent knee bend direction
- Lower-foot support priority for curbs, edges, and uneven terrain
- Automatic model detection and auto-configuration on playermodel swap
- Anti-clip guard to prevent feet from clipping into geometry
- Dynamic sole correction feedback loop
- Crouch transition blending
- NaN recovery and consecutive failure tracking

## What's New in 0.42

- Fixed foot levitation when holding weapons (physgun, fists, any holdtype that raises foot bones in the animation).
  Root cause: ground traces were starting from `max(traceStartZ, footBoneZ + 8)` — weapon animations push foot bones upward, which shifted the trace start point up, reducing effective trace range, causing missed ground hits on one side.
  Fix: traces always start from `traceStartZ` (player origin + offset), independent of animation bone position.
- Removed `lTraceExcess`/`rTraceExcess` subtraction from `lReqDrop`/`rReqDrop`. This was a redundant correction that fired incorrectly when weapon animations elevated foot bones, zeroing the required drop and preventing the body from descending.
- Fixed auto-detect not firing on first playermodel load. Removed `hadPrevModel` gate — detection now triggers on any model change, including the initial one.
- Fixed leg measurement race: bone positions on the very first frame can be garbage if `SetupBones` hasn't run yet. Measurement is now only cached if the result is greater than 20 units.
- Added double-include guard (`_runtimeLoaded` flag) to prevent both `ik_foot.lua` and `init.lua` in `autorun/` from re-initializing the same runtime tables.
- Fixed half-on-curb foot sinking: ground contact now clusters samples around the highest valid hit (tolerance: 3 units) instead of averaging all samples. Low-side air samples no longer drag the contact Z down.
- Body lean moved from bone 0 (`Bip01`, world root with no visual effect) to `Bip01_Spine1`. Lean now actually does something.
- Fixed lean calculation: was using `vel:Dot(ply:GetAngles():Right())` which includes pitch component. Now zeroes pitch before computing `Right()` and uses explicit XY dot product.
- Fixed auto-detect suggested values: `leg_length` was hardcoded to 45, `ground_distance` was incorrectly set to `legLength`, `max_body_drop` floored too low, `traceStartRef` was divided by scale twice. All corrected.
- Raised `ground_distance` default from 45 to 70.

## What's New in 0.42

- Implement auxiliary bone handling and air state adjustments in IK system

## Development Status

Version 0.42. Still being tuned. Feedback welcome.

## Console Commands

- `ik_foot_menu` - Opens the configuration menu
- `ik_foot_hard_reset` - Nuclear reset of all IK state
- `!ikfoot` or `/ikfoot` - Chat commands to open menu

## Configuration Variables

### General
- `ik_foot` - enable/disable IK foot system (default: 1)
- `ik_foot_lean` - enable/disable body leaning (default: 0) (sometimes works)
- `ik_foot_debug` - debug visualization level 0-2 (default: 0)
- `ik_foot_smoothing` - animation smoothing factor (default: 17)

### Ground Detection
- `ik_foot_ground_distance` - ground trace distance (default: 45)
- `ik_foot_trace_start_offset` - trace starting height offset (default: 30)
- `ik_foot_sole_offset` - sole contact point offset (default: 0)

### Leg & Foot
- `ik_foot_leg_length` - leg length for IK calculations (default: 45)
- `ik_foot_high_foot_bend_boost` - knee bend multiplier for raised feet (default: 1.70)
- `ik_foot_rotation_scale` - foot rotation intensity (default: 0.15)

### Body & Stability
- `ik_foot_uneven_drop_scale` - body drop scaling on uneven terrain (default: 0.15)
- `ik_foot_extra_body_drop` - base body drop on flat ground (default: 0.3)
- `ik_foot_extra_body_drop_uneven` - additional body drop on slopes (default: 1.2)
- `ik_foot_max_body_drop` - maximum body drop cap (default: 42)
- `ik_foot_lock_strength` - foot planting stickiness (default: 0.85)
- `ik_foot_release_speed` - foot speed needed to release a planted foot (default: 65)
- `ik_foot_rotation_smoothing` - rotation smoothing speed (default: 20)
- `ik_foot_stabilize_idle` - stabilize feet when idle (default: 1)
- `ik_foot_idle_velocity` - idle detection velocity threshold (default: 5)

### Automation & Safety
- `ik_foot_auto_model_detect` - auto-apply settings on playermodel change (default: 1)
- `ik_foot_anti_clip` - prevent feet from clipping into ground (default: 1)
- `ik_foot_dynamic_sole` - dynamic sole correction feedback loop (default: 1)

## Usage

1. Give me your soul
2. Subscribe to the addon on Steam Workshop
3. Start a game
4. Use `ik_foot_menu` command or find it in the spawn menu under Utilities > User > IK Foot Settings
5. Adjust settings to your preference or load a preset
6. Walk around on uneven terrain to see the effects



## Troubleshooting & Fixes (when it inevitably breaks)

### Foot hovering above ground

**what's happening:**
foot floats slightly above terrain, especially on weird slopes or edges

**why:**
trace isn't reaching far enough or sole offset is off

**fix:**
- increase `ik_foot_ground_distance`
- tweak `ik_foot_sole_offset`
- if model is cursed, slightly increase `ik_foot_leg_length`

---

### Feet clipping into the ground

**what's happening:**
foot goes into the floor like it's not solid

**why:**
anti-clip is off or contact detection is garbage

**fix:**
- enable `ik_foot_anti_clip 1`
- enable `ik_foot_dynamic_sole 1`
- adjust `ik_foot_sole_offset`

---

### IK just stops working

**what's happening:**
no movement, feet freeze, or system just gives up

**why:**
state desynced / model changed / something (PAC3, probably) touched bones

**fix (quick version):**
- `ik_foot 0`
- change playermodel to anything else
- change back
- `ik_foot 1`

**fix (nuclear option):**
- `ik_foot_hard_reset`

yes this actually fixes most problems. dont ask.

---

### Character leaning forward / doing the michael jackson thing

**what's happening:**
body leans forward, feet stay behind like physics gave up

**why:**
body drop or crouch transition got weird

**fix:**
- lower `ik_foot_extra_body_drop`
- lower `ik_foot_extra_body_drop_uneven`
- check `ik_foot_max_body_drop`

---

### Feet jittering when standing still

**what's happening:**
small constant shaking when idle

**why:**
idle detection too sensitive or smoothing too low

**fix:**
- increase `ik_foot_smoothing`
- increase `ik_foot_idle_velocity`
- make sure `ik_foot_stabilize_idle 1`

---

### IK breaks after changing playermodel

**what's happening:**
everything was fine, then you changed model and now it's cursed

**why:**
cached bone/model data no longer matches reality

**fix:**
- `ik_foot 0`
- switch to another model
- switch back
- `ik_foot 1`

or just:
- `ik_foot_hard_reset`

---

## Quick Recovery (do this before you start tweaking 50 sliders)

1. `ik_foot 0`
2. change playermodel
3. change back
4. `ik_foot 1`
5. still broken? → `ik_foot_hard_reset`

this resets like 90% of issues.

## Notes

- some maps are just… bad. weird geometry, broken collisions, etc.
- the system tries to handle it but it's still Source engine
- if something looks cursed, it probably is

## Credits

Created by nikt_ani_nic
Inspired by https://steamcommunity.com/sharedfiles/filedetails/?id=1605334558

## Steam Workshop Description (BBCode)

```bbcode
[h1]IK Foot System[/h1]
[i]Real-time inverse kinematics foot placement for Garry's Mod[/i]

Player models in vanilla GMod treat the ground like a vague suggestion.
Stairs? Optional. Slopes? Theoretical. Dead bodies? Apparently air.

This addon fixes that.

IK Foot System dynamically adjusts player feet to uneven terrain using inverse kinematics. Your character actually reacts to what they're standing on instead of pretending the map is a perfectly flat showroom.

More grounded. More natural. Less accidental levitation.

[h2]What It Adapts To[/h2]

[list]
[*]Stairs (yes even the cursed uneven ones)
[*]Hills and mountains
[*]Slopes and angled props
[*]Vehicles
[*]Random map geometry
[*]Dead bodies (enemy ones obviously we're civilized)
[/list]

If you can stand on it the system will try to respect it.

[h2]Features[/h2]

[list]
[*]Dynamic foot placement on uneven terrain
[*]Critically damped spring smoothing
[*]Automatic body height adjustment based on ground level
[*]Multi-point per-foot ground sampling
[*]Per-foot world-space locking and swing detection
[*]Configurable foot rotation to match surface angles
[*]Optional body leaning
[*]Idle stabilization to prevent jittering
[*]PAC3 compatibility (additive bone blending)
[*]Debug visualization modes
[*]Preset system for quick configuration switching
[*]Auto model detection and configuration
[*]Anti-clip guard for ground penetration
[*]Dynamic sole correction feedback loop
[/list]

[h2]Console Commands[/h2]

[list]
[*][b]ik_foot_menu[/b] - Opens the configuration menu
[*][b]ik_foot_hard_reset[/b] - Nuclear reset of all IK state
[*][b]!ikfoot[/b] or [b]/ikfoot[/b] - Chat commands to open the menu
[/list]

Menu location:
Spawn Menu > Utilities > User > IK Foot Settings

[h2]Configuration (ConVars)[/h2]

Fully configurable via console variables:

[list]
[*][b]ik_foot[/b] - Enable/disable system (default: 1)
[*][b]ik_foot_lean[/b] - Enable/disable body leaning (default: 0)
[*][b]ik_foot_debug[/b] - Debug visualization level (default: 0)
[*][b]ik_foot_ground_distance[/b] - Ground trace distance (default: 45)
[*][b]ik_foot_smoothing[/b] - Animation smoothing factor (default: 17)
[*][b]ik_foot_leg_length[/b] - Leg length for calculations (default: 45)
[*][b]ik_foot_trace_start_offset[/b] - Trace starting height offset (default: 30)
[*][b]ik_foot_sole_offset[/b] - Sole contact point offset (default: 0)
[*][b]ik_foot_uneven_drop_scale[/b] - Body drop scaling on uneven terrain (default: 0.15)
[*][b]ik_foot_extra_body_drop[/b] - Base body drop amount (default: 0.3)
[*][b]ik_foot_extra_body_drop_uneven[/b] - Additional body drop on slopes (default: 1.2)
[*][b]ik_foot_high_foot_bend_boost[/b] - Knee bend multiplier (default: 1.70)
[*][b]ik_foot_rotation_scale[/b] - Foot rotation intensity (default: 0.15)
[*][b]ik_foot_lock_strength[/b] - Foot planting stickiness (default: 0.85)
[*][b]ik_foot_release_speed[/b] - Foot release speed threshold (default: 65)
[*][b]ik_foot_rotation_smoothing[/b] - Rotation smoothing speed (default: 20)
[*][b]ik_foot_max_body_drop[/b] - Maximum body drop (default: 42)
[*][b]ik_foot_stabilize_idle[/b] - Stabilize when idle (default: 1)
[*][b]ik_foot_idle_velocity[/b] - Idle detection threshold (default: 5)
[*][b]ik_foot_auto_model_detect[/b] - Auto-detect model settings (default: 1)
[*][b]ik_foot_anti_clip[/b] - Foot anti-clip guard (default: 1)
[*][b]ik_foot_dynamic_sole[/b] - Dynamic sole correction (default: 1)
[/list]

[h2]Usage[/h2]

[list=1]
[*]Offer your soul.
[*]Subscribe to the addon.
[*]Launch Garry's Mod.
[*]Open the configuration menu.
[*]Walk over questionable terrain and admire your character finally understanding gravity.
[/list]

(Soul offering remains optional.)

[h2]Source Code[/h2]

[url=https://github.com/niktaninic/IK-Foot-System]https://github.com/niktaninic/IK-Foot-System[/url]

Fork it. Modify it. Optimize it. Pretend you would have written it cleaner.

[h2]Development Status[/h2]

[b]Version 0.42 - Current Release[/b]

[h2]What's New in 0.42[/h2]

[list]
[*]Fixed foot levitation when holding weapons (physgun, fists, any holdtype that raises foot bones). Traces now always start from player origin, not animated bone position.
[*]Removed erroneous trace excess subtraction that was zeroing required body drop when weapon animations elevated foot bones.
[*]Fixed auto model detection not firing on first playermodel load.
[*]Fixed leg measurement race condition on first frame (bad bone positions before SetupBones runs).
[*]Fixed double-include bug where both autorun files were re-initializing runtime tables independently.
[*]Fixed foot sinking on curbs/edges — contact now clusters around the highest valid sample instead of averaging all including air-side samples.
[*]Body lean now uses Bip01_Spine1 instead of the world root bone. It now visually works.
[*]Fixed lean calculation including pitch component. Now uses pitch-zeroed right vector with explicit XY dot.
[*]Fixed auto-detect suggested values (leg_length, max_body_drop, traceStartRef, ground_distance were all wrong).
[*]Raised ground_distance default from 45 to 70.
[/list]

[h2]Troubleshooting (when it inevitably breaks)[/h2]

[b]Foot hovering above ground[/b]
Trace isn't reaching far enough or sole offset is off.
→ Increase [b]ik_foot_ground_distance[/b], tweak [b]ik_foot_sole_offset[/b], or bump [b]ik_foot_leg_length[/b] if your model is cursed.

[b]Feet clipping into the ground[/b]
Anti-clip is off or contact detection is having a bad day.
→ Enable [b]ik_foot_anti_clip 1[/b] and [b]ik_foot_dynamic_sole 1[/b]. Adjust [b]ik_foot_sole_offset[/b].

[b]IK just stops working[/b]
State desynced, model changed, or something (PAC3 probably) touched the bones.
→ Quick fix: [b]ik_foot 0[/b] → change model → change back → [b]ik_foot 1[/b]
→ Nuclear option: [b]ik_foot_hard_reset[/b]
Yes this actually fixes most problems. Don't ask.

[b]Character leaning forward / doing the michael jackson[/b]
Body drop or crouch transition got weird.
→ Lower [b]ik_foot_extra_body_drop[/b], [b]ik_foot_extra_body_drop_uneven[/b], check [b]ik_foot_max_body_drop[/b].

[b]Feet jittering when standing still[/b]
Idle detection too sensitive or smoothing too low.
→ Increase [b]ik_foot_smoothing[/b] and [b]ik_foot_idle_velocity[/b]. Make sure [b]ik_foot_stabilize_idle 1[/b].

[b]IK breaks after changing playermodel[/b]
Cached bone/model data no longer matches reality.
→ [b]ik_foot 0[/b] → switch model → switch back → [b]ik_foot 1[/b]
→ Or just: [b]ik_foot_hard_reset[/b]

[b]Quick recovery (do this before tweaking 50 sliders):[/b]
1. [b]ik_foot 0[/b]
2. Change playermodel
3. Change back
4. [b]ik_foot 1[/b]
5. Still broken? → [b]ik_foot_hard_reset[/b]
This fixes like 90% of issues.

[i]Some maps are just bad. Weird geometry, broken collisions, etc. The system tries its best but it's still Source engine. If something looks cursed, it probably is.[/i]

[h2]Credits[/h2]

Created by [b]nikt_ani_nic[/b]
Inspired by:
[url=https://steamcommunity.com/sharedfiles/filedetails/?id=1605334558]Original inspiration addon[/url]
```
