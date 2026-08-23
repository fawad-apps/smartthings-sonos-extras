# Sonos Extras

A SmartThings Edge driver that controls a Sonos soundbar directly over your LAN
with UPnP — no cloud account, no Sonos API key. It discovers the player over
SSDP and subscribes to its events, so the tile follows whatever you do from the
Sonos app or the remote.

This fork adds a full local control surface on top of the original EQ switches.

## What it controls

**Main tile**

| Control | Notes |
|---|---|
| Volume / mute | Also group volume and group mute |
| Play / pause / stop, next / previous track | |
| Now playing | Title, artist, album and cover art |
| Favorites | Your Sonos favorites, playable as presets |
| Announcements | Play a clip and put back what was playing |
| Group state | Which group the soundbar is in, and its role |

**Buttons and sliders**

| Component | What it does |
|---|---|
| Dialog Level, Night Mode, Loudness | On/off sound settings |
| Surrounds On | Whether the surround speakers play at all (`SurroundEnable`) |
| Surround Music - Full | Ambient or Full surround for **music** played through the home theatre (`SurroundMode`). Despite the old name this was never an on/off for the surrounds — that is Surrounds On |
| Bass, Treble, Sub Level, Height/Atmos Level | Sliders showing the real Sonos value (e.g. `+3`), not a 0–100 % dimmer |
| Surround Level (TV), Surround Level (Music) | Two independent trims on the same surround speakers, one per source, each −15…+15 |
| Reset EQ | Flattens every slider to 0 |
| TV Mode | Selects the soundbar's TV input, leaving a group first if it is only a guest in one. A switch rather than a button, so it also *shows* whether the soundbar is on TV audio and can be used as a condition in a routine — and it tracks the source even when you change it from the Sonos app or the TV remote, since the transport URI is in the events the driver already receives |
| Party Mode | Groups every other visible speaker under the soundbar; off splits them again |
| Sync Sonos Rooms | Creates one child device per other Sonos room, each an on/off toggle that joins or leaves the soundbar's group |

## Supported devices

Sonos home-theater devices (soundbars). Known model numbers are matched
directly (`S9` Playbar, `S14` Beam Gen 1, `S19` Arc). Newer or unlisted
soundbars — including the **Arc Ultra**, Beam Gen 2 and Ray — are matched by
manufacturer + model name, so they work without adding a model number.

Non-soundbar Sonos speakers (One, Era, Move, etc.) do not expose these EQ
settings and are intentionally not created as devices of their own. They still
appear as Party Mode and Sync Rooms targets.

On newer models such as the Arc Ultra, `DialogLevel` reports an intensity of
1–4 rather than a simple on/off. The Dialog Level switch treats any non-zero
value as **on**; turning it off sends level 0.

## Known limitations

**Sonos Radio favorites cannot be played.** A favorite is playable only when it
carries a resource (`<res>`) — the URI Sonos itself would use. Sonos Radio
station favorites are stored as *shortcuts* with an empty `<res>`, and only the
Sonos app can play one, by resolving it through Sonos's cloud. The player will
not resolve it locally: every URI that can be reconstructed from the favorite's
metadata is accepted by `SetAVTransportURI` and then fails at `Play` with UPnP
error 501, and the service refuses to be browsed for the real station id (701).
Such favorites are therefore left out of the preset list rather than offered as
buttons that cannot work; the driver logs which ones it skipped and why.

**TV Mode cannot be switched off.** The player refuses to stop its TV input —
`Stop` comes back as UPnP error 701 and it keeps playing. Turning the switch off
therefore re-reads the real source and puts the switch back where it was, rather
than lying about what the speaker is doing. What actually leaves the TV input is
selecting another source: playing a favorite, or joining another speaker's group.

**Music-service favorites need that service linked to the household.** A
favorite belonging to a service the household has no account for fails with UPnP
error 800 — including the Amazon Music demo favorites that ship on a new Sonos
system. The driver logs the error code and what it means.

**Album art is served by the speaker.** Sonos returns cover art as a
player-relative path, which the driver turns into a `http://<player>:1400/getaa…`
URL. This renders in the SmartThings app.

