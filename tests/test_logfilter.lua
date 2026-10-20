local LogFilter = Ext.Require("Shared/LogFilter.lua")

local function Entry(name, category, rarity, value, owner, from)
    return { Name = name, Category = category, Rarity = rarity, Value = value, Owner = owner, From = from }
end

local NO_FILTER = { Categories = {}, MinRarity = 0, MinValue = 0, Search = "" }

Test("Passes: category, rarity and value", function()
    local filter = { Categories = { Food = false }, MinRarity = 1, MinValue = 50, Search = "" }
    AssertEq(LogFilter.Passes(Entry("Bread", "Food", 3, 100), filter), false, "hidden category")
    AssertEq(LogFilter.Passes(Entry("Sword", "Weapon", 0, 100), filter), false, "rarity below minimum")
    AssertEq(LogFilter.Passes(Entry("Sword", "Weapon", 1, 10), filter), false, "value below minimum")
    AssertEq(LogFilter.Passes(Entry("Sword", "Weapon", 1, 50), filter), true, "passes")
    AssertEq(LogFilter.Passes(Entry("Sword", "Weapon", 1, nil), NO_FILTER), true, "no value needed without minimum")
    AssertEq(LogFilter.Passes({ Name = "Odd" }, NO_FILTER), true, "entry without fields")
end)

Test("Search matches name, owner, place and source, ignoring case", function()
    local entry = Entry("Ring of Protection", "Jewelry", 3, 900, "Karlach", "Goblin Boss")
    entry.Where = "Shadowheart > Jewellery Box"
    local function Search(text)
        return LogFilter.Passes(entry, { Categories = {}, MinRarity = 0, MinValue = 0, Search = text })
    end
    AssertEq(Search("ring"), true, "name")
    AssertEq(Search("KARL"), true, "owner")
    AssertEq(Search("jewellery box"), true, "place")
    AssertEq(Search("goblin"), true, "source")
    AssertEq(Search("gale"), false, "no match")
    AssertEq(Search("(%"), false, "pattern characters are plain text")
end)

Test("Collect returns the newest entries first and counts all matches", function()
    local entries = {}
    for i = 1, 10 do
        entries[i] = Entry("Item " .. i, i % 2 == 0 and "Weapon" or "Food", 0, 1)
    end
    local rows, matches = LogFilter.Collect(entries, { Categories = { Food = false }, MinRarity = 0, MinValue = 0, Search = "" }, 3)
    AssertEq(matches, 5, "matches")
    AssertEq(#rows, 3, "rows limited")
    AssertEq(rows[1].Name, "Item 10", "newest first")
    AssertEq(rows[3].Name, "Item 6", "third row")
end)

Test("FormatAge", function()
    AssertEq(LogFilter.FormatAge(nil), "", "nil")
    AssertEq(LogFilter.FormatAge(-3), "now", "clock skew")
    AssertEq(LogFilter.FormatAge(4), "now", "now")
    AssertEq(LogFilter.FormatAge(45), "45s", "seconds")
    AssertEq(LogFilter.FormatAge(125), "2m", "minutes")
    AssertEq(LogFilter.FormatAge(7300), "2h", "hours")
    AssertEq(LogFilter.FormatAge(3 * 86400 + 5), "3d", "days")
end)
