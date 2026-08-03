local log = require "log"
local discovery = require "discovery"
local upnp_services = require "upnp_services"
local lifecycle = {}
local upnp = require "UPnP"

-- Sonos drops event subscriptions silently - on a reboot, a software update, or
-- any spell where it can't reach the hub's callback - and nothing tells us.
-- Asking for a day-long subscription meant that when one died, every tile
-- stayed frozen until the next manual refresh. Ask for an hour and renew at
-- half that, so a lost subscription costs half an hour of staleness at worst
-- instead of a day, for two requests every 30 minutes.
lifecycle.SUBSCRIBETIME = 3600

-- Safety net for the per-device renewal timers below.
lifecycle.RESUBSCRIBE_INTERVAL = 3600

-- Room-group children are created with a "<parent uuid>:group:<room uuid>" DNI.
-- Do NOT test parent_device_id: the platform sets that to the hub for every LAN
-- device, so the soundbar itself would look like a child and skip discovery.
local function is_room_child(device)
    local dni = device.device_network_id
    return dni ~= nil and dni:find(":group:", 1, true) ~= nil
end

-- Subscribe to both RenderingControl (EQ / volume / mute) and AVTransport
-- (playback state). Each subscription gets its own SID and callback.
-- A device adopted from another driver via "Change driver" keeps the previous
-- driver's profile, so none of our components exist on it. Move it onto ours.
local function ensure_profile(device)
    local components = device.profile and device.profile.components
    if components and components.DialogLevel then
        return
    end
    log.info("<" .. device.id .. "> is not on the sonos-extras profile; switching")
    device:try_update_metadata({ profile = "sonos-extras" })
end

-- Sonos answers with the lifetime it actually granted ("Second-3600"), which
-- can be shorter than what we asked for. Renewing off our own number instead
-- would let the subscription lapse and take the live tile updates with it.
local function granted_seconds(response)
    local secs = response and response.timeout
        and tostring(response.timeout):match("Second%-(%d+)")
    return tonumber(secs) or lifecycle.SUBSCRIBETIME
end

local schedule_renewal -- defined below; mutually recursive with subscribe_device

local function subscribe_device(device)
    local upnpdev = device:get_field('upnpdevice')
    if not upnpdev then
        return
    end

    -- Any renewal timer from an earlier call is now stale. Both the driver-wide
    -- timer and the per-device one land here, so without this they would fork
    -- into competing renewal chains that resubscribe forever.
    local generation = (device:get_field("sub_gen") or 0) + 1
    device:set_field("sub_gen", generation)

    local lifetime = lifecycle.SUBSCRIBETIME

    local rc = upnpdev:subscribe(upnp_services.rendering_service_id,
        upnp_services.rendering_event_callback, lifecycle.SUBSCRIBETIME, nil)
    if rc ~= nil then
        device:set_field("upnp_sid", rc.sid)
        lifetime = math.min(lifetime, granted_seconds(rc))
    end

    local av = upnpdev:subscribe(upnp_services.avtransport_service_id,
        upnp_services.avtransport_event_callback, lifecycle.SUBSCRIBETIME, nil)
    if av ~= nil then
        device:set_field("upnp_sid_av", av.sid)
        lifetime = math.min(lifetime, granted_seconds(av))
    end

    if rc or av then
        schedule_renewal(device, generation, math.max(300, math.floor(lifetime / 2)))
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

schedule_renewal = function(device, generation, seconds)
    device.thread:call_with_delay(seconds, function()
        if device:get_field("sub_gen") ~= generation then
            return -- a later subscribe already took over
        end
        local upnpdev = device:get_field("upnpdevice")
        if not upnpdev then
            return
        end
        if not upnpdev.online then
            -- Coming back online resubscribes; renewing at an unreachable
            -- player would just block on timeouts.
            schedule_renewal(device, generation, seconds)
            return
        end
        cancel_subscriptions(device, upnpdev, true)
        subscribe_device(device)
    end)
end

