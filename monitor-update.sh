#!/usr/bin/env bash
# ==============================================================================
#  Proxmox Monitor & Updater (PMAU)
#  https://github.com/chaosrain/ProxmoxMonitorandUpdater
#
#  One-command installer (run on the PVE *host* as root):
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/chaosrain/ProxmoxMonitorandUpdater/main/monitor-update.sh)"
#
#  What it does:
#    * Creates CT 200 — an unprivileged Debian 13 "ops" LXC
#    * Installs Pulse (rcourtman/Pulse) inside CT 200 as the live dashboard
#    * Installs a host-side maintenance job (systemd timer) that patches all
#      guests, refreshes the host package index, and reports via ntfy
#    * Pushes unattended-upgrades into Debian/Ubuntu guests (defense in depth)
#    * Wires ntfy notifications
#
#  Design note (read this): an LXC cannot patch the PVE host or sibling guests.
#  All host/guest mutation therefore runs on the HOST via a systemd timer.
#  CT 200 is the dashboard + control surface, not the thing doing the patching.
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

# Colors
RD=$'\033[01;31m'; GN=$'\033[1;92m'; YW=$'\033[33m'; BL=$'\033[36m'; CL=$'\033[m'
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
UPDATE_HOST_AUTO="${UPDATE_HOST_AUTO:-no}"
PULSE_ADMIN_USER="${PULSE_ADMIN_USER:-}"
PULSE_ADMIN_PASS="${PULSE_ADMIN_PASS:-}"
PULSE_API_TOKEN="${PULSE_API_TOKEN:-}"
PMAU_PULSE_IP="${PMAU_PULSE_IP:-}"
EOF
  chmod 600 "${PMAU_CONF}"
}

