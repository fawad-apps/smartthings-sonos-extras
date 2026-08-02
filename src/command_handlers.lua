local log = require "log"
local upnp_services = require "upnp_services"

local command_handlers = {}

-- Switch EQ (Dialog / Night Mode / Surround Mode) --------------------------
function command_handlers.switch_on(driver, device, command)
    upnp_services.set_switch_eq(device, command.component, true)
end

function command_handlers.switch_off(driver, device, command)
    upnp_services.set_switch_eq(device, command.component, false)
end

-- Level EQ sliders (Sub / Height / Surround) -------------------------------
function command_handlers.set_level(driver, device, command)
    upnp_services.set_level_eq(device, command.component, command.args.level)
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

-- Refresh ------------------------------------------------------------------
function command_handlers.refresh(driver, device)
    upnp_services.refresh_components(device)
end

return command_handlers
