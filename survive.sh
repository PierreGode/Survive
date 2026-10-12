#!/usr/bin/env bash
#
# Survive - self-healing health & network watchdog for the Raspberry Pi.
#
# Keeps the Raspberry Pi reachable over SSH:
#   * continuously checks network connectivity, the SSH daemon and the root
#     filesystem,
#   * gives the system a grace period (default 5 minutes) to recover on its own,
#   * then escalates through increasingly invasive repairs (DHCP renew, Wi-Fi
#     reconnect, network service restart, interface bounce, Wi-Fi driver reload,
#     SSH repair),
#   * and reboots when the system has been unreachable for too long (default
#     10 minutes), with reboot-loop protection and a forced-reboot fallback.
#
# It also performs routine health maintenance (disk space cleanup, memory,
# temperature and under-voltage reporting, restarting failed services).
#
# Usage: survive [run|check|status|version|help]

set -u

SURVIVE_VERSION="1.0.0"
SURVIVE_CONFIG="${SURVIVE_CONFIG:-/etc/survive/survive.conf}"

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

load_defaults() {
    CHECK_INTERVAL=30              # seconds between checks
    GRACE_PERIOD=300               # let the system recover by itself first
    ACTION_INTERVAL=60             # min seconds between two repair actions
    REBOOT_AFTER=600               # reboot when unreachable for this long
    ENABLE_REBOOT=true
    DRY_RUN=false                  # log actions instead of executing them

    INTERFACES=""                  # empty = auto-detect physical interfaces
    PING_TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
    CHECK_GATEWAY=true
    REQUIRE_INTERNET=false         # true = LAN-only connectivity is a fault
    RELOAD_WIFI_DRIVER=true

    CHECK_SSH=true
    SSH_PORT=22
    CHECK_ROOT_RW=true

    REBOOT_BACKOFF_THRESHOLD=3     # consecutive reboots before backing off
    MAX_REBOOT_DELAY=3600          # upper bound for the backed-off delay
    HEALTHY_RESET_TIME=1800        # healthy time that resets the reboot count
    PACKAGE_MANAGER_WAIT=1800      # max time to postpone reboot for apt/dpkg
    REBOOT_FORCE_TIMEOUT=300       # force reboot if graceful one hangs

    MAINTENANCE_INTERVAL=300
    DISK_USAGE_THRESHOLD=90        # percent
    MEMORY_MIN_AVAILABLE_PCT=5     # percent
    TEMP_WARN=80                   # degrees Celsius
    WATCH_SERVICES=""              # extra services to keep running

    STATE_DIR=/var/lib/survive     # persistent across reboots
    RUN_DIR=/run/survive           # per boot, survives daemon restarts
    EVENT_LOG_MAX_LINES=2000
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

load_config() {
    load_defaults
    if [[ -r "$SURVIVE_CONFIG" ]]; then
        # shellcheck source=/dev/null
        . "$SURVIVE_CONFIG"
    fi
    local var
    for var in CHECK_INTERVAL GRACE_PERIOD ACTION_INTERVAL REBOOT_AFTER SSH_PORT \
        REBOOT_BACKOFF_THRESHOLD MAX_REBOOT_DELAY HEALTHY_RESET_TIME \
        PACKAGE_MANAGER_WAIT REBOOT_FORCE_TIMEOUT MAINTENANCE_INTERVAL \
        DISK_USAGE_THRESHOLD MEMORY_MIN_AVAILABLE_PCT TEMP_WARN EVENT_LOG_MAX_LINES; do
        if ! is_uint "${!var}"; then
            log warn "Invalid value '${!var}' for $var, using default"
            local default
            default=$(load_defaults; echo "${!var}")
            printf -v "$var" '%s' "$default"
        fi
    done
    ((CHECK_INTERVAL < 5)) && CHECK_INTERVAL=5
    ((ACTION_INTERVAL < CHECK_INTERVAL)) && ACTION_INTERVAL=$CHECK_INTERVAL
    if ((REBOOT_AFTER <= GRACE_PERIOD)); then
        log warn "REBOOT_AFTER ($REBOOT_AFTER) must be greater than GRACE_PERIOD ($GRACE_PERIOD); adjusting"
        REBOOT_AFTER=$((GRACE_PERIOD + 2 * ACTION_INTERVAL))
    fi
    ((MAX_REBOOT_DELAY < REBOOT_AFTER)) && MAX_REBOOT_DELAY=$REBOOT_AFTER
    return 0
}

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------

log() {
    local level="$1"; shift
    local prio
    case "$level" in
        error) prio=3 ;;
        warn) prio=4 ;;
        notice) prio=5 ;;
        debug) prio=7 ;;
        *) prio=6 ;;
    esac
    if [[ -n "${JOURNAL_STREAM:-}" ]]; then
        printf '<%d>%s\n' "$prio" "$*" >&2
    else
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
    fi
}

