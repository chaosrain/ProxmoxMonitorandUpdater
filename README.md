# Proxmox Monitor & Updater (PMAU)

A single-command, PVE-helper-style installer that stands up a complete
monitoring + maintenance control plane on a Proxmox VE host:

- **CT 200** — an unprivileged Debian 13 "ops" LXC
- **[Pulse](https://github.com/rcourtman/Pulse)** — a real-time, Proxmox-native
  dashboard (nodes, VMs, **LXC**, storage, backups) running inside CT 200, with
  **automatic host registration** (read-only token, no root stored)
- **Host-side maintenance timer** — patches all running LXC guests, refreshes the
  host package index, and reports results
- **Pre-update snapshots** — each guest is snapshotted before patching (configurable
  retention) so a bad update rolls back with `pct rollback`
- **community-scripts `update-apps`** (optional) — also updates the *applications*
  inside community-script-built containers, not just the OS
- **unattended-upgrades** pushed into Debian/Ubuntu guests for security patches
- **ntfy** notifications for every maintenance run
- **Beszel hub** (optional, menu 8) — lightweight monitoring for non-Proxmox hosts
  (UniFi, NAS, Pis), installed in CT 200 on port 8090
- **Prometheus + Grafana + pve-exporter** (optional, menu 9) — the historical-metrics
  power tier in a dedicated CT 201. Prometheus is installed from its upstream binary
  (Debian's apt package is being retired); Grafana gets a provisioned Prometheus
  datasource, and you import the *Proxmox via Prometheus* dashboard (ID 10347) once
  via the UI (it auto-binds to the datasource)

## Menu

```
1  Full setup (CT 200 + Pulse + auto-register + ntfy + updater)
2  Create CT 200 only
3  Install / refresh Pulse in CT 200
4  Auto-register this host into Pulse
5  Configure ntfy notifications
6  Install / update the maintenance timer (snapshots, app-updates)
7  Run maintenance now (guests + host index)
8  Install Beszel hub (monitor non-Proxmox hosts)
9  Install Prometheus + Grafana stack (experimental)
10 Uninstall host components
11 Quit
```

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

## Containers & services

PMAU deploys monitoring across two LXC containers. The optional Prometheus tier
lives in its own container so the heavy, churny stack can be rebuilt without
touching the always-on Pulse/maintenance control plane.

| CTID | Hostname | Role | Services (port) |
|------|----------|------|-----------------|
| **200** | `pmau` | Ops / dashboard control plane | Pulse (`7655`), Beszel hub (`8090`, optional) |
| **201** | `prom-grafana` | Historical metrics (optional, menu 9) | Grafana (`3000`), Prometheus (`9090`), pve-exporter (`9221`) |

Both are unprivileged Debian 13 LXCs. CT 201's NIC MAC is set from `PROM_MAC` in
the config so a DHCP reservation can pin its address.

### Deployed instance (CaliMox / ChaosCore)

| Component | Address | Notes |
|-----------|---------|-------|
| PVE host `calimox` | `10.0.0.10:8006` | exporter scrape target |
| CT 200 `pmau` — Pulse | `http://10.0.0.52:7655` | host auto-registered, read-only token |
| CT 200 `pmau` — Beszel hub | `http://10.0.0.52:8090` | add agents per host via the UI |
| CT 201 `prom-grafana` — Grafana | `http://10.0.0.53:3000` | import dashboard 10347, datasource Prometheus |
| CT 201 — Prometheus | `http://10.0.0.53:9090` | scrapes the exporter |
| CT 201 — pve-exporter | `http://10.0.0.53:9221/pve?target=10.0.0.10:8006` | read-only `pmau-exporter@pve` token |

CT 201 (`10.0.0.53`) is pinned via UCG DHCP reservation to MAC `bc:24:11:05:27:e4`.

## Usage after install

```bash
# run maintenance (guests + host index refresh, no host upgrade)
# NOTE: the very FIRST run is forced to dry-run (shows what it would do) and
# writes a marker; later runs apply for real.
/usr/local/bin/pmau-update.sh

# apply for real even on the first run (override the first-run dry-run guard)
/usr/local/bin/pmau-update.sh --apply

# intentionally apply host dist-upgrade (snapshot/back up first!)
/usr/local/bin/pmau-update.sh --host

# preview without changing anything
/usr/local/bin/pmau-update.sh --dry-run

# check the schedule
systemctl list-timers pmau-update.timer
```

### Safety guards

- **First run is a dry-run.** The first time `pmau-update.sh` executes (manually or
  via the timer) it forces `--dry-run`, logs/notifies what it *would* do, and writes
  `/etc/pmau/.maintenance-ran`. Subsequent runs apply. Use `--apply` to go live
  immediately.
- **Installer self-checks.** Run from a file, `monitor-update.sh` syntax-validates
  itself (`bash -n`) before doing anything. Run via `curl | bash`, the only
  top-level statement is the final `main "$@"`, so a truncated download executes
  nothing rather than half the script.

## Safety posture

- **Host kernel/dist-upgrades are never automated.** The timer only patches guests
  and refreshes the host index; it *reports* pending host updates but applies them
  only when you run `--host` yourself. Take a snapshot or PBS backup first.
- Pulse is configured against a **read-only** Proxmox API token, never root.
- `unattended-upgrades` in guests is limited to the `-security` pocket and does
  **not** auto-reboot.
- The ntfy token and config file are `chmod 600`.

## Connecting Pulse to Proxmox (automatic)

The installer registers the host for you. After Pulse comes up it:

1. reads the one-time bootstrap token from CT 200 (`/etc/pulse/.bootstrap_token`),
2. runs Pulse's first-time security setup (`POST /api/security/quick-setup`),
   creating an `admin` login and an API token (both saved to `/etc/pmau/pmau.conf`,
   `chmod 600`),
3. mints a one-time setup token (`POST /api/setup-script-url`) and runs Pulse's
   generated **node setup script** on the host, which creates a **read-only**
   PVE token (`PVEAuditor`) and calls `POST /api/auto-register`.

No root credentials are ever stored in Pulse. When `Full setup` finishes, open
`http://<ct200-ip>:7655` and the node is already reporting.

**If auto-registration fails** (e.g. Pulse API not ready, or already configured),
the installer falls back to printing manual steps, and you can retry any time with
menu option **4 — Auto-register this host into Pulse**. Manual path: open the
dashboard, unlock with `pct exec 200 -- cat /etc/pulse/.bootstrap_token`, then in
**Settings → Nodes** click the auto-discovered host and run the generated script.

Your generated Pulse admin password is in `/etc/pmau/pmau.conf` (`PULSE_ADMIN_PASS`).

## Requirements

- Proxmox VE 8.x or 9.x (tested against 9.2 / Debian 13)
- Internet access from the host and from CT 200 (template + Pulse + ntfy)

## Uninstall

Menu option 10 removes the host components (timer, scripts, config). It does **not**
destroy CT 200/201 or modify your guests — remove a container manually with
`pct stop <ctid> && pct destroy <ctid>` if you want it gone.

## License

MIT — see [LICENSE](LICENSE).

> Not affiliated with Proxmox Server Solutions GmbH. Pulse is a separate project by
> [@rcourtman](https://github.com/rcourtman). Review the script before piping it to
> `bash` — as you should with any helper script.
