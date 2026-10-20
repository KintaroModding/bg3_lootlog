local Window = Ext.Require("Client/Window.lua")
Window.Init()

local function KeyDown(key, modifiers)
    local event = { Event = "KeyDown", Key = key, Modifiers = modifiers or {}, Repeat = false, Prevented = false }
    function event:PreventAction()
        self.Prevented = true
    end
    Ext.Events.KeyInput:Fire(event)
    return event
end

local function Entry(id, name, category, rarity, value, age)
    return {
        Id = id,
        Name = name,
        Category = category,
        Rarity = rarity,
        Amount = 1,
        Value = value,
        Owner = "Karlach",
        From = "Goblin Boss",
        Icon = "Item_" .. id,
        Epoch = Harness.Clock - (age or 0),
    }
end

local function Shown()
    local window = Harness.Windows[1]
    return window ~= nil and window.Open == true and window.Visible == true
end

local function Rows()
    local tbl = Harness.LiveTable()
    AssertTrue(tbl ~= nil, "a live table exists")
    return Harness.TableRows(tbl)
end

--- Item names of the rows (the first text in the item cell; the subtext follows it).
local function ItemNames()
    local tbl = Harness.LiveTable()
    AssertTrue(tbl ~= nil, "a live table exists")
    local names = {}
    for _, row in ipairs(Harness.ElementData[tbl].Children) do
        local rowData = Harness.ElementData[row]
        if rowData.Class == "ExtuiTableRow" then
            for _, child in ipairs(Harness.ElementData[rowData.Children[2]].Children) do
                local data = Harness.ElementData[child]
                if data.Class == "ExtuiText" then
                    names[#names + 1] = data.Values.Label
                    break
                end
            end
        end
    end
    return table.concat(names, ", ")
end

local function LastHistoryRequest()
    local sent = Harness.Channels.History.Sent
    return sent[#sent]
end

Test("The toggle key opens the window and asks for the history", function()
    AssertEq(#Harness.Windows, 0, "window is created lazily")
    local event = KeyDown("F7")
    AssertTrue(Shown(), "window shown")
    AssertTrue(event.Prevented, "key not passed to the game")
    local calls = Harness.ElementData[Harness.Windows[1]].Calls
    AssertEq(calls.SetSize[1][1] .. "x" .. calls.SetSize[1][2], "780x480", "default size")
    AssertEq(calls.SetPos, nil, "no stored position yet: the game places the window")
    AssertEq(Harness.Find("ExtuiText", "Loading the log...") ~= nil, true, "loading status")

    local request = LastHistoryRequest()
    AssertEq(request.Kind, "RequestToServer", "history requested")
    AssertTrue(type(request.Callback) == "function", "reply callback")
end)

Test("The history reply fills the table, newest first", function()
    LastHistoryRequest().Callback({
        Ready = true,
        Entries = {
            Entry(1, "Bread", "Food", 0, 2, 600),
            Entry(2, "Longsword +1", "Weapon", 1, 120, 300),
            Entry(3, "Ring of Protection", "Jewelry", 3, 900, 120),
            Entry(4, "Fork", "Other", 0, 1, 60),
            Entry(5, "Splint Armour", "Armor", 2, 600, 10),
        },
    })
    Harness.RunTick()

    AssertEq(ItemNames(), "Splint Armour, Fork, Ring of Protection, Longsword +1, Bread", "rows")
    local first = Rows()[1]
    AssertEq(first[1], "10s", "age")
    AssertEq(first[2], "[img] Splint Armour Rare", "icon, name and subtext")
    AssertEq(first[3], "Armor", "type")
    AssertEq(first[4], "Rare", "rarity")
    AssertEq(first[5], "1", "amount")
    AssertEq(first[6], "600", "value")
    AssertEq(first[7], "Karlach", "owner")
    AssertEq(first[8], "", "no place: entry from an older version")
    AssertEq(first[9], "Goblin Boss", "source")
    AssertTrue(Harness.Find("ExtuiText", "Showing 5 of 5 matching entries (5 logged).") ~= nil, "status")
end)

Test("Quick filters and rarity filter", function()
    local gearOnly = Harness.Find("ExtuiButton", "Gear only")
    gearOnly.OnClick(gearOnly)
    Harness.RunTick()
    AssertEq(ItemNames(), "Splint Armour, Ring of Protection, Longsword +1", "gear only")
    AssertEq(Harness.Find("ExtuiCheckbox", "Food").Checked, false, "food checkbox updated")

    local rarity = Harness.Find("ExtuiCombo", "Rarity")
    rarity.SelectedIndex = 2
    rarity.OnChange(rarity)
    Harness.RunTick()
    AssertEq(ItemNames(), "Splint Armour, Ring of Protection", "rare and better")

    local all = Harness.Find("ExtuiButton", "All types")
    all.OnClick(all)
    rarity.SelectedIndex = 0
    rarity.OnChange(rarity)
    local hideJunk = Harness.Find("ExtuiButton", "Hide food & junk")
    hideJunk.OnClick(hideJunk)
    Harness.RunTick()
    AssertEq(ItemNames(), "Splint Armour, Ring of Protection, Longsword +1", "food and junk hidden")

    local weapons = Harness.Find("ExtuiCheckbox", "Weapons")
    weapons.Checked = false
    weapons.OnChange(weapons)
    Harness.RunTick()
    AssertEq(ItemNames(), "Splint Armour, Ring of Protection", "weapons unchecked")

    all.OnClick(all)
    Harness.RunTick()
    AssertEq(#Rows(), 5, "all types again")
end)

Test("Value filter and search", function()
    local value = Harness.Find("ExtuiCombo", "Value")
    value.SelectedIndex = 4 -- 100+ gold
    value.OnChange(value)
    Harness.RunTick()
    AssertEq(ItemNames(), "Splint Armour, Ring of Protection, Longsword +1", "100+ gold")
    value.SelectedIndex = 0
    value.OnChange(value)

    local search = Harness.Find("ExtuiInputText", "Search")
    search.Text = "RING"
    search.OnChange(search)
    Harness.RunTick()
    AssertEq(ItemNames(), "Ring of Protection", "search")
    search.Text = ""
    search.OnChange(search)
    Harness.RunTick()
    AssertEq(#Rows(), 5, "search cleared")
end)

Test("New entries appear while the window is open", function()
    Harness.Channels.Entries.MessageHandler({ Entries = { Entry(6, "Scroll of Fireball", "Scroll", 2, 250, 0) } }, 1)
    Harness.RunTick()
    AssertEq(#Rows(), 6, "one more row")
    AssertEq(Rows()[1][2], "[img] Scroll of Fireball Rare", "newest on top")
    AssertEq(Rows()[1][1], "now", "age")
    AssertEq(Rows()[1][7], "Karlach", "owner")
end)

Test("An entry sent again with the same Id replaces the old one", function()
    local moved = Entry(6, "Scroll of Fireball", "Scroll", 2, 250, 0)
    moved.Owner = "Camp chest"
    Harness.Channels.Entries.MessageHandler({ Entries = { moved } }, 1)
    Harness.RunTick()
    AssertEq(#Rows(), 6, "no new row")
    AssertEq(Rows()[1][7], "Camp chest", "owner updated")
end)

Test("The age column refreshes", function()
    Harness.Clock = Harness.Clock + 120
    Harness.Monotonic = Harness.Monotonic + 6000
    Harness.RunTick()
    AssertEq(Rows()[1][1], "2m", "age updated")
end)

Test("Settings are saved and options work", function()
    Harness.RunTimers() -- settings are written after a short delay
    local saved = Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"])
    AssertEq(saved.ToggleKey, "F7", "toggle key saved")
    AssertEq(saved.Search, nil, "search is not saved")

    local icons = Harness.Find("ExtuiCheckbox", "Show item icons")
    icons.Checked = false
    icons.OnChange(icons)
    Harness.RunTick()
    AssertEq(Rows()[1][2], "Scroll of Fireball Rare", "no icon")

    local rows = Harness.Find("ExtuiCombo", "Rows shown")
    rows.SelectedIndex = 0 -- 50
    rows.OnChange(rows)
    Harness.RunTimers()
    AssertEq(Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"]).MaxRows, 50, "rows saved")

    local key = Harness.Find("ExtuiCombo", "Toggle key")
    key.SelectedIndex = 0 -- F6
    key.OnChange(key)
    local modifier = Harness.Find("ExtuiCombo", "Modifier")
    modifier.SelectedIndex = 1 -- Ctrl
    modifier.OnChange(modifier)

    KeyDown("F7")
    AssertTrue(Shown(), "old key does nothing")
    KeyDown("F6")
    AssertTrue(Shown(), "modifier missing")
    KeyDown("F6", { LCtrl = true })
    AssertTrue(not Shown(), "Ctrl+F6 hides")
    KeyDown("F6", { RCtrl = true })
    AssertTrue(Shown(), "Ctrl+F6 shows")
end)

Test("Clear empties the window and tells the server", function()
    local clear = Harness.Find("ExtuiButton", "Clear log")
    clear.OnClick(clear)
    Harness.RunTick()
    AssertEq(#Rows(), 0, "no rows")
    local sent = Harness.Channels.Clear.Sent
    AssertEq(sent[#sent].Kind, "SendToServer", "server told")
end)

Test("The window closes with the X button and opens again", function()
    local window = Harness.Windows[1]
    window.Open = false
    window.OnClose(window)
    AssertTrue(not Shown(), "closed")
    KeyDown("F6", { LCtrl = true })
    AssertTrue(Shown(), "opened again")
end)

Test("Leaving the session hides the window and resets the log", function()
    Harness.RunTimers() -- pending settings writes
    Ext.Events.GameStateChanged:Fire({ FromState = "Running", ToState = "UnloadSession" })
    AssertTrue(not Shown(), "hidden")

    Ext.Events.GameStateChanged:Fire({ FromState = "LoadLevel", ToState = "Running" })
    local request = LastHistoryRequest()
    request.Callback({ Ready = false, Entries = {} })
    AssertEq(#Harness.Timers, 0, "no retry while hidden")

    KeyDown("F6", { LCtrl = true })
    request = LastHistoryRequest()
    request.Callback({ Ready = false, Entries = {} })
    AssertEq(#Harness.Timers, 1, "retry scheduled while shown")
    Harness.Timers[1].Fn()
    LastHistoryRequest().Callback({ Ready = true, Entries = { Entry(1, "After Reload", "Weapon", 1, 5, 0) } })
    Harness.RunTick()
    AssertEq(ItemNames(), "After Reload", "history loaded after retry")
end)

Test("Window errors are written to client.log", function()
    local original = Window.Toggle
    Window.Toggle = function()
        error("window broke")
    end
    Harness.Channels.Toggle.MessageHandler({}, 1)
    Window.Toggle = original
    Harness.RunTimers()

    local text = Harness.Files["bg3_lootlog/client.log"] or ""
    AssertTrue(string.find(text, "ERROR Toggle failed:", 1, true), "error line")
    AssertTrue(string.find(text, "window broke", 1, true), "error text")
    AssertEq(#Harness.Errors, 1, "error also printed to the console")
    Harness.Errors = {}
end)

Test("The subtext shows the item type, and the search finds it", function()
    local cloak = Entry(100, "Cloak of Protection", "Armor", 1, 300, 0)
    cloak.TypeName = "Cloak"
    local blade = Entry(101, "Blade of the Moon", "Weapon", 3, 900, 0)
    blade.TypeName = "Longsword"
    Harness.Channels.Entries.MessageHandler({ Entries = { cloak, blade } }, 1)
    Harness.RunTick()

    AssertEq(Rows()[1][2], "Blade of the Moon Very Rare Longsword", "weapon name and subtext")
    AssertEq(Rows()[2][2], "Cloak of Protection Uncommon Cloak", "cloak name and subtext")

    local search = Harness.Find("ExtuiInputText", "Search")
    search.Text = "longsword"
    search.OnChange(search)
    Harness.RunTick()
    AssertEq(ItemNames(), "Blade of the Moon", "search by type")
    search.Text = ""
    search.OnChange(search)
    Harness.RunTick()
end)

Test("Position, size and the Options state are stored while the window is open", function()
    local window = Harness.Windows[1]
    window.LastPosition = { 300, 120 }
    window.LastSize = { 900, 600 }
    Harness.Monotonic = Harness.Monotonic + 2500
    Harness.RunTick()
    Harness.RunTimers()
    local saved = Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"])
    AssertEq(saved.WindowX, 300, "x stored every 2 s")
    AssertEq(saved.WindowW, 900, "width stored")

    local options = Harness.Find("ExtuiTree", "Options")
    options.OnExpand(options)
    Harness.RunTimers()
    AssertEq(Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"]).OptionsOpen, true, "open stored")
    options.OnCollapse(options)
    Harness.RunTimers()
    AssertEq(Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"]).OptionsOpen, false, "closed stored")

    -- A window that was never drawn reports size 0 and is not stored.
    window.LastSize = { 0, 0 }
    window.LastPosition = { 5, 5 }
    window.OnClose(window)
    Harness.RunTimers()
    AssertEq(Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"]).WindowX, 300, "zero size ignored")
end)

Test("Filters are a collapsing section; its header shows when filters are active", function()
    local filters = nil
    for _, element in ipairs(Harness.Elements) do
        local data = Harness.ElementData[element]
        if data.Class == "ExtuiTree" and not data.Destroyed and string.find(data.Values.Label or "", "###LootLogFilters", 1, true) then
            filters = element
        end
    end
    AssertTrue(filters ~= nil, "Filters section")
    AssertEq(filters.CollapsingHeader, true, "header style")
    AssertEq(filters.DefaultOpen, true, "open by default")
    local search = Harness.Find("ExtuiInputText", "Search")
    AssertEq(Harness.ElementData[search].Parent, filters, "filter controls are inside")
    AssertEq(filters.Label, "Filters###LootLogFilters", "no filter active")

    local rarity = Harness.Find("ExtuiCombo", "Rarity")
    rarity.SelectedIndex = 2
    rarity.OnChange(rarity)
    AssertEq(filters.Label, "Filters (active)###LootLogFilters", "rarity filter")
    rarity.SelectedIndex = 0
    rarity.OnChange(rarity)
    AssertEq(filters.Label, "Filters###LootLogFilters", "rarity reset")

    search.Text = "ring"
    search.OnChange(search)
    AssertEq(filters.Label, "Filters (active)###LootLogFilters", "search text")
    search.Text = ""
    search.OnChange(search)

    local food = Harness.Find("ExtuiCheckbox", "Food")
    food.Checked = false
    food.OnChange(food)
    AssertEq(filters.Label, "Filters (active)###LootLogFilters", "type unchecked")
    local all = Harness.Find("ExtuiButton", "All types")
    all.OnClick(all)
    AssertEq(filters.Label, "Filters###LootLogFilters", "all types again")

    filters.OnCollapse(filters)
    Harness.RunTimers()
    AssertEq(Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"]).FiltersOpen, false, "closed state stored")
    filters.OnExpand(filters)
    Harness.RunTick()
end)

Test("Use filters: one click shows the full log, a second click the filtered log again", function()
    local function StatusText()
        for _, element in ipairs(Harness.Elements) do
            local data = Harness.ElementData[element]
            local label = data.Values.Label or ""
            if data.Class == "ExtuiText" and not data.Destroyed
                and (string.find(label, "^Showing") or string.find(label, "^Filters off:")) then
                return label
            end
        end
        return nil
    end
    local filters = Harness.Find("ExtuiTree", "Filters###LootLogFilters")
    Window.Show() -- an earlier test closed the window with the X button

    local rarity = Harness.Find("ExtuiCombo", "Rarity")
    rarity.SelectedIndex = 3 -- Very Rare+
    rarity.OnChange(rarity)
    Harness.RunTick()
    local filteredRows = #Rows()
    AssertTrue(string.find(StatusText(), "matching entries", 1, true), "filtered status")

    local useFilters = Harness.Find("ExtuiCheckbox", "Use filters")
    AssertEq(useFilters.Checked, true, "on by default")
    useFilters.Checked = false
    useFilters.OnChange(useFilters)
    Harness.RunTick()
    local allRows = #Rows()
    AssertTrue(allRows > filteredRows, "more rows without filters")
    AssertTrue(string.find(StatusText(), "Filters off: showing " .. allRows .. " of", 1, true), "status says filters are off")
    AssertEq(filters.Label, "Filters (off)###LootLogFilters", "header says off")
    AssertEq(rarity.SelectedIndex, 3, "filter settings unchanged")
    Harness.RunTimers()
    AssertEq(Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"]).FiltersEnabled, false, "off stored")

    useFilters.Checked = true
    useFilters.OnChange(useFilters)
    Harness.RunTick()
    AssertEq(#Rows(), filteredRows, "filtered again")
    AssertEq(filters.Label, "Filters (active)###LootLogFilters", "header says active")
    Harness.RunTimers()
    AssertEq(Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"]).FiltersEnabled, true, "on stored")

    rarity.SelectedIndex = 0
    rarity.OnChange(rarity)
    Harness.RunTick()
end)

--- The live text element with this label in the table, or nil.
local function TableText(label)
    local tbl = Harness.LiveTable()
    for _, element in ipairs(Harness.Elements) do
        local data = Harness.ElementData[element]
        if data.Class == "ExtuiText" and not data.Destroyed and data.Values.Label == label then
            -- text -> cell -> row -> table
            local row = Harness.ElementData[Harness.ElementData[element].Parent].Parent
            if Harness.ElementData[row].Parent == tbl then
                return element
            end
        end
    end
    return nil
end

local function SetSearch(text)
    local search = Harness.Find("ExtuiInputText", "Search")
    search.Text = text
    search.OnChange(search)
    Harness.RunTick()
end

Test("The Where column shows where the item is now; places outside the party are gray", function()
    local amulet = Entry(200, "Amulet of Selune", "Jewelry", 2, 500, 0)
    amulet.Where, amulet.WhereState = "Karlach > Pouch", "party"
    local dagger = Entry(201, "Rusty Dagger", "Weapon", 0, 2, 0)
    dagger.Where, dagger.WhereState = "Gone", "gone"
    Harness.Channels.Entries.MessageHandler({ Entries = { amulet, dagger } }, 1)
    Harness.RunTick()

    local rows = Rows()
    AssertEq(rows[1][8], "Gone", "sold item")
    AssertEq(rows[2][8], "Karlach > Pouch", "item in a bag")
    AssertEq(Harness.ElementData[TableText("Karlach > Pouch")].Calls.SetColor, nil, "party place in the normal color")
    local gray = Harness.ElementData[TableText("Gone")].Calls.SetColor
    AssertTrue(gray ~= nil and gray[1] == "Text" and gray[2][1] < 0.7, "gone in gray")
end)

Test("While the window is open, it asks the server for the places every 2 seconds", function()
    local sent = Harness.Channels.Places.Sent
    local count = #sent
    Harness.Monotonic = Harness.Monotonic + 2000
    Harness.RunTick()
    AssertEq(#sent, count + 1, "asked")
    AssertEq(sent[#sent].Kind, "SendToServer", "sent to the server")
    Harness.RunTick()
    AssertEq(#sent, count + 1, "not again within 2 seconds")

    Window.Hide()
    Harness.Monotonic = Harness.Monotonic + 5000
    Harness.RunTick()
    AssertEq(#sent, count + 1, "not while hidden")
    Window.Show()
    Harness.RunTick()
    AssertEq(#sent, count + 2, "asked again when shown")
end)

Test("A place update changes the cell in place, without a new row or a pop-up", function()
    local tbl = Harness.LiveTable()
    local rowCount = #Rows()
    local moved = Entry(200, "Amulet of Selune", "Jewelry", 2, 500, 0)
    moved.Where, moved.WhereState = "Gale > Backpack", "party"
    local unknown = Entry(999, "Not In This Log", "Jewelry", 4, 5000, 0)
    unknown.Where, unknown.WhereState = "Gale", "party"
    Harness.Channels.Entries.MessageHandler({ Entries = { moved, unknown }, Updated = true }, 1)
    Harness.RunTick()

    AssertEq(Harness.LiveTable(), tbl, "no rebuild")
    AssertEq(#Rows(), rowCount, "no new row")
    AssertEq(Rows()[2][8], "Gale > Backpack", "place changed")
    AssertEq(Harness.Find("ExtuiText", "Not In This Log"), nil, "unknown entry ignored: no row, no pop-up")

    -- The search also finds the place; with a search, a place update filters the table again.
    SetSearch("backpack")
    AssertEq(ItemNames(), "Amulet of Selune", "search by place")
    moved = Entry(200, "Amulet of Selune", "Jewelry", 2, 500, 0)
    moved.Where, moved.WhereState = "Gale > Pouch", "party"
    Harness.Channels.Entries.MessageHandler({ Entries = { moved }, Updated = true }, 1)
    Harness.RunTick()
    AssertEq(#Rows(), 0, "no longer in the backpack")
    SetSearch("")

    -- Sold: the place turns gray, so the table is drawn again.
    tbl = Harness.LiveTable()
    local sold = Entry(200, "Amulet of Selune", "Jewelry", 2, 500, 0)
    sold.Where, sold.WhereState = "Arron", "other"
    Harness.Channels.Entries.MessageHandler({ Entries = { sold }, Updated = true }, 1)
    Harness.RunTick()
    AssertTrue(Harness.LiveTable() ~= tbl, "rebuilt for the color")
    AssertEq(Rows()[2][8], "Arron", "trader")
    AssertTrue(Harness.ElementData[TableText("Arron")].Calls.SetColor ~= nil, "gray")
end)
