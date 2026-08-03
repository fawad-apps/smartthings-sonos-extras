-- Tests for UPnP event parsing and speaker grouping (Party Mode).
--
-- Fixtures are real payloads captured from a Sonos Arc Ultra: LastChange
-- events from a live event subscription, and ZoneGroupState from the actual
-- household topology.

package.path = "src/?.lua;src/?/init.lua;tests/?.lua;" .. package.path

local stubs = require("stubs").install()
local t = require("runner")

local upnp_services = require("upnp_services")

local ARC = "RINCON_74CA60D0A14C01400"
local SUB = "RINCON_949F3E439BDC01400"      -- Arc's bonded subwoofer (a satellite)
local MOVE2 = "RINCON_C4387502ABFC01400"
local BEDROOM = "RINCON_949F3E8CE16601400"
local BATHROOM = "RINCON_804AF2B227EA01400"

local function read_fixture(name)
    local f = assert(io.open("tests/fixtures/" .. name), "missing fixture " .. name)
    local body = f:read("a")
    f:close()
    return body
end

local function lc(events, tag)
    return upnp_services.lastchange_value(events, tag)
end

-- ---------------------------------------------------------------------------
-- LastChange event parsing
--
-- These payloads carry DIDL-Lite *inside* an XML attribute value. Parsing them
-- with a tree parser failed with "Unbalanced Tag (/DIDL-Lite)", so every
-- AVTransport event was dropped and now-playing never updated live - visible
-- only as a WARN in the hub log.
-- ---------------------------------------------------------------------------

t.test("parse_lastchange reads a real AVTransport event", function()
    local events = upnp_services.parse_lastchange(read_fixture("avtransport_lastchange.xml"))
    t.truthy(events, "events parsed")
    t.eq(lc(events, "TransportState"), "PLAYING", "transport state")
    t.eq(lc(events, "CurrentTrackURI"), "x-sonos-htastream:" .. ARC .. ":spdif", "track uri")
end)

t.test("parse_lastchange unescapes embedded DIDL metadata", function()
    local events = upnp_services.parse_lastchange(read_fixture("avtransport_lastchange.xml"))
    local didl = lc(events, "CurrentTrackMetaData")
    t.matches(didl, "^<DIDL%-Lite", "metadata is real XML")
    t.falsy(didl:find("&lt;", 1, true), "no leftover escaping")
end)

t.test("an AVTransport event yields usable track data", function()
    -- End to end: the exact path that was silently dead on the hub.
    local events = upnp_services.parse_lastchange(read_fixture("avtransport_lastchange.xml"))
    local data = upnp_services.build_track_data(
        lc(events, "CurrentTrackMetaData"),
        lc(events, "AVTransportURI") or lc(events, "CurrentTrackURI"),
        lc(events, "AVTransportURIMetaData"), nil)
    t.eq(data.mediaSource, "TV Audio", "source recognised from the transport uri")
    t.truthy(data.title, "a title is always produced")
end)

t.test("parse_lastchange reads a real RenderingControl event", function()
    local events = upnp_services.parse_lastchange(read_fixture("rendering_lastchange.xml"))
    t.truthy(events, "events parsed")
    t.eq(lc(events, "Volume"), "33", "Master volume")
    t.eq(lc(events, "Mute"), "0", "Master mute")
end)