local function status_changed_callback(device)
    local upnpdev = device:get_field("upnpdevice")

    if upnpdev.online then
        log.info("Device is back online")
        device:online()
        -- Always resubscribe. Going offline cleared upnp_sid, so the old
        -- "only if we had a subscription" test could never be true here: a
        -- device that blipped offline came back with no event subscriptions at
        -- all and every tile stayed frozen until the driver was reinstalled.
        subscribe_device(device)
        -- State may well have moved while it was away; catch the tiles up off
        -- the monitor thread.
        device.thread:call_with_delay(1, function()
            upnp_services.refresh_components(device)
        end)
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

    -- Create the per-room toggles without anyone having to find and press the
    -- Sync Sonos Rooms button first. Deferred so it lands behind the refresh
    -- rather than adding another topology fetch to startup, and guarded so a
    -- failure here cannot take the rest of startup with it.
    device.thread:call_with_delay(15, function()
        local ok, err = pcall(upnp_services.sync_rooms, driver, device)
        if not ok then
            log.warn("Automatic room sync failed: " .. tostring(err))
        end
    end)
end

-- Let upnp_services fully re-initialise a device it reacquires on demand.
upnp_services.reinit_hook = function(device, upnpdev)
    startup(device.driver, device, upnpdev)
end

-- Discovery can fail transiently at driver startup (the hub races several
-- description fetches at once). Keep retrying with backoff instead of leaving
-- the device dead until the driver is reinstalled.
local REDISCOVER_BACKOFF = { 30, 60, 120, 300, 600 }

local function schedule_rediscovery(driver, device, attempt)
    attempt = attempt or 1
    local delay = REDISCOVER_BACKOFF[math.min(attempt, #REDISCOVER_BACKOFF)]
    device.thread:call_with_delay(delay, function()
        if device:get_field("upnpdevice") then
            return
        end
        local upnpdev = upnp_services.discover_device(device)
        if upnpdev then
            log.info("<" .. device.id .. "> rediscovered after startup failure")
            startup(driver, device, upnpdev)
        else
            schedule_rediscovery(driver, device, attempt + 1)
        end
    end)
end

function lifecycle.device_added(driver, device)
    log.info("device_added")
    if is_room_child(device) then
        device:online()
        upnp_services.refresh_room(driver, device)
        return
    end
    ensure_profile(device)
    local id = device.device_network_id
    local upnpdev = discovery.popNewlyAdded(id)
    startup(driver, device, upnpdev)
end

-- Fires when the user reassigns an existing device to this driver in the app.
function lifecycle.driver_switched(driver, device)
    log.info("driver_switched")
    if is_room_child(device) then
        return
    end
    ensure_profile(device)
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

    upnp_services.invalidate_topology(device)
end

function lifecycle.device_init(driver, device)
    log.info(string.format("device_init: <%s> dni=%s profile=%s",
        device.id, tostring(device.device_network_id),
        tostring(device.profile and device.profile.id)))
    if is_room_child(device) then
        device:online()
        upnp_services.refresh_room(driver, device)
        return
    end
    ensure_profile(device)
    local upnpdev = device:get_field("upnpdevice")

    if upnpdev == nil then -- if nil, then this handler was called to initialize an existing device (eg driver reinstall)
        upnpdev = upnp_services.discover_device(device)
        if not upnpdev then
            log.warn("<" .. device.id .. "> not found on network; will keep retrying")
            device:offline()
            schedule_rediscovery(driver, device)
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
        -- Don't gate on an existing sid: a device whose subscriptions were
        -- dropped is exactly the one that needs resubscribing, and it has no
        -- sid left to test.
        local upnpdev = device:get_field("upnpdevice")
        if upnpdev then
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
    if driver.listen_ip ~= nil and hub_ipv4 == driver.listen_ip then
        return
    end
    -- Remember it, or the guard is true on every call because nothing else
    -- ever set this, and a reset ran each time the platform mentioned the IP.
    driver.listen_ip = hub_ipv4
    log.info("Hub IP is now " .. tostring(hub_ipv4) .. "; resetting UPnP and resubscribing")

    -- Reset device monitoring and the subscription event server. Guarded: this
    -- path is only reached when something already went wrong with the network,
    -- and a failure here used to take the resubscribe below down with it -
    -- leaving every subscription pointed at an address that no longer exists.
    local ok, err = pcall(upnp.reset, driver)
    if not ok then
        log.error("UPnP reset failed: " .. tostring(err))
    end

    -- upnp.reset empties the monitor's watch table, and only startup ever adds
    -- to it, so online/offline detection would stay dead for the life of the
    -- driver unless every device re-registers here.
    for _, device in ipairs(driver:get_devices()) do
        local upnpdev = device:get_field("upnpdevice")
        if upnpdev then
            pcall(function() upnpdev:monitor(status_changed_callback) end)
        end
    end

    lifecycle.resubscribe_all(driver)
end

return lifecycle
