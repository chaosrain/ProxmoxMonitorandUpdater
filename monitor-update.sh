#!/usr/bin/env bash
# ==============================================================================
#  Proxmox Monitor & Updater (PMAU)
#  https://github.com/chaosrain/ProxmoxMonitorandUpdater
#
#  One-command installer (run on the PVE *host* as root):
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/chaosrain/ProxmoxMonitorandUpdater/main/monitor-update.sh)"
#
#  Creates CT 200 (Debian 13 ops LXC) + Pulse dashboard (auto-registers host),
#  a host-side maintenance timer (snapshots + guest patching + reporting),
#  unattended-upgrades in guests, ntfy notifications, and optional Beszel /
#  Prometheus+Grafana tiers.
#
#  An LXC cannot patch the PVE host or sibling guests, so all host/guest
#  mutation runs on the HOST via systemd timer. CT 200 is the dashboard/control
#  surface, not the patching engine.
#
#  License: MIT
# ==============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------- #
#  Constants / defaults
# ---------------------------------------------------------------------------- #
APP="Proxmox Monitor & Updater"
PMAU_CTID_DEFAULT="200"
PMAU_HOSTNAME="pmau"
PMAU_CONF_DIR="/etc/pmau"
PMAU_CONF="${PMAU_CONF_DIR}/pmau.conf"
PMAU_UPDATE_BIN="/usr/local/bin/pmau-update.sh"
PMAU_NOTIFY_BIN="/usr/local/bin/pmau-notify.sh"
PMAU_LOG="/var/log/pmau-update.log"
PULSE_PORT="7655"

RD=$'\033[01;31m'; GN=$'\033[1;92m'; YW=$'\033[33m'; CL=$'\033[m'
BFR="\\r\\033[K"; HOLD=" "; CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"

# ---------------------------------------------------------------------------- #
#  Logging helpers
# ---------------------------------------------------------------------------- #
msg_info()  { echo -ne " ${HOLD}${YW}${1}...${CL}"; }
msg_ok()    { echo -e  "${BFR} ${CM} ${GN}${1}${CL}"; }
msg_warn()  { echo -e  "${BFR} ${YW}!${CL} ${YW}${1}${CL}"; }
msg_error() { echo -e  "${BFR} ${CROSS} ${RD}${1}${CL}"; }

die() { msg_error "${1}"; exit "${2:-1}"; }
trap 'die "Aborted on line ${LINENO} (exit ${?}). Nothing further was changed." $?' ERR

header() {
  clear 2>/dev/null || true
  cat <<'EOF'
   ___  __  ___   ___   __ __
  / _ \/  |/  /  / _ | / / / /
 / ___/ /|_/ /  / __ |/ /_/ /
/_/  /_/  /_/  /_/ |_|\____/   Proxmox Monitor & Updater
EOF
  echo
}

# ---------------------------------------------------------------------------- #
#  Pre-flight checks
# ---------------------------------------------------------------------------- #
preflight() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this on the Proxmox host as root."
  command -v pveversion >/dev/null 2>&1 || die "pveversion not found — this must run on a Proxmox VE host."
  local ver; ver="$(pveversion | grep -oP 'pve-manager/\K[0-9]+' || echo 0)"
  [[ "${ver}" -ge 8 ]] || msg_warn "Detected PVE major ${ver}; tested on 8.x/9.x. Proceeding."
  if ! command -v whiptail >/dev/null 2>&1; then
    msg_info "Installing whiptail"
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq whiptail >/dev/null 2>&1
    msg_ok "Installed whiptail"
  fi
  mkdir -p "${PMAU_CONF_DIR}"
  [[ -f "${PMAU_CONF}" ]] && source "${PMAU_CONF}" || true
}

save_conf() {
  mkdir -p "${PMAU_CONF_DIR}"
  cat > "${PMAU_CONF}" <<EOF
# Proxmox Monitor & Updater — saved config ($(date -Is))
PMAU_CTID="${PMAU_CTID:-$PMAU_CTID_DEFAULT}"
PMAU_STORAGE="${PMAU_STORAGE:-}"
PMAU_TMPL_STORAGE="${PMAU_TMPL_STORAGE:-local}"
PMAU_BRIDGE="${PMAU_BRIDGE:-vmbr0}"
PMAU_NET="${PMAU_NET:-dhcp}"
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
PULSE_ADMIN_USER="${PULSE_ADMIN_USER:-}"
PULSE_ADMIN_PASS="${PULSE_ADMIN_PASS:-}"
PULSE_API_TOKEN="${PULSE_API_TOKEN:-}"
PMAU_PULSE_IP="${PMAU_PULSE_IP:-}"
SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-2}"
APP_UPDATES="${APP_UPDATES:-no}"
PROM_CTID="${PROM_CTID:-201}"
PROM_IP="${PROM_IP:-}"
BESZEL_IP="${BESZEL_IP:-}"
EOF
  chmod 600 "${PMAU_CONF}"
}

