-- Reads names, categories, rarity and other details of items and characters, and walks the party inventories
-- (server side).
-- Every engine call is protected: a missing component or a destroyed entity gives a fallback value, never an error.

local Common = Ext.Require("Shared/Common.lua")

local ItemInfo = {}

local UUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"
local UNKNOWN_HANDLE = "ls::TranslatedStringRepository::s_HandleUnknown"

local JEWELRY_SLOTS = { Amulet = true, Ring = true, Ring2 = true }
local CLOTHING_SLOTS = { VanityBody = true, VanityBoots = true, Underwear = true }
local WEAPON_SLOTS = {
    MainHand = true,
    OffHand = true,
    MeleeMainHand = true,
    MeleeOffHand = true,
    RangedMainHand = true,
    RangedOffHand = true,
}
local USE_TYPE_CATEGORIES = {
    Potion = "Potion",
    Consumable = "Potion",
    Scroll = "Scroll",
    Arrow = "Ammo",
    Grenade = "Ammo",
    Throwable = "Ammo",
}

-- Item type names for the subtext ("Uncommon Cloak"), British spelling like the game.
local WEAPON_TYPE_NAMES = {
    Battleaxes = "Battleaxe", Clubs = "Club", Daggers = "Dagger", Darts = "Dart", Flails = "Flail",
    Glaives = "Glaive", Greataxes = "Greataxe", Greatclubs = "Greatclub", Greatswords = "Greatsword",
    Halberds = "Halberd", HandCrossbows = "Hand Crossbow", Handaxes = "Handaxe", HeavyCrossbows = "Heavy Crossbow",
    Javelins = "Javelin", LightCrossbows = "Light Crossbow", LightHammers = "Light Hammer", Longbows = "Longbow",
    Longswords = "Longsword", Maces = "Mace", Mauls = "Maul", Morningstars = "Morningstar", Pikes = "Pike",
    Quarterstaffs = "Quarterstaff", Rapiers = "Rapier", Scimitars = "Scimitar", Shortbows = "Shortbow",
    Shortswords = "Shortsword", Sickles = "Sickle", Slings = "Sling", Spears = "Spear", Tridents = "Trident",
    Warhammers = "Warhammer", Warpicks = "War Pick",
}
local SLOT_TYPE_NAMES = {
    Helmet = "Helmet", Gloves = "Gloves", Boots = "Boots", Cloak = "Cloak", Amulet = "Amulet",
    Ring = "Ring", Ring2 = "Ring", VanityBody = "Camp Clothes", VanityBoots = "Camp Shoes",
    Underwear = "Underwear", MusicalInstrument = "Instrument",
}
local USE_TYPE_NAMES = {
    Potion = "Potion", Scroll = "Scroll", Arrow = "Arrow", Grenade = "Grenade",
    Throwable = "Throwable", Consumable = "Consumable",
}
local TAG_FOOD = "c86e0114-a5ab-48f6-b497-de321ebff577"
local TAG_INGREDIENT = "64b824e7-50c5-475a-98c2-52026e372d77"
local CAMP_CHEST_TEMPLATE = "PlayerCampChest"
-- Bags inside bags are followed this deep.
local MAX_INVENTORY_DEPTH = 8

-- Shown instead of the camp chest's own name ("Traveller's Chest").
ItemInfo.CampChestName = "Camp chest"

--- Calls fn and returns its first result, or nil when it raises an error.
local function Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

local function NonEmpty(text)
    if type(text) == "string" and text ~= "" then
        return text
    end
    return nil
end

--- Resolves a translated string handle ("h1234...;1" or "h1234...") to text.
local function Translate(handle)
    handle = NonEmpty(handle)
    if handle == nil or handle == UNKNOWN_HANDLE then
        return nil
    end
    handle = string.gsub(handle, ";%d+$", "")
    local text = NonEmpty(Try(Ext.Loca.GetTranslatedString, handle))
    if text == nil or text == handle then
        return nil
    end
    return text
end

--- Returns the text of a TranslatedString object.
local function TranslatedText(translatedString)
    if translatedString == nil then
        return nil
    end
    return NonEmpty(Try(function() return translatedString:Get() end))
end

local function GetEntity(uuid)
    if uuid == nil then
        return nil
    end
    return Try(Ext.Entity.Get, uuid)
end

--- Returns a component of an entity, or nil when the entity or the component is missing.
local function GetComponent(entity, name)
    if entity == nil then
        return nil
    end
    return Try(function() return entity[name] end)
end

