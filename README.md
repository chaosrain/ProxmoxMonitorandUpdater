# Proxmox Monitor & Updater (PMAU)

A single-command, PVE-helper-style installer that stands up a complete
monitoring + maintenance control plane on a Proxmox VE host:

- **CT 200** — an unprivileged Debian 13 "ops" LXC
- **[Pulse](https://github.com/rcourtman/Pulse)** — a real-time, Proxmox-native
  dashboard (nodes, VMs, **LXC**, storage, backups) running inside CT 200
- **Host-side maintenance timer** — patches all running LXC guests, refreshes the
  host package index, and reports results
- **unattended-upgrades** pushed into Debian/Ubuntu guests for security patches
- **ntfy** notifications for every maintenance run

## Quick start

Run on the **Proxmox host, as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chaosrain/ProxmoxMonitorandUpdater/main/monitor-update.sh)"
```

You'll get an interactive menu. Pick **Full setup** for the whole stack, or run
individual steps. Re-running is safe — it's idempotent and stores choices in
`/etc/pmau/pmau.conf`.

## Why the updater runs on the host, not in CT 200

This is the one thing people get wrong. An unprivileged LXC **cannot** patch the
PVE host, cannot run `apt`/`pct`/`qm` against sibling guests, and cannot touch the
kernel — that requires host privilege. So PMAU splits responsibilities:

| Job | Where it runs |
|-----|---------------|
| Live dashboard (Pulse) | inside CT 200 |
| Guest patching, host index refresh, host upgrades | **host** (`pmau-update.sh` via systemd timer) |
| Per-guest security auto-patch | inside each guest (`unattended-upgrades`) |

CT 200 is the dashboard and control surface. The patching lives on the host
because that's the only place it physically can.

## What gets installed

| Path | Purpose |
|------|---------|
| `/usr/local/bin/pmau-update.sh` | host maintenance script |
| `/usr/local/bin/pmau-notify.sh` | ntfy push helper |
| `/etc/systemd/system/pmau-update.{service,timer}` | scheduled maintenance |
| `/etc/pmau/pmau.conf` | saved configuration (chmod 600) |
| `/var/log/pmau-update.log` | run log |
| CT 200 | Debian 13 LXC running Pulse on port `7655` |

## Usage after install

```bash
# run maintenance immediately (guests + host index refresh, no host upgrade)
/usr/local/bin/pmau-update.sh

# intentionally apply host dist-upgrade (snapshot/back up first!)
/usr/local/bin/pmau-update.sh --host

# preview without changing anything
/usr/local/bin/pmau-update.sh --dry-run

# check the schedule
systemctl list-timers pmau-update.timer
```

## Safety posture

- **Host kernel/dist-upgrades are never automated.** The timer only patches guests
  and refreshes the host index; it *reports* pending host updates but applies them
  only when you run `--host` yourself. Take a snapshot or PBS backup first.
- Pulse is configured against a **read-only** Proxmox API token, never root.
- `unattended-upgrades` in guests is limited to the `-security` pocket and does
  **not** auto-reboot.
- The ntfy token and config file are `chmod 600`.

## Connecting Pulse to Proxmox

After install, open `http://<ct200-ip>:7655`, then in **Settings** add your node
using a token created at **Datacenter → Permissions → API Tokens**
(`PVEAuditor` role is sufficient for read-only monitoring).

## Requirements

- Proxmox VE 8.x or 9.x (tested against 9.2 / Debian 13)
- Internet access from the host and from CT 200 (template + Pulse + ntfy)

## Uninstall

Menu option 7 removes the host components (timer, scripts, config). It does **not**
destroy CT 200 or modify your guests — remove the container manually with
`pct stop 200 && pct destroy 200` if you want it gone.

## License

MIT — see [LICENSE](LICENSE).

> Not affiliated with Proxmox Server Solutions GmbH. Pulse is a separate project by
> [@rcourtman](https://github.com/rcourtman). Review the script before piping it to
> `bash` — as you should with any helper script.