# ---------------------------------------------------------------------------- #
#  Storage picker
# ---------------------------------------------------------------------------- #
pick_storage() {
  local title="$1" content="$2" __out="$3"
  local opts=() s
  while read -r s; do [[ -n "$s" ]] && opts+=("$s" ""); done < <(pvesm status -content "$content" 2>/dev/null | awk 'NR>1{print $1}')
  [[ ${#opts[@]} -gt 0 ]] || die "No storage with content '${content}' found."
  if [[ ${#opts[@]} -eq 2 ]]; then printf -v "$__out" '%s' "${opts[0]}"; return 0; fi
  local choice
  choice="$(whiptail --title "$APP" --menu "$title" 16 70 8 "${opts[@]}" 3>&1 1>&2 2>&3)" || die "Cancelled."
  printf -v "$__out" '%s' "$choice"
}

# ---------------------------------------------------------------------------- #
#  Create CT 200
# ---------------------------------------------------------------------------- #
create_ct() {
  PMAU_CTID="${PMAU_CTID:-$PMAU_CTID_DEFAULT}"
  if pct status "${PMAU_CTID}" >/dev/null 2>&1; then
    die "CT ${PMAU_CTID} already exists. Choose 'Install/refresh Pulse' to target it, or destroy it first."
  fi

  pick_storage "Select storage for the container rootfs (rootdir):" "rootdir" PMAU_STORAGE
  pick_storage "Select storage that holds CT templates (vztmpl):"     "vztmpl"  PMAU_TMPL_STORAGE

  PMAU_BRIDGE="$(whiptail --title "$APP" --inputbox "Network bridge:" 10 60 "${PMAU_BRIDGE:-vmbr0}" 3>&1 1>&2 2>&3)" || die "Cancelled."

  local netcfg
  if whiptail --title "$APP" --yesno "Use DHCP for CT ${PMAU_CTID}?\n\n(No = enter a static address)" 11 60; then
    PMAU_NET="dhcp"; netcfg="name=eth0,bridge=${PMAU_BRIDGE},ip=dhcp"
  else
    local cidr gw
    cidr="$(whiptail --title "$APP" --inputbox "Static address (CIDR, e.g. 10.0.0.200/24):" 10 60 "" 3>&1 1>&2 2>&3)" || die "Cancelled."
    gw="$(whiptail --title "$APP" --inputbox "Gateway (e.g. 10.0.0.1):" 10 60 "" 3>&1 1>&2 2>&3)" || die "Cancelled."
    PMAU_NET="${cidr},${gw}"; netcfg="name=eth0,bridge=${PMAU_BRIDGE},ip=${cidr},gw=${gw}"
  fi

  msg_info "Refreshing template catalog"
  pveam update >/dev/null 2>&1 || true
  msg_ok "Template catalog refreshed"

  local tmpl
  tmpl="$(pveam available --section system 2>/dev/null | awk '/debian-13-standard/{print $2}' | sort -V | tail -1)"
  [[ -n "${tmpl}" ]] || die "No debian-13-standard template available via pveam."

  if ! pveam list "${PMAU_TMPL_STORAGE}" 2>/dev/null | grep -q "${tmpl}"; then
    msg_info "Downloading ${tmpl}"
    pveam download "${PMAU_TMPL_STORAGE}" "${tmpl}" >/dev/null 2>&1 || die "Template download failed."
    msg_ok "Downloaded ${tmpl}"
  fi
  local tmpl_ref="${PMAU_TMPL_STORAGE}:vztmpl/${tmpl}"

  msg_info "Creating CT ${PMAU_CTID} (${PMAU_HOSTNAME})"
  pct create "${PMAU_CTID}" "${tmpl_ref}" \
    --hostname "${PMAU_HOSTNAME}" \
    --cores 1 --memory 1024 --swap 512 \
    --rootfs "${PMAU_STORAGE}:8" \
    --unprivileged 1 --features nesting=0 \
    --net0 "${netcfg}" \
    --onboot 1 --tags "pmau,monitoring" >/dev/null 2>&1 \
    || die "pct create failed."
  msg_ok "Created CT ${PMAU_CTID}"

  msg_info "Starting CT ${PMAU_CTID}"
  pct start "${PMAU_CTID}" >/dev/null 2>&1 || die "pct start failed."
  sleep 5
  local tries=0
  until pct exec "${PMAU_CTID}" -- bash -c 'getent hosts deb.debian.org >/dev/null 2>&1' || [[ $tries -ge 15 ]]; do
    sleep 2; tries=$((tries+1))
  done
  msg_ok "CT ${PMAU_CTID} is up"

  msg_info "Updating CT base packages"
  pct exec "${PMAU_CTID}" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq dist-upgrade && apt-get install -y -qq curl ca-certificates' >/dev/null 2>&1
  msg_ok "CT base ready"

  save_conf
}

# ---------------------------------------------------------------------------- #
#  Install Pulse inside CT 200 (+ auto-register the host)
# ---------------------------------------------------------------------------- #
install_pulse() {
  PMAU_CTID="${PMAU_CTID:-$PMAU_CTID_DEFAULT}"
  pct status "${PMAU_CTID}" >/dev/null 2>&1 || die "CT ${PMAU_CTID} does not exist. Create it first."
  pct start "${PMAU_CTID}" >/dev/null 2>&1 || true

  msg_info "Installing Pulse inside CT ${PMAU_CTID} (systemd mode)"
  pct exec "${PMAU_CTID}" -- bash -c \
    'export DEBIAN_FRONTEND=noninteractive; curl -fsSL https://raw.githubusercontent.com/rcourtman/Pulse/main/install.sh | bash' \
    >/dev/null 2>&1 || die "Pulse install failed (check 'pct exec ${PMAU_CTID} -- journalctl -u pulse')."
  msg_ok "Pulse installed"

  local ip
  ip="$(pct exec "${PMAU_CTID}" -- bash -c "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')"
  PMAU_PULSE_IP="${ip}"
  save_conf

  local t=0
  until curl -fsS "http://${ip}:${PULSE_PORT}/api/health" >/dev/null 2>&1 || [[ $t -ge 20 ]]; do
    sleep 2; t=$((t+1))
  done

  if register_node; then
    whiptail --title "$APP" --msgbox \
"Pulse is installed in CT ${PMAU_CTID} and this host is auto-registered.

Dashboard : http://${ip}:${PULSE_PORT}
Login     : ${PULSE_ADMIN_USER}  (password saved in ${PMAU_CONF})

The Proxmox node was registered with a READ-ONLY token created by Pulse's
own setup script — no root credentials were stored." 16 72
  else
    whiptail --title "$APP" --msgbox \
"Pulse is installed in CT ${PMAU_CTID}, but automatic node registration did
not complete. Finish it from the UI:

  1. Open  http://${ip}:${PULSE_PORT}
  2. Unlock with the bootstrap token:
       pct exec ${PMAU_CTID} -- cat /etc/pulse/.bootstrap_token
  3. Settings > Nodes: your host should be auto-discovered. Click it and run
     the generated setup script on this host (creates a READ-ONLY token).

Do not give Pulse root." 18 74
  fi
}

# ---------------------------------------------------------------------------- #
#  Auto-register THIS Proxmox host into Pulse (read-only, no root stored)
# ---------------------------------------------------------------------------- #
register_node() {
  local ip="${PMAU_PULSE_IP}"
  [[ -n "$ip" ]] || { msg_warn "No Pulse IP known; skipping auto-register"; return 1; }
  local base="http://${ip}:${PULSE_PORT}"

  command -v jq      >/dev/null 2>&1 || apt-get install -y -qq jq      >/dev/null 2>&1 || true
  command -v openssl >/dev/null 2>&1 || apt-get install -y -qq openssl >/dev/null 2>&1 || true
  command -v jq >/dev/null 2>&1 || { msg_warn "jq unavailable; cannot parse Pulse API"; return 1; }

  local bt
  bt="$(pct exec "${PMAU_CTID}" -- cat /etc/pulse/.bootstrap_token 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$bt" ]]; then
    msg_warn "No bootstrap token (Pulse may already be configured); skipping auto-register"
    return 1
  fi

  msg_info "Pulse first-time security setup"
  PULSE_ADMIN_USER="admin"
  PULSE_ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)Aa1!"
  PULSE_API_TOKEN="$(openssl rand -hex 32)"
  local body code
  body="$(jq -nc --arg u "$PULSE_ADMIN_USER" --arg p "$PULSE_ADMIN_PASS" --arg t "$PULSE_API_TOKEN" \
        '{username:$u,password:$p,apiToken:$t,enableNotifications:false}')"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H "X-Setup-Token: ${bt}" -H 'Content-Type: application/json' \
        -d "$body" "${base}/api/security/quick-setup" || echo 000)"
  if [[ ! "$code" =~ ^2 ]]; then
    msg_warn "quick-setup HTTP ${code} — leaving Pulse for manual setup"
    return 1
  fi
  save_conf
  msg_ok "Pulse admin + API token configured"

  curl -s -o /dev/null -X POST -H "X-API-Token: ${PULSE_API_TOKEN}" "${base}/api/security/apply-restart" >/dev/null 2>&1 || true
  local t=0
  until curl -fsS "${base}/api/health" >/dev/null 2>&1 || [[ $t -ge 20 ]]; do sleep 2; t=$((t+1)); done

  msg_info "Generating Pulse node setup script"
  local surl sutoken
  surl="$(curl -s -X POST -H "X-API-Token: ${PULSE_API_TOKEN}" -H 'Content-Type: application/json' \
        -d '{"type":"pve"}' "${base}/api/setup-script-url" 2>/dev/null)"
  sutoken="$(printf '%s' "$surl" | jq -r '.token // .setupToken // .auth_token // .authToken // empty' 2>/dev/null)"
  if [[ -z "$sutoken" ]]; then
    sutoken="$(printf '%s' "$surl" | grep -oE 'auth_token=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2)"
  fi
  if [[ -z "$sutoken" ]]; then
    msg_warn "Could not obtain a setup token from Pulse — finish node add in the UI"
    return 1
  fi
  msg_ok "Setup token obtained"

  msg_info "Registering this host with Pulse (read-only token)"
  local setup_sh="/tmp/pmau-pulse-setup.sh"
  if ! curl -fsSL "${base}/api/setup-script?auth_token=${sutoken}" -o "${setup_sh}" 2>/dev/null; then
    msg_warn "Could not download setup script — finish node add in the UI"
    return 1
  fi
  if bash "${setup_sh}" >/dev/null 2>&1; then
    rm -f "${setup_sh}"; msg_ok "Host registered with Pulse (read-only)"; return 0
  fi
  msg_warn "Setup script did not complete cleanly — verify in the Pulse UI"
  rm -f "${setup_sh}"; return 1
}

# ---------------------------------------------------------------------------- #
#  ntfy notifications
# ---------------------------------------------------------------------------- #
configure_ntfy() {
  NTFY_URL="$(whiptail --title "$APP" --inputbox "ntfy server base URL:" 10 64 "${NTFY_URL:-https://ntfy.sh}" 3>&1 1>&2 2>&3)" || die "Cancelled."
  NTFY_TOPIC="$(whiptail --title "$APP" --inputbox "ntfy topic (keep it unguessable):" 10 64 "${NTFY_TOPIC:-pmau-$(hostname -s)-$RANDOM}" 3>&1 1>&2 2>&3)" || die "Cancelled."
  NTFY_TOKEN="$(whiptail --title "$APP" --inputbox "ntfy access token (optional, blank for none):" 10 64 "${NTFY_TOKEN:-}" 3>&1 1>&2 2>&3)" || true
  save_conf
  write_notify_bin
  msg_info "Sending test notification"
  "${PMAU_NOTIFY_BIN}" "PMAU" "Test notification from $(hostname -f)" "white_check_mark" && msg_ok "Test sent to ${NTFY_URL%/}/${NTFY_TOPIC}" || msg_warn "Test send failed — verify URL/topic/token"
}

write_notify_bin() {
  cat > "${PMAU_NOTIFY_BIN}" <<'EOF'
#!/usr/bin/env bash
# pmau-notify.sh <title> <message> [tags]  — sends an ntfy push.
set -euo pipefail
CONF="/etc/pmau/pmau.conf"; [[ -f "$CONF" ]] && source "$CONF"
[[ -n "${NTFY_URL:-}" && -n "${NTFY_TOPIC:-}" ]] || { echo "ntfy not configured"; exit 0; }
title="${1:-PMAU}"; msg="${2:-}"; tags="${3:-information_source}"
args=(-s -o /dev/null -w '%{http_code}' -H "Title: ${title}" -H "Tags: ${tags}" -d "${msg}")
[[ -n "${NTFY_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
code="$(curl "${args[@]}" "${NTFY_URL%/}/${NTFY_TOPIC}" || echo 000)"
[[ "$code" =~ ^2 ]]
EOF
  chmod 700 "${PMAU_NOTIFY_BIN}"
}

# ---------------------------------------------------------------------------- #
#  Host-side updater (systemd timer) + unattended-upgrades in guests
# ---------------------------------------------------------------------------- #
write_update_bin() {
  cat > "${PMAU_UPDATE_BIN}" <<'EOF'
#!/usr/bin/env bash
# pmau-update.sh  — host-side maintenance.
#   (default)  : snapshot + update all running LXC guests + refresh host index.
#   --host     : additionally apply host dist-upgrade (manual/intentional).
#   --apply    : apply for real even on the first run (bypass first-run dry-run).
#   --dry-run  : show what would happen, change nothing.
# An LXC cannot do this to its siblings/host; that is why this lives on the host.
set -uo pipefail
CONF="/etc/pmau/pmau.conf"; [[ -f "$CONF" ]] && source "$CONF"
LOG="/var/log/pmau-update.log"
NOTIFY="/usr/local/bin/pmau-notify.sh"
DO_HOST="no"; DRY="no"; FORCE_APPLY="no"
for a in "$@"; do
  case "$a" in
    --host) DO_HOST="yes" ;;
    --dry-run) DRY="yes" ;;
    --apply) FORCE_APPLY="yes" ;;
    *) echo "unknown arg: $a"; exit 2 ;;
  esac
done

# First-run safety: the very first maintenance run is forced to dry-run so you
# can see what it would do. A marker is then written; subsequent runs apply.
FIRST_RUN_MARKER="/etc/pmau/.maintenance-ran"
FIRST_RUN_NOTE=""
if [[ ! -f "$FIRST_RUN_MARKER" && "$FORCE_APPLY" != yes && "$DRY" != yes ]]; then
  DRY="yes"
  FIRST_RUN_NOTE="FIRST RUN forced to dry-run — re-run with --apply (or wait for the next scheduled run) to apply for real."
fi
mkdir -p /etc/pmau 2>/dev/null || true
touch "$FIRST_RUN_MARKER" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }
run() { if [[ "$DRY" == yes ]]; then log "DRY: $*"; else eval "$@"; fi; }

SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-2}"
# Snapshot a guest before patching, then prune old PMAU snapshots.
snap_guest() {
  [[ "${SNAPSHOT_KEEP:-2}" -gt 0 ]] || { log "Snapshots disabled (SNAPSHOT_KEEP=0)"; return 0; }
  local id="$1" name; name="pmau_pre_$(date +%Y%m%d%H%M%S)"
  if pct snapshot "$id" "$name" --description "PMAU pre-update" >>"$LOG" 2>&1; then
    log "CT $id snapshot $name created"
  else
    log "CT $id snapshot skipped (storage may not support snapshots) — continuing"
    return 0
  fi
  local snaps; mapfile -t snaps < <(pct listsnapshot "$id" 2>/dev/null | grep -oE 'pmau_pre_[0-9]+' | sort -u)
  local excess=$(( ${#snaps[@]} - SNAPSHOT_KEEP )) i
  for ((i=0; i<excess; i++)); do
    pct delsnapshot "$id" "${snaps[$i]}" >>"$LOG" 2>&1 && log "CT $id pruned old snapshot ${snaps[$i]}"
  done
}

log "=== PMAU run start (host=$DO_HOST dry=$DRY) ==="
summary=""
if [[ -n "$FIRST_RUN_NOTE" ]]; then log "$FIRST_RUN_NOTE"; summary+="${FIRST_RUN_NOTE}"$'\n'; fi

# Refresh host package index (safe; does not upgrade)
run "apt-get update -qq" >/dev/null 2>&1
host_pending="$(apt-get -s dist-upgrade 2>/dev/null | grep -c '^Inst' || true)"; host_pending="${host_pending:-0}"
summary+="Host: ${host_pending} updates pending"$'\n'
log "Host updates pending: ${host_pending}"

if [[ "$DO_HOST" == yes ]]; then
  log "Applying host dist-upgrade"
  run "DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade" 2>&1 | tee -a "$LOG"
  summary+="Host: dist-upgrade applied"$'\n'
fi

# Patch every running LXC guest
ok=0; fail=0; failed_ids=""
while read -r ctid; do
  [[ -z "$ctid" ]] && continue
  ostype="$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^ostype/{print $2}')"
  case "$ostype" in
    debian|ubuntu|"")
      log "Updating CT ${ctid} (${ostype:-unknown})"
      if [[ "$DRY" == yes ]]; then
        log "DRY: snapshot + apt update/dist-upgrade for CT ${ctid}"; ok=$((ok+1))
      else
        snap_guest "$ctid"
        if pct exec "$ctid" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq dist-upgrade && apt-get -y -qq autoremove' >>"$LOG" 2>&1; then
          ok=$((ok+1))
        else
          fail=$((fail+1)); failed_ids+="${ctid} "
          log "CT ${ctid} FAILED"
        fi
      fi
      ;;
    *) log "Skipping CT ${ctid} (ostype=${ostype})" ;;
  esac
done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')

# Optional: community-scripts app-level updates (for community-built containers)
if [[ "${APP_UPDATES:-no}" == yes && "$DRY" != yes ]]; then
  log "Running community-scripts update-apps (app-level updates)"
  if curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-apps.sh -o /tmp/pmau-update-apps.sh 2>>"$LOG"; then
    if var_backup=no var_container=all_running var_unattended=yes var_skip_confirm=yes var_auto_reboot=no \
         bash /tmp/pmau-update-apps.sh >>"$LOG" 2>&1; then
      log "update-apps completed"; summary+="App updates: completed"$'\n'
    else
      log "update-apps returned non-zero"; summary+="App updates: see log"$'\n'
    fi
    rm -f /tmp/pmau-update-apps.sh
  else
    log "Could not download update-apps.sh"
  fi
fi

summary+="Guests updated OK: ${ok}, failed: ${fail}"$'\n'
[[ -n "$failed_ids" ]] && summary+="Failed CTs: ${failed_ids}"$'\n'
log "Guests OK=${ok} FAIL=${fail} ${failed_ids}"
log "=== PMAU run end ==="

if [[ -x "$NOTIFY" ]]; then
  if [[ "$fail" -gt 0 ]]; then
    "$NOTIFY" "PMAU: updates done ($(hostname -s))" "$summary" "warning" || true
  else
    "$NOTIFY" "PMAU: updates done ($(hostname -s))" "$summary" "white_check_mark" || true
  fi
fi
EOF
  chmod 700 "${PMAU_UPDATE_BIN}"
}

