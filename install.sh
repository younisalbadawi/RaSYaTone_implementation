#!/usr/bin/env bash
# RaSYaTone local installer
# Run: sudo bash ./install.sh  (or: chmod +x ./install.sh && ./install.sh)
#
# Menu:
#   1) PRE-CHECK DB install prerequisites
#   2) PRE-CHECK App install prerequisites
#   3) Install PostgreSQL database
#   4) Install RaSYaTone application server
#   Q) Quit
#
# Tested package managers: apt (Debian/Ubuntu/Raspbian), dnf (RHEL/Rocky/Alma/Fedora), apk (Alpine)
#
# Non-interactive CLI flags (for CI/automation):
#   bash install.sh --precheck-db     # run option 1, exit with precheck rc
#   bash install.sh --precheck-app    # run option 2, exit with precheck rc
#   bash install.sh --install-db      # run option 3 interactive prompts then exit
#   bash install.sh --install-app     # run option 4 interactive prompts then exit
#
# --- VERSION STAMP (server copy cross-check: run: grep 'SCRIPT_VERSION_BUILD=' install.sh) ---
SCRIPT_VERSION_BUILD="2026-08-03T2015-fix-default-ALL-pg-hba"
EXPECTED_VERSION_MARKER="$SCRIPT_VERSION_BUILD"

# --- BANNER: runs FIRST, before set -e, before any logic, impossible to miss.
printf "\n\033[1;97m=======================================================\033[0m\n"
printf "\033[1;97m RaSYaTone Installer — build stamp: %s\033[0m\n" "$SCRIPT_VERSION_BUILD"
printf "\033[1;97m Expected marker:          %s\033[0m\n"           "$EXPECTED_VERSION_MARKER"
if command -v sha256sum >/dev/null 2>&1; then
  _s=$(sha256sum "$0" 2>/dev/null | awk '{print $1}')
  [ -n "${_s:-}" ] && printf "\033[1;37m SHA256: %s\033[0m\n" "$_s"
elif command -v shasum >/dev/null 2>&1; then
  _s=$(shasum -a 256 "$0" 2>/dev/null | awk '{print $1}')
  [ -n "${_s:-}" ] && printf "\033[1;37m SHA256: %s\033[0m\n" "$_s"
fi
printf "\033[1;97m=======================================================\033[0m\n"
printf "If build stamp above is NOT exactly:  %s\n"         "$EXPECTED_VERSION_MARKER"
printf "=> your server copy is OUTDATED. Re-copy install.sh from local Windows machine NOW.\n\n"

set -euo pipefail
umask 022

# --- global defaults --------------------------------------------------------
ENV_DIR="/etc/rasyatone/static"
ENV_FILE="${ENV_DIR}/rasyatone.env"
DEF_DB_NAME="rasyatone_db"
DEF_DB_USER="rasyatone_db_user"
DEF_DB_HOST="localhost"
DEF_DB_PORT="5432"
DEF_LISTEN_ADDRESSES="*"
DEF_APP_DIR="/opt/rasyatone"
DEF_GIT_BRANCH="main"
DEF_DJANGO_SETTINGS="rasyatone.settings"
DEF_GUNICORN_BIND="0.0.0.0:8000"
DEF_SERVICE="rasyatone"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=10

# --- tiny helpers -----------------------------------------------------------
_ok()   { printf "  \033[92m[ OK ]\033[0m %s\n" "$*"; }
_nok()  { printf "  \033[91m[FAIL]\033[0m %s\n" "$*"; return 1; }
_warn() { printf "  \033[93m[WARN]\033[0m %s\n" "$*"; }
_die()  { printf "\n\033[91mERROR:\033[0m %s\n" "$*" >&2; exit 1; }
_section(){ printf "\n\033[1;97m=== %s ===\033[0m\n" "$*"; }

prompt_def() {
  local text="$1" def="${2:-}" val=""
  if [ -n "$def" ]; then printf "%s [%s]: " "$text" "$def" >&2
  else printf "%s: " "$text" >&2; fi
  IFS= read -r val || true
  if [ -z "${val:-}" ]; then printf "%s" "$def"
  else printf "%s" "$val"; fi
}

prompt_secret() {
  local text="$1" def="${2:-}" val=""
  if [ -n "$def" ]; then printf "%s (Enter=keep current, type new value to overwrite, no echo): " "$text" >&2
  else printf "%s (no echo, required): " "$text" >&2; fi
  stty -echo 2>/dev/null || true
  IFS= read -r val || true
  stty echo 2>/dev/null || true
  printf "\n" >&2
  if [ -z "${val:-}" ]; then
    if [ -z "$def" ]; then _die "Empty value with no default not allowed: $text"; fi
    printf "%s" "$def"
  else printf "%s" "$val"; fi
}

confirm_yn() {
  local prompt="$1" def="${2:-n}" val=""
  if [ "$def" = "y" ] || [ "$def" = "Y" ]; then printf "%s [Y/n]: " "$prompt" >&2
  else printf "%s [y/N]: " "$prompt" >&2; fi
  IFS= read -r val || val=""
  val=$(printf "%s" "${val:-$def}" | tr '[:upper:]' '[:lower:]' | cut -c1)
  [ "$val" = "y" ]
}
# prompt_yn: same confirm_yn but returns literal "y"/"n" (for $() capture, not boolean exit code)
prompt_yn() {
  if confirm_yn "$@"; then printf "y"; else printf "n"; fi
}

# --- package manager auto-detect --------------------------------------------
declare -g PM="" PKG_INSTALL="" PKG_UPDATE=""
detect_pm() {
  if [ -n "$PM" ]; then return 0; fi
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"; PKG_UPDATE="apt-get update -qq"; PKG_INSTALL="apt-get install -y -qq"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"; PKG_UPDATE="dnf -q check-update || true"; PKG_INSTALL="dnf install -y -q"
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"; PKG_UPDATE="apk update -q"; PKG_INSTALL="apk add -q"
  else
    _die "Could not detect package manager (apt/dnf/apk). Install prerequisites manually first."
  fi
}

service_control() {
  local action="$1" name="${2:-postgresql}"
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl "$action" "$name" 2>/dev/null || sudo systemctl "$action" "postgresql" 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    sudo rc-service "$name" "$action" 2>/dev/null || sudo rc-service postgresql "$action" 2>/dev/null || true
  elif command -v rc-update >/dev/null 2>&1; then
    sudo rc-service "$name" "$action" 2>/dev/null || true
  else
    _warn "No systemctl/rc-service; service '$action $name' must be run manually"
  fi
}

# --- firewall helpers: auto-detect ufw / firewalld / generic iptables -------------
# Safety rule: SSH (22/TCP) is ALWAYS opened BEFORE enabling any firewall, so user
# isn't locked out of their SSH session on a remote server.
firewall_detect() {
  if command -v ufw >/dev/null 2>&1; then
    FW_BACKEND="ufw"; return 0
  elif command -v firewall-cmd >/dev/null 2>&1; then
    FW_BACKEND="firewalld"; return 0
  elif command -v iptables >/dev/null 2>&1; then
    FW_BACKEND="iptables"; return 0
  fi
  FW_BACKEND="none"; return 1
}

firewall_install_and_enable() {
  # Installs firewall package if missing; enables it. Returns 0 on success.
  # After this call, SSH port 22/TCP is guaranteed open and firewall is active.
  firewall_detect || true
  case "$FW_BACKEND" in
    ufw)
      if ! command -v ufw >/dev/null 2>&1; then
        _section "Installing ufw firewall package via $PM"
        $PKG_UPDATE >/dev/null || true
        $PKG_INSTALL ufw >/dev/null 2>&1 || return 1
      fi
      # CRITICAL: allow SSH BEFORE enabling the firewall
      sudo ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1 || true
      sudo ufw --force enable >/dev/null 2>&1 || return 1
      sudo ufw default deny incoming >/dev/null 2>&1 || true
      sudo ufw default allow outgoing >/dev/null 2>&1 || true
      return 0
      ;;
    firewalld)
      if ! command -v firewall-cmd >/dev/null 2>&1; then
        _section "Installing firewalld package via $PM"
        $PKG_UPDATE >/dev/null || true
        $PKG_INSTALL firewalld >/dev/null 2>&1 || return 1
      fi
      # start + enable firewalld
      if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl enable --now firewalld >/dev/null 2>&1 || return 1
      elif command -v rc-service >/dev/null 2>&1; then
        sudo rc-update add firewalld default >/dev/null 2>&1 || true
        sudo rc-service firewalld start >/dev/null 2>&1 || return 1
      fi
      # CRITICAL: SSH FIRST (add permanent + immediate)
      sudo firewall-cmd --permanent --add-service=ssh --zone=public >/dev/null 2>&1 || \
        sudo firewall-cmd --permanent --add-port=22/tcp --zone=public >/dev/null 2>&1 || true
      sudo firewall-cmd --add-service=ssh --zone=public >/dev/null 2>&1 || \
        sudo firewall-cmd --add-port=22/tcp --zone=public >/dev/null 2>&1 || true
      return 0
      ;;
    iptables)
      # Generic: just install iptables-persistent / iptables-services if available,
      # ensure SSH 22/tcp ACCEPT rule at top of INPUT chain, then save.
      if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive $PKG_INSTALL iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
      elif command -v dnf >/dev/null 2>&1; then
        $PKG_INSTALL iptables-services >/dev/null 2>&1 || true
      fi
      # Add SSH allow rule FIRST (if not already present)
      if ! sudo iptables -C INPUT -p tcp --dport 22 -j ACCEPT >/dev/null 2>&1; then
        sudo iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT || return 1
      fi
      # Drop defaults for incoming; allow established/related; loopback
      sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      sudo iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
      sudo iptables -P INPUT DROP 2>/dev/null || true
      # Save rules
      if command -v netfilter-persistent >/dev/null 2>&1; then sudo netfilter-persistent save >/dev/null 2>&1 || true
      elif command -v iptables-save >/dev/null 2>&1; then sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null || true
      elif command -v service >/dev/null 2>&1; then sudo service iptables save >/dev/null 2>&1 || true
      fi
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

