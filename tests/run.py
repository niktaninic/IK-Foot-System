"""Offline tests for the IK runtime (no Garry's Mod needed).

    pip install lupa
    python3 tests/run.py

Runs the leg solver against forward kinematics, the bone detection against
synthetic rigs, and walks a simulated player over stairs / flat / curb / ramp.
"""
import os
import sys

import json

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


FAILS = []


def run(test, setup=""):
    lua = lupa.LuaRuntime()
    lua.execute('ROOT = %r; %s' % (ROOT, setup))
    lua.execute('dofile(ROOT .. "/tests/%s")' % test)
    return lua


def expect(setup, name, ok, value):
    if not ok:
        FAILS.append("%s | %s = %s" % (setup, name, value))
        print("  FAIL %s = %s" % (name, value))


g = run("test_solver.lua").globals()
expect("solver", "fk failures", g.SOLVER_FAILS == 0, g.SOLVER_FAILS)
g = run("test_bones.lua").globals()
expect("bones", "detection failures", g.BONES_FAILS == 0, g.BONES_FAILS)
g = run("test_pac.lua").globals()
expect("pac", "layer failures", g.PAC_FAILS == 0, g.PAC_FAILS)
for setup in ("SPEED=60", "SPEED=90", "SPEED=200", "SPEED=400", "SPEED=90; DIR=-1", "SPEED=200; DIR=-1",
              'SPEED=90; WORLD="flat"', 'SPEED=90; WORLD="curb"', 'SPEED=90; WORLD="ramp"', 'SPEED=90; WORLD="ramp"; DIR=-1',
              'SPEED=90; WORLD="ramp"; STRAFE=true', "SPEED=90; STOPAT=1.37",
              "SPEED=90; STOPAT=1.45; RESUMEAT=1.7", "SPEED=90; STOPAT=1.2; TURN=true", "SPEED=90; STRAFE=true",
              "SPEED=90; DIR=-1; STOPAT=1.5", "SPEED=90; TELEPORT_AT=1.0", "SPEED=90; LOWFPS=true",
              'SPEED=90; MODELSCALE=1.5; FOLLOWER_KIND="body"', 'SPEED=90; FOLLOWER_KIND="calf"',
              "SPEED=90; EXPECTED_REST=3", 'SPEED=90; WORLD="flat"; REST_DIP=true; EXPECTED_REST=3',
              'SPEED=90; WORLD="flat"; REST_DIP=true', 'SPEED=0; WORLD="flat"; REST_DIP=true; EXPECTED_REST=3',
              # an invisible player clip ramp over the stairs: feet must stand
              # on the visible treads and the stepper must still see stairs
              'SPEED=90; WORLD="clipstairs"',
              # standing at a ledge with the feet over the drop: no crouch
              'SPEED=90; WORLD="ledge"; STOPAT=0.78', 'SPEED=90; WORLD="ledge"; STOPAT=0.78; LEDGE_DROP=22',
              # steep / tall stairs walked down without the stepper: never a drop-off
              "SPEED=90; DIR=-1; NOSTEP=true; RISE=12; TREAD=10", "SPEED=400; DIR=-1; RISE=10",
              # not drawn for 0.3 s mid stairs (first person, out of view)
              "SPEED=90; HIDE_AT=1.0; HIDE_FOR=0.3",
              # going down: slower walk, taller steps
              "SPEED=60; DIR=-1", "SPEED=90; DIR=-1; RISE=10"):
    print("---", setup)
    sys.stdout.flush()
    r = run("test_stairs.lua", setup).globals().RESULT
    stairs = ("WORLD" not in setup or "clipstairs" in setup) and "TELEPORT" not in setup and "HIDE" not in setup
    expect(setup, "nan frames", r.nan == 0, r.nan)
    expect(setup, "restep loops", r.restepLoops == 0, r.restepLoops)
    expect(setup, "both feet swinging while idle", r.idleBothSwing == 0, r.idleBothSwing)
    expect(setup, "planted foot penetration", r.penetration < 0.5, r.penetration)
    expect(setup, "planted foot float", r.float < 3, r.float)
    expect(setup, "follower position error", r.shoeErr < 0.01, r.shoeErr)
    expect(setup, "follower angle error", r.shoeAngErr < 0.05, r.shoeAngErr)
    if stairs and "SPEED=200" not in setup and "SPEED=400" not in setup:
        expect(setup, "treads between footfalls", r.maxSkip <= 1, r.maxSkip)
    if stairs and "STOPAT" not in setup and "TURN" not in setup:
        expect(setup, "same foot twice", r.sameFootTwice == 0, r.sameFootTwice)
    if "REST_DIP" in setup and ("EXPECTED_REST" in setup or "SPEED=0" in setup):
        expect(setup, "REST H kept through bad reads", r.minRest > 2.5, r.minRest)
    if 'WORLD="ramp"' in setup:
        # foot turned 80 % onto a 27 deg slope: ~0.8 above by geometry, kinks at both ends
        expect(setup, "planted foot above a slope", r.plantedMax < 1.6, r.plantedMax)
        expect(setup, "planted foot sunk into a slope", r.plantedMin > -0.3, r.plantedMin)
    if setup == 'SPEED=90; WORLD="ramp"':
        # the rear foot lifting off used to let the body shoot up 3 units in a frame
        expect(setup, "body jump walking up a slope", r.maxDropJump < 2, r.maxDropJump)
    # going down, the body follows the staircase instead of the feet landing
    # one by one: it used to sink in bursts and leave the landing foot short
    # (previous build: float 1.7-2.6, jerk 2.6 / 2.7 / 4.0 / 6.7). the first
    # step off the top landing still has to learn the crouch
    down_jerk = {"SPEED=60; DIR=-1": 2.2, "SPEED=90; DIR=-1": 2.2, "SPEED=90; DIR=-1; RISE=10": 3.2, "SPEED=200; DIR=-1": 3.0}
    if setup in down_jerk:
        expect(setup, "planted foot short of the tread going down", r.float < 0.6, r.float)
        expect(setup, "body jerk going down", r.maxBodyAccel < down_jerk[setup], r.maxBodyAccel)
    if setup in ("SPEED=60", "SPEED=90"):
        expect(setup, "body jerk going up", r.maxBodyAccel < 1.2, r.maxBodyAccel)
    if 'WORLD="curb"' in setup:
        expect(setup, "body jump stepping onto a curb", r.maxDropJump < 0.7, r.maxDropJump)
    if ('WORLD="flat"' in setup or 'WORLD="curb"' in setup) and "REST_DIP" not in setup:
        expect(setup, "planted foot height on level ground", -0.3 < r.plantedMin and r.plantedMax < 0.3, (r.plantedMin, r.plantedMax))
    if "clipstairs" in setup:
        expect(setup, "stepper engaged under a clip ramp", r.stairFrames > 60, r.stairFrames)
    if "ledge" in setup:
        expect(setup, "body drop at a ledge", r.ledgeDrop < 2, r.ledgeDrop)
        expect(setup, "foot reaching down a ledge", r.ledgeAnkleMin > 0, r.ledgeAnkleMin)
    if "NOSTEP" in setup or "SPEED=400" in setup:
        expect(setup, "stairs taken for a drop-off", r.dropOffFrames == 0, r.dropOffFrames)
    if "HIDE_AT" in setup:
        expect(setup, "body off after resuming", r.resumeDropErr is not None and r.resumeDropErr < 1, r.resumeDropErr)
        expect(setup, "feet replanted after resuming", r.replants == 0, r.replants)

