local log = require "log"
local capabilities = require "st.capabilities"
local upnp = require "UPnP"
local cosock = require "cosock"
local socket = require "cosock.socket"
local http = cosock.asyncify "socket.http"
-- LuaSocket defaults to 60s, so a Sonos that is asleep, rebooting or simply
-- gone wedges the device thread for a full minute per request - which the user
-- sees as the whole driver hanging. It can't go much lower than this though:
-- queuing a music-service playlist really does take Sonos ~10s to answer while
-- it talks to the service.
http.TIMEOUT = 15
local ltn12 = require "ltn12"
-- No XML parser here on purpose: Sonos payloads embed escaped XML inside
-- attribute values, which a tree parser chokes on. Everything is read with
-- targeted patterns instead.

local upnp_services = {}

upnp_services.rendering_service_id = "urn:upnp-org:serviceId:RenderingControl"
upnp_services.avtransport_service_id = "urn:upnp-org:serviceId:AVTransport"
upnp_services.zonetopology_service_id = "urn:upnp-org:serviceId:ZoneGroupTopology"
upnp_services.searchtarget = 'urn:schemas-upnp-org:device:MediaRenderer:1'
-- Kept for backward compatibility with anything referencing the old name.
upnp_services.service_id = upnp_services.rendering_service_id

upnp_services.VOLUME_STEP = 5

-- All Sonos players expose AVTransport at the same control path / service type,
-- which lets us command *other* players directly by IP (for grouping).
local AV_SERVICE_TYPE = "urn:schemas-upnp-org:service:AVTransport:1"
local AV_CONTROL_PATH = "/MediaRenderer/AVTransport/Control"

-- Sonos favorites live on the MediaServer sub-device, and group volume/mute on
-- GroupRenderingControl - neither is part of the MediaRenderer description we
-- discovered, so both are reached by direct SOAP to the player.
local CD_SERVICE_TYPE = "urn:schemas-upnp-org:service:ContentDirectory:1"
local CD_CONTROL_PATH = "/MediaServer/ContentDirectory/Control"
local GRC_SERVICE_TYPE = "urn:schemas-upnp-org:service:GroupRenderingControl:1"
local GRC_CONTROL_PATH = "/MediaRenderer/GroupRenderingControl/Control"
local ZGT_SERVICE_TYPE = "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
local ZGT_CONTROL_PATH = "/ZoneGroupTopology/Control"

-- The soundbar's TV input. Every Sonos soundbar exposes it under this scheme.
local TV_STREAM_SUFFIX = ":spdif"

-- Sonos favorites container.
local FAVORITES_OBJECT_ID = "FV:2"

-- How long to wait for a notification clip to finish when the caller didn't
-- tell us its duration.
local NOTIFICATION_MAX_SECONDS = 60

-- ---------------------------------------------------------------------------
-- Player identity
-- ---------------------------------------------------------------------------

-- We find players via the MediaRenderer sub-device, whose UDN carries an "_MR"
-- suffix (RINCON_<mac>01400_MR), but ZoneGroupTopology members and the
-- "x-rincon:" grouping URIs use the bare player UUID. Always canonicalize
-- before comparing or building a URI. A device adopted from another driver
-- ("Change driver") keeps that driver's DNI - SmartThings' own Sonos driver
-- uses the bare MAC - so derive the UUID from that as a fallback.
function upnp_services.player_uuid(device)
    local upnpdev = device:get_field('upnpdevice')
    local id = (upnpdev and upnpdev.uuid) or device.device_network_id or ""

    local bare = id:match("^(RINCON_%w+)_MR$")
    if bare then
        return bare
    end
    if id:match("^RINCON_") then
        return id
    end

    local mac = id:match("^(%x%x%x%x%x%x%x%x%x%x%x%x)$")
    if mac then
        return "RINCON_" .. mac:upper() .. "01400"
    end
    return id
end

-- True if a device record identifies the player behind this SSDP UUID: either
-- an exact DNI match, or a bare-MAC DNI contained in the UUID.
local function id_matches(dni, uuid)
    if dni == uuid then
        return true
    end
    local mac = dni and dni:match("^(%x%x%x%x%x%x%x%x%x%x%x%x)$")
    return mac ~= nil and uuid:upper():find(mac:upper(), 1, true) ~= nil
end

-- Exposed for tests.
upnp_services.id_matches = id_matches

-- ---------------------------------------------------------------------------
-- Feature configuration
-- ---------------------------------------------------------------------------

-- Switch-style EQ settings. DialogLevel prefers the newer SpeechEnhanceEnabled
-- on/off flag (Arc Ultra and later), falling back to the legacy DialogLevel.
local switch_eqs = {
    NightMode = { eqTypes = { "NightMode" } },
    SurroundMode = { eqTypes = { "SurroundMode" } },
    DialogLevel = { eqTypes = { "SpeechEnhanceEnabled", "DialogLevel" } }
}

-- Custom slider capabilities show real EQ values (e.g. Bass +3), not a 0-100%
-- dimmer. eqLevel covers -10..10; surroundLevel covers -15..15.
local EQ_CAP = "autumnpepper05038.eqlevel"
local SURROUND_CAP = "autumnpepper05038.surroundlevel"

-- Slider-style EQ settings via SetEQ/GetEQ, reported as their actual signed value.
local level_eqs = {
    SubGain = { eqType = "SubGain", min = -10, max = 10, cap = EQ_CAP },
    HeightLevel = { eqType = "HeightChannelLevel", min = -10, max = 10, cap = EQ_CAP },
    SurroundLevel = { eqType = "SurroundLevel", min = -15, max = 15, cap = SURROUND_CAP }
}

-- Slider-style settings via dedicated actions (Bass/Treble use Set/GetBass, not SetEQ).
local level_controls = {
    Bass = { get = "GetBass", set = "SetBass", arg = "DesiredBass", field = "CurrentBass", min = -10, max = 10, cap = EQ_CAP },
    Treble = { get = "GetTreble", set = "SetTreble", arg = "DesiredTreble", field = "CurrentTreble", min = -10, max = 10, cap = EQ_CAP }
}

-- Reverse lookups so events can be routed back to the right component.
local eqtype_to_switch = {}
for comp, cfg in pairs(switch_eqs) do
    for _, eqType in ipairs(cfg.eqTypes) do
        eqtype_to_switch[eqType] = comp
    end
end
local eqtype_to_level = {}
for comp, cfg in pairs(level_eqs) do
    eqtype_to_level[cfg.eqType] = comp
end

