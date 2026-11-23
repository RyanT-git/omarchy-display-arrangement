#!/usr/bin/env python3
"""Persist a monitor arrangement to ~/.config/hypr/monitors.lua.

Usage: persist-layout.py NAME=X,Y,SCALE [NAME=X,Y,SCALE ...]

For each output, the first single-line `hl.monitor({ output = "NAME", ... })`
rule has its position and scale rewritten in place; mode, transform and
anything else on the line are kept. An output with no rule gets one added
after Omarchy's catch-all `output = ""` rule. A rule spread over several lines
is left alone and reported, rather than risk writing broken Lua.

GDK_SCALE follows the lowest monitor scale, rounded, the same way
omarchy-hyprland-monitor-scaling sets it.

The file is replaced atomically (Hyprland reloads on every write), and the
previous version is kept as monitors.lua.layout-bak.
"""

import os
import re
import sys
import tempfile

NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
CONFIG = os.path.expanduser("~/.config/hypr/monitors.lua")


def parse_args(argv):
    layout = {}
    for arg in argv:
        name, sep, rest = arg.partition("=")
        if not sep or not NAME_RE.match(name):
            raise ValueError(f"bad output spec: {arg!r}")
        parts = rest.split(",")
        if len(parts) != 3:
            raise ValueError(f"bad output spec: {arg!r}")
        x, y = int(parts[0]), int(parts[1])
        scale = float(parts[2])
        if not (0 < scale <= 10) or abs(x) > 100000 or abs(y) > 100000:
            raise ValueError(f"value out of range: {arg!r}")
        layout[name] = (x, y, scale)
    if not layout:
        raise ValueError("no outputs given")
    return layout


def fmt_scale(scale):
    return f"{scale:.4f}".rstrip("0").rstrip(".")


def is_single_line(line):
    return re.search(r"\}\)\s*(--.*)?$", line) is not None


def rule_output(lines, i):
    """Output named by the hl.monitor rule starting on lines[i], or None.

    A rule spread over several lines is read up to its closing `})`, so its
    output is still recognised even when `output =` sits on a later line.
    """
    code = lines[i].split("--", 1)[0]
    if not code.lstrip().startswith("hl.monitor("):
        return None
    if not is_single_line(lines[i]):
        for j in range(i + 1, min(len(lines), i + 40)):
            code += " " + lines[j].split("--", 1)[0]
            if is_single_line(lines[j]):
                break
    m = re.search(r'output\s*=\s*"([^"]*)"', code)
    return m.group(1) if m else None


def set_field(line, field, value):
    """Replace `field = <value>` on a one-line rule, or add it before `})`."""
    pattern = re.compile(r"(\b" + field + r'\s*=\s*)("[^"]*"|[A-Za-z0-9_.]+)')
    if pattern.search(line):
        return pattern.sub(lambda m: m.group(1) + value, line, count=1)
    return re.sub(r"\s*\}\)", f", {field} = {value} }})", line, count=1)


def main(argv):
    try:
        layout = parse_args(argv)
    except ValueError as e:
        print(f"persist-layout: {e}", file=sys.stderr)
        return 2

    if not os.path.isfile(CONFIG):
        print(f"persist-layout: {CONFIG} not found", file=sys.stderr)
        return 1

    target = os.path.realpath(CONFIG)
    with open(target, encoding="utf-8") as f:
        lines = f.read().split("\n")

    updated = set()
    skipped = []
    catch_all = None
    for i, line in enumerate(lines):
        output = rule_output(lines, i)
        if output is None:
            continue
        if output == "" and catch_all is None and is_single_line(line):
            catch_all = i
            continue
        if output not in layout or output in updated:
            continue
        if not is_single_line(line):
            skipped.append(output)
            updated.add(output)
            continue
        x, y, scale = layout[output]
        line = set_field(line, "position", f'"{x}x{y}"')
        line = set_field(line, "scale", fmt_scale(scale))
        lines[i] = line
        updated.add(output)

    missing = [n for n in layout if n not in updated]
    if missing:
        insert_at = catch_all + 1 if catch_all is not None else len(lines)
        new_rules = []
        for name in missing:
            x, y, scale = layout[name]
            new_rules.append(
                f'hl.monitor({{ output = "{name}", mode = "preferred", '
                f'position = "{x}x{y}", scale = {fmt_scale(scale)} }})'
            )
        lines[insert_at:insert_at] = new_rules

    # GDK_SCALE is session-wide; follow the lowest scale like Omarchy does.
    gdk = max(1, int(min(s for _, _, s in layout.values()) + 0.5))
    for i, line in enumerate(lines):
        if re.match(r"^local omarchy_gdk_scale = ", line):
            lines[i] = f"local omarchy_gdk_scale = {gdk}"
        elif re.match(r'^hl\.env\("GDK_SCALE", "[^"]*"\)', line):
            lines[i] = f'hl.env("GDK_SCALE", "{gdk}")'

    content = "\n".join(lines)
    with open(target, encoding="utf-8") as f:
        original = f.read()
    if content == original:
        return report(layout, skipped, "already up to date")

    directory = os.path.dirname(target)
    mode = os.stat(target).st_mode & 0o7777

    with open(target + ".layout-bak", "w", encoding="utf-8") as f:
        f.write(original)

    fd, tmp = tempfile.mkstemp(prefix=".monitors.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

    return report(layout, skipped, "saved " + ", ".join(sorted(layout)))


def report(layout, skipped, done):
    if skipped:
        print("persist-layout: left multi-line rules alone for: " + ", ".join(skipped), file=sys.stderr)
        return 3
    print("persist-layout: " + done)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
