local log = require "log"
local upnp = require "UPnP"
local cosock = require "cosock" -- cosock used only for sleep timers in this module
local socket = require "cosock.socket"
local upnp_services = require "upnp_services"
local discovery = {}

-- Known Sonos home-theater model numbers (fast path).
local profiles = {
    ["S9"] = "sonos-extras",  -- Playbar
    ["S14"] = "sonos-extras", -- Beam (Gen 1)
    ["S19"] = "sonos-extras", -- Arc
    ["S59"] = "sonos-extras"  -- Beam Ultra
}

-- Fallback so newer / unlisted Sonos soundbars (e.g. Arc Ultra, Beam Gen 2,
-- Ray) are supported without adding a model number here. We only match Sonos
-- home-theater devices by name, so satellite speakers (One, Era, etc.) that
-- don't expose these EQ settings aren't picked up.
local soundbar_keywords = { "arc", "beam", "ray", "playbar" }

local function resolve_profile(devinfo)
    local by_model = profiles[devinfo.modelNumber]
    if by_model then
        return by_model
    end

    local manufacturer = (devinfo.manufacturer or ""):lower()
    if manufacturer:find("sonos", 1, true) then
        local name = ((devinfo.modelName or "") .. " " .. (devinfo.modelDescription or "")):lower()
        for _, keyword in ipairs(soundbar_keywords) do
            if name:find(keyword, 1, true) then
                return "sonos-extras"
            end
        end
    end

    return nil
end

local newly_added = {}

function discovery.handler(driver, opts, should_continue)
    local known_devices = {}
    local found_devices = {}

    local device_list = driver:get_devices()
    for _, device in ipairs(device_list) do
        local id = device.device_network_id
        known_devices[id] = true
    end

    local waitTime = 3
    local repeat_count = 3
    while should_continue() and (repeat_count > 0) do
        log.info("request " .. ((repeat_count * -1) + 4) .. " searchtarget " .. upnp_services.searchtarget)
        upnp.discover(upnp_services.searchtarget, waitTime, function(upnpdev)
            local id = upnpdev.uuid
            if not known_devices[id] and not found_devices[id] then
                found_devices[id] = true
                local devinfo = upnpdev:devinfo()
                local modelNumber = devinfo.modelNumber
                local devprofile = resolve_profile(devinfo)
                if devprofile then
                    log.info(string.format("Matched Sonos device '%s' model %s",
                        devinfo.friendlyName or "?", modelNumber or "?"))
                    local create_device_msg = {
                        type = "LAN",
                        device_network_id = id,
                        label = devinfo.friendlyName,
                        profile = devprofile,
                        manufacturer = devinfo.manufacturer,
                        model = modelNumber,
                        vendor_provided_label = devinfo.modelName
                    }

                    assert(driver:try_create_device(create_device_msg), "failed to create device record")
                    newly_added[id] = upnpdev
                end
            end
        end)

        repeat_count = repeat_count - 1

        if repeat_count > 0 then
            socket.sleep(2) -- avoid creating network storms
        end
    end
    log.info("Driver is exiting discovery")
end

function discovery.popNewlyAdded(id)
    log.info("Popping: " .. id)
    local ret = newly_added[id]
    newly_added[id] = nil
    return ret
end

return discovery
