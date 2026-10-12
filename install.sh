#!/usr/bin/env bash
#
# Install the Survive self-healing service.
#
# Usage: sudo ./install.sh [--no-hardware-watchdog] [--no-start]

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/bin/survive
CONF_DIR=/etc/survive
UNIT=/etc/systemd/system/survive.service
WATCHDOG_CONF=/etc/systemd/system.conf.d/survive-watchdog.conf

HW_WATCHDOG=true
START=true
for arg in "$@"; do
    case "$arg" in
        --no-hardware-watchdog) HW_WATCHDOG=false ;;
        --no-start) START=false ;;
        -h | --help)
            echo "Usage: sudo $0 [--no-hardware-watchdog] [--no-start]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo $0 $*" >&2
    exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd is required" >&2
    exit 1
fi

missing=()
command -v ip >/dev/null 2>&1 || missing+=(iproute2)
command -v ping >/dev/null 2>&1 || missing+=(iputils-ping)
command -v pgrep >/dev/null 2>&1 || missing+=(procps)
command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]] || missing+=(openssh-server)
if ((${#missing[@]})); then
    echo "Installing missing packages: ${missing[*]}"
    apt-get update -q || true
    apt-get install -y -q "${missing[@]}"
fi

echo "Installing $BIN"
install -m 0755 "$SRC/survive.sh" "$BIN"

mkdir -p "$CONF_DIR"
if [[ -e "$CONF_DIR/survive.conf" ]]; then
    echo "Keeping existing $CONF_DIR/survive.conf (new defaults: $CONF_DIR/survive.conf.dist)"
    install -m 0644 "$SRC/survive.conf" "$CONF_DIR/survive.conf.dist"
else
    install -m 0644 "$SRC/survive.conf" "$CONF_DIR/survive.conf"
fi

install -m 0644 "$SRC/survive.service" "$UNIT"

# SSH must always be available.
for ssh_unit in ssh.service sshd.service; do
    if systemctl cat "$ssh_unit" >/dev/null 2>&1; then
        echo "Enabling $ssh_unit"
        systemctl enable "$ssh_unit" >/dev/null 2>&1 || true
        [[ "$START" == true ]] && { systemctl start "$ssh_unit" || true; }
        break
    fi
done

# Hardware watchdog: reboots the Pi if the kernel or systemd itself hangs,
# a situation no user space service can recover from.
if [[ "$HW_WATCHDOG" == true ]]; then
    [[ -e /dev/watchdog ]] || modprobe bcm2835_wdt 2>/dev/null || true
    if [[ -e /dev/watchdog ]]; then
        echo "Enabling hardware watchdog ($WATCHDOG_CONF)"
        mkdir -p "$(dirname "$WATCHDOG_CONF")"
        cat >"$WATCHDOG_CONF" <<'CONF'
# Installed by survive: reboot automatically if the system hangs.
# The Raspberry Pi watchdog supports a maximum timeout of ~15 seconds.
[Manager]
RuntimeWatchdogSec=14
RebootWatchdogSec=2min
CONF
        systemctl daemon-reexec
    else
        echo "No hardware watchdog (/dev/watchdog) found; skipping"
    fi
fi

systemctl daemon-reload
systemctl enable survive.service >/dev/null
if [[ "$START" == true ]]; then
    systemctl restart survive.service
    echo
    "$BIN" check || true
fi

echo
echo "Survive installed."
echo "  Status:  survive status   |  systemctl status survive"
echo "  Logs:    journalctl -u survive -f"
echo "  Config:  $CONF_DIR/survive.conf"
