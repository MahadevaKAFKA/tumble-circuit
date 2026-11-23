#!/usr/bin/env python3
"""
Minimal place builder for THIS project: reads default.project.json and writes an .rbxlx
(Roblox XML place, format version 4) that Roblox Studio can open directly.

It implements only the Rojo features this project uses:
  * nodes with $className / $path / $properties (bool, number, string)
  * $path to a file:      *.server.lua -> Script, *.client.lua -> LocalScript, *.lua -> ModuleScript
  * $path to a directory: Folder; files become scripts named by their stem; subfolders recurse
It is a convenience for owners without Rojo. Rojo (`rojo build`) remains the source-of-truth build.

Usage: python3 tools/build_rbxlx.py [projectDir] [output.rbxlx]
"""
import json
import sys
import uuid
from pathlib import Path
from xml.sax.saxutils import escape

SCRIPT_SUFFIXES = [(".server.lua", "Script"), (".client.lua", "LocalScript"), (".lua", "ModuleScript")]


def script_class(path: Path):
    for suffix, cls in SCRIPT_SUFFIXES:
        if path.name.endswith(suffix):
            return cls, path.name[: -len(suffix)]
    return None, None


def new_ref():
    return "RBX" + uuid.uuid4().hex.upper()


def cdata(text: str) -> str:
    # "]]>" cannot appear inside CDATA; split it if it ever does.
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


class Item:
    def __init__(self, cls, name):
        self.cls = cls
        self.name = name
        self.props = []  # (xmlType, name, rawXmlValue)
        self.children = []

    def to_xml(self, indent=1):
        pad = "\t" * indent
        out = [f'{pad}<Item class="{self.cls}" referent="{new_ref()}">', f"{pad}\t<Properties>"]
        out.append(f'{pad}\t\t<string name="Name">{escape(self.name)}</string>')
        for xml_type, name, value in self.props:
            out.append(f'{pad}\t\t<{xml_type} name="{name}">{value}</{xml_type}>')
        out.append(f"{pad}\t</Properties>")
        for child in self.children:
            out.append(child.to_xml(indent + 1))
        out.append(f"{pad}</Item>")
        return "\n".join(out)


def item_from_file(path: Path, name=None):
    cls, stem = script_class(path)
    if cls is None:
        raise SystemExit(f"unsupported file type: {path}")
    item = Item(cls, name or stem)
    item.props.append(("ProtectedString", "Source", cdata(path.read_text(encoding="utf-8"))))
    return item


def item_from_dir(path: Path, name):
    item = Item("Folder", name)
    for entry in sorted(path.iterdir()):
        if entry.is_dir():
            item.children.append(item_from_dir(entry, entry.name))
        elif script_class(entry)[0]:
            item.children.append(item_from_file(entry))
    return item


def prop_xml(value):
    if isinstance(value, bool):
        return "bool", "true" if value else "false"
    if isinstance(value, int):
        return "int", str(value)
    if isinstance(value, float):
        return "float", repr(value)
    if isinstance(value, str):
        return "string", escape(value)
    raise SystemExit(f"unsupported $properties value: {value!r}")


def build_node(name, node, root: Path):
    if "$path" in node:
        target = root / node["$path"]
        if target.is_file():
            item = item_from_file(target, name)
        elif target.is_dir():
            item = item_from_dir(target, name)
        else:
            raise SystemExit(f"$path not found: {target}")
    else:
        item = Item(node.get("$className", "Folder"), name)
    for key, value in node.get("$properties", {}).items():
        xml_type, raw = prop_xml(value)
        item.props.append((xml_type, key, raw))
    for key, child in node.items():
        if not key.startswith("$"):
            item.children.append(build_node(key, child, root))
    return item


def main():
    project_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    output = Path(sys.argv[2] if len(sys.argv) > 2 else project_dir / "TumbleCircuit.rbxlx")
    project = json.loads((project_dir / "default.project.json").read_text(encoding="utf-8"))
    tree = project["tree"]
    services = [build_node(key, child, project_dir) for key, child in tree.items() if not key.startswith("$")]
    body = "\n".join(s.to_xml(1) for s in services)
    xml = (
        '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">\n'
        "\t<External>null</External>\n\t<External>nil</External>\n" + body + "\n</roblox>\n"
    )
    output.write_text(xml, encoding="utf-8")
    print(f"wrote {output} ({len(xml)} bytes)")


if __name__ == "__main__":
    main()
