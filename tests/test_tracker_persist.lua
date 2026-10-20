-- A savegame that already holds log entries.

local function Id(n)
    return string.format("00000000-0000-0000-0000-%012d", n)
end

Harness.ModVars.Log = {
    Entries = {
        { Id = 7, Name = "Saved Sword", Category = "Weapon", Rarity = 2, Amount = 1, Epoch = 1 },
        { Id = 8, Name = "Saved Ring", Category = "Jewelry", Rarity = 3, Amount = 1, Epoch = 2 },
    },
    NextId = 9,
}

local Tracker = Ext.Require("Server/Tracker.lua")
Tracker.Init()

local KARLACH, GOBLIN = Id(1), Id(2)
Harness.AddObject(KARLACH, "character", "Karlach", { Player = true, Party = true, Components = { PartyMember = {} } })
Harness.AddObject(GOBLIN, "character", "Goblin")

Test("History is not served before the savegame is loaded", function()
    local reply = Harness.Channels.History.RequestHandler({}, 1)
    AssertEq(reply.Ready, false, "not ready")
    AssertEq(#reply.Entries, 0, "no entries yet")
end)

Test("The saved log is restored and extended", function()
    Ext.Events.SessionLoaded:Fire({})
    local reply = Harness.Channels.History.RequestHandler({}, 1)
    AssertEq(reply.Ready, true, "ready")
    AssertEq(#reply.Entries, 2, "saved entries")
    AssertEq(reply.Entries[2].Name, "Saved Ring", "order kept")

    Harness.AddObject(Id(50), "item", "New Loot", { Holder = GOBLIN })
    Harness.Move(Id(50), KARLACH)
    Harness.RunTicks()

    local entries = Harness.ModVars.Log.Entries
    AssertEq(#entries, 3, "one more entry")
    AssertEq(entries[3].Id, 9, "id continues from the savegame")
    AssertEq(Harness.ModVars.Log.NextId, 10, "next id saved")
end)

Test("A level start re-reads an empty log from the savegame", function()
    -- The session event can come before the savegame data; an empty log is read again on level start.
    Harness.Channels.Clear.MessageHandler({}, 1)
    Harness.ModVars.Log = { Entries = { { Id = 1, Name = "Late Entry", Category = "Other", Rarity = 0 } }, NextId = 2 }
    Harness.Listeners["LevelGameplayStarted/2"]("WLD_Main_A", 0)
    local reply = Harness.Channels.History.RequestHandler({}, 1)
    AssertEq(#reply.Entries, 1, "re-read")
    AssertEq(reply.Entries[1].Name, "Late Entry", "entry from the savegame")
end)
