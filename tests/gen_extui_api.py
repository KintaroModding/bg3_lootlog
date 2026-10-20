"""Extracts the IMGUI, audio and resource definitions from the Script Extender IDE helpers into extui_api.json.

The test harness uses this file to reject IMGUI properties and methods, and Ext.Audio / Ext.Resource functions,
that do not exist in the real API.

Usage:
    python tests/gen_extui_api.py [path/to/ExtIdeHelpers.lua]

Without a path, the current file is downloaded from the Script Extender repository.
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

IDE_HELPERS_URL = "https://raw.githubusercontent.com/Norbyte/bg3se/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua"
ALIASES = ["GuiCond", "GuiColor", "GuiTableColumnFlags", "GuiStyleVar", "GuiMeasureScaling"]


def load_helpers() -> str:
    if len(sys.argv) > 1:
        return Path(sys.argv[1]).read_text(encoding="utf-8")
    with urllib.request.urlopen(IDE_HELPERS_URL) as response:
        return response.read().decode("utf-8")


def main() -> None:
    text = load_helpers()

    classes = {}
    current = None
    for line in text.splitlines():
        match = re.match(r"^--- ?@class (Extui\w+|Ext_ClientIMGUI|Ext_ClientAudio|Ext_Resource)(?::(\w+))?\s*$", line)
        if match:
            current = {"parent": match.group(2), "fields": {}}
            classes[match.group(1)] = current
            continue
        if current is None:
            continue
        field = re.match(r"^--- ?@field (\w+) (.+?)\s*$", line)
        if field:
            current["fields"][field.group(1)] = field.group(2)
        elif not line.startswith("---"):
            current = None

    aliases = {}
    for name in ALIASES:
        match = re.search(r"^--- ?@alias " + name + r" (.+)$", text, re.M)
        if match:
            aliases[name] = re.findall(r'"([^"]+)"', match.group(1))

    output = Path(__file__).with_name("extui_api.json")
    output.write_text(json.dumps({"classes": classes, "aliases": aliases}, indent=1, sort_keys=True), encoding="utf-8")
    print(f"Wrote {len(classes)} classes and {len(aliases)} aliases to {output}")


if __name__ == "__main__":
    main()
