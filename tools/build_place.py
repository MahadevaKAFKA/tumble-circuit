#!/usr/bin/env python3
"""Offline place builder (Rojo-compatible subset).

Builds an .rbxlx (Roblox XML place) from default.project.json using the same
file rules as Rojo 7:
  directory                -> Folder (or the init script's class)
  init.server.luau         -> the directory becomes a Script
  init.client.luau         -> the directory becomes a LocalScript
  init.luau                -> the directory becomes a ModuleScript
  Name.server.luau         -> Script
  Name.client.luau         -> LocalScript
  Name.luau / Name.lua     -> ModuleScript
  Name.json                -> ModuleScript returning the JSON as a Luau table

CI uses real Rojo (see .github/workflows/build.yml); this script exists so a
place file can be produced and inspected without installing anything.

Usage: python3 tools/build_place.py [--project default.project.json] [--output build/TumbleCircuit.rbxlx]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sys
from xml.sax.saxutils import escape

SCRIPT_SUFFIXES = [
    (".server.luau", "Script"),
    (".client.luau", "LocalScript"),
    (".server.lua", "Script"),
    (".client.lua", "LocalScript"),
    (".luau", "ModuleScript"),
    (".lua", "ModuleScript"),
]
INIT_FILES = [
    ("init.server.luau", "Script"),
    ("init.client.luau", "LocalScript"),
    ("init.luau", "ModuleScript"),
    ("init.server.lua", "Script"),
    ("init.client.lua", "LocalScript"),
    ("init.lua", "ModuleScript"),
]
IGNORED_JSON = (".project.json", ".meta.json", ".model.json")

# Property types for $properties used in the project file.
PROPERTY_TYPES = {
    ("Players", "CharacterAutoLoads"): "bool",
    ("Workspace", "StreamingEnabled"): "bool",
    ("SpawnLocation", "Anchored"): "bool",
    ("SpawnLocation", "Neutral"): "bool",
    ("SpawnLocation", "CanCollide"): "bool",
    ("SpawnLocation", "Duration"): "int",
    ("SpawnLocation", "Transparency"): "float",
}


class Instance:
    def __init__(self, class_name: str, name: str):
        self.class_name = class_name
        self.name = name
        self.properties: list[tuple[str, str, str]] = []  # (xml type, name, text)
        self.source: str | None = None
        self.children: list[Instance] = []

    def path(self, parent_path: str) -> str:
        return f"{parent_path}/{self.name}" if parent_path else self.name


def luau_literal(value, indent: int = 0) -> str:
    pad = "\t" * (indent + 1)
    end_pad = "\t" * indent
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("JSON number is not finite")
        return repr(value) if isinstance(value, float) else str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        if not value:
            return "{}"
        if all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in value):
            return "{ " + ", ".join(luau_literal(v) for v in value) + " }"
        items = [f"{pad}{luau_literal(v, indent + 1)}," for v in value]
        return "{\n" + "\n".join(items) + f"\n{end_pad}}}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = [f"{pad}[{json.dumps(str(k))}] = {luau_literal(v, indent + 1)}," for k, v in value.items()]
        return "{\n" + "\n".join(items) + f"\n{end_pad}}}"
    raise TypeError(f"unsupported JSON value: {value!r}")


def json_module_source(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return "return " + luau_literal(data) + "\n"


def read_text(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def instance_from_file(path: str) -> Instance | None:
    base = os.path.basename(path)
    for suffix, class_name in SCRIPT_SUFFIXES:
        if base.endswith(suffix):
            inst = Instance(class_name, base[: -len(suffix)])
            inst.source = read_text(path)
            return inst
    if base.endswith(".json") and not base.endswith(IGNORED_JSON):
        inst = Instance("ModuleScript", base[: -len(".json")])
        inst.source = json_module_source(path)
        return inst
    if base.endswith(".model.json"):
        raise SystemExit(f"{path}: .model.json files are not supported by the offline builder")
    return None  # other files are ignored, as Rojo does for unknown extensions


def instance_from_dir(path: str, name: str) -> Instance:
    entries = sorted(os.listdir(path))
    class_name = "Folder"
    source = None
    init_name = None
    for init_file, init_class in INIT_FILES:
        if init_file in entries:
            class_name = init_class
            source = read_text(os.path.join(path, init_file))
            init_name = init_file
            break
    inst = Instance(class_name, name)
    inst.source = source
    for entry in entries:
        if entry == init_name or entry.startswith("."):
            continue
        full = os.path.join(path, entry)
        if os.path.isdir(full):
            inst.children.append(instance_from_dir(full, entry))
        else:
            child = instance_from_file(full)
            if child:
                inst.children.append(child)
    return inst


def format_property(class_name: str, prop: str, value) -> tuple[str, str, str]:
    kind = PROPERTY_TYPES.get((class_name, prop))
    if kind is None:
        raise SystemExit(f"offline builder does not know the type of {class_name}.{prop}; add it to PROPERTY_TYPES")
    if kind == "bool":
        if not isinstance(value, bool):
            raise SystemExit(f"{class_name}.{prop} must be true/false")
        return ("bool", prop, "true" if value else "false")
    if kind == "int":
        if not isinstance(value, int) or isinstance(value, bool):
            raise SystemExit(f"{class_name}.{prop} must be an integer")
        return ("int", prop, str(value))
    if kind == "float":
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            raise SystemExit(f"{class_name}.{prop} must be a number")
        return ("float", prop, repr(float(value)))
    raise SystemExit(f"unsupported property type {kind}")


def build_node(name: str, node: dict, root_dir: str) -> Instance:
    if "$path" in node:
        target = os.path.join(root_dir, node["$path"])
        if os.path.isdir(target):
            inst = instance_from_dir(target, name)
        elif os.path.isfile(target):
            inst = instance_from_file(target)
            if inst is None:
                raise SystemExit(f"$path {node['$path']} is not a supported file type")
            inst.name = name
        else:
            raise SystemExit(f"$path {node['$path']} does not exist")
        if "$className" in node and node["$className"] != inst.class_name:
            raise SystemExit(f"{name}: $className conflicts with the class from $path")
    elif "$className" in node:
        inst = Instance(node["$className"], name)
    else:
        raise SystemExit(f"{name}: node needs $className or $path")

    for prop, value in node.get("$properties", {}).items():
        inst.properties.append(format_property(inst.class_name, prop, value))

    for key, child in node.items():
        if key.startswith("$"):
            continue
        inst.children.append(build_node(key, child, root_dir))
    return inst


def referent(path: str) -> str:
    return "RBX" + hashlib.md5(path.encode("utf-8")).hexdigest().upper()


def cdata(text: str) -> str:
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def emit(inst: Instance, parent_path: str, depth: int, out: list[str]):
    path = inst.path(parent_path)
    pad = "\t" * depth
    out.append(f'{pad}<Item class="{escape(inst.class_name)}" referent="{referent(path)}">')
    out.append(f"{pad}\t<Properties>")
    out.append(f'{pad}\t\t<string name="Name">{escape(inst.name)}</string>')
    for xml_type, prop, text in inst.properties:
        out.append(f'{pad}\t\t<{xml_type} name="{escape(prop)}">{escape(text)}</{xml_type}>')
    if inst.source is not None:
        out.append(f'{pad}\t\t<ProtectedString name="Source">{cdata(inst.source)}</ProtectedString>')
    out.append(f"{pad}\t</Properties>")
    for child in inst.children:
        emit(child, path, depth + 1, out)
    out.append(f"{pad}</Item>")


def build(project_path: str) -> tuple[Instance, str]:
    with open(project_path, encoding="utf-8") as f:
        project = json.load(f)
    root_dir = os.path.dirname(os.path.abspath(project_path))
    tree = project["tree"]
    if tree.get("$className") != "DataModel":
        raise SystemExit("project tree root must be a DataModel")
    root = Instance("DataModel", "game")
    for key, child in tree.items():
        if key.startswith("$"):
            continue
        root.children.append(build_node(key, child, root_dir))
    out = ['<roblox version="4">']
    for service in root.children:
        emit(service, "", 1, out)
    out.append("</roblox>")
    return root, "\n".join(out) + "\n"


def describe(inst: Instance, parent_path: str = "") -> list[str]:
    lines = []
    for child in inst.children:
        path = child.path(parent_path)
        extra = f" ({len(child.source.splitlines())} lines)" if child.source is not None else ""
        lines.append(f"{path} [{child.class_name}]{extra}")
        lines.extend(describe(child, path))
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", default="default.project.json")
    parser.add_argument("--output", default="build/TumbleCircuit.rbxlx")
    parser.add_argument("--tree", action="store_true", help="print the instance tree")
    args = parser.parse_args()

    root, xml = build(args.project)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w", encoding="utf-8", newline="\n") as f:
        f.write(xml)
    if args.tree:
        print("\n".join(describe(root)))
    count = len(describe(root))
    print(f"wrote {args.output}: {count} instances, {len(xml.encode('utf-8'))} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
