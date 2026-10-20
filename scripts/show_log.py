r"""Prints the Loot Log entries, newest first, and the newest lines of the mod's log files.

Sources of the log:
  * Live file (default): the mod writes Script Extender/bg3_lootlog/log.json about once per second after a change.
  * Savegame: the Script Extender stores mod variables in the save's Globals.lsf, region "ScriptExtenderSave",
    encoded with its binary JSON format (BG3Extender/Lua/Libs/JsonBinary.inl). This needs Divine.exe of LSLib.

After the log, the script prints the newest lines of server.log and client.log (Shared/FileWriter.lua). Each load
writes a line like "Loot Log 1.0.0.1 loaded.", so the logs show which version runs.

The files are read from $BG3_DATA_DIR (the BG3 user-data folder, for example a share of the game PC), else from
%LOCALAPPDATA%/Larian Studios/Baldur's Gate 3. Divine.exe is taken from _tools/lslib in a parent folder of the
project, as build.ps1 does; $BG3_TOOLS overrides it.

Usage:
    python scripts/show_log.py                  # live log.json (newest save when there is no live file), then the logs
    python scripts/show_log.py --save           # newest save
    python scripts/show_log.py path/to/x.lsv    # a specific save (or a log.json file)
    python scripts/show_log.py -n 100           # 100 lines of server.log and client.log (default 40)
    python scripts/show_log.py --json           # raw log as JSON, without the log files
    python scripts/show_log.py --self-test      # check the binary JSON decoder
"""

import argparse
import base64
import datetime
import json
import os
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

MOD_FOLDER = "bg3_lootlog"
VARIABLE_NAME = "Log"
ROOT = Path(__file__).resolve().parent.parent
META = ROOT / "src" / "Mods" / MOD_FOLDER / "meta.lsx"
DATA_DIR = Path(os.environ.get("BG3_DATA_DIR")
                or Path(os.environ.get("LOCALAPPDATA", "")) / "Larian Studios" / "Baldur's Gate 3")
LIVE_DIR = DATA_DIR / "Script Extender" / MOD_FOLDER
RARITY_LABELS = ["Common", "Uncommon", "Rare", "Very Rare", "Legendary", "Unique"]

# TypeTag values of the Script Extender binary JSON format.
NULL, BOOL, INT0, INT8, INT16, INT32, INT64, FLOAT, STRING, REF8, REF16, REF32, OBJECT, ARRAY, END = range(15)


