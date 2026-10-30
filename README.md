# IK Foot System

**Version 0.51** - in-game diagnostics, follower/PAC/REST H fixes (0.50: real stair stepping, analytical leg IK, robust bone detection)

Inverse kinematics foot placement system for Garry's Mod that makes player models adapt to terrain naturally.

## Features

- Analytical two-bone leg IK (law of cosines) that hits the exact foot target, rig-axis independent
- Procedural stair gait: one stair per step, alternating feet, toe-clearance arcs (up and down)
- Smooth body height on stairs: Source's per-step origin pops are absorbed in world space
- Body height derived from real leg reach (supporting feet only), knee-fold limit, landing absorption
- Per-foot ground sampling with edge clustering, foot lock against height flicker
- Foot alignment to slopes, only while the foot is actually planted
- Automatic bone detection: body root from the hierarchy (not "bone 0"), only skinned extra roots follow the body
- Per-model mesh analysis (sole height, skinned bones) used automatically for every player
- Zero-latency pose (computed in PrePlayerDraw, once per frame)
- PAC3 compatibility (additive bone blending)
- Debug visualization (contacts, IK targets, knee lines, stair profile)
- Preset system for quick configuration switching

## What's New in 0.51

Fixes found in a full review of the per-frame pipeline. "Verified" below means the offline tests
(`tests/run.py`, fake engine), not confirmed in Garry's Mod yet.

- Bone layer composed rotations per euler component. With any other rotation on the same bone
  (another addon, a PAC bone part on a leg) the drawn foot ended up away from the solver's result
  (2.2 units for a 25/30/-20 deg foreign rotation in the test). Rotations are now composed; with PAC
  parts on our bones the parts' share is recovered every frame so PAC's next reset reproduces the drawn pose.
- Foot followers parented to the thigh or calf (not only to the pelvis) now get the foot's transform.
  Detection records a verdict for every candidate and rejects bones that sit between both feet (skirt hem),
  are tall (coat tail), belong to the other leg, sit under the spine/lean bone, are helpers, or already
  inherit the foot. The foot centre falls back to toe vertices, then to the lowest mesh region, instead of
  the current (possibly stale) bone matrix.
- REST H has an expected value from the model's bind pose ankle height (scaled with the model) and rejects
  reads outside it. Independently, a sudden deviation is only learned if it persists for 1 s.
- Stepper: feet on turned/diagonal stairs no longer straddle an edge (heel, centre and toe must share one
  surface); low frame rates run the stepper in sub-steps (10 fps used to skip four stairs); a trailing foot
  that is about to fall out of reach lifts early instead of being teleported; a settle step started while
  standing finishes with the body when walking off.
- Teleports reset the smoothed state; stair-pop detection includes the ground entity's velocity (lifts);
  the foot lock uses the same ground height as the unlocked path (no 2 unit pop when it engages);
  leg length is cached per model scale; NaN angles from bone matrices are rejected; frame time is no
  longer capped at 1/20 s.
- Ground traces ignore player clip brushes (invisible ramps many maps put over stairs). The feet stood on
  the ramp, up to a step above the treads, and the stair stepper never saw steps there.
- A foot over a ledge or a gap no longer reaches for the ground below it. Ground more than a step below
  the player only counts when it can be reached in walkable steps (stairs); otherwise the body crouched to
  its limit (25 units at a 30 unit ledge in the test) with the leg still dangling.
- After a pause in drawing the player (first person, out of view, IK switched off) the IK starts fresh
  instead of resuming from the old locks and springs (the body was 10 units off after 0.3 s on stairs).
- Settings received over the network are range-checked on every client and NaN falls back to the default;
  presets can only set the addon's own cvars.
- Slopes: planted feet floated up to 6 units above a 27 deg ramp walking up and sank 2.4 units into it
  walking down. Three causes: anti-clip compared the five ground samples flat (the toe sample on an upslope
  is higher only because of the slope), the foot lock held a fixed height while the animation slid the
  foot along the slope, and the per-foot smoothing lagged behind the origin climbing the slope. Samples
  are now compared along the plane the sole will be turned to, the lock holds the ground plane, and only
  what that plane does not explain (edges, seams) is smoothed. Now 0 to 1.3 units on the same ramp
  (the default 80 % foot alignment leaves about 0.8 by geometry).