# full pipeline on the fake engine, with and without pac (parts on our bones),
# overlay paths enabled; dump and capture must be valid json
for setup in ("", "WITH_PAC=true", 'WITH_PAC=true; PAC_THIGH_PART={p=15,y=10,r=0}', 'DEBUG_LEVEL="2"', "SPEED=0"):
    print("--- pipeline", setup)
    sys.stdout.flush()
    lua = lupa.LuaRuntime()
    lua.execute('ROOT = %r; %s' % (ROOT, setup))
    lua.execute('dofile(ROOT .. "/tests/test_pipeline.lua")')
    for name in ("DUMP_JSON", "CAPTURE_JSON"):
        data = lua.globals()[name]
        try:
            json.loads(data)
            print("  %s: valid json (%d bytes)" % (name, len(data)))
        except Exception as exc:  # noqa: BLE001
            FAILS.append("%s | %s invalid json: %s" % (setup, name, exc))
            print("  FAIL %s: %s" % (name, exc))
    # the fields a bug report needs must be in the dump
    dump = json.loads(lua.globals().DUMP_JSON)
    for side in ("left", "right"):
        leg = dump["current"]["legs"][side]
        missing = [k for k in ("anim_foot", "target", "target_anim", "solver_ankle", "solver_knee", "hip",
                               "engine_ankle", "reach", "req", "blend", "contact", "step", "drop_limits")
                   if k not in leg]
        expect(setup, "dump %s leg fields" % side, not missing, missing)
    expect(setup, "dump rest / drop", "rest" in dump["current"] and "drop" in dump["current"], list(dump["current"]))
    expect(setup, "pipeline checks", lua.globals().PIPELINE_FAILS == 0, lua.globals().PIPELINE_FAILS)

print()
print("FAILED CHECKS:" if FAILS else "ALL CHECKS PASSED")
for f in FAILS:
    print("  " + f)
sys.exit(1 if FAILS else 0)
