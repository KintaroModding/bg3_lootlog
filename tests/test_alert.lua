-- Pop-up and chime for rare loot (client side).

local ITEM_RECEIVED = "48c6a208-8528-6bd4-8e95-2066979dc327"
local OLD_CHIME = "a6571b9a-0b79-6712-6326-a0e3134ed0ad"
local COINS = "515a392e-a9d6-d16d-7a7a-25a6cc960c21"
Harness.Resources.Sound[ITEM_RECEIVED] = { SoundEvent = "UI_Gameplay_Item_Received", Duration = 3.59 }
Harness.Resources.Sound[OLD_CHIME] = { SoundEvent = "UI_Gameplay_Coin_Removed", Duration = 0.65 }
Harness.Resources.Sound[COINS] = { SoundEvent = "UI_Gameplay_Coin_Add", Duration = 2.96 }
Harness.Resources.Sound["11111111-0000-0000-0000-000000000002"] = { SoundEvent = "VO_Karlach_Line", Duration = 3 }

-- Settings saved by the first version, with the chime that was silent in the game.
Harness.Files["bg3_lootlog/settings.json"] = Ext.Json.Stringify({ ChimeSound = OLD_CHIME, ChimeVolume = 60 })

local Settings = Ext.Require("Client/Settings.lua")
local Window = Ext.Require("Client/Window.lua")
Window.Init()

local function Entry(id, name, rarity, amount)
    return { Id = id, Name = name, Category = "Weapon", Rarity = rarity, Amount = amount or 1, Icon = "Item_" .. id,
        Epoch = Harness.Clock, Owner = "Karlach" }
end

local function Send(entries)
    Harness.Channels.Entries.MessageHandler({ Entries = entries }, 1)
end

local function KeyDown(key)
    local event = { Event = "KeyDown", Key = key, Modifiers = {}, Repeat = false }
    function event:PreventAction() end
    Ext.Events.KeyInput:Fire(event)
end

local function AlertWindow()
    for _, window in ipairs(Harness.Windows) do
        if window.Label == "Loot Log Alert" then
            return window
        end
    end
    return nil
end

local function AlertShown()
    local window = AlertWindow()
    return window ~= nil and window.Visible == true and window.Open == true
end