# ---------------------------------------------------------------------------- #
#  Storage / network pickers
# ---------------------------------------------------------------------------- #
pick_storage() {
  local title="$1" content="$2" __out="$3"
  local opts=() s
  while read -r s; do [[ -n "$s" ]] && opts+=("$s" ""); done < <(pvesm status -content "$content" 2>/dev/null | awk 'NR>1{print $1}')
  [[ ${#opts[@]} -gt 0 ]] || die "No storage with content '${content}' found."
  if [[ ${#opts[@]} -eq 2 ]]; then
    printf -v "$__out" '%s' "${opts[0]}"; return 0
  fi
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
    PMAU_NET="dhcp"
    netcfg="name=eth0,bridge=${PMAU_BRIDGE},ip=dhcp"
  else
    local cidr gw
    cidr="$(whiptail --title "$APP" --inputbox "Static address (CIDR, e.g. 10.0.0.200/24):" 10 60 "" 3>&1 1>&2 2>&3)" || die "Cancelled."
    gw="$(whiptail --title "$APP" --inputbox "Gateway (e.g. 10.0.0.1):" 10 60 "" 3>&1 1>&2 2>&3)" || die "Cancelled."
    PMAU_NET="${cidr},${gw}"
    netcfg="name=eth0,bridge=${PMAU_BRIDGE},ip=${cidr},gw=${gw}"
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
  # wait for network
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
#  Install Pulse inside CT 200
# ---------------------------------------------------------------------------- #
install_pulse() {
  PMAU_CTID="${PMAU_CTID:-$PMAU_CTID_DEFAULT}"
  pct status "${PMAU_CTID}" >/dev/null 2>&1 || die "CT ${PMAU_CTID} does not exist. Create it first."
  pct start "${PMAU_CTID}" >/dev/null 2>&1 || true

  msg_info "Installing Pulse inside CT ${PMAU_CTID} (systemd mode)"
  # Pulse's installer detects it is running inside a container and installs a
  # systemd service rather than trying to create another LXC.
  pct exec "${PMAU_CTID}" -- bash -c \
    'export DEBIAN_FRONTEND=noninteractive; curl -fsSL https://raw.githubusercontent.com/rcourtman/Pulse/main/install.sh | bash' \
    >/dev/null 2>&1 || die "Pulse install failed (check 'pct exec ${PMAU_CTID} -- journalctl -u pulse')."
  msg_ok "Pulse installed"

  local ip
  ip="$(pct exec "${PMAU_CTID}" -- bash -c "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')"
  PMAU_PULSE_IP="${ip}"
  save_conf

  # Wait for the Pulse API to answer before attempting auto-registration.
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
own setup script — no root credentials were stored. Open the dashboard and
your node should already be reporting." 17 72
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
#  Flow: bootstrap token -> quick-setup (admin + API token)
#        -> setup-script-url (one-time token) -> run setup-script on host.
#  Returns non-zero on any failure so the caller can show manual steps.
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

  # Apply restart so auth/token are active (systemd deployment).
  curl -s -o /dev/null -X POST -H "X-API-Token: ${PULSE_API_TOKEN}" "${base}/api/security/apply-restart" >/dev/null 2>&1 || true
  local t=0
  until curl -fsS "${base}/api/health" >/dev/null 2>&1 || [[ $t -ge 20 ]]; do sleep 2; t=$((t+1)); done

  msg_info "Generating Pulse node setup script"
  local surl
  surl="$(curl -s -X POST -H "X-API-Token: ${PULSE_API_TOKEN}" -H 'Content-Type: application/json' \
        -d '{"type":"pve"}' "${base}/api/setup-script-url" 2>/dev/null)"
  local sutoken
  sutoken="$(printf '%s' "$surl" | jq -r '.token // .setupToken // .auth_token // .authToken // empty' 2>/dev/null)"
  if [[ -z "$sutoken" ]]; then
    # Some builds return a full URL; try to extract auth_token from it.
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
  # The script creates a PVE monitoring user + PVEAuditor token and calls
  # /api/auto-register back to Pulse. It runs here, on the PVE host.
  if bash "${setup_sh}" >/dev/null 2>&1; then
    rm -f "${setup_sh}"
    msg_ok "Host registered with Pulse (read-only)"
    return 0
  fi
  msg_warn "Setup script did not complete cleanly — verify in the Pulse UI"
  rm -f "${setup_sh}"
  return 1
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
args=(-s -o /dev/null -w '%{http_code}'
      -H "Title: ${title}" -H "Tags: ${tags}" -d "${msg}")
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
#   Default        : update all running LXC guests + refresh host index, report.
#   --host         : additionally apply host dist-upgrade (manual/intentional).
#   --dry-run      : show what would happen, change nothing.
# An LXC cannot do this to its siblings/host; that is why this lives on the host.
set -uo pipefail
CONF="/etc/pmau/pmau.conf"; [[ -f "$CONF" ]] && source "$CONF"
LOG="/var/log/pmau-update.log"
NOTIFY="/usr/local/bin/pmau-notify.sh"
DO_HOST="no"; DRY="no"
for a in "$@"; do
  case "$a" in
    --host) DO_HOST="yes" ;;
    --dry-run) DRY="yes" ;;
    *) echo "unknown arg: $a"; exit 2 ;;
  esac
done
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }
run() { if [[ "$DRY" == yes ]]; then log "DRY: $*"; else eval "$@"; fi; }

log "=== PMAU run start (host=$DO_HOST dry=$DRY) ==="
summary=""

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

# Patch every running LXC guest (skip self/ops container is optional)
ok=0; fail=0; failed_ids=""
while read -r ctid; do
  [[ -z "$ctid" ]] && continue
  ostype="$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^ostype/{print $2}')"
  case "$ostype" in
    debian|ubuntu|"")
      log "Updating CT ${ctid} (${ostype:-unknown})"
      if [[ "$DRY" == yes ]]; then
        log "DRY: pct exec ${ctid} -- apt-get update/upgrade"; ok=$((ok+1))
      elif pct exec "$ctid" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq dist-upgrade && apt-get -y -qq autoremove' >>"$LOG" 2>&1; then
        ok=$((ok+1))
      else
        fail=$((fail+1)); failed_ids+="${ctid} "
        log "CT ${ctid} FAILED"
      fi
      ;;
    *) log "Skipping CT ${ctid} (ostype=${ostype})" ;;
  esac
done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')

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

push_unattende