--- Returns the bare UUID of an Osiris GUIDSTRING ("Name_uuid" or "uuid").
--- @param guidString string|nil
--- @return string|nil
function ItemInfo.Uuid(guidString)
    if type(guidString) ~= "string" then
        return nil
    end
    return string.match(guidString, "(" .. UUID_PATTERN .. ")$")
end

--- Returns the name part of a "Name_uuid" template string.
--- @param templateString string|nil
--- @return string|nil
function ItemInfo.TemplateName(templateString)
    if type(templateString) ~= "string" then
        return nil
    end
    return string.match(templateString, "^(.+)_" .. UUID_PATTERN .. "$")
end

local function GetRootTemplate(templateString)
    local id = ItemInfo.Uuid(templateString)
    if id == nil then
        return nil
    end
    return Try(Ext.Template.GetRootTemplate, id)
end

--- Returns the display name of any game object (item, character or container).
--- @param uuid string|nil
--- @return string|nil
function ItemInfo.GetObjectName(uuid)
    if uuid == nil then
        return nil
    end

    local entity = GetEntity(uuid)
    local customName = GetComponent(entity, "CustomName")
    local name = customName and NonEmpty(Try(function() return customName.Name end))
    if name then
        return name
    end

    name = Translate(Try(function() return Osi.GetDisplayName(uuid) end))
    if name then
        return name
    end

    local displayName = GetComponent(entity, "DisplayName")
    if displayName then
        return TranslatedText(Try(function() return displayName.NameKey end))
            or TranslatedText(Try(function() return displayName.Name end))
    end
    return nil
end

local function GetStatsId(entity, template)
    local data = GetComponent(entity, "Data")
    local statsId = data and NonEmpty(Try(function() return data.StatsId end))
    if statsId == nil then
        local serverItem = GetComponent(entity, "ServerItem")
        statsId = serverItem and NonEmpty(Try(function() return serverItem.Stats end))
    end
    if statsId == nil and template then
        statsId = NonEmpty(Try(function() return template.Stats end))
    end
    return statsId
end

--- Returns the rarity rank (0 = Common ... 5 = Unique) and the raw rarity name.
--- The stats entry is the primary source; the numeric ValueComponent.Rarity is the fallback.
--- @return integer rank
--- @return string|nil name
function ItemInfo.GetRarity(entity, stat)
    local name
    if stat then
        local value = Try(function() return stat.Rarity end)
        if value ~= nil then
            name = tostring(value)
        end
    end

    if name == nil or Common.RarityRankByName[name] == nil then
        local valueComponent = GetComponent(entity, "Value")
        local number = valueComponent and Try(function() return valueComponent.Rarity end)
        if number ~= nil then
            name = Common.RarityNameByValue[tonumber(number)] or name
        end
    end

    return Common.RarityRankByName[name] or 0, name
end

--- Returns the category id (see Common.Categories) of an item.
function ItemInfo.GetCategory(uuid, entity, stat, templateName)
    if GetComponent(entity, "IsGold") or (templateName and string.find(templateName, "^LOOT_Gold")) then
        return "Gold"
    end

    if GetComponent(entity, "Weapon") then
        return "Weapon"
    end

    local equipable = GetComponent(entity, "Equipable")
    if equipable then
        local slot = tostring(Try(function() return equipable.Slot end) or "")
        if JEWELRY_SLOTS[slot] then
            return "Jewelry"
        elseif CLOTHING_SLOTS[slot] then
            return "Clothing"
        elseif slot == "MusicalInstrument" then
            return "Other"
        elseif WEAPON_SLOTS[slot] and not GetComponent(entity, "Armor") then
            return "Weapon"
        end
        return "Armor"
    end

    if GetComponent(entity, "Armor") then
        return "Armor"
    end

    if GetComponent(entity, "Key") then
        return "Key"
    end

    if GetComponent(entity, "IsStoryItem") or Try(function() return Osi.IsStoryItem(uuid) end) == 1 then
        return "Quest"
    end

    if GetComponent(entity, "CampSupply") then
        return "Food"
    end

    local use = GetComponent(entity, "Use")
    if use then
        local useType = tostring(Try(function() return use.ItemUseType end) or "")
        if USE_TYPE_CATEGORIES[useType] then
            return USE_TYPE_CATEGORIES[useType]
        end
    end

    -- Items without live components (for example a stack that was merged) fall back to their stats type.
    local modifierList = stat and Try(function() return stat.ModifierList end)
    if modifierList == "Weapon" then
        return "Weapon"
    elseif modifierList == "Armor" then
        return "Armor"
    end

    return "Other"
end

