#!/bin/bash

INSTALL_LOCATION=/usr/local/bin/duo

DEV_MODE=false
DEV_INSTALL_LOCATION=/data/repos/nowsci/zenbook-duo-linux/duo.sh

DEFAULT_BACKLIGHT=1
DEFAULT_SCALE=1

if [ "${1}" = "--dev-mode" ]; then
    DEV_MODE=true
    INSTALL_LOCATION=${DEV_INSTALL_LOCATION}
fi

if [ "${DEV_MODE}" = false ]; then
    read -p "What would you like to use for the default keyboard backlight brightness [0-3]? " DEFAULT_BRIGHTNESS
    read -p "What would you like to use for monitor scale (1 = 100%, 1.5 = 150%, 2=200%) [1-2]? " DEFAULT_SCALE
    sudo apt install -y \
        inotify-tools \
        usbutils \
        mutter-common-bin \
        iio-sensor-proxy \
        python3-usb \
        dconf-cli
    sudo mkdir -p /usr/local/bin
    sudo cp ./duo.sh ${INSTALL_LOCATION}
    sudo chmod a+x ${INSTALL_LOCATION}
    sudo sed -i "s/DEFAULT_BACKLIGHT=1/DEFAULT_BACKLIGHT=${DEFAULT_BACKLIGHT}/g" ${INSTALL_LOCATION}
    sudo sed -i "s/DEFAULT_SCALE=1/DEFAULT_SCALE=${DEFAULT_SCALE}/g" ${INSTALL_LOCATION}
fi

function addSudoers() {
    RESULT=$(sudo grep "${1}" /etc/sudoers)
    if [ -z "${RESULT}" ]; then
        echo "${1}" | sudo tee -a /etc/sudoers
    fi
}

PYTHON3=$(which python3)
if [ -n "${PYTHON3}" ] && [ -n "${USER}" ]; then
    addSudoers "${USER} ALL=NOPASSWD:${PYTHON3} /tmp/duo/backlight.py *"
    addSudoers "${USER} ALL=NOPASSWD:/usr/bin/tee /sys/class/backlight/card1-eDP-2-backlight/brightness"
fi

sudo rm -f /lib/systemd/system-sleep/duo
sudo ln -s ${INSTALL_LOCATION} /lib/systemd/system-sleep/duo

echo "[Unit]
Description=Zenbook Duo Power Events Handler (boot & shutdown)
DefaultDependencies=no
Before=shutdown.target
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${INSTALL_LOCATION} boot
ExecStop=${INSTALL_LOCATION} shutdown
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
" | sudo tee /etc/systemd/system/zenbook-duo.service

echo "[Unit]
Description=Zenbook Duo User Handler
After=graphical-session.target

[Service]
ExecStartPre=/bin/sleep 3
ExecStart=${INSTALL_LOCATION}
Restart=no

[Install]
WantedBy=default.target
" | sudo tee /etc/systemd/user/zenbook-duo-user.service

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable zenbook-duo.service
systemctl --user daemon-reexec
systemctl --user daemon-reload
sudo systemctl --global enable zenbook-duo-user.service

# Returns 0 only when the *current session* is GNOME.
# Checks session env vars first; falls back to a running gnome-shell process.
# Avoids false positives from 'command -v gnome-shell', which only tests whether
# GNOME is installed, not whether it is the active desktop session.
gnome_session_active() {
    # XDG_CURRENT_DESKTOP can be a colon-separated list (e.g. "ubuntu:GNOME")
    case ":${XDG_CURRENT_DESKTOP}:" in *:GNOME:*) return 0 ;; esac
    # XDG_SESSION_DESKTOP is set by the session manager to the session name
    case "${XDG_SESSION_DESKTOP}" in gnome|GNOME|gnome-xorg|gnome-wayland) return 0 ;; esac
    # Legacy / distro-specific fallback
    case "${DESKTOP_SESSION}" in gnome|GNOME|gnome-xorg|gnome-wayland) return 0 ;; esac
    # Last resort: a running gnome-shell process means GNOME is the active session
    pgrep -x gnome-shell &>/dev/null
}

if gnome_session_active; then
    echo "GNOME detected. Configuring touchscreen gesture mapping..."
    if ! command -v dconf &>/dev/null; then
        echo "Error: dconf is not available. Install dconf-cli and re-run setup.sh to apply gesture mapping." >&2
    fi
    if command -v dconf &>/dev/null; then
        if dconf write "/org/gnome/desktop/peripherals/touchscreens/04f3:4447/output" "['SDC', '0x419d', '0x00000000', 'eDP-1']" \
            && dconf write "/org/gnome/desktop/peripherals/touchscreens/04f3:4448/output" "['SDC', '0x419d', '0x00000000', 'eDP-2']" \
            && dconf write "/org/gnome/desktop/peripherals/tablets/04f3:4447/output" "['SDC', '0x419d', '0x00000000', 'eDP-1']" \
            && dconf write "/org/gnome/desktop/peripherals/tablets/04f3:4448/output" "['SDC', '0x419d', '0x00000000', 'eDP-2']"; then
            echo "Gesture and pen mapping configured: digitizer on main screen -> eDP-1, digitizer on second screen -> eDP-2."
        else
            echo "Error: failed to write one or more GNOME dconf mappings." >&2
            echo "Run setup.sh again in an active GNOME session, or apply keys manually with dconf write." >&2
        fi
    fi
else
    echo "Non-GNOME desktop detected. Skipping gesture mapping configuration."
fi

echo "Install complete."