# Persistent incident log, kept on disk so the reason for a reboot can be
# inspected afterwards even when the journal is volatile.
event() {
    local level="$1"; shift
    log "$level" "$*"
    local file="$STATE_DIR/events.log"
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$file" 2>/dev/null || return 0
    local lines
    lines=$(wc -l <"$file" 2>/dev/null || echo 0)
    if ((lines > EVENT_LOG_MAX_LINES)); then
        tail -n "$((EVENT_LOG_MAX_LINES / 2))" "$file" >"$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file"
    fi
}

# Execute (or only log, in dry-run mode) a repair command.
run_action() {
    if [[ "$DRY_RUN" == true ]]; then
        log notice "[dry-run] $*"
        return 0
    fi
    log debug "exec: $*"
    timeout 120 "$@" >/dev/null 2>&1
}

have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# Time & systemd watchdog
# --------------------------------------------------------------------------

# Monotonic clock (seconds since boot). Wall-clock time on a Raspberry Pi
# without RTC jumps when NTP syncs, so it must not be used to measure outages.
now() {
    local up
    read -r up _ </proc/uptime
    echo "${up%%.*}"
}

notify_watchdog() {
    if [[ -n "${NOTIFY_SOCKET:-}" ]] && have systemd-notify; then
        systemd-notify --pid=$$ "WATCHDOG=1" >/dev/null 2>&1 || true
    fi
}

# Sleep while keeping the systemd watchdog fed; interruptible by signals.
nap() {
    local remaining=$1 chunk
    while ((remaining > 0)); do
        notify_watchdog
        chunk=$((remaining > 30 ? 30 : remaining))
        sleep "$chunk" &
        wait $! 2>/dev/null
        [[ "$RUNNING" == true ]] || break
        remaining=$((remaining - chunk))
    done
    notify_watchdog
}

# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------

FAIL_SINCE=0         # uptime when the current outage started (0 = healthy)
LAST_ACTION_AT=0     # uptime of the last repair action
ACTION_STEP=0        # number of repair rounds in the current outage
HEALTHY_SINCE=0      # uptime since which the system is healthy
PKG_WAIT_SINCE=0     # uptime since which a reboot is postponed for apt/dpkg
REBOOT_WARNED=0      # reboot-disabled warning already logged in this outage
LAST_MAINTENANCE=0
LAST_FAULTS=""
REBOOT_COUNT=0       # consecutive reboots performed by survive (persistent)