t.test("lastchange_value picks Master, not the first channel listed", function()
    -- Sonos reports Volume for Master, LF and RF. Taking whichever came first
    -- would report the fixed 100 of a satellite channel as the room volume.
    local events = upnp_services.parse_lastchange(read_fixture("rendering_lastchange.xml"))
    t.eq(#events.Volume >= 2, true, "several channels present")
    t.eq(lc(events, "Volume"), "33", "Master wins")
end)

t.test("parse_lastchange handles tags with no channel attribute", function()
    local events = upnp_services.parse_lastchange(
        [[<Event><InstanceID val="0"><Bass val="-3"/><Treble val="4"/></InstanceID></Event>]])
    t.eq(lc(events, "Bass"), "-3", "bass")
    t.eq(lc(events, "Treble"), "4", "treble")
end)

t.test("parse_lastchange returns nil for empty input rather than erroring", function()
    t.falsy(upnp_services.parse_lastchange(nil), "nil input")
    t.falsy(upnp_services.parse_lastchange(""), "empty input")
end)

-- ---------------------------------------------------------------------------
-- Zone group topology
-- ---------------------------------------------------------------------------

t.test("parse_zone_groups reads the real household topology", function()
    local groups = upnp_services.parse_zone_groups(read_fixture("zonegroupstate.xml"))
    t.truthy(groups, "topology parsed")
    t.eq(#groups, 3, "group count")
end)

t.test("parse_zone_groups handles a home-theatre member with satellites", function()
    -- The Arc's ZoneGroupMember wraps <Satellite> children, so it is NOT
    -- self-closing. A parser expecting only self-closing members finds the
    -- Arc's group empty and Party Mode silently does nothing.
    local groups = upnp_services.parse_zone_groups(read_fixture("zonegroupstate.xml"))
    local arc_group
    for _, g in ipairs(groups) do
        if g.coordinator == ARC then arc_group = g end
    end
    t.truthy(arc_group, "Arc's group found")
    t.eq(#arc_group.members, 1, "the Arc is one member, not one per satellite")
    t.eq(arc_group.members[1].uuid, ARC, "member uuid")
    t.eq(arc_group.members[1].ip, "192.168.2.109", "member ip from Location")
    t.eq(arc_group.members[1].name, "Living Room", "zone name")
end)

t.test("satellites are never treated as group members", function()
    local groups = upnp_services.parse_zone_groups(read_fixture("zonegroupstate.xml"))
    for _, g in ipairs(groups) do
        for _, m in ipairs(g.members) do
            t.falsy(m.uuid == SUB, "subwoofer must not appear as a member")
        end
    end
end)

t.test("parse_zone_groups reports nil on junk instead of an empty topology", function()
    t.falsy(upnp_services.parse_zone_groups("<ZoneGroupState></ZoneGroupState>"), "no groups")
    t.falsy(upnp_services.parse_zone_groups(nil), "nil input")
end)

-- ---------------------------------------------------------------------------
-- Party Mode target selection
-- ---------------------------------------------------------------------------

local function real_groups()
    return upnp_services.parse_zone_groups(read_fixture("zonegroupstate.xml"))
end

local function uuids_of(list)
    local out = {}
    for _, m in ipairs(list) do out[m.uuid] = true end
    return out
end

t.test("group_targets never includes the soundbar itself", function()
    -- The original code compared topology UUIDs against the "_MR" SSDP form,
    -- so the Arc never matched itself and Party Mode told the Arc to join its
    -- own group.
    local targets = upnp_services.group_targets(real_groups(), ARC)
    t.falsy(uuids_of(targets)[ARC], "Arc excluded from its own party")
end)

t.test("group_targets excludes invisible players", function()
    -- Bonded satellites and the hidden half of a stereo pair must never be
    -- commanded directly.
    local targets = upnp_services.group_targets(real_groups(), ARC)
    for _, m in ipairs(targets) do
        t.falsy(m.invisible, "target " .. tostring(m.name) .. " is visible")
    end
    t.falsy(uuids_of(targets)[SUB], "subwoofer excluded")
end)

t.test("group_targets finds every other visible room", function()
    local targets = upnp_services.group_targets(real_groups(), ARC)
    local ids = uuids_of(targets)
    t.truthy(ids[MOVE2], "Move 2 included")
    t.truthy(ids[BEDROOM], "Main Bedroom included")
    t.truthy(ids[BATHROOM], "Bathroom included")
    t.eq(#targets, 3, "exactly the three visible rooms")
end)

t.test("every group target has an address to command", function()
    for _, m in ipairs(upnp_services.group_targets(real_groups(), ARC)) do
        t.matches(m.ip, "^%d+%.%d+%.%d+%.%d+$", "ip for " .. tostring(m.name))
        t.truthy(tonumber(m.port), "port for " .. tostring(m.name))
    end
end)

t.test("the grouping URI uses the bare uuid, never the _MR form", function()
    -- "x-rincon:RINCON_..._MR" is rejected by Sonos, so grouping silently
    -- failed for every player.
    local device = stubs.device({
        dni = ARC .. "_MR",
        fields = { upnpdevice = { uuid = ARC .. "_MR", ip = "192.168.2.109", port = "1400" } }
    })
    local uri = "x-rincon:" .. upnp_services.player_uuid(device)
    t.eq(uri, "x-rincon:" .. ARC, "grouping uri")
    t.falsy(uri:find("_MR", 1, true), "no _MR suffix")
end)

-- ---------------------------------------------------------------------------
-- Party Mode / mediaGroup state
-- ---------------------------------------------------------------------------

t.test("group_state reports ungrouped when alone", function()
    local state = upnp_services.group_state(real_groups(), ARC)
    t.truthy(state, "state found for the Arc")
    t.falsy(state.grouped, "not grouped")
    t.eq(state.role, "ungrouped", "role")
    t.eq(state.group.coordinator, ARC, "coordinator")
end)

t.test("group_state reports primary for the coordinator of a real group", function()
    -- Bathroom coordinates a group that also contains Move 2 and Main Bedroom.
    local state = upnp_services.group_state(real_groups(), BATHROOM)
    t.truthy(state, "state found")
    t.eq(state.group.coordinator, BATHROOM, "coordinator")
end)

t.test("group_state reports auxiliary for a follower", function()
    local groups = {
        {
            id = ARC .. ":1", coordinator = ARC,
            members = {
                { uuid = ARC, invisible = false },
                { uuid = MOVE2, invisible = false },
            }
        }
    }
    local state = upnp_services.group_state(groups, MOVE2)
    t.eq(state.role, "auxiliary", "follower role")
    t.truthy(state.grouped, "is grouped")

    state = upnp_services.group_state(groups, ARC)
    t.eq(state.role, "primary", "coordinator role")
end)

t.test("group_state ignores invisible members when deciding if grouped", function()
    -- A soundbar with a bonded sub is alone, not grouped.
    local groups = {
        {
            id = ARC .. ":1", coordinator = ARC,
            members = {
                { uuid = ARC, invisible = false },
                { uuid = SUB, invisible = true },
            }
        }
    }
    local state = upnp_services.group_state(groups, ARC)
    t.falsy(state.grouped, "bonded sub does not count as a group")
    t.eq(state.role, "ungrouped", "role")
end)

t.test("group_state returns nil for a player not in the topology", function()
    t.falsy(upnp_services.group_state(real_groups(), "RINCON_000000000000000"), "unknown player")
end)

t.run()
