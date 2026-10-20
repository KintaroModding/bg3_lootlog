-- Scenarios from the Ancient Mega Pack auto-loot (Osiris: ToInventory, MoveAllLootableItemsTo, SendToCampChest)
-- and FallenStar's Loot Autoseller (sells junk on arrival, empties junk containers).

local Tracker = Ext.Require("Server/Tracker.lua")
Tracker.Init()

local function Id(n)
    return string.format("00000000-0000-0000-0000-%012d", n)
end

local KARLACH, GALE, GOBLIN, CHEST, CAMP = Id(1), Id(2), Id(10), Id(11), Id(12)

Harness.AddObject(KARLACH, "character", "Karlach", { Player = true, Party = true, Components = { PartyMember = {} } })
Harness.AddObject(GALE, "character", "Gale", { Player = true, Party = true, Components = { PartyMember = {} } })
Harness.AddObject(GOBLIN, "character", "Goblin Boss")
Harness.AddObject(CHEST, "container", "Old Chest")
Harness.AddObject(CAMP, "container", "Traveller's Chest", { Template = "CONT_PlayerCampChest_A", Components = { CampChest = {} } })
Harness.AddObject(Id(13), "item", "Stored Shield", { Holder = CAMP, Components = { Armor = { Shield = true } } })

local nextItem = 2000

local function NewItem(name, holder, options)
    nextItem = nextItem + 1
    local uuid = Id(nextItem)
    options = options or {}
    options.Holder = holder
    Harness.AddObject(uuid, "item", name, options)
    return uuid
end

local function Entries()
    return (Harness.ModVars.Log or {}).Entries or {}
end