load_state() {
    local key value
    if [[ -r "$RUN_DIR/state" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                FAIL_SINCE | LAST_ACTION_AT | ACTION_STEP | HEALTHY_SINCE | PKG_WAIT_SINCE | REBOOT_WARNED | LAST_MAINTENANCE)
                    is_uint "$value" && printf -v "$key" '%s' "$value" ;;
                LAST_FAULTS)
                    [[ "$value" =~ ^[a-z\ ]*$ ]] && LAST_FAULTS="$value" ;;
            esac
        done <"$RUN_DIR/state"
    fi
    # Values from the future (state file not on a per-boot tmpfs): discard.
    local t
    t=$(now)
    if ((FAIL_SINCE > t || HEALTHY_SINCE > t || LAST_ACTION_AT > t || PKG_WAIT_SINCE > t || LAST_MAINTENANCE > t)); then
        FAIL_SINCE=0 LAST_ACTION_AT=0 ACTION_STEP=0 HEALTHY_SINCE=0 PKG_WAIT_SINCE=0 REBOOT_WARNED=0 LAST_MAINTENANCE=0 LAST_FAULTS=""
    fi
    REBOOT_COUNT=0
    if [[ -r "$STATE_DIR/reboot_count" ]]; then
        read -r value <"$STATE_DIR/reboot_count" || true
        is_uint "${value:-}" && REBOOT_COUNT=$value
    fi
    return 0
}

save_state() {
    mkdir -p "$RUN_DIR" 2>/dev/null || return 0
    {
        echo "FAIL_SINCE=$FAIL_SINCE"
        echo "LAST_ACTION_AT=$LAST_ACTION_AT"
        echo "ACTION_STEP=$ACTION_STEP"
        echo "HEALTHY_SINCE=$HEALTHY_SINCE"
        echo "PKG_WAIT_SINCE=$PKG_WAIT_SINCE"
        echo "REBOOT_WARNED=$REBOOT_WARNED"
        echo "LAST_MAINTENANCE=$LAST_MAINTENANCE"
        echo "LAST_FAULTS=$LAST_FAULTS"
    } >"$RUN_DIR/state.tmp" 2>/dev/null && mv -f "$RUN_DIR/state.tmp" "$RUN_DIR/state"
}

save_reboot_count() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    echo "$REBOOT_COUNT" >"$STATE_DIR/reboot_count.tmp" 2>/dev/null &&
        mv -f "$STATE_DIR/reboot_count.tmp" "$STATE_DIR/reboot_count" && sync
}

# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

# Physical network interfaces (eth0, wlan0, USB adapters...), skipping
# virtual ones like docker bridges, VPN tunnels and veth pairs.
monitored_interfaces() {
    if [[ -n "$INTERFACES" ]]; then
        echo "$INTERFACES"
        return
    fi
    local dev list=""
    for dev in /sys/class/net/*; do
        [[ -e "$dev/device" ]] || continue
        list+="${dev##*/} "
    done
    echo "${list% }"
}

is_wireless() { [[ -d "/sys/class/net/$1/wireless" || -L "/sys/class/net/$1/phy80211" ]]; }

default_gateway() {
    ip -4 route show default 2>/dev/null | awk '/^default/ { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }'
}

ping_host() {
    case "$1" in
        *:*) ping -6 -n -q -c 2 -W 2 "$1" >/dev/null 2>&1 ;;
        *) ping -n -q -c 2 -W 2 "$1" >/dev/null 2>&1 ;;
    esac
}

NET_DETAIL=""

check_network() {
    local iface addr_found=false
    for iface in $(monitored_interfaces); do
        if [[ -n "$(ip -o addr show dev "$iface" scope global 2>/dev/null)" ]]; then
            addr_found=true
            break
        fi
    done
    if [[ "$addr_found" != true ]]; then
        NET_DETAIL="no IP address on any interface ($(monitored_interfaces))"
        return 1
    fi

    local gw target lan_ok=false
    gw=$(default_gateway)
    for target in $PING_TARGETS; do
        if ping_host "$target"; then
            NET_DETAIL="ok (gateway ${gw:-none}, $target reachable)"
            return 0
        fi
    done
    if [[ "$CHECK_GATEWAY" == true && -n "$gw" ]] && ping_host "$gw"; then
        lan_ok=true
    fi
    if [[ "$lan_ok" == true && "$REQUIRE_INTERNET" != true ]]; then
        NET_DETAIL="ok (gateway $gw reachable, internet unreachable)"
        return 0
    fi
    if [[ -z "$gw" ]]; then
        NET_DETAIL="no default route and no ping target reachable"
    elif [[ "$lan_ok" == true ]]; then
        NET_DETAIL="gateway $gw reachable but internet unreachable (REQUIRE_INTERNET=true)"
    else
        NET_DETAIL="gateway $gw and ping targets unreachable"
    fi
    return 1
}

