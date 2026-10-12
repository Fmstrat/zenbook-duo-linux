#!/bin/bash

# Default backlight (0-3)
DEFAULT_BACKLIGHT=1

# Default scale (1-2)
DEFAULT_SCALE=1

# Capture Ctrl+C and close any subprocesses such as duo-watch-monitor
trap 'echo "Ctrl+C captured. Exiting..."; pkill -P $$; exit 1' INT

mkdir -p /tmp/duo

# xrandr (used under the MATE/X11 backend below) needs DISPLAY set, and
# systemd --user sessions don't always import it reliably; fall back to the
# standard first-display value rather than failing every xrandr call.
[ -z "${DISPLAY}" ] && export DISPLAY=:0

# SCALE=$(gdctl show |grep Scale: |sed 's/│//g' |awk '{print $2}' |head -n1)
# if [ -z "${SCALE}" ]; then
#     SCALE=1
# fi
SCALE=${DEFAULT_SCALE}

# --- Display backend (GNOME/gdctl vs MATE-or-other-X11/xrandr) -------------
# Populated by duo-detect-display-backend, called once below. Every other
# function in this file that needs to drive the displays must go through
# duo-monitor-count / duo-set-monitors-single / duo-set-monitors-dual rather
# than calling gdctl or xrandr directly, so the same script works unchanged
# whichever desktop environment is active when it runs.
DISPLAY_BACKEND=
PRIMARY_OUTPUT=
SECONDARY_OUTPUT=

# Finds the two eDP (built-in panel) outputs xrandr knows about and assigns
# them to PRIMARY_OUTPUT/SECONDARY_OUTPUT. Discovered dynamically (not
# hardcoded as eDP-1/eDP-2) because X11/RandR connector naming is driver
# dependent and isn't guaranteed to match Mutter/DRM's naming. Both panels
# report as "connected" in xrandr's output even when powered off, so this
# works regardless of which panel(s) are currently active.
function duo-xrandr-detect-outputs() {
    # -P prints "eDP-1 connected ..." lines; keep just the output name, only
    # for eDP* connectors, sorted so the results are stable across runs.
    mapfile -t _EDP_OUTPUTS < <(xrandr --query | grep -oP '^\S+(?= connected)' | grep '^eDP' | sort)
    PRIMARY_OUTPUT="${_EDP_OUTPUTS[0]}"
    SECONDARY_OUTPUT="${_EDP_OUTPUTS[1]}"
}

# Chooses the display backend for this run by probing capability rather than
# trusting $XDG_CURRENT_DESKTOP (systemd --user environment import for that
# var has been unreliable, which is why it used to be hardcoded to GNOME in
# the installed unit file — that hardcoding is what broke switching desktop
# environments). `gdctl show` fails fast (~0.2s) with a clean non-zero exit
# when no GNOME/Mutter session is registered on the bus, so it's safe to
# probe on every invocation instead of caching a decision at install time.
function duo-detect-display-backend() {
    if command -v gdctl >/dev/null 2>&1 && gdctl show >/dev/null 2>&1; then
        DISPLAY_BACKEND=gdctl
        PRIMARY_OUTPUT=eDP-1
        SECONDARY_OUTPUT=eDP-2
    else
        DISPLAY_BACKEND=xrandr
        duo-xrandr-detect-outputs
    fi
    echo "$(date) - BACKEND - Selected: ${DISPLAY_BACKEND} (primary=${PRIMARY_OUTPUT} secondary=${SECONDARY_OUTPUT})"
}

# Power-event invocations (system-sleep hook and the boot/shutdown unit) run
# as root outside the user session and must never touch the display server.
# During suspend/resume, systemd-sleep runs hooks while user.slice is frozen,
# so Xwayland's :0 socket still exists but its owner (gnome-shell) can't
# answer: xrandr blocks until systemd kills the hook at its 90s timeout,
# adding 90s to both lid close and lid open. Display reconciliation after
# resume is left to the user service (duo-watch-resume).
POWER_EVENT=false
case "${1}" in
pre|post|hibernate|thaw|boot|shutdown) POWER_EVENT=true ;;
esac