push_unattended_upgrades() {
  msg_info "Enabling unattended-upgrades in Debian/Ubuntu guests"
  local ctid ostype
  while read -r ctid; do
    [[ -z "$ctid" ]] && continue
    ostype="$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^ostype/{print $2}')"
    case "$ostype" in
      debian|ubuntu)
        pct exec "$ctid" -- bash -c '
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq >/dev/null 2>&1
          apt-get install -y -qq unattended-upgrades >/dev/null 2>&1
          cat > /etc/apt/apt.conf.d/20auto-upgrades <<CFG
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CFG
        ' >/dev/null 2>&1 || msg_warn "CT ${ctid}: unattended-upgrades step skipped"
        ;;
    esac
  done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
  msg_ok "unattended-upgrades configured in guests"
}

install_updater() {
  write_notify_bin
  write_update_bin

  local sched
  sched="$(whiptail --title "$APP" --inputbox \
"systemd OnCalendar schedule for guest updates:\n\n  Sun *-*-* 03:00:00  -> weekly (recommended)\n  daily               -> every day\n  *-*-* 03:00         -> daily at 03:00" \
14 64 "Sun *-*-* 03:00:00" 3>&1 1>&2 2>&3)" || die "Cancelled."

  cat > /etc/systemd/system/pmau-update.service <<EOF
[Unit]
Description=PMAU host-side guest/host maintenance
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PMAU_UPDATE_BIN}
EOF

  cat > /etc/systemd/system/pmau-update.timer <<EOF
