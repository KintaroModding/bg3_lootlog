-- Window settings of the local player, stored in %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\bg3_lootlog\settings.json.

local Common = Ext.Require("Shared/Common.lua")
local FileWriter = Ext.Require("Shared/FileWriter.lua")

local Settings = {}

local FILE_PATH = "bg3_lootlog/settings.json"
-- UI_Gameplay_Item_Received
local DEFAULT_CHIME = "48c6a208-8528-6bd4-8e95-2066979dc327"
-- The first default (UI_Gameplay_Coin_Removed) was silent in the game; saved settings with it get the new default.
local OLD_DEFAULT_CHIME = "a6571b9a-0b79-6712-6326-a0e3134ed0ad"

local function Defaults()
    local categories = {}
    for _, category in ipairs(Common.Categories) do
        categories[category.Id] = true
    end

    return {
        ToggleKey = "F7",
        ToggleModifier = "None",
        MinRarity = 0,
        MinValue = 0,
        -- "Use filters" above the table; off shows every entry and keeps the filter settings.
        FiltersEnabled = true,
        MaxRows = 100,
        ShowIcons = true,
        Categories = categories,
        -- Main window position and size in pixels (-1 = not stored yet), and the open state of its sections.
        WindowX = -1,
        WindowY = -1,
        WindowW = 780,
        WindowH = 480,
        FiltersOpen = true,
        OptionsOpen = false,
        -- Pop-up and chime for new loot with at least this rarity rank (1 = Uncommon).
        AlertEnabled = true,
        AlertMinRarity = 1,
        -- Pop-up position in percent of the screen (50 / 14 = top center).
        AlertX = 50,
        AlertY = 14,
        ChimeVolume = 60,
        ChimeSound = DEFAULT_CHIME,
        -- Only in the file: "server" plays the chime with PlayHUDSoundResource, "client" posts the event on the
        -- HUD sound object. VolumeRtpc scales the chime volume, with the global value ("global") or the value on
        -- the HUD sound object ("hud").
        ChimeMethod = "server",
        VolumeRtpc = "RTPC_Volume_UI",
        VolumeScope = "global",
    }
end

Settings.Values = Defaults()

--- Loads the settings file. Unknown keys and values of the wrong type are ignored.
function Settings.Load()
    local values = Defaults()

    local text = Ext.IO.LoadFile(FILE_PATH)
    if text and text ~= "" then
        local ok, saved = pcall(Ext.Json.Parse, text)
        if ok and type(saved) == "table" then
            for key, default in pairs(values) do
                local value = saved[key]
                if key == "Categories" then
                    if type(value) == "table" then
                        for id in pairs(default) do
                            if type(value[id]) == "boolean" then
                                default[id] = value[id]
                            end
                        end
                    end
                elseif value ~= nil and type(value) == type(default) then
                    values[key] = value
                end
            end
        end
    end

    if values.ChimeSound == OLD_DEFAULT_CHIME then
        values.ChimeSound = DEFAULT_CHIME
    end

    Settings.Values = values
end

-- Sliders change many times per second; the file is written at most twice per second.
local writer = FileWriter.New(FILE_PATH, 500, function()
    return Ext.Json.Stringify(Settings.Values)
end)

function Settings.Save()
    writer:Touch()
end

return Settings
