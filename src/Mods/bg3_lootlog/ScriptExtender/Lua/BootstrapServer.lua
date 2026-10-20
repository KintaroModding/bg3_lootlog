local Common = Ext.Require("Shared/Common.lua")
local ServerLog = Ext.Require("Server/ServerLog.lua")

Ext.Events.SessionLoaded:Subscribe(function()
    ServerLog.Add("Loot Log " .. Common.ModVersion() .. " loaded.")
end)

local Tracker = Ext.Require("Server/Tracker.lua")
Tracker.Init()

local Sound = Ext.Require("Server/Sound.lua")
Sound.Init()