[Unit]
Description=Run PMAU maintenance on a schedule

[Timer]
OnCalendar=${sched}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now pmau-update.timer >/dev/null 2>&1
  msg_ok "Installed pmau-update.timer (${sched})"

  SNAPSHOT_KEEP="$(whiptail --title "$APP" --inputbox \
"Pre-update snapshots to keep per guest (0 disables snapshots).\n\nEach run snapshots a guest before patching, so a broken update can be\nrolled back with: pct rollback <ctid> <snapname>" \
13 70 "${SNAPSHOT_KEEP:-2}" 3>&1 1>&2 2>&3)" || SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-2}"

  if whiptail --title "$APP" --yesno \
"Also run community-scripts 'update-apps' during maintenance?\n\nUpdates the APPLICATIONS inside community-script-built containers\n(not just the OS). Runs unattended, no auto-reboot." 12 70; then
    APP_UPDATES="yes"
  else
    APP_UPDATES="no"
  fi

  if whiptail --title "$APP" --yesno "Also enable unattended-upgrades (security patches) inside each Debian/Ubuntu guest now?" 10 64; then
    push_unattended_upgrades
  fi
  save_conf
}

# ---------------------------------------------------------------------------- #
#  Beszel — lightweight monitoring for NON-Proxmox hosts (UniFi, NAS, Pis)
# ---------------------------------------------------------------------------- #
install_beszel() {
  PMAU_CTID="${PMAU_CTID:-$PMAU_CTID_DEFAULT}"
  pct status "${PMAU_CTID}" >/dev/null 2>&1 || die "CT ${PMAU_CTID} does not exist. Create it first (option 2)."
  pct start "${PMAU_CTID}" >/dev/null 2>&1 || true

  msg_info "Installing Beszel hub in CT ${PMAU_CTID} (systemd, port 8090)"
  pct exec "${PMAU_CTID}" -- bash -c \
    'export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq curl >/dev/null 2>&1; curl -sL https://get.beszel.dev/hub -o /tmp/install-hub.sh && chmod +x /tmp/install-hub.sh && /tmp/install-hub.sh' \
    >/dev/null 2>&1 || die "Beszel hub install failed (pct exec ${PMAU_CTID} -- journalctl -u beszel)."
  msg_ok "Beszel hub installed"

  BESZEL_IP="$(pct exec "${PMAU_CTID}" -- bash -c "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')"
  save_conf

  whiptail --title "$APP" --msgbox \
"Beszel hub is running in CT ${PMAU_CTID}.

  Dashboard: http://${BESZEL_IP}:8090

First visit creates the admin account. To monitor a host (UniFi box, NAS,
Pi, the PVE host itself): in the hub UI click 'Add System' — it shows the
exact agent install command (with key + token) to run on that host.

Beszel agents talk OUT to the hub, so no inbound ports on the agents." 17 74
}

