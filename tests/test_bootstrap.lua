-- Both bootstrap files load without errors and write the version line to the log files.

Harness.Mods[ModuleUUID] = { Info = { ModVersion = { 1, 0, 0, 0 } } }

Ext.Require("BootstrapServer.lua")
Ext.Require("BootstrapClient.lua")

Test("SessionLoaded writes the version to server.log and client.log", function()
    Ext.Events.SessionLoaded:Fire()
    Harness.RunTimers()
    AssertTrue(string.find(Harness.Files["bg3_lootlog/server.log"] or "", " 1.0.0.0 loaded.", 1, true), "server.log")
    AssertTrue(string.find(Harness.Files["bg3_lootlog/client.log"] or "", " 1.0.0.0 loaded.", 1, true), "client.log")
end)
