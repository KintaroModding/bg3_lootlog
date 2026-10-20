-- Finds where logged items are now (server side).
--
-- An entry stores its place in Where, for example "Karlach > Pouch", "Gale (equipped)" or "Camp chest > Scroll Case",
-- and in WhereState:
--   "party"  with a party member, also in a bag (top-level holder is a party member)
--   "camp"   in the camp chest
--   "other"  in another inventory: a trader, another character, a container in the world
--   "ground" lying in the world
--   "gone"   no longer in the game: sold to Loot Autoseller, used up or destroyed. This state is final.
--
-- Stackable items (potions, arrows, gold) can merge into another stack of the same item; one of the two items is
-- then destroyed. Osiris reports the merge with StackedWith. Without that event, an item with the same template in
-- the party inventories counts as the stack.

local ItemInfo = Ext.Require("Server/ItemInfo.lua")

local Places = {}

local SEPARATOR = " > "
-- Bags inside bags are followed this deep.
local MAX_DEPTH = 8

-- [itemUuid] = itemUuid: the other item of a StackedWith event, stored in both directions. When an item no longer
-- exists, the other item holds its stack.
local stackedWith = {}

--- Calls fn and returns its first result, or nil when it raises an error.
local function Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

local function Exists(uuid)
    return Try(function() return Osi.Exists(uuid) end) == 1
end

--- Forgets the stack merges of the last session (a new savegame was loaded).
function Places.Reset()
    stackedWith = {}
end

--- Osiris StackedWith(item, stackedWithItem): one of the two items merged into the other.
--- @param item string|nil Bare UUID
--- @param other string|nil Bare UUID
function Places.OnStackedWith(item, other)
    if item and other and item ~= other then
        stackedWith[item] = other
        stackedWith[other] = item
    end
end

--- Returns the item that holds the stack of uuid now: uuid itself, or an item it merged into. Nil when gone.
local function Resolve(uuid)
    local seen = {}
    local current = uuid
    while current ~= nil and not seen[current] do
        if Exists(current) then
            return current
        end
        seen[current] = true
        current = stackedWith[current]
    end
    return nil
end

--- Caches for one update: many items share the same bags and characters.
local function NewContext()
    return { Parents = {}, Names = {}, States = {}, Index = nil }
end

--- Returns the direct inventory holder (a character or a container), or nil when the object is not in an inventory.
local function Parent(context, uuid)
    local parent = context.Parents[uuid]
    if parent == nil then
        parent = ItemInfo.Uuid(Try(function() return Osi.GetDirectInventoryOwner(uuid) end)) or false
        context.Parents[uuid] = parent
    end
    return parent or nil
end

local function Name(context, uuid)
    local name = context.Names[uuid]
    if name == nil then
        name = ItemInfo.GetObjectName(uuid) or "?"
        context.Names[uuid] = name
    end
    return name
end

--- Returns "party", "camp" or "other" for a top-level inventory holder.
local function HolderState(context, top)
    local state = context.States[top]
    if state == nil then
        if ItemInfo.IsPartyCharacter(top) then
            state = "party"
        elseif ItemInfo.IsCampChest(top) then
            state = "camp"
        else
            state = "other"
        end
        context.States[top] = state
    end
    return state
end

--- Returns the place of an existing item: the text and the state.
local function Describe(context, uuid)
    -- Holders from the direct holder up to the top-level holder.
    local holders = {}
    local seen = { [uuid] = true }
    local current = uuid
    for _ = 1, MAX_DEPTH do
        local parent = Parent(context, current)
        if parent == nil or seen[parent] then
            break
        end
        seen[parent] = true
        holders[#holders + 1] = parent
        current = parent
    end

    if #holders == 0 then
        return "On the ground", "ground"
    end

    local state = HolderState(context, holders[#holders])
    local parts = {}
    for i = #holders, 1, -1 do
        if i == #holders and state == "camp" then
            parts[#parts + 1] = ItemInfo.CampChestName
        else
            parts[#parts + 1] = Name(context, holders[i])
        end
    end

    local text = table.concat(parts, SEPARATOR)
    if #holders == 1 and state ~= "camp" and Try(function() return Osi.IsEquipped(uuid) end) == 1 then
        text = text .. " (equipped)"
    end
    return text, state
end

--- Returns a party item with this root template (bare UUID), or nil. The index is built once per update.
local function FindByTemplate(context, templateId)
    if context.Index == nil then
        local index = {}
        for _, root in ipairs(ItemInfo.PartyInventoryRoots()) do
            pcall(ItemInfo.ForEachInventoryItem, root, function(uuid)
                local id = ItemInfo.Uuid(Try(function() return Osi.GetTemplate(uuid) end))
                if id and index[id] == nil then
                    index[id] = uuid
                end
            end)
        end
        context.Index = index
    end
    return context.Index[templateId]
end

local function Locate(context, entry)
    local uuid = Resolve(entry.Uuid)
    if uuid == nil and type(entry.Template) == "string" then
        uuid = FindByTemplate(context, entry.Template)
        if uuid then
            -- The next update finds the stack directly.
            stackedWith[entry.Uuid] = uuid
        end
    end

    if uuid == nil then
        return "Gone", "gone"
    end
    return Describe(context, uuid)
end

--- Finds the current place of every entry with an item. Entries without an item (logged before version 1.0.0.3,
--- and test entries) and gone items are skipped.
--- @param entries table[] Log entries; Where and WhereState are updated in place
--- @return table[] changed The entries whose place changed
function Places.Update(entries)
    local context = NewContext()
    local changed = {}
    for _, entry in ipairs(entries) do
        if type(entry.Uuid) == "string" and entry.WhereState ~= "gone" then
            local text, state = Locate(context, entry)
            if text ~= entry.Where or state ~= entry.WhereState then
                entry.Where = text
                entry.WhereState = state
                changed[#changed + 1] = entry
            end
        end
    end
    return changed
end

return Places