# ---------------------------------------------------------------------------- #
#  Prometheus + Grafana + pve-exporter (historical-metrics power tier)
#  EXPERIMENTAL / heavy: dedicated LXC (CT 201).
# ---------------------------------------------------------------------------- #
install_prometheus_stack() {
  PROM_CTID="${PROM_CTID:-201}"
  if pct status "${PROM_CTID}" >/dev/null 2>&1; then
    die "CT ${PROM_CTID} already exists. Destroy it or set a different PROM_CTID in ${PMAU_CONF}."
  fi
  whiptail --title "$APP" --yesno \
"This builds a SEPARATE container (CT ${PROM_CTID}) running Prometheus +
Grafana + pve-exporter for long-term metrics. It's the heavy tier and is
marked experimental — expect to tweak. Continue?" 12 72 || return 0

  [[ -n "${PMAU_STORAGE:-}"      ]] || pick_storage "rootfs storage (rootdir):" "rootdir" PMAU_STORAGE
  [[ -n "${PMAU_TMPL_STORAGE:-}" ]] || pick_storage "template storage (vztmpl):" "vztmpl" PMAU_TMPL_STORAGE
  PMAU_BRIDGE="${PMAU_BRIDGE:-vmbr0}"

  pveam update >/dev/null 2>&1 || true
  local tmpl; tmpl="$(pveam available --section system 2>/dev/null | awk '/debian-13-standard/{print $2}' | sort -V | tail -1)"
  [[ -n "$tmpl" ]] || die "No debian-13-standard template available."
  pveam list "${PMAU_TMPL_STORAGE}" 2>/dev/null | grep -q "$tmpl" || pveam download "${PMAU_TMPL_STORAGE}" "$tmpl" >/dev/null 2>&1 || die "Template download failed."

  msg_info "Creating CT ${PROM_CTID} (prometheus-grafana)"
  pct create "${PROM_CTID}" "${PMAU_TMPL_STORAGE}:vztmpl/${tmpl}" \
    --hostname prom-grafana --cores 2 --memory 2048 --swap 512 \
    --rootfs "${PMAU_STORAGE}:12" --unprivileged 1 --features nesting=0 \
    --net0 "name=eth0,bridge=${PMAU_BRIDGE},ip=dhcp" --onboot 1 --start 1 \
    --tags "pmau,monitoring" >/dev/null 2>&1 || die "pct create ${PROM_CTID} failed."
  sleep 5
  local t=0
  until pct exec "${PROM_CTID}" -- bash -c 'getent hosts deb.debian.org >/dev/null 2>&1' || [[ $t -ge 15 ]]; do sleep 2; t=$((t+1)); done
  PROM_IP="$(pct exec "${PROM_CTID}" -- bash -c "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')"
  msg_ok "Created CT ${PROM_CTID} (${PROM_IP})"

  msg_info "Creating read-only PVE token for pve-exporter"
  local host_ip; host_ip="$(hostname -I | awk '{print $1}')"
  pveum user add pmau-exporter@pve --comment "PMAU Prometheus exporter (read-only)" >/dev/null 2>&1 || true
  pveum acl modify / -user pmau-exporter@pve -role PVEAuditor >/dev/null 2>&1 || true
  local tok; tok="$(pveum user token add pmau-exporter@pve prometheus --privsep 0 --output-format json 2>/dev/null | grep -oE '"value"[: ]+"[^"]+"' | sed -E 's/.*"value"[: ]+"([^"]+)".*/\1/')"
  [[ -n "$tok" ]] || msg_warn "Token may already exist; recreate with: pveum user token remove pmau-exporter@pve prometheus"
  msg_ok "PVE token ready"

  msg_info "Installing exporter + Prometheus + Grafana in CT ${PROM_CTID}"
  pct exec "${PROM_CTID}" -- bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq python3-venv python3-pip apt-transport-https software-properties-common wget gpg curl tar >/dev/null
    python3 -m venv /opt/pve-exporter
    /opt/pve-exporter/bin/pip -q install --upgrade pip prometheus-pve-exporter >/dev/null
    mkdir -p /etc/prometheus
    cat > /etc/prometheus/pve.yml <<CFG