firewall_add_port() {
  # Usage: firewall_add_port <proto> <port> [comment]
  # proto = tcp|udp; port = numeric or service name
  local proto="$1" port="$2" comment="${3:-}"
  [ -z "$proto" ] && return 1
  [ -z "$port" ]  && return 1
  firewall_detect || true
  case "$FW_BACKEND" in
    ufw)
      if [ -n "$comment" ]; then
        sudo ufw allow "${port}/${proto}" comment "$comment" >/dev/null 2>&1 || return 1
      else
        sudo ufw allow "${port}/${proto}" >/dev/null 2>&1 || return 1
      fi
      ;;
    firewalld)
      sudo firewall-cmd --permanent --add-port="${port}/${proto}" --zone=public >/dev/null 2>&1 || return 1
      sudo firewall-cmd            --add-port="${port}/${proto}" --zone=public >/dev/null 2>&1 || return 1
      ;;
    iptables)
      if ! sudo iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
        # insert right after the SSH rule at position 2 (top-ish of chain)
        sudo iptables -I INPUT 2 -p "$proto" --dport "$port" -j ACCEPT || return 1
      fi
      if command -v netfilter-persistent >/dev/null 2>&1; then sudo netfilter-persistent save >/dev/null 2>&1 || true
      elif command -v iptables-save >/dev/null 2>&1; then sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null || true
      elif command -v service >/dev/null 2>&1; then sudo service iptables save >/dev/null 2>&1 || true
      fi
      ;;
    *) return 1 ;;
  esac
  return 0
}

firewall_summary() {
  local fw=""
  firewall_detect || true
  printf "\nFirewall summary (backend=%s):\n" "$FW_BACKEND"
  case "$FW_BACKEND" in
    ufw)
      printf "  ufw status:\n"
      sudo ufw status numbered 2>/dev/null | sed 's/^/    /' || true
      ;;
    firewalld)
      printf "  public zone permanent ports/services:\n"
      sudo firewall-cmd --permanent --list-all --zone=public 2>/dev/null | sed 's/^/    /' || true
      ;;
    iptables)
      printf "  iptables INPUT chain:\n"
      sudo iptables -L INPUT -v -n --line-numbers 2>/dev/null | sed 's/^/    /' || true
      ;;
    *)
      printf "  (no ufw/firewalld/iptables backend detected — skip firewall summary)\n"
      ;;
  esac
}

# --- environment loader (DB_* vars from .env; returns 0 if file existed) ----
load_env_file() {
  DB_NAME="$DEF_DB_NAME"; DB_USER="$DEF_DB_USER"; DB_PASSWORD=""
  DB_HOST="$DEF_DB_HOST"; DB_PORT="$DEF_DB_PORT"; LISTEN_ADDRESSES="$DEF_LISTEN_ADDRESSES"
  APP_DIR="$DEF_APP_DIR"; GIT_URL=""; GIT_BRANCH="$DEF_GIT_BRANCH"
  DJANGO_SETTINGS="$DEF_DJANGO_SETTINGS"; GUNICORN_BIND="$DEF_GUNICORN_BIND"; SERVICE_NAME="$DEF_SERVICE"
  if [ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ]; then
    set -a; . "$ENV_FILE" || true; set +a
    DB_NAME="${DB_NAME:-$DEF_DB_NAME}"; DB_USER="${DB_USER:-$DEF_DB_USER}"
    DB_HOST="${DB_HOST:-$DEF_DB_HOST}"; DB_PORT="${DB_PORT:-$DEF_DB_PORT}"
    LISTEN_ADDRESSES="${LISTEN_ADDRESSES:-$DEF_LISTEN_ADDRESSES}"
    APP_DIR="${APP_DIR:-$DEF_APP_DIR}"; GIT_BRANCH="${GIT_BRANCH:-$DEF_GIT_BRANCH}"
    DJANGO_SETTINGS="${DJANGO_SETTINGS_MODULE:-${DJANGO_SETTINGS:-$DEF_DJANGO_SETTINGS}}"
    GUNICORN_BIND="${GUNICORN_BIND:-$DEF_GUNICORN_BIND}"; SERVICE_NAME="${SERVICE_NAME:-$DEF_SERVICE}"
    return 0
  fi
  return 1
}

# =========================================================
# Option 1: PRE-CHECK DB install prerequisites
# =========================================================
precheck_db_prereqs() {
  _section "PRE-CHECK: Before installing PostgreSQL Database"
  local fail=0
  detect_pm; _ok "Package manager detected: $PM"

  # 1. privilege
  if sudo -n true 2>/dev/null || [ "$(id -u)" = "0" ]; then _ok "Root/sudo privilege available"
  else _nok "No sudo access; run with sudo or as root" || ((fail++)); fi

  # 2. PM mirrors reachable
  printf "  Running package manager update (may take a few seconds)...\n" >&2
  if eval "$PKG_UPDATE" >/dev/null 2>&1; then _ok "Package manager update OK (mirrors reachable)"
  else _nok "Package manager update failed — check mirror/DNS/network" || ((fail++)); fi

  # 3. /var free disk >= 1 GB
  local free_kb
  free_kb=$(df -Pk /var 2>/dev/null | awk 'NR==2{print $4}') || free_kb=0
  if [ "${free_kb:-0}" -ge 1048576 ]; then _ok "/var free space: ${free_kb} KB (>=1 GB)"
  else _nok "/var free space ${free_kb:-0} KB < 1 GB; needed for PGDATA + WAL" || ((fail++)); fi

  # 4. free RAM >= 512 MB
  local mem_kb
  mem_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -ge 524288 ]; then _ok "Free RAM: ${mem_kb} KB (>= 512 MB)"
  else _warn "Free RAM ${mem_kb} KB < 512 MB (works, but OOM possible on large imports — recommend >=1 GB)"; fi

  # 5. port 5432 free
  if command -v ss >/dev/null 2>&1; then
    if ss -lnt | awk '{print $4}' | grep -Eq "[:.]5432\$"; then _warn "Port 5432 already listening (another postgres? ensure target cluster is correct)"
    else _ok "Port 5432 free (no existing postgres listener)"; fi
  elif command -v nc >/dev/null 2>&1; then
    if nc -z -w2 127.0.0.1 5432 2>/dev/null; then _warn "Port 5432 already listening (another postgres?)"
    else _ok "Port 5432 free"; fi
  else _warn "ss/nc not available, cannot probe port 5432"; fi

  # 6. no existing non-empty PGDATA
  local existing_pg="" cand
  for cand in /var/lib/postgresql/*/main /var/lib/pgsql/*/data /var/lib/postgresql/data; do
    if [ -d "$cand" ] && [ -n "$(ls -A "$cand" 2>/dev/null | head -n 1)" ]; then existing_pg+=" $cand"; fi
  done
  if [ -z "$existing_pg" ]; then _ok "No existing non-empty PGDATA directories detected"
  else _warn "Existing PGDATA found:$existing_pg (Option 3 may upgrade/modify them — be careful)"; fi

  # 7. UTF-8 locales
  local locale_ok=0
  if locale -a 2>/dev/null | grep -Eiq "en_US\.utf.?8|C\.utf.?8"; then locale_ok=1; fi
  if [ "$locale_ok" = "1" ] || command -v locale-gen >/dev/null 2>&1; then _ok "UTF-8 locale available"
  else _nok "No UTF-8 locale found; initdb / CREATE DATABASE collation will fail" || ((fail++)); fi

  # 8. firewall best-effort
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ufw status 2>/dev/null | grep -q "5432"; then _ok "ufw active: port 5432 allow rule found"
    else _warn "ufw active: no 5432 allow rule found (OK if DB access = localhost only)"; fi
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    if firewall-cmd --list-ports 2>/dev/null | grep -q "5432/tcp"; then _ok "firewalld active: 5432/tcp found"
    else _warn "firewalld active: no 5432/tcp rule (OK if DB access = localhost only)"; fi
  else _ok "No active ufw/firewalld detected"; fi

  printf "\nPre-check DB summary: %d FAIL\n" "$fail" >&2
  [ "$fail" -eq 0 ]
}