# Returns 0 if something answers with an SSH banner on host:port.
ssh_banner() {
    # shellcheck disable=SC2016
    timeout 5 bash -c '
        exec 3<>"/dev/tcp/$1/$2" || exit 1
        IFS= read -r -t 4 line <&3 || exit 1
        [[ "$line" == SSH-* ]]
    ' _ "$1" "$2" 2>/dev/null
}

SSH_DETAIL=""

# Loopback first: reachability from outside is covered by the network check;
# this verifies that sshd is alive and answering.
check_ssh() {
    local host
    for host in 127.0.0.1 ::1 $(ip -o addr show scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'); do
        if ssh_banner "$host" "$SSH_PORT"; then
            SSH_DETAIL="ok (banner on $host:$SSH_PORT)"
            return 0
        fi
    done
    SSH_DETAIL="no SSH banner on port $SSH_PORT"
    return 1
}

root_is_readonly() {
    local opts
    opts=$(awk '$2 == "/" { o = $4 } END { print o }' /proc/mounts 2>/dev/null)
    [[ ",$opts," == *,ro,* ]]
}

# Sets FAULTS to the list of current critical faults (empty when healthy).
FAULTS=""

collect_faults() {
    local faults=""
    check_network || faults+="network "
    if [[ "$CHECK_SSH" == true ]]; then
        check_ssh || faults+="ssh "
    fi
    if [[ "$CHECK_ROOT_RW" == true ]] && root_is_readonly; then
        faults+="rootfs "
    fi
    FAULTS="${faults% }"
}

# --------------------------------------------------------------------------
# Repairs
# --------------------------------------------------------------------------

unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }
unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# Network managers in use on Raspberry Pi OS (Bookworm: NetworkManager,
# Bullseye and older: dhcpcd) and other Debian based systems.
NETWORK_MANAGERS="NetworkManager.service dhcpcd.service systemd-networkd.service networking.service"

restart_network_manager() {
    local unit restarted=false
    for unit in $NETWORK_MANAGERS; do
        if unit_active "$unit"; then
            event notice "Restarting $unit"
            run_action systemctl restart "$unit"
            restarted=true
        fi
    done
    if [[ "$restarted" != true ]]; then
        # The network manager itself may have crashed: start any enabled one.
        for unit in $NETWORK_MANAGERS; do
            if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                event warn "$unit is enabled but not running; starting it"
                run_action systemctl reset-failed "$unit"
                run_action systemctl start "$unit"
            fi
        done
    fi
}

net_reconnect() {
    event notice "Repair: reconnecting network interfaces"
    have rfkill && run_action rfkill unblock all
    local iface
    for iface in $(monitored_interfaces); do
        run_action ip link set "$iface" up
        if unit_active NetworkManager.service && have nmcli; then
            run_action nmcli networking on
            run_action nmcli device connect "$iface"
        else
            if is_wireless "$iface" && have wpa_cli; then
                run_action wpa_cli -i "$iface" reconfigure
                run_action wpa_cli -i "$iface" reconnect
            fi
            if unit_active dhcpcd.service && have dhcpcd; then
                run_action dhcpcd -n "$iface"
            elif unit_active systemd-networkd.service && have networkctl; then
                run_action networkctl renew "$iface"
            fi
        fi
    done
}

net_restart_service() {
    event notice "Repair: restarting network services"
    restart_network_manager
}

net_bounce() {
    event notice "Repair: bouncing network interfaces"
    local iface
    for iface in $(monitored_interfaces); do
        run_action ip link set "$iface" down
    done
    [[ "$DRY_RUN" == true ]] || sleep 3
    for iface in $(monitored_interfaces); do
        run_action ip link set "$iface" up
    done
    restart_network_manager
}