# Only probe gdctl/xrandr when running inside the user session.
if [ "${POWER_EVENT}" = false ]; then
    duo-detect-display-backend
fi

# Translates the canonical rotation words this script uses everywhere
# (normal/left/inverted/right, xrandr's own vocabulary) into the --transform
# degree flag gdctl expects. "normal" has no gdctl flag at all.
function duo-gdctl-transform-flag() {
    case "${1}" in
    left) echo "--transform 90" ;;
    inverted) echo "--transform 180" ;;
    right) echo "--transform 270" ;;
    *) echo "" ;;
    esac
}

# Returns the number of currently active/enabled logical monitors, via
# whichever backend was selected.
function duo-monitor-count() {
    if [ "${DISPLAY_BACKEND}" = gdctl ]; then
        gdctl show | grep 'Logical monitor #' | wc -l
    else
        xrandr --listactivemonitors | awk '/^Monitors:/ {print $2}'
    fi
}

# Enables only the primary panel (turning the secondary off if it was on)
# at the given rotation. $1 = normal|left|inverted|right.
function duo-set-monitors-single() {
    if [ "${DISPLAY_BACKEND}" = gdctl ]; then
        local T
        T=$(duo-gdctl-transform-flag "${1}")
        gdctl set --logical-monitor --primary --scale ${SCALE} --monitor ${PRIMARY_OUTPUT} ${T}
    else
        # --scale is intentionally not applied here: xrandr's scale is a
        # framebuffer resample (blurry text), not Mutter's logical-monitor
        # scale, and isn't the right tool for MATE's HiDPI story either
        # (MATE has its own window-scaling-factor setting for that).
        xrandr --output "${SECONDARY_OUTPUT}" --off \
               --output "${PRIMARY_OUTPUT}" --auto --primary --rotate "${1}" --pos 0x0
    fi
}

# Enables both panels, with the secondary positioned relative to the primary.
# $1 = below|above|left-of|right-of, $2 = normal|left|inverted|right.
function duo-set-monitors-dual() {
    if [ "${DISPLAY_BACKEND}" = gdctl ]; then
        local T
        T=$(duo-gdctl-transform-flag "${2}")
        gdctl set --logical-monitor --primary --scale ${SCALE} --monitor ${PRIMARY_OUTPUT} ${T} \
                  --logical-monitor --scale ${SCALE} --monitor ${SECONDARY_OUTPUT} --${1} ${PRIMARY_OUTPUT} ${T}
    else
        # --auto is required on both outputs: merely specifying --below/etc.
        # on a currently-off output does not implicitly assign it a mode.
        xrandr --output "${PRIMARY_OUTPUT}" --auto --primary --rotate "${2}" --pos 0x0 \
               --output "${SECONDARY_OUTPUT}" --auto --rotate "${2}" --${1} "${PRIMARY_OUTPUT}"
    fi
}
# ---------------------------------------------------------------------------

