# IK Foot System

Feet that stand on the ground. A client-side inverse kinematics addon for Garry's Mod that puts player
feet on stairs, slopes, curbs and props instead of letting them float over or sink into the world.

**Version 0.51** · [Changelog](CHANGELOG.md)

## What it does

- **Stairs, one tread per step.** The ground ahead is scanned and split into treads; each foot lands on
  its own tread, alternating, lifting over the edge going up and down. Fast enough and it takes two at a
  time, like a person would. Standing still on stairs, a foot left hanging takes one calm step under the body.
- **Smooth body height.** Source moves the player up a whole step in one tick; the body follows the
  staircase as a smooth line instead, and crouches only as much as the feet need to reach the ground.
- **Slopes and uneven ground.** Planted feet hold the ground plane, turn to lie on it, and stay put while
  the body moves over them.
- **Exact leg IK.** An analytical two-bone solver reaches the foot target exactly, on any rig orientation.
- **Works with your model.** Leg bones are found through the skeleton hierarchy (also on rigs without
  ValveBiped names); every model is measured once (leg length, sole height, extra skinned bones), and
  shoes or skirts hanging off the wrong bone follow the feet. Hair and helper bones are never moved.
- **PAC3 compatible.** The IK is a layer on top of the animation; PAC parts and other addons' bone
  changes on the same bones are kept.
- **Everyone, not just you.** Other players get IK too, with their own settings (networked and
  range-checked). Can be limited by distance or switched off for performance.
- **Safe at the edges.** Ledges and gaps are not mistaken for stairs, invisible player clips over stairs
  are ignored, teleports and pauses reset cleanly, NaN input never reaches a bone.

## Installation