- When a supporting foot lifted off, its reach limit vanished within a frame or two and the body shot up
  (3 units in one frame walking up a ramp, 0.9 stepping onto a curb). The limit is now released over
  0.2 s (tightening still applies at once), for the animation's own feet; the stair stepper is unchanged.
- Stairs: the body height now follows the staircase instead of the feet. The per-foot requirements change
  in jumps whenever a foot lifts off or lands, so the body went down stairs in bursts and the landing foot
  was left up to 2.6 units short of its tread. The scanned profile under the hips, averaged over one tread
  depth, is a straight ramp through the tread centres; the body rides it, aimed ahead by the walking speed,
  crouched as much as the feet turned out to need (learned within a step or two). The foot requirements
  remain a floor. Going down (test): landing foot short 1.9 -> 0 units, body jerk 2.7 -> 1.8 (walk) and
  6.7 -> 1.9 (run). `ik_foot_dump` shows the learned `stair_crouch`; the drop limiter reads `stair_line`.

## Diagnostics

All commands only observe; running them does not change the IK state.

- `ik_foot_diag` - short console report: model, REST H vs expected, drop limiter, per-leg state, followers
  with their engine error, rejected candidates near the feet, recent events, and a list of likely causes.
- `ik_foot_dump` - full state to `garrysmod/data/ik_foot/dump_<date>.json` (config, bone set, follower
  verdicts, current detailed sample, ~10 s history, events).
- `ik_foot_capture [seconds] [detail]` - record samples at 30 Hz (max 60 s) to `data/ik_foot/capture_<date>.json`;
  `ik_foot_capture_stop` saves early.
- `ik_foot_debug 0/1/2` - overlay off / basic / detailed. Colours: gray = animated foot, yellow = target,
  green = IK result (leg lines), magenta = engine read back, cyan = ground contact, orange = knee direction.
- `ik_foot_diag_history 0/1` (default 1) - cheap always-on history for the local player.
- `ik_foot_diag_print 0/1` (default 1) - rate-limited event lines in the console while debugging or capturing.

Data is recorded in three stages: `anim` (clean pose without IK), `solver` (what was computed) and
`engine` (bones read back after the model was drawn). A solver/engine difference means something between
our manipulation and the final bones did not behave as assumed. Events (`foreign_write`, `engine_mismatch`,
`follower_error`, `rest_jump`, `contact_lost`, `solver_miss`, `restep_loop`, `replant`, `teleport`, `nan`,
`process_error`) carry time, frame, leg, a count when repeated, and the relevant values.

## What's New in 0.50

### Stairs ("climbs several steps at once" - fixed)
- Root cause: the old procedural stepper only moved the point where the ground was traced. The visible foot
  still followed the walk animation, whose stride covers 2-4 treads, so the character visibly skipped stairs.
- New stair stepper: a ground profile is scanned along the movement direction and split into treads. Each
  foot is placed on a real tread, alternating, `ik_foot_stair_treads_per_step` treads ahead of the other foot.
  The foot rises first and moves forward late when climbing (and the reverse when descending), so it clears the
  step edge.