# =========================================================
# Option 2: PRE-CHECK App install prerequisites
# =========================================================
precheck_app_prereqs() {
  _section "PRE-CHECK: Before installing RaSYaTone Application Server"
  local fail=0
  detect_pm; _ok "Package manager detected: $PM"
  load_env_file || true

  # 1. privilege
  if sudo -n true 2>/dev/null || [ "$(id -u)" = "0" ]; then _ok "Root/sudo privilege available"
  else _nok "No sudo access; install requires sudo for system packages" || ((fail++)); fi

  # 2. mirrors + DNS
  printf "  Running package manager update ...\n" >&2
  if eval "$PKG_UPDATE" >/dev/null 2>&1; then _ok "Package manager mirrors OK"
  else _nok "Package manager mirrors unreachable" || ((fail++)); fi
  if command -v getent >/dev/null 2>&1; then
    getent hosts pypi.org >/dev/null 2>&1 && _ok "DNS: pypi.org resolves" || _warn "DNS pypi.org failed (pip install will fail)"
    getent hosts github.com >/dev/null 2>&1 && _ok "DNS: github.com resolves" || _warn "DNS github.com failed (private git host OK if URL uses that host)"
  fi

  # 3. free disk app dir >= 1 GB
  local probe_dir="${APP_DIR:-/opt}" free_kb
  free_kb=$(df -Pk "$probe_dir" 2>/dev/null | awk 'NR==2{print $4}') || free_kb=0
  if [ "${free_kb:-0}" -ge 1048576 ]; then _ok "$probe_dir free space: ${free_kb} KB (>= 1 GB)"
  else _nok "$probe_dir free space ${free_kb:-0} KB < 1 GB (needs ~600 MB min for venv)" || ((fail++)); fi

  # 4. python3 version
  if command -v python3 >/dev/null 2>&1; then
    local py_ver py_maj py_min
    py_ver=$(python3 -c 'import sys;print(sys.version_info.major,sys.version_info.minor)' 2>/dev/null || echo "0 0")
    read -r py_maj py_min <<<"$py_ver"
    if [ "$py_maj" -gt "$MIN_PYTHON_MAJOR" ] || { [ "$py_maj" -eq "$MIN_PYTHON_MAJOR" ] && [ "$py_min" -ge "$MIN_PYTHON_MINOR" ]; }; then
      _ok "python3 version: ${py_maj}.${py_min} (>= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR})"
    else _nok "python3 version ${py_maj}.${py_min} too old; Django 5 requires >= 3.10" || ((fail++)); fi
  else _nok "python3 binary not installed" || ((fail++)); fi

  # 5. venv + pip modules
  if command -v python3 >/dev/null 2>&1; then
    python3 -m venv --help >/dev/null 2>&1 && _ok "python3 -m venv module available" || { _nok "python3-venv package missing"; ((fail++)); }
    python3 -m pip --version >/dev/null 2>&1  && _ok "python3 -m pip module available"  || { _nok "python3-pip package missing";  ((fail++)); }
  fi

  # 6. git + URL reachable
  if command -v git >/dev/null 2>&1; then _ok "git installed: $(git --version 2>&1 | head -n1)"
  else _nok "git binary not installed" || ((fail++)); fi
  if [ -z "${GIT_URL:-}" ]; then printf "\n"; GIT_URL=$(prompt_def "Git repository URL (to verify reachability)" "") || true; fi
  if [ -n "$GIT_URL" ] && command -v git >/dev/null 2>&1; then
    if GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$GIT_URL" >/dev/null 2>&1; then
      _ok "Git URL reachable (ls-remote returned heads)"
    else _nok "Git URL '$GIT_URL' not reachable (bad URL? need SSH key? private repo auth?)" || ((fail++)); fi
  else _warn "Skipping git URL probe (no URL / no git)"; fi

  # 7. target app dir writable & empty or not existing
  if [ -z "${APP_DIR:-}" ]; then APP_DIR="$DEF_APP_DIR"; fi
  if [ ! -e "$APP_DIR" ]; then _ok "App dir $APP_DIR does not exist (will be created)"
  elif [ -d "$APP_DIR" ] && [ -z "$(ls -A "$APP_DIR" 2>/dev/null | head -n1)" ]; then _ok "App dir $APP_DIR exists but is empty (safe to use)"
  else _warn "App dir $APP_DIR exists and is NOT empty (Option 4 will prompt to overwrite before git clone)"; fi
  local parent_dir
  parent_dir=$(dirname "$APP_DIR")
  if [ -w "$parent_dir" ] || sudo -n test -w "$parent_dir" 2>/dev/null || [ "$(id -u)" = "0" ]; then _ok "App dir parent $parent_dir writable"
  else _warn "Cannot write to $parent_dir (sudo will be used during Option 4)"; fi

  # 8. gunicorn bind port free
  local bind_port
  bind_port=$(printf "%s" "${GUNICORN_BIND:-$DEF_GUNICORN_BIND}" | awk -F: '{print $NF}')
  if [ -n "$bind_port" ] && command -v ss >/dev/null 2>&1; then
    if ss -lnt | awk '{print $4}' | grep -Eq "[:.]${bind_port}\$"; then _warn "Port $bind_port already listening (conflict with gunicorn bind=$GUNICORN_BIND)"
    else _ok "Gunicorn bind port $bind_port free"; fi
  else _warn "ss not available, cannot probe port $bind_port"; fi

  # 9. env file + all 5 DB vars non-empty
  local vars_ok=1 v val
  if [ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ]; then
    _ok "$ENV_FILE exists"
    for v in DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT; do
      eval "val=\${${v}:-}"
      if [ -n "$val" ]; then _ok "  $v set (value not printed)"
      else _nok "  $v empty/missing" || { vars_ok=0; ((fail++)); }; fi
    done
  else _nok "$ENV_FILE file missing (Option 4 will create it)" || { vars_ok=0; ((fail++)); }; fi

  # 10. DB host:port TCP reachable
  if [ "$vars_ok" = "1" ] && command -v nc >/dev/null 2>&1; then
    if nc -z -w3 "$DB_HOST" "$DB_PORT" 2>/dev/null; then _ok "DB host $DB_HOST:$DB_PORT TCP reachable (nc -z)"
    else _nok "DB host $DB_HOST:$DB_PORT NOT reachable via nc -z -w3 — wrong host? firewall?" || ((fail++)); fi
  elif [ "$vars_ok" = "1" ]; then _warn "nc missing; skipping DB host:port TCP probe"; fi

  # 11. full psql SELECT 1
  local row
  if [ "$vars_ok" = "1" ] && command -v psql >/dev/null 2>&1; then
    row=$(PGPASSWORD="$DB_PASSWORD" timeout 8 psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1" 2>/dev/null || true)
    if [ "$row" = "1" ]; then _ok "psql SELECT 1 via DB_USER=$DB_USER succeeded"
    else _warn "psql SELECT 1 failed (wrong DB_PASSWORD? DB/user not created yet? try Option 3 first)"; fi
  elif [ "$vars_ok" = "1" ]; then _warn "psql client not installed; skipping full DB credential SELECT 1 validation (will fail at manage.py migrate)"; fi

  # 12. systemd present
  if command -v systemctl >/dev/null 2>&1; then _ok "systemd present (service install supported)"
  else _warn "systemctl not found (Alpine/container? — will skip service install, run gunicorn manually)"; fi

  printf "\nPre-check App summary: %d FAIL\n" "$fail" >&2
  [ "$fail" -eq 0 ]
}

# =========================================================
# Option 3: Install PostgreSQL database (NO .env write)
# =========================================================
install_db() {
  _section "Install PostgreSQL Database"
  detect_pm
  load_env_file || true

  printf "\nEnter database settings (press Enter to keep default in [brackets]):\n"
  DB_NAME=$(prompt_def "Database name"            "${DB_NAME:-$DEF_DB_NAME}")
  DB_USER=$(prompt_def "Database user"            "${DB_USER:-$DEF_DB_USER}")
  DB_PASSWORD=$(prompt_secret "Database user password" "${DB_PASSWORD:-}")
  DB_HOST=$(prompt_def "Database host (use 'localhost' for local socket)" "${DB_HOST:-$DEF_DB_HOST}")
  DB_PORT=$(prompt_def "Database port"            "${DB_PORT:-$DEF_DB_PORT}")
  LISTEN_ADDRESSES=$(prompt_def "PostgreSQL listen_addresses ('*' = all, 'localhost' = local only)" \
                              "${LISTEN_ADDRESSES:-$DEF_LISTEN_ADDRESSES}")
  local ALLOW_PG_DBS="ALL"  # DEFAULT = ALL (strongly recommended). Only SELF if user explicitly chooses it.
  ALLOW_PG_DBS_RAW=$(prompt_def "Which databases should '$DB_USER' connect to? [RECOMMENDED: ALL = '$DB_NAME' + postgres + all DBs. SELF = ONLY '$DB_NAME' — NOTE: pgAdmin / DBeaver default test connection uses database='postgres' and WILL FAIL if you pick SELF]" "ALL")
  ALLOW_PG_DBS_RAW=$(printf "%s" "$ALLOW_PG_DBS_RAW" | tr '[:lower:]' '[:upper:]')
  case "$ALLOW_PG_DBS_RAW" in
    ALL) ALLOW_PG_DBS="ALL" ;;
    *)   ALLOW_PG_DBS="SELF" ;;
  esac
  # If user chose SELF and listen_addresses != localhost, GIANT WARNING. This is the #1 cause of 'no pg_hba.conf entry for database postgres' FATALs.
  if [ "$ALLOW_PG_DBS" = "SELF" ] && [ "$LISTEN_ADDRESSES" != "localhost" ] && [ "$LISTEN_ADDRESSES" != "127.0.0.1" ] && [ "$LISTEN_ADDRESSES" != "::1" ]; then
    printf "\n\033[1;31m====================================================================\n"
    printf "  WARNING: You chose ALLOW_PG_DBS=SELF (only DB=$DB_NAME allowed)\n"
    printf "  BUT listen_addresses is PUBLIC ($LISTEN_ADDRESSES).\n"
    printf "\n"
    printf "  -> GUI PostgreSQL clients (pgAdmin, DBeaver, psql default)\n"
    printf "     try to connect with database='postgres' as a test.\n"
    printf "     With SELF, PostgreSQL will REJECT them with:\n"
    printf "       FATAL: no pg_hba.conf entry for host … database \"postgres\"\n"
    printf "\n"
    printf "  RECOMMENDED FIX: rerun Option 3 and answer ALLOW_PG_DBS = ALL.\n"
    printf "  Continuing with SELF anyway in 10 seconds (Ctrl-C to abort)...\n"
    printf "====================================================================\033[0m\n"
    sleep 10
  fi
  local PG_ALLOW_IPS=""
  PG_ALLOW_IPS=$(prompt_def \
    "Remote client IPs allowed (comma-separated CIDRs). Examples:
     Single IP: 5.32.252.64/32
     Two clients: 5.32.252.64/32,84.242.41.112/32
     Any IPv4 client (open to internet): 0.0.0.0/0
     Any IPv4+IPv6: 0.0.0.0/0,::/0
     (Press Enter: listen=localhost → local only; else → samenet + 127 + ::1 + 0.0.0.0/0 + ::/0  [internet-wide open; password required])" "")
  if [ -z "${PG_ALLOW_IPS:-}" ]; then
    if [ "$LISTEN_ADDRESSES" = "localhost" ] || [ "$LISTEN_ADDRESSES" = "127.0.0.1" ] || [ "$LISTEN_ADDRESSES" = "::1" ]; then
      PG_ALLOW_IPS="127.0.0.1/32,::1/128,samenet"
    else
      PG_ALLOW_IPS="samenet,127.0.0.1/32,::1/128,0.0.0.0/0,::/0"
      _warn "Default allow set = any internet client (0.0.0.0/0 + ::/0). Scram-sha-256 password auth required; if you want to restrict, rerun Option 3 and paste comma CIDRs like: 84.242.41.112/32,5.32.252.64/32"
    fi
  fi
  local PG_HBA_DBS=""
  if [ "$ALLOW_PG_DBS" = "ALL" ]; then PG_HBA_DBS="${DB_NAME},postgres,all"; else PG_HBA_DBS="${DB_NAME}"; fi
  _ok "pg_hba allow CIDRs: ${PG_ALLOW_IPS}"
  _ok "pg_hba allow DB list: ${PG_HBA_DBS}  (user=$DB_USER, auth=scram-sha-256, SSL+plain allowed)"
  _ok "ALLOW_PG_DBS resolved = ${ALLOW_PG_DBS}  [DEFAULT: ALL; your GUI clients connecting with database='postgres' will work]"

  _section "Installing PostgreSQL packages via $PM"
  eval "$PKG_UPDATE" >/dev/null 2>&1 || true
  case "$PM" in
    apt) sudo $PKG_INSTALL postgresql postgresql-client postgresql-contrib locales ;;
    dnf) sudo $PKG_INSTALL postgresql-server postgresql-contrib ;;
    apk) sudo $PKG_INSTALL postgresql postgresql-client postgresql-contrib ;;
  esac

  # initdb on first install (RHEL-based / Alpine)
  if command -v postgresql-setup >/dev/null 2>&1; then
    sudo postgresql-setup --initdb --unit postgresql 2>/dev/null || true
  elif [ "$PM" = "apk" ] && ls -d /var/lib/postgresql/*/data >/dev/null 2>&1; then
    local ddir
    for ddir in /var/lib/postgresql/*/data; do
      if [ -z "$(ls -A "$ddir" 2>/dev/null | head -n1)" ]; then
        sudo su - postgres -c "initdb -D $ddir" 2>/dev/null || true
      fi
    done
  fi
  service_control enable postgresql
  service_control start postgresql

  _section "Creating database + user"
  local esc_pw db_locale="" db_create_flags="" db_exists="" role_exists=""
  esc_pw=$(printf "%s" "$DB_PASSWORD" | sed -e "s/'/''/g")

  # Bug fix 2: auto-detect best available UTF-8 locale for LC_COLLATE / LC_CTYPE.
  # en_US.UTF-8 is not installed on minimal/cloud/Raspberry images (only C.UTF-8/C).
  for cand in en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8; do
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_collation WHERE collname ILIKE '${cand}' LIMIT 1" postgres 2>/dev/null | grep -q "^1$"; then
      db_locale="$cand"
      break
    fi
  done
  if [ -n "$db_locale" ]; then
    db_create_flags="ENCODING 'UTF8' LC_COLLATE = '${db_locale}' LC_CTYPE = '${db_locale}' TEMPLATE template0"
    _ok "Auto-detected DB locale: ${db_locale}"
  else
    db_create_flags="ENCODING 'UTF8' TEMPLATE template0"
    _warn "No en_US.UTF-8 / C.UTF-8 collation found in pg_collation; using ENCODING UTF8 only (template0 default)."
  fi

  local esc_user esc_db
  esc_user=$(printf "%s" "$DB_USER" | sed -e "s/'/''/g")
  esc_db=$(printf "%s" "$DB_NAME" | sed -e "s/'/''/g")

  # ===== GUARD: print SCRIPT_VERSION_BUILD again immediately before DB SQL runs =====
  printf "\n\033[1;93m[DB-STEP 0/6] version guard: SCRIPT_VERSION_BUILD=%s\033[0m\n" "$SCRIPT_VERSION_BUILD"
  [ "$SCRIPT_VERSION_BUILD" = "$EXPECTED_VERSION_MARKER" ] || _die "Version guard mismatch (stale server copy? exit)"

  # Use /tmp PSQL SCRIPT FILES + psql -f (no heredocs, no DO blocks, 100% visible SQL artifacts)
  # User can cat these files after run to verify statements are standalone.
  SQL_ROLE_CREATE="/tmp/rasyatone_role_create.sql"
  SQL_ROLE_ALTER="/tmp/rasyatone_role_alter.sql"
  SQL_DB_CREATE="/tmp/rasyatone_db_create.sql"
  SQL_DB_GRANT="/tmp/rasyatone_db_grant.sql"

  # (A) Idempotent role create/alter — pure shell existence + standalone SQL script files.
  role_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${esc_user}'" postgres 2>/dev/null | tr -d '[:space:]' || true)
  if [ "$role_exists" != "1" ]; then
    printf "\033[1;93m[DB-STEP 1/6] role does NOT exist -> writing %s (CREATE ROLE standalone, NO DO block)\033[0m\n" "$SQL_ROLE_CREATE"
    printf 'CREATE ROLE %s LOGIN PASSWORD '"'"'%s'"'"';\n' "$DB_USER" "$esc_pw" > "$SQL_ROLE_CREATE"
    printf "  contents of %s:\n" "$SQL_ROLE_CREATE"; sed 's/^/    | /' "$SQL_ROLE_CREATE"
    sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$SQL_ROLE_CREATE"
    _ok "Role ${DB_USER} created (via -f $SQL_ROLE_CREATE)"
  else
    printf "\033[1;93m[DB-STEP 1/6] role exists -> writing %s (ALTER ROLE standalone, NO DO block)\033[0m\n" "$SQL_ROLE_ALTER"
    printf 'ALTER ROLE %s WITH PASSWORD '"'"'%s'"'"';\n' "$DB_USER" "$esc_pw" > "$SQL_ROLE_ALTER"
    printf "  contents of %s:\n" "$SQL_ROLE_ALTER"; sed 's/^/    | /' "$SQL_ROLE_ALTER"
    sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$SQL_ROLE_ALTER"
    _ok "Role ${DB_USER} existed -> password updated (via -f $SQL_ROLE_ALTER)"
  fi

  # (B) CREATE DATABASE — standalone -c call OR standalone SQL script file. No heredocs. No DO.
  db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${esc_db}'" postgres 2>/dev/null | tr -d '[:space:]' || true)
  if [ "$db_exists" != "1" ]; then
    printf "\033[1;93m[DB-STEP 2/6] DB does NOT exist -> writing %s (CREATE DATABASE STANDALONE outside any block)\033[0m\n" "$SQL_DB_CREATE"
    printf 'CREATE DATABASE %s OWNER %s %s;\n' "$DB_NAME" "$DB_USER" "$db_create_flags" > "$SQL_DB_CREATE"
    printf "  contents of %s:\n" "$SQL_DB_CREATE"; sed 's/^/    | /' "$SQL_DB_CREATE"
    # Fail-fast safety: refuse to run if SQL file contents contain "DO " or "BEGIN" anywhere
    if grep -Eiq 'DO[[:space:]]*\$|BEGIN' "$SQL_DB_CREATE" 2>/dev/null; then
      _die "Refusing to run $SQL_DB_CREATE — grep found DO/BEGIN inside. This MUST never happen for a CREATE DATABASE standalone statement."
    fi
    sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$SQL_DB_CREATE"
    _ok "Database ${DB_NAME} created (owner=${DB_USER}, locale=${db_locale:-template0 default}) via -f $SQL_DB_CREATE"
  else
    printf "\033[1;93m[DB-STEP 2/6] DB exists -> skip CREATE DATABASE\033[0m\n"
    _ok "Database ${DB_NAME} already exists — skipping CREATE DATABASE, re-granting only"
  fi

  # (C) GRANT + ALTER OWNER -> standalone SQL script file
  printf "\033[1;93m[DB-STEP 3/6] writing %s (GRANT + OWNER standalone)\033[0m\n" "$SQL_DB_GRANT"
  {
    printf 'GRANT ALL PRIVILEGES ON DATABASE %s TO %s;\n' "$DB_NAME" "$DB_USER"
    printf 'ALTER DATABASE %s OWNER TO %s;\n' "$DB_NAME" "$DB_USER"
  } > "$SQL_DB_GRANT"
  printf "  contents of %s:\n" "$SQL_DB_GRANT"; sed 's/^/    | /' "$SQL_DB_GRANT"
  sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$SQL_DB_GRANT"
  _ok "Granted ALL on ${DB_NAME} to ${DB_USER}; owner set (via -f $SQL_DB_GRANT)"
  printf "\033[1;93m[DB-STEP 3/6 done] All DB create SQL scripts located in /tmp/rasyatone_*.sql (cat them after run if ever suspicious)\033[0m\n"

  _section "Configuring listen_addresses + pg_hba.conf + SSL"
  local pg_conf pg_hba pg_data="" cert_found=0 ssl_on=0
  pg_conf=$(sudo -u postgres psql -tAc "SHOW config_file" 2>/dev/null | tr -d '[:space:]' || true)
  pg_hba=$(sudo -u postgres psql -tAc "SHOW hba_file"    2>/dev/null | tr -d '[:space:]' || true)
  pg_data=$(sudo -u postgres psql -tAc "SHOW data_directory" 2>/dev/null | tr -d '[:space:]' || true)

  if [ -n "$pg_conf" ]; then
    sudo sed -i -E "s|^#?[[:space:]]*listen_addresses[[:space:]]*=.*|listen_addresses = '${LISTEN_ADDRESSES}'|" "$pg_conf"
    sudo sed -i -E "s|^#?[[:space:]]*port[[:space:]]*=.*|port = ${DB_PORT}|" "$pg_conf"
    _ok "Set listen_addresses='${LISTEN_ADDRESSES}', port=${DB_PORT} in ${pg_conf}"

    # SSL: enable if the default snakeoil certs exist (Debian/Ubuntu generate them automatically
    # via ssl-cert package; or user's data dir already has server.crt+server.key from initdb).
    local ssl_crt="" ssl_key=""
    if [ -n "$pg_data" ] && [ -f "${pg_data}/server.crt" ] && [ -f "${pg_data}/server.key" ]; then
      ssl_crt="${pg_data}/server.crt"; ssl_key="${pg_data}/server.key"
    elif [ -f "/etc/ssl/certs/ssl-cert-snakeoil.pem" ] && [ -f "/etc/ssl/private/ssl-cert-snakeoil.key" ]; then
      ssl_crt="/etc/ssl/certs/ssl-cert-snakeoil.pem"
      ssl_key="/etc/ssl/private/ssl-cert-snakeoil.key"
      # Ensure postgres user can read the snakeoil key (ssl-cert group on Debian)
      sudo chmod 640 "$ssl_key" 2>/dev/null || true
      sudo chgrp postgres "$ssl_key" 2>/dev/null || true
      sudo usermod -aG ssl-cert postgres 2>/dev/null || true
    fi
    if [ -n "$ssl_crt" ] && [ -n "$ssl_key" ]; then
      sudo sed -i -E "s|^#?[[:space:]]*ssl[[:space:]]*=.*|ssl = on|" "$pg_conf"
      sudo sed -i -E "s|^#?[[:space:]]*ssl_cert_file[[:space:]]*=.*|ssl_cert_file = '${ssl_crt}'|" "$pg_conf"
      sudo sed -i -E "s|^#?[[:space:]]*ssl_key_file[[:space:]]*=.*|ssl_key_file = '${ssl_key}'|" "$pg_conf"
      # password_encryption → scram-sha-256 so the user's CREATE ROLE password hash method aligns with pg_hba
      sudo sed -i -E "s|^#?[[:space:]]*password_encryption[[:space:]]*=.*|password_encryption = scram-sha-256|" "$pg_conf"
      _ok "SSL enabled in postgresql.conf: ssl=on cert=${ssl_crt} key=${ssl_key}; password_encryption=scram-sha-256"
      ssl_on=1
    else
      _warn "No server SSL certs found (expected either \$PGDATA/server.crt + server.key from initdb, or Debian ssl-cert snakeoil). Clients that prefer SSL (many GUI clients) will still fall back to plain TCP if pg_hba rules allow it."
      ssl_on=0
    fi
  else _warn "Could not locate postgresql.conf"; fi

  # pg_hba rules: split user-provided CIDRs by comma; for each CIDR, for each DB in PG_HBA_DBS list,
  # write TWO rules: hostssl + host (so SSL clients match hostssl, non-SSL clients match host).
  # Auth = scram-sha-256 for every rule.
  if [ -n "$pg_hba" ]; then
    local marker="## RASyatone installer rules"
    # (A) DELETE LEGACY OLD RULES from pre-marker installer versions (lines containing our DB_USER + scram-sha-256
    #     that are NOT inside the current marker block, plus the old 3-rule pattern without a marker header).
    #     This is CRITICAL: if the user previously ran an OLD installer build (no markers), those rules
    #     sit above the new marker block and never get cleaned up by the marker range delete — re-running
    #     the script would silently add duplicates (worse: old rules only covered DB_NAME, not postgres).
    sudo sed -i -E "/^[[:space:]]*#.*R[Aa][Ss][Yy].*marker|^${marker}/,/^## END RASyatone/! {
                      /^[[:space:]]*(local|host|hostssl|hostnossl)[[:space:]]+.*[[:space:]]${DB_USER}[[:space:]]+.*scram-sha-256[[:space:]]*$/d
                    }" "$pg_hba" 2>/dev/null || true
    # (B) Delete the current marker block (if exists) — idempotent on reruns.
    if grep -Fq "$marker" "$pg_hba" 2>/dev/null; then
      sudo sed -i "/^${marker}/,/^## END RASyatone/d" "$pg_hba" 2>/dev/null || true
    fi

    local IFS_save="$IFS" cidr db_list db
    printf '%s\n' "$marker  (build=$SCRIPT_VERSION_BUILD  user=$DB_USER  CIDRs=$PG_ALLOW_IPS  DBs=$PG_HBA_DBS  auth=scram-sha-256  ssl_on=${ssl_on})" | sudo tee -a "$pg_hba" >/dev/null
    # Split DB list (comma-separated: e.g. rasyatone_db,postgres,all  →  each one gets rules per CIDR)
    db_list=""
    IFS=',' read -ra DBARR <<<"$PG_HBA_DBS"
    for db in "${DBARR[@]}"; do
      db=$(printf "%s" "$db" | tr -d '[:space:]')
      [ -z "$db" ] && continue
      db_list="${db_list:+${db_list},}${db}"
      # Write local (unix socket) rule first for convenience (CIDR irrelevant for local socket)
      printf 'local   %-24s %-24s                         scram-sha-256\n' "$db" "$DB_USER" | sudo tee -a "$pg_hba" >/dev/null
    done
    # Loop user CIDRs: for each CIDR + for each DB → hostssl rule, then host rule (scram-sha-256)
    IFS=',' read -ra CIDRARR <<<"$PG_ALLOW_IPS"
    for cidr in "${CIDRARR[@]}"; do
      cidr=$(printf "%s" "$cidr" | tr -d '[:space:]')
      [ -z "$cidr" ] && continue
      # Skip samenet / samehost / local keywords in the CIDR loop for the hostssl/host dual rules:
      #   samenet → PostgreSQL auto-keyword; write plain 'host' rule (no hostssl needed, same as host)
      case "$cidr" in
        samenet|samehost)
          for db in "${DBARR[@]}"; do
            db=$(printf "%s" "$db" | tr -d '[:space:]')
            [ -z "$db" ] && continue
            printf 'host    %-24s %-24s %-24s scram-sha-256\n' "$db" "$DB_USER" "$cidr" | sudo tee -a "$pg_hba" >/dev/null
          done
          continue
          ;;
      esac
      for db in "${DBARR[@]}"; do
        db=$(printf "%s" "$db" | tr -d '[:space:]')
        [ -z "$db" ] && continue
        # SSL rule first: clients that prefer SSL will match this one.
        printf 'hostssl %-24s %-24s %-24s scram-sha-256\n' "$db" "$DB_USER" "$cidr" | sudo tee -a "$pg_hba" >/dev/null
        # Plain host rule as fallback: for clients that don't do SSL, or for SSL off cases.
        printf 'host    %-24s %-24s %-24s scram-sha-256\n' "$db" "$DB_USER" "$cidr" | sudo tee -a "$pg_hba" >/dev/null
      done
    done
    IFS="$IFS_save"
    printf '%s\n' "## END RASyatone" | sudo tee -a "$pg_hba" >/dev/null
    _ok "pg_hba.conf updated (marker=RASyatone, DB list=${db_list}, CIDRs=${PG_ALLOW_IPS}, auth=scram-sha-256, ssl=${ssl_on})"
    printf "  %s last 30 lines:\n" "$pg_hba"; sudo tail -n 30 "$pg_hba" 2>/dev/null | sed 's/^/    | /' || true
  else _warn "Could not locate pg_hba.conf"; fi
  service_control restart postgresql

  _section "Verify connection with new user"
  local row row2 row_any=0
  # 1) Always verify DB_NAME connection (127.0.0.1)
  row=$(PGPASSWORD="$DB_PASSWORD" timeout 8 psql -h "127.0.0.1" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT current_database(), current_user" 2>/dev/null || true)
  if [ -n "$row" ]; then _ok "psql connect verify (127.0.0.1, DB=$DB_NAME): OK — $row"; row_any=1; fi
  # 2) If ALLOW_PG_DBS=ALL (the new default), VERIFY DB=postgres CONNECTS TOO. This is the EXACT test
  #    the user's GUI client (pgAdmin/DBeaver) performs by default. If this fails → die loud because
  #    the exact FATAL the user reported cannot happen if the script produced correct rules.
  if [ "$ALLOW_PG_DBS" = "ALL" ]; then
    row2=$(PGPASSWORD="$DB_PASSWORD" timeout 8 psql -h "127.0.0.1" -p "$DB_PORT" -U "$DB_USER" -d postgres -tAc "SELECT current_database(), current_user" 2>/dev/null || true)
    if [ -n "$row2" ]; then
      _ok "psql connect verify (127.0.0.1, DB=postgres): OK — $row2   [GUI clients connecting with database='postgres' will work]"
      row_any=1
    else
      _die "VERIFY FAILED — DB=postgres connect as '$DB_USER' rejected (exactly the GUI error you reported). pg_hba rules are wrong or postgres did not restart cleanly. Review pg_hba tail above (the RASyatone marker block); it MUST contain a 'host(ssl)? postgres $DB_USER <yourcidr> scram-sha-256' line. If not, marker delete regex may have failed. Report as bug: build=$SCRIPT_VERSION_BUILD"
    fi
  fi
  if [ "$row_any" -eq 0 ]; then
    if [ "$ALLOW_PG_DBS" = "ALL" ]; then
      _die "Could not connect locally as $DB_USER to either DB=$DB_NAME or DB=postgres — review pg_hba rules printed above"
    else
      _die "Could not connect as $DB_USER@127.0.0.1:$DB_PORT/$DB_NAME after install — review pg_hba rules printed above. If you need DB=postgres access, rerun Option 3 and keep ALLOW_PG_DBS=ALL (the default)"
    fi
  fi
  # 3) Optional public-host reachability test — if listen_addresses is NOT localhost only
  if [ "$LISTEN_ADDRESSES" != "localhost" ] && [ "$LISTEN_ADDRESSES" != "127.0.0.1" ] && [ "$LISTEN_ADDRESSES" != "::1" ]; then
    local public_ips="" pubip="" oneip row3 any_ok=0 any_fail=0
    if command -v hostname >/dev/null 2>&1; then
      public_ips=$(hostname -I 2>/dev/null || true)
    fi
    if [ -z "${public_ips:-}" ]; then
      public_ips=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | paste -sd' ' - || true)
    fi
    if [ -z "${public_ips:-}" ] && command -v dig >/dev/null 2>&1; then
      pubip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | awk 'NR==1{print;exit}' || true)
      public_ips="$pubip"
    fi
    for oneip in $public_ips; do
      # Test both DB_NAME and postgres (if ALL) against every discoverable public / global IP
      row=$(PGPASSWORD="$DB_PASSWORD" timeout 6 psql -h "$oneip" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT current_database(), current_user" 2>/dev/null || true)
      if [ -n "$row" ]; then
        _ok "psql connect verify (public IP $oneip, DB=$DB_NAME): OK — $row   (firewall port $DB_PORT/tcp is open; listener=$LISTEN_ADDRESSES correct)"
        any_ok=$((any_ok + 1))
      else
        _warn "psql connect via self-host IP $oneip DB=$DB_NAME FAILED. Causes: firewall $DB_PORT/tcp not open (run firewall enable step Option 3), listen_addresses wrong, pg_hba CIDR ($PG_ALLOW_IPS) missing $oneip entry."
        any_fail=$((any_fail + 1))
      fi
      if [ "$ALLOW_PG_DBS" = "ALL" ]; then
        row3=$(PGPASSWORD="$DB_PASSWORD" timeout 6 psql -h "$oneip" -p "$DB_PORT" -U "$DB_USER" -d postgres -tAc "SELECT current_database(), current_user" 2>/dev/null || true)
        if [ -n "$row3" ]; then
          _ok "psql connect verify (public IP $oneip, DB=postgres): OK — $row3   (the EXACT test your GUI client performed — works now!)"
          any_ok=$((any_ok + 1))
        else
          _warn "psql connect via self-host IP $oneip DB=postgres FAILED (this is the GUI test). If local DB=postgres passed but this fails: firewall issue ($DB_PORT/tcp on $oneip), or pg_hba CIDR missing public IP of client network, or ISP NAT $oneip unreachable from server side."
          any_fail=$((any_fail + 1))
        fi
      fi
    done
    if [ "$any_fail" -gt 0 ] && [ "$any_ok" -eq 0 ]; then
      _warn "ALL public-IP self-connects failed — check firewall $DB_PORT/tcp rule status (Option 3 enables it and prints rules). If firewall OFF enable it with: sudo ufw allow 5432/tcp  or  firewall-cmd --permanent --add-port=5432/tcp ; firewall-cmd --reload"
    fi
  fi
  # 3) User action checklist for remote clients (prevent common pg_hba confusion)
  printf "\n\033[1;33mRemote client troubleshooting checklist (if login still prompts for password / pg_hba reject):\033[0m\n"
  printf "   (a) Connect to database='%s', NOT database='postgres'  (you selected ALLOW_PG_DBS=%s)\n" "$DB_NAME" "$ALLOW_PG_DBS"
  printf "   (b) Remote client IP must appear in PG_ALLOW_IPS = %s  (rerun Option 3 to add it if missing)\n" "$PG_ALLOW_IPS"
  printf "   (c) User/password must be exactly: user='%s' password='<the value you typed>'\n" "$DB_USER"
  if [ "$ssl_on" -eq 1 ]; then
    printf "   (d) Server SSL is ON → client can connect with sslmode=require/prefer for TLS (pg_hba has both hostssl + host rules)\n"
  else
    printf "   (d) Server SSL is OFF → pg_hba 'host' rule matches plain TCP; if your client insists on SSL rerun Option 3 or install ssl-cert package before running it.\n"
  fi
  printf "\n"

  # ================ Firewall enable + PostgreSQL rule ================
  _section "Enable system firewall (Option 3 firewall step)"
  local do_fw=""
  do_fw=$(prompt_yn "Enable firewall and open needed ports (PostgreSQL ${DB_PORT}/tcp + SSH 22/tcp)? [Y/n] — SSH 22 is ALWAYS opened first so you won't be locked out" "y")
  if [ "$do_fw" = "y" ]; then
    firewall_detect || true
    _ok "Detected firewall backend: ${FW_BACKEND}"
    if firewall_install_and_enable; then
      _ok "Firewall installed/enabled; SSH 22/tcp already open"
      if [ "$LISTEN_ADDRESSES" = "localhost" ] || [ "$LISTEN_ADDRESSES" = "127.0.0.1" ] || [ "$LISTEN_ADDRESSES" = "::1" ]; then
        _warn "listen_addresses='${LISTEN_ADDRESSES}' (localhost only); skipping firewall rule for PostgreSQL ${DB_PORT}/tcp (no remote access needed)."
      else
        if firewall_add_port tcp "$DB_PORT" "PostgreSQL (rasyatone DB)"; then
          _ok "Firewall rule added: PostgreSQL ${DB_PORT}/tcp"
        else
          _warn "Could not add PostgreSQL ${DB_PORT}/tcp firewall rule — add manually if needed."
        fi
      fi
      firewall_summary
    else
      _warn "Could not install/enable firewall (backend=${FW_BACKEND}). Review manually — SSH 22/tcp and PostgreSQL ${DB_PORT}/tcp remain open per current network rules."
    fi
  else
    _warn "Firewall skipped by user choice. SSH 22/tcp and PostgreSQL ${DB_PORT}/tcp visibility depend on existing network/firewall rules."
  fi

  _section "PostgreSQL install POST-INSTALL SUMMARY"
  service_control status postgresql || true
  printf "  DB_HOST=%s  DB_PORT=%s  DB_NAME=%s  DB_USER=%s\n" "$DB_HOST" "$DB_PORT" "$DB_NAME" "$DB_USER"
  printf "  listen_addresses=%s\n" "$LISTEN_ADDRESSES"
  printf "  Note: .env file intentionally NOT written by Option 3 — run Option 4 to create/update %s\n" "$ENV_FILE"
  printf "\nDone.\n"
}

