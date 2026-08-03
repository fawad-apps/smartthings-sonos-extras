local discovery = require "discovery"
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local lifecycle = require "lifecycle"
local command_handlers = require "command_handlers"
local log = require "log"

-- Loud startup marker: if this line is absent from logcat, the driver never
-- loaded and nothing below it is running.
log.info("=== Sonos Extras: driver module loaded ===")

local sonos_driver = Driver("Sonos Extras", {
    discovery = discovery.handler,
    lifecycle_handlers = {
        added = lifecycle.device_added,
        init = lifecycle.device_init,
        driverSwitched = lifecycle.driver_switched,
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
        [capabilities.mediaPresets.ID] = {
            [capabilities.mediaPresets.commands.playPreset.NAME] = command_handlers.play_preset
        },
        [capabilities.audioNotification.ID] = {
            [capabilities.audioNotification.commands.playTrack.NAME] = command_handlers.play_track,
            [capabilities.audioNotification.commands.playTrackAndResume.NAME] = command_handlers.play_track_and_resume,
            [capabilities.audioNotification.commands.playTrackAndRestore.NAME] = command_handlers.play_track_and_restore
        },
        [capabilities.mediaGroup.ID] = {
            [capabilities.mediaGroup.commands.setGroupVolume.NAME] = command_handlers.set_group_volume,
            [capabilities.mediaGroup.commands.groupVolumeUp.NAME] = command_handlers.group_volume_up,
            [capabilities.mediaGroup.commands.groupVolumeDown.NAME] = command_handlers.group_volume_down,
            [capabilities.mediaGroup.commands.setGroupMute.NAME] = command_handlers.set_group_mute,
            [capabilities.mediaGroup.commands.muteGroup.NAME] = command_handlers.mute_group,
            [capabilities.mediaGroup.commands.unmuteGroup.NAME] = command_handlers.unmute_group
        },
        [capabilities.refresh.ID] = {
            [capabilities.refresh.commands.refresh.NAME] = command_handlers.refresh
        }
    }
})

sonos_driver:call_on_schedule(lifecycle.SUBSCRIBETIME - 5, lifecycle.resubscribe_all, "Re-subscribe timer")

log.info("=== Sonos Extras: starting driver run loop ===")
sonos_driver:run()