--- Returns the set of flag names of a stats flags property (a bitfield, a list or a ";"-separated string).
local function FlagSet(value)
    local set = {}
    if type(value) == "string" then
        for part in string.gmatch(value, "[^;,%s]+") do
            set[part] = true
        end
    elseif value ~= nil then
        pcall(function()
            for key, item in pairs(value) do
                if type(item) == "string" then
                    set[item] = true
                elseif type(key) == "string" and item == true then
                    set[key] = true
                end
            end
        end)
    end
    return set
end

--- Splits a CamelCase word into words ("MusicalInstrument" -> "Musical Instrument").
local function SplitWords(text)
    return (string.gsub(text, "(%l)(%u)", "%1 %2"))
end

--- Returns the item type for the subtext ("Cloak", "Longsword", "Light Armour", "Potion", ...), or nil.
--- @param category string Category id from ItemInfo.GetCategory
function ItemInfo.GetTypeName(uuid, entity, stat, category)
    local proficiency = FlagSet(stat and Try(function() return stat["Proficiency Group"] end))
    local equipable = GetComponent(entity, "Equipable")
    local slot = equipable and tostring(Try(function() return equipable.Slot end) or "") or ""
    if slot == "" and stat then
        slot = tostring(Try(function() return stat.Slot end) or "")
    end

    if category == "Weapon" then
        for flag, name in pairs(WEAPON_TYPE_NAMES) do
            if proficiency[flag] then
                return name
            end
        end
        return "Weapon"
    end

    if category == "Armor" or category == "Jewelry" or category == "Clothing" or slot == "MusicalInstrument" then
        local armor = GetComponent(entity, "Armor")
        if proficiency.Shields or (armor and Try(function() return armor.Shield end) == true) then
            return "Shield"
        end
        if SLOT_TYPE_NAMES[slot] then
            return SLOT_TYPE_NAMES[slot]
        end
        if proficiency.HeavyArmor then
            return "Heavy Armour"
        elseif proficiency.MediumArmor then
            return "Medium Armour"
        elseif proficiency.LightArmor then
            return "Light Armour"
        end
        return "Clothing"
    end

    if category == "Gold" then
        return "Gold"
    elseif category == "Key" then
        return "Key"
    elseif category == "Quest" then
        return "Story Item"
    elseif category == "Food" then
        return Try(function() return Osi.IsTagged(uuid, TAG_FOOD) end) == 1 and "Food" or "Camp Supplies"
    end

    local use = GetComponent(entity, "Use")
    local useType = use and tostring(Try(function() return use.ItemUseType end) or "")
    if useType and USE_TYPE_NAMES[useType] then
        return USE_TYPE_NAMES[useType]
    end

    if Try(function() return Osi.GetBookID(uuid) end) ~= nil then
        return "Book"
    end
    if Try(function() return Osi.IsTagged(uuid, TAG_INGREDIENT) end) == 1 then
        return "Ingredient"
    end

    -- The stats category, when it is a plain word ("Junk", "Valuable", ...).
    local objectCategory = stat and Try(function() return stat.ObjectCategory end)
    if type(objectCategory) == "string" and string.match(objectCategory, "^%a+$") and #objectCategory <= 24 then
        return SplitWords(objectCategory)
    end
    return nil
end

--- Returns the number of items in this stack.
function ItemInfo.GetAmount(uuid)
    local ok, exact = pcall(function() return Osi.GetStackAmount(uuid) end)
    if ok and type(exact) == "number" and exact > 0 then
        return math.floor(exact)
    end
    return 1
end

--- Builds a log entry for an item.
--- @param uuid string Bare item UUID
--- @param templateString string|nil "Name_uuid" root template from the Osiris event
--- @return table entry
function ItemInfo.Describe(uuid, templateString)
    local entity = GetEntity(uuid)
    local template = GetRootTemplate(templateString)
    local templateName = ItemInfo.TemplateName(templateString)
    local statsId = GetStatsId(entity, template)
    local stat = statsId and Try(Ext.Stats.Get, statsId) or nil
    local rarity, rarityName = ItemInfo.GetRarity(entity, stat)
    local value = GetComponent(entity, "Value")
    local icon = GetComponent(entity, "Icon")
    local category = ItemInfo.GetCategory(uuid, entity, stat, templateName)

    return {
        Name = ItemInfo.GetObjectName(uuid)
            or (template and TranslatedText(Try(function() return template.DisplayName end)))
            or templateName
            or "Unknown item",
        Category = category,
        TypeName = ItemInfo.GetTypeName(uuid, entity, stat, category),
        Rarity = rarity,
        RarityName = rarityName,
        Amount = ItemInfo.GetAmount(uuid),
        Value = value and Try(function() return value.Value end) or nil,
        Icon = (icon and NonEmpty(Try(function() return icon.Icon end)))
            or (template and NonEmpty(Try(function() return template.Icon end))),
        StatsId = statsId,
        Epoch = Ext.Timer.ClockEpoch(),
    }
