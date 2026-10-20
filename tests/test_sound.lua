-- The server plays the chime with the game's HUD sound call.

local Sound = Ext.Require("Server/Sound.lua")
Sound.Init()

local ITEM_RECEIVED = "48c6a208-8528-6bd4-8e95-2066979dc327"

Harness.UserCharacters[65537] = "S_Player_Tav_00000000-0000-0000-0000-000000000001"
Harness.HostCharacter = "S_Player_Host_00000000-0000-0000-0000-000000000002"

local function ServerLog()
    Harness.RunTimers()
    return Harness.Files["bg3_lootlog/server.log"] or ""
end

Test("The chime plays for the character of the asking client", function()
    Harness.Channels.Chime.MessageHandler({ Sound = ITEM_RECEIVED, Log = true }, 65536)
    AssertEq(#Harness.HudSounds, 1, "played once")
    AssertEq(Harness.HudSounds[1].Character, Harness.UserCharacters[65537], "client's character")
    AssertEq(Harness.HudSounds[1].Sound, ITEM_RECEIVED, "sound resource")
    AssertTrue(string.find(ServerLog(), "Chime: PlayHUDSoundResource(", 1, true), "logged on request")
end)

Test("Unknown clients fall back to the host character", function()
    Harness.Channels.Chime.MessageHandler({ Sound = ITEM_RECEIVED }, 999)
    AssertEq(Harness.HudSounds[2].Character, Harness.HostCharacter, "host")
end)

Test("Invalid requests are ignored", function()
    Harness.Channels.Chime.MessageHandler({ Sound = "not a guid" }, 65536)
    Harness.Channels.Chime.MessageHandler({}, 65536)
    Harness.Channels.Chime.MessageHandler("text", 65536)
    AssertEq(#Harness.HudSounds, 2, "nothing played")
end)
