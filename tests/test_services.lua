-- Tests for the request shape of the driver: what it puts on the wire, when,
-- and how often.
--
-- These exist because the driver was slow rather than wrong. A refresh issued
-- ~20 sequential requests on the same thread that serves every user tap - two
-- of them the largest payloads Sonos returns, one of them fetched three times
-- over - so a tap landing during a refresh waited for all of it.

package.path = "src/?.lua;src/?/init.lua;tests/?.lua;" .. package.path

local stubs = require("stubs").install()
local t = require("runner")

local upnp_services = require("upnp_services")

local ARC_SSDP_UUID = "RINCON_74CA60D0A14C01400_MR"
local ARC = "RINCON_74CA60D0A14C01400"
local BEDROOM = "RINCON_949F3E8CE16601400"

local function read_fixture(name)
    local f = assert(io.open("tests/fixtures/" .. name), "missing fixture " .. name)
    local body = f:read("a")
    f:close()
    return body
end

-- ---------------------------------------------------------------------------
-- Harness: a player that answers UPnP commands and raw SOAP posts
-- ---------------------------------------------------------------------------

local function xml_escape(s)
    return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

local function member(uuid, name)
    return string.format(
        '<ZoneGroupMember UUID="%s" Location="http://192.168.2.109:1400/xml/device_description.xml"' ..
        ' ZoneName="%s" Invisible="0"/>', uuid, name)
end

local function topology(coordinator, members)
    return '<ZoneGroups><ZoneGroup Coordinator="' .. coordinator .. '" ID="' .. coordinator ..
        ':1">' .. table.concat(members) .. '</ZoneGroup></ZoneGroups>'
end

local STANDALONE = topology(ARC, { member(ARC, "Living Room") })
local ARC_IS_A_GUEST = topology(BEDROOM, { member(BEDROOM, "Main Bedroom"), member(ARC, "Living Room") })

-- The topology arrives as escaped XML inside the SOAP body, which is exactly
-- the shape the pattern reader has to cope with.
local function zone_group_response(inner)
    return '<s:Envelope><s:Body><u:GetZoneGroupStateResponse><ZoneGroupState>' ..
        xml_escape(inner) .. '</ZoneGroupState></u:GetZoneGroupStateResponse></s:Body></s:Envelope>'
end

local device_seq = 0

-- A device whose UPnP commands and SOAP posts are both recorded. `bodies` maps
-- a SOAP action to the response body the player should answer with; anything
-- unlisted fails the way an unreachable player would.
local function fake_player(bodies, components)
    device_seq = device_seq + 1
    local calls = { commands = {}, deferred = {} }

    local upnpdev = {
        uuid = ARC_SSDP_UUID,
        ip = "192.168.2.109",
        port = "1400",
        online = true,
        command = function(_, _, cmd)
            table.insert(calls.commands, cmd.action)
            return nil
        end
    }

    local device = stubs.device({
        id = "device-" .. device_seq,
        dni = ARC_SSDP_UUID,
        components = components or { "main", "PartyMode" },
        fields = { upnpdevice = upnpdev }
    })
    device.thread.call_with_delay = function(_, delay, fn)
        table.insert(calls.deferred, { delay = delay, fn = fn })
    end

    stubs.http.reset()
    stubs.http.handler = function(req)
        local action = req.headers.SOAPACTION:match("#(.+)$")
        local body = bodies and bodies[action]
        if not body then
            return nil, 599
        end
        table.insert(req.sink, body)
        return 1, 200
    end

    return device, calls
end

local function soap_actions()
    local actions = {}
    for _, req in ipairs(stubs.http.requests) do
        table.insert(actions, req.headers.SOAPACTION:match("#(.+)$"))
    end
    return actions
end

local function count_action(name)
    local n = 0
    for _, action in ipairs(soap_actions()) do
        if action == name then
            n = n + 1
        end
    end
    return n
end

local function request_body(action)
    for _, req in ipairs(stubs.http.requests) do
        if req.headers.SOAPACTION:match("#(.+)$") == action then
            return req.source
        end
    end
    return nil
end

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Refresh is split: cheap controls now, heavy payloads afterwards
-- ---------------------------------------------------------------------------

t.test("refresh reads the visible controls immediately", function()
    local device, calls = fake_player()
    upnp_services.refresh_components(device)

    t.truthy(contains(calls.commands, "GetVolume"), "volume read inline")
    t.truthy(contains(calls.commands, "GetMute"), "mute read inline")
    t.truthy(contains(calls.commands, "GetTransportInfo"), "transport read inline")
    t.truthy(contains(calls.commands, "GetBass"), "bass read inline")
end)

