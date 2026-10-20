-- Detects items that join the party and keeps the log in the savegame.
--
-- An item counts as new loot when it lands in a party member's inventory (or a bag inside it, or the camp chest)
-- and the party did not own it before:
--   * Osiris raises TemplateAddedTo / RemovedFrom for every inventory hop. The item UUID stays the same while the
--     item moves between inventories.
--   * After every load, all items the party already owns are marked as known. Known items are never logged.
--   * A new item whose source inventory belongs to the party or the camp chest is an internal move, not loot.
--     Exception: a container that joined the party a moment ago (another mod may empty it right away).
--   * Items inside a container that joins the party raise no events of their own; they are logged with the container.
--   * An item that moves on to the camp chest shortly after it was logged (auto-loot "send to camp") gets the camp
--     chest as its owner.
-- Entries are collected during a tick and sent to the client on the next tick, when the source of the item is known.
-- Each entry keeps the item UUID, so the current place of the item can be found later (Server/Places.lua): when the
-- entry is sent, and when the open window asks for it.

local Common = Ext.Require("Shared/Common.lua")
local FileWriter = Ext.Require("Shared/FileWriter.lua")
local ItemInfo = Ext.Require("Server/ItemInfo.lua")
local Places = Ext.Require("Server/Places.lua")
local events = Ext.Require("Server/ServerLog.lua")

local Tracker = {
    -- Prints every relevant inventory event to the Script Extender console. Toggle with !lootlog_debug.
    Debug = false,
}

local CAMP_OWNER = ItemInfo.CampChestName
local MAX_SCAN_DEPTH = 8
-- How long a logged item can still be updated, and how long a new container counts as fresh.
local RECENT_MS = 10000
-- The window asks for the places every 2 seconds; more requests (several clients) are ignored.
local PLACES_MIN_MS = 1000

-- Osiris add types that are never logged.
local IGNORED_ADD_TYPES = {}

-- [itemUuid] = true for items the party already owned. Rebuilt after every load.
local known = {}
-- Entries created during the current tick. They are sent on the next tick.
local pendingByItem = {}
local pendingOrder = {}
-- [itemUuid] = holderUuid: the first inventory an unknown item left during the current tick.
local recentRemoved = {}
-- [holderUuid] = { Kind = "party"|"camp"|false, Top = uuid }: holder classification cache for the current tick.
local holderCache = {}
-- [itemUuid] = { Entry = entry, Time = ms }: entries sent during the last RECENT_MS.
local recentEntries = {}
-- Sent entries that changed (new owner). They are sent again on the next tick.
local updatedEntries = {}
-- [containerUuid] = ms: containers that joined the party during the last RECENT_MS.
local freshContainers = {}
local tickScheduled = false
-- True after the savegame finished loading and the mod variables are available.
local sessionLoaded = false
-- True after the party inventories were scanned. Before that, new items are only marked as known.
local ready = false
-- { Entries = { ... }, NextId = n }, loaded lazily from the mod variable.
local state = nil
-- Monotonic time of the last place update for the window.
local lastPlacesUpdate = nil

--- Calls fn and returns its first result, or nil when it raises an error.
local function Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

--- Wraps an event handler so that an error is printed instead of breaking other listeners.
local function Guarded(name, fn)
    return function(...)
        local ok, err = xpcall(fn, debug.traceback, ...)
        if not ok then
            _PE("[LootLog] " .. name .. " failed: " .. tostring(err))
            events.Add("ERROR " .. name .. " failed: " .. tostring(err))
        end
    end
end

--- Prints a message to the Script Extender console and adds it to server.log.
local function Log(message)
    _P("[LootLog] " .. message)
    events.Add(message)
end

local function DebugPrint(message)
    if Tracker.Debug then
        Log(message)
    end
end

