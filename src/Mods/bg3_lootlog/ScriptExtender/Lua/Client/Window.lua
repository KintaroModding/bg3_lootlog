-- The Loot Log window (Script Extender IMGUI). Lists the log with filters; a hotkey shows and hides it.

local Common = Ext.Require("Shared/Common.lua")
local LogFilter = Ext.Require("Shared/LogFilter.lua")
local Alert = Ext.Require("Client/Alert.lua")
local ClientLog = Ext.Require("Client/ClientLog.lua")
local Settings = Ext.Require("Client/Settings.lua")

local Window = {}

-- Keys without a default game binding. INSERT is left out because Mod Configuration Menu uses it.
local TOGGLE_KEYS = { "F6", "F7", "F9", "F10", "F11", "END", "SCROLLLOCK", "PAUSE" }
local TOGGLE_MODIFIERS = { "None", "Ctrl", "Shift", "Alt" }
local RARITY_OPTIONS = { "Any rarity", "Uncommon+", "Rare+", "Very Rare+", "Legendary+" }
-- Index = minimum rarity rank for the pop-up and the chime.
local ALERT_RARITY_OPTIONS = { "Uncommon+", "Rare+", "Very Rare+", "Legendary+" }
local VALUE_OPTIONS = { 0, 10, 25, 50, 100, 250, 500, 1000 }
local ROW_OPTIONS = { 50, 100, 200, 500 }
local COLUMNS = {
    { Name = "Age",    Flags = "WidthFixed",   Width = 42 },
    { Name = "Item",   Flags = "WidthStretch", Width = 3 },
    { Name = "Type",   Flags = "WidthFixed",   Width = 70 },
    { Name = "Rarity", Flags = "WidthFixed",   Width = 80 },
    { Name = "Qty",    Flags = "WidthFixed",   Width = 36 },
    { Name = "Value",  Flags = "WidthFixed",   Width = 48 },
    { Name = "Who",    Flags = "WidthFixed",   Width = 100 },
    { Name = "Where",  Flags = "WidthStretch", Width = 2 },
    { Name = "From",   Flags = "WidthStretch", Width = 1.5 },
}
local ICON_SIZE = { 20, 20 }
local SUBTEXT_COLOR = { 0.62, 0.62, 0.62, 1.0 }
-- Places outside the party ("Arron", "On the ground", "Gone") are shown in gray.
local AWAY_STATES = { other = true, ground = true, gone = true }
local AGE_REFRESH_MS = 5000
-- While the window is shown, the server is asked this often where the logged items are now.
local PLACES_REFRESH_MS = 2000
-- While the window is shown, its position and size are checked this often and stored when they changed.
local PLACEMENT_SAVE_MS = 2000
-- A restored window keeps at least this many pixels on the screen (after a resolution change).
local MIN_ON_SCREEN = 120
local HISTORY_RETRY_MS = 3000

-- Log entries of the current savegame, oldest first.
local entries = {}
local entryIds = {}
-- "none": not requested yet, "pending": waiting for the server, "done": entries hold the full history.
local historyState = "none"
-- The search text is not saved; an old search would hide new loot after a restart.
local search = ""

local window = nil
local ui = {}
local dirty = true
local rebuildScheduled = false
-- { Element = text, Epoch = seconds } for every visible row, to refresh the "Age" column.
local ageLabels = {}
local lastAgeRefresh = 0
local lastPlacementCheck = 0
-- [entryId] = { Element = text, Away = bool } for every visible row, to change the "Where" column in place.
local placeLabels = {}
local lastPlacesRequest = nil

--- Wraps a callback so that an error is printed instead of breaking the UI.
local function Guarded(name, fn)
    return function(...)
        local ok, err = xpcall(fn, debug.traceback, ...)
        if not ok then
            _PE("[LootLog] " .. name .. " failed: " .. tostring(err))
            ClientLog.Add("ERROR " .. name .. " failed: " .. tostring(err))
        end
    end
end

local function IndexOf(list, value)
    for i, item in ipairs(list) do
        if item == value then
            return i
        end
    end
    return nil
end

local function Rarity(rank)
    return Common.Rarities[(rank or 0) + 1] or Common.Rarities[1]
end

local function IsShown()
    return window ~= nil and window.Open == true and window.Visible == true
end