default:
  user: pmau-exporter@pve
  token_name: prometheus
  token_value: ${tok}
  verify_ssl: false
CFG
    chmod 640 /etc/prometheus/pve.yml
    cat > /etc/systemd/system/prometheus-pve-exporter.service <<UNIT
[Unit]
Description=Prometheus PVE Exporter
After=network-online.target
[Service]
ExecStart=/opt/pve-exporter/bin/pve_exporter --config.file /etc/prometheus/pve.yml --web.listen-address 0.0.0.0:9221
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now prometheus-pve-exporter >/dev/null 2>&1
    # Prometheus from upstream binary (Debian's apt package is being autoremoved)
    PVER=\$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/prometheus/prometheus/releases/latest | sed -E 's#.*/v##')
    curl -fsSL \"https://github.com/prometheus/prometheus/releases/download/v\${PVER}/prometheus-\${PVER}.linux-amd64.tar.gz\" -o /tmp/prom.tgz
    tar -xzf /tmp/prom.tgz -C /tmp
    install -m755 /tmp/prometheus-\${PVER}.linux-amd64/prometheus /usr/local/bin/prometheus
    install -m755 /tmp/prometheus-\${PVER}.linux-amd64/promtool  /usr/local/bin/promtool
    id prometheus >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
    mkdir -p /etc/prometheus /var/lib/prometheus
    chown -R prometheus:prometheus /var/lib/prometheus
    cat > /etc/systemd/system/prometheus.service <<UNIT2
