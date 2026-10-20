-- On-screen notice and chime for new loot of a minimum rarity.
--
-- The notice is a small click-through IMGUI window at the top of the screen; it fades out after a few seconds.
-- The chime is a game UI sound resource. By default the server plays it with PlayHUDSoundResource (the game's own
-- HUD sound call); ChimeMethod = "client" posts the event on the HUD sound object from the client instead.
-- The volume scales the global UI volume RTPC while the chime plays; afterwards the RTPC goes back to the value it
-- had before. (A value on the HUD object alone did not change the volume in the game.)

local Common = Ext.Require("Shared/Common.lua")
local ClientLog = Ext.Require("Client/ClientLog.lua")
local Settings = Ext.Require("Client/Settings.lua")

local Alert = {}

-- Chime choices: game UI sound resources (from sounds.txt).
Alert.Sounds = {
    { Id = "48c6a208-8528-6bd4-8e95-2066979dc327", Label = "Item received" },
    { Id = "82aaf204-adf6-468d-af34-b65fe11e5a94", Label = "Recipe unlocked" },
    { Id = "c820b050-e903-bf19-cba7-e7c2a37ffcd0", Label = "Success roll" },
    { Id = "594db05c-3903-5bd5-ccaf-2c3665d9e71b", Label = "Inspiration" },
    { Id = "515a392e-a9d6-d16d-7a7a-25a6cc960c21", Label = "Coins" },
    { Id = "14d742fc-44a7-126e-7a11-60d182dd94e0", Label = "Journal updated" },
    { Id = "7f37f7c3-0f77-1bf0-6935-74e7fb25dd87", Label = "Quest completed" },
    { Id = "2a41c1d0-cf90-9c9f-552a-0503514f8c7f", Label = "Dice success" },
}

local SOUND_OBJECT = "HUD"
-- The sound can start later than the request (server round trip); the volume stays changed this much longer.
local VOLUME_MARGIN_MS = 700
-- Duration for sounds whose resource gives no duration (-1), so their end also plays at the chosen volume.
local DEFAULT_DURATION_MS = 4500
local RESTORE_CHECK_MS = 300
local SHOW_MS = 6000
local FADE_MS = 800
local MAX_LINES = 5
local KEEP_LINES = 50
local CHIME_GAP_MS = 1500
local ICON_SIZE = { 28, 28 }
local BACKGROUND_ALPHA = 0.85
local MORE_COLOR = { 0.75, 0.75, 0.75, 1.0 }
local SUBTEXT_COLOR = { 0.72, 0.72, 0.72, 1.0 }
local SOUND_LIST_PATH = "bg3_lootlog/sounds.txt"
local SOUND_LIST_PATTERN = "ui_|_ui|loot|item|gold|reward|notif|chime|achiev|levelup|level_up|quest|coin"

local window = nil
local content = nil
local lines = {}
-- { Text = text, Image = image|nil, Color = {r,g,b,a} } for the shown lines
local shown = {}
local shownAt = 0
local visible = false
local lastChime = nil
local chimeDetailsLogged = false
-- Active volume change: { Rtpc = name, Before = value, Token = n }. Overlapping chimes share the first Before.
local volumeOverride = nil

local function Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

local function SetAlpha(alpha)
    window:SetBgAlpha(BACKGROUND_ALPHA * alpha)
    for _, line in ipairs(shown) do
        line.Text:SetColor("Text", { line.Color[1], line.Color[2], line.Color[3], alpha })
        if line.Subtext then
            line.Subtext:SetColor("Text", { SUBTEXT_COLOR[1], SUBTEXT_COLOR[2], SUBTEXT_COLOR[3], alpha })
        end
        if line.Image then
            line.Image.Tint = { 1, 1, 1, alpha }
        end
    end
end

local function EnsureWindow()
    if window ~= nil then
        return
    end
    window = Ext.IMGUI.NewWindow("Loot Log Alert")
    window.Closeable = false
    window.NoTitleBar = true
    window.NoResize = true
    window.NoMove = true
    window.NoCollapse = true
    window.NoScrollbar = true
    window.NoSavedSettings = true
    window.NoFocusOnAppearing = true
    window.NoBringToFrontOnFocus = true
    window.NoNav = true
    window.NoInputs = true
    window.AlwaysAutoResize = true
    window.Open = false
    window.Visible = false
end

