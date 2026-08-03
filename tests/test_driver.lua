-- Regression tests for the Sonos Extras driver.
--
-- Run with: scripts/test.sh   (or: lua tests/test_driver.lua from the repo root)
--
-- Every case here corresponds to a failure that actually reached the hub and
-- was painful to diagnose, because the driver failed silently rather than
-- reporting anything.

package.path = "src/?.lua;src/?/init.lua;tests/?.lua;" .. package.path

local stubs = require("stubs").install()
local t = require("runner")

local upnp_services = require("upnp_services")

local ARC_SSDP_UUID = "RINCON_74CA60D0A14C01400_MR" -- what SSDP advertises
local ARC_PLAYER_UUID = "RINCON_74CA60D0A14C01400"  -- what ZoneGroupTopology uses
local ARC_MAC = "74CA60D0A14C"                      -- SmartThings' Sonos driver DNI
local HUB_DEVICE_ID = "4204ac73-fdd4-4e85-824a-ffa2435c4dee"

local function read_fixture(name)
    local f = assert(io.open("tests/fixtures/" .. name), "missing fixture " .. name)
    local body = f:read("a")
    f:close()
    return body
end

local function device_with_uuid(dni, upnp_uuid)
    return stubs.device({
        dni = dni,
        fields = upnp_uuid and { upnpdevice = { uuid = upnp_uuid, ip = "192.168.2.109", port = "1400" } } or {}
    })
end

-- ---------------------------------------------------------------------------
-- Player identity
--
-- SSDP finds the MediaRenderer sub-device, whose UDN has an "_MR" suffix, but
-- ZoneGroupTopology members and "x-rincon:" grouping URIs use the bare UUID.
-- Mixing them up made every grouping URI malformed and meant the soundbar
-- never excluded itself from its own group.
-- ---------------------------------------------------------------------------

t.test("player_uuid strips the _MR suffix SSDP reports", function()
    local device = device_with_uuid(ARC_SSDP_UUID, ARC_SSDP_UUID)
    t.eq(upnp_services.player_uuid(device), ARC_PLAYER_UUID, "canonical uuid")
end)

t.test("player_uuid leaves an already-bare uuid alone", function()
    local device = device_with_uuid(ARC_PLAYER_UUID, ARC_PLAYER_UUID)
    t.eq(upnp_services.player_uuid(device), ARC_PLAYER_UUID, "canonical uuid")
end)

t.test("player_uuid derives the uuid from a bare-MAC DNI", function()
    -- A device adopted from SmartThings' Sonos driver has the MAC as its DNI
    -- and no UPnP handle yet.
    local device = device_with_uuid(ARC_MAC, nil)
    t.eq(upnp_services.player_uuid(device), ARC_PLAYER_UUID, "uuid from MAC")
end)

t.test("player_uuid accepts a lowercase MAC DNI", function()
    local device = device_with_uuid(ARC_MAC:lower(), nil)
    t.eq(upnp_services.player_uuid(device), ARC_PLAYER_UUID, "uuid from lowercase MAC")
end)

t.test("id_matches links a bare-MAC DNI to its SSDP uuid", function()
    t.truthy(upnp_services.id_matches(ARC_MAC, ARC_SSDP_UUID), "MAC vs SSDP uuid")
    t.truthy(upnp_services.id_matches(ARC_MAC:lower(), ARC_SSDP_UUID), "lowercase MAC")
    t.truthy(upnp_services.id_matches(ARC_SSDP_UUID, ARC_SSDP_UUID), "exact match")
end)

t.test("id_matches rejects a different player's MAC", function()
    -- Guards against a DNI matching whichever speaker answers SSDP first.
    t.falsy(upnp_services.id_matches("949F3E8CE166", ARC_SSDP_UUID), "other speaker's MAC")
end)