# =========================================================
# Option 4: Install RaSYaTone application server
# =========================================================
install_app() {
  _section "Install RaSYaTone Application Server"
  detect_pm
  load_env_file || true

  printf "\nEnter RaSYaTone app server settings (press Enter to keep default in [brackets]):\n"
  printf "  (Database settings — Enter keeps current value from %s)\n" "$ENV_FILE"
  DB_NAME=$(prompt_def "Database name"      "${DB_NAME:-$DEF_DB_NAME}")
  DB_USER=$(prompt_def "Database user"      "${DB_USER:-$DEF_DB_USER}")
  DB_PASSWORD=$(prompt_secret "Database user password" "${DB_PASSWORD:-}")
  DB_HOST=$(prompt_def "Database host"      "${DB_HOST:-$DEF_DB_HOST}")
  DB_PORT=$(prompt_def "Database port"      "${DB_PORT:-$DEF_DB_PORT}")
  APP_DIR=$(prompt_def "App install directory" "${APP_DIR:-$DEF_APP_DIR}")
  GIT_URL=$(prompt_def "Git repository URL (https://... or git@...) (REQUIRED)" "${GIT_URL:-}")
  [ -z "$GIT_URL" ] && _die "Git URL is required — cannot clone application without a repo URL"
  GIT_BRANCH=$(prompt_def "Git branch"          "${GIT_BRANCH:-$DEF_GIT_BRANCH}")
  DJANGO_SETTINGS=$(prompt_def "Django settings module (Python dotted path)" "${DJANGO_SETTINGS:-$DEF_DJANGO_SETTINGS}")
  GUNICORN_BIND=$(prompt_def "Gunicorn bind address" "${GUNICORN_BIND:-$DEF_GUNICORN_BIND}")
  SERVICE_NAME=$(prompt_def "systemd service name" "${SERVICE_NAME:-$DEF_SERVICE}")

  _section "Writing $ENV_FILE"
  sudo mkdir -p "$ENV_DIR"
  printf '%s\n' \
    "# RaSYaTone environment (written by install.sh Option 4. Edit freely; re-running installer overwrites)." \
    "# Database (required for manage.py migrate + app startup)" \
    "DB_NAME='${DB_NAME}'" \
    "DB_USER='${DB_USER}'" \
    "DB_PASSWORD='${DB_PASSWORD}'" \
    "DB_HOST='${DB_HOST}'" \
    "DB_PORT='${DB_PORT}'" \
    "# App" \
    "APP_DIR='${APP_DIR}'" \
    "GIT_URL='${GIT_URL}'" \
    "GIT_BRANCH='${GIT_BRANCH}'" \
    "DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS}'" \
    "GUNICORN_BIND='${GUNICORN_BIND}'" \
    "SERVICE_NAME='${SERVICE_NAME}'" \
    | sudo tee "$ENV_FILE" >/dev/null
  sudo chmod 0640 "$ENV_FILE" 2>/dev/null || true
  _ok "$ENV_FILE written (0640). Edit manually if desired."

  _section "Installing system packages (python3-venv/pip/git/build tools + psql client) via $PM"
  eval "$PKG_UPDATE" >/dev/null 2>&1 || true
  case "$PM" in
    apt) sudo $PKG_INSTALL python3 python3-venv python3-pip python3-dev git build-essential libpq-dev curl gettext-base postgresql-client ;;
    dnf) sudo $PKG_INSTALL python3 python3-devel python3-pip git gcc gcc-c++ make libpq-devel curl postgresql ;;
    apk) sudo $PKG_INSTALL python3 py3-virtualenv py3-pip python3-dev git build-base postgresql-dev curl postgresql-client ;;
  esac

  _section "Validate DB connectivity (DB_PASSWORD from $ENV_FILE)"
  set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
  if command -v psql >/dev/null 2>&1; then
    local row
    row=$(PGPASSWORD="$DB_PASSWORD" timeout 10 psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1" 2>/dev/null || true)
    if [ "$row" = "1" ]; then _ok "psql SELECT 1 OK (DB credentials validate)"
    else _warn "psql SELECT 1 probe FAILED — manage.py migrate will likely fail too. Continuing..."; fi
  else _warn "psql client not installed — skipping DB credential SELECT 1 pre-validate"; fi

  _section "Prepare app directory: $APP_DIR"
  sudo mkdir -p "$APP_DIR"
  sudo chown "$(id -u):$(id -g)" "$APP_DIR" 2>/dev/null || true
  if [ ! -d "${APP_DIR}/.git" ]; then
    if [ -n "$(ls -A "$APP_DIR" 2>/dev/null | head -n1)" ]; then
      local do_over=""
      do_over=$(prompt_def "App dir $APP_DIR is not empty — remove contents before git clone? [y/N]" "n")
      if [ "$do_over" = "y" ] || [ "$do_over" = "Y" ]; then
        sudo rm -rf "${APP_DIR:?}/"* "${APP_DIR:?}/".[!.]* 2>/dev/null || true
      fi
    fi
    if [ -z "$(ls -A "$APP_DIR" 2>/dev/null | head -n1)" ]; then
      git clone -b "$GIT_BRANCH" --depth 1 "$GIT_URL" "$APP_DIR"
    fi
  else
    git -C "$APP_DIR" fetch --depth 1 origin "$GIT_BRANCH" || true
    git -C "$APP_DIR" reset --hard "origin/$GIT_BRANCH"
  fi
  [ -d "$APP_DIR" ] || _die "App dir $APP_DIR missing after clone"
  _ok "App dir populated (branch=$GIT_BRANCH)"

  _section "Create virtualenv at $APP_DIR/.venv + install dependencies"
  if [ ! -d "$APP_DIR/.venv" ]; then python3 -m venv "$APP_DIR/.venv"; fi
  # shellcheck disable=SC1091
  . "$APP_DIR/.venv/bin/activate"
  python -m pip install --quiet --upgrade pip setuptools wheel
  if [ -f "$APP_DIR/requirements.txt" ]; then
    python -m pip install --quiet -r "$APP_DIR/requirements.txt"
  else
    _warn "No $APP_DIR/requirements.txt found — skipping pip install -r (install manually)"
  fi
  python -m pip install --quiet gunicorn 2>/dev/null || true
  _ok "venv ready; gunicorn: $(gunicorn --version 2>&1 | head -n1)"

  _section "Run Django collectstatic + migrate"
  (
    cd "$APP_DIR"
    set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DJANGO_SETTINGS}"
    . "./.venv/bin/activate"
    if python manage.py collectstatic --noinput >/dev/null; then _ok "collectstatic ok"
    else _warn "collectstatic exited non-zero (STATIC_ROOT unset? continue if expected)"; fi
    python manage.py migrate || _die "manage.py migrate failed — DB credentials in $ENV_FILE?"
  )
  _ok "Django migrate OK"

  if command -v systemctl >/dev/null 2>&1; then
    _section "Install systemd service: $SERVICE_NAME"
    local unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
    local workers="${GUNICORN_WORKERS:-2}"
    local wsgi_module="${DJANGO_SETTINGS%.*}.wsgi:application"
    printf '%s\n' \
      "[Unit]" \
      "Description=RaSYaTone application server (gunicorn)" \
      "After=network.target postgresql.service" \
      "" \
      "[Service]" \
      "Type=notify" \
      "User=root" \
      "Group=root" \
      "WorkingDirectory=$APP_DIR" \
      "EnvironmentFile=-$ENV_FILE" \
      "Environment=\"DJANGO_SETTINGS_MODULE=$DJANGO_SETTINGS\"" \
      "ExecStart=$APP_DIR/.venv/bin/gunicorn --workers $workers --bind $GUNICORN_BIND --chdir $APP_DIR $wsgi_module" \
      "ExecReload=/bin/kill -s HUP \$MAINPID" \
      "Restart=always" \
      "RestartSec=3" \
      "" \
      "[Install]" \
      "WantedBy=multi-user.target" \
      | sudo tee "$unit_file" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    _ok "systemd unit written and started: $unit_file"
  else
    _warn "systemd not present — skipped service install (run gunicorn manually)"
  fi

  # ================ Firewall enable + app + web ports ================
  _section "Enable system firewall (Option 4 firewall step)"
  local bind_port do_fw="" do_webfw=""
  bind_port=$(printf "%s" "$GUNICORN_BIND" | awk -F: '{print $NF}')
  do_fw=$(prompt_yn "Enable firewall and open needed ports (Gunicorn ${bind_port}/tcp + SSH 22/tcp)? [Y/n] — SSH 22 is ALWAYS opened first so you won't be locked out" "y")
  if [ "$do_fw" = "y" ]; then
    firewall_detect || true
    _ok "Detected firewall backend: ${FW_BACKEND}"
    if firewall_install_and_enable; then
      _ok "Firewall installed/enabled; SSH 22/tcp already open"
      if firewall_add_port tcp "$bind_port" "Gunicorn / RaSYaTone app (${SERVICE_NAME})"; then
        _ok "Firewall rule added: Gunicorn ${bind_port}/tcp"
      else
        _warn "Could not add Gunicorn ${bind_port}/tcp firewall rule — add manually if needed."
      fi
      do_webfw=$(prompt_yn "Also open HTTP (80/tcp) and HTTPS (443/tcp) for a future nginx reverse proxy / Let's Encrypt? [y/N]" "n")
      if [ "$do_webfw" = "y" ]; then
        firewall_add_port tcp 80 "HTTP (nginx / reverse proxy)"  || true
        firewall_add_port tcp 443 "HTTPS TLS (nginx / Let's Encrypt)" || true
        _ok "Firewall rules added: 80/tcp (HTTP), 443/tcp (HTTPS)"
      fi
      firewall_summary
    else
      _warn "Could not install/enable firewall (backend=${FW_BACKEND}). Review manually — SSH 22/tcp and Gunicorn ${bind_port}/tcp visibility depend on existing network rules."
    fi
  else
    _warn "Firewall skipped by user choice. SSH 22/tcp and Gunicorn ${bind_port}/tcp visibility depend on existing network/firewall rules."
  fi

  _section "RaSYaTone app install POST-INSTALL SUMMARY"
  printf "  APP_DIR=%s\n" "$APP_DIR"
  printf "  VENV_PYTHON=%s\n" "$APP_DIR/.venv/bin/python"
  printf "  DJANGO_SETTINGS=%s\n" "$DJANGO_SETTINGS"
  printf "  ENV_FILE=%s\n" "$ENV_FILE"
  if command -v systemctl >/dev/null 2>&1; then
    printf "  SERVICE=%s state=" "$SERVICE_NAME"
    systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
    systemctl status --no-pager -n 5 "$SERVICE_NAME" 2>/dev/null || true
  fi
  local bind_port
  bind_port=$(printf "%s" "$GUNICORN_BIND" | awk -F: '{print $NF}')
  if command -v curl >/dev/null 2>&1; then
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${bind_port}/" 2>/dev/null || echo "000")
    printf "  HTTP 127.0.0.1:%s status %s\n" "$bind_port" "$http_code"
  elif command -v nc >/dev/null 2>&1; then
    if nc -z -w3 "127.0.0.1" "$bind_port" 2>/dev/null; then
      printf "  Port 127.0.0.1:%s LISTENING (bind=$GUNICORN_BIND)\n" "$bind_port"
    else
      printf "  Port 127.0.0.1:%s NOT listening yet (gunicorn may still be starting)\n" "$bind_port"
    fi
  fi
  printf "\nDone.\n"
}

