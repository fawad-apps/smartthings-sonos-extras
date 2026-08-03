local log = require "log"
local discovery = require "discovery"
local upnp_services = require "upnp_services"
local lifecycle = {}
local upnp = require "UPnP"

lifecycle.SUBSCRIBETIME = 86400

local function is_room_child(device)
    return device.parent_device_id ~= nil and device.parent_device_id ~= ''
end

-- Subscribe to both RenderingControl (EQ / volume / mute) and AVTransport
-- (playback state). Each subscription gets its own SID and callback.
local function subscribe_device(device)
    local upnpdev = device:get_field('upnpdevice')
    if not upnpdev then
        return
    end

    local rc = upnpdev:subscribe(upnp_services.rendering_service_id,
        upnp_services.rendering_event_callback, lifecycle.SUBSCRIBETIME, nil)
    if rc ~= nil then
        device:set_field("upnp_sid", rc.sid)
    end

    local av = upnpdev:subscribe(upnp_services.avtransport_service_id,
        upnp_services.avtransport_event_callback, lifecycle.SUBSCRIBETIME, nil)
    if av ~= nil then
        device:set_field("upnp_sid_av", av.sid)
    end

    return rc
end

local function cancel_subscriptions(device, upnpdev, unsubscribe)
    for _, field in ipairs({ "upnp_sid", "upnp_sid_av" }) do
        local sid = device:get_field(field)
        if sid then
            if unsubscribe then
                upnpdev:unsubscribe(sid)
            end
            upnpdev:cancel_resubscribe(sid)
            device:set_field(field, nil)
        end
    end
end

local function status_changed_callback(device)
    local upnpdev = device:get_field("upnpdevice")
    local sid = device:get_field("upnp_sid")

    if upnpdev.online then
        log.info("Device is back online")
        device:online()
        if sid then
            subscribe_device(device)
        end
    else
        log.info("Device has gone offline")
        device:offline()
        cancel_subscriptions(device, upnpdev, false)
    end
end

local function startup(driver, device, upnpdev)
    if upnpdev then
        upnpdev:init(driver, device)
        upnpdev:monitor(status_changed_callback)
        subscribe_device(device)
    end
    device:online()
    upnp_services.emit_static_capabilities(device)
    upnp_services.refresh_components(device)
end

function lifecycle.device_added(driver, device)
    log.info("device_added")
    if is_room_child(device) then
        device:online()
        upnp_services.refresh_room(driver, device)
        return
    end
    local id = device.device_network_id
    local upnpdev = discovery.popNewlyAdded(id)
    startup(driver, device, upnpdev)
end

function lifecycle.device_removed(driver, device)
    log.info("device_removed")
    log.info("<" .. device.id .. "> removed")

    if is_room_child(device) then
        return
    end

    local upnpdev = device:get_field("upnpdevice")

    -- Clean up any outstanding event subscriptions
    if upnpdev then
        cancel_subscriptions(device, upnpdev, true)
        -- stop monitoring & allow for later re-discovery
        upnpdev:forget()
    end
end

function lifecycle.device_init(driver, device)
    log.info("device_init")
    if is_room_child(device) then
        device:online()
        upnp_services.refresh_room(driver, device)
        return
    end
    local upnpdev = device:get_field("upnpdevice")

    if upnpdev == nil then -- if nil, then this handler was called to initialize an existing device (eg driver reinstall)
        upnpdev = upnp_services.discover_device(device)
        if not upnpdev then
            log.warn("<" .. device.id .. "> not found on network")
            device:offline()
            return
        else
            -- Perform startup tasks for the device
            startup(driver, device, upnpdev)
        end
    else
        -- nothing else needs to be done if device metadata already available (already handled in device_added)
    end
end

function lifecycle.resubscribe_all(driver)
    local device_list = driver:get_devices()

    for _, device in ipairs(device_list) do
        -- Determine if there is a subscription for this device
        local sid = device:get_field("upnp_sid")
        if sid then
            local upnpdev = device:get_field("upnpdevice")
            local name = upnpdev:devinfo().friendlyName

            -- Resubscribe only if the device is online
            if upnpdev.online then
                cancel_subscriptions(device, upnpdev, true)
                log.info(string.format("Re-subscribing to %s", name))
                subscribe_device(device)
            else
                log.warn(string.format("%s is offline, can't re-subscribe now", name))
            end
        end
    end
end

function lifecycle.lan_info_changed_handler(driver, hub_ipv4)
    if driver.listen_ip == nil or hub_ipv4 ~= driver.listen_ip then
        -- reset device monitoring and subscription event server
        upnp.reset(driver)
        -- renew all subscriptions
        lifecycle.resubscribe_all(driver)
    end
end

return lifecycle
