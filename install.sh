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
declare -g PYTHON_BIN=""

# --- tiny helpers -----------------------------------------------------------
_ok()   { printf "  \033[92m[ OK ]\033[0m %s\n" "$*"; }
_nok()  { printf "  \033[91m[FAIL]\033[0m %s\n" "$*"; return 1; }
_warn() { printf "  \033[93m[WARN]\033[0m %s\n" "$*"; }
_info() { local fmt="$1"; shift; printf "  \033[96m[INFO]\033[0m ${fmt}\n" "$@"; }
_die()  { printf "\n\033[91mERROR:\033[0m %s\n" "$*" >&2; exit 1; }
_section(){ printf "\n\033[1;97m=== %s ===\033[0m\n" "$*"; }

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

# --- package manager auto-detect --------------------------------------------
declare -g PM="" PKG_INSTALL="" PKG_UPDATE="" FW_BACKEND="none"
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
      _run_with_spinner "Install build tools + python3 meta + libpq-dev + libffi-dev + postgresql-client" \
        _sudo_pkg_install python3 python3-venv python3-pip python3-dev git build-essential libpq-dev libffi-dev curl gettext-base postgresql-client || true
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
      _run_with_spinner "dnf: install python3 meta + gcc + libpq/libffi-devel + postgresql + postgresql-contrib" \
        _sudo_pkg_install python3 python3-devel python3-pip git gcc gcc-c++ make libpq-devel libffi-devel curl postgresql postgresql-contrib || \
      _run_with_spinner "dnf: install python3 meta + gcc + libpq/libffi-devel + postgresql" \
        _sudo_pkg_install python3 python3-devel python3-pip git gcc gcc-c++ make libpq-devel libffi-devel curl postgresql || true
      ;;
    apk)
      # Alpine: python3 + build tools + dev headers.
      _run_with_spinner "apk: install python3 + build tools + postgresql-dev + libffi-dev" \
        _sudo_pkg_install python3 py3-virtualenv py3-pip python3-dev git build-base postgresql-dev libffi-dev curl postgresql-client || true
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
    _run_with_spinner "psql SELECT 1 credential test (${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME})" bash -c 'PGPASSWORD="$1" timeout 8 psql -h "$2" -p "$3" -U "$4" -d "$5" -tAc "SELECT 1" >"$6" 2>&1' _ "$DB_PASSWORD" "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_NAME" "$psql_out"
    row=$(cat "$psql_out" 2>/dev/null | tr -d '[:space:]' || true)
    rm -f "$psql_out" 2>/dev/null || true
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

  printf "\nEnter RaSYaTone app server settings (press Enter to keep default in [brackets]):\n"
  printf "  (Database settings — Enter keeps current value from %s)\n" "$ENV_FILE"
  DB_NAME=$(prompt_def "Database name"      "${DB_NAME:-$DEF_DB_NAME}")
  DB_USER=$(prompt_def "Database user"      "${DB_USER:-$DEF_DB_USER}")
  DB_PASSWORD=$(prompt_secret "Database user password" "${DB_PASSWORD:-}")
  DB_HOST=$(prompt_def "Database host"      "${DB_HOST:-$DEF_DB_HOST}")
  DB_PORT=$(prompt_def "Database port"      "${DB_PORT:-$DEF_DB_PORT}")
  APP_DIR=$(prompt_def "App install directory" "${APP_DIR:-$DEF_APP_DIR}")
  GIT_URL=$(prompt_def "Git repository URL (https://... or git@...) (REQUIRED). PRIVATE REPO on your account: URL alone will NOT auth; installer offers METHOD1/METHOD2 wizard next." "${GIT_URL:-}")
  [ -z "$GIT_URL" ] && _die "Git URL is required — cannot clone application without a repo URL"
  GIT_BRANCH=$(prompt_def "Git branch"          "${GIT_BRANCH:-$DEF_GIT_BRANCH}")
  DJANGO_SETTINGS=$(prompt_def "Django settings module (Python dotted path)" "${DJANGO_SETTINGS:-$DEF_DJANGO_SETTINGS}")
  GUNICORN_BIND=$(prompt_def "Gunicorn bind address" "${GUNICORN_BIND:-$DEF_GUNICORN_BIND}")
  SERVICE_NAME=$(prompt_def "systemd service name" "${SERVICE_NAME:-$DEF_SERVICE}")

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
  set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
  if command -v psql >/dev/null 2>&1; then
    _run_with_spinner "psql SELECT 1 (credential pre-check)" bash -c "set -e; row=\$(PGPASSWORD='$DB_PASSWORD' timeout 10 psql -h '$DB_HOST' -p '$DB_PORT' -U '$DB_USER' -d '$DB_NAME' -tAc 'SELECT 1' 2>/dev/null || true); [ \"\$row\" = \"1\" ]" || {
      _warn "psql SELECT 1 probe FAILED — manage.py migrate will likely fail too. Continuing...";
    }
    _ok "psql SELECT 1 OK (DB credentials validate)"
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
      else
        _die "Cannot proceed with git clone into non-empty $APP_DIR without wiping it first. Answer 'y' to wipe, or clear $APP_DIR manually then rerun Option 4."
      fi
    fi
    # Safety: dir MUST be empty before fresh clone. (If user answered Y above but rm -rf left stubborn dotfiles somehow, fail loudly.)
    if [ -n "$(ls -A "$APP_DIR" 2>/dev/null | head -n1)" ]; then
      _die "$APP_DIR is still not empty after wipe attempt. Remove contents manually and try again."
    fi
    _info "Running git clone (branch=$GIT_BRANCH, depth=1) — spinner shows activity during clone; token redacted from final stdout."
    _run_with_spinner "git clone branch=$GIT_BRANCH depth=1 into $APP_DIR" bash -c "git clone -b '$GIT_BRANCH' --depth 1 '$GIT_URL' '$APP_DIR'" || \
      _die "git clone FAILED (rc=$?). See /tmp/rasyatone_spin_*.log for the exact git error. Common causes: (1) private repo PAT expired — rerun, wizard will get a NEW token; (2) branch '$GIT_BRANCH' does not exist — re-check; (3) DNS/network to github.com down."
  else
    _ok "App dir already has .git — fetching latest origin/$GIT_BRANCH instead of fresh clone"
    _run_with_spinner "git fetch depth=1 origin/$GIT_BRANCH" bash -c "git -C '$APP_DIR' fetch --depth 1 origin '$GIT_BRANCH' || true" || true
    _run_with_spinner "git reset --hard origin/$GIT_BRANCH" bash -c "git -C '$APP_DIR' reset --hard 'origin/$GIT_BRANCH'" || \
      _die "git reset --hard origin/$GIT_BRANCH FAILED. Manual intervention: cd $APP_DIR ; git status ; git stash ; git reset --hard HEAD"
  fi
  [ -d "$APP_DIR" ] || _die "App dir $APP_DIR missing after clone"
  # Post-clone safety: a successful clone MUST produce a .git subdir. If it's not there, clone silently failed.
  [ -d "${APP_DIR}/.git" ] || _die "git clone reported exit 0 but ${APP_DIR}/.git does NOT exist — likely empty-branch / repo-initialization race / shallow clone failure. Rerun with a different branch or check repo contents on GitHub."
  _ok "App dir populated (branch=$GIT_BRANCH)"

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

  _section "Run Django collectstatic + migrate"
  (
    cd "$APP_DIR"
    set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DJANGO_SETTINGS}"
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
    # Ensure venv/bin is on PATH inside this subshell (belt+braces same as
    # outer activate block — no activate no-op inside subshell)
    case ":$PATH:" in
      *":$APP_DIR/.venv/bin:"*) : ;;
      *) export PATH="$APP_DIR/.venv/bin:$PATH" ;;
    esac
    [ -x "$APP_DIR/.venv/bin/python" ] || _die "collectstatic/migrate PRECHECK: $APP_DIR/.venv/bin/python missing (venv gone?). Run: sudo rm -rf '${APP_DIR:?}/.venv' ; rerun Option 4."
    export PYTHONPATH="${APP_DIR:?}${PYTHONPATH:+:${PYTHONPATH}}"
    export VIRTUAL_ENV="${VIRTUAL_ENV:-$APP_DIR/.venv}"
    local django_precheck_rc=0 django_precheck_traceback=""
    django_precheck_traceback=$("$APP_DIR/.venv/bin/python" - <<'PY' 2>&1 || django_precheck_rc=$?
import os, sys, traceback
try:
    import django
    from django.conf import settings as _ds
    # NOTE: we use os.environ.get DJANGO_SETTINGS_MODULE explicitly — the
    # `import django; django.setup()` call below will respect env and fail
    # with EXACT ModuleNotFoundError chain the user saw IF PYTHONPATH is wrong.
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
    if [ "$django_precheck_rc" -ne 0 ]; then
      local dsm="${DJANGO_SETTINGS_MODULE:-<UNSET>}"
      _die "\
Django settings import PRECHECK FAILED (rc=$django_precheck_rc). BEFORE we even
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
  PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='$dsm' '$APP_DIR/.venv/bin/python' -c 'import django; django.setup(); from django.conf import settings; print(\"OK; STATIC_ROOT=\", settings.STATIC_ROOT)'
"
    fi
    _ok "Django settings PRECHECK OK (PYTHONPATH=$APP_DIR; DJANGO_SETTINGS_MODULE=$DJANGO_SETTINGS_MODULE; traceback clean)"
    set +e
    # collectstatic: first quiet attempt with spinner; if that fails re-run
    # noisily so user sees WHY it failed (STATIC_ROOT / permissions)
    _run_with_spinner "manage.py collectstatic --noinput (scan static files)" bash -c "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE:-$DJANGO_SETTINGS}' '$APP_DIR/.venv/bin/python' manage.py collectstatic --noinput >/dev/null 2>&1"
    local csrc=$?
    set -e
    if [ "$csrc" -ne 0 ]; then
      # Re-run noisily with a secondary spinner so progress still shown during long re-run
      _warn "collectstatic exited non-zero — re-running with full output for debugging:"
      (cd "$APP_DIR" && PYTHONPATH="$APP_DIR" DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-$DJANGO_SETTINGS}" "$APP_DIR/.venv/bin/python" manage.py collectstatic --noinput 2>&1 | tail -n 20 || true)
      _warn "Continuing anyway — if STATIC_ROOT was unset or wrong path this is expected."
    else
      _ok "collectstatic ok"
    fi
    _run_with_spinner "manage.py migrate (apply DB migrations)" bash -c "cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE:-$DJANGO_SETTINGS}' '$APP_DIR/.venv/bin/python' manage.py migrate" || \
      _die "manage.py migrate FAILED (rc=$?). Full categorized causes IN ORDER:
  (A) SETTINGS-IMPORT FAILURE (the #1 cause, this is the error we ran a precheck
      probe for above — if you hit this, the probe above should have died first,
      but if it slipped through, run: cd '$APP_DIR' && PYTHONPATH='$APP_DIR'
      DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE:-$DJANGO_SETTINGS}'
      '$APP_DIR/.venv/bin/python' -c 'import django; django.setup()' — full
      traceback will show actual missing package / broken import).
  (B) DB CONNECTION FAILURE (2nd most common). Env file loaded: $ENV_FILE.
      Check: DB_HOST / DB_PORT / DB_NAME / DB_USER / DB_PASSWORD set and match
      what install_db (Option 3) created? SELECT 1 probe during prechecks
      (terminal line near psql) should show if credentials work.
  (C) DB PRIVILEGE FAILURE. CREATEDB missing? If DB_NAME did not exist and
      Django tried to autocreate it (some settings configs do that), DB_USER
      needs CREATEDB attribute: sudo -u postgres psql -c \"ALTER USER $DB_USER WITH CREATEDB;\"
      Also CONNECT on database: sudo -u postgres psql -c \"REVOKE CONNECT ON DATABASE $DB_NAME FROM PUBLIC; GRANT CONNECT ON DATABASE $DB_NAME TO $DB_USER;\"
  (D) MIGRATION FILES MISSING / BROKEN. Check APP_DIR/migrations/ or each app
      migration dirs. Run: cd '$APP_DIR' && PYTHONPATH='$APP_DIR' DJANGO_SETTINGS_MODULE='${DJANGO_SETTINGS_MODULE:-$DJANGO_SETTINGS}' '$APP_DIR/.venv/bin/python' manage.py showmigrations
  (E) PYTHON version mismatch. Venv python version: $("$APP_DIR/.venv/bin/python" -c 'import sys;print(sys.version)' 2>/dev/null). Django 5+ needs >= 3.10 and <= 3.13 (MAX_ALLOWED_PYTHON_MINOR=3.13 cap to avoid cpython-314 psycopg2 sdist crashes)."
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
    _run_with_spinner "systemd daemon-reload (re-read unit files)" sudo systemctl daemon-reload || true
    _run_with_spinner "systemctl enable --now $SERVICE_NAME (start app)" sudo systemctl enable --now "$SERVICE_NAME" || \
      _warn "systemctl enable --now returned non-zero — app may still be starting (RestartSec=3). Run: systemctl status '$SERVICE_NAME' in 10s to verify."
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
  if [ -x "$APP_DIR/.venv/bin/python" ]; then
    printf "  VENV_PYTHON_VERSION=%s\n" "$("$APP_DIR/.venv/bin/python" --version 2>&1 | head -n1)"
  fi
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
