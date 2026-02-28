# IK Foot System

**Version 0.1** - Early release, still subject to optimization and improvements.

Inverse kinematics foot placement system for Garry's Mod that makes player models adapt to terrain naturally.

## Features

- Dynamic foot placement on uneven terrain
- Smooth animation interpolation
- Body position adjustment based on ground height
- Configurable foot rotation to match surface angles
- Idle stabilization to prevent jittering
- PAC3 compatibility
- Debug visualization modes
- Preset system for quick configuration switching

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
- `ik_foot_extra_body_drop` - base body drop amount (default: 1.0)
- `ik_foot_extra_body_drop_uneven` - additional body drop on slopes (default: 4.0)
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

This is version 0.1 - an early release of the addon. There are likely areas that could be optimized or improved. Feedback and suggestions are welcome!

## Credits

Created by nikt_ani_nic
Inspired by https://steamcommunity.com/sharedfiles/filedetails/?id=1605334558

**Note:** README and comments were generated with AI assistance.