-- The files written for tools outside the game: bg3_lootlog/log.json and bg3_lootlog/server.log.

local ItemInfo = Ext.Require("Server/ItemInfo.lua")
local Tracker = Ext.Require("Server/Tracker.lua")
Tracker.Init()

local function Id(n)
    return string.format("00000000-0000-0000-0000-%012d", n)
end

local KARLACH, GOBLIN = Id(1), Id(2)
Harness.AddObject(KARLACH, "character", "Karlach", { Player = true, Party = true, Components = { PartyMember = {} } })
Harness.AddObject(GOBLIN, "character", "Goblin")

local nextItem = 3000

local function NewItem(name, holder)
    nextItem = nextItem + 1
    Harness.AddObject(Id(nextItem), "item", name, { Holder = holder })
    return Id(nextItem)
end

local function LiveLog()
    local text = Harness.Files["bg3_lootlog/log.json"]
    AssertTrue(text ~= nil, "log.json written")
    return Ext.Json.Parse(text)
end

local function ServerLog()
    return Harness.Files["bg3_lootlog/server.log"] or ""
end

Test("A load writes log.json and server.log after the delay", function()
    Harness.Mods[ModuleUUID] = { Info = { ModVersion = { 1, 0, 0, 7 } } }
    Ext.Events.SessionLoaded:Fire({})
    AssertEq(Harness.Files["bg3_lootlog/log.json"], nil, "nothing written before the delay")
    AssertEq(#Harness.Timers, 2, "one pending write per file")

    Harness.RunTimers()
    AssertEq(#LiveLog().Entries, 0, "empty log")
    AssertTrue(string.find(ServerLog(), "2026-10-12 21:00:00 UTC  Loot Log 1.0.0.7. Session loaded:", 1, true),
        "load line with time and version")
end)

Test("Loot in several ticks gives one write of log.json", function()
    for i = 1, 3 do
        Harness.Move(NewItem("Loot " .. i, GOBLIN), KARLACH)
        Harness.RunTick()
    end
    AssertEq(#Harness.Timers, 1, "writes are combined")

    Harness.RunTimers()
    local live = LiveLog()
    AssertEq(#live.Entries, 3, "entries")
    AssertEq(live.Entries[3].Name, "Loot 3", "newest last")
    AssertEq(live.Entries[3].From, "Goblin", "source")
    AssertEq(live.NextId, 4, "next id")
    AssertEq(live.Updated, Harness.Clock, "time of the write")
end)

Test("Clear and debug output reach the files", function()
    Harness.Channels.Clear.MessageHandler({}, 1)
    Harness.ConsoleCommands.lootlog_debug("lootlog_debug")
    Harness.Move(NewItem("Debug Loot", GOBLIN), KARLACH)
    Harness.RunTicks()
    Harness.ConsoleCommands.lootlog_debug("lootlog_debug")
    Harness.RunTimers()

    AssertEq(#LiveLog().Entries, 1, "cleared, then one entry")
    AssertTrue(string.find(ServerLog(), "Log cleared.", 1, true), "clear line")
    AssertTrue(string.find(ServerLog(), "NEW Debug Loot", 1, true), "debug line")
    AssertTrue(string.find(ServerLog(), "Debug output is OFF", 1, true), "debug toggle line")
end)

Test("Errors are written to server.log", function()
    local original = ItemInfo.Describe
    ItemInfo.Describe = function()
        error("broken item data")
    end
    Harness.Move(NewItem("Cursed Loot", GOBLIN), KARLACH)
    ItemInfo.Describe = original
    Harness.RunTimers()

    AssertTrue(string.find(ServerLog(), "ERROR TemplateAddedTo failed:", 1, true), "error line")
    AssertTrue(string.find(ServerLog(), "broken item data", 1, true), "error text")
    AssertEq(#Harness.Errors, 1, "error also printed to the console")
    Harness.Errors = {}
end)

Test("server.log keeps the newest 500 lines", function()
    for i = 1, 520 do
        Harness.ConsoleCommands.lootlog_debug("lootlog_debug")
    end
    Harness.RunTimers()
    local count = select(2, string.gsub(ServerLog(), "\n", "\n"))
    AssertEq(count, 500, "line count")
end)