net_reload_driver() {
    if [[ "$RELOAD_WIFI_DRIVER" != true ]]; then
        net_restart_service
        return
    fi
    local iface module reloaded=false
    for iface in $(monitored_interfaces); do
        is_wireless "$iface" || continue
        module=$(basename "$(readlink -f "/sys/class/net/$iface/device/driver/module" 2>/dev/null)" 2>/dev/null)
        [[ -n "$module" && "$module" != "." && "$module" != "/" ]] || continue
        event notice "Repair: reloading Wi-Fi driver $module for $iface"
        run_action modprobe -r "$module"
        [[ "$DRY_RUN" == true ]] || sleep 3
        run_action modprobe "$module"
        [[ "$DRY_RUN" == true ]] || sleep 5
        reloaded=true
    done
    if [[ "$reloaded" == true ]]; then
        restart_network_manager
    else
        net_bounce
    fi
}

NETWORK_STEPS=(net_reconnect net_restart_service net_bounce net_reload_driver)

ssh_unit() {
    local unit
    for unit in ssh.service sshd.service; do
        if unit_exists "$unit"; then
            echo "$unit"
            return
        fi
    done
}

ssh_repair() {
    local unit
    unit=$(ssh_unit)
    if [[ -z "$unit" ]]; then
        event error "Repair: no ssh/sshd service installed (apt install openssh-server)"
        return
    fi
    event notice "Repair: restarting $unit"
    run_action mkdir -p /run/sshd
    run_action chmod 0755 /run/sshd
    # Missing/corrupted host keys keep sshd from starting (e.g. after SD card issues).
    if ! compgen -G "/etc/ssh/ssh_host_*_key" >/dev/null && have ssh-keygen; then
        event warn "SSH host keys missing; regenerating them"
        run_action ssh-keygen -A
    fi
    local sshd_bin out
    sshd_bin=$(command -v sshd || echo /usr/sbin/sshd)
    if [[ -x "$sshd_bin" ]] && ! out=$("$sshd_bin" -t 2>&1); then
        if [[ "$out" == *"host key"* ]] && have ssh-keygen; then
            event warn "sshd host key problem ($out); regenerating host keys"
            run_action ssh-keygen -A
        else
            event error "sshd configuration test failed: $out"
        fi
    fi
    if ! systemctl is-enabled --quiet "$unit" 2>/dev/null &&
        ! systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        event warn "$unit is disabled; enabling it"
        run_action systemctl enable "$unit"
    fi
    run_action systemctl reset-failed "$unit"
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        # Socket activated sshd: restarting the service could stop the socket.
        run_action systemctl reset-failed ssh.socket
        run_action systemctl restart ssh.socket
    else
        run_action systemctl restart "$unit"
    fi
}

rootfs_repair() {
    event error "Root filesystem is mounted read-only (filesystem errors or failing SD card); a reboot with fsck is required"
}

remediate() {
    local faults="$1" fault
    for fault in $faults; do
        notify_watchdog
        case "$fault" in
            network) "${NETWORK_STEPS[ACTION_STEP % ${#NETWORK_STEPS[@]}]}" ;;
            ssh) ssh_repair ;;
            rootfs) rootfs_repair ;;
        esac
    done
    notify_watchdog
}

# --------------------------------------------------------------------------
# Reboot
# --------------------------------------------------------------------------

# Reboot delay, doubled for every consecutive reboot beyond the threshold so a
# problem that a reboot cannot fix (e.g. router switched off) does not cause a
# reboot loop, while still retrying periodically.
reboot_deadline() {
    local delay=$REBOOT_AFTER extra=$((REBOOT_COUNT - REBOOT_BACKOFF_THRESHOLD + 1))
    while ((extra > 0 && delay < MAX_REBOOT_DELAY)); do
        delay=$((delay * 2))
        extra=$((extra - 1))
    done
    ((delay > MAX_REBOOT_DELAY)) && delay=$MAX_REBOOT_DELAY
    echo "$delay"
}

