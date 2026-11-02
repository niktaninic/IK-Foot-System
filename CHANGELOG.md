# Changelog

Detailed notes per version. "Test" numbers come from the offline simulation in `tests/` (fake engine), not from measurements in Garry's Mod.

## 0.51

Also in 0.51: a new settings menu (pages, search, style presets, per-setting explanations and reset buttons), client-only performance options for other players (`ik_foot_others`, `ik_foot_max_distance`) and in-game diagnostics (`ik_foot_diag`, `ik_foot_dump`, `ik_foot_capture`). Steep stairs: a foot no longer plants on the edge of the step above when going down.

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
- Stair entry: the stepper seeded feet on the floor before the stairs at the start of the scan window
  (20 units behind the body, which then crouched on flat ground), let the animation's planted foot step
  first while its lifted one waited (left 25 units behind at a run) and sent the first foot straight
  onto the first step from far away. Feet now start where they stand, the animation's lifted foot steps
  first, and the floor is walked up to the stairs. The stair crouch is a peak hold seeded from the
  rise, so the first steps are covered too. Body jerk (test, previous -> now): walk down 2.7 -> 0.4,
  run down 6.7 -> 1.1, walk up 0.63 -> 0.42, run up 4.3 -> 3.2; feet reach their treads in every case.
- Standing on stairs while being moved sideways slower than walking (pushed, sliding): the stair
  stepper only measured along the stairs and placed feet relative to where the stairs were scanned, so
  both feet stayed behind (18 units after 4 s in the test, a teleport later). Feet now follow with
  steps, measured and placed relative to the body; moving off the scanned line rescans.
- Diagnostics: `restep_loop` counted the last steps of a walk after every stop (thousands of false
  alarms); it now counts only steps started while standing. Serious events (big solver misses,
  replants, re-step loops, engine mismatches, NaN, errors) keep ~10 s of history before and 2 s after
  them as `incidents` in `ik_foot_dump`, so a later dump still shows what happened.
- Cost: the stair scan (41 traces) ran every 0.12 s even standing still or on flat ground. It now
  follows motion and, over smooth ground, only looks as often as it must to find stairs in time, ahead
  of the player only. Hot trace code reuses its vectors. Test: traces per frame walking on flat ground
  20 -> 14, standing 15 -> 10.5, on stairs 17 -> 13; Vector allocations per frame about -25 %.

## 0.50

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