[Unit]
Description=Prometheus
After=network-online.target
[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus
Restart=always
[Install]
WantedBy=multi-user.target
UNIT2
    cat > /etc/prometheus/prometheus.yml <<CFG
global:
  scrape_interval: 30s
scrape_configs:
  - job_name: pve
    metrics_path: /pve
    params:
      module: [default]
    static_configs:
      - targets: ['${host_ip}:8006']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9221
CFG
    chown -R prometheus:prometheus /etc/prometheus
    systemctl daemon-reload
    systemctl enable --now prometheus >/dev/null 2>&1 || true
    mkdir -p /etc/apt/keyrings
    wget -qO- https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main' > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
    apt-get install -y -qq grafana >/dev/null
    mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
    cat > /etc/grafana/provisioning/datasources/prometheus.yml <<CFG
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
CFG
    cat > /etc/grafana/provisioning/dashboards/pmau.yml <<CFG
apiVersion: 1
providers:
  - name: PMAU
    folder: Proxmox
    type: file
    options:
      path: /var/lib/grafana/dashboards
CFG
    curl -fsSL 'https://grafana.com/api/dashboards/10347/revisions/latest/download' -o /var/lib/grafana/dashboards/proxmox-10347.json 2>/dev/null || true
    systemctl enable --now grafana-server >/dev/null 2>&1
  " >/dev/null 2>&1 || msg_warn "Stack install hit an error — check 'pct exec ${PROM_CTID} -- journalctl -xe'"
  save_conf
  msg_ok "Prometheus/Grafana stack deployed"

  whiptail --title "$APP" --msgbox \
"Prometheus + Grafana + pve-exporter are in CT ${PROM_CTID}.

  Grafana   : http://${PROM_IP}:3000   (default login admin/admin)
  Prometheus: http://${PROM_IP}:9090
  Exporter  : http://${PROM_IP}:9221/pve?target=${host_ip}:8006

A 'Proxmox' folder with the imported dashboard should appear in Grafana.
If the dashboard's datasource is empty, set it to 'Prometheus' once.

EXPERIMENTAL: if metrics are missing, verify the exporter token and the
Prometheus target on the host (${host_ip}:8006)." 19 76
}

