local Common = Ext.Require("Shared/Common.lua")
local Tracker = Ext.Require("Server/Tracker.lua")
Tracker.Init()

local function Id(n)
    return string.format("00000000-0000-0000-0000-%012d", n)
end

local KARLACH, GALE, SHADOWHEART = Id(1), Id(2), Id(3)
local GOBLIN, CHEST, CAMP, BAG, TRADER = Id(10), Id(11), Id(12), Id(13), Id(14)
local OLD_SWORD, OLD_POTION, CAMP_GEM, CAMP_GEM_2, SH_MACE = Id(20), Id(21), Id(22), Id(23), Id(24)

Harness.AddObject(KARLACH, "character", "Karlach", { Player = true, Party = true, Template = "S_Player_Karlach", Components = { PartyMember = {} } })
Harness.AddObject(GALE, "character", "Gale", { Player = true, Party = true, Template = "S_Player_Gale", Components = { PartyMember = {} } })
Harness.AddObject(GOBLIN, "character", "Goblin Boss")
Harness.AddObject(TRADER, "character", "Arron")
Harness.AddObject(CHEST, "container", "Old Chest", { Template = "CONT_Chest_A" })
-- No CampChest component: the camp chest is found by its template name and is not scanned on load.
Harness.AddObject(CAMP, "container", "Traveller's Chest", { Template = "CONT_PlayerCampChest_A" })
Harness.AddObject(BAG, "item", "Pouch", { Holder = KARLACH, Container = true })
Harness.AddObject(OLD_SWORD, "item", "Old Sword", { Holder = KARLACH, Components = { Weapon = {} } })
Harness.AddObject(OLD_POTION, "item", "Old Potion", { Holder = BAG, Components = { Use = { ItemUseType = "Potion" } } })
Harness.AddObject(CAMP_GEM, "item", "Camp Gem", { Holder = CAMP })
Harness.AddObject(CAMP_GEM_2, "item", "Camp Gem 2", { Holder = CAMP })

local nextItem = 1000

local function NewItem(name, holder, components)
    nextItem = nextItem + 1
    local uuid = Id(nextItem)
    Harness.AddObject(uuid, "item", name, { Holder = holder, Components = components or {} })
    return uuid
end

local function Entries()
    return (Harness.ModVars.Log or {}).Entries or {}
end

