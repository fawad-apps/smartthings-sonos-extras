-- Minimal stand-ins for the modules the SmartThings Edge runtime provides, so
-- the real driver sources can be require()d and tested off-hub with plain Lua.
--
-- These are deliberately dumb: they record what the driver did rather than
-- simulating a hub. Anything a test needs to assert on is captured on the
-- stub's `calls` table.

local stubs = {}

-- log -----------------------------------------------------------------------
local log = { lines = {} }
local function record(level)
    return function(...)
        local parts = {}
        for i = 1, select('#', ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        table.insert(log.lines, { level = level, message = table.concat(parts, " ") })
    end
end
log.info, log.debug, log.warn, log.error, log.trace =
    record("info"), record("debug"), record("warn"), record("error"), record("trace")

-- st.capabilities -----------------------------------------------------------
-- Every capability/attribute resolves to a constructor that returns a plain
-- table describing the event, so tests can inspect emitted values.
local function attribute_table(cap_id)
    return setmetatable({ ID = cap_id }, {
        __index = function(_, attr)
            return setmetatable({ NAME = attr }, {
                __call = function(_, value)
                    return { capability = cap_id, attribute = attr, value = value }
                end,
                __index = function(_, state)
                    return function()
                        return { capability = cap_id, attribute = attr, value = state }
                    end
                end
            })
        end
    })
end

local capabilities = setmetatable({}, {
    __index = function(tbl, cap_id)
        local cap = attribute_table(cap_id)
        cap.commands = setmetatable({}, {
            __index = function(_, cmd) return { NAME = cmd } end
        })
        rawset(tbl, cap_id, cap)
        return cap
    end
})

-- UPnP ----------------------------------------------------------------------
local upnp = { calls = {}, discover_results = {} }
function upnp.discover(target, waittime, callback)
    table.insert(upnp.calls, { target = target, waittime = waittime })
    for _, devobj in ipairs(upnp.discover_results) do
        callback(devobj)
    end
end
function upnp.reset() end

-- cosock / sockets ----------------------------------------------------------
-- The clock advances only when a test says so. Freezing it at 0 meant every
-- TTL and cooldown in the driver (topology cache, favorites cache, reacquire
-- backoff) was untestable, because no elapsed time could ever be expressed.
local clock = { now = 0 }
local socket = {
    sleep = function() end,
    gettime = function() return clock.now end
}

-- Records every request so tests can assert on what the driver actually put on
-- the wire. `http.handler` lets a test answer with a canned body: the stubbed
-- ltn12 sink IS the chunk table, so a handler appends to req.sink.
local http = { requests = {}, handler = nil }
function http.request(req)
    table.insert(http.requests, req)
    if http.handler then
        return http.handler(req)
    end
    return nil, 599
end
function http.reset()
    http.requests = {}
    http.handler = nil
end
local cosock = {
    socket = socket,
    asyncify = function() return http end
}

-- ltn12 / xml ---------------------------------------------------------------
local ltn12 = {
    sink = { table = function(t) return t end },
    source = { string = function(s) return s end }
}
local tree = { new = function() return { root = {} } end }
local xml2lua = { parser = function() return { parse = function() end } end }

function stubs.install()
    package.loaded["log"] = log
    package.loaded["st.capabilities"] = capabilities
    package.loaded["st.driver"] = function() return {} end
    package.loaded["UPnP"] = upnp
    package.loaded["cosock"] = cosock
    package.loaded["cosock.socket"] = socket
    package.loaded["socket.http"] = http
    package.loaded["ltn12"] = ltn12
    package.loaded["xmlhandler.tree"] = tree
    package.loaded["xml2lua"] = xml2lua
    return stubs
end

-- Build a fake SmartThings device. `fields` seeds get_field/set_field.
function stubs.device(opts)
    opts = opts or {}
    local fields = opts.fields or {}
    local components = {}
    for _, id in ipairs(opts.components or { "main" }) do
        components[id] = { id = id }
    end

    local device = {
        id = opts.id or "test-device-id",
        device_network_id = opts.dni,
        parent_device_id = opts.parent_device_id,
        profile = { id = opts.profile_id or "test-profile", components = components },
        emitted = {},
        state = {},
        thread = { call_with_delay = function() end }
    }
    function device:get_field(name) return fields[name] end
    function device:set_field(name, value) fields[name] = value end
    function device:emit_component_event(component, event)
        table.insert(self.emitted, { component = component.id, event = event })
    end
    function device:online() self.state.online = true end
    function device:offline() self.state.online = false end
    function device:try_update_metadata(meta) self.state.metadata = meta end
    return device
end

stubs.log = log
stubs.upnp = upnp
stubs.capabilities = capabilities
stubs.http = http

-- Move the stubbed clock forward, so a test can express "and then 20 seconds
-- passed" and see a cache actually expire.
function stubs.advance(seconds)
    clock.now = clock.now + seconds
end

return stubs
