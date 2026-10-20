-- Test harness: small mocks of the Script Extender API, so the mod scripts run outside the game.
-- The runner provides these globals: MOD_LUA_ROOT (string), READ_FILE(path) -> string|nil, EXTUI_API (table).
--
-- The IMGUI mock is generated from the Script Extender IDE helpers (tests/extui_api.json): reading or writing a
-- property that the real API does not have, or passing a value of the wrong type, raises an error.

Harness = {
    Output = {},
    Errors = {},
    Files = {},
    Loca = {},
    Stats = {},
    Templates = {},
    Objects = {},
    ModVars = {},
    RegisteredVars = {},
    Channels = {},
    Listeners = {},
    ConsoleCommands = {},
    Timers = {},
    Windows = {},
    Elements = {},
    ElementData = {},
    Clock = 1700000000,
    Monotonic = 0,
}

ModuleUUID = "bee0663b-2f51-42f4-87ae-c016090080a8"

local UUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

---------------------------------------------------------------------------------------------------
-- Output and assertions
---------------------------------------------------------------------------------------------------

local function Join(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    return table.concat(parts, " ")
end

function _P(...)
    Harness.Output[#Harness.Output + 1] = Join(...)
end

function _PE(...)
    Harness.Errors[#Harness.Errors + 1] = Join(...)
end

function AssertEq(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message or "AssertEq", tostring(expected), tostring(actual)), 2)
    end
end

function AssertTrue(value, message)
    if not value then
        error(message or "AssertTrue failed", 2)
    end
end

function Harness.OutputContains(text)
    for _, line in ipairs(Harness.Output) do
        if string.find(line, text, 1, true) then
            return true
        end
    end
    return false
end

local tests = {}

function Test(name, fn)
    tests[#tests + 1] = { Name = name, Fn = fn }
end

--- Runs all registered tests in order. A test also fails when the mod printed an error with _PE.
function Harness.RunAll()
    local passed = 0
    local failures = {}
    for _, test in ipairs(tests) do
        local ok, err = xpcall(test.Fn, debug.traceback)
        if ok and #Harness.Errors > 0 then
            ok = false
            err = "the mod printed errors:\n" .. table.concat(Harness.Errors, "\n")
        end
        Harness.Errors = {}
        if ok then
            passed = passed + 1
        else
            failures[#failures + 1] = test.Name .. "\n" .. tostring(err)
        end
    end
    return passed, failures
end

---------------------------------------------------------------------------------------------------
-- Serialization (mod variables, net messages and JSON must only hold plain data)
---------------------------------------------------------------------------------------------------

local function DeepCopy(value, path)
    path = path or "value"
    local kind = type(value)
    if kind == "table" then
        local copy = {}
        for key, item in pairs(value) do
            if type(key) ~= "string" and type(key) ~= "number" then
                error(string.format("not serializable: key of type %s in %s", type(key), path), 2)
            end
            copy[key] = DeepCopy(item, path .. "." .. tostring(key))
        end
        return copy
    elseif kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then
        return value
    end
    error(string.format("not serializable: %s is a %s", path, kind), 2)
end

Harness.DeepCopy = DeepCopy

local jsonStore = {}

---------------------------------------------------------------------------------------------------
-- Module loading, events, ticks
---------------------------------------------------------------------------------------------------

local modules = {}

local function Require(path)
    local cached = modules[path]
    if cached == nil then
        local source = READ_FILE(MOD_LUA_ROOT .. "/" .. path)
        assert(source, "Ext.Require: file not found: " .. path)
        local chunk, err = load(source, "@" .. path, "t")
        assert(chunk, err)
        cached = chunk()
        if cached == nil then
            cached = true
        end
        modules[path] = cached
    end
    return cached
end

local function NewEvent(name)
    local event = { Name = name, Handlers = {} }
    function event:Subscribe(handler)
        assert(type(handler) == "function", name .. ":Subscribe needs a function")
        self.Handlers[#self.Handlers + 1] = handler
        return #self.Handlers
    end
    function event:Fire(data)
        for _, handler in ipairs(self.Handlers) do
            handler(data or {})
        end
    end
    return event
end

local nextTick = {}

--- Runs the callbacks queued with Ext.OnNextTick, then fires the Tick event.
function Harness.RunTick()
    local queue = nextTick
    nextTick = {}
    for _, fn in ipairs(queue) do
        fn()
    end
    Ext.Events.Tick:Fire({})
end

function Harness.RunTicks(count)
    for _ = 1, count or 3 do
        Harness.RunTick()
    end
end

--- Runs every pending timer once (Ext.Timer.WaitFor / WaitForRealtime).
function Harness.RunTimers()
    local timers = Harness.Timers
    Harness.Timers = {}
    for _, timer in ipairs(timers) do
        timer.Fn()
    end
end

---------------------------------------------------------------------------------------------------
-- Net channels
---------------------------------------------------------------------------------------------------

local function CreateChannel(module, name)
    assert(module == ModuleUUID, "Ext.Net.CreateChannel: wrong module " .. tostring(module))
    assert(Harness.Channels[name] == nil, "Ext.Net.CreateChannel: duplicate channel " .. name)

    local channel = { Name = name, Sent = {} }

    local function Record(self, kind, data, extra)
        assert(self == channel, "call channel methods with ':'")
        local message = { Kind = kind, Data = DeepCopy(data, name .. " payload") }
        for key, value in pairs(extra or {}) do
            message[key] = value
        end
        channel.Sent[#channel.Sent + 1] = message
    end

    function channel:SetHandler(fn)
        assert(self == channel and type(fn) == "function")
        channel.MessageHandler = fn
    end
    function channel:SetRequestHandler(fn)
        assert(self == channel and type(fn) == "function")
        channel.RequestHandler = fn
    end
    function channel:Broadcast(data) Record(self, "Broadcast", data) end
    function channel:SendToClient(data, user) Record(self, "SendToClient", data, { User = user }) end
    function channel:SendToServer(data) Record(self, "SendToServer", data) end
    function channel:RequestToServer(data, callback) Record(self, "RequestToServer", data, { Callback = callback }) end

    Harness.Channels[name] = channel
    return channel
end

---------------------------------------------------------------------------------------------------
-- Game world: objects, entities, Osiris
---------------------------------------------------------------------------------------------------

local handleCounter = 0
local templateIds = {}

--- Returns the root template UUID of a template name; the same name always gets the same UUID.
function Harness.TemplateUuid(templateName)
    local id = templateIds[templateName]
    if id == nil then
        local count = 0
        for _ in pairs(templateIds) do
            count = count + 1
        end
        id = string.format("7e000000-0000-0000-0000-%012d", count + 1)
        templateIds[templateName] = id
    end
    return id
end

--- Adds a character, container or item.
--- Options: Holder, Player, Party, Container, Template, Amount, Story, Tags ({[guid]=true}), BookId, Equipped,
--- Components.
function Harness.AddObject(uuid, kind, name, options)
    options = options or {}
    handleCounter = handleCounter + 1
    local handle = string.format("h%08xg0000g0000g0000g000000000000", handleCounter)
    Harness.Loca[handle] = name

    local object = {
        Uuid = uuid,
        Kind = kind,
        Name = name,
        Handle = handle .. ";1",
        Holder = options.Holder,
        Player = options.Player,
        Party = options.Party,
        Container = options.Container or kind ~= "item",
        Template = options.Template or ("TPL_" .. string.gsub(name, "%W", "_")),
        Amount = options.Amount or 1,
        Story = options.Story,
        Tags = options.Tags,
        BookId = options.BookId,
        Equipped = options.Equipped,
        Components = options.Components or {},
    }
    Harness.Objects[uuid] = object
    return object
end

--- Destroys an object (sold to Loot Autoseller, used up, merged into another stack).
function Harness.RemoveObject(uuid)
    Harness.Objects[uuid] = nil
end

--- Returns "Name_uuid" of the root template of an object, as Osiris passes it.
function Harness.TemplateString(uuid)
    local template = Harness.Objects[uuid].Template
    return template .. "_" .. Harness.TemplateUuid(template)
end

function Harness.GuidString(uuid)
    local object = Harness.Objects[uuid]
    return (object and object.Template or "Destroyed") .. "_" .. uuid
end

local function FindObject(guidString)
    if type(guidString) ~= "string" then
        return nil
    end
    local uuid = string.match(guidString, "(" .. UUID_PATTERN .. ")$")
    return uuid and Harness.Objects[uuid]
end

local function TopObject(object)
    local current = object
    for _ = 1, 20 do
        if current.Holder == nil then
            return current
        end
        current = Harness.Objects[current.Holder]
    end
    error("holder loop")
end

function Harness.BuildEntity(uuid)
    local object = Harness.Objects[uuid]
    if object == nil then
        return nil
    end

    local entity = {}
    for name, component in pairs(object.Components) do
        entity[name] = component
    end
    entity.Uuid = { EntityUuid = uuid }

    if object.Container then
        local items = {}
        for itemUuid, other in pairs(Harness.Objects) do
            if other.Holder == uuid then
                items[#items + 1] = { Item = Harness.BuildEntity(itemUuid), field_8 = 0 }
            end
        end
        entity.InventoryOwner = { Inventories = { { InventoryContainer = { Items = items } } } }
    end
    return entity
end

Osi = setmetatable({
    GetDisplayName = function(guid)
        local object = FindObject(guid)
        return object and object.Handle
    end,
    IsCharacter = function(guid)
        local object = FindObject(guid)
        return (object and object.Kind == "character") and 1 or 0
    end,
    IsPlayer = function(guid)
        local object = FindObject(guid)
        return (object and object.Player) and 1 or 0
    end,
    IsPartyMember = function(guid, _)
        local object = FindObject(guid)
        return (object and object.Party) and 1 or 0
    end,
    GetTemplate = function(guid)
        local object = FindObject(guid)
        return object and Harness.TemplateString(object.Uuid)
    end,
    Exists = function(guid)
        return FindObject(guid) and 1 or 0
    end,
    GetInventoryOwner = function(guid)
        local object = FindObject(guid)
        if object == nil or object.Holder == nil then
            return nil
        end
        return Harness.GuidString(TopObject(object).Uuid)
    end,
    GetDirectInventoryOwner = function(guid)
        local object = FindObject(guid)
        if object == nil or object.Holder == nil then
            return nil
        end
        return Harness.GuidString(object.Holder)
    end,
    IsEquipped = function(guid)
        local object = FindObject(guid)
        return (object and object.Equipped) and 1 or 0
    end,
    GetStackAmount = function(guid)
        local object = FindObject(guid)
        if object == nil then
            return nil
        end
        return object.Amount, object.Amount
    end,
    IsStoryItem = function(guid)
        local object = FindObject(guid)
        return (object and object.Story) and 1 or 0
    end,
    GetOriginalOwner = function(_)
        return nil
    end,
    IsTagged = function(guid, tag)
        local object = FindObject(guid)
        return (object and object.Tags and object.Tags[tag]) and 1 or 0
    end,
    GetBookID = function(guid)
        local object = FindObject(guid)
        return object and object.BookId
    end,
    GetCurrentCharacter = function(userId)
        return Harness.UserCharacters[userId]
    end,
    GetHostCharacter = function()
        return Harness.HostCharacter
    end,
    PlayHUDSoundResource = function(character, resource)
        Harness.HudSounds[#Harness.HudSounds + 1] = { Character = character, Sound = resource }
    end,
    DB_Players = {
        Get = function(self, _)
            assert(self == Osi.DB_Players, "call DB_Players:Get with ':'")
            local rows = {}
            for uuid, object in pairs(Harness.Objects) do
                if object.Player then
                    rows[#rows + 1] = { Harness.GuidString(uuid) }
                end
            end
            return rows
        end,
    },
}, {
    __index = function(_, key)
        error("Osi." .. tostring(key) .. " is not mocked", 2)
    end,
})

function Harness.FireAddedTo(itemUuid, holderUuid, addType)
    Harness.Listeners["TemplateAddedTo/4"](Harness.TemplateString(itemUuid),
        Harness.GuidString(itemUuid), Harness.GuidString(holderUuid), addType or "Regular")
end

--- Osiris StackedWith: item merged into the stack of other.
function Harness.FireStackedWith(itemUuid, otherUuid)
    Harness.Listeners["StackedWith/2"](Harness.GuidString(itemUuid), Harness.GuidString(otherUuid))
end

function Harness.FireRemovedFrom(itemUuid, holderUuid)
    Harness.Listeners["RemovedFrom/2"](Harness.GuidString(itemUuid), Harness.GuidString(holderUuid))
end

--- Moves an item and fires the Osiris events. order = "added-first" fires TemplateAddedTo before RemovedFrom.
function Harness.Move(itemUuid, newHolder, addType, order)
    local oldHolder = Harness.Objects[itemUuid].Holder
    if order == "added-first" then
        Harness.Objects[itemUuid].Holder = newHolder
        Harness.FireAddedTo(itemUuid, newHolder, addType)
        if oldHolder then
            Harness.FireRemovedFrom(itemUuid, oldHolder)
        end
    else
        if oldHolder then
            Harness.FireRemovedFrom(itemUuid, oldHolder)
        end
        Harness.Objects[itemUuid].Holder = newHolder
        Harness.FireAddedTo(itemUuid, newHolder, addType)
    end
end

---------------------------------------------------------------------------------------------------
-- IMGUI (validated against the real API definitions)
---------------------------------------------------------------------------------------------------

local API = EXTUI_API

local function FieldType(className, key)
    local class = API.classes[className]
    while class do
        local declared = class.fields[key]
        if declared then
            return declared
        end
        class = class.parent and API.classes[class.parent] or nil
    end
    return nil
end

local function IsAliasValue(aliasName, value)
    if type(value) ~= "string" then
        return type(value) == "number" or type(value) == "table"
    end
    for _, item in pairs(API.aliases[aliasName]) do
        if item == value then
            return true
        end
    end
    return false
end

local function CheckValue(where, declared, value)
    local optional = string.sub(declared, -1) == "?"
    local base = optional and string.sub(declared, 1, -2) or declared
    if value == nil then
        if not optional then
            error(where .. ": nil is not allowed for " .. declared, 3)
        end
        return
    end

    local ok = true
    if base == "boolean" then
        ok = type(value) == "boolean"
    elseif base == "string" or base == "FixedString" or base == "StringView" then
        ok = type(value) == "string"
    elseif base == "number" or string.match(base, "^u?int%d*$") then
        ok = type(value) == "number"
    elseif string.match(base, "%[%]$") or string.match(base, "^i?vec%d$") then
        ok = type(value) == "table"
    elseif base == "RegistryEntry" then
        ok = type(value) == "function"
    elseif API.aliases[base] then
        ok = IsAliasValue(base, value)
    end
    if not ok then
        error(string.format("%s: expected %s, got %s (%s)", where, declared, type(value), tostring(value)), 3)
    end
end

local function ParseSignature(signature)
    local params = {}
    for part in string.gmatch(string.match(signature, "^fun%((.-)%)") or "", "[^,]+") do
        local name, declared = string.match(part, "^%s*([%w_]+)%s*:%s*(.-)%s*$")
        if name and name ~= "self" then
            params[#params + 1] = declared
        end
    end
    return params, string.match(signature, "%)%s*:%s*([%w_]+)")
end

local INITIAL_VALUES = {
    AddCheckbox = function(values, args) values.Checked = args[2] == true end,
    AddInputText = function(values, args) values.Text = args[2] or "" end,
    AddSliderInt = function(values, args) values.Value = { args[2] or 0, 0, 0, 0 } end,
}

local NewElement

local function MakeMethod(element, data, key, declared)
    local params, returnType = ParseSignature(declared)
    return function(self, ...)
        if self ~= element then
            error(string.format("IMGUI mock: call %s:%s with ':'", data.Class, key), 2)
        end
        if data.Destroyed then
            error(string.format("IMGUI mock: %s:%s called on a destroyed element", data.Class, key), 2)
        end

        local args = table.pack(...)
        if args.n > #params then
            error(string.format("IMGUI mock: %s:%s takes %d arguments, got %d", data.Class, key, #params, args.n), 2)
        end
        for i, param in ipairs(params) do
            CheckValue(string.format("%s:%s argument %d", data.Class, key, i), param, args[i])
        end

        -- The last call of each method, for tests (Harness.ElementData[element].Calls.SetPos).
        data.Calls[key] = args

        if key == "Destroy" then
            data.Destroyed = true
            return nil
        end

        if returnType and (API.classes[returnType] or returnType == "ImguiHandle" or string.match(returnType, "^Extui")) then
            local childClass = API.classes[returnType] and returnType or "ExtuiStyledRenderable"
            local child = NewElement(childClass, type(args[1]) == "string" and args[1] or nil)
            if INITIAL_VALUES[key] then
                INITIAL_VALUES[key](Harness.ElementData[child].Values, args)
            end
            Harness.ElementData[child].Parent = element
            data.Children[#data.Children + 1] = child
            return child
        end
        return nil
    end
end

NewElement = function(className, label)
    assert(API.classes[className], "IMGUI mock: unknown class " .. tostring(className))
    local data = { Class = className, Values = { Label = label }, Children = {}, Destroyed = false, Calls = {} }
    local element = {}
    Harness.ElementData[element] = data
    Harness.Elements[#Harness.Elements + 1] = element

    setmetatable(element, {
        __index = function(_, key)
            local declared = FieldType(className, key)
            if declared == nil then
                error(string.format("IMGUI mock: %s has no member '%s'", className, tostring(key)), 2)
            end
            if string.sub(declared, 1, 4) == "fun(" then
                return MakeMethod(element, data, key, declared)
            end
            return data.Values[key]
        end,
        __newindex = function(_, key, value)
            local declared = FieldType(className, key)
            if declared == nil then
                error(string.format("IMGUI mock: %s has no member '%s'", className, tostring(key)), 2)
            end
            if string.sub(declared, 1, 4) == "fun(" then
                error(string.format("IMGUI mock: %s.%s is a method", className, key), 2)
            end
            if data.Destroyed then
                error(string.format("IMGUI mock: write to %s.%s after Destroy()", className, key), 2)
            end
            CheckValue(className .. "." .. key, declared, value)
            data.Values[key] = value
        end,
    })
    return element
end

--- Returns the first live element of a class with the given label.
function Harness.Find(className, label)
    for _, element in ipairs(Harness.Elements) do
        local data = Harness.ElementData[element]
        if data.Class == className and not data.Destroyed and data.Values.Label == label then
            return element
        end
    end
    return nil
end

--- Returns the live table of the window, or nil.
function Harness.LiveTable()
    local found = nil
    for _, element in ipairs(Harness.Elements) do
        local data = Harness.ElementData[element]
        if data.Class == "ExtuiTable" and not data.Destroyed then
            assert(found == nil, "more than one live table")
            found = element
        end
    end
    return found
end

--- Returns the rows of a table as lists of cell texts. Images in a cell are reported as "[img]".
function Harness.TableRows(tbl)
    local rows = {}
    for _, row in ipairs(Harness.ElementData[tbl].Children) do
        if Harness.ElementData[row].Class == "ExtuiTableRow" then
            local cells = {}
            for _, cell in ipairs(Harness.ElementData[row].Children) do
                local parts = {}
                for _, child in ipairs(Harness.ElementData[cell].Children) do
                    local data = Harness.ElementData[child]
                    if data.Class == "ExtuiText" then
                        parts[#parts + 1] = data.Values.Label
                    elseif data.Class == "ExtuiImage" then
                        parts[#parts + 1] = "[img]"
                    end
                end
                cells[#cells + 1] = table.concat(parts, " ")
            end
            rows[#rows + 1] = cells
        end
    end
    return rows
end

---------------------------------------------------------------------------------------------------
-- Ext
---------------------------------------------------------------------------------------------------

Ext = {
    Require = Require,

    OnNextTick = function(fn)
        assert(type(fn) == "function", "Ext.OnNextTick needs a function")
        nextTick[#nextTick + 1] = fn
    end,

    RegisterConsoleCommand = function(name, fn)
        Harness.ConsoleCommands[name] = fn
    end,

    Events = setmetatable({}, {
        __index = function(events, name)
            local event = NewEvent(name)
            rawset(events, name, event)
            return event
        end,
    }),

    Timer = {
        ClockEpoch = function() return Harness.Clock end,
        ClockTime = function() return "2026-10-12 21:00:00.0000000" end,
        MonotonicTime = function() return Harness.Monotonic end,
        WaitFor = function(ms, fn)
            Harness.Timers[#Harness.Timers + 1] = { Ms = ms, Fn = fn }
            return #Harness.Timers
        end,
        WaitForRealtime = function(ms, fn)
            Harness.Timers[#Harness.Timers + 1] = { Ms = ms, Fn = fn }
            return #Harness.Timers
        end,
    },

    Vars = {
        RegisterModVariable = function(module, name, options)
            assert(module == ModuleUUID, "RegisterModVariable: wrong module")
            Harness.RegisteredVars[name] = options
        end,
        GetModVariables = function(module)
            assert(module == ModuleUUID, "GetModVariables: wrong module")
            return setmetatable({}, {
                __index = function(_, key)
                    return Harness.ModVars[key]
                end,
                __newindex = function(_, key, value)
                    assert(Harness.RegisteredVars[key], "mod variable is not registered: " .. tostring(key))
                    Harness.ModVars[key] = DeepCopy(value, key)
                end,
            })
        end,
    },

    Net = {
        CreateChannel = CreateChannel,
    },

    IO = {
        LoadFile = function(path)
            return Harness.Files[path]
        end,
        SaveFile = function(path, content)
            assert(type(content) == "string", "SaveFile needs a string")
            Harness.Files[path] = content
            return true
        end,
    },

    Json = {
        Stringify = function(value)
            jsonStore[#jsonStore + 1] = DeepCopy(value)
            return "json:" .. #jsonStore
        end,
        Parse = function(text)
            local id = tonumber(string.match(text, "^json:(%d+)$"))
            if id == nil then
                error("Ext.Json.Parse: invalid JSON")
            end
            return DeepCopy(jsonStore[id])
        end,
    },

    Loca = {
        GetTranslatedString = function(handle)
            return Harness.Loca[handle] or ""
        end,
    },

    Stats = {
        Get = function(id)
            return Harness.Stats[id]
        end,
    },

    Template = {
        GetRootTemplate = function(id)
            return Harness.Templates[id]
        end,
    },

    Entity = {
        Get = function(uuid)
            return Harness.BuildEntity(uuid)
        end,
        GetAllEntitiesWithComponent = function(name)
            local result = {}
            for uuid, object in pairs(Harness.Objects) do
                if object.Components[name] then
                    result[#result + 1] = Harness.BuildEntity(uuid)
                end
            end
            return result
        end,
    },

    Osiris = {
        RegisterListener = function(name, arity, when, fn)
            assert(when == "before" or when == "after", "RegisterListener: bad event type")
            assert(type(fn) == "function", "RegisterListener: handler must be a function")
            Harness.Listeners[name .. "/" .. arity] = fn
        end,
    },

    IMGUI = setmetatable({}, {
        __index = function(_, key)
            local declared = FieldType("Ext_ClientIMGUI", key)
            if declared == nil then
                error("Ext.IMGUI has no member '" .. tostring(key) .. "'", 2)
            end
            if key == "NewWindow" then
                return function(label)
                    assert(type(label) == "string", "NewWindow needs a label")
                    local window = NewElement("ExtuiWindow", label)
                    Harness.Windows[#Harness.Windows + 1] = window
                    return window
                end
            end
            if key == "GetViewportSize" then
                return function() return { 1920, 1080 } end
            end
            return function() end
        end,
    }),

    -- Records every call. GetRTPC returns the value set before, else Harness.DefaultRtpc.
    Audio = setmetatable({}, {
        __index = function(_, key)
            if FieldType("Ext_ClientAudio", key) == nil then
                error("Ext.Audio has no member '" .. tostring(key) .. "'", 2)
            end
            return function(...)
                local args = table.pack(...)
                Harness.AudioCalls[#Harness.AudioCalls + 1] = { Name = key, Args = args }
                local rtpcKey = tostring(args[1]) .. "/" .. tostring(args[2])
                if key == "GetRTPC" then
                    return Harness.Rtpc[rtpcKey] or Harness.DefaultRtpc
                elseif key == "SetRTPC" then
                    Harness.Rtpc[rtpcKey] = args[3]
                elseif key == "ResetRTPC" then
                    Harness.Rtpc[rtpcKey] = nil
                    return nil
                elseif key == "PostEvent" and Harness.FailNextPostEvent then
                    Harness.FailNextPostEvent = false
                    return false
                end
                return true
            end
        end,
    }),

    Resource = setmetatable({}, {
        __index = function(_, key)
            if FieldType("Ext_Resource", key) == nil then
                error("Ext.Resource has no member '" .. tostring(key) .. "'", 2)
            end
            if key == "Get" then
                return function(id, bank)
                    return (Harness.Resources[bank] or {})[id]
                end
            end
            return function(bank)
                local ids = {}
                for id in pairs(Harness.Resources[bank] or {}) do
                    ids[#ids + 1] = id
                end
                table.sort(ids)
                return ids
            end
        end,
    }),
}

Harness.AudioCalls = {}
Harness.Rtpc = {}
Harness.DefaultRtpc = 80
Harness.Resources = { Sound = {} }
Harness.UserCharacters = {}
Harness.HostCharacter = nil
Harness.HudSounds = {}
-- [moduleUuid] = { Info = { ModVersion = { 1, 0, 0, 0 } } }
Harness.Mods = {}

Ext.Mod = {
    GetMod = function(uuid)
        return Harness.Mods[uuid]
    end,
}

--- Returns the recorded Ext.Audio calls with the given name.
function Harness.AudioCallsNamed(name)
    local calls = {}
    for _, call in ipairs(Harness.AudioCalls) do
        if call.Name == name then
            calls[#calls + 1] = call
        end
    end
    return calls
end
