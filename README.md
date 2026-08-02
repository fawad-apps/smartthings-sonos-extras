# Sonos Extras

Smartthings hub connected device to control Sonos 
* Dialog Level
* Night Mode
* Surround Mode

This device uses UPnP to discover the Sonos devices and subscribe to events to update the device state to match Sonos.

## Supported devices
Sonos home-theater devices (soundbars) are supported. Known model numbers are
matched directly (`S9` Playbar, `S14` Beam Gen 1, `S19` Arc). Newer or unlisted
soundbars — including the **Arc Ultra**, Beam Gen 2, and Ray — are matched by
manufacturer + model name, so they work without adding a model number.

Non-soundbar Sonos speakers (One, Era, Move, etc.) do not expose these EQ
settings and are intentionally not created.

Note: on newer models such as the Arc Ultra, `DialogLevel` reports an intensity
of 1–4 rather than a simple on/off. The Dialog Level switch treats any non-zero
value as **on**; turning it off sends level 0.

## How to install (build it yourself)
1. Install the SmartThings CLI: `npm install -g @smartthings/cli`
2. Log in / authenticate the CLI, and create your own channel if you don't have one:
   `smartthings edge:channels:create`
3. Package and upload this driver:
   `smartthings edge:drivers:package` (run from the repo root)
4. Assign the driver to your channel:
   `smartthings edge:channels:assign`
5. Enroll your hub in the channel and install the driver:
   `smartthings edge:channels:enroll` then `smartthings edge:drivers:install`
6. In the SmartThings app, run **Add device → Scan nearby** to discover the soundbar.

See the [Developer Docs](https://developer-preview.smartthings.com/docs/devices/hub-connected/enroll-in-a-shared-channel/) for details on channels and driver installation.

### Finding your model number
To confirm what your soundbar reports (handy if you want to add it to the fast-path list in `src/discovery.lua`):

```
curl -s http://<SOUNDBAR_IP>:1400/xml/device_description.xml | grep -E "modelNumber|modelName|manufacturer"
```