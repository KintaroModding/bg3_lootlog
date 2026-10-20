local ItemInfo = Ext.Require("Server/ItemInfo.lua")

local function Id(n)
    return string.format("00000000-0000-0000-0000-%012d", n)
end

Test("Uuid and TemplateName parse Osiris strings", function()
    AssertEq(ItemInfo.Uuid("WPN_Longsword_" .. Id(5)), Id(5), "prefixed")
    AssertEq(ItemInfo.Uuid(Id(5)), Id(5), "bare")
    AssertEq(ItemInfo.Uuid("not a guid"), nil, "invalid")
    AssertEq(ItemInfo.Uuid(nil), nil, "nil")
    AssertEq(ItemInfo.TemplateName("LOOT_Gold_A_" .. Id(7)), "LOOT_Gold_A", "template name")
    AssertEq(ItemInfo.TemplateName(Id(7)), nil, "no name part")
end)

Test("Categories come from the item components", function()
    local cases = {
        { "Gold", { IsGold = {} } },
        { "Weapon", { Weapon = {}, Equipable = { Slot = "MeleeMainHand" } } },
        { "Weapon", { Equipable = { Slot = "RangedMainHand" } } },
        { "Weapon", { Weapon = {}, IsStoryItem = {} } },
        { "Jewelry", { Equipable = { Slot = "Ring" }, Armor = {} } },
        { "Jewelry", { Equipable = { Slot = "Amulet" } } },
        { "Clothing", { Equipable = { Slot = "VanityBody" }, Armor = {} } },
        { "Armor", { Equipable = { Slot = "Breast" }, Armor = {} } },
        { "Armor", { Equipable = { Slot = "MeleeOffHand" }, Armor = { Shield = true } } },
        { "Other", { Equipable = { Slot = "MusicalInstrument" } } },
        { "Key", { Key = { Key = "KEY_Test" } } },
        { "Quest", { IsStoryItem = {} } },
        { "Food", { CampSupply = { Amount = 5 }, Use = { ItemUseType = "Consumable" } } },
        { "Potion", { Use = { ItemUseType = "Potion" } } },
        { "Potion", { Use = { ItemUseType = "Consumable" } } },
        { "Scroll", { Use = { ItemUseType = "Scroll" } } },
        { "Ammo", { Use = { ItemUseType = "Arrow" } } },
        { "Ammo", { Use = { ItemUseType = "Grenade" } } },
        { "Other", { Use = { ItemUseType = "None" } } },
        { "Other", {} },
    }
    for i, case in ipairs(cases) do
        local uuid = Id(100 + i)
        Harness.AddObject(uuid, "item", "Case " .. i, { Components = case[2] })
        AssertEq(ItemInfo.GetCategory(uuid, Ext.Entity.Get(uuid), nil, "TPL_Case"), case[1], "case " .. i)
    end

    local story = Id(150)
    Harness.AddObject(story, "item", "Story note", { Story = true })
    AssertEq(ItemInfo.GetCategory(story, Ext.Entity.Get(story), nil, "TPL"), "Quest", "story item from Osiris")
    AssertEq(ItemInfo.GetCategory(Id(151), nil, nil, "LOOT_Gold_A"), "Gold", "gold by template name")
    AssertEq(ItemInfo.GetCategory(Id(152), nil, { ModifierList = "Armor" }, "TPL"), "Armor", "stats fallback")
end)

Test("Rarity comes from the stats entry first, then from the Value component", function()
    AssertEq((ItemInfo.GetRarity(nil, { Rarity = "VeryRare" })), 3, "stats VeryRare")
    AssertEq((ItemInfo.GetRarity(nil, { Rarity = "Legendary" })), 4, "stats Legendary")
    AssertEq((ItemInfo.GetRarity({ Value = { Rarity = 2 } }, nil)), 1, "value 2 = Uncommon")
    AssertEq((ItemInfo.GetRarity({ Value = { Rarity = 4 } }, { Rarity = "Strange" })), 3, "unknown stats name falls back")
    AssertEq((ItemInfo.GetRarity({ Value = { Rarity = 1 } }, nil)), 5, "value 1 = Unique")
    AssertEq((ItemInfo.GetRarity(nil, nil)), 0, "nothing known")
end)