local function Names()
    local names = {}
    for _, entry in ipairs(Entries()) do
        names[#names + 1] = entry.Name
    end
    return table.concat(names, ", ")
end

local function Find(name)
    for _, entry in ipairs(Entries()) do
        if entry.Name == name then
            return entry
        end
    end
    return nil
end

local function Clear()
    Harness.Channels.Clear.MessageHandler({}, 1)
end

Ext.Events.SessionLoaded:Fire({})

Test("Items in the camp chest are known after loading", function()
    Harness.Move(Id(13), KARLACH)
    Harness.RunTicks()
    AssertEq(#Entries(), 0, "nothing logged")
end)

Test("Corpse loot (MoveAllLootableItemsTo) is logged with the corpse as source", function()
    local sword = NewItem("Scimitar", GOBLIN, { Components = { Weapon = {} } })
    local ring = NewItem("Ring of Mischief", GOBLIN, { Components = { Equipable = { Slot = "Ring" } } })
    Harness.Move(sword, KARLACH)
    Harness.Move(ring, KARLACH)
    Harness.RunTicks()
    AssertEq(Names(), "Scimitar, Ring of Mischief", "entries")
    AssertEq(Find("Ring of Mischief").From, "Goblin Boss", "source")
    AssertEq(Find("Ring of Mischief").Category, "Jewelry", "category")
end)

Test("Ground pickup (ToInventory) has no source", function()
    Clear()
    local arrow = NewItem("Arrow of Fire", nil, { Amount = 5, Components = { Use = { ItemUseType = "Arrow" } } })
    Harness.Move(arrow, GALE)
    Harness.RunTicks()
    AssertEq(Names(), "Arrow of Fire", "entry")
    AssertEq(Find("Arrow of Fire").From, nil, "no source")
    AssertEq(Find("Arrow of Fire").Amount, 5, "amount")
    AssertEq(Find("Arrow of Fire").Owner, "Gale", "owner")
end)

Test("A picked-up container is logged with its contents", function()
    Clear()
    local capsule = NewItem("Void Capsule", nil, { Container = true })
    NewItem("Gem", capsule)
    local pouch = NewItem("Pouch", capsule, { Container = true })
    NewItem("Potion of Speed", pouch, { Components = { Use = { ItemUseType = "Potion" } } })
    Harness.Move(capsule, KARLACH)
    Harness.RunTicks()

    AssertEq(#Entries(), 4, "capsule, gem, pouch and potion")
    AssertEq(Entries()[1].Name, "Void Capsule", "container first")
    AssertEq(Find("Gem").From, "Void Capsule", "content source")
    AssertEq(Find("Potion of Speed").From, "Pouch", "nested content source")
    AssertEq(Find("Potion of Speed").Owner, "Karlach", "owner")
    AssertEq(Find("Potion of Speed").Category, "Potion", "category")

    -- The contents are known now.
    local gem = nil
    for uuid, object in pairs(Harness.Objects) do
        if object.Name == "Gem" then
            gem = uuid
        end
    end
    Harness.Move(gem, GALE)
    Harness.RunTicks()
    AssertEq(#Entries(), 4, "moving the contents later logs nothing")
end)

Test("A container that another mod empties right away still counts as new loot", function()
    Clear()
    local sack = NewItem("Junk Sack", CHEST, { Container = true })
    local fork = NewItem("Fork", sack)
    local spoon = NewItem("Spoon", sack)

    -- The sack arrives. Loot Autoseller empties it before our handler runs, its events follow.
    Harness.FireRemovedFrom(sack, CHEST)
    Harness.Objects[sack].Holder = KARLACH
    Harness.Objects[fork].Holder = KARLACH
    Harness.Objects[spoon].Holder = KARLACH
    Harness.FireAddedTo(sack, KARLACH)
    Harness.FireRemovedFrom(fork, sack)
    Harness.FireAddedTo(fork, KARLACH)
    Harness.FireRemovedFrom(spoon, sack)
    Harness.FireAddedTo(spoon, KARLACH)
    Harness.RunTicks()

    AssertEq(Names(), "Junk Sack, Fork, Spoon", "all logged")
    AssertEq(Find("Junk Sack").From, "Old Chest", "container source")
    AssertEq(Find("Fork").From, "Junk Sack", "content source")
end)

Test("A party bag that was not scanned is an internal move, with its contents", function()
    Clear()
    local bag = NewItem("Gale's Bag", GALE, { Container = true })
    NewItem("Old Book", bag)
    Harness.Move(bag, KARLACH)
    Harness.RunTicks()
    AssertEq(#Entries(), 0, "nothing logged")
end)

Test("Send to camp: a logged item that moves on to the camp chest gets the camp chest as owner", function()
    Clear()
    local loot = NewItem("Fine Robe", GOBLIN, { Components = { Equipable = { Slot = "Breast" }, Armor = {} } })
    Harness.Move(loot, KARLACH)
    Harness.RunTicks()
    local entry = Find("Fine Robe")
    AssertEq(entry.Owner, "Karlach", "first owner")

    local sentBefore = #Harness.Channels.Entries.Sent
    Harness.Monotonic = Harness.Monotonic + 500
    Harness.Move(loot, CAMP)
    Harness.RunTicks()
    AssertEq(Find("Fine Robe").Owner, "Camp chest", "owner updated")
    AssertEq(#Entries(), 1, "no new entry")
    local sent = Harness.Channels.Entries.Sent
    AssertEq(#sent, sentBefore + 1, "update sent")
    AssertEq(sent[#sent].Data.Entries[1].Id, entry.Id, "same id")

    -- Much later, a move to camp is the player's own action and changes nothing.
    local other = NewItem("Plain Robe", GOBLIN, { Components = { Equipable = { Slot = "Breast" }, Armor = {} } })
    Harness.Move(other, KARLACH)
    Harness.RunTicks()
    Harness.Monotonic = Harness.Monotonic + 20000
    Harness.Move(other, CAMP)
    Harness.RunTicks()
    AssertEq(Find("Plain Robe").Owner, "Karlach", "owner kept")
end)

Test("Junk that is sold on arrival is still logged, and so is the gold", function()
    Clear()
    local junk = NewItem("Broken Plate", GOBLIN)
    Harness.Move(junk, KARLACH)
    Harness.Objects[junk] = nil -- deleted by the autoseller during the same tick
    local gold = NewItem("Gold", nil, { Template = "LOOT_Gold_A", Amount = 3 })
    Harness.Objects[gold].Holder = KARLACH
    Harness.FireAddedTo(gold, KARLACH)
    Harness.RunTicks()

    AssertEq(Names(), "Broken Plate, Gold", "both logged")
    AssertEq(Find("Broken Plate").From, "Goblin Boss", "source kept")
    AssertEq(Find("Gold").Category, "Gold", "gold category")
    AssertEq(Find("Gold").Amount, 3, "gold amount")
end)
