# Survive
Raspberry pi self healing

Survive is an installable systemd service that keeps a Raspberry Pi healthy and,
above all, **reachable over SSH**. It continuously monitors the network, the SSH
daemon and the system health, lets the Pi recover on its own first, then
repairs what it can and finally reboots when nothing else helps.

## How it works

Every 30 seconds Survive checks:

| Check | Considered healthy when |
|-------|-------------------------|
| Network | an interface has an IP address and the internet (`PING_TARGETS`) or the default gateway answers |
| SSH | the SSH daemon answers with an `SSH-` banner on port 22 (end-to-end check, not just "service active") |
| Root filesystem | `/` has not unexpectedly become read-only (SD card / filesystem errors) |

When one of them fails, Survive escalates over time (counted with the monotonic
clock, so NTP time jumps on a Pi without RTC do not matter):

| Time unreachable | Action |
|------------------|--------|
| 0 – 5 min | **Grace period**: only observe and log, let the Pi reconnect by itself |
| 5 – 10 min | **Repair**, one step per minute, escalating and cycling: <br>1. unblock rfkill, bring interfaces up, Wi-Fi reconnect, DHCP renew <br>2. restart the network manager (NetworkManager / dhcpcd / systemd-networkd / networking), start it if it crashed <br>3. bounce the network interfaces <br>4. reload the Wi-Fi kernel driver (e.g. `brcmfmac`) <br>SSH: recreate `/run/sshd`, regenerate missing host keys, validate the config, re-enable and restart `ssh` |
| ≥ 10 min | **Reboot** (graceful, forced if it hangs) |

As soon as everything is healthy again the outage is cleared and the timers reset.

### Safety & intelligence

* **Reboot loop protection** – after 3 consecutive reboots that did not fix the
  problem (e.g. the router is switched off) the reboot delay doubles each time,
  up to 1 hour, so it keeps retrying without rebooting constantly. The counter
  resets after 30 minutes of healthy operation.
* **No reboot during package installs** – a reboot is postponed (up to 30 min)
  while `apt`/`dpkg`/`unattended-upgrades` is running.
* **Hung reboot fallback** – if a graceful reboot has not happened after 5
  minutes it is forced (`systemctl reboot -ff`, then the kernel SysRq trigger).
* **Hardware watchdog** – the installer enables the Raspberry Pi hardware
  watchdog through systemd, so a frozen kernel/system reboots automatically.
* **Self-supervision** – the service is protected from the OOM killer, restarts
  automatically and is supervised by the systemd watchdog. Its state lives in
  `/run/survive`, so a daemon restart does not reset an ongoing outage timer.
* **Health maintenance** (every 5 min) – cleans the journal, apt cache, rotated
  logs (older than 7 days) and old temp files when the disk is ≥ 90 % full; logs low memory (with the
  biggest processes), high temperature and under-voltage/throttling
  (`vcgencmd`); restarts services listed in `WATCH_SERVICES`.
* **Persistent incident log** – every problem, repair and reboot is written to
  `/var/lib/survive/events.log`, so you can see why the Pi rebooted.

## Installation

```bash
git clone https://github.com/PierreGode/Survive.git
cd Survive
sudo ./install.sh
```

Options: `--no-hardware-watchdog` (do not enable the hardware watchdog),
`--no-start` (install and enable, but do not start yet).

The installer installs `/usr/local/bin/survive`, `/etc/survive/survive.conf`
(an existing configuration is kept) and `survive.service`, makes sure SSH is
enabled and starts the service.

## Usage

```bash
survive check                 # run all checks once
survive status                # current state, reboot counter and recent events
journalctl -u survive -f      # live log
systemctl status survive
```

## Configuration

Edit `/etc/survive/survive.conf`, then `sudo systemctl restart survive`.
The most important settings:

| Setting | Default | Meaning |
|---------|---------|---------|
| `GRACE_PERIOD` | `300` | seconds to let the Pi recover by itself |
| `REBOOT_AFTER` | `600` | seconds unreachable before rebooting |
| `ENABLE_REBOOT` | `true` | allow rebooting |
| `DRY_RUN` | `false` | only log actions (for testing) |
| `PING_TARGETS` | `1.1.1.1 8.8.8.8 9.9.9.9` | connectivity targets (use a LAN host on isolated networks) |
| `REQUIRE_INTERNET` | `false` | `false`: reaching the gateway is enough |
| `INTERFACES` | auto | interfaces to monitor/repair, e.g. `"wlan0"` |
| `WATCH_SERVICES` | empty | extra services to keep running |

See the comments in [`survive.conf`](survive.conf) for all options.

## Uninstall

```bash
sudo ./uninstall.sh           # add --purge to also remove config and logs
```

## Development

```bash
shellcheck -x survive.sh install.sh uninstall.sh tests/test_survive.sh
bash tests/test_survive.sh
```
