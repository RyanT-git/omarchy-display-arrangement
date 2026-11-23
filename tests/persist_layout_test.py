#!/usr/bin/env python3
"""Run: python3 -I tests/persist_layout_test.py

Exercises persist-layout.py against a throwaway HOME, never the real config.
"""

import os
import subprocess
import sys
import tempfile

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "persist-layout.py")

SAMPLE = """local omarchy_gdk_scale = 2
local omarchy_monitor_scale = 1

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

hl.monitor({ output = "DP-1", mode = "1920x1080@60", position = "0x0", scale = 1 })
hl.monitor({ output = "DP-2", mode = "1920x1080@60", position = "1920x0", scale = 1, transform = 1 })
-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })
hl.monitor({
  output = "HDMI-A-1",
  scale = 1,
})
"""


def run(home, *args):
    env = dict(os.environ, HOME=home)
    return subprocess.run([sys.executable, "-I", SCRIPT, *args], env=env, capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as home:
        cfg_dir = os.path.join(home, ".config", "hypr")
        os.makedirs(cfg_dir)
        cfg = os.path.join(cfg_dir, "monitors.lua")
        with open(cfg, "w") as f:
            f.write(SAMPLE)

        r = run(home, "DP-1=0,0,1.25", "DP-2=1536,0,1", "DP-3=2616,0,2")
        assert r.returncode == 0, r.stderr
        text = open(cfg).read()
        assert 'output = "DP-1", mode = "1920x1080@60", position = "0x0", scale = 1.25 })' in text, text
        assert 'position = "1536x0", scale = 1, transform = 1 })' in text, text
        assert '-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })' in text
        assert 'hl.monitor({ output = "DP-3", mode = "preferred", position = "2616x0", scale = 2 })' in text
        assert text.index('output = "DP-3"') > text.index('output = ""'), "new rule goes after the catch-all"
        assert "local omarchy_gdk_scale = 1" in text, "GDK scale follows the lowest scale"
        assert open(cfg + ".layout-bak").read() == SAMPLE

        r = run(home, "HDMI-A-1=0,1080,1")
        assert r.returncode == 3 and "multi-line" in r.stderr, (r.returncode, r.stderr)

        for bad in ['DP-1"=0,0,1', "DP-1=0,0", "DP-1=a,0,1", "DP-1=0,0,0", "DP-1=0,0,99"]:
            r = run(home, bad)
            assert r.returncode == 2, (bad, r.returncode, r.stderr)

        before = open(cfg).read()
        r = run(home, "DP-1=0,0,1.25", "DP-2=1536,0,1", "DP-3=2616,0,2")
        assert r.returncode == 0 and "already up to date" in r.stdout
        assert open(cfg).read() == before

    print("persist-layout tests passed")


if __name__ == "__main__":
    main()
