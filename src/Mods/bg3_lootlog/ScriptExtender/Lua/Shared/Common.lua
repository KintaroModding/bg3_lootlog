-- Constants, helpers, persistent variables and network channels shared by the server and client contexts.

local Common = {}

--- Returns the version of this mod from its meta.lsx, for example "1.0.0.0".
function Common.ModVersion()
    local ok, version = pcall(function() return Ext.Mod.GetMod(ModuleUUID).Info.ModVersion end)
    if not ok or version == nil then
        return "?"
    end
    return table.concat({ tostring(version[1]), tostring(version[2]), tostring(version[3]), tostring(version[4]) }, ".")
end

-- Maximum number of entries kept in the savegame and shown in the window.
Common.MaxEntries = 500

-- Item categories in display order. The Id is stored in log entries.
Common.Categories = {
    { Id = "Weapon",   Label = "Weapons" },
    { Id = "Armor",    Label = "Armor" },
    { Id = "Jewelry",  Label = "Jewelry" },
    { Id = "Clothing", Label = "Clothing" },
    { Id = "Potion",   Label = "Potions" },
    { Id = "Scroll",   Label = "Scrolls" },
    { Id = "Ammo",     Label = "Ammo" },
    { Id = "Food",     Label = "Food" },
    { Id = "Gold",     Label = "Gold" },
    { Id = "Key",      Label = "Keys" },
    { Id = "Quest",    Label = "Quest" },
    { Id = "Other",    Label = "Other" },
}

Common.CategoryLabels = {}
for _, category in ipairs(Common.Categories) do
    Common.CategoryLabels[category.Id] = category.Label
end

-- Categories enabled by the "Gear only" quick filter.
Common.GearCategories = { Weapon = true, Armor = true, Jewelry = true }

-- Rarity ranks used for filtering and colors. Index = rank + 1.
Common.Rarities = {
    { Label = "Common",    Color = { 0.86, 0.86, 0.86, 1.0 } },
    { Label = "Uncommon",  Color = { 0.35, 0.85, 0.35, 1.0 } },
    { Label = "Rare",      Color = { 0.35, 0.62, 1.00, 1.0 } },
    { Label = "Very Rare", Color = { 0.77, 0.47, 1.00, 1.0 } },
    { Label = "Legendary", Color = { 1.00, 0.76, 0.27, 1.0 } },
    { Label = "Unique",    Color = { 1.00, 0.54, 0.22, 1.0 } },
}

--- Returns the subtext of an entry like the game's tooltip, for example "Uncommon Cloak".
--- @param entry table Log entry
--- @return string
function Common.Subtext(entry)
    local rarity = Common.Rarities[(entry.Rarity or 0) + 1] or Common.Rarities[1]
    if type(entry.TypeName) == "string" and entry.TypeName ~= "" then
        return rarity.Label .. " " .. entry.TypeName
    end
    return rarity.Label
end

-- Rarity names used by stats entries and engine enums, mapped to a rank.
Common.RarityRankByName = {
    Common = 0,
    Sentinel = 0,
    Uncommon = 1,
    Rare = 2,
    VeryRare = 3,
    ["Very Rare"] = 3,
    Epic = 3,
    Legendary = 4,
    Unique = 5,
    Divine = 5,
    Story = 5,
}

-- ItemDataRarity enum order, used for the numeric ValueComponent.Rarity field.
Common.RarityNameByValue = {
    [0] = "Common",
    [1] = "Unique",
    [2] = "Uncommon",
    [3] = "Rare",
    [4] = "VeryRare",
    [5] = "Legendary",
    [6] = "Divine",
    [7] = "Sentinel",
}

-- The log lives in the savegame. Only the server reads or writes it; the client asks for it over the History channel.
-- Variables must be registered with the same settings in both contexts.
Ext.Vars.RegisterModVariable(ModuleUUID, "Log", {
    Server = true,
    Client = false,
    WriteableOnServer = true,
    WriteableOnClient = false,
    Persistent = true,
    SyncToClient = false,
    SyncToServer = false,
})

Common.Channels = {
    -- Server -> client: entries logged during the last tick ({ Entries = { ... } }), or entries whose place changed
    -- ({ Entries = { ... }, Updated = true }).
    Entries = Ext.Net.CreateChannel(ModuleUUID, "Entries"),
    -- Client -> server request: the full log of the current savegame.
    History = Ext.Net.CreateChannel(ModuleUUID, "History"),
    -- Client -> server: remove all entries.
    Clear = Ext.Net.CreateChannel(ModuleUUID, "Clear"),
    -- Server -> client: show or hide the window (console command).
    Toggle = Ext.Net.CreateChannel(ModuleUUID, "Toggle"),
    -- Client -> server: play a HUD sound resource for the character of this client ({ Sound = id, Log = bool }).
    Chime = Ext.Net.CreateChannel(ModuleUUID, "Chime"),
    -- Client -> server: find where the logged items are now. Changed entries come back on the Entries channel.
    Places = Ext.Net.CreateChannel(ModuleUUID, "Places"),
}

return Common
