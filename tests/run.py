"""Offline tests for the IK runtime (no Garry's Mod needed).

    pip install lupa
    python3 tests/run.py

Runs the leg solver against forward kinematics, the bone detection against
synthetic rigs, and walks a simulated player over stairs / flat / curb / ramp.
"""
import os
import sys

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(test, setup=""):
    lua = lupa.LuaRuntime()
    lua.execute('ROOT = %r; %s' % (ROOT, setup))
    lua.execute('dofile(ROOT .. "/tests/%s")' % test)


run("test_solver.lua")
run("test_bones.lua")
run("test_pac.lua")
for setup in ("SPEED=60", "SPEED=90", "SPEED=200", "SPEED=400", "SPEED=90; DIR=-1", "SPEED=200; DIR=-1",
              'SPEED=90; WORLD="flat"', 'SPEED=90; WORLD="curb"', 'SPEED=90; WORLD="ramp"', "SPEED=90; STOPAT=1.37"):
    print("---", setup)
    sys.stdout.flush()
    run("test_stairs.lua", setup)