Subscribe on the Steam Workshop, or copy this folder into `garrysmod/addons/`.
In multiplayer the server needs the addon too (it relays every player's settings to the others).

## Settings menu

Open it with `ik_foot_menu`, `!ikfoot` / `/ikfoot` in chat, or **Spawn menu > Utilities > User > IK Foot**.

| Page | What's there |
| --- | --- |
| Quick setup | Main switches, debug overlay, four style presets (Default, Subtle, Responsive, Grounded), live status |
| Ground, Legs & feet, Stairs, Body, Automation | Every setting with a plain explanation; a blue bar marks changed values, the arrow resets one |
| Performance | IK on other players and up to which distance (client only, not sent to the server) |
| Presets | Save, load and delete your own setups (`garrysmod/data/ik_foot_presets.txt`) |
| Diagnostics | Status, overlay, report / dump / recording buttons |
| About | Version, credits, command list |

The search box above the pages finds settings by name, description or console name.
Style presets only change tuning values, never your on/off switches.

## Console variables

Values marked *(ref)* are in units of a reference 45 unit leg and scale with the model automatically.

### General

| ConVar | Default | Range | Description |
| --- | --- | --- | --- |
| `ik_foot` | 1 | 0-1 | The whole system on or off for your character |
| `ik_foot_lean` | 0 | 0-1 | Lean the upper body into turns, acceleration and up stairs |
| `ik_foot_debug` | 0 | 0-2 | Debug overlay: off / basic / detailed |
| `ik_foot_smoothing` | 17 | 1-50 | How fast body and feet follow the ground (higher = snappier) |

### Ground

| ConVar | Default | Range | Description |
| --- | --- | --- | --- |
| `ik_foot_ground_distance` | 70 | 20-100 | How far down the feet look for ground *(ref)* |
| `ik_foot_trace_start_offset` | 30 | 20-40 | Where above the feet the ground search starts *(ref)* |
| `ik_foot_sole_offset` | 0 | -3-5 | Extra height between foot bone and ground, on top of the automatic value |
| `ik_foot_anti_clip` | 1 | 0-1 | A foot over an edge rests on top of it instead of sinking in |
| `ik_foot_moving_surface_max_speed` | 45 | 5-180 | Ground faster than this (lifts, vehicles) gets no stair steps or foot locks |

### Legs & feet

| ConVar | Default | Range | Description |
| --- | --- | --- | --- |
| `ik_foot_leg_length` | 0 | 0-80 | Leg length override; 0 = measured from the model (recommended) |
| `ik_foot_rotation_scale` | 0.8 | 0-1 | How much feet turn to lie flat on a slope |
| `ik_foot_rotation_smoothing` | 20 | 1-60 | How fast the feet turn to match the ground |
| `ik_foot_lock_strength` | 0.85 | 0.1-2 | How firmly a planted foot stays where it landed |
| `ik_foot_release_speed` | 65 | 5-200 | How fast the animation must move a planted foot to let it go |

### Stairs

| ConVar | Default | Range | Description |
| --- | --- | --- | --- |
| `ik_foot_stair_stepper` | 1 | 0-1 | Put every foot on a real tread instead of the animation's stride |
| `ik_foot_stair_treads_per_step` | 1 | 1-3 | Minimum treads per step |
| `ik_foot_stair_max_cadence` | 8 | 3-16 | Steps per second before more treads per step are taken |
| `ik_foot_stair_step_lift` | 3 | 0-10 | Clearance over the next tread's edge *(ref)* |
| `ik_foot_stair_step_min_height` | 3 | 1-12 | Smaller height differences are not stair steps *(ref)* |
| `ik_foot_stair_step_max_height` | 20 | 8-36 | Larger height differences are ledges, not stair steps *(ref)* |

### Body

| ConVar | Default | Range | Description |
| --- | --- | --- | --- |
| `ik_foot_max_body_drop` | 24 | 5-40 | Deepest crouch to keep both feet on the ground *(ref)* |
| `ik_foot_uneven_drop_scale` | 0.15 | 0-1 | Extra crouch when the feet stand at different heights |
| `ik_foot_extra_body_drop` | 0.3 | 0-5 | A little knee bend on flat ground |
| `ik_foot_extra_body_drop_uneven` | 1.2 | 0-10 | Extra knee bend on uneven ground and stairs |
| `ik_foot_stabilize_idle` | 1 | 0-1 | Keep the feet firmly planted while standing |
| `ik_foot_idle_velocity` | 5 | 1-20 | Below this speed you count as standing |

### Automation

| ConVar | Default | Range | Description |
| --- | --- | --- | --- |
| `ik_foot_auto_model_detect` | 1 | 0-1 | Measure every new player model and apply matching settings |
| `ik_foot_dynamic_sole` | 1 | 0-1 | Learn how high the ankle sits on a planted foot, per model |

### Client only (performance, diagnostics)

| ConVar | Default | Range | Description |
| --- | --- | --- | --- |
| `ik_foot_others` | 1 | 0-1 | IK on other players |
| `ik_foot_max_distance` | 3000 | 300-10000 | Other players further away than this get no IK |
| `ik_foot_diag_history` | 1 | 0-1 | Keep a cheap rolling history for reports |
| `ik_foot_diag_print` | 1 | 0-1 | Print event lines while the overlay or a recording is on |

## Commands

| Command | What it does |
| --- | --- |
| `ik_foot_menu` | Open the settings menu (also `!ikfoot` / `/ikfoot` in chat) |
| `ik_foot_hard_reset` | Remove all of the IK's bone changes and state, then start over |
| `ik_foot_diag` | Short report in the console: model, measurements, limits, recent events, likely causes |
| `ik_foot_dump` | Full state to `garrysmod/data/ik_foot/dump_<date>.json` |
| `ik_foot_capture [seconds] [detail]` | Record up to 60 s at 30 Hz to `data/ik_foot/capture_<date>.json` |
| `ik_foot_capture_stop` | Stop a recording early and save it |

## Troubleshooting

**Something looks wrong.** Turn on the overlay (`ik_foot_debug 2`) and run `ik_foot_diag`; its
"likely causes" list covers most problems. Overlay colours: gray = animation's foot, yellow = target,
green = IK result, magenta = what the engine drew, cyan = ground contact, orange = knee direction.

**Feet float or sink a little.** Adjust `ik_foot_sole_offset` (up if they sink, down if they float).
On an unusual model set `ik_foot_leg_length` to its real leg length.

**Feet ignore tall steps or low ground.** Raise `ik_foot_trace_start_offset` or `ik_foot_ground_distance`.

**Jitter while standing.** Raise `ik_foot_idle_velocity`, keep `ik_foot_stabilize_idle 1`, or try the
*Subtle* style.

**Stuck or broken after a model change or another addon.** `ik_foot_hard_reset`. If that is not enough:
`ik_foot 0`, change the player model and back, `ik_foot 1`.

**Reporting a bug.** Run `ik_foot_dump` right after it happens and attach the file. Serious events keep
~10 s of history before them (`incidents`), so the dump still shows what went wrong. A short
`ik_foot_capture 10` while reproducing helps even more.

## Known limitations

- Running fast up very steep stairs (a tread barely longer than the foot) can still leave a foot short
  of its tread for a moment.
- Maps with broken collision or unusual geometry can confuse the stair scan; it falls back to the
  animation when it cannot find a believable gait.
- 0.51 fixes were verified in the offline simulation; real-game feedback is welcome.

## For developers

```
lua/autorun/ik_foot.lua                    loader (server and client)
lua/autorun/client/cl_ik_foot_gui.lua      settings menu
lua/ik_foot/shared/sh_ik_foot_config.lua   settings: defaults, ranges, labels
lua/ik_foot/server/sv_ik_foot_sync.lua     relays player settings
lua/ik_foot/client/cl_ik_foot_sync.lua     sends your settings
lua/ik_foot/client/runtime/
  cl_ik_foot_context.lua   bone detection, model analysis, params, bone blend layer
  cl_ik_foot_hooks.lua     per-frame pipeline (strip, read pose, solve, apply)
  ik_ground.lua            ground traces, contact, stair scan
  ik_state.lua             per-player state, foot locks, stair stepper
  ik_controller.lua        targets, body height, foot alignment
  ik_solver.lua            analytical two-bone leg IK
  ik_apply.lua             writes the result to the bones
  ik_diag.lua              overlay, events, history, report, dump, capture
```

The runtime can be tested without the game: `pip install lupa`, then `python3 tests/run.py`.
It runs the solver against forward kinematics, bone detection on synthetic rigs, the PAC bone layer,
the menu on a Derma mock, simulated walks (stairs up and down, steep stairs, flat, curb, ramp, ledge,
player clips, stops, turns, strafing, drifting, teleports, 10 fps, pauses) and the full per-frame
pipeline on a fake engine. It exits non-zero on any failed check.

## Credits

Created by **nikt_ani_nic**.
Inspired by [this addon](https://steamcommunity.com/sharedfiles/filedetails/?id=1605334558).
Source: <https://github.com/niktaninic/IK-Foot-System>
