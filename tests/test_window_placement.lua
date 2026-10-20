-- The main window restores its stored position, size and the open state of its sections.

Harness.Files["bg3_lootlog/settings.json"] = Ext.Json.Stringify({
    WindowX = 5000, -- off the 1920 px wide screen (resolution changed)
    WindowY = 100,
    WindowW = 900,
    WindowH = 600,
    OptionsOpen = true,
    FiltersOpen = false,
})

local Window = Ext.Require("Client/Window.lua")
Window.Init()

local function KeyDown(key)
    local event = { Event = "KeyDown", Key = key, Modifiers = {}, Repeat = false }
    function event:PreventAction() end
    Ext.Events.KeyInput:Fire(event)
end

local function Saved()
    Harness.RunTimers()
    return Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"])
end

Test("A new window gets the stored size, a position on the screen and the Options state", function()
    KeyDown("F7")
    local window = Harness.Windows[1]
    local calls = Harness.ElementData[window].Calls
    AssertEq(window.Scaling, "Absolute", "sizes in real pixels")
    AssertEq(calls.SetSize[1][1], 900, "width")
    AssertEq(calls.SetSize[1][2], 600, "height")
    AssertEq(calls.SetSize[2], "Always", "size applied once over imgui.ini")
    AssertEq(calls.SetPos[1][1], 1800, "x kept on the screen (1920 - 120)")
    AssertEq(calls.SetPos[1][2], 100, "y")

    local options = Harness.Find("ExtuiTree", "Options")
    AssertTrue(options ~= nil, "Options section")
    AssertEq(options.CollapsingHeader, true, "header style")
    AssertEq(options.DefaultOpen, true, "opens by default")
    AssertEq(Harness.ElementData[options].Calls.SetOpen[1], true, "open state applied")

    local filters = Harness.Find("ExtuiTree", "Filters###LootLogFilters")
    AssertTrue(filters ~= nil, "Filters section")
    AssertEq(filters.DefaultOpen, false, "stored closed")
    AssertEq(Harness.ElementData[filters].Calls.SetOpen[1], false, "closed state applied")
end)

Test("Closing the window with the key stores the new position and size", function()
    local window = Harness.Windows[1]
    window.LastPosition = { 250.4, 80.6 }
    window.LastSize = { 1000, 700 }
    KeyDown("F7")
    local saved = Saved()
    AssertEq(saved.WindowX, 250, "x rounded")
    AssertEq(saved.WindowY, 81, "y rounded")
    AssertEq(saved.WindowW, 1000, "width")
    AssertEq(saved.WindowH, 700, "height")
end)
