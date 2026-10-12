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
* **Crash-loop guard** – a service stuck restarting in a tight loop (e.g. a
  wrong/stale bind address) pegs the CPU and can make the whole Pi
  unresponsive. Survive watches systemd's per-unit restart counter and stops a
  runaway unit (`reset-failed` too) so the system stays reachable; you fix the
  unit and start it again. `survive.service` and SSH are always protected, and
  extra units can be exempted via `CRASHLOOP_IGNORE`.
* **Persistent incident log** – every problem, repair and reboot is written to
  `/var/lib/survive/events.log`, so you can see why the Pi rebooted.

## Installation

```bash
git clone https://github.com/PierreGode/Survive.git
cd Survive
sudo ./install.sh
```

Options: `--no-hardware-watchdog` (do not enable the hardware watchdog),
`--no-start` (install and enable, but do not start yet),
`--with-web` (also install the web dashboard, see below).

The installer installs `/usr/local/bin/survive`, `/etc/survive/survive.conf`
(an existing configuration is kept) and `survive.service`, makes sure SSH is
enabled and starts the service.

## Web dashboard

An optional status page that shows everything at a glance: overall health,
system vitals (CPU, temperature, memory, disk, load), under-voltage /
throttling, the crash-loop guard, watched services, every listening TCP port
and Docker container, and the recent incident log. It auto-refreshes and needs
no build step or dependencies — just Python 3 (standard library only).

A **Settings** panel lets you change the most useful options live — toggle
auto-reboot and the crash-loop guard, adjust the grace/reboot timers and
crash-loop threshold, and pick which systemd services Survive monitors
(`WATCH_SERVICES`). Changes are written to `survive.conf` and `survive` is
restarted. Every value is strictly validated before it is written (the config
is sourced by bash), so the panel cannot be used to inject shell commands.
Because the panel can change behaviour and restart services, and it has **no
authentication**, only expose the dashboard on a trusted network — see the
bind note below.

```bash
sudo ./install.sh --with-web            # or, on an existing install:
sudo install -m 0755 web/survive-web.py /usr/local/bin/survive-web
sudo mkdir -p /usr/local/share/survive-web
sudo install -m 0644 web/index.html /usr/local/share/survive-web/index.html
sudo install -m 0644 web/survive-web.service /etc/systemd/system/
sudo systemctl enable --now survive-web
```

Then open `http://<pi>:8099`. The port and bind address are set in
`survive-web.service` (`SURVIVE_WEB_PORT`, `SURVIVE_WEB_HOST`); it binds to
`0.0.0.0` by default, so restrict it (e.g. to `127.0.0.1` or a VPN interface)
if the host is not on a trusted network. The dashboard only reads state and
never changes anything.

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
| `CRASHLOOP_GUARD` | `true` | stop services stuck in a restart loop |
| `CRASHLOOP_THRESHOLD` | `15` | restarts within the window that count as a loop |
| `CRASHLOOP_WINDOW` | `120` | seconds the restarts are counted over |
| `CRASHLOOP_ACTION` | `stop` | `stop` the unit, or only `log` it |
| `CRASHLOOP_IGNORE` | empty | units to never stop (survive/ssh always protected) |

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