--- The filter for the table. With "Use filters" off, every entry passes; the filter settings stay unchanged.
local function CurrentFilter()
    if not Settings.Values.FiltersEnabled then
        return { Categories = {}, MinRarity = 0, MinValue = 0, Search = "" }
    end
    return {
        Categories = Settings.Values.Categories,
        MinRarity = Settings.Values.MinRarity,
        MinValue = Settings.Values.MinValue,
        Search = search,
    }
end

local function UpdateAges()
    local now = Ext.Timer.ClockEpoch()
    for _, label in ipairs(ageLabels) do
        label.Element.Label = LogFilter.FormatAge(now - label.Epoch)
    end
    lastAgeRefresh = Ext.Timer.MonotonicTime()
end

local function AddEntryRow(tbl, entry, now)
    local rarity = Rarity(entry.Rarity)
    local row = tbl:AddRow()

    local epoch = entry.Epoch or now
    local age = row:AddCell():AddText(LogFilter.FormatAge(now - epoch))
    ageLabels[#ageLabels + 1] = { Element = age, Epoch = epoch }

    local itemCell = row:AddCell()
    local hasIcon = false
    if Settings.Values.ShowIcons and entry.Icon then
        hasIcon = pcall(function() itemCell:AddImage(entry.Icon, ICON_SIZE) end)
    end
    local name = itemCell:AddText(entry.Name or "?")
    name.SameLine = hasIcon
    name:SetColor("Text", rarity.Color)
    local subtext = itemCell:AddText(Common.Subtext(entry))
    subtext.SameLine = true
    subtext:SetColor("Text", SUBTEXT_COLOR)

    row:AddCell():AddText(Common.CategoryLabels[entry.Category] or tostring(entry.Category))
    local rarityText = row:AddCell():AddText(rarity.Label)
    rarityText:SetColor("Text", rarity.Color)
    row:AddCell():AddText(tostring(entry.Amount or 1))
    row:AddCell():AddText(entry.Value and tostring(entry.Value) or "")
    row:AddCell():AddText(entry.Owner or "")

    local where = row:AddCell():AddText(entry.Where or "")
    local away = AWAY_STATES[entry.WhereState] == true
    if away then
        where:SetColor("Text", SUBTEXT_COLOR)
    end
    if entry.Id ~= nil then
        placeLabels[entry.Id] = { Element = where, Away = away }
    end

    row:AddCell():AddText(entry.From or "")
end

--- Recreates the table with the entries that pass the current filter.
local function Rebuild()
    dirty = false
    if window == nil then
        return
    end

    if ui.Table then
        ui.Table:Destroy()
        ui.Table = nil
    end
    ageLabels = {}
    placeLabels = {}

    local rows, matches = LogFilter.Collect(entries, CurrentFilter(), Settings.Values.MaxRows)
    if historyState == "pending" then
        ui.Status.Label = "Loading the log..."
    elseif #entries == 0 then
        ui.Status.Label = "No loot logged in this save yet. New items appear here when they join your inventory."
    elseif not Settings.Values.FiltersEnabled then
        ui.Status.Label = string.format("Filters off: showing %d of %d logged entries.", #rows, #entries)
    else
        ui.Status.Label = string.format("Showing %d of %d matching entries (%d logged).", #rows, matches, #entries)
    end

    local tbl = ui.TableHost:AddTable("LootLogEntries", #COLUMNS)
    tbl.ScrollY = true
    tbl.FreezeRows = 1
    tbl.RowBg = true
    tbl.BordersInnerV = true
    tbl.Resizable = true
    tbl.ShowHeader = true
    for _, column in ipairs(COLUMNS) do
        tbl:AddColumn(column.Name, column.Flags, column.Width)
    end

    local now = Ext.Timer.ClockEpoch()
    for _, entry in ipairs(rows) do
        AddEntryRow(tbl, entry, now)
    end

    ui.Table = tbl
    lastAgeRefresh = Ext.Timer.MonotonicTime()
end

--- Rebuilds the table on the next tick. Several changes in one tick cause one rebuild.
local function MarkDirty()
    dirty = true
    if rebuildScheduled or not IsShown() then
        return
    end
    rebuildScheduled = true
    Ext.OnNextTick(Guarded("Rebuild", function()
        rebuildScheduled = false
        if dirty and IsShown() then
            Rebuild()
        end
    end))
end

--- True when any filter hides entries (a type unchecked, a minimum rarity or value, or a search text).
local function FiltersActive()
    local values = Settings.Values
    if search ~= "" or (values.MinRarity or 0) > 0 or (values.MinValue or 0) > 0 then
        return true
    end
    for _, category in ipairs(Common.Categories) do
        if values.Categories[category.Id] == false then
            return true
        end
    end
    return false
end

--- Shows "(active)" or "(off)" in the Filters header, so a closed section does not hide the filter state.
--- The text after ### is the fixed IMGUI id, so the open state stays when the label changes.
local function UpdateFiltersLabel()
    if ui.Filters then
        local label = "Filters"
        if not Settings.Values.FiltersEnabled then
            label = "Filters (off)"
        elseif FiltersActive() then
            label = "Filters (active)"
        end
        ui.Filters.Label = label .. "###LootLogFilters"
    end
end

local function OnFilterChanged()
    Settings.Save()
    UpdateFiltersLabel()
    MarkDirty()
end

local function SetCategories(isEnabled)
    for _, category in ipairs(Common.Categories) do
        local enabled = isEnabled(category.Id)
        Settings.Values.Categories[category.Id] = enabled
        if ui.Categories and ui.Categories[category.Id] then
            ui.Categories[category.Id].Checked = enabled
        end
    end
    OnFilterChanged()
end

local function SetEntries(list)
    entries = {}
    entryIds = {}
    for _, entry in ipairs(list) do
        entries[#entries + 1] = entry
        if entry.Id then
            entryIds[entry.Id] = true
        end
    end
end

local function RequestHistory()
    if historyState ~= "none" then
        return
    end
    historyState = "pending"
    Common.Channels.History:RequestToServer({}, Guarded("History reply", function(reply)
        if type(reply) == "table" and reply.Ready and type(reply.Entries) == "table" then
            SetEntries(reply.Entries)
            historyState = "done"
        else
            -- The server is still loading the savegame.
            historyState = "none"
            if IsShown() then
                Ext.Timer.WaitForRealtime(HISTORY_RETRY_MS, Guarded("History retry", RequestHistory))
            end
        end
        MarkDirty()
    end))
end

--- Replaces the entry with the same Id. Returns false when this client does not have it.
local function ReplaceEntry(entry)
    if entry.Id == nil or not entryIds[entry.Id] then
        return false
    end
    for i = #entries, 1, -1 do
        if entries[i].Id == entry.Id then
            entries[i] = entry
            break
        end
    end
    return true
end

--- Entries whose place changed. A visible "Where" cell changes in place; the table is only rebuilt when the
--- color changes (party / away) or a search may match the new place. Unknown entries are ignored.
local function OnPlacesUpdated(list)
    local searching = Settings.Values.FiltersEnabled and search ~= ""
    local rebuild = false
    for _, entry in ipairs(list) do
        if ReplaceEntry(entry) then
            local label = placeLabels[entry.Id]
            if searching then
                rebuild = true
            elseif label then
                if label.Away == (AWAY_STATES[entry.WhereState] == true) then
                    label.Element.Label = entry.Where or ""
                else
                    rebuild = true
                end
            end
        end
    end
    if rebuild then
        MarkDirty()
    end
end

local function OnEntries(data)
    if type(data) ~= "table" or type(data.Entries) ~= "table" then
        return
    end
    if data.Updated then
        OnPlacesUpdated(data.Entries)
        return
    end

    -- New entries that are rare enough for the pop-up and the chime.
    local notable = {}
    for _, entry in ipairs(data.Entries) do
        -- An entry that was sent before can change (for example its owner); it replaces the old one.
        if not ReplaceEntry(entry) then
            entries[#entries + 1] = entry
            if entry.Id then
                entryIds[entry.Id] = true
            end
            if (entry.Rarity or 0) >= Settings.Values.AlertMinRarity then
                notable[#notable + 1] = entry
            end
        end
    end

    while #entries > Common.MaxEntries do
        local removed = table.remove(entries, 1)
        if removed.Id then
            entryIds[removed.Id] = nil
        end
    end

    if #notable > 0 then
        if Settings.Values.AlertEnabled then
            Alert.Show(notable)
        end
        Alert.Chime(false)
    end

    MarkDirty()
end

local function ClearLog()
    SetEntries({})
    Common.Channels.Clear:SendToServer({})
    MarkDirty()
end

--- Adds a combo box. onChange receives the 1-based index of the selected option.
local function AddCombo(parent, label, options, selectedIndex, width, onChange)
    local combo = parent:AddCombo(label)
    combo.Options = options
    combo.SelectedIndex = math.max(0, math.min(#options - 1, selectedIndex))
    combo.ItemWidth = width
    combo.OnChange = Guarded(label, function(element)
        onChange(element.SelectedIndex + 1)
    end)
    return combo
end

--- Adds a collapsing section (a tree in collapsing header style, which reports open and close) whose open state
--- is stored in Settings.Values[settingKey].
local function AddSection(parent, label, settingKey)
    local section = parent:AddTree(label)
    section.CollapsingHeader = true
    section.DefaultOpen = Settings.Values[settingKey]
    section:SetOpen(Settings.Values[settingKey], "Always")
    section.OnExpand = Guarded(settingKey .. " open", function()
        Settings.Values[settingKey] = true
        Settings.Save()
    end)
    section.OnCollapse = Guarded(settingKey .. " close", function()
        Settings.Values[settingKey] = false
        Settings.Save()
    end)
    return section
end

--- Stores the window position and size in the settings when they changed (the game reports them every frame).
local function SaveWindowPlacement()
    if window == nil then
        return
    end
    local position = window.LastPosition
    local size = window.LastSize
    if type(position) ~= "table" or type(size) ~= "table" or (size[1] or 0) <= 0 or (size[2] or 0) <= 0 then
        return
    end

    local values = Settings.Values
    local x, y = math.floor(position[1] + 0.5), math.floor(position[2] + 0.5)
    local w, h = math.floor(size[1] + 0.5), math.floor(size[2] + 0.5)
    if x ~= values.WindowX or y ~= values.WindowY or w ~= values.WindowW or h ~= values.WindowH then
        values.WindowX, values.WindowY, values.WindowW, values.WindowH = x, y, w, h
        Settings.Save()
    end
end

--- Applies the stored position and size once; a part of the window always stays on the screen.
local function RestoreWindowPlacement()
    local values = Settings.Values
    window:SetSize({ math.max(values.WindowW, 300), math.max(values.WindowH, 200) }, "Always")
    if values.WindowX < 0 or values.WindowY < 0 then
        return
    end

    local x, y = values.WindowX, values.WindowY
    local ok, screen = pcall(Ext.IMGUI.GetViewportSize)
    if ok and type(screen) == "table" and screen[1] then
        x = math.min(x, math.max(0, screen[1] - MIN_ON_SCREEN))
        y = math.min(y, math.max(0, screen[2] - MIN_ON_SCREEN))
    end
    window:SetPos({ x, y }, "Always")
end

local function CreateWindow()
    window = Ext.IMGUI.NewWindow("Loot Log")
    window.Closeable = true
    window.Open = false
    window.Visible = false
    -- Sizes in real pixels, so a stored size is restored exactly.
    window.Scaling = "Absolute"
    RestoreWindowPlacement()
    window.OnClose = Guarded("OnClose", function()
        window.Visible = false
        SaveWindowPlacement()
    end)

    -- Filters
    local filters = AddSection(window, "Filters###LootLogFilters", "FiltersOpen")
    ui.Filters = filters

    local searchBox = filters:AddInputText("Search", search)
    searchBox.Hint = "item, type, who, where or from"
    searchBox.ItemWidth = 180
    searchBox.OnChange = Guarded("Search", function(element)
        search = element.Text or ""
        UpdateFiltersLabel()
        MarkDirty()
    end)

    local rarity = AddCombo(filters, "Rarity", RARITY_OPTIONS, Settings.Values.MinRarity, 120, function(index)
        Settings.Values.MinRarity = index - 1
        OnFilterChanged()
    end)
    rarity.SameLine = true

    local valueLabels = {}
    for i, value in ipairs(VALUE_OPTIONS) do
        valueLabels[i] = value == 0 and "Any value" or (value .. "+ gold")
    end
    local valueIndex = (IndexOf(VALUE_OPTIONS, Settings.Values.MinValue) or 1) - 1
    local value = AddCombo(filters, "Value", valueLabels, valueIndex, 110, function(index)
        Settings.Values.MinValue = VALUE_OPTIONS[index] or 0
        OnFilterChanged()
    end)
    value.SameLine = true

    ui.Categories = {}
    for i, category in ipairs(Common.Categories) do
        local checkbox = filters:AddCheckbox(category.Label, Settings.Values.Categories[category.Id] ~= false)
        checkbox.SameLine = (i - 1) % 6 ~= 0
        checkbox.OnChange = Guarded(category.Label, function(element)
            Settings.Values.Categories[category.Id] = element.Checked
            OnFilterChanged()
        end)
        ui.Categories[category.Id] = checkbox
    end

    local gearOnly = filters:AddButton("Gear only")
    gearOnly.OnClick = Guarded("Gear only", function()
        SetCategories(function(id) return Common.GearCategories[id] == true end)
    end)

    local hideJunk = filters:AddButton("Hide food & junk")
    hideJunk.SameLine = true
    hideJunk.OnClick = Guarded("Hide food & junk", function()
        SetCategories(function(id) return id ~= "Food" and id ~= "Other" end)
    end)

    local allTypes = filters:AddButton("All types")
    allTypes.SameLine = true
    allTypes.OnClick = Guarded("All types", function()
        SetCategories(function() return true end)
    end)

    -- Options
    local options = AddSection(window, "Options", "OptionsOpen")

    local keyIndex = (IndexOf(TOGGLE_KEYS, Settings.Values.ToggleKey) or 2) - 1
    AddCombo(options, "Toggle key", TOGGLE_KEYS, keyIndex, 110, function(index)
        Settings.Values.ToggleKey = TOGGLE_KEYS[index] or "F7"
        Settings.Save()
    end)

    local modifierIndex = (IndexOf(TOGGLE_MODIFIERS, Settings.Values.ToggleModifier) or 1) - 1
    local modifier = AddCombo(options, "Modifier", TOGGLE_MODIFIERS, modifierIndex, 90, function(index)
        Settings.Values.ToggleModifier = TOGGLE_MODIFIERS[index] or "None"
        Settings.Save()
    end)
    modifier.SameLine = true

    local rowLabels = {}
    for i, count in ipairs(ROW_OPTIONS) do
        rowLabels[i] = tostring(count)
    end
    local rowIndex = (IndexOf(ROW_OPTIONS, Settings.Values.MaxRows) or 2) - 1
    local rowsCombo = AddCombo(options, "Rows shown", rowLabels, rowIndex, 80, function(index)
        Settings.Values.MaxRows = ROW_OPTIONS[index] or 100
        OnFilterChanged()
    end)
    rowsCombo.SameLine = true

    local icons = options:AddCheckbox("Show item icons", Settings.Values.ShowIcons)
    icons.OnChange = Guarded("Show item icons", function(element)
        Settings.Values.ShowIcons = element.Checked
        OnFilterChanged()
    end)

    local clear = options:AddButton("Clear log")
    clear.SameLine = true
    clear.OnClick = Guarded("Clear log", ClearLog)

    -- Pop-up and chime for rare loot
    local alerts = options:AddCheckbox("Pop-up for new loot", Settings.Values.AlertEnabled)
    alerts.OnChange = Guarded("Pop-up for new loot", function(element)
        Settings.Values.AlertEnabled = element.Checked
        Settings.Save()
    end)

    local alertRarity = AddCombo(options, "Pop-up and chime from", ALERT_RARITY_OPTIONS, Settings.Values.AlertMinRarity - 1, 120, function(index)
        Settings.Values.AlertMinRarity = index
        Settings.Save()
    end)
    alertRarity.SameLine = true

    local volume = options:AddSliderInt("Chime volume (0 = off)", Settings.Values.ChimeVolume, 0, 100)
    volume.ItemWidth = 220
    volume.OnChange = Guarded("Chime volume", function(element)
        Settings.Values.ChimeVolume = element.Value[1]
        Settings.Save()
    end)
    -- Play the chime when the slider is released, so the new volume can be heard.
    volume.OnDeactivate = Guarded("Chime volume preview", function()
        Alert.Chime(true)
    end)

    local soundLabels = {}
    local soundIndex = 0
    for i, sound in ipairs(Alert.Sounds) do
        soundLabels[i] = sound.Label
        if sound.Id == Settings.Values.ChimeSound then
            soundIndex = i - 1
        end
    end
    local sound = AddCombo(options, "Chime sound", soundLabels, soundIndex, 150, function(index)
        Settings.Values.ChimeSound = Alert.Sounds[index].Id
        Settings.Save()
        Alert.Chime(true)
    end)
    sound.SameLine = true

    local test = options:AddButton("Test pop-up and chime")
    test.OnClick = Guarded("Test pop-up and chime", Alert.Test)

    -- Pop-up position; moving a slider shows a sample pop-up at the new place.
    local alertX = options:AddSliderInt("Pop-up left/right %", Settings.Values.AlertX, 0, 100)
    alertX.ItemWidth = 220
    alertX.OnChange = Guarded("Pop-up left/right", function(element)
        Settings.Values.AlertX = element.Value[1]
        Settings.Save()
        Alert.Preview()
    end)

    local alertY = options:AddSliderInt("Pop-up up/down %", Settings.Values.AlertY, 0, 100)
    alertY.ItemWidth = 220
    alertY.SameLine = true
    alertY.OnChange = Guarded("Pop-up up/down", function(element)
        Settings.Values.AlertY = element.Value[1]
        Settings.Save()
        Alert.Preview()
    end)

    -- One click above the table: compare the filtered and the full log.
    local useFilters = window:AddCheckbox("Use filters", Settings.Values.FiltersEnabled)
    useFilters.OnChange = Guarded("Use filters", function(element)
        Settings.Values.FiltersEnabled = element.Checked
        OnFilterChanged()
    end)

    ui.Status = window:AddText("")
    ui.Status.SameLine = true
    ui.TableHost = window:AddGroup("LootLogRows")
    UpdateFiltersLabel()
end

function Window.Show()
    if Ext.IMGUI == nil then
        _PE("[LootLog] IMGUI is not available, so the window cannot be shown.")
        return
    end
    if window == nil then
        CreateWindow()
    end

    window.Visible = true
    window.Open = true
    RequestHistory()
    if dirty then
        Rebuild()
    else
        UpdateAges()
    end
end

function Window.Hide()
    if window ~= nil then
        SaveWindowPlacement()
        window.Open = false
        window.Visible = false
    end
end

function Window.Toggle()
    if IsShown() then
        Window.Hide()
    else
        Window.Show()
    end
end

local function HasModifier(modifiers, label)
    local ok, value = pcall(function() return modifiers[label] end)
    return ok and value == true
end

local function ModifiersMatch(modifiers, wanted)
    local ctrl = HasModifier(modifiers, "LCtrl") or HasModifier(modifiers, "RCtrl")
    local shift = HasModifier(modifiers, "LShift") or HasModifier(modifiers, "RShift")
    local alt = HasModifier(modifiers, "LAlt") or HasModifier(modifiers, "RAlt")
    if wanted == "Ctrl" then
        return ctrl and not shift and not alt
    elseif wanted == "Shift" then
        return shift and not ctrl and not alt
    elseif wanted == "Alt" then
        return alt and not ctrl and not shift
    end
    return not ctrl and not shift and not alt
end

local function OnKeyInput(event)
    if tostring(event.Event) ~= "KeyDown" or event.Repeat then
        return
    end
    if tostring(event.Key) ~= Settings.Values.ToggleKey then
        return
    end
    if not ModifiersMatch(event.Modifiers, Settings.Values.ToggleModifier) then
        return
    end

    Window.Toggle()
    pcall(function() event:PreventAction() end)
end

local function OnTick()
    local now = Ext.Timer.MonotonicTime()
    if #ageLabels > 0 and IsShown() and now - lastAgeRefresh >= AGE_REFRESH_MS then
        UpdateAges()
    end
    -- Store a moved or resized window also when the game is closed while the window is open.
    if IsShown() and now - lastPlacementCheck >= PLACEMENT_SAVE_MS then
        lastPlacementCheck = now
        SaveWindowPlacement()
    end
    -- Ask where the logged items are now; entries whose place changed come back on the Entries channel.
    if IsShown() and historyState == "done"
        and (lastPlacesRequest == nil or now - lastPlacesRequest >= PLACES_REFRESH_MS) then
        lastPlacesRequest = now
        Common.Channels.Places:SendToServer({})
    end
    Alert.Update()
end

local function OnGameStateChanged(event)
    local to = tostring(event.ToState)
    if to == "Running" then
        RequestHistory()
    elseif to == "UnloadSession" or to == "LoadSession" or to == "Menu" then
        Window.Hide()
        Alert.Hide()
        Alert.RestoreVolume()
        SetEntries({})
        historyState = "none"
        dirty = true
    end
end

function Window.Init()
    Settings.Load()
    Common.Channels.Entries:SetHandler(Guarded("Entries", OnEntries))
    Common.Channels.Toggle:SetHandler(Guarded("Toggle", function() Window.Toggle() end))
    Ext.Events.KeyInput:Subscribe(Guarded("KeyInput", OnKeyInput))
    Ext.Events.Tick:Subscribe(Guarded("Tick", OnTick))
    Ext.Events.GameStateChanged:Subscribe(Guarded("GameStateChanged", OnGameStateChanged))
    Ext.Events.SessionLoaded:Subscribe(Guarded("Sound list", Alert.WriteSoundList))
end

return Window