package_manager_busy() {
    pgrep -x 'apt|apt-get|aptitude|dpkg|unattended-upgr' >/dev/null 2>&1 ||
        pgrep -f '/usr/bin/unattended-upgrade' >/dev/null 2>&1
}

do_reboot() {
    if [[ "$DRY_RUN" == true ]]; then
        log notice "[dry-run] reboot"
        return 0
    fi
    sync
    timeout 60 systemctl reboot >/dev/null 2>&1 || timeout 60 reboot >/dev/null 2>&1
    # If the graceful reboot hangs (wedged system), force it. A SIGTERM means
    # the shutdown is progressing (a hang from there on is caught by the
    # hardware watchdog's RebootWatchdogSec).
    nap "$REBOOT_FORCE_TIMEOUT"
    [[ "$RUNNING" == true ]] || return 0
    event error "Graceful reboot did not complete; forcing reboot"
    sync
    timeout 30 systemctl reboot --force --force >/dev/null 2>&1
    nap 30
    [[ "$RUNNING" == true ]] || return 0
    if [[ -w /proc/sysrq-trigger ]]; then
        echo 1 >/proc/sys/kernel/sysrq 2>/dev/null
        echo s >/proc/sysrq-trigger
        sleep 2
        echo u >/proc/sysrq-trigger
        sleep 2
        echo b >/proc/sysrq-trigger
    fi
}

attempt_reboot() {
    local t="$1" faults="$2" elapsed="$3"
    if [[ "$ENABLE_REBOOT" != true ]]; then
        if ((REBOOT_WARNED == 0)); then
            event error "Unreachable for ${elapsed}s ($faults) but ENABLE_REBOOT=false; not rebooting"
            REBOOT_WARNED=1
        fi
        return 0
    fi
    if package_manager_busy; then
        ((PKG_WAIT_SINCE == 0)) && PKG_WAIT_SINCE=$t
        if ((t - PKG_WAIT_SINCE < PACKAGE_MANAGER_WAIT)); then
            log warn "Reboot postponed: package manager is running (waited $((t - PKG_WAIT_SINCE))s of ${PACKAGE_MANAGER_WAIT}s)"
            return 0
        fi
        event warn "Package manager still running after ${PACKAGE_MANAGER_WAIT}s; rebooting anyway"
    fi
    REBOOT_COUNT=$((REBOOT_COUNT + 1))
    save_reboot_count
    event error "REBOOTING: unreachable for ${elapsed}s ($faults), repairs failed (consecutive reboot #$REBOOT_COUNT)"
    do_reboot
    # Only reached in dry-run mode or if the reboot failed: start a new episode.
    FAIL_SINCE=$t
    LAST_ACTION_AT=0
    ACTION_STEP=0
    PKG_WAIT_SINCE=0
}

# --------------------------------------------------------------------------
# Health maintenance (non-critical)
# --------------------------------------------------------------------------

disk_usage_pct() { df -P / 2>/dev/null | awk 'NR == 2 { sub(/%/, "", $5); print $5 }'; }

cleanup_disk() {
    event warn "Root filesystem ${1}% full; cleaning up"
    have journalctl && run_action journalctl --vacuum-size=50M
    have apt-get && run_action apt-get clean
    run_action find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -mtime +7 -delete
    run_action find /tmp /var/tmp -xdev -type f -mtime +7 -delete
    event notice "Disk usage after cleanup: $(disk_usage_pct)%"
}

THROTTLE_LAST=""