Test("Describe builds a complete entry from a live item", function()
    local uuid = Id(200)
    Harness.Stats["WPN_Test"] = { Rarity = "Rare", ModifierList = "Weapon" }
    Harness.AddObject(uuid, "item", "Test Blade", {
        Amount = 2,
        Components = {
            Weapon = {},
            Data = { StatsId = "WPN_Test" },
            Value = { Value = 120, Rarity = 3 },
            Icon = { Icon = "Item_WPN_Test" },
        },
    })

    local entry = ItemInfo.Describe(uuid, "WPN_Test_Template_" .. Id(999))
    AssertEq(entry.Name, "Test Blade", "name")
    AssertEq(entry.Category, "Weapon", "category")
    AssertEq(entry.Rarity, 2, "rarity")
    AssertEq(entry.RarityName, "Rare", "rarity name")
    AssertEq(entry.Amount, 2, "amount")
    AssertEq(entry.Value, 120, "value")
    AssertEq(entry.Icon, "Item_WPN_Test", "icon")
    AssertEq(entry.StatsId, "WPN_Test", "stats id")
    AssertEq(entry.Epoch, Harness.Clock, "time")
    Harness.DeepCopy(entry)
end)

Test("Describe falls back to the root template when the item is gone", function()
    local templateId = Id(300)
    Harness.Templates[templateId] = {
        DisplayName = { Get = function() return "Merged Arrow" end },
        Stats = "ARR_Test",
        Icon = "Item_ARR_Test",
    }
    Harness.Stats["ARR_Test"] = { Rarity = "Uncommon", ModifierList = "Object" }

    local entry = ItemInfo.Describe(Id(301), "ARR_Fire_" .. templateId)
    AssertEq(entry.Name, "Merged Arrow", "name")
    AssertEq(entry.Rarity, 1, "rarity")
    AssertEq(entry.Category, "Other", "category")
    AssertEq(entry.Amount, 1, "amount")
    AssertEq(entry.Icon, "Item_ARR_Test", "icon")

    local unknown = ItemInfo.Describe(Id(302), "Mystery_Thing_" .. Id(303))
    AssertEq(unknown.Name, "Mystery_Thing", "template name as last resort")
end)

Test("Object names prefer a custom name", function()
    local uuid = Id(400)
    Harness.AddObject(uuid, "character", "Tav", { Components = { CustomName = { Name = "Kintaro" } } })
    AssertEq(ItemInfo.GetObjectName(uuid), "Kintaro", "custom name")
    local other = Id(401)
    Harness.AddObject(other, "character", "Karlach")
    AssertEq(ItemInfo.GetObjectName(other), "Karlach", "display name")
    AssertEq(ItemInfo.GetObjectName(nil), nil, "nil")
end)

Test("DebugSummary does not fail on sparse data", function()
    local uuid = Id(500)
    Harness.AddObject(uuid, "item", "Plain")
    AssertTrue(string.find(ItemInfo.DebugSummary(uuid), "history", 1, true), "summary text")
    AssertTrue(string.find(ItemInfo.DebugSummary(Id(501)), "history", 1, true), "missing item")
end)

