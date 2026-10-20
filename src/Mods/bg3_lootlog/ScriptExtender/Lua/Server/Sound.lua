-- Plays the chime for a client with the game's own HUD sound call (PlayHUDSoundResource).

local Common = Ext.Require("Shared/Common.lua")
local events = Ext.Require("Server/ServerLog.lua")

local Sound = {}

local UUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

--- Returns the character that the client with this net peer id controls (the host character as fallback).
local function CharacterOfPeer(peerId)
    if type(peerId) == "number" then
        -- Osiris user ids are the peer id with 1 in the low 16 bits.
        local userId = ((math.tointeger(peerId) or 0) & 0xffff0000) | 1
        local character = Try(function() return Osi.GetCurrentCharacter(userId) end)
        if character then
            return character
        end
    end
    return Try(function() return Osi.GetHostCharacter() end)
end

function Sound.Init()
    Common.Channels.Chime:SetHandler(function(data, peerId)
        if type(data) ~= "table" or type(data.Sound) ~= "string" or not string.match(data.Sound, UUID_PATTERN) then
            return
        end
        local character = CharacterOfPeer(peerId)
        if character == nil then
            events.Add("ERROR Chime: no character for peer " .. tostring(peerId))
            return
        end
        local ok, err = pcall(function() Osi.PlayHUDSoundResource(character, data.Sound) end)
        if not ok then
            events.Add("ERROR Chime: PlayHUDSoundResource failed: " .. tostring(err))
        elseif data.Log then
            events.Add(string.format("Chime: PlayHUDSoundResource(%s, %s)", tostring(character), data.Sound))
        end
    end)
end

return Sound
