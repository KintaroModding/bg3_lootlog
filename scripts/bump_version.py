"""Increases the build number (the last version digit) of the mod in meta.lsx by 1.

BG3 stores a version as one int64: major << 55 | minor << 47 | revision << 31 | build.
Both Version64 attributes (ModuleInfo and PublishVersion) get the new value.

Usage:
    python scripts/bump_version.py           # 1.0.0.5 -> 1.0.0.6
    python scripts/bump_version.py --show    # print the current version
"""

import re
import sys
from pathlib import Path

META = Path(__file__).resolve().parent.parent / "src" / "Mods" / "bg3_lootlog" / "meta.lsx"
VERSION64 = re.compile(r'(<attribute id="Version64" type="int64" value=")(\d+)("\s*/>)')


def decode(value: int) -> tuple:
    return value >> 55, (value >> 47) & 0xFF, (value >> 31) & 0xFFFF, value & 0x7FFFFFFF


def encode(major: int, minor: int, revision: int, build: int) -> int:
    return (major << 55) | (minor << 47) | (revision << 31) | build


def text(version: tuple) -> str:
    return ".".join(str(part) for part in version)


def main() -> None:
    assert decode(encode(1, 2, 3, 4)) == (1, 2, 3, 4) and encode(1, 0, 0, 0) == 36028797018963968

    content = META.read_bytes().decode("utf-8")
    values = [int(match.group(2)) for match in VERSION64.finditer(content)]
    if not values:
        sys.exit(f"No Version64 attribute in {META}")
    current = decode(values[0])

    if "--show" in sys.argv:
        print(text(current))
        return

    major, minor, revision, build = current
    new = (major, minor, revision, build + 1)
    content = VERSION64.sub(lambda match: f"{match.group(1)}{encode(*new)}{match.group(3)}", content)
    META.write_bytes(content.encode("utf-8"))
    print(f"Version {text(current)} -> {text(new)}")


if __name__ == "__main__":
    main()
