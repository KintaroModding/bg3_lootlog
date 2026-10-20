local Common = Ext.Require("Shared/Common.lua")
local ClientLog = Ext.Require("Client/ClientLog.lua")

Ext.Events.SessionLoaded:Subscribe(function()
    ClientLog.Add("Loot Log " .. Common.ModVersion() .. " loaded.")
end)

local Window = Ext.Require("Client/Window.lua")
Window.Init()
