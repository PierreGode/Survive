#!/usr/bin/env bash
#
# Tests for the survive decision logic (escalation timeline, reboot backoff,
# state persistence). Run with: bash tests/test_survive.sh

# shellcheck disable=SC2034,SC2317  # globals/mocks are used by the sourced script
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SURVIVE_CONFIG=/dev/null
# shellcheck source=survive.sh
. "$ROOT/survive.sh"

PASS=0
FAIL=0
ACTIONS=()

# --- mocks ---------------------------------------------------------------
log() { :; }
remediate() { ACTIONS+=("repair:$1:$ACTION_STEP"); }
do_reboot() { ACTIONS+=("reboot"); }
PKG_BUSY=false
package_manager_busy() { [[ "$PKG_BUSY" == true ]]; }

setup() {
    load_defaults
    STATE_DIR="$TMP/state.$RANDOM"
    RUN_DIR="$TMP/run.$RANDOM"
    FAIL_SINCE=0 LAST_ACTION_AT=0 ACTION_STEP=0 HEALTHY_SINCE=0
    PKG_WAIT_SINCE=0 REBOOT_WARNED=0 LAST_MAINTENANCE=0 LAST_FAULTS="" REBOOT_COUNT=0
    PKG_BUSY=false
    ACTIONS=()
}

# Simulate the daemon loop from $1 to $2 (seconds of uptime) with the given faults.
simulate() {
    local from=$1 to=$2 faults=$3 t
    for ((t = from; t <= to; t += CHECK_INTERVAL)); do
        evaluate "$t" "$faults"
    done
}

count() {
    local pattern=$1 n=0 a
    for a in "${ACTIONS[@]+"${ACTIONS[@]}"}"; do
        # shellcheck disable=SC2053
        [[ "$a" == $pattern ]] && n=$((n + 1))
    done
    echo "$n"
}