-- ---------------------------------------------------------------------------
-- Room-child detection
--
-- THE regression that silently killed the whole driver: SmartThings sets
-- parent_device_id to the HUB for every LAN device, so testing it made the
-- soundbar look like a room-group child. device_init took the child branch,
-- never ran discovery, and every command then failed with "Missing upnpdevice"
-- while refresh quietly did nothing at all.
-- ---------------------------------------------------------------------------

local function command_handlers_with_spy()
    local spy = { calls = {} }
    local fake = setmetatable({ VOLUME_STEP = 5 }, {
        __index = function(_, name)
            return function(...)
                table.insert(spy.calls, name)
                return nil
            end
        end
    })
    package.loaded["upnp_services"] = fake
    package.loaded["command_handlers"] = nil
    local handlers = require("command_handlers")
    package.loaded["upnp_services"] = upnp_services -- restore for other tests
    return handlers, spy
end

t.test("refresh on the soundbar refreshes components, not a room", function()
    local handlers, spy = command_handlers_with_spy()
    local soundbar = stubs.device({
        dni = ARC_SSDP_UUID,
        parent_device_id = HUB_DEVICE_ID, -- the platform really does set this
    })
    handlers.refresh(nil, soundbar)
    t.eq(spy.calls[1], "refresh_components", "handler chosen for the soundbar")
end)

t.test("refresh on a MAC-DNI soundbar refreshes components", function()
    local handlers, spy = command_handlers_with_spy()
    local adopted = stubs.device({ dni = ARC_MAC, parent_device_id = HUB_DEVICE_ID })
    handlers.refresh(nil, adopted)
    t.eq(spy.calls[1], "refresh_components", "handler chosen for adopted device")
end)

t.test("refresh on a room-group child refreshes the room", function()
    local handlers, spy = command_handlers_with_spy()
    local child = stubs.device({
        dni = ARC_PLAYER_UUID .. ":group:RINCON_949F3E8CE16601400",
        parent_device_id = "some-parent-device-id",
    })
    handlers.refresh(nil, child)
    t.eq(spy.calls[1], "refresh_room", "handler chosen for the child")
end)

t.test("switch on the soundbar sets EQ, does not join a room", function()
    local handlers, spy = command_handlers_with_spy()
    local soundbar = stubs.device({ dni = ARC_SSDP_UUID, parent_device_id = HUB_DEVICE_ID })
    handlers.switch_on(nil, soundbar, { component = "NightMode" })
    t.eq(spy.calls[1], "set_switch_eq", "NightMode routes to EQ")
end)

t.test("the momentary buttons route to their own actions", function()
    -- All three are the same capability on different components, so a missed
    -- branch silently flattens the EQ instead of doing what the button says.
    local handlers, spy = command_handlers_with_spy()
    local soundbar = stubs.device({ dni = ARC_SSDP_UUID, parent_device_id = HUB_DEVICE_ID })

    handlers.push(nil, soundbar, { component = "TVMode" })
    t.eq(spy.calls[1], "play_tv", "TV Mode switches the input")

    handlers.push(nil, soundbar, { component = "SyncRooms" })
    t.eq(spy.calls[2], "sync_rooms", "Sync Rooms creates children")

    handlers.push(nil, soundbar, { component = "ResetEQ" })
    t.eq(spy.calls[3], "reset_eq", "Reset EQ flattens")
end)

t.test("switch on a room child joins the room", function()
    local handlers, spy = command_handlers_with_spy()
    local child = stubs.device({ dni = ARC_PLAYER_UUID .. ":group:RINCON_949F3E8CE16601400" })
    handlers.switch_on(nil, child, { component = "main" })
    t.eq(spy.calls[1], "join_room", "child routes to join_room")
end)

-- ---------------------------------------------------------------------------
-- Sonos favorites (mediaPresets), against a real Browse response
-- ---------------------------------------------------------------------------