class BinaryJsonReader:
    """Python port of lua::json::BinaryReader."""

    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0
        self.depth = 0

    def parse(self):
        value = self._next()
        if self.pos != len(self.data):
            raise ValueError(f"trailing data at byte {self.pos}")
        return value

    def _tag(self):
        if self.pos >= len(self.data):
            raise ValueError("unexpected end of data")
        byte = self.data[self.pos]
        return byte & 0x0F, byte >> 4

    def _read_string(self):
        tag = self.data[self.pos]
        length = (tag >> 4) & 3
        extra = tag >> 6
        self.pos += 1
        shift = 2
        for _ in range(extra):
            length |= self.data[self.pos] << shift
            shift += 8
            self.pos += 1
        text = self.data[self.pos:self.pos + length]
        if len(text) != length:
            raise ValueError("string runs past the end of data")
        self.pos += length
        return text.decode("utf-8")

    def _read_string_at(self, delta):
        if delta > self.pos:
            raise ValueError("bad string reference")
        old = self.pos
        self.pos -= delta
        try:
            return self._read_string()
        finally:
            self.pos = old

    def _next(self):
        tag, data = self._tag()
        d = self.data
        p = self.pos
        if tag == NULL:
            self.pos += 1
            return None
        if tag == BOOL:
            self.pos += 1
            return bool(data)
        if tag == INT0:
            self.pos += 1
            return data - 4
        if tag == INT8:
            self.pos += 2
            return ((data << 8) | d[p + 1]) - 0x400
        if tag == INT16:
            self.pos += 3
            return ((data << 16) | struct.unpack_from("<H", d, p + 1)[0]) - 0x40000
        if tag == INT32:
            self.pos += 5
            return ((data << 32) | struct.unpack_from("<I", d, p + 1)[0]) - 0x400000000
        if tag == INT64:
            self.pos += 9
            return struct.unpack_from("<q", d, p + 1)[0]
        if tag == FLOAT:
            self.pos += 5
            return struct.unpack_from("<f", d, p + 1)[0]
        if tag == STRING:
            return self._read_string()
        if tag == REF8:
            offset = (data << 8) | d[p + 1]
            text = self._read_string_at(offset)
            self.pos += 2
            return text
        if tag == REF16:
            offset = (data << 16) | struct.unpack_from("<H", d, p + 1)[0]
            text = self._read_string_at(offset)
            self.pos += 3
            return text
        if tag == REF32:
            offset = struct.unpack_from("<I", d, p + 1)[0]
            text = self._read_string_at(offset)
            self.pos += 5
            return text
        if tag in (OBJECT, ARRAY):
            self.pos += 1
            self.depth += 1
            if self.depth > 64:
                raise ValueError("nesting too deep")
            result = {} if tag == OBJECT else []
            while True:
                next_tag, _ = self._tag()
                if next_tag == END:
                    self.pos += 1
                    self.depth -= 1
                    return result
                if tag == OBJECT:
                    key = self._next()
                    result[key] = self._next()
                else:
                    result.append(self._next())
        raise ValueError(f"unknown tag {tag} at byte {p}")


class BinaryJsonWriter:
    """Python port of lua::json::BinaryWriter, used by the self-test."""

    def __init__(self):
        self.buf = bytearray()
        self.strings = {}

    def write(self, value):
        if value is None:
            self.buf.append(NULL)
        elif isinstance(value, bool):
            self.buf.append(BOOL | (int(value) << 4))
        elif isinstance(value, int):
            self._int(value)
        elif isinstance(value, float):
            self.buf.append(FLOAT | (4 << 4))
            self.buf += struct.pack("<f", value)
        elif isinstance(value, str):
            self._string(value)
        elif isinstance(value, dict):
            self.buf.append(OBJECT)
            for key, item in value.items():
                self._string(key)
                self.write(item)
            self.buf.append(END)
        elif isinstance(value, list):
            self.buf.append(ARRAY)
            for item in value:
                self.write(item)
            self.buf.append(END)
        else:
            raise TypeError(type(value))
        return bytes(self.buf)

    def _int(self, v):
        if -4 <= v <= 3:
            self.buf.append(INT0 | ((v + 4) << 4))
        elif -0x400 <= v <= 0x3FF:
            vl = v + 0x400
            self.buf += bytes([INT8 | (((vl >> 8) & 0x0F) << 4), vl & 0xFF])
        elif -0x40000 <= v <= 0x3FFFF:
            vl = v + 0x40000
            self.buf.append(INT16 | (((vl >> 16) & 0x0F) << 4))
            self.buf += struct.pack("<H", vl & 0xFFFF)
        elif -0x400000000 <= v <= 0x3FFFFFFFF:
            vl = v + 0x400000000
            self.buf.append(INT32 | (((vl >> 32) & 0x0F) << 4))
            self.buf += struct.pack("<I", vl & 0xFFFFFFFF)
        else:
            self.buf.append(INT64)
            self.buf += struct.pack("<q", v)

    def _string(self, text):
        raw = text.encode("utf-8")
        if raw in self.strings:
            offset = len(self.buf) - self.strings[raw]
            if offset < 0xFFF:
                self.buf += bytes([REF8 | (((offset >> 8) & 0x0F) << 4), offset & 0xFF])
            elif offset < 0xFFFFF:
                self.buf.append(REF16 | (((offset >> 16) & 0x0F) << 4))
                self.buf += struct.pack("<H", offset & 0xFFFF)
            else:
                self.buf.append(REF32)
                self.buf += struct.pack("<I", offset)
            return
        self.strings[raw] = len(self.buf)
        length = len(raw)
        low, rest = length & 3, length >> 2
        extra = 3 if rest >= 0x10000 else 2 if rest >= 0x100 else 1 if rest > 0 else 0
        self.buf.append(STRING | (low << 4) | (extra << 6))
        while rest:
            self.buf.append(rest & 0xFF)
            rest >>= 8
        self.buf += raw


