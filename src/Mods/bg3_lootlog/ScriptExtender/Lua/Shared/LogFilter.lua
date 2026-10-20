-- Filtering and formatting of log entries. Pure functions without engine calls, so the tests can load this file directly.

local LogFilter = {}

--- Returns true when the entry passes the filter.
--- @param entry table Log entry
--- @param filter table { Categories = {[id]=bool}, MinRarity = int, MinValue = int, Search = string }
--- @return boolean
function LogFilter.Passes(entry, filter)
    local categories = filter.Categories or {}
    if categories[entry.Category or "Other"] == false then
        return false
    end

    if (entry.Rarity or 0) < (filter.MinRarity or 0) then
        return false
    end

    local minValue = filter.MinValue or 0
    if minValue > 0 and (entry.Value or 0) < minValue then
        return false
    end

    local search = filter.Search or ""
    if search ~= "" then
        local haystack = string.lower(table.concat({ entry.Name or "", entry.TypeName or "", entry.Owner or "",
            entry.Where or "", entry.From or "" }, "\n"))
        if not string.find(haystack, string.lower(search), 1, true) then
            return false
        end
    end

    return true
end

--- Returns up to maxRows matching entries (newest first) and the total number of matches.
--- @param entries table[] Log entries, oldest first
--- @param filter table See LogFilter.Passes
--- @param maxRows integer
--- @return table[] rows
--- @return integer matches
function LogFilter.Collect(entries, filter, maxRows)
    local rows = {}
    local matches = 0
    for i = #entries, 1, -1 do
        local entry = entries[i]
        if LogFilter.Passes(entry, filter) then
            matches = matches + 1
            if #rows < maxRows then
                rows[#rows + 1] = entry
            end
        end
    end
    return rows, matches
end

--- Formats an age in seconds as a short label: "now", "45s", "12m", "3h" or "2d".
--- @param seconds number|nil
--- @return string
function LogFilter.FormatAge(seconds)
    if seconds == nil then
        return ""
    elseif seconds < 5 then
        return "now"
    elseif seconds < 60 then
        return string.format("%ds", math.floor(seconds))
    elseif seconds < 3600 then
        return string.format("%dm", math.floor(seconds / 60))
    elseif seconds < 86400 then
        return string.format("%dh", math.floor(seconds / 3600))
    end
    return string.format("%dd", math.floor(seconds / 86400))
end

return LogFilter
