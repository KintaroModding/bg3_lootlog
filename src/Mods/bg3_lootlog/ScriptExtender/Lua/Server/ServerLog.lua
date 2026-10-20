-- Messages and errors of the server side, readable outside the game: Script Extender\bg3_lootlog\server.log.

local FileWriter = Ext.Require("Shared/FileWriter.lua")

return FileWriter.NewLineFile("bg3_lootlog/server.log", 500)
