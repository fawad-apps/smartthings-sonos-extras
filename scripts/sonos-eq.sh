#!/usr/bin/env bash
# Read the real EQ values straight from a Sonos player over UPnP/SOAP.
# Usage: ./sonos-eq.sh <SONOS_IP>
set -euo pipefail
IP="${1:?usage: sonos-eq.sh <SONOS_IP>}"
RC="http://$IP:1400/MediaRenderer/RenderingControl/Control"
SVC="urn:schemas-upnp-org:service:RenderingControl:1"

soap() { # $1=action  $2=inner-args-xml
  curl -s -H 'Content-Type: text/xml; charset="utf-8"' \
       -H "SOAPACTION: \"$SVC#$1\"" \
       -d "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:$1 xmlns:u=\"$SVC\"><InstanceID>0</InstanceID>$2</u:$1></s:Body></s:Envelope>" \
       "$RC"
}

val() { grep -oE '<Current[A-Za-z]+>-?[0-9]+</Current[A-Za-z]+>' | grep -oE -- '-?[0-9]+' | head -1; }

echo "Reading EQ from $IP ..."
printf 'Bass      : %s\n' "$(soap GetBass   '' | val)"
printf 'Treble    : %s\n' "$(soap GetTreble '' | val)"
printf 'SubGain   : %s\n' "$(soap GetEQ '<EQType>SubGain</EQType>'            | val)"
printf 'Height    : %s\n' "$(soap GetEQ '<EQType>HeightChannelLevel</EQType>' | val)"
printf 'Surround  : %s\n' "$(soap GetEQ '<EQType>SurroundLevel</EQType>'      | val)"
printf 'NightMode : %s\n' "$(soap GetEQ '<EQType>NightMode</EQType>'          | val)"
printf 'Speech    : %s\n' "$(soap GetEQ '<EQType>SpeechEnhanceEnabled</EQType>' | val)"
echo "(Bass/Treble/Sub/Height range -10..10, Surround -15..15; 0 = flat = 50% on the tile)"