def self_test():
    sample = {
        "NextId": 1234,
        "Entries": [
            {"Id": i, "Name": f"Item {i % 7}", "Category": "Weapon", "Rarity": i % 6, "Value": i * 37,
             "Epoch": 1791763200 + i, "Owner": "Karlach", "From": "Goblin Boss" if i % 2 else None, "Ratio": 0.5}
            for i in range(600)
        ],
        "Big": 2 ** 40, "Negative": -5000, "Long": "x" * 70000, "Empty": [],
    }
    sample["Entries"] = [{k: v for k, v in e.items() if v is not None} for e in sample["Entries"]]
    decoded = BinaryJsonReader(BinaryJsonWriter().write(sample)).parse()
    assert decoded == sample, "round trip mismatch"
    assert BinaryJsonReader(base64.b64decode("DQ4=")).parse() == [], "empty table from a real save"
    print("self-test passed")


def mod_uuid() -> str:
    """Returns the UUID from meta.lsx; the Script Extender stores the mod variables of a save under it."""
    node = ET.parse(META).getroot().find(".//node[@id='ModuleInfo']/attribute[@id='UUID']")
    if node is None:
        raise SystemExit(f"No UUID in {META}")
    return node.get("value")


def find_divine():
    """Returns Divine.exe of LSLib below $BG3_TOOLS, else below the first _tools folder above the project, or None."""
    tools = os.environ.get("BG3_TOOLS")
    if not tools:
        tools = next((folder / "_tools" for folder in ROOT.parents if (folder / "_tools").is_dir()), None)
    if tools is None:
        return None
    divine = Path(tools) / "lslib" / "Packed" / "Tools" / "Divine.exe"
    return divine if divine.is_file() else None