assert_eq() {
    if [[ "$1" == "$2" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $3 (expected '$2', got '$1')"
    fi
}

assert_true() {
    if "${@:2}"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $1"
    fi
}

# --- tests ---------------------------------------------------------------

test_no_action_during_grace_period() {
    setup
    simulate 1000 1299 "network"
    assert_eq "${#ACTIONS[@]}" 0 "no action within the 5 minute grace period"
    assert_eq "$FAIL_SINCE" 1000 "outage start recorded"
}

test_repairs_start_after_grace_period() {
    setup
    simulate 1000 1300 "network"
    assert_eq "${ACTIONS[*]}" "repair:network:0" "first repair at 5 minutes"
    simulate 1330 1599 "network"
    assert_eq "$(count 'repair:*')" 5 "one repair per ACTION_INTERVAL between 5 and 10 minutes"
    assert_eq "$(count reboot)" 0 "no reboot before 10 minutes"
    assert_eq "${ACTIONS[1]}" "repair:network:1" "repairs escalate"
}

test_reboot_after_ten_minutes() {
    setup
    simulate 1000 1600 "network ssh"
    assert_eq "$(count reboot)" 1 "reboot after 10 minutes"
    assert_eq "$REBOOT_COUNT" 1 "reboot counter incremented"
    assert_eq "$(cat "$STATE_DIR/reboot_count")" 1 "reboot counter persisted"
}

test_recovery_resets_outage() {
    setup
    simulate 1000 1500 "ssh"
    evaluate 1530 ""
    assert_eq "$FAIL_SINCE" 0 "recovery clears the outage"
    assert_eq "$ACTION_STEP" 0 "recovery resets the escalation"
    ACTIONS=()
    simulate 1560 1859 "ssh"
    assert_eq "${#ACTIONS[@]}" 0 "new outage gets a fresh grace period"
    simulate 1860 2159 "ssh"
    assert_eq "$(count reboot)" 0 "new outage gets a fresh reboot timer"
}

test_changing_faults_keep_outage_timer() {
    setup
    simulate 1000 1300 "network"
    simulate 1330 1600 "ssh"
    assert_eq "$(count reboot)" 1 "outage timer continues when the fault type changes"
}

test_reboot_backoff() {
    setup
    REBOOT_COUNT=0; assert_eq "$(reboot_deadline)" 600 "no backoff for first reboot"
    REBOOT_COUNT=2; assert_eq "$(reboot_deadline)" 600 "no backoff below threshold"
    REBOOT_COUNT=3; assert_eq "$(reboot_deadline)" 1200 "backoff doubles at threshold"
    REBOOT_COUNT=4; assert_eq "$(reboot_deadline)" 2400 "backoff doubles again"
    REBOOT_COUNT=9; assert_eq "$(reboot_deadline)" 3600 "backoff is capped"
}

test_backoff_delays_reboot() {
    setup
    REBOOT_COUNT=3
    simulate 1000 1799 "network"
    assert_eq "$(count reboot)" 0 "no reboot before backed-off deadline"
    simulate 1800 2220 "network"
    assert_eq "$(count reboot)" 1 "reboot at backed-off deadline"
}

test_healthy_period_resets_reboot_count() {
    setup
    REBOOT_COUNT=2
    simulate 100 1000 ""
    assert_eq "$REBOOT_COUNT" 2 "counter kept before HEALTHY_RESET_TIME"
    simulate 1030 1900 ""
    assert_eq "$REBOOT_COUNT" 0 "counter reset after HEALTHY_RESET_TIME"
}

test_reboot_postponed_while_package_manager_runs() {
    setup
    PKG_BUSY=true
    simulate 1000 2000 "network"
    assert_eq "$(count reboot)" 0 "reboot postponed during apt/dpkg"
    simulate 2030 3500 "network"
    assert_eq "$(count reboot)" 1 "reboot after PACKAGE_MANAGER_WAIT"
}

test_reboot_disabled() {
    setup
    ENABLE_REBOOT=false
    simulate 1000 5000 "network"
    assert_eq "$(count reboot)" 0 "never reboots with ENABLE_REBOOT=false"
    assert_true "repairs continue with reboot disabled" test "$(count 'repair:*')" -gt 0
}

test_state_survives_daemon_restart() {
    setup
    simulate 1000 1400 "network"
    save_state
    local saved_step=$ACTION_STEP
    FAIL_SINCE=0 ACTION_STEP=0 LAST_FAULTS=""
    now() { echo 1430; }
    load_state
    assert_eq "$FAIL_SINCE" 1000 "outage start restored"
    assert_eq "$ACTION_STEP" "$saved_step" "escalation step restored"
    assert_eq "$LAST_FAULTS" "network" "faults restored"
    now() { echo 10; }
    load_state
    assert_eq "$FAIL_SINCE" 0 "state from a previous boot is discarded"
}

test_config_validation() {
    local cfg="$TMP/survive.conf"
    printf 'GRACE_PERIOD=600\nREBOOT_AFTER=300\nCHECK_INTERVAL=abc\n' >"$cfg"
    SURVIVE_CONFIG="$cfg" load_config
    assert_eq "$CHECK_INTERVAL" 30 "invalid number falls back to default"
    assert_true "REBOOT_AFTER adjusted above GRACE_PERIOD" test "$REBOOT_AFTER" -gt "$GRACE_PERIOD"
}

test_network_repair_steps_cycle() {
    setup
    local calls=()
    net_reconnect() { calls+=(reconnect); }
    net_restart_service() { calls+=(restart); }
    net_bounce() { calls+=(bounce); }
    net_reload_driver() { calls+=(driver); }
    local step
    for step in 0 1 2 3 4; do
        ACTION_STEP=$step
        "${NETWORK_STEPS[ACTION_STEP % ${#NETWORK_STEPS[@]}]}"
    done
    assert_eq "${calls[*]}" "reconnect restart bounce driver reconnect" "network repairs escalate and cycle"
}

for test in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    "$test"
done

echo "$PASS passed, $FAIL failed"
((FAIL == 0))
