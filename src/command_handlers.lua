local log = require "log"
local upnp_services = require "upnp_services"

local command_handlers = {}

-- Match lifecycle.lua: identify room-group children by their ":group:" DNI, not
-- by parent_device_id (which the platform sets to the hub for all LAN devices).
local function is_room_child(device)
    local dni = device.device_network_id
    return dni ~= nil and dni:find(":group:", 1, true) ~= nil
end

-- Switch handlers: a child device is a per-room group toggle; on the soundbar,
-- Party Mode groups/ungroups everyone and TV Mode selects the TV input,
-- everything else is a RenderingControl toggle (Dialog / Night Mode / Surround
-- Mode / Loudness).
function command_handlers.switch_on(driver, device, command)
    if is_room_child(device) then
        upnp_services.join_room(driver, device)
    elseif command.component == 'PartyMode' then
        upnp_services.group_all(device, driver)
    elseif command.component == 'TVMode' then
        upnp_services.play_tv(device)
    else
        upnp_services.set_switch(device, command.component, true)
    end
end

function command_handlers.switch_off(driver, device, command)
    if is_room_child(device) then
        upnp_services.leave_room(driver, device)
    elseif command.component == 'PartyMode' then
        upnp_services.ungroup_all(device, driver)
    elseif command.component == 'TVMode' then
        upnp_services.leave_tv(device)
    else
        upnp_services.set_switch(device, command.component, false)
    end
end

-- Level sliders (Bass / Treble / Sub / Height / Surround) -------------------
function command_handlers.set_level(driver, device, command)
    upnp_services.set_level(device, command.component, command.args.level)
end

-- Momentary buttons: Sync Sonos Rooms creates per-room toggles, Reset EQ
-- flattens the sliders. (TV Mode was one of these; it is a switch now, so it
-- can show whether the soundbar is on its TV input and be used as a condition
-- in a routine.)
function command_handlers.push(driver, device, command)
    if command.component == 'SyncRooms' then
        upnp_services.sync_rooms(driver, device)
    else
        upnp_services.reset_eq(device)
    end
end

-- Volume -------------------------------------------------------------------
function command_handlers.set_volume(driver, device, command)
    upnp_services.set_volume(device, command.args.volume)
end

function command_handlers.volume_up(driver, device, command)
    upnp_services.adjust_volume(device, upnp_services.VOLUME_STEP)
end

function command_handlers.volume_down(driver, device, command)
    upnp_services.adjust_volume(device, -upnp_services.VOLUME_STEP)
end

-- Mute ---------------------------------------------------------------------
function command_handlers.set_mute(driver, device, command)
    upnp_services.set_mute(device, command.args.state == 'muted')
end

function command_handlers.mute(driver, device, command)
    upnp_services.set_mute(device, true)
end

function command_handlers.unmute(driver, device, command)
    upnp_services.set_mute(device, false)
end

-- Transport ----------------------------------------------------------------
function command_handlers.play(driver, device, command)
    upnp_services.transport_play(device)
end

function command_handlers.pause(driver, device, command)
    upnp_services.transport_pause(device)
end

function command_handlers.stop(driver, device, command)
    upnp_services.transport_stop(device)
end

function command_handlers.set_playback_status(driver, device, command)
    local status = command.args.playbackStatus
    if status == 'playing' then
        upnp_services.transport_play(device)
    elseif status == 'paused' then
        upnp_services.transport_pause(device)
    elseif status == 'stopped' then
        upnp_services.transport_stop(device)
    end
end

function command_handlers.next_track(driver, device, command)
    upnp_services.transport_next(device)
end

function command_handlers.previous_track(driver, device, command)
    upnp_services.transport_previous(device)
end

-- Sonos favorites ----------------------------------------------------------
function command_handlers.play_preset(driver, device, command)
    upnp_services.play_preset(device, tostring(command.args.presetId))
end

-- Announcements ------------------------------------------------------------
-- playTrack leaves the clip playing; playTrackAndResume restarts what was
-- playing; playTrackAndRestore puts the transport back without resuming.
function command_handlers.play_track(driver, device, command)
    upnp_services.play_notification(device, command.args.uri, command.args.level, nil, false)
end

function command_handlers.play_track_and_resume(driver, device, command)
    upnp_services.play_notification(device, command.args.uri, command.args.level,
        command.args.duration, true)
end

function command_handlers.play_track_and_restore(driver, device, command)
    upnp_services.play_notification(device, command.args.uri, command.args.level,
        command.args.duration, false)
end

-- Group volume / mute ------------------------------------------------------
function command_handlers.set_group_volume(driver, device, command)
    upnp_services.set_group_volume(device, command.args.groupVolume)
end

function command_handlers.group_volume_up(driver, device, command)
    upnp_services.adjust_group_volume(device, upnp_services.VOLUME_STEP)
end

function command_handlers.group_volume_down(driver, device, command)
    upnp_services.adjust_group_volume(device, -upnp_services.VOLUME_STEP)
end

function command_handlers.set_group_mute(driver, device, command)
    upnp_services.set_group_mute(device, command.args.groupMute == 'muted')
end

function command_handlers.mute_group(driver, device, command)
    upnp_services.set_group_mute(device, true)
end

function command_handlers.unmute_group(driver, device, command)
    upnp_services.set_group_mute(device, false)
end

-- Refresh ------------------------------------------------------------------
function command_handlers.refresh(driver, device)
    if is_room_child(device) then
        upnp_services.refresh_room(driver, device)
    else
        -- A refresh the user asked for re-reads the favorites even if the
        -- cached copy is still young: refreshing right after adding one in the
        -- Sonos app has to show it.
        upnp_services.refresh_components(device, true)
    end
end

return command_handlers