local transport_state_event = {
    PLAYING = capabilities.mediaPlayback.playbackStatus.playing,
    TRANSITIONING = capabilities.mediaPlayback.playbackStatus.playing,
    PAUSED_PLAYBACK = capabilities.mediaPlayback.playbackStatus.paused,
    STOPPED = capabilities.mediaPlayback.playbackStatus.stopped
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function upnp_services.log_table(v)
    for key, value in pairs(v) do
        local t = type(value)
        if t == "string" or t == "boolean" then
            log.debug(string.format("%s : %s", key, value))
        elseif t == "nil" then
            log.debug(string.format("%s : nil", key))
        elseif t == "table" then
            log.debug(string.format("%s : start", key))
            upnp_services.log_table(value)
            log.debug(string.format("%s : end", key))
        else
            log.debug(string.format("%s : type: %s", key, t))
        end
    end
end

local function get_component(device, id)
    local comp = device.profile.components[id]
    if not comp then
        log.error("Missing component: " .. tostring(id))
    end
    return comp
end

-- Set by lifecycle so a rediscovered device can be fully re-initialised
-- (monitoring + event subscriptions) without this module depending on lifecycle.
upnp_services.reinit_hook = nil

local function now()
    return socket.gettime()
end

local reacquiring = false

-- Rediscovery blocks the device thread for several seconds. Once it has failed,
-- retrying it on every single command turns one unreachable player into a
-- driver that appears to hang on every tap, so back off and fail fast instead.
local REACQUIRE_COOLDOWN = 60
local reacquire_blocked_until = 0

-- If discovery failed at startup the device has no UPnP handle and every
-- command dies. Rather than stay broken until the driver restarts, try to find
-- the player again on demand.
function upnp_services.reacquire(device)
    if reacquiring or now() < reacquire_blocked_until then
        return nil
    end
    reacquiring = true
    local ok, upnpdev = pcall(upnp_services.discover_device, device)
    if ok and upnpdev then
        log.info("Reacquired player for <" .. tostring(device.device_network_id) .. ">")
        if upnp_services.reinit_hook then
            pcall(upnp_services.reinit_hook, device, upnpdev)
        else
            upnpdev:init(device.driver, device)
        end
    else
        -- Don't let the app show a healthy tile for a device we can't reach:
        -- an offline marker is the only signal the user ever sees.
        log.error("Could not reach player for <" .. tostring(device.device_network_id) .. ">")
        device:offline()
        reacquire_blocked_until = now() + REACQUIRE_COOLDOWN
    end
    reacquiring = false
    return device:get_field("upnpdevice")
end

local function get_upnpdev(device)
    return device:get_field("upnpdevice") or upnp_services.reacquire(device)
end

local function command(device, service_id, action, arguments)
    local upnpdev = get_upnpdev(device)
    if not upnpdev then
        log.error("Missing upnpdevice")
        return nil
    end
    local status, response = upnpdev:command(service_id, { action = action, arguments = arguments })
    if status == 'OK' then
        return response
    end
    log.error(string.format("%s status: %s", action, tostring(status)))
    return nil
end

local function rc_command(device, action, arguments)
    return command(device, upnp_services.rendering_service_id, action, arguments)
end

local function av_command(device, action, arguments)
    return command(device, upnp_services.avtransport_service_id, action, arguments)
end

local XML_ESCAPES = { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;', ['"'] = '&quot;', ["'"] = '&apos;' }

local function xml_escape(s)
    return (tostring(s):gsub('[&<>"\']', XML_ESCAPES))
end

local XML_UNESCAPES = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }

local function xml_unescape(s)
    if not s then
        return nil
    end
    return (s:gsub('&(#?%w+);', function(entity)
        if entity:sub(1, 1) == '#' then
            local n = tonumber(entity:sub(2))
            return n and string.char(n % 256) or ('&' .. entity .. ';')
        end
        return XML_UNESCAPES[entity] or ('&' .. entity .. ';')
    end))
end

-- The UPnP error codes Sonos actually returns, so a failure in the log says
-- what to do about it rather than just "500".
local SOAP_ERRORS = {
    ["402"] = "invalid arguments",
    ["701"] = "transition not available",
    ["714"] = "unsupported URI",
    ["800"] = "music service refused it - the account may need re-linking in the Sonos app",
    ["804"] = "music service not authenticated"
}

-- Send a raw SOAP action to an explicit ip:port. Used both to command *other*
-- Sonos players (for grouping) and to reach services that don't live on the
-- MediaRenderer sub-device we discovered (ContentDirectory, GroupRenderingControl).
-- Returns ok, response_body.
local function soap_post(ip, port, path, service_type, action, args)
    local body_args = ''
    for name, value in pairs(args or {}) do
        body_args = body_args .. '<' .. name .. '>' .. xml_escape(value) .. '</' .. name .. '>'
    end
    local body = string.format(
        '<?xml version="1.0" encoding="utf-8"?>' ..
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"' ..
        ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>' ..
        '<u:%s xmlns:u="%s">%s</u:%s></s:Body></s:Envelope>',
        action, service_type, body_args, action)

    local resp_chunks = {}
    local _, code = http.request {
        url = "http://" .. ip .. ":" .. port .. path,
        method = "POST",
        sink = ltn12.sink.table(resp_chunks),
        source = ltn12.source.string(body),
        headers = {
            ["SOAPACTION"] = service_type .. '#' .. action,
            ["CONTENT-TYPE"] = "text/xml",
            ["HOST"] = ip .. ":" .. port,
            ["CONTENT-LENGTH"] = #body
        }
    }
    local response = table.concat(resp_chunks)
    if code ~= 200 then
        -- The HTTP code is always 500 for a UPnP fault; the code that says what
        -- actually went wrong is buried in the fault body, and without it every
        -- failure looked identical in the log.
        local fault = response:match("<errorCode>(%d+)</errorCode>")
        log.error(string.format("SOAP %s to %s failed: HTTP %s%s", action, tostring(ip),
            tostring(code), fault and (", UPnP error " .. fault ..
                (SOAP_ERRORS[fault] and (" (" .. SOAP_ERRORS[fault] .. ")") or "")) or ""))
        return false, response
    end
    return true, response
end

-- Sonos exposes every service on the player's own ip:1400, so anything the
-- discovered MediaRenderer description doesn't cover can still be reached
-- directly. Returns ok, response_body.
local function self_soap(device, path, service_type, action, args)
    local upnpdev = get_upnpdev(device)
    if not (upnpdev and upnpdev.ip) then
        log.error("self_soap: no upnpdevice/ip")
        return false
    end
    return soap_post(upnpdev.ip, upnpdev.port or "1400", path, service_type, action, args)
end

local function clamp(cfg, value)
    value = math.floor(tonumber(value) or 0)
    return math.max(cfg.min, math.min(cfg.max, value))
end

-- Sonos EQ values are historically 0/1, but newer models (e.g. Arc Ultra)
-- report DialogLevel as an intensity 1-4. Treat any non-zero value as "on".
local function switch_event_for_value(value)
    if value == nil or value == '0' or value == 0 then
        return capabilities.switch.switch.off()
    end
    return capabilities.switch.switch.on()
end

local function emit(device, comp_id, event)
    local component = get_component(device, comp_id)
    if component then
        device:emit_component_event(component, event)
    end
end

-- ---------------------------------------------------------------------------
-- Switch EQ (Night Mode, Surround Mode, Dialog)
-- ---------------------------------------------------------------------------

function upnp_services.get_switch_eq(device, comp)
    local cfg = switch_eqs[comp]
    for _, eqType in ipairs(cfg.eqTypes) do
        local response = rc_command(device, 'GetEQ', { InstanceID = 0, EQType = eqType })
        if response and response.GetEQ then
            emit(device, comp, switch_event_for_value(response.GetEQ.CurrentValue))
            return
        end
    end
end

function upnp_services.set_switch_eq(device, comp, on)
    local cfg = switch_eqs[comp]
    local desired = on and 1 or 0
    for _, eqType in ipairs(cfg.eqTypes) do
        local response = rc_command(device, 'SetEQ',
            { InstanceID = 0, EQType = eqType, DesiredValue = desired })
        if response then
            emit(device, comp, switch_event_for_value(desired))
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Level sliders: EQ (Sub/Height/Surround) and dedicated (Bass/Treble)
-- ---------------------------------------------------------------------------

local function emit_level(device, comp, cap, value)
    emit(device, comp, capabilities[cap].level(math.floor(tonumber(value) or 0)))
end

local function get_level_eq(device, comp)
    local cfg = level_eqs[comp]
    local response = rc_command(device, 'GetEQ', { InstanceID = 0, EQType = cfg.eqType })
    if response and response.GetEQ then
        emit_level(device, comp, cfg.cap, response.GetEQ.CurrentValue)
    end
end

local function set_level_eq(device, comp, value)
    local cfg = level_eqs[comp]
    value = clamp(cfg, value)
    local response = rc_command(device, 'SetEQ',
        { InstanceID = 0, EQType = cfg.eqType, DesiredValue = value })
    if response then
        emit_level(device, comp, cfg.cap, value)
    end
end

local function get_level_control(device, comp)
    local cfg = level_controls[comp]
    local response = rc_command(device, cfg.get, { InstanceID = 0 })
    if response and response[cfg.get] then
        emit_level(device, comp, cfg.cap, response[cfg.get][cfg.field])
    end
end

local function set_level_control(device, comp, value)
    local cfg = level_controls[comp]
    value = clamp(cfg, value)
    local args = { InstanceID = 0 }
    args[cfg.arg] = value
    local response = rc_command(device, cfg.set, args)
    if response then
        emit_level(device, comp, cfg.cap, value)
    end
end

-- Dispatcher used by the setLevel command handler.
function upnp_services.set_level(device, comp, value)
    if level_eqs[comp] then
        set_level_eq(device, comp, value)
    elseif level_controls[comp] then
        set_level_control(device, comp, value)
    else
        log.error("Unknown level component: " .. tostring(comp))
    end
end

-- Reset all EQ level sliders to flat (0).
function upnp_services.reset_eq(device)
    for comp in pairs(level_eqs) do
        set_level_eq(device, comp, 0)
    end
    for comp in pairs(level_controls) do
        set_level_control(device, comp, 0)
    end
end

-- ---------------------------------------------------------------------------
-- Volume / Mute
-- ---------------------------------------------------------------------------

local function emit_volume(device, value)
    emit(device, 'main', capabilities.audioVolume.volume(tonumber(value) or 0))
end

local function emit_mute(device, muted)
    emit(device, 'main', muted and capabilities.audioMute.mute.muted() or capabilities.audioMute.mute.unmuted())
end

function upnp_services.get_volume(device)
    local response = rc_command(device, 'GetVolume', { InstanceID = 0, Channel = 'Master' })
    if response and response.GetVolume then
        emit_volume(device, response.GetVolume.CurrentVolume)
    end
end

function upnp_services.set_volume(device, vol)
    vol = math.max(0, math.min(100, math.floor(tonumber(vol) or 0)))
    local response = rc_command(device, 'SetVolume',
        { InstanceID = 0, Channel = 'Master', DesiredVolume = vol })
    if response then
        emit_volume(device, vol)
    end
end

function upnp_services.adjust_volume(device, delta)
    local response = rc_command(device, 'GetVolume', { InstanceID = 0, Channel = 'Master' })
    if response and response.GetVolume then
        local current = tonumber(response.GetVolume.CurrentVolume) or 0
        upnp_services.set_volume(device, current + delta)
    end
end

function upnp_services.get_mute(device)
    local response = rc_command(device, 'GetMute', { InstanceID = 0, Channel = 'Master' })
    if response and response.GetMute then
        emit_mute(device, tostring(response.GetMute.CurrentMute) == '1')
    end
end

function upnp_services.set_mute(device, muted)
    local response = rc_command(device, 'SetMute',
        { InstanceID = 0, Channel = 'Master', DesiredMute = muted and 1 or 0 })
    if response then
        emit_mute(device, muted)
    end
end

-- ---------------------------------------------------------------------------
-- Transport (Play / Pause / Stop / Next / Previous)
-- ---------------------------------------------------------------------------

function upnp_services.transport_play(device)
    av_command(device, 'Play', { InstanceID = 0, Speed = 1 })
end

function upnp_services.transport_pause(device)
    av_command(device, 'Pause', { InstanceID = 0 })
end

function upnp_services.transport_stop(device)
    av_command(device, 'Stop', { InstanceID = 0 })
end

function upnp_services.transport_next(device)
    av_command(device, 'Next', { InstanceID = 0 })
end

function upnp_services.transport_previous(device)
    av_command(device, 'Previous', { InstanceID = 0 })
end

local function emit_transport_state(device, sonos_state)
    local event_ctor = transport_state_event[sonos_state]
    if event_ctor then
        emit(device, 'main', event_ctor())
    end
end

function upnp_services.get_transport_state(device)
    local response = av_command(device, 'GetTransportInfo', { InstanceID = 0 })
    if response and response.GetTransportInfo then
        emit_transport_state(device, response.GetTransportInfo.CurrentTransportState)
    end
end

-- Advertise which transport buttons the UI should render.
function upnp_services.emit_static_capabilities(device)
    if not get_component(device, 'main') then
        return
    end
    emit(device, 'main', capabilities.mediaPlayback.supportedPlaybackCommands({ "play", "pause", "stop" }))
    emit(device, 'main', capabilities.mediaTrackControl.supportedTrackControlCommands({ "nextTrack", "previousTrack" }))
end

-- ---------------------------------------------------------------------------
-- Speaker grouping (Party Mode)
-- ---------------------------------------------------------------------------

local function parse_attrs(s)
    local attrs = {}
    for key, value in s:gmatch('([%w_]+)="([^"]*)"') do
        attrs[key] = value
    end
    return attrs
end

-- Pure: ZoneGroupState XML in, a list of groups out, each with a coordinator
-- UUID and its members (uuid / ip / port / name / invisible).
--
-- A home-theatre member wraps its sub and surrounds in nested <Satellite>
-- elements, so ZoneGroupMember is NOT always self-closing. Only ZoneGroupMember
-- elements are real group members - satellites are parts of one speaker and
-- must never be commanded or offered as rooms to group with.
function upnp_services.parse_zone_groups(xml)
    if not xml or xml == '' then
        return nil
    end

    local groups = {}
    for group_attrs, body in xml:gmatch('<ZoneGroup%s+([^>]*)>(.-)</ZoneGroup>') do
        local ga = parse_attrs(group_attrs)
        local members = {}
        for member_attrs in body:gmatch('<ZoneGroupMember%s+([^>]*)>') do
            local a = parse_attrs(member_attrs)
            if a.UUID then
                local loc = a.Location or ''
                table.insert(members, {
                    uuid = a.UUID,
                    ip = loc:match("http://([^:/]+)"),
                    port = loc:match("http://[^:]+:(%d+)") or "1400",
                    name = a.ZoneName,
                    invisible = (a.Invisible == "1")
                })
            end
        end
        table.insert(groups, { id = ga.ID, coordinator = ga.Coordinator, members = members })
    end

    if #groups == 0 then
        return nil
    end
    return groups
end

-- Every visible player that isn't us - the set Party Mode commands.
function upnp_services.group_targets(groups, self_uuid)
    local targets = {}
    for _, group in ipairs(groups or {}) do
        for _, m in ipairs(group.members) do
            if m.uuid ~= self_uuid and m.ip and not m.invisible then
                table.insert(targets, m)
            end
        end
    end
    return targets
end

-- Whether this player is grouped with anyone else, and in what role.
function upnp_services.group_state(groups, self_uuid)
    for _, group in ipairs(groups or {}) do
        local contains_self, others = false, 0
        for _, m in ipairs(group.members) do
            if m.uuid == self_uuid then
                contains_self = true
            elseif not m.invisible then
                others = others + 1
            end
        end
        if contains_self then
            local role = 'ungrouped'
            if others > 0 then
                role = (group.coordinator == self_uuid) and 'primary' or 'auxiliary'
            end
            return { group = group, grouped = others > 0, role = role, others = others }
        end
    end
    return nil
end

-- ZoneGroupState is the largest payload Sonos returns - the whole household,
-- satellites included - and a single refresh needs it three times over (party
-- switch, mediaGroup, room children). Fetching it once per burst is the
-- difference between one round trip and three.
local TOPOLOGY_TTL = 10
local topology_cache = {}

function upnp_services.invalidate_topology(device)
    topology_cache[device.id] = nil
end

local function collect_zone_groups(device)
    local cached = topology_cache[device.id]
    if cached and (now() - cached.at) < TOPOLOGY_TTL then
        return cached.groups
    end

    -- Read this one with raw SOAP rather than through the UPnP library: the
    -- response carries the topology as escaped XML inside the SOAP body, and
    -- running tens of KB of that through the tree parser costs the hub far more
    -- than the request itself. Patterns read it straight.
    local ok, body = self_soap(device, ZGT_CONTROL_PATH, ZGT_SERVICE_TYPE, 'GetZoneGroupState', {})
    local xml = ok and body and xml_unescape(body:match("<ZoneGroupState>(.-)</ZoneGroupState>"))
    if not xml then
        log.error("Could not read ZoneGroupState")
        return nil
    end

    local groups = upnp_services.parse_zone_groups(xml)
    if not groups then
        log.error("ZoneGroupState contained no zone groups")
        return nil
    end

    topology_cache[device.id] = { at = now(), groups = groups }
    return groups
end

local function set_party_switch(device, on)
    emit(device, 'PartyMode', on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
end

-- Group every other (visible) Sonos player under this soundbar.
function upnp_services.group_all(device)
    local self_uuid = upnp_services.player_uuid(device)
    local groups = collect_zone_groups(device)
    if not groups then
        return
    end

    -- Make this soundbar the head of its own group first.
    av_command(device, 'BecomeCoordinatorOfStandaloneGroup', { InstanceID = 0 })

    local targets = upnp_services.group_targets(groups, self_uuid)
    local target_uri = "x-rincon:" .. self_uuid
    local count, failed = 0, 0
    for _, m in ipairs(targets) do
        if soap_post(m.ip, m.port, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'SetAVTransportURI',
                { InstanceID = 0, CurrentURI = target_uri, CurrentURIMetaData = "" }) then
            count = count + 1
        else
            failed = failed + 1
            log.error(string.format("Party mode: could not group %s (%s)",
                tostring(m.name), tostring(m.ip)))
        end
    end
    log.info(string.format("Party mode ON: grouped %d of %d player(s) under %s",
        count, #targets, tostring(self_uuid)))
    if failed > 0 then
        log.warn(string.format("Party mode: %d player(s) did not join", failed))
    end
    upnp_services.invalidate_topology(device)
    set_party_switch(device, count > 0)
end

-- Split every other player currently grouped with this soundbar into standalone.
function upnp_services.ungroup_all(device)
    local self_uuid = upnp_services.player_uuid(device)
    local groups = collect_zone_groups(device)
    if not groups then
        set_party_switch(device, false)
        return
    end

    local targets = upnp_services.group_targets(groups, self_uuid)
    local count = 0
    for _, m in ipairs(targets) do
        if soap_post(m.ip, m.port, AV_CONTROL_PATH, AV_SERVICE_TYPE,
                'BecomeCoordinatorOfStandaloneGroup', { InstanceID = 0 }) then
            count = count + 1
        else
            log.error(string.format("Party mode: could not ungroup %s (%s)",
                tostring(m.name), tostring(m.ip)))
        end
    end
    log.info(string.format("Party mode OFF: ungrouped %d of %d player(s)", count, #targets))
    upnp_services.invalidate_topology(device)
    set_party_switch(device, false)
end

-- Reflect current grouping state on the Party Mode switch. Callers that already
-- hold the topology pass it in so refresh doesn't fetch it again.
function upnp_services.get_group_state(device, groups)
    groups = groups or collect_zone_groups(device)
    if not groups then
        return
    end
    local state = upnp_services.group_state(groups, upnp_services.player_uuid(device))
    set_party_switch(device, state ~= nil and state.grouped)
end

-- ---------------------------------------------------------------------------
-- TV mode (put the soundbar back on its TV input)
-- ---------------------------------------------------------------------------

-- The soundbar's TV input is a stream on the player itself, addressed by its
-- own uuid - so this must be the bare uuid, never the "_MR" SSDP form.
function upnp_services.tv_uri(uuid)
    return "x-sonos-htastream:" .. uuid .. TV_STREAM_SUFFIX
end

-- Switch back to TV audio after music, a favorite or a group has taken the
-- transport over.
function upnp_services.play_tv(device)
    local uuid = upnp_services.player_uuid(device)

    -- While the soundbar is a guest in someone else's group its transport
    -- belongs to that group's coordinator, so setting the TV stream on it does
    -- nothing until it heads its own group again. Only split when we're the
    -- guest: doing it as coordinator would throw everyone out of Party Mode.
    local groups = collect_zone_groups(device)
    local state = groups and upnp_services.group_state(groups, uuid)
    if state and state.role == 'auxiliary' then
        log.info("TV mode: leaving group to take back the transport")
        av_command(device, 'BecomeCoordinatorOfStandaloneGroup', { InstanceID = 0 })
        upnp_services.invalidate_topology(device)
    end

    local ok = self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'SetAVTransportURI',
        { InstanceID = 0, CurrentURI = upnp_services.tv_uri(uuid), CurrentURIMetaData = '' })
    if not ok then
        log.error("TV mode: could not switch to the TV input")
        return
    end

    upnp_services.transport_play(device)
    upnp_services.get_track_data(device)
    upnp_services.get_transport_state(device)
    log.info("TV mode: switched to TV audio")
end

-- ---------------------------------------------------------------------------
-- Per-room grouping (child devices, one on/off toggle per other Sonos room)
-- ---------------------------------------------------------------------------

local function find_device(driver, device_id)
    for _, d in ipairs(driver:get_devices()) do
        if d.id == device_id then
            return d
        end
    end
    return nil
end

-- Create a child toggle device for every other visible Sonos room.
function upnp_services.sync_rooms(driver, device)
    local self_uuid = upnp_services.player_uuid(device)
    local groups = collect_zone_groups(device)
    if not groups then
        return
    end

    -- Key the dedup on the room UUID rather than the whole DNI, so children
    -- created under an earlier DNI scheme aren't duplicated.
    local existing = {}
    for _, d in ipairs(driver:get_devices()) do
        local room = d.device_network_id:match(":group:(.+)")
        if room then
            existing[room] = true
        end
    end

    local rooms = upnp_services.group_targets(groups, self_uuid)
    local created = 0
    for _, m in ipairs(rooms) do
        if not existing[m.uuid] then
            local ok = driver:try_create_device({
                type = "LAN",
                device_network_id = self_uuid .. ":group:" .. m.uuid,
                label = "Group: " .. (m.name or m.uuid),
                profile = "sonos-group-member",
                parent_device_id = device.id
            })
            if ok then
                created = created + 1
                existing[m.uuid] = true
            else
                log.error("Sync rooms: could not create toggle for " .. tostring(m.name))
            end
        end
    end
    log.info(string.format("Sync rooms: %d room(s) visible, created %d new toggle(s)",
        #rooms, created))
end

-- Resolve a child toggle -> (parent uuid, room ip, room port) from live topology.
local function room_target(driver, child)
    local room_uuid = child.device_network_id:match(":group:(.+)")
    local parent = find_device(driver, child.parent_device_id)
    if not (room_uuid and parent) then
        return nil
    end
    local groups = collect_zone_groups(parent)
    if not groups then
        return nil
    end
    for _, group in ipairs(groups) do
        for _, m in ipairs(group.members) do
            if m.uuid == room_uuid and m.ip then
                return upnp_services.player_uuid(parent), m.ip, m.port
            end
        end
    end
    return nil
end

function upnp_services.join_room(driver, child)
    local parent = find_device(driver, child.parent_device_id)
    local parent_uuid, ip, port = room_target(driver, child)
    if not ip then
        log.error("join_room: room not found in topology")
        return
    end
    local ok = soap_post(ip, port, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'SetAVTransportURI',
        { InstanceID = 0, CurrentURI = "x-rincon:" .. parent_uuid, CurrentURIMetaData = "" })
    if parent then
        upnp_services.invalidate_topology(parent)
    end
    emit(child, 'main', ok and capabilities.switch.switch.on() or capabilities.switch.switch.off())
end

function upnp_services.leave_room(driver, child)
    local parent = find_device(driver, child.parent_device_id)
    local _, ip, port = room_target(driver, child)
    if ip then
        soap_post(ip, port, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'BecomeCoordinatorOfStandaloneGroup',
            { InstanceID = 0 })
    end
    if parent then
        upnp_services.invalidate_topology(parent)
    end
    emit(child, 'main', capabilities.switch.switch.off())
end

-- Reflect whether a room is currently grouped with the soundbar.
function upnp_services.refresh_room(driver, child)
    local room_uuid = child.device_network_id:match(":group:(.+)")
    local parent = find_device(driver, child.parent_device_id)
    if not (room_uuid and parent) then
        return
    end
    local groups = collect_zone_groups(parent)
    if not groups then
        return
    end
    local parent_uuid = upnp_services.player_uuid(parent)
    for _, group in ipairs(groups) do
        local has_room = false
        for _, m in ipairs(group.members) do
            if m.uuid == room_uuid then
                has_room = true
            end
        end
        if has_room then
            local grouped = (group.coordinator == parent_uuid)
            emit(child, 'main', grouped and capabilities.switch.switch.on() or capabilities.switch.switch.off())
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Now playing (audioTrackData)
-- ---------------------------------------------------------------------------

-- DIDL-Lite is small and its shape varies by source, so pull fields with
-- patterns rather than a full parse - the XML parser's node shape for
-- attribute-bearing text elements isn't worth guessing at.
-- Sonos returns this instead of a value for fields that don't apply to the
-- current source (e.g. everything positional while on TV audio).
local NOT_IMPLEMENTED = "NOT_IMPLEMENTED"

local function usable(value)
    if value == nil or value == '' or value == NOT_IMPLEMENTED then
        return nil
    end
    return value
end

local function didl_field(didl, tag)
    if not usable(didl) then
        return nil
    end
    local pattern_tag = tag:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    -- The tag name has to end where it ends. "<upnp:album[^>]*>" happily
    -- matches "<upnp:albumArtURI>", and the lazy body then ran on to the real
    -- </upnp:album> at the far end of the item - so the album came back as the
    -- art URL plus every element in between.
    local raw = didl:match("<" .. pattern_tag .. ">(.-)</" .. pattern_tag .. ">")
        or didl:match("<" .. pattern_tag .. "%s[^>]*>(.-)</" .. pattern_tag .. ">")
    if not usable(raw) then
        return nil
    end
    return xml_unescape(raw)
end

-- "http://<player ip>:<port>", used to absolutize player-relative album art.
local function art_base_for(device)
    local upnpdev = device:get_field("upnpdevice")
    if not (upnpdev and upnpdev.ip) then
        return nil
    end
    return string.format("http://%s:%s", upnpdev.ip, upnpdev.port or "1400")
end

-- Album art comes back as a player-relative path.
local function absolute_art_url(art_base, uri)
    if not uri then
        return nil
    end
    if uri:match("^https?://") then
        return uri
    end
    if not art_base then
        return nil
    end
    if uri:sub(1, 1) ~= '/' then
        uri = '/' .. uri
    end
    return art_base .. uri
end

-- Line-in style sources carry no metadata; name them from the transport URI.
local function source_from_uri(uri)
    if not uri then
        return nil
    end
    if uri:match("^x%-sonos%-htastream:") then
        return "TV Audio"
    elseif uri:match("^x%-rincon%-stream:") then
        return "Line In"
    elseif uri:match("^x%-sonosapi%-stream:") or uri:match("^x%-rincon%-mp3radio:") then
        return "Radio"
    elseif uri:match("^x%-rincon:") then
        return "Grouped"
    end
    return nil
end

-- Pure: DIDL in, audioTrackData table out. Kept separate from emitting so it
-- can be tested against real Sonos payloads without a device.
function upnp_services.build_track_data(track_didl, current_uri, current_didl, art_base)
    local source = source_from_uri(current_uri)

    -- A stream's useful title is often in r:streamContent, with the station
    -- name in the enclosing CurrentURIMetaData instead.
    local title = didl_field(track_didl, "dc:title")
    local stream_content = didl_field(track_didl, "r:streamContent")
    if stream_content and stream_content ~= '' then
        title = stream_content
    end

    return {
        title = title or source or "Unknown",
        artist = didl_field(track_didl, "dc:creator"),
        album = didl_field(track_didl, "upnp:album"),
        albumArtUrl = absolute_art_url(art_base, didl_field(track_didl, "upnp:albumArtURI")),
        mediaSource = source or didl_field(current_didl, "dc:title")
    }
end

local function emit_track_data(device, track_didl, current_uri, current_didl)
    local data = upnp_services.build_track_data(track_didl, current_uri, current_didl,
        art_base_for(device))
    emit(device, 'main', capabilities.audioTrackData.audioTrackData(data))
end

function upnp_services.get_track_data(device)
    local pos = av_command(device, 'GetPositionInfo', { InstanceID = 0 })
    local media = av_command(device, 'GetMediaInfo', { InstanceID = 0 })
    local track_didl = pos and pos.GetPositionInfo and pos.GetPositionInfo.TrackMetaData
    local current_uri = media and media.GetMediaInfo and media.GetMediaInfo.CurrentURI
    local current_didl = media and media.GetMediaInfo and media.GetMediaInfo.CurrentURIMetaData
    emit_track_data(device, track_didl, current_uri, current_didl)
end

-- ---------------------------------------------------------------------------
-- Sonos favorites (mediaPresets)
-- ---------------------------------------------------------------------------

-- Play a favorite. Container-style favorites (a playlist, album or station
-- from a music service) have to be queued and played from the queue; a plain
-- track or stream URI can be set on the transport directly.
-- Returns false as soon as a step fails, so the caller can say the favorite
-- didn't play instead of firing Play at a transport that was never loaded.
local function play_uri(device, uri, meta)
    local ok
    if uri:match("^x%-rincon%-cpcontainer:") or uri:match("^x%-rincon%-playlist:")
        or uri:match("^x%-rincon%-cpcontainer") or uri:match("^file:") then
        local queue_uri = "x-rincon-queue:" .. upnp_services.player_uuid(device) .. "#0"
        self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'RemoveAllTracksFromQueue',
            { InstanceID = 0 })
        ok = self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'AddURIToQueue', {
            InstanceID = 0,
            EnqueuedURI = uri,
            EnqueuedURIMetaData = meta or '',
            DesiredFirstTrackNumberEnqueued = 0,
            EnqueueAsNext = 1
        })
        if not ok then
            return false
        end
        ok = self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'SetAVTransportURI',
            { InstanceID = 0, CurrentURI = queue_uri, CurrentURIMetaData = '' })
    else
        ok = self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'SetAVTransportURI',
            { InstanceID = 0, CurrentURI = uri, CurrentURIMetaData = meta or '' })
    end
    if not ok then
        return false
    end
    return self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'Play', { InstanceID = 0, Speed = 1 })
end

-- Pure: a ContentDirectory Browse SOAP body in, (presets, meta_by_id) out.
-- Returns nil plus a reason so callers can log a real failure rather than
-- silently emitting an empty favorites list.
function upnp_services.parse_presets(body, art_base)
    if not body then
        return nil, "no response body"
    end

    -- The Result element is DIDL-Lite escaped inside the SOAP body.
    local didl = xml_unescape(body:match("<Result>(.-)</Result>"))
    if not didl then
        return nil, "browse returned no Result element"
    end

    local presets, meta_by_id, skipped = {}, {}, {}
    for item in didl:gmatch("<item.-</item>") do
        local id = item:match('id="([^"]*)"')
        local title = didl_field(item, "dc:title")
        if id and title then
            -- r:resMD is the metadata Sonos wants handed back when playing it.
            local meta = didl_field(item, "r:resMD")
            local uri = didl_field(item, "res")

            if uri then
                meta_by_id[id] = { uri = uri, meta = meta, name = title }
                table.insert(presets, {
                    id = id,
                    name = title,
                    imageUrl = absolute_art_url(art_base, didl_field(item, "upnp:albumArtURI")),
                    mediaSource = didl_field(item, "r:description")
                })
            else
                -- A favorite with an empty <res> is a "shortcut" - Sonos Radio
                -- stations are the usual case. Only the Sonos app can play one,
                -- by resolving it through Sonos's cloud; the player will not do
                -- it locally. Verified against the hardware: every URI that can
                -- be built from such a favorite's metadata is accepted by
                -- SetAVTransportURI and then fails at Play with error 501, and
                -- the service refuses to be browsed for the real id (701). This
                -- used to rebuild an "x-rincon-cpcontainer:" URI here, which
                -- produced a preset button that could never work.
                table.insert(skipped, title)
            end
        end
    end

    return presets, meta_by_id, skipped
end

-- Favorites change rarely but the Browse response is one of the biggest things
-- Sonos returns, so don't re-fetch it on every refresh.
local PRESETS_TTL = 900

function upnp_services.get_presets(device, force)
    local fetched_at = device:get_field("presets_at")
    if not force and fetched_at and device:get_field("presets")
        and (now() - fetched_at) < PRESETS_TTL then
        return
    end

    local ok, body = self_soap(device, CD_CONTROL_PATH, CD_SERVICE_TYPE, 'Browse', {
        ObjectID = FAVORITES_OBJECT_ID,
        BrowseFlag = 'BrowseDirectChildren',
        Filter = '*',
        StartingIndex = 0,
        RequestedCount = 100,
        SortCriteria = ''
    })
    if not ok then
        log.error("Could not browse Sonos favorites")
        return
    end

    local presets, meta_by_id, skipped = upnp_services.parse_presets(body, art_base_for(device))
    if not presets then
        log.error("Could not read Sonos favorites: " .. tostring(meta_by_id))
        return
    end

    if #skipped > 0 then
        log.warn(string.format(
            "Skipping %d favorite(s) with no playable resource - these are shortcuts " ..
            "(Sonos Radio stations) that only the Sonos app can resolve: %s",
            #skipped, table.concat(skipped, ", ")))
    end

    device:set_field("presets", meta_by_id)
    device:set_field("presets_at", now())
    emit(device, 'main', capabilities.mediaPresets.presets(presets))
    log.info(string.format("Loaded %d Sonos favorite(s)", #presets))
end

function upnp_services.play_preset(device, preset_id)
    local presets = device:get_field("presets")
    -- Favorites are only fetched on refresh, so a preset played before the
    -- first refresh (or after they changed) needs a fresh browse.
    if not (presets and presets[preset_id]) then
        upnp_services.get_presets(device, true)
        presets = device:get_field("presets")
    end

    local entry = presets and presets[preset_id]
    if not entry then
        log.error("Unknown preset: " .. tostring(preset_id))
        return
    end

    if play_uri(device, entry.uri, entry.meta) then
        upnp_services.get_track_data(device)
        upnp_services.get_transport_state(device)
    else
        -- The favorite itself is fine; Sonos declined to play it. The SOAP
        -- error logged above says why - a music-service favorite needs that
        -- service still linked to the household.
        log.error(string.format("Sonos would not play favorite %s (%s)",
            tostring(entry.name or preset_id), tostring(entry.uri)))
    end
end

-- ---------------------------------------------------------------------------
-- Announcements (audioNotification)
-- ---------------------------------------------------------------------------

local function restore_snapshot(device, snap)
    if not snap then
        return
    end
    if snap.volume then
        upnp_services.set_volume(device, snap.volume)
    end
    if snap.uri then
        self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'SetAVTransportURI',
            { InstanceID = 0, CurrentURI = snap.uri, CurrentURIMetaData = snap.meta or '' })
        local track = tonumber(snap.track)
        if track and track > 0 then
            self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'Seek',
                { InstanceID = 0, Unit = 'TRACK_NR', Target = track })
        end
        -- Only seek to a real timestamp; TV and line-in report NOT_IMPLEMENTED.
        if snap.position and snap.position:match("^%d+:%d%d:%d%d$") then
            self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'Seek',
                { InstanceID = 0, Unit = 'REL_TIME', Target = snap.position })
        end
    end
    if snap.resume and snap.state == 'PLAYING' then
        upnp_services.transport_play(device)
    end
    upnp_services.get_track_data(device)
    upnp_services.get_transport_state(device)
end

-- Play a clip, then put back whatever was playing. `resume` decides whether
-- playback restarts or just the transport is restored.
function upnp_services.play_notification(device, uri, level, duration, resume)
    if not uri then
        return
    end

    local media = av_command(device, 'GetMediaInfo', { InstanceID = 0 })
    local pos = av_command(device, 'GetPositionInfo', { InstanceID = 0 })
    local transport = av_command(device, 'GetTransportInfo', { InstanceID = 0 })
    local vol = rc_command(device, 'GetVolume', { InstanceID = 0, Channel = 'Master' })

    local snap = {
        uri = usable(media and media.GetMediaInfo and media.GetMediaInfo.CurrentURI),
        meta = usable(media and media.GetMediaInfo and media.GetMediaInfo.CurrentURIMetaData),
        track = usable(pos and pos.GetPositionInfo and pos.GetPositionInfo.Track),
        position = usable(pos and pos.GetPositionInfo and pos.GetPositionInfo.RelTime),
        state = transport and transport.GetTransportInfo and transport.GetTransportInfo.CurrentTransportState,
        volume = vol and vol.GetVolume and vol.GetVolume.CurrentVolume,
        resume = resume
    }

    if level then
        upnp_services.set_volume(device, level)
    end

    self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'SetAVTransportURI',
        { InstanceID = 0, CurrentURI = uri, CurrentURIMetaData = '' })
    self_soap(device, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'Play', { InstanceID = 0, Speed = 1 })

    local wait = tonumber(duration)
    if wait and wait > 0 then
        device.thread:call_with_delay(wait + 1, function()
            restore_snapshot(device, snap)
        end)
        return
    end

    -- No duration given: poll until the clip stops, with a hard ceiling so a
    -- stalled stream can't strand playback forever.
    local waited = 0
    local function poll()
        waited = waited + 2
        local info = av_command(device, 'GetTransportInfo', { InstanceID = 0 })
        local state = info and info.GetTransportInfo and info.GetTransportInfo.CurrentTransportState
        if state == 'STOPPED' or state == 'NO_MEDIA_PRESENT' or waited >= NOTIFICATION_MAX_SECONDS then
            restore_snapshot(device, snap)
        else
            device.thread:call_with_delay(2, poll)
        end
    end
    device.thread:call_with_delay(2, poll)
end

-- ---------------------------------------------------------------------------
-- Group state / group volume (mediaGroup)
-- ---------------------------------------------------------------------------

local function grc_command(device, action, args)
    return self_soap(device, GRC_CONTROL_PATH, GRC_SERVICE_TYPE, action, args)
end

function upnp_services.get_media_group(device, groups)
    groups = groups or collect_zone_groups(device)
    if not groups then
        return
    end
    local state = upnp_services.group_state(groups, upnp_services.player_uuid(device))
    if state then
        emit(device, 'main', capabilities.mediaGroup.groupId(state.group.id or ''))
        emit(device, 'main', capabilities.mediaGroup.groupPrimaryDeviceId(state.group.coordinator or ''))
        emit(device, 'main', capabilities.mediaGroup.groupRole(state.role))
    end

    local ok, body = grc_command(device, 'GetGroupVolume', { InstanceID = 0 })
    if ok and body then
        local v = body:match("<CurrentVolume>(%d+)</CurrentVolume>")
        if v then
            emit(device, 'main', capabilities.mediaGroup.groupVolume(tonumber(v)))
        end
    end

    ok, body = grc_command(device, 'GetGroupMute', { InstanceID = 0 })
    if ok and body then
        local m = body:match("<CurrentMute>(%d+)</CurrentMute>")
        if m then
            emit(device, 'main', capabilities.mediaGroup.groupMute(m == '1' and 'muted' or 'unmuted'))
        end
    end
end

function upnp_services.set_group_volume(device, vol)
    vol = math.max(0, math.min(100, math.floor(tonumber(vol) or 0)))
    if grc_command(device, 'SetGroupVolume', { InstanceID = 0, DesiredVolume = vol }) then
        emit(device, 'main', capabilities.mediaGroup.groupVolume(vol))
    end
end

function upnp_services.adjust_group_volume(device, delta)
    local ok, body = grc_command(device, 'GetGroupVolume', { InstanceID = 0 })
    local current = ok and body and tonumber(body:match("<CurrentVolume>(%d+)</CurrentVolume>"))
    if current then
        upnp_services.set_group_volume(device, current + delta)
    end
end

function upnp_services.set_group_mute(device, muted)
    if grc_command(device, 'SetGroupMute', { InstanceID = 0, DesiredMute = muted and 1 or 0 }) then
        emit(device, 'main', capabilities.mediaGroup.groupMute(muted and 'muted' or 'unmuted'))
    end
end

-- ---------------------------------------------------------------------------

-- Small, single round trips for the controls the user is actually looking at.
function upnp_services.refresh_fast(device)
    upnp_services.get_volume(device)
    upnp_services.get_mute(device)
    upnp_services.get_transport_state(device)
    for comp in pairs(switch_eqs) do
        upnp_services.get_switch_eq(device, comp)
    end
    for comp in pairs(level_eqs) do
        get_level_eq(device, comp)
    end
    for comp in pairs(level_controls) do
        get_level_control(device, comp)
    end
end

-- Household topology, now-playing and favorites: the heavy half, several round
-- trips including the two biggest payloads Sonos returns.
--
-- `user_asked` means someone pulled to refresh in the app, which is exactly
-- what you do after adding a favorite in the Sonos app - so that path has to
-- ignore the favorites cache or the new favorite wouldn't show up for 15
-- minutes and refreshing would look broken.
function upnp_services.refresh_slow(device, user_asked)
    local groups = collect_zone_groups(device)
    if groups then
        upnp_services.get_group_state(device, groups)
        upnp_services.get_media_group(device, groups)
    end
    upnp_services.get_track_data(device)
    upnp_services.get_presets(device, user_asked)
end

-- A refresh is ~20 sequential requests, and everything the user does runs on
-- this same thread - so a tap landing during one used to sit behind all of it.
-- Answer with the cheap half immediately and let the rest run afterwards, where
-- a queued command can get in front of it.
function upnp_services.refresh_components(device, user_asked)
    upnp_services.refresh_fast(device)
    device.thread:call_with_delay(1, function()
        upnp_services.refresh_slow(device, user_asked)
    end)
end

-- ---------------------------------------------------------------------------
-- Eventing
-- ---------------------------------------------------------------------------

-- LastChange is XML whose *attribute values* themselves contain escaped XML
-- (DIDL-Lite, for track metadata). Handing that to a full XML parser blows up
-- with "Unbalanced Tag (/DIDL-Lite)", which silently dropped every AVTransport
-- event. The payload is a flat list of <Tag [channel="..."] val="..."/>, so
-- read it directly. Attribute values never contain a literal > or " (they're
-- entity-escaped), which is what makes this safe.
--
-- Returns { [tag] = { {val=..., channel=...}, ... } }.
function upnp_services.parse_lastchange(raw)
    if not raw or raw == '' then
        return nil
    end
    local inst = raw:match("<InstanceID.->(.*)</InstanceID>") or raw

    local events = {}
    for tag, attrs in inst:gmatch("<([%w:_%-]+)([^>]*)/>") do
        local val = attrs:match('val="(.-)"')
        if val then
            local entry = {
                val = xml_unescape(val),
                channel = attrs:match('channel="([^"]*)"')
            }
            local list = events[tag]
            if list then
                list[#list + 1] = entry
            else
                events[tag] = { entry }
            end
        end
    end
    return events
end

-- Value for the Master channel, or for a tag that isn't reported per-channel.
function upnp_services.lastchange_value(events, tag)
    local list = events and events[tag]
    if not list then
        return nil
    end
    for _, entry in ipairs(list) do
        if entry.channel == nil or entry.channel == 'Master' then
            return entry.val
        end
    end
    return nil
end

local lc_value = upnp_services.lastchange_value

local function parse_lastchange(propertylist)
    return upnp_services.parse_lastchange(propertylist and propertylist.LastChange)
end

function upnp_services.rendering_event_callback(device, sid, sequence, propertylist)
    local inst = parse_lastchange(propertylist)
    if not inst then
        log.debug("RenderingControl event with no InstanceID")
        return
    end

    -- EQ switches
    for eqType, comp in pairs(eqtype_to_switch) do
        local value = lc_value(inst, eqType)
        if value then
            emit(device, comp, switch_event_for_value(value))
        end
    end

    -- EQ level sliders
    for eqType, comp in pairs(eqtype_to_level) do
        local value = lc_value(inst, eqType)
        if value then
            emit_level(device, comp, level_eqs[comp].cap, value)
        end
    end

    -- Bass / Treble (element name matches the component id)
    for comp, cfg in pairs(level_controls) do
        local value = lc_value(inst, comp)
        if value then
            emit_level(device, comp, cfg.cap, value)
        end
    end

    local vol = lc_value(inst, 'Volume')
    if vol then
        emit_volume(device, vol)
    end

    local mute = lc_value(inst, 'Mute')
    if mute then
        emit_mute(device, tostring(mute) == '1')
    end
end

function upnp_services.avtransport_event_callback(device, sid, sequence, propertylist)
    local inst = parse_lastchange(propertylist)
    if not inst then
        return
    end
    local state = lc_value(inst, 'TransportState')
    if state then
        emit_transport_state(device, state)
    end

    -- Track metadata arrives as DIDL-Lite in the event value, so now-playing
    -- updates without polling. Fall back to CurrentTrackURI: on TV and line-in
    -- the transport URI is only reported when the source actually changes.
    local track_didl = lc_value(inst, 'CurrentTrackMetaData')
    local current_uri = lc_value(inst, 'AVTransportURI') or lc_value(inst, 'CurrentTrackURI')
    local current_didl = lc_value(inst, 'AVTransportURIMetaData')

    if usable(track_didl) then
        emit_track_data(device, track_didl, current_uri, current_didl)
    elseif current_uri then
        -- Sonos announces the new URI before it has metadata for it. Emitting
        -- on that replaced a real now-playing with "Unknown" and threw the
        -- album art away - which is what the tile actually showed while music
        -- was playing. A URI that names its own source (TV, line-in) is enough
        -- on its own; anything else has to be asked for once Sonos catches up.
        if source_from_uri(current_uri) then
            emit_track_data(device, nil, current_uri, current_didl)
        elseif not device:get_field("track_poll_pending") then
            device:set_field("track_poll_pending", true)
            device.thread:call_with_delay(1, function()
                device:set_field("track_poll_pending", nil)
                upnp_services.get_track_data(device)
            end)
        end
    end
end

-- Backward-compatible alias (older lifecycle code referenced event_callback).
upnp_services.event_callback = upnp_services.rendering_event_callback

-- ---------------------------------------------------------------------------
-- Discovery helper
-- ---------------------------------------------------------------------------

function upnp_services.discover_device(device)
    local upnpdev
    local waittime = 1 -- initially try for a quick response since it's a known device

    -- NOTE: a specific search target must include prefix (eg 'uuid:') for SSDP searches
    while waittime <= 3 do
        -- Report what SSDP actually returned: "found nothing" and "found other
        -- players but not this one" are very different failures.
        local seen = {}
        upnp.discover(upnp_services.searchtarget, waittime, function(devobj)
            table.insert(seen, tostring(devobj.uuid))
            if id_matches(device.device_network_id, devobj.uuid) then
                upnpdev = devobj
            end
        end)
        log.info(string.format("discover attempt %d for %s: %d responder(s) [%s]",
            waittime, tostring(device.device_network_id), #seen, table.concat(seen, ", ")))
        if upnpdev then
            return upnpdev
        end
        waittime = waittime + 1
        if waittime <= 3 then
            socket.sleep(2)
        end
    end
    return nil
end

return upnp_services