t.test("parse_presets reads every favorite from a real response", function()
    local presets = upnp_services.parse_presets(read_fixture("favorites_browse.xml"))
    t.truthy(presets, "presets parsed")
    -- Only the four carrying a <res> element. The other three are shortcuts
    -- the player cannot resolve locally - see the skip test below.
    t.eq(#presets, 4, "favorite count")
    for _, p in ipairs(presets) do
        t.truthy(p.id and p.id ~= "", "preset id for " .. tostring(p.name))
        t.truthy(p.name and p.name ~= "", "preset name")
    end
end)

t.test("parse_presets fully unescapes the double-escaped r:resMD", function()
    -- resMD is escaped twice: once for the SOAP Result, once inside the item.
    -- Under-unescaping silently produces metadata Sonos rejects at play time.
    local _, meta_by_id = upnp_services.parse_presets(read_fixture("favorites_browse.xml"))
    local entry = meta_by_id["FV:2/0"]
    t.truthy(entry, "entry for FV:2/0")
    t.matches(entry.meta, "^<DIDL%-Lite", "resMD is real XML")
    t.falsy(entry.meta:find("&lt;DIDL", 1, true), "no leftover escaping")
end)

t.test("parse_presets recognises container favorites", function()
    local _, meta_by_id = upnp_services.parse_presets(read_fixture("favorites_browse.xml"))
    t.matches(meta_by_id["FV:2/0"].uri, "^x%-rincon%-cpcontainer:", "playlist is a container")
    t.matches(meta_by_id["FV:2/2"].uri, "^x%-sonosapi%-hls%-static:", "track is a direct URI")
end)

t.test("parse_presets skips shortcut favorites the player cannot play", function()
    -- Sonos Radio favorites carry an empty <res>: only the Sonos app can play
    -- them, by resolving the shortcut through Sonos's cloud. This used to
    -- rebuild an "x-rincon-cpcontainer:" URI from their metadata, which the
    -- hardware accepts on SetAVTransportURI and then fails at Play with error
    -- 501 - a preset button that could never work. They are reported as
    -- skipped instead, so the log says which ones and why.
    local presets, _, skipped = upnp_services.parse_presets(read_fixture("favorites_browse.xml"))
    for _, p in ipairs(presets) do
        t.falsy(p.name == "Discover Sonos Radio", "shortcut favorite is not offered as a preset")
    end
    t.eq(#skipped, 3, "the three Sonos Radio shortcuts are reported")

    local named = table.concat(skipped, ", ")
    t.truthy(named:find("Discover Sonos Radio", 1, true), "skipped list names the favorite")
end)

t.test("parse_presets reports why it failed instead of returning empty", function()
    local presets, reason = upnp_services.parse_presets("<Envelope>no result here</Envelope>")
    t.falsy(presets, "no presets")
    t.matches(reason, "Result", "failure reason mentions the missing element")

    presets, reason = upnp_services.parse_presets(nil)
    t.falsy(presets, "no presets for nil body")
    t.truthy(reason, "failure reason given")
end)

t.test("parse_presets absolutizes player-relative album art", function()
    local body = [[<Result>&lt;DIDL-Lite&gt;&lt;item id="FV:2/9"&gt;]] ..
        [[&lt;dc:title&gt;Local&lt;/dc:title&gt;]] ..
        [[&lt;res&gt;x-file-cifs://nas/song.flac&lt;/res&gt;]] ..
        [[&lt;upnp:albumArtURI&gt;/getaa?u=song&lt;/upnp:albumArtURI&gt;]] ..
        [[&lt;/item&gt;&lt;/DIDL-Lite&gt;</Result>]]
    local presets = upnp_services.parse_presets(body, "http://192.168.2.109:1400")
    t.eq(presets[1].imageUrl, "http://192.168.2.109:1400/getaa?u=song", "absolute art url")
end)

-- ---------------------------------------------------------------------------
-- Now playing (audioTrackData)
-- ---------------------------------------------------------------------------

t.test("build_track_data names the TV source when Sonos sends no metadata", function()
    -- On TV audio Sonos returns the literal string NOT_IMPLEMENTED for track
    -- metadata; treating that as a title would show "NOT_IMPLEMENTED" on the tile.
    local data = upnp_services.build_track_data(
        "NOT_IMPLEMENTED",
        "x-sonos-htastream:" .. ARC_PLAYER_UUID .. ":spdif",
        nil, nil)
    t.eq(data.title, "TV Audio", "title")
    t.eq(data.mediaSource, "TV Audio", "mediaSource")
end)

t.test("build_track_data extracts title, artist and album from DIDL", function()
    local didl = [[<DIDL-Lite><item><dc:title>Torn</dc:title>]] ..
        [[<dc:creator>Natalie Imbruglia</dc:creator>]] ..
        [[<upnp:album>Left of the Middle</upnp:album>]] ..
        [[<upnp:albumArtURI>/getaa?x=1</upnp:albumArtURI></item></DIDL-Lite>]]
    local data = upnp_services.build_track_data(didl, "x-sonosapi-hls-static:foo", nil,
        "http://192.168.2.109:1400")
    t.eq(data.title, "Torn", "title")
    t.eq(data.artist, "Natalie Imbruglia", "artist")
    t.eq(data.album, "Left of the Middle", "album")
    t.eq(data.albumArtUrl, "http://192.168.2.109:1400/getaa?x=1", "album art")
end)

t.test("build_track_data does not let albumArtURI swallow the album", function()
    -- Real Apple Music payload from the Arc. "<upnp:album[^>]*>" matched
    -- "<upnp:albumArtURI>", so the album came back as the art URL followed by
    -- every element up to the real </upnp:album>.
    local didl = [[<DIDL-Lite><item id="-1" parentID="-1" restricted="true">]] ..
        [[<res protocolInfo="sonos.com-http:*:audio/mp4:*" duration="0:03:32">]] ..
        [[x-sonos-http:librarytrack%3aa.1440795737.mp4?sid=204&amp;flags=8232&amp;sn=8</res>]] ..
        [[<r:streamContent></r:streamContent>]] ..
        [[<upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-http%3alibrarytrack.mp4</upnp:albumArtURI>]] ..
        [[<dc:title>Home Again</dc:title>]] ..
        [[<upnp:class>object.item.audioItem.musicTrack</upnp:class>]] ..
        [[<dc:creator>Michael Kiwanuka</dc:creator>]] ..
        [[<upnp:album>Home Again</upnp:album></item></DIDL-Lite>]]
    local data = upnp_services.build_track_data(didl, "x-sonos-http:librarytrack.mp4", nil,
        "http://192.168.2.109:1400")

    t.eq(data.title, "Home Again", "title")
    t.eq(data.artist, "Michael Kiwanuka", "artist")
    t.eq(data.album, "Home Again", "album is the album, not the art URL")
    t.eq(data.albumArtUrl, "http://192.168.2.109:1400/getaa?s=1&u=x-sonos-http%3alibrarytrack.mp4",
        "album art")
end)

t.test("build_track_data prefers streamContent for radio", function()
    local didl = [[<DIDL-Lite><item><dc:title>Station</dc:title>]] ..
        [[<r:streamContent>Artist - Song</r:streamContent></item></DIDL-Lite>]]
    local data = upnp_services.build_track_data(didl, "x-sonosapi-stream:abc", nil, nil)
    t.eq(data.title, "Artist - Song", "live stream title")
    t.eq(data.mediaSource, "Radio", "mediaSource")
end)

t.test("build_track_data keeps absolute album art untouched", function()
    local didl = [[<DIDL-Lite><item><dc:title>x</dc:title>]] ..
        [[<upnp:albumArtURI>https://example.com/a.jpg</upnp:albumArtURI></item></DIDL-Lite>]]
    local data = upnp_services.build_track_data(didl, nil, nil, "http://192.168.2.109:1400")
    t.eq(data.albumArtUrl, "https://example.com/a.jpg", "absolute art preserved")
end)

t.run()
