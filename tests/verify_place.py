#!/usr/bin/env python3
"""Verify a built .rbxlx place against tests/place_expectations.json.

Checks that every required instance exists with the right class, required
properties have the right values, every script has source, and every
WaitForChild/FindFirstChild("Name") in a script points at something that is in
the place or is created at runtime (listed in runtimeNames).

Usage: python3 tests/verify_place.py build/TumbleCircuit.rbxlx
"""

from __future__ import annotations

import json
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT_CLASSES = {"Script", "LocalScript", "ModuleScript"}
LOOKUP_RE = re.compile(r"(?:WaitForChild|FindFirstChild)\(\s*\"([^\"]+)\"")


def load_tree(path: str):
    root = ET.parse(path).getroot()
    if root.tag != "roblox":
        raise SystemExit(f"{path}: not a Roblox XML place (root <{root.tag}>)")
    nodes = {}

    def walk(item, parent_path):
        props = item.find("Properties")
        name = None
        values = {}
        source = None
        if props is not None:
            for prop in props:
                pname = prop.get("name")
                if pname == "Name":
                    name = prop.text or ""
                elif pname == "Source":
                    source = prop.text or ""
                else:
                    values[pname] = (prop.tag, prop.text)
        if name is None:
            raise SystemExit(f"instance of class {item.get('class')} under {parent_path or 'game'} has no Name")
        path = f"{parent_path}/{name}" if parent_path else name
        if path in nodes:
            raise SystemExit(f"duplicate instance path {path}")
        nodes[path] = {"class": item.get("class"), "props": values, "source": source}
        for child in item.findall("Item"):
            walk(child, path)

    for item in root.findall("Item"):
        walk(item, "")
    return nodes


def parse_value(tag: str, text: str):
    if tag == "bool":
        return text == "true"
    if tag in ("int", "int64"):
        return int(text)
    if tag in ("float", "double"):
        return float(text)
    return text


def main(argv: list[str]) -> int:
    place = argv[1] if len(argv) > 1 else "build/TumbleCircuit.rbxlx"
    with open(os.path.join(HERE, "place_expectations.json"), encoding="utf-8") as f:
        expect = json.load(f)
    nodes = load_tree(place)
    failures = []

    for want in expect["instances"]:
        node = nodes.get(want["path"])
        if node is None:
            failures.append(f"missing {want['path']} ({want['class']})")
        elif node["class"] != want["class"]:
            failures.append(f"{want['path']} is {node['class']}, expected {want['class']}")

    for want in expect["properties"]:
        node = nodes.get(want["path"])
        if node is None:
            failures.append(f"missing {want['path']} for property {want['name']}")
            continue
        if want["name"] not in node["props"]:
            failures.append(f"{want['path']}.{want['name']} is not set")
            continue
        tag, text = node["props"][want["name"]]
        value = parse_value(tag, text)
        if value != want["value"]:
            failures.append(f"{want['path']}.{want['name']} = {value!r}, expected {want['value']!r}")

    names = {path.rsplit("/", 1)[-1] for path in nodes}
    allowed = names | set(expect["runtimeNames"])
    scripts = 0
    for path, node in nodes.items():
        if node["class"] not in SCRIPT_CLASSES:
            continue
        scripts += 1
        source = node["source"]
        if not source or not source.strip():
            failures.append(f"{path} has no source")
            continue
        for ref in sorted(set(LOOKUP_RE.findall(source))):
            if ref not in allowed:
                failures.append(f"{path} looks up '{ref}', which is not in the place or the runtime list")

    if failures:
        print(f"FAILED: {place}")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"OK: {place} — {len(nodes)} instances, {scripts} scripts, all references resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