# ---------------------------------------------------------------------------- #
#  Uninstall
# ---------------------------------------------------------------------------- #
uninstall() {
  whiptail --title "$APP" --yesno "Remove PMAU host components (timer, scripts, conf)?\n\nThis does NOT destroy CT ${PMAU_CTID:-200} or touch your guests." 12 64 || return 0
  systemctl disable --now pmau-update.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/pmau-update.service /etc/systemd/system/pmau-update.timer "${PMAU_UPDATE_BIN}" "${PMAU_NOTIFY_BIN}"
  systemctl daemon-reload
  msg_ok "Host components removed (CT and conf left intact)"
}

# ---------------------------------------------------------------------------- #
#  Full setup
# ---------------------------------------------------------------------------- #
full_setup() {
  create_ct
  install_pulse
  configure_ntfy
  install_updater
  whiptail --title "$APP" --msgbox \
"Setup complete.

Dashboard : http://${PMAU_PULSE_IP:-<ct-ip>}:${PULSE_PORT}
Updater   : systemctl list-timers pmau-update.timer
Run now   : ${PMAU_UPDATE_BIN}            (first run = dry-run)
Apply now : ${PMAU_UPDATE_BIN} --apply
Host patch: ${PMAU_UPDATE_BIN} --host     (intentional host upgrade)
Logs      : ${PMAU_LOG}
Config    : ${PMAU_CONF}

Reminder: host kernel upgrades are deliberately NOT automated.
Snapshot/back up before running with --host." 20 72
}

# ---------------------------------------------------------------------------- #
#  Main menu
# ---------------------------------------------------------------------------- #
main_menu() {
  while true; do
    local choice
    choice="$(whiptail --title "$APP" --menu "Select an action:" 22 74 12 \
      "1"  "Full setup (CT 200 + Pulse + auto-register + ntfy + updater)" \
      "2"  "Create CT 200 only" \
      "3"  "Install / refresh Pulse in CT 200" \
      "4"  "Auto-register this host into Pulse" \
      "5"  "Configure ntfy notifications" \
      "6"  "Install / update the maintenance timer (snapshots, app-updates)" \
      "7"  "Run maintenance now (guests + host index)" \
      "8"  "Install Beszel hub (monitor non-Proxmox hosts)" \
      "9"  "Install Prometheus + Grafana stack (experimental)" \
      "10" "Uninstall host components" \
      "11" "Quit" \
      3>&1 1>&2 2>&3)" || exit 0
    case "$choice" in
      1) full_setup ;;
      2) create_ct; msg_ok "CT created. Use option 3 to install Pulse." ;;
      3) install_pulse ;;
      4) [[ -n "${PMAU_PULSE_IP:-}" ]] || PMAU_PULSE_IP="$(pct exec "${PMAU_CTID:-$PMAU_CTID_DEFAULT}" -- bash -c "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')"
         if register_node; then msg_ok "Registered. Open http://${PMAU_PULSE_IP}:${PULSE_PORT}"; else msg_warn "Auto-register did not complete; see the on-screen manual steps."; fi ;;
      5) configure_ntfy ;;
      6) install_updater ;;
      7) [[ -x "${PMAU_UPDATE_BIN}" ]] && "${PMAU_UPDATE_BIN}" || die "Updater not installed (option 6 first)." ;;
      8) install_beszel ;;
      9) install_prometheus_stack ;;
      10) uninstall ;;
      11) exit 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------- #
#  Self-check
#  - From a file: syntax-validate ourselves with `bash -n` and abort on error.
#  - Via curl|bash: no file to check; the only top-level statement is the final
#    main "$@", so a truncated download executes nothing (fail-safe).
# ---------------------------------------------------------------------------- #
self_check() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -f "$src" ]]; then
    if ! bash -n "$src" 2>/tmp/pmau_selfcheck.err; then
      msg_error "Self-check failed — script has a syntax error:"
      cat /tmp/pmau_selfcheck.err >&2
      exit 1
    fi
    msg_ok "Self-check passed (syntax OK)"
  fi
}

main() {
  header
  self_check
  preflight
  main_menu
}

# Single top-level entrypoint. Keep this as the LAST line: a truncated piped
# download never reaches here, so no partial run occurs.
main "$@"
