local log = require "log"
local capabilities = require "st.capabilities"
local upnp = require "UPnP"
local cosock = require "cosock"
local socket = require "cosock.socket"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local tree = require "xmlhandler.tree"
local xml2lua = require "xml2lua"

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

local function command(device, service_id, action, arguments)
    local upnpdev = device:get_field("upnpdevice")
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

-- Send a raw SOAP action to an explicit ip:port. Used to command *other*
-- Sonos players (for grouping) that aren't managed as SmartThings devices.
local function soap_post(ip, port, path, service_type, action, args)
    local body_args = ''
    for name, value in pairs(args or {}) do
        body_args = body_args .. '<' .. name .. '>' .. tostring(value) .. '</' .. name .. '>'
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
    if code ~= 200 then
        log.error(string.format("SOAP %s to %s failed: %s", action, tostring(ip), tostring(code)))
        return false
    end
    return true
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

-- Parse ZoneGroupTopology into a list of groups, each with a coordinator UUID
-- and its members (uuid / ip / port / name / invisible).
local function collect_zone_groups(device)
    local response = command(device, upnp_services.zonetopology_service_id, 'GetZoneGroupState', {})
    if not (response and response.GetZoneGroupState and response.GetZoneGroupState.ZoneGroupState) then
        log.error("Could not read ZoneGroupState")
        return nil
    end

    local res = tree:new()
    local parser = xml2lua.parser(res)
    parser:parse(response.GetZoneGroupState.ZoneGroupState)

    local zgs = res and res.root and res.root.ZoneGroupState
    if not (zgs and zgs.ZoneGroups and zgs.ZoneGroups.ZoneGroup) then
        return nil
    end

    local raw_groups = zgs.ZoneGroups.ZoneGroup
    if raw_groups._attr then
        raw_groups = { raw_groups } -- single group -> array
    end

    local groups = {}
    for _, g in ipairs(raw_groups) do
        local members = {}
        local raw_members = g.ZoneGroupMember
        if raw_members then
            if raw_members._attr then
                raw_members = { raw_members }
            end
            for _, m in ipairs(raw_members) do
                if m._attr and m._attr.UUID then
                    local loc = m._attr.Location or ''
                    table.insert(members, {
                        uuid = m._attr.UUID,
                        ip = loc:match("http://([^:/]+)"),
                        port = loc:match("http://[^:]+:(%d+)") or "1400",
                        name = m._attr.ZoneName,
                        invisible = (m._attr.Invisible == "1")
                    })
                end
            end
        end
        table.insert(groups, { coordinator = g._attr and g._attr.Coordinator, members = members })
    end
    return groups
end

