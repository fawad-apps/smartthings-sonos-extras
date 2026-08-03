local discovery = require "discovery"
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local lifecycle = require "lifecycle"
local command_handlers = require "command_handlers"

local sonos_driver = Driver("Sonos Extras", {
    discovery = discovery.handler,
    lifecycle_handlers = {
        added = lifecycle.device_added,
        init = lifecycle.device_init,
        removed = lifecycle.device_removed,
        deleted = lifecycle.device_removed
    },
    lan_info_changed_handler = lifecycle.lan_info_changed_handler,
    capability_handlers = {
        [capabilities.switch.ID] = {
            [capabilities.switch.commands.on.NAME] = command_handlers.switch_on,
            [capabilities.switch.commands.off.NAME] = command_handlers.switch_off
        },
        ["autumnpepper05038.eqlevel"] = {
            ["setLevel"] = command_handlers.set_level
        },
        ["autumnpepper05038.surroundlevel"] = {
            ["setLevel"] = command_handlers.set_level
        },
        [capabilities.momentary.ID] = {
            [capabilities.momentary.commands.push.NAME] = command_handlers.push
        },
        [capabilities.audioVolume.ID] = {
            [capabilities.audioVolume.commands.setVolume.NAME] = command_handlers.set_volume,
            [capabilities.audioVolume.commands.volumeUp.NAME] = command_handlers.volume_up,
            [capabilities.audioVolume.commands.volumeDown.NAME] = command_handlers.volume_down
        },
        [capabilities.audioMute.ID] = {
            [capabilities.audioMute.commands.setMute.NAME] = command_handlers.set_mute,
            [capabilities.audioMute.commands.mute.NAME] = command_handlers.mute,
            [capabilities.audioMute.commands.unmute.NAME] = command_handlers.unmute
        },
        [capabilities.mediaPlayback.ID] = {
            [capabilities.mediaPlayback.commands.play.NAME] = command_handlers.play,
            [capabilities.mediaPlayback.commands.pause.NAME] = command_handlers.pause,
            [capabilities.mediaPlayback.commands.stop.NAME] = command_handlers.stop,
            [capabilities.mediaPlayback.commands.setPlaybackStatus.NAME] = command_handlers.set_playback_status
        },
        [capabilities.mediaTrackControl.ID] = {
            [capabilities.mediaTrackControl.commands.nextTrack.NAME] = command_handlers.next_track,
            [capabilities.mediaTrackControl.commands.previousTrack.NAME] = command_handlers.previous_track
        },
        [capabilities.refresh.ID] = {
            [capabilities.refresh.commands.refresh.NAME] = command_handlers.refresh
        }
    }
})

sonos_driver:call_on_schedule(lifecycle.SUBSCRIBETIME - 5, lifecycle.resubscribe_all, "Re-subscribe timer")

sonos_driver:run()
