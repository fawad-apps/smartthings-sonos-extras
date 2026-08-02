local log = require "log"
local capabilities = require "st.capabilities"
local upnp = require "UPnP"
local socket = require "cosock.socket"
local tree = require "xmlhandler.tree"
local xml2lua = require "xml2lua"

local upnp_services = {}

upnp_services.rendering_service_id = "urn:upnp-org:serviceId:RenderingControl"
upnp_services.avtransport_service_id = "urn:upnp-org:serviceId:AVTransport"
upnp_services.searchtarget = 'urn:schemas-upnp-org:device:MediaRenderer:1'
-- Kept for backward compatibility with anything referencing the old name.
upnp_services.service_id = upnp_services.rendering_service_id

upnp_services.VOLUME_STEP = 5

-- ---------------------------------------------------------------------------
-- Feature configuration
-- ---------------------------------------------------------------------------

-- Switch-style EQ settings. Each maps a device component (a `switch`) to one or
-- more RenderingControl EQTypes tried in order. DialogLevel prefers the newer
-- SpeechEnhanceEnabled on/off flag (Arc Ultra and later), falling back to the
-- legacy DialogLevel value on older models.
local switch_eqs = {
    NightMode = { eqTypes = { "NightMode" } },
    SurroundMode = { eqTypes = { "SurroundMode" } },
    DialogLevel = { eqTypes = { "SpeechEnhanceEnabled", "DialogLevel" } }
}

-- Slider-style EQ settings (switchLevel, 0-100%) mapped onto a signed EQ range.
local level_eqs = {
    SubGain = { eqType = "SubGain", min = -10, max = 10 },
    HeightLevel = { eqType = "HeightChannelLevel", min = -10, max = 10 },
    SurroundLevel = { eqType = "SurroundLevel", min = -15, max = 15 }
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

local function round(n)
    return math.floor(n + 0.5)
end

local function eq_to_percent(cfg, value)
    value = tonumber(value) or cfg.min
    local pct = (value - cfg.min) / (cfg.max - cfg.min) * 100
    return math.max(0, math.min(100, round(pct)))
end

local function percent_to_eq(cfg, pct)
    pct = tonumber(pct) or 0
    local value = cfg.min + (pct / 100) * (cfg.max - cfg.min)
    return math.max(cfg.min, math.min(cfg.max, round(value)))
end

-- Sonos EQ values are historically 0/1, but newer models (e.g. Arc Ultra)
-- report DialogLevel as an intensity 1-4. Treat any non-zero value as "on".
local function switch_event_for_value(value)
    if value == nil or value == '0' or value == 0 then
        return capabilities.switch.switch.off()
    end
    return capabilities.switch.switch.on()
end

-- ---------------------------------------------------------------------------
-- Switch EQ (Night Mode, Surround Mode, Dialog)
-- ---------------------------------------------------------------------------

local function emit_switch(device, comp, value)
    local component = get_component(device, comp)
    if component then
        device:emit_component_event(component, switch_event_for_value(value))
    end
end

function upnp_services.get_switch_eq(device, comp)
    local cfg = switch_eqs[comp]
    for _, eqType in ipairs(cfg.eqTypes) do
        local response = rc_command(device, 'GetEQ', { InstanceID = 0, EQType = eqType })
        if response and response.GetEQ then
            emit_switch(device, comp, response.GetEQ.CurrentValue)
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
            emit_switch(device, comp, desired)
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Level EQ (Sub / Height / Surround) as 0-100% sliders
-- ---------------------------------------------------------------------------

function upnp_services.get_level_eq(device, comp)
    local cfg = level_eqs[comp]
    local response = rc_command(device, 'GetEQ', { InstanceID = 0, EQType = cfg.eqType })
    if response and response.GetEQ then
        local component = get_component(device, comp)
        if component then
            device:emit_component_event(component,
                capabilities.switchLevel.level(eq_to_percent(cfg, response.GetEQ.CurrentValue)))
        end
    end
end

function upnp_services.set_level_eq(device, comp, pct)
    local cfg = level_eqs[comp]
    local response = rc_command(device, 'SetEQ',
        { InstanceID = 0, EQType = cfg.eqType, DesiredValue = percent_to_eq(cfg, pct) })
    if response then
        local component = get_component(device, comp)
        if component then
            device:emit_component_event(component, capabilities.switchLevel.level(tonumber(pct)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Volume / Mute
-- ---------------------------------------------------------------------------

local function emit_volume(device, value)
    local component = get_component(device, 'main')
    if component then
        device:emit_component_event(component, capabilities.audioVolume.volume(tonumber(value) or 0))
    end
end

local function emit_mute(device, muted)
    local component = get_component(device, 'main')
    if component then
        local event = muted and capabilities.audioMute.mute.muted() or capabilities.audioMute.mute.unmuted()
        device:emit_component_event(component, event)
    end
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
        local component = get_component(device, 'main')
        if component then
            device:emit_component_event(component, event_ctor())
        end
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
    local component = get_component(device, 'main')
    if not component then
        return
    end
    device:emit_component_event(component,
        capabilities.mediaPlayback.supportedPlaybackCommands({ "play", "pause", "stop" }))
    device:emit_component_event(component,
        capabilities.mediaTrackControl.supportedTrackControlCommands({ "nextTrack", "previousTrack" }))
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

function upnp_services.refresh_components(device)
    for comp in pairs(switch_eqs) do
        upnp_services.get_switch_eq(device, comp)
    end
    for comp in pairs(level_eqs) do
        upnp_services.get_level_eq(device, comp)
    end
    upnp_services.get_volume(device)
    upnp_services.get_mute(device)
    upnp_services.get_transport_state(device)
end

-- ---------------------------------------------------------------------------
-- Eventing
-- ---------------------------------------------------------------------------

-- Find the value of a LastChange child for the Master channel. The node may be
-- a single element (single-channel devices) or an array (Master/LF/RF).
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

    -- EQ switches (only emit for the primary EQType that actually appeared)
    for eqType, comp in pairs(eqtype_to_switch) do
        local node = inst[eqType]
        if node and node._attr then
            emit_switch(device, comp, node._attr.val)
        end
    end

    -- EQ level sliders
    for eqType, comp in pairs(eqtype_to_level) do
        local node = inst[eqType]
        if node and node._attr then
            local cfg = level_eqs[comp]
            local component = get_component(device, comp)
            if component then
                device:emit_component_event(component,
                    capabilities.switchLevel.level(eq_to_percent(cfg, node._attr.val)))
            end
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
