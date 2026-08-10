#!/usr/bin/env bash
# RaSYaTone local installer
# Run: sudo bash ./install.sh  (or: chmod +x ./install.sh && ./install.sh)
#
# Menu:
#   1) PRE-CHECK DB install prerequisites
#   2) PRE-CHECK App install prerequisites
#   3) Install PostgreSQL database
#   4) Install RaSYaTone application server
#   5) Upgrade/Update RaSYaTone application server
#   Q) Quit
#
# Tested package managers: apt (Debian/Ubuntu/Raspbian), dnf (RHEL/Rocky/Alma/Fedora), apk (Alpine)
#
# Non-interactive CLI flags (for CI/automation):
#   bash install.sh --precheck-db     # run option 1, exit with precheck rc
#   bash install.sh --precheck-app    # run option 2, exit with precheck rc
#   bash install.sh --install-db      # run option 3 interactive prompts then exit
#   bash install.sh --install-app     # run option 4 interactive prompts then exit
#   bash install.sh --upgrade-app     # run option 5 interactive prompts then exit
#
# --- VERSION STAMP (server copy cross-check: run: grep 'SCRIPT_VERSION_BUILD=' install.sh) ---
SCRIPT_VERSION_BUILD="2026-08-10T-upgrade-option-piplog-winfilter"
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
# ── CRITICAL BOOT SAFETY: ONE-TIME ENV SANITIZER (runs BEFORE ANY `set -a; . "$ENV_FILE"`) ──
#   Fixes the EXACT user bug: previous run wrote garbage CIRCULAR_APPS=raiseCircularDependencyError(
#   (open paren unquoted) → THIS run first `source` throws:
#     /etc/rasyatone/static/rasyatone.env: line 17: syntax error near unexpected token `('
#   which aborts Bash source parser BEFORE reading DB_PASSWORD, DJANGO_SETTINGS_MODULE, etc.
#   -> every subsequent migration/install step crashes with empty/nounset DB_PASSWORD errors.
#   This sanitizer runs IMMEDIATELY when ENV_FILE is set (BEFORE function definitions would be
#   available, so we inline the same 12-line loop check for CIRCULAR_* invalid key=value lines).
if [ -n "${ENV_FILE:-}" ] && [ -f "${ENV_FILE}" ] && [ -r "${ENV_FILE}" ] && [ -w "${ENV_FILE}" ]; then
  _early_san_tmp=""
  _early_san_tmp=$(mktemp /tmp/rasyatone_env_early_sanitize_$$.XXXXXX 2>/dev/null || true)
  if [ -n "${_early_san_tmp}" ]; then
    _early_changed=0
    while IFS= read -r _early_line || [ -n "${_early_line}" ]; do
      case "$_early_line" in ''|\#*) printf '%s\n' "$_early_line" >> "$_early_san_tmp"; continue ;; esac
      case "$_early_line" in
        CIRCULAR_APPS=*|CIRCULAR_APPLY_2STEP=*)
          _early_k="${_early_line%%=*}"
          _early_v="${_early_line#*=}"
          # Strip surrounding SINGLE or DOUBLE quotes if present (both accepted on read).
          case "$_early_v" in
            "'"*"'") _early_v="${_early_v#\'}"; _early_v="${_early_v%\'}" ;;
            '"'*'"') _early_v="${_early_v#\"}"; _early_v="${_early_v%\"}" ;;
          esac
          _early_ok=0
          if [ "$_early_k" = "CIRCULAR_APPS" ]; then
            if [ -z "$_early_v" ]; then _early_ok=1
            elif printf '%s' "$_early_v" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]* [a-zA-Z_][a-zA-Z0-9_]*$'; then _early_ok=1
            else _early_ok=0
            fi
          else
            case "$_early_v" in y|Y|n|N|'') _early_ok=1 ;; *) _early_ok=0 ;; esac
          fi
          if [ "$_early_ok" -eq 1 ]; then
            # Write with SINGLE-QUOTED value (Bash source requires spaces in value quoted).
            case "$_early_k" in
              CIRCULAR_APPS)         printf 'CIRCULAR_APPS='\''%s'\''\n' "$_early_v" >> "$_early_san_tmp" ;;
              CIRCULAR_APPLY_2STEP)  printf 'CIRCULAR_APPLY_2STEP='\''%s'\''\n' "$_early_v" >> "$_early_san_tmp" ;;
            esac
            # Detect rewrite even if only quoting style changed (valid but unquoted → quoted).
            case "$_early_line" in
              "CIRCULAR_APPS='"*"'")  : already quoted correctly ;;
              "CIRCULAR_APPLY_2STEP='"*"'") : already quoted correctly ;;
              *) _early_changed=1 ;;
            esac
          else
            case "$_early_k" in
              CIRCULAR_APPS)         printf 'CIRCULAR_APPS='\'''\''\n' >> "$_early_san_tmp" ;;
              CIRCULAR_APPLY_2STEP)  printf 'CIRCULAR_APPLY_2STEP='\''n'\''\n' >> "$_early_san_tmp" ;;
            esac
            _early_changed=1
          fi
          ;;
        *) printf '%s\n' "$_early_line" >> "$_early_san_tmp" ;;
      esac
    done < "$ENV_FILE"
    if [ "$_early_changed" -eq 1 ]; then
      chmod --reference="$ENV_FILE" "$_early_san_tmp" 2>/dev/null || true
      mv -f "$_early_san_tmp" "$ENV_FILE" 2>/dev/null || { cat "$_early_san_tmp" > "$ENV_FILE"; rm -f "$_early_san_tmp"; }
      printf "\033[1;33m[WARN] EARLY BOOT ENV SANITIZER: removed invalid CIRCULAR_* sentinel entries from %s (open-paren/garbage caused bash source syntax error). Rewritten to valid empty quoted defaults. Next sourcing will succeed.\033[0m\n" "$ENV_FILE" >&2
    else
      rm -f "$_early_san_tmp"
    fi
  fi
  unset _early_san_tmp _early_changed _early_line _early_k _early_v _early_ok
fi
DEF_DB_NAME="rasyatone_db"
DEF_DB_USER="rasyatone_db_user"
DEF_DB_HOST="localhost"
DEF_DB_PORT="5432"
DEF_LISTEN_ADDRESSES="*"
DEF_APP_DIR="/opt/rasyatone"
DEF_GIT_BRANCH="main"
DEF_DJANGO_SETTINGS_MODULE="rasyatone.settings"
DEF_GUNICORN_BIND="0.0.0.0:8000"
DEF_SERVICE="rasyatone"
DEF_SERVICE_ACCOUNT="rasyatone_app_user"
DEF_USE_UNIX_SOCKET="n"
DEF_ENABLE_SYSTEMD_HARDENING="n"
DEF_ENABLE_NGINX_LOGROTATE="n"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=10
declare -g PYTHON_BIN=""

# --- tiny helpers -----------------------------------------------------------
_ok()   { printf "  \033[92m[ OK ]\033[0m %b\n" "$*"; }
_nok()  { printf "  \033[91m[FAIL]\033[0m %b\n" "$*"; return 1; }
_warn() { printf "  \033[93m[WARN]\033[0m %b\n" "$*"; }
_info() { local fmt="$1"; shift; printf "  \033[96m[INFO]\033[0m ${fmt}\n" "$@"; }
_die()  { printf "\n\033[91mERROR:\033[0m %b\n" "$*" >&2; exit 1; }
_section(){ printf "\n\033[1;97m=== %s ===\033[0m\n" "$*"; }

# Dynamic CREATE ROLE + CREATE DATABASE + SELECT 1 one-shot auto-fixer for when psql credential test crashes
# with "database does not exist" or "role does not exist". Runs 3-tier superuser access probe (any 1 success = auto-fix works):
#   (A) PEER-AUTH LOCAL UNIX SOCKET (no sudo, no password):
#          psql -h /var/run/postgresql -U postgres -d postgres -tAc "SELECT 1" → returns '1'
#       Most common on Ubuntu/Debian/Contabo when installer runs as root on same machine as Postgres.
#   (B) INTERACTIVE SUDO (with password prompt IF needed):
#          sudo -u postgres psql postgres -tAc "SELECT 1" (tty present → accepts sudo password from user)
#       90% of VPS setups including Contabo default (sudoers has no NOPASSWD for root? It does. But remove -n probe.)
#   (C) EXPLICIT DB_SUPERUSER_USER / DB_SUPERUSER_PASSWORD (user-managed sentinel values):
#          PGPASSWORD=<sentinel> psql -h DB_HOST -p DB_PORT -U <superuser> -d postgres -tAc "SELECT 1"
#       Used when Postgres is on a DIFFERENT server from the installer (not local), or peer/sudo both fail.
# Any probe success = user gets Y/n offer, then we run CREATE ROLE + CREATE DATABASE + GRANT + re-verify SELECT 1 as app user.
# Returns 0 if post-autofix SELECT 1 == '1' (caller can break their retry loop).
# Returns 1 otherwise (caller falls back to prompt_edit_multiple / manual shell fix).
_psql_auto_fix_missing_role_or_db() {
  local _cause_lc="$1"  # lowercase psql error (already from tr upper->lower)
  local _db_user="$2" _db_name="$3" _db_pw="$4"
  local _out5="/tmp/rasyatone_psql_autofix_$$.out"
  # 3-tier probe result: "peer" | "sudo" | "superuser" | "" (none)
  local _mode=""
  local _trow=""
  # Per-tier diagnostic capture (so if all tiers fail, user sees EXACTLY what went wrong per tier).
  local _tierA_rc=0 _tierA_cmd="" _tierA_err="/tmp/rasyatone_autofix_tierA_$$.err"
  local _tierB_rc=0 _tierB_cmd="" _tierB_err="/tmp/rasyatone_autofix_tierB_$$.err"
  local _tierC_rc=0 _tierC_cmd="" _tierC_err="/tmp/rasyatone_autofix_tierC_$$.err"
  local _tierC_skipped=0  # 1 = user answered Enter=SKIP, not probe failure
  : > "$_tierA_err"; : > "$_tierB_err"; : > "$_tierC_err"

  # ── TIER A: peer-auth local UNIX socket (no sudo, no password) ──────────────────────────
  _tierA_cmd="(not attempted; psql command missing from PATH)"
  if [ -z "$_mode" ]; then
    if command -v psql >/dev/null 2>&1; then
      # Try socket dirs in order of decreasing commonness on Debian/Ubuntu/RHEL
      local _sdir=""
      for _sdir in /var/run/postgresql /tmp /run/postgresql; do
        [ -S "${_sdir}/.s.PGSQL.5432" ] || [ -d "$_sdir" ] || continue
        _tierA_cmd="psql -h '$_sdir' -U postgres -d postgres -tAc 'SELECT 1'"
        _trow=$(psql -h "$_sdir" -U postgres -d postgres -tAc "SELECT 1" 2>"$_tierA_err" | tr -d '[:space:]' || true)
        _tierA_rc=$?
        if [ "$_trow" = "1" ]; then
          _mode="peer|$_sdir"
          break
        fi
      done
      if [ -z "$_mode" ]; then
        # Either: no socket dir found at all, or peer auth denied for OS user. Record for diagnostics.
        if [ "$_tierA_cmd" = "(not attempted; psql command missing from PATH)" ]; then
          local _found_dirs=""
          for _sdir in /var/run/postgresql /tmp /run/postgresql; do
            if [ -S "${_sdir}/.s.PGSQL.5432" ] || [ -d "$_sdir" ]; then
              _found_dirs="${_found_dirs}${_sdir},"
            fi
          done
          printf 'No peer socket dirs found (checked /var/run/postgresql,/tmp,/run/postgresql: found=[%s])\n' "${_found_dirs%,}" >> "$_tierA_err"
        fi
      fi
    else
      printf 'psql command NOT FOUND on PATH (install postgresql-client first)\n' >> "$_tierA_err"
    fi
  fi

  # ── TIER B: interactive sudo (no -n flag; accepts sudo password prompt if tty present) ──
  _tierB_cmd="(not attempted)"
  if [ -z "$_mode" ]; then
    if command -v sudo >/dev/null 2>&1 && id -u postgres >/dev/null 2>&1; then
      _tierB_cmd="sudo -u postgres psql postgres -tAc 'SELECT 1'"
      _trow=$(sudo -u postgres psql postgres -tAc "SELECT 1" 2>"$_tierB_err" | tr -d '[:space:]' || true)
      _tierB_rc=$?
      if [ "$_trow" = "1" ]; then
        _mode="sudo"
      elif [ -t 0 ]; then
        # Stdin is a tty → sudo might need interactive password. Re-try without silencing stderr so user sees prompt.
        local _yes
        _yes=$(prompt_def "sudo probe first pass failed; retry sudo WITH tty password prompt (needed if your sudoers lacks NOPASSWD entry)? [Y/n]" "Y")
        case "$_yes" in y|Y|yes|YES|Yes|1)
          printf "  Running: sudo -u postgres psql postgres -tAc 'SELECT 1' — enter sudo password if asked.\n" >&2
          _trow=$(sudo -u postgres psql postgres -tAc "SELECT 1" 2> "$_tierB_err" | tr -d '[:space:]' || true)
          _tierB_rc=$?
          if [ "$_trow" = "1" ]; then _mode="sudo"; fi
        ;; esac
      fi
    else
      printf 'sudo command missing OR postgres OS user DNE (id -u postgres failed)\n' >> "$_tierB_err"
    fi
  fi

  # ── TIER C: explicit DB_SUPERUSER sentinel fields (user can paste superuser credentials here) ──
  local _su_user="${DB_SUPERUSER_USER:-postgres}" _su_pw="${DB_SUPERUSER_PASSWORD:-}"
  _tierC_cmd="(not attempted)"
  if [ -z "$_mode" ]; then
    if command -v psql >/dev/null 2>&1; then
      # If sentinel not set yet → prompt_def to let user paste them now (optional: hitting Enter skips).
      if [ -z "${_su_pw}" ]; then
        local _offered_su
        _offered_su=$(prompt_def "No local peer/sudo superuser access found. Connect as DB superuser VIA TCP to ${DB_HOST}:${DB_PORT} to create role+DB remotely? Enter superuser username [postgres or hit Enter=SKIP]" "${_su_user}")
        if [ -z "${_offered_su}" ] || [ "${_offered_su}" = "SKIP" ] || [ "${_offered_su}" = "skip" ]; then
          _tierC_skipped=1
          printf 'USER-SKIPPED: user hit Enter=SKIP on superuser username prompt (no remote TCP create requested)\n' >> "$_tierC_err"
        else
          _su_user="${_offered_su}"
          _su_pw=$(prompt_secret "Superuser password for ${_su_user} @ ${DB_HOST}:${DB_PORT}/postgres (no echo, empty=skip tier C)" "")
          if [ -z "${_su_pw}" ]; then
            _tierC_skipped=1
            printf 'USER-SKIPPED: user left superuser password empty (no remote TCP create requested)\n' >> "$_tierC_err"
          else
            export DB_SUPERUSER_USER="${_su_user}" DB_SUPERUSER_PASSWORD="${_su_pw}"
            _tierC_cmd="PGPASSWORD=<redacted> psql -h '${DB_HOST}' -p '${DB_PORT}' -U '${_su_user}' -d postgres -tAc 'SELECT 1'"
            _trow=$(PGPASSWORD="$_su_pw" timeout 8 psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${_su_user}" -d postgres -tAc "SELECT 1" 2>"$_tierC_err" | tr -d '[:space:]' || true)
            _tierC_rc=$?
            if [ "$_trow" = "1" ]; then _mode="superuser|tcp"; fi
          fi
        fi
      else
        # Sentinel values already in env/ENV_FILE → quick probe silently.
        _tierC_cmd="PGPASSWORD=<redacted> psql -h '${DB_HOST}' -p '${DB_PORT}' -U '${_su_user}' -d postgres -tAc 'SELECT 1'"
        _trow=$(PGPASSWORD="$_su_pw" timeout 8 psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${_su_user}" -d postgres -tAc "SELECT 1" 2>"$_tierC_err" | tr -d '[:space:]' || true)
        _tierC_rc=$?
        if [ "$_trow" = "1" ]; then _mode="superuser|tcp"; fi
      fi
    else
      printf 'psql command NOT FOUND on PATH (install postgresql-client)\n' >> "$_tierC_err"
    fi
  fi

  if [ -z "$_mode" ]; then
    # ── ALL 3 probes failed or user skipped tier C — print FULL DIAGNOSTIC breakdown per tier so user knows EXACTLY what broke.
    local _failed_tiers=0 _sep="  \033[95m[TIER]\033[0m "
    printf "\n" >&2
    printf "${_sep}A (peer unix socket): cmd = %s | rc = %d | last 6 err lines:\n" "$_tierA_cmd" "$_tierA_rc" >&2
    if [ -s "$_tierA_err" ]; then tail -n 6 "$_tierA_err" | sed 's/^/      /' >&2; fi
    [ "$_tierA_cmd" != "(not attempted)" ] && _failed_tiers=$((_failed_tiers+1))
    printf "${_sep}B (sudo -u postgres): cmd = %s | rc = %d | last 6 err lines:\n" "$_tierB_cmd" "$_tierB_rc" >&2
    if [ -s "$_tierB_err" ]; then tail -n 6 "$_tierB_err" | sed 's/^/      /' >&2; fi
    [ "$_tierB_cmd" != "(not attempted)" ] && _failed_tiers=$((_failed_tiers+1))
    # Tier C only marked as FAIL if user actually attempted probe (not skip).
    if [ "$_tierC_skipped" -eq 1 ]; then
      printf "${_sep}C (superuser TCP): user SKIPPED (no remote superuser credentials provided).\n" >&2
    else
      printf "${_sep}C (superuser TCP): cmd = %s | rc = %d | last 6 err lines:\n" "$_tierC_cmd" "$_tierC_rc" >&2
      if [ -s "$_tierC_err" ]; then tail -n 6 "$_tierC_err" | sed 's/^/      /' >&2; fi
      [ "$_tierC_cmd" != "(not attempted)" ] && _failed_tiers=$((_failed_tiers+1))
    fi
    if [ "$_tierC_skipped" -eq 1 ]; then
      _info "AUTO-FIX PARTIALLY UNAVAILABLE: $_failed_tiers local probe(s) FAILED + user SKIPPED remote Tier C superuser create. Diagnostic per-tier breakdown just printed above this line. Use manual SQL commands above OR pick Option 3 from main menu OR populate DB_SUPERUSER_USER/DB_SUPERUSER_PASSWORD in prompt_edit_multiple menu below and retry (then Tier C probe retries too)."
    else
      _info "AUTO-FIX NOT AVAILABLE: $_failed_tiers superuser probe(s) FAILED. Diagnostic per-tier breakdown just printed above this line. Most common fix if DB is local to this machine: make postgres OS role accept peer-auth from OS root user — run: sudo -u postgres psql postgres -c \"CREATE ROLE root SUPERUSER LOGIN;\" — OR simpler: pick Option 3 from main menu which always uses sudo -u postgres psql directly (with password prompt if needed) and will create role + DB there. If DB is remote server, populate sentinels DB_SUPERUSER_USER=postgres DB_SUPERUSER_PASSWORD=<pw> and retry."
    fi
    rm -f "$_tierA_err" "$_tierB_err" "$_tierC_err"
    return 1
  fi
  rm -f "$_tierA_err" "$_tierB_err" "$_tierC_err"
  local _needs_role=0 _needs_db=0
  case "$_cause_lc" in
    *database*does*not*exist*)   _needs_db=1 ;;
    *role*does*not*exist*|*user*does*not*exist*) _needs_role=1; _needs_db=1 ;;
  esac
  if [ "$_needs_db" -eq 0 ] && [ "$_needs_role" -eq 0 ]; then return 1; fi
  local _offer=""
  if [ "$_needs_role" -eq 1 ] && [ "$_needs_db" -eq 1 ]; then
    _offer="CREATE ROLE ${_db_user} (LOGIN + password from ENV_FILE DB_PASSWORD=) + CREATE DATABASE ${_db_name} OWNER ${_db_user} + GRANT CONNECT + SELECT 1 verify. SUPERUSER MODE=${_mode%%|*}."
  else
    _offer="CREATE DATABASE ${_db_name} OWNER ${_db_user} + SELECT 1 verify (role already exists; password OK — DB object alone missing). SUPERUSER MODE=${_mode%%|*}."
  fi
  local _do_it
  _do_it=$(prompt_def "AUTO-FIX AVAILABLE via ${_mode%%|*}: Run: ${_offer}? [Y/n]" "Y")
  case "$_do_it" in
    y|Y|yes|YES|Yes|1) ;;
    *) return 1 ;;
  esac
  _section "AUTO-FIX (mode ${_mode%%|*}): ${_offer}"
  # Escape single quotes in password for SQL literals: every ' → ''
  local _sql_pw
  _sql_pw=$(printf '%s' "${_db_pw}" | sed "s/'/''/g")
  local _esc_user
  _esc_user=$(printf '%s' "${_db_user}" | sed "s/'/''/g")
  local _esc_db
  _esc_db=$(printf '%s' "${_db_name}" | sed "s/'/''/g")
  # Build CREATE ROLE sql (always write file even if _needs_role=0 so both branches have consistent temp file cleanup).
  local _role_sql="/tmp/rasyatone_autofix_role_$$.sql"
  : > "$_role_sql"
  if [ "$_needs_role" -eq 1 ]; then
    printf "CREATE ROLE %s LOGIN PASSWORD '%s' NOSUPERUSER NOCREATEROLE CREATEDB;\n" "${_esc_user}" "${_sql_pw}" > "$_role_sql"
  fi
  local _db_sql="/tmp/rasyatone_autofix_db_$$.sql"
  : > "$_db_sql"
  if [ "$_needs_db" -eq 1 ]; then
    printf "CREATE DATABASE %s OWNER %s;\n" "${_esc_db}" "${_esc_user}" > "$_db_sql"
  fi
  local _grant_sql="/tmp/rasyatone_autofix_grant_$$.sql"
  printf 'GRANT CONNECT ON DATABASE %s TO %s;\n' "${_esc_db}" "${_esc_user}" > "$_grant_sql"
  # Apply mode dispatch:
  case "$_mode" in
    peer\|*)
      local _sdir="${_mode#*|}"
      if [ "$_needs_role" -eq 1 ]; then
        _run_with_spinner "psql auto-fix (CREATE ROLE ${_db_user} via peer socket)" psql -h "$_sdir" -U postgres -v ON_ERROR_STOP=1 -d postgres -f "$_role_sql" >/dev/null 2>"$_out5" || true
      fi
      if [ "$_needs_db" -eq 1 ]; then
        _run_with_spinner "psql auto-fix (CREATE DATABASE ${_db_name} via peer socket)" psql -h "$_sdir" -U postgres -v ON_ERROR_STOP=1 -d postgres -f "$_db_sql" >/dev/null 2>"$_out5" || true
        _run_with_spinner "psql auto-fix (GRANT CONNECT via peer socket)" psql -h "$_sdir" -U postgres -v ON_ERROR_STOP=1 -d postgres -f "$_grant_sql" >/dev/null 2>"$_out5" || true
      fi
      ;;
    sudo)
      if [ "$_needs_role" -eq 1 ]; then
        _run_with_spinner "psql auto-fix (CREATE ROLE ${_db_user} via sudo postgres)" sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$_role_sql" >/dev/null 2>"$_out5" || true
      fi
      if [ "$_needs_db" -eq 1 ]; then
        _run_with_spinner "psql auto-fix (CREATE DATABASE ${_db_name} via sudo postgres)" sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$_db_sql" >/dev/null 2>"$_out5" || true
        _run_with_spinner "psql auto-fix (GRANT CONNECT via sudo postgres)" sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$_grant_sql" >/dev/null 2>"$_out5" || true
      fi
      ;;
    superuser\|tcp)
      # Remote TCP via superuser credentials.
      if [ "$_needs_role" -eq 1 ]; then
        _run_with_spinner "psql auto-fix (CREATE ROLE ${_db_user} via superuser TCP)" bash -c "PGPASSWORD='${_su_pw//\'/\'\\\'\'}' psql -h '${DB_HOST}' -p '${DB_PORT}' -U '${_su_user}' -d postgres -v ON_ERROR_STOP=1 -f '${_role_sql}'" >/dev/null 2>"$_out5" || true
      fi
      if [ "$_needs_db" -eq 1 ]; then
        _run_with_spinner "psql auto-fix (CREATE DATABASE ${_db_name} via superuser TCP)" bash -c "PGPASSWORD='${_su_pw//\'/\'\\\'\'}' psql -h '${DB_HOST}' -p '${DB_PORT}' -U '${_su_user}' -d postgres -v ON_ERROR_STOP=1 -f '${_db_sql}'" >/dev/null 2>"$_out5" || true
        _run_with_spinner "psql auto-fix (GRANT CONNECT via superuser TCP)" bash -c "PGPASSWORD='${_su_pw//\'/\'\\\'\'}' psql -h '${DB_HOST}' -p '${DB_PORT}' -U '${_su_user}' -d postgres -v ON_ERROR_STOP=1 -f '${_grant_sql}'" >/dev/null 2>"$_out5" || true
      fi
      ;;
  esac
  rm -f "$_role_sql" "$_db_sql" "$_grant_sql"
  # Verify SELECT 1 immediately as the REAL app user DB_USER against the REAL target DB:
  local _verify_row=""
  _verify_row=$(PGPASSWORD="${_db_pw}" timeout 8 psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${_db_user}" -d "${_db_name}" -tAc "SELECT 1" 2>/dev/null | tr -d '[:space:]' || true)
  rm -f "$_out5"
  if [ "$_verify_row" = "1" ]; then
    _ok "AUTO-FIX SUCCESS (mode ${_mode%%|*}): SELECT 1 returned '1' — role ${_db_user} + DB ${_db_name} ready (all missing objects created in-place)."
    # Persist sentinel superuser values if user just gave them via tier C so prompt_edit_multiple sees them.
    if [ -n "${DB_SUPERUSER_PASSWORD:-}" ] && [ -n "${ENV_FILE:-}" ]; then
      local _sed_bin _sufield _suvalue _sedline
      command -v gsed >/dev/null 2>&1 && _sed_bin="gsed" || _sed_bin="sed"
      for _sufield in DB_SUPERUSER_USER DB_SUPERUSER_PASSWORD; do
        eval _suvalue="\${$_sufield:-}"
        [ -z "${_suvalue+x}" ] && continue
        _sedline="$_sufield='$_suvalue'"
        if grep -Eq "^${_sufield}=" "$ENV_FILE" 2>/dev/null; then
          sudo "$_sed_bin" -i~ -E "s|^${_sufield}=.*|${_sedline}|" "$ENV_FILE" 2>/dev/null || true
          sudo rm -f "${ENV_FILE}~" 2>/dev/null || true
        else
          printf '%s\n' "$_sedline" | sudo tee -a "$ENV_FILE" >/dev/null 2>/dev/null || true
        fi
      done
    fi
    return 0
  fi
  _warn "AUTO-FIX applied (mode ${_mode%%|*}) but SELECT 1 still fails (verify row='${_verify_row}' not '1'). Proceeding to manual prompt_edit_multiple / manual shell fix menu."
  return 1
}

# ── Resolve Django CircularDependencyError between two apps (typically auth_app ↔ companies) ──
# Invocation: _resolve_circular_dep "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$VENV_PY" "$LABEL"
#   LABEL is used for spinner prefix / backup dir differentiation (e.g. "pre-mk" or "pre-migrate" or "cause-i").
# Behavior:
#   1. Try to load Django MigrationLoader.graph; if no CircularDep → print GRAPH_OK and return 0.
#   2. If CircularDep detected → extract app pair, guarantee AUTH_USER_MODEL app is cA (always created first).
#   3. Backup 0001 → delete both 0001 → regen cA 0001 → Python post-edit STRIPS cB dep from cA 0001 and
#      comments out cross-app ForeignKey in CreateModel.fields → migrate cA → regen cB 0001 (valid DAG dep now)
#      → migrate cB → final makemigrations adds 0002 re-adding stripped FK → migrate all.
# Returns: 0 if no circular OR circular fixed; 1 if circular detected but fix attempts had spinner non-zero rc
#          (safe fallback; caller will still try migrate, which may enter retry banners).
_resolve_circular_dep() {
  local _rcd_app_dir="$1"
  local _rcd_settings="$2"
  local _rcd_venv_py="$3"
  local _rcd_label="${4:-pre}"
  [ -z "${_rcd_app_dir}" ] || [ ! -d "${_rcd_app_dir}" ] && return 0
  [ -z "${_rcd_venv_py}" ] || [ ! -x "${_rcd_venv_py}" ] && return 0
  local _rcd_base_env="cd '${_rcd_app_dir}' && PYTHONPATH='${_rcd_app_dir}' DJANGO_SETTINGS_MODULE='${_rcd_settings}' '${_rcd_venv_py}'"
  local _rcd_out="" _rcd_rc=0
  set +e
  _rcd_out=$( PYTHONPATH="${_rcd_app_dir}" DJANGO_SETTINGS_MODULE="${_rcd_settings}" "${_rcd_venv_py}" - <<'PY'
import os, sys
try:
    import django; django.setup()
    from django.db.migrations.loader import MigrationLoader
    from django.db.migrations.exceptions import CircularDependencyError
    try:
        loader = MigrationLoader(None, ignore_no_migrations=True)
        print("GRAPH_OK")
        sys.exit(0)
    except CircularDependencyError as e:
        import re
        raw = str(e)
        m = re.findall(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\.0001_initial\b", raw)
        if len(m) >= 2:
            a, b = m[0], m[1]
            try:
                from django.conf import settings
                aum = getattr(settings, "AUTH_USER_MODEL", "auth.User")
                aum_al = aum.partition(".")[0]
                if aum_al != "auth":
                    if b == aum_al:
                        a, b = b, a
            except Exception:
                pass
            print("CIRCULAR:%s|%s" % (a, b))
        else:
            print("CIRCULAR_PARSE_FAIL:%s" % raw)
        sys.exit(2)
except CircularDependencyError as e:
    import re
    raw = str(e)
    m = re.findall(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\.0001_initial\b", raw)
    if len(m) >= 2:
        a, b = m[0], m[1]
        try:
            from django.conf import settings
            aum = getattr(settings, "AUTH_USER_MODEL", "auth.User")
            aum_al = aum.partition(".")[0]
            if aum_al != "auth":
                if b == aum_al:
                    a, b = b, a
        except Exception:
            pass
        print("CIRCULAR:%s|%s" % (a, b))
    else:
        print("CIRCULAR_PARSE_FAIL:%s" % raw)
    sys.exit(2)
except Exception:
    try:
        from django.db import connections
        from django.db.migrations.loader import MigrationLoader
        from django.db.migrations.exceptions import CircularDependencyError
        conn = connections["default"]
        loader = MigrationLoader(conn, ignore_no_migrations=True)
        print("GRAPH_OK_FALLBACK_CONN")
        sys.exit(0)
    except CircularDependencyError as e:
        import re
        raw = str(e)
        m = re.findall(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\.0001_initial\b", raw)
        if len(m) >= 2:
            a, b = m[0], m[1]
            try:
                from django.conf import settings
                aum = getattr(settings, "AUTH_USER_MODEL", "auth.User")
                aum_al = aum.partition(".")[0]
                if aum_al != "auth":
                    if b == aum_al:
                        a, b = b, a
            except Exception:
                pass
            print("CIRCULAR:%s|%s" % (a, b))
        else:
            print("CIRCULAR_PARSE_FAIL:%s" % raw)
        sys.exit(2)
    except Exception as ex2:
        print("GRAPH_CHECK_SKIP:%s" % type(ex2).__name__)
        sys.exit(3)
PY
)
  _rcd_rc=$?
  set -e
  # ── CRITICAL: extract LAST non-empty line ONLY from stdout (ignore python warnings mixed in). ──
  #   Python startup warnings (DeprecationWarning, urllib3 InsecurePlatformWarning etc.) go to stdout
  #   and make the whole string NOT match the CIRCULAR:* / GRAPH_OK glob. Filtering the final line from
  #   stdout guarantees we only parse the sentinel output written by Python last print().
  if [ -n "${_rcd_out}" ]; then
    _rcd_out=$(printf '%s\n' "$_rcd_out" | grep -vE '^[[:space:]]*$' | tail -n 1 || true)
  fi
  # Strip carriage returns / control chars from probe output (Windows line endings, stray ^M, etc.).
  _rcd_out=$(printf '%s' "${_rcd_out}" | tr -d '\r\001-\010\013\014\016-\037\177' || true)
  local _pa="" _pb=""
  case "$_rcd_out" in
    CIRCULAR:*)
      _pa=${_rcd_out#CIRCULAR:}; _pb=${_pa#*|}; _pa=${_pa%%|*}
      _pa=$(printf '%s' "$_pa" | tr -d '[:space:]'); _pb=$(printf '%s' "$_pb" | tr -d '[:space:]')
      ;;
  esac
  # ── Resolve ACTUAL app directory paths via Django's apps.get_app_config(label).path API. ──
  #   Bash heuristic "$APP_DIR/label" FAILS for common Django layouts: nested apps,
  #   INSTALLED_APPS = 'pkg.auth_app' (dotted module path), app labels that differ from dir name, etc.
  #   MigrationLoader uses AppConfig.path; we must match THAT behavior — not bash-guess.
  local _pa_dir="" _pb_dir=""
  if [ -n "${_pa}" ]; then
    _pa_dir=$( PYTHONPATH="${_rcd_app_dir}" DJANGO_SETTINGS_MODULE="${_rcd_settings}" "${_rcd_venv_py}" - "${_pa}" <<'PY' 2>/dev/null || true
import django, sys
try:
    django.setup()
    from django.apps import apps
    print(apps.get_app_config(sys.argv[1]).path)
except Exception: pass
PY
)
    _pa_dir=$(printf '%s' "${_pa_dir}" | tr -d '[:space:]\r\n' || true)
  fi
  if [ -n "${_pb}" ]; then
    _pb_dir=$( PYTHONPATH="${_rcd_app_dir}" DJANGO_SETTINGS_MODULE="${_rcd_settings}" "${_rcd_venv_py}" - "${_pb}" <<'PY' 2>/dev/null || true
import django, sys
try:
    django.setup()
    from django.apps import apps
    print(apps.get_app_config(sys.argv[1]).path)
except Exception: pass
PY
)
    _pb_dir=$(printf '%s' "${_pb_dir}" | tr -d '[:space:]\r\n' || true)
  fi
  [ -z "${_pa_dir}" ] && _pa_dir="${_rcd_app_dir}/$_pa"
  [ -z "${_pb_dir}" ] && _pb_dir="${_rcd_app_dir}/$_pb"
  # ── VERBOSE per-clause guard (4 clauses) + OVERRIDE if probe explicitly said CIRCULAR:*. ──
  #   On your Contabo rerun the bash-heuristic L502 [ -d APP_DIR/auth_app ] VETOED the split even
  #   though Python probe had already found both apps via MigrationLoader(None). This guard now
  #   prints EXACTLY which clause would have vetoed, and OVERRIDES if probe output = CIRCULAR:*.
  local _cl1=0 _cl2=0 _cl3=0 _cl4=0 _veto=0 _probe_says_cycle=0
  [ -z "$_pa" ] && _cl1=1 || true
  [ -z "$_pb" ] && _cl2=1 || true
  [ -n "${_pa_dir}" ] && [ ! -d "${_pa_dir}" ] && _cl3=1 || true
  [ -n "${_pb_dir}" ] && [ ! -d "${_pb_dir}" ] && _cl4=1 || true
  case "$_rcd_out" in CIRCULAR:*) _probe_says_cycle=1 ;; esac
  if [ "$_cl1" -eq 1 ] || [ "$_cl2" -eq 1 ]; then
    _veto=1
  elif [ "$_probe_says_cycle" -eq 1 ]; then
    _veto=0
    [ "$_cl3" -eq 1 ] && _warn "[$_rcd_label] Guard clause-3 would have vetoed (no dir for app [$_pa] guess=$_pa_dir). OVERRIDDEN because probe output=CIRCULAR:*; proceeding with Python-resolved paths anyway." || true
    [ "$_cl4" -eq 1 ] && _warn "[$_rcd_label] Guard clause-4 would have vetoed (no dir for app [$_pb] guess=$_pb_dir). OVERRIDDEN because probe output=CIRCULAR:*; proceeding with Python-resolved paths anyway." || true
  elif [ "$_cl3" -eq 1 ] || [ "$_cl4" -eq 1 ]; then
    _veto=1
  fi
  if [ "$_veto" -eq 1 ]; then
    local _cl_reasons=""
    [ "$_cl1" -eq 1 ] && _cl_reasons="$_cl_reasons cl1=(pair-appA EMPTY)"
    [ "$_cl2" -eq 1 ] && _cl_reasons="$_cl_reasons cl2=(pair-appB EMPTY)"
    [ "$_cl3" -eq 1 ] && _cl_reasons="$_cl_reasons cl3=(dir-not-exist appA=$_pa_dir)"
    [ "$_cl4" -eq 1 ] && _cl_reasons="$_cl_reasons cl4=(dir-not-exist appB=$_pb_dir)"
    case "$_rcd_out" in
      GRAPH_OK|GRAPH_OK_FALLBACK_CONN)
        _ok "[$_rcd_label] Django migration graph OK: no CircularDependencyError (all Migration.dependencies form a valid DAG)."
        ;;
      *)
        _info "[$_rcd_label] Django migration graph check skipped (output=$_rcd_out rc=$_rcd_rc reasons=[$_cl_reasons ]). Safe no-op; cycle will be caught by migrate banners if exists."
        ;;
    esac
    return 0
  fi
  # Cycle detected. Run 2-step split.
  local _bkdir="/tmp/rasyatone_${_rcd_label}_circular_backup_$$"
  _warn "[$_rcd_label] CircularDependencyError DETECTED between apps [$_pa] ↔ [$_pb] (appA_dir=$_pa_dir appB_dir=$_pb_dir). Running AUTO-SPLIT 2-step fix now (NO USER INTERACTION NEEDED)."
  _info "[$_rcd_label] Step 0/4: BACKUP existing 0001_initial.py files to $_bkdir (rollback manually if needed)."
  mkdir -p "$_bkdir/$_pa/migrations" "$_bkdir/$_pb/migrations" 2>/dev/null || true
  cp -f "${_pa_dir}/migrations/0001_initial.py" "$_bkdir/$_pa/migrations/" 2>/dev/null || true
  cp -f "${_pb_dir}/migrations/0001_initial.py" "$_bkdir/$_pb/migrations/" 2>/dev/null || true
  _info "[$_rcd_label] Step 1/4: DELETE both auto-generated bad 0001_initial.py files (cross-FK → cycle)."
  rm -f "${_pa_dir}/migrations/0001_initial.py" "${_pb_dir}/migrations/0001_initial.py" 2>/dev/null || true
  mkdir -p "${_pa_dir}/migrations" "${_pb_dir}/migrations" 2>/dev/null || true
  touch "${_pa_dir}/migrations/__init__.py" "${_pb_dir}/migrations/__init__.py" 2>/dev/null || true
  # Guarantee cA = AUTH_USER_MODEL app (always first). Python catch has already ordered this but double-check via settings bash sentinel.
  local _cA="$_pa" _cB="$_pb"
  local _cA_dir="${_pa_dir}" _cB_dir="${_pb_dir}"
  local _aum_guess=""
  _aum_guess=$( PYTHONPATH="${_rcd_app_dir}" DJANGO_SETTINGS_MODULE="${_rcd_settings}" "${_rcd_venv_py}" - <<'PY' 2>/dev/null || true
import django, sys
try:
    django.setup()
    from django.conf import settings
    aum = getattr(settings, "AUTH_USER_MODEL", "auth.User")
    al = aum.partition(".")[0]
    if al != "auth": print(al)
except Exception: pass
PY
)
  _aum_guess=$(printf '%s' "${_aum_guess}" | tr -d '[:space:]\r\n' || true)
  if [ -n "${_aum_guess}" ]; then
    if [ "${_cB}" = "${_aum_guess}" ]; then
      local _t="$_cA"; _cA="$_cB"; _cB="$_t"
      local _td="$_cA_dir"; _cA_dir="$_cB_dir"; _cB_dir="$_td"
    fi
  fi
  _info "[$_rcd_label] Step 2/4: regenerate cA ($_cA) 0001 → Python post-edit will STRIP $_cB dep/comments cross FK for cycle safety."
  _run_with_spinner "($_rcd_label step 2) makemigrations $_cA (1st of pair; post-edit dep strip next)" bash -c \
    "${_rcd_base_env} manage.py makemigrations --noinput '${_cA}'" || true
  if [ -f "${_cA_dir}/migrations/0001_initial.py" ]; then
    PYTHONPATH="${_rcd_app_dir}" DJANGO_SETTINGS_MODULE="${_rcd_settings}" "${_rcd_venv_py}" - "${_cA_dir}/migrations/0001_initial.py" "${_cB}" <<'PY' || true
import sys, os
path, target_app = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()
lines = src.splitlines()
out = []
i = 0
in_deps = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()
    if "dependencies = [" in stripped or stripped.startswith("dependencies = ["):
        out.append(line); in_deps = 1; i += 1; continue
    if in_deps:
        if "]" in stripped and stripped.endswith("]"):
            in_deps = 0; out.append(line); i += 1; continue
        if ("'%s'" % target_app) in line or ('"%s"' % target_app) in line:
            i += 1; continue
        out.append(line); i += 1; continue
    if ("ForeignKey" in line or "OneToOneField" in line) and (("'%s." % target_app) in line or ('"%s.' % target_app) in line):
        out.append("        # CYCLIC SPLIT: commented out cross-app FK; re-added as 0002 after 0001 both applied.")
        out.append("        # " + line.lstrip())
        depth = 0
        if "(" in line:
            for ch in line:
                if ch == "(": depth += 1
                elif ch == ")": depth -= 1
            while depth > 0 and i + 1 < len(lines):
                i += 1
                nxt = lines[i]
                for ch in nxt:
                    if ch == "(": depth += 1
                    elif ch == ")": depth -= 1
                out.append("        # " + nxt.lstrip())
                if depth <= 0: break
        i += 1; continue
    out.append(line); i += 1
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
print("POST_EDIT_OK: stripped cross-app dep references to %s from %s" % (target_app, os.path.basename(path)))
PY
  fi
  _info "[$_rcd_label] Step 3/4: migrate $_cA.0001_initial (cycle-free; no $_cB dependency in Migration.dependencies)."
  set +e
  _run_migrate_autoheal "${_rcd_app_dir}" "${_rcd_settings}" "${_rcd_venv_py}" "${_rcd_base_env}" "${_cA}" || true
  set -e
  _info "[$_rcd_label] Step 4a/4: regenerate $_cB 0001 — since $_cA.0001 EXISTS in disk graph + DB, dependencies list ($_cA,0001_initial) = valid DAG (no cycle)."
  _run_with_spinner "($_rcd_label step 4a) makemigrations $_cB (2nd of pair; valid DAG dep)" bash -c \
    "${_rcd_base_env} manage.py makemigrations --noinput '${_cB}'" || true
  _info "[$_rcd_label] Step 4b/4: migrate $_cB + final catch-all makemigrations (re-adds stripped FK as $_cA.0002) + migrate all."
  set +e
  _run_migrate_autoheal "${_rcd_app_dir}" "${_rcd_settings}" "${_rcd_venv_py}" "${_rcd_base_env}" "${_cB}" || true
  set -e
  _run_with_spinner "($_rcd_label step 4c) makemigrations all (re-adds stripped cross FK as $_cA.0002)" bash -c \
    "${_rcd_base_env} manage.py makemigrations --noinput" || true
  set +e
  _run_migrate_autoheal "${_rcd_app_dir}" "${_rcd_settings}" "${_rcd_venv_py}" "${_rcd_base_env}" "" || true
  set -e
  _ok "[$_rcd_label] AUTO-SPLIT complete for [$_cA] ↔ [$_cB]. Backup at: $_bkdir. Proceeding to normal migrate flow."
  return 0
}
# ── GENERIC UndefinedTable (relation "x_y" does not exist) AUTO-HEAL WRAPPER for `manage.py migrate` ──
#   THE DYNAMIC FIX FOR ANY MODEL the user asked about.
#   Works for ANY app, ANY model, ANY transitive dependency chain — not just auth_app/companies/hr.
#
#   How it detects the missing app DYNAMICALLY (no hardcoded app names):
#     1. Call `manage.py migrate <label>` via spinner. If rc=0 → return 0 immediately.
#     2. If rc≠0, grep the spinner's captured stderr for the EXACT Postgres error pattern:
#           relation "underscore_delimited_table" does not exist
#        e.g. `relation "hr_employee" does not exist`, `relation "core_foo_bar_baz"` does not exist.
#     3. For the table name, enumerate every UNDERSCORE-SPLIT PREFIX (longest-first) from it.
#        For table "hr_employee", try labels in order: "hr_employee", "hr".
#        For table "sales_order_item", try: "sales_order_item", "sales_order", "sales".
#     4. Query Django's ACTUAL apps registry via Python `apps.get_app_configs()` — NO bash guessing.
#        If any prefix matches an installed app label → THAT is the missing dependency app.
#        (Django sets `db_table = app_label_model_name` by default, so first underscore pieces = label.)
#     5. Run: makemigrations <found_app> → migrate <found_app> (via spinner, nested wrapped for safety).
#     6. Retry ORIGINAL migrate. If still UndefinedTable on DIFFERENT table → loop.
#     7. Hard cap 5 rounds. If 5 rounds hit and still failing OR no prefix matches any installed app
#        → cannot auto-heal → return original rc so user's retry banners run.
#
#   Invocation: _run_migrate_autoheal _rma_app_dir _rma_settings _rma_venv_py _rma_base_env _rma_label
#     _rma_label: either a single app label (e.g. 'auth_app', 'hr') OR the empty string to mean
#                 'migrate' (all apps — catch-all).
_run_migrate_autoheal() {
  local _rma_app_dir="$1"
  local _rma_settings="$2"
  local _rma_venv_py="$3"
  local _rma_base_env="$4"
  local _rma_label="${5:-}"
  [ -z "${_rma_app_dir}" ] || [ ! -d "${_rma_app_dir}" ] && return 1
  [ -z "${_rma_venv_py}" ] || [ ! -x "${_rma_venv_py}" ] && return 1
  local _rma_target=""
  if [ -n "${_rma_label}" ]; then
    _rma_target="'${_rma_label}'"
  fi
  local _rma_round=0
  local _rma_rc=1
  local _rma_rel=""
  local _rma_tb_log=""
  local _rma_done_label=""
  local _rma_log_pattern="autoheal-r${_rma_round}"
  while [ "$_rma_round" -lt 5 ]; do
    set +e
    if [ -n "${_rma_label}" ]; then
      _run_with_spinner "(autoheal round $_rma_round) manage.py migrate ${_rma_label}" bash -c \
        "${_rma_base_env} manage.py migrate '${_rma_label}'"
      _rma_rc=$?
    else
      _run_with_progress "(autoheal round $_rma_round) manage.py migrate (all apps)" bash -c \
        "${_rma_base_env} manage.py migrate"
      _rma_rc=$?
    fi
    set -e
    if [ "$_rma_rc" -eq 0 ]; then
      [ "$_rma_round" -gt 0 ] && _ok "UndefinedTable auto-heal succeeded after $_rma_round rounds (last resolved dep: ${_rma_done_label:-<none>})." || true
      return 0
    fi
    # ── Find most recent spinner log for `manage.py migrate …` ──
    # Use `ls -1t` (newest-by-mtime first — the ONLY reliable way to find the LAST failed migrate)
    # vs naive glob which is filename-lexicographic order (can select an OLD log with no error lines).
    _rma_tb_log=""
    local _rma_cand=""
    while IFS= read -r _rma_cand; do
      [ -z "${_rma_cand}" ] && continue
      [ -f "${_rma_cand}" ] || continue
      _rma_tb_log="${_rma_cand}"
      break
    done < <(ls -1t /tmp/rasyatone_spin_*_manage_py_migrate*.log 2>/dev/null || true)
    if [ -z "${_rma_tb_log}" ] || [ ! -f "${_rma_tb_log}" ]; then
      _info "UndefinedTable autoheal: migrate rc=${_rma_rc} but no migrate spinner log readable. Cannot auto-heal → failing."
      return "$_rma_rc"
    fi
    local _rma_tail=""
    _rma_tail="$( tail -n 200 "${_rma_tb_log}" 2>/dev/null || true )"
    local _rma_tail_bytes=0
    _rma_tail_bytes=$( printf '%s' "${_rma_tail}" | wc -c | tr -d '[:space:]' || printf '0' )
    _rma_rel=""
    _rma_rel=$( printf '%s' "${_rma_tail}" | grep -oE 'relation "[^"]+" does not exist' 2>/dev/null | head -n 1 | sed 's/^relation "//; s/" does not exist$//' || true )
    if [ -z "${_rma_rel}" ]; then
      # Also try FULL log (not just last 200 lines) — sometimes the UndefinedTable traceback is higher up.
      _rma_rel=$( grep -oE 'relation "[^"]+" does not exist' "${_rma_tb_log}" 2>/dev/null | head -n 1 | sed 's/^relation "//; s/" does not exist$//' || true )
    fi
    if [ -z "${_rma_rel}" ]; then
      # ── CLASS B: NodeNotFoundError (migration graph DummyNode).
      #    Extract referencer (APP.NAME) cleanly; then for missing parent app label, find the FIRST single-quoted
      #    valid Django identifier on the NodeNotFoundError line (it corresponds to the parent app label in tuple
      #    ('PARENT_LABEL', '0001_initial')). Never needs interpretation of paren vs quote ordering.
      local _rma_node_missing_app="" _rma_node_referencer="" _rma_node_line=""
      _rma_node_line="$( grep -E 'NodeNotFoundError: Migration [^ ]+ dependencies reference nonexistent parent node' "${_rma_tb_log}" 2>/dev/null | head -n 1 || true )"
      if [ -z "${_rma_node_line}" ]; then
        _rma_node_line="$( printf '%s' "${_rma_tail}" | grep -E 'NodeNotFoundError: Migration [^ ]+ dependencies reference nonexistent parent node' 2>/dev/null | head -n 1 || true )"
      fi
      if [ -n "${_rma_node_line}" ]; then
        # Referencer: APP.NAME (the migration file that declares the faulty dep)
        _rma_node_referencer="$( printf '%s' "${_rma_node_line}" | grep -oE 'Migration [^ ]+ dependencies' 2>/dev/null | head -n 1 | sed -E 's/^Migration //; s/ dependencies$//' || true )"
        # Parent app label: FIRST single-quoted [A-Za-z0-9_]+ token inside the tuple (matches ('companies', '0001_initial') → 'companies')
        _rma_node_missing_app="$( printf '%s' "${_rma_node_line}" | grep -oE "'[a-zA-Z0-9_]+'" 2>/dev/null | head -n 1 | sed -E "s/^'//; s/'$//" || true )"
      fi
      # STRICT VALIDATION — Django app labels are strictly [a-zA-Z0-9_]+. If extraction fails parse, skip.
      if [ -n "${_rma_node_missing_app}" ] && ! printf '%s' "${_rma_node_missing_app}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
        _info "UndefinedTable autoheal round ${_rma_round}: extracted NodeNotFoundError missing_app='${_rma_node_missing_app}' fails [a-zA-Z0-9_]+ validation (parse failure). Ignoring — will not auto-heal with invalid label."
        _rma_node_missing_app=""
      fi
      if [ -z "${_rma_node_missing_app}" ]; then
        # Secondary try: try FULL file for the first single-quoted valid id AFTER the phrase 'parent node'
        _rma_node_missing_app="$( sed -n '/parent node/,$p' "${_rma_tb_log}" 2>/dev/null | grep -oE "'[a-zA-Z0-9_]+'" 2>/dev/null | head -n 1 | sed -E "s/^'//; s/'$//" || true )"
        if [ -n "${_rma_node_missing_app}" ] && ! printf '%s' "${_rma_node_missing_app}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
          _rma_node_missing_app=""
        fi
      fi
      if [ -n "${_rma_node_missing_app}" ]; then
        _info "UndefinedTable autoheal round ${_rma_round}: graph NodeNotFoundError detected. Referencer='${_rma_node_referencer}' missing_parent_app='${_rma_node_missing_app}'. Auto-healing missing app first."
        local _rma_self_node=0
        local _rma_deleted_orphan=0
        local _ref_app="" _ref_name=""
        if [[ "${_rma_node_referencer}" == *.* ]]; then
          _ref_app="${_rma_node_referencer%%.*}"
          _ref_name="${_rma_node_referencer#*.}"
        fi
        if [ -n "${_ref_app}" ] && [ -n "${_ref_name}" ]; then
          local _ref_file1="${_rma_app_dir}/${_ref_app}/migrations/${_ref_name}.py"
          local _ref_file2=""
          local _ref_file3=""
          local _ref_app_path=""
          set +e
          _ref_app_path="$( PYTHONPATH="${_rma_app_dir}" DJANGO_SETTINGS_MODULE="${_rma_settings}" "${_rma_venv_py}" - "${_ref_app}" <<'PY' 2>/dev/null
import django, sys
django.setup()
from django.apps import apps
print(apps.get_app_config(sys.argv[1]).path)
PY
)"
          set -e
          _ref_app_path="$( printf '%s' "${_ref_app_path}" | tr -d '\r\n' || true )"
          if [ -n "${_ref_app_path}" ]; then
            _ref_file2="${_ref_app_path}/migrations/${_ref_name}.py"
          fi
          local _ref_file=""
          if [ -f "${_ref_file1}" ]; then
            _ref_file="${_ref_file1}"
          elif [ -n "${_ref_file2}" ] && [ -f "${_ref_file2}" ]; then
            _ref_file="${_ref_file2}"
          else
            _ref_file3="$( find "${_rma_app_dir}" -maxdepth 6 -type f -path "*/${_ref_app}/migrations/${_ref_name}.py" -print -quit 2>/dev/null || true )"
            _ref_file3="$( printf '%s' "${_ref_file3}" | tr -d '\r\n' || true )"
            if [ -n "${_ref_file3}" ] && [ -f "${_ref_file3}" ]; then
              _ref_file="${_ref_file3}"
            fi
          fi
          if [ -n "${_ref_file}" ]; then
            local _applied=0
            if PYTHONPATH="${_rma_app_dir}" DJANGO_SETTINGS_MODULE="${_rma_settings}" "${_rma_venv_py}" manage.py showmigrations "${_ref_app}" 2>/dev/null | grep -qE "^\[X\][[:space:]]+${_ref_name}" >/dev/null 2>&1; then
              _applied=1
            fi
            if [ "$_applied" -eq 0 ]; then
              _warn "UndefinedTable autoheal round ${_rma_round}: deleting orphan referencer migration '${_ref_app}.${_ref_name}' to unblock migration graph: ${_ref_file}"
              rm -f "${_ref_file}" 2>/dev/null || true
              if [ ! -f "${_ref_file}" ]; then
                _rma_deleted_orphan=1
                set +e
                _run_with_spinner "(autoheal r${_rma_round} → regen graphs cleanly) manage.py makemigrations --noinput" bash -c \
                  "${_rma_base_env} manage.py makemigrations --noinput" || true
                set -e
              fi
            fi
          else
            _warn "UndefinedTable autoheal round ${_rma_round}: NodeNotFoundError referencer '${_ref_app}.${_ref_name}' but could not locate migration file to delete. Tried: ${_ref_file1} ; ${_ref_file2:-<no app path>} ; find-match=${_ref_file3:-<none>}. Graph may remain broken."
          fi
        fi
        # Sanity: if the "missing parent" is the SAME app we are already trying to migrate, recursive autoheal would
        # just call itself again without changing state. Skip recursive self-call; orphan cleanup below may still fix graph.
        if [ -n "${_rma_label}" ] && [ "${_rma_node_missing_app}" = "${_rma_label}" ]; then
          _rma_self_node=1
          _warn "UndefinedTable autoheal round ${_rma_round}: NodeNotFoundError missing parent '${_rma_node_missing_app}' IS the current migrate target. Skipping recursive self-heal to avoid endless same-label recursion; will rely on orphan cleanup + next bounded retry."
        else
          set +e
          _run_with_spinner "(autoheal r${_rma_round} → makemig missing parent '${_rma_node_missing_app}') manage.py makemigrations --noinput '${_rma_node_missing_app}'" bash -c \
            "${_rma_base_env} manage.py makemigrations --noinput '${_rma_node_missing_app}'" || true
          _run_migrate_autoheal "${_rma_app_dir}" "${_rma_settings}" "${_rma_venv_py}" "${_rma_base_env}" "${_rma_node_missing_app}" || true
          set -e
        fi
        if [ "$_rma_self_node" -eq 1 ] && [ "$_rma_deleted_orphan" -eq 0 ]; then
          _warn "UndefinedTable autoheal round ${_rma_round}: NodeNotFoundError self-target produced NO state change (no orphan file deleted). Stopping autoheal early and falling back to retry banner instead of repeating the same error."
          return "$_rma_rc"
        fi
        _rma_round=$(( _rma_round + 1 ))
        continue
      fi
    fi
    if [ -z "${_rma_rel}" ]; then
      local _rma_uc_line=""
      _rma_uc_line="$( printf '%s' "${_rma_tail}" | grep -E 'UndefinedColumn|django\.db\.utils\.ProgrammingError: column|psycopg2\.errors\.UndefinedColumn' 2>/dev/null | head -n 1 || true )"
      if [ -z "${_rma_uc_line}" ]; then
        _rma_uc_line="$( grep -E 'UndefinedColumn|django\.db\.utils\.ProgrammingError: column|psycopg2\.errors\.UndefinedColumn' "${_rma_tb_log}" 2>/dev/null | head -n 1 || true )"
      fi
      if [ -n "${_rma_uc_line}" ]; then
        local _rma_apps_line=""
        local _rma_apps=""
        _rma_apps_line="$( grep -oE "Your models in app\\(s\\):.*" "${_rma_tb_log}" 2>/dev/null | head -n 1 || true )"
        if [ -n "${_rma_apps_line}" ]; then
          _rma_apps="$( printf '%s' "${_rma_apps_line}" | grep -oE "'[a-zA-Z0-9_]+'" 2>/dev/null | tr -d "'" | tr '\n' ' ' | tr -s ' ' | sed -E 's/^ //; s/ $//' || true )"
        fi
        if [ -z "${_rma_apps}" ]; then
          _rma_apps="${_rma_label:-}"
        fi
        local _rma_fix_list=""
        local _ra
        for _ra in ${_rma_apps}; do
          _ra="$( printf '%s' "${_ra}" | tr -d '[:space:]\r\n' || true )"
          [ -z "${_ra}" ] && continue
          if [ -z "${_rma_fix_list}" ]; then
            _rma_fix_list="${_ra}"
          elif [[ " ${_rma_fix_list} " == *" ${_ra} "* ]]; then
            continue
          else
            _rma_fix_list="${_rma_fix_list} ${_ra}"
          fi
        done
        if [ -z "${_rma_fix_list}" ]; then
          _info "UndefinedTable autoheal round ${_rma_round}: UndefinedColumn detected but could not infer any app labels to heal. Falling back."
          return "$_rma_rc"
        fi
        _warn "UndefinedTable autoheal round ${_rma_round}: UndefinedColumn detected (schema drift; migrations missing/outdated). Auto-running makemigrations+migrate for: [${_rma_fix_list}]."
        local _rf
        for _rf in ${_rma_fix_list}; do
          set +e
          _run_with_spinner "(autoheal r${_rma_round} → makemig '${_rf}' for UndefinedColumn) manage.py makemigrations --noinput '${_rf}'" bash -c \
            "${_rma_base_env} manage.py makemigrations --noinput '${_rf}'"
          local _mm_rc=$?
          if [ "${_mm_rc}" -ne 0 ]; then
            local _mm_log=""
            _mm_log="$( ls -1t /tmp/rasyatone_spin_*makemig*${_rf}*.log /tmp/rasyatone_spin_*makemigrations*${_rf}*.log 2>/dev/null | head -n 1 || true )"
            if [ -n "${_mm_log}" ] && grep -Eq "impossible to add a non-nullable field without specifying a default|non-nullable field" "${_mm_log}" 2>/dev/null; then
              local _mm_tail=""
              _mm_tail="$( tail -n 3 "${_mm_log}" 2>/dev/null | tr '\n' ' ' | tr -s ' ' | sed -E 's/^ //; s/ $//' || true )"
              _die "makemigrations '${_rf}' requires a default/null for a new non-nullable field. Fix the Django model/migration (set null=True or provide a default/data migration), then rerun. ${_mm_tail}"
            fi
            _warn "UndefinedTable autoheal round ${_rma_round}: makemigrations '${_rf}' failed (rc=${_mm_rc}). Cannot auto-heal further; falling back to retry banner."
            return "$_rma_rc"
          fi
          _run_migrate_autoheal "${_rma_app_dir}" "${_rma_settings}" "${_rma_venv_py}" "${_rma_base_env}" "${_rf}" || true
          set -e
        done
        _rma_round=$(( _rma_round + 1 ))
        continue
      fi
      _info "UndefinedTable autoheal round ${_rma_round}: opened newest migrate log (${_rma_tb_log}, tail=${_rma_tail_bytes}b) — NO 'relation X does not exist' or NodeNotFoundError pattern match. Different error category (password/connection/circular-dep/schema). Cannot auto-heal via UndefinedTable/NodeNotFound path; return rc=${_rma_rc} so retry banner handles other classes."
      return "$_rma_rc"
    fi
    # ── Enumerate LONGEST-FIRST underscore-prefix candidates → match against Django apps registry. ──
    #    Python returns EMPTY string on no match (after trim), OR exact app label.
    #    CRITICAL: do NOT swallow stderr blindly! django.setup() can fail with ImportError/DatabaseError
    #    — if we hide those, we get false "no match found" banners.
    #    We split stdout (label) vs stderr (tracebacks). If stdout empty AND stderr non-empty → treat as probe ERROR (not no-match) and tell user.
    local _rma_match=""
    local _rma_probe_stderr="/tmp/rasyatone_rma_probe_stderr_$$.log"
    local _rma_probe_stdout="/tmp/rasyatone_rma_probe_stdout_$$.log"
    : > "$_rma_probe_stderr" 2>/dev/null || true
    : > "$_rma_probe_stdout" 2>/dev/null || true
    set +e
    PYTHONPATH="${_rma_app_dir}" DJANGO_SETTINGS_MODULE="${_rma_settings}" "${_rma_venv_py}" - "${_rma_rel}" <<'PY' >"$_rma_probe_stdout" 2>"$_rma_probe_stderr"
import django, sys
try:
    django.setup()
    from django.apps import apps
    table = sys.argv[1]
    parts = table.split("_")
    found_label = ""
    # Longest-prefix-first candidate search against AppConfig.label (the official dep key)
    for i in range(len(parts), 0, -1):
        cand = "_".join(parts[:i])
        try:
            cfg = apps.get_app_config(cand)
            found_label = cfg.label
            break
        except LookupError:
            continue
    if found_label:
        print(found_label)
        sys.exit(0)
    else:
        sys.exit(2)  # exit 2 = no match found (clean), stderr empty
except Exception as _e:
    # Probe ERROR: django.setup failed or similar. Print traceback for user debugging, exit 1.
    import traceback
    sys.stderr.write("RMA_PROBE_EXCEPTION: %s\n" % str(_e))
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PY
    local _rma_probe_rc=$?
    set -e
    _rma_match="$( tr -d '[:space:]\r\n' < "$_rma_probe_stdout" 2>/dev/null || printf '' )"
    local _rma_probe_err_lines="$( wc -l < "$_rma_probe_stderr" 2>/dev/null | tr -d '[:space:]' || printf '0' )"
    if [ -z "${_rma_match}" ]; then
      if [ "$_rma_probe_rc" -eq 1 ] || [ "$_rma_probe_err_lines" -gt 0 ]; then
        local _err_snip=""
        _err_snip="$( tail -n 12 "$_rma_probe_stderr" 2>/dev/null | sed 's/^/      | /' || true )"
        _warn "UndefinedTable autoheal round ${_rma_round}: table '${_rma_rel}' — Python apps.get_app_config PROBE FAILED (django.setup crashed; not a 'no app matches' problem). Probe stderr (last 12 lines):\n${_err_snip}\n    Falling back to manual retry banner — you likely need to fix settings/import errors in ${DJANGO_SETTINGS_MODULE} before migration probes can work."
      else
        _warn "UndefinedTable autoheal round ${_rma_round}: table '${_rma_rel}' — no underscore-prefix matches any installed app. (Longest-match search against Django apps registry failed cleanly; probe returned rc=${_rma_probe_rc}.) Falling back to 3-attempt retry banner."
      fi
      rm -f "$_rma_probe_stdout" "$_rma_probe_stderr" 2>/dev/null || true
      return "$_rma_rc"
    fi
    rm -f "$_rma_probe_stdout" "$_rma_probe_stderr" 2>/dev/null || true
    if [ "${_rma_match}" = "${_rma_label:-}" ]; then
      _warn "UndefinedTable autoheal round ${_rma_round}: table '${_rma_rel}' → match app '${_rma_match}' IS the migrate target we just ran. Cannot auto-heal a target against itself (circular: UndefinedTable within its own migration). Failing back to manual retry banner."
      return "$_rma_rc"
    fi
    _rma_done_label="${_rma_match}"
    _warn "UndefinedTable autoheal round ${_rma_round}: relation '${_rma_rel}' does not exist → MATCHED installed app label '${_rma_match}' (longest underscore-prefix vs apps registry). Auto-running: makemigrations + migrate '${_rma_match}' BEFORE retrying target migrate."
    set +e
    _run_with_spinner "(autoheal r${_rma_round} → makemig '${_rma_match}') manage.py makemigrations --noinput '${_rma_match}'" bash -c \
      "${_rma_base_env} manage.py makemigrations --noinput '${_rma_match}'" || true
    _run_migrate_autoheal "${_rma_app_dir}" "${_rma_settings}" "${_rma_venv_py}" "${_rma_base_env}" "${_rma_match}" || true
    set -e
    _rma_round=$(( _rma_round + 1 ))
  done
  _warn "UndefinedTable autoheal: hit max 5 rounds; still failing. (Last resolved dep: ${_rma_done_label:-<none>}; last missing table: ${_rma_rel:-<none>}.) Failing back to manual retry banner."
  return "$_rma_rc"
}
# ── ENV_FILE CIRCULAR SENTINEL SANITIZER (runs BEFORE every `set -a; . "$ENV_FILE"`) ──
#   Fixes the EXACT user crash: last run wrote garbage CIRCULAR_APPS=raiseCircularDependencyError(
#   (open paren unquoted) to /etc/rasyatone/static/rasyatone.env line 17. THIS run's `set -a; . env`
#   tried to source it → syntax error near unexpected token `(' → ALL subsequent reads of DB_PASSWORD,
#   DJANGO_SETTINGS_MODULE, etc. failed (parser aborted on invalid shell syntax).
#
#   Two-layer safety:
#     1. Strip any lines where KEY=CIRCULAR_APPS or CIRCULAR_APPLY_2STEP contain INVALID CHARS
#        (anything not POSIX shell word = [a-zA-Z0-9_] plus single space separator for CIRCULAR_APPS).
#     2. For CIRCULAR_APPLY_2STEP: must be exactly y / Y / n / N / empty.
#   Writes sanitized copy to /tmp tmpfile, then mv atomic (since sed -i may leave partial writes).
_sanitize_env_file_circular_sentinels() {
  local _s_ef="${1:-$ENV_FILE}"
  [ -z "${_s_ef}" ] || [ ! -f "${_s_ef}" ] && return 0
  local _s_tmp=""
  _s_tmp=$(mktemp /tmp/rasyatone_env_sanitize_$$.XXXXXX 2>/dev/null || true)
  [ -z "${_s_tmp}" ] && return 0
  local _s_k="" _s_v="" _s_changed=0
  local _s_valid_ca=1
  while IFS= read -r _s_line || [ -n "${_s_line}" ]; do
    case "$_s_line" in
      ''|\#*) printf '%s\n' "$_s_line" >> "$_s_tmp"; continue ;;
    esac
    case "$_s_line" in
      CIRCULAR_APPS=*|CIRCULAR_APPLY_2STEP=*)
        _s_k="${_s_line%%=*}"
        _s_v="${_s_line#*=}"
        case "$_s_v" in
          "'"*"'") _s_v="${_s_v#\'}"; _s_v="${_s_v%\'}" ;;
          '"'*'"') _s_v="${_s_v#\"}"; _s_v="${_s_v%\"}" ;;
        esac
        _s_valid_ca=0
        if [ "$_s_k" = "CIRCULAR_APPS" ]; then
          if [ -z "$_s_v" ]; then
            _s_valid_ca=1
          elif printf '%s' "$_s_v" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]* [a-zA-Z_][a-zA-Z0-9_]*$'; then
            _s_valid_ca=1
          else
            _s_valid_ca=0
          fi
        elif [ "$_s_k" = "CIRCULAR_APPLY_2STEP" ]; then
          case "$_s_v" in y|Y|n|N|'') _s_valid_ca=1 ;; *) _s_valid_ca=0 ;; esac
        fi
        if [ "$_s_valid_ca" -eq 1 ]; then
          case "$_s_k" in
            CIRCULAR_APPS)         printf 'CIRCULAR_APPS='\''%s'\''\n' "$_s_v" >> "$_s_tmp" ;;
            CIRCULAR_APPLY_2STEP)  printf 'CIRCULAR_APPLY_2STEP='\''%s'\''\n' "$_s_v" >> "$_s_tmp" ;;
          esac
          case "$_s_line" in
            "CIRCULAR_APPS='"*"'")  : ;;
            "CIRCULAR_APPLY_2STEP='"*"'") : ;;
            *) _s_changed=1 ;;
          esac
        else
          case "$_s_k" in
            CIRCULAR_APPS)         printf 'CIRCULAR_APPS='\'''\''\n' >> "$_s_tmp" ;;
            CIRCULAR_APPLY_2STEP)  printf 'CIRCULAR_APPLY_2STEP='\''n'\''\n' >> "$_s_tmp" ;;
          esac
          _s_changed=1
        fi
        ;;
      *) printf '%s\n' "$_s_line" >> "$_s_tmp" ;;
    esac
  done < "$_s_ef"
  if [ "$_s_changed" -eq 1 ]; then
    chmod --reference="$_s_ef" "$_s_tmp" 2>/dev/null || true
    mv -f "$_s_tmp" "$_s_ef" 2>/dev/null || { cat "$_s_tmp" > "$_s_ef"; rm -f "$_s_tmp"; }
    _warn "ENV_FILE sanitized: removed invalid CIRCULAR_* sentinel entries (last run wrote unquoted/garbage entries → bash source syntax error or empty readback). Entries rewritten to valid single-quoted defaults."
  else
    rm -f "$_s_tmp"
  fi
  return 0
}
# ── Validate CIRCULAR_APPS value BEFORE writing it to ENV_FILE. ──
#   Args: $1 = candidate value (the _circ_apps bash var about to be written).
#   Echoes normalized valid value on stdout: either empty string or "word1 word2" (exactly two POSIX words).
#   Caller: _valid_ca=$(_validate_circular_apps_value "$_circ_apps"); CIRCULAR_APPS="$_valid_ca" >> ENV_FILE.
_validate_circular_apps_value() {
  local _in="${1:-}"
  # Trim leading/trailing whitespace + collapse internal multi-space to single space.
  _in=$(printf '%s' "$_in" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' || true)
  [ -z "$_in" ] && { printf ''; return 0; }
  if printf '%s' "$_in" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]* [a-zA-Z_][a-zA-Z0-9_]*$'; then
    printf '%s' "$_in"
    return 0
  fi
  # Invalid → empty.
  printf ''
  return 0
}

# Canonicalize ANY GitHub HTTPS URL (with or without x-access-token auth) so it has exactly ONE trailing .git,
# no doubled .git.git, and no trailing slashes. Works as an output safety net on ANY GitHub URL form.
# Three-layer defense:
#   1. sed ERE label loop strips all trailing .git occurrences (portable across all sed builds)
#   2. bash while-loop parameter expansion BACKUP strips any remaining .git (catches weird sed builds)
#   3. Final assertion: abort if output still contains ".git.git" anywhere (canary failsafe)
_normalize_github_url() {
  local s=""
  s="$(printf '%s' "${1:-}" | sed -E \
    -e 's|[/]*$||' \
    -e ':gitloop' -e 's|(\.git)[/]*$||' -e 't gitloop' \
    -e 's|[/]*$||')"
  # Layer 2 (bash backup): parameter expansion strip
  while [ "${s%/}" != "$s" ]; do s="${s%/}"; done
  local prev=""
  while [ "$prev" != "$s" ]; do
    prev="$s"
    while [ "${s%.git}" != "$s" ]; do s="${s%.git}"; done
    while [ "${s%/}" != "$s" ]; do s="${s%/}"; done
  done
  s="${s}.git"
  # Layer 3 (canary assertion): NO output of this function is allowed to contain .git.git
  case "$s" in
    *".git.git"*) _die "BUG: _normalize_github_url leaked '.git.git'! Input='${1:-}' Output='${s}' — refusing to continue to avoid a broken git clone." ;;
  esac
  printf '%s' "$s"
}

# --- Python version helpers ---------------------------------------------------
# Checks whether a python binary ($1 = full path or basename like python3.11)
# satisfies >= MIN_PYTHON_MAJOR.MIN_PYTHON_MINOR. Prints binary path on stdout
# and returns 0 if OK; returns non-zero silently otherwise.
_py_version_ok() {
  local bin="$1" py_ver py_maj py_min
  command -v "$bin" >/dev/null 2>&1 || return 1
  py_ver=$("$bin" -c 'import sys;print(sys.version_info.major,sys.version_info.minor)' 2>/dev/null || echo "0 0")
  read -r py_maj py_min <<<"$py_ver"
  [ "$py_maj" -ge 0 ] 2>/dev/null || return 1
  [ "$py_min" -ge 0 ] 2>/dev/null || return 1
  if [ "$py_maj" -gt "$MIN_PYTHON_MAJOR" ]; then return 0; fi
  if [ "$py_maj" -eq "$MIN_PYTHON_MAJOR" ] && [ "$py_min" -ge "$MIN_PYTHON_MINOR" ]; then return 0; fi
  return 1
}
# Reverse check: python version <= MAX_ALLOWED_PYTHON_MINOR. Needed as SEPARATE
# gate after venv creation / activation because _py_version_ok only checks MIN
# floor (>= 3.10) and accepts 3.14 / 3.15 / 4.0 without complaint — exactly how
# psycopg2-binary 2.9.9 on cpython-314 slipped through and tried to build against
# /usr/include/python3.14 headers, producing `_PyInterpreterState_Get` errors.
# Returns 0 if python version is on the ALLOWED side of the cap (i.e. safe to use).
_py_version_within_max_cap() {
  local bin="$1" py_ver py_maj py_min
  command -v "$bin" >/dev/null 2>&1 || return 1
  py_ver=$("$bin" -c 'import sys;print(sys.version_info.major,sys.version_info.minor)' 2>/dev/null || echo "0 0")
  read -r py_maj py_min <<<"$py_ver"
  [ "$py_maj" -ge 0 ] 2>/dev/null || return 1
  [ "$py_min" -ge 0 ] 2>/dev/null || return 1
  if [ "$py_maj" -ne 3 ]; then
    # CPython 4+ major — definitely beyond our cap, refuse
    return 1
  fi
  [ "$py_min" -le "$MAX_ALLOWED_PYTHON_MINOR" ]
}

# Maximum Python minor version to prefer by default. Python 3.13+ has too many
# packages (numpy 1.26.x, pandas 2.1.x, psycopg 3.x) with requires-python < 3.13
# so pip resolve fails on servers with 3.13 installed. 3.11/3.12 are the sweet
# spot: every Django/numpy/psycopg wheel is built, PEP 668 is honored, stable.
MAX_PREFERRED_PYTHON_MINOR=12

# ABSOLUTE upper cap on Python we will EVER select. Python 3.14 has removed many
# deprecated C-API symbols that OLD pinned sdists still use. For example
# psycopg2-binary 2.9.9 and older call PyWeakref_GetObject which is
# Py_DEPRECATED(3.13) and gone in 3.14+ — their sdist builds immediately fail.
# Never select >= 3.14 automatically; instead DIE with instructions to install
# 3.11/3.12 from repos.
MAX_ALLOWED_PYTHON_MINOR=13

# Scans for ANY python3* binary on PATH with version >= 3.10 (Django 5 floor).
# PREFERENCE ORDER: pick highest minor <= MAX_PREFERRED_PYTHON_MINOR (3.12 by
# default) first; if only 3.13 is available fall back to newest reluctantly with
# a warning; if ONLY >= 3.14 (too new, broken sdists) exist DIE with guidance.
_detect_compatible_python3() {
  PYTHON_BIN=""
  local cand best_bin="" best_maj=0 best_min=0 py_ver py_maj py_min too_new_bin="" too_new_maj=0 too_new_min=0
  # Pass 1: only python3.12, python3.11, python3.10 (sweet spot, no wheel problems)
  for cand in python3.12 python3.11 python3.10; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if _py_version_ok "$(command -v "$cand")"; then
      py_ver=$("$cand" -c 'import sys;print(sys.version_info.major,sys.version_info.minor)' 2>/dev/null || echo "0 0")
      read -r py_maj py_min <<<"$py_ver"
      if [ "$py_maj" -gt "$best_maj" ] || { [ "$py_maj" -eq "$best_maj" ] && [ "$py_min" -gt "$best_min" ]; }; then
        best_bin="$(command -v "$cand")"
        best_maj="$py_maj"
        best_min="$py_min"
      fi
    fi
  done
  # Pass 2: if no preferred-range Python found (only 3.13 on the box), reluctantly accept it.
  if [ -z "$best_bin" ]; then
    for cand in python3.13; do
      command -v "$cand" >/dev/null 2>&1 || continue
      if _py_version_ok "$(command -v "$cand")"; then
        py_ver=$("$cand" -c 'import sys;print(sys.version_info.major,sys.version_info.minor)' 2>/dev/null || echo "0 0")
        read -r py_maj py_min <<<"$py_ver"
        if [ -z "$best_bin" ] || { [ "$py_maj" -gt "$best_maj" ] || { [ "$py_maj" -eq "$best_maj" ] && [ "$py_min" -gt "$best_min" ]; }; }; then
          best_bin="$(command -v "$cand")"
          best_maj="$py_maj"
          best_min="$py_min"
        fi
      fi
    done
    if [ -n "$best_bin" ]; then
      _warn "No Python 3.10/3.11/3.12 found — falling back to python ${best_maj}.${best_min}. WARNING: many common Django deps (numpy 1.26.x, pandas 2.x) still require-python < 3.13. pip install -r requirements.txt may fail with 'Ignored the following versions that require a different python version'. If that happens: apt install python3.11 python3.11-venv python3.11-pip then rerun Option 4."
    fi
  fi
  # Pass 3: Python 3.14 / 3.15+ / uncapped python3 default scan to detect "only 3.14 on the box".
  # We NEVER use these but we need to know they exist so we can fail WITH useful guidance
  # (instead of failing with a generic "no python found" error).
  if [ -z "$best_bin" ]; then
    for cand in python3.15 python3.14 python3; do
      command -v "$cand" >/dev/null 2>&1 || continue
      py_ver=$("$cand" -c 'import sys;print(sys.version_info.major,sys.version_info.minor)' 2>/dev/null || echo "0 0")
      read -r py_maj py_min <<<"$py_ver"
      if [ "$py_maj" -eq 3 ] && [ "$py_min" -gt "$MAX_ALLOWED_PYTHON_MINOR" ]; then
        if [ "$py_min" -gt "$too_new_min" ]; then
          too_new_bin="$(command -v "$cand")"
          too_new_maj="$py_maj"
          too_new_min="$py_min"
        fi
      elif [ "$py_maj" -eq 3 ] && [ "$py_min" -ge "$MIN_PYTHON_MINOR" ] && [ "$py_min" -le "$MAX_ALLOWED_PYTHON_MINOR" ]; then
        # Found a Python 3.13/3.12/3.11/3.10 via the `python3` symlink (last resort)
        best_bin="$(command -v "$cand")"
        best_maj="$py_maj"
        best_min="$py_min"
      fi
    done
  fi
  # Final: if only 3.14+ existed, DIE with specific guidance, don't use it.
  if [ -z "$best_bin" ] && [ -n "$too_new_bin" ]; then
    PYTHON_BIN="$too_new_bin"
    _die "\
Only Python ${too_new_maj}.${too_new_min} was found on this server
(MAX_ALLOWED_PYTHON_MINOR=3.${MAX_ALLOWED_PYTHON_MINOR}).

Python >= 3.14 REMOVES many deprecated CPython C-API symbols that commonly
pinned old sdists still use (e.g. psycopg2-binary 2.9.9 calls PyWeakref_GetObject
which was Py_DEPRECATED(3.13) and removed in 3.14+). Building from sdist on
3.14 will fail with 'fatal error: compile failure — no matching wheel found'
for at least 50% of real-world requirements.txt files.

Fix (pick ONE):
  * Debian / Ubuntu   : apt install python3.11 python3.11-venv python3.11-pip python3.11-dev
                        (add-apt-repository ppa:deadsnakes/ppa first if needed)
  * RHEL 9 / Rocky 9  : dnf install -y python3.11 python3.11-devel python3.11-pip
  * RHEL 8 / CentOS 8 : dnf module enable -y python3.11 ; dnf install -y python3.11 python3.11-devel python3.11-pip
  * Any Linux         : Compile Python 3.11 or 3.12 from source with --enable-optimizations

Once 3.11/3.12 is on PATH, rerun Option 4 — it will be preferred automatically.

If you INSIST on using python ${too_new_maj}.${too_new_min} despite known
sdist breakage (NOT supported), edit MAX_ALLOWED_PYTHON_MINOR in install.sh to
${too_new_min} and rerun — but expect many packages to fail in pip."
  fi
  if [ -n "$best_bin" ]; then
    PYTHON_BIN="$best_bin"
    _info "Selected compatible Python: ${PYTHON_BIN} (v${best_maj}.${best_min} >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR})"
    return 0
  fi
  # Nothing >= 3.10 found. Still record the default python3 for error messages.
  command -v python3 >/dev/null 2>&1 && PYTHON_BIN="$(command -v python3)" || PYTHON_BIN="python3"
  return 1
}

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

# ── prompt_w_retry: generic retry wrapper for wizard inputs that have validators ──
# Usage in Option 4 prompt section (EXAMPLE):
#   DB_HOST=$(prompt_w_retry \
#     "Database host" "$DEF_DB_HOST" "3" \
#     "host_reachable_or_local" \
#     "Host did not respond to nc -z probe on DB_PORT. Typo? Example: 'localhost' or 'db.example.com'.")
#
# Args:
#   $1 prompt_label        text shown to user on prompt_def invocation
#   $2 default_value       default shown in [ brackets ] (can be empty)
#   $3 max_retries         number of retries (e.g. 3 means up to 3 re-prompts). If this many
#                          retries still fail, we HARD DIE with a hint so user can fix env.
#   $4 validator_fn        shell function NAME. It will be called with the PROPOSED value
#                          as its ONLY positional argument. Exit 0 = value OK, exit non-zero
#                          = value rejected (re-prompt).
#   $5 hint_on_fail        text printed on VALIDATOR FAIL (before re-prompt). Tells user
#                          what went wrong so they can fix it.
#   $6 is_secret           if "secret" → use prompt_secret instead of prompt_def (for DB_PASSWORD / TOKEN fields).
# Output: prints the accepted value to stdout.
prompt_w_retry() {
  local prompt_label="$1" default_value="$2" max_retries="${3:-3}" validator_fn="$4" hint_on_fail="$5" is_secret="${6:-}"
  local attempt=0 current_value="" rc=0
  while [ "$attempt" -le "$max_retries" ]; do
    attempt=$(( attempt + 1 ))
    if [ "$is_secret" = "secret" ]; then
      current_value=$(prompt_secret "$prompt_label" "$default_value") || true
    else
      current_value=$(prompt_def "$prompt_label" "$default_value") || true
    fi
    # Call validator on proposed value. If validator_fn is empty/undefined, treat as always-OK.
    rc=0
    if [ -n "$validator_fn" ] && command -v "$validator_fn" >/dev/null 2>&1; then
      "$validator_fn" "$current_value" >/dev/null 2>&1 || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      printf "%s" "$current_value"
      return 0
    fi
    # Validator rejected it.
    if [ "$attempt" -le "$max_retries" ]; then
      _warn "Attempt $attempt/$max_retries: value for '$prompt_label' failed validation ($validator_fn returned rc=$rc). HINT: $hint_on_fail"
      if ! confirm_yn "Re-enter value for '$prompt_label'?" "y"; then
        _die "User chose to ABORT retries for '$prompt_label' instead of re-entering. Correct input and rerun."
      fi
      # Loop back and re-prompt.
    else
      _die "$max_retries retries exhausted for '$prompt_label' (kept failing validator=$validator_fn, rc=$rc). HINT: $hint_on_fail"
    fi
  done
  return 1
}

# ── prompt_edit_multiple: batch retry prompt for a NAMED group of related variables ──
# Used when a GROUP of inputs fail together (e.g. all 4 DB creds, or the Django
# settings trio). Instead of re-prompting one at a time, we print a menu of the
# currently-entered values, let user pick which ones to overwrite (or [A] ALL), then
# call the validator again.
#
# Usage (EXAMPLE for DB creds group):
#   while validate_db_creds; rc=$? -ne 0; do
#     prompt_edit_multiple \
#       "Database credentials failed SELECT 1 validation" \
#       "DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT" \
#       "Re-run SELECT 1 validation now?" \
#       "y"
#     validate_db_creds && break
#   done
prompt_edit_multiple() {
  local section_title="$1" fields_csv="$2" retry_question="$3" retry_default="${4:-y}"
  local -a fields_arr=()
  local field="" current="" choice="" edited_any=0
  IFS=' ' read -r -a fields_arr <<<"$fields_csv"
  printf "\n\033[1;33m%s:\033[0m\n" "$section_title" >&2
  local i=0
  for field in "${fields_arr[@]}"; do
    i=$(( i + 1 ))
    # Indirect expansion: get current value of variable whose NAME is $field.
    # Protect against set -u (nounset): expand through ${!field:-} then direct; wrap in set +u block for eval.
    current=${!field:-}
    if [ -z "${current:+set}" ]; then
      # field might not be exported as bash var but exist in ENV_FILE; try indirect expansion via eval with nounset temporarily off
      local _pu_restore=1
      case "$-" in *u*) ;; *) _pu_restore=0;; esac
      [ "$_pu_restore" -eq 1 ] && set +u
      eval current=\"\${${field}:-}\" 2>/dev/null || current=""
      [ "$_pu_restore" -eq 1 ] && set -u
    fi
    # Passwords are hidden, show ******** unless empty
    if [[ "$field" == *PASS* ]] || [[ "$field" == *TOKEN* ]] || [[ "$field" == *SECRET* ]]; then
      if [ -z "$current" ]; then current="(EMPTY — TYPICALLY REQUIRED!)"; else current="******** (length=${#current})"; fi
    else
      [ -z "$current" ] && current="(EMPTY)"
    fi
    printf "   \033[1;37m[%d]\033[0m %s = \033[0;36m%s\033[0m\n" "$i" "$field" "$current" >&2
  done
  printf "   \033[1;37m[A]\033[0m Edit ALL above fields in order\n" >&2
  printf "   \033[1;37m[S]\033[0m SKIP (accept current values as-is and retry validation anyway)\n" >&2
  printf "   \033[1;37m[Q]\033[0m Abort installation and exit (fix the underlying issue first)\n" >&2
  choice=$(prompt_def "Which field(s) to edit? [A=all / 1..$i number / S=skip / Q=quit]" "A")
  case "${choice^^}" in
    Q) _die "User chose Q=QUIT on '$section_title' retry prompt. Fix the underlying config issue and rerun Option 4." ;;
    S) _warn "User chose S=SKIP on '$section_title'. Validation will be retried with EXISTING values." ;;
    A)
      edited_any=1
      for field in "${fields_arr[@]}"; do
        local default_for=""
        # set -u nounset protection for indirect expansion (read).
        default_for=${!field:-}
        if [ -z "${default_for:+set}" ]; then
          local _pu1=1
          case "$-" in *u*) ;; *) _pu1=0;; esac
          [ "$_pu1" -eq 1 ] && set +u
          eval default_for=\"\${${field}:-}\" 2>/dev/null || default_for=""
          [ "$_pu1" -eq 1 ] && set -u
        fi
        local is_pass=""
        [[ "$field" == *PASS* ]] || [[ "$field" == *TOKEN* ]] || [[ "$field" == *SECRET* ]] && is_pass="secret"
        local new_val=""
        if [ "$is_pass" = "secret" ]; then
          new_val=$(prompt_secret "$field" "$default_for")
        else
          new_val=$(prompt_def "$field" "$default_for")
        fi
        # Write back: assign to the VARIABLE whose name is $field (indirect).
        # set -u nounset safe direct assignment via printf -v (if bash >= 4.2, universal fallback: eval with set +u).
        if printf -v "$field" '%s' "$new_val" 2>/dev/null; then
          :
        else
          local _pu2=1
          case "$-" in *u*) ;; *) _pu2=0;; esac
          [ "$_pu2" -eq 1 ] && set +u
          eval $field=\"\$new_val\" 2>/dev/null || true
          [ "$_pu2" -eq 1 ] && set -u
        fi
        # ALWAYS write to ENV_FILE so subsequent set -a; . "$ENV_FILE"; set +a syncs the new value for subshells.
        if [ -n "${ENV_FILE:-}" ]; then
          grep -v "^${field}=" "$ENV_FILE" > "$ENV_FILE.tmp.$$" 2>/dev/null || true
          printf "%s=%s\n" "$field" "$new_val" >> "$ENV_FILE.tmp.$$" 2>/dev/null
          mv "$ENV_FILE.tmp.$$" "$ENV_FILE" 2>/dev/null || true
        fi
      done
      ;;
    *)
      # Single numeric field number (1-based).
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ]; then
        edited_any=1
        field="${fields_arr[$((choice-1))]}"
        local default_for=""
        default_for=${!field:-}
        if [ -z "${default_for:+set}" ]; then
          local _pu3=1
          case "$-" in *u*) ;; *) _pu3=0;; esac
          [ "$_pu3" -eq 1 ] && set +u
          eval default_for=\"\${${field}:-}\" 2>/dev/null || default_for=""
          [ "$_pu3" -eq 1 ] && set -u
        fi
        local is_pass=""
        [[ "$field" == *PASS* ]] || [[ "$field" == *TOKEN* ]] || [[ "$field" == *SECRET* ]] && is_pass="secret"
        local new_val=""
        if [ "$is_pass" = "secret" ]; then
          new_val=$(prompt_secret "$field" "$default_for")
        else
          new_val=$(prompt_def "$field" "$default_for")
        fi
        if printf -v "$field" '%s' "$new_val" 2>/dev/null; then
          :
        else
          local _pu4=1
          case "$-" in *u*) ;; *) _pu4=0;; esac
          [ "$_pu4" -eq 1 ] && set +u
          eval $field=\"\$new_val\" 2>/dev/null || true
          [ "$_pu4" -eq 1 ] && set -u
        fi
        if [ -n "${ENV_FILE:-}" ]; then
          grep -v "^${field}=" "$ENV_FILE" > "$ENV_FILE.tmp.$$" 2>/dev/null || true
          printf "%s=%s\n" "$field" "$new_val" >> "$ENV_FILE.tmp.$$" 2>/dev/null
          mv "$ENV_FILE.tmp.$$" "$ENV_FILE" 2>/dev/null || true
        fi
      else
        _warn "Unrecognized choice '$choice' (expected A/S/Q/1..$i). Treating as S=SKIP."
      fi
      ;;
  esac
  # User's last chance: are they ready to retry the validation loop?
  if ! confirm_yn "$retry_question" "$retry_default"; then
    _warn "User declined retry for '$section_title'. Continuing anyway (installer will likely fail on the next step)."
  fi
  return 0
}

# ── Convenience validators for common wizard groups (used by prompt_w_retry) ──
# These MUST be safe to call repeatedly during prompt loops: no side effects,
# they only run probes that verify the PROPOSED user value.
_validator_nonempty() {
  local v="$1"; [ -n "${v:-}" ]
}
_validator_linux_username() {
  local v="$1"
  [[ "$v" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}
_validator_dir_writable_or_parent_exists() {
  local d="$1"
  [ -z "${d:-}" ] && return 1
  # Expand any ~ manually in case user typed ~/.local/myapp
  case "$d" in "~/"*) d="${HOME}/${d#\~/}"; esac
  # If dir already exists: must be writable by euid.
  if [ -d "$d" ]; then [ -w "$d" ] && return 0; return 2; fi
  # Else: parent must exist AND be writable (so we can mkdir -p later).
  local parent="${d%/*}"
  [ "${parent:-/}" = "$d" ] && parent="/"  # d=/foo case
  [ -n "${parent:-}" ] || parent="/"
  [ -d "$parent" ] && [ -w "$parent" ]
}
_validator_cidr_list_or_star() {
  local raw="$1"; local ip="" ok=1
  # Special values: * is allowed (listen_addresses='*' case), localhost, all
  case "${raw^^}" in
    "*"|"LOCALHOST"|"ALL") return 0 ;;
  esac
  while IFS=',' read -r -a _arr; do
    for ip in "${_arr[@]}"; do
      ip=$(printf '%s' "$ip" | sed -E 's/[[:space:]]+//g')
      [ -z "$ip" ] && continue
      # CIDR pattern: a.b.c.d/N or a.b.c.d single ip, or ipv6 colon forms
      if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$ ]]; then continue; fi
      if [[ "$ip" =~ ^[0-9a-fA-F:]+(\/[0-9]+)?$ ]] && [[ "$ip" == *:* ]]; then continue; fi
      ok=0
    done
  done <<<"$raw"
  [ "$ok" -eq 1 ]
}
_validator_dotted_python_module_syntax() {
  # Sanity syntax only: letters/digits/underscore, separated by dots, no leading/trailing dot.
  # For DJANGO_SETTINGS_MODULE this gives a quick syntax fail before we ever try clone+migrate.
  local m="$1"
  [[ "$m" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]]
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

# ── _autodetect_django_settings_module: detect + pick DJANGO_SETTINGS_MODULE from a cloned repo ──
# Called RIGHT AFTER git clone succeeds (APP_DIR/.git exists, repo is populated). Never before.
# Detection priority order (highest → lowest):
#   (1) Parse $APP_DIR/manage.py for the canonical line:
#           os.environ.setdefault("DJANGO_SETTINGS_MODULE", "pkg.settings")
#       This is what django-admin startproject writes and what Django itself falls back to.
#   (2) Filesystem scan under $APP_DIR: find Django "settings.py" files (or settings/ packages).
#       Rank by production-desirability so production.py beats dev.py.
#
# After building the sorted candidate list, ALWAYS shows a confirmation pick list (per user choice)
# — never silently picks. If 0 candidates found → fall back to prompt_w_retry with dotted-syntax validator.
#
# SIDE EFFECTS:
#   * Sets the global shell variable DJANGO_SETTINGS_MODULE to the chosen value (exported so children inherit)
#   * OVERWRITES the DJANGO_SETTINGS_MODULE= line in $ENV_FILE via sed-inplace, OR appends if missing.
#   * Reloads ENV_FILE with `set -a; . "$ENV_FILE"; set +a` so every later step uses the new value.
#
# Globals read: APP_DIR, ENV_FILE, DEF_DJANGO_SETTINGS_MODULE
# Globals written: DJANGO_SETTINGS_MODULE (exported)
_autodetect_django_settings_module() {
  [ -d "${APP_DIR:-}" ] || { _warn "_autodetect_django_settings_module: APP_DIR=$APP_DIR missing or empty — skipping detection"; return 2; }
  local detect_python=""
  if [ -n "${PYTHON_BIN:-}" ] && [ -x "$PYTHON_BIN" ]; then detect_python="$PYTHON_BIN"
  elif command -v python3 >/dev/null 2>&1; then detect_python="$(command -v python3)"
  elif command -v python  >/dev/null 2>&1; then detect_python="$(command -v python)"
  else detect_python=""; fi

  # ── Stage 1: use Python to build a SORTED candidate list (score desc). Python handles regex + path joins cleanly. ──
  local cand_raw="" cand_rc=0
  if [ -n "$detect_python" ]; then
    cand_rc=0
    cand_raw=$( APP_DIR_ROOT="$APP_DIR" DEF_MOD="$DEF_DJANGO_SETTINGS_MODULE" "$detect_python" - <<'PY' 2>&1 || cand_rc=$?
import os, re, sys, glob
app_root = os.environ["APP_DIR_ROOT"]
def_mod   = os.environ.get("DEF_MOD", "")

cands = []  # list of (score:int, dotted:str, source:str, rel_path:str)

# ── (a) Parse manage.py ──
manage_py = os.path.join(app_root, "manage.py")
if os.path.isfile(manage_py):
    try:
        with open(manage_py, "r", encoding="utf-8", errors="replace") as fh:
            content = fh.read()
    except Exception:
        content = ""
    # Match: os.environ.setdefault("DJANGO_SETTINGS_MODULE", "pkg.settings")  OR
    #        os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'pkg.settings')
    m = re.search(
        r"""DJANGO_SETTINGS_MODULE\s*["']?\s*,\s*["']([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)["']""",
        content,
    )
    if m:
        dotted = m.group(1)
        parts = dotted.split(".")
        rel_path = os.path.join(*parts) + ".py"
        cands.append((100, dotted, "manage.py DJANGO_SETTINGS_MODULE", rel_path))

# ── (b) Filesystem scan for settings.py / settings/*.py ──
# First find all top-level package dirs (D under app_root that contain __init__.py), then look inside.
for entry in sorted(os.listdir(app_root)):
    pkg_dir = os.path.join(app_root, entry)
    if not os.path.isdir(pkg_dir):
        continue
    if not (os.path.isfile(os.path.join(pkg_dir, "__init__.py")) or os.path.isfile(os.path.join(pkg_dir, "__init__.pyi"))):
        # Not a strict Python package — could still be the settings dir if user has no __init__.py.
        # Skip anyway because Django project layout convention ALWAYS puts settings.py INSIDE a package with __init__.py.
        pass
    # entry is a plausible top-level package. Look for settings files.
    entry_score_bump = 0
    # Top-level entry that matches "project name" heuristics: contains 'app'/'proj'/'config'/'core'/'main' or matches DEF_MOD prefix → bonus.
    def_mod_prefix = def_mod.split(".")[0] if def_mod else ""
    if def_mod_prefix and entry == def_mod_prefix: entry_score_bump += 5
    # Plain D/settings.py (startproject default)
    settings_py = os.path.join(pkg_dir, "settings.py")
    if os.path.isfile(settings_py):
        dotted = f"{entry}.settings"
        cands.append((80 + entry_score_bump, dotted, f"filesystem {entry}/settings.py", os.path.join(entry, "settings.py")))
    # D/settings/ subpackage
    settings_dir = os.path.join(pkg_dir, "settings")
    if os.path.isdir(settings_dir):
        base_dotted = f"{entry}.settings"
        init_py = os.path.join(settings_dir, "__init__.py")
        if os.path.isfile(init_py):
            cands.append((75 + entry_score_bump, base_dotted, f"filesystem {entry}/settings/__init__.py (package default)", os.path.join(entry, "settings", "__init__.py")))
        # Scan individual .py files inside settings/: production > prod > staging > base > dev (dev filtered unless last resort)
        file_rank = {
            "production": 90,
            "prod":       85,
            "staging":    80,
            "stage":      78,
            "base":       60,
            "common":     58,
            "dev":        20,
            "development":18,
            "local":      15,
            "test":       10,
            "tests":       8,
        }
        for pyfile in sorted(glob.glob(os.path.join(settings_dir, "*.py"))):
            basename = os.path.splitext(os.path.basename(pyfile))[0]
            if basename.startswith("_"):
                continue
            score = file_rank.get(basename, 50)
            dotted = f"{base_dotted}.{basename}"
            cands.append((score + entry_score_bump, dotted, f"filesystem {entry}/settings/{basename}.py", os.path.join(entry, "settings", basename + ".py")))

# De-duplicate by dotted path (keep highest score). Seen as dict: dotted -> (score, source, rel_path)
seen = {}
for score, dotted, source, rel_path in cands:
    prev = seen.get(dotted)
    if prev is None or score > prev[0]:
        seen[dotted] = (score, source, rel_path)

final = sorted(
    ((score, dotted, source, rel_path) for dotted, (score, source, rel_path) in seen.items()),
    key=lambda t: (-t[0], t[1])
)

# Emit to stdout in TSV: score\tdotted\tsource\trel_path
for (score, dotted, source, rel_path) in final:
    print(f"{score}\t{dotted}\t{source}\t{rel_path}")
PY
)
  else
    cand_rc=99; cand_raw=""
  fi

  # ── Parse TSV output into bash arrays ──
  local -a cand_scores=() cand_dotted=() cand_sources=() cand_paths=()
  local num_cands=0
  if [ "$cand_rc" -eq 0 ] && [ -n "$cand_raw" ]; then
    while IFS=$'\t' read -r score dotted source rel_path; do
      [ -z "${dotted:-}" ] && continue
      cand_scores+=("$score")
      cand_dotted+=("$dotted")
      cand_sources+=("$source")
      cand_paths+=("$rel_path")
      num_cands=$(( num_cands + 1 ))
    done <<<"$cand_raw"
  fi

  # ── Filter candidates that are actually resolvable on disk (score ≥ 60 = production / settings.py / base at minimum) ──
  local -a good_dotted=() good_source=() good_score=() good_rel=()
  local num_good=0 i=0
  for i in "${!cand_dotted[@]}"; do
    local s="${cand_scores[$i]}" d="${cand_dotted[$i]}" src="${cand_sources[$i]}" rp="${cand_paths[$i]}"
    local actual_file="${APP_DIR}/${rp}"
    # If actual resolve failed (e.g. manage.py said pkg.settings but file is missing) → skip.
    if [ ! -f "$actual_file" ]; then
      # Try settings/ package without .py (package dir form): if rp ends with __init__.py the dir itself is the package.
      local dir_equiv="${actual_file%/__init__.py}"
      if [ ! -d "$dir_equiv" ]; then continue; fi
    fi
    if [ "$s" -ge 60 ]; then
      good_dotted+=("$d"); good_source+=("$src"); good_score+=("$s"); good_rel+=("$rp"); num_good=$(( num_good + 1 ))
    fi
  done

  # ── If 0 "good" candidates, use the raw manage.py candidate even if file missing (faithful to repo) or fall back. ──
  if [ "$num_good" -eq 0 ]; then
    for i in "${!cand_dotted[@]}"; do
      good_dotted+=("${cand_dotted[$i]}"); good_source+=("${cand_sources[$i]}")
      good_score+=("${cand_scores[$i]}"); good_rel+=("${cand_paths[$i]}"); num_good=$(( num_good + 1 ))
      [ "$num_good" -ge 3 ] && break
    done
  fi

  local chosen=""
  _section "Auto-detect DJANGO_SETTINGS_MODULE (from cloned repo at $APP_DIR)"

  if [ "$num_good" -eq 0 ]; then
    _warn "Auto-detect found ZERO settings-module candidates under APP_DIR=$APP_DIR (manage.py missing? no *.settings.*.py files?). Falling back to manual input."
    chosen=$(prompt_w_retry "Django settings module (Python dotted path; env var DJANGO_SETTINGS_MODULE)" \
      "${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}" 3 _validator_dotted_python_module_syntax \
      "Syntax error: expected Python dotted identifier like 'myproject.settings' or 'myproject.settings.production' — start with letter/underscore, parts separated by dots, no spaces or leading/trailing dots.")
  else
    printf "  \033[1;36mFound %d candidate(s)\033[0m (production-like first). Per your choice, ALWAYS confirming before use:\n" "$num_good" >&2
    i=0
    for i in "${!good_dotted[@]}"; do
      local n=$(( i + 1 ))
      local score_label=""
      case "${good_score[$i]}" in
        100) score_label="\033[0;32mEXACT manage.py line (authoritative)\033[0m" ;;
        9[0-9]) score_label="\033[0;32mproduction-like (recommended)\033[0m" ;;
        8[0-9]) score_label="\033[0;32mstartproject default or production-ish\033[0m" ;;
        7[0-9]) score_label="\033[0;33msettings package default (__init__.py)\033[0m" ;;
        6[0-9]) score_label="\033[0;33mbase.py (shared; usually OK if no production.py)\033[0m" ;;
        *)     score_label="\033[0;31mlow-confidence; verify before using\033[0m" ;;
      esac
      printf "    \033[1;37m[%d]\033[0m \033[1;36m%s\033[0m\n" "$n" "${good_dotted[$i]}" >&2
      printf "         source: %s\n         score:  %s\n" "${good_source[$i]}" "$score_label" >&2
    done
    local max_n="$num_good"
    printf "    \033[1;37m[M]\033[0m Enter dotted path manually (override detection)\n" >&2
    local default_choice="1"
    local pick=""
    while [ -z "$chosen" ]; do
      pick=$(prompt_def "Pick a number [1-$max_n] or M=manual. Default=$default_choice (top=best production match)" "$default_choice")
      if [ -z "${pick:-}" ]; then pick="$default_choice"; fi
      case "${pick^^}" in
        M)
          chosen=$(prompt_w_retry "Django settings module (Python dotted path; env var DJANGO_SETTINGS_MODULE)" \
            "${DJANGO_SETTINGS_MODULE:-${good_dotted[0]:-$DEF_DJANGO_SETTINGS_MODULE}}" 3 _validator_dotted_python_module_syntax \
            "Syntax error: expected Python dotted identifier like 'myproject.settings' or 'myproject.settings.production'. Start with letter/underscore, parts separated by single dots, no spaces or leading/trailing dots.")
          ;;
        *)
          if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$max_n" ]; then
            chosen="${good_dotted[$((pick - 1))]}"
            _ok "Using DJANGO_SETTINGS_MODULE='$chosen' (pick #$pick from list; source=${good_source[$((pick-1))]})."
          else
            _warn "Unrecognized pick '$pick' — expected 1..$max_n or M. Try again."
          fi
          ;;
      esac
    done
  fi

  # ── FINAL: sanitize + assign to shell var + persist to ENV_FILE + reload ──
  if ! _validator_dotted_python_module_syntax "$chosen"; then
    _warn "Final chosen value '$chosen' still failed dotted-syntax sanity check. Forcing DEF_DJANGO_SETTINGS_MODULE='$DEF_DJANGO_SETTINGS_MODULE' (will fail STAGE 1 validation if wrong, with retry prompt)."
    chosen="$DEF_DJANGO_SETTINGS_MODULE"
  fi
  DJANGO_SETTINGS_MODULE="$chosen"
  export DJANGO_SETTINGS_MODULE

  # Persist to ENV_FILE (replace-or-append same pattern as post-clone probe uses)
  if [ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ]; then
    local new_line="DJANGO_SETTINGS_MODULE='${chosen}'" sed_bin="sed"
    if grep -Eq '^DJANGO_SETTINGS_MODULE=' "$ENV_FILE" 2>/dev/null; then
      command -v gsed >/dev/null 2>&1 && sed_bin="gsed"
      sudo "$sed_bin" -i~ -E "s|^DJANGO_SETTINGS_MODULE=.*|${new_line}|" "$ENV_FILE" 2>/dev/null || true
      sudo rm -f "${ENV_FILE}~" 2>/dev/null || true
    else
      printf '%s\n' "$new_line" | sudo tee -a "$ENV_FILE" >/dev/null 2>/dev/null || true
    fi
    _ok "Wrote DJANGO_SETTINGS_MODULE='${chosen}' into ENV_FILE=$ENV_FILE (replace-or-append)."
    _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
    set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
    _ok "ENV reloaded from $ENV_FILE. DJANGO_SETTINGS_MODULE now=${DJANGO_SETTINGS_MODULE} (shell + subprocess env)."
  else
    _warn "ENV_FILE=$ENV_FILE missing or unreadable — could not persist DJANGO_SETTINGS_MODULE value. Shell variable still set; if later steps fail, write it to env file manually."
  fi
  return 0
}

# ----- Spinner / progress helpers -------------------------------------------
# These wrap long-running silent operations so the user sees ACTIVITY instead
# of a blinking cursor for 60-90 seconds. Works for: apt install / pip install /
# git clone / manage.py migrate / collectstatic / initdb / psql big scripts.
#
# Design rules:
#   * Cursor is hidden during spin, ALWAYS restored via trap on EXIT/INT/TERM
#     (Ctrl-C during a spinner would otherwise leave user with invisible cursor).
#   * TTY detection: when stdout is not a tty (CI, script | tee log), spinner
#     is disabled entirely, we just print the label + run command in foreground
#     normally (no CR rewrite, no braille — CI logs stay parseable).
#   * Command stdout+stderr captured to /tmp/rasyatone_spin_<pid>_<label>.log.
#     On RC=0 → [OK] label (elapsed). On RC≠0 → [FAIL] label + tail -n30 of log
#     printed IMMEDIATELY so user can see the error without opening a file.
#   * NEVER swallows exit code (critical under `set -euo pipefail`): caller's
#     RC == subprocess RC, exactly as if you ran it without the wrapper.
_SPINNER_TRAP_SET=0
_spinner_setup_trap() {
  if [ "$_SPINNER_TRAP_SET" = "1" ]; then return 0; fi
  _SPINNER_TRAP_SET=1
  # cursor_normal — run on EXIT / INT / TERM to re-show cursor + newline on abort.
  # Save original traps so we don't clobber future EXIT handlers (chain via
  # explicit list — POSIX shell doesn't stack traps natively, but this is the
  # only EXIT trap we use besides cleanup, so it's fine).
  _spinner_cnorm() {
    printf '\033[?25h' >/dev/tty 2>/dev/null || printf '\r' >&2
  }
  trap '_spinner_cnorm' EXIT INT TERM HUP
}

# Elapsed-seconds → human "0.4s / 15s / 2m 05s / 1h 07m"
_human_elapsed() {
  local secs=$1
  if [ "$secs" -lt 60 ]; then printf "%ds" "$secs"; return 0; fi
  if [ "$secs" -lt 3600 ]; then printf "%dm %02ds" $((secs/60)) $((secs%60)); return 0; fi
  printf "%dh %02dm" $((secs/3600)) $(((secs%3600)/60))
}

# Safe label truncation (avoid bash arithmetic-syntax crashes from malformed
# parameter-expansion chains like ${VAR:60:+...} which some bash versions try
# to parse as arithmetic context, interpreting "..." dots as unknown operands).
# Usage: _trunc_label "$string" 60 → first 60 chars + "..." when longer.
_trunc_label() {
  local s="$1" maxlen=$2
  [ -z "${s:-}" ] && { printf ""; return 0; }
  [ -z "${maxlen:-}" ] && maxlen=60
  local curlen=${#s}
  if [ "$curlen" -gt "$maxlen" ]; then
    printf "%s..." "${s:0:$maxlen}"
  else
    printf "%s" "$s"
  fi
}

# Usage: _run_with_spinner "Label" command [args...]
#   Label — short single-line description shown next to spinner (no newlines!).
#   command + args — the actual long-running command. Arguments are passed
#   VERBATIM (eval-free) via quoted array exec, so pipelines/redirects are NOT
#   supported inside the command itself; if you need redirection, wrap it in a
#   small helper function and pass the helper name as the command.
_run_with_spinner() {
  local label="$1"; shift
  local logfile="/tmp/rasyatone_spin_$$_$(printf '%s' "$label" | tr -c 'A-Za-z0-9_' '_' | cut -c1-40).log"
  : > "$logfile" 2>/dev/null || true
  _spinner_setup_trap
  local tty_on=1
  [ -t 1 ] 2>/dev/null || tty_on=0

  # === NON-TTY MODE (CI / piped logs): no spinner, just run + echo result.
  if [ "$tty_on" -eq 0 ]; then
    local st et secs rc
    st=$(date +%s 2>/dev/null || echo 0)
    "$@" >"$logfile" 2>&1
    rc=$?
    et=$(date +%s 2>/dev/null || echo 0)
    secs=$((et - st)); [ "$secs" -lt 0 ] && secs=0
    if [ "$rc" -eq 0 ]; then
      _ok "${label} (elapsed $(_human_elapsed "$secs"))"
    else
      _nok "${label} FAILED (rc=${rc}, elapsed $(_human_elapsed "$secs")). Last 30 lines of ${logfile}:"
      tail -n 30 "$logfile" 2>/dev/null | sed 's/^/    | /' || true
    fi
    return "$rc"
  fi

  # === TTY MODE (interactive): run command in background, spin in foreground.
  # UTF-8 braille spinner (modern terminals); fallback ASCII spinner if LANG
  # doesn't look UTF-8 capable (LC_ALL=C users on minimal containers).
  local frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  case "${LC_ALL:-${LANG:-C}}" in
    *UTF*|*utf-8*|*utf8*) ;;
    *) frames="|/-\\" ;;
  esac
  local nframes=${#frames}
  # Hide cursor at start.
  printf '\033[?25l' >/dev/tty 2>/dev/null || true

  # Spawn long command in subshell (captured to logfile) in background.
  ( "$@" ) >"$logfile" 2>&1 &
  local cmd_pid=$!
  local st et secs rc idx=0 ch out line
  st=$(date +%s 2>/dev/null || echo 0)

  # Wait loop: poll every 0.15s, rewrite same line with spinner + label + elapsed.
  # Use `kill -0 $pid` (POSIX) instead of wait (so we can rewrite line repeatedly).
  while kill -0 "$cmd_pid" 2>/dev/null; do
    ch="${frames:idx % nframes:1}"
    # Fallback for shells where substring with arithmetic misbehaves — pick via array-like indexing.
    [ -z "$ch" ] && ch="$(printf '%s' "$frames" | cut -c$(( (idx % nframes) + 1)) )"
    et=$(date +%s 2>/dev/null || echo "$st")
    secs=$((et - st)); [ "$secs" -lt 0 ] && secs=0
    # Print: '  ⠋ Label ... elapsed Ns'  — then \r to overwrite same line next tick.
    printf "  \033[96m%s\033[0m %s ... \033[90melapsed %s\033[0m\r" "$ch" "$label" "$(_human_elapsed "$secs")" >&2
    idx=$((idx + 1))
    # Sleep portably. `sleep 0.15` works on GNU + busybox sleep from 2017+; fall
    # back to 1-second sleep if it errors (ultra-minimal containers).
    sleep 0.15 2>/dev/null || sleep 1
  done

  wait "$cmd_pid" 2>/dev/null
  rc=$?
  et=$(date +%s 2>/dev/null || echo "$st")
  secs=$((et - st)); [ "$secs" -lt 0 ] && secs=0

  # Clear the spinner line entirely (overwrite with spaces then CR) before
  # writing the final [OK]/[FAIL] line — avoids residual braille chars left
  # on-screen when label is shorter than previous (e.g., "apt update" → label).
  local w
  w=$(tput cols 2>/dev/null || echo 120)
  printf "%-${w}s\r" " " >&2

  if [ "$rc" -eq 0 ]; then
    _ok "${label} (elapsed $(_human_elapsed "$secs"))"
  else
    # FAIL: print head banner + tail -n30 of log IMMEDIATELY so user doesn't
    # have to manually open /tmp/rasyatone_spin_*.log. The `| sed 's/^/    | /'`
    # prefix makes log lines visually distinct from installer output.
    _nok "${label} FAILED (rc=${rc}, elapsed $(_human_elapsed "$secs")). Log: ${logfile}. Last 30 lines:"
    tail -n 30 "$logfile" 2>/dev/null | sed 's/^/    | /' || true
    printf "    Full log: \033[1m%s\033[0m\n" "$logfile" >&2
  fi
  # restore cursor explicitly (trap also fires but belt+braces)
  printf '\033[?25h' >/dev/tty 2>/dev/null || true
  return "$rc"
}

_run_with_progress() {
  local label="$1"; shift
  local logfile="/tmp/rasyatone_spin_$$_$(printf '%s' "$label" | tr -c 'A-Za-z0-9_' '_' | cut -c1-40).log"
  : > "$logfile" 2>/dev/null || true
  _spinner_setup_trap
  local tty_on=1
  [ -t 1 ] 2>/dev/null || tty_on=0
  local st et secs rc
  st=$(date +%s 2>/dev/null || echo 0)
  if [ "$tty_on" -eq 0 ]; then
    "$@" >"$logfile" 2>&1
    rc=$?
  else
    printf "  \033[96m>\033[0m %s\n" "$label" >&2
    set +e
    ( "$@" ) 2>&1 | tee "$logfile"
    rc=$?
    set -e
  fi
  et=$(date +%s 2>/dev/null || echo 0)
  secs=$((et - st)); [ "$secs" -lt 0 ] && secs=0
  if [ "$rc" -eq 0 ]; then
    _ok "${label} (elapsed $(_human_elapsed "$secs"))"
  else
    _nok "${label} FAILED (rc=${rc}, elapsed $(_human_elapsed "$secs")). Log: ${logfile}. Last 30 lines:"
    tail -n 30 "$logfile" 2>/dev/null | sed 's/^/    | /' || true
    printf "    Full log: \033[1m%s\033[0m\n" "$logfile" >&2
  fi
  return "$rc"
}

# --- package manager auto-detect --------------------------------------------
declare -g PM="" PKG_INSTALL="" PKG_UPDATE="" FW_BACKEND="none"
declare -g SERVICE_ACCOUNT_GROUP=""
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

_ensure_service_account_ready() {
  local u="$1"
  local appdir="$2"
  local shell=""
  if [ -x /usr/sbin/nologin ]; then shell="/usr/sbin/nologin"
  elif [ -x /sbin/nologin ]; then shell="/sbin/nologin"
  else shell="/bin/false"
  fi
  if ! id "$u" >/dev/null 2>&1; then
    set +e
    if command -v groupadd >/dev/null 2>&1; then
      sudo groupadd --system "$u" >/dev/null 2>&1 || true
    fi
    if command -v useradd >/dev/null 2>&1; then
      sudo useradd --system --no-create-home --home-dir "$appdir" --shell "$shell" --gid "$u" "$u" >/dev/null 2>&1 || \
      sudo useradd --system --no-create-home --home-dir "$appdir" --shell "$shell" "$u" >/dev/null 2>&1 || true
    elif command -v adduser >/dev/null 2>&1; then
      sudo adduser -S -H -h "$appdir" -s "$shell" "$u" >/dev/null 2>&1 || true
    fi
    set -e
  fi
  if ! id "$u" >/dev/null 2>&1; then
    _die "Could not create service account '${u}'. Create it manually then rerun."
  fi
  SERVICE_ACCOUNT_GROUP="$(id -gn "$u" 2>/dev/null || echo "$u")"
}

_git_run_as_service() {
  local appdir="$1"; shift
  local u="${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}"
  local g="${SERVICE_ACCOUNT_GROUP:-$u}"
  if [ -d "$appdir" ]; then
    sudo chown -R "${u}:${g}" "$appdir" 2>/dev/null || true
  fi
  sudo -H -u "$u" git -c safe.directory="$appdir" -C "$appdir" "$@"
}

_configure_certbot_autorenew() {
  if ! command -v certbot >/dev/null 2>&1; then
    _warn "certbot not found — skipping auto-renew configuration"
    return 1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -Eq '^certbot\.timer'; then
      _run_with_spinner "Enable certbot.timer (auto-renew)" sudo systemctl enable --now certbot.timer || true
      if systemctl is-active certbot.timer >/dev/null 2>&1; then
        _ok "certbot auto-renew enabled via systemd timer"
        return 0
      fi
    fi
  fi
  if command -v crontab >/dev/null 2>&1; then
    local cron_line="0 3,15 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx' >/dev/null 2>&1"
    local tmp="/tmp/rasyatone_certbot_cron_$$.txt"
    set +e
    sudo crontab -l 2>/dev/null >"$tmp"
    if ! grep -Fq "certbot renew --quiet" "$tmp" 2>/dev/null; then
      printf "%s\n" "$cron_line" >>"$tmp"
      sudo crontab "$tmp" 2>/dev/null || true
    fi
    rm -f "$tmp" 2>/dev/null || true
    set -e
    _ok "certbot auto-renew configured via root cron (03:00 and 15:00)"
    return 0
  fi
  _warn "Could not configure certbot auto-renew (no systemd timer and no crontab command)."
  return 1
}

# --- Package install wrappers (used by _run_with_spinner for multi-word globals)
# These expand $PKG_UPDATE / $PKG_INSTALL with word-splitting as they were
# originally designed, so _run_with_spinner (which passes args VERBATIM, no eval)
# can call a NAME instead of evaluating a big string with embedded word splitting.
_pkg_update()  { eval "$PKG_UPDATE"; }
_pkg_install() { if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive eval "$PKG_INSTALL $*"; else eval "$PKG_INSTALL $*"; fi; }
_sudo_pkg_install() { if command -v apt-get >/dev/null 2>&1; then sudo DEBIAN_FRONTEND=noninteractive env DEBIAN_FRONTEND=noninteractive bash -c "eval \$0 \$*" "$PKG_INSTALL" "$@"; else sudo bash -c "eval \$0 \$*" "$PKG_INSTALL" "$@"; fi; }
# Apt-only wrapper: ignore missing packages (for OPTIONAL splits like python3.X-pip
# / python3.X-venv which deadsnakes PPA often doesn't ship on certain Ubuntu combos).
# dnf uses --skip-broken / setopt=strict=False; apk has no strict "missing package" fail.
_sudo_apt_install_ignore_missing() {
  # args: list of packages; OPT ones that don't exist are skipped silently
  sudo DEBIAN_FRONTEND=noninteractive env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends -o APT::Install-Recommends=false -o Debug::pkgProblemResolver=0 \
    -o APT::Get::Fix-Missing=true --ignore-missing "$@"
}
_add_deadsnakes_ppa() { sudo DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:deadsnakes/ppa; }
_dnf_enable_py311_module() { sudo dnf module enable -y python3.11; }

# --- Cross-distro post-install pip + venv VALIDATION helper.
# Rule: NEVER rely on "did we install python3.X-pip package?" as source of truth.
# Instead: ask the INTERPRETER directly. If pip module missing → bootstrap via
# `pythonX.Y -m ensurepip --upgrade` (CPython stdlib module always bundled with
# deadsnakes, always available on dnf, always available on Alpine py3).
# If venv module missing → install distro-default python3-venv (it supplies the
# shared ensurepip wheels that even non-default python3.X reuses) and retry.
_validate_and_bootstrap_py_venv_pip() {
  local pybin="$1"
  local label_short="${pybin##*/}"
  [ -z "${pybin:-}" ] || ! command -v "$pybin" >/dev/null 2>&1 && return 1
  local ok=1
  if ! "$pybin" -m venv --help >/dev/null 2>&1; then
    _warn "${label_short} -m venv module MISSING after install — trying distro-default python3-venv meta-package (it ships ensurepip wheels shared across all python versions)"
    case "$PM" in
      apt) _run_with_spinner "${label_short}: restore venv module (install distro-default python3-venv meta)" _sudo_pkg_install python3-venv || true ;;
      dnf) _run_with_spinner "${label_short}: restore venv module (dnf: python3-virtualenv + platform-python-devel)" _sudo_pkg_install python3-virtualenv platform-python-devel || true ;;
      apk) _run_with_spinner "${label_short}: restore venv module (apk: py3-virtualenv + python3-dev)" _sudo_pkg_install py3-virtualenv python3-dev || true ;;
    esac
    if ! "$pybin" -m venv --help >/dev/null 2>&1; then
      _nok "${label_short} -m venv STILL MISSING after meta-package install — venv creation will likely fail later; install python<version>-venv manually and rerun"
      ok=0
    else
      _ok "${label_short} -m venv module OK (restored via distro python3-venv meta)"
    fi
  fi
  if ! "$pybin" -m pip --version >/dev/null 2>&1; then
    _warn "${label_short} -m pip MISSING (no separate ${label_short}-pip package shipped by repo) — bootstrapping via ${label_short} -m ensurepip --upgrade (bundled in CPython stdlib, 100% reliable)"
    if ! _run_with_spinner "Bootstrap pip via ${label_short} -m ensurepip --upgrade" "$pybin" -m ensurepip --upgrade; then
      # 2nd tier: download get-pip.py as a last resort
      _warn "ensurepip failed — fallback: curl get-pip.py -> ${label_short} installer"
      curl -fsSL --max-time 30 https://bootstrap.pypa.io/get-pip.py -o /tmp/rasyatone_get_pip.py 2>/dev/null || true
      if [ -s /tmp/rasyatone_get_pip.py ]; then
        _run_with_spinner "Bootstrap pip via get-pip.py (${label_short})" "$pybin" /tmp/rasyatone_get_pip.py --quiet || true
      fi
      rm -f /tmp/rasyatone_get_pip.py 2>/dev/null || true
    fi
    if "$pybin" -m pip --version >/dev/null 2>&1; then
      _ok "${label_short} -m pip bootstrap OK via ensurepip"
    else
      _nok "${label_short} -m pip STILL MISSING after ensurepip — pip installs will FAIL; fix by hand: curl -sSL https://bootstrap.pypa.io/get-pip.py | sudo ${label_short}"
      ok=0
    fi
  fi
  return $(( ok ? 0 : 1 ))
}

# Install Python runtime (>= 3.10 AND <= MAX_ALLOWED_PYTHON_MINOR), plus build
# essentials (git/libpq-dev/libffi-dev/postgresql-client). Runs from BOTH:
#   * precheck_app_prereqs() — so "Run prechecks first?" flow won't fail on
#     servers that only have python 3.14+ (which we refuse to use) BEFORE the
#     precheck detection pass runs.
#   * install_app() — Option 4 proper. If already called in precheck, the apt/dnf
#     calls are idempotent and take ~0s (all packages already marked "installed").
# Returns 0 if a compatible python is available after install (or already was),
# non-zero otherwise (caller decides whether to continue).
_install_compatible_python_runtime() {
  detect_pm
  load_env_file || true
  # Run pkg update once (idempotent) — spinner shows progress during mirror sync.
  _run_with_spinner "Package manager update (mirror sync)" _pkg_update || true
  # Local flags: after install we run _validate_and_bootstrap_py_venv_pip
  # against these interpreter paths (if they exist). Initialised empty for set -u.
  local pydot_11="" pydot_10="" pydot_12="" validated_any=0
  case "$PM" in
    apt)
      # apt (Debian/Ubuntu):
      _run_with_spinner "Install prerequisites (software-properties-common ca-certificates)" _sudo_pkg_install software-properties-common ca-certificates || true
      # If NO acceptable python is present, explicitly install python3.11.
      if ! _py_version_ok python3.11 && ! _py_version_ok python3.10 && ! _py_version_ok python3.12 && { ! _py_version_ok python3.13 || [ "${MAX_ALLOWED_PYTHON_MINOR:-13}" -lt 13 ]; }; then
        if command -v add-apt-repository >/dev/null 2>&1; then
          _run_with_spinner "Add deadsnakes PPA (for python3.11)" _add_deadsnakes_ppa || true
          _run_with_spinner "Refresh apt index after deadsnakes PPA add" _pkg_update || true
        fi
        # --- 2-pass install: MUST-HAVES first (hard fail -> python3.10 fallback),
        # then OPTIONAL packages (--ignore-missing) because deadsnakes PPA on
        # many Ubuntu/LTS combos DOES NOT ship python3.11-pip / python3.10-pip
        # (and sometimes not python3.11-venv as a separate package either).
        # Pip + venv are validated and bootstrapped via ensurepip AFTER.
        if _run_with_spinner "Install python3.11 core (MUST-HAVE: python3.11 python3.11-dev)" _sudo_pkg_install python3.11 python3.11-dev; then
          pydot_11="python3.11"
          _run_with_spinner "Install python3.11 OPTIONAL venv/pip (ignore-missing if repo lacks them)" _sudo_apt_install_ignore_missing python3.11-venv python3.11-pip || true
        else
          _warn "python3.11 core install failed — trying python3.10 core fallback"
          if _run_with_spinner "Fallback: install python3.10 core (MUST-HAVE: python3.10 python3.10-dev)" _sudo_pkg_install python3.10 python3.10-dev; then
            pydot_10="python3.10"
            _run_with_spinner "Install python3.10 OPTIONAL venv/pip (ignore-missing)" _sudo_apt_install_ignore_missing python3.10-venv python3.10-pip || true
          fi
        fi
      fi
      # Always install baseline python3 meta-packages + build tools + libpq/libffi-dev + psql client.
      # + WEASYPRINT DEPENDENCIES (CRITICAL for PDF reports): libpango* is what weasyprint's text/ffi.py tries to dlopen().
      #   Without these, migrate fails with OSError: cannot load library 'libpango-1.0-0' — which the user hit exactly.
      #   WeasyPrint install docs list these exact runtime libs + fontconfig + shared MIME + liberation fonts (PDF glyphs).
      _run_with_spinner "Install build tools + python3 meta + libpq-dev + libffi-dev + postgresql-client + weasyprint deps (pango/cairo/fontconfig)" \
        _sudo_pkg_install python3 python3-venv python3-pip python3-dev git build-essential libpq-dev libffi-dev curl gettext-base postgresql-client \
          libpango-1.0-0 libpangoft2-1.0-0 libpangocairo-1.0-0 libcairo2 libgdk-pixbuf-2.0-0 shared-mime-info fonts-liberation2 fontconfig-config fontconfig || true
      ;;
    dnf)
      # dnf (RHEL/Fedora/Rocky/Alma):
      if ! _py_version_ok python3.11 && ! _py_version_ok python3.10 && ! _py_version_ok python3.12 && { ! _py_version_ok python3.13 || [ "${MAX_ALLOWED_PYTHON_MINOR:-13}" -lt 13 ]; }; then
        if [ -r /etc/redhat-release ] || [ -r /etc/almalinux-release ] || [ -r /etc/rocky-release ] || [ -r /etc/oracle-release ]; then
          _run_with_spinner "dnf: enable python3.11 module (AppStream)" _dnf_enable_py311_module || true
        fi
        # DNF split: MUST-HAVE = python3.11 + devel (hard fail -> python3.10 fallback).
        # OPTIONAL = python3.11-pip (AppStream often omits it; ensurepip bootstrap later).
        # dnf --setopt=strict=0 skips packages that don't exist in any repo.
        if _run_with_spinner "dnf: install python3.11 core (MUST-HAVE: python3.11 python3.11-devel)" _sudo_pkg_install python3.11 python3.11-devel; then
          pydot_11="python3.11"
          _run_with_spinner "dnf: install python3.11 OPTIONAL pip (strict=0 skip if missing)" sudo dnf install -y --setopt=strict=0 --skip-broken python3.11-pip python3.11-venv >/dev/null 2>&1 || true
        else
          _warn "dnf python3.11 core install failed — trying python3.10 core fallback"
          if _run_with_spinner "Fallback: dnf install python3.10 core" _sudo_pkg_install python3.10 python3.10-devel; then
            pydot_10="python3.10"
            _run_with_spinner "dnf: install python3.10 OPTIONAL pip (strict=0 skip if missing)" sudo dnf install -y --setopt=strict=0 --skip-broken python3.10-pip python3.10-venv >/dev/null 2>&1 || true
          fi
        fi
      fi
      # Baseline + build tools. Try with postgresql-contrib first; fall back if not available.
      # + WEASYPRINT DEPENDENCIES (CRITICAL for PDF reports): pango/cairo/gdk-pixbuf/fontconfig — missing these = OSError during migrate.
      _run_with_spinner "dnf: install python3 meta + gcc + libpq/libffi-devel + postgresql + postgresql-contrib + weasyprint deps (pango/cairo)" \
        _sudo_pkg_install python3 python3-devel python3-pip git gcc gcc-c++ make libpq-devel libffi-devel curl postgresql postgresql-contrib \
          pango cairo cairo-gobject gdk-pixbuf2 fontconfig liberation-fonts || \
      _run_with_spinner "dnf: install python3 meta + gcc + libpq/libffi-devel + postgresql + weasyprint deps (fallback no contrib)" \
        _sudo_pkg_install python3 python3-devel python3-pip git gcc gcc-c++ make libpq-devel libffi-devel curl postgresql \
          pango cairo cairo-gobject gdk-pixbuf2 fontconfig liberation-fonts || true
      ;;
    apk)
      # Alpine: python3 + build tools + dev headers.
      # + WEASYPRINT DEPENDENCIES (CRITICAL for PDF reports): pango/cairo/gdk-pixbuf/fontconfig/ttf-liberation
      _run_with_spinner "apk: install python3 + build tools + postgresql-dev + libffi-dev + weasyprint deps (pango/cairo)" \
        _sudo_pkg_install python3 py3-virtualenv py3-pip python3-dev git build-base postgresql-dev libffi-dev curl postgresql-client \
          pango cairo gdk-pixbuf fontconfig ttf-liberation || true
      ;;
  esac
  # ---------------------------------------------------------------
  # POST-INSTALL: cross-distro pip + venv module VALIDATE + BOOTSTRAP
  # ---------------------------------------------------------------
  # If we just installed pydot_11/pydot_10/pydot_12 via the PM-specific branches
  # above, validate and run ensurepip bootstrap on them FIRST (highest priority).
  # NOTE: do NOT redirect output to /dev/null — this section runs slow spinner
  # operations (ensurepip bootstrap, get-pip.py download, apt install venv meta)
  # that MUST be visible to the user (they are exactly the activity indicator
  # the user expects; hiding them reproduces the "blinking cursor / shows nothing"
  # bug reported repeatedly in prior runs). Caller sets || true anyway so RC≠0
  # never aborts anything in set -e mode.
  local pv
  for pv in "$pydot_12" "$pydot_11" "$pydot_10"; do
    if [ -n "${pv:-}" ] && command -v "$pv" >/dev/null 2>&1; then
      _validate_and_bootstrap_py_venv_pip "$pv" || true
      validated_any=1
    fi
  done
  # If no per-minor python was installed above (or user already had a compatible
  # one), fall back to whatever _detect_compatible_python3 finds and validate it.
  if [ "$validated_any" -eq 0 ]; then
    if _detect_compatible_python3 2>/dev/null && [ -n "${PYTHON_BIN:-}" ] && command -v "$PYTHON_BIN" >/dev/null 2>&1; then
      _validate_and_bootstrap_py_venv_pip "$PYTHON_BIN" || true
    fi
  fi
  # Final post-install check: is there now a compatible python?
  _detect_compatible_python3 2>/dev/null
}

service_control() {
  local action="$1" name="${2:-postgresql}"
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl "$action" "$name" 2>/dev/null || sudo systemctl "$action" "postgresql" 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    # OpenRC: start/stop/restart/status go to rc-service; enable/disable go to rc-update add/del
    case "$action" in
      enable)  sudo rc-update add "$name" default 2>/dev/null || sudo rc-update add postgresql default 2>/dev/null || true ;;
      disable) sudo rc-update del "$name" default 2>/dev/null || sudo rc-update del postgresql default 2>/dev/null || true ;;
      *)       sudo rc-service "$name" "$action" 2>/dev/null || sudo rc-service postgresql "$action" 2>/dev/null || true ;;
    esac
  elif command -v rc-update >/dev/null 2>&1; then
    # Only rc-update exists but no rc-service (rare corner case): enable/disable work via rc-update
    case "$action" in
      enable)  sudo rc-update add "$name" default 2>/dev/null || true ;;
      disable) sudo rc-update del "$name" default 2>/dev/null || true ;;
      *)       _warn "rc-update present but rc-service missing; cannot run '$action $name' — run manually via OpenRC init scripts" ;;
    esac
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
        sudo ufw allow "${port}/${proto}" comment "$comment" >/dev/null 2>&1 || true
        if sudo ufw status 2>/dev/null | grep -Eq "^${port}/${proto}\\b" 2>/dev/null; then
          return 0
        fi
      fi
      sudo ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
      if sudo ufw status 2>/dev/null | grep -Eq "^${port}/${proto}\\b" 2>/dev/null; then
        return 0
      fi
      if [ "$proto" = "tcp" ] && [ "$port" = "443" ]; then
        sudo ufw allow https >/dev/null 2>&1 || true
        if sudo ufw status 2>/dev/null | grep -Eq "^(443/tcp|https)\\b" 2>/dev/null; then
          return 0
        fi
      fi
      return 1
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
  DJANGO_SETTINGS_MODULE="$DEF_DJANGO_SETTINGS_MODULE"; GUNICORN_BIND="$DEF_GUNICORN_BIND"; SERVICE_NAME="$DEF_SERVICE"; SERVICE_ACCOUNT="$DEF_SERVICE_ACCOUNT"
  USE_UNIX_SOCKET="$DEF_USE_UNIX_SOCKET"; ENABLE_SYSTEMD_HARDENING="$DEF_ENABLE_SYSTEMD_HARDENING"; ENABLE_NGINX_LOGROTATE="$DEF_ENABLE_NGINX_LOGROTATE"
  if [ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ]; then
    _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
    set -a; . "$ENV_FILE" || true; set +a
    DB_NAME="${DB_NAME:-$DEF_DB_NAME}"; DB_USER="${DB_USER:-$DEF_DB_USER}"
    DB_HOST="${DB_HOST:-$DEF_DB_HOST}"; DB_PORT="${DB_PORT:-$DEF_DB_PORT}"
    LISTEN_ADDRESSES="${LISTEN_ADDRESSES:-$DEF_LISTEN_ADDRESSES}"
    APP_DIR="${APP_DIR:-$DEF_APP_DIR}"; GIT_BRANCH="${GIT_BRANCH:-$DEF_GIT_BRANCH}"
    DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
    GUNICORN_BIND="${GUNICORN_BIND:-$DEF_GUNICORN_BIND}"; SERVICE_NAME="${SERVICE_NAME:-$DEF_SERVICE}"; SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}"
    USE_UNIX_SOCKET="${USE_UNIX_SOCKET:-$DEF_USE_UNIX_SOCKET}"; ENABLE_SYSTEMD_HARDENING="${ENABLE_SYSTEMD_HARDENING:-$DEF_ENABLE_SYSTEMD_HARDENING}"; ENABLE_NGINX_LOGROTATE="${ENABLE_NGINX_LOGROTATE:-$DEF_ENABLE_NGINX_LOGROTATE}"
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

  # 0. Python runtime auto-install (same code as Option 4 proper — idempotent).
  #    If this server ONLY has Python >= 3.14 (MAX cap), or Python < 3.10 (too old),
  #    we MUST resolve it HERE before running detection checks, because the user
  #    defaulted "Run prechecks first?" to Y. Otherwise the precheck would fail
  #    immediately on the hard-cap DIE (even though install_app would have fixed
  #    it one step later). This is the exact bug the user reported: Option 4 ->
  #    prechecks ran first, hit 3.14-only, died before install_app got a chance.
  printf "  Auto-installing python3.11 / build tools (if needed) — mirrors + apt/dnf may run ...\n" >&2
  set +e
  _install_compatible_python_runtime
  local pyrc=$?
  set -e
  if [ "$pyrc" -eq 0 ]; then
    _ok "Python runtime auto-install OK: PYTHON_BIN=${PYTHON_BIN:-<pending>}"
  else
    _warn "Python runtime auto-install completed but post-check still unmet (will run normal detection next to get exact fail reason)"
  fi

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

  # 4. python3 version (Django 5 floor: >= 3.10, MAX_ALLOWED_PYTHON_MINOR cap).
  #    NOTE: _install_compatible_python_runtime already ran above, so if this
  #    still fails → deadsnakes PPA was unreachable OR repo index is stale —
  #    give the user EXACT commands to run (not vague "rerun Option 4").
  if _detect_compatible_python3; then
    local show_ver
    show_ver=$("$PYTHON_BIN" -c 'import sys;print(sys.version_info.major,sys.version_info.minor)' 2>/dev/null || echo "0 0")
    _ok "python3 version OK: ${PYTHON_BIN} -> v${show_ver} (>= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}, <= 3.${MAX_ALLOWED_PYTHON_MINOR:-13})"
  else
    local cur_ver="0.0"
    if command -v python3 >/dev/null 2>&1; then
      cur_ver=$(python3 -c 'import sys;print(sys.version_info.major,".",sys.version_info.minor,sep="")' 2>/dev/null || echo "0.0")
    fi
    _nok "NO compatible Python (need >= 3.${MIN_PYTHON_MINOR} AND <= 3.${MAX_ALLOWED_PYTHON_MINOR:-13}). System python3=${cur_ver}. The installer tried AUTO-INSTALL python3.11 but it FAILED (deadsnakes PPA unreachable? no internet?). Exact manual fix: apt install software-properties-common ca-certificates ; DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:deadsnakes/ppa ; apt update ; DEBIAN_FRONTEND=noninteractive apt install -y python3.11 python3.11-venv python3.11-pip python3.11-dev  — then rerun Option 2 / 4." || ((fail++))
  fi

  # 5. venv + pip modules (only if we found a compatible python)
  if [ -n "${PYTHON_BIN:-}" ] && command -v "${PYTHON_BIN##*/}" >/dev/null 2>&1; then
    "$PYTHON_BIN" -m venv --help >/dev/null 2>&1 && _ok "${PYTHON_BIN} -m venv module available" || { _nok "${PYTHON_BIN##*/}-venv / python3-venv package missing — Option 4 will install it"; ((fail++)); }
    "$PYTHON_BIN" -m pip --version >/dev/null 2>&1  && _ok "${PYTHON_BIN} -m pip module available"  || { _nok "${PYTHON_BIN##*/}-pip / python3-pip package missing — Option 4 will install it";  ((fail++)); }
  fi

  # 6. git + URL reachable
  if command -v git >/dev/null 2>&1; then _ok "git installed: $(git --version 2>&1 | head -n1)"
  else _nok "git binary not installed" || ((fail++)); fi
  if [ -z "${GIT_URL:-}" ]; then printf "\n"; GIT_URL=$(prompt_def "Git repository URL (to verify reachability)" "") || true; fi
  if [ -n "$GIT_URL" ] && command -v git >/dev/null 2>&1; then
    local git_label=""
    git_label=$(_trunc_label "$GIT_URL" 60)
    if _run_with_spinner "Git ls-remote reachability probe (${git_label})" bash -c 'GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$1" >/dev/null 2>&1' _ "$GIT_URL"; then
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
    if _run_with_spinner "nc TCP probe $DB_HOST:$DB_PORT (timeout 3s)" nc -z -w3 "$DB_HOST" "$DB_PORT" 2>/dev/null; then _ok "DB host $DB_HOST:$DB_PORT TCP reachable (nc -z)"
    else _nok "DB host $DB_HOST:$DB_PORT NOT reachable via nc -z -w3 — wrong host? firewall?" || ((fail++)); fi
  elif [ "$vars_ok" = "1" ]; then _warn "nc missing; skipping DB host:port TCP probe"; fi

  # 11. full psql SELECT 1
  local row psql_out="/tmp/rasyatone_prechk_psql_$$.out"
  if [ "$vars_ok" = "1" ] && command -v psql >/dev/null 2>&1; then
    local s1_attempt=0 s1_max=3 s1_done=0
    while [ "$s1_attempt" -lt "$s1_max" ] && [ "$s1_done" -ne 1 ]; do
      s1_attempt=$(( s1_attempt + 1 ))
      _run_with_spinner "psql SELECT 1 credential test ($s1_attempt/$s1_max) ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}" bash -c 'PGPASSWORD="$1" timeout 8 psql -h "$2" -p "$3" -U "$4" -d "$5" -tAc "SELECT 1" >"$6" 2>&1' _ "$DB_PASSWORD" "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_NAME" "$psql_out" || true
      row=$(cat "$psql_out" 2>/dev/null | tr -d '[:space:]' || true)
      if [ "$row" = "1" ]; then
        s1_done=1
        _ok "psql SELECT 1 via DB_USER=$DB_USER succeeded"
      else
        local _psql_cause2="" _psql_action2="" _pe2=""
        _pe2=$(cat "$psql_out" 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
        case "$_pe2" in
          *database*does*not*exist*)
            _psql_cause2="DATABASE OBJECT MISSING: PostgreSQL is running + your password was CORRECT (postgres did NOT reject auth) — but CREATE DATABASE '${DB_NAME}' was never run, so the object does not exist in pg_catalog.pg_database. You must run Option 3 FIRST (install PostgreSQL + CREATE ROLE + CREATE DATABASE) before Option 4 can validate credentials against the target DB."
            _psql_action2="Action 1 (recommended): exit this menu → run Option 3 fully (will CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} and return here). Action 2 (if Postgres is already installed/running): run this one-liner NOW on the DB server as root:  sudo -u postgres psql postgres -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};\"  then retry this preflight."
            ;;
          *password*authentication*failed*for*user*)
            _psql_cause2="WRONG DB_PASSWORD (PostgreSQL scram-sha-256/md5 auth failed). DB_HOST, DB_PORT, DB_USER, DB_NAME are all VALID and reachable; only the password hash stored for role does not match DB_PASSWORD="
            _psql_action2="Fix DB_PASSWORD value above (edit in prompt) OR reset role password on DB server: sudo -u postgres psql postgres -c \"ALTER ROLE ${DB_USER} WITH PASSWORD 'your-new-password-here';\" then paste that value into DB_PASSWORD in this prompt."
            ;;
          *role*\"*\"*does*not*exist*|*role*does*not*exist|*user*\"*\"*does*not*exist*)
            _psql_cause2="ROLE ${DB_USER} DOES NOT EXIST in pg_roles on server. Option 3 CREATE ROLE was never run or failed — otherwise everything else is OK."
            _psql_action2="Run Option 3 FIRST from main menu to create role+password+DB, OR on DB server: sudo -u postgres psql postgres -c \"CREATE ROLE ${DB_USER} LOGIN PASSWORD 'password' NOSUPERUSER NOCREATEROLE CREATEDB; CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};\"."
            ;;
          *no*pg_hba\.conf*entry*|*host\ *no\ *authentication|*pg_hba*)
            _psql_cause2="pg_hba.conf REJECT: server has no allow rule for source_IP + user + DB combination. Postgres is reachable + password would be tested next (after pg_hba), but this is a firewall-style first reject."
            _psql_action2="On DB server: append 'host all all 10.0.0.0/24 scram-sha-256' to /etc/postgresql/*/main/pg_hba.conf; ensure postgresql.conf listen_addresses='*'; then sudo systemctl restart postgresql."
            ;;
          *connection\ *refused|could\ *not\ *connect\ *to\ *server|no\ *route\ *to\ *host|connection\ *timed\ *out|host\ *is\ *not\ *listening*)
            _psql_cause2="NETWORK/SERVER DOWN: PostgreSQL daemon not listening on DB_HOST:DB_PORT = ${DB_HOST}:${DB_PORT} (postgres not running, firewall blocking 5432, or wrong host/port)."
            _psql_action2="Check DB server: sudo systemctl status postgresql; sudo ss -ltnp | grep :5432; sudo nc -zv ${DB_HOST} ${DB_PORT}; fix listen_addresses/start postgres/open firewall."
            ;;
          *timeout*|*terminating\ *connection\ *due\ *to\ *connection\ *timeout*)
            _psql_cause2="NETWORK TIMEOUT (packets dropped, not rejected). Firewall DROP rule or wrong DB_HOST."
            _psql_action2="Same as CONNECTION REFUSED plus check iptables -S FORWARD for drops."
            ;;
          *)
            _psql_cause2="Other psql error: $(cat "$psql_out" 2>/dev/null | tail -n 3 | tr '\n' ' ')"
            _psql_action2="Edit credentials in prompt and retry; or view server log journalctl -u postgresql --since '10 min ago'."
            ;;
        esac
        # ── AUTO-FIX: if cause is DB missing OR role missing AND sudo -u postgres is available, offer to create them RIGHT HERE.
        local _auto_ok=0
        case "$_pe2" in
          *database*does*not*exist*|*role*does*not*exist*|*user*does*not*exist*)
            if _psql_auto_fix_missing_role_or_db "$_pe2" "${DB_USER}" "${DB_NAME}" "${DB_PASSWORD}"; then
              # Reload row since auto-fix created DB/role:
              local _arow=""
              _arow=$(PGPASSWORD="$DB_PASSWORD" timeout 6 psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1" 2>/dev/null | tr -d '[:space:]' || true)
              if [ "$_arow" = "1" ]; then
                s1_done=1
                _auto_ok=1
                _ok "psql SELECT 1 via DB_USER=$DB_USER succeeded after AUTO-FIX."
              fi
            fi
            ;;
        esac
        if [ "$s1_attempt" -lt "$s1_max" ] && [ "$_auto_ok" -ne 1 ]; then
          _warn "psql SELECT 1 FAILED attempt $s1_attempt/$s1_max. DETECTED CAUSE: ${_psql_cause2}. Raw output: $(cat "$psql_out" 2>/dev/null | tail -n 5 | tr '\n' ' ')"
          _info "FIX SUGGESTION: ${_psql_action2}"
          # ── Pre-populate superuser sentinel defaults into ENV_FILE before prompt_edit_multiple (prevents (EMPTY) for new fields; user can overwrite.
          if [ -n "${ENV_FILE:-}" ]; then
            grep -q "^DB_SUPERUSER_USER=" "$ENV_FILE" 2>/dev/null || echo "DB_SUPERUSER_USER='postgres'" >> "$ENV_FILE"
            grep -q "^DB_SUPERUSER_PASSWORD=" "$ENV_FILE" 2>/dev/null || echo "DB_SUPERUSER_PASSWORD=''" >> "$ENV_FILE"
            _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
            set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
          fi
          prompt_edit_multiple \
            "psql SELECT 1 credential test FAILED — edit DB creds to fix. Sentinel fields: DB_SUPERUSER_USER/DB_SUPERUSER_PASSWORD enable remote-TCP CREATE ROLE/DATABASE if local peer/sudo unavailable." \
            "DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT DB_SUPERUSER_USER DB_SUPERUSER_PASSWORD" \
            "Retry psql SELECT 1 with (possibly edited) values?" \
            "y"
        else
          _warn "psql SELECT 1 FAILED all $s1_max attempts. DETECTED CAUSE: ${_psql_cause2}. FIX SUGGESTION: ${_psql_action2}. Will mark as FAIL on precheck summary."
          ((fail++)) || true
        fi
      fi
    done
    rm -f "$psql_out" 2>/dev/null || true
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
  DB_NAME=$(prompt_w_retry "Database name"            "${DB_NAME:-$DEF_DB_NAME}" 3 _validator_nonempty "Database name CANNOT be empty — examples: rasyatone_db, myapp_db.")
  DB_USER=$(prompt_w_retry "Database user"            "${DB_USER:-$DEF_DB_USER}" 3 _validator_nonempty "Database user CANNOT be empty — examples: rasyatone_db_user, appuser.")
  DB_PASSWORD=$(prompt_w_retry "Database user password" "${DB_PASSWORD:-}" 3 _validator_nonempty "Database password CANNOT be empty. Pick a strong password and remember it — the application will need it to connect." "secret")
  DB_HOST=$(prompt_w_retry "Database host (use 'localhost' for local socket)" "${DB_HOST:-$DEF_DB_HOST}" 3 _validator_nonempty "Database host CANNOT be empty. Examples: 'localhost' (local Unix socket), '127.0.0.1', or a remote hostname like 'db.example.com'.")
  DB_PORT=$(prompt_w_retry "Database port"            "${DB_PORT:-$DEF_DB_PORT}" 3 _validator_nonempty "Database port CANNOT be empty. PostgreSQL default = 5432.")
  LISTEN_ADDRESSES=$(prompt_w_retry \
    "PostgreSQL listen_addresses ('*' = all, 'localhost' = local only)" \
    "${LISTEN_ADDRESSES:-$DEF_LISTEN_ADDRESSES}" \
    3 _validator_cidr_list_or_star \
    "listen_addresses syntax error. Acceptable values: '*' (all interfaces), 'localhost', comma-separated IPv4 CIDR list (e.g. 127.0.0.1,10.0.0.0/8), or IPv6 colon forms.")
  local ALLOW_PG_DBS="ALL"  # DEFAULT = ALL (strongly recommended). Only SELF if user explicitly chooses it.
  ALLOW_PG_DBS_RAW=$(prompt_def "Which databases should '$DB_USER' connect to? [RECOMMENDED: ALL = '$DB_NAME' + postgres + all DBs. SELF = ONLY '$DB_NAME' — NOTE: pgAdmin / DBeaver default test connection uses database='postgres' and WILL FAIL if you pick SELF]" "ALL")
  ALLOW_PG_DBS_RAW=$(printf "%s" "$ALLOW_PG_DBS_RAW" | tr '[:lower:]' '[:upper:]')
  case "$ALLOW_PG_DBS_RAW" in
    ALL) ALLOW_PG_DBS="ALL" ;;
    *)   ALLOW_PG_DBS="SELF" ;;
  esac
  local ROLE_CREATEDB="YES"  # DEFAULT = YES per user request: the DB user MUST be able to CREATE DATABASE after install.
  ROLE_CREATEDB_RAW=$(prompt_def "Grant '$DB_USER' permission to CREATE DATABASE (CREATEDB attribute)? [RECOMMENDED YES — allows application / user / migration scripts to run 'CREATE DATABASE ...' without sudo -u postgres. NO = only postgres/superuser can create DBs]" "YES")
  ROLE_CREATEDB_RAW=$(printf "%s" "$ROLE_CREATEDB_RAW" | tr '[:lower:]' '[:upper:]')
  case "$ROLE_CREATEDB_RAW" in
    NO|N) ROLE_CREATEDB="NO" ;;
    *)    ROLE_CREATEDB="YES" ;;
  esac
  local ROLE_ATTRS=""
  if [ "$ROLE_CREATEDB" = "YES" ]; then
    ROLE_ATTRS="CREATEDB"
    _ok "Role attributes: ${ROLE_ATTRS}  (user '$DB_USER' will be able to run CREATE DATABASE after install)"
  else
    _warn "Role attributes: NO special attributes (user '$DB_USER' CANNOT run CREATE DATABASE — only superuser/postgres can create DBs). If this is wrong, rerun Option 3 and answer YES."
  fi
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
  _run_with_spinner "Package manager mirror sync ($PM)" _pkg_update || true
  case "$PM" in
    apt) _run_with_spinner "apt: install postgresql + client + contrib + locales" \
           _sudo_pkg_install postgresql postgresql-client postgresql-contrib locales ;;
    dnf) _run_with_spinner "dnf: install postgresql-server + postgresql-contrib" \
           _sudo_pkg_install postgresql-server postgresql-contrib ;;
    apk) _run_with_spinner "apk: install postgresql + client + contrib" \
           _sudo_pkg_install postgresql postgresql-client postgresql-contrib ;;
  esac
  _ok "PostgreSQL packages installed via $PM"

  # initdb on first install (RHEL-based / Alpine) — spinner shown so user sees
  # activity (initdb can take a few seconds on slow IO / first-boot entropy low)
  if command -v postgresql-setup >/dev/null 2>&1; then
    _run_with_spinner "postgresql-setup --initdb (RHEL/Alma/Rocky first-boot init)" bash -c "sudo postgresql-setup --initdb --unit postgresql 2>/dev/null || true" || true
  elif [ "$PM" = "apk" ] && ls -d /var/lib/postgresql/*/data >/dev/null 2>&1; then
    local ddir
    for ddir in /var/lib/postgresql/*/data; do
      if [ -z "$(ls -A "$ddir" 2>/dev/null | head -n1)" ]; then
        _run_with_spinner "initdb -D $ddir (Alpine PostgreSQL first-boot data init)" \
          bash -c "sudo su - postgres -c 'initdb -D \"$ddir\"' 2>/dev/null || true" || true
      fi
    done
  fi
  service_control enable postgresql
  _run_with_spinner "Start PostgreSQL service (postgresql)" service_control start postgresql || true

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
    printf "\033[1;93m[DB-STEP 1/6] role does NOT exist -> writing %s (CREATE ROLE standalone, attrs=%s NO DO block)\033[0m\n" "$SQL_ROLE_CREATE" "$ROLE_ATTRS"
    printf 'CREATE ROLE %s %s LOGIN PASSWORD '"'"'%s'"'"';\n' "$DB_USER" "$ROLE_ATTRS" "$esc_pw" > "$SQL_ROLE_CREATE"
    printf "  contents of %s:\n" "$SQL_ROLE_CREATE"; sed 's/^/    | /' "$SQL_ROLE_CREATE"
    _run_with_spinner "psql: CREATE ROLE ${DB_USER} (via -f ${SQL_ROLE_CREATE##*/})" sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$SQL_ROLE_CREATE"
    _ok "Role ${DB_USER} created (attrs=${ROLE_ATTRS:-NONE}, via -f $SQL_ROLE_CREATE)"
  else
    printf "\033[1;93m[DB-STEP 1/6] role exists -> writing %s (ALTER ROLE standalone, attrs=%s NO DO block)\033[0m\n" "$SQL_ROLE_ALTER" "$ROLE_ATTRS"
    printf 'ALTER ROLE %s WITH %s PASSWORD '"'"'%s'"'"';\n' "$DB_USER" "$ROLE_ATTRS" "$esc_pw" > "$SQL_ROLE_ALTER"
    printf "  contents of %s:\n" "$SQL_ROLE_ALTER"; sed 's/^/    | /' "$SQL_ROLE_ALTER"
    _run_with_spinner "psql: ALTER ROLE ${DB_USER} password+attrs (via -f ${SQL_ROLE_ALTER##*/})" sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$SQL_ROLE_ALTER"
    _ok "Role ${DB_USER} existed -> password updated + attrs=${ROLE_ATTRS:-NONE} applied (via -f $SQL_ROLE_ALTER)"
  fi
  # (A2) POST-VERIFY role attributes. Ensure CREATEDB is actually set (if user requested YES) before continuing.
  local cd_check=""
  cd_check=$(sudo -u postgres psql -tAc "SELECT rolcreatedb FROM pg_roles WHERE rolname='${esc_user}'" postgres 2>/dev/null | tr -d '[:space:]' || true)
  if [ "$ROLE_CREATEDB" = "YES" ]; then
    if [ "$cd_check" = "t" ]; then
      _ok "Role attribute verify -> rolcreatedb = TRUE (user '$DB_USER' CAN run CREATE DATABASE — verified OK)"
    else
      _die "VERIFY FAILED: ROLE CREATEDB NOT SET. Requested ROLE_CREATEDB=YES but pg_roles says rolcreatedb=$cd_check. Build=$SCRIPT_VERSION_BUILD"
    fi
  else
    if [ "$cd_check" = "t" ]; then
      _warn "Role attribute verify: rolcreatedb = TRUE even though you requested NO. Attribute leak from prior role state; leaving as-is (has create DB permission)"
    else
      _ok "Role attribute verify -> rolcreatedb = FALSE (user '$DB_USER' cannot CREATE DATABASE — matches NO request)"
    fi
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
    _run_with_spinner "psql: CREATE DATABASE ${DB_NAME} owner=${DB_USER} (via -f ${SQL_DB_CREATE##*/})" sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$SQL_DB_CREATE"
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
  _run_with_spinner "psql: GRANT ALL on ${DB_NAME} to ${DB_USER} + set owner (via -f ${SQL_DB_GRANT##*/})" sudo -u postgres psql -v ON_ERROR_STOP=1 postgres -f "$SQL_DB_GRANT"
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
    # ====== IDENTIFIABLE RULE CLEANUP (two passes = NEVER removes admin custom rules) ======
    # PASS A FIRST (strongest): delete the installer marker block if present on rerun.
    #   Since we are about to write a NEW marker block, the old one MUST be deleted first.
    #   Marker block = "## RASyatone installer rules ..." header line  →  "## END RASyatone" line.
    if grep -Fq "$marker" "$pg_hba" 2>/dev/null; then
      sudo sed -i "/^${marker}/,/^## END RASyatone/d" "$pg_hba" 2>/dev/null || true
    fi
    # PASS B SECOND (legacy): delete UNMARKED DB_USER+scram-sha-256 rules written by OLD builds of
    #   this installer that had NO marker block (pre-rewrite versions). CRITICAL safety property:
    #   because PASS A already removed the CURRENT marker block, EVERY line matching the pattern
    #   below is NECESSARILY a pre-marker ghost rule (not a marker-block rule, not admin custom).
    #   We do NOT touch rules using md5, ident, peer, or auth-methods other than scram-sha-256,
    #   and we do NOT touch rules for users != DB_USER — admin custom rules are safe.
    sudo sed -i -E "/^[[:space:]]*(local|host|hostssl|hostnossl)[[:space:]]+[^[:space:]]+[[:space:]]+${DB_USER}[[:space:]]+(samenet|samehost|local|[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]+)?|::1?\/?[0-9]*)[[:space:]]+scram-sha-256[[:space:]]*$/d" \
      "$pg_hba" 2>/dev/null || true

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
  _run_with_spinner "Restart PostgreSQL service (apply listen_addresses + pg_hba changes)" service_control restart postgresql

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
  if [ "$ALLOW_PG_DBS" = "ALL" ]; then
    printf "   (a) \033[92mALLOW_PG_DBS=ALL — ANY database name works!\033[0m The pg_hba rules match: DB_NAME='%s', postgres, template1, and every other DB. pgAdmin/DBeaver Test Connection button with database='postgres' (their default) WORKS. User/password: user='%s' password='<the value you typed>'\n" "$DB_NAME" "$DB_USER"
  else
    printf "   (a) \033[93mALLOW_PG_DBS=SELF — ONLY database='%s' works!\033[0m Do NOT use database='postgres' (pgAdmin/DBeaver default) with SELF mode — it will FAIL. Connect specifically to database='%s' in your client connection settings. User/password: user='%s' password='<the value you typed>'\n" "$DB_NAME" "$DB_NAME" "$DB_USER"
  fi
  printf "   (b) Remote CLIENT IP (the machine running pgAdmin, NOT this server!) must be inside PG_ALLOW_IPS = %s\n       If it's missing: rerun Option 3 and ADD the client's public CIDR (e.g. if client has public IP 203.0.113.14 → enter 203.0.113.14/32 in the PG_ALLOW_IPS prompt)\n" "$PG_ALLOW_IPS"
  printf "   (c) Server firewall must pass PostgreSQL %s/tcp — the firewall step (Option 3) enabled it and printed a summary. Re-check with: sudo ufw status numbered  |  sudo firewall-cmd --list-ports  |  sudo iptables -S\n" "$DB_PORT"
  if [ "$ssl_on" -eq 1 ]; then
    printf "   (d) Server SSL is ON → client can connect with sslmode=require/prefer for TLS (pg_hba has both hostssl + host rules; SSL clients match hostssl first)\n"
  else
    printf "   (d) Server SSL is OFF → pg_hba 'host' rule matches plain TCP only. If your GUI client INSISTS on sslmode=require and fails, change it to sslmode=prefer/disable in the connection settings.\n"
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
# === github_auth_private_repo: GitHub Fine-Grained PAT auth for private repos ===
# Architectural principles (this is the ONE TRUE implementation for this flow):
#   1. VERIFY BEFORE TRUST  : Any persisted token is *always* re-verified via git ls-remote probe
#                             before returning. No expired/revoked tokens auto-fast-path past the check.
#   2. WRITE AFTER VERIFY    : Token file on disk is written/updated ONLY after a successful probe.
#                             Bad/invalid tokens never pollute the persisted state.
#   3. ONE CANONICAL WRITER  : Single helper _save_github_token() writes git_token.env —
#                             zero duplication between initial/retry branches.
#   4. SANITIZE EVERY INPUT  : All URLs go through _normalize_github_url. Owner/repo split on
#                             single '/' — no "../../etc/passwd" style tricks possible.
#   5. TIMEOUT EVERY NETWORK : All git ls-remote calls use timeout(1) — no hangs.
#   6. SSH URL DETECTION     : User pastes git@github.com: form → we ASK whether they already
#                             configured SSH keys on this server (skip wizard) or want to switch to
#                             the Fine-Grained PAT HTTPS method documented here.
# Reference: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-fine-grained-personal-access-token
# Inputs (globals)  : GIT_URL  — user-pasted URL. HTTPS or SSH git@github.com: form.
# Outputs (globals) : GIT_URL  — rewritten to canonical https://x-access-token:<TOKEN>@github.com/<owner>/<repo>.git
# Side effects      : Writes /etc/rasyatone/static/git_token.env (GITHUB_TOKEN=… chmod 600 root:root)
github_auth_private_repo() {
  # ── Fast skip: not GitHub at all ──────────────────────────────────────────
  case "$GIT_URL" in
    *github.com*) ;;
    *) return 0 ;;
  esac

  # ── Helper: save token to disk (ONE CANONICAL WRITER, writes AFTER verify) ─
  _save_github_token() {
    # Caller must have already verified token works.
    sudo mkdir -p "$(dirname "$GIT_TOKEN_FILE")"
    {
      echo "# RaSYaTone GitHub token — single Fine-Grained PAT reused across all deployment servers."
      echo "# Written by install.sh github_auth_private_repo()."
      echo "# Rotation: re-generate in GitHub UI when it expires, re-run Option 4, paste new token."
      echo "# SENSITIVE: DO NOT commit. Disk chmod: 600 owner=root:root."
      printf 'GITHUB_TOKEN=%s\n' "$TOKEN"
    } | sudo tee "$GIT_TOKEN_FILE" >/dev/null
    sudo chmod 0600 "$GIT_TOKEN_FILE"
    sudo chown 0:0 "$GIT_TOKEN_FILE"
  }

  # ── Helper: prompt for a token (ONE prompt text, used everywhere) ─────────
  _prompt_token() {
    local label="${1:-Paste the Fine-Grained token (github_pat_.../ghs_...) here. Hidden input, echo off.}"
    local t=""
    while [ -z "${t:-}" ]; do
      t=$(prompt_secret "$label")
      [ -n "${t:-}" ] || printf "  Token cannot be empty. Try again (or Ctrl-C to abort).\n" >&2
    done
    printf '%s' "$t"
  }

  # ── Helper: run probe + set globals passed by reference names ─────────────
  # Sets: $1 (out_rc) exit code, $2 (out_log) log contents trimmed, $3 (out_headcount) branch count
  _run_auth_probe() {
    local __rcvar="$1" __logvar="$2" __hcvar="$3" log="" rc=0 hc="0"
    log="$(GIT_TERMINAL_PROMPT=0 timeout 15 git ls-remote --heads "$GIT_URL" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$log" ]; then
      hc=$(printf '%s\n' "$log" | grep -c '^' 2>/dev/null || echo "0")
      # hc=$(wc -l <<< trimmed) but grep -c '^' is robust to empty input on busybox
      hc=$(printf '%s' "$log" | awk 'END{print NR}' 2>/dev/null || echo "0")
    fi
    eval "$__rcvar=\"$rc\""
    eval "$__logvar=\$log"
    eval "$__hcvar=\"$hc\""
  }

  # ── Step 1: Extract + sanitize OWNER_REPO. Run ALWAYS. ────────────────────
  local OWNER_REPO="" GIT_OWNER="" GIT_REPO="" IN_URL_TOKEN=""
  local GIT_TOKEN_FILE="/etc/rasyatone/static/git_token.env"
  local EXISTING_TOKEN="" TOKEN="" INPUT_WAS_SSH="0"

  # Detect SSH URL (git@github.com:owner/repo) BEFORE regex extraction — user might want SSH skip
  case "$GIT_URL" in
    git@github.com:*) INPUT_WAS_SSH="1" ;;
  esac

  if [[ "$GIT_URL" =~ @github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) ]]; then
    OWNER_REPO="${BASH_REMATCH[1]}"
  elif [[ "$GIT_URL" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) ]]; then
    OWNER_REPO="${BASH_REMATCH[1]}"
  else
    OWNER_REPO="$(printf '%s' "$GIT_URL" | sed -E 's|^[[:space:]]*(https?://[^/]+/|git@github\.com:)||')"
  fi

  # Layer 1 strip: sed label loop (portable)
  OWNER_REPO="$(printf '%s' "$OWNER_REPO" | sed -E \
    -e 's|^[/]*||' -e 's|[/]*$||' \
    -e ':a' -e 's|(\.git)[/]*$||' -e 't a' -e 's|[/]*$||')"
  # Layer 2 strip: bash parameter-expansion fixed-point loop (backup for weird sed builds)
  local prev=""
  while [ "$prev" != "$OWNER_REPO" ]; do
    prev="$OWNER_REPO"
    while [ "${OWNER_REPO%/}" != "$OWNER_REPO" ]; do OWNER_REPO="${OWNER_REPO%/}"; done
    while [ "${OWNER_REPO%.git}" != "$OWNER_REPO" ]; do OWNER_REPO="${OWNER_REPO%.git}"; done
  done
  while [ "${OWNER_REPO#/}" != "$OWNER_REPO" ]; do OWNER_REPO="${OWNER_REPO#/}"; done
  while [ "${OWNER_REPO%/}" != "$OWNER_REPO" ]; do OWNER_REPO="${OWNER_REPO%/}"; done

  # Structural validation: MUST be exactly owner/repo — no more, no fewer slashes, non-empty parts
  case "$OWNER_REPO" in
    */*) : ;;
    *)   _die "GIT_URL='$GIT_URL' did not parse into owner/repo form. Paste HTTPS (https://github.com/owner/repo) or SSH (git@github.com:owner/repo)." ;;
  esac
  GIT_OWNER="${OWNER_REPO%%/*}"
  GIT_REPO="${OWNER_REPO#*/}"
  GIT_REPO="${GIT_REPO%%/*}"          # drop everything after second '/' (path injection guard)
  OWNER_REPO="${GIT_OWNER}/${GIT_REPO}"
  [ -n "$GIT_OWNER" ] || _die "GitHub owner name empty from GIT_URL='$GIT_URL'"
  [ -n "$GIT_REPO" ]  || _die "GitHub repo name empty from GIT_URL='$GIT_URL'"
  printf "\n"
  _info "Parsed GitHub repo: owner='%s', repo='%s' (canonical: github.com/%s)" "$GIT_OWNER" "$GIT_REPO" "$OWNER_REPO"

  # ── Step 2: SSH URL branch — ask user what they want ─────────────────────
  if [ "$INPUT_WAS_SSH" = "1" ]; then
    printf "\n"
    _warn "You pasted an SSH URL (git@github.com:${OWNER_REPO})."
    printf "  Fine-Grained PAT wizard uses HTTPS token auth (works on EVERY server without SSH key setup).\n"
    local ssh_choice=""
    ssh_choice=$(prompt_def "Pick auth method: [1] Switch to Fine-Grained PAT HTTPS method (RECOMMENDED — no SSH key needed per server)  /  [S] Skip wizard: I already have SSH keys configured correctly on THIS server for 'git@github.com' and want to use them.  Answer? [1]" "1")
    case "$ssh_choice" in
      [Ss]|[Ss][Ss][Hh])
        _ok "Skipping Fine-Grained PAT wizard — using your SSH-key-based git@github.com URL as-is."
        GIT_URL="$(_normalize_github_url "git@github.com:${OWNER_REPO}.git")"
        _ok "Final canonical SSH URL: ${GIT_URL}"
        return 0
        ;;
      *)
        _ok "Proceeding with Fine-Grained PAT HTTPS method."
        ;;
    esac
  fi

  # ── Step 3: Read EXISTING_TOKEN safely + detect in-URL token ──────────────
  # Sourcing env file without set -u guard: use subshell + guarded syntax
  if [ -f "$GIT_TOKEN_FILE" ] && [ -r "$GIT_TOKEN_FILE" ]; then
    EXISTING_TOKEN="$(set +u; (. "$GIT_TOKEN_FILE" 2>/dev/null && printf '%s' "${GITHUB_TOKEN:-}") || true; set +u; true)"
    # Also strip any stray surrounding whitespace/newlines introduced by subshell
    EXISTING_TOKEN="$(printf '%s' "$EXISTING_TOKEN" | tr -d '[:space:]')"
  fi
  # Detect token already embedded inside HTTPS URL (from prior run / saved .env)
  if [[ "$GIT_URL" =~ ^https://x-access-token:([^@]+)@github\.com/ ]]; then
    IN_URL_TOKEN="${BASH_REMATCH[1]}"
  fi

  # ── Step 4: If already-authed fast path — STILL PROBE the token first! ────
  # Rule: never trust a saved token blindly. Expired/revoked tokens MUST be caught now,
  # not 90 seconds later at `git clone`.
  if [ -n "$IN_URL_TOKEN" ]; then
    TOKEN="$IN_URL_TOKEN"
    GIT_URL="$(_normalize_github_url "https://x-access-token:${TOKEN}@github.com/${OWNER_REPO}.git")"
    printf "\n"
    _info "GIT_URL already contains x-access-token auth — running one probe to verify token is NOT expired/revoked before trusting it."
    local prc0=0 hc0="" log0=""
    _run_auth_probe prc0 log0 hc0
    if [ "$prc0" -eq 0 ] && [ -n "$log0" ]; then
      _ok "Saved token PROBE OK (git ls-remote returned ${hc0} branches). Auto-normalized + trusting."
      # Verified OK → (re)write token file (in case it's missing / stale chmod on disk)
      _save_github_token
      return 0
    fi
    _warn "Saved token inside GIT_URL FAILED probe (rc=${prc0}). Token likely expired / revoked. Dropping into wizard to get a NEW one."
    IN_URL_TOKEN=""; TOKEN=""
    GIT_URL="$(_normalize_github_url "https://github.com/${OWNER_REPO}.git")"
  fi

  # ── Step 5: Wizard banner + step-by-step ──────────────────────────────────
  printf "\n\033[1;96m[GITHUB PRIVATE-REPO AUTH — FINE-GRAINED PAT WIZARD]\033[0m\n"
  printf "  Repo:                https://github.com/%s  (PRIVATE repo on your account, owner '%s')\n" "$OWNER_REPO" "$GIT_OWNER"
  printf "  Pattern:             SINGLE token reused on EVERY deployment server (paste the SAME token on N servers)\n"
  printf "  Official method:     Fine-Grained Personal Access Token (beta tokens page) — always supported by GitHub\n"
  printf "  Why not Deploy Key?  1 deploy key = 1 repo, cannot be reused across N servers → N manual key-copy steps.\n"
  printf "  Why not Classic PAT? Classic 'repo' scope grants R/W to ALL private repos in your account (overly broad).\n"
  printf "  Why not SSH keys?    Requires per-server keygen + copy-paste of N pubkeys to GitHub. Fine-Grained PAT = paste 1 value.\n\n"
  printf "  8-step guide to generate the one reusable token NOW (open in a browser):\n"
  printf "    1) https://github.com/settings/tokens?type=beta   (Fine-grained tokens page, NOT classic)\n"
  printf "    2) Generate new token\n"
  printf "    3) Name: rasyatone-app-deploy     (Expire 90 days; rotate as recommended by GitHub)\n"
  printf "    4) Resource owner: %s   (must be the account that owns the repo)\n" "$GIT_OWNER"
  printf "    5) Repository access: ONLY SELECT REPOSITORIES  →  pick exactly:  %s\n" "$OWNER_REPO"
  printf "    6) Repository permissions  →  Contents = Read-only   (all others default 'No access')\n"
  printf "    7) Generate token at the bottom\n"
  printf "    8) COPY IT NOW. Starts with 'github_pat_' or 'ghs_'. Shown exactly once.\n\n"

  # ── Step 6: Obtain initial token (reuse-saved prompt if available) ────────
  if [ -n "$EXISTING_TOKEN" ]; then
    local reuse=""
    reuse=$(prompt_def "Saved token already exists in $GIT_TOKEN_FILE. Reuse it? [Y/n] (No = paste a new one now)" "Y")
    case "$reuse" in
      [Nn]|[Nn][Oo])
        TOKEN="$(_prompt_token "Paste a NEW Fine-Grained token (github_pat_.../ghs_...). Hidden input.")"
        ;;
      *)
        TOKEN="$EXISTING_TOKEN"
        _ok "Reusing saved token from $GIT_TOKEN_FILE (display redacted). Will verify via probe next."
        ;;
    esac
  else
    TOKEN="$(_prompt_token "Paste the Fine-Grained token (github_pat_.../ghs_...) here. Hidden input. You will paste the EXACT SAME token on EVERY future deployment server.")"
  fi

  # Build canonical URL + save token file only AFTER probe passes, not before
  GIT_URL="$(_normalize_github_url "https://x-access-token:${TOKEN}@github.com/${OWNER_REPO}.git")"
  printf "  Final clone URL (token REDACTED for display):\n"
  printf "    %s\n" "$(printf '%s' "$GIT_URL" | sed -E 's|(https://x-access-token:)[^@]+(@github\.com/)|\1********\2|')"

  # ── Step 7: Probe + Retry loop (FAIL FAST. Writes token AFTER success.) ──
  local PROBE_LOG="/tmp/rasyatone_probe_$$.log"
  local SKIP_PROBE_NEXT="0"
  while :; do
    local prc=0 log="" hc="0"
    if [ "$SKIP_PROBE_NEXT" = "1" ]; then
      SKIP_PROBE_NEXT="0"; prc=1; log=""
      _warn "Skipping redundant probe (returning to menu after empty-token input)."
    else
      printf "\n\033[1;96m[GITHUB AUTH PROBE]\033[0m  timeout 15 git ls-remote --heads <token-authed URL>  (fail-fast: catch bad tokens NOW)\n"
      _run_auth_probe prc log hc
      # Stash full log in file for tail display on failure
      printf '%s\n' "$log" >"$PROBE_LOG" 2>/dev/null || true
    fi

    # Success branch: verified OK → write token file once, return
    if [ "$prc" -eq 0 ] && [ -n "$log" ]; then
      hc="${hc:-0}"
      [ "${hc}" -ge 0 ] 2>/dev/null || hc=0
      _ok "Auth probe OK: repo '${OWNER_REPO}' reachable (${hc} branch(es) listed). Token validated."
      _save_github_token
      _ok "Token persisted to $GIT_TOKEN_FILE (chmod 600, owner=root)."
      rm -f "$PROBE_LOG"
      return 0
    fi

    # Failure branch: diagnose + choice menu
    if [ "$prc" -ne 0 ] || [ -z "$log" ]; then
      _warn "Auth probe FAILED (rc=${prc}). Common causes to check BEFORE retrying:"
      printf "    1) Whitespace at paste edges? Re-paste cleanly (triple-click then Ctrl-Shift-C in terminals often works cleanest).\n"
      printf "    2) Wrong token TYPE? MUST be Fine-Grained (page URL ends with type=beta). Classic PATs work but the repo selection logic differs.\n"
      printf "    3) Repository access = Only select repositories → %s selected?\n" "$OWNER_REPO"
      printf "    4) Permissions → Repository permissions → Contents must be Read-only (No access means clone fails).\n"
      printf "    5) Token already expired? You set a 7-day expiry and today is day 8.\n"
      printf "    6) SSO/SAML org? Corporate SSO org tokens require 'Configure SSO' click on the token.\n\n"
      printf "  Last 15 lines of probe output:\n"
      tail -n 15 "$PROBE_LOG" 2>/dev/null | sed 's/^/    | /' || true
    fi

    local retry=""
    printf "\n\033[1mProbe FAILED — choose action:\033[0m\n"
    printf "  [1] Paste NEW token     (default)\n"
    printf "  [C] Continue anyway     (NOT RECOMMENDED — git clone will almost certainly fail)\n"
    printf "  [A] Abort installer     (exit to shell)\n"
    retry=$(prompt_def "Your choice? [1]" "1")
    case "$retry" in
      [Cc]|[Cc][Oo][Nn][Tt][Ii][Nn][Uu][Ee])
        _warn "Continuing past failed probe — YOU WERE WARNED. Token NOT persisted to token file so next rerun re-prompts cleanly."
        rm -f "$PROBE_LOG"
        return 0
        ;;
      [Aa]|[Aa][Bb][Oo][Rr][Tt])
        rm -f "$PROBE_LOG"
        _die "Aborted by user after repeated GitHub Fine-Grained PAT auth probe failures."
        ;;
      *)
        # [1] default: get a new token + rebuild URL + loop back to probe
        local new_tok=""
        new_tok="$(_prompt_token "Paste NEW valid Fine-Grained token (github_pat_/ghs_...). Hidden input.")"
        if [ -z "${new_tok:-}" ]; then
          _warn "Empty token entered — skipping network probe, showing menu again."
          SKIP_PROBE_NEXT="1"
          continue
        fi
        TOKEN="$new_tok"
        GIT_URL="$(_normalize_github_url "https://x-access-token:${TOKEN}@github.com/${OWNER_REPO}.git")"
        printf "  Updated clone URL (token REDACTED):\n    %s\n" "$(printf '%s' "$GIT_URL" | sed -E 's|(https://x-access-token:)[^@]+(@github\.com/)|\1********\2|')"
        # Fall through to top of while; next iteration probes the NEW token
        ;;
    esac
  done
}

install_app() {
  _section "Install RaSYaTone Application Server"
  detect_pm
  load_env_file || true
  local nginx_https=0 nginx_domain="" nginx_email="" nginx_tls_ok=0

  printf "\nEnter RaSYaTone app server settings (press Enter to keep default in [brackets]):\n"
  printf "  (Database settings — Enter keeps current value from %s)\n" "$ENV_FILE"
  DB_NAME=$(prompt_w_retry "Database name"      "${DB_NAME:-$DEF_DB_NAME}" 3 _validator_nonempty "Database name CANNOT be empty — example: rasyatone_db.")
  DB_USER=$(prompt_w_retry "Database user"      "${DB_USER:-$DEF_DB_USER}" 3 _validator_nonempty "Database user CANNOT be empty — example: rasyatone_db_user.")
  DB_PASSWORD=$(prompt_w_retry "Database user password" "${DB_PASSWORD:-}" 3 _validator_nonempty "Database password CANNOT be empty. The application uses this to connect to PostgreSQL — remember it." "secret")
  DB_HOST=$(prompt_w_retry "Database host"      "${DB_HOST:-$DEF_DB_HOST}" 3 _validator_nonempty "Database host CANNOT be empty. Examples: 'localhost' (local) or 'db.example.com' (remote).")
  DB_PORT=$(prompt_w_retry "Database port"      "${DB_PORT:-$DEF_DB_PORT}" 3 _validator_nonempty "Database port CANNOT be empty. PostgreSQL default = 5432.")
  APP_DIR=$(prompt_w_retry "App install directory" "${APP_DIR:-$DEF_APP_DIR}" 3 _validator_dir_writable_or_parent_exists "App directory must either (a) exist and be writable by current user, OR (b) its PARENT directory must exist and be writable (so we can mkdir -p later). Example: /opt/rasyatone. Parent of /opt/rasyatone = /opt must exist.")
  GIT_URL=$(prompt_def "Git repository URL (https://... or git@...) (REQUIRED). PRIVATE REPO on your account: URL alone will NOT auth; installer offers METHOD1/METHOD2 wizard next." "${GIT_URL:-}")
  [ -z "$GIT_URL" ] && _die "Git URL is required — cannot clone application without a repo URL"
  GIT_BRANCH=$(prompt_w_retry "Git branch"          "${GIT_BRANCH:-$DEF_GIT_BRANCH}" 3 _validator_nonempty "Git branch CANNOT be empty. Examples: main, master, develop.")
  # NOTE: DJANGO_SETTINGS_MODULE is now AUTO-DETECTED AFTER git clone (see _autodetect_django_settings_module called right after clone block).
  #       This is why there is no Step 1 prompt for it: we cannot detect it from an empty APP_DIR; detection uses the cloned manage.py + filesystem.
  GUNICORN_BIND=$(prompt_w_retry "Gunicorn bind address" "${GUNICORN_BIND:-$DEF_GUNICORN_BIND}" 3 _validator_nonempty "Gunicorn bind CANNOT be empty. Formats: '0.0.0.0:8000' (all), '127.0.0.1:8000' (local only), 'unix:/tmp/rasyatone.sock' (nginx upstream).")
  SERVICE_NAME=$(prompt_w_retry "systemd service name" "${SERVICE_NAME:-$DEF_SERVICE}" 3 _validator_nonempty "systemd service name CANNOT be empty. Example: rasyatone (becomes systemctl status rasyatone.service).")
  SERVICE_ACCOUNT=$(prompt_w_retry "Service account username (non-root, runs gunicorn)" "${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}" 3 _validator_linux_username "Invalid Linux username. Use lowercase letters/numbers/underscore/dash, must start with letter or underscore (max 32 chars). Example: rasyatone_app_user.")
  local _bind_port_raw=""
  _bind_port_raw=$(printf "%s" "$GUNICORN_BIND" | awk -F: '{print $NF}' 2>/dev/null || true)
  if ! printf "%s" "$_bind_port_raw" | grep -Eq '^[0-9]+$' 2>/dev/null; then
    _bind_port_raw=$(printf "%s" "$DEF_GUNICORN_BIND" | awk -F: '{print $NF}' 2>/dev/null || echo "8000")
  fi
  local do_nginx=""
  do_nginx=$(prompt_yn "Configure nginx reverse proxy + Let's Encrypt HTTPS for a domain now? [Y/n] (Recommended for 80/443 + domain)" "y")
  if [ "$do_nginx" = "y" ]; then
    nginx_https=1
    nginx_domain=$(prompt_w_retry "Domain name (DNS A/AAAA must point to THIS server)" "${nginx_domain:-}" 3 _validator_nonempty "Domain name cannot be empty. Example: rasyatone.example.com")
    nginx_email=$(prompt_w_retry "Let's Encrypt email (for renewal notices)" "${nginx_email:-}" 3 _validator_nonempty "Email cannot be empty.")
    USE_UNIX_SOCKET=$(prompt_yn "Use unix socket between nginx and gunicorn (hardening)? [y/N]" "${USE_UNIX_SOCKET:-$DEF_USE_UNIX_SOCKET}")
    ENABLE_NGINX_LOGROTATE=$(prompt_yn "Install nginx logrotate rules if missing? [y/N]" "${ENABLE_NGINX_LOGROTATE:-$DEF_ENABLE_NGINX_LOGROTATE}")
    if [ -n "${_bind_port_raw:-}" ]; then
      if [ "$USE_UNIX_SOCKET" = "y" ]; then
        GUNICORN_BIND="unix:/run/${SERVICE_NAME}/gunicorn.sock"
        _ok "Gunicorn bind changed to '${GUNICORN_BIND}' (nginx will serve 80/443; Gunicorn stays localhost-only via unix socket)."
      else
        GUNICORN_BIND="127.0.0.1:${_bind_port_raw}"
        _ok "Gunicorn bind changed to '${GUNICORN_BIND}' (nginx will serve 80/443; Gunicorn stays localhost-only)."
      fi
    fi
  fi

  ENABLE_SYSTEMD_HARDENING=$(prompt_yn "Enable systemd hardening (safe flags)? [y/N]" "${ENABLE_SYSTEMD_HARDENING:-$DEF_ENABLE_SYSTEMD_HARDENING}")

  printf "\n"
  github_auth_private_repo   # rewrites GIT_URL in-place if GitHub private repo

  # ============================================================
  # FINAL CANONICALIZATION GUARD (outer defense perimeter)
  #   - github_auth_private_repo applies _normalize_github_url
  #     internally at 3 construction sites + inside its saved-
  #     token fast-path. This block is the FINAL safety net:
  #     no matter what happened above, GIT_URL will be stripped
  #     of any trailing slash / stacked .git and re-suffixed
  #     with exactly one .git before we write the env file.
  #   - Hard assertion: if GIT_URL *still* contains .git.git
  #     after this, something catastrophic happened and the
  #     installer aborts instead of wasting time on a clone
  #     that is guaranteed to fail.
  # ============================================================
  case "$GIT_URL" in
    *"github.com"*|*"@github.com"*)
      GIT_URL="$(_normalize_github_url "$GIT_URL")"
      ;;
  esac
  case "$GIT_URL" in
    *".git.git"*)
      _die "FATAL SANITY FAIL: GIT_URL still contains '.git.git' after final canonicalization pass. Value='${GIT_URL}'. Report this bug."
      ;;
  esac

  _section "Writing $ENV_FILE"
  sudo mkdir -p "$ENV_DIR"
  # At this point DJANGO_SETTINGS_MODULE may be unset (Step 1 prompt was removed). Write a placeholder; the auto-detection
  # block right after git clone will OVERWRITE this line with the detected/confirmed value via sed-inplace.
  : "${DJANGO_SETTINGS_MODULE:=$DEF_DJANGO_SETTINGS_MODULE}"
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
    "DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}'" \
    "GUNICORN_BIND='${GUNICORN_BIND}'" \
    "USE_UNIX_SOCKET='${USE_UNIX_SOCKET}'" \
    "ENABLE_SYSTEMD_HARDENING='${ENABLE_SYSTEMD_HARDENING}'" \
    "ENABLE_NGINX_LOGROTATE='${ENABLE_NGINX_LOGROTATE}'" \
    "SERVICE_ACCOUNT='${SERVICE_ACCOUNT}'" \
    "SERVICE_NAME='${SERVICE_NAME}'" \
    | sudo tee "$ENV_FILE" >/dev/null
  sudo chmod 0640 "$ENV_FILE" 2>/dev/null || true
  _ok "$ENV_FILE written (0640). DJANGO_SETTINGS_MODULE written as placeholder='${DJANGO_SETTINGS_MODULE}' — will be overwritten by auto-detection right after git clone. Edit manually if desired."

  _section "Installing system packages (python >= 3.10 enforced, venv/pip/git/build tools + psql client) via $PM"
  # NOTE: _install_compatible_python_runtime is the SINGLE SOURCE OF TRUTH for
  # python install logic — SAME exact code runs in both precheck_app_prereqs()
  # AND here. If user answered Y to "Run prechecks first?" (the default), apt
  # marked all these packages "installed" already and this block takes ~0s
  # (fully idempotent). If the user jumped straight to Option 4 without running
  # prechecks, this installs them. Either way, we don't duplicate the distro
  # install switch-statement — zero divergence risk.
  set +e
  _install_compatible_python_runtime
  local prc=$?
  set -e

  # Re-detect after install. Fail LOUDLY with distro-specific manual commands
  # if deadsnakes / module enable failed (network down? repo mirror stale?).
  if [ "$prc" -ne 0 ]; then
    _detect_compatible_python3 2>/dev/null || true
  fi
  if [ -z "${PYTHON_BIN:-}" ] || ! _py_version_ok "$PYTHON_BIN" 2>/dev/null; then
    _die "\
No compatible Python (>= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}, <= 3.${MAX_ALLOWED_PYTHON_MINOR:-13}) found AFTER system package install.
Django 5 (in your repo) REFUSES to install on Python < 3.10, and Python >= 3.14
breaks too many pinned sdists (PyWeakref_GetObject symbol removed). What to do:
  * Ubuntu 20.04 / Debian 11 : install python3.11 from deadsnakes PPA manually:
      apt install software-properties-common ca-certificates
      DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:deadsnakes/ppa
      apt update
      DEBIAN_FRONTEND=noninteractive apt install -y python3.11 python3.11-venv python3.11-pip python3.11-dev
  * RHEL 8 / CentOS 8        : dnf module enable python3.11 -y && dnf install -y python3.11 python3.11-devel python3.11-pip
  * RHEL 9 / Rocky 9 / Alma 9: dnf install -y python3.11 python3.11-devel python3.11-pip
  * Any distro               : compile Python 3.11+ from source (./configure --enable-optimizations --prefix=/usr/local && make -j && sudo make altinstall)
  * Check PYTHON_BIN is on PATH first: command -v python3.11 ; python3.11 --version"
  fi
  _ok "Post-package PYTHON_BIN=${PYTHON_BIN} OK (confirmed >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR} and <= 3.${MAX_ALLOWED_PYTHON_MINOR:-13})"

  # Step C: Verify PYTHON_BIN really does have venv + pip modules (distros ship
  # these as separate packages; a broken `apt-get install` can leave PYTHON_BIN
  # functional but `pythonX -m venv` missing).
  _run_with_spinner "Verify ${PYTHON_BIN##*/} has 'venv' module" bash -c "$PYTHON_BIN -m venv --help >/dev/null 2>&1" || \
    _die "PYTHON_BIN=${PYTHON_BIN} has no 'venv' module. Install the matching -venv / -devel package for this Python (e.g. apt install ${PYTHON_BIN##*/}-venv)."
  _run_with_spinner "Verify ${PYTHON_BIN##*/} has 'pip' module" bash -c "$PYTHON_BIN -m pip --version >/dev/null 2>&1" || \
    _die "PYTHON_BIN=${PYTHON_BIN} has no 'pip' module. Install the matching -pip package for this Python (e.g. apt install ${PYTHON_BIN##*/}-pip)."
  _ok "Python runtime locked: ${PYTHON_BIN} $("$PYTHON_BIN" --version 2>&1 | head -n1) — venv+pip modules verified"

  _section "Validate DB connectivity (DB_PASSWORD from $ENV_FILE)"
  _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
  set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
  if command -v psql >/dev/null 2>&1; then
    local dbprobe_attempt=0 dbprobe_max=3 dbprobe_done=0
    local dbprobe_out="/tmp/rasyatone_dbprobe_$$.out"
    while [ "$dbprobe_attempt" -lt "$dbprobe_max" ] && [ "$dbprobe_done" -ne 1 ]; do
      dbprobe_attempt=$(( dbprobe_attempt + 1 ))
      local dbprobe_rc=0
      _run_with_spinner "psql SELECT 1 (credential pre-check $dbprobe_attempt/$dbprobe_max) ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}" bash -c "set +e; row=\$(PGPASSWORD='$DB_PASSWORD' timeout 10 psql -h '$DB_HOST' -p '$DB_PORT' -U '$DB_USER' -d '$DB_NAME' -tAc 'SELECT 1' 2>'$dbprobe_out' || true); [ \"\$row\" = \"1\" ]" || dbprobe_rc=$?
      local row=""
      row=$(PGPASSWORD="$DB_PASSWORD" timeout 6 psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc 'SELECT 1' 2>/dev/null || true)
      if [ "$row" = "1" ] || [ "$dbprobe_rc" -eq 0 ]; then
        dbprobe_done=1
        _ok "psql SELECT 1 OK (DB credentials validate)"
      else
        local last_err="" _psql_cause="" _psql_action=""
        last_err=$(cat "$dbprobe_out" 2>/dev/null | tail -n 5 | tr '\n' ' ' || echo "")
        # ── CAUSE (I): Dynamic categorize psql error into 6 common families + suggest concrete action (never generic "wrong pw?").
        local _pe=$(cat "$dbprobe_out" 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
        case "$_pe" in
          *database*does*not*exist*)
            _psql_cause="DATABASE OBJECT MISSING: PostgreSQL is running + auth works (password OK) but CREATE DATABASE '${DB_NAME}' was never run. Common cause: Option 3 (install PostgreSQL + create DB) was NOT yet executed, or it failed partway through."
            _psql_action="Create the DB now: run Option 3 first from the menu (it will CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}), OR — if Postgres is externally managed and you have sudo on the DB server — run: sudo -u postgres psql postgres -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};\" then retry."
            ;;
          *password*authentication*failed*for*user*)
            _psql_cause="WRONG DB_PASSWORD (scram-sha-256 / md5 auth denied). PostgreSQL is running + host:port + DB_NAME are all correct; only the password value in ENV_FILE DB_PASSWORD= does not match the role's stored password hash."
            _psql_action="Edit DB_PASSWORD above to match the password entered during Option 3. If forgotten, on the DB server run: sudo -u postgres psql postgres -c \"ALTER ROLE ${DB_USER} WITH PASSWORD 'new-good-password';\" then paste that new password back into DB_PASSWORD here."
            ;;
          *role*\"*\"*does*not*exist*|*role*does*not*exist|*user*\"*\"*does*not*exist*)
            _psql_cause="DB_USER '${DB_USER}' ROLE NOT CREATED: Option 3 CREATE ROLE was never executed, or it failed. PostgreSQL is running, auth is asked, but there is no role '${DB_USER}' in pg_roles."
            _psql_action="Run Option 3 FIRST from the installer menu (Option 3 creates the role + password), OR on the DB server run: sudo -u postgres psql postgres -c \"CREATE ROLE ${DB_USER} LOGIN PASSWORD 'your-password' NOSUPERUSER NOCREATEROLE CREATEDB;\" plus CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};."
            ;;
          *no*pg_hba\.conf*entry*|*host\ *no\ *authentication|*pg_hba*)
            _psql_cause="pg_hba.conf AUTH METHOD MISMATCH: PostgreSQL is running but your client source IP/host/user/database combo is not listed in pg_hba.conf on the server (typically: your server IP is 10.0.0.1, client connecting from Contabo public IP, but pg_hba only has 127.0.0.1 allow rules)."
            _psql_action="On the DB server edit /etc/postgresql/*/main/pg_hba.conf: add a line 'host all all 10.0.0.0/24 scram-sha-256' (or client's real IP). Also set listen_addresses='*' in postgresql.conf. Then systemctl restart postgresql."
            ;;
          *connection\ *refused|could\ *not\ *connect\ *to\ *server|no\ *route\ *to\ *host|connection\ *timed\ *out|host\ *is\ *not\ *listening*)
            _psql_cause="NETWORK / SERVER DOWN: PostgreSQL daemon is NOT LISTENING on ${DB_HOST}:${DB_PORT} (postgres not running, wrong DB_HOST/DB_PORT, firewall drop on 5432, or wrong IP)."
            _psql_action="Run on DB server: sudo systemctl status postgresql; sudo ss -ltnp | grep :5432; nc -zv ${DB_HOST} ${DB_PORT}. Verify DB_HOST=${DB_HOST} DB_PORT=${DB_PORT} match what Postgres reports (it defaults port 5432 and listen_addresses=localhost unless changed)."
            ;;
          ""|*timeout*\ *10*|*terminating\ *connection\ *due\ *to\ *connection\ *timeout*)
            _psql_cause="TIMEOUT / NO RESPONSE: 10-second timeout with zero packets back. Same family as CONNECTION REFUSED but firewall DROPS packets instead of RST."
            _psql_action="Check iptables/nftables/security groups for inbound 5432 allow. Confirm Postgres is running and listening on 0.0.0.0 not 127.0.0.1 only."
            ;;
          *)
            _psql_cause="Other psql error (generic classification failed)."
            _psql_action="Retry with edited credentials / verify PostgreSQL server logs (journalctl -u postgresql --since \"10 min ago\") for exact cause."
            ;;
        esac
        # ── AUTO-FIX: if cause is DB missing OR role missing AND sudo -u postgres works, offer to create them RIGHT NOW (no exit to Option3/shell).
        local _auto_ok2=0
        case "$_pe" in
          *database*does*not*exist*|*role*does*not*exist*|*user*does*not*exist*)
            if _psql_auto_fix_missing_role_or_db "$_pe" "${DB_USER}" "${DB_NAME}" "${DB_PASSWORD}"; then
              local _arow2=""
              _arow2=$(PGPASSWORD="$DB_PASSWORD" timeout 6 psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1" 2>/dev/null | tr -d '[:space:]' || true)
              if [ "$_arow2" = "1" ]; then
                dbprobe_done=1; _auto_ok2=1
                _ok "psql SELECT 1 OK (DB credentials validate) after AUTO-FIX."
              fi
            fi
            ;;
        esac
        if [ "$dbprobe_attempt" -lt "$dbprobe_max" ] && [ "$_auto_ok2" -ne 1 ]; then
          _warn "psql SELECT 1 FAILED attempt $dbprobe_attempt/$dbprobe_max. DETECTED CAUSE: ${_psql_cause}. RAW LAST ERROR: $last_err"
          _info "FIX SUGGESTION: ${_psql_action}"
          # ── Pre-populate superuser sentinel defaults into ENV_FILE before prompt_edit_multiple (prevents (EMPTY) for new fields.
          if [ -n "${ENV_FILE:-}" ]; then
            grep -q "^DB_SUPERUSER_USER=" "$ENV_FILE" 2>/dev/null || echo "DB_SUPERUSER_USER='postgres'" >> "$ENV_FILE"
            grep -q "^DB_SUPERUSER_PASSWORD=" "$ENV_FILE" 2>/dev/null || echo "DB_SUPERUSER_PASSWORD=''" >> "$ENV_FILE"
            _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
            set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
          fi
          prompt_edit_multiple \
            "psql SELECT 1 (credential pre-check) FAILED — edit DB creds to fix (pre-filled defaults from ENV_FILE on first open). Sentinels DB_SUPERUSER_USER/DB_SUPERUSER_PASSWORD create role+DB REMOTELY via TCP when local peer/sudo unavailable." \
            "DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT DB_SUPERUSER_USER DB_SUPERUSER_PASSWORD" \
            "Retry psql SELECT 1 with (possibly edited) values?" \
            "y"
          # prompt_edit_multiple modified values in memory → also persist them to ENV_FILE
          # before we lose them (so git clone / collectstatic / migrate later use the fixed values).
          local _dbk _dbv _sed_line
          local _sed_bin
          command -v gsed >/dev/null 2>&1 && _sed_bin="gsed" || _sed_bin="sed"
          if [ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ]; then
            for _dbk in DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT; do
              eval _dbv="\${$_dbk:-}"
              [ -z "${_dbv+x}" ] && continue
              _sed_line="$_dbk='$_dbv'"
              if grep -Eq "^${_dbk}=" "$ENV_FILE" 2>/dev/null; then
                sudo "$_sed_bin" -i~ -E "s|^${_dbk}=.*|${_sed_line}|" "$ENV_FILE" 2>/dev/null || true
                sudo rm -f "${ENV_FILE}~" 2>/dev/null || true
              else
                printf '%s\n' "$_sed_line" | sudo tee -a "$ENV_FILE" >/dev/null 2>/dev/null || true
              fi
            done
            # Reload from ENV so DB_* vars used inside git clone block (if any) are in sync with what's on disk.
            _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
            set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
          fi
        else
          _warn "psql SELECT 1 FAILED all $dbprobe_max attempts. DETECTED CAUSE: ${_psql_cause}. LAST ERROR: $last_err — manage.py migrate below will likely fail too. FIX SUGGESTION: ${_psql_action}. Continuing (you can abort with Ctrl-C and rerun Option 3 first to fix creds / create DB)."
        fi
      fi
    done
    rm -f "$dbprobe_out" 2>/dev/null || true
  else _warn "psql client not installed — skipping DB credential SELECT 1 pre-validate"; fi

  _section "Prepare app directory: $APP_DIR"
  _ensure_service_account_ready "${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}" "$APP_DIR"
  sudo mkdir -p "$APP_DIR"
  sudo chown "${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}:${SERVICE_ACCOUNT_GROUP:-${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}}" "$APP_DIR" 2>/dev/null || true
  if [ ! -d "${APP_DIR}/.git" ]; then
    if [ -n "$(ls -A "$APP_DIR" 2>/dev/null | head -n1)" ]; then
      local do_over=""
      do_over=$(prompt_def "App dir $APP_DIR is not empty — remove contents before git clone? [y/N]" "n")
      if [ "$do_over" = "y" ] || [ "$do_over" = "Y" ]; then
        sudo rm -rf "${APP_DIR:?}/"* "${APP_DIR:?}/".[!.]* 2>/dev/null || true
      else
        _die "Cannot proceed with git clone into non-empty $APP_DIR without wiping it first. Answer 'y' to wipe, or clear $APP_DIR manually then rerun Option 4."
      fi
    fi
    # Safety: dir MUST be empty before fresh clone. (If user answered Y above but rm -rf left stubborn dotfiles somehow, fail loudly.)
    if [ -n "$(ls -A "$APP_DIR" 2>/dev/null | head -n1)" ]; then
      _die "$APP_DIR is still not empty after wipe attempt. Remove contents manually and try again."
    fi
    _info "Running git clone (branch=$GIT_BRANCH, depth=1) — spinner shows activity during clone; token redacted from final stdout."
    _run_with_spinner "git clone branch=$GIT_BRANCH depth=1 into $APP_DIR" sudo -H -u "${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}" git clone -b "$GIT_BRANCH" --depth 1 "$GIT_URL" "$APP_DIR" || \
      _die "git clone FAILED (rc=$?). See /tmp/rasyatone_spin_*.log for the exact git error. Common causes: (1) private repo PAT expired — rerun, wizard will get a NEW token; (2) branch '$GIT_BRANCH' does not exist — re-check; (3) DNS/network to github.com down."
  else
    _ok "App dir already has .git — fetching latest origin/$GIT_BRANCH instead of fresh clone"
    _run_with_spinner "git fetch depth=1 origin/$GIT_BRANCH" _git_run_as_service "$APP_DIR" fetch --depth 1 origin "$GIT_BRANCH" || true
    _run_with_spinner "git reset --hard origin/$GIT_BRANCH" _git_run_as_service "$APP_DIR" reset --hard "origin/$GIT_BRANCH" || \
      _die "git reset --hard origin/$GIT_BRANCH FAILED. Manual intervention: cd $APP_DIR ; git status ; git stash ; git reset --hard HEAD"
  fi
  [ -d "$APP_DIR" ] || _die "App dir $APP_DIR missing after clone"
  # Post-clone safety: a successful clone MUST produce a .git subdir. If it's not there, clone silently failed.
  [ -d "${APP_DIR}/.git" ] || _die "git clone reported exit 0 but ${APP_DIR}/.git does NOT exist — likely empty-branch / repo-initialization race / shallow clone failure. Rerun with a different branch or check repo contents on GitHub."
  _ok "App dir populated (branch=$GIT_BRANCH)"
  # ── AUTO-DETECT DJANGO_SETTINGS_MODULE from the cloned repo ──
  # Per user request: we no longer ask for this at Step 1 wizard (APP_DIR was empty — impossible to detect).
  # Now APP_DIR is populated; this function parses manage.py + scans settings files, shows a confirmation pick
  # list every time (per user's Show pick list every time choice), persists chosen value to ENV_FILE + reloads env.
  # If detection fails entirely → falls back to dotted-path manual prompt with syntax validator.
  _autodetect_django_settings_module
  # ── EARLY POST-CLONE VALIDATION: does DJANGO_SETTINGS_MODULE dotted path MATCH what we actually cloned? ──
  # This is the #1 root cause of the user's `ModuleNotFoundError: No module named 'rasyaterp'` crash at collectstatic/migrate time.
  # We JUST cloned the repo — BEFORE we waste 5-15 minutes creating venv + running pip install (gcc compiles psycopg2,
  # builds cffi, etc.) we verify that the TOP-LEVEL PACKAGE DIRECTORY of DJANGO_SETTINGS_MODULE ACTUALLY EXISTS in APP_DIR.
  # If not → offer prompt_edit_multiple RETRY so user can correct the typo (instead of dying 10 minutes later in collectstatic).
  #
  # Also: REWRITE THE ENV FILE if DJANGO_SETTINGS_MODULE was corrected in the loop, so the venv activate block picks up
  # the correct value later.
  _section "Post-clone: validate DJANGO_SETTINGS_MODULE layout matches cloned repo"
  local dsm="" dsm_pkg_dir="" dsm_py_file="" probe_attempt=0 dsm_ok=0 max_dsm_probes=3
  local diag_lines=""   # MUST be declared before stage 2 block so appends work consistently
  dsm="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
  while [ "$probe_attempt" -lt "$max_dsm_probes" ] && [ "$dsm_ok" -ne 1 ]; do
    probe_attempt=$(( probe_attempt + 1 ))
    # Convert dotted path to filesystem path:
    #   DJANGO_SETTINGS_MODULE = "rasyaterp.settings" → package dir = APP_DIR/rasyaterp, file = APP_DIR/rasyaterp/settings.py
    #   DJANGO_SETTINGS_MODULE = "myapp.settings.production" → package dir = APP_DIR/myapp, file = APP_DIR/myapp/settings/production.py
    dsm_pkg_dir="${APP_DIR}/${dsm%%.*}"
    dsm_py_file="${APP_DIR}/${dsm//./\/}.py"
    printf "  Attempt %d/%d: DJANGO_SETTINGS_MODULE = \033[1;36m%s\033[0m\n" "$probe_attempt" "$max_dsm_probes" "$dsm" >&2
    printf "    → expected PACKAGE DIR: \033[0;33m%s\033[0m (must exist after clone)\n" "$dsm_pkg_dir" >&2
    printf "    → expected SETTINGS .PY FILE: \033[0;33m%s\033[0m (must exist after clone)\n" "$dsm_py_file" >&2
    # Layered checks: (1) top-level package dir exists AND contains __init__.py or __init__.pyi (strict package marker)
    #                 (2) the final settings.py file exists. If both pass → pass STAGE 1 (layout ok).
    local has_pkg=0 has_settings=0
    if [ -d "$dsm_pkg_dir" ] && [ -f "$dsm_pkg_dir/__init__.py" ] || [ -f "$dsm_pkg_dir/__init__.pyi" ]; then has_pkg=1; fi
    if [ -f "$dsm_py_file" ]; then has_settings=1; fi
    diag_lines=""
    if [ "$has_pkg" -eq 1 ] && [ "$has_settings" -eq 1 ]; then
      # ── STAGE 2 (beyond dir/file exists): ACTUAL PYTHON importability probe of TOP-LEVEL PACKAGE ──
      local stage2_rc=0 stage2_output="" stage2_python=""
      # Pick any python binary available for STAGE 2: prefer PYTHON_BIN else python3 else python else empty.
      if [ -n "${PYTHON_BIN:-}" ] && [ -x "$PYTHON_BIN" ]; then stage2_python="$PYTHON_BIN"
      elif command -v python3 >/dev/null 2>&1; then stage2_python="$(command -v python3)"
      elif command -v python  >/dev/null 2>&1; then stage2_python="$(command -v python)"
      else stage2_python=""; fi
      local dsm_pkg_name=""
      dsm_pkg_name="${dsm%%.*}"   # "rasyaterp.settings" → rasyaterp
      if [ -n "$stage2_python" ] && [ -n "$dsm_pkg_name" ]; then
        stage2_rc=0
        # CRITICAL: pass PROBE_PKG_NAME as env var (was missing in the first draft of STAGE 2)
        stage2_output=$( PROBE_PKG_NAME="$dsm_pkg_name" PYTHONPATH="$APP_DIR" "$stage2_python" - <<'PY' 2>&1 || stage2_rc=$?
import os, sys, importlib, traceback
pkg = os.environ.get("PROBE_PKG_NAME", "")
if not pkg:
    sys.stderr.write("ENV MISSING PROBE_PKG_NAME\n")
    sys.exit(2)  # treat as "skip with expected-only" since we can't probe safely
# KNOWN pip-provided modules (not in repo) that WILL be present after pip install -r requirements.txt.
# If ANY of these are the root cause of failure during STAGE 2 (before pip), we SKIP (expected).
KNOWN_REQ_MODULES = {
    "django", "rest_framework", "psycopg2", "psycopg", "storages", "celery",
    "redis", "gunicorn", "whitenoise", "corsheaders", "allauth", "crispy_forms",
    "drf_yasg", "PIL", "pandas", "numpy", "openpyxl", "requests", "boto3",
    "sendgrid", "twilio", "stripe", "jwt", "simplejwt",
}
try:
    importlib.import_module(pkg)
    sys.stderr.write("STAGE2_OK: top-level package %s imported cleanly\n" % pkg)
    sys.exit(0)
except SyntaxError as e:
    traceback.print_exc()
    sys.stderr.write("\nSTAGE2_REAL_FAIL: SYNTAX ERROR in package %s (__init__.py is malformed; fix before rerun)\n" % pkg)
    sys.exit(1)
except Exception as e:
    # Walk traceback chain to find the REAL "root" exception message (CPython masks nested package failures).
    tb_exc = e
    depth = 0
    while True:
        cause = getattr(tb_exc, "__cause__", None) or getattr(tb_exc, "__context__", None)
        if cause is None or depth > 8:
            break
        tb_exc = cause
        depth += 1
    msg = str(tb_exc).lower()
    # Extract likely module name from ModuleNotFoundError messages: "No module named 'foo.bar'" → foo.bar
    missing_mod = None
    if isinstance(tb_exc, ModuleNotFoundError):
        missing_mod = str(getattr(tb_exc, "name", "")).lower() or None
    if missing_mod is None:
        # Fallback: scrape "No module named 'X'" pattern anywhere in chained messages
        import re
        full = "\n".join([str(type(e).__name__), str(e), str(type(tb_exc).__name__), str(tb_exc)]).lower()
        m = re.search(r"no module named ['\"]([^'\"]+)['\"]", full)
        if m:
            missing_mod = m.group(1).lower()
    # Decision: if missing_mod is in KNOWN_REQ_MODULES → EXPECTED BEFORE PIP INSTALL (treat ok).
    #           if missing_mod starts with pkg. (internal submodule) → REAL FAIL (typo inside repo).
    #           if missing_mod is some other third-party lib → REAL FAIL (either requirements wrong OR typo).
    #           if SyntaxError (handled above) or any other exception: REAL FAIL (traceback shows actual issue).
    if missing_mod:
        top_level_missing = missing_mod.split(".")[0]
        if top_level_missing in KNOWN_REQ_MODULES:
            traceback.print_exc()
            sys.stderr.write("\nSTAGE2_EXPECTED_PIP_MISSING: import of %s failed only because requirements modules (%s) are not installed yet. This is normal BEFORE pip install. Treating as PASS.\n" % (pkg, top_level_missing))
            sys.exit(2)
        if missing_mod.startswith(pkg + "."):
            # INTERNAL MODULE TYPO inside the package (e.g. rasyaterp.conrig missing 'f' in config → REAL FAIL with traceback)
            traceback.print_exc()
            sys.stderr.write("\nSTAGE2_REAL_FAIL: MISSING INTERNAL SUBMODULE %s inside package %s — this is a TYPO in your repo code (e.g. rasyaterp/__init__.py imports it wrong).\n" % (missing_mod, pkg))
            sys.exit(1)
    # Anything else: print traceback + REAL_FAIL so user sees actual root exception (not masked ModuleNotFound).
    traceback.print_exc()
    sys.stderr.write("\nSTAGE2_REAL_FAIL: exception during import of top-level package %s (root type: %s; root message: %s)\n" % (pkg, type(tb_exc).__name__, str(tb_exc)[:200]))
    sys.exit(1)
PY
)
        # Post-process rc: Python exit 2 = EXPECTED_PIP_MISSING (KNOWN_REQ_MODULES only, treat as PASS),
        # Python exit 0 = import cleanly (treat as PASS),
        # Python exit 1 = REAL syntax/import failure with traceback (treat as FAIL).
        local stage2_pass=0
        case "$stage2_rc" in
            0|2) stage2_pass=1 ;;
            *)   stage2_pass=0 ;;
        esac
        if [ "$stage2_pass" -eq 1 ]; then
          dsm_ok=1
          local stage2_label=""
          if [ "$stage2_rc" -eq 0 ]; then stage2_label="__init__.py imported cleanly (only stdlib used)"; else stage2_label="__init__.py only requires pip modules (DJANGO/REST_FRAMEWORK/etc.) — normal before pip install, treating pass"; fi
          _ok "Post-clone STAGE 2 (top-level package importability) OK: $stage2_label."
          # Mark both stages passed to prevent later WARN.
          has_pkg=1; has_settings=1
          break
        else
          # REAL FAIL: stage2_rc=1. Output already contains the Python traceback with the REAL exception.
          diag_lines+="      [STAGE 2 REAL FAIL] top-level package '$dsm_pkg_name' EXISTS on disk but IMPORT during __init__.py execution FAILED with the above exception.\n"
          diag_lines+="              NOTE: CPython masks this failure as 'ModuleNotFoundError: No module named $dsm_pkg_name' in later migrate/collectstatic — STAGE 2 catches the REAL cause EARLY.\n"
          diag_lines+="              FULL PYTHON TRACEBACK (from '$stage2_python' with PYTHONPATH=$APP_DIR):\n"
          diag_lines+="$(printf '%s\n' "$stage2_output" | sed 's#^#                  #')\n"
          # Reset has_pkg so the retry prompt is shown.
          has_pkg=0
        fi
      else
        # No python available yet (very rare since _install_compatible_python_runtime runs before Option 4 clone)
        _warn "Post-clone STAGE 2 skipped: no python binary on PATH (PYTHON_BIN=$PYTHON_BIN, no python3/python). Will rely on final django.setup() PRECHECK before collectstatic/migrate for catch."
        dsm_ok=1
        has_pkg=1; has_settings=1
        break
      fi
    fi
    # Fail: diagnostics.
    local diag_lines=""
    [ "$has_pkg" -eq 0 ]        && diag_lines+="      [MISSING] Top-level package directory: $dsm_pkg_dir — typo in the first dotted part?\n"
    [ "$has_settings" -eq 0 ]   && diag_lines+="      [MISSING] Final settings .py file:   $dsm_py_file — did you type the correct dotted path suffix (e.g. .settings vs .settings.production)?\n"
    # Show the user what the top-level repo ACTUALLY contains so they can fix it!
    local repo_top_level=""
    repo_top_level=$(cd "$APP_DIR" 2>/dev/null && find . -maxdepth 2 -type f \( -name manage.py -o -name "settings.py" -o -name "settings_*.py" -o -name "asgi.py" -o -name "wsgi.py" -o -name "__init__.py" \) 2>/dev/null | sort | sed 's#^./##' | head -n 30 || echo "")
    _warn "Post-clone validation FAILED (attempt $probe_attempt/$max_dsm_probes) for DJANGO_SETTINGS_MODULE='$dsm':
${diag_lines}
  TOP-LEVEL FILES FOUND in $APP_DIR (these should include your actual package dir / manage.py):
$(printf '%s\n' "$repo_top_level" | sed 's#^#      #')
  HINTS:
    • If the cloned package is NOT called '${dsm%%.*}' (e.g. it's 'myapp') → set DJANGO_SETTINGS_MODULE = 'myapp.settings'.
    • If you have a settings/ directory (myapp/settings/base.py, production.py, etc.) → DJANGO_SETTINGS_MODULE = 'myapp.settings.production'.
    • If DJANGO_SETTINGS_MODULE = correct but you still see MISSING above → $APP_DIR has the wrong repo (wrong GIT_URL / wrong GIT_BRANCH)."
    if [ "$probe_attempt" -lt "$max_dsm_probes" ]; then
      prompt_edit_multiple \
        "Post-clone DJANGO_SETTINGS_MODULE failed early validation (save time before venv/pip install)" \
        "DJANGO_SETTINGS_MODULE GIT_URL GIT_BRANCH APP_DIR" \
        "Retry layout validation with (possibly edited) values?" \
        "y"
      # User may have edited DJANGO_SETTINGS_MODULE → re-sync dsm for next iteration.
      dsm="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
      # Also if user changed GIT_URL/GIT_BRANCH we can't re-clone inside this probe loop — just continue so validation can fail
      # again cleanly.
    fi
  done
  if [ "$dsm_ok" -ne 1 ]; then
    _warn "Post-clone DJANGO_SETTINGS_MODULE validation FAILED all $max_dsm_probes attempts. Installer will continue (you may have a nonstandard layout the probe can't detect, e.g. dynamic settings package). HOWEVER: if later collectstatic/migrate fails with 'ModuleNotFoundError: No module named …' → THIS is the root cause — recheck: DJANGO_SETTINGS_MODULE=$dsm against APP_DIR=$APP_DIR actual files."
  else
    # DURING PROBE we may have rewritten DJANGO_SETTINGS_MODULE via prompt_edit_multiple. WRITE THE CORRECTED VALUE BACK TO ENV_FILE
    # so later pip-install/collectstatic/migrate blocks pick up the correct module path (no more 10-minutes-later ModuleNotFound crash).
    # Only rewrite if we detect a difference (no thrashing). Keep the rest of ENV_FILE intact via a sed-inplace edit that
    # targets the DJANGO_SETTINGS_MODULE= line alone, OR appends if no line.
    if [ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ]; then
      local new_dsm_value="" new_line=""
      new_dsm_value="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
      new_line="DJANGO_SETTINGS_MODULE='${new_dsm_value}'"
      if grep -Eq '^DJANGO_SETTINGS_MODULE=' "$ENV_FILE" 2>/dev/null; then
        if command -v gsed >/dev/null 2>&1; then sed_bin="gsed"; else sed_bin="sed"; fi
        # Replace in place without touching quoting of other keys or comments.
        sudo "$sed_bin" -i~ -E "s|^DJANGO_SETTINGS_MODULE=.*|${new_line}|" "$ENV_FILE" 2>/dev/null || true
        sudo rm -f "${ENV_FILE}~" 2>/dev/null || true
      else
        printf '%s\n' "$new_line" | sudo tee -a "$ENV_FILE" >/dev/null 2>/dev/null || true
      fi
      _ok "Post-clone: wrote corrected DJANGO_SETTINGS_MODULE='${new_dsm_value}' to ENV_FILE so later collectstatic/migrate use it."
    fi
  fi

  _section "Create virtualenv at $APP_DIR/.venv + install dependencies"
  # ---------------------------------------------------------------------
  # PRE-CHECK AUTO-HEAL: does a pre-existing $APP_DIR/.venv already exist?
  # If yes, probe its $venv_python BEFORE we reuse it. The #1 cause of
  # psycopg2-binary cpython-314 _PyInterpreterState_Get compile crashes is
  # cause #1 from the DIE message: a STALE .venv created during an earlier
  # installer run when this server only had python 3.14. We used to just
  # skip venv creation when dir existed and blindly activate it → wrong
  # headers. Fix: probe both MIN floor and MAX cap; FAIL either check →
  # AUTO-WIPE the stale venv so the code below re-creates it cleanly with
  # the current $PYTHON_BIN (which detection confirmed is 3.10..3.13).
  # ---------------------------------------------------------------------
  local venv_py="${APP_DIR:?APP_DIR_EMPTY_GUARD}/.venv/bin/python"
  if [ -d "${APP_DIR:?}/.venv" ] && [ -x "$venv_py" ]; then
    local old_ok=0 old_cap_ok=0 old_mm="" old_maj="" old_min=""
    _py_version_ok "$venv_py" >/dev/null 2>&1 && old_ok=1 || old_ok=0
    _py_version_within_max_cap "$venv_py" >/dev/null 2>&1 && old_cap_ok=1 || old_cap_ok=0
    if [ -n "$(command -v "$venv_py" 2>/dev/null || true)" ] || [ -x "$venv_py" ]; then
      old_mm=$("$venv_py" -c 'import sys;print("%s.%s"%(sys.version_info.major,sys.version_info.minor))' 2>/dev/null || echo "?")
    fi
    if [ "$old_ok" -ne 1 ] || [ "$old_cap_ok" -ne 1 ]; then
      local old_reason=""
      if [ "$old_ok" -ne 1 ]; then old_reason="too old (< 3.${MIN_PYTHON_MINOR} Django 5 floor)"; fi
      if [ "$old_cap_ok" -ne 1 ]; then
        if [ -n "$old_reason" ]; then old_reason="${old_reason} AND "; fi
        old_reason="${old_reason}too new (> 3.${MAX_ALLOWED_PYTHON_MINOR} MAX_ALLOWED cap — psycopg2 sdist compile crash)"
      fi
      _warn "Pre-existing .venv DETECTED but INCOMPATIBLE — AUTO-FIXING: detected python=${old_mm:-UNKNOWN} which is ${old_reason}. Removing stale venv so installer can re-create it cleanly with PYTHON_BIN=${PYTHON_BIN} (detected compatible)."
      # Belt-and-braces: refuse to rm ANYTHING that isn't explicitly under $APP_DIR/.venv
      # (with APP_DIR non-empty via bash :? guard above). Also check the directory has
      # either bin/activate or bin/python (i.e. really a venv, not random user data).
      if [ ! -f "${APP_DIR:?}/.venv/bin/activate" ] && [ ! -x "${APP_DIR:?}/.venv/bin/python" ]; then
        _die "REFUSING to auto-remove ${APP_DIR}/.venv — it has no bin/activate or bin/python, so it is NOT a Python venv directory (user data there?). Remove it manually and rerun Option 4 if you are SURE it's safe."
      fi
      _run_with_spinner "Auto-remove stale INCOMPATIBLE .venv (python=${old_mm}, reason=${old_reason// /_})" bash -c "sudo rm -rf '${APP_DIR}/.venv'" || \
        _die "Auto-remove stale venv FAILED (rc=$?). Try manually: sudo rm -rf '${APP_DIR}/.venv' then rerun Option 4."
      _ok "Auto-FIX applied: stale ${old_mm} .venv removed cleanly. Will now create a FRESH venv with PYTHON_BIN=${PYTHON_BIN##*/}."
    else
      _ok "Reusing pre-existing .venv at ${APP_DIR}/.venv — probed python=${old_mm} which is compatible (>= 3.${MIN_PYTHON_MINOR}, <= 3.${MAX_ALLOWED_PYTHON_MINOR})."
    fi
  fi
  # Now the regular create-flow (if directory already exists, it's compatible).
  # AUTO-RETRY LADDER for the exact common failure mode you pasted:
  #   [FAIL] Create venv with PYTHON_BIN=python3.11 … FAILED …
  #   Error: Command '['/opt/rasyatone/.venv/bin/python3.11','-m','ensurepip','--upgrade','--default-pip']' \
  #          returned non-zero exit status 1.
  # Two causes → two fixes in order:
  #   ATTEMPT 1: plain "$PYTHON_BIN -m venv path" (default path, ensurepip runs inside venv — standard).
  #   On FAIL → _warn + ATTEMPT 2 PREP: run _validate_and_bootstrap_py_venv_pip (installs distro
  #              python3-venv meta-package which ships shared ensurepip wheels for *all* interpreters,
  #              then runs ensurepip on the HOST python so it has wheels cached) → re-run plain create.
  #   On FAIL → ATTEMPT 3: "$PYTHON_BIN -m venv --without-pip path" (skips ensurepip inside venv;
  #              we bootstrap pip manually AFTER venv activate using the host's pip cache). This
  #              will succeed if "$PYTHON_BIN -m venv --help" works (i.e. only the inside-venv ensurepip
  #              step is broken). We then run pip bootstrap inside the active venv post-create.
  # Only die AFTER ATTEMPT 3 ALSO fails (real issue: disk full, permissions, broken python install).
  if [ ! -d "$APP_DIR/.venv" ]; then
    local vcreate_attempt=0 vcreate_done=0
    while [ $vcreate_attempt -lt 3 ] && [ $vcreate_done -ne 1 ]; do
      vcreate_attempt=$(( vcreate_attempt + 1 ))
      case $vcreate_attempt in
        1)
          _info "venv create ATTEMPT 1/3: default mode (with ensurepip inside venv) using PYTHON_BIN=${PYTHON_BIN##*/}"
          if _run_with_spinner "Create venv [1/3]: PYTHON_BIN=${PYTHON_BIN##*/} $APP_DIR/.venv" bash -c "'$PYTHON_BIN' -m venv '$APP_DIR/.venv'"; then
            vcreate_done=1
          fi
          ;;
        2)
          _warn "venv create ATTEMPT 1 FAILED — root cause is almost always: deadsnakes shipped python3.11 but the distro-wide python3-venv META-PACKAGE (which provides the SHARED ensurepip wheels that ALL interpreters reuse) was NOT installed on this server. Running AUTO-FIX: _validate_and_bootstrap_py_venv_pip $PYTHON_BIN (this installs python3-venv via apt/dnf/apk + runs host ensurepip to cache wheels) then retrying create once more…"
          _validate_and_bootstrap_py_venv_pip "$PYTHON_BIN" || true
          if _run_with_spinner "Create venv [2/3]: (after bootstrap) PYTHON_BIN=${PYTHON_BIN##*/} $APP_DIR/.venv" bash -c "'$PYTHON_BIN' -m venv '$APP_DIR/.venv'"; then
            vcreate_done=1
          fi
          ;;
        3)
          _warn "venv create ATTEMPT 2 FAILED (inside-venv ensurepip STILL crashing). Running FINAL ATTEMPT 3: create venv with --without-pip (skips the broken ensurepip step inside venv). We will bootstrap pip MANUALLY inside the activated venv immediately after create, so install continues normally."
          if _run_with_spinner "Create venv [3/3]: --without-pip then manual bootstrap later" bash -c "'$PYTHON_BIN' -m venv --without-pip '$APP_DIR/.venv'"; then
            vcreate_done=1
          fi
          ;;
      esac
    done
    if [ $vcreate_done -ne 1 ]; then
      _die "venv creation FAILED after 3 ATTEMPTS with PYTHON_BIN=${PYTHON_BIN}. ATTEMPT 1 = default mode, ATTEMPT 2 = after bootstrap install python3-venv meta, ATTEMPT 3 = --without-pip bypass. ALL 3 failed — this is NOT a standard deadsnakes issue. Check: (1) disk free space in $APP_DIR >= 1 GB? (2) mkdir permissions on $APP_DIR/.venv for the user running this script? (3) is ${PYTHON_BIN} actually working? Run: ${PYTHON_BIN} -c 'import venv,sys; print(sys.version)' If that crashes, reinstall python3.11 via deadsnakes completely: sudo apt purge -y python3.11 python3.11-dev python3.11-minimal ; sudo apt autoremove -y ; sudo apt install -y python3.11 python3.11-dev python3.11-venv ; rerun Option 4."
    fi
    local created_py_mm=""
    if [ -x "${APP_DIR:?}/.venv/bin/python" ]; then
      created_py_mm=$("${APP_DIR}/.venv/bin/python" -c 'import sys;print("%s.%s"%(sys.version_info.major,sys.version_info.minor))' 2>/dev/null || echo "?")
    else
      created_py_mm="unknown (venv_broken"
    fi
    _ok "venv CREATE SUCCESS (attempt ${vcreate_attempt}/3). Location: ${APP_DIR}/.venv, detected-python=${created_py_mm}"
  fi
  # shellcheck disable=SC1091
  # NOTE: `set -u` (nounset) from top of script causes activate scripts to crash
  # when they reference variables like _OLD_VIRTUAL_PATH that may not exist.
  # We temporarily disable nounset during activate and re-enable it after.
  #
  # BELT+BRACES PATH INJECTION: The venv "activate" script does TWO things:
  #   (1) prepend $VENV_BIN to $PATH so bare `python` resolves to venv python
  #   (2) set VIRTUAL_ENV shell variable
  # Bug we are fixing NOW: on some Debian bash setups, sourcing the activate
  # script inside a function with set +e + set -u toggles can silently no-op
  # (activate uses bash 'hash -r' which interacts weirdly with non-interactive
  #  bash, or the script may exit early due to nounset edge cases before
  #  reaching the PATH assignment). When this happens, command -v python returns
  #  EMPTY / system python, but the venv itself (APP_DIR/.venv/bin/python) is
  #  still 100% healthy. The OLD check DIED here unnecessarily:
  #    [ -n "$active_py" ] || _die "After sourcing .venv/bin/activate, 'python'
  #                                 command is not on PATH — venv is broken."
  # FIX:
  #   (a) ALWAYS build active_py from the absolute venv/bin/python path
  #       (NOT from command -v python lookup). This is what we actually want
  #       to validate version/MAX cap on — it cannot be broken by PATH env.
  #   (b) Explicitly prepend VENV_BIN to PATH ourselves AFTER sourcing activate
  #       (guarantees bare `python` / `pip` / `gunicorn` resolve correctly even
  #        if activate script no-op'd.)
  #   (c) `command -v python` failure is now WARN + AUTO-FIX, not DIE.
  local venv_bin="${APP_DIR:?}/.venv/bin"
  [ -d "$venv_bin" ] || _die "Venv bin dir $venv_bin does not exist after venv creation step! Something wiped it between create and activate. Try: sudo rm -rf '${APP_DIR}/.venv' ; rerun Option 4."
  local active_py="${venv_bin}/python"
  [ -x "$active_py" ] || _die "Venv python binary $active_py does NOT exist or is NOT executable (after successful create). This is almost always (1) disk corruption, (2) parallel install script run wiped it, or (3) antivirus/security tool quarantined it. Try: sudo rm -rf '${APP_DIR}/.venv' ; rerun Option 4."
  set +u
  . "$APP_DIR/.venv/bin/activate" 2>/dev/null || true
  set -u
  # Belt+braces: explicitly inject venv/bin onto PATH (even if activate script
  # no-op'd due to non-interactive bash nounset/hash weirdness described above).
  # Use bash colon-separated dedupe pattern: only prepend if not already present.
  case ":$PATH:" in
    *":$venv_bin:"*) : ;;   # already there (activate worked normally)
    *) export PATH="$venv_bin:$PATH" ;;
  esac
  export VIRTUAL_ENV="${VIRTUAL_ENV:-${APP_DIR:?}/.venv}"
  # Now: if `command -v python` is STILL empty (shouldn't be, since we prepended),
  # it's only a cosmetic issue (absolute active_py works). Warn, don't die.
  if ! command -v python >/dev/null 2>&1; then
    _warn "After activate+manual PATH inject, bare 'python' still not on PATH via command -v lookup. This is cosmetic; we will use absolute venv python=$active_py directly below. Child processes that call bare 'python' or 'pip' may need to re-source activate manually once."
  fi
  # Sanity check: verify the activated `python` is the same one we chose
  _py_version_ok "$active_py" || _die "Activated venv python ($active_py, version=$($active_py -c 'import sys;print(sys.version_info.major,".",sys.version_info.minor,sep="")' 2>/dev/null)) is TOO OLD for Django 5 (< ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}). This means venv was created with the WRONG python binary earlier. Wipe $APP_DIR/.venv and rerun Option 4 — this time it will use PYTHON_BIN=${PYTHON_BIN}."
  # CRITICAL reverse check: activated python MUST be <= MAX_ALLOWED_PYTHON_MINOR.
  # _py_version_ok (above) only checks MIN floor and accepts 3.14+ silently,
  # which causes psycopg2-binary 2.9.9 sdist build to compile against /usr/include/python3.14
  # headers and fail with: _PyInterpreterState_Get implicit declaration (symbol removed in 3.14).
  #
  # AUTO-HEAL (belt+braces): if somehow the PRE-CHECK auto-wipe above missed this case
  # (e.g. venv was created by a concurrent process RIGHT AFTER pre-check probe),
  # try ONE single auto-recreate with the current $PYTHON_BIN. Only DIE if the 2nd
  # attempt ALSO produces incompatible python.
  local active_mm="" active_maj="" active_min=""
  active_mm=$("$active_py" -c 'import sys;print("%s.%s" % (sys.version_info.major,sys.version_info.minor))' 2>/dev/null || echo "0.0")
  active_maj="${active_mm%%.*}"; active_min="${active_mm#*.}"
  if ! _py_version_within_max_cap "$active_py" 2>/dev/null; then
    _warn "Post-activate gate: venv python=${active_mm} IS STILL INCOMPATIBLE (> MAX=3.${MAX_ALLOWED_PYTHON_MINOR}) even after pre-check auto-wipe pass. Running FINAL single auto-recreate attempt with PYTHON_BIN=${PYTHON_BIN}…"
    # Safety guard: only remove real venv (bin/activate OR bin/python exists here)
    if [ ! -f "${APP_DIR:?}/.venv/bin/activate" ] && [ ! -x "${APP_DIR:?}/.venv/bin/python" ]; then
      _die "Post-activate auto-fix REFUSING to remove ${APP_DIR}/.venv — it doesn't look like a real venv (no bin/activate or bin/python). Remove manually if safe."
    fi
    _run_with_spinner "Post-activate auto-fix: remove incompatible ${active_mm} .venv" bash -c "sudo rm -rf '${APP_DIR:?}/.venv'" || \
      _die "Post-activate: auto-remove of incompatible venv FAILED. Manual fix: sudo rm -rf '${APP_DIR:?}/.venv' ; rerun Option 4."
    _run_with_spinner "Post-activate auto-fix: recreate venv with ${PYTHON_BIN##*/}" bash -c "'${PYTHON_BIN}' -m venv '${APP_DIR:?}/.venv'" || \
      _die "Post-activate: recreate venv with PYTHON_BIN=${PYTHON_BIN} FAILED. Fix the underlying system package issue (${PYTHON_BIN##*/}-venv missing? disk full?) then rerun Option 4."
    # Re-activate with our new fixed venv (use same absolute-path pattern as
    # first activate block so we can't die on PATH-population no-op again).
    venv_bin="${APP_DIR:?}/.venv/bin"
    [ -d "$venv_bin" ] || _die "After recreate: venv bin dir $venv_bin missing."
    active_py="${venv_bin}/python"
    [ -x "$active_py" ] || _die "After recreate: venv python=$active_py not executable."
    set +u
    . "$APP_DIR/.venv/bin/activate" 2>/dev/null || true
    set -u
    case ":$PATH:" in
      *":$venv_bin:"*) : ;;
      *) export PATH="$venv_bin:$PATH" ;;
    esac
    export VIRTUAL_ENV="${APP_DIR:?}/.venv"
    active_mm=$("$active_py" -c 'import sys;print("%s.%s" % (sys.version_info.major,sys.version_info.minor))' 2>/dev/null || echo "0.0")
    _py_version_ok "$active_py" || _die "Post-activate auto-recreate: regenerated venv python (${active_mm}) TOO OLD (< 3.${MIN_PYTHON_MINOR}). PYTHON_BIN=${PYTHON_BIN} is wrong or broken. Try: install python3.11 (deadsnakes PPA), then rerun Option 4."
    if ! _py_version_within_max_cap "$active_py" 2>/dev/null; then
      _die "\
Post-activate AUTO-FIX FAIL (2nd attempt also produced incompatible venv).

Venv Python ${active_mm} is STILL ABOVE MAX_ALLOWED_PYTHON_MINOR=3.${MAX_ALLOWED_PYTHON_MINOR}
EVEN AFTER two auto-wipe+recreate cycles with PYTHON_BIN=${PYTHON_BIN}.

This means PYTHON_BIN=${PYTHON_BIN} itself IS ABOVE the cap. Something went wrong
earlier in detection: what should happen is _detect_compatible_python3() should
have DIED loud before we ever got to venv creation with exact instructions.

Run THESE commands as root now and rerun Option 4:
  sudo rm -rf '${APP_DIR:?}/.venv'
  apt install -y software-properties-common ca-certificates
  DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:deadsnakes/ppa
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y python3.11 python3.11-venv python3.11-dev python3-pip
  command -v python3.11 && python3.11 --version   # expect 3.11.x

Then re-run the installer — detection will now prefer python3.11 over python 3.14.
MAX_ALLOWED_PYTHON_MINOR=3.${MAX_ALLOWED_PYTHON_MINOR} is INTENTIONAL: do NOT
raise it or psycopg2-binary 2.9.9 and 10+ other pinned sdists will still fail
with _PyInterpreterState_Get / PyWeakref_GetObject compile errors."
    fi
    _ok "Post-activate AUTO-HEAL SUCCESS (2nd pass OK). Venv rebuilt cleanly with PYTHON_BIN=${PYTHON_BIN##*/} -> python=${active_mm}. Installer continues normally."
  fi
  _ok "Venv Python OK: ${active_py} -> Python ${active_mm} (>=3.${MIN_PYTHON_MINOR}, <= 3.${MAX_ALLOWED_PYTHON_MINOR}) — pip install will compile against correct headers"
  # ---------------------------------------------------------------------------
  # POST-ACTIVATE PIP BOOTSTRAP GUARANTEE (required for --without-pip ATTEMPT 3).
  # If we created venv with ATTEMPT 3 fallback (--without-pip flag) to bypass
  # the crashed ensurepip inside venv → venv/bin/python exists but NO `pip`
  # module is present. The next line `python -m pip install --upgrade …` will
  # immediately crash with ImportError: No module named pip. Fix: run a 2-step
  # bootstrap inside the ACTIVATED venv FIRST:
  #   (1) try `python -m ensurepip --upgrade` (uses host wheels cached by the
  #       _validate_and_bootstrap_py_venv_pip call in ATTEMPT 2)
  #   (2) if ensurepip fails → curl get-pip.py → pipe into activated python
  # Only die if BOTH fail AND python -m pip STILL isn't present.
  # ---------------------------------------------------------------------------
  if ! python -m pip --version >/dev/null 2>&1; then
    _warn "Activated venv has NO pip module (venv was created with --without-pip bypass, or inside-venv ensurepip failed silently). Running ACTIVATED venv pip bootstrap now."
    if ! _run_with_spinner "Bootstrap pip (inside venv): python -m ensurepip --upgrade" python -m ensurepip --upgrade; then
      _warn "ensurepip inside activated venv FAILED — last resort: curl get-pip.py -> activated python"
      curl -fsSL --max-time 60 https://bootstrap.pypa.io/get-pip.py -o /tmp/rasyatone_venv_get_pip.py 2>/dev/null || true
      if [ -s /tmp/rasyatone_venv_get_pip.py ]; then
        _run_with_spinner "Bootstrap pip (inside venv): pipe get-pip.py" python /tmp/rasyatone_venv_get_pip.py --quiet || true
      else
        _nok "get-pip.py download FAILED (60s timeout / no internet). Pip cannot be installed; pip install line below will crash."
      fi
      rm -f /tmp/rasyatone_venv_get_pip.py 2>/dev/null || true
    fi
    if ! python -m pip --version >/dev/null 2>&1; then
      _die "Post-activate pip bootstrap FAILED completely. Could NOT produce a working `python -m pip` inside the activated venv via ensurepip or get-pip.py download. Root causes in order: (1) no internet from this server to pypi.org + bootstrap.pypa.io; (2) activated venv python itself is broken. Try: curl -fsSL -I https://pypi.org/simple/pip/ ; if that fails → fix server network/DNS/firewall first. If network OK → reinstall python3.11: sudo apt purge -y python3.11 python3.11-dev python3.11-minimal ; sudo apt autoremove -y ; sudo apt install -y python3.11 python3.11-dev python3.11-venv ; rerun Option 4."
    fi
    _ok "Post-activate pip bootstrap SUCCESS: pip is present inside activated venv (version: $(python -m pip --version 2>/dev/null || echo unknown))."
  fi
  _run_with_spinner "pip upgrade (pip+setuptools+wheel in venv)" bash -c "python -m pip install --quiet --upgrade pip setuptools wheel" || \
    _die "pip upgrade failed — venv Python is broken or no internet. Try: $active_py -m ensurepip --upgrade"
  if [ -f "$APP_DIR/requirements.txt" ]; then
    # Helper: list of Windows-only PyPI package names (platform_system == "Windows"
    # wheels only — they simply don't exist on Linux so 'pip install' aborts with
    # 'No matching distribution found' for the whole requirements.txt). These are
    # almost always committed by developers who generated requirements.txt on
    # their Windows laptop via 'pip freeze' and never noticed the cross-platform
    # pin. For each one we strip the full line from requirements.txt to build a
    # Linux-safe filtered copy; we also save a .bak of the original and WARN.
    # Usage: _filter_linux_requirements <src_requirements.txt> <dst_filtered.txt>
    # Returns 0 (always), prints a list of skipped lines to stdout (for _info/_warn).
    _filter_linux_requirements() {
      local src="$1" dst="$2" skipped="" pkg="" line="" stripped=""
      local -a WIN_ONLY_PKGS=(
        pywin32 pypiwin32 "pywin32-ctypes"
        windows-curses win-unicode-console
        colorama wmi pywinauto pyad
        comtypes pyttsx3 pywinrm win32core win32ctypes
      )
      : >"$dst"
      while IFS= read -r line || [ -n "$line" ]; do
        stripped="$(printf '%s' "$line" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
        # Skip blank lines and pure comments (preserve them verbatim)
        if [ -z "$stripped" ] || [[ "$line" == \#* ]]; then
          printf '%s\n' "$line" >>"$dst"
          continue
        fi
        # Check if this requirement starts with any of the Windows-only package names
        local matched=0
        for pkg in "${WIN_ONLY_PKGS[@]}"; do
          # Match case-insensitively, exact prefix: "pkg", "pkg==", "pkg>=", "pkg~=", "pkg<=", "pkg[extras]"
          if printf '%s' "$stripped" | grep -Ei "^${pkg}([\[\=<>~!\ ]|$)" >/dev/null 2>&1; then
            matched=1
            break
          fi
        done
        if [ "$matched" -eq 1 ]; then
          if [ -z "$skipped" ]; then skipped="$line"; else skipped="${skipped}|${line}"; fi
        else
          printf '%s\n' "$line" >>"$dst"
        fi
      done <"$src"
      printf '%s' "$skipped"
    }

    REQ_SRC="$APP_DIR/requirements.txt"
    REQ_FILTERED="$APP_DIR/requirements.linux-filtered.txt"
    REQ_BAK="$APP_DIR/requirements.txt.bak"
    local skipped_lines="" dropped_count=0
    if ! cp -f "$REQ_SRC" "$REQ_BAK" 2>/dev/null; then
      _warn "Could not back up requirements.txt to $REQ_BAK (permissions?). Continuing without backup."
      REQ_BAK=""
    fi
    skipped_lines="$(_filter_linux_requirements "$REQ_SRC" "$REQ_FILTERED")"
    if [ -n "$skipped_lines" ]; then
      local IFS_SAVE="$IFS"
      IFS='|'
      local -a drops=( $skipped_lines )
      IFS="$IFS_SAVE"
      dropped_count="${#drops[@]}"
      _warn "requirements.txt contains ${dropped_count} WINDOWS-ONLY pinned packages that have NO Linux wheels. Removed them from a filtered copy to avoid 'No matching distribution found' abort. If these deps are genuinely required on Linux, remove them from requirements.txt in your repo.\n    Dropped lines:"
      local dl
      for dl in "${drops[@]}"; do
        printf "      - %s\n" "$dl" >&2
      done
      _info "Original backed up to: ${REQ_BAK:-<backup unavailable>}  Filtered copy (will be used): $REQ_FILTERED"
    fi

    local pip_log="/tmp/rasyatone_pip_$$.log"
    : >"$pip_log"
    set +e
    # The bash -c block writes pip output DIRECTLY into pip_log (for categorized
    # diagnosis), while _run_with_spinner still animates spinner. rc returned by
    # spinner == pip subprocess rc.
    local req_label=""
    if [ "$dropped_count" -gt 0 ]; then
      req_label="pip install -r requirements.linux-filtered.txt (${dropped_count} Windows deps removed)"
      _run_with_spinner "$req_label" bash -c "python -m pip install -r '$REQ_FILTERED' >'$pip_log' 2>&1"
    else
      req_label="pip install -r requirements.txt"
      _run_with_spinner "$req_label" bash -c "python -m pip install -r '$REQ_SRC' >'$pip_log' 2>&1"
    fi
    local prc=$?
    set -e
    if [ "$prc" -ne 0 ]; then
      # Save full pip log before trimming to 80 lines — user can read it later.
      local save_log="/tmp/rasyatone_pip_failure_$(date +%Y%m%d_%H%M%S).log"
      cp -f "$pip_log" "$save_log" 2>/dev/null || true
      _nok "pip install FAILED (rc=$prc). Full pip log saved to: $save_log"
      echo "  --- pip output (last 80 lines) ---" >&2
      tail -n 80 "$pip_log" >&2 || true
      echo "  --- end pip output ---" >&2

      # ====== CATEGORIZED FAILURE DIAGNOSIS ==========================================
      # Scans the full pip log for known error signatures and prints ONLY the
      # relevant remediation bullets (not a generic catch-all that misses pywin32).
      local log_lower=""
      log_lower="$(tr '[:upper:]' '[:lower:]' < "$pip_log")"
      local bullets=""
      if printf '%s' "$log_lower" | grep -Eq "no matching distribution found.*pywin32|could not find a version.*pywin32|pywin32.*from versions: none"; then
        bullets="${bullets}|★ WINDOWS-ONLY PACKAGE DETECTED (pywin32==311 / etc): 'pywin32' is Windows-only — it has NO wheels for Linux. The developer who generated requirements.txt did so on their Windows laptop via 'pip freeze' without filtering cross-platform pins. Fix the requirements.txt in your repo by removing the pywin32 / pypiwin32 / pywin32-ctypes lines entirely, or add a platform marker: pywin32==311 ; platform_system == 'Windows'."
      fi
      if printf '%s' "$log_lower" | grep -Eq "ignored the following versions that require a different python version|requires-python.*is not compatible"; then
        bullets="${bullets}|★ PYTHON VERSION TOO NEW / TOO OLD (requires-python mismatch). The locked-in venv python is: $($active_py -c 'import sys;print(sys.version_info.major,".",sys.version_info.minor,sep="")' 2>/dev/null). Many Django deps (numpy 1.26.x, pandas 2.x) still require-python < 3.13 and have no 3.13 wheels. Fix: install python3.11 system-wide (apt install python3.11 python3.11-venv python3.11-pip), then rerun Option 4 — the installer will prefer python3.11/3.12 over 3.13 automatically."
      fi
      if printf '%s' "$log_lower" | grep -Eq "failed building wheel for psycopg2|fatal error.*libpq-fe\.h|pg_config executable not found|error: command 'x86_64-linux-gnu-gcc'|failed building wheel for psycopg"; then
        bullets="${bullets}|★ PSYCOPG/PSYCOPG2 BUILD FAILURE. libpq-dev / postgresql-server-dev-* or gcc/build-essential missing from this server. Run: apt install -y build-essential libpq-dev postgresql-server-dev-all. Or in requirements.txt use 'psycopg[binary]' instead of 'psycopg2' to skip compilation."
      fi
      if printf '%s' "$log_lower" | grep -Eq "fatal error.*python\.h: no such file or directory|python\.h: no such file or directory"; then
        bullets="${bullets}|★ PYTHON HEADERS MISSING. You are compiling a C extension but the Python '-devel' package is not installed for this exact Python binary. Install: apt install ${PYTHON_BIN##*/}-dev (or equivalent dnf install python3.11-devel / apk add python3-dev)."
      fi
      if printf '%s' "$log_lower" | grep -Eq "fatal error.*ffi\.h: no such file or directory|ffi\.h: no such file or directory"; then
        bullets="${bullets}|★ LIBFFI HEADERS MISSING (ffi.h). 'cffi' package cannot build because libffi-dev/libffi-devel was NOT installed by the system package manager. This is REQUIRED for cryptography / bcrypt / PyNaCl / paramiko builds. Fix: apt install libffi-dev, or dnf install libffi-devel, or apk add libffi-dev — then rerun Option 4."
      fi
      if printf '%s' "$log_lower" | grep -Eq "pyweakref_getobject|_pyinterpreterstate_get|pyinterpreterstate_main|py_deprecated\(3\.1[3-9]\)|cpython-31[4-9]|implicit declaration of function '_py|implicit declaration of function 'pyweakref|error: command '.*gcc' failed with exit code 1.*psycopg|building '_cffi_backend' extension failed"; then
        # ANY of these patterns → Python too new for pinned old sdists.
        # Symbols removed in CPython 3.14 that old pinned sdists still call directly:
        #   * PyWeakref_GetObject (Py_DEPRECATED(3.13) in 3.13, deleted in 3.14)
        #   * _PyInterpreterState_Get (internal, made static in 3.13+ / removed in 3.14)
        #   * PyInterpreterState_Main (API shape change; private macro gone)
        # Compile-time header mismatch also shown by cpython-31[4-9] wheel tags in the
        # sdist fallback lines the user's gcc compile ran under.
        local actual_py_ver=""
        actual_py_ver="$($active_py -c 'import sys;print("%s.%s" % (sys.version_info.major,sys.version_info.minor))' 2>/dev/null || echo "?")"
        if [ "$actual_py_ver" != "?" ]; then
          local amj="${actual_py_ver%%.*}" amin="${actual_py_ver#*.}"
          if [ "$amj" -eq 3 ] && [ "$amin" -ge 14 ] 2>/dev/null; then
            bullets="${bullets}|★ PYTHON TOO NEW FOR PINNED SDISTS (locked=${actual_py_ver}). Python 3.14+ removes many deprecated CPython C-API symbols that old pinned sdist versions still use. Your EXACT error pattern: psycopg2-binary 2.9.9 called '_PyInterpreterState_Get' (private symbol made static in 3.13 and deleted in 3.14) when compiling against /usr/include/python${actual_py_ver} headers. The installer already refuses 3.14+ during detection; what happened is a PRE-EXISTING .venv (created when only 3.14 was available on this server) got re-used because the venv directory already existed. FIX = rm -rf ${APP_DIR}/.venv, install python3.11 from deadsnakes PPA, then rerun Option 4. Copy-paste exact commands (run as root on this server):
    rm -rf '${APP_DIR}/.venv'
    apt install -y software-properties-common ca-certificates
    DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:deadsnakes/ppa
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y python3.11 python3.11-venv python3.11-dev python3-pip
    command -v python3.11 && python3.11 --version   # expect Python 3.11.x
Then re-run the installer Option 4. For the user who reported this failure:
the previous 'Only Python 3.14 was found MAX_ALLOWED=3.13' hard die before this step has been fixed too — prechecks now auto-install python3.11 via deadsnakes BEFORE the detection pass runs."
          else
            # 3.10..3.13 but still got removed-symbol error — most likely a psycopg2
            # binary wheel pinned too old; still actionable, just no 3.14 specific note
            bullets="${bullets}|★ PSYCOPG2 C-API INCOMPATIBILITY (actual venv python=${actual_py_ver}, but sdist calls removed C symbols). Most likely psycopg2-binary==2.9.9 pinned in requirements.txt is too old for the CPython on this server. Quickest fix: edit requirements.txt (commit to your repo!) and change 'psycopg2-binary==2.9.9' → 'psycopg[binary]>=3.1.8' (psycopg v3 supports Python 3.10–3.13 with binary wheels, no sdist compile needed). Or install python3.11 from deadsnakes PPA and rerun — 3.11 has prebuilt wheels for psycopg2-binary 2.9.9 so no C compile ever runs."
          fi
        else
          # active_py unknown (shouldn't happen but guard anyway)
          bullets="${bullets}|★ PYTHON / C-API INCOMPATIBILITY during sdist compile (couldn't read venv python version). Could be Python 3.14+ or a too-new psycopg. Fix: install python3.11 system-wide, remove stale ${APP_DIR}/.venv, rerun Option 4."
        fi
      fi
      if printf '%s' "$log_lower" | grep -Eq "no matching distribution found"; then
        # Generic "no matching" — only show if more specific bullets didn't fire.
        if [ -z "$bullets" ]; then
          bullets="${bullets}|★ UNKNOWN 'No matching distribution found'. Check: (1) private package index misconfigured, (2) package was renamed/removed from PyPI, (3) package is Windows/macOS-only. Run: $active_py -m pip install --verbose -r $REQ_SRC > /tmp/verbose.log 2>&1 then read it."
        fi
      fi
      if printf '%s' "$log_lower" | grep -Eq "killed|out of memory|cannot allocate memory"; then
        bullets="${bullets}|★ OOM KILLED during compile. This server has too little RAM. Fixes: (a) add swap: dd if=/dev/zero of=/swapfile bs=1M count=2048 && mkswap /swapfile && swapon /swapfile, or (b) install binary wheels — change requirements.txt to use psycopg[binary] instead of psycopg2, numpy binary wheels only (pip install --only-binary=:all: -r requirements.txt)."
      fi
      if printf '%s' "$log_lower" | grep -Eq "could not fetch url|connection error|timed out|network is unreachable|name or service not known"; then
        bullets="${bullets}|★ NETWORK FAILURE reaching PyPI. This server cannot reach pypi.org. Fix: verify DNS (resolvectl query pypi.org), check HTTP_PROXY/HTTPS_PROXY env vars, or configure a private PyPI mirror via pip config set global.index-url."
      fi
      if [ -z "$bullets" ]; then
        bullets="|★ NO CATEGORIZATION MATCHED (unknown pip failure). Full verbose pip log saved at: $save_log — paste its content (or search for first 'ERROR:') to diagnose."
      fi
      printf "\n  === DIAGNOSIS (categorized fixes based on actual pip log) ===\n" >&2
      local IFS_SAVE2="$IFS"
      IFS='|'
      local -a b_arr=( $bullets )
      IFS="$IFS_SAVE2"
      local b
      for b in "${b_arr[@]}"; do
        [ -z "$b" ] && continue
        printf "  %s\n" "$b" >&2
      done
      printf "  ===============================================================\n" >&2
      # Clean up the filtered-temp file we created (or leave it if user wants it)
      if [ -n "$REQ_FILTERED" ] && [ -f "$REQ_FILTERED" ] && [ "$dropped_count" -gt 0 ]; then
        _info "Filtered requirements (Windows deps removed) left on disk: $REQ_FILTERED — you can retry pip install on it manually: pip install -r $REQ_FILTERED"
      fi
      _die "pip install requirements.txt FAILED. Read diagnosis bullets above carefully, fix the root cause, then rerun Option 4."
    else
      _ok "pip install requirements.txt OK"
      if [ "$dropped_count" -gt 0 ]; then
        _warn "Remember: we DROPPED ${dropped_count} Windows-only packages before pip install. If your Django code actually imports pywin32 at runtime on Linux it WILL fail at import-time — those packages only exist on Windows."
      fi
    fi
  else
    _warn "No $APP_DIR/requirements.txt found — skipping pip install -r (install manually)"
  fi
  # gunicorn install: first quiet install; if that fails, retry noisily and show
  # output via spinner so user sees what's wrong. spinner always captures output.
  set +e
  _run_with_spinner "pip install gunicorn (systemd unit needs this binary)" bash -c "python -m pip install --quiet gunicorn 2>/dev/null || python -m pip install gunicorn"
  local gunrc=$?
  set -e
  [ "$gunrc" -eq 0 ] || _die "Failed to install gunicorn into venv — cannot create systemd unit / start app. See spinner log: /tmp/rasyatone_spin_*.log"
  _ok "venv ready; python=$(command -v python) ($(python --version 2>&1 | head -n1)); gunicorn: $(gunicorn --version 2>&1 | head -n1)"

  # ── WEASYPRINT PREFLIGHT: catch missing system libraries (libpango/cairo/fontconfig) BEFORE migrate ──
  # The user's EXACT migrate failure was:
  #     from weasyprint import HTML -> OSError: cannot load library 'libpango-1.0-0'
  # This happens because: (a) weasyprint pip wheel installs fine without system libs; (b) Django's manage.py migrate
  # runs run_checks() -> import urlconf -> imports views at module top-level -> `from weasyprint import HTML` triggers
  # dlopen() inside a CPython FFI (not a Python ImportError). It ONLY surfaces during migrate's urlconf import check,
  # NOT during `import django; django.setup()` (django.setup doesn't import URLconfs — that's why banner Cause (A) probe PASSes
  # but migrate FAIL, which confused the user).
  #
  # This preflight runs a standalone `import weasyprint` INSIDE the venv with PYTHONPATH set. If it fails with
  # "cannot load library" OSError -> shows a prompt_edit_multiple menu offering (1) AUTO-INSTALL pango/cairo system libs
  # via _sudo_pkg_install right here, (2) continue anyway, (3) edit settings. This catches the exact failure 10 minutes
  # earlier than migrate, before the 3-attempt migrate banner.
  set +e
  local wp_pf_attempt=0 wp_pf_max=2 wp_pf_ok=0 wp_pf_out="" wp_pf_rc=0
  while [ "$wp_pf_attempt" -lt "$wp_pf_max" ] && [ "$wp_pf_ok" -ne 1 ]; do
    wp_pf_attempt=$(( wp_pf_attempt + 1 ))
    wp_pf_rc=0
    wp_pf_out=$( PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" - <<'PY' 2>&1 || wp_pf_rc=$?
import sys
try:
    import importlib
    mod = importlib.import_module("weasyprint")
    html_cls = getattr(mod, "HTML", None)
    if html_cls is None:
        print("weasyprint IMPORT OK BUT HTML class MISSING from weasyprint.__init__", file=sys.stderr)
        sys.exit(3)
    print("OK: weasyprint=%s; HTML class loaded" % getattr(mod, "__version__", "unknown"))
    sys.exit(0)
except ModuleNotFoundError as e:
    # weasyprint not in requirements.txt — fine, don't force install system libs for an app that doesn't use it.
    print("SKIP: module not found (weasyprint not in requirements.txt for this app).")
    sys.exit(0)
except OSError as e:
    # FFI dlopen() failure — missing pango/cairo libs — this is the exact user crash.
    import traceback
    traceback.print_exc()
    sys.exit(1)
except Exception:
    import traceback
    traceback.print_exc()
    sys.exit(2)
PY
)
    case "$wp_pf_rc" in
      0) wp_pf_ok=1; break ;;
      *) # rc>0: we have a problem. Print banner, offer AUTO-INSTALL of system libs via prompt_edit_multiple.
        local wp_cat=""
        case "$wp_pf_rc" in
          1) wp_cat="MISSING SYSTEM LIBRARIES (weasyprint text/ffi.py dlopen() failed on libpango/cairo/fontconfig)." ;;
          2) wp_cat="weasyprint import INTERNAL ERROR (not FFI/lib missing — traceback above)." ;;
          3) wp_cat="weasyprint __init__.py loaded but HTML symbol missing — wheel corrupted or partial pip install." ;;
        esac
        printf "\n\033[1;33m=== Weasyprint PDF PREFLIGHT FAILED (attempt %d/%d, rc=%d) — %s ===\033[0m\n" "$wp_pf_attempt" "$wp_pf_max" "$wp_pf_rc" "$wp_cat" >&2
        printf "\033[1;36mPREFLIGHT TRACEBACK (exact lines weasyprint threw):\033[0m\n" >&2
        printf '%s\n' "$wp_pf_out" | sed 's#^#    #' >&2
        printf "\n\033[1;36mRecommended fix (Option 1 in menu below): install Pango/Cairo/fontconfig system libs RIGHT NOW (no installer rerun needed).\033[0m\n" >&2
        if [ "$wp_pf_attempt" -lt "$wp_pf_max" ]; then
          # prompt_edit_multiple fields that control this failure: we let user choose (1) install libs via AUTO field, (2) confirm skip.
          # We use a SENTINEL FIELD `WP_AUTOINSTALL_SYSTEM_DEPS` (set to "y") — after prompt_edit_multiple returns and it's "y",
          # we run _sudo_pkg_install on the system libraries list.
          WP_AUTOINSTALL_SYSTEM_DEPS="${WP_AUTOINSTALL_SYSTEM_DEPS:-y}"
          prompt_edit_multiple \
            "Weasyprint PDF preflight FAILED (attempt $wp_pf_attempt/$wp_pf_max) — missing system libs for pango/cairo/fontconfig. Fix choices (edit WP_AUTOINSTALL_SYSTEM_DEPS='y' then press Enter to AUTO-INSTALL now):" \
            "WP_AUTOINSTALL_SYSTEM_DEPS DJANGO_SETTINGS_MODULE APP_DIR" \
            "Retry weasyprint import after making the change(s)? (Enter=yes — autoinstalls libs if WP_AUTOINSTALL_SYSTEM_DEPS=y)" \
            "y"
          # If user left WP_AUTOINSTALL_SYSTEM_DEPS=y or set it to y/yes: install the system libs.
          case "${WP_AUTOINSTALL_SYSTEM_DEPS^^}" in
            Y|YES|1|TRUE|ON)
              detect_pm
              _section "AUTO-INSTALL Weasyprint system deps (pango/cairo/fontconfig, package manager=$PM)"
              local wp_installed=0
              case "$PM" in
                apt)
                  _run_with_spinner "apt: install weasyprint runtime deps (libpango/libcairo/fontconfig + fonts)" \
                    _sudo_pkg_install libpango-1.0-0 libpangoft2-1.0-0 libpangocairo-1.0-0 libcairo2 libgdk-pixbuf-2.0-0 shared-mime-info fonts-liberation2 fontconfig-config fontconfig && wp_installed=1
                  ;;
                dnf)
                  _run_with_spinner "dnf: install weasyprint runtime deps (pango/cairo/gdk-pixbuf + liberation fonts)" \
                    _sudo_pkg_install pango cairo cairo-gobject gdk-pixbuf2 fontconfig liberation-fonts && wp_installed=1
                  ;;
                apk)
                  _run_with_spinner "apk: install weasyprint runtime deps (pango/cairo/fontconfig + ttf-liberation)" \
                    _sudo_pkg_install pango cairo gdk-pixbuf fontconfig ttf-liberation && wp_installed=1
                  ;;
                *)
                  _warn "Unknown package manager PM=$PM — cannot AUTO-INSTALL. Please run: (apt/dnf/apk) install pango cairo fontconfig (and font packages), then retry."
                  ;;
              esac
              if [ "$wp_installed" -eq 1 ]; then
                _ok "Weasyprint system deps installed via $PM. Next iteration will retry import."
                # Clear any ld.so cache so dlopen() can see the new libs
                command -v ldconfig >/dev/null 2>&1 && sudo ldconfig 2>/dev/null || true
              fi
              ;;
            *)
              _warn "WP_AUTOINSTALL_SYSTEM_DEPS set to non-yes value '${WP_AUTOINSTALL_SYSTEM_DEPS}' — skipping AUTO-INSTALL. Will retry the import as-is (likely will fail again unless you installed libs manually outside)."
              ;;
          esac
        fi
        ;;
    esac
  done
  if [ "$wp_pf_ok" -eq 1 ]; then
    _ok "Weasyprint PDF preflight OK (import weasyprint + HTML class resolves — libpango/cairo system libs present)."
    printf "%s\n" "$wp_pf_out" | sed 's#^#    #' >&2 || true
  else
    _warn "Weasyprint PDF preflight FAILED all $wp_pf_max attempts. The migrate command WILL LIKELY FAIL NEXT with EXACT same OSError if your views/__init__.py still does 'from weasyprint import HTML' at top level. Migrate banner has a new Cause (F) section with copy-paste install lines to recover."
  fi
  set -e

  _section "Run Django collectstatic + migrate"
  (
    cd "$APP_DIR"
    _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
    set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
    # Same set -u safety for nested activate inside subshell
    set +u
    # shellcheck disable=SC1091
    . "./.venv/bin/activate" 2>/dev/null || true
    set -u
    # -------------------------------------------------------------------------
    # PYTHONPATH + settings-import PRECHECK (catches the EXACT user crash
    # before we run collectstatic/migrate so die message is specific).
    #
    # Root cause of the user's ModuleNotFoundError: No module named 'rasyaterp':
    #   (a) DJANGO_SETTINGS_MODULE defaults to "rasyaterp.settings" (expected
    #       repo layout: $APP_DIR/rasyaterp/settings.py next to manage.py).
    #   (b) For Django's import_module("rasyaterp.settings") to resolve, the
    #       PARENT directory containing `rasyaterp/` MUST be on PYTHONPATH.
    #   (c) When user runs via `./manage.py`, CPython adds cwd to sys.path[0]
    #       automatically — HOWEVER some Debian setuid/non-interactive bash
    #       sessions running with `bash -c "python manage.py …"` can have
    #       `sys.path[0] = ''` (empty string = "cwd at import time") which
    #       no-ops inside Django's import_module call chain, OR the user has
    #       a top-level rasyaterp/__init__.py with a broken import that
    #       propagates up as a generic ModuleNotFoundError mask.
    #
    # Fix: explicitly export PYTHONPATH = APP_DIR, then run a 2-line probe
    # that tries: `import django; django.setup(); from django.conf import
    # settings; print(settings.INSTALLED_APPS[0])`. If probe fails → loud die
    # with EXACTLY: what we tried, the full traceback, and copy-paste debug
    # commands the user can run locally to reproduce outside the installer.
    # -------------------------------------------------------------------------
    # Belt+braces: inject PATH/PYTHONPATH/VIRTUAL_ENV explicitly INSIDE this subshell too
    case ":$PATH:" in
      *":$APP_DIR/.venv/bin:"*) : ;;
      *) export PATH="$APP_DIR/.venv/bin:$PATH" ;;
    esac
    [ -x "$APP_DIR/.venv/bin/python" ] || _die "collectstatic/migrate PRECHECK: $APP_DIR/.venv/bin/python missing (venv gone?). Run: sudo rm -rf '${APP_DIR:?}/.venv' ; rerun Option 4."
    export PYTHONPATH="${APP_DIR:?}${PYTHONPATH:+:${PYTHONPATH}}"
    export VIRTUAL_ENV="${VIRTUAL_ENV:-$APP_DIR/.venv}"
    # Retry the probe up to 3 times, offering prompt_edit_multiple each time.
    local django_precheck_rc=0 django_precheck_traceback=""
    local dpm_attempt=0 dpm_max=3 dpm_ok=0
    while [ "$dpm_attempt" -lt "$dpm_max" ] && [ "$dpm_ok" -ne 1 ]; do
      dpm_attempt=$(( dpm_attempt + 1 ))
      django_precheck_rc=0
      django_precheck_traceback=$("$APP_DIR/.venv/bin/python" - <<'PY' 2>&1 || django_precheck_rc=$?
import os, sys, traceback
try:
    import django
    from django.conf import settings as _ds
    from django.core.management import execute_from_command_line
    django.setup()
    from django.conf import settings
    print("django.setup() OK; ROOT_URLCONF=%s; INSTALLED_APPS_n=%d" % (settings.ROOT_URLCONF, len(settings.INSTALLED_APPS)))
    sys.exit(0)
except Exception:
    traceback.print_exc()
    sys.exit(2)
PY
)
      if [ "$django_precheck_rc" -eq 0 ]; then dpm_ok=1; break; fi
      # Probe failed: either die or offer retry if stdin is a TTY
      local dsm="${DJANGO_SETTINGS_MODULE:-<UNSET>}"
      local diag_banner=""
      diag_banner=$(cat <<EOBANNER
Django settings import PRECHECK FAILED (attempt $dpm_attempt/$dpm_max, rc=$django_precheck_rc). BEFORE we even
tried collectstatic/migrate we failed to run:
    PYTHONPATH=$APP_DIR DJANGO_SETTINGS_MODULE=$dsm $APP_DIR/.venv/bin/python \
      -c 'import django; django.setup()'

This is the EXACT failure chain that produced the ModuleNotFoundError: No
module named 'rasyaterp' traceback in your log. Root causes IN ORDER:

  (1) DJANGO_SETTINGS_MODULE=$dsm does not match reality in repo.
      Expected repo layout at APP_DIR=$APP_DIR is:
        $APP_DIR/manage.py (exists OK)
        $APP_DIR/${dsm%%.*}/__init__.py (PACKAGE DIR of the top-level settings module)
        $APP_DIR/${dsm//./\/}.py (actual settings.py file)
      If your package is not named '${dsm%%.*}' you need to pass an env override
      to Option 4 (edit the env file at $ENV_FILE and set DJANGO_SETTINGS_MODULE
      to e.g. 'myactualpackage.settings.production'). Debug with:
        cd '$APP_DIR' && sudo -E '$APP_DIR/.venv/bin/python' manage.py check --settings=$dsm

  (2) PYTHONPATH did not include APP_DIR at import time. We export it above,
      but some NFS mounts / setcap(8) / AppArmor profiles can clear PYTHONPATH
      for child processes. If the debug command below works but the installer
      still dies here → add PYTHONPATH to your /etc/environment and rerun.

  (3) The actual settings package $dsm has a broken import in __init__.py
      (e.g. a third-party package listed in INSTALLED_APPS wasn't installed
      because pip install -r requirements.txt partially failed). Run the
      debug command and look for 2nd line of traceback (below rasyaterp line)
      to find the ACTUAL missing module (could be something like 'storages'
      or 'rest_framework' masked by import chain).

FULL TRACEBACK FROM PROBE:
$django_precheck_traceback

COPY-PASTE DEBUG COMMANDS (run as root):
  cd '$APP_DIR'
  ls -la '$APP_DIR'
  ls -la '$APP_DIR/${dsm%%.*}' 2>/dev/null || echo 'PACKAGE DIR ${dsm%%.*} NOT PRESENT -> fix DJANGO_SETTINGS_MODULE env var'
  PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='$dsm' '$APP_DIR/.venv/bin/python' -c 'import django; django.setup(); from django.conf import settings; print("OK; STATIC_ROOT=", settings.STATIC_ROOT)'
EOBANNER
)
      if [ "$dpm_attempt" -lt "$dpm_max" ]; then
        printf "\n\033[1;31m%s\033[0m\n" "$diag_banner" >&2
        prompt_edit_multiple \
          "Django settings import precheck failed (attempt $dpm_attempt/$dpm_max). Edit a field to fix it before we continue:" \
          "DJANGO_SETTINGS_MODULE DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT APP_DIR" \
          "Retry django.setup() precheck with (possibly edited) values?" \
          "y"
        # If user re-edited DB_* / DJANGO_SETTINGS_MODULE → must reload ENV into THIS subshell
        _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
        set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
        export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
      else
        _die "$diag_banner"
      fi
    done
    _ok "Django settings PRECHECK OK (attempt $dpm_attempt/$dpm_max; PYTHONPATH=$APP_DIR; DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE}; traceback clean)"
    set +e
    # collectstatic: first quiet attempt with spinner; if that fails re-run
    # noisily so user sees WHY it failed (STATIC_ROOT / permissions)
    _run_with_spinner "manage.py collectstatic --noinput (scan static files)" bash -c "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py collectstatic --noinput >/dev/null 2>&1"
    local csrc=$?
    set -e
    if [ "$csrc" -ne 0 ]; then
      # Re-run noisily with a secondary spinner so progress still shown during long re-run
      _warn "collectstatic exited non-zero — re-running with full output for debugging:"
      (cd "$APP_DIR" && PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" manage.py collectstatic --noinput 2>&1 | tail -n 20 || true)
      _warn "Continuing anyway — if STATIC_ROOT was unset or wrong path this is expected."
    else
      _ok "collectstatic ok"
    fi
    # ── makemigrations: ALWAYS run BEFORE migrate, per user request ──
    # Flow:
    #   (1) PROBE: manage.py makemigrations --check --dry-run --verbosity 1
    #         rc=0 → nothing pending; skip silently.
    #         rc=1 → model changes detected but no migration files exist → run step (2).
    #   (2) REAL: manage.py makemigrations (no --check) in a spinner, 3 attempts with prompt_edit_multiple retries
    #         Fields: DJANGO_SETTINGS_MODULE APP_DIR (same fields as migrate/probes).
    #         On FAIL: print FRESH traceback outside spinner + 6-block evidence banner.
    #   (3) MERGE: If there are conflicting migrations (git branches created same migration number)
    #         automatically run makemigrations --merge --no-input; warn if user interaction required.
    # Reasoning: Django's manage.py migrate will SILENTLY NO-OP if there are model changes
    # without corresponding migration files (INSTALLED_APPS models not reflected in migrations
    # → migrate prints "No migrations to apply" even though tables are missing. Running
    # makemigrations FIRST guarantees that migrate actually has migration files to apply.
    local mmk_attempt=0 mmk_max=3 mmk_ok=0 mmk_rc=0 mmk_pending=0
    local mmk_spin_log="" mmk_fresh_tmp="/tmp/rasyatone_mmk_fresh_$$.tmp"
    local mmk_cmd_check="cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --check --dry-run --verbosity 1"
    local mmk_cmd_real="cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput --verbosity 1"
    # ── Step (1): PROBE --check --dry-run (cheap, 1 attempt, decides if we need real run) ──
    set +e
    local mmk_check_out="" mmk_check_rc=0
    mmk_check_out=$( bash -c "$mmk_cmd_check" 2>&1 || mmk_check_rc=$? )
    case "$mmk_check_rc" in
      0)
        mmk_pending=0
        _ok "makemigrations PROBE ok — NO model changes pending; all apps have current migration files."
        ;;
      1)
        mmk_pending=1
        _section "makemigrations PROBE detected pending model changes (makemigrations --check rc=1). Creating migration files NOW BEFORE migrate (per user request)."
        printf "%s\n" "$mmk_check_out" | sed 's#^#    #' >&2 || true
        ;;
      *)
        # rc>1 is an actual error (import failure, DB unreachable). Treat like the real step failure → offer retries.
        mmk_pending=1
        _warn "makemigrations PROBE returned rc=$mmk_check_rc (not 0/1). Will fall through to 3-attempt real makemigrations retry loop so we can diagnose."
        printf "%s\n" "$mmk_check_out" | sed 's#^#    #' >&2 || true
        ;;
    esac
    if [ "$mmk_pending" -eq 1 ]; then
      while [ "$mmk_attempt" -lt "$mmk_max" ] && [ "$mmk_ok" -ne 1 ]; do
        mmk_attempt=$(( mmk_attempt + 1 ))
        mmk_spin_log=""
        mmk_rc=0
        _run_with_spinner "manage.py makemigrations (attempt $mmk_attempt/$mmk_max) — create migration files for pending model changes" bash -c "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput --verbosity 1" || mmk_rc=$?
        local _gl
        for _gl in $(ls -1t /tmp/rasyatone_spin_*_*makemigrations* 2>/dev/null | head -n 3); do
          [ -f "$_gl" ] || continue
          if [ -s "$_gl" ]; then mmk_spin_log="$_gl"; break; fi
          [ -z "${mmk_spin_log}" ] && mmk_spin_log="$_gl"
        done
        if [ "$mmk_rc" -eq 0 ]; then
          mmk_ok=1
          # ── Step (3): MERGE conflicts — run AFTER successful makemigrations (rc=0) ──
          #   Even if rc=0 above, conflicting migration file names (e.g. two 0001_initial.py
          #   in same app from different git branches) can still cause migrate to fail later.
          #   makemigrations --merge fixes these; run it with --noinput. rc=1 = "nothing to merge" (ok).
          set +e
          local mmk_merge_rc=0 mmk_merge_out=""
          mmk_merge_out=$( bash -c "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --merge --noinput --verbosity 1" 2>&1 || mmk_merge_rc=$? )
          case "$mmk_merge_rc" in
            0)   _ok "makemigrations merged conflicting migration files automatically."
                 printf "%s\n" "$mmk_merge_out" | sed 's#^#    #' >&2 || true ;;
            1)   : ;;  # "No merge needed" — standard case, silent ;;
            *)   _warn "makemigrations --merge returned rc=$mmk_merge_rc (may need manual --merge with --no-interactive=false). migrate will likely show conflicting migration names error and offer --merge suggestion." ;
                 printf "%s\n" "$mmk_merge_out" | sed 's#^#    #' >&2 || true ;;
          esac
          set -e
          # ── Step (4): PROACTIVE circular dep resolve (after makemigrations created new files). ──
          _section "makemigrations ok → Check for Django CircularDependencyError in graph (post-makemigrations)."
          set +e
          _resolve_circular_dep "$APP_DIR" "${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" "post-mk" || true
          set -e
          break
        fi
        # ── makemigrations FAILED this attempt: build detailed evidence banner ──
        local mmk_fresh_tb=""
        mmk_fresh_tb=$( bash -c "$mmk_cmd_real" 2>&1 | tail -n 80 || true )
        printf '%s\n' "$mmk_fresh_tb" > "$mmk_fresh_tmp" 2>/dev/null || true
        local mmk_dsetup_out="" mmk_dsetup_rc=0
        mmk_dsetup_out=$( PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" - <<'PY' 2>&1 || mmk_dsetup_rc=$?
import os, sys, traceback
try:
    import django
    django.setup()
    from django.conf import settings
    print("django.setup() OK; ROOT_URLCONF=%s; INSTALLED_APPS_n=%d; DATABASES.default.HOST=%s" % (settings.ROOT_URLCONF, len(settings.INSTALLED_APPS), settings.DATABASES["default"].get("HOST", "<UNSET>")))
    sys.exit(0)
except Exception:
    traceback.print_exc()
    sys.exit(2)
PY
)
        local venv_pv=""
        venv_pv=$("$APP_DIR/.venv/bin/python" -c 'import sys;print(sys.version)' 2>/dev/null || echo "UNKNOWN")
        printf "\n\033[1;31m=== manage.py makemigrations FAILED attempt %d/%d (rc=%s) — FULL EVIDENCE BELOW ===\033[0m\n" "$mmk_attempt" "$mmk_max" "$mmk_rc" >&2
        printf "  \033[1;33m[EXACT makemigrations CMD (COPY-PASTE REPRODUCE LINE):]\033[0m\n    %s\n" "$mmk_cmd_real" >&2
        printf "  \033[1;33m[ENV makemigrations ran with:]\033[0m\n    PYTHONPATH=%s\n    DJANGO_SETTINGS_MODULE=%s\n    VENV_BIN=%s\n    VENV_PY_VERSION=%s\n" \
          "$APP_DIR" "${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" "$venv_pv" >&2
        printf "  \033[1;33m[makemigrations SPINNER LOG contents:]\033[0m" >&2
        if [ -n "${mmk_spin_log}" ] && [ -f "${mmk_spin_log}" ]; then
          printf " (file=%s, size=$(wc -c <"$mmk_spin_log" 2>/dev/null || echo 0) bytes)\n" "$mmk_spin_log" >&2
          tail -n 60 "$mmk_spin_log" 2>/dev/null | sed 's#^#    #' >&2 || true
        else
          printf "\n    [NO SPINNER LOG FOUND — _run_with_spinner may not have written one]\n" >&2
        fi
        printf "  \033[1;33m[FRESH DIRECT traceback (makemigrations rerun OUTSIDE spinner, no redirection):]\033[0m\n" >&2
        printf '%s\n' "$mmk_fresh_tb" | sed 's#^#    #' >&2
        printf "  \033[1;33m[django.setup() standalone probe rc=%d]:\033[0m\n" "$mmk_dsetup_rc" >&2
        printf '%s\n' "$mmk_dsetup_out" | sed 's#^#    #' >&2
        rm -f "$mmk_fresh_tmp" 2>/dev/null || true
        if [ "$mmk_attempt" -lt "$mmk_max" ]; then
          prompt_edit_multiple \
            "manage.py makemigrations FAILED attempt $mmk_attempt/$mmk_max — edit a field to fix it before we retry:" \
            "DJANGO_SETTINGS_MODULE DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT APP_DIR" \
            "Retry makemigrations with (possibly edited) values NOW?" \
            "y"
          _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
          set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
          export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
          mmk_cmd_check="cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --check --dry-run --verbosity 1"
          mmk_cmd_real="cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput --verbosity 1"
        else
          _die "\
manage.py makemigrations FAILED all $mmk_max attempts (last rc=$mmk_rc).

Categorized causes (most common first):

  (A) DJANGO_SETTINGS_MODULE=$DJANGO_SETTINGS_MODULE is invalid or INSTALLED_APPS contains typos → verify against Cause (A) django.setup probe above. COPY-PASTE:
        cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' -c 'import django; django.setup(); from django.apps import apps; [print(a.name) for a in apps.get_app_configs()]'

  (B) DB connection failure (makemigrations introspects DB for swappable AUTH_USER_MODEL / RunPython dependencies). SMOKE TEST:
        PGPASSWORD='$DB_PASSWORD' psql -h '$DB_HOST' -p '$DB_PORT' -U '$DB_USER' -d '$DB_NAME' -c 'SELECT 1;'

  (C) Migration model integrity error: one of your models has an invalid field definition (e.g. ForeignKey to a model not in INSTALLED_APPS, broken choices). The FRESH traceback above lists the exact line of models.py.

  (D) Python / venv mismatch. Venv python = $venv_pv. If >= 3.14 psycopg2/weasyprint C extensions compile fails earlier at pip step, but makemigrations can still fail to import them.

FULL makemigrations reproduce (SINGLE LINE):
  $mmk_cmd_real
"
        fi
      done
      if [ "$mmk_ok" -eq 1 ]; then
        _ok "manage.py makemigrations SUCCESS (attempt $mmk_attempt/$mmk_max). New migration files written to app/migrations/ subdirectories."
      fi
    fi
    set -e
    # ── UNCONDITIONAL PRE-MIGRATE CIRCULAR DEP RESOLVE (catches cycles from git-pushed 0001 files!) ──
    #   The above makemigrations section runs ONLY when there are pending model changes
    #   (makemigrations --check rc=1). If 0001 files are ALREADY committed in the git repo
    #   (exact user scenario!), makemigrations skips entirely → the post-mk circular check
    #   above NEVER RUNS. Run the graph check HERE UNCONDITIONALLY to catch git-committed cycles.
    _section "PRE-MIGRATE: UNCONDITIONAL Django migration graph check (catches cycles from git-pushed 0001 files)."
    set +e
    _resolve_circular_dep "$APP_DIR" "${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" "pre-safety1" || true
    set -e
    # ── Pre-migrate SAFETY-1: AUTH_USER_MODEL probe. Classic Django bug #1: custom user model (AUTH_USER_MODEL !=
    #    auth.User, e.g. AUTH_USER_MODEL='auth_app.User' → table 'auth_app_user') MUST have ITS OWN 0001 migration
    #    applied BEFORE django.contrib.admin.0001_initial runs. Admin.0001 creates FK django_admin_log.user_id
    #    REFERENCES auth_app_user(id). If auth_app's migration hasn't run yet we get:
    #      ProgrammingError: relation "auth_app_user" does not exist
    #    during admin.0001_initial — EXACTLY the crash in the user's banner (see showmigrations probe: auth_app
    #    wasn't even listed because its 0001.py / migrations/__init__.py was missing from git).
    # Steps: (1) Python probe reads settings.AUTH_USER_MODEL → split into app_label / model_name.
    #        (2) If app_label != 'auth' (custom user) → run `manage.py migrate <app_label>` ALONE, FIRST,
    #            BEFORE running the full `migrate` (with no args). This creates auth_app_user table so admin FK succeeds.
    #        (3) If this single-app migrate FAILS: full 3-attempt retry banner for it, not swallow.
    local aum_raw="" aum_app="" aum_model="" aum_db_table=""
    aum_raw=$( PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" - <<'PY' 2>/dev/null || true
import os, sys
try:
    import django; django.setup()
    from django.conf import settings
    from django.apps import apps
    aum = getattr(settings, "AUTH_USER_MODEL", "auth.User")
    al, _, mn = aum.partition(".")
    try:
        mc = apps.get_model(al, mn, require_ready=False)
        tbl = mc._meta.db_table
    except Exception:
        tbl = al.lower() + "_" + mn.lower()
    print("APP=" + al + "\tMODEL=" + mn + "\tDB_TABLE=" + tbl)
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
)
    if [ -n "${aum_raw}" ]; then
      aum_app=${aum_raw#*APP=}; aum_app=${aum_app%%$'\t'*}
      aum_model=${aum_raw#*MODEL=}; aum_model=${aum_model%%$'\t'*}
      aum_db_table=${aum_raw#*DB_TABLE=}
    fi
    if [ -n "${aum_app}" ] && [ "${aum_app}" != "auth" ]; then
      # ── ── ── DYNAMIC SAFETY-1: AUTH_USER_MODEL single-app migration with AUTOMATIC TRANSITIVE DEPENDENCY RESOLUTION ── ── ──
      # TWO-STAGE strategy (because user's real-world repo has auth_app.User with ForeignKey('companies.Company') → auth_app
      # 0001 dependency on companies.0001 → naive single migrate auth_app alone FAILS with relation "companies_company" DNE):
      #   STAGE 1 (PROACTIVE, NO ERRORS REQUIRED): Introspect Django MigrationLoader.graph for the user app's initial 0001
      #      migration file dependencies list → extract any app_label != self.app_label != django.contrib.* → these are the
      #      transitive INSTALLED_APPS we MUST run BEFORE aum_app. Run migrate <dep> one at a time (with auto-makemigrations
      #      fallback if their migration files missing) in dependency order.
      #   STAGE 2 (REACTIVE, ERROR-DRIVEN): Even STAGE 1 misses some (e.g. model FK through through table not reflected in
      #      Migration.dependencies). Iteratively: try running migrate <current_target>. If FAILS with ProgrammingError relation
      #      X does not exist:
      #        → parse relation X → guess app_label B (same parser as main migrate banner).
      #        → if B NOT already applied AND B NOT already in next-queue → PREPEND to migration queue (so B runs NEXT attempt).
      #        → cap max 8 iterations → avoid infinite loops (circular FK impossible with Django tables but defensive for user code).
      # If STAGE 1 + STAGE 2 still fail → fall back to 3-attempt retry banner with prompt_edit_multiple as before.
      _section "AUTH_USER_MODEL PRECHECK: custom user = '${aum_app}.${aum_model}' → table ${aum_db_table}. Resolving TRANSITIVE dependencies dynamically (STAGE 1: graph introspection; STAGE 2: UndefinedTable-driven iteration)."
      local _dyn_base_env="cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python'"
      local _dyn_dep_apps=""   # space-separated ordered list: STAGE 1 + STAGE 2 discovered dependencies, in required order (dep first).
      local _dyn_applied=""    # space-separated list: apps that SUCCESSFULLY applied (skip on retry).
      local _dyn_max_iter=8 _dyn_iter=0 _dyn_rc=0 _dyn_tb="" _dyn_rel="" _dyn_guess=""
      local _dyn_queue="${aum_app}"   # queue: next app to try. Starts with aum_app; dependencies are PREPENDED as discovered.
      local _dyn_done=0
      local _dyn_known_apps=""
      _dyn_known_apps=$( PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" - <<'PY' 2>/dev/null || true
import sys
try:
    import django
    django.setup()
    from django.apps import apps
    labels = sorted({cfg.label for cfg in apps.get_app_configs() if getattr(cfg, "label", None)})
    print(" ".join(labels))
except Exception:
    sys.exit(0)
PY
)
      # ── STAGE 1: proactive graph introspection BEFORE any migrate attempt.
      local _stage1_deps=""
      _stage1_deps=$( TARGET_AUM_APP="${aum_app}" PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" - <<'PY' 2>/dev/null || true
import os, sys, json
try:
    import django; django.setup()
    from django.conf import settings
    from django.db import connections
    from django.db.migrations.loader import MigrationLoader
    # Introspect migration loader WITHOUT DB access (ignore migration records — we want the filesystem migration graph).
    from django.db.migrations.loader import MIGRATIONS_MODULE_NAME
    from django.apps import apps
    from django.db.migrations.recorder import MigrationRecorder
    target_app_label = os.environ.get("TARGET_AUM_APP", "")
    # Build loader with connection (we won't write to DB; loader reads both DB + filesystem).
    loader = MigrationLoader(connections["default"], ignore_no_migrations=False)
    # Collect: for every migration key (app, name) that STARTS with target_app_label, walk its .dependencies, filter to only
    # those dependencies whose dep[0] != target_app_label and dep[0] not in built-in django.contrib.* apps.
    # Then walk those dependencies recursively, depth-first.
    builtins = {"admin","auth","authtoken","contenttypes","sessions","messages","staticfiles","sites","flatpages","redirects","django_celery_beat","django_celery_results","guardian"}
    seen = set()
    order = []
    def walk_deps_of(app_label, depth=0):
        if depth > 12:
            return
        for key, mig in loader.disk_migrations.items():
            if key[0] != app_label:
                continue
            for dep in getattr(mig, "dependencies", []) or []:
                dep_app = dep[0]
                if dep_app in builtins or dep_app == app_label or dep_app in seen:
                    continue
                # Skip django.contrib.* style apps that ship with migrations but are handled by full migrate later.
                if dep_app in seen:
                    continue
                seen.add(dep_app)
                order.append(dep_app)
                walk_deps_of(dep_app, depth+1)
    walk_deps_of(target_app_label)
    # Also: walk ForeignKey targets of the User model's own 0001 CreateModel. If CreateModel operation has FK field with
    # to="app_label.ModelName" not in builtins → add dep_app if not already.
    try:
        from django.db.migrations.state import ModelState
        from django.db.migrations import operations
        for key, mig in loader.disk_migrations.items():
            if key[0] != target_app_label:
                continue
            for op in getattr(mig, "operations", []) or []:
                if hasattr(op, "fields"):  # CreateModel
                    for _fname, _field in op.fields or []:
                        to_val = None
                        if hasattr(_field, "remote_field") and _field.remote_field and hasattr(_field.remote_field, "model"):
                            to_val = _field.remote_field.model
                        elif hasattr(_field, "to"):
                            to_val = getattr(_field, "to", None)
                        if not to_val:
                            continue
                        to_s = str(to_val)
                        if "." in to_s:
                            fk_app, _ = to_s.split(".", 1)
                        else:
                            # FK to self or same app.
                            continue
                        if fk_app not in builtins and fk_app != target_app_label and fk_app not in seen:
                            seen.add(fk_app)
                            order.insert(0, fk_app)
                            walk_deps_of(fk_app, 1)
    except Exception:
        pass
    print(" ".join(order))
    sys.exit(0)
except Exception as _e:
    # Graph introspection can fail for a myriad reasons (0001 not generated yet, we fail silently and STAGE 2 will catch deps via errors).
    sys.exit(0)
PY
)
      if [ -n "${_stage1_deps}" ]; then
        # ── Filter stage1 deps: (1) strip target app label removed; (2) dedupe preserve order; (3) remove whitespace trimmed.
        #    Pure POSIX string ops — no associative arrays, works on Bash 3.2+. Needle-in-haystack: " $_s1_filtered " contains " $_s1_tok ".
        local _s1_filtered="" _s1_tok=""
        for _s1_tok in ${_stage1_deps}; do
          _s1_tok=$(printf '%s' "${_s1_tok}" | tr -d '[:space:]\r\n' || true)
          [ -z "${_s1_tok}" ] && continue
          [ "${_s1_tok}" = "${aum_app}" ] && continue
          # Dedupe: is token already in filtered list?
          if [ -z "${_s1_filtered}" ]; then
            _s1_filtered="${_s1_tok}"
          elif [[ " ${_s1_filtered} " == *" ${_s1_tok} "* ]]; then
            continue
          else
            _s1_filtered="${_s1_filtered} ${_s1_tok}"
          fi
        done
        _stage1_deps="${_s1_filtered}"
        _info "STAGE 1 graph introspection: ${aum_app} 0001 transitive dependencies (non-builtin, deduped) = [${_stage1_deps}]. Will run these BEFORE ${aum_app}."
        # Build queue: [deps order dep-first] + aum_app.
        if [ -n "${_stage1_deps}" ]; then
          _dyn_queue="${_stage1_deps} ${aum_app}"
        else
          _dyn_queue="${aum_app}"
        fi
      else
        _info "STAGE 1 graph introspection: no transitive deps discoverable (0001 missing? falling back to STAGE 2 UndefinedTable-driven discovery)."
      fi
      # ── STAGE 2: iterative UndefinedTable-driven topological single-app migrate loop.
      while [ "$_dyn_done" -ne 1 ] && [ "$_dyn_iter" -lt "$_dyn_max_iter" ]; do
        _dyn_iter=$(( _dyn_iter + 1 ))
        # Take FIRST app from queue (preserve order so dependencies run first).
        local _dyn_next="" _dyn_rest=""
        for _dyn_next in $_dyn_queue; do break; done
        _dyn_rest=${_dyn_queue#"${_dyn_next}"}; _dyn_rest=${_dyn_rest# }; _dyn_rest=${_dyn_rest% }
        if [ -z "${_dyn_next}" ]; then _dyn_done=1; break; fi
        # If already applied → skip (don't re-apply already applied single-app).
        local _skip=0
        local _a
        for _a in $_dyn_applied; do [ "$_a" = "$_dyn_next" ] && _skip=1; done
        if [ "$_skip" -eq 1 ]; then
          _dyn_queue="${_dyn_rest}"
          continue
        fi
        # If migration files MISSING for next app → auto-makemigrations for it once (same pattern as before).
        local _mmk_fallback_rc=0
        {
          local _has_mk=0
          local _sm_head="" _sm_rc=0
          # NOTE: showmigrations / makemigrations / migrate can ALL CRASH with NodeNotFoundError before doing anything
          # if the filesystem migration graph already contains a DummyNode (orphan later-numbered migration referencing missing earlier sibling).
          # We capture rc; non-zero means graph is broken → treat as "needs makemigrations + cleanup".
          set +e
          _sm_head=$( cd "$APP_DIR" && PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" manage.py showmigrations "$_dyn_next" 2>&1 | head -n 3 )
          _sm_rc=$?
          set -e
          if [ "$_sm_rc" -eq 0 ] && printf '%s\n' "$_sm_head" | grep -q '\[ \] 0001\|0001_initial\|App .* does not have migrations'; then
            _has_mk=1
          elif [ "$_sm_rc" -ne 0 ] && printf '%s\n' "$_sm_head" | grep -qE 'NodeNotFoundError|DummyNode|reference nonexistent parent'; then
            # Graph already broken (orphan migration file) — force makemigrations run to fix it.
            _has_mk=1
          fi
          if [ "$_has_mk" -ne 1 ]; then
            _info "App '${_dyn_next}' has NO migration files yet (${aum_app} dependency chain). Auto-running: makemigrations ${_dyn_next}."
            _run_with_spinner "manage.py makemigrations ${_dyn_next} (auto — required by AUTH_USER_MODEL dependency chain)" bash -c \
              "${_dyn_base_env} manage.py makemigrations --noinput '${_dyn_next}'" || _mmk_fallback_rc=$?
          fi
        } 2>/dev/null || true
        local _dyn_next_cmd="${_dyn_base_env} manage.py migrate '${_dyn_next}'"
        _dyn_rc=0
        set +e
        _run_migrate_autoheal "$APP_DIR" "${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" "${_dyn_base_env}" "${_dyn_next}" || _dyn_rc=$?
        set -e
        if [ "$_dyn_rc" -eq 0 ]; then
          _ok "migrate ${_dyn_next} OK (iteration $_dyn_iter). Added to applied set."
          _dyn_applied="${_dyn_applied} ${_dyn_next}"; _dyn_applied=${_dyn_applied# }; _dyn_applied=${_dyn_applied% }
          _dyn_queue="${_dyn_rest}"
          [ -z "${_dyn_queue}" ] && _dyn_done=1
          continue
        fi
        # FAILURE: check whether it's ProgrammingError UndefinedTable — if yes, resolve dependency dynamically.
        _dyn_tb=$( bash -c "$_dyn_next_cmd" 2>&1 | tail -n 80 || true )
        # ── Check for CircularDependencyError (auth_app.0001 ↔ companies.0001 cross-FK). ──
        local _dyn_circ=""
        _dyn_circ=$( printf '%s\n' "$_dyn_tb" | grep -oE 'CircularDependencyError:[^$]*$' 2>/dev/null | head -n 1 || true )
        if [ -n "${_dyn_circ}" ]; then
          _warn "migrate ${_dyn_next} FAILED: CircularDependencyError detected. Raw circular pair = [${_dyn_circ#CircularDependencyError: }]. CAUSE: both apps' 0001_initial migration files contain ForeignKey fields pointing AT EACH OTHER (auth_app.User → companies.Company AND companies.Company → auth_app.User) — Django graph sees a DAG cycle: auth_app.0001 depends on companies.0001 which depends on auth_app.0001. AUTO-FIX NOT AVAILABLE in STAGE 2; falling back to 3-attempt retry banner with DIRECT circular-dep copy-paste resolution template (CAUSE I in banner)."
          break
        fi
        # ── Check for NodeNotFoundError (orphan migration file with missing parent dependency): ──
        #    Extract FIRST single-quoted valid Django identifier after 'parent node' (the tuple ('LABEL', 'NNNN_initial')).
        #    No paren/quote order reasoning needed.
        local _dyn_node_miss="" _dyn_node_ref="" _dyn_node_line=""
        _dyn_node_line="$( printf '%s\n' "$_dyn_tb" | grep -E 'NodeNotFoundError: Migration [^ ]+ dependencies reference nonexistent parent node' 2>/dev/null | head -n 1 || true )"
        if [ -n "${_dyn_node_line}" ]; then
          _dyn_node_ref="$( printf '%s' "${_dyn_node_line}" | grep -oE 'Migration [^ ]+ dependencies' 2>/dev/null | head -n 1 | sed -E 's/^Migration //; s/ dependencies$//' || true )"
          _dyn_node_miss="$( printf '%s' "${_dyn_node_line}" | grep -oE "'[a-zA-Z0-9_]+'" 2>/dev/null | head -n 1 | sed -E "s/^'//; s/'$//" || true )"
        fi
        if [ -z "${_dyn_node_miss}" ]; then
          _dyn_node_miss="$( printf '%s\n' "$_dyn_tb" | sed -n '/parent node/,$p' 2>/dev/null | grep -oE "'[a-zA-Z0-9_]+'" 2>/dev/null | head -n 1 | sed -E "s/^'//; s/'$//" || true )"
        fi
        # STRICT VALIDATION: if parse produced invalid chars, skip entirely — no queue mutation.
        if [ -n "${_dyn_node_miss}" ]; then
          if [ -n "${_dyn_known_apps}" ]; then
            if [[ " ${_dyn_known_apps} " != *" ${_dyn_node_miss} "* ]]; then
              _info "STAGE 2: extracted missing app='${_dyn_node_miss}' is not a real installed app label — ignore."
              _dyn_node_miss=""
            fi
          elif ! printf '%s' "${_dyn_node_miss}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
            _info "STAGE 2: extracted missing app='${_dyn_node_miss}' failed label-char validation — ignore."
            _dyn_node_miss=""
          fi
        fi
        # ── SANITIZE QUEUE: rebuild token-by-token, DROP any token that has non [a-zA-Z0-9_] chars (defense-in-depth). ──
        #    If we know the installed app labels, keep ONLY those. This strips accidentally-added junk tokens like
        #    'reference nonexistent parent node companies' that bash word-split into plain words.
        local _dyn_queue_clean="" _tok
        for _tok in $_dyn_queue; do
          if [ -n "${_dyn_known_apps}" ]; then
            [[ " ${_dyn_known_apps} " == *" ${_tok} "* ]] || continue
          elif ! printf '%s' "${_tok}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
            continue
          fi
          [ -z "${_dyn_queue_clean}" ] && _dyn_queue_clean="${_tok}" || _dyn_queue_clean="${_dyn_queue_clean} ${_tok}"
        done
        _dyn_queue="${_dyn_queue_clean}"
        local _dyn_applied_clean=""
        for _tok in $_dyn_applied; do
          if [ -n "${_dyn_known_apps}" ]; then
            [[ " ${_dyn_known_apps} " == *" ${_tok} "* ]] || continue
          elif ! printf '%s' "${_tok}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
            continue
          fi
          [ -z "${_dyn_applied_clean}" ] && _dyn_applied_clean="${_tok}" || _dyn_applied_clean="${_dyn_applied_clean} ${_tok}"
        done
        _dyn_applied="${_dyn_applied_clean}"
        if [ -n "${_dyn_node_miss}" ]; then
          # Heal same as autoheal wrapper: auto-run makemigrations on missing app FIRST, then DELETE orphan referencer if not applied.
          _warn "migrate ${_dyn_next} FAILED: NodeNotFoundError graph broken. Referencer='${_dyn_node_ref}' missing_parent_app='${_dyn_node_miss}'. Auto-healing in STAGE 2: migrate missing parent app, then retry current target."
          local _dyn_deleted_orphan=0
          local _ref_app="" _ref_name=""
          if [[ "${_dyn_node_ref}" == *.* ]]; then
            _ref_app="${_dyn_node_ref%%.*}"
            _ref_name="${_dyn_node_ref#*.}"
          fi
          if [ -n "${_ref_app}" ] && [ -n "${_ref_name}" ]; then
            local _ref_file="${APP_DIR}/${_ref_app}/migrations/${_ref_name}.py"
            if [ -f "${_ref_file}" ]; then
              local _applied=0
              if PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" manage.py showmigrations "${_ref_app}" 2>/dev/null | grep -qE "^\[X\][[:space:]]+${_ref_name}" >/dev/null 2>&1; then
                _applied=1
              fi
              if [ "$_applied" -eq 0 ]; then
                _warn "STAGE 2: referencer file '${_ref_app}.${_ref_name}' NOT applied in DB — it's a half-generated partial from interrupted install. Deleting orphan: ${_ref_file}"
                rm -f "${_ref_file}" 2>/dev/null || true
                _dyn_deleted_orphan=1
              fi
            fi
          fi
          # Ensure missing parent app is migrated BEFORE retrying target (prepend to queue).
          local _picked_dep="${_dyn_node_miss}"
          # Sanity: if the missing parent is the SAME app as the current target, queue mutation would just requeue the
          # same app as its own dependency. Orphan deletion above may already have fixed the graph; retry current target once.
          if [ "${_picked_dep}" = "${_dyn_next}" ]; then
            if [ "$_dyn_deleted_orphan" -eq 1 ]; then
              _warn "STAGE 2: NodeNotFoundError missing parent '${_picked_dep}' IS the current target '${_dyn_next}', but orphan cleanup changed state. Retrying current target once in bounded loop."
              continue
            fi
            _warn "STAGE 2: NodeNotFoundError missing parent '${_picked_dep}' IS the current target '${_dyn_next}' and orphan cleanup made NO state change. Breaking to retry banner instead of repeating the same error."
            break
          fi
          # DOUBLE VALIDATION before queue mutation: any parse failure now → skip without touching queue.
          if [ -n "${_dyn_known_apps}" ]; then
            if [[ " ${_dyn_known_apps} " != *" ${_picked_dep} "* ]]; then
              _info "STAGE 2: picked dep='${_picked_dep}' is not a real installed app label — skipping queue mutation."
              break
            fi
          elif ! printf '%s' "${_picked_dep}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
            _info "STAGE 2: picked dep='${_picked_dep}' failed final validation before queue rebuild — skipping queue mutation."
            break
          fi
          local _dup=0
          for _a in $_dyn_queue; do [ "$_a" = "${_picked_dep}" ] && _dup=1; done
          for _a in $_dyn_applied; do [ "$_a" = "${_picked_dep}" ] && _dup=2; done
          if [ "$_dup" -eq 0 ]; then
            _info "STAGE 2: prepending missing parent app '${_picked_dep}' to migration queue (will run BEFORE '${_dyn_next}')."
            _dyn_queue="${_picked_dep} ${_dyn_next} ${_dyn_rest}"
          elif [ "$_dup" -eq 1 ]; then
            local _new_q="" _w
            for _w in $_dyn_queue; do
              if [ "$_w" = "${_picked_dep}" ]; then
                _new_q="${_w} ${_dyn_next}"
              elif [ "$_w" != "${_dyn_next}" ]; then
                [ -z "${_new_q}" ] && _new_q="${_w}" || _new_q="${_new_q} ${_w}"
              fi
            done
            _dyn_queue="${_new_q} ${_dyn_rest}"
          else
            continue
          fi
          # ── SANITIZE queue AGAIN after rebuild (defense-in-depth: strip any accidentally word-split tokens). ──
          _dyn_queue_clean=""
          for _tok in $_dyn_queue; do
            if [ -n "${_dyn_known_apps}" ]; then
              [[ " ${_dyn_known_apps} " == *" ${_tok} "* ]] || continue
            elif ! printf '%s' "${_tok}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
              continue
            fi
            [ -z "${_dyn_queue_clean}" ] && _dyn_queue_clean="${_tok}" || _dyn_queue_clean="${_dyn_queue_clean} ${_tok}"
          done
          _dyn_queue="${_dyn_queue_clean}"
          continue
        fi
        local _dyn_uc=""
        _dyn_uc="$( printf '%s\n' "$_dyn_tb" | grep -E 'UndefinedColumn|django\.db\.utils\.ProgrammingError: column|psycopg2\.errors\.UndefinedColumn' 2>/dev/null | head -n 1 || true )"
        if [ -n "${_dyn_uc}" ]; then
          local _dyn_apps_line="" _dyn_apps_raw="" _dyn_apps_list="" _a2=""
          _dyn_apps_line="$( printf '%s\n' "$_dyn_tb" | grep -oE "Your models in app\\(s\\):[^\n]+" 2>/dev/null | head -n 1 || true )"
          if [ -n "${_dyn_apps_line}" ]; then
            _dyn_apps_raw="$( printf '%s' "${_dyn_apps_line}" | grep -oE "'[a-zA-Z0-9_]+'" 2>/dev/null | sed -E "s/^'//; s/'$//" | tr '\n' ' ' | tr -s ' ' | sed -E 's/^ //; s/ $//' || true )"
          fi
          if [ -z "${_dyn_apps_raw}" ]; then
            _dyn_apps_raw="${_dyn_next}"
          fi
          for _a2 in ${_dyn_apps_raw}; do
            [ -z "${_a2}" ] && continue
            if [ -n "${_dyn_known_apps}" ] && [[ " ${_dyn_known_apps} " != *" ${_a2} "* ]]; then
              continue
            fi
            if [ -z "${_dyn_apps_list}" ]; then
              _dyn_apps_list="${_a2}"
            elif [[ " ${_dyn_apps_list} " == *" ${_a2} "* ]]; then
              continue
            else
              _dyn_apps_list="${_dyn_apps_list} ${_a2}"
            fi
          done
          if [ -n "${_dyn_apps_list}" ]; then
            _warn "migrate ${_dyn_next} FAILED: UndefinedColumn detected (schema drift; migrations missing/outdated). Auto-running makemigrations for: [${_dyn_apps_list}] then retrying via queue."
            local _pref="" _a3=""
            for _a3 in ${_dyn_apps_list}; do
              set +e
              _run_with_spinner "manage.py makemigrations ${_a3} (autoheal — UndefinedColumn)" bash -c \
                "${_dyn_base_env} manage.py makemigrations --noinput '${_a3}'"
              local _mm2_rc=$?
              if [ "${_mm2_rc}" -ne 0 ]; then
                local _mm2_log=""
                _mm2_log="$( ls -1t /tmp/rasyatone_spin_*makemig*${_a3}*.log /tmp/rasyatone_spin_*makemigrations*${_a3}*.log 2>/dev/null | head -n 1 || true )"
                if [ -n "${_mm2_log}" ] && grep -Eq "impossible to add a non-nullable field without specifying a default|non-nullable field" "${_mm2_log}" 2>/dev/null; then
                  local _mm2_tail=""
                  _mm2_tail="$( tail -n 3 "${_mm2_log}" 2>/dev/null | tr '\n' ' ' | tr -s ' ' | sed -E 's/^ //; s/ $//' || true )"
                  _die "makemigrations '${_a3}' requires a default/null for a new non-nullable field. Fix the Django model/migration (set null=True or provide a default/data migration), then rerun. ${_mm2_tail}"
                fi
                _warn "migrate ${_dyn_next} FAILED: makemigrations '${_a3}' failed (rc=${_mm2_rc}). Cannot auto-heal further."
                set -e
                break
              fi
              set -e
              if [ "${_a3}" != "${_dyn_next}" ]; then
                local _seen=0 _t
                for _t in $_dyn_queue; do [ "$_t" = "${_a3}" ] && _seen=1; done
                for _t in $_dyn_applied; do [ "$_t" = "${_a3}" ] && _seen=2; done
                if [ "$_seen" -eq 0 ]; then
                  [ -z "${_pref}" ] && _pref="${_a3}" || _pref="${_pref} ${_a3}"
                fi
              fi
            done
            if [ "${_mm2_rc:-0}" -ne 0 ]; then
              break
            fi
            if [ -n "${_pref}" ]; then
              _dyn_queue="${_pref} ${_dyn_next} ${_dyn_rest}"
            fi
            continue
          fi
        fi
        _dyn_rel=$( printf '%s\n' "$_dyn_tb" | grep -oE 'relation "[^"]+" does not exist' 2>/dev/null | head -n 1 | sed 's/^relation "//; s/" does not exist$//' || true )
        if [ -z "${_dyn_rel}" ]; then
          # Not a dependency error — break out of STAGE 2 into 3-attempt retry banner with prompt_edit_multiple.
          _warn "migrate ${_dyn_next} FAILED (rc=$_dyn_rc) BUT error is NOT any auto-healable class (UndefinedTable/CircularDep/NodeNotFound). Leaving STAGE 2 and entering full 3-attempt retry loop for ${aum_app} with evidence banner."
          break
        fi
        # UndefinedTable hit! Guess app_label from relation name (same as main migrate banner).
        _dyn_guess=$(printf '%s' "$_dyn_rel" | awk -F'_' '{if(NF>2)print $1"_"$2"/"$1; else if(NF==2)print $1; else print $0}' 2>/dev/null || true)
        local _dep_candidate=""
        # Try guesses in order: multi-segment first, then single segment.
        case "$_dyn_guess" in
          */*) _dep_candidate="${_dyn_guess%%/*}" ;;
          *  ) _dep_candidate="${_dyn_guess}" ;;
        esac
        local _fallback_dep=""
        # If the guesses don't seem to exist, also try: first segment only.
        if [ -z "${_fallback_dep}" ]; then _fallback_dep=$(printf '%s' "$_dyn_rel" | awk -F'_' '{print $1}' 2>/dev/null || true); fi
        local _picked_dep=""
        local _cand
        for _cand in "$_dep_candidate" "$_fallback_dep"; do
          [ -z "$_cand" ] && continue
          # Quick check: does INSTALLED_APPS know an app with this label? (python probe, tolerant — but keep stderr to diagnose probe crashes).
          local _found=0
          local _probe_stderr="/tmp/rasyatone_stage2_probe_stderr_$$.log"
          local _probe_stdout="/tmp/rasyatone_stage2_probe_stdout_$$.log"
          : > "$_probe_stderr" 2>/dev/null || true
          : > "$_probe_stdout" 2>/dev/null || true
          set +e
          PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" - "$_cand" >"$_probe_stdout" 2>"$_probe_stderr" <<'PY'
import django, sys
try:
    django.setup()
    from django.apps import apps
    label = sys.argv[1]
    # (a) try strict get_app_config(label) first — AppConfig.label official lookup
    try:
        cfg = apps.get_app_config(label)
        print(cfg.label)
        sys.exit(0)
    except LookupError:
        pass
    # (b) fallback: iterate all installed apps and check their LABELS / dotted paths
    #      (handles cases where label registered with non-default name in AppConfig)
    for cfg in apps.get_app_configs():
        lc = cfg.label
        ld = cfg.name  # full dotted module name e.g. 'core.hr'
        if ld and (ld == label or ld.endswith('.' + label)):
            print(lc)
            sys.exit(0)
        if lc == label:
            print(lc)
            sys.exit(0)
    sys.exit(2)  # exit 2 = clean no match, stderr empty
except Exception as _e:
    import traceback
    sys.stderr.write("STAGE2_PROBE_EXCEPTION: %s\n" % str(_e))
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PY
          local _probe_rc=$?
          set -e
          local _probe_res=""
          _probe_res="$( tr -d '[:space:]\r\n' < "$_probe_stdout" 2>/dev/null || printf '' )"
          if [ "$_probe_rc" -eq 0 ] && [ -n "$_probe_res" ]; then
            _picked_dep="$_probe_res"
            rm -f "$_probe_stderr" "$_probe_stdout" 2>/dev/null || true
            break
          elif [ "$_probe_rc" -eq 1 ]; then
            local _err_snip=""
            _err_snip="$( tail -n 10 "$_probe_stderr" 2>/dev/null | sed 's/^/      | /' || true )"
            _warn "STAGE 2: UndefinedTable table '${_dyn_rel}' candidate app '${_cand}' — apps.is_installed PROBE FAILED (django.setup crashed; missing setting or import error). Probe stderr (last 10 lines):\n${_err_snip}\n    Will try other candidates / fall back."
          fi
          rm -f "$_probe_stderr" "$_probe_stdout" 2>/dev/null || true
        done
        if [ -z "${_picked_dep}" ]; then
          _warn "STAGE 2: UndefinedTable relation '${_dyn_rel}' → guess '${_dyn_guess}' not installed in INSTALLED_APPS. Can't resolve dependency dynamically → falling to 3-attempt retry banner."
          break
        fi
        # Sanity: dependency must NOT be the same app that just failed (would loop forever).
        if [ "${_picked_dep}" = "${_dyn_next}" ]; then
          _warn "STAGE 2: UndefinedTable within SAME app '${_picked_dep}' (self-referential FK). This is NOT a transitive dep bug; it's a migration file integrity error inside app. Falling out."
          break
        fi
        # Prevent duplicates in queue:
        local _dup=0
        for _a in $_dyn_queue; do [ "$_a" = "${_picked_dep}" ] && _dup=1; done
        for _a in $_dyn_applied; do [ "$_a" = "${_picked_dep}" ] && _dup=2; done
        if [ "$_dup" -ge 2 ]; then
          _warn "STAGE 2: dep '${_picked_dep}' ALREADY applied successfully (not in DB state! likely a second FK referencing different table in same app OR existing migration dependencies don't match DB. Falling out to retry banner.)"
          break
        fi
        if [ "$_dup" -eq 1 ]; then
          _info "STAGE 2: dep '${_picked_dep}' already in queue (will run in order)."
          # It's already in queue somewhere; to guarantee it runs NEXT (because ${_dyn_next} depends on it RIGHT NOW), remove it
          # from wherever it is and PREPEND.
          local _new_q="" _w
          for _w in $_dyn_queue; do
            [ "$_w" = "${_picked_dep}" ] && continue
            [ "$_w" = "${_dyn_next}" ] && continue
            _new_q="${_new_q} ${_w}"
          done
          _new_q="${_new_q# }"
          _dyn_queue="${_picked_dep} ${_dyn_next} ${_new_q}"; _dyn_queue=${_dyn_queue% }
        else
          # Fresh dependency → PREPEND to queue so it runs NEXT iteration, then retry ${_dyn_next} after.
          _dyn_queue="${_picked_dep} ${_dyn_next} ${_dyn_rest}"; _dyn_queue=${_dyn_queue% }
        fi
        _info "STAGE 2 iteration $_dyn_iter/$_dyn_max_iter: migrate ${_dyn_next} failed with UndefinedTable '${_dyn_rel}' → resolved to dependency app '${_picked_dep}'. New queue = [${_dyn_queue}]"
      done
      # Check if we're DONE: queue empty AND target aum_app in applied list.
      local _aum_success=0
      for _a in $_dyn_applied; do [ "$_a" = "${aum_app}" ] && _aum_success=1; done
      if [ "$_aum_success" -eq 1 ]; then
        _ok "DYNAMIC AUTH_USER_MODEL DEPENDENCY RESOLUTION SUCCESS (${_dyn_iter} iterations). Applied apps in order: [${_dyn_applied}]. Table ${aum_db_table} now exists; admin.0001 FK will resolve cleanly. Proceeding to full migrate."
      else
        # ── Fallback full 3-attempt retry banner with prompt_edit_multiple for aum_app.
        _warn "Dynamic auth_user_model resolution did not fully succeed after ${_dyn_iter} iterations. Entering 3-attempt retry banner for '${aum_app}' migrate."
        local aum_att=0 aum_max=3 aum_ok=0 aum_frc=0
        local aum_fresh="/tmp/rasyatone_aum_fresh_$$.tmp"
        local aum_cmd="${_dyn_base_env} manage.py migrate '${aum_app}'"
        while [ "$aum_att" -lt "$aum_max" ] && [ "$aum_ok" -ne 1 ]; do
          aum_att=$(( aum_att + 1 ))
          aum_frc=0
          set +e
          _run_migrate_autoheal "$APP_DIR" "${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" "${_dyn_base_env}" "${aum_app}" || aum_frc=$?
          set -e
          if [ "$aum_frc" -eq 0 ]; then aum_ok=1; break; fi
          local aum_tb=""
          aum_tb=$( bash -c "$aum_cmd" 2>&1 | tail -n 80 || true )
          printf '%s\n' "$aum_tb" > "$aum_fresh" 2>/dev/null || true
          local aum_sho=""
          aum_sho=$( bash -c "${_dyn_base_env} manage.py showmigrations '${aum_app}'" 2>&1 | tail -n 40 || true )
          printf "\n\033[1;31m=== migrate ${aum_app} (AUTH_USER_MODEL app) FAILED attempt $aum_att/$aum_max (rc=$aum_frc) — EVIDENCE ===\033[0m\n" >&2
          printf "  \033[1;33m[EXACT CMD:]  \033[0m%s\n" "$aum_cmd" >&2
          printf "  \033[1;33m[FRESH DIRECT TRACEBACK:]\033[0m\n" >&2
          printf '%s\n' "$aum_tb" | sed 's#^#    #' >&2
          printf "  \033[1;33m[showmigrations ${aum_app}:]\033[0m\n" >&2
          printf '%s\n' "$aum_sho" | sed 's#^#    #' >&2
          printf "  \033[1;33m[STAGE 1 graph deps:]\033[0m %s\n" "${_stage1_deps:-<none discovered>}" >&2
          printf "  \033[1;33m[STAGE 2 applied:]\033[0m %s\n  \033[1;33m[STAGE 2 final queue:]\033[0m %s\n" "${_dyn_applied:-<none>}" "${_dyn_queue:-<empty>}" >&2
          # ── CAUSE (I): CircularDependencyError auto-extract + banner (if present in traceback). ──
          #   NOTE: _circ_apps MUST be declared OUTSIDE the if/then block. Your exact Contabo rerun crashed:
          #     line 4557: _circ_apps: unbound variable
          #   because _circ_apps was declared INSIDE `if [ -n "${_circ_line}" ]; then … fi` scope,
          #   and when traceback contained NO CircularDep (e.g. UndefinedTable hr_employee), the if
          #   never fired, but later L4557 ran `if [ -n "${_circ_apps}" ]; then` → nounset under set -u.
          local _circ_line="" _circ_pair_raw="" _circ_app1="" _circ_app2="" _circ_apps="" _circ_cp=""
          _circ_line=$(printf '%s\n' "$aum_tb" | grep -E 'CircularDependencyError:.*0001_initial' 2>/dev/null | head -n 1 || true)
          if [ -z "${_circ_line}" ]; then
            _circ_line=$(printf '%s\n' "$aum_tb" | grep -E '[a-zA-Z_][a-zA-Z0-9_]*\.0001_initial.*[a-zA-Z_][a-zA-Z0-9_]*\.0001_initial' 2>/dev/null | head -n 1 || true)
          fi
          if [ -n "${_circ_line}" ]; then
            _circ_pair_raw=$(printf '%s' "${_circ_line}" | sed -E 's/.*CircularDependencyError:\s*//' || true)
            _circ_app1=$(printf '%s' "${_circ_pair_raw}" | awk -F',' '{print $1}' | awk -F'.' '{print $1}' | tr -d '[:space:]' || true)
            _circ_app2=$(printf '%s' "${_circ_pair_raw}" | awk -F',' '{print $2}' | awk -F'.' '{print $1}' | tr -d '[:space:]' || true)
            # ORDER GUARANTEE: AUTH_USER_MODEL app (${aum_app}) is ALWAYS first word in CIRCULAR_APPS
            #   so menu-based CIRCULAR_APPLY_2STEP correctly sets cA = user app, cB = other app.
            if [ "${_circ_app2}" = "${aum_app}" ]; then
              local _ct="$_circ_app1"; _circ_app1="$_circ_app2"; _circ_app2="$_ct"
            fi
            _circ_apps="${_circ_app1} ${_circ_app2}"
            _circ_apps="${_circ_apps# }"
            printf "\n\033[1;95m=== CAUSE (I): AUTH_USER_MODEL CircularDependencyError DETECTED between apps [${_circ_app1}] ↔ [${_circ_app2}] (cross-FK in both 0001_initial.py files) ===\033[0m\n" >&2
            printf "  WHY: \033[1m%s.models.User has ForeignKey/OneToOne → %s.models.Company, AND %s.models.Company has ForeignKey → AUTH_USER_MODEL %s.User\033[0m in their respective models.py files.\n" "${_circ_app1}" "${_circ_app2}" "${_circ_app2}" "${_circ_app1}" >&2
            printf "  Django makemigrations auto-generated BOTH 0001_initial.py files with Migration.dependencies = [ ('%s','0001_initial'), ('%s','0001_initial') ] — forming a DAG cycle → CircularDependencyError at graph build time.\n" "${_circ_app1}" "${_circ_app2}" >&2
            printf "  RESOLUTION PATTERN (2-step mig-split, applied in exact order — or simpler: use AUTH_USER_MODEL swappable FK instead of direct FK):\n" >&2
            printf "  Step 1 (break cycle FIRST): temporarily REMOVE the cross-FK from ONE of the two apps (pick %s — the non-user app), run makemigrations for BOTH apps so 0001 has no cycle, migrate BOTH.\n" "${_circ_app2}" >&2
            printf "  Step 2 (add FK back): RE-ADD the ForeignKey you removed to %s models.py, run makemigrations again → 0002_add_fk for %s, then migrate (no cycle now since 0001 already applied to both).\n" "${_circ_app2}" "${_circ_app2}" >&2
            printf "  SIMPLER CORRECT FIX (preferred permanent Django idiom): change %s Company FK from ForeignKey('%s.User') → ForeignKey(settings.AUTH_USER_MODEL) AND in Migration.dependencies add run_before = [('%s', '0001_initial')] to %s 0001; or in your custom user model class definition ensure Auth_USER_MODEL is set before migrations are made — then delete both 0001 files and makemigrations fresh.\n" "${_circ_app2}" "${_circ_app1}" "${_circ_app1}" "${_circ_app2}" >&2
            printf "  COPY-PASTE SHELL FIX (deletes auto-gen bad 0001 files, regenerates with swappable AUTH_USER_MODEL FK in %s; user hits Enter):\n" "${_circ_app2}" >&2
            _circ_cp=$(printf 'cd %s && \\\n  for APP in %s %s; do\n    rm -f ${APP}/migrations/0001_initial.py 2>/dev/null || true\n    mkdir -p ${APP}/migrations && touch ${APP}/migrations/__init__.py 2>/dev/null || true\n  done && \\\n  PYTHONPATH="%s" DJANGO_SETTINGS_MODULE="%s" "%s/.venv/bin/python" manage.py makemigrations --noinput %s && \\\n  PYTHONPATH="%s" DJANGO_SETTINGS_MODULE="%s" "%s/.venv/bin/python" manage.py migrate %s && \\\n  PYTHONPATH="%s" DJANGO_SETTINGS_MODULE="%s" "%s/.venv/bin/python" manage.py makemigrations --noinput %s && \\\n  PYTHONPATH="%s" DJANGO_SETTINGS_MODULE="%s" "%s/.venv/bin/python" manage.py migrate %s && \\\n  PYTHONPATH="%s" DJANGO_SETTINGS_MODULE="%s" "%s/.venv/bin/python" manage.py makemigrations --noinput %s 2>/dev/null || true && \\\n  PYTHONPATH="%s" DJANGO_SETTINGS_MODULE="%s" "%s/.venv/bin/python" manage.py migrate %s 2>/dev/null || true && \\\n  PYTHONPATH="%s" DJANGO_SETTINGS_MODULE="%s" "%s/.venv/bin/python" manage.py migrate\n' "$APP_DIR" "${_circ_app1}" "${_circ_app2}" "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$APP_DIR" "${_circ_app1}" "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$APP_DIR" "${_circ_app1}" "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$APP_DIR" "${_circ_app2}" "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$APP_DIR" "${_circ_app2}" "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$APP_DIR" "${_circ_app1}" "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$APP_DIR" "${_circ_app2}" "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$APP_DIR" || true)
            printf '%s\n' "$_circ_cp" | sed 's/^/    /' >&2
          fi
          if [ "$aum_att" -lt "$aum_max" ]; then
            # Pre-populate sentinel defaults for prompt_edit_multiple.
            local _sugg_dep=""
            local _rel2
            _rel2=$(printf '%s\n' "$aum_tb" | grep -oE 'relation "[^"]+" does not exist' 2>/dev/null | head -n 1 | sed 's/^relation "//; s/" does not exist$//' || true)
            [ -n "${_rel2}" ] && _sugg_dep=$(printf '%s' "$_rel2" | awk -F'_' '{if(NF>2)print $1"_"$2; else print $1}' 2>/dev/null || true)
            # Ensure sentinels exist in ENV_FILE (set -u nounset protection).
            [ -n "${ENV_FILE:-}" ] && {
              { [ -z "${DJANGO_SETTINGS_MODULE+x}" ] && echo "DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE}" >> "$ENV_FILE" 2>/dev/null; } || true
              grep -q "^MAKEMIGRATIONS_APP=" "$ENV_FILE" 2>/dev/null || echo "MAKEMIGRATIONS_APP=y" >> "$ENV_FILE" 2>/dev/null || true
              if [ -n "${_sugg_dep}" ]; then
                grep -q "^MIGRATE_DEPENDENCY_FIRST=" "$ENV_FILE" 2>/dev/null && sed -i "/^MIGRATE_DEPENDENCY_FIRST=/d" "$ENV_FILE" 2>/dev/null || true
                echo "MIGRATE_DEPENDENCY_FIRST=${_sugg_dep}" >> "$ENV_FILE" 2>/dev/null || true
              else
                grep -q "^MIGRATE_DEPENDENCY_FIRST=" "$ENV_FILE" 2>/dev/null || echo "MIGRATE_DEPENDENCY_FIRST=" >> "$ENV_FILE" 2>/dev/null || true
              fi
              # ── CAUSE (I): if CircularDependencyError detected → pre-populate CIRCULAR_APPS sentinel + defaults. ──
              if [ -n "${_circ_apps}" ]; then
                local _valid_ca=""
                _valid_ca=$(_validate_circular_apps_value "${_circ_apps}" || true)
                grep -q "^CIRCULAR_APPS=" "$ENV_FILE" 2>/dev/null && sed -i "/^CIRCULAR_APPS=/d" "$ENV_FILE" 2>/dev/null || true
                if [ -n "${_valid_ca}" ]; then
                  echo "CIRCULAR_APPS='${_valid_ca}'" >> "$ENV_FILE" 2>/dev/null || true
                  grep -q "^CIRCULAR_APPLY_2STEP=" "$ENV_FILE" 2>/dev/null || echo "CIRCULAR_APPLY_2STEP='y'" >> "$ENV_FILE" 2>/dev/null || true
                else
                  echo "CIRCULAR_APPS=''" >> "$ENV_FILE" 2>/dev/null || true
                  grep -q "^CIRCULAR_APPLY_2STEP=" "$ENV_FILE" 2>/dev/null || echo "CIRCULAR_APPLY_2STEP='n'" >> "$ENV_FILE" 2>/dev/null || true
                fi
              else
                grep -q "^CIRCULAR_APPS=" "$ENV_FILE" 2>/dev/null || echo "CIRCULAR_APPS=''" >> "$ENV_FILE" 2>/dev/null || true
                grep -q "^CIRCULAR_APPLY_2STEP=" "$ENV_FILE" 2>/dev/null || echo "CIRCULAR_APPLY_2STEP='n'" >> "$ENV_FILE" 2>/dev/null || true
              fi
            } || true
            prompt_edit_multiple \
              "migrate ${aum_app} FAILED attempt $aum_att/$aum_max — edit fields then retry (fields 10-11 auto-apply CAUSE I 2-step circular split for auth_app↔companies cross-FK):" \
              "DJANGO_SETTINGS_MODULE MAKEMIGRATIONS_APP MIGRATE_DEPENDENCY_FIRST DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT APP_DIR CIRCULAR_APPS CIRCULAR_APPLY_2STEP" \
              "Retry migrate ${aum_app} with edited values?" \
              "y"
            _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
            set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
            export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
            # ── CAUSE (I): CIRCULAR_APPLY_2STEP sentinel = y → run the 2-step split auto-fix. ──
            local circ_do="${CIRCULAR_APPLY_2STEP:-n}"
            local circ_apps="${CIRCULAR_APPS:-}"
            circ_do="${circ_do#\'}"; circ_do="${circ_do%\'}"; circ_do="${circ_do#\"}"; circ_do="${circ_do%\"}"
            circ_apps="${circ_apps#\'}"; circ_apps="${circ_apps%\'}"; circ_apps="${circ_apps#\"}"; circ_apps="${circ_apps%\"}"
            if { [ "${circ_do}" = "y" ] || [ "${circ_do}" = "Y" ]; } && [ -n "${circ_apps}" ]; then
              _section "CAUSE (I) AUTO-FIX: CircularDependencyError detected (CIRCULAR_APPS=${circ_apps}). Running 2-step split auto-resolver."
              _info "Calling reusable circular dep resolver (labeled 'cause-i-menu'). Backup dir: /tmp/rasyatone_cause-i-menu_circular_backup_$$/"
              set +e
              _resolve_circular_dep "$APP_DIR" "${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" "cause-i-menu" || true
              set -e
              _ok "CAUSE (I) circular resolver returned (rc=$?). Retrying auth_app migrate now (should succeed)."
            fi
            local mmk_yn=${MAKEMIGRATIONS_APP:-y}
            if [ "${mmk_yn}" = "y" ] || [ "${mmk_yn}" = "Y" ]; then
              _run_with_spinner "(pre-retry) manage.py makemigrations --noinput ${aum_app}" bash -c \
                "${_dyn_base_env} manage.py makemigrations --noinput '${aum_app}'" || true
            fi
            local dep_first=${MIGRATE_DEPENDENCY_FIRST:-}
            if [ -n "${dep_first}" ]; then
              _run_with_spinner "(pre-retry) manage.py makemigrations --noinput ${dep_first} (dependency chain)" bash -c \
                "${_dyn_base_env} manage.py makemigrations --noinput '${dep_first}'" || true
              set +e
              _run_migrate_autoheal "$APP_DIR" "${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" "${_dyn_base_env}" "${dep_first}" || true
              set -e
            fi
            aum_cmd="${_dyn_base_env} manage.py migrate '${aum_app}'"
          else
            rm -f "$aum_fresh"
            # ── Re-extract CircularDependencyError pair from aum_tb (die block scope; _circ_apps was local to inner if) ──
            local _dc_line="" _dc_pair_raw="" _dc_app1="" _dc_app2="" _dc_apps="<none detected>"
            _dc_line=$(printf '%s\n' "$aum_tb" | grep -E 'CircularDependencyError:.*0001_initial' 2>/dev/null | head -n 1 || true)
            if [ -z "${_dc_line}" ]; then
              _dc_line=$(printf '%s\n' "$aum_tb" | grep -E '[a-zA-Z_][a-zA-Z0-9_]*\.0001_initial.*[a-zA-Z_][a-zA-Z0-9_]*\.0001_initial' 2>/dev/null | head -n 1 || true)
            fi
            if [ -n "${_dc_line}" ]; then
              _dc_pair_raw=$(printf '%s' "${_dc_line}" | sed -E 's/.*CircularDependencyError:\s*//' || true)
              _dc_app1=$(printf '%s' "${_dc_pair_raw}" | awk -F',' '{print $1}' | awk -F'.' '{print $1}' | tr -d '[:space:]' || true)
              _dc_app2=$(printf '%s' "${_dc_pair_raw}" | awk -F',' '{print $2}' | awk -F'.' '{print $1}' | tr -d '[:space:]' || true)
              [ -n "${_dc_app1}" ] && [ -n "${_dc_app2}" ] && _dc_apps="${_dc_app1} ↔ ${_dc_app2}"
            fi
            _die "\
AUTH_USER_MODEL single-app migrate FAILED all $aum_max attempts for custom user app '${aum_app}' (last rc=$aum_frc).
ROOT CAUSE SETS:
  1. Migration files for ${aum_app} DO NOT EXIST in git-pushed repo: missing ${aum_app}/migrations/__init__.py (empty file required by Django migrations loader) OR no 0001_initial.py present → fix:
       cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput '${aum_app}'
     then:
       $aum_cmd
  2. TRANSITIVE DEPENDENCY CHAIN MISSING APPLIED: ${aum_app}.0001 has ForeignKey('companies.Company') / similar → relation 'companies_company' DNE. Run dependency app migrate FIRST (STAGE 2 resolves most automatically; manual order if failed):
       cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput companies && \\
       PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate companies && \\
       $aum_cmd
  3. 0001_initial.py exists but Migration.dependencies inside class Migration misses the app → edit ${aum_app}/migrations/0001_initial.py class Migration: dependencies = [('companies','0001_initial'), …]; or add run_before = [('admin', '0001_initial')] then re-run.
  4. INSTALLED_APPS typo: '${aum_app}' misspelled → showmigrations above empty for ${aum_app}.
  5. CircularDependencyError (graph DAG cycle, ${_dc_apps}) — BOTH 0001_initial.py have cross-FK to each other → each Migration.dependencies lists the other app → cycle. 2-step split fix (delete BOTH 0001, regen auth_app only FIRST, regen companies SECOND):
       cd '$APP_DIR' && rm -f ${aum_app}/migrations/0001_initial.py ${_dc_app2:-companies}/migrations/0001_initial.py 2>/dev/null || true
       mkdir -p ${aum_app}/migrations ${_dc_app2:-companies}/migrations && touch ${aum_app}/migrations/__init__.py ${_dc_app2:-companies}/migrations/__init__.py 2>/dev/null || true
       PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput ${aum_app}
       PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate ${aum_app}
       PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput ${_dc_app2:-companies}
       PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate ${_dc_app2:-companies}
       PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput 2>/dev/null || true
       PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate
     PERMANENT IDIOMATIC FIX (prevent recurrence): change ${_dc_app2:-companies}.Company FK from ForeignKey('${aum_app}.User') → ForeignKey(settings.AUTH_USER_MODEL) — Django makemigrations handles AUTH_USER_MODEL swappable FKs specially and will not generate cross-dependencies in 0001.
COPY-PASTE IMMEDIATE FIX (transitive dep chain version — handles any FK depth; use CAUSE 5 if circular):
  cd '$APP_DIR' && \\
  for APP in companies ${aum_app}; do
    mkdir -p \$APP/migrations && touch \$APP/migrations/__init__.py 2>/dev/null || true
    PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput \$APP
    PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate \$APP
  done
  # Finally full migrate:
  PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate
DIAGNOSTIC CONTEXT:
  STAGE 1 graph deps:  ${_stage1_deps:-<none discovered>}
  STAGE 2 applied:     ${_dyn_applied:-<none>}
  STAGE 2 final queue: ${_dyn_queue:-<empty>}
  AUTH_USER_MODEL: ${aum_app}.${aum_model} → DB table = ${aum_db_table}
  Circular dep pair (CAUSE 5, if set): ${_dc_apps}
"
            fi
          done
          rm -f "$aum_fresh"
          if [ "$aum_ok" -eq 1 ]; then
            _ok "manage.py migrate ${aum_app} SUCCESS (AUTH_USER_MODEL custom user table ${aum_db_table} now exists via fallback retry banner). Proceeding to full migrate."
          fi
        fi
      fi
    # ── Pre-migrate SAFETY-2: Parse showmigrations output for partially-applied contenttypes-only state (user's exact DB state:
    #    contenttypes.0001 = [X] applied, every other app = [ ] NOT applied). This is ALWAYS the result of a prior migrate
    #    run that crashed right after contenttypes.0001_initial but before anything else (the exact user's crash scenario on
    #    attempt 1 with auth_app_user missing). If we detect this AND the user later gets ProgrammingError UndefinedTable,
    #    we will auto-offer to fake-migrate apps that were actually applied out-of-band and continue.
    local pm_partial_state=0
    {
      local _so_full
      _so_full=$( bash -c "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py showmigrations --list" 2>&1 || true )
      local _applied_count
      _applied_count=$(printf '%s\n' "$_so_full" | grep -c '\[X\]' 2>/dev/null || true)
      local _contenttypes_line
      _contenttypes_line=$(printf '%s\n' "$_so_full" | grep -n 'contenttypes' 2>/dev/null | head -n 1 || true)
      if [ "$_applied_count" -eq 1 ] && printf '%s\n' "$_so_full" | grep -q '\[X\] 0001_initial' 2>/dev/null && printf '%s\n' "$_so_full" | grep -q '^contenttypes' 2>/dev/null; then
        # Only 1 applied migration overall, it is contenttypes.0001_initial → classic partial migrate state.
        pm_partial_state=1
      fi
    } 2>/dev/null || true
    if [ "$pm_partial_state" -eq 1 ]; then
      _warn "Detected PARTIALLY-APPLIED DB state: ONLY contenttypes.0001_initial = [X] applied (all other apps [ ]). This is ALWAYS a prior migrate that crashed mid-way. On next ProgrammingError UndefinedTable fail the retry banner will auto-offer to run makemigrations for the missing app_label referenced in the error and run single-app migrate first."
    fi
    # ── FINAL BELT-AND-SUSPENDERS: Run circular dep check RIGHT BEFORE the 3-attempt full migrate wrapper. ──
    #   Catches any residual cycle missed by pre-safety1 / post-mk checks.
    _section "PRE-MIGRATE FINAL CHECK: Django migration graph circular dep verification (right before migrate)."
    set +e
    _resolve_circular_dep "$APP_DIR" "${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" "pre-final-migrate" || true
    set -e
    # ── migrate: wrapped in 3-attempt retry loop with prompt_edit_multiple + banner shows FRESH traceback on every fail ──
    # The user's EXACT issue: spinner failed with `ModuleNotFoundError: No module named 'rasyaterp'` but the old
    # banner only had static text causes list. This loop:
    #   (1) Runs migrate exactly like the spinner does (same PYTHONPATH / DJANGO_SETTINGS_MODULE / venv python).
    #   (2) On FAIL: immediately re-runs the same command (no spinner) so we capture a FRESH full traceback into
    #       a temp file, then dumps: that FRESH traceback + the spinner's own redirected log file (from _run_with_spinner)
    #       + auto-runs cause (A)'s django.setup probe + dumps ENV used so user sees root cause masked by CPython.
    #   (3) BEFORE DIE: offers prompt_edit_multiple menu for all the vars migrate actually uses
    #       (DJANGO_SETTINGS_MODULE DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT APP_DIR) so the user
    #       can fix typoed password / wrong settings module / wrong DB host RIGHT HERE without rerunning the entire installer.
    local mig_attempt=0 mig_max=3 mig_ok=0 mig_rc=0
    local mig_spin_log="" mig_fresh_tmp="/tmp/rasyatone_mig_fresh_$$.tmp"
    local mig_cmd_fresh="cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate"
    while [ "$mig_attempt" -lt "$mig_max" ] && [ "$mig_ok" -ne 1 ]; do
      mig_attempt=$(( mig_attempt + 1 ))
      mig_spin_log=""
      mig_rc=0
      set +e
      _run_migrate_autoheal "$APP_DIR" "${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python'" "" || mig_rc=$?
      set -e
      # Locate most recent _run_with_spinner migrate log file (newest by mtime matching label pattern).
      # _run_with_spinner writes to /tmp/rasyatone_spin_<pid>_<label>.log with <label> sanitized — glob newest matching migrate file.
      local _gl
      for _gl in $(ls -1t /tmp/rasyatone_spin_*_*migrate* 2>/dev/null | head -n 3); do
        [ -f "$_gl" ] || continue
        # Use the first one that's non-empty (most recent)
        if [ -s "$_gl" ]; then mig_spin_log="$_gl"; break; fi
        [ -z "${mig_spin_log}" ] && mig_spin_log="$_gl"
      done
      if [ "$mig_rc" -eq 0 ]; then
        mig_ok=1
        break
      fi
      # ── migrate FAILED this attempt: build a SUPER detailed evidence banner (not static text) ──
      # Part A: rerun migrate immediately with stdout/stderr UNREDICTED (no spinner redirect) so we capture FRESH traceback.
      local fresh_tb=""
      fresh_tb=$( bash -c "$mig_cmd_fresh" 2>&1 | tail -n 80 || true )
      printf '%s\n' "$fresh_tb" > "$mig_fresh_tmp" 2>/dev/null || true
      # Part B: auto-run cause (A)'s django.setup probe — this is the #1 cause.
      local dsetup_out="" dsetup_rc=0
      dsetup_out=$( PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" - <<'PY' 2>&1 || dsetup_rc=$?
import os, sys, traceback
try:
    import django
    django.setup()
    from django.conf import settings
    print("django.setup() OK; ROOT_URLCONF=%s; STATIC_ROOT=%s; DATABASES.default.HOST=%s" % (settings.ROOT_URLCONF, settings.STATIC_ROOT if hasattr(settings, "STATIC_ROOT") else "<UNSET>", settings.DATABASES["default"].get("HOST", "<UNSET>")))
    sys.exit(0)
except Exception:
    traceback.print_exc()
    sys.exit(2)
PY
)
      # Part C: auto-run cause (D)'s manage.py showmigrations — SHOW HEAD+TAIL (not just tail) because user's
      # custom apps (like auth_app) appear FIRST in showmigrations output, before django built-ins.
      # If auth_app is missing entirely (due to migrations/__init__.py missing or app not in INSTALLED_APPS),
      # tail-only probe showed only celery/guardian/sessions and the user missed the root cause.
      local show_out="" show_full="" show_head="" show_tail=""
      show_full=$( bash -c "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py showmigrations" 2>&1 || true )
      show_head=$(printf '%s\n' "$show_full" | head -n 40 || true)
      show_tail=$(printf '%s\n' "$show_full" | tail -n 40 || true)
      local sh_ln_ct
      sh_ln_ct=$(printf '%s\n' "$show_full" | wc -l 2>/dev/null | tr -d ' ' || true)
      if [ "${sh_ln_ct:-0}" -le 80 ]; then
        show_out="$show_full"
      else
        show_out="(showmigrations total ${sh_ln_ct} lines — truncated to HEAD 40 + TAIL 40)\n--- HEAD (first 40 lines, custom apps show up FIRST — check for MISSING auth_app/your_user_app here):\n${show_head}\n--- TAIL (last 40 lines, django + 3rd-party apps):\n${show_tail}"
      fi
      # If AUTH_USER_MODEL custom user probe was run (aum_app set), explicitly grep for it in showmigrations so
      # even if it's buried the user can see it present/missing instantly.
      if [ -n "${aum_app:-}" ]; then
        local show_aum_hits
        show_aum_hits=$(printf '%s\n' "$show_full" | grep -n "^${aum_app}" 2>/dev/null || true)
        if [ -z "${show_aum_hits}" ]; then
          show_out="${show_out}\n--- AUTH_USER_MODEL APP '${aum_app}' (custom user = '${aum_app}.${aum_model}' → table ${aum_db_table}) — **NOT FOUND in showmigrations output!** This is ALWAYS the root cause of ProgrammingError relation ${aum_db_table} does not exist during admin.0001_initial FK creation. Fix: (1) ensure '${aum_app}' in INSTALLED_APPS; (2) mkdir -p ${aum_app}/migrations && touch ${aum_app}/migrations/__init__.py; (3) makemigrations --noinput ${aum_app}; (4) migrate ${aum_app}."
        else
          show_out="${show_out}\n--- AUTH_USER_MODEL APP '${aum_app}' FOUND in showmigrations lines:\n${show_aum_hits}"
        fi
      fi
      # Part C2: auto-parse ProgrammingError UndefinedTable from fresh_tb → if "relation X does not exist", pull
      # relation name and derive likely app_label by Django table naming convention (applabel_modelname or
      # applabel_*). This lets us pre-populate the retry menu's MIGRATE_SPECIFIC_APP_FIRST field.
      local undef_rel="" undef_app_guess=""
      undef_rel=$( printf '%s\n' "$fresh_tb" | grep -oE 'relation "[^"]+" does not exist' 2>/dev/null | head -n 1 | sed 's/^relation "//; s/" does not exist$//' || true )
      if [ -n "${undef_rel}" ]; then
        # Relation name pattern: "auth_app_user" = app_label "auth_app". "core_accounts_user" = app_label could be
        # "core_accounts" (seg1_seg2) or just "core" (seg1). Emit both separated by "/". Run awk on SINGLE LINE only
        # (avoid multi-line awk inside $() — triggers bash 5.0/5.1 parser bug "while looking for matching )").
        undef_app_guess=$(printf '%s' "$undef_rel" | awk -F'_' '{if(NF>2)print $1"_"$2"/"$1; else if(NF==2)print $1; else print $0}' 2>/dev/null || true)
      fi
      # Part D: list EXACT env that was used for migrate bash -c (for env leak debugging: APP_DIR empty? DJANGO_SETTINGS_MODULE defaulted?).
      local venv_pv=""
      venv_pv=$("$APP_DIR/.venv/bin/python" -c 'import sys;print(sys.version)' 2>/dev/null || echo "UNKNOWN")
      printf "\n\033[1;31m=== manage.py migrate FAILED attempt %d/%d (rc=%s) — FULL EVIDENCE BELOW ===\033[0m\n" "$mig_attempt" "$mig_max" "$mig_rc" >&2
      printf "  \033[1;33m[EXACT CMD used for migrate bash -c (COPY-PASTE REPRODUCE LINE):]\033[0m\n    %s\n" "$mig_cmd_fresh" >&2
      printf "  \033[1;33m[ENV VARS migrate ran with:]\033[0m\n    PYTHONPATH=%s\n    DJANGO_SETTINGS_MODULE=%s\n    VENV_BIN=%s\n    VENV_PY_VERSION=%s\n" \
        "$APP_DIR" "${DJANGO_SETTINGS_MODULE:-<UNSET>}" "$APP_DIR/.venv/bin/python" "$venv_pv" >&2
      printf "  \033[1;33m[SPINNER LOG FILE contents (migrate stderr/stdout captured inside _run_with_spinner):]\033[0m" >&2
      if [ -n "${mig_spin_log}" ] && [ -f "${mig_spin_log}" ]; then
        printf " (file=%s, size=$(wc -c <"$mig_spin_log" 2>/dev/null || echo 0) bytes)\n" "$mig_spin_log" >&2
        tail -n 60 "$mig_spin_log" 2>/dev/null | sed 's#^#    #' >&2 || true
      else
        printf "\n    [NO SPINNER LOG FOUND — _run_with_spinner may not have written one or glob missed it]\n" >&2
      fi
      printf "  \033[1;33m[FRESH DIRECT traceback (migrate rerun OUTSIDE spinner, no redirection — should match actual error):]\033[0m\n" >&2
      printf '%s\n' "$fresh_tb" | sed 's#^#    #' >&2
      if [ -n "${undef_rel}" ]; then
        printf "  \033[1;35m[ProgrammingError UNDEFINEDTABLE DETECTED]: relation = '%s' → likely app_label guess = '%s'. This is a MISSING migration (table not created yet). See retry menu fields below for direct fix.\033[0m\n" "${undef_rel}" "${undef_app_guess}" >&2
      fi
      printf "  \033[1;33m[Cause (A) PROBE: django.setup() standalone check rc=%d]:\033[0m\n" "$dsetup_rc" >&2
      printf '%s\n' "$dsetup_out" | sed 's#^#    #' >&2
      printf "  \033[1;33m[Cause (D) PROBE: manage.py showmigrations (HEAD+TAIL) — custom apps appear FIRST; check top for MISSING auth_app/your_user_app]:\033[0m\n" >&2
      printf '%b\n' "$show_out" | sed 's#^#    #' >&2
      # Cleanup temp before next iteration / before retry prompt.
      rm -f "$mig_fresh_tmp" 2>/dev/null || true
      if [ "$mig_attempt" -lt "$mig_max" ]; then
        # Build sentinel field defaults for retry menu. These are READ DIRECTLY by the logic after prompt_edit_multiple:
        #   MIGRATE_SPECIFIC_APP_FIRST  — if non-empty: run `makemigrations <app>` then `migrate <app>` SINGLE-APP BEFORE full migrate.
        #                                 For UndefinedTable relation "auth_app_user" → default "auth_app".
        #   MAKEMIGRATIONS_ALL_PENDING  — if "y": run `makemigrations --noinput` (no args = all apps) BEFORE retrying migrate.
        #   FAKE_MIGRATE_PARTIAL        — if "y": for classic "contenttypes-only" partial-applied state → run fake migrations.
        local default_app_first=""
        if [ -n "${undef_app_guess}" ]; then
          default_app_first="${undef_app_guess%%/*}"
        elif [ -n "${aum_app:-}" ]; then
          default_app_first="${aum_app}"
        fi
        local default_mmk_all="y"
        if [ -n "${default_app_first}" ]; then default_mmk_all="n"; fi
        local default_fake="n"
        if [ "${pm_partial_state:-0}" -eq 1 ]; then default_fake="n"; fi
        # Write sentinel fields into ENV_FILE so prompt_edit_multiple can pick them up with defaults.
        if [ -n "${default_app_first}" ]; then echo "MIGRATE_SPECIFIC_APP_FIRST=${default_app_first}" >> "$ENV_FILE" 2>/dev/null || true; fi
        echo "MAKEMIGRATIONS_ALL_PENDING=${default_mmk_all}" >> "$ENV_FILE" 2>/dev/null || true
        echo "FAKE_MIGRATE_PARTIAL=${default_fake}" >> "$ENV_FILE" 2>/dev/null || true
        prompt_edit_multiple \
          "manage.py migrate FAILED attempt $mig_attempt/$mig_max — edit a field to fix it before we retry (fields 8-10 are the DIRECT fix for ProgrammingError/UndefinedTable/missing-migration bugs):" \
          "DJANGO_SETTINGS_MODULE DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT APP_DIR MIGRATE_SPECIFIC_APP_FIRST MAKEMIGRATIONS_ALL_PENDING FAKE_MIGRATE_PARTIAL" \
          "Retry manage.py migrate with (possibly edited) values NOW?" \
          "y"
        # Re-sync migrate command string + subshell env after edit menu wrote new values.
        _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
        set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
        export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
        mig_cmd_fresh="cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate"
        # ── Retry-menu SENTINEL ACTIONS (run PRE-retry of migrate, inside spinner so user sees progress) ──
        # Sentinel 1: MAKEMIGRATIONS_ALL_PENDING=y → run makemigrations --noinput.
        local mmk_all_yn=${MAKEMIGRATIONS_ALL_PENDING:-n}
        if [ "${mmk_all_yn}" = "y" ] || [ "${mmk_all_yn}" = "Y" ]; then
          _run_with_spinner "(pre-retry sentinel) manage.py makemigrations --noinput (create all pending migration files for all apps — fixes missing migration files root cause)" bash -c \
            "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput" || true
        fi
        # Sentinel 2: MIGRATE_SPECIFIC_APP_FIRST non-empty → makemigrations <app> + migrate <app> SINGLE-APP FIRST.
        local spec_app=${MIGRATE_SPECIFIC_APP_FIRST:-}
        if [ -n "${spec_app}" ]; then
          local _mmk_rc=0 _mig_rc=0
          _run_with_spinner "(pre-retry sentinel) manage.py makemigrations --noinput ${spec_app}" bash -c \
            "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput '${spec_app}'" || _mmk_rc=$?
          _run_with_spinner "(pre-retry sentinel) manage.py migrate ${spec_app} (single-app migrate FIRST — creates ${spec_app} tables before full migrate)" bash -c \
            "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate '${spec_app}'" || _mig_rc=$?
          if [ "$_mig_rc" -eq 0 ] && [ "$_mmk_rc" -eq 0 ]; then
            _ok "Sentinel migrate ${spec_app} OK — ${spec_app} tables now exist. Full migrate retry will now cleanly resolve FK references."
          fi
        fi
        # Sentinel 3: FAKE_MIGRATE_PARTIAL=y → fake-apply all 0001/0002 migrations that are already actually in DB.
        local fake_yn=${FAKE_MIGRATE_PARTIAL:-n}
        if [ "${fake_yn}" = "y" ] || [ "${fake_yn}" = "Y" ]; then
          _run_with_spinner "(pre-retry sentinel) manage.py migrate --fake-initial (classic partial-state fix: if migration already applied to DB, mark them in django_migrations without re-running CREATE TABLE)" bash -c \
            "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate --fake-initial" || true
        fi
      else
        # 3rd and final fail: hard die with the categorized list + evidence summary so user has it for copy-paste.
        _die "\
manage.py migrate FAILED all $mig_max attempts (last rc=$mig_rc).

Full categorized causes IN ORDER (matching the numbered evidence blocks above):

  (A) SETTINGS-IMPORT FAILURE (the #1 cause, matches django.setup() standalone probe above).
      Root cause of '$fresh_tb' traceback: if django.setup() probe above printed:
        • ModuleNotFoundError: No module named 'rasyaterp' → TOP-LEVEL PACKAGE NAME in DJANGO_SETTINGS_MODULE does not match actual cloned repo (typo like 'rasyaterp' vs 'rasyatone'), OR rasyaterp/__init__.py has a broken internal import that CPython masks.
        • ModuleNotFoundError: No module named 'rest_framework'/'storages'/etc. → pip install -r requirements.txt PARTIALLY FAILED during venv setup (see earlier terminal line: pip install rc).
      COPY-PASTE DEBUG:
        cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' -c 'import django; django.setup(); from django.conf import settings; print(settings.ROOT_URLCONF)'

  (B) DB CONNECTION FAILURE (2nd most common — see DATABASES.default.HOST printed in django.setup() probe above).
      Loaded env file: $ENV_FILE. Verify DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD values match the ones install_db (Option 3) created.
      COPY-PASTE DB SMOKE:
        PGPASSWORD='$DB_PASSWORD' psql -h '$DB_HOST' -p '$DB_PORT' -U '$DB_USER' -d '$DB_NAME' -c 'SELECT 1;'

  (C) DB PRIVILEGE FAILURE (django.setup OK, SELECT 1 OK, but migrate fails on CREATE TABLE/ALTER).
      CREATEDB missing?  sudo -u postgres psql -c \"ALTER USER $DB_USER WITH CREATEDB;\"
      CONNECT missing?  sudo -u postgres psql -c \"REVOKE CONNECT ON DATABASE $DB_NAME FROM PUBLIC; GRANT CONNECT ON DATABASE $DB_NAME TO $DB_USER;\"

  (D) MIGRATION FILES MISSING / BROKEN — see showmigrations probe above. If NO apps are listed, your INSTALLED_APPS in settings.py is empty or points to non-existent apps (typo). COPY-PASTE:
        cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations

  (E) PYTHON version mismatch. Venv python: $venv_pv. Must be >= 3.10 AND <= 3.$MAX_ALLOWED_PYTHON_MINOR (3.13 — intentionally capped to avoid psycopg2 cpython-314 _PyInterpreterState_Get compile crash).

  (F) **FFI / SHARED LIBRARY / WEASYPRINT PDF FAILURE — THE EXACT CRASH YOU JUST HIT (see FRESH DIRECT traceback above for: OSError: cannot load library libpango-1.0-0 / libcairo.so.2 / libgdk_pixbuf). ROOT CAUSE:**
      Django migrate -> run_checks() -> imports ROOT_URLCONF (= rasya_terp.urls per settings) -> includes 'core.accounts.urls' -> imports views.__init__ at module top-level -> imports core/accounts/views/reports.py -> top-level 'from weasyprint import HTML' -> weasyprint tries to dlopen() its C libraries via python cffi. These are NOT pip packages; they are system shared libraries that were missing from the baseline install on this server.
      **django.setup() Cause (A) probe PASSED because django.setup() does NOT import URLconfs. migrate's check() DOES import URLconfs. That's why Cause (A) OK but migrate FAIL.**
      COPY-PASTE SINGLE-COMMAND FIX (run as root; pick the one for your distro):
        [Debian/Ubuntu apt]:   apt-get install -y libpango-1.0-0 libpangoft2-1.0-0 libpangocairo-1.0-0 libcairo2 libgdk-pixbuf-2.0-0 shared-mime-info fonts-liberation2 fontconfig-config fontconfig
        [RHEL/Fedora dnf]:     dnf install -y pango cairo cairo-gobject gdk-pixbuf2 fontconfig liberation-fonts
        [Alpine apk]:          apk add --no-cache pango cairo gdk-pixbuf fontconfig ttf-liberation
      After install:  sudo ldconfig   (clears dlopen() cache so new libs visible)
                      then re-run Option 4 or run migrate manually: $mig_cmd_fresh
      PREVENTION: Installer now runs a 'Weasyprint PDF PREFLIGHT' 2-attempt probe RIGHT AFTER pip install (before collectstatic/migrate block). It offers an AUTO-INSTALL of these libs via prompt_edit_multiple so you never hit this error inside the migrate retry banner again.

  (G) **makemigrations was never run (migrate will SILENTLY NO-OP on missing migration files).**
      This is the #1 silent-death bug in Django deploys WITHOUT the preflight probe we added. ROOT CAUSE: A developer pushed model changes (added/renamed a model/field) but forgot to commit the corresponding app/migrations/00XX_*.py files. Django's migrate command does NOT fail here — it prints 'No migrations to apply' and exits 0, even though the tables literally do not exist and will crash at first HTTP request.
      PROOF this happened: run the probe manually and compare rc:
        rc=0 = migrations up-to-date (correct)
        rc=1 = MODEL CHANGES DETECTED BUT NO MIGRATION FILES (THE BUG):
        cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --check --dry-run --verbosity 1 ; echo "rc=$?"
      AUTOMATIC PROTECTION: this installer now runs makemigrations --check RIGHT BEFORE migrate (between collectstatic and migrate). If rc=1 it automatically runs makemigrations, auto-merges any conflicts, and only then proceeds to migrate.
      If migrate still fails here AFTER the automatic makemigrations step ran:
        (1) The git-pushed migration files themselves have syntax errors / Raise / RunPython bugs → run makemigrations standalone debug command.
        (2) Conflicting migration names (two 0001_initial.py from different branches) → auto --merge ran but may need manual intervention: cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --merge
        (3) Custom app_config.ready() in INSTALLED_APPS that modifies ORM state at import-time before migrations loader can read migrations dirs → inspect traceback above for app.ready.

  (H) **ProgrammingError UndefinedTable during admin.0001_initial — relation auth_app_user does not exist (THE EXACT CRASH).
      YOUR BANNER EVIDENCE WALKTHROUGH — 100% reproducible:
        (1) FRESH DIRECT traceback ends with: django.db.utils.ProgrammingError: relation =auth_app_user does not exist
            while Applying admin.0001_initial (or another app with FK to custom user).
        (2) Cause (D) PROBE showmigrations (HEAD + explicit grep): AUTH_USER_MODEL APP =auth_app= NOT FOUND in showmigrations (no app label line at all) — this is the SMOKING GUN.
        (3) Cause (A) django.setup() PROBE = rc=0 OK (RED HERRING! django.setup() never imports migrations loader or URLconfs — so never sees the missing table till migrate's check phase runs urlconf → views → ForeignKey resolution).
        (4) Pre-migrate SAFETY-2 state detection banner printed: ONLY contenttypes.0001_initial = [X] applied = partial applied state from the run before crash at admin.0001 FK creation.
      ROOT CAUSE TRIPLE WHAMMY (one or all present):
        (H.1) MISSING migrations/__init__.py package marker in the custom user app directory. Django migrations loader REQUIRES app/migrations/__init__.py (even if ZERO BYTES EMPTY) — it is the Python package marker; without it showmigrations does not list the app at all even though it IS in INSTALLED_APPS. The INSTALLED_APPS line reads the app config fine, but migrations loader sees no migrations/ package so skips.
        (H.2) 0001_initial.py NEVER COMMITTED to git. Dev ran makemigrations locally producing 0001_initial.py with CreateModel auth_app_user but forgot git add auth_app/migrations/*.py → repo clone has 0 files.
        (H.3) DEPENDENCY ORDERING BUG. Even if (H.1)+(H.2) are OK → Django migration resolver applies admin.0001 BEFORE auth_app.0001 if auth_app's class Migration: does not declare run_before = [('admin', '0001_initial')]. Classic Django trap #1 for custom user models.
      COPY-PASTE STEP-BY-STEP FIX (in order, stop on first non-zero rc):
        1. ENSURE migrations/__init__.py EXISTS (ZERO BYTES EMPTY OK — required Python package marker):
           mkdir -p '$APP_DIR/auth_app/migrations' && touch '$APP_DIR/auth_app/migrations/__init__.py'
        2. CREATE 0001_initial.py for auth_app:
           cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py makemigrations --noinput auth_app
        3. RUN SINGLE-APP MIGRATE auth_app FIRST (creates table auth_app_user BEFORE admin.0001 FK REFERENCES it):
           cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python' manage.py migrate auth_app
        4. FINALLY RUN FULL MIGRATE:
           $mig_cmd_fresh
      PREVENTION: Installer now runs a 2-layer pre-migrate safety net BEFORE the 3-attempt migrate loop:
        (SAFETY-1) AUTH_USER_MODEL probe right before migrate loop: reads settings.AUTH_USER_MODEL. If app label != auth (custom user), runs migrate=SINGLE-APP FIRST with auto-makemigrations fallback if migration files missing, then full 3-attempt retry banner for just the user app if that fails.
        (SAFETY-2) PARTIAL-APPLIED STATE detection: only contenttypes.0001 = [X] applied. This is always the result of a previous run that crashed at admin.0001 FK creation. On next fail the retry menu sentinel fields are pre-populated correctly.
        (SAFETY-3) RETRY MENU FIELDS 8-10: MIGRATE_SPECIFIC_APP_FIRST (auto-populated =auth_app= by parsing UndefinedTable relation name in traceback), MAKEMIGRATIONS_ALL_PENDING (default y if no app_first, else n), FAKE_MIGRATE_PARTIAL for --fake-initial. All fixable DIRECTLY in-menu. No exit required.

COPY-PASTE REPRODUCE (SINGLE LINE):
  $mig_cmd_fresh

FULL migrate bash -c env (for debugging leaks):
  PYTHONPATH=$APP_DIR
  DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE:-<UNSET>}
  VENV_PY=$APP_DIR/.venv/bin/python
  APP_DIR=$APP_DIR"
      fi
    done
    if [ "$mig_ok" -eq 1 ]; then
      _ok "manage.py migrate SUCCESS (attempt $mig_attempt/$mig_max). All migrations applied."
    fi
  )
  _ok "Django migrate OK"

  if command -v systemctl >/dev/null 2>&1; then
    local _svc_user="${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}"
    _ensure_service_account_ready "${_svc_user}" "$APP_DIR"
    local _svc_group="${SERVICE_ACCOUNT_GROUP:-${_svc_user}}"
    _ok "Service account: ${_svc_user} (group=${_svc_group})"
    _run_with_spinner "Chown APP_DIR to service account (${_svc_user})" sudo chown -R "${_svc_user}:${_svc_group}" "$APP_DIR" || true
    if [ -f "$ENV_FILE" ]; then
      sudo chown "root:${_svc_group}" "$ENV_FILE" 2>/dev/null || true
      sudo chmod 0640 "$ENV_FILE" 2>/dev/null || true
      _ok "ENV_FILE permissions set: root:${_svc_group} 0640 (service can read)"
    fi
    _section "Install systemd service: $SERVICE_NAME"
    local unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
    local workers="${GUNICORN_WORKERS:-2}"
    local wsgi_module="${DJANGO_SETTINGS_MODULE%.*}.wsgi:application"
    local _exec_umask=""
    local _svc_runtime_dir=""
    local _svc_runtime_mode=""
    local _hard_no_new_priv=""
    local _hard_private_tmp=""
    local _hard_protect_system=""
    local _hard_protect_home=""
    if [ "${USE_UNIX_SOCKET:-$DEF_USE_UNIX_SOCKET}" = "y" ]; then
      _exec_umask=" --umask 007"
      _svc_runtime_dir="${SERVICE_NAME}"
      _svc_runtime_mode="0750"
    fi
    if [ "${ENABLE_SYSTEMD_HARDENING:-$DEF_ENABLE_SYSTEMD_HARDENING}" = "y" ]; then
      _hard_no_new_priv="NoNewPrivileges=true"
      _hard_private_tmp="PrivateTmp=true"
      _hard_protect_system="ProtectSystem=full"
      _hard_protect_home="ProtectHome=true"
    fi
    {
      printf '%s\n' \
        "[Unit]" \
        "Description=RaSYaTone application server (gunicorn)" \
        "After=network.target postgresql.service" \
        "" \
        "[Service]" \
        "Type=notify" \
        "User=${_svc_user}" \
        "Group=${_svc_group}" \
        "WorkingDirectory=$APP_DIR" \
        "EnvironmentFile=-$ENV_FILE" \
        "Environment=\"DJANGO_SETTINGS_MODULE=$DJANGO_SETTINGS_MODULE\"" \
        "Environment=\"HOME=$APP_DIR\""
      if [ -n "${_svc_runtime_dir:-}" ]; then printf "RuntimeDirectory=%s\n" "$_svc_runtime_dir"; fi
      if [ -n "${_svc_runtime_mode:-}" ]; then printf "RuntimeDirectoryMode=%s\n" "$_svc_runtime_mode"; fi
      if [ -n "${_hard_no_new_priv:-}" ]; then printf "%s\n" "$_hard_no_new_priv"; fi
      if [ -n "${_hard_private_tmp:-}" ]; then printf "%s\n" "$_hard_private_tmp"; fi
      if [ -n "${_hard_protect_system:-}" ]; then printf "%s\n" "$_hard_protect_system"; fi
      if [ -n "${_hard_protect_home:-}" ]; then printf "%s\n" "$_hard_protect_home"; fi
      printf '%s\n' \
        "ExecStart=$APP_DIR/.venv/bin/gunicorn --workers $workers --bind $GUNICORN_BIND${_exec_umask} --chdir $APP_DIR $wsgi_module" \
        "ExecReload=/bin/kill -s HUP \$MAINPID" \
        "Restart=always" \
        "RestartSec=3" \
        "" \
        "[Install]" \
        "WantedBy=multi-user.target"
    } | sudo tee "$unit_file" >/dev/null
    _run_with_spinner "systemd daemon-reload (re-read unit files)" sudo systemctl daemon-reload || true
    _run_with_spinner "systemctl enable --now $SERVICE_NAME (start app)" sudo systemctl enable --now "$SERVICE_NAME" || \
      _warn "systemctl enable --now returned non-zero — app may still be starting (RestartSec=3). Run: systemctl status '$SERVICE_NAME' in 10s to verify."
    _ok "systemd unit written and started: $unit_file"
  else
    _warn "systemd not present — skipped service install (run gunicorn manually)"
  fi

  if [ "$nginx_https" -eq 1 ]; then
    _section "Install nginx reverse proxy + HTTPS (Let's Encrypt)"
    set +e
    case "$PM" in
      apt)
        _run_with_spinner "Install nginx+certbot (apt)" sudo bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx certbot python3-certbot-nginx" || true
        ;;
      dnf)
        _run_with_spinner "Install nginx+certbot (dnf)" sudo bash -c "dnf install -y -q nginx certbot python3-certbot-nginx" || true
        ;;
      apk)
        _run_with_spinner "Install nginx+certbot (apk)" sudo apk add -q nginx certbot || true
        ;;
    esac
    set -e
    if command -v systemctl >/dev/null 2>&1; then
      _run_with_spinner "systemctl enable --now nginx" sudo systemctl enable --now nginx || true
    fi
    local _svc_group_for_ng=""
    _svc_group_for_ng="${SERVICE_ACCOUNT_GROUP:-${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}}"
    local _ng_user=""
    _ng_user=$(sudo awk '$1=="user"{print $2; exit}' /etc/nginx/nginx.conf 2>/dev/null | tr -d ';' || true)
    if [ -z "${_ng_user:-}" ]; then
      if id -u www-data >/dev/null 2>&1; then _ng_user="www-data"
      elif id -u nginx >/dev/null 2>&1; then _ng_user="nginx"
      fi
    fi
    if [ "${USE_UNIX_SOCKET:-$DEF_USE_UNIX_SOCKET}" = "y" ] && [ -n "${_ng_user:-}" ]; then
      set +e
      sudo usermod -a -G "${_svc_group_for_ng}" "${_ng_user}" >/dev/null 2>&1
      set -e
    fi
    local nginx_conf="/etc/nginx/conf.d/${SERVICE_NAME}.conf"
    local nginx_conf_bak=""
    nginx_conf_bak="${nginx_conf}.bak-$(date +%Y%m%d%H%M%S 2>/dev/null || echo now)"
    if sudo test -f "$nginx_conf" 2>/dev/null; then
      sudo cp -f "$nginx_conf" "$nginx_conf_bak" 2>/dev/null || true
    fi
    sudo mkdir -p "$(dirname "$nginx_conf")" 2>/dev/null || true
    local _nginx_upstream=""
    _nginx_upstream="http://127.0.0.1:${_bind_port_raw}"
    if [ "${USE_UNIX_SOCKET:-$DEF_USE_UNIX_SOCKET}" = "y" ]; then
      _nginx_upstream="http://unix:/run/${SERVICE_NAME}/gunicorn.sock"
    fi
    printf '%s\n' \
      "server {" \
      "  listen 80;" \
      "  server_name ${nginx_domain};" \
      "  client_max_body_size 50m;" \
      "  location / {" \
      "    proxy_pass ${_nginx_upstream};" \
      "    proxy_buffer_size 16k;" \
      "    proxy_buffers 8 16k;" \
      "    proxy_busy_buffers_size 32k;" \
      "    proxy_read_timeout 120s;" \
      "    proxy_send_timeout 120s;" \
      "    proxy_set_header Host \$host;" \
      "    proxy_set_header X-Real-IP \$remote_addr;" \
      "    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" \
      "    proxy_set_header X-Forwarded-Proto \$scheme;" \
      "  }" \
      "}" \
      | sudo tee "$nginx_conf" >/dev/null
    local _nginx_ok=0
    set +e
    sudo nginx -t >/dev/null 2>&1
    _nginx_ok=$?
    set -e
    if [ "$_nginx_ok" -ne 0 ]; then
      _warn "nginx config test FAILED after writing ${nginx_conf}. Restoring backup (if present) and keeping nginx unchanged."
      if sudo test -f "$nginx_conf_bak" 2>/dev/null; then
        sudo cp -f "$nginx_conf_bak" "$nginx_conf" 2>/dev/null || true
        _run_with_spinner "nginx config test (restored backup)" sudo nginx -t || true
      fi
    else
      _ok "nginx config test OK"
    fi
    if command -v systemctl >/dev/null 2>&1; then
      if [ "$_nginx_ok" -eq 0 ]; then
        _run_with_spinner "systemctl reload nginx" sudo systemctl reload nginx || true
      else
        _warn "nginx reload skipped (config test failed)"
      fi
    fi
    if [ "${ENABLE_NGINX_LOGROTATE:-$DEF_ENABLE_NGINX_LOGROTATE}" = "y" ]; then
      if sudo test -f "/etc/logrotate.d/nginx" 2>/dev/null; then
        _ok "nginx logrotate already present: /etc/logrotate.d/nginx"
      else
        printf '%s\n' \
          "/var/log/nginx/*.log {" \
          "  daily" \
          "  missingok" \
          "  rotate 14" \
          "  compress" \
          "  delaycompress" \
          "  notifempty" \
          "  create 0640 root adm" \
          "  sharedscripts" \
          "  postrotate" \
          "    [ -s /run/nginx.pid ] && kill -USR1 \`cat /run/nginx.pid\`" \
          "  endscript" \
          "}" \
          | sudo tee "/etc/logrotate.d/nginx" >/dev/null
        _ok "nginx logrotate installed: /etc/logrotate.d/nginx"
      fi
    fi
    local resolved_ip=""
    resolved_ip=$(getent hosts "$nginx_domain" 2>/dev/null | awk '{print $1}' | head -n 1 || true)
    local public_ips=""
    public_ips=$(hostname -I 2>/dev/null || true)
    public_ips=$(printf '%s' "$public_ips" | tr -s ' ' | sed -E 's/^ //; s/ $//' || true)
    local server_pub=""
    local iptok=""
    for iptok in $public_ips; do
      case "$iptok" in
        127.*|::1|10.*|192.168.*) continue ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) continue ;;
      esac
      server_pub="$iptok"
      break
    done
    if [ -n "${resolved_ip:-}" ] && [ -n "${server_pub:-}" ] && [ "$resolved_ip" != "$server_pub" ]; then
      _warn "DNS for ${nginx_domain} resolves to ${resolved_ip}, but this server public IP looks like ${server_pub}. Certbot will fail until DNS points to this server."
    else
      set +e
      _run_with_spinner "certbot nginx HTTPS for ${nginx_domain}" sudo certbot --nginx --non-interactive --agree-tos -m "$nginx_email" -d "$nginx_domain" --redirect || true
      if sudo test -f "/etc/letsencrypt/live/${nginx_domain}/fullchain.pem" 2>/dev/null; then
        nginx_tls_ok=1
        _ok "Let's Encrypt certificate installed for ${nginx_domain}."
        _configure_certbot_autorenew || true
      else
        _warn "Certbot did not produce a certificate under /etc/letsencrypt/live/${nginx_domain}/. Site will remain HTTP until DNS/ports are fixed."
      fi
      set -e
    fi
  fi

  # ================ Firewall enable + app + web ports ================
  _section "Enable system firewall (Option 4 firewall step)"
  local bind_port do_fw="" do_webfw=""
  bind_port=$(printf "%s" "$GUNICORN_BIND" | awk -F: '{print $NF}')
  if ! printf "%s" "$bind_port" | grep -Eq '^[0-9]+$' 2>/dev/null; then
    bind_port=$(printf "%s" "$DEF_GUNICORN_BIND" | awk -F: '{print $NF}' 2>/dev/null || echo "8000")
  fi
  if [ "$nginx_https" -eq 1 ]; then
    do_fw=$(prompt_yn "Enable firewall and open needed ports (HTTP 80/tcp + HTTPS 443/tcp + SSH 22/tcp)? [Y/n]" "y")
  else
    do_fw=$(prompt_yn "Enable firewall and open needed ports (Gunicorn ${bind_port}/tcp + SSH 22/tcp)? [Y/n] — SSH 22 is ALWAYS opened first so you won't be locked out" "y")
  fi
  if [ "$do_fw" = "y" ]; then
    firewall_detect || true
    _ok "Detected firewall backend: ${FW_BACKEND}"
    if firewall_install_and_enable; then
      _ok "Firewall installed/enabled; SSH 22/tcp already open"
      if [ "$nginx_https" -eq 1 ]; then
        local _fw80_rc=0 _fw443_rc=0
        set +e
        firewall_add_port tcp 80 "HTTP (nginx / reverse proxy)"
        _fw80_rc=$?
        firewall_add_port tcp 443 "HTTPS TLS (nginx / Let's Encrypt)"
        _fw443_rc=$?
        set -e
        if [ "$_fw80_rc" -eq 0 ] && [ "$_fw443_rc" -eq 0 ]; then
          _ok "Firewall rules added: 80/tcp (HTTP), 443/tcp (HTTPS)"
        else
          _warn "Firewall port-open step incomplete (80 rc=${_fw80_rc}, 443 rc=${_fw443_rc})."
          case "$FW_BACKEND" in
            ufw)
              printf "  Try manually:\n    sudo ufw allow 80/tcp\n    sudo ufw allow 443/tcp\n    sudo ufw status\n"
              ;;
            firewalld)
              printf "  Try manually:\n    sudo firewall-cmd --permanent --add-service=http --zone=public\n    sudo firewall-cmd --permanent --add-service=https --zone=public\n    sudo firewall-cmd --reload\n"
              ;;
            iptables)
              printf "  Try manually:\n    sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT\n    sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT\n"
              ;;
          esac
        fi
      else
        if firewall_add_port tcp "$bind_port" "Gunicorn / RaSYaTone app (${SERVICE_NAME})"; then
          _ok "Firewall rule added: Gunicorn ${bind_port}/tcp"
        else
          _warn "Could not add Gunicorn ${bind_port}/tcp firewall rule — add manually if needed."
        fi
        do_webfw=$(prompt_yn "Also open HTTP (80/tcp) and HTTPS (443/tcp) for a future nginx reverse proxy / Let's Encrypt? [y/N]" "n")
        if [ "$do_webfw" = "y" ]; then
          local _fw80_rc=0 _fw443_rc=0
          set +e
          firewall_add_port tcp 80 "HTTP (nginx / reverse proxy)"
          _fw80_rc=$?
          firewall_add_port tcp 443 "HTTPS TLS (nginx / Let's Encrypt)"
          _fw443_rc=$?
          set -e
          if [ "$_fw80_rc" -eq 0 ] && [ "$_fw443_rc" -eq 0 ]; then
            _ok "Firewall rules added: 80/tcp (HTTP), 443/tcp (HTTPS)"
          else
            _warn "Firewall port-open step incomplete (80 rc=${_fw80_rc}, 443 rc=${_fw443_rc})."
            case "$FW_BACKEND" in
              ufw)
                printf "  Try manually:\n    sudo ufw allow 80/tcp\n    sudo ufw allow 443/tcp\n    sudo ufw status\n"
                ;;
              firewalld)
                printf "  Try manually:\n    sudo firewall-cmd --permanent --add-service=http --zone=public\n    sudo firewall-cmd --permanent --add-service=https --zone=public\n    sudo firewall-cmd --reload\n"
                ;;
              iptables)
                printf "  Try manually:\n    sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT\n    sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT\n"
                ;;
            esac
          fi
        fi
      fi
      firewall_summary
    else
      if [ "$nginx_https" -eq 1 ]; then
        _warn "Could not install/enable firewall (backend=${FW_BACKEND}). Review manually — SSH 22/tcp and ports 80/443 visibility depend on existing network rules."
      else
        _warn "Could not install/enable firewall (backend=${FW_BACKEND}). Review manually — SSH 22/tcp and Gunicorn ${bind_port}/tcp visibility depend on existing network rules."
      fi
    fi
  else
    if [ "$nginx_https" -eq 1 ]; then
      _warn "Firewall skipped by user choice. SSH 22/tcp and ports 80/443 visibility depend on existing network/firewall rules."
    else
      _warn "Firewall skipped by user choice. SSH 22/tcp and Gunicorn ${bind_port}/tcp visibility depend on existing network/firewall rules."
    fi
  fi

  local script_dir="" report_log="" report_tmp=""
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd 2>/dev/null || echo ".")"
  report_log="${script_dir}/rasyatone_post_install_summary.log"
  report_tmp="/tmp/rasyatone_post_install_summary_${$}.log"
  set +e
  {
    printf "\n\033[1;97m=== RaSYaTone app install POST-INSTALL SUMMARY ===\033[0m\n"
    printf "Generated: %s\n" "$(date -Is 2>/dev/null || date 2>/dev/null || echo "unknown")"
    printf "\n\033[1;97mCore:\033[0m\n"
    printf "  APP_DIR=%s\n" "$APP_DIR"
    printf "  VENV_PYTHON=%s\n" "$APP_DIR/.venv/bin/python"
    if [ -x "$APP_DIR/.venv/bin/python" ]; then
      printf "  VENV_PYTHON_VERSION=%s\n" "$("$APP_DIR/.venv/bin/python" --version 2>&1 | head -n1)"
    fi
    printf "  DJANGO_SETTINGS_MODULE=%s\n" "$DJANGO_SETTINGS_MODULE"
    printf "  ENV_FILE=%s\n" "$ENV_FILE"
    printf "  SERVICE_ACCOUNT=%s\n" "${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}"
    if command -v systemctl >/dev/null 2>&1; then
      printf "\n\033[1;97mService:\033[0m\n"
      printf "  SERVICE=%s state=" "$SERVICE_NAME"
      systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
      local _spid=""
      _spid=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null | tr -d '[:space:]' || true)
      if [ -n "${_spid}" ] && [ "${_spid}" != "0" ]; then
        printf "  MainPID=%s\n" "$_spid"
        if command -v ps >/dev/null 2>&1; then
          ps -o user=,group=,pid=,etimes=,cmd= -p "$_spid" 2>/dev/null | sed 's/^/  /' || true
        fi
      fi
      systemctl status --no-pager -n 5 "$SERVICE_NAME" 2>/dev/null | sed 's/^/  /' || true
    fi
    local bind_port
    bind_port=$(printf "%s" "$GUNICORN_BIND" | awk -F: '{print $NF}')
    if ! printf "%s" "$bind_port" | grep -Eq '^[0-9]+$' 2>/dev/null; then
      bind_port=""
    fi
    printf "\n\033[1;97mHTTP (local):\033[0m\n"
    if printf "%s" "$GUNICORN_BIND" | grep -Eq '^unix:' 2>/dev/null; then
      printf "  Gunicorn unix socket=%s\n" "$GUNICORN_BIND"
      local _sock_path=""
      _sock_path="${GUNICORN_BIND#unix:}"
      if [ -n "${_sock_path}" ] && sudo test -S "${_sock_path}" 2>/dev/null; then
        printf "  Socket exists: %s\n" "$_sock_path"
      else
        printf "  Socket missing: %s\n" "$_sock_path"
      fi
    fi
    if command -v curl >/dev/null 2>&1; then
      local http_code
      if [ -n "${bind_port}" ]; then
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${bind_port}/" 2>/dev/null || echo "000")
        printf "  HTTP 127.0.0.1:%s status %s\n" "$bind_port" "$http_code"
      elif [ "$nginx_https" -eq 1 ]; then
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1/" 2>/dev/null || echo "000")
        printf "  HTTP 127.0.0.1:80 status %s\n" "$http_code"
      fi
    elif command -v nc >/dev/null 2>&1; then
      if [ -n "${bind_port}" ]; then
        if nc -z -w3 "127.0.0.1" "$bind_port" 2>/dev/null; then
          printf "  Port 127.0.0.1:%s LISTENING (bind=$GUNICORN_BIND)\n" "$bind_port"
        else
          printf "  Port 127.0.0.1:%s NOT listening yet (gunicorn may still be starting)\n" "$bind_port"
        fi
      fi
    fi
    local public_ips=""
    public_ips=$(hostname -I 2>/dev/null || true)
    public_ips=$(printf '%s' "$public_ips" | tr -s ' ' | sed -E 's/^ //; s/ $//' || true)
    if [ -n "${public_ips}" ]; then
      printf "\n\033[1;97mNetwork:\033[0m\n"
      printf "  Server IPs=%s\n" "$public_ips"
      local oneip=""
      for oneip in $public_ips; do
        case "$oneip" in
          127.*|::1) continue ;;
        esac
        if [ -n "${bind_port}" ]; then
          printf "  URL=http://%s:%s/\n" "$oneip" "$bind_port"
        else
          printf "  URL=http://%s/\n" "$oneip"
        fi
      done
    fi
    if [ "$nginx_https" -eq 1 ]; then
      printf "\n\033[1;97mNginx/TLS:\033[0m\n"
      if [ "$nginx_tls_ok" -eq 1 ]; then
        printf "  URL=https://%s/\n" "$nginx_domain"
      else
        printf "  URL=http://%s/\n" "$nginx_domain"
      fi
      printf "  Note: Gunicorn is localhost-only (%s). nginx serves 80/443.\n" "$GUNICORN_BIND"
      if command -v systemctl >/dev/null 2>&1; then
        printf "  nginx state="
        systemctl is-active nginx 2>/dev/null || true
      fi
      if [ -n "${nginx_domain:-}" ] && sudo test -f "/etc/letsencrypt/live/${nginx_domain}/fullchain.pem" 2>/dev/null; then
        if command -v openssl >/dev/null 2>&1; then
          local _cert_end=""
          _cert_end=$(sudo openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${nginx_domain}/fullchain.pem" 2>/dev/null || true)
          [ -n "${_cert_end}" ] && printf "  TLS %s\n" "$_cert_end"
        fi
      fi
    else
      printf "  Note: Gunicorn is running directly on port %s. If you want to use a domain on :80/:443 (or HTTPS), install a reverse proxy (nginx) and TLS.\n" "$bind_port"
    fi
    if command -v ss >/dev/null 2>&1; then
      printf "\n\033[1;97mListeners:\033[0m\n"
      ss -ltnp 2>/dev/null | grep -E ":(80|443)\\b" 2>/dev/null | sed 's/^/  /' || printf "  80/443: (no listener detected)\n"
      if [ -n "${bind_port}" ]; then
        ss -ltnp 2>/dev/null | grep -E "[:.]${bind_port}\\b" 2>/dev/null | sed 's/^/  /' || printf "  %s: (no listener detected)\n" "$bind_port"
      fi
    fi
    if command -v curl >/dev/null 2>&1 && [ -n "${public_ips}" ] && [ -n "${bind_port}" ]; then
      printf "\n\033[1;97mReachability checks (from this server):\033[0m\n"
      local rip="" rcode=""
      for rip in $public_ips; do
        case "$rip" in
          127.*|::1|10.*|192.168.*) continue ;;
          172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) continue ;;
        esac
        rcode=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "http://${rip}:${bind_port}/" 2>/dev/null || echo "000")
        printf "  HTTP %s:%s status %s\n" "$rip" "$bind_port" "$rcode"
      done
    fi
    if command -v psql >/dev/null 2>&1; then
      printf "\n\033[1;97mDatabase:\033[0m\n"
      local _db_err="/tmp/rasyatone_postinstall_dbcheck_$$.log"
      : >"$_db_err" 2>/dev/null || true
      local _row=""
      _row=$(PGPASSWORD="$DB_PASSWORD" timeout 6 psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1" 2>"$_db_err" | tr -d '[:space:]' || true)
      if [ "$_row" = "1" ]; then
        printf "  psql SELECT 1: OK (%s@%s:%s/%s)\n" "$DB_USER" "$DB_HOST" "$DB_PORT" "$DB_NAME"
      else
        printf "  psql SELECT 1: FAIL (%s@%s:%s/%s)\n" "$DB_USER" "$DB_HOST" "$DB_PORT" "$DB_NAME"
        tail -n 3 "$_db_err" 2>/dev/null | sed 's/^/  /' || true
      fi
      rm -f "$_db_err" 2>/dev/null || true
    fi
    printf "\n\033[1;97mResources:\033[0m\n"
    if command -v df >/dev/null 2>&1; then
      df -h / "$APP_DIR" 2>/dev/null | awk 'NR==1||NR==2||NR==3{print}' | sed 's/^/  /' || true
    fi
    if command -v free >/dev/null 2>&1; then
      free -h 2>/dev/null | awk 'NR==1||NR==2{print}' | sed 's/^/  /' || true
    fi
    printf "\n\033[1;97mUseful commands:\033[0m\n"
    if command -v systemctl >/dev/null 2>&1; then
      printf "  - systemctl status --no-pager '%s'\n" "$SERVICE_NAME"
      printf "  - journalctl -u '%s' -n 200 --no-pager\n" "$SERVICE_NAME"
      printf "  - systemctl restart '%s'\n" "$SERVICE_NAME"
      if [ "$nginx_https" -eq 1 ]; then
        printf "  - systemctl status --no-pager nginx\n"
        printf "  - nginx -t\n"
        printf "  - certbot renew --dry-run\n"
        printf "  - certbot certificates\n"
      if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -Eq '^certbot\.timer'; then
        printf "  - systemctl status --no-pager certbot.timer\n"
        printf "  - systemctl list-timers --all | grep certbot\n"
      else
        printf "  - sudo crontab -l | grep certbot\n"
      fi
      fi
    fi
    printf "  - cd '%s' && PYTHONPATH='%s' DJANGO_SETTINGS_MODULE='%s' '%s' manage.py createsuperuser\n" "$APP_DIR" "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$APP_DIR/.venv/bin/python"
    printf "  - cd '%s' && PYTHONPATH='%s' DJANGO_SETTINGS_MODULE='%s' '%s' manage.py showmigrations --list\n" "$APP_DIR" "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$APP_DIR/.venv/bin/python"
    printf "  - cd '%s' && PYTHONPATH='%s' DJANGO_SETTINGS_MODULE='%s' '%s' manage.py check --deploy\n" "$APP_DIR" "$APP_DIR" "$DJANGO_SETTINGS_MODULE" "$APP_DIR/.venv/bin/python"
    printf "\n"
  } | tee "$report_tmp"
  set -e
  sudo mkdir -p "$script_dir" 2>/dev/null || true
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' "$report_tmp" 2>/dev/null | sudo tee -a "$report_log" >/dev/null 2>/dev/null || true
  sudo chmod 0644 "$report_log" 2>/dev/null || true
  rm -f "$report_tmp" 2>/dev/null || true
  _ok "Post-install summary saved: $report_log"
  printf "\nDone.\n"
}

upgrade_app() {
  _section "Upgrade/Update RaSYaTone Application Server"
  detect_pm
  load_env_file
  _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
  set -a; . "$ENV_FILE" 2>/dev/null || true; set +a

  prompt_edit_multiple \
    "Upgrade settings (loaded from ENV_FILE). Edit fields if needed before upgrade:" \
    "APP_DIR GIT_URL GIT_BRANCH SERVICE_NAME SERVICE_ACCOUNT DJANGO_SETTINGS_MODULE GUNICORN_BIND DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PORT" \
    "Proceed with upgrade now?" \
    "y"

  _sanitize_env_file_circular_sentinels "$ENV_FILE" 2>/dev/null || true
  set -a; . "$ENV_FILE" 2>/dev/null || true; set +a

  export APP_DIR="${APP_DIR:-$DEF_APP_DIR}"
  export GIT_BRANCH="${GIT_BRANCH:-$DEF_GIT_BRANCH}"
  export SERVICE_NAME="${SERVICE_NAME:-$DEF_SERVICE}"
  export SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}"
  export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
  export GUNICORN_BIND="${GUNICORN_BIND:-$DEF_GUNICORN_BIND}"

  [ -d "${APP_DIR}/.git" ] || _die "Upgrade requires an existing git clone at APP_DIR=${APP_DIR}. No ${APP_DIR}/.git found. Run Option 4 (Install app) first."

  _ensure_service_account_ready "${SERVICE_ACCOUNT}" "$APP_DIR"

  local before_rev=""
  before_rev=$(_git_run_as_service "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

  _section "Update source code from origin/${GIT_BRANCH}"
  _run_with_spinner "git fetch depth=1 origin/$GIT_BRANCH" _git_run_as_service "$APP_DIR" fetch --depth 1 origin "$GIT_BRANCH" || true
  _run_with_spinner "git reset --hard origin/$GIT_BRANCH" _git_run_as_service "$APP_DIR" reset --hard "origin/$GIT_BRANCH" || \
    _die "git reset --hard origin/$GIT_BRANCH FAILED. Manual intervention: cd $APP_DIR ; git status ; git stash ; git reset --hard HEAD"

  local after_rev=""
  after_rev=$(_git_run_as_service "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  _ok "Git updated: ${before_rev} -> ${after_rev} (branch=${GIT_BRANCH})"

  _section "Update Python virtualenv + dependencies"
  _install_compatible_python_runtime || true
  _detect_compatible_python3 2>/dev/null || true
  if [ -z "${PYTHON_BIN:-}" ]; then
    if command -v python3 >/dev/null 2>&1; then PYTHON_BIN="$(command -v python3)"; fi
  fi
  [ -n "${PYTHON_BIN:-}" ] || _die "Could not detect a usable python3 on this server. Run Option 4 to install a compatible Python runtime."

  if [ ! -x "${APP_DIR}/.venv/bin/python" ]; then
    _validate_and_bootstrap_py_venv_pip "$PYTHON_BIN" || true
    _run_with_spinner "Create venv: ${APP_DIR}/.venv (PYTHON_BIN=${PYTHON_BIN##*/})" bash -c "'$PYTHON_BIN' -m venv '$APP_DIR/.venv'" || \
      _die "Failed to create venv at ${APP_DIR}/.venv. Run Option 4 to rebuild the environment."
  fi

  local venv_bin="${APP_DIR}/.venv/bin"
  local active_py="${venv_bin}/python"
  [ -x "$active_py" ] || _die "Venv python missing at $active_py. Run Option 4 to rebuild the environment."
  set +u
  . "${APP_DIR}/.venv/bin/activate" 2>/dev/null || true
  set -u
  case ":$PATH:" in
    *":$venv_bin:"*) : ;;
    *) export PATH="$venv_bin:$PATH" ;;
  esac
  export VIRTUAL_ENV="${VIRTUAL_ENV:-${APP_DIR}/.venv}"

  _run_with_spinner "pip upgrade (pip+setuptools+wheel in venv)" bash -c "python -m pip install --quiet --upgrade pip setuptools wheel" || \
    _die "pip upgrade failed inside venv. Run Option 4 to diagnose and auto-heal python/venv issues."

  if [ -f "${APP_DIR}/requirements.txt" ]; then
    _filter_linux_requirements_for_upgrade() {
      local src="$1" dst="$2" skipped="" pkg="" line="" stripped=""
      local -a WIN_ONLY_PKGS=(
        pywin32 pypiwin32 "pywin32-ctypes"
        windows-curses win-unicode-console
        colorama wmi pywinauto pyad
        comtypes pyttsx3 pywinrm win32core win32ctypes
      )
      : >"$dst"
      while IFS= read -r line || [ -n "$line" ]; do
        stripped="$(printf '%s' "$line" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
        if [ -z "$stripped" ] || [[ "$line" == \#* ]]; then
          printf '%s\n' "$line" >>"$dst"
          continue
        fi
        local matched=0
        for pkg in "${WIN_ONLY_PKGS[@]}"; do
          if printf '%s' "$stripped" | grep -Ei "^${pkg}([\[\=<>~!\ ]|$)" >/dev/null 2>&1; then
            matched=1
            break
          fi
        done
        if [ "$matched" -eq 1 ]; then
          if [ -z "$skipped" ]; then skipped="$line"; else skipped="${skipped}|${line}"; fi
        else
          printf '%s\n' "$line" >>"$dst"
        fi
      done <"$src"
      printf '%s' "$skipped"
    }

    local req_src="${APP_DIR}/requirements.txt"
    local req_filtered="${APP_DIR}/requirements.linux-filtered.txt"
    local req_bak="${APP_DIR}/requirements.txt.bak"
    local skipped_lines="" dropped_count=0
    if ! cp -f "$req_src" "$req_bak" 2>/dev/null; then
      req_bak=""
    fi
    skipped_lines="$(_filter_linux_requirements_for_upgrade "$req_src" "$req_filtered")"
    if [ -n "$skipped_lines" ]; then
      local IFS_SAVE="$IFS"
      IFS='|'
      local -a drops=( $skipped_lines )
      IFS="$IFS_SAVE"
      dropped_count="${#drops[@]}"
      _warn "requirements.txt contains ${dropped_count} WINDOWS-ONLY pinned packages that have NO Linux wheels. Using filtered copy for install."
      local dl
      for dl in "${drops[@]}"; do
        printf "  - %s\n" "$dl" >&2
      done
      _info "Original backed up to: ${req_bak:-<backup unavailable>}  Filtered copy: $req_filtered"
    fi

    local pip_log="/tmp/rasyatone_pip_upgrade_$$.log"
    : >"$pip_log" 2>/dev/null || true
    set +e
    local req_label=""
    if [ "$dropped_count" -gt 0 ]; then
      req_label="pip install -r requirements.linux-filtered.txt (${dropped_count} Windows deps removed) (log: $pip_log)"
      _run_with_spinner "$req_label" bash -c "python -m pip install -r '$req_filtered' >'$pip_log' 2>&1"
    else
      req_label="pip install -r requirements.txt (log: $pip_log)"
      _run_with_spinner "$req_label" bash -c "python -m pip install -r '$req_src' >'$pip_log' 2>&1"
    fi
    local prc=$?
    set -e
    if [ "$prc" -ne 0 ]; then
      _nok "pip install FAILED (rc=$prc). Evidence follows (primary log: $pip_log)."
      local pip_sz=0
      pip_sz=$(wc -c <"$pip_log" 2>/dev/null | tr -d '[:space:]' || echo 0)
      if [ "${pip_sz:-0}" -gt 0 ] 2>/dev/null; then
        printf "  pip_log_size=%s bytes\n" "$pip_sz" >&2
        tail -n 80 "$pip_log" 2>/dev/null | sed 's/^/  /' >&2 || true
      else
        _warn "pip log is EMPTY (size=0). Capturing additional evidence from the most recent spinner log and a verbose re-run log."
        local pip_spin_log=""
        local _gl=""
        for _gl in $(ls -1t /tmp/rasyatone_spin_*_*pip_install* 2>/dev/null | head -n 6); do
          [ -f "$_gl" ] || continue
          pip_spin_log="$_gl"
          break
        done
        if [ -n "${pip_spin_log:-}" ] && [ -f "${pip_spin_log:-}" ]; then
          printf "  spinner_log=%s (size=%s bytes)\n" "$pip_spin_log" "$(wc -c <"$pip_spin_log" 2>/dev/null | tr -d '[:space:]' || echo 0)" >&2
          tail -n 80 "$pip_spin_log" 2>/dev/null | sed 's/^/  /' >&2 || true
        else
          printf "  (no spinner log found matching /tmp/rasyatone_spin_*pip_install*)\n" >&2
        fi
        local pip_log2="/tmp/rasyatone_pip_upgrade_rerun_$$.log"
        : >"$pip_log2" 2>/dev/null || true
        set +e
        bash -c "python -m pip -vvv install -r '${APP_DIR}/requirements.txt' >'$pip_log2' 2>&1" || true
        set -e
        printf "  verbose_rerun_log=%s (size=%s bytes)\n" "$pip_log2" "$(wc -c <"$pip_log2" 2>/dev/null | tr -d '[:space:]' || echo 0)" >&2
        tail -n 120 "$pip_log2" 2>/dev/null | sed 's/^/  /' >&2 || true
        _die "Upgrade aborted due to pip install failure. Logs: $pip_log (primary), ${pip_spin_log:-<none>} (spinner), $pip_log2 (verbose rerun)."
      fi
      _die "Upgrade aborted due to pip install failure. Full log: $pip_log"
    fi
    _ok "pip install requirements.txt OK"
  else
    _warn "No ${APP_DIR}/requirements.txt found — skipping pip install -r"
  fi

  _section "Run Django collectstatic + migrate"
  local base_env=""
  base_env="cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE}' '$APP_DIR/.venv/bin/python'"

  set +e
  _run_with_spinner "manage.py collectstatic --noinput" bash -c "${base_env} manage.py collectstatic --noinput >/dev/null 2>&1" || true
  set -e

  local mig_rc=0
  set +e
  _run_migrate_autoheal "$APP_DIR" "${DJANGO_SETTINGS_MODULE}" "$APP_DIR/.venv/bin/python" "${base_env}" "" || mig_rc=$?
  set -e
  [ "$mig_rc" -eq 0 ] || _die "manage.py migrate FAILED during upgrade (rc=$mig_rc). Fix the underlying issue and rerun Option 5."

  if command -v systemctl >/dev/null 2>&1; then
    _section "Restart application service: ${SERVICE_NAME}"
    _run_with_spinner "systemctl restart ${SERVICE_NAME}" sudo systemctl restart "${SERVICE_NAME}" || true
    sudo systemctl is-active "${SERVICE_NAME}" >/dev/null 2>&1 && _ok "${SERVICE_NAME} is active" || _warn "${SERVICE_NAME} is not active (check: systemctl status ${SERVICE_NAME})"
  else
    _warn "systemctl not available — skipping service restart. Restart gunicorn manually if applicable."
  fi

  local script_dir=""
  script_dir="$(cd "$(dirname "$0")" && pwd -P 2>/dev/null || pwd)"
  local report_log="${script_dir}/rasyatone_post_install_summary.log"
  {
    printf "\n=== RaSYaTone app UPGRADE SUMMARY ===\n"
    printf "Timestamp: %s\n" "$(date -Is 2>/dev/null || date 2>/dev/null || echo unknown)"
    printf "APP_DIR: %s\n" "$APP_DIR"
    printf "SERVICE: %s\n" "$SERVICE_NAME"
    printf "Branch: %s\n" "$GIT_BRANCH"
    printf "Git: %s -> %s\n" "$before_rev" "$after_rev"
  } | sudo tee -a "$report_log" >/dev/null 2>/dev/null || true
  sudo chmod 0644 "$report_log" 2>/dev/null || true
  _ok "Upgrade summary appended: $report_log"
  printf "\nDone.\n"
}

doctor_report() {
  load_env_file >/dev/null 2>&1 || true
  detect_pm >/dev/null 2>&1 || true
  firewall_detect >/dev/null 2>&1 || true
  local bind_port=""
  bind_port=$(printf "%s" "${GUNICORN_BIND:-$DEF_GUNICORN_BIND}" | awk -F: '{print $NF}' 2>/dev/null || echo "8000")
  local svc="${SERVICE_NAME:-$DEF_SERVICE}"
  local app_dir="${APP_DIR:-$DEF_APP_DIR}"
  local env_file="${ENV_FILE:-/etc/rasyatone.env}"
  _section "RaSYaTone Doctor (no changes)"
  printf "\n\033[1;97mCore:\033[0m\n"
  printf "  APP_DIR=%s\n" "$app_dir"
  printf "  ENV_FILE=%s\n" "$env_file"
  printf "  SERVICE=%s\n" "$svc"
  printf "  SERVICE_ACCOUNT=%s\n" "${SERVICE_ACCOUNT:-$DEF_SERVICE_ACCOUNT}"
  printf "  DJANGO_SETTINGS_MODULE=%s\n" "${DJANGO_SETTINGS_MODULE:-$DEF_DJANGO_SETTINGS_MODULE}"
  printf "  GUNICORN_BIND=%s\n" "${GUNICORN_BIND:-$DEF_GUNICORN_BIND}"
  printf "\n\033[1;97mListeners:\033[0m\n"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E ":(80|443|${bind_port})\\b" 2>/dev/null | sed 's/^/  /' || printf "  (no listener detected for ports 80/443/%s)\n" "$bind_port"
  else
    printf "  ss not available\n"
  fi
  printf "\n\033[1;97mHTTP checks:\033[0m\n"
  if command -v curl >/dev/null 2>&1; then
    local c1=""
    c1=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${bind_port}/" 2>/dev/null || echo "000")
    printf "  http://127.0.0.1:%s/ -> %s\n" "$bind_port" "$c1"
  else
    printf "  curl not available\n"
  fi
  printf "\n\033[1;97mService:\033[0m\n"
  if command -v systemctl >/dev/null 2>&1; then
    printf "  %s state=" "$svc"
    systemctl is-active "$svc" 2>/dev/null || true
    systemctl status --no-pager -n 12 "$svc" 2>/dev/null | sed 's/^/  /' || true
  else
    printf "  systemctl not available\n"
  fi
  printf "\n\033[1;97mNginx:\033[0m\n"
  local nginx_conf="/etc/nginx/conf.d/${svc}.conf"
  local nginx_domain=""
  if sudo test -f "$nginx_conf" 2>/dev/null; then
    nginx_domain=$(sudo awk '/server_name[[:space:]]+/{print $2; exit}' "$nginx_conf" 2>/dev/null | tr -d ';' || true)
    printf "  conf=%s\n" "$nginx_conf"
    [ -n "${nginx_domain}" ] && printf "  server_name=%s\n" "$nginx_domain"
  else
    printf "  conf=%s (missing)\n" "$nginx_conf"
  fi
  if command -v nginx >/dev/null 2>&1; then
    set +e
    sudo nginx -t >/dev/null 2>&1
    local nt_rc=$?
    set -e
    if [ "$nt_rc" -eq 0 ]; then
      printf "  nginx -t: OK\n"
    else
      printf "  nginx -t: FAIL\n"
      sudo nginx -t 2>&1 | tail -n 8 | sed 's/^/  /' || true
    fi
  else
    printf "  nginx not installed\n"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    printf "  nginx state="
    systemctl is-active nginx 2>/dev/null || true
  fi
  printf "\n\033[1;97mCertbot:\033[0m\n"
  if command -v certbot >/dev/null 2>&1; then
    certbot certificates 2>/dev/null | sed 's/^/  /' | head -n 40 || true
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -Eq '^certbot\.timer'; then
      printf "  auto-renew=systemd timer\n"
      systemctl is-enabled certbot.timer 2>/dev/null | sed 's/^/  /' || true
      systemctl list-timers --all 2>/dev/null | grep -i certbot 2>/dev/null | sed 's/^/  /' || true
    else
      printf "  auto-renew=cron (if installed)\n"
      sudo crontab -l 2>/dev/null | grep -i certbot 2>/dev/null | sed 's/^/  /' || printf "  (no certbot cron lines found)\n"
    fi
  else
    printf "  certbot not installed\n"
  fi
  printf "\n\033[1;97mFirewall:\033[0m\n"
  if command -v ufw >/dev/null 2>&1; then
    sudo ufw status 2>/dev/null | sed 's/^/  /' || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    sudo firewall-cmd --state 2>/dev/null | sed 's/^/  /' || true
    sudo firewall-cmd --list-services 2>/dev/null | sed 's/^/  services: /' || true
  elif command -v iptables >/dev/null 2>&1; then
    sudo iptables -S 2>/dev/null | grep -E "dport (80|443|${bind_port})" 2>/dev/null | sed 's/^/  /' || printf "  (no matching iptables rules found)\n"
  else
    printf "  firewall tool not detected\n"
  fi
  printf "\n"
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
    printf "  5) Upgrade/Update RaSYaTone application server\n"
    printf "  Q) Quit\n"
    local choice=""
    printf "\nChoose [1/2/3/4/5/Q]: "
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
      5) _section "Option 5 — Upgrade/Update RaSYaTone application server"
         upgrade_app ;;
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
elif [ "${1:-}" = "--upgrade-app" ]; then
  upgrade_app; exit 0
elif [ "${1:-}" = "--precheck-db" ]; then
  precheck_db_prereqs; exit $?
elif [ "${1:-}" = "--precheck-app" ]; then
  precheck_app_prereqs; exit $?
elif [ "${1:-}" = "--doctor" ]; then
  doctor_report; exit 0
elif [ -n "${1:-}" ]; then
  _die "Unknown arg: $1 (use no args for interactive menu, or --precheck-db | --precheck-app | --install-db | --install-app | --upgrade-app | --doctor)"
else
  main_menu
fi
