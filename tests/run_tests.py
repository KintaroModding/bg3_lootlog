"""Runs the bg3_lootlog Lua tests outside the game with lupa (Lua 5.4).

Usage:
    python tests/run_tests.py

Every tests/test_*.lua file runs in a fresh Lua state with the mocks from tests/harness.lua.
Before that, every mod script is compiled once to catch syntax errors.
"""

import json
import sys
from pathlib import Path

try:
    from lupa import lua54
except ImportError:
    sys.exit("lupa is missing. Install it with: python -m pip install lupa")

TESTS_DIR = Path(__file__).resolve().parent
ROOT = TESTS_DIR.parent
LUA_ROOT = ROOT / "src" / "Mods" / "bg3_lootlog" / "ScriptExtender" / "Lua"


def read_file(path):
    file = Path(path)
    return file.read_text(encoding="utf-8") if file.is_file() else None


def syntax_check() -> int:
    lua = lua54.LuaRuntime()
    compile_chunk = lua.eval("function(source, name) local _, err = load(source, name, 't') return err end")
    failures = 0
    for path in sorted(LUA_ROOT.rglob("*.lua")):
        error = compile_chunk(path.read_text(encoding="utf-8"), "@" + path.relative_to(LUA_ROOT).as_posix())
        if error:
            print(f"SYNTAX ERROR {error}")
            failures += 1
    return failures


def run_test_file(path: Path, api: dict) -> int:
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    lua_globals = lua.globals()
    lua_globals.MOD_LUA_ROOT = LUA_ROOT.as_posix()
    lua_globals.READ_FILE = read_file
    lua_globals.EXTUI_API = lua.table_from(api, recursive=True)
    lua.execute(read_file(TESTS_DIR / "harness.lua"))

    try:
        lua.execute(path.read_text(encoding="utf-8"))
    except Exception as error:  # A failure while loading the test file itself
        print(f"FAIL {path.name}: could not load\n    {error}")
        return 1

    passed, failures = lua.eval("Harness.RunAll")()
    failures = list(failures.values())
    for failure in failures:
        name, _, details = failure.partition("\n")
        print(f"FAIL {path.name}: {name}")
        for line in details.splitlines():
            print(f"    {line}")
    print(f"{path.name}: {passed} passed, {len(failures)} failed")
    return len(failures)


def main() -> None:
    api = json.loads((TESTS_DIR / "extui_api.json").read_text(encoding="utf-8"))
    failures = syntax_check()
    for path in sorted(TESTS_DIR.glob("test_*.lua")):
        failures += run_test_file(path, api)
    print("ALL TESTS PASSED" if failures == 0 else f"{failures} FAILURE(S)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
