# IK Foot System

**Version 0.31** - TraceGroundSample now filters out all player entities, not just the current player.

Inverse kinematics foot placement system for Garry's Mod that makes player models adapt to terrain naturally.

## Features

- Dynamic foot placement on uneven terrain
- Smooth animation interpolation
- Body position adjustment based on ground height
- Midpoint stair sampling for stable climbing
- Per-foot world-space planting and swing detection
- Configurable foot rotation to match surface angles
- Idle stabilization to prevent jittering
- PAC3 compatibility
- Debug visualization modes
- Preset system for quick configuration switching

## What's New in 0.31

- TraceGroundSample now filters out all player entities, not just the current player.

## Console Commands

- `ik_foot_menu` - Opens the configuration menu
- `!ikfoot` or `/ikfoot` - Chat commands to open menu

## Configuration Variables

- `ik_foot` - enable/disable IK foot system (default: 1)
- `ik_foot_lean` - enable/disable body leaning (default: 0)
- `ik_foot_ground_distance` - ground detection range (default: 45)
- `ik_foot_smoothing` - animation smoothing factor (default: 17)
- `ik_foot_debug` - debug visualization level (default: 0)
- `ik_foot_leg_length` - leg length for calculations (default: 45)
- `ik_foot_trace_start_offset` - trace starting height offset (default: 30)
- `ik_foot_sole_offset` - sole contact point offset (default: 1.75)
- `ik_foot_uneven_drop_scale` - body drop scaling on uneven terrain (default: 0.35)
- `ik_foot_extra_body_drop` - base body drop amount (default: 0.3)
- `ik_foot_extra_body_drop_uneven` - additional body drop on slopes (default: 1.2)
- `ik_foot_high_foot_bend_boost` - knee bend multiplier (default: 1.45)
- `ik_foot_rotation_scale` - foot rotation intensity (default: 0.15)
- `ik_foot_stabilize_idle` - stabilize when idle (default: 1)
- `ik_foot_idle_velocity` - idle detection threshold (default: 5)
- `ik_foot_idle_threshold` - idle position tolerance (default: 0.5)

## Usage

1. Give me your soul
2. Subscribe to the addon on Steam Workshop
3. Start a game
4. Use `ik_foot_menu` command or find it in the spawn menu under Utilities > User > IK Foot Settings
5. Adjust settings to your preference or load a preset
6. Walk around on uneven terrain to see the effects


## Development Status

This is version 0.31. The addon is still being tuned and improved. Feedback and suggestions are welcome!

## Credits

Created by nikt_ani_nic
Inspired by https://steamcommunity.com/sharedfiles/filedetails/?id=1605334558

**Note:** README and comments were generated with AI assistance.

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
[*]Smooth animation interpolation
[*]Automatic body height adjustment based on ground level
[*]Midpoint stair stabilization
[*]Per-foot world-space locking and swing detection
[*]Configurable foot rotation to match surface angles
[*]Optional body leaning
[*]Idle stabilization to prevent jittering
[*]PAC3 compatibility
[*]Debug visualization modes
[*]Preset system for quick configuration switching
[/list]

[h2]Console Commands[/h2]

[list]
[*][b]ik_foot_menu[/b] - Opens the configuration menu
[*][b]!ikfoot[/b] or [b]/ikfoot[/b] - Chat commands to open the menu
[/list]

Menu location:
Spawn Menu > Utilities > User > IK Foot Settings

[h2]Configuration (ConVars)[/h2]

Fully configurable via console variables:

[list]
[*][b]ik_foot[/b] - Enable/disable system (default: 1)
[*][b]ik_foot_lean[/b] - Enable/disable body leaning (default: 0)
[*][b]ik_foot_ground_distance[/b] - Ground detection range (default: 45)
[*][b]ik_foot_smoothing[/b] - Animation smoothing factor (default: 17)
[*][b]ik_foot_debug[/b] - Debug visualization level (default: 0)
[*][b]ik_foot_leg_length[/b] - Leg length for calculations (default: 45)
[*][b]ik_foot_trace_start_offset[/b] - Trace starting height offset (default: 30)
[*][b]ik_foot_sole_offset[/b] - Sole contact point offset (default: 1.75)
[*][b]ik_foot_uneven_drop_scale[/b] - Body drop scaling on uneven terrain (default: 0.35)
[*][b]ik_foot_extra_body_drop[/b] - Base body drop amount (default: 0.3)
[*][b]ik_foot_extra_body_drop_uneven[/b] - Additional body drop on slopes (default: 1.2)
[*][b]ik_foot_high_foot_bend_boost[/b] - Knee bend multiplier (default: 1.45)
[*][b]ik_foot_rotation_scale[/b] - Foot rotation intensity (default: 0.15)
[*][b]ik_foot_stabilize_idle[/b] - Stabilize when idle (default: 1)
[*][b]ik_foot_idle_velocity[/b] - Idle detection threshold (default: 5)
[*][b]ik_foot_idle_threshold[/b] - Idle position tolerance (default: 0.5)
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

[b]Version 0.31 - Current Release[/b]

TraceGroundSample now filters out all player entities, not just the current player.

[h2]Credits[/h2]

Created by [b]nikt_ani_nic[/b]
Inspired by:
[url=https://steamcommunity.com/sharedfiles/filedetails/?id=1605334558]Original inspiration addon[/url]

Some README and comments were generated with AI assistance.
```