-- Where are the logged items now? (Server/Places.lua, called by the Tracker)

local Tracker = Ext.Require("Server/Tracker.lua")
Tracker.Init()

local function Id(n)
    return string.format("00000000-0000-0000-0000-%012d", n)
end

local KARLACH, GALE, GOBLIN, TRADER, CAMP = Id(1), Id(2), Id(10), Id(11), Id(12)
local POUCH, GEM_BAG, SATCHEL, BOX = Id(20), Id(21), Id(22), Id(23)
local HEALING_STACK, ARROW_STACK = Id(30), Id(31)

Harness.AddObject(KARLACH, "character", "Karlach", { Player = true, Party = true, Components = { PartyMember = {} } })
Harness.AddObject(GALE, "character", "Gale", { Player = true, Party = true, Components = { PartyMember = {} } })
Harness.AddObject(GOBLIN, "character", "Goblin Boss")
Harness.AddObject(TRADER, "character", "Arron")
Harness.AddObject(CAMP, "container", "Traveller's Chest", { Template = "CONT_PlayerCampChest_A", Components = { CampChest = {} } })
Harness.AddObject(POUCH, "item", "Pouch", { Holder = KARLACH, Container = true })
Harness.AddObject(GEM_BAG, "item", "Gem Bag", { Holder = POUCH, Container = true })
Harness.AddObject(SATCHEL, "item", "Satchel", { Holder = GALE, Container = true })
Harness.AddObject(BOX, "item", "Box", { Holder = CAMP, Container = true })
-- A different template than the looted potion, so only the StackedWith event can lead to it.
Harness.AddObject(HEALING_STACK, "item", "Potion of Healing", { Holder = SATCHEL, Template = "POT_Healing_Stack", Amount = 3 })
Harness.AddObject(ARROW_STACK, "item", "Arrow of Fire", { Holder = BOX, Template = "ARR_Fire", Amount = 10 })

Ext.Events.SessionLoaded:Fire({})

local nextItem = 3000

local function Find(name)
    for _, entry in ipairs(Harness.ModVars.Log.Entries) do
        if entry.Name == name then
            return entry
        end
    end
    error("no entry " .. name)
end

local function Place(name)
    local entry = Find(name)
    return tostring(entry.Where) .. " | " .. tostring(entry.WhereState)
end

--- Loots a new item from the goblin, then waits until the "send to camp" time window is over.
local function Loot(name, holder, options)
    nextItem = nextItem + 1
    local uuid = Id(nextItem)
    options = options or {}
    options.Holder = GOBLIN
    Harness.AddObject(uuid, "item", name, options)
    Harness.Move(uuid, holder)
    Harness.RunTicks()
    Harness.Monotonic = Harness.Monotonic + 11000
    return uuid
end

--- The open window asks where the items are, one second after the last time. Returns the entries the server sent
--- back, or nil when no place changed.
local function AskPlaces()
    Harness.Monotonic = Harness.Monotonic + 1000
    local sent = Harness.Channels.Entries.Sent
    local count = #sent
    Harness.Channels.Places.MessageHandler({}, 1)
    if #sent == count then
        return nil
    end
    AssertEq(sent[#sent].Data.Updated, true, "sent as a place update")
    return sent[#sent].Data.Entries
end

Test("A new entry keeps its item and is sent with its place", function()
    local sword = Loot("Sword of Justice", KARLACH, { Components = { Weapon = {} } })
    local entry = Find("Sword of Justice")
    AssertEq(entry.Uuid, sword, "item kept")
    AssertEq(entry.Template, Harness.TemplateUuid(Harness.Objects[sword].Template), "root template kept")
    AssertEq(Place("Sword of Justice"), "Karlach | party", "place")

    local sent = Harness.Channels.Entries.Sent
    AssertEq(sent[#sent].Data.Entries[1].Where, "Karlach", "sent with the place")
    AssertEq(sent[#sent].Data.Updated, nil, "new entries are not a place update")
end)

Test("Bags show the whole path; only changed entries are sent", function()
    Harness.Move(Find("Sword of Justice").Uuid, GEM_BAG)
    local changed = AskPlaces()
    AssertTrue(changed ~= nil and #changed == 1, "one entry changed")
    AssertEq(changed[1].Name, "Sword of Justice", "the sword")
    AssertEq(changed[1].Where, "Karlach > Pouch > Gem Bag", "sent with the new place")
    AssertEq(Place("Sword of Justice"), "Karlach > Pouch > Gem Bag | party", "saved")
    AssertEq(AskPlaces(), nil, "nothing changed, nothing sent")
end)

Test("Equipped, camp chest, trader and ground", function()
    local sword = Find("Sword of Justice").Uuid
    Harness.Move(sword, KARLACH)
    Harness.Objects[sword].Equipped = true
    AskPlaces()
    AssertEq(Place("Sword of Justice"), "Karlach (equipped) | party", "equipped")

    Harness.Objects[sword].Equipped = nil
    Harness.Move(sword, BOX)
    AskPlaces()
    AssertEq(Place("Sword of Justice"), "Camp chest > Box | camp", "camp chest")

    Harness.Move(sword, TRADER)
    AskPlaces()
    AssertEq(Place("Sword of Justice"), "Arron | other", "sold to a trader")

    Harness.Objects[sword].Holder = nil
    AskPlaces()
    AssertEq(Place("Sword of Justice"), "On the ground | ground", "dropped")
end)

Test("A destroyed item is gone for good", function()
    local junk = Loot("Broken Plate", GALE)
    AssertEq(Place("Broken Plate"), "Gale | party", "in the inventory")
    Harness.RemoveObject(junk) -- sold by Loot Autoseller
    AskPlaces()
    AssertEq(Place("Broken Plate"), "Gone | gone", "gone")

    Harness.AddObject(junk, "item", "Broken Plate", { Holder = GALE })
    AskPlaces()
    AssertEq(Place("Broken Plate"), "Gone | gone", "not looked up again")
end)

Test("A potion that merged into another stack shows that stack (StackedWith)", function()
    local potion = Loot("Potion of Healing", KARLACH, { Template = "POT_Healing" })
    Harness.FireStackedWith(potion, HEALING_STACK)
    Harness.RemoveObject(potion)
    AskPlaces()
    AssertEq(Place("Potion of Healing"), "Gale > Satchel | party", "the stack it merged into")
end)

Test("Without StackedWith, a party item with the same template counts as the stack", function()
    local arrow = Loot("Arrow of Fire", KARLACH, { Template = "ARR_Fire" })
    Harness.RemoveObject(arrow)
    AskPlaces()
    AssertEq(Place("Arrow of Fire"), "Camp chest > Box | camp", "same template in the camp chest")
end)

Test("Entries without an item have no place; one update per second at most", function()
    Harness.ConsoleCommands.lootlog_test("lootlog_test")
    Harness.RunTicks()
    AskPlaces()
    AssertEq(Find("Test Fork").Where, nil, "test entries have no item")

    local spoon = Loot("Bent Spoon", GALE)
    AskPlaces()
    Harness.Move(spoon, SATCHEL)
    Harness.Channels.Places.MessageHandler({}, 1) -- a second client at the same moment
    AssertEq(Place("Bent Spoon"), "Gale | party", "request in the same second ignored")
    AskPlaces()
    AssertEq(Place("Bent Spoon"), "Gale > Satchel | party", "next request")
end)
