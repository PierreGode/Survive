#!/usr/bin/env bash
#
# Remove the Survive self-healing service.
#
# Usage: sudo ./uninstall.sh [--purge]   (--purge also removes config and state)

set -euo pipefail

PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo $0 $*" >&2
    exit 1
fi

systemctl disable --now survive-web.service 2>/dev/null || true
systemctl disable --now survive.service 2>/dev/null || true
rm -f /etc/systemd/system/survive.service /usr/local/bin/survive
rm -f /etc/systemd/system/survive-web.service /usr/local/bin/survive-web
rm -rf /usr/local/share/survive-web
if [[ -e /etc/systemd/system.conf.d/survive-watchdog.conf ]]; then
    rm -f /etc/systemd/system.conf.d/survive-watchdog.conf
    systemctl daemon-reexec
fi
systemctl daemon-reload
rm -rf /run/survive

if [[ "$PURGE" == true ]]; then
    rm -rf /etc/survive /var/lib/survive
fi

echo "Survive removed."
