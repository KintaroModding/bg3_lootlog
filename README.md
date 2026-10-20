# Loot Log

Logs all loot your party gets, also from auto-loot mods, in a filterable in-game window with an optional pop-up and chime.

A mod for Baldur's Gate 3 (Patch 8), made with game version 4.1.1.7398727. It needs
[Norbyte's Script Extender](https://github.com/Norbyte/bg3se) v30 or later. This README is for developers. What the
mod does, how to install and use it, and its compatibility are in [openmods.md](openmods.md), the mod page on
[openmods](https://openmods.nexus).

## Build

Requirements: Windows PowerShell and [LSLib](https://github.com/Norbyte/lslib/releases) (`Divine.exe`).
`build.ps1` looks for `_tools\lslib\Packed\Tools\Divine.exe` in the parent folders of the project; set `BG3_TOOLS` to
a folder that holds `lslib\` to use another place.

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1             # dist\bg3_lootlog.pak
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Deploy     # build, then copy the .pak to the Mods folder
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Wait      # copy the .pak when the game is closed
```

`deploy.ps1` copies the .pak to the `Mods` folder below `BG3_DATA_DIR` (the BG3 user-data folder), else to
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods`; `-ModsDir` overrides both. The running game locks the .pak, so
the script stops (exit code 2) or, with `-Wait`, waits until the game is closed. It copies to a temporary file,
checks the hash and then swaps the file in one step.

## Project layout

```
src/                                     Mod files (packed into the .pak)
  Mods/bg3_lootlog/meta.lsx              Mod metadata (UUID bee0663b-2f51-42f4-87ae-c016090080a8)
  Mods/bg3_lootlog/ScriptExtender/
    Config.json
    Lua/BootstrapServer.lua              Server entry point
    Lua/BootstrapClient.lua              Client entry point
    Lua/Shared/Common.lua                Categories, rarities, mod version, mod variable, net channels
    Lua/Shared/FileWriter.lua            Throttled file output in the Script Extender folder
    Lua/Shared/LogFilter.lua             Filtering and formatting (pure functions)
    Lua/Server/Tracker.lua               Inventory events, known items, the saved log
    Lua/Server/ItemInfo.lua              Item names, categories, rarity; party inventories
    Lua/Server/Places.lua                Where the logged items are now
    Lua/Server/Sound.lua                 Plays the chime (PlayHUDSoundResource)
    Lua/Server/ServerLog.lua             server.log
    Lua/Client/Window.lua                IMGUI window and hotkey
    Lua/Client/Alert.lua                 Pop-up and chime for new loot
    Lua/Client/Settings.lua              Settings file of the window
    Lua/Client/ClientLog.lua             client.log
docs/                                    Cover and screenshots for openmods.md
tests/                                   Offline tests (Lua 5.4 through lupa)
scripts/bump_version.py                  Raises the last version digit in meta.lsx
scripts/show_log.py                      Prints the log (live file or savegame) and the mod's log files
build.ps1                                Builds dist/bg3_lootlog.pak from src/
deploy.ps1                               Copies the .pak to the Mods folder
openmods.json, openmods.md               Data and mod page for openmods.nexus
```

## How "new loot" is detected

- Osiris raises `TemplateAddedTo` and `RemovedFrom` for every inventory hop. An item keeps its UUID while it moves
  between inventories.
- After each load, every item the party already owns is marked as known. Known items are never logged, so moving
  items between party members does not create entries.
- A new item that comes from a party inventory or the camp chest is an internal move and is not logged.
  Exception: a container that joined the party a moment ago, because other mods may empty it right away.
- Items inside a container that joins the party (a bag, a "void capsule") raise no events of their own. They are
  logged together with the container, with the container as their source.
- When an item moves on to the camp chest within 10 seconds after it was logged (auto-loot "send to camp"), its
  owner changes to *Camp chest*.
- Entries are collected during one game tick and sent to the window on the next tick, when the source is known.

## How "Where" is found

- Each entry stores the item UUID and its root template. When an entry is sent, and every 2 seconds while the window
  is open, the server walks up from the item with `GetDirectInventoryOwner` (bag, bag, ..., party member or camp
  chest) and sends the entries whose place changed. The window changes these cells in place.
- An item that no longer exists may have merged into another stack. Osiris reports this with `StackedWith`; the entry
  then follows the other stack. Without that event, an item with the same root template in the party inventories
  counts as the stack. When nothing is found, the item is *Gone* and is not looked up again.

## The chime

The chime is a game UI sound resource. The server plays it with `PlayHUDSoundResource` for the character of the
client (`"ChimeMethod": "client"` in `settings.json` posts the event on the HUD sound object instead). The volume
scales the global UI volume RTPC (`VolumeRtpc`, default `RTPC_Volume_UI`) while the chime plays, so other UI sounds
in those seconds are quieter too; afterwards the RTPC goes back to its earlier value. A value on the HUD object only
(`"VolumeScope": "hud"`) did not change the volume in the game.

## Files outside the game

The mod writes these files to `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\bg3_lootlog\`:

| File | Content |
|------|---------|
| `log.json` | The log of the loaded save, rewritten at most once per second after a change and after each load |
| `server.log` | Load messages, errors and (with `!lootlog_debug`) every relevant inventory event; newest 500 lines |
| `client.log` | Load messages and errors of the window; newest 200 lines |
| `settings.json` | Window, pop-up and chime settings (`ChimeSound` is a sound resource id) |
| `sounds.txt` | Written once: game sound resources with UI-like event names, to pick another chime |

The log itself is a mod variable in the savegame (newest 500 entries); the Script Extender stores it in the save's
`Globals.lsf`.

Each load writes a line like `Loot Log 1.0.0.1 loaded.` to `server.log` and `client.log`, so the logs show which
version runs. `scripts\show_log.py` prints the log as a table, newest first, and then the newest lines of
`server.log` and `client.log`. It reads the files from `BG3_DATA_DIR`, else from the local BG3 user-data folder. The
log comes from the live `log.json`, or from a savegame (this needs `Divine.exe`, found as in `build.ps1`):

```powershell
python scripts\show_log.py                    # live log.json (newest save when there is no live file), then the logs
python scripts\show_log.py --save             # newest savegame
python scripts\show_log.py path\to\Save.lsv   # a specific savegame
python scripts\show_log.py --json             # the raw log as JSON
```

## Versioning

Every change raises the last version digit (1.0.0.0 -> 1.0.0.1):

```powershell
python scripts\bump_version.py           # both Version64 values in meta.lsx
python scripts\bump_version.py --show
```

## Tests

```powershell
python -m pip install lupa
python tests\run_tests.py
```

The tests run every mod script against mocks of the Script Extender API (`tests/harness.lua`). The IMGUI, audio and
resource mocks are checked against the Script Extender IDE helpers (`tests/gen_extui_api.py` refreshes
`tests/extui_api.json`), so a property or method that does not exist in the real API fails the tests.

## License

MIT, see [LICENSE](LICENSE).