check_health() {
    local usage
    usage=$(disk_usage_pct)
    if is_uint "$usage" && ((usage >= DISK_USAGE_THRESHOLD)); then
        cleanup_disk "$usage"
    fi

    local total avail
    total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null)
    avail=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null)
    if is_uint "$total" && is_uint "$avail" && ((total > 0 && avail * 100 / total < MEMORY_MIN_AVAILABLE_PCT)); then
        event warn "Low memory: $((avail / 1024))MB available of $((total / 1024))MB; top: $(ps -eo comm,rss --sort=-rss --no-headers 2>/dev/null | head -n 5 | awk '{ printf "%s(%dMB) ", $1, $2 / 1024 }')"
    fi

    local temp
    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        read -r temp </sys/class/thermal/thermal_zone0/temp
        if is_uint "$temp" && ((temp / 1000 >= TEMP_WARN)); then
            event warn "High CPU temperature: $((temp / 1000))C"
        fi
    fi

    if have vcgencmd; then
        local throttled
        throttled=$(vcgencmd get_throttled 2>/dev/null | sed -n 's/^throttled=//p')
        if [[ -n "$throttled" && "$throttled" != "$THROTTLE_LAST" ]]; then
            THROTTLE_LAST=$throttled
            local flags=$((throttled))
            ((flags & 0x1)) && event warn "Under-voltage detected (check the power supply)"
            ((flags & 0x4)) && event warn "CPU is currently throttled"
            ((flags & 0x8)) && event warn "Soft temperature limit active"
            ((flags & 0x10000 && !(flags & 0x1))) && event warn "Under-voltage has occurred since boot"
        fi
    fi

    local svc
    for svc in $WATCH_SERVICES; do
        if ! unit_active "$svc"; then
            event warn "Watched service $svc is not running; restarting"
            run_action systemctl reset-failed "$svc"
            run_action systemctl restart "$svc"
        fi
    done
}

# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------

# One supervision step: evaluate faults and decide what to do.
evaluate() {
    local t="$1" faults="$2"
    if [[ -z "$faults" ]]; then
        if ((FAIL_SINCE > 0)); then
            event notice "Recovered after $((t - FAIL_SINCE))s (was: $LAST_FAULTS)"
        fi
        FAIL_SINCE=0
        LAST_ACTION_AT=0
        ACTION_STEP=0
        PKG_WAIT_SINCE=0
        REBOOT_WARNED=0
        LAST_FAULTS=""
        ((HEALTHY_SINCE == 0)) && HEALTHY_SINCE=$t
        if ((REBOOT_COUNT > 0 && t - HEALTHY_SINCE >= HEALTHY_RESET_TIME)); then
            log info "Healthy for $((t - HEALTHY_SINCE))s; resetting reboot counter"
            REBOOT_COUNT=0
            save_reboot_count
        fi
        return 0
    fi

    HEALTHY_SINCE=0
    if ((FAIL_SINCE == 0)); then
        FAIL_SINCE=$t
        event warn "Problem detected: $faults; allowing ${GRACE_PERIOD}s for self-recovery"
    elif [[ "$faults" != "$LAST_FAULTS" ]]; then
        event warn "Problem changed: $faults (was: $LAST_FAULTS)"
    fi
    LAST_FAULTS="$faults"

    local elapsed=$((t - FAIL_SINCE)) deadline
    deadline=$(reboot_deadline)
    if ((elapsed >= deadline)); then
        attempt_reboot "$t" "$faults" "$elapsed"
    elif ((elapsed >= GRACE_PERIOD)); then
        if ((LAST_ACTION_AT == 0 || t - LAST_ACTION_AT >= ACTION_INTERVAL)); then
            log warn "Still failing after ${elapsed}s ($faults); repair round $((ACTION_STEP + 1)), reboot in $((deadline - elapsed))s"
            remediate "$faults"
            ACTION_STEP=$((ACTION_STEP + 1))
            LAST_ACTION_AT=$t
        fi
    else
        log info "Waiting for self-recovery: $faults for ${elapsed}s (repairs start at ${GRACE_PERIOD}s)"
    fi
}

describe_faults() {
    local f
    for f in $1; do
        case "$f" in
            network) log warn "network: $NET_DETAIL" ;;
            ssh) log warn "ssh: $SSH_DETAIL" ;;
            rootfs) log warn "rootfs: root filesystem is read-only" ;;
        esac
    done
}

RUNNING=true

