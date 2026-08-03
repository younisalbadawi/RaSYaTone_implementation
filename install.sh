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
set -euo pipefail
umask 022

# --- global defaults --------------------------------------------------------
ENV_DIR="/etc/rasyatone/static"
ENV_FILE="${ENV_DIR}/rasyatone.env"
DEF_DB_NAME="rasyatone"
DEF_DB_USER="rasyatone"
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
  else
    _warn "No systemctl/rc-service; service '$action $name' must be run manually"
  fi
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
  local esc_pw
  esc_pw=$(printf "%s" "$DB_PASSWORD" | sed -e "s/'/''/g")
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${esc_pw}';
  ELSE
    ALTER ROLE ${DB_USER} WITH PASSWORD '${esc_pw}';
  END IF;
END \$\$;
DO \$\$ BEGIN
  CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8' LC_COLLATE = 'en_US.UTF-8' LC_CTYPE = 'en_US.UTF-8' TEMPLATE template0;
EXCEPTION WHEN duplicate_database THEN NULL; END \$\$;
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};
EOF
  _ok "Created user '${DB_USER}', database '${DB_NAME}', granted ALL"

  _section "Configuring listen_addresses + pg_hba.conf"
  local pg_conf pg_hba
  pg_conf=$(sudo -u postgres psql -tAc "SHOW config_file" 2>/dev/null | tr -d '[:space:]' || true)
  pg_hba=$(sudo -u postgres psql -tAc "SHOW hba_file"    2>/dev/null | tr -d '[:space:]' || true)
  if [ -n "$pg_conf" ]; then
    sudo sed -i -E "s|^#?[[:space:]]*listen_addresses[[:space:]]*=.*|listen_addresses = '${LISTEN_ADDRESSES}'|" "$pg_conf"
    sudo sed -i -E "s|^#?[[:space:]]*port[[:space:]]*=.*|port = ${DB_PORT}|" "$pg_conf"
    _ok "Set listen_addresses='${LISTEN_ADDRESSES}', port=${DB_PORT} in ${pg_conf}"
  else _warn "Could not locate postgresql.conf"; fi
  if [ -n "$pg_hba" ]; then
    if ! grep -Eq "^host[[:space:]]+${DB_NAME}[[:space:]]+${DB_USER}[[:space:]]+" "$pg_hba" 2>/dev/null; then
      printf 'host    %s    %s    samenet                 scram-sha-256\n' "$DB_NAME" "$DB_USER" | sudo tee -a "$pg_hba" >/dev/null
      printf 'host    %s    %s    127.0.0.1/32            scram-sha-256\n' "$DB_NAME" "$DB_USER" | sudo tee -a "$pg_hba" >/dev/null
      printf 'host    %s    %s    ::1/128                 scram-sha-256\n' "$DB_NAME" "$DB_USER" | sudo tee -a "$pg_hba" >/dev/null
      _ok "Appended scram-sha-256 host rules for ${DB_USER}/${DB_NAME} to ${pg_hba}"
    fi
  else _warn "Could not locate pg_hba.conf"; fi
  service_control restart postgresql

  _section "Verify connection with new user"
  local row
  row=$(PGPASSWORD="$DB_PASSWORD" timeout 8 psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT current_database(), current_user" 2>/dev/null || true)
  if [ -n "$row" ]; then _ok "psql connect verify OK: $row"
  else _die "Could not connect as $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME after install — review pg_hba / listen_addresses above"; fi

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