# =========================================================
# Main interactive menu
# =========================================================
main_menu() {
  while true; do
    printf "\n\033[1;97m=================================\033[0m\n"
    printf "\033[1;97m  RaSYaTone Local Server Installer\033[0m\n"
    printf "\033[1;97m=================================\033[0m\n"
    printf "  1) PRE-CHECK DB install prerequisites  (8 fail-fast checks BEFORE installing DB)\n"
    printf "  2) PRE-CHECK App install prerequisites (12 checks BEFORE installing RaSYaTone app)\n"
    printf "  3) Install PostgreSQL database\n"
    printf "  4) Install RaSYaTone application server\n"
    printf "  Q) Quit\n"
    local choice=""
    printf "\nChoose [1/2/3/4/Q]: "
    IFS= read -r choice || choice=""
    case "$choice" in
      1) if precheck_db_prereqs; then
           printf "\n\033[92mAll DB pre-checks PASSED. Safe to run option 3.\033[0m\n"
         else
           printf "\n\033[91mSome DB pre-checks FAILED — see items above. Fix before option 3.\033[0m\n"
         fi ;;
      2) if precheck_app_prereqs; then
           printf "\n\033[92mAll App pre-checks PASSED. Safe to run option 4.\033[0m\n"
         else
           printf "\n\033[91mSome App pre-checks FAILED — see items above.\033[0m\n"
         fi ;;
      3) _section "Option 3 — Install PostgreSQL database"
         if confirm_yn "Run DB pre-checks (Option 1) first?" "y"; then
           if ! precheck_db_prereqs; then
             printf "\n\033[93mPre-checks reported FAIL above.\033[0m\n"
             if ! confirm_yn "Continue DB install anyway (NOT recommended)?" "n"; then
               printf "Returning to menu.\n"; continue
             fi
           fi
         fi
         install_db ;;
      4) _section "Option 4 — Install RaSYaTone application server"
         if confirm_yn "Run App pre-checks (Option 2) first?" "y"; then
           if ! precheck_app_prereqs; then
             printf "\n\033[93mPre-checks reported FAIL above.\033[0m\n"
             if ! confirm_yn "Continue App install anyway (NOT recommended)?" "n"; then
               printf "Returning to menu.\n"; continue
             fi
           fi
         fi
         install_app ;;
      q|Q|"") echo "Quit."; exit 0 ;;
      *)   printf "Unknown choice: %s. Try again.\n" "$choice" ;;
    esac
  done
}

# --- entrypoint (menu by default, or CLI flags for automation) --------------
if [ "${1:-}" = "--install-db" ]; then
  install_db; exit 0
elif [ "${1:-}" = "--install-app" ]; then
  install_app; exit 0
elif [ "${1:-}" = "--precheck-db" ]; then
  precheck_db_prereqs; exit $?
elif [ "${1:-}" = "--precheck-app" ]; then
  precheck_app_prereqs; exit $?
elif [ -n "${1:-}" ]; then
  _die "Unknown arg: $1 (use no args for interactive menu, or --precheck-db | --precheck-app | --install-db | --install-app)"
else
  main_menu
fi