local function set_party_switch(device, on)
    emit(device, 'PartyMode', on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
end

-- Group every other (visible) Sonos player under this soundbar.
function upnp_services.group_all(device)
    local self_uuid = device.device_network_id
    local groups = collect_zone_groups(device)
    if not groups then
        return
    end

    -- Make this soundbar the head of its own group first.
    av_command(device, 'BecomeCoordinatorOfStandaloneGroup', { InstanceID = 0 })

    local target = "x-rincon:" .. self_uuid
    local count = 0
    for _, group in ipairs(groups) do
        for _, m in ipairs(group.members) do
            if m.uuid ~= self_uuid and m.ip and not m.invisible then
                if soap_post(m.ip, m.port, AV_CONTROL_PATH, AV_SERVICE_TYPE, 'SetAVTransportURI',
                        { InstanceID = 0, CurrentURI = target, CurrentURIMetaData = "" }) then
                    count = count + 1
                end
            end
        end
    end
    log.info(string.format("Party mode ON: grouped %d player(s) under %s", count, tostring(self_uuid)))
    set_party_switch(device, count > 0)
end

-- Split every other player currently grouped with this soundbar into standalone.
function upnp_services.ungroup_all(device)
    local self_uuid = device.device_network_id
    local groups = collect_zone_groups(device)
    if not groups then
        set_party_switch(device, false)
        return
    end

    local count = 0
    for _, group in ipairs(groups) do
        for _, m in ipairs(group.members) do
            if m.uuid ~= self_uuid and m.ip and not m.invisible then
                if soap_post(m.ip, m.port, AV_CONTROL_PATH, AV_SERVICE_TYPE,
                        'BecomeCoordinatorOfStandaloneGroup', { InstanceID = 0 }) then
                    count = count + 1
                end
            end
        end
    end
    log.info(string.format("Party mode OFF: ungrouped %d player(s)", count))
    set_party_switch(device, false)
end

-- Reflect current grouping state on the Party Mode switch.
function upnp_services.get_group_state(device)
    local groups = collect_zone_groups(device)
    if not groups then
        return
    end
    local self_uuid = device.device_network_id
    local grouped = false
    for _, group in ipairs(groups) do
        local contains_self, others = false, 0
        for _, m in ipairs(group.members) do
            if m.uuid == self_uuid then
                contains_self = true
            elseif not m.invisible then
                others = others + 1
            end
        end
        if contains_self and others > 0 then
            grouped = true
        end
    end
    set_party_switch(device, grouped)
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

function upnp_services.refresh_components(device)
    for comp in pairs(switch_eqs) do
        upnp_services.get_switch_eq(device, comp)
    end
    for comp in pairs(level_eqs) do
        get_level_eq(device, comp)
    end
    for comp in pairs(level_controls) do
        get_level_control(device, comp)
    end
    upnp_services.get_volume(device)
    upnp_services.get_mute(device)
    upnp_services.get_transport_state(device)
    upnp_services.get_group_state(device)
end

-- ---------------------------------------------------------------------------
-- Eventing
-- ---------------------------------------------------------------------------

-- Find the value of a LastChange child for the Master channel. The node may be
-- a single element or an array (Master/LF/RF).
local function master_value(node)
    if not node then
        return nil
    end
    if node._attr then
        if node._attr.channel == nil or node._attr.channel == 'Master' then
            return node._attr.val
        end
        return nil
    end
    for _, entry in ipairs(node) do
        if entry._attr and entry._attr.channel == 'Master' then
            return entry._attr.val
        end
    end
    return nil
end

local function parse_lastchange(propertylist)
    if not (propertylist and propertylist.LastChange) then
        return nil
    end
    local res = tree:new()
    local parser = xml2lua.parser(res)
    parser:parse(propertylist.LastChange)
    if res and res.root and res.root.Event and res.root.Event.InstanceID then
        return res.root.Event.InstanceID
    end
    return nil
end

function upnp_services.rendering_event_callback(device, sid, sequence, propertylist)
    local inst = parse_lastchange(propertylist)
    if not inst then
        log.debug("RenderingControl event with no InstanceID")
        return
    end

    -- EQ switches
    for eqType, comp in pairs(eqtype_to_switch) do
        local node = inst[eqType]
        if node and node._attr then
            emit(device, comp, switch_event_for_value(node._attr.val))
        end
    end

    -- EQ level sliders
    for eqType, comp in pairs(eqtype_to_level) do
        local node = inst[eqType]
        if node and node._attr then
            emit_level(device, comp, level_eqs[comp].cap, node._attr.val)
        end
    end

    -- Bass / Treble (element name matches the component id)
    for comp, cfg in pairs(level_controls) do
        local value = master_value(inst[comp])
        if value then
            emit_level(device, comp, cfg.cap, value)
        end
    end

    local vol = master_value(inst.Volume)
    if vol then
        emit_volume(device, vol)
    end

    local mute = master_value(inst.Mute)
    if mute then
        emit_mute(device, tostring(mute) == '1')
    end
end

function upnp_services.avtransport_event_callback(device, sid, sequence, propertylist)
    local inst = parse_lastchange(propertylist)
    if not inst then
        return
    end
    if inst.TransportState and inst.TransportState._attr then
        emit_transport_state(device, inst.TransportState._attr.val)
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
        upnp.discover(upnp_services.searchtarget, waittime, function(devobj)
            if device.device_network_id == devobj.uuid then
                upnpdev = devobj
            end
        end)
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