**Adopting a device from another driver.** If you move a speaker onto this
driver with "Change driver", it keeps the previous driver's profile and DNI. The
driver switches it onto its own profile automatically and canonicalises the
identifier — SmartThings' own Sonos driver uses the bare MAC, SSDP advertises
`RINCON_…_MR`, and grouping URIs need the bare `RINCON_…01400`. Note that
adopting the device means SmartThings' official Sonos features are gone, so
anything you want has to be implemented here.

Adding or changing components sometimes does not appear until the device is
removed and re-added ("Scan nearby"). Custom capabilities in particular usually
need a re-add.

## Installing

Custom capabilities: the EQ sliders use two custom capabilities
(`…eqlevel` for −10..10 and `…surroundlevel` for −15..15), each with a slider
presentation. They live under a personal namespace, so if you are building this
yourself you need to create your own and update the ids in
`profiles/sonos-extras.yaml` and `src/init.lua`.

1. Install the SmartThings CLI: `npm install -g @smartthings/cli`
2. Authenticate it, and create a channel if you don't have one:
   `smartthings edge:channels:create`
3. Package and upload: `smartthings edge:drivers:package .`
4. Assign it to your channel: `smartthings edge:channels:assign`
5. Enroll your hub and install: `smartthings edge:channels:enroll` then
   `smartthings edge:drivers:install`
6. In the SmartThings app, **Add device → Scan nearby**.

See the [Developer Docs](https://developer-preview.smartthings.com/docs/devices/hub-connected/enroll-in-a-shared-channel/)
for details on channels and driver installation.

### scripts/deploy.sh

`scripts/deploy.sh` does the whole cycle and refuses to ship a build that does
not pass `scripts/test.sh`. It matters that it does all three steps: packaging
uploads a version but does **not** publish it to the channel, so without
`channels:assign` in between, `drivers:install` reports success while
re-installing the previous build — the hub keeps running old code and nothing
appears to change. The script then polls the hub until it confirms the new
version, so a failed deploy is loud instead of silent.

The driver, channel and hub ids at the top of the script are the author's;
change them to your own.

## Development

```
scripts/test.sh      # syntax check + regression tests, no hub required
```

Tests run off-hub with plain `lua` against stubbed SmartThings modules
(`tests/stubs.lua`) and real payloads captured from an Arc Ultra
(`tests/fixtures/`). The stubs record what the driver put on the wire, so tests
can assert on request shape and count — that a refresh answers the visible
controls before the heavy payloads, that the household topology is fetched once
per burst rather than once per consumer, and so on.

Every test corresponds to a failure that actually reached the hub, because this
driver's failure mode is silence: it keeps serving a tile that looks fine while
doing nothing.

### Watching it run

```
smartthings edge:drivers:logcat --all --hub-address <hub-ip>
```

The driver-id filter argument silently returns nothing — use `--all` and grep.
The driver logs under its display name.

### Talking to the speaker directly

`scripts/sonos-eq.sh <IP>` reads the real EQ values straight off the player over
SOAP, which is the ground truth for checking whether a tile is accurate. Sonos
serves every service on the player's own `<ip>:1400`, so any action can be
tested with a plain SOAP POST before touching driver code.

### Finding your model number

```
curl -s http://<SOUNDBAR_IP>:1400/xml/device_description.xml | grep -E "modelNumber|modelName|manufacturer"
```

## How it works

Discovery is SSDP; state comes from UPnP event subscriptions on
`RenderingControl` (volume, mute, EQ) and `AVTransport` (playback, now playing),
renewed off the lifetime Sonos actually grants rather than a fixed timer.

Sonos payloads embed escaped XML inside XML *attribute values* — DIDL-Lite track
metadata inside a `LastChange` `val=`. A tree parser cannot handle that; it
fails with `Unbalanced Tag (/DIDL-Lite)` and silently drops every event. Both
`LastChange` and `ZoneGroupState` are therefore read with targeted patterns, and
no XML parser is used for them.