- Treads per step only goes up when one tread per step would exceed `ik_foot_stair_max_cadence`
  (GMod's 200 u/s is ~3.8 m/s, so at that speed it takes two stairs per step, like a person would).
  At sprint speeds where no believable stair gait exists it blends back to the animation.
- Standing still on stairs, a foot left far from under the body takes one calm step onto the tread under the hips.
- Source moves the player origin up a whole step in one tick. The body used to pop by the full step height;
  those discrete jumps are now detected and absorbed, with adaptive smoothing on fast climbs.

### Bone detection ("hair bones were moved too")
- The body offset was always applied to bone 0, and every bone with no parent was moved along with it.
  On models with extra bones (hair/accessory roots, helper/IK/attachment bones, bones merged in by
  `$includemodel`) that moved bones that should never be touched.
- The body root is now the topmost ancestor of the thigh bones. Extra root bones only follow the body when
  mesh vertices are actually skinned to them (or their children) and they are not helper bones by name.
- Leg chains are validated (calf under thigh, foot under calf). Rigs with non-ValveBiped names are detected
  through the hierarchy, skipping twist bones. Broken rigs are rejected instead of half-applied.
- Manipulations are removed from the old bone indices when a model changes.
- Foot followers: geometry skinned around a foot to bones that are not children of the foot (shoes hanging
  off the pelvis on some models) now gets the same transform as the solved foot instead of staying behind.
- PAC3: with pac parts worn, pac defers bone manipulations by a frame; the IK now writes its own delta
  directly and mirrors it into pac's bone table, so it never computes on top of its own previous result.

### Math
- Old knee solve: `asin(lift / (leg/2)) * 1.7` applied as thigh -k / calf +k. That keeps the calf parallel
  to the animation, so the foot moved forward by l*sin(k) and up only l*(1-cos(k)); the 1.7 "boost" hid it.
  Replaced by an exact two-bone solve (verified numerically: 0 error over 400 random poses and rig conventions).
- Cvars that were scaled twice (auto-detect wrote model-sized values that were then multiplied by the model
  scale again) are now reference-skeleton units, scaled once. Old stored values are migrated automatically.
- `ik_foot_sole_offset` now also works on flat ground (it was clamped away before).
- The foot lock actually affects the pose now (it only fed the debug overlay before).
- Body lean rotates around the real body axes (the old roll on Spine1 was a twist) and leans into
  acceleration instead of velocity.

### Performance
- 5 traces per foot instead of 9 hull traces, with a table filter instead of a Lua callback per entity.
- Stair profile scanned at most every 0.12 s, stepper ground traces only when a foot lands.
- Params read once per frame, IK skipped beyond 3000 units, no per-frame resets while disabled.

### Other
- Single loader `lua/autorun/ik_foot.lua` (the generic `lua/autorun/init.lua` could be overridden by any other addon).
- Remote players no longer read 0 for every param before the server has networked them.
- Client re-sends its config periodically so a rate-limited update can't leave the server out of sync.

## Development Status

Version 0.50. Feedback welcome.

## Console Commands

- `ik_foot_menu` - Opens the configuration menu
- `ik_foot_hard_reset` - Nuclear reset of all IK state
- `!ikfoot` or `/ikfoot` - Chat commands to open menu

## Configuration Variables

Values marked *(ref)* are in reference-skeleton units (45 unit leg) and scale with the model automatically.

### General
- `ik_foot` - enable/disable IK foot system (default: 1)
- `ik_foot_lean` - enable/disable body leaning (default: 0)
- `ik_foot_debug` - debug visualization level 0-2 (default: 0)
- `ik_foot_smoothing` - body/foot height smoothing, higher = snappier (default: 17)

### Ground Detection
- `ik_foot_ground_distance` - ground trace distance *(ref)* (default: 70)
- `ik_foot_trace_start_offset` - trace start height above the player origin *(ref)* (default: 30)
- `ik_foot_sole_offset` - extra sole offset on top of the automatic mesh correction (default: 0)

### Leg & Foot
- `ik_foot_leg_length` - leg length override, 0 = measured from bones (default: 0)
- `ik_foot_rotation_scale` - how much planted feet align to the slope (default: 0.8)
- `ik_foot_rotation_smoothing` - slope alignment smoothing (default: 20)
- `ik_foot_lock_strength` - foot planting stickiness (default: 0.85)
- `ik_foot_release_speed` - foot speed that releases a planted foot (default: 65)

### Stairs
- `ik_foot_stair_stepper` - procedural stair stepping (default: 1)
- `ik_foot_stair_treads_per_step` - minimum stairs per step (default: 1)
- `ik_foot_stair_max_cadence` - max steps per second before taking more stairs per step (default: 8)
- `ik_foot_stair_step_lift` - foot clearance over step edges *(ref)* (default: 3)
- `ik_foot_stair_step_min_height` / `ik_foot_stair_step_max_height` - step heights treated as stairs *(ref)* (default: 3 / 20)
- `ik_foot_moving_surface_max_speed` - stairs on surfaces faster than this use the animation (default: 45)

### Body & Stability
- `ik_foot_uneven_drop_scale` - extra body drop per unit of height difference (default: 0.15)
- `ik_foot_extra_body_drop` - extra body drop when a foot is lower than the origin *(ref)* (default: 0.3)
- `ik_foot_extra_body_drop_uneven` - extra body drop on uneven ground *(ref)* (default: 1.2)
- `ik_foot_max_body_drop` - maximum body drop *(ref)* (default: 24)
- `ik_foot_stabilize_idle` - keep feet locked while idle (default: 1)
- `ik_foot_idle_velocity` - idle detection velocity threshold (default: 5)

### Automation & Safety
- `ik_foot_auto_model_detect` - use the per-model mesh analysis and announce it on model change (default: 1)
- `ik_foot_anti_clip` - rest feet on the highest point under them instead of the average (default: 1)
- `ik_foot_dynamic_sole` - calibrate the ankle height from the animation at runtime (default: 1)

Removed: `ik_foot_high_foot_bend_boost` (compensated the old wrong knee formula),
`ik_foot_stair_sequence_window`, `ik_foot_stair_release_multiplier`, `ik_foot_stair_adaptive_maxstep`.

## Running the tests

The runtime can be tested without Garry's Mod: `pip install lupa` then `python3 tests/run.py` (solver, bone detection, PAC bone layer, stair/flat/curb/ramp walks with stops, turns, strafing, teleport and 10 fps, REST H bad reads, and the whole per-frame pipeline on a fake engine incl. dump/capture JSON). It exits non-zero on any failed check.

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
- if model is cursed, set `ik_foot_leg_length` to the real leg length (0 = auto)

---

### Feet clipping into the ground

**what's happening:**
foot goes into the floor like it's not solid

**why:**
anti-clip is off or contact detection is garbage

**fix:**
- enable `ik_foot_anti_clip 1`
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
[*][b]ik_foot_smoothing[/b] - Height smoothing (default: 17)
[*][b]ik_foot_ground_distance[/b] - Ground trace distance (default: 70)
[*][b]ik_foot_trace_start_offset[/b] - Trace starting height offset (default: 30)
[*][b]ik_foot_sole_offset[/b] - Extra sole offset (default: 0)
[*][b]ik_foot_leg_length[/b] - Leg length override, 0 = auto (default: 0)
[*][b]ik_foot_rotation_scale[/b] - Foot slope alignment (default: 0.8)
[*][b]ik_foot_lock_strength[/b] - Foot planting stickiness (default: 0.85)
[*][b]ik_foot_release_speed[/b] - Foot release speed threshold (default: 65)
[*][b]ik_foot_stair_stepper[/b] - Procedural stair stepping (default: 1)
[*][b]ik_foot_stair_treads_per_step[/b] - Minimum stairs per step (default: 1)
[*][b]ik_foot_stair_max_cadence[/b] - Max stair steps per second (default: 8)
[*][b]ik_foot_stair_step_lift[/b] - Foot clearance over step edges (default: 3)
[*][b]ik_foot_uneven_drop_scale[/b] - Body drop scaling on uneven terrain (default: 0.15)
[*][b]ik_foot_extra_body_drop[/b] - Base body drop amount (default: 0.3)
[*][b]ik_foot_extra_body_drop_uneven[/b] - Additional body drop on uneven ground (default: 1.2)
[*][b]ik_foot_max_body_drop[/b] - Maximum body drop (default: 24)
[*][b]ik_foot_stabilize_idle[/b] - Stabilize when idle (default: 1)
[*][b]ik_foot_idle_velocity[/b] - Idle detection threshold (default: 5)
[*][b]ik_foot_auto_model_detect[/b] - Auto-detect model settings (default: 1)
[*][b]ik_foot_anti_clip[/b] - Foot anti-clip guard (default: 1)
[*][b]ik_foot_dynamic_sole[/b] - Runtime ankle height calibration (default: 1)
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

[b]Version 0.50 - Current Release[/b]

[h2]What's New in 0.50[/h2]

[list]
[*]Fixed the long standing stair bug: the character no longer climbs several stairs per step. A real stair gait places each foot on its own tread, alternating feet, with toe clearance going up and down.
[*]Smooth body height on stairs (Source's per-step origin jumps are absorbed).
[*]Exact two-bone leg IK replaces the old approximate knee formula.
[*]Fixed bone detection: the body root comes from the skeleton hierarchy and only skinned extra roots follow the body, so hair/helper/attachment bones on models with many bones are no longer moved by mistake.
[*]Automatic per-model analysis (sole height, skinned bones) for every player.
[*]No more one-frame pose lag, fewer and cheaper traces.
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