--- Texts of the live alert lines.
local function AlertLines()
    local texts = {}
    for _, element in ipairs(Harness.Elements) do
        local data = Harness.ElementData[element]
        if data.Class == "ExtuiText" and not data.Destroyed then
            local parent = Harness.ElementData[data.Parent]
            if parent and parent.Class == "ExtuiGroup" and parent.Values.Label == "LootLogAlertLines" and not parent.Destroyed then
                texts[#texts + 1] = data.Values.Label
            end
        end
    end
    return table.concat(texts, " | ")
end

--- Sound ids the client asked the server to play, since the last ResetAudio().
local chimeStart = 0
local function ChimeRequests()
    local sounds = {}
    local sent = Harness.Channels.Chime.Sent
    for i = chimeStart + 1, #sent do
        sounds[#sounds + 1] = sent[i].Data.Sound
    end
    return table.concat(sounds, ", ")
end

local function ResetAudio()
    Harness.AudioCalls = {}
    Harness.Rtpc = {}
    Harness.DefaultRtpc = 80
    chimeStart = #Harness.Channels.Chime.Sent
end

local function Later(ms)
    Harness.Monotonic = Harness.Monotonic + (ms or 5000)
end

Test("Saved settings with the old, silent chime get the new default", function()
    AssertEq(Settings.Values.ChimeSound, ITEM_RECEIVED, "migrated")
    AssertEq(Settings.Values.ChimeVolume, 60, "other settings kept")
    AssertEq(Settings.Values.ChimeMethod, "server", "server playback by default")
end)

Test("Common loot gives no pop-up and no chime", function()
    Send({ Entry(1, "Fork", 0) })
    AssertEq(AlertShown(), false, "no pop-up")
    AssertEq(ChimeRequests(), "", "no chime")
end)

Test("Uncommon loot shows the pop-up and asks the server for the chime", function()
    Harness.Monotonic = 100000
    Send({ Entry(2, "Longsword +1", 1), Entry(3, "Ring of Protection", 3), Entry(4, "Bread", 0) })

    AssertEq(AlertShown(), true, "pop-up shown")
    AssertEq(AlertLines(), "Ring of Protection | Very Rare | Longsword +1 | Uncommon", "newest first, common item left out")
    AssertEq(ChimeRequests(), ITEM_RECEIVED, "one chime for the batch")
    AssertEq(Harness.Channels.Chime.Sent[#Harness.Channels.Chime.Sent].Data.Log, true, "first chime is logged")
    AssertEq(#Harness.AudioCallsNamed("PostEvent"), 0, "no client-side event")
    AssertTrue(AlertWindow().NoInputs, "click-through")
end)

local function SetCalls(value)
    local count = 0
    for _, call in ipairs(Harness.AudioCallsNamed("SetRTPC")) do
        if call.Args[3] == value then
            count = count + 1
        end
    end
    return count
end

Test("The volume scales the global UI volume RTPC while the chime plays and sets it back afterwards", function()
    -- Default volume 60 %: the UI volume (80 in the mock) is 48 during the chime.
    local set = Harness.AudioCallsNamed("SetRTPC")[1]
    AssertEq(set.Args[1], "Global", "global value")
    AssertEq(set.Args[2], "RTPC_Volume_UI", "rtpc")
    AssertEq(set.Args[3], 48, "scaled volume")
    AssertEq(Harness.Rtpc["Global/RTPC_Volume_UI"], 48, "lowered")

    Harness.RunTimers() -- end of the chime
    AssertEq(Harness.Rtpc["Global/RTPC_Volume_UI"], 80, "set back")
    AssertEq(#Harness.AudioCallsNamed("ResetRTPC"), 0, "a global value is set back, not reset")

    local log = Harness.Files["bg3_lootlog/client.log"] or ""
    AssertTrue(string.find(log, "Chime: UI_Gameplay_Item_Received", 1, true), "details in client.log")
    AssertTrue(string.find(log, "RTPC_Volume_UI on Global before 80, now 48", 1, true), "volume details")
    AssertTrue(string.find(log, "RTPC probe (Global): RTPC_Volume_Master=80", 1, true), "probe of the volume RTPCs")
end)

Test("Scope hud: the value on the HUD object is reset, or set again when the game had its own", function()
    Settings.Values.VolumeScope = "hud"
    ResetAudio()
    Harness.Rtpc["HUD/RTPC_Volume_UI"] = 50 -- the game's value on the object
    Harness.DefaultRtpc = 100 -- what a reset falls back to
    Later()
    Send({ Entry(5, "Rare Amulet", 2) })
    AssertEq(Harness.Rtpc["HUD/RTPC_Volume_UI"], 30, "60 % of 50")
    Harness.RunTimers()
    Harness.RunTimers()
    AssertEq(#Harness.AudioCallsNamed("ResetRTPC"), 1, "reset")
    AssertEq(Harness.Rtpc["HUD/RTPC_Volume_UI"], 50, "the game's value is back")
    Settings.Values.VolumeScope = "global"
end)

Test("Overlapping chimes keep the first value and set it back once", function()
    ResetAudio()
    Later()
    Send({ Entry(6, "Rare Cloak", 2) }) -- 48
    Settings.Values.ChimeVolume = 25
    Alert = Ext.Require("Client/Alert.lua")
    Alert.Chime(true) -- 25 % of the original 80, not of 48
    AssertEq(Harness.Rtpc["Global/RTPC_Volume_UI"], 20, "scaled from the original value")
    Harness.RunTimers()
    Harness.RunTimers()
    AssertEq(Harness.Rtpc["Global/RTPC_Volume_UI"], 80, "original value")
    AssertEq(SetCalls(80), 1, "set back once")
    Settings.Values.ChimeVolume = 60
end)


Test("More rare loot extends the pop-up; a second chime waits for the gap", function()
    ResetAudio()
    Later(500)
    local before = AlertLines()
    Send({ Entry(7, "Scroll of Haste", 2, 2) })
    AssertEq(AlertLines(), "Scroll of Haste x2 | Rare | " .. before, "added on top")
    AssertEq(ChimeRequests(), "", "no chime within 1.5 s")
    Later(2000)
    Send({ Entry(8, "Gloves of Dexterity", 3) })
    AssertEq(ChimeRequests(), ITEM_RECEIVED, "chime after the gap")
end)

Test("The pop-up shows at most five lines and then fades out", function()
    local batch = {}
    for i = 1, 4 do
        batch[i] = Entry(10 + i, "Rare Thing " .. i, 2)
    end
    Send(batch)
    AssertTrue(string.find(AlertLines(), "more (F7: Loot Log)", 1, true), "overflow line")

    Later(5500)
    Harness.RunTick()
    AssertEq(AlertShown(), true, "still shown while fading")
    Later(1000)
    Harness.RunTick()
    AssertEq(AlertShown(), false, "closed after 6 s")
end)

Test("An updated entry (same Id) gives no new pop-up", function()
    ResetAudio()
    Later()
    local moved = Entry(8, "Gloves of Dexterity", 3)
    moved.Owner = "Camp chest"
    Send({ moved })
    AssertEq(AlertShown(), false, "no pop-up")
    AssertEq(ChimeRequests(), "", "no chime")
end)

Test("Options: pop-up off, rarity limit, volume slider, sound choice and test button", function()
    KeyDown("F7") -- creates the main window with its options

    local popup = Harness.Find("ExtuiCheckbox", "Pop-up for new loot")
    popup.Checked = false
    popup.OnChange(popup)
    local rarity = Harness.Find("ExtuiCombo", "Pop-up and chime from")
    rarity.SelectedIndex = 1 -- Rare+
    rarity.OnChange(rarity)

    ResetAudio()
    Later()
    Send({ Entry(20, "Uncommon Cloak", 1) })
    AssertEq(ChimeRequests(), "", "uncommon is below Rare+")
    Send({ Entry(21, "Rare Cloak", 2) })
    AssertEq(ChimeRequests(), ITEM_RECEIVED, "rare plays the chime")
    AssertEq(AlertShown(), false, "pop-up switched off")

    -- Volume slider: 0 = off; releasing the slider plays a preview.
    local volume = Harness.Find("ExtuiSliderInt", "Chime volume (0 = off)")
    AssertEq(volume.Value[1], 60, "slider starts at the setting")
    volume.Value = { 0, 0, 0, 0 }
    volume.OnChange(volume)
    ResetAudio()
    Later()
    Send({ Entry(22, "Rare Boots", 2) })
    AssertEq(ChimeRequests(), "", "volume 0 is silent")
    Harness.RunTimers() -- let the earlier, quieter chime finish
    Harness.RunTimers()
    ResetAudio()
    volume.Value = { 100, 0, 0, 0 }
    volume.OnChange(volume)
    volume.OnDeactivate(volume)
    AssertEq(ChimeRequests(), ITEM_RECEIVED, "preview")
    AssertEq(#Harness.AudioCallsNamed("SetRTPC"), 0, "full volume: RTPC untouched")

    -- Sound choice: plays the new sound at once.
    ResetAudio()
    local sound = Harness.Find("ExtuiCombo", "Chime sound")
    AssertEq(sound.Options[sound.SelectedIndex + 1], "Item received", "current sound selected")
    sound.SelectedIndex = 4 -- Coins
    sound.OnChange(sound)
    AssertEq(ChimeRequests(), COINS, "preview of the new sound")

    -- Test button: sample pop-up (even when switched off) and chime.
    ResetAudio()
    local test = Harness.Find("ExtuiButton", "Test pop-up and chime")
    test.OnClick(test)
    AssertEq(AlertShown(), true, "test pop-up")
    AssertTrue(string.find(AlertLines(), "Test: Legendary Longbow", 1, true), "sample lines")
    AssertEq(ChimeRequests(), COINS, "test chime")

    Harness.RunTimers()
    local saved = Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"])
    AssertEq(saved.AlertEnabled, false, "pop-up setting saved")
    AssertEq(saved.AlertMinRarity, 2, "rarity setting saved")
    AssertEq(saved.ChimeVolume, 100, "volume saved")
    AssertEq(saved.ChimeSound, COINS, "sound saved")
end)

Test("Client method: the event is posted on the HUD object, loaded first when needed", function()
    Settings.Values.ChimeMethod = "client"
    ResetAudio()
    Harness.FailNextPostEvent = true
    Later()
    Send({ Entry(25, "Rare Belt", 2) })
    local posts = Harness.AudioCallsNamed("PostEvent")
    AssertEq(#posts, 2, "posted twice")
    AssertEq(posts[2].Args[1] .. ":" .. posts[2].Args[2], "HUD:UI_Gameplay_Coin_Add", "event on HUD")
    AssertEq(Harness.AudioCallsNamed("LoadEvent")[1].Args[1], "UI_Gameplay_Coin_Add", "loaded in between")
    AssertEq(ChimeRequests(), "", "server not asked")
    Settings.Values.ChimeMethod = "server"
end)

Test("A missing chime sound is reported in client.log", function()
    Harness.Resources.Sound[COINS] = nil
    ResetAudio()
    Later()
    Send({ Entry(30, "Rare Hat", 2) })
    AssertEq(ChimeRequests(), "", "nothing played")
    Harness.RunTimers()
    AssertTrue(string.find(Harness.Files["bg3_lootlog/client.log"] or "", "ERROR Chime: sound resource", 1, true), "error line")
end)

Test("The sound list is written once on session load", function()
    Ext.Events.SessionLoaded:Fire({})
    local text = Harness.Files["bg3_lootlog/sounds.txt"]
    AssertTrue(text ~= nil, "written")
    AssertTrue(string.find(text, "UI_Gameplay_Item_Received", 1, true), "UI sound listed")
    AssertTrue(not string.find(text, "VO_Karlach_Line", 1, true), "voice line left out")
    Harness.Files["bg3_lootlog/sounds.txt"] = "kept"
    Ext.Events.SessionLoaded:Fire({})
    AssertEq(Harness.Files["bg3_lootlog/sounds.txt"], "kept", "not rewritten")
end)

Test("Leaving the session hides the pop-up", function()
    local test = Harness.Find("ExtuiButton", "Test pop-up and chime")
    test.OnClick(test)
    AssertEq(AlertShown(), true, "shown")
    Ext.Events.GameStateChanged:Fire({ FromState = "Running", ToState = "Menu" })
    AssertEq(AlertShown(), false, "hidden")
end)

Test("Leaving the session while a chime plays sets the volume back at once", function()
    Settings.Values.ChimeVolume = 60
    Harness.Resources.Sound[COINS] = { SoundEvent = "UI_Gameplay_Coin_Add", Duration = 2.96 }
    Harness.RunTimers()
    Harness.RunTimers()
    ResetAudio()
    Later()
    Send({ Entry(40, "Rare Ring", 2) })
    AssertEq(Harness.Rtpc["Global/RTPC_Volume_UI"], 48, "lowered")
    Ext.Events.GameStateChanged:Fire({ FromState = "Running", ToState = "UnloadSession" })
    AssertEq(Harness.Rtpc["Global/RTPC_Volume_UI"], 80, "set back at once")
    Harness.RunTimers()
    AssertEq(SetCalls(80), 1, "the later restore does nothing")
    AssertEq(Harness.Rtpc["Global/RTPC_Volume_UI"], 80, "still the original value")
end)

Test("The pop-up shows the subtext with the item type", function()
    Settings.Values.AlertEnabled = true
    Settings.Values.AlertMinRarity = 1
    ResetAudio()
    Later()
    local cloak = Entry(50, "Cloak of Protection", 1)
    cloak.TypeName = "Cloak"
    Send({ cloak })
    AssertEq(AlertShown(), true, "shown")
    AssertTrue(string.find(AlertLines(), "Cloak of Protection | Uncommon Cloak", 1, true), "name and subtext")
end)

Test("Position sliders move the pop-up and show a preview without a chime", function()
    ResetAudio()
    local x = Harness.Find("ExtuiSliderInt", "Pop-up left/right %")
    local y = Harness.Find("ExtuiSliderInt", "Pop-up up/down %")
    AssertEq(x.Value[1], 50, "default left/right")
    AssertEq(y.Value[1], 14, "default up/down")

    x.Value = { 10, 0, 0, 0 }
    x.OnChange(x)
    AssertEq(AlertShown(), true, "preview shown")
    AssertTrue(string.find(AlertLines(), "Test: Cloak of Protection | Uncommon Cloak", 1, true), "preview lines")
    y.Value = { 80, 0, 0, 0 }
    y.OnChange(y)

    local call = Harness.ElementData[AlertWindow()].Calls.SetPos
    AssertTrue(math.abs(call[1][1] - 192) < 1e-6, "x = 10 % of 1920")
    AssertTrue(math.abs(call[1][2] - 864) < 1e-6, "y = 80 % of 1080")
    AssertEq(call[2], "Always", "applied every time")
    AssertTrue(math.abs(call[3][1] - 0.1) < 1e-9 and math.abs(call[3][2] - 0.8) < 1e-9, "pivot follows the sliders")
    AssertEq(ChimeRequests(), "", "no chime for the preview")

    Harness.RunTimers()
    local saved = Ext.Json.Parse(Harness.Files["bg3_lootlog/settings.json"])
    AssertEq(saved.AlertX, 10, "left/right saved")
    AssertEq(saved.AlertY, 80, "up/down saved")
end)
