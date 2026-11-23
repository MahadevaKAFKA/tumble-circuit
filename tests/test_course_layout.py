#!/usr/bin/env python3
"""Geometry and gameplay sanity checks for src/shared/CourseLayout.json.

These run without Roblox. They check the things that would otherwise only show
up in a playtest: spawns inside floors or rails, checkpoints you can't reach,
overlapping zones, a kill plane above the floor, an impossible jump, a sweeper
that clips the rails or lets the marble sneak past.

Usage: python3 tests/test_course_layout.py
"""

from __future__ import annotations

import json
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAYOUT = os.path.join(ROOT, "src", "shared", "CourseLayout.json")
CONFIG = os.path.join(ROOT, "src", "shared", "Config.luau")
GRAVITY = 196.2  # Roblox default Workspace.Gravity
EPS = 1e-6


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def mul(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def length(a):
    return math.sqrt(dot(a, a))


def config_number(section: str, key: str) -> float:
    with open(CONFIG, encoding="utf-8") as f:
        src = f.read()
    block = re.search(rf"Config\.{section}\s*=\s*\{{(.*?)\n\}}", src, flags=re.S)
    if not block:
        raise AssertionError(f"Config.{section} not found")
    m = re.search(rf"(?m)^\s*{key}\s*=\s*([-0-9.]+)", block.group(1))
    if not m:
        raise AssertionError(f"Config.{section}.{key} not found")
    return float(m.group(1))


class Slab:
    def __init__(self, data, thickness=None):
        self.name = data["Name"]
        self.a = tuple(data["From"])
        self.b = tuple(data["To"])
        self.width = data.get("Width", 1)
        self.thickness = thickness if thickness is not None else data["Thickness"]
        delta = sub(self.b, self.a)
        self.length = length(delta)
        flat = (delta[0], 0.0, delta[2])
        self.flat_len = length(flat)
        self.dir = mul(flat, 1 / self.flat_len)  # horizontal direction
        self.side = (-self.dir[2], 0.0, self.dir[0])

    def top_at(self, x: float, z: float, margin: float = 0.0):
        """Height of the top surface at (x, z), or None if outside the footprint."""
        rel = (x - self.a[0], 0.0, z - self.a[2])
        along = dot(rel, self.dir)
        across = dot(rel, self.side)
        if along < -EPS + margin or along > self.flat_len + EPS - margin:
            return None
        if abs(across) > self.width / 2 + EPS - margin:
            return None
        t = along / self.flat_len
        return self.a[1] + (self.b[1] - self.a[1]) * t

    def edge_distance(self, x: float, z: float) -> float:
        rel = (x - self.a[0], 0.0, z - self.a[2])
        across = dot(rel, self.side)
        return self.width / 2 - abs(across)


def surface_at(slabs, x, z, margin=0.0):
    heights = [s.top_at(x, z, margin) for s in slabs]
    heights = [h for h in heights if h is not None]
    return max(heights) if heights else None


def in_box(p, center, size):
    return all(abs(p[i] - center[i]) <= size[i] / 2 + EPS for i in range(3))


def boxes_overlap(c1, s1, c2, s2):
    return all(abs(c1[i] - c2[i]) < (s1[i] + s2[i]) / 2 - EPS for i in range(3))


def point_segment_distance_2d(p, a, b):
    ax, az = a[0], a[2]
    bx, bz = b[0], b[2]
    px, pz = p[0], p[2]
    dx, dz = bx - ax, bz - az
    seg = dx * dx + dz * dz
    t = 0.0 if seg == 0 else max(0.0, min(1.0, ((px - ax) * dx + (pz - az) * dz) / seg))
    cx, cz = ax + t * dx, az + t * dz
    return math.hypot(px - cx, pz - cz), t


def rail_height_at(rail, t):
    return rail["From"][1] + (rail["To"][1] - rail["From"][1]) * t


def main() -> int:
    with open(LAYOUT, encoding="utf-8") as f:
        layout = json.load(f)
    failures: list[str] = []
    passes: list[str] = []

    def check(condition, ok_message, fail_message):
        (passes if condition else failures).append(ok_message if condition else fail_message)

    diameter = config_number("Marble", "Diameter")
    radius = diameter / 2
    jump_velocity = config_number("Movement", "JumpVelocity")
    ground_accel = config_number("Movement", "GroundAcceleration")
    max_speed = config_number("Movement", "MaxSpeed")

    slabs = [Slab(s) for s in layout["Slabs"]]
    rails = layout["Rails"]
    rail_half = layout["RailWidth"] / 2
    checkpoints = layout["Checkpoints"]
    finish = layout["Finish"]

    # 1. Slab sanity
    for s in slabs:
        check(s.length > 0 and s.width > 0, f"slab {s.name} has size", f"slab {s.name} has zero size")
        check(s.length <= 2048 and s.width <= 2048, f"slab {s.name} within part size limit",
              f"slab {s.name} exceeds Roblox's 2048-stud part limit")

    lowest = min(min(s.a[1], s.b[1]) for s in slabs)
    check(layout["KillY"] <= lowest - 15, f"KillY {layout['KillY']} is well below the lowest floor ({lowest})",
          f"KillY {layout['KillY']} is too close to the lowest floor ({lowest})")

    # 2. Checkpoints: spawns on a floor, inside their zone, clear of rails and edges
    for index, cp in enumerate(checkpoints, start=1):
        spawn = tuple(cp["Spawn"])
        top = surface_at(slabs, spawn[0], spawn[2])
        check(top is not None and abs(top - spawn[1]) < 0.01,
              f"checkpoint {index} spawn sits on a floor",
              f"checkpoint {index} ({cp['Name']}) spawn {spawn} is not on a floor top (found {top})")
        ball = (spawn[0], spawn[1] + radius + 0.5, spawn[2])
        check(in_box(ball, cp["ZoneCenter"], cp["ZoneSize"]),
              f"checkpoint {index} spawn is inside its own zone",
              f"checkpoint {index} ({cp['Name']}) spawned marble {ball} is outside its zone")
        nearest_edge = max((s.edge_distance(spawn[0], spawn[2]) for s in slabs if s.top_at(spawn[0], spawn[2]) is not None), default=-1)
        check(nearest_edge >= radius + 1,
              f"checkpoint {index} spawn is clear of floor edges",
              f"checkpoint {index} ({cp['Name']}) spawn is only {nearest_edge:.2f} studs from a floor edge")
        for rail in rails:
            dist, t = point_segment_distance_2d(ball, rail["From"], rail["To"])
            low = rail_height_at(rail, t) - layout["RailThickness"]
            high = rail_height_at(rail, t)
            vertical_overlap = ball[1] + radius > low and ball[1] - radius < high
            if vertical_overlap and dist < radius + rail_half:
                failures.append(f"checkpoint {index} spawn overlaps rail {rail['Name']}")
        strip_top = surface_at(slabs, cp["StripCenter"][0], cp["StripCenter"][2])
        check(strip_top is not None and abs(cp["StripCenter"][1] - (strip_top + cp["StripSize"][1] / 2)) < 0.01,
              f"checkpoint {index} strip lies on the floor",
              f"checkpoint {index} strip is not resting on the floor (floor {strip_top}, strip y {cp['StripCenter'][1]})")
        yaw = math.radians(cp["YawDegrees"])
        look = (-math.sin(yaw), 0.0, -math.cos(yaw))
        ahead = add(spawn, mul(look, 13))
        check(surface_at(slabs, ahead[0], ahead[2]) is not None,
              f"checkpoint {index} faces along the course",
              f"checkpoint {index} ({cp['Name']}) faces off the course (yaw {cp['YawDegrees']})")

    # 3. Zones don't overlap (a marble can only ever be in one)
    zones = [(f"checkpoint {i}", tuple(cp["ZoneCenter"]), tuple(cp["ZoneSize"])) for i, cp in enumerate(checkpoints, start=1)]
    zones.append(("finish", tuple(finish["ZoneCenter"]), tuple(finish["ZoneSize"])))
    for i in range(len(zones)):
        for j in range(i + 1, len(zones)):
            a, b = zones[i], zones[j]
            check(not boxes_overlap(a[1], a[2], b[1], b[2]), f"{a[0]} and {b[0]} zones are separate",
                  f"{a[0]} zone overlaps {b[0]} zone")

    # 4. Each zone covers floor where the rolling marble actually passes
    for name, center, size in zones:
        top = surface_at(slabs, center[0], center[2])
        if top is None:
            failures.append(f"{name} zone centre is not above a floor")
            continue
        ball_y = top + radius
        check(center[1] - size[1] / 2 < ball_y < center[1] + size[1] / 2,
              f"{name} zone height catches a rolling marble",
              f"{name} zone (y {center[1]}±{size[1] / 2}) misses a marble rolling at y {ball_y}")

    # 5. Bumpers stand on the floor and leave room to pass
    for bumper in layout["Bumpers"]:
        base = bumper["Base"]
        top = surface_at(slabs, base[0], base[2])
        check(top is not None and abs(top - base[1]) < 0.01, f"bumper {bumper['Name']} stands on the floor",
              f"bumper {bumper['Name']} base {base} is not on a floor")
        host = next((s for s in slabs if s.top_at(base[0], base[2]) is not None), None)
        if host:
            across = dot((base[0] - host.a[0], 0, base[2] - host.a[2]), host.side)
            gap_one = host.width / 2 - across - bumper["Diameter"] / 2
            gap_two = host.width / 2 + across - bumper["Diameter"] / 2
            check(max(gap_one, gap_two) >= diameter + 1, f"bumper {bumper['Name']} leaves a passage",
                  f"bumper {bumper['Name']} blocks the lane (gaps {gap_one:.1f} / {gap_two:.1f})")

    # 6. Sweeper clears the rails but the marble can't sneak around the ends
    for sweeper in layout["Sweepers"]:
        base = sweeper["Base"]
        host = next((s for s in slabs if s.top_at(base[0], base[2]) is not None), None)
        if not host:
            failures.append(f"sweeper {sweeper['Name']} is not on a floor")
            continue
        half_arm = sweeper["ArmLength"] / 2
        clearance = host.width / 2 - half_arm
        check(clearance >= 0.5, f"sweeper {sweeper['Name']} arm clears the rails ({clearance:.1f} studs)",
              f"sweeper {sweeper['Name']} arm hits the rails (clearance {clearance:.2f})")
        check(clearance < diameter, f"sweeper {sweeper['Name']} can't be bypassed at the ends",
              f"sweeper {sweeper['Name']} leaves {clearance:.1f} studs: the marble can roll past without timing it")
        arm_bottom = base[1] + sweeper["FloorGap"]
        arm_top = arm_bottom + sweeper["ArmHeight"]
        ball_center = base[1] + radius
        check(arm_bottom < ball_center < arm_top + radius and arm_bottom < diameter + base[1],
              f"sweeper {sweeper['Name']} arm is at marble height",
              f"sweeper {sweeper['Name']} arm (y {arm_bottom}-{arm_top}) passes over/under the marble")
        for index, cp in enumerate(checkpoints, start=1):
            d = math.hypot(cp["Spawn"][0] - base[0], cp["Spawn"][2] - base[2])
            check(d > half_arm + radius + 1, f"checkpoint {index} spawn is outside the sweeper circle",
                  f"checkpoint {index} spawn is inside the sweeper's reach")

    # 7. The finish gap can be cleared from the last checkpoint
    lane = next(s for s in slabs if s.name == "Lane3")
    pad = next(s for s in slabs if s.name == "FinishPad")
    gap = dot(sub(pad.a, lane.b), lane.dir)
    drop = lane.b[1] - pad.a[1]
    last_cp = checkpoints[-1]
    runup = dot(sub(lane.b, tuple(last_cp["Spawn"])), lane.dir) - radius
    speed = min(max_speed, math.sqrt(2 * ground_accel * max(runup, 0)))
    # jump at the edge: y(t) = v t - g t^2 / 2 ; land when y = -drop
    t_land = (jump_velocity + math.sqrt(jump_velocity ** 2 + 2 * GRAVITY * drop)) / GRAVITY
    jump_range = speed * t_land
    check(gap > 0 and jump_range > gap + diameter,
          f"finish gap {gap:.0f} studs is clearable with a jump (range {jump_range:.0f} at {speed:.0f} studs/s)",
          f"finish gap {gap:.1f} studs cannot be cleared: range {jump_range:.1f} at {speed:.1f} studs/s")
    t_cross = gap / speed if speed > 0 else math.inf
    fall = 0.5 * GRAVITY * t_cross ** 2
    passes.append(f"rolling off at full speed without jumping drops {fall:.1f} studs over the gap (pad is {drop:.0f} lower)")

    # 8. Finish zone sits on the finish pad
    fc = finish["ZoneCenter"]
    check(pad.top_at(fc[0], fc[2]) is not None, "finish zone is on the finish pad", "finish zone is not over the finish pad")

    # 9. The path is continuous (consecutive slabs touch, except the deliberate gap)
    for first, second in zip(slabs, slabs[1:]):
        if (first.name, second.name) == ("Lane3", "FinishPad"):
            continue
        probe = add(second.a, mul(second.dir, 0.5))
        before = add(second.a, mul(second.dir, -0.5))
        h_first = first.top_at(before[0], before[2]) if first.top_at(before[0], before[2]) is not None else surface_at(slabs, before[0], before[2])
        check(second.top_at(probe[0], probe[2]) is not None and h_first is not None and abs(h_first - second.a[1]) < 0.75,
              f"{first.name} connects to {second.name}", f"{first.name} does not connect smoothly to {second.name}")

    for message in passes:
        print(f"  ok   {message}")
    for message in failures:
        print(f"  FAIL {message}")
    print(f"\ncourse layout: {len(passes)} checks passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