local function LastEntry()
    local entries = Entries()
    return entries[#entries]
end

local function Broadcasts()
    return Harness.Channels.Entries.Sent
end

Test("Common registers the persistent log and the channels", function()
    local options = Harness.RegisteredVars.Log
    AssertTrue(options ~= nil, "Log variable registered")
    AssertEq(options.Persistent, true, "persistent")
    AssertEq(options.Server, true, "server")
    for _, name in ipairs({ "Entries", "History", "Clear", "Toggle" }) do
        AssertTrue(Harness.Channels[name] ~= nil, "channel " .. name)
    end
    AssertTrue(Harness.Listeners["TemplateAddedTo/4"] ~= nil, "TemplateAddedTo listener")
    AssertTrue(Harness.Listeners["RemovedFrom/2"] ~= nil, "RemovedFrom listener")
end)

Test("Before the session is loaded, new items are only marked as known", function()
    local early = NewItem("Early Ring", GOBLIN, { Equipable = { Slot = "Ring" } })
    Harness.Move(early, KARLACH)
    Harness.RunTicks()
    AssertEq(#Entries(), 0, "nothing logged")

    Ext.Events.SessionLoaded:Fire({})
    AssertTrue(Harness.OutputContains("Logging is active"), "ready after load")

    Harness.Move(early, GALE)
    Harness.RunTicks()
    AssertEq(#Entries(), 0, "known item not logged later")
end)

Test("Items the party already owns are not logged when they move", function()
    Harness.Move(OLD_SWORD, GALE)
    Harness.Move(OLD_POTION, GALE)
    Harness.RunTicks()
    AssertEq(#Entries(), 0, "nothing logged")
    AssertEq(#Broadcasts(), 0, "nothing sent")
end)

Test("Loot from a corpse is logged with owner and source", function()
    Harness.Stats["WPN_Flail"] = { Rarity = "Rare", ModifierList = "Weapon" }
    local loot = NewItem("Spiked Flail", GOBLIN, { Weapon = {}, Data = { StatsId = "WPN_Flail" }, Value = { Value = 300, Rarity = 3 } })
    Harness.Move(loot, KARLACH)
    Harness.RunTicks()

    AssertEq(#Entries(), 1, "one entry")
    local entry = LastEntry()
    AssertEq(entry.Id, 1, "first id")
    AssertEq(entry.Name, "Spiked Flail", "name")
    AssertEq(entry.Owner, "Karlach", "owner")
    AssertEq(entry.From, "Goblin Boss", "source")
    AssertEq(entry.Category, "Weapon", "category")
    AssertEq(entry.Rarity, 2, "rarity")
    AssertEq(entry.ItemUuid, nil, "internal fields removed")
    AssertEq(entry.FromHolder, nil, "internal fields removed")
    AssertEq(entry.DestTop, nil, "internal fields removed")

    AssertEq(#Broadcasts(), 1, "one broadcast")
    AssertEq(Broadcasts()[1].Data.Entries[1].Name, "Spiked Flail", "broadcast payload")
end)

Test("The source is found when RemovedFrom comes after TemplateAddedTo", function()
    local loot = NewItem("Silver Ring", CHEST, { Equipable = { Slot = "Ring" } })
    Harness.Move(loot, BAG, "Regular", "added-first")
    Harness.RunTicks()
    AssertEq(LastEntry().Name, "Silver Ring", "logged")
    AssertEq(LastEntry().From, "Old Chest", "source")
    AssertEq(LastEntry().Owner, "Karlach", "owner of the bag")
end)

Test("A ground pickup that moves on in the same tick reports the final owner", function()
    local count = #Entries()
    local pickup = NewItem("Apple", nil, { CampSupply = { Amount = 1 } })
    Harness.Objects[pickup].Holder = KARLACH
    Harness.FireAddedTo(pickup, KARLACH, "Regular")
    Harness.Move(pickup, GALE)
    Harness.RunTicks()

    AssertEq(#Entries(), count + 1, "one entry")
    AssertEq(LastEntry().Name, "Apple", "name")
    AssertEq(LastEntry().Owner, "Gale", "final owner")
    AssertEq(LastEntry().From, nil, "no source")
    AssertEq(LastEntry().Category, "Food", "category")
end)

Test("Items taken from the camp chest are internal moves", function()
    local count = #Entries()
    Harness.Move(CAMP_GEM, KARLACH)
    Harness.Move(CAMP_GEM_2, GALE, "Regular", "added-first")
    Harness.RunTicks()
    AssertEq(#Entries(), count, "nothing logged")
end)

Test("Loot sent straight to the camp chest is logged", function()
    local loot = NewItem("Wine", GOBLIN, { CampSupply = { Amount = 2 } })
    Harness.Move(loot, CAMP)
    Harness.RunTicks()
    AssertEq(LastEntry().Name, "Wine", "logged")
    AssertEq(LastEntry().Owner, "Camp chest", "camp owner")
    AssertEq(LastEntry().From, "Goblin Boss", "source")
end)

Test("Treasure generated into world containers is ignored", function()
    local count = #Entries()
    local treasure = NewItem("Gem", nil)
    Harness.Objects[treasure].Holder = CHEST
    Harness.FireAddedTo(treasure, CHEST, "Treasure")
    Harness.RunTicks()
    AssertEq(#Entries(), count, "nothing logged")

    Harness.Move(treasure, KARLACH)
    Harness.RunTicks()
    AssertEq(LastEntry().Name, "Gem", "logged once looted")
end)

Test("Bought items are logged with the trader as source", function()
    local ware = NewItem("Scroll of Haste", TRADER, { Use = { ItemUseType = "Scroll" } })
    Harness.Move(ware, GALE)
    Harness.RunTicks()
    AssertEq(LastEntry().Name, "Scroll of Haste", "logged")
    AssertEq(LastEntry().From, "Arron", "trader")
    AssertEq(LastEntry().Category, "Scroll", "category")
end)

Test("Items of a companion who joins are known", function()
    Harness.AddObject(SHADOWHEART, "character", "Shadowheart", { Player = true, Party = true, Template = "S_Player_ShadowHeart", Components = { PartyMember = {} } })
    Harness.AddObject(SH_MACE, "item", "Mace", { Holder = SHADOWHEART, Components = { Weapon = {} } })
    Harness.Listeners["CharacterJoinedParty/1"](Harness.GuidString(SHADOWHEART))

    local count = #Entries()
    Harness.Move(SH_MACE, KARLACH)
    Harness.RunTicks()
    AssertEq(#Entries(), count, "nothing logged")
end)

Test("History and Clear handlers", function()
    local reply = Harness.Channels.History.RequestHandler({}, 1)
    AssertEq(reply.Ready, true, "ready")
    AssertEq(#reply.Entries, #Entries(), "full history")
    Harness.DeepCopy(reply)

    Harness.Channels.Clear.MessageHandler({}, 1)
    AssertEq(#Entries(), 0, "cleared")

    local loot = NewItem("Dagger", GOBLIN, { Weapon = {} })
    Harness.Move(loot, KARLACH)
    Harness.RunTicks()
    AssertEq(#Entries(), 1, "logging continues")
    AssertTrue(LastEntry().Id > 1, "ids keep counting")
end)

Test("The log keeps the newest entries only", function()
    for i = 1, Common.MaxEntries + 10 do
        local loot = NewItem("Bulk " .. i, GOBLIN)
        Harness.Move(loot, KARLACH)
    end
    Harness.RunTicks()
    AssertEq(#Entries(), Common.MaxEntries, "trimmed")
    AssertEq(LastEntry().Name, "Bulk " .. (Common.MaxEntries + 10), "newest kept")
end)

Test("Console commands", function()
    local count = #Broadcasts()
    Harness.ConsoleCommands.lootlog_test("lootlog_test")
    Harness.RunTicks()
    AssertEq(LastEntry().Name, "Test Fork", "test entries added")
    AssertEq(#Broadcasts(), count + 1, "one batch")

    Harness.ConsoleCommands.lootlog("lootlog")
    AssertEq(#Harness.Channels.Toggle.Sent, 1, "toggle sent")

    Harness.ConsoleCommands.lootlog_debug("lootlog_debug")
    AssertEq(Tracker.Debug, true, "debug on")
    local loot = NewItem("Debug Item", GOBLIN)
    Harness.Move(loot, KARLACH)
    Harness.Move(OLD_SWORD, KARLACH)
    Harness.RunTicks()
    AssertTrue(Harness.OutputContains("NEW Debug Item"), "debug output for new items")
    AssertTrue(Harness.OutputContains("known item Old Sword"), "debug output for known items")
    Harness.ConsoleCommands.lootlog_debug("lootlog_debug")
    AssertEq(Tracker.Debug, false, "debug off")

    Harness.ConsoleCommands.lootlog_rescan("lootlog_rescan")
    AssertTrue(Harness.OutputContains("Rescan:"), "rescan output")
end)