t.test("refresh does not fetch topology or favorites on the command path", function()
    -- Both are large and slow; doing them inline is what made a tap during a
    -- refresh wait seconds for its turn on the device thread.
    local device, calls = fake_player()
    upnp_services.refresh_components(device)

    t.eq(count_action("GetZoneGroupState"), 0, "topology not fetched inline")
    t.eq(count_action("Browse"), 0, "favorites not fetched inline")
    t.eq(#calls.deferred, 1, "heavy half queued exactly once")
end)

t.test("the deferred half is what fetches topology and favorites", function()
    local device, calls = fake_player({
        GetZoneGroupState = zone_group_response(STANDALONE),
        Browse = read_fixture("favorites_browse.xml")
    })
    upnp_services.refresh_components(device)
    calls.deferred[1].fn()

    t.truthy(count_action("GetZoneGroupState") > 0, "topology fetched when deferred")
    t.eq(count_action("Browse"), 1, "favorites fetched when deferred")
end)

-- ---------------------------------------------------------------------------
-- Topology: read with patterns, fetched once per burst
-- ---------------------------------------------------------------------------

t.test("zone topology is read straight out of the SOAP body", function()
    -- Read with patterns rather than a tree parser: the payload is the whole
    -- household as escaped XML, and parsing tens of KB of it on the hub costs
    -- far more than the round trip.
    local device = fake_player({ GetZoneGroupState = zone_group_response(ARC_IS_A_GUEST) })
    upnp_services.get_group_state(device)

    local emitted = device.emitted[#device.emitted]
    t.eq(emitted.component, "PartyMode", "party switch updated")
    t.eq(emitted.event.value, "on", "grouped topology reads as party mode on")
end)

t.test("topology is fetched once for every consumer in a refresh", function()
    -- Party switch, mediaGroup and the room children all need it; three
    -- separate fetches of the biggest payload Sonos serves is pure latency.
    local device = fake_player({ GetZoneGroupState = zone_group_response(STANDALONE) })
    upnp_services.get_group_state(device)
    upnp_services.get_media_group(device)

    t.eq(count_action("GetZoneGroupState"), 1, "one topology fetch for two consumers")
end)

t.test("invalidating the topology forces a fresh read", function()
    -- Anything that regroups speakers must not leave the old layout cached.
    local device = fake_player({ GetZoneGroupState = zone_group_response(STANDALONE) })
    upnp_services.get_group_state(device)
    upnp_services.invalidate_topology(device)
    upnp_services.get_group_state(device)

    t.eq(count_action("GetZoneGroupState"), 2, "re-read after invalidation")
end)

-- ---------------------------------------------------------------------------
-- Favorites are cached
-- ---------------------------------------------------------------------------

t.test("favorites are not re-browsed on every refresh", function()
    local device = fake_player({ Browse = read_fixture("favorites_browse.xml") })
    upnp_services.get_presets(device)
    upnp_services.get_presets(device)

    t.eq(count_action("Browse"), 1, "second refresh reuses the cached favorites")
end)

t.test("a refresh the user asked for re-reads the favorites", function()
    -- You add a favorite in the Sonos app, then pull to refresh here. Serving
    -- that from a 15-minute cache would look like the driver was broken.
    local device, calls = fake_player({ Browse = read_fixture("favorites_browse.xml") })
    upnp_services.get_presets(device)

    upnp_services.refresh_components(device, true)
    calls.deferred[1].fn()

    t.eq(count_action("Browse"), 2, "user refresh bypasses the favorites cache")
end)

t.test("playing an unknown preset still forces a fresh browse", function()
    -- Otherwise a favorite added after the cache filled could never be played.
    local device = fake_player({ Browse = read_fixture("favorites_browse.xml") })
    upnp_services.get_presets(device)
    upnp_services.get_presets(device, true)

    t.eq(count_action("Browse"), 2, "forced browse ignores the cache")
end)

t.test("a favorite the player refuses does not get a Play fired after it", function()
    -- Sonos answers a refused music-service favorite with a SOAP fault. Carrying
    -- on regardless sent Play at a transport that had never been loaded, so the
    -- log showed two failures and neither said the favorite was the problem.
    local device = fake_player({ Browse = read_fixture("favorites_browse.xml") })
    upnp_services.get_presets(device)
    upnp_services.play_preset(device, "FV:2/2") -- a direct-URI favorite

    t.eq(count_action("Play"), 0, "no Play once the transport failed to load")
end)

t.test("a refused container favorite is not followed by the queue switch", function()
    local device = fake_player({ Browse = read_fixture("favorites_browse.xml") })
    upnp_services.get_presets(device)
    upnp_services.play_preset(device, "FV:2/0") -- a playlist container

    t.truthy(count_action("AddURIToQueue") > 0, "enqueue was attempted")
    t.eq(count_action("SetAVTransportURI"), 0, "queue not selected after a failed enqueue")
    t.eq(count_action("Play"), 0, "no Play")
end)

-- ---------------------------------------------------------------------------
-- Now playing: a metadata-less event must not wipe the tile
-- ---------------------------------------------------------------------------

local function lastchange(body)
    return { LastChange = "<Event><InstanceID val=\"0\">" .. body .. "</InstanceID></Event>" }
end

t.test("an event with a URI but no metadata does not emit Unknown", function()
    -- Sonos announces the new URI before it has metadata for it. Emitting on
    -- that replaced a real now-playing with "Unknown" and dropped the album
    -- art - exactly what the tile showed while music was playing.
    local device, calls = fake_player()
    upnp_services.avtransport_event_callback(device, "sid", 1,
        lastchange('<CurrentTrackURI val="x-sonos-http:librarytrack.mp4"/>'))

    t.eq(#device.emitted, 0, "nothing emitted from a metadata-less event")
    t.eq(#calls.deferred, 1, "the real track data is asked for instead")
end)

t.test("a URI that names its own source is emitted without a poll", function()
    -- TV audio and line-in never carry metadata, so waiting for it would mean
    -- the tile never says what the soundbar is playing.
    local device, calls = fake_player()
    upnp_services.avtransport_event_callback(device, "sid", 1,
        lastchange('<AVTransportURI val="x-sonos-htastream:' .. ARC .. ':spdif"/>'))

    t.eq(device.emitted[1].event.value.title, "TV Audio", "TV source named from the URI alone")
    t.eq(#calls.deferred, 0, "no poll needed")
end)

t.test("an event carrying real metadata is emitted straight away", function()
    local device, calls = fake_player()
    local didl = "&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;Home Again&lt;/dc:title&gt;" ..
        "&lt;dc:creator&gt;Michael Kiwanuka&lt;/dc:creator&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;"
    upnp_services.avtransport_event_callback(device, "sid", 1,
        lastchange('<CurrentTrackMetaData val="' .. didl .. '"/>'))

    t.eq(device.emitted[1].event.value.title, "Home Again", "title from the event")
    t.eq(#calls.deferred, 0, "no poll when the event already had the metadata")
end)

-- ---------------------------------------------------------------------------
-- TV mode
-- ---------------------------------------------------------------------------

t.test("the TV stream URI uses the bare player uuid", function()
    -- "x-sonos-htastream:RINCON_..._MR:spdif" is rejected by Sonos, so the
    -- soundbar would simply stay on whatever was playing.
    t.eq(upnp_services.tv_uri(ARC), "x-sonos-htastream:" .. ARC .. ":spdif", "tv uri")
end)

t.test("TV mode sets the TV stream on the soundbar and plays it", function()
    local device, calls = fake_player({
        GetZoneGroupState = zone_group_response(STANDALONE),
        SetAVTransportURI = "<s:Envelope><s:Body/></s:Envelope>"
    })
    upnp_services.play_tv(device)

    local body = request_body("SetAVTransportURI")
    t.truthy(body, "transport URI was set")
    t.truthy(body:find("x-sonos-htastream:" .. ARC .. ":spdif", 1, true), "TV stream URI sent")
    t.truthy(contains(calls.commands, "Play"), "playback started")
end)

t.test("TV mode leaves a group the soundbar is only a guest in", function()
    -- As a guest its transport belongs to the group's coordinator, so setting
    -- the TV stream on it would do nothing at all.
    local device, calls = fake_player({
        GetZoneGroupState = zone_group_response(ARC_IS_A_GUEST),
        SetAVTransportURI = "<s:Envelope><s:Body/></s:Envelope>"
    })
    upnp_services.play_tv(device)

    t.truthy(contains(calls.commands, "BecomeCoordinatorOfStandaloneGroup"), "left the group")
end)

t.test("TV mode does not break up a group the soundbar leads", function()
    -- Standalone or coordinating Party Mode, splitting would throw every other
    -- room out of the group the user just made.
    local device, calls = fake_player({
        GetZoneGroupState = zone_group_response(STANDALONE),
        SetAVTransportURI = "<s:Envelope><s:Body/></s:Envelope>"
    })
    upnp_services.play_tv(device)

    t.falsy(contains(calls.commands, "BecomeCoordinatorOfStandaloneGroup"), "group left alone")
end)

t.run()