local function Render()
    if content ~= nil then
        content:Destroy()
    end
    content = window:AddGroup("LootLogAlertLines")
    shown = {}

    -- Newest first.
    local first = math.max(1, #lines - MAX_LINES + 1)
    for i = #lines, first, -1 do
        local entry = lines[i]
        local rarity = Common.Rarities[(entry.Rarity or 0) + 1] or Common.Rarities[1]

        local image = nil
        if Settings.Values.ShowIcons and entry.Icon then
            local ok, result = pcall(function() return content:AddImage(entry.Icon, ICON_SIZE) end)
            if ok then
                image = result
            end
        end

        local label = entry.Name or "?"
        if (entry.Amount or 1) > 1 then
            label = label .. " x" .. entry.Amount
        end
        local text = content:AddText(label)
        text.SameLine = image ~= nil
        local subtext = content:AddText(Common.Subtext(entry))
        subtext.SameLine = true
        shown[#shown + 1] = { Text = text, Subtext = subtext, Image = image, Color = rarity.Color }
    end

    if #lines > MAX_LINES then
        local more = content:AddText(string.format("+%d more (F7: Loot Log)", #lines - MAX_LINES))
        shown[#shown + 1] = { Text = more, Color = MORE_COLOR }
    end
end

local function Percent(value, default)
    if type(value) ~= "number" then
        return default / 100
    end
    return math.max(0, math.min(100, value)) / 100
end

--- Places the notice at AlertX / AlertY (percent of the screen). The pivot moves with the position, so 0 % puts the
--- left (top) edge at the screen edge and 100 % the right (bottom) edge: the notice always stays on the screen.
local function Position()
    local size = Try(Ext.IMGUI.GetViewportSize)
    if type(size) == "table" and size[1] then
        local x = Percent(Settings.Values.AlertX, 50)
        local y = Percent(Settings.Values.AlertY, 14)
        window:SetPos({ size[1] * x, size[2] * y }, "Always", { x, y })
    end
end

function Alert.Hide()
    visible = false
    lines = {}
    if window ~= nil then
        window.Visible = false
        window.Open = false
    end
end

--- Shows entries in the notice (newest on top). More entries extend the time the notice stays.
--- @param entries table[]
function Alert.Show(entries)
    if #entries == 0 or Ext.IMGUI == nil then
        return
    end
    EnsureWindow()
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = entry
    end
    while #lines > KEEP_LINES do
        table.remove(lines, 1)
    end

    Render()
    SetAlpha(1)
    Position()
    shownAt = Ext.Timer.MonotonicTime()
    visible = true
    window.Visible = true
    window.Open = true
end

function Alert.IsVisible()
    return visible
end

--- Puts the volume RTPC back to the value from before the chime.
local function RestoreVolume(override)
    if override.Object == "Global" then
        Try(Ext.Audio.SetRTPC, override.Object, override.Rtpc, override.Before, true)
        return
    end
    -- Object scope: the reset removes our value from the object. If the game had set its own value on that object,
    -- the reset changes it, so the value from before the chime is set again.
    Try(Ext.Audio.ResetRTPC, override.Object, override.Rtpc)
    Ext.Timer.WaitForRealtime(RESTORE_CHECK_MS, function()
        local current = Try(Ext.Audio.GetRTPC, override.Object, override.Rtpc)
        if type(current) == "number" and math.abs(current - override.Before) > 0.01 then
            Try(Ext.Audio.SetRTPC, override.Object, override.Rtpc, override.Before, true)
        end
    end)
end

--- Scales the volume RTPC for durationMs. Returns the value before the change, or nil when nothing changed.
--- Bus volumes in Wwise only follow the global RTPC value, so the default scope is "Global"; this also lowers other
--- UI sounds while the chime plays.
local function ApplyVolume(volume, durationMs)
    local rtpc = Settings.Values.VolumeRtpc
    if rtpc == "" or (volume >= 100 and volumeOverride == nil) then
        return nil
    end

    if volumeOverride == nil then
        local object = Settings.Values.VolumeScope == "hud" and SOUND_OBJECT or "Global"
        local before = Try(Ext.Audio.GetRTPC, object, rtpc)
        if type(before) ~= "number" or before <= 0 then
            return nil
        end
        volumeOverride = { Object = object, Rtpc = rtpc, Before = before, Token = 0 }
    end

    local override = volumeOverride
    local target = override.Before * math.min(volume, 100) / 100
    if Try(Ext.Audio.SetRTPC, override.Object, override.Rtpc, target, true) ~= true then
        return nil
    end

    -- Only the restore of the newest chime runs.
    override.Token = override.Token + 1
    local token = override.Token
    Ext.Timer.WaitForRealtime(durationMs, function()
        if volumeOverride == override and override.Token == token then
            volumeOverride = nil
            RestoreVolume(override)
        end
    end)
    return override.Before
end

--- Restores the volume at once (leaving the session while a chime plays).
function Alert.RestoreVolume()
    if volumeOverride ~= nil then
        local override = volumeOverride
        volumeOverride = nil
        RestoreVolume(override)
    end
end

-- Global values of the volume RTPCs, written to client.log once to find the right one.
local PROBE_RTPCS = {
    "RTPC_Volume_Master", "RTPC_Volume_Music", "RTPC_Volume_SFX", "RTPC_Volume_UI", "RTPC_Volume_VO",
    "RTPC_Volume_Dialogue", "RTPC_Volume_Ambient", "RTPC_Volume_Cinematics", "RTPC_Volume_Voice",
}

local function ProbeVolumes()
    local parts = {}
    for _, name in ipairs(PROBE_RTPCS) do
        parts[#parts + 1] = name .. "=" .. tostring(Try(Ext.Audio.GetRTPC, "Global", name))
    end
    ClientLog.Add("RTPC probe (Global): " .. table.concat(parts, ", "))
end

--- Plays the chime at the volume from the settings (0 = off).
--- @param force boolean|nil Play even when a chime played a moment ago (test button, slider)
--- @return boolean played
function Alert.Chime(force)
    local volume = Settings.Values.ChimeVolume or 0
    if volume <= 0 then
        return false
    end
    local now = Ext.Timer.MonotonicTime()
    if not force and lastChime ~= nil and now - lastChime < CHIME_GAP_MS then
        return false
    end
    lastChime = now

    local soundId = Settings.Values.ChimeSound
    local resource = Try(Ext.Resource.Get, soundId, "Sound")
    local event = resource and Try(function() return resource.SoundEvent end)
    if type(event) ~= "string" or event == "" then
        ClientLog.Add("ERROR Chime: sound resource " .. tostring(soundId) .. " not found")
        return false
    end

    local duration = Try(function() return resource.Duration end)
    local durationMs = (type(duration) == "number" and duration > 0) and math.floor(duration * 1000) or DEFAULT_DURATION_MS
    local before = ApplyVolume(volume, durationMs + VOLUME_MARGIN_MS)

    local logDetails = force or not chimeDetailsLogged
    if not chimeDetailsLogged then
        ProbeVolumes()
    end
    chimeDetailsLogged = true

    local played
    if Settings.Values.ChimeMethod == "client" then
        played = Try(Ext.Audio.PostEvent, SOUND_OBJECT, event)
        if played ~= true then
            -- The event may not be loaded yet.
            Try(Ext.Audio.LoadEvent, event)
            played = Try(Ext.Audio.PostEvent, SOUND_OBJECT, event)
        end
    else
        Common.Channels.Chime:SendToServer({ Sound = soundId, Log = logDetails })
        played = true
    end

    if logDetails then
        local override = volumeOverride
        ClientLog.Add(string.format("Chime: %s (%s) via %s, volume %d%%, %s on %s before %s, now %s, result %s",
            event, soundId, Settings.Values.ChimeMethod, volume, tostring(Settings.Values.VolumeRtpc),
            override and override.Object or "-", tostring(before),
            override and tostring(Try(Ext.Audio.GetRTPC, override.Object, override.Rtpc)) or "-", tostring(played)))
    end
    return played == true
end

--- Shows sample entries without a chime, at the current position (position sliders).
function Alert.Preview()
    lines = {}
    Alert.Show({
        { Name = "Test: Cloak of Protection", Rarity = 1, Amount = 1, TypeName = "Cloak" },
        { Name = "Test: Scroll of Haste", Rarity = 2, Amount = 2, TypeName = "Scroll" },
        { Name = "Test: Gloves of Dexterity", Rarity = 3, Amount = 1, TypeName = "Gloves" },
        { Name = "Test: Legendary Longbow", Rarity = 4, Amount = 1, TypeName = "Longbow" },
    })
end

--- Shows sample entries and plays the chime (Options: "Test").
function Alert.Test()
    Alert.Preview()
    Alert.Chime(true)
end

--- Fades the notice out at the end of its time; called every tick.
function Alert.Update()
    if not visible then
        return
    end
    local age = Ext.Timer.MonotonicTime() - shownAt
    if age >= SHOW_MS then
        Alert.Hide()
    elseif age >= SHOW_MS - FADE_MS then
        SetAlpha((SHOW_MS - age) / FADE_MS)
    end
end

--- Writes the game's UI-like sound resources to bg3_lootlog/sounds.txt once, to choose chimes from.
function Alert.WriteSoundList()
    if Ext.IO.LoadFile(SOUND_LIST_PATH) ~= nil then
        return
    end
    local ids = Try(Ext.Resource.GetAll, "Sound") or {}
    local rows = {}
    for _, id in ipairs(ids) do
        local resource = Try(Ext.Resource.Get, id, "Sound")
        local event = resource and Try(function() return resource.SoundEvent end)
        if type(event) == "string" then
            local lower = string.lower(event)
            for pattern in string.gmatch(SOUND_LIST_PATTERN, "[^|]+") do
                if string.find(lower, pattern, 1, true) then
                    local duration = Try(function() return resource.Duration end) or 0
                    rows[#rows + 1] = string.format("%-60s %6.2fs  %s", event, duration, id)
                    break
                end
            end
        end
    end
    table.sort(rows)
    Ext.IO.SaveFile(SOUND_LIST_PATH, string.format("%d of %d sound resources (event, duration, resource id)\n%s\n",
        #rows, #ids, table.concat(rows, "\n")))
    ClientLog.Add(string.format("Wrote %s: %d of %d sound resources", SOUND_LIST_PATH, #rows, #ids))
end

return Alert