# Python embed
PYTHON3=$(which python3)
KEYBOARD_DEV=$(lsusb | grep 'Zenbook Duo Keyboard' |awk '{print $6}')
if [ -n "${KEYBOARD_DEV}" ] && [ ! -f /tmp/duo/backlight.py ]; then
    VENDOR_ID=${KEYBOARD_DEV%:*}
    PRODUCT_ID=${KEYBOARD_DEV#*:}
    echo "#!/usr/bin/env python3

# BSD 2-Clause License
#
# Copyright (c) 2024, Alesya Huzik
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.

# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import sys
import usb.core
import usb.util

# USB Parameters
VENDOR_ID = 0x${VENDOR_ID}
PRODUCT_ID = 0x${PRODUCT_ID}
REPORT_ID = 0x5A
WVALUE = 0x035A
WINDEX = 4
WLENGTH = 16

if len(sys.argv) != 2:
    print(f\"Usage: {sys.argv[0]} <level>\")
    sys.exit(1)

try:
    level = int(sys.argv[1])
    if level < 0 or level > 3:
        raise ValueError
except ValueError:
    print(\"Invalid level. Must be an integer between 0 and 3.\")
    sys.exit(1)

# Prepare the data packet
data = [0] * WLENGTH
data[0] = REPORT_ID
data[1] = 0xBA
data[2] = 0xC5
data[3] = 0xC4
data[4] = level

# Find the device
dev = usb.core.find(idVendor=VENDOR_ID, idProduct=PRODUCT_ID)

if dev is None:
    print(f\"Device not found (Vendor ID: 0x{VENDOR_ID:04X}, Product ID: 0x{PRODUCT_ID:04X})\")
    sys.exit(1)

# Detach kernel driver if necessary
if dev.is_kernel_driver_active(WINDEX):
    try:
        dev.detach_kernel_driver(WINDEX)
    except usb.core.USBError as e:
        print(f\"Could not detach kernel driver: {str(e)}\")
        sys.exit(1)

# try:
#     dev.set_configuration()
#     usb.util.claim_interface(dev, WINDEX)
# except usb.core.USBError as e:
#     print(f\"Could not set configuration or claim interface: {str(e)}\")
#     sys.exit(1)

# Send the control transfer
try:
    bmRequestType = 0x21  # Host to Device | Class | Interface
    bRequest = 0x09       # SET_REPORT
    wValue = WVALUE       # 0x035A
    wIndex = WINDEX       # Interface number
    ret = dev.ctrl_transfer(bmRequestType, bRequest, wValue, wIndex, data, timeout=1000)
    if ret != WLENGTH:
        print(f\"Warning: Only {ret} bytes sent out of {WLENGTH}.\")
    else:
        print(\"Data packet sent successfully.\")
except usb.core.USBError as e:
    print(f\"Control transfer failed: {str(e)}\")
    usb.util.release_interface(dev, WINDEX)
    sys.exit(1)

# Release the interface
usb.util.release_interface(dev, WINDEX)
# Reattach the kernel driver if necessary
try:
    dev.attach_kernel_driver(WINDEX)
except usb.core.USBError:
    pass  # Ignore if we can't reattach the driver

sys.exit(0)
" > /tmp/duo/backlight.py
fi

if [ -f /tmp/duo/status ]; then
    . /tmp/duo/status
fi
if [ -z "${WIFI_BEFORE}" ]; then
    WIFI_BEFORE=$(nmcli radio wifi)
fi
if [ -z "${BLUETOOTH_BEFORE}" ]; then
    BLUETOOTH_BEFORE=$(rfkill -n -o SOFT list bluetooth |head -n1)
fi
KEYBOARD_ATTACHED=false
if [ -n "$(lsusb | grep 'Zenbook Duo Keyboard')" ]; then
    KEYBOARD_ATTACHED=true
fi
# Power events keep the MONITOR_COUNT sourced from /tmp/duo/status above,
# since counting monitors would query the (possibly frozen) display server.
if [ "${POWER_EVENT}" = false ]; then
    MONITOR_COUNT=$(duo-monitor-count)
fi
function duo-set-status() {
    echo "
        BLUETOOTH_BEFORE=${BLUETOOTH_BEFORE}
        WIFI_BEFORE=${WIFI_BEFORE}
        KEYBOARD_ATTACHED=${KEYBOARD_ATTACHED}
        MONITOR_COUNT=${MONITOR_COUNT}
    " > /tmp/duo/status
}
duo-set-status

# Returns success when this instance belongs to GDM's login screen. The user
# service is enabled globally on purpose so panel toggling and rotation also
# work at the login screen, but the greeter's dynamic user (gdm-greeter,
# uid 605xx) has no sudoers entry and no notification daemon, so those calls
# can only fail there. Detected by logind session class rather than username
# because GDM allocates several greeter users. Cached in IS_GREETER; main()
# computes it before forking the watchers so they inherit the result.
function duo-is-greeter() {
    if [ -z "${IS_GREETER}" ]; then
        IS_GREETER=false
        local S
        # Root (system-sleep hook, boot unit) has no logind user and falls
        # through as non-greeter; errors are discarded for that case.
        for S in $(loginctl show-user "$(id -u)" -p Sessions --value 2>/dev/null); do
            if [ "$(loginctl show-session "${S}" -p Class --value 2>/dev/null)" = greeter ]; then
                IS_GREETER=true
            fi
        done
    fi
    [ "${IS_GREETER}" = true ]
}

# Sets the keyboard backlight level (0-3). Skipped at the login screen, where
# the sudoers rule installed by setup.sh doesn't apply.
function duo-set-kb-backlight() {
    if duo-is-greeter; then
        return 0
    fi
    /usr/bin/sudo ${PYTHON3} /tmp/duo/backlight.py ${1} >/dev/null
}

# Shows a short desktop notification. Skipped at the login screen, which has
# no notification daemon for notify-send to connect to.
function duo-notify() {
    if duo-is-greeter; then
        return 0
    fi
    notify-send -a "Zenbook Duo" -t 1000 --hint=int:transient:1 -i "preferences-desktop-display" "${1}"
}

# Turns the WiFi radio on if NetworkManager's polkit policy allows it for this
# session right now. That can change while running: the login-screen instance
# is allowed while the greeter is the active session, but is refused once the
# user's session takes over and before GDM stops the greeter.
function duo-wifi-on() {
    if nmcli -t -f PERMISSION,VALUE general permissions 2>/dev/null |
            grep -qx 'org.freedesktop.NetworkManager.enable-disable-wifi:yes'; then
        echo "$(date) - MONITOR - Turning on WIFI"
        nmcli radio wifi on
    fi
}

BRIGHTNESS=0
# Mirrors the top panel's brightness onto the bottom panel while the keyboard
# is detached. Skipped at the login screen: the sudo tee rule from setup.sh
# only covers the installing user.
function duo-sync-display-backlight() {
    if duo-is-greeter; then
        return 0
    fi
    . /tmp/duo/status
    if [ "${KEYBOARD_ATTACHED}" = false ]; then
        CUR_BRIGHTNESS=$(cat /sys/class/backlight/intel_backlight/brightness)
        if [ "${CUR_BRIGHTNESS}" != "${BRIGHTNESS}" ]; then
            BRIGHTNESS=${CUR_BRIGHTNESS}
            echo "$(date) - DISPLAY - Setting brightness to $(echo ${BRIGHTNESS} |sudo tee /sys/class/backlight/card1-eDP-2-backlight/brightness)"
        fi
    fi
}

function duo-watch-display-backlight() {
    while true; do
        inotifywait -e modify /sys/class/backlight/intel_backlight/brightness >/dev/null 2>&1
        duo-sync-display-backlight
    done
}

function duo-watch-wifi() {
    while read -r LINE; do
        sleep 1
        . /tmp/duo/status
        if [ "${KEYBOARD_ATTACHED}" = true ]; then
            if [[ "${LINE}" = *"<true>"* ]]; then
                WIFI_BEFORE=enabled
            else
                WIFI_BEFORE=disabled
            fi
            echo "$(date) - NETWORK - WIFI: ${WIFI_BEFORE}"
            duo-set-status
        fi
    done < <(gdbus monitor -y -d org.freedesktop.NetworkManager | grep --line-buffered WirelessEnabled)
}

function duo-watch-bluetooth() {
    while read -r LINE; do
        sleep 1
        . /tmp/duo/status
        if [ "${KEYBOARD_ATTACHED}" = true ]; then
            if [[ "${LINE}" = *"<true>"* ]]; then
                BLUETOOTH_BEFORE=unblocked
            else
                BLUETOOTH_BEFORE=blocked
            fi
            echo "$(date) - NETWORK - Bluetooth: ${BLUETOOTH_BEFORE}"
            duo-set-status
        fi
    done < <(gdbus monitor -y -d org.bluez | grep --line-buffered "'Powered':")
}

function duo-watch-lock() {
    while read -r LINE; do
        sleep 1
        if [[ "${LINE}" = *"<false>"* ]]; then
            echo "$(date) - SESSION - Unlocked, rechecking monitor state"
            duo-check-monitor
        fi
    done < <(gdbus monitor -y -d org.freedesktop.login1 | grep --line-buffered "LockedHint")
}

# Re-checks monitor state after every resume, from inside the user session.
# This replaces the display handling the root system-sleep hook used to do
# (it can't reach the display server, see POWER_EVENT), and works on any
# desktop: logind emits PrepareForSleep(false) after resume regardless of DE,
# whereas duo-watch-lock depends on the locker setting LockedHint, which
# mate-screensaver doesn't do. The signal arrives after user.slice is thawed,
# so gdctl/xrandr are responsive by the time duo-check-monitor runs.
function duo-watch-resume() {
    while read -r LINE; do
        # PrepareForSleep(true) fires before suspend; only act on resume.
        if [[ "${LINE}" = *"false"* ]]; then
            # Give the compositor/X server a moment to bring the panels back.
            sleep 2
            echo "$(date) - SESSION - Resumed, rechecking monitor state"
            duo-check-monitor
        fi
    done < <(gdbus monitor -y -d org.freedesktop.login1 | grep --line-buffered "PrepareForSleep")
}

# Re-evaluates keyboard/monitor state and reconciles WiFi, Bluetooth, and
# the bottom panel to match: keyboard attached -> single panel, bottom off;
# keyboard detached -> dual panel, bottom on below the primary. Called from
# the user service only: at session start, after resume (duo-watch-resume),
# on USB attach/detach events, and on session unlock. Drives the
# displays only through duo-set-monitors-single/-dual so it behaves the same
# under whichever display backend duo-detect-display-backend selected.
function duo-check-monitor() {
    . /tmp/duo/status
    KEYBOARD_ATTACHED=false
    if [ -n "$(lsusb | grep 'Zenbook Duo Keyboard')" ]; then
        KEYBOARD_ATTACHED=true
    fi
    MONITOR_COUNT=$(duo-monitor-count)
    duo-set-status
    echo "$(date) - MONITOR - WIFI before: ${WIFI_BEFORE}, Bluetooth before: ${BLUETOOTH_BEFORE}"
    echo "$(date) - MONITOR - Keyboard attached: ${KEYBOARD_ATTACHED}, Monitor count: ${MONITOR_COUNT}"
    if [ ${KEYBOARD_ATTACHED} = true ]; then
        echo "$(date) - MONITOR - Keyboard attached"
        duo-set-kb-backlight ${DEFAULT_BACKLIGHT}
        if [ "${WIFI_BEFORE}" = enabled ]; then
            duo-wifi-on
        fi
        if [ "${BLUETOOTH_BEFORE}" = unblocked ]; then
            echo "$(date) - MONITOR - Turning on Bluetooth"
            rfkill unblock bluetooth
        else
            echo "$(date) - MONITOR - Turning off Bluetooth"
            rfkill block bluetooth
        fi
        if (( MONITOR_COUNT > 1 )) || (( MONITOR_COUNT == 0 )); then
            echo "$(date) - MONITOR - Disabling bottom monitor"
            duo-set-monitors-single normal
            NEW_MONITOR_COUNT=$(duo-monitor-count)
            if ((${NEW_MONITOR_COUNT} == 1)); then
                MESSAGE="Disabled bottom display"
            else
                MESSAGE="ERROR: Bottom display still on"
            fi
            duo-notify "${MESSAGE}"
        fi
    else
        echo "$(date) - MONITOR - Keyboard detached"
        if [ "${WIFI_BEFORE}" = enabled ]; then
            duo-wifi-on
        fi
        echo "$(date) - MONITOR - Turning on Bluetooth"
        rfkill unblock bluetooth
        if (( MONITOR_COUNT < 2 )); then
            echo "$(date) - MONITOR - Enabling bottom monitor"
            duo-set-monitors-dual below normal
            NEW_MONITOR_COUNT=$(duo-monitor-count)
            if (( NEW_MONITOR_COUNT == 2 )); then
                MESSAGE="Enabled bottom display"
            else
                MESSAGE="ERROR: Bottom display still off"
            fi
            duo-notify "${MESSAGE}"
        fi
    fi
}

function duo-watch-monitor() {
    while true; do
        echo "$(date) - MONITOR - Waiting for USB event"
        inotifywait -e attrib /dev/bus/usb/*/ >/dev/null 2>&1
        duo-check-monitor
    done
}

# Dispatches the single-argument CLI subcommands: power-event hooks
# (pre/post/hibernate/thaw/shutdown/boot, invoked by the system-sleep hook
# and the boot/shutdown systemd unit), keyboard-backlight level (kbb), and
# the four accelerometer-driven rotation states. The rotate cases pick
# single- vs dual-panel handling based on whether the keyboard is attached,
# then delegate to duo-set-monitors-single/-dual for the actual backend call.
function duo-cli() {
    . /tmp/duo/status
    case "${1}" in
    pre|hibernate|shutdown)
        echo "$(date) - ACPI - $@"
        duo-set-kb-backlight 0
    ;;
    post|thaw|boot)
        echo "$(date) - ACPI - $@"
        duo-set-kb-backlight ${DEFAULT_BACKLIGHT}
        # No duo-check-monitor here: as root with the session frozen (resume)
        # or not yet started (boot) it can't drive the displays and would hang
        # on xrandr. The user service re-checks via duo-watch-resume instead.
    ;;
    kbb)
        echo "$(date) - KEYBOARD - Backlight = ${2}"
        duo-set-kb-backlight ${2}
    ;;
    left-up)
        echo "$(date) - ROTATE - Left-up"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            duo-set-monitors-single left
        else
            duo-set-monitors-dual left-of left
        fi
        ;;
    right-up)
        echo "$(date) - ROTATE - Right-up"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            duo-set-monitors-single right
        else
            duo-set-monitors-dual right-of right
        fi
        ;;
    bottom-up)
        echo "$(date) - ROTATE - Bottom-up"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            duo-set-monitors-single inverted
        else
            duo-set-monitors-dual above inverted
        fi
        ;;
    normal)
        echo "$(date) - ROTATE - Normal"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            duo-set-monitors-single normal
        else
            duo-set-monitors-dual below normal
        fi
        ;;
    *)
        echo "$(date) - UNKNOWN - $@"
        ;;
    esac
}

# Watches iio-sensor-proxy for accelerometer orientation changes and drives
# duo-cli's rotate cases accordingly. Wrapped in a restart loop (matching
# duo-watch-monitor/duo-watch-display-backlight below) because
# `monitor-sensor` can fail to claim the accelerometer (e.g. a startup race
# with iio-sensor-proxy still initializing) and exits when that happens —
# without a retry, that one failure would silently kill auto-rotation for
# the rest of the session.
function duo-watch-rotate() {
    echo "$(date) - ROTATE - Watching"
    while true; do
        monitor-sensor --accel |
            grep --line-buffered -oP "Accelerometer orientation changed: \K\S+" |
            xargs -I '{}' "$0" '{}' >/dev/null 2>&1
        echo "$(date) - ROTATE - monitor-sensor exited, restarting in 5s"
        sleep 5
    done
}

function main() {
    # Resolve once here so the backgrounded watchers inherit the cached value.
    if duo-is-greeter; then
        echo "$(date) - SESSION - Login screen instance: keyboard backlight, bottom-panel brightness sync and notifications are skipped"
    fi
    duo-set-kb-backlight ${DEFAULT_BACKLIGHT}
    duo-check-monitor
    duo-watch-monitor &
    duo-watch-rotate &
    duo-watch-display-backlight &
    duo-watch-wifi &
    duo-watch-lock &
    duo-watch-resume &
    duo-watch-bluetooth
}

if [ -z "${1}" ]; then
    main | tee -a /tmp/duo/duo.log
else
    duo-cli $@ | tee -a /tmp/duo/duo.log
    if [ "${USER}" = root ]; then
        chmod a+w /tmp/duo /tmp/duo/duo.log /tmp/duo/status
    fi
fi