Test("Type names for the subtext", function()
    local nextId = 600
    local function TypeOf(components, stat, category, options)
        nextId = nextId + 1
        options = options or {}
        options.Components = components
        Harness.AddObject(Id(nextId), "item", "Thing " .. nextId, options)
        return ItemInfo.GetTypeName(Id(nextId), Ext.Entity.Get(Id(nextId)), stat, category)
    end
    local FOOD = "c86e0114-a5ab-48f6-b497-de321ebff577"
    local INGREDIENT = "64b824e7-50c5-475a-98c2-52026e372d77"

    AssertEq(TypeOf({ Weapon = {} }, { ["Proficiency Group"] = { "Longswords", "MartialWeapons" } }, "Weapon"),
        "Longsword", "weapon from a flag list")
    AssertEq(TypeOf({ Weapon = {} }, { ["Proficiency Group"] = "HandCrossbows;MartialWeapons" }, "Weapon"),
        "Hand Crossbow", "weapon from a flag string")
    AssertEq(TypeOf({ Weapon = {} }, { ["Proficiency Group"] = { [1] = "Warpicks" } }, "Weapon"), "War Pick", "two words")
    AssertEq(TypeOf({ Weapon = {} }, nil, "Weapon"), "Weapon", "unknown weapon")
    AssertEq(TypeOf({ Equipable = { Slot = "Cloak" }, Armor = {} }, nil, "Armor"), "Cloak", "cloak")
    AssertEq(TypeOf({ Equipable = { Slot = "Ring2" } }, nil, "Jewelry"), "Ring", "ring")
    AssertEq(TypeOf({ Equipable = { Slot = "Helmet" }, Armor = {} }, nil, "Armor"), "Helmet", "helmet")
    AssertEq(TypeOf({ Equipable = { Slot = "Breast" }, Armor = {} }, { ["Proficiency Group"] = { "MediumArmor" } }, "Armor"),
        "Medium Armour", "body armour")
    AssertEq(TypeOf({ Equipable = { Slot = "Breast" }, Armor = {} }, nil, "Armor"), "Clothing", "clothes")
    AssertEq(TypeOf({ Equipable = { Slot = "MeleeOffHand" }, Armor = { Shield = true } }, nil, "Armor"), "Shield", "shield")
    AssertEq(TypeOf({ Equipable = { Slot = "VanityBody" } }, nil, "Clothing"), "Camp Clothes", "camp clothes")
    AssertEq(TypeOf({ Equipable = { Slot = "MusicalInstrument" } }, nil, "Other"), "Instrument", "instrument")
    AssertEq(TypeOf({ Use = { ItemUseType = "Potion" } }, nil, "Potion"), "Potion", "potion")
    AssertEq(TypeOf({ Use = { ItemUseType = "Arrow" } }, nil, "Ammo"), "Arrow", "arrow")
    AssertEq(TypeOf({}, nil, "Gold"), "Gold", "gold")
    AssertEq(TypeOf({}, nil, "Key"), "Key", "key")
    AssertEq(TypeOf({}, nil, "Quest"), "Story Item", "story item")
    AssertEq(TypeOf({ CampSupply = {} }, nil, "Food", { Tags = { [FOOD] = true } }), "Food", "food tag")
    AssertEq(TypeOf({ CampSupply = {} }, nil, "Food"), "Camp Supplies", "drink or supplies")
    AssertEq(TypeOf({}, nil, "Other", { BookId = "BOOK_Test" }), "Book", "book")
    AssertEq(TypeOf({}, nil, "Other", { Tags = { [INGREDIENT] = true } }), "Ingredient", "ingredient")
    AssertEq(TypeOf({}, { ObjectCategory = "Junk" }, "Other"), "Junk", "stats category")
    AssertEq(TypeOf({}, { ObjectCategory = "PreciousStone" }, "Other"), "Precious Stone", "split words")
    AssertEq(TypeOf({}, { ObjectCategory = "Gem_Rare_1" }, "Other"), nil, "odd stats category ignored")
    AssertEq(TypeOf({}, nil, "Other"), nil, "nothing known")
end)

Test("Describe adds the type name", function()
    Harness.Stats["WPN_Typed"] = { Rarity = "Uncommon", ModifierList = "Weapon", ["Proficiency Group"] = { "Scimitars" } }
    Harness.AddObject(Id(700), "item", "Curved Blade", { Components = { Weapon = {}, Data = { StatsId = "WPN_Typed" } } })
    local entry = ItemInfo.Describe(Id(700), "WPN_Typed_" .. Id(701))
    AssertEq(entry.TypeName, "Scimitar", "type name")
    local Common = Ext.Require("Shared/Common.lua")
    AssertEq(Common.Subtext(entry), "Uncommon Scimitar", "subtext")
    AssertEq(Common.Subtext({ Rarity = 0 }), "Common", "subtext without type")
end)
