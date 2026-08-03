#!/usr/bin/env bash
#
# Deploy the driver to the hub and *prove* the hub is running the new build.
#
# `edge:drivers:package` only uploads a version - it does not publish it to the
# channel. Without `edge:channels:assign` in between, `edge:drivers:install`
# happily reports success while re-installing the previous build, so the hub
# keeps running old code and nothing appears to change. This script does all
# three steps and then polls the hub until it confirms the new version, so a
# failed deploy is loud instead of silent.
#
# Usage: scripts/deploy.sh
set -euo pipefail

DRIVER_ID="fb29e78d-9ae0-44cd-92c3-5e03b7f39403"
CHANNEL_ID="6dcc1ac3-24c5-4294-856c-304f5ca7a1ab"
HUB_ID="4204ac73-fdd4-4e85-824a-ffa2435c4dee"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Never ship a build that doesn't parse or fails its regression tests. Set
# SKIP_TESTS=1 only to deploy deliberately-broken code while debugging.
if [ "${SKIP_TESTS:-0}" = "1" ]; then
    echo "!!  SKIP_TESTS=1 - deploying WITHOUT syntax check or tests"
else
    "$REPO_ROOT/scripts/test.sh"
fi

echo "==> Packaging"
VERSION=$(smartthings edge:drivers:package . --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
echo "    version: $VERSION"

echo "==> Assigning to channel"
smartthings edge:channels:assign "$DRIVER_ID" "$VERSION" -C "$CHANNEL_ID" >/dev/null

echo "==> Installing to hub"
smartthings edge:drivers:install "$DRIVER_ID" -H "$HUB_ID" -C "$CHANNEL_ID" >/dev/null

echo "==> Waiting for the hub to report the new version"
for _ in $(seq 1 40); do
    ON_HUB=$(smartthings devices "$HUB_ID" --json 2>/dev/null | python3 -c '
import json, sys
hub = json.load(sys.stdin).get("hub", {})
v = [d["driverVersion"] for d in hub.get("hubDrivers", []) if d["driverId"].startswith("'"${DRIVER_ID%%-*}"'")]
print(v[0] if v else "")
' || true)
    if [ "$ON_HUB" = "$VERSION" ]; then
        echo "    hub is running $VERSION"
        echo
        echo "Deployed. Watch it run with:"
        echo "  smartthings edge:drivers:logcat $DRIVER_ID --hub-address <hub-ip>"
        echo "(the driver logs under the name \"Sonos Extra Control\")"
        exit 0
    fi
    sleep 15
done

echo "!!  Hub still reports '$ON_HUB', expected '$VERSION'" >&2
echo "!!  The deploy did NOT land - do not trust any behaviour you observe." >&2
exit 1