def newest_save():
    story = DATA_DIR / "PlayerProfiles" / "Public" / "Savegames" / "Story"
    saves = sorted(story.glob("*/*.lsv"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not saves:
        print(f"No savegames found in {story}")
        return None
    return saves[0]


def read_mod_variables(save: Path, divine: Path) -> dict:
    """Returns {name: (type, bytes)} for the mod variables of this mod in a savegame."""
    module = mod_uuid()
    with tempfile.TemporaryDirectory() as tmp:
        # Divine.exe needs absolute local paths and fails on a share, so it reads a local copy of the save.
        local_save = Path(tmp) / save.name
        shutil.copyfile(save, local_save)
        subprocess.run([str(divine), "--game", "bg3", "--action", "extract-package", "--source", str(local_save),
                        "--destination", tmp, "--expression", r"Globals\.lsf$", "--use-regex", "--loglevel", "warn"],
                       check=True)
        lsf = Path(tmp) / "Globals.lsf"
        lsx = Path(tmp) / "Globals.lsx"
        subprocess.run([str(divine), "--game", "bg3", "--action", "convert-resource", "--source", str(lsf),
                        "--destination", str(lsx), "--loglevel", "warn"], check=True)

        variables = {}
        for _, element in ET.iterparse(lsx, events=("end",)):
            if element.tag == "node" and element.get("id") == "ModVariables":
                attributes = {a.get("id"): a.get("value") for a in element.findall("attribute")}
                if attributes.get("Module") == module:
                    for variable in element.iter("node"):
                        if variable.get("id") != "Variable":
                            continue
                        values = {a.get("id"): a.get("value") for a in variable.findall("attribute")}
                        variables[values.get("Name")] = (values.get("Type"), base64.b64decode(values.get("Value") or ""))
            elif element.tag == "region" and element.get("id") == "ScriptExtenderSave":
                break
        return variables


def print_entries(log: dict):
    entries = log.get("Entries") or []
    print(f"{len(entries)} entries (next id {log.get('NextId')}), newest first:\n")
    header = (f"{'Id':>5}  {'Time':<19}  {'Item':<34} {'Type':<9} {'Rarity':<10} {'Qty':>4} {'Value':>6}  "
              f"{'Who':<14} {'Where':<28} From")
    print(header)
    print("-" * len(header))
    for entry in reversed(entries):
        epoch = entry.get("Epoch")
        when = datetime.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S") if epoch else ""
        rarity = entry.get("Rarity") or 0
        rarity_label = RARITY_LABELS[rarity] if 0 <= rarity < len(RARITY_LABELS) else str(rarity)
        print(f"{entry.get('Id', ''):>5}  {when:<19}  {str(entry.get('Name', ''))[:34]:<34} "
              f"{str(entry.get('Category', '')):<9} {rarity_label:<10} {entry.get('Amount', 1):>4} "
              f"{str(entry.get('Value', '')):>6}  {str(entry.get('Owner', ''))[:14]:<14} "
              f"{str(entry.get('Where') or '')[:28]:<28} {entry.get('From') or ''}")


def read_save_log(save: Path):
    print(f"Save: {save} ({datetime.datetime.fromtimestamp(save.stat().st_mtime):%Y-%m-%d %H:%M:%S})")
    divine = find_divine()
    if divine is None:
        print("Divine.exe (LSLib) not found: put LSLib into _tools/lslib above the project, or set BG3_TOOLS.")
        return None
    variables = read_mod_variables(save, divine)
    if VARIABLE_NAME not in variables:
        print("No Loot Log data in this save (saved before Loot Log was active, or nothing logged yet).")
        return None
    _, raw = variables[VARIABLE_NAME]
    return BinaryJsonReader(raw).parse()


def read_live_log(path: Path):
    log = json.loads(path.read_text(encoding="utf-8"))
    updated = log.get("Updated")
    when = datetime.datetime.fromtimestamp(updated).strftime("%Y-%m-%d %H:%M:%S") if updated else "?"
    print(f"Live file: {path} (written {when})")
    return log


def print_tail(path: Path, count: int):
    print(f"\n== {path} (newest {count} lines) ==")
    if not path.is_file():
        print("(not there: the mod did not write it yet, or the folder is not reachable)")
        return
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines()[-count:]:
        print(line)


def main():
    parser = argparse.ArgumentParser(
        description="Print the Loot Log (live file or savegame) and the newest lines of the mod's log files.")
    parser.add_argument("source", nargs="?", help="a .lsv savegame or a log.json file")
    parser.add_argument("--save", action="store_true", help="read the newest savegame instead of the live file")
    parser.add_argument("-n", type=int, default=40, help="lines of server.log and client.log (default 40)")
    parser.add_argument("--json", action="store_true", help="print the raw log as JSON, without the log files")
    parser.add_argument("--self-test", action="store_true", help="test the binary JSON decoder and exit")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return

    live_file = LIVE_DIR / "log.json"
    log = None
    if args.source:
        source = Path(args.source)
        log = read_live_log(source) if source.suffix.lower() == ".json" else read_save_log(source)
    elif args.save or not live_file.is_file():
        save = newest_save()
        if save is not None:
            log = read_save_log(save)
    else:
        log = read_live_log(live_file)

    if args.json:
        if log is not None:
            print(json.dumps(log, indent=2, ensure_ascii=False))
        return
    if log is not None:
        print_entries(log)
    print_tail(LIVE_DIR / "server.log", args.n)
    print_tail(LIVE_DIR / "client.log", args.n)


if __name__ == "__main__":
    main()
