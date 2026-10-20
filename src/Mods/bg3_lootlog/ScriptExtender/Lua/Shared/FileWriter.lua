-- Throttled file output in the Script Extender folder (%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender).
-- Touch() schedules one write after the delay; more touches during the delay share that write. The content is built
-- when the write happens, so it is always current.

local FileWriter = {}

--- @param path string Path relative to the Script Extender folder
--- @param delayMs number Real-time delay before the write
--- @param build fun():string Builds the file content
function FileWriter.New(path, delayMs, build)
    local writer = { Path = path, Scheduled = false }

    local function Write()
        writer.Scheduled = false
        local ok, err = pcall(function()
            Ext.IO.SaveFile(path, build())
        end)
        if not ok then
            _PE("[LootLog] Could not write " .. path .. ": " .. tostring(err))
        end
    end

    function writer:Touch()
        if self.Scheduled then
            return
        end
        self.Scheduled = true
        Ext.Timer.WaitForRealtime(delayMs, Write)
    end

    return writer
end

--- Returns a line list that keeps the newest maxLines lines and writes them to a text file.
--- @param path string
--- @param maxLines integer
function FileWriter.NewLineFile(path, maxLines)
    local lines = {}
    local writer = FileWriter.New(path, 1000, function()
        return table.concat(lines, "\n") .. "\n"
    end)

    local lineFile = {}

    function lineFile.Add(message)
        -- ClockTime is UTC with fractions of a second: "2026-10-12 21:07:42.1234567".
        lines[#lines + 1] = string.sub(Ext.Timer.ClockTime(), 1, 19) .. " UTC  " .. message
        while #lines > maxLines do
            table.remove(lines, 1)
        end
        writer:Touch()
    end

    return lineFile
end

return FileWriter