local function LoadState()
    if state == nil then
        local saved = Try(function() return Ext.Vars.GetModVariables(ModuleUUID).Log end)
        if type(saved) == "table" and type(saved.Entries) == "table" then
            state = { Entries = saved.Entries, NextId = tonumber(saved.NextId) or (#saved.Entries + 1) }
        else
            state = { Entries = {}, NextId = 1 }
        end
    end
    return state
end

-- Live copy of the log, readable outside the game: Script Extender\bg3_lootlog\log.json.
local logFile = FileWriter.New("bg3_lootlog/log.json", 1000, function()
    local current = LoadState()
    return Ext.Json.Stringify({ Updated = Ext.Timer.ClockEpoch(), NextId = current.NextId, Entries = current.Entries })
end)

local function SaveState()
    local current = LoadState()
    Ext.Vars.GetModVariables(ModuleUUID).Log = { Entries = current.Entries, NextId = current.NextId }
    logFile:Touch()
end

--- Returns the top-level inventory holder of an object, or the object itself when it is not in an inventory.
local function TopOwner(uuid)
    return ItemInfo.Uuid(Try(function() return Osi.GetInventoryOwner(uuid) end)) or uuid
end

local ScheduleTick

--- Returns "party", "camp" or nil for an inventory holder, and the top-level holder.
local function ClassifyHolder(holderUuid)
    if holderUuid == nil then
        return nil, nil
    end

    local cached = holderCache[holderUuid]
    if cached == nil then
        local top = TopOwner(holderUuid)
        local kind = false
        if ItemInfo.IsPartyCharacter(top) then
            kind = "party"
        elseif ItemInfo.IsCampChest(top) then
            kind = "camp"
        end
        cached = { Kind = kind, Top = top }
        holderCache[holderUuid] = cached
        ScheduleTick()
    end

    return cached.Kind or nil, cached.Top
end

local function OwnerName(kind, top)
    if kind == "camp" then
        return CAMP_OWNER
    end
    return ItemInfo.GetObjectName(top) or "Party"
end

local function IsRecent(time)
    return time ~= nil and Ext.Timer.MonotonicTime() - time < RECENT_MS
end

local function PurgeRecent()
    for uuid, recent in pairs(recentEntries) do
        if not IsRecent(recent.Time) then
            recentEntries[uuid] = nil
        end
    end
    for uuid, time in pairs(freshContainers) do
        if not IsRecent(time) then
            freshContainers[uuid] = nil
        end
    end
end

--- Marks all items in the inventories of an entity (and in bags inside them) as known.
local function MarkInventoryKnown(entity)
    local count = 0
    ItemInfo.ForEachInventoryItem(entity, function(uuid)
        if not known[uuid] then
            known[uuid] = true
            count = count + 1
        end
    end)
    return count
end

local function ScanEntity(entity)
    local ok, result = pcall(MarkInventoryKnown, entity)
    if ok then
        return result
    end
    _PE("[LootLog] Inventory scan failed: " .. tostring(result))
    events.Add("ERROR Inventory scan failed: " .. tostring(result))
    return 0
end

--- Marks everything the party owns as known: party members, other party entities and the camp chest.
local function ScanParty(players)
    local count = 0
    for _, entity in ipairs(ItemInfo.PartyInventoryRoots(players)) do
        count = count + ScanEntity(entity)
    end
    return count
end

local function Refresh(reason)
    sessionLoaded = true
    LoadState()
    holderCache = {}

    local players = Try(function() return Osi.DB_Players:Get(nil) end) or {}
    local count = ScanParty(players)
    if #players > 0 then
        ready = true
    end

    Log(string.format("Loot Log %s. %s: %d party members, %d items marked as known, %d log entries. Logging is %s.",
        Common.ModVersion(), reason, #players, count, #LoadState().Entries, ready and "active" or "waiting for the party"))
    -- log.json shows the log of the save that is loaded now.
    logFile:Touch()
end

local function Flush()
    if #pendingOrder == 0 and #updatedEntries == 0 then
        return
    end

    local current = LoadState()
    local now = Ext.Timer.MonotonicTime()
    local batch = {}
    for _, entry in ipairs(pendingOrder) do
        local itemUuid = entry.Uuid
        local fromHolder = entry.FromHolder
        local parent = entry.Parent
        entry.FromHolder = nil
        entry.DestTop = nil
        entry.Parent = nil

        -- The contents of a skipped container are skipped too. A fresh container is a source of new loot.
        local skipReason = nil
        if parent ~= nil and parent.Skipped then
            skipReason = "inside " .. tostring(parent.Name)
        elseif fromHolder and not IsRecent(freshContainers[fromHolder]) then
            local fromKind = ClassifyHolder(fromHolder)
            if fromKind then
                skipReason = string.format("moved from %s (%s)", tostring(ItemInfo.GetObjectName(fromHolder)), fromKind)
            end
        end

        if skipReason then
            entry.Skipped = true
            if itemUuid then
                freshContainers[itemUuid] = nil
            end
            DebugPrint(string.format("SKIP %s: %s", entry.Name, skipReason))
        else
            -- The item can move on during the same tick (for example from a bag to another party member).
            if itemUuid then
                local kind, top = ClassifyHolder(itemUuid)
                if kind then
                    entry.Owner = OwnerName(kind, top)
                end
                recentEntries[itemUuid] = { Entry = entry, Time = now }
            end
            if fromHolder then
                entry.From = ItemInfo.GetObjectName(fromHolder)
            end

            entry.Id = current.NextId
            current.NextId = current.NextId + 1
            current.Entries[#current.Entries + 1] = entry
            batch[#batch + 1] = entry
        end
    end

    pendingByItem = {}
    pendingOrder = {}

    -- Entries sent earlier that changed; the client replaces entries with the same Id.
    for _, entry in ipairs(updatedEntries) do
        batch[#batch + 1] = entry
    end
    updatedEntries = {}

    if #batch == 0 then
        return
    end

    Places.Update(batch)

    if #current.Entries > Common.MaxEntries then
        local trimmed = {}
        for i = #current.Entries - Common.MaxEntries + 1, #current.Entries do
            trimmed[#trimmed + 1] = current.Entries[i]
        end
        current.Entries = trimmed
    end

    SaveState()
    Common.Channels.Entries:Broadcast({ Entries = batch })
end

--- Finds the current place of every logged item and sends the entries whose place changed.
--- Updated = true: the client only replaces entries it has; they never cause a pop-up.
local function UpdatePlaces()
    local now = Ext.Timer.MonotonicTime()
    if lastPlacesUpdate ~= nil and now - lastPlacesUpdate < PLACES_MIN_MS then
        return
    end
    lastPlacesUpdate = now

    local changed = Places.Update(LoadState().Entries)
    if #changed > 0 then
        SaveState()
        Common.Channels.Entries:Broadcast({ Entries = changed, Updated = true })
    end
end

local function OnNextTick()
    tickScheduled = false
    Flush()
    recentRemoved = {}
    holderCache = {}
    PurgeRecent()
end

ScheduleTick = function()
    if not tickScheduled then
        tickScheduled = true
        Ext.OnNextTick(Guarded("Tick", OnNextTick))
    end
end

local function QueueEntry(itemUuid, template, kind, top, fromHolder, parent)
    local entry = ItemInfo.Describe(itemUuid, template)
    entry.Owner = OwnerName(kind, top)
    -- Kept in the log: the item and its root template, to find the item (or its stack) later.
    entry.Uuid = itemUuid
    entry.Template = ItemInfo.Uuid(template)
    entry.DestTop = top
    entry.FromHolder = fromHolder
    entry.Parent = parent
    pendingByItem[itemUuid] = entry
    pendingOrder[#pendingOrder + 1] = entry
    ScheduleTick()
    return entry
end

--- Logs the items inside a container that just joined the party (for example a picked-up bag).
--- They raise no inventory events of their own. The container counts as fresh for a short time.
local function QueueContents(container, kind, top, depth)
    if depth > MAX_SCAN_DEPTH then
        return
    end

    local entity = Try(Ext.Entity.Get, container.Uuid)
    local owner = entity and Try(function() return entity.InventoryOwner end)
    if owner == nil then
        return
    end

    freshContainers[container.Uuid] = Ext.Timer.MonotonicTime()
    for _, inventory in pairs(owner.Inventories) do
        local inventoryContainer = Try(function() return inventory.InventoryContainer end)
        if inventoryContainer then
            for _, slot in pairs(inventoryContainer.Items) do
                local uuid = slot.Item and Try(function() return slot.Item.Uuid.EntityUuid end)
                if uuid and not known[uuid] then
                    known[uuid] = true
                    local entry = QueueEntry(uuid, Try(function() return Osi.GetTemplate(uuid) end), kind, top, nil, container)
                    entry.From = container.Name
                    QueueContents(entry, kind, top, depth + 1)
                end
            end
        end
    end
end

local function OnTemplateAddedTo(template, item, holder, addType)
    local itemUuid = ItemInfo.Uuid(item)
    if itemUuid == nil then
        return
    end

    if known[itemUuid] then
        -- Auto-loot "send to camp": an item that was logged a moment ago moves on to the camp chest.
        local recent = recentEntries[itemUuid]
        if recent and IsRecent(recent.Time) and recent.Entry.Owner ~= CAMP_OWNER
            and ClassifyHolder(ItemInfo.Uuid(holder)) == "camp" then
            recent.Entry.Owner = CAMP_OWNER
            updatedEntries[#updatedEntries + 1] = recent.Entry
            ScheduleTick()
        end

        if Tracker.Debug then
            DebugPrint(string.format("known item %s -> %s (addType %s)", tostring(ItemInfo.GetObjectName(itemUuid)),
                tostring(ItemInfo.GetObjectName(ItemInfo.Uuid(holder))), tostring(addType)))
        end
        return
    end

    local holderUuid = ItemInfo.Uuid(holder)
    local kind, top = ClassifyHolder(holderUuid)
    if kind == nil then
        return
    end

    known[itemUuid] = true
    if not ready then
        DebugPrint("not ready, marked as known: " .. tostring(ItemInfo.GetObjectName(itemUuid)))
        return
    end
    if IGNORED_ADD_TYPES[addType] then
        DebugPrint(string.format("ignored add type %s: %s", tostring(addType), tostring(ItemInfo.GetObjectName(itemUuid))))
        return
    end

    local entry = QueueEntry(itemUuid, template, kind, top, recentRemoved[itemUuid], nil)
    QueueContents(entry, kind, top, 1)

    if Tracker.Debug then
        DebugPrint(string.format("NEW %s x%d [%s, rarity %s/%s, value %s, stats %s] -> %s (holder %s, addType %s, from %s) %s",
            entry.Name, entry.Amount, entry.Category, tostring(entry.Rarity), tostring(entry.RarityName),
            tostring(entry.Value), tostring(entry.StatsId), entry.Owner, tostring(ItemInfo.GetObjectName(holderUuid)),
            tostring(addType), tostring(entry.FromHolder and ItemInfo.GetObjectName(entry.FromHolder)),
            ItemInfo.DebugSummary(itemUuid)))
    end
end

local function OnRemovedFrom(item, holder)
    local itemUuid = ItemInfo.Uuid(item)
    local holderUuid = ItemInfo.Uuid(holder)
    if itemUuid == nil or holderUuid == nil then
        return
    end

    local entry = pendingByItem[itemUuid]
    if entry then
        -- TemplateAddedTo came first. A later hop out of the first destination is not the source.
        if entry.FromHolder == nil and TopOwner(holderUuid) ~= entry.DestTop then
            entry.FromHolder = holderUuid
        end
        return
    end

    if known[itemUuid] or recentRemoved[itemUuid] then
        return
    end
    recentRemoved[itemUuid] = holderUuid
    ScheduleTick()
end

--- Adds one sample entry per category, to check the window without looting.
function Tracker.AddTestEntries()
    local samples = {
        { "Test Longsword +1", "Weapon", 1, 1, 120, "Longsword" },
        { "Test Legendary Longbow", "Weapon", 4, 1, 2500, "Longbow" },
        { "Test Splint Armour", "Armor", 2, 1, 600, "Heavy Armour" },
        { "Test Ring of Protection", "Jewelry", 3, 1, 900, "Ring" },
        { "Test Camp Clothes", "Clothing", 0, 1, 20, "Camp Clothes" },
        { "Test Potion of Healing", "Potion", 0, 3, 30, "Potion" },
        { "Test Scroll of Fireball", "Scroll", 2, 1, 250, "Scroll" },
        { "Test Arrow of Fire", "Ammo", 1, 5, 20, "Arrow" },
        { "Test Bread", "Food", 0, 2, 2, "Food" },
        { "Test Gold", "Gold", 0, 75, 1, "Gold" },
        { "Test Rusty Key", "Key", 0, 1, 0, "Key" },
        { "Test Mysterious Artefact", "Quest", 5, 1, 0, "Story Item" },
        { "Test Fork", "Other", 0, 1, 1, nil },
    }
    for _, sample in ipairs(samples) do
        pendingOrder[#pendingOrder + 1] = {
            Name = sample[1],
            Category = sample[2],
            Rarity = sample[3],
            Amount = sample[4],
            Value = sample[5],
            TypeName = sample[6],
            Owner = "Console",
            From = "!lootlog_test",
            Epoch = Ext.Timer.ClockEpoch(),
        }
    end
    ScheduleTick()
    Log("Added " .. #samples .. " test entries.")
end

function Tracker.Init()
    Ext.Osiris.RegisterListener("TemplateAddedTo", 4, "after", Guarded("TemplateAddedTo", OnTemplateAddedTo))
    Ext.Osiris.RegisterListener("RemovedFrom", 2, "after", Guarded("RemovedFrom", OnRemovedFrom))
    Ext.Osiris.RegisterListener("StackedWith", 2, "after", Guarded("StackedWith", function(item, other)
        Places.OnStackedWith(ItemInfo.Uuid(item), ItemInfo.Uuid(other))
    end))

    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", Guarded("LevelGameplayStarted", function()
        -- Read the log again in case the session event came before the savegame data.
        if #LoadState().Entries == 0 then
            state = nil
        end
        Refresh("Level started")
    end))

    Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", Guarded("CharacterJoinedParty", function(character)
        holderCache = {}
        local count = ScanEntity(Try(Ext.Entity.Get, ItemInfo.Uuid(character)))
        DebugPrint(string.format("%s joined the party, %d items marked as known",
            tostring(ItemInfo.GetObjectName(ItemInfo.Uuid(character))), count))
    end))

    Ext.Osiris.RegisterListener("CharacterLeftParty", 1, "after", Guarded("CharacterLeftParty", function()
        holderCache = {}
    end))

    Ext.Events.SessionLoaded:Subscribe(Guarded("SessionLoaded", function()
        Places.Reset()
        Refresh("Session loaded")
    end))

    Ext.Events.ResetCompleted:Subscribe(Guarded("ResetCompleted", function()
        Refresh("Lua reset")
    end))

    Common.Channels.History:SetRequestHandler(function()
        if not sessionLoaded then
            return { Ready = false, Entries = {} }
        end
        return { Ready = true, Entries = LoadState().Entries }
    end)

    Common.Channels.Clear:SetHandler(function()
        if not sessionLoaded then
            return
        end
        LoadState().Entries = {}
        SaveState()
        Log("Log cleared.")
    end)

    Common.Channels.Places:SetHandler(Guarded("Places", function()
        if sessionLoaded then
            UpdatePlaces()
        end
    end))

    Ext.RegisterConsoleCommand("lootlog", function()
        Common.Channels.Toggle:Broadcast({})
    end)

    Ext.RegisterConsoleCommand("lootlog_debug", function()
        Tracker.Debug = not Tracker.Debug
        Log("Debug output is " .. (Tracker.Debug and "ON" or "OFF"))
    end)

    Ext.RegisterConsoleCommand("lootlog_test", function()
        Tracker.AddTestEntries()
    end)

    Ext.RegisterConsoleCommand("lootlog_rescan", function()
        Refresh("Rescan")
    end)
end

return Tracker