end

--- True for a party member: a player character or a companion in the party.
--- @param uuid string
--- @return boolean
function ItemInfo.IsPartyCharacter(uuid)
    if Try(function() return Osi.IsCharacter(uuid) end) ~= 1 then
        return false
    end
    return Try(function() return Osi.IsPlayer(uuid) end) == 1
        or Try(function() return Osi.IsPartyMember(uuid, 0) end) == 1
end

--- True for the camp chest: by its component, or by its template name when the component is missing.
--- @param uuid string
--- @return boolean
function ItemInfo.IsCampChest(uuid)
    if GetComponent(GetEntity(uuid), "CampChest") then
        return true
    end
    local template = Try(function() return Osi.GetTemplate(uuid) end)
    return type(template) == "string" and string.find(template, CAMP_CHEST_TEMPLATE, 1, true) ~= nil
end

--- Calls visit(uuid, entity) for every item in the inventories of an entity, also for items in bags inside them.
--- Errors of the engine API are not caught here; callers protect the call.
--- @param entity any Entity with an InventoryOwner component
--- @param visit fun(uuid: string, entity: any)
function ItemInfo.ForEachInventoryItem(entity, visit, depth)
    depth = depth or 0
    if entity == nil or depth > MAX_INVENTORY_DEPTH then
        return
    end

    local owner = GetComponent(entity, "InventoryOwner")
    if owner == nil then
        return
    end

    for _, inventory in pairs(owner.Inventories) do
        local container = GetComponent(inventory, "InventoryContainer")
        if container then
            for _, slot in pairs(container.Items) do
                local item = slot.Item
                if item then
                    local uuid = Try(function() return item.Uuid.EntityUuid end)
                    if uuid then
                        visit(uuid, item)
                    end
                    ItemInfo.ForEachInventoryItem(item, visit, depth + 1)
                end
            end
        end
    end
end

--- Returns the entities that hold the party's items: party members and camp chests, each once.
--- @param players table|nil Rows of Osi.DB_Players; read from Osiris when nil
--- @return table entities
function ItemInfo.PartyInventoryRoots(players)
    local roots = {}
    local seen = {}
    local function Add(entity)
        if entity == nil then
            return
        end
        local uuid = Try(function() return entity.Uuid.EntityUuid end)
        if uuid == nil or not seen[uuid] then
            if uuid then
                seen[uuid] = true
            end
            roots[#roots + 1] = entity
        end
    end

    for _, row in pairs(players or Try(function() return Osi.DB_Players:Get(nil) end) or {}) do
        Add(GetEntity(ItemInfo.Uuid(row[1])))
    end
    for _, entity in pairs(Try(Ext.Entity.GetAllEntitiesWithComponent, "PartyMember") or {}) do
        Add(entity)
    end
    for _, entity in pairs(Try(Ext.Entity.GetAllEntitiesWithComponent, "CampChest") or {}) do
        Add(entity)
    end
    return roots
end

--- Returns a one-line summary of the raw item data, for the debug output.
function ItemInfo.DebugSummary(uuid)
    local entity = GetEntity(uuid)
    local value = GetComponent(entity, "Value")
    local serverItem = GetComponent(entity, "ServerItem")
    local history = GetComponent(entity, "ServerOwneeHistory")

    local function EntityName(handle)
        if handle == nil then
            return "-"
        end
        local id = Try(function() return handle.Uuid.EntityUuid end)
        return (id and ItemInfo.GetObjectName(id)) or tostring(handle)
    end

    return string.format(
        "valueRarity=%s itemType=%s storyItem=%s originalOwner=%s history(original=%s previous=%s latest=%s)",
        tostring(value and Try(function() return value.Rarity end)),
        tostring(serverItem and Try(function() return serverItem.ItemType end)),
        tostring(serverItem and Try(function() return serverItem.StoryItem end)),
        tostring(ItemInfo.GetObjectName(ItemInfo.Uuid(Try(function() return Osi.GetOriginalOwner(uuid) end)))),
        EntityName(history and Try(function() return history.OriginalOwner end)),
        EntityName(history and Try(function() return history.PreviousOwner end)),
        EntityName(history and Try(function() return history.LatestOwner end))
    )
end

return ItemInfo