daemon() {
    if [[ $EUID -ne 0 && "$DRY_RUN" != true ]]; then
        log error "survive must run as root (or with DRY_RUN=true)"
        exit 1
    fi
    trap 'RUNNING=false' TERM INT
    mkdir -p "$STATE_DIR" "$RUN_DIR"
    load_state

    if [[ "$CHECK_ROOT_RW" == true ]] && root_is_readonly; then
        log notice "Root filesystem is read-only at startup (read-only setup?); disabling the read-only check"
        CHECK_ROOT_RW=false
    fi

    log info "Survive $SURVIVE_VERSION started (grace ${GRACE_PERIOD}s, reboot after ${REBOOT_AFTER}s, interfaces: $(monitored_interfaces), dry-run: $DRY_RUN)"
    ((REBOOT_COUNT > 0)) && log notice "Consecutive reboots by survive: $REBOOT_COUNT (next reboot after $(reboot_deadline)s)"
    if [[ -n "${NOTIFY_SOCKET:-}" ]] && have systemd-notify; then
        systemd-notify --pid=$$ --ready "STATUS=monitoring" >/dev/null 2>&1 || true
    fi

    local t
    while [[ "$RUNNING" == true ]]; do
        notify_watchdog
        collect_faults
        [[ -n "$FAULTS" ]] && describe_faults "$FAULTS"
        t=$(now)
        evaluate "$t" "$FAULTS"
        if ((t - LAST_MAINTENANCE >= MAINTENANCE_INTERVAL || LAST_MAINTENANCE == 0)); then
            check_health
            LAST_MAINTENANCE=$t
        fi
        save_state
        [[ "$RUNNING" == true ]] && nap "$CHECK_INTERVAL"
    done
    log info "Survive stopping"
}

cmd_check() {
    local rc=0
    if check_network; then echo "network: $NET_DETAIL"; else echo "network: FAIL - $NET_DETAIL"; rc=1; fi
    if [[ "$CHECK_SSH" == true ]]; then
        if check_ssh; then echo "ssh:     $SSH_DETAIL"; else echo "ssh:     FAIL - $SSH_DETAIL"; rc=1; fi
    fi
    if root_is_readonly; then echo "rootfs:  read-only"; else echo "rootfs:  ok (read-write)"; fi
    echo "disk:    $(disk_usage_pct)% used"
    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp
        read -r temp </sys/class/thermal/thermal_zone0/temp
        echo "temp:    $((temp / 1000))C"
    fi
    have vcgencmd && echo "power:   $(vcgencmd get_throttled 2>/dev/null)"
    return $rc
}

cmd_status() {
    load_state
    local t
    t=$(now)
    if ((FAIL_SINCE > 0)); then
        echo "State:            FAILING ($LAST_FAULTS) for $((t - FAIL_SINCE))s, $ACTION_STEP repair round(s)"
        echo "Reboot after:     $(reboot_deadline)s of failure"
    elif ((HEALTHY_SINCE > 0)); then
        echo "State:            healthy for $((t - HEALTHY_SINCE))s"
    else
        echo "State:            unknown (daemon not running yet?)"
    fi
    echo "Reboot counter:   $REBOOT_COUNT consecutive reboot(s) by survive"
    echo "Recent events ($STATE_DIR/events.log):"
    if [[ -r "$STATE_DIR/events.log" ]]; then
        tail -n 20 "$STATE_DIR/events.log" | sed 's/^/  /'
    else
        echo "  none"
    fi
}

usage() {
    cat <<EOF
Survive $SURVIVE_VERSION - Raspberry Pi self-healing service

Usage: survive [command]

Commands:
  run      Run the monitoring daemon (default; used by survive.service)
  check    Run all checks once and print the result
  status   Show the current state and recent events
  version  Print the version
  help     Show this help

Configuration: $SURVIVE_CONFIG
EOF
}

main() {
    load_config
    case "${1:-run}" in
        run) daemon ;;
        check) cmd_check ;;
        status) cmd_status ;;
        version | --version | -v) echo "$SURVIVE_VERSION" ;;
        help | --help | -h) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
