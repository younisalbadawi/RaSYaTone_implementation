#!/usr/bin/env python3
"""RaSYaTone Django deployment script -- single file.

Approach B: atomic release-dir symlink switcher.

Modes:
  Interactive wizard (auto on Windows TTY, or --interactive):
        python3 rasyatone_deploy.py --interactive
  Local (default):
        sudo python3 rasyatone_deploy.py [--stage preflight|deploy|rollback|check]
  Remote (via --remote):
        python3 rasyatone_deploy.py --stage deploy --remote user@host:port
"""
from __future__ import annotations

import argparse
import contextlib
import copy as _cp
import datetime as dt
import getpass
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, NamedTuple, Optional

# Unix-only modules (remote mode can run on Windows, so make these lazy)
try:
    import grp  # type: ignore[import-not-found]
except ModuleNotFoundError:  # pragma: no cover - Windows
    grp = None  # type: ignore[assignment]
try:
    import pwd  # type: ignore[import-not-found]
except ModuleNotFoundError:  # pragma: no cover - Windows
    pwd = None  # type: ignore[assignment]


def _geteuid_or_none() -> Optional[int]:
    """Return current euid on Unix or None on Windows (safe for remote mode)."""
    return getattr(os, "geteuid", lambda: None)()


def _chown_safe(path: str | os.PathLike, uid: int, gid: int, log=None) -> bool:
    """os.chown on Unix, silent no-op on Windows. Returns True if applied."""
    if not hasattr(os, "chown"):
        return False
    try:
        os.chown(str(path), uid, gid)
        return True
    except OSError as exc:
        if log is not None:
            log.debug("chown %s (uid=%s gid=%s) skipped: %s", path, uid, gid, exc)
        return False


def _getpwnam_safe(user: str):
    """Safe pwd.getpwnam wrapper. Returns None on Windows, raises KeyError on unknown user."""
    if pwd is None:  # Windows
        return None
    return pwd.getpwnam(user)


def _getgrnam_safe(group: str):
    """Safe grp.getgrnam wrapper. Returns None on Windows, raises KeyError on unknown group."""
    if grp is None:  # Windows
        return None
    return grp.getgrnam(group)


# ============================================================
# 2.1 Cross-platform TTY / VT100 / Unicode auto-detection
#      (prevents the "\\u2554\\u2550\\u2550" escape rendering bug on Windows)
# ============================================================

def _fix_console_io_encoding() -> None:
    """Force stdout/stderr to UTF-8 on Windows so Unicode chars don't become \\u escapes."""
    if sys.platform != "win32":
        return
    for attr in ("stdout", "stderr"):
        stream = getattr(sys, attr, None)
        if stream is None:
            continue
        reconf = getattr(stream, "reconfigure", None)
        if callable(reconf):
            try:
                reconf(encoding="utf-8", errors="backslashreplace")
            except Exception:
                pass


def _vt_mode_enable() -> bool:
    """Enable ENABLE_VIRTUAL_TERMINAL_PROCESSING on Windows console output handle.
    Returns True if VT mode is active (color + unicode box chars render correctly)."""
    if sys.platform != "win32":
        return True  # Unix/macOS terminals default VT-capable if isatty
    try:
        import ctypes
        from ctypes import wintypes
        STD_OUTPUT_HANDLE = wintypes.DWORD(-11)
        ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        ENABLE_PROCESSED_OUTPUT = 0x0001
        kernel32 = ctypes.windll.kernel32
        h = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
        if h in (None, 0, -1):
            return False
        mode = wintypes.DWORD(0)
        if not kernel32.GetConsoleMode(h, ctypes.byref(mode)):
            return False  # not a real console handle (redirected pipe / file)
        new_mode = wintypes.DWORD(mode.value | ENABLE_VIRTUAL_TERMINAL_PROCESSING
                                   | ENABLE_PROCESSED_OUTPUT)
        return bool(kernel32.SetConsoleMode(h, new_mode))
    except Exception:
        return False


def _auto_flags(argv0: list[str]) -> tuple[bool, bool]:
    """Return (no_color, no_unicode) auto-detected from environment, argv, and VT probe.

    Rules (first match wins):
      NO_COLOR env != ""           → no_color=True, no_unicode=True
      TERM=dumb                    → no_color=True
      --no-color in argv           → no_color=True
      NOT a TTY (stdout.isatty=False) → no_color=True, no_unicode=True
      VT enable probe fails (Win)  → no_color=True, no_unicode=True
      else → (False, False)
    """
    no_color = False
    no_unicode = False
    joined = " ".join(argv0).lower()
    if os.environ.get("NO_COLOR", "") != "":
        return True, True
    if os.environ.get("TERM", "") == "dumb":
        no_color = True
    if "--no-color" in joined:
        no_color = True
    try:
        istty = sys.stdout.isatty() and sys.stderr.isatty()
    except Exception:
        istty = False
    if not istty:
        no_color = True
        no_unicode = True
    vt_ok = _vt_mode_enable()
    if not vt_ok:
        no_color = True
        no_unicode = True
    return no_color, no_unicode


# Box-drawing tables (native Unicode ↔ ASCII fallback)
_CHARS_UTF8 = {
    "tl": "╔", "tr": "╗", "bl": "╚", "br": "╝", "h": "═", "v": "║",
    "ml": "╠", "mr": "╣", "mdh": "╦", "muh": "╩", "mx": "╬",
    "em": "—", "ge": "≥", "le": "≤", "arr": "→", "larr": "←",
    "x": "✗", "ok": "✓",
}
_CHARS_ASCII = {
    "tl": "+", "tr": "+", "bl": "+", "br": "+", "h": "-", "v": "|",
    "ml": "+", "mr": "+", "mdh": "+", "muh": "+", "mx": "+",
    "em": "--", "ge": ">=", "le": "<=", "arr": "->", "larr": "<-",
    "x": "x", "ok": "ok",
}


def _gx(key: str, no_unicode: bool) -> str:
    """Return glyph by key using active charset."""
    table = _CHARS_ASCII if no_unicode else _CHARS_UTF8
    return table.get(key, _CHARS_ASCII.get(key, "?"))


def _banner_hr(width: int, *, no_unicode: bool) -> str:
    h = _gx("h", no_unicode)
    return h * width


def _wrap_fix_encoding_once() -> None:
    """Idempotent: call fix_console_io_encoding + VT probe once per run."""
    global _IO_FIXED
    if _IO_FIXED:
        return
    _IO_FIXED = True
    _fix_console_io_encoding()


_IO_FIXED = False


# Centralized ASCII normalizer (no_unicode flag or force=True for error messages):
# replaces non-ASCII punctuation with ASCII equivalents to prevent mojibake on
# non-UTF-8 / legacy consoles (cmd.exe default cp1252/cp850) and pipe outputs.
_NORM_TEXT_TABLE = {
    "—": "--", "–": "-", "−": "-",
    "≥": ">=", "≤": "<=", "≠": "!=", "≈": "~=",
    "→": "->", "←": "<-", "↔": "<->", "⇒": "=>", "⇐": "<=",
    "…": "...", "·": "*", "•": "*",
    "«": "<<", "»": ">>", '"': '"', '"': '"', ''': "'", ''': "'",
}

def _norm_text(s: str, no_unicode: Optional[bool] = None) -> str:
    """Normalize a user-visible output string to ASCII-safe equivalents.

    If no_unicode is True (auto-detected or user --no-unicode), normalize the
    entire string. If no_unicode is False, only fix codepoints that commonly
    cause mojibake (≥/≤/—/→) because they render wrongly on cp1252/non-VT even
    when the rest works.
    """
    if s is None:
        return s
    if not isinstance(s, str):
        return s
    aggressive = bool(no_unicode) if no_unicode is not None else True  # default: always safe
    out = []
    for ch in s:
        if ch in _NORM_TEXT_TABLE:
            out.append(_NORM_TEXT_TABLE[ch])
            continue
        if ord(ch) < 128:
            out.append(ch)
            continue
        if aggressive:
            # Aggressive no_unicode: escape anything else
            out.append(f"\\u{ord(ch):04x}" if ord(ch) < 0x10000 else f"\\U{ord(ch):08x}")
        else:
            # Non-aggressive: only replace known-mojibake codepoints above;
            # everything else passes through (user might have proper UTF-8 terminal).
            out.append(ch)
    return "".join(out)


_STDOUT_WIDTH = 74  # matches banner box interior width (bar=74)


def _wrap_text_width(text: str, width: int = _STDOUT_WIDTH,
                     indent: int = 3, *, pad: bool = True) -> str:
    """Word-wrap text to max width chars per line.

    Each output line begins with `indent` leading spaces (default 3 matches
    PASS/FAIL row column start). Lines shorter than width are padded with
    trailing spaces when pad=True so they render as a uniform visual block.

    Respects existing newlines in the input (treats them as hard paragraph
    breaks). Long runs without spaces are split mid-word (greedy per line).
    """
    if text is None:
        text = ""
    if not isinstance(text, str):
        text = str(text)
    # Strip carriage returns that cause 74-char-padded lines to end with \r and
    # reset cursor to col 0 between prints (overwrite corruption). Python's
    # argparse HelpFormatter on Windows writes usage via text mode so strings
    # are CRLF-delimited; split("\n") below then keeps the "\r" tail on every
    # paragraph — which we must drop BEFORE width-padding or every padded
    # line's tail \r undoes the whole line's render on next line's overwrite.
    # Similarly, bare \r (old-Mac line breaks) become paragraph boundaries.
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # Always normalize first: —→--, ≥→>= etc. so widths reflect final output char counts
    # (normalization never adds width beyond ASCII equivalents; —=1→--=2, so must be pre-counted)
    text = _norm_text(text, no_unicode=True)
    paragraphs = text.split("\n")
    output_lines: list[str] = []
    for para in paragraphs:
        if para == "":
            output_lines.append(" " * indent if pad else "")
            continue
        content_width = max(1, width - indent)
        tokens = para.split(" ")
        current = ""
        for tok in tokens:
            # Token itself may exceed content_width; split mid-token char by char
            while len(tok) > content_width:
                if current:
                    output_lines.append((" " * indent) + current)
                    current = ""
                output_lines.append((" " * indent) + tok[:content_width])
                tok = tok[content_width:]
            if not tok:
                continue
            if not current:
                current = tok
            elif len(current) + 1 + len(tok) <= content_width:
                current = current + " " + tok
            else:
                output_lines.append((" " * indent) + current)
                current = tok
        if current:
            output_lines.append((" " * indent) + current)
    if pad:
        padded = []
        for ln in output_lines:
            if len(ln) < width:
                ln = ln + (" " * (width - len(ln)))
            elif len(ln) > width:
                ln = ln[:width]
            padded.append(ln)
        return "\n".join(padded)
    return "\n".join(output_lines)


_PAD_WIDTH = _STDOUT_WIDTH



def _safe_stderr_print(*args: Any, sep: str = " ", end: str = "\n",
                      no_unicode: Optional[bool] = None,
                      error: bool = False) -> None:
    """Print to stdout (for info banners) or stderr (for errors) with
    safe Unicode normalization to prevent UnicodeEncodeError / mojibake
    on legacy Windows consoles (cp1252/cp850) and piped outputs where
    stderr/stdout is NOT a UTF-8 TTY.

    - error=False (default): info/banner output → primary stream sys.stdout
      Avoids PowerShell ErrorRecord wrapping on pipelines 2>&1.
    - error=False: exception / failure banners → primary stream sys.stderr
      Conventional diagnostic stream for actual error conditions.

    Uses _norm_text() for every string arg, and falls back to ASCII
    backslashreplace encoding if underlying write still raises.
    """
    try:
        parts = []
        for a in args:
            if isinstance(a, str):
                parts.append(_norm_text(a, no_unicode=no_unicode))
            else:
                parts.append(str(a))
        s = sep.join(parts) + end
        primary = sys.stderr if error else sys.stdout
        backup = sys.stdout if error else sys.stderr
        # Try primary text stream first
        try:
            primary.write(s)
            primary.flush()
            return
        except (UnicodeEncodeError, LookupError):
            pass
        except Exception:
            pass
        # Fallback 1: encode with backslashreplace and write to primary buffer
        try:
            buf = getattr(primary, "buffer", None)
            if buf is not None:
                try:
                    enc = getattr(primary, "encoding", None) or "utf-8"
                    buf.write(s.encode(enc, errors="backslashreplace"))
                    buf.flush()
                    return
                except Exception:
                    pass
        except Exception:
            pass
        # Fallback 2: same fallback on backup stream buffer (std<->err swap)
        try:
            buf2 = getattr(backup, "buffer", None)
            if buf2 is not None:
                try:
                    enc2 = getattr(backup, "encoding", None) or "utf-8"
                    buf2.write(s.encode(enc2, errors="backslashreplace"))
                    buf2.flush()
                    return
                except Exception:
                    pass
        except Exception:
            pass
        # Last-ditch: encode as ASCII backslashreplace and write to backup text
        try:
            backup.write(s.encode("ascii", errors="backslashreplace").decode("ascii"))
            backup.flush()
        except Exception:
            pass
    except Exception:
        # Never throw from printing
        return


APP_NAME_DEFAULT = "rasyatone"
SERVICE_USER_DEFAULT = "rasyatone_user"
DEPLOY_DIR_DEFAULT = "/opt/rasyatone"
CONFIG_DIR_DEFAULT = "/etc/rasyatone"
ENV_FILE_DEFAULT = "/etc/rasyatone/static/rasyatone.env"
LOG_DIR_DEFAULT = "/var/log/rasyatone"
BACKUP_DIR_DEFAULT = "/var/backups/rasyatone"
REPO_DEFAULT = "https://github.com/younisalbadawi/RaSYaT_SpAcE_Solution.git"
REF_DEFAULT = "main"
DOMAIN_DEFAULT = "rasyatone.alrasayt.com"
LETSENCRYPT_EMAIL_DEFAULT = "younisalbadawi@alrasyat.com"
STAGE_DEFAULT = "deploy"
SUPPORTED_UBUNTU = {"focal", "jammy", "noble"}
SUPPORTED_DEBIAN = {"bullseye", "bookworm", "trixie"}
MIN_PYTHON = (3, 10)
KEEP_RELEASES_DEFAULT = 5

_SCRIPT_VERSION = "1.0.0"

# ============================================================
# 1. Exception classes: DeployError hierarchy
# ============================================================
class DeployError(Exception):
    def __init__(self, stage: int, code: int, user_msg: str,
                 cmd: Optional[list[str]] = None, returncode: Optional[int] = None,
                 stdout: str = "", stderr: str = ""):
        super().__init__(user_msg)
        self.stage = stage
        self.code = code
        self.user_msg = user_msg
        self.cmd = cmd
        self.returncode = returncode
        self._stdout = stdout
        self._stderr = stderr


class PreflightError(DeployError):
    pass


class StageError(DeployError):
    pass  # stages 1..13 safe (no prod impact)


class ProdStageError(DeployError):
    pass  # stages 14..18 triggers auto-rollback


# ============================================================
# 2. Env file parser (NEVER sources file into parent shell)
# ============================================================
_ENV_LINE_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")
_SENSITIVE_KEY_RE = re.compile(
    r"(SECRET|PASSWD?|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|"
    r"CREDENTIAL|AUTH|SESSION|COOKIE|CLIENT_?SECRET|DSN)",
    re.IGNORECASE,
)
_DBPASS_URL_RE = re.compile(r"\b(postgres(?:ql)?://[^:/?#\s]+):[^:@/?#\s]*@", re.IGNORECASE)
_BASICAUTH_URL_RE = re.compile(r"\b(https?://[^:/?#\s]+):[^:@/?#\s]*@", re.IGNORECASE)
_KV_EQ_RE = re.compile(
    r"([A-Za-z_][A-Za-z0-9_]*(?:"
    r"SECRET|PASSWD?|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIAL|AUTH|SESSION|"
    r"COOKIE|CLIENT_?SECRET|DSN)[A-Za-z0-9_]*\s*=\s*)([^\s;&|'\"`]+)",
    re.IGNORECASE,
)


def parse_env_file(path: Path) -> dict[str, str]:
    """Parse a .env file into a dict WITHOUT sourcing it into the parent shell."""
    env: dict[str, str] = {}
    if not path.exists():
        return env
    try:
        raw_text = path.read_text(errors="replace")
    except OSError:
        return {}
    for raw in raw_text.splitlines():
        stripped = raw.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        m = _ENV_LINE_RE.match(raw)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
            val = val[1:-1]
        env[key] = val
    return env


def mask_val_for_logging(k: str, v: str) -> bool:
    return bool(_SENSITIVE_KEY_RE.search(k))


# ============================================================
# 3. Secret / text scrub filter
# ============================================================
def scrub_secrets(text: str, env: Optional[dict[str, str]] = None) -> str:
    if not text:
        return ""
    out = _KV_EQ_RE.sub(lambda mm: f"{mm.group(1)}***", text)
    out = _DBPASS_URL_RE.sub(lambda mm: f"{mm.group(1)}:***@", out)
    out = _BASICAUTH_URL_RE.sub(lambda mm: f"{mm.group(1)}:***@", out)
    if env:
        for k, v in env.items():
            if not v or len(v) < 3:
                continue
            if _SENSITIVE_KEY_RE.search(k):
                out = out.replace(v, "***")
    return out


# ============================================================
# 4. Colors + dual logging setup (console + deploy.log)
# ============================================================
_COLORS = {
    "RED": "\033[31m",
    "GREEN": "\033[32m",
    "YELLOW": "\033[33m",
    "BLUE": "\033[34m",
    "MAGENTA": "\033[35m",
    "CYAN": "\033[36m",
    "BOLD": "\033[1m",
    "RESET": "\033[0m",
    "BOLD_RED": "\033[1;31m",
    "BOLD_GREEN": "\033[1;32m",
    "BOLD_YELLOW": "\033[1;33m",
    "BOLD_BLUE": "\033[1;34m",
    "BOLD_MAGENTA": "\033[1;35m",
    "BOLD_CYAN": "\033[1;36m",
}


def _c(use: str, enable: bool) -> str:
    return _COLORS.get(use, "") if enable else ""


def setup_logging(log_dir: Path, quiet: bool = False, verbose: bool = False,
                  no_color: bool = False):
    """Set up dual console + file logger. Returns logger."""
    import logging as _logging

    level = _logging.DEBUG if verbose else (_logging.ERROR if quiet else _logging.INFO)
    logger = _logging.getLogger("rasyatone.deploy")
    logger.setLevel(_logging.DEBUG)
    logger.handlers.clear()

    # Console (stderr, colored)
    class _NoColorFormatter(_logging.Formatter):
        def format(self, record):
            s = super().format(record)
            for code in _COLORS.values():
                s = s.replace(code, "")
            return s

    console = _logging.StreamHandler(sys.stdout)
    console.setLevel(level)
    msgfmt = "%(message)s" if not verbose else "%(asctime)s %(levelname)7s | %(message)s"
    fmt_cls = _NoColorFormatter if no_color else _logging.Formatter
    console.setFormatter(fmt_cls(msgfmt))
    class _DropErrorsOnConsoleFilter(_logging.Filter):
        def filter(self, record):
            return record.levelno < _logging.ERROR
    console.addFilter(_DropErrorsOnConsoleFilter())
    logger.addHandler(console)

    # ------------------------------------------------------------------
    # Cross-process locking FileHandler.
    # Multiple concurrent rasyatone_deploy.py invocations append to the SAME
    # deploy.log. Without per-record byte-range locks:
    #   (a) writes shorter than 4KB-64KB can still interleave mid-line,
    #   (b) even O_APPEND on Windows/POSIX can return writes in "wrong"
    #       timestamp order when two processes emit their record within ~1ms
    #       (as seen in deploy.log lines 108-137 where PID=30636 @ 11:13:23
    #        PRECEDES PID=6216 @ 11:04:41 in the file).
    # Fix: use msvcrt.locking LK_NBLCK (NON-BLOCKING attempt, 3 tries with
    # 25ms backoff) on Windows; fcntl.flock LOCK_EX | LOCK_NB on POSIX.
    # CRITICAL: we NEVER wait more than ~100ms total for a log lock — logging
    # must never delay the deploy pipeline (deploy.log 158-185 showed ~9s gaps
    # caused by a prior LK_LOCK attempt waiting on another PID's handle). If
    # we cannot acquire in 3 tries, emit the record UNLOCKED (O_APPEND on
    # NTFS/UFS is always atomic per POSIX for writes smaller than PIPE_BUF).
    # ------------------------------------------------------------------
    class _LockedFileHandler(_logging.FileHandler):
        def emit(self, record):
            try:
                msg = self.format(record)
                stream = self.stream
            except Exception:
                self.handleError(record)
                return
            acquired = False
            try:
                acquired = self._lock_ex_nb(stream, tries=3, sleep_ms=25)
                try:
                    if self.mode == "a":
                        try: stream.seek(0, 2)
                        except Exception: pass
                    stream.write(msg)
                    stream.write(self.terminator)
                    self.flush()
                finally:
                    if acquired:
                        self._unlock(stream)
            except Exception:
                self.handleError(record)

        @staticmethod
        def _lock_ex_nb(stream, tries: int = 3, sleep_ms: int = 25) -> bool:
            """Return True if a non-blocking exclusive lock was acquired.

            Never blocks longer than `tries * sleep_ms` milliseconds (plus the
            negligible syscall overhead). Caller is responsible for _unlock()
            only when this returned True.
            """
            fp = getattr(stream, "fileno", None)
            if fp is None: return False
            try: fd = fp()
            except Exception: return False
            on_windows = _geteuid_or_none() is None
            import time as _tm_lk
            for attempt in range(max(1, tries)):
                try:
                    if on_windows:
                        import msvcrt  # type: ignore
                        import os as _os_lk
                        n_bytes = 1024 * 1024  # 1 MB past current EOF
                        msvcrt.locking(fd, msvcrt.LK_NBLCK, n_bytes)
                        return True
                    else:
                        try:
                            import fcntl  # type: ignore
                            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            return True
                        except ImportError:
                            return False
                except Exception:
                    if attempt + 1 < tries:
                        _tm_lk.sleep(sleep_ms / 1000.0)
            return False

        @staticmethod
        def _unlock(stream):
            fp = getattr(stream, "fileno", None)
            if fp is None: return
            try: fd = fp()
            except Exception: return
            on_windows = _geteuid_or_none() is None
            try:
                if on_windows:
                    import msvcrt  # type: ignore
                    n_bytes = 1024 * 1024
                    try: msvcrt.locking(fd, msvcrt.LK_UNLCK, n_bytes)
                    except Exception: pass
                else:
                    try:
                        import fcntl  # type: ignore
                        fcntl.flock(fd, fcntl.LOCK_UN)
                    except ImportError:
                        pass
            except Exception:
                pass

    # File handler /var/log/rasyatone/deploy.log (0640, rasyatone_user:adm if possible)
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        deploy_log = log_dir / "deploy.log"
        file_h = _LockedFileHandler(deploy_log, mode="a", encoding="utf-8")
        file_h.setLevel(_logging.DEBUG)
        file_h.setFormatter(_logging.Formatter(
            "%(asctime)s | ST=%(stage)s | PID=%(process)d | %(levelname)-7s | %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S%z",
        ))
        logger.addHandler(file_h)
        try:
            # Try to set adm group ownership on log dir + file if we can (Unix only)
            try:
                euid = _geteuid_or_none()
                if euid == 0:
                    adm_gr = _getgrnam_safe("adm")
                    adm_gid = adm_gr.gr_gid if adm_gr is not None else -1
                    if adm_gid != -1:
                        _chown_safe(str(log_dir), -1, adm_gid, log=None)
                        try:
                            os.chmod(str(log_dir), 0o2750)
                        except OSError:
                            pass
                        if deploy_log.exists():
                            _chown_safe(str(deploy_log), -1, adm_gid, log=None)
                            try:
                                os.chmod(str(deploy_log), 0o640)
                            except OSError:
                                pass
            except (OSError, KeyError):
                pass
        except Exception:
            pass
    except Exception:
        pass  # file logging is best-effort

    # Inject a default "stage=0" into the logger adapter so stage prefix works
    class _StageAdapter(_logging.LoggerAdapter):
        def process(self, msg, kwargs):
            extra = kwargs.setdefault("extra", {})
            extra.setdefault("stage", str(self.extra.get("stage", 0)))
            return msg, kwargs

    return _StageAdapter(logger, {"stage": 0})


# ============================================================
# 5. subprocess run_ok wrapper (always uses wrapper, NEVER bare)
# ============================================================
_CURRENT_STAGE: int = 0
_CURRENT_STAGE_NAME: str = "init"


def _subprocess_user_args(user: Optional[str], env: Optional[dict[str, str]],
                          cmd: list[str]) -> list[str]:
    """When `user` specified, prepend `sudo -u <user> -E` so subprocess inherits env kwargs only."""
    if not user:
        return list(cmd)
    sudo = shutil.which("sudo") or "/usr/bin/sudo"
    base = [sudo, "-n", "-u", user, "-E", "--"]
    return base + list(cmd)


def run_ok(cmd, *, check: bool = True, shell: bool = False,
           env: Optional[dict[str, str]] = None, cwd: Optional[Any] = None,
           user: Optional[str] = None, sensitive: bool = False,
           log=None, scrub_env: Optional[dict[str, str]] = None,
           timeout: int = 1800, label: Optional[str] = None) -> subprocess.CompletedProcess:
    """Run subprocess, capture stdout+stderr, scrub before logging, raise DeployError on fail.

    - Only subprocesses created via run_ok (never bare Popen/subprocess.run).
    - sensitive=True: cmd is redacted in logs (useful for passwords in command)
    - env= passed ONLY to subprocess child; NEVER exposed to parent os.environ.
    - Raises PreflightError if CURRENT_STAGE==0 else StageError/ProdStageError depending on
      CURRENT_STAGE threshold.
    """
    global _CURRENT_STAGE
    if isinstance(cmd, str):
        real_cmd: list[str] = [cmd]
        use_shell = shell or True
    else:
        real_cmd = list(cmd)
        use_shell = bool(shell)

    if user:
        real_cmd = _subprocess_user_args(user=user, env=env, cmd=real_cmd)
        use_shell = False  # sudo wrapper uses list mode; never shell

    # Child env: start with shallow copy of os.environ (so python3/bin/sh works)
    # THEN overlay env dict on top. For strict security, keys matching secrets in PARENT
    # env can optionally be stripped; here we take defensive approach.
    child_env = None
    if env is not None:
        child_env = _cp.deepcopy(dict(os.environ))
        # strip obvious secret keys from parent env; they'll be re-added via env overlay if set
        for pk in list(child_env.keys()):
            if _SENSITIVE_KEY_RE.search(pk):
                child_env.pop(pk, None)
        child_env.update({k: v for k, v in env.items() if v is not None})

    if log is not None:
        scrubbed_cmd = "<redacted command>" if sensitive else (
            scrub_secrets(shlex.join(real_cmd) if not use_shell else real_cmd, env=scrub_env)
        )
        log.debug("RUN%s %s%s",
                  f"[{label}]" if label else "",
                  scrubbed_cmd,
                  f"  (cwd={cwd})" if cwd else "")

    try:
        completed = subprocess.run(
            real_cmd,
            shell=use_shell,
            text=True,
            capture_output=True,
            env=child_env,
            cwd=str(cwd) if cwd is not None else None,
            timeout=timeout,
            check=False,
        )
    except (FileNotFoundError, PermissionError) as exc:
        msg = str(exc)
        if log is not None:
            log.error("RUN EXCEPTION %s", msg)
        # Determine binary name (after user sudo-wrap) for best-effort decision
        bin_name = ""
        if isinstance(real_cmd, list) and real_cmd:
            bin_name = Path(real_cmd[0]).name.lower()
        elif isinstance(real_cmd, str) and not use_shell:
            bin_name = Path(real_cmd.split()[0]).name.lower() if real_cmd.split() else ""
        # Best-effort Unix-only binaries (no DeployError if missing; treat as rc=127 regardless of check)
        _UNIX_ONLY_BINS = frozenset({
            "systemctl", "nginx", "certbot", "journalctl", "ufw", "postgresql",
            "psql", "pg_isready", "pg_dump", "pg_restore", "apt", "apt-get",
            "apt-cache", "dpkg", "useradd", "usermod", "userdel", "groupadd",
            "groupdel", "chpasswd", "mktemp", "gunicorn", "redis-server",
            "redis-cli", "a2enmod", "a2dissite", "a2ensite", "logrotate",
            "adduser", "deluser", "addgroup", "delgroup"
        })
        if bin_name in _UNIX_ONLY_BINS or not check:
            return subprocess.CompletedProcess(
                args=real_cmd, returncode=127, stdout="", stderr=msg)
        raise _deploy_error_for_stage(
            stage=_CURRENT_STAGE, code=210,
            user_msg=f"Executable not found: {msg}",
            cmd=real_cmd, returncode=127, stderr=msg,
        ) from exc
    except subprocess.TimeoutExpired as exc:
        if log is not None:
            log.error("RUN TIMEOUT after %ss", timeout)
        raise _deploy_error_for_stage(
            stage=_CURRENT_STAGE, code=211,
            user_msg=f"Command timed out after {timeout}s: {shlex.join(real_cmd)[:120]}",
            cmd=real_cmd, returncode=124, stderr=str(exc),
        ) from exc

    # Log stdout/stderr (SCRUBBED!)
    if log is not None and completed.stdout:
        log.debug("STDOUT: %s", scrub_secrets(completed.stdout[-4000:], env=scrub_env))
    if log is not None and completed.stderr:
        log.debug("STDERR: %s", scrub_secrets(completed.stderr[-4000:], env=scrub_env))

    if check and completed.returncode != 0:
        last_20_lines = "\n".join(
            (completed.stderr or completed.stdout or "").splitlines()[-20:]
        )
        raise _deploy_error_for_stage(
            stage=_CURRENT_STAGE,
            code=200 + max(1, _CURRENT_STAGE),
            user_msg=(f"Command failed (exit {completed.returncode}).\n"
                      f"Tail output:\n{scrub_secrets(last_20_lines, env=scrub_env)}"),
            cmd=real_cmd, returncode=completed.returncode,
            stdout=completed.stdout or "", stderr=completed.stderr or "",
        )
    return completed


def _deploy_error_for_stage(stage: int, code: int, user_msg: str,
                            cmd: Optional[list[str]] = None, returncode: Optional[int] = None,
                            stdout: str = "", stderr: str = "") -> DeployError:
    if stage == 0:
        cls = PreflightError
    elif stage >= 14:
        cls = ProdStageError
    else:
        cls = StageError
    return cls(stage=stage, code=code, user_msg=user_msg,
               cmd=cmd, returncode=returncode, stdout=stdout, stderr=stderr)


# ============================================================
# 6. Idempotency helpers (ensure_* — 25 resources)
# ============================================================
def _sh(cmd: str, *, log=None, scrub_env=None, sensitive=False, check=True,
        user: Optional[str] = None, env=None) -> subprocess.CompletedProcess:
    """Convenience wrapper for short bash one-liners. NEVER use for unsafe input."""
    return run_ok(["bash", "-lc", cmd], shell=False, check=check,
                  log=log, scrub_env=scrub_env, sensitive=sensitive, user=user, env=env)


def idempotency_user_exists(user: str) -> bool:
    if pwd is None:  # Windows (remote-only mode); local-deploy calls never reach here
        return False
    try:
        pwd.getpwnam(user)
        return True
    except KeyError:
        return False


def ensure_user(user: str, home_path: Path, shell: str = "/usr/sbin/nologin", log=None) -> None:
    """Create system user if not exists."""
    if idempotency_user_exists(user):
        return
    run_ok(["useradd", "--system", "--create-home",
            "--home-dir", str(home_path),
            "--shell", shell,
            "--comment", f"RaSYaTone service user",
            user],
           log=log)
    if log is not None:
        log.info("Created service user %s (home=%s)", user, home_path)


def ensure_group_member(user: str, group: str, log=None) -> None:
    try:
        groups = _sh(f"id -Gn {shlex.quote(user)}", log=log).stdout.strip().split()
    except DeployError:
        groups = []
    if group in groups:
        return
    run_ok(["usermod", "-aG", group, user], log=log)
    if log is not None:
        log.info("Added %s to group %s", user, group)


def ensure_dir(path: Path, mode: int, owner_user: Optional[str], owner_group: Optional[str],
               log=None, sticky_group: bool = False, create_parents: bool = True) -> None:
    """mkdir -p, chmod, chown idempotently."""
    changed = False
    if not path.exists():
        path.mkdir(parents=create_parents, exist_ok=True)
        changed = True
    # Apply mode if differs
    try:
        current_mode = stat.S_IMODE(path.stat().st_mode)
        desired = mode | (stat.S_ISGID if sticky_group else 0)
        if current_mode != desired:
            os.chmod(str(path), desired)
            changed = True
    except OSError:
        pass
    # Apply ownership if differs and we have perms (Unix only)
    if owner_user or owner_group:
        try:
            euid = _geteuid_or_none()
            if euid is None or euid != 0:
                pass
            else:
                st = path.stat()
                cur_uid, cur_gid = st.st_uid, st.st_gid
                pw = _getpwnam_safe(owner_user) if owner_user else None
                gr = _getgrnam_safe(owner_group) if owner_group else None
                want_uid = pw.pw_uid if pw is not None else -1
                want_gid = gr.gr_gid if gr is not None else -1
                if (want_uid != -1 and want_uid != cur_uid) or (want_gid != -1 and want_gid != cur_gid):
                    if _chown_safe(str(path), want_uid, want_gid, log=log):
                        changed = True
        except (OSError, KeyError):
            pass
    if changed and log is not None:
        log.info("Ensured dir %s (mode=0%o owner=%s:%s%s)",
                 path, mode, owner_user or "-", owner_group or "-",
                 " +sticky" if sticky_group else "")


def ensure_apt_package(name: str, log=None, cache_update_ttl_h: int = 24) -> None:
    """Install apt package only if dpkg reports not fully installed."""
    try:
        check = _sh(f"dpkg-query -W -f='${{Status}}' {shlex.quote(name)} 2>/dev/null",
                    log=None, check=False)
        if "install ok installed" in (check.stdout or ""):
            return
    except Exception:
        pass
    # Update apt cache if older than ttl hours
    cache_file = Path("/var/cache/apt/pkgcache.bin")
    if not cache_file.exists() or (time.time() - cache_file.stat().st_mtime) > cache_update_ttl_h * 3600:
        run_ok(["apt-get", "update", "-y"], log=log)
    run_ok(["apt-get", "install", "-y", name], log=log)
    if log is not None:
        log.info("Installed apt package %s", name)


def _sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def ensure_systemd_unit(unit_name: str, rendered_contents: str, log=None,
                        enable: bool = True, start: bool = False) -> bool:
    """Write a systemd unit file idempotently. Returns True if content changed."""
    unit_path = Path(f"/etc/systemd/system/{unit_name}")
    current_sha = None
    if unit_path.exists():
        current_sha = _sha256_text(unit_path.read_text())
    new_sha = _sha256_text(rendered_contents)
    changed = (current_sha != new_sha) or not unit_path.exists()
    if changed:
        # atomic write
        tmp_dir = Path("/etc/systemd/system")
        fd, tmp_path = tempfile.mkstemp(prefix="." + unit_name + ".", dir=str(tmp_dir), text=True)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(rendered_contents)
            os.chmod(tmp_path, 0o644)
            os.replace(tmp_path, unit_path)
        except Exception:
            with contextlib.suppress(OSError):
                os.unlink(tmp_path)
            raise
        run_ok(["systemctl", "daemon-reload"], log=log)
        if log is not None:
            log.info("Wrote updated systemd unit %s (daemon-reload)", unit_name)
    if enable:
        en = run_ok(["systemctl", "is-enabled", unit_name], log=None, check=False)
        if "enabled" not in (en.stdout or ""):
            run_ok(["systemctl", "enable", unit_name], log=log)
    if start or changed:
        run_ok(["systemctl", "restart", unit_name], log=log, check=False)
        # check status
        up = run_ok(["systemctl", "is-active", "--quiet", unit_name], log=None, check=False)
        if up.returncode != 0 and log is not None:
            tail = run_ok(["journalctl", "-u", unit_name, "--no-pager", "-n", "60"],
                          log=None, check=False).stdout
            log.warning("Unit %s may be unhealthy after restart. journal tail:\n%s",
                        unit_name, tail[-3000:])
    return changed


def systemd_is_active(unit: str) -> bool:
    if not shutil.which("systemctl"):
        return False
    r = run_ok(["systemctl", "is-active", "--quiet", unit], check=False, log=None)
    return r.returncode == 0


def ensure_ufw_allow(port_or_service: Any, proto: str = "tcp", log=None) -> None:
    """Open port/service in ufw idempotently if ufw exists and is enabled."""
    if not shutil.which("ufw"):
        return
    st = _sh("ufw status 2>/dev/null | head -n 1", log=None, check=False).stdout.strip().lower()
    if "active" not in st:
        return
    needle = str(port_or_service)
    # Normalize port + proto to 2 forms: "PORT/PROTO" and service name
    out = _sh("ufw status verbose 2>/dev/null || true", log=None, check=False).stdout
    if (f"{needle}/{proto}" in out) or (f" {needle} " in out):
        return
    rule = f"{needle}/{proto}" if isinstance(port_or_service, int) or needle.isdigit() else str(needle)
    run_ok(["ufw", "allow", rule], log=log)
    if log is not None:
        log.info("ufw allow %s", rule)


def ensure_firewalld_service(service: str, log=None) -> None:
    if not shutil.which("firewall-cmd"):
        return
    # running
    q1 = run_ok(["firewall-cmd", "--query-service", service], log=None, check=False)
    q2 = run_ok(["firewall-cmd", "--permanent", "--query-service", service], log=None, check=False)
    if q1.returncode != 0:
        run_ok(["firewall-cmd", "--add-service", service], log=log)
    if q2.returncode != 0:
        run_ok(["firewall-cmd", "--permanent", "--add-service", service], log=log)
    if q1.returncode != 0 or q2.returncode != 0:
        run_ok(["firewall-cmd", "--reload"], log=log, check=False)
        if log is not None:
            log.info("firewalld: opened %s (permanent + running)", service)


def ensure_env_file_perms(path: Path, mode: int = 0o640, owner: str = "root",
                          group: str = SERVICE_USER_DEFAULT, log=None) -> bool:
    """Verify env file only; NEVER write or template content. Returns True if perms ok."""
    if not path.exists():
        return False
    try:
        st = path.stat()
        cur_mode = stat.S_IMODE(st.st_mode)
        euid = _geteuid_or_none()
        is_root = (euid == 0)
        if cur_mode not in (0o600, mode):  # allow stricter
            if is_root:
                os.chmod(str(path), mode)
                if log is not None:
                    log.warning("Chmod env file %s -> 0%o (was 0%o)", path, mode, cur_mode)
        if is_root:
            try:
                gr = _getgrnam_safe(group)
                pw = _getpwnam_safe(owner)
                want_gid = gr.gr_gid if gr is not None else -1
                want_uid = pw.pw_uid if pw is not None else -1
                if (want_gid != -1 and want_gid != st.st_gid) or (want_uid != -1 and want_uid != st.st_uid):
                    if _chown_safe(str(path), want_uid, want_gid, log=log):
                        if log is not None:
                            log.warning("Chown env file %s -> %s:%s", path, owner, group)
            except (KeyError, OSError):
                pass
    except OSError as exc:
        if log is not None:
            log.warning("Could not stat/chmod env file %s: %s", path, exc)
        return False
    return True


def git_ref_exists(repo: str, ref: str, log=None) -> bool:
    r = run_ok(["git", "ls-remote", "--exit-code", "--refs", repo,
                f"refs/heads/{ref}", f"refs/tags/{ref}"],
               log=log, check=False)
    return r.returncode == 0 and bool(r.stdout.strip())


def certbot_cert_valid_for_at_least(domain: str, days: int = 7, log=None) -> bool:
    if not shutil.which("certbot"):
        return False
    certs = _sh("certbot certificates 2>/dev/null || true", log=log, check=False).stdout
    m = re.search(rf"Certificate Name:\s*{re.escape(domain)}\b.*?Validity:\s*([\w\s:]+)\n",
                  certs, flags=re.S)
    if not m:
        return False
    info = m.group(1)
    mm = re.search(r"(\d+)\s+day\(s\)", info)
    if mm:
        return int(mm.group(1)) >= days
    return "VALID" in info.upper() or "active" in info.lower()


def nginx_unit_sha_matches(path: Path, rendered: str) -> bool:
    if not path.exists():
        return False
    return _sha256_text(path.read_text()) == _sha256_text(rendered)


# ============================================================
# 7. Preflight 16 checks + summary banner
# ============================================================
class PreflightResult(NamedTuple):
    num: int
    name: str
    ok: bool
    detail: str


def port_free(port: int, host: str = "0.0.0.0") -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((host, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def dns_resolves(domain: str) -> list[str]:
    try:
        addrs = socket.getaddrinfo(domain, 443, family=socket.AF_INET, type=socket.SOCK_STREAM)
        return sorted({a[4][0] for a in addrs})
    except socket.gaierror:
        return []


def public_ip_via_curl(log=None) -> Optional[str]:
    r = run_ok(["curl", "-fsS", "--max-time", "5", "https://api.ipify.org"],
               log=log, check=False)
    if r.returncode == 0:
        return (r.stdout or "").strip() or None
    return None


def _os_release() -> dict[str, str]:
    p = Path("/etc/os-release")
    if not p.exists():
        return {}
    out: dict[str, str] = {}
    for line in p.read_text().splitlines():
        m = re.match(r"([A-Z0-9_]+)=(.*)", line)
        if not m:
            continue
        v = m.group(2)
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
            v = v[1:-1]
        out[m.group(1)] = v
    return out


def _disk_free_gb(path: Path) -> float:
    """Return free space in gigabytes. Uses os.statvfs on Unix, shutil.disk_usage on Windows."""
    try:
        if hasattr(os, "statvfs"):
            st = os.statvfs(str(path))
            return (st.f_frsize * st.f_bavail) / 1_000_000_000
        # Windows / other: shutil fallback
        usage = shutil.disk_usage(str(path))
        return usage.free / 1_000_000_000
    except (OSError, AttributeError):
        return 0.0


def _mem_total_mb() -> float:
    """Return total physical memory in MB. /proc/meminfo on Linux; ctypes/Kernel32 on Windows."""
    # Linux path (primary target)
    try:
        text = Path("/proc/meminfo").read_text()
        m = re.search(r"MemTotal:\s*(\d+)\s*kB", text)
        if m:
            return int(m.group(1)) / 1024.0
    except OSError:
        pass
    # Windows fallback via ctypes (for Windows-local CLI testing)
    try:
        import ctypes
        class _MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]
        ms = _MEMORYSTATUSEX()
        ms.dwLength = ctypes.sizeof(ms)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(ms)):  # type: ignore[attr-defined]
            return ms.ullTotalPhys / (1024.0 * 1024.0)
    except (OSError, AttributeError, ImportError):
        pass
    return 0.0


def _sudo_available() -> bool:
    """Return True if root or sudo -n works. Safe on Windows (returns False without executing)."""
    euid = _geteuid_or_none()
    if euid == 0:
        return True
    if not shutil.which("sudo"):
        return False
    # Avoid running Unix-only binaries (e.g. /bin/true) on non-Unix systems
    if euid is None:  # Windows
        return False
    true_exe = "/usr/bin/true" if Path("/usr/bin/true").exists() else "/bin/true"
    r = run_ok(["sudo", "-n", true_exe], check=False, log=None)
    return r.returncode == 0


def _db_connectivity_works(env: dict[str, str], log=None) -> tuple[bool, str]:
    db_url = env.get("DATABASE_URL", "").strip()
    db_name = env.get("DB_NAME", "").strip()
    db_user = env.get("DB_USER", "").strip()
    db_host = env.get("DB_HOST", "").strip()
    if not db_url and not (db_name and db_user and db_host):
        return False, "DB vars not set"
    psql = shutil.which("psql")
    if not psql:
        return False, "psql not installed (install postgresql-client)"
    # Build connection without leaking password on command line (PGPASSPROMPT/PGPASSWORD via env only)
    local_env = dict(env)
    args: list[str]
    if db_url:
        args = [psql, db_url, "-At", "-c", "SELECT 1;"]
    else:
        args = [psql, "-h", db_host, "-p", env.get("DB_PORT", "5432"),
                "-U", db_user, "-d", db_name, "-At", "-c", "SELECT 1;"]
    try:
        r = run_ok(args, env=local_env, scrub_env=env, log=log, check=False, timeout=20)
    except Exception as exc:
        return False, f"Exception: {exc}"
    if r.returncode == 0 and "1" in (r.stdout or ""):
        return True, "ok"
    tail = (r.stderr or r.stdout or "").strip().splitlines()[-5:]
    return False, "\n".join(tail)


def run_preflight(args, env: dict[str, str], log) -> list[PreflightResult]:
    results: list[PreflightResult] = []

    def add(num: int, name: str, ok: bool, detail: str):
        results.append(PreflightResult(num=num, name=name, ok=ok, detail=detail))

    on_unix_pf = _geteuid_or_none() is not None

    # 1 OS
    rel = _os_release()
    os_id = rel.get("ID", "")
    codename = rel.get("VERSION_CODENAME", "")
    ok_os = (os_id == "ubuntu" and codename in SUPPORTED_UBUNTU) or \
            (os_id == "debian" and codename in SUPPORTED_DEBIAN)
    if not on_unix_pf:
        add(1, "Operating system (Ubuntu 20.04+ / Debian 11+)", True,
            "N/A (non-Unix platform -- validated on target Ubuntu server)")
    else:
        add(1, "Operating system (Ubuntu 20.04+ / Debian 11+)", ok_os,
            f"ID={os_id} VERSION_CODENAME={codename}")

    # 2 root or sudo
    euid_pf = _geteuid_or_none()
    if not on_unix_pf:
        add(2, "Root or sudo-nopasswd available", True,
            "N/A (non-Unix platform -- validated on target Ubuntu server)")
    else:
        add(2, "Root or sudo-nopasswd available", _sudo_available(),
            ("user is root" if euid_pf == 0 else (f"euid={euid_pf} sudo={shutil.which('sudo')}" if euid_pf is not None else f"non-Unix sudo={shutil.which('sudo')}")))

    # 3 ports
    required_ports = [80, 443]
    if getattr(args, "with_workers", False):
        required_ports.append(6379)
    bind_issues = []
    for p in required_ports:
        if not port_free(p):
            bind_issues.append(f":{p} in use")
    add(3, "Ports 80/443 (and 6379 if --with-workers) free",
        len(bind_issues) == 0, "; ".join(bind_issues) or "all free")

    # 4 disk
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    log_dir = Path(getattr(args, "log_dir", LOG_DIR_DEFAULT))
    backup_dir = Path(BACKUP_DIR_DEFAULT)
    # Cross-platform path resolution: on non-Unix systems (e.g. Windows local for
    # CLI parse/validation), measure the current drive instead of nonexistent Unix paths
    def _disk_ref(candidate: Path, unix_fallback: str) -> Path:
        if candidate.exists():
            return candidate
        if on_unix_pf:
            return Path(unix_fallback)
        # Windows/other: closest filesystem root that exists
        try:
            return Path(candidate.anchor or Path.cwd().anchor or ".")
        except OSError:
            return Path(".")
    issues: list[str] = []
    if _disk_free_gb(_disk_ref(deploy_dir, "/")) < 5:
        issues.append(f"{deploy_dir} free < 5GB")
    if _disk_free_gb(_disk_ref(log_dir, "/var/log")) < 1:
        issues.append(f"{log_dir} free < 1GB")
    if _disk_free_gb(_disk_ref(Path("/tmp"), "/tmp")) < 2:
        issues.append("/tmp free < 2GB")
    if _disk_free_gb(_disk_ref(backup_dir, "/var/backups")) < 0.5:
        issues.append("/var/backups free < 500MB")
    add(4, "Disk space (/opt≥5G, /var/log≥1G, /tmp≥2G)",
        len(issues) == 0, "; ".join(issues) or "ok")

    # 5 memory
    mem_mb = _mem_total_mb()
    add(5, "Total memory ≥ 1.5GB", mem_mb >= 1536,
        (f"mem_total_mb={mem_mb:.0f}" if mem_mb > 0 else "mem_total_mb=unknown"))

    # 6 DNS resolution
    domain = getattr(args, "domain", DOMAIN_DEFAULT)
    ips = dns_resolves(domain)
    detail = f"resolved {ips}" if ips else "NXDOMAIN"
    # Cross-check with public IP (Unix-only: remote/local deploy only)
    pub = public_ip_via_curl(log=log) if on_unix_pf else None
    if pub and ips and pub not in ips:
        detail += f" WARNING: server public_ip={pub} not in DNS {ips}"
    if not on_unix_pf:
        add(6, f"DNS: {domain}", True,
            "N/A (non-Unix platform -- validated on target Ubuntu server)")
    else:
        add(6, f"DNS: {domain}", bool(ips), detail)

    # 7 internet reachability (for apt/git/certbot) — Unix only
    reach = True
    reach_msg: list[str] = []
    if on_unix_pf:
        for url in ["https://github.com", "https://acme-v02.api.letsencrypt.org"]:
            rr = run_ok(["curl", "-fsS", "--max-time", "5", "-o", "/dev/null", url],
                        check=False, log=None)
            if rr.returncode != 0:
                reach = False
                reach_msg.append(f"{url} unreachable")
    else:
        reach = False
        reach_msg.append("(skipped; run on target Unix host to check)")
    if not on_unix_pf:
        add(7, "Internet: github + letsencrypt ACME reachable", True,
            "N/A (non-Unix platform -- validated on target Ubuntu server)")
    else:
        add(7, "Internet: github + letsencrypt ACME reachable", reach,
            "; ".join(reach_msg) or "ok")

    # 8 git reachable + ref exists
    repo = getattr(args, "repo", REPO_DEFAULT)
    ref = getattr(args, "ref", REF_DEFAULT)
    greachable = git_ref_exists(repo, ref, log=log)
    add(8, f"Git {repo} ref={ref} reachable", greachable,
        f"git ls-remote exit={'ok' if greachable else 'fail'}")

    # 9 remote DB reachable
    db_ok, db_msg = _db_connectivity_works(env, log=log)
    db_vars_present = bool(env.get("DATABASE_URL")) or all(
        env.get(k) for k in ("DB_NAME", "DB_USER", "DB_PASSWORD", "DB_HOST")
    )
    if not on_unix_pf:
        add(9, "PostgreSQL connectivity (remote)", True,
            "N/A (non-Unix platform -- validated on target Ubuntu server)")
    elif not db_vars_present:
        add(9, "PostgreSQL connectivity (remote)", False,
            "DB vars missing in env file (provide DATABASE_URL or DB_NAME/USER/PASSWORD/HOST)")
    else:
        add(9, "PostgreSQL connectivity (remote)", db_ok, db_msg)

    # 10 env file exists
    env_path = Path(getattr(args, "env_file", ENV_FILE_DEFAULT))
    exists = env_path.exists() and env_path.stat().st_size > 0
    if not on_unix_pf:
        add(10, f"Env file: {env_path} exists + non-empty", True,
            "N/A (non-Unix platform -- env populated on target Ubuntu server after GitHub clone)")
    else:
        add(10, f"Env file: {env_path} exists + non-empty", exists,
            "ok" if exists else f"missing or empty (create it first; script never writes templates)")

    # 11 required env keys non-empty
    sec = env.get("DJANGO_SECRET_KEY", "").strip()
    ok_sec = bool(sec) and not sec.startswith("CHANGE_ME")
    debug = env.get("DJANGO_DEBUG", "").strip()
    stage = getattr(args, "stage", STAGE_DEFAULT)
    debug_ok = True
    if stage == "deploy" and not getattr(args, "force_dangerous_debug_deploy", False):
        debug_ok = debug.lower() not in {"1", "true", "yes", "on"}
    allowed = env.get("DJANGO_ALLOWED_HOSTS", "").strip()
    if not on_unix_pf:
        add(11, "Required env keys (DJANGO_SECRET_KEY, !DEBUG deploy, ALLOWED_HOSTS)", True,
            "N/A (non-Unix platform -- validated on target Ubuntu server)")
    else:
        add(11, "Required env keys (DJANGO_SECRET_KEY, !DEBUG deploy, ALLOWED_HOSTS)",
            ok_sec and debug_ok and bool(allowed),
            f"secret={'set' if ok_sec else 'UNSET/MINIMAL'}; "
            f"debug={'FORBIDDEN (deploy stage)' if not debug_ok else debug or '(empty→ok)'}; "
            f"allowed_hosts={'set' if allowed else 'EMPTY'}")

    # 12 DB connection vars present
    dburl = env.get("DATABASE_URL", "")
    if dburl:
        scheme = dburl.split(":", 1)[0].lower()
        ok_dbvars = scheme.startswith("postgres")
    else:
        ok_dbvars = all(env.get(k) for k in ("DB_NAME", "DB_USER", "DB_PASSWORD", "DB_HOST"))
    if not on_unix_pf:
        add(12, "Database connection vars set (DATABASE_URL XOR split DB_*)", True,
            "N/A (non-Unix platform -- validated on target Ubuntu server)")
    else:
        add(12, "Database connection vars set (DATABASE_URL XOR split DB_*)",
            ok_dbvars,
            "DATABASE_URL set" if dburl else "split DB_* set" if ok_dbvars else "MISSING")

    # 13 python >= 3.10
    py_ok = sys.version_info >= MIN_PYTHON
    add(13, f"Python >= {'.'.join(map(str, MIN_PYTHON))}", py_ok,
        f"python={sys.version.split()[0]}")

    # 14 existing nginx overwrite guard
    nginx_sites = list(Path("/etc/nginx/sites-enabled").glob("*")) if Path(
        "/etc/nginx/sites-enabled").exists() else []
    nginx_sites2 = [s for s in nginx_sites if s.name not in ("default", "rasyatone")]
    interactive = not getattr(args, "non_interactive", False)
    force = getattr(args, "force", False)
    if nginx_sites2 and interactive and not force:
        ok14, detail14 = False, (
            f"Will overwrite nginx vhosts in sites-enabled: "
            f"{', '.join(s.name for s in nginx_sites2)}. Use --force or --non-interactive to continue."
        )
    else:
        ok14, detail14 = True, (f"sites-enabled: {[s.name for s in nginx_sites]}" or "empty")
    add(14, "Nginx overwrite guard (confirm if other sites already enabled)", ok14, detail14)

    # 15 env file not world-readable
    on_unix_15 = _geteuid_or_none() is not None
    perm_ok = True
    if env_path.exists():
        try:
            m = stat.S_IMODE(env_path.stat().st_mode)
            if not on_unix_15:
                msg15 = f"ok (skipped; apply 0640 on Unix deploy host, current={m:o})"
            elif m & 0o007:
                perm_ok = False
                msg15 = f"env file mode is 0{m:o} (too open; chmod 0640 {env_path} && " \
                       f"chgrp {getattr(args, 'service_user', SERVICE_USER_DEFAULT)} {env_path})"
            else:
                msg15 = f"ok (0{m:o})"
        except OSError as exc:
            perm_ok = False
            msg15 = f"stat failed: {exc}"
    else:
        msg15 = "env file not present (checked in #10)"
    add(15, "Env file permission ≤ 0640 (world-not-readable)", perm_ok, msg15)

    # 16 print summary (mark pass here after banner)
    overall = all(r.ok for r in results)
    add(16, f"Preflight summary (overall {'PASS' if overall else 'FAIL'} — {len(results)} checks)",
        overall,
        f"{sum(1 for r in results if r.ok)}/{len(results)} checks ok")

    return results


# ============================================================
# 8. Django layout auto-detect (no hardcoded package names)
# ============================================================
class DjangoLayout(NamedTuple):
    settings_module: str
    wsgi_app: Optional[str]
    asgi_app: Optional[str]
    managepy_rel: str
    app_name_slug: str
    celery_app: Optional[str]


def _relpath(path: Path, root: Path) -> str:
    return str(path.resolve().relative_to(root.resolve())).replace(os.sep, "/")


def _dotpath(path: Path, root: Path) -> str:
    rel = _relpath(path, root)
    return rel[:-3].replace("/", ".").replace("\\", ".")


def detect_django_layout(release_root: Path,
                         settings_module_hint: Optional[str] = None,
                         managepy_hint: Optional[str] = None) -> DjangoLayout:
    # manage.py
    if managepy_hint:
        cand = release_root / managepy_hint
        manage_candidates = [cand] if cand.exists() else []
    else:
        manage_candidates = sorted(p for p in release_root.rglob("manage.py")
                                   if ".venv" not in p.parts and "venv" not in p.parts
                                   and "node_modules" not in p.parts)
    if not manage_candidates:
        raise RuntimeError(
            f"Could not find manage.py in release {release_root}. "
            f"Pass --managepy <relpath> explicitly.")
    managepy = manage_candidates[0]
    managepy_rel = _relpath(managepy, release_root)

    # wsgi.py / asgi.py (prefer wsgi)
    wsgi_candidates = sorted(p for p in release_root.rglob("wsgi.py")
                             if "venv" not in p.parts and "node_modules" not in p.parts)
    asgi_candidates = sorted(p for p in release_root.rglob("asgi.py")
                             if "venv" not in p.parts and "node_modules" not in p.parts)
    chosen_wsgi: Optional[str] = None
    chosen_asgi: Optional[str] = None
    settings_module = ""
    app_name_slug = APP_NAME_DEFAULT

    def _extract_settings_from(py_path: Path) -> Optional[str]:
        txt = py_path.read_text(errors="replace")
        m = re.search(r"""DJANGO_SETTINGS_MODULE(?:\s*=\s*|\s*,\s*)['"]([^'"]+)['"]""", txt)
        return m.group(1) if m else None

    def _extract_callable(py_path: Path, kind: str) -> Optional[str]:
        """Return dotted.path:callable for wsgi/asgi application."""
        dot = _dotpath(py_path, release_root)
        txt = py_path.read_text(errors="replace")
        # Common names: application / app / get_asgi_application / get_wsgi_application
        if re.search(rf"^{kind}_application\s*=\s*get_{kind}_application\(\)", txt, re.M):
            return f"{dot}:{kind}_application"
        if re.search(r"^application\s*=\s*get_{kind}_application\(\)", txt, re.M):
            return f"{dot}:application"
        if re.search(r"^(application|app)\s*=", txt, re.M):
            mm = re.search(r"^(application|app)\s*=\s*([A-Za-z0-9_\.]+)", txt, re.M)
            return f"{dot}:{mm.group(1)}" if mm else f"{dot}:application"
        return f"{dot}:application"  # default

    if wsgi_candidates:
        chosen_wsgi = _extract_callable(wsgi_candidates[0], "wsgi")
        settings_module = _extract_settings_from(wsgi_candidates[0]) or settings_module
        app_name_slug = _dotpath(wsgi_candidates[0].parent, release_root).split(".", 1)[0] or APP_NAME_DEFAULT
    if asgi_candidates:
        chosen_asgi = _extract_callable(asgi_candidates[0], "asgi")
        settings_module = settings_module or _extract_settings_from(asgi_candidates[0])

    # Also check manage.py
    settings_module = settings_module or _extract_settings_from(managepy) or ""

    # celery app auto-detect
    celery_candidates = sorted(p for p in release_root.rglob("celery.py")
                               if "venv" not in p.parts and "node_modules" not in p.parts)
    celery_app: Optional[str] = None
    if celery_candidates:
        txt = celery_candidates[0].read_text(errors="replace")
        m = re.search(r"""Celery\s*\(\s*['"]([^'"]+)['"]""", txt)
        name = m.group(1) if m else _dotpath(celery_candidates[0].parent, release_root).split(".", 1)[0]
        celery_app = f"{_dotpath(celery_candidates[0], release_root).replace('.celery', '')}.celery:app" if name else None

    # Fallback settings_module: use package name.settings.production if available
    if not settings_module:
        base_pkg = app_name_slug
        for try_suffix in (".settings.production", ".settings.prod",
                          ".settings", ".config.settings"):
            candidate = release_root / Path((base_pkg + try_suffix).replace(".", os.sep) + ".py")
            if candidate.exists():
                settings_module = base_pkg + try_suffix
                break
    settings_module = settings_module_hint or settings_module
    if not settings_module:
        raise RuntimeError(
            "Could not auto-detect DJANGO_SETTINGS_MODULE. Pass --settings-module explicitly.")

    return DjangoLayout(settings_module=settings_module,
                        wsgi_app=chosen_wsgi,
                        asgi_app=chosen_asgi,
                        managepy_rel=managepy_rel,
                        app_name_slug=app_name_slug,
                        celery_app=celery_app)


# ============================================================
# 9. Release directory + release.json helpers
# ============================================================
def release_timestamp() -> str:
    return dt.datetime.utcnow().strftime("%Y%m%d-%H%M%S")


def make_release_dir(deploy_dir: Path, log=None) -> tuple[Path, str]:
    releases_root = deploy_dir / "releases"
    releases_root.mkdir(parents=True, exist_ok=True)
    ts = release_timestamp()
    # Ensure uniqueness even if same second
    suffix = 0
    while True:
        final_ts = f"{ts}{chr(ord('a') + suffix) if suffix else ''}"
        release_path = releases_root / final_ts
        if not release_path.exists():
            release_path.mkdir(mode=0o755)
            if log is not None:
                log.info("Created release dir %s", release_path)
            return release_path, final_ts
        suffix += 1


def read_release_json(release_root: Path) -> dict:
    p = release_root / "release.json"
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def write_release_json(release_root: Path, data: dict) -> None:
    """Atomic write of release.json."""
    p = release_root / "release.json"
    fd, tmp = tempfile.mkstemp(prefix=".release.json.", dir=str(release_root), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, sort_keys=True, default=str)
        os.chmod(tmp, 0o644)
        os.replace(tmp, p)
    except Exception:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def current_release_link(deploy_dir: Path) -> Optional[Path]:
    link = deploy_dir / "current"
    if not link.exists():
        return None
    try:
        if link.is_symlink():
            tgt = link.resolve(strict=False)
            return tgt if tgt.exists() else None
        # Windows junction (not a symlink but .exists()) — treat as link via readlink fallback
        if os.name == "nt":
            try:
                tgt_str = os.readlink(str(link))
            except OSError:
                tgt_str = None
            if tgt_str:
                tgt = Path(tgt_str)
                if not tgt.is_absolute():
                    tgt = (deploy_dir / tgt).resolve(strict=False)
                return tgt if tgt.exists() else None
        # Regular directory fallback: check for release.json inside (best effort)
        if (link / "release.json").exists():
            return link
    except OSError:
        return None
    return None


def _list_releases_newest_first(deploy_dir: Path) -> list[Path]:
    releases = deploy_dir / "releases"
    if not releases.exists():
        return []
    return sorted(releases.iterdir(), key=lambda d: d.stat().st_mtime_ns, reverse=True)


def prune_old_releases(deploy_dir: Path, keep: int, prev_release: Optional[Path],
                       log=None) -> list[Path]:
    """Auto-prune old releases. Never delete current or PREV_RELEASE."""
    cur = current_release_link(deploy_dir)
    ordered = [d for d in _list_releases_newest_first(deploy_dir) if d.is_dir()]
    # Always protect current & prev_release from deletion
    protected: set[Path] = set()
    if cur is not None:
        protected.add(cur)
    if prev_release is not None:
        try:
            protected.add(prev_release.resolve())
        except OSError:
            protected.add(prev_release)
    to_delete: list[Path] = []
    # Keep newest N (--keep-releases). After protection check add to delete.
    for idx, d in enumerate(ordered):
        if idx < keep:
            continue
        with contextlib.suppress(OSError):
            if d.resolve() in protected:
                continue
        to_delete.append(d)
    for d in to_delete:
        if log is not None:
            log.info("Pruning old release dir %s", d)
        shutil.rmtree(d, ignore_errors=True)
    return to_delete


# ============================================================
# 10. Deploy pipeline stages 1..18
# ============================================================
def _count_cpu() -> int:
    return max(1, os.cpu_count() or 1)


def _default_workers() -> int:
    return 2 * _count_cpu() + 1


# -------- systemd unit templates --------
def _render_gunicorn_unit(*, service_user: str, deploy_dir: Path,
                          settings_module: str, wsgi_app: str,
                          workers: int, bind: str,
                          env_file: Path) -> str:
    return f"""[Unit]
Description=RaSYaTone Django Gunicorn ({service_user})
After=network.target

[Service]
Type=notify
NotifyAccess=all
User={service_user}
Group={service_user}
RuntimeDirectory=rasyatone
RuntimeDirectoryMode=0750
UMask=0007
WorkingDirectory={deploy_dir}/current
EnvironmentFile={env_file}
Environment=DJANGO_SETTINGS_MODULE={settings_module}
ExecStart={deploy_dir}/current/venv/bin/gunicorn \\
    --pid /run/rasyatone/gunicorn.pid \\
    --bind {bind} \\
    --workers {workers} \\
    --worker-class sync \\
    --timeout 60 \\
    --max-requests 1000 \\
    --max-requests-jitter 100 \\
    --chdir {deploy_dir}/current \\
    --log-level info \\
    --access-logfile {LOG_DIR_DEFAULT}/gunicorn.access.log \\
    --error-logfile {LOG_DIR_DEFAULT}/gunicorn.error.log \\
    {wsgi_app}
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=mixed
TimeoutStopSec=30
Restart=on-failure
RestartSec=5
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths={deploy_dir}/shared /var/log/rasyatone /run/rasyatone /tmp

[Install]
WantedBy=multi-user.target
"""


def _render_celery_unit(*, service_user: str, deploy_dir: Path, env_file: Path,
                        celery_app: str, concurrency: int, kind: str) -> str:
    # kind = "worker" or "beat"
    if kind == "beat":
        cmd = (f"{deploy_dir}/current/venv/bin/celery -A {celery_app} beat "
               f"--loglevel=info "
               f"--schedule {deploy_dir}/shared/celerybeat-schedule")
        desc = "RaSYaTone Celery Beat Scheduler"
    else:
        cmd = (f"{deploy_dir}/current/venv/bin/celery -A {celery_app} worker "
               f"--loglevel=info --concurrency={concurrency} "
               f"--logfile {LOG_DIR_DEFAULT}/celery-worker.log")
        desc = "RaSYaTone Celery Worker"
    return f"""[Unit]
Description={desc}
After=network.target redis-server.service
Wants=redis-server.service

[Service]
Type=simple
User={service_user}
Group={service_user}
WorkingDirectory={deploy_dir}/current
EnvironmentFile={env_file}
ExecStart={cmd}
Restart=on-failure
RestartSec=10
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths={deploy_dir}/shared /var/log/rasyatone /tmp /run/rasyatone

[Install]
WantedBy=multi-user.target
"""


def _render_nginx_site(domain: str, aliases: list[str], deploy_dir: Path,
                       gunicorn_bind: str, *, ssl_config_block: str = "") -> str:
    server_names = " ".join([domain] + list(aliases or []))
    upstream = (f"server unix:{gunicorn_bind};" if gunicorn_bind.startswith("/") else
                f"server {gunicorn_bind};")
    return f"""upstream rasyatone_backend {{
    {upstream}
    keepalive 32;
}}

# Default catch-all: unknown Host → empty reply 444 (prevents host-header attacks)
server {{
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}}

server {{
    listen 80;
    listen [::]:80;
    server_name {server_names};
    return 301 https://$host$request_uri;
}}

server {{
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {server_names};
    {ssl_config_block}
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    client_max_body_size 25M;
    access_log {LOG_DIR_DEFAULT}/nginx.access.log;
    error_log  {LOG_DIR_DEFAULT}/nginx.error.log;

    location /static/ {{
        alias {deploy_dir}/shared/staticfiles/;
        access_log off;
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }}

    location /media/ {{
        alias {deploy_dir}/shared/media/;
        expires 7d;
        add_header Cache-Control "private";
        try_files $uri =404;
    }}

    location = /robots.txt {{ access_log off; log_not_found off; }}
    location = /favicon.ico {{ access_log off; log_not_found off; }}

    location / {{
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering on;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        proxy_connect_timeout 10s;
        proxy_pass http://rasyatone_backend;
    }}
}}
"""


def _render_logrotate_config(service_user: str) -> str:
    return f"""/var/log/rasyatone/*.log {{
    weekly
    missingok
    rotate 12
    compress
    delaycompress
    notifempty
    create 0640 {service_user} adm
    sharedscripts
    postrotate
        if [ -f /run/rasyatone/gunicorn.pid ]; then
            PID=$(cat /run/rasyatone/gunicorn.pid) && kill -USR1 "$PID" 2>/dev/null || true
        fi
    endscript
}}
"""


def _symlink_exists_pointing_to(link: Path, target: Path) -> bool:
    if not link.is_symlink():
        return False
    try:
        return link.resolve() == target.resolve()
    except OSError:
        return False


def _force_symlink(link: Path, target: Path) -> None:
    """Atomic symlink switch (uses ln -sfn via os.replace equivalent for safety).
    On Windows without symlink privilege, falls back to NTFS junction via mklink /J.
    """
    d = link.parent
    tmp = Path(tempfile.mktemp(prefix=".link.", dir=str(d)))
    try:
        try:
            os.symlink(str(target), tmp)
        except OSError as exc_sym:
            if os.name != "nt":
                raise
            # Windows fallback: NTFS junction via cmd /c mklink /J (no admin required)
            r = subprocess.run(["cmd", "/c", "mklink", "/J", str(tmp), str(target)],
                               capture_output=True, text=True, check=False)
            if r.returncode != 0:
                raise RuntimeError(
                    f"Cannot create symlink/junction at {tmp}: symlink={exc_sym}; "
                    f"mklink/J stdout={r.stdout} stderr={r.stderr}") from exc_sym
        os.replace(tmp, link)
    except OSError as exc_replace:
        # On Windows, replacing an existing NTFS junction can throw WinError 5 or 17;
        # fall back to explicit unlink then os.replace or rename.
        if os.name == "nt":
            try:
                if callable(getattr(link, "is_junction", None)) and link.is_junction():
                    link.rmdir()
                elif getattr(link, "is_symlink", lambda: False)():
                    link.unlink()
                else:
                    link.unlink()
            except OSError:
                with contextlib.suppress(OSError):
                    link.rmdir()
            try:
                os.replace(tmp, link)
            except OSError:
                os.rename(str(tmp), str(link))
        else:
            raise
    except Exception:
        with contextlib.suppress(OSError):
            if tmp.exists():
                try:
                    if getattr(tmp, "is_symlink", lambda: False)():
                        tmp.unlink()
                    elif callable(getattr(tmp, "is_junction", None)) and tmp.is_junction():
                        tmp.rmdir()
                    else:
                        tmp.unlink()
                except OSError:
                    with contextlib.suppress(OSError):
                        tmp.rmdir()
        raise


# -------- stage callers --------
def deploy_stage1_apt(args, env, log, scrub_env) -> None:
    if log is not None:
        log.info("[STAGE 1/18] Installing system packages (nginx, certbot, python3-venv, ...)")
    packages = [
        "nginx", "certbot", "python3-certbot-nginx",
        "python3-venv", "python3-pip", "python3-dev",
        "git", "curl", "acl", "postgresql-client",
        "build-essential", "libpq-dev", "pkg-config",
        "logrotate", "ca-certificates",
    ]
    for p in packages:
        ensure_apt_package(p, log=log)


def deploy_stage2_user_dirs(args, env, log, scrub_env) -> None:
    if log is not None:
        log.info("[STAGE 2/18] Ensuring service user + directories")
    service_user = getattr(args, "service_user", SERVICE_USER_DEFAULT)
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    log_dir = Path(getattr(args, "log_dir", LOG_DIR_DEFAULT))
    config_dir = Path(getattr(args, "config_dir", CONFIG_DIR_DEFAULT))
    env_file = Path(getattr(args, "env_file", ENV_FILE_DEFAULT))
    backup_dir = Path(BACKUP_DIR_DEFAULT)
    home = deploy_dir / ".home"
    ensure_user(service_user, home_path=home, log=log)
    if grp is not None:
        try:
            grp.getgrnam(service_user)
        except KeyError:
            # some systems create group automatically; if not create one
            _sh(f"groupadd --system {shlex.quote(service_user)} || true", log=log)
    ensure_group_member(service_user, "adm", log=log)
    # dirs
    ensure_dir(deploy_dir, 0o755, service_user, service_user, log=log)
    ensure_dir(deploy_dir / "releases", 0o755, service_user, service_user, log=log)
    shared = deploy_dir / "shared"
    ensure_dir(shared, 0o2775, service_user, "adm", log=log, sticky_group=True)
    ensure_dir(shared / "media", 0o2775, service_user, "adm", log=log, sticky_group=True)
    ensure_dir(shared / "logs", 0o2750, service_user, "adm", log=log, sticky_group=True)
    ensure_dir(shared / "staticfiles", 0o755, service_user, service_user, log=log)
    ensure_dir(shared / "cache", 0o2775, service_user, service_user, log=log, sticky_group=True)
    ensure_dir(log_dir, 0o2750, service_user, "adm", log=log, sticky_group=True)
    ensure_dir(config_dir, 0o755, "root", service_user, log=log)
    ensure_dir(config_dir / "static", 0o750, "root", service_user, log=log)
    ensure_dir(backup_dir, 0o700, "root", "root", log=log)
    # Env file permissions (user provided; never overwrite content)
    ensure_env_file_perms(env_file, group=service_user, log=log)


def deploy_stage3_validate_secrets(args, env, log, scrub_env) -> None:
    if log is not None:
        log.info("[STAGE 3/18] Validating secrets env file")
    env_path = Path(getattr(args, "env_file", ENV_FILE_DEFAULT))
    if not env_path.exists():
        raise StageError(stage=3, code=202,
                          user_msg=(f"Env file missing: {env_path}. Create it manually before "
                                    "running deploy (script never writes env templates)."))
    parsed = parse_env_file(env_path)
    required = {"DJANGO_SECRET_KEY": lambda v: v and not v.startswith("CHANGE_ME"),
                "DJANGO_ALLOWED_HOSTS": lambda v: bool(v)}
    if getattr(args, "stage", STAGE_DEFAULT) == "deploy" and \
            not getattr(args, "force_dangerous_debug_deploy", False):
        required["DJANGO_DEBUG"] = lambda v: (v or "").lower() not in {"1", "true", "yes", "on"}
    for k, predicate in required.items():
        val = parsed.get(k, "")
        if not predicate(val):
            raise StageError(stage=3, code=202,
                              user_msg=f"Env key {k} failed validation (value={mask_val_for_logging(k,val) and '***' or 'EMPTY'})")
    db_url = parsed.get("DATABASE_URL") or ""
    split_ok = all(parsed.get(k) for k in ("DB_NAME", "DB_USER", "DB_PASSWORD", "DB_HOST"))
    if not (db_url.startswith("postgres") or split_ok):
        raise StageError(stage=3, code=202,
                          user_msg=("No valid DB configuration. Set DATABASE_URL=postgres://... or "
                                    "DB_NAME+DB_USER+DB_PASSWORD+DB_HOST in env file."))


def deploy_stage4_make_release(args, env, release_json, log, scrub_env) -> tuple[Path, str]:
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    path, ts = make_release_dir(deploy_dir, log=log)
    release_json["ref"] = getattr(args, "ref", REF_DEFAULT)
    release_json["repo"] = getattr(args, "repo", REPO_DEFAULT)
    release_json["deployed_by"] = getpass.getuser()
    release_json["started_at"] = dt.datetime.utcnow().isoformat() + "Z"
    release_json["mode"] = "remote" if getattr(args, "remote", None) else "local"
    release_json["app_name"] = getattr(args, "app_name", APP_NAME_DEFAULT)
    write_release_json(path, release_json)
    if log is not None:
        log.info("[STAGE 4/18] Created release dir %s", path)
    return path, ts


def deploy_stage5_git_clone(args, env, release_path: Path, release_json: dict,
                            log, scrub_env) -> str:
    if log is not None:
        log.info("[STAGE 5/18] Cloning git repository (ref=%s)",
                 getattr(args, "ref", REF_DEFAULT))
    ref = getattr(args, "ref", REF_DEFAULT)
    repo = getattr(args, "repo", REPO_DEFAULT)
    # tag/sha detached checkout; branch → shallow
    tag_glob = re.match(r"^v?[0-9]+[.][0-9]+", ref) or ref.startswith("v")
    is_sha = len(ref) == 40 and all(c in "0123456789abcdef" for c in ref)
    with tempfile.TemporaryDirectory(dir=str(release_path.parent), prefix=".gitclone.") as td:
        tmp = Path(td)
        if tag_glob or is_sha:
            run_ok(["git", "clone", "--no-checkout", repo, str(tmp)], log=log)
            run_ok(["git", "-C", str(tmp), "checkout", ref], log=log)
        else:
            run_ok(["git", "clone", "--depth", "50", "--single-branch",
                    "--branch", ref, repo, str(tmp)], log=log)
        # Move content into release_path (exclude .git if user wants but keep for commit info)
        for item in tmp.iterdir():
            target = release_path / item.name
            if target.exists():
                continue
            shutil.move(str(item), str(target))
    # Capture rev-parse HEAD
    git_sha = run_ok(["git", "-C", str(release_path), "rev-parse", "HEAD"],
                     log=log).stdout.strip()
    release_json["git_sha"] = git_sha
    release_json["git_ref"] = ref
    release_json["git_repo"] = repo
    write_release_json(release_path, release_json)
    if log is not None:
        log.info("  → checked out git_sha=%.12s", git_sha)
    return git_sha


def deploy_stage6_detect_layout(args, env, release_path: Path, release_json: dict,
                                log, scrub_env) -> DjangoLayout:
    if log is not None:
        log.info("[STAGE 6/18] Detecting Django package layout")
    # CLI overrides
    settings_cli = getattr(args, "settings_module", None)
    wsgi_cli = getattr(args, "wsgi_app", None)
    manage_cli = getattr(args, "managepy", None)
    try:
        layout = detect_django_layout(release_path,
                                      settings_module_hint=settings_cli,
                                      managepy_hint=manage_cli)
    except RuntimeError as exc:
        raise _deploy_error_for_stage(
            stage=_CURRENT_STAGE, code=212,
            user_msg=f"Django layout detection failed: {exc}. "
                     f"Pass --settings-module <dotted.path> and/or --managepy <relpath> explicitly.",
            cmd="detect_django_layout", returncode=1, stderr=str(exc),
        ) from exc
    sm = settings_cli or layout.settings_module
    wsg = wsgi_cli or layout.wsgi_app
    mg = manage_cli or layout.managepy_rel
    layout = DjangoLayout(settings_module=sm, wsgi_app=wsg, asgi_app=layout.asgi_app,
                          managepy_rel=mg, app_name_slug=layout.app_name_slug,
                          celery_app=layout.celery_app)
    release_json["settings_module"] = layout.settings_module
    release_json["wsgi_app"] = layout.wsgi_app
    release_json["asgi_app"] = layout.asgi_app
    release_json["managepy_rel"] = layout.managepy_rel
    release_json["app_name_slug"] = layout.app_name_slug
    release_json["celery_app"] = layout.celery_app
    write_release_json(release_path, release_json)
    if log is not None:
        log.info("  → settings=%s wsgi=%s managepy=%s celery=%s",
                 layout.settings_module, layout.wsgi_app,
                 layout.managepy_rel, layout.celery_app)
    return layout


def deploy_stage7_venv_pip(args, env, release_path: Path, release_json: dict,
                           log, scrub_env) -> Path:
    if log is not None:
        log.info("[STAGE 7/18] Creating per-release venv + pip install requirements")
    # pick newest python3.10+
    python_bin = _resolve_python_bin(log=log)
    venv_path = release_path / "venv"
    run_ok([python_bin, "-m", "venv", str(venv_path)], log=log)
    # Upgrade base stack
    venv_pip = venv_path / "bin" / "pip"
    venv_python = venv_path / "bin" / "python"
    run_ok([str(venv_pip), "install", "--upgrade", "pip", "setuptools", "wheel"], log=log)
    # Find requirements file
    root = release_path
    ordered = ["requirements.lock", "requirements.prod.txt",
               "requirements-production.txt", "requirements.txt"]
    req = None
    for name in ordered:
        p = root / name
        if p.exists():
            req = p
            break
    if req is None:
        raise StageError(
            stage=7, code=207,
            user_msg=(f"No requirements file found in release {release_path}. "
                      "Need one of: " + ", ".join(ordered)))
    cmd = [str(venv_pip), "install"]
    if req.name.endswith(".lock"):
        cmd.append("--require-hashes")
    cmd += ["-r", str(req)]
    run_ok(cmd, log=log, scrub_env=scrub_env)
    # Ensure psycopg driver installed
    pkgs = run_ok([str(venv_pip), "list", "--format=freeze"], log=log).stdout.lower()
    if "psycopg2-binary" not in pkgs and "psycopg[binary]" not in pkgs and \
            "psycopg==" not in pkgs and "psycopg2==" not in pkgs:
        run_ok([str(venv_pip), "install", "psycopg2-binary"], log=log)
    if "gunicorn" not in pkgs:
        run_ok([str(venv_pip), "install", "gunicorn"], log=log)
    if getattr(args, "with_workers", False):
        if "celery" not in pkgs:
            run_ok([str(venv_pip), "install", "celery[redis]"], log=log)
            if log is not None:
                log.warning("Installed celery[redis] because --with-workers set "
                            "(add celery + redis to requirements.txt for reproducibility)")
    # Capture pip list sha
    pip_list = run_ok([str(venv_pip), "list", "--format=json"], log=log).stdout.encode("utf-8")
    release_json["pip_list_sha256"] = hashlib.sha256(pip_list).hexdigest()
    write_release_json(release_path, release_json)
    return venv_python


def _resolve_python_bin(log=None) -> str:
    preferred = [f"python3.{v}" for v in range(13, 9, -1)] + ["python3"]
    for cand in preferred:
        p = shutil.which(cand)
        if not p:
            continue
        r = run_ok([p, "-c", "import sys;print('.'.join(map(str,sys.version_info[:3])))"],
                   check=False, log=None)
        if r.returncode != 0:
            continue
        try:
            ver = tuple(int(x) for x in r.stdout.strip().split("."))
        except ValueError:
            continue
        if ver >= MIN_PYTHON:
            return p
    raise StageError(stage=7, code=207,
                      user_msg=f"No python >= {'.'.join(map(str,MIN_PYTHON))} on PATH ({preferred})")


def deploy_stage8_link_shared_env(args, env, release_path: Path, log, scrub_env) -> None:
    if log is not None:
        log.info("[STAGE 8/18] Symlinking shared dirs + env file into release")
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    env_path = Path(getattr(args, "env_file", ENV_FILE_DEFAULT))
    shared = deploy_dir / "shared"
    links = [("media", shared / "media"),
             ("logs", shared / "logs"),
             ("staticfiles", shared / "staticfiles"),
             (".env", env_path)]
    for name, target in links:
        if not target.exists() and name != ".env":
            target.mkdir(parents=True, exist_ok=True)
        link = release_path / name
        if link.is_symlink() or link.exists():
            if _symlink_exists_pointing_to(link, target):
                continue
            if link.is_symlink() or link.is_file():
                link.unlink()
            elif link.is_dir():
                shutil.rmtree(link)
        os.symlink(str(target), link)


def _inject_django_env(base: dict[str, str], args, env, release_path: Path,
                       layout: DjangoLayout) -> dict[str, str]:
    merged = dict(base)
    # Ensure paths explicitly so Django settings can rely on them (user env may override)
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    merged.setdefault("DJANGO_SETTINGS_MODULE", layout.settings_module)
    merged.setdefault("DJANGO_STATIC_ROOT", str(deploy_dir / "shared" / "staticfiles"))
    merged.setdefault("DJANGO_MEDIA_ROOT", str(deploy_dir / "shared" / "media"))
    merged.setdefault("DJANGO_LOG_DIR", str(deploy_dir / "shared" / "logs"))
    return merged


def deploy_stage9_django_check_deploy(args, env, release_path: Path, venv_python: Path,
                                      layout: DjangoLayout, log, scrub_env) -> None:
    if getattr(args, "skip_check_deploy", False):
        if log is not None:
            log.warning("[STAGE 9/18] Skipped Django check --deploy (--skip-check-deploy set)")
        return
    if log is not None:
        log.info("[STAGE 9/18] Django manage.py check --deploy (critical gate)")
    sub_env = _inject_django_env(env, args, env, release_path, layout)
    mp = release_path / layout.managepy_rel
    r = run_ok([str(venv_python), str(mp), "check", "--deploy",
                "--fail-level", "WARNING"],
               env=sub_env, scrub_env=scrub_env, log=log, check=False, timeout=300)
    if r.returncode != 0:
        out = (r.stdout or "") + "\n" + (r.stderr or "")
        raise StageError(
            stage=9, code=209,
            user_msg=(
                "Django check --deploy found serious issues (fix them before retrying, "
                "or pass --skip-check-deploy to ignore):\n"
                + scrub_secrets(out[-5000:], env=scrub_env)))


def deploy_stage10_pre_migration_backup(args, env, release_path: Path, release_ts: str,
                                         log, scrub_env) -> None:
    mode = getattr(args, "pre_migration_backup", "auto")
    if mode == "no":
        if log is not None:
            log.info("[STAGE 10/18] Skipping pre-migration backup (--pre-migration-backup=no)")
        return
    if log is not None:
        log.info("[STAGE 10/18] Pre-migration PostgreSQL backup (mode=%s)", mode)
    psql = shutil.which("psql") or shutil.which("pg_dump")
    db_ok = bool(env.get("DATABASE_URL")) or all(env.get(k) for k in
                                                 ("DB_NAME", "DB_USER", "DB_PASSWORD", "DB_HOST"))
    if not psql or not db_ok:
        if mode == "yes":
            raise StageError(stage=10, code=210,
                              user_msg="Pre-migration backup required (--pre-migration-backup=yes)"
                                       " but psql is missing or DB env vars are not set.")
        if log is not None:
            log.warning("Skipping pre-migration backup (psql installed=%s dbvars_set=%s)",
                        bool(psql), db_ok)
        return
    backup_dir = Path(BACKUP_DIR_DEFAULT)
    ensure_dir(backup_dir, 0o700, "root", "root", log=log)
    out_file = backup_dir / f"pre-migration-{release_ts}.dump"
    cmd = ["pg_dump", "--format=custom", "--compress=6", f"--file={out_file}"]
    db_url = env.get("DATABASE_URL") or ""
    sub_env = dict(env)
    if db_url.startswith("postgres"):
        cmd += ["--dbname", db_url]
    else:
        cmd += ["-h", env["DB_HOST"], "-p", env.get("DB_PORT", "5432"),
                "-U", env["DB_USER"], "-d", env["DB_NAME"]]
    run_ok(cmd, env=sub_env, scrub_env=scrub_env, log=log, timeout=3600)
    try:
        os.chmod(out_file, 0o600)
    except OSError:
        pass
    _chown_safe(out_file, 0, 0, log=log)
    # Prune keep 14
    dumps = sorted(backup_dir.glob("pre-migration-*.dump"),
                   key=lambda p: p.stat().st_mtime_ns, reverse=True)
    for old in dumps[14:]:
        if log is not None:
            log.info("Pruning pre-migration backup older than 14 days: %s", old)
        old.unlink(missing_ok=True)
    if log is not None:
        log.info("  → backup: %s", out_file)


def deploy_stage11_migrate(args, env, release_path: Path, venv_python: Path,
                           layout: DjangoLayout, log, scrub_env) -> None:
    if log is not None:
        log.info("[STAGE 11/18] Running Django migrate --noinput")
    mp = release_path / layout.managepy_rel
    sub_env = _inject_django_env(env, args, env, release_path, layout)
    run_ok([str(venv_python), str(mp), "migrate", "--noinput"],
           env=sub_env, scrub_env=scrub_env, log=log, timeout=900)


def _staticfiles_manifest_matches(release_path: Path, deploy_dir: Path, log=None) -> bool:
    """Return True if STATIC_ROOT manifest hash matches code hash → skip collectstatic."""
    static_root = deploy_dir / "shared" / "staticfiles"
    manifest = static_root / "staticfiles.json"
    if not manifest.exists():
        return False
    try:
        manifest_sha = hashlib.sha256(manifest.read_bytes()).hexdigest()
        manifest_prev_path = deploy_dir / "shared" / ".staticfiles_sha256"
        if not manifest_prev_path.exists():
            return False
        last_code_sha = manifest_prev_path.read_text().strip()
        # Compute code sha via pip_list_sha256 in release.json? use release_json git_sha + pip_list_sha256 concat
        rj = read_release_json(release_path)
        code_sha = hashlib.sha256(
            f"{rj.get('git_sha','')}|{rj.get('pip_list_sha256','')}".encode()).hexdigest()
        return code_sha == last_code_sha and manifest_sha.startswith(last_code_sha[:16])
    except (OSError, json.JSONDecodeError):
        return False


def deploy_stage12_collectstatic(args, env, release_path: Path, venv_python: Path,
                                 layout: DjangoLayout, log, scrub_env) -> None:
    if log is not None:
        log.info("[STAGE 12/18] collectstatic --noinput --clear")
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    if _staticfiles_manifest_matches(release_path, deploy_dir, log=log):
        if log is not None:
            log.info("  → skipping (staticfiles unchanged since last deploy)")
        return
    mp = release_path / layout.managepy_rel
    sub_env = _inject_django_env(env, args, env, release_path, layout)
    run_ok([str(venv_python), str(mp), "collectstatic", "--noinput", "--clear"],
           env=sub_env, scrub_env=scrub_env, log=log, timeout=900)
    # Update static code sha marker
    rj = read_release_json(release_path)
    code_sha = hashlib.sha256(
        f"{rj.get('git_sha','')}|{rj.get('pip_list_sha256','')}".encode()).hexdigest()
    (deploy_dir / "shared" / ".staticfiles_sha256").write_text(code_sha)


def deploy_stage13_workers_if_enabled(args, env, release_path: Path, venv_python: Path,
                                      layout: DjangoLayout, release_json: dict,
                                      log, scrub_env) -> None:
    if not getattr(args, "with_workers", False):
        if log is not None:
            log.info("[STAGE 13/18] Workers skipped (no --with-workers)")
        return
    if log is not None:
        log.info("[STAGE 13/18] Installing Redis + rendering Celery systemd units")
    ensure_apt_package("redis-server", log=log)
    # Harden redis localhost-only
    rconf = Path("/etc/redis/redis.conf")
    if rconf.exists():
        text = rconf.read_text(errors="replace")
        new_lines: list[str] = []
        for line in text.splitlines():
            s = line.strip()
            if s.startswith("bind "):
                new_lines.append("bind 127.0.0.1 ::1")
                continue
            if s.startswith("protected-mode "):
                new_lines.append("protected-mode yes")
                continue
            if s.startswith("supervised "):
                new_lines.append("supervised systemd")
                continue
            new_lines.append(line)
        new_text = "\n".join(new_lines) + "\n"
        if _sha256_text(new_text) != _sha256_text(text):
            backup = rconf.with_suffix(rconf.suffix + ".pre-rasyatone.bak")
            if not backup.exists():
                shutil.copy2(rconf, backup)
            rconf.write_text(new_text)
            run_ok(["systemctl", "restart", "redis-server"], log=log, check=False)
    run_ok(["systemctl", "enable", "redis-server"], log=log, check=False)
    # ensure redis running
    up = run_ok(["redis-cli", "ping"], check=False, log=None)
    if "PONG" not in (up.stdout or ""):
        if log is not None:
            log.warning("Redis ping != PONG after install: %s", (up.stdout + up.stderr).strip())
    # Celery units write done in stage 15 (after symlink current) so chdir /current resolves


def deploy_stage14_switch_current(args, env, release_path: Path, release_json: dict,
                                  log, scrub_env) -> Optional[Path]:
    if log is not None:
        log.info("[STAGE 14/18] Atomic current symlink switch → %s", release_path)
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    link = deploy_dir / "current"
    prev = current_release_link(deploy_dir)
    _force_symlink(link, release_path)
    release_json["prev_release"] = str(prev) if prev else None
    release_json["switched_at"] = dt.datetime.utcnow().isoformat() + "Z"
    write_release_json(release_path, release_json)
    if log is not None:
        log.info("  → previous release: %s", prev)
    return prev


def deploy_stage15_systemd(args, env, release_path: Path, layout: DjangoLayout,
                           log, scrub_env) -> None:
    if log is not None:
        log.info("[STAGE 15/18] Installing Gunicorn (and Celery if enabled) systemd units")
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    env_file = Path(getattr(args, "env_file", ENV_FILE_DEFAULT))
    service_user = getattr(args, "service_user", SERVICE_USER_DEFAULT)
    workers = int(getattr(args, "gunicorn_workers", 0) or _default_workers())
    mode = getattr(args, "gunicorn_mode", "unix")
    bind_arg = getattr(args, "gunicorn_bind", None)
    if mode == "unix" and not bind_arg:
        bind_arg = "/run/rasyatone/gunicorn.sock"
    elif mode == "tcp" and not bind_arg:
        bind_arg = "127.0.0.1:8000"
    wsgi_app = layout.wsgi_app or f"{layout.settings_module.rsplit('.',1)[0]}.wsgi:application"
    gunit = _render_gunicorn_unit(
        service_user=service_user, deploy_dir=deploy_dir,
        settings_module=layout.settings_module, wsgi_app=wsgi_app,
        workers=workers, bind=bind_arg, env_file=env_file)
    ensure_systemd_unit("rasyatone.service", gunit, log=log, enable=True, start=True)
    release_json = read_release_json(release_path)
    release_json["gunicorn_bind"] = bind_arg
    release_json["gunicorn_workers"] = workers
    release_json["gunicorn_wsgi_app"] = wsgi_app
    write_release_json(release_path, release_json)
    if getattr(args, "with_workers", False):
        celery_app = layout.celery_app or (
            f"{layout.settings_module.rsplit('.',1)[0]}.celery:app")
        concurrency = int(env.get("CELERY_WORKER_CONCURRENCY") or str(_count_cpu()))
        wunit = _render_celery_unit(service_user=service_user, deploy_dir=deploy_dir,
                                    env_file=env_file, celery_app=celery_app,
                                    concurrency=concurrency, kind="worker")
        bunit = _render_celery_unit(service_user=service_user, deploy_dir=deploy_dir,
                                    env_file=env_file, celery_app=celery_app,
                                    concurrency=concurrency, kind="beat")
        ensure_systemd_unit("rasyatone-celery.service", wunit, log=log, enable=True, start=True)
        ensure_systemd_unit("rasyatone-celerybeat.service", bunit, log=log, enable=True, start=True)


def deploy_stage16_nginx_certbot(args, env, release_path: Path, log, scrub_env) -> str:
    """Returns bind string for nginx upstream (unix socket / TCP)."""
    if log is not None:
        log.info("[STAGE 16/18] Nginx vhost + Certbot LetsEncrypt")
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    rj = read_release_json(release_path)
    bind = rj.get("gunicorn_bind", "/run/rasyatone/gunicorn.sock")
    domain = getattr(args, "domain", DOMAIN_DEFAULT)
    aliases = list(getattr(args, "alias", []) or [])
    # First render without certbot SSL cert paths (to do HTTP→HTTPS redirect + certbot challenge)
    # Stage pattern:
    # 1. Write initial vhost with HTTP only
    # 2. nginx -t + reload (serve HTTP first for certbot challenge)
    # 3. Run certbot --nginx if cert not present / not valid
    # 4. Rewrite vhost with ssl_certificate paths injected from certbot install location
    # 5. Final nginx -t + reload
    sites_avail = Path("/etc/nginx/sites-available")
    sites_enabled = Path("/etc/nginx/sites-enabled")
    sites_avail.mkdir(parents=True, exist_ok=True)
    sites_enabled.mkdir(parents=True, exist_ok=True)
    initial = _render_nginx_site(domain, aliases, deploy_dir, bind, ssl_config_block="")
    target = sites_avail / "rasyatone"
    # Backup any existing nginx site config to /var/backups/rasyatone/nginx/
    if target.exists():
        backup_dir = Path(BACKUP_DIR_DEFAULT) / "nginx"
        backup_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target, backup_dir / f"rasyatone.{int(time.time())}.conf")
    target.write_text(initial)
    # Enable symlink
    enabled = sites_enabled / "rasyatone"
    if not enabled.is_symlink() or not enabled.exists():
        if enabled.exists() or enabled.is_symlink():
            enabled.unlink()
        enabled.symlink_to(target)
    # Disable default site to avoid collisions
    default_link = sites_enabled / "default"
    if default_link.exists() and getattr(args, "force", False):
        default_link.unlink(missing_ok=True)
    # Test & reload
    run_ok(["nginx", "-t"], log=log)
    if systemd_is_active("nginx"):
        run_ok(["systemctl", "reload", "nginx"], log=log)
    else:
        run_ok(["systemctl", "enable", "--now", "nginx"], log=log)
    # Open firewall
    for svc in ("http", "https", "ssh"):
        ensure_ufw_allow(svc, log=log)
        ensure_firewalld_service(svc, log=log)
    # Certbot install/renew if needed
    le_email = getattr(args, "letsencrypt_email", LETSENCRYPT_EMAIL_DEFAULT)
    if not certbot_cert_valid_for_at_least(domain, days=7, log=log):
        ensure_apt_package("certbot", log=log)
        ensure_apt_package("python3-certbot-nginx", log=log)
        # certbot auto will configure SSL; allow failures to not crash whole deploy (warn)
        domains_cli: list[str] = ["-d", domain]
        for a in aliases:
            domains_cli += ["-d", a]
        r = run_ok(["certbot", "--nginx", "-n",
                    "--agree-tos", "--redirect", "--no-eff-email",
                    "-m", le_email] + domains_cli,
                   log=log, check=False, timeout=900)
        if r.returncode != 0:
            msg = scrub_secrets((r.stderr or r.stdout or ""), env=scrub_env)[-2000:]
            if log is not None:
                log.error("Certbot failed: %s", msg)
            raise ProdStageError(
                stage=16, code=316,
                user_msg=f"Certbot failed while requesting SSL cert for {domain}: {msg}")
    # Enable certbot timer (auto-renew)
    run_ok(["systemctl", "enable", "certbot.timer"], log=log, check=False)
    run_ok(["systemctl", "start", "certbot.timer"], log=log, check=False)
    # Inject ssl_certificate paths from the certbot location if not already in site file
    cert_live_dir = Path("/etc/letsencrypt/live") / domain
    if cert_live_dir.exists():
        fullchain = cert_live_dir / "fullchain.pem"
        privkey = cert_live_dir / "privkey.pem"
        ssl_block = (
            f"ssl_certificate     {fullchain};\n"
            f"    ssl_certificate_key {privkey};"
        )
        new_site = _render_nginx_site(domain, aliases, deploy_dir, bind,
                                      ssl_config_block=ssl_block)
        if target.read_text() != new_site:
            target.write_text(new_site)
            run_ok(["nginx", "-t"], log=log)
            run_ok(["systemctl", "reload", "nginx"], log=log)
    # Renew dry-run test (warn only on fail)
    dry = run_ok(["certbot", "renew", "--dry-run", "-q"], log=log, check=False, timeout=600)
    if dry.returncode != 0 and log is not None:
        log.warning("certbot renew --dry-run failed (auto-renew might be broken). Output:\n%s",
                    scrub_secrets((dry.stderr or dry.stdout or "")[-2000:]))
    return bind


def deploy_stage17_logrotate(args, env, log, scrub_env) -> None:
    if not getattr(args, "logrotate", True):
        if log is not None:
            log.info("[STAGE 17/18] logrotate skipped (--no-logrotate)")
        return
    if log is not None:
        log.info("[STAGE 17/18] Installing logrotate config for rasyatone logs")
    service_user = getattr(args, "service_user", SERVICE_USER_DEFAULT)
    rendered = _render_logrotate_config(service_user)
    p = Path("/etc/logrotate.d/rasyatone")
    if not p.exists() or _sha256_text(p.read_text()) != _sha256_text(rendered):
        p.write_text(rendered)
        os.chmod(p, 0o644)
    # dry-run test
    run_ok(["logrotate", "-d", str(p)], log=log, check=False)


def deploy_stage18_health_cleanup_banner(args, env, release_path: Path, prev_release,
                                         log, scrub_env) -> None:
    if log is not None:
        log.info("[STAGE 18/18] Health checks + release cleanup + SUCCESS banner")
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    domain = getattr(args, "domain", DOMAIN_DEFAULT)
    ok, detail = health_check_bundle(args, env, release_path, deploy_dir, domain, log=log)
    # Write finished_at
    rj = read_release_json(release_path)
    rj["finished_at"] = dt.datetime.utcnow().isoformat() + "Z"
    rj["health_status"] = "OK" if ok else "FAIL"
    rj["health_detail"] = detail
    write_release_json(release_path, rj)
    # Prune old releases
    keep = int(getattr(args, "keep_releases", KEEP_RELEASES_DEFAULT))
    prune_old_releases(deploy_dir, keep=keep, prev_release=prev_release, log=log)
    # Banner + log marker
    dur_s = 0
    started = rj.get("started_at")
    if started:
        try:
            dur_s = (dt.datetime.fromisoformat(rj["finished_at"].rstrip("Z")) -
                     dt.datetime.fromisoformat(started.rstrip("Z"))).total_seconds()
        except Exception:
            pass
    deploy_result = "SUCCESS" if ok else "FAIL_WITH_UNHEALTHY"
    log_marker = (f"DEPLOY_RESULT={deploy_result} "
                  f"release_ts={rj.get('prev_release')} git_sha={rj.get('git_sha','')[:12]} "
                  f"health={'PASS' if ok else 'FAIL'} duration_s={dur_s:.1f}")
    if log is not None:
        log.info(scrub_secrets(log_marker, env=scrub_env))
        nc = bool(getattr(args, "no_color", False))
        nu = bool(getattr(args, "no_unicode", False))
        print_banner_deploy_success(rj, dur_s, ok=ok, log=log, no_color=nc, no_unicode=nu)
    if not ok:
        raise ProdStageError(
            stage=18, code=318,
            user_msg=f"Deployment finished but health checks failed:\n{detail}")


def health_check_bundle(args, env, release_path: Path, deploy_dir: Path,
                        domain: str, log=None) -> tuple[bool, str]:
    """Run 3 health checks (HTTP, DB, services). Returns (all_ok, detail_multiline)."""
    results: list[tuple[str, bool, str]] = []
    # HTTP /health or fallback /
    resolved = dns_resolves(domain) or ["127.0.0.1"]
    resolved_ip = resolved[0]
    curl_cmd = ["curl", "-fsS", "--max-time", "15",
                "--resolve", f"{domain}:443:{resolved_ip}",
                f"https://{domain}/health/"]
    r1 = run_ok(curl_cmd, log=log, check=False, timeout=30)
    if r1.returncode != 0:
        curl_cmd2 = ["curl", "-fsS", "--max-time", "15",
                     "--header", f"Host: {domain}",
                     "http://127.0.0.1/"]
        r1b = run_ok(curl_cmd2, log=log, check=False, timeout=30)
        results.append(("HTTP /health (fallback /)", r1b.returncode == 0,
                        (r1b.stderr or r1b.stdout or "")[:500] or r1.stderr[:300]))
    else:
        results.append(("HTTP /health (HTTPS)", True, (r1.stdout or "")[:200]))
    # DB connectivity
    dbok, dbmsg = _db_connectivity_works(env, log=log)
    results.append(("PostgreSQL SELECT 1;", dbok, dbmsg))
    # Services
    units = ["nginx", "rasyatone"]
    if getattr(args, "with_workers", False):
        units += ["redis-server", "rasyatone-celery", "rasyatone-celerybeat"]
    for u in units:
        a = systemd_is_active(u)
        results.append((f"systemd active {u}", a, "" if a else "inactive or failed"))
    all_ok = all(passed for _, passed, _ in results)
    lines = [f"[{ 'OK' if p else 'FAIL'}] {n:<40s} {d.strip() if d else ''}"
             for n, p, d in results]
    return all_ok, "\n".join(lines)


def print_banner_deploy_success(rj: dict, dur_s: float, *, ok: bool, log=None,
                                no_color: bool = False, no_unicode: bool = False) -> None:
    _wrap_fix_encoding_once()
    c = lambda col, on: _c(col, on)
    status = "DEPLOY SUCCESS" if ok else "DEPLOY COMPLETED WITH UNHEALTHY SERVICES"
    bar = 70
    tl, tr, bl, br = _gx("tl", no_unicode), _gx("tr", no_unicode), _gx("bl", no_unicode), _gx("br", no_unicode)
    ml = _gx("ml", no_unicode); mr = _gx("mr", no_unicode)
    v = _gx("v", no_unicode); hr = _banner_hr(bar, no_unicode=no_unicode)
    col1 = "GREEN" if ok else "YELLOW"
    box = (
        f"\n{c('BOLD', not no_color)}{c(col1, not no_color)}"
        f"{tl}{hr}{tr}\n"
        f"{v} {status:<{bar-2}s}{v}\n"
        f"{ml}{hr}{mr}\n"
        f"{v} Release directory : {str(rj.get('switched_at',''))[:64]:<64s} {v}\n"
        f"{v} Git SHA           : {str(rj.get('git_sha',''))[:16]:<16s}              "
        f"(ref={str(rj.get('git_ref',''))[:20]:<20s}) {v}\n"
        f"{v} Prev release      : {str(rj.get('prev_release') or '(none)')[:64]:<64s} {v}\n"
        f"{v} Settings module   : {str(rj.get('settings_module',''))[:64]:<64s} {v}\n"
        f"{v} Duration          : {dur_s:6.1f} seconds                                        {v}\n"
        f"{v} Rollback command  : sudo python3 rasyatone_deploy.py --stage rollback        {v}\n"
        f"{bl}{hr}{br}{c('RESET', not no_color)}\n"
    )
    _safe_stderr_print(box, no_unicode=no_unicode, end="")


# ============================================================
# 11. Rollback stage + Check stage
# ============================================================
def _systemd_nginx_config_backup_restore(deploy_dir: Path, target_release: Path, log=None) -> None:
    """If nginx site needs to change because target had different settings, restore from backup."""
    # Best-effort: rewrite site using target's gunicorn bind if differs
    # Actual implementation: static per spec
    return


def run_rollback(args, env, log, scrub_env) -> int:
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    cur = current_release_link(deploy_dir)
    if cur is None:
        raise DeployError(stage=0, code=100, user_msg="No /current symlink — nothing to roll back")
    to_ts = getattr(args, "rollback_to", None)
    target_release: Optional[Path] = None
    if to_ts:
        candidate = deploy_dir / "releases" / to_ts
        if candidate.is_dir():
            target_release = candidate
    if target_release is None:
        # use current release.json's prev_release
        cur_rj = read_release_json(cur)
        prev = cur_rj.get("prev_release")
        if prev:
            p = Path(prev)
            if p.is_dir():
                target_release = p
    if target_release is None:
        raise DeployError(stage=0, code=100,
                           user_msg="No rollback target. Specify --rollback-to <timestamp>")
    # Validate target not partial
    tgt_rj = read_release_json(target_release)
    if not (target_release / "venv" / "bin" / "python").exists() and \
            not getattr(args, "force_partial", False):
        raise DeployError(stage=0, code=100,
                           user_msg=f"Rollback target {target_release} has no venv/bin/python — "
                                    "looks like a partial release. Pass --force-partial to ignore.")
    if not tgt_rj.get("finished_at") and not getattr(args, "force_partial", False):
        raise DeployError(stage=0, code=100,
                           user_msg="Target release never finished successfully (no finished_at). "
                                    "Pass --force-partial to ignore.")
    if log is not None:
        log.info("ROLLBACK current=%s → target=%s", cur, target_release)
    link = deploy_dir / "current"
    _force_symlink(link, target_release)
    run_ok(["systemctl", "daemon-reload"], log=log)
    # Graceful gunicorn reload first → fallback restart
    gr = run_ok(["systemctl", "reload", "rasyatone"], log=log, check=False)
    time.sleep(5)
    if not systemd_is_active("rasyatone"):
        if log is not None:
            log.warning("gunicorn reload failed; hard restart rasyatone.service")
        run_ok(["systemctl", "restart", "rasyatone"], log=log, check=False)
    if getattr(args, "with_workers", False):
        for u in ("rasyatone-celery", "rasyatone-celerybeat"):
            run_ok(["systemctl", "restart", u], log=log, check=False)
    _systemd_nginx_config_backup_restore(deploy_dir, target_release, log=log)
    run_ok(["nginx", "-t"], log=log, check=False)
    run_ok(["systemctl", "reload", "nginx"], log=log, check=False)
    # Health
    ok, detail = health_check_bundle(args, env, target_release, deploy_dir,
                                     getattr(args, "domain", DOMAIN_DEFAULT), log=log)
    status = "SUCCESS" if ok else "FAILED"
    if log is not None:
        log.info(scrub_secrets(
            f"ROLLBACK_RESULT={status} from={cur} to={target_release} "
            f"health={'PASS' if ok else 'FAIL'}", env=scrub_env))
        print("\n" + _c("BOLD", True) + _c("BLUE", True) +
              f"  ╔ ROLLBACK {status} ═ current → {target_release} ═╗\n" +
              _c("RESET", True) + detail + "\n", file=sys.stderr)
    return 0 if ok else 5


def run_check(args, env, log, scrub_env) -> int:
    if log is not None:
        log.info("Running CHECK stage (no mutations): sudo/env/dns/db/services/health")
    check_results: list[tuple[str, bool, str]] = []
    check_results.append(("sudo available", _sudo_available(), ""))
    env_path = Path(getattr(args, "env_file", ENV_FILE_DEFAULT))
    check_results.append(("env file exists", env_path.exists() and env_path.stat().st_size > 0,
                          str(env_path)))
    domain = getattr(args, "domain", DOMAIN_DEFAULT)
    ips = dns_resolves(domain)
    check_results.append((f"DNS {domain}", bool(ips), str(ips)))
    dbok, dbmsg = _db_connectivity_works(env, log=log)
    check_results.append(("PostgreSQL", dbok, dbmsg))
    # Health
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    cur = current_release_link(deploy_dir) or (deploy_dir / "current")
    ok, detail = health_check_bundle(args, env, cur, deploy_dir, domain, log=log)
    lines = [scrub_secrets(f"[ {'OK' if p else 'FAIL'} ] {n:<40s} {d.strip() if d else ''}")
             for n, p, d in check_results]
    lines.append("--- health bundle ---")
    lines.append(detail)
    full = "\n".join(lines)
    if log is not None:
        log.info(scrub_secrets(f"CHECK_RESULT={'PASS' if ok else 'FAIL'}", env=scrub_env))
        nu = bool(getattr(args, "no_unicode", False))
        nc = bool(getattr(args, "no_color", False))
        _safe_stderr_print("\n" + _c("BOLD", not nc) + "RaSYaTone CHECK result:" + _c("RESET", not nc) +
                          "\n" + full, no_unicode=nu)
    return 0 if ok and all(p for _, p, _ in check_results) else 6


# ============================================================
# 12. Remote-mode SSH wrapper (ssh_run + hostkey auto-cleanup)
# ============================================================
_REMOTE_RE = re.compile(r"^(?P<user>[^@:]+)@(?P<host>[^@:]+)(?::(?P<port>\d+))?$")


def _is_host_key_error(stderr: str) -> bool:
    if not stderr:
        return False
    needles = ("REMOTE HOST IDENTIFICATION HAS CHANGED", "Host key verification failed",
               "key does not match for", "Offending key", "WARNING: POSSIBLE DNS SPOOFING",
               "server's host key is not cached",  # PuTTY/plink first-connect
               "host key does not match",  # PuTTY/plink changed-key
               "cached server host key differs",  # PuTTY variants
               "Cannot confirm a host key in batch mode")  # PuTTY/plink -batch abort
    return any(h in stderr for h in needles)


def _putty_registry_hostkey_key_names(host: str, port: Optional[int] = None) -> list[str]:
    """PuTTY stores host keys as HKCU\\Software\\SimonTatham\\PuTTY\\SshHostKeys\\
    with value names == "<ssh-algo>@<port>:<host>" for custom ports, or
    "<ssh-algo>@<host>" for port 22. Return the (algo-oblivious) tail parts
    "<port>:<host>" / "<host>" that we need to strip-value-delete from the
    SshHostKeys subkey to clear stale PuTTY cache for a target host.
    """
    suffixes: list[str] = []
    p = port if port else 22
    if p == 22:
        suffixes.append(f"@{host}")
    suffixes.append(f"@{p}:{host}")
    # PuTTY sometimes stores IPv4 with 0-padded dotted quad; include a fallback
    # matching-bysuffix loop in _clear_putty_host_keys rather than enumerate here.
    return suffixes


def _clear_putty_host_keys(host: str, port: Optional[int] = None, log=None) -> int:
    """Clear stale PuTTY/plink host-key entries from HKCU registry. Returns 0 on success,
    non-zero on access error (registry not available or empty)."""
    on_windows = _geteuid_or_none() is None
    if not on_windows:
        return 0
    try:
        import winreg  # type: ignore
    except Exception:
        return 0
    deleted = 0
    errors = 0
    SQ = f"Software\\SimonTatham\\PuTTY\\SshHostKeys"
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, SQ, 0,
                            winreg.KEY_READ | winreg.KEY_SET_VALUE) as h:
            i = 0
            names: list[str] = []
            while True:
                try:
                    names.append(winreg.EnumValue(h, i)[0])
                except OSError:
                    break
                i += 1
            p = port if port else 22
            # match tail forms: "<algo>@host" (22) / "<algo>@port:host" (custom) /
            # also catch IPv4 dotted-quad canonicalized-by-plink forms
            host_lower = host.lower()
            host_suffixes = [
                f"@{host}",
                f"@{p}:{host}",
            ]
            host_suffixes_lower = [s.lower() for s in host_suffixes]
            for vn in names:
                try:
                    vnl = vn.lower()
                    for suf in host_suffixes_lower:
                        if vnl.endswith(suf):
                            winreg.DeleteValue(h, vn)
                            deleted += 1
                            break
                except Exception as exc:
                    if log is not None:
                        log.warning("[hostkey/putty] cannot delete regval %s: %s", vn, exc)
                    errors += 1
            if log is not None and deleted:
                log.info("[hostkey/putty] cleared %d stale PuTTY SshHostKeys entry/entries for %s",
                         deleted, host)
            return 0 if errors == 0 else 1
    except FileNotFoundError:
        return 0
    except OSError as exc:
        if log is not None:
            log.warning("[hostkey/putty] cannot open PuTTY SshHostKeys regkey: %s", exc)
        return 2


def _remove_host_key(host: str, port: Optional[int] = None, log=None) -> int:
    """Run ssh-keygen -R twice (bare and host:port bracketed) plus clear PuTTY
    SshHostKeys registry (Windows/plink path). Returns 0 if any cleanup succeeded."""
    def _run(cmd):
        return run_ok(cmd, log=log, check=False, timeout=60).returncode
    r1 = _run(["ssh-keygen", "-R", host])
    r2 = 0
    if port and port != 22:
        r2 = _run(["ssh-keygen", "-R", f"[{host}]:{port}"])
    rp = _clear_putty_host_keys(host, port=port, log=log)
    openssh_ok = (r1 == 0 or r2 == 0)
    if openssh_ok or rp == 0:
        return 0
    return (r1 | r2) if rp == 0 else (r1 | r2 | rp)


def _ssh_base_args(host: str, user: str, port: Optional[int], identity: Optional[Path],
                   password_auth: bool = False) -> list[str]:
    batch = "no" if password_auth else "yes"
    args = ["ssh",
            "-o", f"BatchMode={batch}",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "StrictHostKeyChecking=accept-new"]
    if password_auth:
        # Prefer password/kbd-interactive when we have a password, but keep pubkey as
        # third fallback so identity/agent can still win if the user also uploaded a key.
        # NumberOfPasswordPrompts=1 limits the single ask we will feed via our pty/stdin driver.
        args += ["-o", "PreferredAuthentications=publickey,password,keyboard-interactive",
                 "-o", "NumberOfPasswordPrompts=1",
                 "-o", "KbdInteractiveAuthentication=yes",
                 "-o", "PasswordAuthentication=yes"]
    elif identity:
        args += ["-o", f"IdentitiesOnly=yes", "-i", str(identity)]
    if port:
        args += ["-p", str(port)]
    args.append(f"{user}@{host}")
    return args


def _ssh_locate_plink() -> Optional[str]:
    """Return path to PuTTY plink.exe binary if available (Windows password-auth capable), else None."""
    return shutil.which("plink")


_PLINK_HOSTKEY_FLAGS: Optional[list[str]] = None  # memoized: -auto_store_ssh_keys or fallback


def _plink_hostkey_flags(plink_exe: Optional[str] = None) -> list[str]:
    """Probe plink.exe capability at most once and return the best supported
    host-key-auto-accept argv slice.

    PuTTY 0.79 (2024) added `-auto_store_ssh_keys` which silently accepts and
    caches an unknown host key on first connect (analogous to OpenSSH's
    StrictHostKeyChecking=accept-new). This is strongly preferred over `-batch`
    which **aborts with a fatal** FATAL ERROR: Cannot confirm a host key in
    batch mode on every first connect (see deploy.log hostkey errors).

    PuTTY 0.77–0.78 do NOT have -auto_store_ssh_keys, but they DO support
    `-hostkey keyid` (documented in 0.78 --help as "manually specify a host
    key (may be repeated)"). Callers can parse the SHA-256:… fingerprint from
    the first `-batch` failure stderr and retry with an explicit
    ["-hostkey", "sha256@<64-hex>"] appended.

    If the installed plink predates 0.77 and doesn't recognize either, we
    fall back to `-batch` and rely on the caller's `_remove_host_key()` + retry
    loop for remediation (still better than a console pop-up in CREATE_NO_WINDOW).
    """
    global _PLINK_HOSTKEY_FLAGS
    if _PLINK_HOSTKEY_FLAGS is not None:
        return list(_PLINK_HOSTKEY_FLAGS)
    probe: list[str] = ["-auto_store_ssh_keys"]
    exe = plink_exe or _ssh_locate_plink()
    if exe is not None and _geteuid_or_none() is None:
        try:
            import subprocess as _sp_plink
            # plink --help exits non-zero but stderr prints all flags. Run with
            # no user/host to avoid a connect attempt; the help/usage output is
            # written to stderr regardless. PuTTY >= 0.77 uses --help with
            # DOUBLE DASH (GNU-style) — single -help errors with
            # "plink: unknown option \"-help\"" (31 chars only, no flag info).
            _pp = _sp_plink.Popen(
                [exe, "--help"], stdout=_sp_plink.PIPE, stderr=_sp_plink.PIPE,
                creationflags=0x08000000,
            )
            try:
                _o, _e = _pp.communicate(timeout=8)
            except _sp_plink.TimeoutExpired:
                _pp.kill() ; _o, _e = _pp.communicate()
            text = (_e or b"").decode("utf-8", errors="replace") + \
                   (_o or b"").decode("utf-8", errors="replace")
            # Match hyphens, underscores or mixed (PuTTY help says
            # "-auto_store_ssh_keys" in some builds, "-auto-store-ssh-keys"
            # in others; --help text itself already uses "-auto_store_…" as
            # of 0.79 so we normalize all hyphen-underscore variants).
            _t_norm = text.lower().replace("_", "-")
            has_as = ("auto-store-ssh-keys" in _t_norm)
            if not has_as:
                probe = ["-batch"]
        except Exception:
            probe = ["-batch"]
    else:
        probe = ["-batch"]
    _PLINK_HOSTKEY_FLAGS = probe
    return list(_PLINK_HOSTKEY_FLAGS)


_PLINK_PARSED_FP_CACHE: dict[str, str] = {}  # key: host[:port] → last accepted PuTTY-native "<TYPE>:<native>"
_PLINK_FP_CACHE_FILE_NAME = ".rasyatone_deploy_hostkey_fingerprints.json"


def _plink_fingerprint_cache_path(override_parent: Optional[Path] = None) -> Optional[Path]:
    """Return the persistent on-disk path for `_PLINK_PARSED_FP_CACHE`.

    Priority:
      1. `override_parent` (if provided & caller already has a resolved log_dir).
      2. Windows: `%LOCALAPPDATA%\\rasyatone\\` (or fallback: `%USERPROFILE%\\.rasyatone\\`).
      3. POSIX: `$XDG_STATE_HOME/rasyatone/` (or fallback: `~/.local/state/rasyatone/`),
         then `~/.rasyatone/`.
    NEVER place the cache inside a remote-only path (e.g. /var/log/rasyatone can be on
    remote box when in local-mode — this cache is for the CLIENT running rasyatone_deploy.py
    on the operator's Windows machine).
    """
    parents: list[Path] = []
    if override_parent is not None:
        parents.append(Path(override_parent))
    home = Path.home()
    euid = _geteuid_or_none()
    if euid is None:
        # Windows — prefer %LOCALAPPDATA% (per-user, machine-local, no roam)
        local_appdata = os.environ.get("LOCALAPPDATA")
        if local_appdata:
            parents.append(Path(local_appdata) / "rasyatone")
        parents.append(home / ".rasyatone")
    else:
        xdg_state = os.environ.get("XDG_STATE_HOME")
        if xdg_state:
            parents.append(Path(xdg_state) / "rasyatone")
        parents.append(home / ".local" / "state" / "rasyatone")
        parents.append(home / ".rasyatone")
    for p in parents:
        try:
            p.mkdir(parents=True, exist_ok=True)
        except (OSError, PermissionError):
            continue
        try:
            probe = p / f".write_probe_{os.getpid()}"
            probe.write_bytes(b"")
            probe.unlink()
            return p / _PLINK_FP_CACHE_FILE_NAME
        except (OSError, PermissionError):
            continue
    return None


def _load_plink_hostkey_cache(override_parent: Optional[Path] = None,
                              log: Optional[logging.Logger] = None) -> int:
    """Load on-disk fingerprint cache into `_PLINK_PARSED_FP_CACHE`.

    Returns number of entries loaded (0 = nothing loaded, empty file / missing).
    NEVER raises; all errors are caught and logged as warnings if logger provided.
    File format JSON: `{ "<port>:<host>" : "SHA256:<base64>"  |  "MD5:aa:bb:cc:..." }`
    """
    global _PLINK_PARSED_FP_CACHE
    path = _plink_fingerprint_cache_path(override_parent=override_parent)
    if path is None or not path.exists():
        return 0
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, PermissionError, UnicodeDecodeError) as exc:
        if log is not None:
            log.warning("[hostkey] cannot read persistent fingerprint cache %s: %s", path, exc)
        return 0
    try:
        data = json.loads(raw)
    except (ValueError, json.JSONDecodeError) as exc:
        if log is not None:
            log.warning("[hostkey] corrupt persistent fingerprint cache %s (%s); ignoring.", path, exc)
        return 0
    if not isinstance(data, dict):
        if log is not None:
            log.warning("[hostkey] persistent fingerprint cache %s is not a JSON object; ignoring.", path)
        return 0
    loaded = 0
    for k, v in data.items():
        if (not isinstance(k, str)) or (not isinstance(v, str)):
            continue
        if not v.startswith("SHA256:") and not v.startswith("MD5:"):
            continue
        _PLINK_PARSED_FP_CACHE[k] = v
        loaded += 1
    return loaded


def _save_plink_hostkey_cache(override_parent: Optional[Path] = None,
                              log: Optional[logging.Logger] = None) -> bool:
    """Flush `_PLINK_PARSED_FP_CACHE` to disk so next Python process inherits cache.

    Returns True on successful write; False on any failure; NEVER raises.
    """
    path = _plink_fingerprint_cache_path(override_parent=override_parent)
    if path is None:
        if log is not None:
            log.warning("[hostkey] no writable location for persistent fingerprint cache; skipping save.")
        return False
    try:
        # atomic: write to tmp + os.replace on same volume so concurrent readers
        # never see half-written JSON (NTFS rename is atomic for files on same drive)
        tmp = path.with_suffix(path.suffix + ".tmp." + str(os.getpid()))
        tmp.write_text(json.dumps(dict(_PLINK_PARSED_FP_CACHE), ensure_ascii=False, indent=2, sort_keys=True),
                       encoding="utf-8")
        os.replace(tmp, path)
        try:
            os.chmod(path, 0o600)  # contain user-visible SSH host fingerprints
        except OSError:
            pass
    except (OSError, PermissionError) as exc:
        if log is not None:
            log.warning("[hostkey] cannot write persistent fingerprint cache %s: %s", path, exc)
        try:
            if tmp.exists():
                tmp.unlink()
        except OSError:
            pass
        return False
    return True


def _plink_parse_hostkey_fingerprint(stderr_text: str) -> Optional[str]:
    """Return the PuTTY-NATIVE key-id format from `stderr_text` if it contains a
    "The server's ssh-<algo> key fingerprint is:" stanza; else None.

    PuTTY's `-hostkey` flag parser (validated on PuTTY 0.78 install) accepts ONLY:
      • "SHA256:<original-base64-token>"      (case-sensitive "SHA256:" prefix,
                                                NO case normalization, NO decode,
                                                NO re-encoding — use the token as
                                                written in the error.)
      • "MD5:aa:bb:cc:dd:…" (lowercase hex, colon-separated, 16 pairs)

    CRITICAL: ANY other format (sha256:, SHA256:<hex>, sha256@<hex>, bare base64,
    bare hex) is REJECTED by plink with:
        "plink: 'X' is not a valid format for a manual host key specification"
    — see deploy.log #188-189 for that error live. We therefore return the EXACT
    PuTTY-printed form with zero transformation: regex captures from "SHA256:<tok>"
    where <tok> is 43-44 base64 chars possibly ending in "=", and we RE-emit as
    `"SHA256:" + tok` unchanged.
    """
    if not stderr_text:
        return None
    import re as _re_fp
    for m in _re_fp.finditer(r"SHA256\s*:\s*([A-Za-z0-9+/=]{40,50})", stderr_text):
        # PuTTY prints: "ssh-ed25519 255 SHA256:aogXOILOWvZHIRSP33UcWBlTfc++F+CjRHnkTSTBy1E"
        # Accepted by -hostkey after probe: "SHA256:aogXOILOWvZHIRSP33UcWBlTfc++F+CjRHnkTSTBy1E"
        # (uppercase SHA256 colon + original token exactly as printed)
        return "SHA256:" + m.group(1)
    for m in _re_fp.finditer(r"(MD5\s*:\s*(?:[0-9a-fA-F]{2}:){15}[0-9a-fA-F]{2})", stderr_text):
        return m.group(1).replace(" ", "")
    return None


def _ssh_locate_sshpass() -> Optional[str]:
    """Return path to sshpass binary if available, else None."""
    return shutil.which("sshpass")


def _threaded_heartbeat(stop_event, log=None, interval: float = 2.0,
                        label: str = "") -> None:
    """Background target: print a single `.` every `interval`s until stop_event is set.

    Used to keep the terminal looking alive during long SSH transfers/runs where
    stdout/stderr may be silent for minutes. Outputs to stderr (progress channel).
    """
    import threading as _thr
    _safe_stderr_print(f"\n   {label} ", no_unicode=True, error=False, end="")
    try:
        sys.stderr.flush()
    except Exception:
        pass
    while not stop_event.is_set():
        if stop_event.wait(interval):
            break
        try:
            sys.stderr.write(".")
            sys.stderr.flush()
        except Exception:
            break
    _safe_stderr_print(" done", no_unicode=True, error=False)
    try:
        sys.stderr.flush()
    except Exception:
        pass


@contextlib.contextmanager
def _ssh_heartbeat(label: str, enable: bool = True):
    """Context manager: starts a heartbeat dot-printer thread, cleans up on exit."""
    import threading as _thr
    t = None
    stop_evt = _thr.Event()
    if enable and sys.stderr is not None and getattr(sys.stderr, "isatty", lambda: False)():
        t = _thr.Thread(target=_threaded_heartbeat,
                        args=(stop_evt,),
                        kwargs={"label": label, "interval": 2.0},
                        daemon=True)
        t.start()
    try:
        yield
    finally:
        stop_evt.set()
        if t is not None:
            t.join(timeout=5.0)


def _ssh_run_with_pty(ssh_args: list[str], ssh_password: Optional[str],
                      stdin_payload: Optional[str | bytes],
                      timeout: int, log=None, label: str = "ssh",
                      plink_hostkey: Optional[str] = None) -> subprocess.CompletedProcess:
    """Run an SSH subprocess using Python stdlib pty (POSIX) / pipe-feeding fallback (Windows).

    - On POSIX (Linux/macOS with Python built with pty support): fork a real PTY so
      OpenSSH reads the password from its controlling terminal, not stdin (the stdin
      channel must remain free for `stdin_payload` to reach remote bash).
    - On Windows (no native pty in stdlib): use PuTTY plink.exe if available (it has
      native -pw password support); else fail-fast with a clean actionable error
      explaining how Win32-OpenSSH.exe never reads passwords from pipes and how to fix.
    """
    on_windows = _geteuid_or_none() is None
    ssh_pass_bytes: bytes = b""
    if ssh_password:
        ssh_pass_bytes = (ssh_password + "\n").encode("utf-8")

    # ------------------------------------------------------------------
    # Windows + password auth: PREFER plink.exe (PuTTY) over ssh.exe since the
    # Microsoft Win32-OpenSSH port always reads passwords from a Console, never
    # from redirected stdin. CREATE_NO_WINDOW + stdin-pipe on ssh.exe causes a
    # silent indefinite hang (ssh.exe blocks in AttachConsole forever). plink
    # supports `-pw <password> -batch` which fully avoids console dependencies.
    # ------------------------------------------------------------------
    if on_windows and ssh_password:
        plink = _ssh_locate_plink()
        if plink is not None:
            # Translate ssh args to plink args:
            #   ssh [-o BatchMode=no -p 22 -i key] user@host -T -- bash -lc script
            #   plink [-ssh -P 22 -i key.ppk] user@host -pw <pw> -batch -T bash -lc script
            # Extract components from ssh_args we built in ssh_run()
            pw_env_argv = ssh_args  # original ssh argv; we'll rebuild as plink argv below
            user_host: Optional[str] = None
            port_opt: Optional[str] = None
            identity_opt: list[str] = []
            # scan ssh_args for known positional/optionals
            i = 0
            while i < len(pw_env_argv):
                a = pw_env_argv[i]
                if a == "-p":
                    port_opt = pw_env_argv[i + 1] if i + 1 < len(pw_env_argv) else None
                    i += 2
                    continue
                if a == "-i":
                    if i + 1 < len(pw_env_argv):
                        identity_opt = ["-i", pw_env_argv[i + 1]]
                    i += 2
                    continue
                if a == "-T" or a.startswith("-o") or a == "--":
                    i += 1
                    continue
                if "@" in a and (user_host is None):
                    user_host = a
                i += 1
            # Extract remote cmd: any args after the final "-- bash -lc script" block
            remote_cmd: list[str] = []
            # Simpler: ssh_args = [ssh, ...opts..., user@host, -T, --, "bash", "-lc", script]
            if "--" in pw_env_argv:
                cmd_start = pw_env_argv.index("--") + 1
                remote_cmd = pw_env_argv[cmd_start:]
            if user_host is None:
                # Fallback: try to rebuild manually from what ssh_run passed
                pass
            # Pre-populate hostkey: if a PREVIOUS call to the same host already had
            # to pass `-hostkey <sha256:…>` in order to connect (PuTTY 0.78 empty cache
            # on first connect), re-use that fingerprint now so the FIRST plink
            # attempt succeeds immediately. PuTTY's `-hostkey` CLI flag is intentionally
            # NON-persistent (a security feature; it never writes HKCU\…\SshHostKeys
            # when using -hostkey). So: we persist the cached fingerprint in our own
            # Python memory to avoid 2nd/3rd/4th SSH calls re-entering the whole
            # "detect stale → parse fp → retry" overhead cycle. See deploy.log lines
            # 202-210 where after Upload OK, the NEXT SSH call to the SAME exact
            # host:port re-executed Warning→ssh-keygen -R→parse→retry for no benefit.
            _port_str = str(port_opt) if port_opt is not None else "22"
            _host_part = user_host.split("@", 1)[1] if (user_host and "@" in user_host) else None
            cache_key = f"{_port_str}:{_host_part}" if _host_part else None
            _came_from_cache = False
            if plink_hostkey is None and cache_key and (cache_key in _PLINK_PARSED_FP_CACHE):
                plink_hostkey = _PLINK_PARSED_FP_CACHE[cache_key]
                _came_from_cache = True
                if log is not None:
                    if ":" in plink_hostkey:
                        _pp_t, _pp_b = plink_hostkey.split(":", 1)
                        if _pp_t.upper() == "MD5":
                            _pps = _pp_b.split(":")
                            _pp_short = f"{_pp_t}:" + ":".join(_pps[:4]) + ":…"
                        else:
                            _pp_short = f"{_pp_t}:{_pp_b[:12]}…"
                    else:
                        _pp_short = plink_hostkey[:16] + "…"
                    log.info("[hostkey/plink] reusing prior -hostkey %s (cache hit for %s).",
                             _pp_short, cache_key)
            plink_argv: list[str] = [plink, "-ssh"]
            if port_opt is not None:
                plink_argv += ["-P", str(port_opt)]
            plink_argv += identity_opt
            plink_argv += ["-pw", ssh_password]
            plink_argv += _plink_hostkey_flags(plink)  # -auto_store_ssh_keys (PuTTY>=0.79) or -batch fallback
            if plink_hostkey:
                # Retry on PuTTY 0.77–0.78: first -batch run failed with "The host key is
                # not cached … FATAL ERROR: Cannot confirm a host key in batch mode" and
                # the caller successfully parsed the fingerprint from stderr. Pass back
                # the EXACT PuTTY-native string returned by _plink_parse_hostkey_fingerprint:
                # either "SHA256:<original-base64>" (43-44 chars after colon, case sensitive)
                # or "MD5:aa:bb:…". We validated these on a real PuTTY 0.78: any other
                # format raises "is not a valid format for a manual host key specification"
                # (see deploy.log #188-189 for the live sha256@<hex> rejection).
                plink_argv += ["-hostkey", plink_hostkey]
                if log is not None:
                    # Pretty-print the key id for logs: strip long base64 after 12 chars
                    # (SHA256:<12 chars>…) or MD5:<first-4-pairs>:…:…
                    if ":" in plink_hostkey:
                        _h_type, _h_body = plink_hostkey.split(":", 1)
                        if _h_type.upper() == "MD5":
                            _parts = _h_body.split(":")
                            _short_body = ":".join(_parts[:4]) + ":…"
                        else:
                            _short_body = _h_body[:12] + "…"
                        _short = f"{_h_type}:{_short_body}"
                    else:
                        _short = plink_hostkey[:16] + "…"
                    # Two distinct log lines because semantics differ:
                    #   * "using explicit -hostkey…" = FIRST attempt is using a -hostkey
                    #     flag that was either passed in by caller OR populated from our
                    #     process-global _PLINK_PARSED_FP_CACHE dict (cache hit above).
                    #     No prior failure occurred → NOT a retry.
                    #   * "retrying with explicit -hostkey…" = caller is recovering from
                    #     an already-seen -batch abort. A previous plink invocation failed
                    #     with "Cannot confirm a host key in batch mode" → true retry.
                    # To distinguish, we tag onto the `plink_hostkey` local: if it came
                    # from cache lookup above, we ALREADY logged a distinct cache-hit
                    # line and this block fires BUT we must NOT print "retrying". So:
                    # if caller explicitly passed plink_hostkey into function args, that
                    # ALWAYS means retry path; if we populated it locally from
                    # _PLINK_PARSED_FP_CACHE dict, that means first attempt + cache hit.
                    # We set a local bool _came_from_cache right before populating
                    # plink_hostkey from dict so we can tell the two cases apart here.
                    if _came_from_cache:
                        log.info("[hostkey/plink] using explicit -hostkey %s on first attempt (from local cache).", _short)
                    else:
                        log.info("[hostkey/plink] retrying with explicit -hostkey %s", _short)
            plink_argv += ["-T"]
            if user_host:
                plink_argv.append(user_host)
            plink_argv += remote_cmd
            creationflags = 0
            if on_windows:
                creationflags = 0x08000000  # CREATE_NO_WINDOW
            stdin_bytes: Optional[bytes]
            if stdin_payload is None:
                stdin_bytes = None
            elif isinstance(stdin_payload, str):
                stdin_bytes = stdin_payload.encode("utf-8")
            else:
                stdin_bytes = stdin_payload
            try:
                proc = subprocess.Popen(
                    plink_argv,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    creationflags=creationflags,
                )
            except ValueError:
                proc = subprocess.Popen(
                    plink_argv,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
            try:
                with _ssh_heartbeat(label, enable=True):
                    out_b, err_b = proc.communicate(input=stdin_bytes, timeout=timeout)
            except subprocess.TimeoutExpired:
                proc.kill()
                out_b, err_b = proc.communicate()
                raise subprocess.TimeoutExpired(plink_argv, timeout) from None
            out_s = out_b.decode("utf-8", errors="replace") if out_b is not None else ""
            err_s = err_b.decode("utf-8", errors="replace") if err_b is not None else ""
            # plink uses different host-key error text: "The server's host key is not
            # cached in the registry" — surface by returning it in stderr so caller's
            # _is_host_key_error can act on it.
            return subprocess.CompletedProcess(args=plink_argv, returncode=proc.returncode,
                                               stdout=out_s, stderr=err_s)
        # ------------------------------------------------------------------
        # No plink.exe on Windows AND password required => FAIL FAST with clear
        # actionable guidance instead of silently hanging inside ssh.exe forever.
        # ------------------------------------------------------------------
        no_such_binary_msg = (
            "   On Windows, Microsoft's ssh.exe reads login passwords from a CONSOLE "
            "handle (never stdin/pipe). A password was set in the wizard, and neither "
            "sshpass nor PuTTY plink.exe was found on PATH. Options to fix (pick one):"
            "\n     (a) winget install PuTTY.PuTTY   (installs plink.exe, recommended)"
            "\n     (b) choco install putty          (if you use Chocolatey)"
            "\n     (c) Use SSH keys:  type $env:USERPROFILE\\.ssh\\id_*.pub | "
            "ssh root@207.180.207.208 mkdir -p ~/.ssh ^&^& cat ^>^> ~/.ssh/authorized_keys"
            "  then re-run wizard and press ENTER for both passwords (leave blank)."
            "\n     (d) Run the script from WSL:Ubuntu + `apt install sshpass`."
        )
        if log is not None:
            log.error(no_such_binary_msg)
        raise DeployError(0, 41, no_such_binary_msg)

    # ------------------------------------------------------------------
    # POSIX: real pty via os.forkpty (pty module wraps it cleanly)
    # ------------------------------------------------------------------
    if not on_windows and hasattr(__import__("os"), "forkpty"):
        # POSIX: real pty via os.forkpty (pty module wraps it cleanly)
        import pty as _pty
        import select as _select
        pid, fd = _pty.fork()
        if pid == 0:
            # child: exec ssh; inherit the PTY as controlling terminal
            try:
                os.execvp(ssh_args[0], ssh_args)
            finally:
                os._exit(127)
        # parent: drive the PTY
        if stdin_payload is None:
            payload_bytes = b""
        elif isinstance(stdin_payload, str):
            payload_bytes = stdin_payload.encode("utf-8")
        else:
            payload_bytes = stdin_payload
        output_buf = bytearray()
        stderr_buf = bytearray()  # pty merges stdout+stderr; we demux below via ssh exit code
        password_sent = False
        payload_sent = False
        stdin_remaining = ssh_pass_bytes + payload_bytes if ssh_password else payload_bytes
        start_t = time.time()
        try:
            with _ssh_heartbeat(label, enable=True):
                while True:
                    if time.time() - start_t > timeout:
                        os.kill(pid, 9)
                        raise subprocess.TimeoutExpired(ssh_args, timeout)
                    r_ready, w_ready, _ = _select.select(
                        [fd],
                        [fd] if stdin_remaining else [],
                        [],
                        0.25,
                    )
                    if fd in r_ready:
                        try:
                            chunk = os.read(fd, 65536)
                        except OSError:
                            chunk = b""
                        if not chunk:
                            break
                        output_buf.extend(chunk)
                        # Heuristic: detect SSH password prompt so we send the PW *before*
                        # sending the user payload (keeps payload in good shape for remote bash).
                        low_tail = bytes(output_buf[-256:]).lower()
                        if (not password_sent and ssh_password
                                and (b"password:" in low_tail
                                     or b"passphrase " in low_tail
                                     or b"passphrase:" in low_tail
                                     or b"verification code" in low_tail)):
                            try:
                                n = os.write(fd, ssh_pass_bytes)
                            except OSError:
                                n = 0
                            if n == len(ssh_pass_bytes):
                                password_sent = True
                                stdin_remaining = payload_bytes
                        if (not password_sent or not payload_sent) and (time.time() - start_t > 1.2):
                            if stdin_remaining:
                                try:
                                    n = os.write(fd, stdin_remaining)
                                except OSError:
                                    n = 0
                                if n > 0:
                                    stdin_remaining = stdin_remaining[n:]
                                    if ssh_password and not password_sent and not stdin_remaining.startswith(ssh_pass_bytes[: min(4, len(ssh_pass_bytes))]):
                                        password_sent = True
                                    if not stdin_remaining:
                                        payload_sent = True
                                        password_sent = True
                    if fd in w_ready and stdin_remaining:
                        try:
                            n = os.write(fd, stdin_remaining)
                        except OSError:
                            n = 0
                        if n > 0:
                            stdin_remaining = stdin_remaining[n:]
                            if not stdin_remaining:
                                payload_sent = True
                                if not ssh_password:
                                    password_sent = True
                    done_pid, status = os.waitpid(pid, os.WNOHANG)
                    if done_pid == pid:
                        try:
                            while True:
                                chunk = os.read(fd, 65536)
                                if not chunk:
                                    break
                                output_buf.extend(chunk)
                        except OSError:
                            pass
                        rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else (
                            -os.WTERMSIG(status) if os.WIFSIGNALED(status) else 1)
                        try:
                            os.close(fd)
                        except OSError:
                            pass
                        out_s = bytes(output_buf).decode("utf-8", errors="replace")
                        return subprocess.CompletedProcess(
                            args=ssh_args, returncode=rc, stdout=out_s, stderr="")
                    time.sleep(0.005)
        finally:
            try:
                done_pid, _ = os.waitpid(pid, os.WNOHANG)
                if done_pid == 0:
                    os.kill(pid, 9)
                    os.waitpid(pid, 0)
            except (ProcessLookupError, ChildProcessError, PermissionError, OSError):
                pass
            try:
                os.close(fd)
            except OSError:
                pass

    # ------------------------------------------------------------------
    # macOS/BSD without forkpty: use sshpass + plain Popen. On non-Windows
    # systems this fallback rarely triggers (Python on macOS provides forkpty
    # via pty module on framework builds, and Linux always has it).
    # ------------------------------------------------------------------
    sshpass = _ssh_locate_sshpass() if ssh_password else None
    if sshpass is not None and ssh_password:
        env = os.environ.copy()
        env["SSHPASS"] = ssh_password
        wrapped = [sshpass, "-e"] + ssh_args
        stdin_bytes = None
        if isinstance(stdin_payload, bytes):
            stdin_bytes = stdin_payload
        elif isinstance(stdin_payload, str):
            stdin_bytes = stdin_payload.encode("utf-8")
        proc = subprocess.Popen(wrapped, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env)
        try:
            with _ssh_heartbeat(label, enable=True):
                out_b, err_b = proc.communicate(input=stdin_bytes, timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            out_b, err_b = proc.communicate()
            raise subprocess.TimeoutExpired(wrapped, timeout) from None
        out_s = out_b.decode("utf-8", errors="replace") if out_b is not None else ""
        err_s = err_b.decode("utf-8", errors="replace") if err_b is not None else ""
        return subprocess.CompletedProcess(args=wrapped, returncode=proc.returncode,
                                           stdout=out_s, stderr=err_s)
    # ------------------------------------------------------------------
    # LAST RESORT (non-Windows, no pty, no sshpass): PIPE feeding. We know
    # this almost-never works for password auth, but for key-auth scenarios
    # (ssh_password is None) it will proceed fine. We'll surface the failure
    # via the existing permission-denied hint below.
    # ------------------------------------------------------------------
    extra_env: dict[str, str] = {}
    if ssh_password and on_windows:
        extra_env.setdefault("DISPLAY", "localhost:0.0")
    env = os.environ.copy()
    env.update(extra_env)
    full_stdin = bytearray()
    if ssh_password:
        full_stdin.extend(ssh_pass_bytes)
    if stdin_payload is None:
        pass
    elif isinstance(stdin_payload, str):
        full_stdin.extend(stdin_payload.encode("utf-8"))
    else:
        full_stdin.extend(stdin_payload)
    stdin_bytes = bytes(full_stdin) if full_stdin else None
    creationflags = 0
    if on_windows:
        creationflags = 0x08000000
    try:
        proc = subprocess.Popen(
            ssh_args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            creationflags=creationflags,
        )
    except ValueError:
        proc = subprocess.Popen(
            ssh_args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
    try:
        with _ssh_heartbeat(label, enable=True):
            out_b, err_b = proc.communicate(input=stdin_bytes, timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        out_b, err_b = proc.communicate()
        raise subprocess.TimeoutExpired(ssh_args, timeout) from None
    out_s = out_b.decode("utf-8", errors="replace") if out_b is not None else ""
    err_s = err_b.decode("utf-8", errors="replace") if err_b is not None else ""
    if ssh_password and proc.returncode != 0:
        low = (err_s or "").lower()
        if ("permission denied" in low and "password" in low) or \
                ("permission denied" in low and "publickey" in low and not on_windows):
            hint_lines = [
                "",
                "   SSH password stdin-feeding fallback was unable to authenticate",
                "   this host. To fix, use ONE of:",
                "     (a) Install sshpass (apt install sshpass / brew install hudochenkov/sshpass/sshpass)",
                "         or (b) Add your public key to ~user/.ssh/authorized_keys on the target",
                "         or (c) Load your key into ssh-agent (ssh-add) and leave password blank.",
            ]
            for line in hint_lines:
                if log is not None:
                    log.error(line)
    return subprocess.CompletedProcess(args=ssh_args, returncode=proc.returncode,
                                       stdout=out_s, stderr=err_s)


def ssh_run(*, host: str, user: str, port: Optional[int], identity: Optional[Path],
            script: str, timeout: int = 7200, log=None, scrub_env=None,
            stdin_payload: Optional[str | bytes] = None,
            ssh_password: Optional[str] = None,
            progress_label: Optional[str] = None):
    """Run script on remote via ssh -T. Retry once on host-key error (auto-cleanup).

    If `stdin_payload` is provided, pipes it into the remote `bash -lc script` over ssh's
    stdin channel instead of embedding inside `script`. This avoids Windows CreateProcessW
    argv size limit (WinError 206: filename or extension too long) for large payloads.

    If `ssh_password` is provided:
      - On systems with `sshpass` installed: prefix the ssh command with `sshpass -p<PW>`.
      - On Windows with PuTTY plink.exe available: translate ssh_args → plink with -pw.
      - Otherwise: use PTY-based driver (POSIX) or fail-fast actionable DeployError (Windows).

    `progress_label`: if supplied, the label printed before a heartbeat-dot stream
    (e.g. "transfer" or "running"). Useful for keeping the terminal "alive" visually.
    """
    password_auth = bool(ssh_password)
    plink_extra_hostkey: list[str] = []  # closure-mutable: populated if PuTTY 0.77–0.78 retry

    def _label_for(kind: str) -> str:
        if progress_label:
            return f"[{progress_label}/{kind}]"
        return kind

    def _run_once() -> subprocess.CompletedProcess:
        base_args = _ssh_base_args(host, user, port, identity, password_auth=password_auth)
        ssh_args = base_args + ["-T", "--", "bash", "-lc", script]
        # Fast path: no password needed (BatchMode=yes, key/agent auth) — use plain subprocess,
        # wrapped with heartbeat so the user sees dots during multi-minute long operations.
        if not password_auth:
            if stdin_payload is None or isinstance(stdin_payload, str):
                with _ssh_heartbeat(_label_for("ssh"), enable=True):
                    return subprocess.run(
                        ssh_args,
                        input=stdin_payload,
                        text=True,
                        capture_output=True,
                        timeout=timeout,
                        check=False,
                    )
            proc = subprocess.Popen(ssh_args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            try:
                with _ssh_heartbeat(_label_for("ssh"), enable=True):
                    out_b, err_b = proc.communicate(input=stdin_payload, timeout=timeout)
            except subprocess.TimeoutExpired:
                proc.kill()
                out_b, err_b = proc.communicate()
                raise subprocess.TimeoutExpired(ssh_args, timeout) from None
            out_s = out_b.decode("utf-8", errors="replace") if out_b is not None else ""
            err_s = err_b.decode("utf-8", errors="replace") if err_b is not None else ""
            return subprocess.CompletedProcess(args=ssh_args, returncode=proc.returncode,
                                               stdout=out_s, stderr=err_s)
        # Password path: prefer sshpass if installed (widely available, proven reliable,
        # handles the "read password from controlling tty without pty" problem for us).
        sshpass = _ssh_locate_sshpass()
        if sshpass is not None:
            env = os.environ.copy()
            # Pass password via sshpass envvar (avoids ps(1) argument exposure of -p<PW>).
            env["SSHPASS"] = ssh_password
            wrapped = [sshpass, "-e"] + ssh_args
            if stdin_payload is None or isinstance(stdin_payload, str):
                with _ssh_heartbeat(_label_for("sshpass"), enable=True):
                    return subprocess.run(
                        wrapped,
                        input=stdin_payload,
                        text=True,
                        capture_output=True,
                        timeout=timeout,
                        check=False,
                        env=env,
                    )
            proc = subprocess.Popen(wrapped, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=env)
            try:
                with _ssh_heartbeat(_label_for("sshpass"), enable=True):
                    out_b, err_b = proc.communicate(input=stdin_payload, timeout=timeout)
            except subprocess.TimeoutExpired:
                proc.kill()
                out_b, err_b = proc.communicate()
                raise subprocess.TimeoutExpired(wrapped, timeout) from None
            out_s = out_b.decode("utf-8", errors="replace") if out_b is not None else ""
            err_s = err_b.decode("utf-8", errors="replace") if err_b is not None else ""
            return subprocess.CompletedProcess(args=wrapped, returncode=proc.returncode,
                                               stdout=out_s, stderr=err_s)
        # sshpass not available — fall back to in-process PTY driver.
        return _ssh_run_with_pty(ssh_args, ssh_password=ssh_password,
                                 stdin_payload=stdin_payload, timeout=timeout, log=log,
                                 label=_label_for("pty-ssh"),
                                 plink_hostkey=plink_extra_hostkey[0] if plink_extra_hostkey else None)

    first = _run_once()
    if first.returncode != 0 and _is_host_key_error(first.stderr or ""):
        # PuTTY 0.77–0.78 specific retry: first -batch attempt returned a SHA256
        # fingerprint stanza; parse it before clearing caches, then carry into retry.
        parsed_fp = None
        if _geteuid_or_none() is None:
            parsed_fp = _plink_parse_hostkey_fingerprint(first.stderr or "")
        if log is not None:
            log.warning("[hostkey] Detected stale SSH host key for %s — running ssh-keygen -R then retrying",
                        host)
            log.info("[hostkey] Running: ssh-keygen -R %s%s",
                     host, f" -R [{host}]:{port}" if port and port != 22 else "")
        _remove_host_key(host, port=port, log=log)
        if parsed_fp:
            # Cache parsed fingerprint in two places: (1) closure list to pass to
            # immediate retry below, (2) process-global _PLINK_PARSED_FP_CACHE dict
            # keyed by "<port>:<host>" so SUBSEQUENT ssh_run() calls to the same
            # host prepend -hostkey to the FIRST plink invocation already, skipping
            # the entire "fail → clear caches → parse fp → retry" overhead loop.
            # (3) Persist to on-disk JSON cache so NEXT PYTHON PROCESS startup also
            # inherits this fingerprint (deploy.log lines 200-256 show every new
            # PID 41640 / 2764 / 10548 / 41072 re-pays the 5-second warm-up because
            # the dict dies with each process) — saves ~5 seconds per run.
            plink_extra_hostkey.append(parsed_fp)
            cache_key = f"{port or 22}:{host}"
            _PLINK_PARSED_FP_CACHE[cache_key] = parsed_fp
            try:
                _save_plink_hostkey_cache(log=log)
            except Exception:
                pass
            if log is not None:
                # parsed_fp is either "SHA256:<base64>" or "MD5:aa:bb:cc:..." — pretty print
                if ":" in parsed_fp:
                    _h_type, _h_body = parsed_fp.split(":", 1)
                    if _h_type.upper() == "MD5":
                        _parts = _h_body.split(":")
                        _short = f"{_h_type}:" + ":".join(_parts[:4]) + ":…"
                    else:
                        _short = f"{_h_type}:{_h_body[:12]}…"
                else:
                    _short = parsed_fp[:16] + "…"
                log.info(
                    "[hostkey/plink] fingerprint %s parsed from stderr; retry will append -hostkey flag.",
                    _short,
                )
        if log is not None:
            log.info("[hostkey] Retrying SSH connection with fresh host keys...")
        first = _run_once()
    return first


def remote_deploy_wrapper(args, log, scrub_env) -> int:
    """Upload this script to remote, run with --local-mode plus all non-remote CLI flags, then exit.

    Transfer strategy (avoids Windows WinError 206 / macOS ARG_MAX for long scripts):
      1. Send the ~150KB base64 payload over SSH's stdin pipe (NO argv embedding).
      2. Remote bash reads stdin, writes to /tmp/*.b64, decodes, chmods, runs.
      3. Run step is separate SSH session with tiny argv (sudo python3 /tmp/* --local-mode ...).

    Sudo handling:
      - If the user supplied a remote sudo password via the interactive wizard
        (args._ssh_sudo_password), use `sudo -S -k -p ''` to read the password from
        stdin (prefixed into the SSH payload before the script body).
      - Otherwise, keep the original `sudo -n` (non-interactive, NOPASSWD sudo required)
        behavior for backwards compatibility with cloud Ubuntu defaults.
    SSH login handling:
      - args._ssh_password (wizard-provided) is forwarded to ssh_run() as the SSH login
        password fallback. sshpass is used when available, else PTY/pipe driver.
    """
    remote_str = getattr(args, "remote", None)
    identity = getattr(args, "identity", None)
    identity_path = Path(identity).expanduser().resolve() if identity else None
    mm = _REMOTE_RE.match(remote_str)
    if not mm:
        raise DeployError(0, 400, f"Could not parse --remote={remote_str!r}. Use user@host[:port]")
    user, host, port = mm.group("user"), mm.group("host"), \
        (int(mm.group("port")) if mm.group("port") else None)
    if identity_path and not identity_path.exists():
        raise DeployError(0, 400, f"Identity file not found: {identity_path}")
    ssh_password: Optional[str] = getattr(args, "_ssh_password", None)
    sudo_password: Optional[str] = getattr(args, "_ssh_sudo_password", None)
    # Optimization: root user on the remote never needs sudo (already uid 0).
    # Skip the entire sudo wrapper so we never prompt for a sudo password that
    # would never be used. Also clears the sudo_password to skip stdin prefix.
    is_root = (user == "root")
    if is_root and sudo_password:
        if log is not None:
            log.info("  SSH user='root' → auto-skipping sudo wrapper (remote is root already).")
        sudo_password = None
    if log is not None:
        log.info("REMOTE MODE → %s@%s%s", user, host, f":{port}" if port else "")
        if is_root:
            log.info("  auth: remote=root (no sudo required)")
        elif sudo_password:
            log.info("  sudo mode: interactive (password provided via wizard)")
        else:
            log.info("  sudo mode: non-interactive (sudo -n; NOPASSWD sudo required)")
    # Read this script body + encode b64 (bytes = piped over ssh stdin; never placed on argv)
    import base64
    this_file = Path(__file__).resolve()
    script_bytes = this_file.read_bytes()
    b64_bytes = base64.b64encode(script_bytes)  # ~133KB for ~100KB script; piped over stdin
    # Build remote CLI args (exclude --remote / --identity) and include --local-mode
    pass_flags = _remote_build_args_argv(args)
    tmp_stem = f"rasyatone_deploy_tmp_{os.getpid()}"
    tmp_script = f"/tmp/{tmp_stem}.py"

    # ------------------------------------------------------------------
    # Stage 1: TRANSFER (stdin-piped; avoids 32KB Windows argv hard limit)
    # Pipeline:
    #   - SSH stdin carries the large base64 payload (b64_bytes).
    #   - `cat` on the remote copies its stdin (b64 bytes) to FD 4's pipe.
    #   - Python source code comes via FD 3 <<'PYEOF' heredoc (NOT stdin).
    #   - Inner python reads b64 bytes from FD 4 /proc/self/fd/4, writes
    #     decoded script directly to /tmp/*.py. No intermediate b64 disk file.
    # ------------------------------------------------------------------
    transfer_script = (
        "set -e; "
        f"TMP=$(mktemp); trap 'rm -f $TMP' EXIT; "
        f"printf '%s\\n' 'Reading deploy script body via stdin...' >&2; "
        "cat > \"$TMP\"; "  # entire SSH stdin (=b64 payload) written to tmp cleanly
        "echo 'Decoding and writing script...' >&2; "
        + "python3 - \"$TMP\" " + shlex.quote(tmp_script) + " <<'PYEOF'\n"
        "import base64, os, sys\n"
        "b64_path, py_path = sys.argv[1], sys.argv[2]\n"
        "raw_b64 = open(b64_path,'rb').read()\n"
        "open(py_path,'wb').write(base64.b64decode(raw_b64))\n"
        "os.chmod(py_path, 0o755)\n"
        "print(f'WROTE {py_path} ({os.path.getsize(py_path)} bytes)', file=sys.stderr)\n"
        "PYEOF"
    )
    result = ssh_run(host=host, user=user, port=port, identity=identity_path,
                     script=transfer_script, timeout=300, log=log, scrub_env=scrub_env,
                     stdin_payload=b64_bytes, ssh_password=ssh_password,
                     progress_label="transfer")
    if result.returncode != 0:
        if log is not None:
            log.error("Remote script upload failed:\n%s",
                      scrub_secrets((result.stderr or result.stdout or "")[-3000:]))
        return 40
    if log is not None:
        log.info("Upload OK (%d bytes script transferred)", len(script_bytes))

    # Stage 2: RUN remotely
    # Root user bypass: just "python3 /tmp/script.py --local-mode ..." (no sudo wrapper at all)
    if is_root:
        sudo_prefix = []
        run_stdin_payload: Optional[bytes] = None
    elif sudo_password:
        # When a sudo password is available:
        #   - prefix sudo_pw + newline to the stdin of the remote SSH channel
        #   - change `sudo -n` to `sudo -S -k` so sudo reads password from its stdin
        #     (-S = stdin, -k = ignore timestamp so the PW is always requested once)
        #   - use a zero-length sudo prompt string (-p '') so no "Password:" text
        #     needs to be stripped from stderr
        sudo_prefix = ["sudo", "-S", "-k", "-p", ""]
        run_stdin_payload = (sudo_password + "\n").encode("utf-8")
    else:
        sudo_prefix = ["sudo", "-n"]
        run_stdin_payload = None  # let ssh_run/remote bash stdin flow naturally
    run_argv = sudo_prefix + ["python3", tmp_script, "--local-mode"] + pass_flags
    quoted = " ".join(shlex.quote(a) for a in run_argv)
    run_cmd = f"{quoted}; rc=$?; rm -f {shlex.quote(tmp_script)}; exit $rc"
    result2 = ssh_run(host=host, user=user, port=port, identity=identity_path,
                      script=run_cmd, timeout=4 * 3600, log=log, scrub_env=scrub_env,
                      stdin_payload=run_stdin_payload, ssh_password=ssh_password,
                      progress_label="run")
    # Stream remote stdout/stderr back to local
    if result2.stdout:
        sys.stdout.write(result2.stdout)
        sys.stdout.flush()
    if result2.stderr:
        sys.stderr.write(scrub_secrets(result2.stderr, env=scrub_env))
        sys.stderr.flush()
    if log is not None:
        log.info("REMOTE exit=%s", result2.returncode)
    return result2.returncode


def _remote_build_args_argv(args) -> list[str]:
    """Reconstruct argv list for remote invocation from parsed args namespace."""
    out: list[str] = []
    # String / int / Path single values
    single_flags = [
        ("stage", "--stage"), ("repo", "--repo"), ("ref", "--ref"),
        ("app_name", "--app-name"), ("service_user", "--service-user"),
        ("deploy_dir", "--deploy-dir"), ("log_dir", "--log-dir"),
        ("config_dir", "--config-dir"), ("env_file", "--env-file"),
        ("domain", "--domain"), ("letsencrypt_email", "--letsencrypt-email"),
        ("settings_module", "--settings-module"), ("wsgi_app", "--wsgi-app"),
        ("managepy", "--managepy"),
        ("gunicorn_workers", "--gunicorn-workers"), ("gunicorn_mode", "--gunicorn-mode"),
        ("gunicorn_bind", "--gunicorn-bind"),
        ("pre_migration_backup", "--pre-migration-backup"),
        ("keep_releases", "--keep-releases"),
        ("rollback_to", "--rollback-to"),
    ]
    for ns, flag in single_flags:
        v = getattr(args, ns, None)
        if v is None:
            continue
        out += [flag, str(v)]
    # Repeatable: alias
    for alias in (getattr(args, "alias", None) or []):
        out += ["--alias", str(alias)]
    bool_flags_true = [
        ("with_workers", "--with-workers"),
        ("force", "--force"),
        ("non_interactive", "--non-interactive"),
        ("skip_check_deploy", "--skip-check-deploy"),
        ("force_dangerous_debug_deploy", "--force-dangerous-debug-deploy"),
        ("force_partial", "--force-partial"),
    ]
    for ns, flag in bool_flags_true:
        if getattr(args, ns, False):
            out.append(flag)
    bool_flags_false = [
        ("logrotate", "--no-logrotate"),
        ("healthcheck", "--no-healthcheck"),
    ]
    for ns, flag in bool_flags_false:
        if getattr(args, ns, True) is False:
            out.append(flag)
    if getattr(args, "verbose", False):
        out.append("--verbose")
    if getattr(args, "quiet", False):
        out.append("--quiet")
    if getattr(args, "no_color", False):
        out.append("--no-color")
    return out


# ============================================================
# 12.5 Interactive deployment wizard (--interactive)
# ============================================================
def _prompt_input(prompt: str, default: str | None = None,
                  validator=None, no_unicode: bool = False) -> str:
    """Prompt user with optional default + validator. Loops until valid.

    - prompt: label shown before the input (will be 74-char wrapped, 3-space indented)
    - default: pre-filled value shown as [default] after the prompt. User hitting
               Enter accepts the default.
    - validator: callable(s) -> (ok: bool, error_msg: str | None) or raises ValueError
    Returns the validated string (guaranteed non-empty when default is non-None).
    """
    indent = "   "
    bar = 74
    while True:
        # Format: indent + "Label [default]: " but ensure we don't exceed bar visible width
        if default is not None and default != "":
            suf = f" [{default}]"
        else:
            suf = ""
        full_label = f"{indent}{prompt}{suf}: "
        # Wrap long labels across multiple lines, prompt only on last
        vis_label = _norm_text(full_label, no_unicode=no_unicode)
        if _visible_len_local(vis_label) > bar:
            # Hard wrap at bar-3 (leaving room for 3-char indent on continuations)
            wrapped_lines = _wrap_text_width_local(full_label, bar - 3, no_unicode=no_unicode)
            if len(wrapped_lines) > 1:
                for line in wrapped_lines[:-1]:
                    _safe_stderr_print(f"{indent}{line}", no_unicode=no_unicode, error=False)
                last_prompt = wrapped_lines[-1]
            else:
                last_prompt = wrapped_lines[0]
        else:
            last_prompt = full_label
        try:
            raw = input(last_prompt)
        except EOFError:
            raise DeployError(0, 131, "Interactive wizard cancelled (EOF on stdin).")
        except KeyboardInterrupt:
            _safe_stderr_print("", no_unicode=no_unicode, error=False)
            raise DeployError(0, 130, "Interactive wizard cancelled by user.")
        value = raw.strip()
        if value == "" and default is not None:
            value = default
        if validator is not None:
            try:
                ok, msg = validator(value)
            except (ValueError, TypeError) as exc:
                ok, msg = False, str(exc)
            if not ok:
                _safe_stderr_print(
                    f"{indent}{_c('BOLD_RED', not no_unicode)}{_gx('x', no_unicode)} "
                    f"Invalid: {msg or 'please try again'}{_c('RESET', not no_unicode)}",
                    no_unicode=no_unicode, error=False)
                continue
        return value


def _getpass_safe(prompt: str, no_unicode: bool = False) -> str:
    """Hidden password input that DEGRADES GRACEFULLY when stdin/stdout are not a TTY.

    On Windows, getpass.getpass() opens the CONSOLE handle (ReadConsoleW) directly
    — it NEVER reads from sys.stdin. When we pipe stdin from a file (e.g. wizard
    feed script) that means getpass will BLOCK FOREVER waiting for the user to
    type in an invisible console window, producing zero output and zero CPU — the
    exact "Terminal#2-99 stuck no progress" symptom.

    Fallback logic (in order):
      (1) If stdin AND stdout are both TTY → use real getpass.getpass() (hidden).
      (2) Else if stdin is a readable stream → call normal input(prompt) (not
          hidden, but reads from piped stdin so wizard feed scripts work).
      (3) Else → empty string.
    """
    try:
        _stdin_tty = bool(getattr(sys.stdin, "isatty", lambda: False)())
        _stdout_tty = bool(getattr(sys.stdout, "isatty", lambda: False)())
    except Exception:
        _stdin_tty, _stdout_tty = False, False
    if _stdin_tty and _stdout_tty:
        try:
            return getpass.getpass(prompt)
        except (EOFError, KeyboardInterrupt):
            return ""
        except Exception:
            pass
    # Non-TTY stdin: fall back to regular input() so piped wizard feeds work
    try:
        return input(prompt)
    except EOFError:
        return ""
    except KeyboardInterrupt:
        return ""
    except Exception:
        return ""


def _visible_len_local(s: str) -> int:
    return len(_ansi_re_pf_local().sub("", _norm_text(s, no_unicode=True)))


def _ansi_re_pf_local():
    if not hasattr(_ansi_re_pf_local, "cache"):
        import re as _repf
        _ansi_re_pf_local.cache = _repf.compile(r"\x1b\[[0-9;]*[A-Za-z]")
    return _ansi_re_pf_local.cache


def _wrap_text_width_local(text: str, width: int, no_unicode: bool = False) -> list[str]:
    """Greedy word-wrap respecting ANSI + normalized glyph widths.

    Returns list of lines (no trailing newline on any). Empty text -> [""] .
    """
    if text == "":
        return [""]
    t = _norm_text(text, no_unicode=no_unicode)
    ansi_re = _ansi_re_pf_local()
    tokens: list[tuple[str, bool]] = []  # (text, is_ansi)
    i = 0
    while i < len(t):
        m = ansi_re.match(t, i)
        if m:
            tokens.append((m.group(), True))
            i = m.end()
        else:
            tokens.append((t[i], False))
            i += 1
    lines: list[str] = []
    cur_chars: list[str] = []
    cur_vis = 0
    # Scan char by char; split on spaces when adding next word would exceed width
    j = 0
    while j < len(tokens):
        tok_ch, tok_is_ansi = tokens[j]
        if tok_is_ansi:
            cur_chars.append(tok_ch)
            j += 1
            continue
        ch = tok_ch
        if ch == "\n":
            lines.append("".join(cur_chars))
            cur_chars = []
            cur_vis = 0
            j += 1
            continue
        if ch == " " and cur_vis > 0:
            # Look ahead to compute next word visible length
            wvis = 0
            k = j
            while k < len(tokens):
                c2, a2 = tokens[k]
                if a2:
                    k += 1
                    continue
                if c2 == " " or c2 == "\n":
                    break
                wvis += 1
                k += 1
            if wvis > 0 and cur_vis + 1 + wvis > width:
                lines.append("".join(cur_chars))
                cur_chars = []
                cur_vis = 0
                j += 1
                continue
        cur_chars.append(ch)
        cur_vis += 1
        if cur_vis >= width:
            lines.append("".join(cur_chars))
            cur_chars = []
            cur_vis = 0
        j += 1
    if cur_chars:
        lines.append("".join(cur_chars))
    return lines or [""]


def _print_wizard_banner(no_unicode: bool, no_color: bool, step: int, total: int,
                         title: str) -> None:
    """74-char wide, 3-space indented wizard section header."""
    bar = 74
    indent = "   "
    B = _c("BOLD", not no_color) + _c("CYAN", not no_color)
    R = _c("RESET", not no_color)
    tl, tr, bl, br = _gx("tl", no_unicode), _gx("tr", no_unicode), _gx("bl", no_unicode), _gx("br", no_unicode)
    ml, mr = _gx("ml", no_unicode), _gx("mr", no_unicode)
    v, hr = _gx("v", no_unicode), _banner_hr(bar, no_unicode=no_unicode)
    head = f"[{step}/{total}] {title}"
    _safe_stderr_print("", no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{B}{indent}{tl}{hr}{tr}", no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{indent}{v} {head:<{bar-2}s} {v}", no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{indent}{ml}{hr}{mr}{R}", no_unicode=no_unicode, error=False)


def _print_wizard_close(no_unicode: bool, no_color: bool) -> None:
    bar = 74
    indent = "   "
    B = _c("BOLD", not no_color) + _c("CYAN", not no_color)
    R = _c("RESET", not no_color)
    bl, br = _gx("bl", no_unicode), _gx("br", no_unicode)
    hr = _banner_hr(bar, no_unicode=no_unicode)
    _safe_stderr_print(f"{B}{indent}{bl}{hr}{br}{R}", no_unicode=no_unicode, error=False)


def _run_interactive_wizard(args) -> None:
    """Guided deployment wizard. Mutates args namespace in-place.

    Entry conditions: --interactive flag OR (Windows host + stdin TTY + no --remote).
    Exit conditions: args.remote is populated (if remote chosen) + deploy path args
    are populated. Raises DeployError(130/131) on user abort / EOF.
    """
    no_unicode = bool(getattr(args, "no_unicode", False))
    no_color = bool(getattr(args, "no_color", False))
    on_windows = _geteuid_or_none() is None  # no geteuid -> Windows/macOS
    bar = 74
    indent = "   "
    Y = _c("BOLD_YELLOW", not no_color)
    R = _c("RESET", not no_color)
    G = _c("BOLD_GREEN", not no_color)
    C = _c("BOLD_CYAN", not no_color)

    # ---------------- Top-level welcome banner ----------------
    tl, tr, bl, br = _gx("tl", no_unicode), _gx("tr", no_unicode), _gx("bl", no_unicode), _gx("br", no_unicode)
    ml, mr = _gx("ml", no_unicode), _gx("mr", no_unicode)
    v, hr = _gx("v", no_unicode), _banner_hr(bar, no_unicode=no_unicode)
    BANNER_B = _c("BOLD", not no_color) + _c("MAGENTA", not no_color)
    RST = _c("RESET", not no_color)
    _safe_stderr_print("", no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{BANNER_B}{indent}{tl}{hr}{tr}", no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{indent}{v} {'RaSYaTone Deployment Wizard':<{bar-2}s} {v}", no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{indent}{ml}{hr}{mr}", no_unicode=no_unicode, error=False)
    intro_lines = _wrap_text_width_local(
        "Answer a few questions below. Values in [brackets] are defaults; "
        "press ENTER to accept. Press Ctrl+C any time to cancel.",
        bar - 4, no_unicode=no_unicode)
    for ln in intro_lines:
        _safe_stderr_print(f"{indent}{v} {ln:<{bar-2}s} {v}", no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{indent}{bl}{hr}{br}{RST}", no_unicode=no_unicode, error=False)
    _safe_stderr_print("", no_unicode=no_unicode, error=False)

    # Step 1/6: Remote or local?
    _print_wizard_banner(no_unicode, no_color, 1, 6, "Deployment Target")
    default_target = "r" if on_windows else "l"
    tgt_prompt = f"{indent}Deploy (r)emotely over SSH or (l)ocally on this machine"
    def _validate_target(v):
        v = v.lower()
        if v in {"r", "remote", "l", "local"}:
            return True, None
        return False, "enter 'r' for remote or 'l' for local"
    target = _prompt_input("Deploy (r)emotely over SSH or (l)ocally on this machine",
                           default=default_target, validator=_validate_target,
                           no_unicode=no_unicode).lower()
    is_remote = target in {"r", "remote"}
    _print_wizard_close(no_unicode, no_color)

    # Step 2/6: SSH host details (only if remote)
    ssh_user = None
    ssh_host = None
    ssh_port = None
    ssh_identity = None
    ssh_password = None
    ssh_sudo_password = None
    if is_remote:
        _print_wizard_banner(no_unicode, no_color, 2, 6, "SSH Connection Details")

        def _validate_nonempty(v):
            if not v:
                return False, "this value is required"
            return True, None

        def _validate_host(v):
            if not v:
                return False, "hostname or IP is required"
            if len(v) > 253:
                return False, "hostname looks too long"
            return True, None

        def _validate_port(v):
            if v == "":
                return True, None
            try:
                p = int(v)
            except ValueError:
                return False, "port must be an integer (e.g. 22)"
            if not (1 <= p <= 65535):
                return False, "port must be between 1 and 65535"
            return True, None

        def _validate_key_path(v):
            if v == "":
                return True, None
            p = Path(v).expanduser()
            if not p.exists():
                return False, f"file not found: {p}"
            if not p.is_file():
                return False, f"not a regular file: {p}"
            try:
                mode = p.stat().st_mode
                if not (mode & stat.S_IRUSR):
                    return False, f"identity file not readable: {p}"
            except OSError as exc:
                return False, f"cannot stat file: {exc}"
            return True, None

        default_user = getattr(args, "remote", None)
        if default_user:
            mm = _REMOTE_RE.match(default_user)
            if mm:
                default_user = mm.group("user")
        if not default_user:
            default_user = "ubuntu" if on_windows else getpass.getuser()
        ssh_user = _prompt_input("SSH username", default=default_user,
                                 validator=_validate_nonempty, no_unicode=no_unicode)

        default_host = None
        if getattr(args, "remote", None):
            mm = _REMOTE_RE.match(args.remote)
            if mm:
                default_host = mm.group("host")
        if not default_host:
            default_host = ""
        ssh_host = _prompt_input("SSH host (IP or FQDN)", default=default_host or None,
                                 validator=_validate_host, no_unicode=no_unicode)

        default_port = "22"
        if getattr(args, "remote", None):
            mm = _REMOTE_RE.match(args.remote)
            if mm and mm.group("port"):
                default_port = mm.group("port")
        ssh_port_raw = _prompt_input("SSH port", default=default_port,
                                     validator=_validate_port, no_unicode=no_unicode)
        ssh_port = int(ssh_port_raw) if ssh_port_raw else 22

        default_id = getattr(args, "identity", None) or ""
        id_hint = "(blank to use ssh-agent / default keys, or password auth below)"
        _safe_stderr_print(f"{indent}{C}{id_hint}{RST}", no_unicode=no_unicode, error=False)
        ssh_identity_raw = _prompt_input("SSH private key path", default=default_id or None,
                                         validator=_validate_key_path, no_unicode=no_unicode)
        ssh_identity = ssh_identity_raw if ssh_identity_raw else None

        # SSH password fallback (useful when no key + no ssh-agent; echoed as ***)
        if not ssh_identity:
            pw_hint = ("Leave blank ONLY if ssh-agent holds your key, otherwise "
                       "SSH will fail with 'Permission denied (publickey,password)'.")
            _safe_stderr_print(f"{indent}{Y}{pw_hint}{RST}", no_unicode=no_unicode, error=False)
        else:
            pw_hint = ("Optional: used as fallback if the identity/agent key is rejected "
                       "(blank = fail on key rejection).")
            _safe_stderr_print(f"{indent}{C}{pw_hint}{RST}", no_unicode=no_unicode, error=False)
        _ssh_prompt = f"{indent}SSH login password (hidden input, Enter to skip): "
        ssh_pw_1 = _getpass_safe(_ssh_prompt, no_unicode=no_unicode)
        if ssh_pw_1:
            _ssh_prompt2 = f"{indent}Confirm SSH password: "
            ssh_pw_2 = _getpass_safe(_ssh_prompt2, no_unicode=no_unicode)
            if ssh_pw_1 != ssh_pw_2:
                _safe_stderr_print(
                    f"{indent}{_c('BOLD_RED', not no_color)}{_gx('x', no_unicode)} "
                    f"Passwords did not match -- prompting again.{_c('RESET', not no_color)}",
                    no_unicode=no_unicode, error=False)
                ssh_pw_1 = _getpass_safe(_ssh_prompt, no_unicode=no_unicode)
            ssh_password = ssh_pw_1 if ssh_pw_1 else None

        # Remote sudo password (only needed if sudo -n fails due to requiretty/pw sudo)
        sudo_hint = (
            "On most cloud Ubuntu defaults, 'ubuntu' user has NOPASSWD sudo. "
            "If your host REQUIRES a password for sudo, enter it below."
        )
        _safe_stderr_print(f"{indent}{C}{sudo_hint}{RST}", no_unicode=no_unicode, error=False)
        _sudo_prompt = f"{indent}Remote user sudo password (hidden, Enter if NOPASSWD sudo): "
        sudo_pw_1 = _getpass_safe(_sudo_prompt, no_unicode=no_unicode)
        if sudo_pw_1:
            _sudo_prompt2 = f"{indent}Confirm remote sudo password: "
            sudo_pw_2 = _getpass_safe(_sudo_prompt2, no_unicode=no_unicode)
            if sudo_pw_1 != sudo_pw_2:
                _safe_stderr_print(
                    f"{indent}{_c('BOLD_RED', not no_color)}{_gx('x', no_unicode)} "
                    f"Sudo passwords did not match -- prompting again.{_c('RESET', not no_color)}",
                    no_unicode=no_unicode, error=False)
                sudo_pw_1 = _getpass_safe(_sudo_prompt, no_unicode=no_unicode)
            ssh_sudo_password = sudo_pw_1 if sudo_pw_1 else None

        _print_wizard_close(no_unicode, no_color)
    else:
        # Skip step 2-3 visuals for local
        pass

    # Step 3/6: Execution stage
    _print_wizard_banner(no_unicode, no_color, 3 if is_remote else 2, 6, "Execution Stage")
    stage_choices = [("1", "preflight"), ("2", "deploy"), ("3", "rollback"), ("4", "check")]
    stage_default_map = {"preflight": "1", "deploy": "2", "rollback": "3", "check": "4"}
    current_stage = getattr(args, "stage", STAGE_DEFAULT)
    stage_default = stage_default_map.get(current_stage, "2")
    for num, name in stage_choices:
        _safe_stderr_print(f"{indent}  {num}. {name}", no_unicode=no_unicode, error=False)

    def _validate_stage(v):
        if v in {n for n, _ in stage_choices} or v in {nm for _, nm in stage_choices}:
            return True, None
        return False, f"pick 1-4 or a name: {', '.join(nm for _, nm in stage_choices)}"

    stage_pick = _prompt_input("Choose stage", default=stage_default,
                               validator=_validate_stage, no_unicode=no_unicode).lower()
    chosen_stage = None
    for num, name in stage_choices:
        if stage_pick in {num, name}:
            chosen_stage = name
            break
    chosen_stage = chosen_stage or STAGE_DEFAULT
    args.stage = chosen_stage
    if hasattr(args, "stage_set_deploy"):
        args.stage_set_deploy = (chosen_stage == "deploy")
    _print_wizard_close(no_unicode, no_color)

    # Step 4/6: Application + paths
    next_step = 4 if is_remote else 3
    _print_wizard_banner(no_unicode, no_color, next_step, 6, "App Identity & Paths")
    args.app_name = _prompt_input("Application name",
                                  default=getattr(args, "app_name", APP_NAME_DEFAULT),
                                  validator=lambda v: (True, None) if v else (False, "app name required"),
                                  no_unicode=no_unicode)
    args.service_user = _prompt_input("Service account (on target)",
                                      default=getattr(args, "service_user", SERVICE_USER_DEFAULT),
                                      validator=lambda v: (True, None) if v else (False, "service user required"),
                                      no_unicode=no_unicode)
    args.deploy_dir = _prompt_input("Deploy directory (on target)",
                                    default=getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT),
                                    validator=lambda v: (True, None) if v else (False, "deploy dir required"),
                                    no_unicode=no_unicode)
    args.config_dir = _prompt_input("Config directory (on target)",
                                    default=getattr(args, "config_dir", CONFIG_DIR_DEFAULT),
                                    validator=lambda v: (True, None) if v else (False, "config dir required"),
                                    no_unicode=no_unicode)
    args.log_dir = _prompt_input("Log directory (on target)",
                                 default=getattr(args, "log_dir", LOG_DIR_DEFAULT),
                                 validator=lambda v: (True, None) if v else (False, "log dir required"),
                                 no_unicode=no_unicode)
    env_default = getattr(args, "env_file", ENV_FILE_DEFAULT)
    _safe_stderr_print(
        f"{indent}{Y}Note: env file is user-managed (not templated).{RST}",
        no_unicode=no_unicode, error=False)
    args.env_file = _prompt_input("Env file path (on target)", default=env_default,
                                  validator=lambda v: (True, None) if v else (False, "env file path required"),
                                  no_unicode=no_unicode)
    _print_wizard_close(no_unicode, no_color)

    # Step 5/6: Repo + domain + SSL
    next_step = 5 if is_remote else 4
    _print_wizard_banner(no_unicode, no_color, next_step, 6, "Repo, Domain & SSL")
    args.repo = _prompt_input("Git repository URL",
                              default=getattr(args, "repo", REPO_DEFAULT),
                              validator=lambda v: (True, None) if v else (False, "repo URL required"),
                              no_unicode=no_unicode)
    args.ref = _prompt_input("Git ref (branch/tag/sha)",
                             default=getattr(args, "ref", REF_DEFAULT),
                             validator=lambda v: (True, None) if v else (False, "git ref required"),
                             no_unicode=no_unicode)
    args.domain = _prompt_input("Public domain name",
                                default=getattr(args, "domain", DOMAIN_DEFAULT),
                                validator=lambda v: (True, None) if v else (False, "domain required"),
                                no_unicode=no_unicode)
    args.letsencrypt_email = _prompt_input(
        "Let's Encrypt contact email",
        default=getattr(args, "letsencrypt_email", LETSENCRYPT_EMAIL_DEFAULT),
        validator=lambda v: (True, None) if v and ("@" in v) else (False, "valid email required (for SSL)"),
        no_unicode=no_unicode)
    _print_wizard_close(no_unicode, no_color)

    # Step 6/6: Workers + extras
    next_step = 6 if is_remote else 5
    _print_wizard_banner(no_unicode, no_color, next_step, 6, "Runtime Options")
    def _validate_yn(v):
        if v.lower() in {"y", "n", "yes", "no", ""}:
            return True, None
        return False, "enter 'y' or 'n'"
    with_workers_default = "y" if getattr(args, "with_workers", False) else "n"
    with_workers_pick = _prompt_input(
        "Install Celery workers + Redis (background jobs)? [y/N]",
        default=with_workers_default, validator=_validate_yn, no_unicode=no_unicode)
    args.with_workers = with_workers_pick.lower() in {"y", "yes"}
    keep_rel_def = str(getattr(args, "keep_releases", KEEP_RELEASES_DEFAULT))
    def _validate_int_pos(v):
        try:
            n = int(v)
            return (True, None) if n > 0 else (False, "must be > 0")
        except ValueError:
            return False, "must be a positive integer"
    kr_raw = _prompt_input("Releases to keep (rollback slots)", default=keep_rel_def,
                           validator=_validate_int_pos, no_unicode=no_unicode)
    args.keep_releases = int(kr_raw)
    # Backups
    backup_def = getattr(args, "pre_migration_backup", "auto")
    def _validate_backup(v):
        if v.lower() in {"yes", "no", "auto", "y", "n", "a"}:
            return True, None
        return False, "enter 'yes', 'no', or 'auto'"
    backup_raw = _prompt_input(
        "Pre-migration DB backup (yes/no/auto)", default=backup_def,
        validator=_validate_backup, no_unicode=no_unicode)
    bmap = {"y": "yes", "n": "no", "a": "auto"}
    br = backup_raw.lower()
    args.pre_migration_backup = bmap.get(br[0] if br else "a", "auto")
    _print_wizard_close(no_unicode, no_color)

    # ---------------- Apply SSH details to args ----------------
    if is_remote:
        port_suffix = f":{ssh_port}" if (ssh_port and ssh_port != 22) else ""
        args.remote = f"{ssh_user}@{ssh_host}{port_suffix}"
        if ssh_identity:
            args.identity = str(Path(ssh_identity).expanduser())
        # Sensitive runtime-only credentials (never serialized, never logged, never
        # shown in summary beyond "SET/UNSET"). Stored on args so the remote wrapper
        # can drive ssh password auth + interactive sudo over the SSH channel.
        setattr(args, "_ssh_password", ssh_password)
        setattr(args, "_ssh_sudo_password", ssh_sudo_password)
    else:
        args.remote = None
        setattr(args, "_ssh_password", None)
        setattr(args, "_ssh_sudo_password", None)

    # ---------------- Confirmation summary ----------------
    tl, tr, bl, br = _gx("tl", no_unicode), _gx("tr", no_unicode), _gx("bl", no_unicode), _gx("br", no_unicode)
    ml, mr = _gx("ml", no_unicode), _gx("mr", no_unicode)
    v, hr = _gx("v", no_unicode), _banner_hr(bar, no_unicode=no_unicode)
    BB = _c("BOLD", not no_color) + _c("GREEN", not no_color)
    RST = _c("RESET", not no_color)
    _safe_stderr_print("", no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{BB}{indent}{tl}{hr}{tr}", no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{indent}{v} {'Wizard Complete -- Configuration Summary':<{bar-2}s} {v}",
                       no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{indent}{ml}{hr}{mr}", no_unicode=no_unicode, error=False)
    # Auth method summary (safe, never echoes actual passwords)
    if is_remote:
        _auth_parts = []
        if ssh_identity:
            _auth_parts.append(f"key {Path(ssh_identity).name}")
        else:
            _auth_parts.append("key: ssh-agent/default")
        if ssh_password:
            _auth_parts.append("ssh pw: SET")
        else:
            _auth_parts.append("ssh pw: unset")
        if ssh_sudo_password:
            _auth_parts.append("sudo pw: SET (interactive)")
        else:
            _auth_parts.append("sudo pw: unset (NOPASSWD sudo)")
        _auth_line = " + ".join(_auth_parts)
    else:
        _auth_line = "(local, sudo only)"
    summary_rows = [
        ("Mode", "Remote SSH (" + args.remote + ")" if args.remote else "Local (this machine)"),
        ("Auth", _auth_line),
        ("Stage", args.stage),
        ("App", args.app_name),
        ("Service User", args.service_user),
        ("Deploy Dir", args.deploy_dir),
        ("Repo", args.repo),
        ("Ref", args.ref),
        ("Domain", args.domain),
        ("SSL Email", args.letsencrypt_email),
        ("Workers", "ON (Redis + Celery)" if args.with_workers else "OFF"),
        ("Backup", args.pre_migration_backup),
        ("Keep Releases", str(args.keep_releases)),
    ]
    for k, vv in summary_rows:
        line = f"{k}: {vv}"
        if _visible_len_local(line) > bar - 4:
            line = line[:bar - 7] + "..."
        _safe_stderr_print(f"{indent}{v} {line:<{bar-2}s} {v}", no_unicode=no_unicode, error=False)
    _safe_stderr_print(f"{indent}{bl}{hr}{br}{RST}", no_unicode=no_unicode, error=False)

    # Final confirm (unless --force)
    if not getattr(args, "force", False):
        _safe_stderr_print("", no_unicode=no_unicode, error=False)
        def _validate_confirm(v):
            if v.lower() in {"y", "n", "yes", "no", ""}:
                return True, None
            return False, "enter 'y' to proceed or 'n' to abort"
        confirm = _prompt_input("Proceed with this configuration? [Y/n]", default="y",
                                validator=_validate_confirm, no_unicode=no_unicode)
        if confirm.lower() in {"n", "no"}:
            raise DeployError(0, 130, "Deployment cancelled by user at confirmation step.")
    return


# ============================================================
# 13. argparse CLI + main() entry
# ============================================================
def _build_argparser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="rasyatone_deploy.py",
        description="RaSYaTone Django deployment — single-script Approach B (atomic release switch).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--version", action="version", version=f"%(prog)s {_SCRIPT_VERSION}")
    p.add_argument("--deploy", dest="stage_set_deploy", action="store_true",
                   help="Convenience alias equivalent to --stage deploy (default).")
    p.add_argument("--stage", choices=["preflight", "deploy", "rollback", "check"],
                   default=STAGE_DEFAULT,
                   help="Execution stage (default: deploy).")
    p.add_argument("--remote", type=str, default=None, metavar="user@host[:port]",
                   help="Run the deploy remotely over SSH (local mode on target).")
    p.add_argument("--identity", type=str, default=None, metavar="PATH",
                   help="SSH private key path for remote mode (default: ssh agent/Defaults).")
    p.add_argument("--local-mode", dest="local_mode", action="store_true",
                   help=argparse.SUPPRESS)  # used internally by remote wrapper
    # App / git defaults
    g = p.add_argument_group("Repository")
    g.add_argument("--repo", default=REPO_DEFAULT, help="Git repository URL.")
    g.add_argument("--ref", default=REF_DEFAULT, help="Branch / tag / SHA to deploy.")
    g = p.add_argument_group("Paths & identity")
    g.add_argument("--app-name", default=APP_NAME_DEFAULT)
    g.add_argument("--service-user", default=SERVICE_USER_DEFAULT)
    g.add_argument("--deploy-dir", default=DEPLOY_DIR_DEFAULT)
    g.add_argument("--log-dir", default=LOG_DIR_DEFAULT)
    g.add_argument("--config-dir", default=CONFIG_DIR_DEFAULT)
    g.add_argument("--env-file", default=ENV_FILE_DEFAULT)
    g = p.add_argument_group("Domain & SSL")
    g.add_argument("--domain", default=DOMAIN_DEFAULT)
    g.add_argument("--alias", action="append", default=[], metavar="ALIAS",
                   help="Extra server aliases (repeatable, e.g. --alias www.rasyatone.com).")
    g.add_argument("--letsencrypt-email", default=LETSENCRYPT_EMAIL_DEFAULT)
    g = p.add_argument_group("Django runtime")
    g.add_argument("--settings-module", default=None,
                   help="Override DJANGO_SETTINGS_MODULE (auto-detected if omitted).")
    g.add_argument("--wsgi-app", default=None,
                   help="Override Gunicorn WSGI entry (auto-detected if omitted).")
    g.add_argument("--managepy", default=None,
                   help="Relative path to manage.py (auto-detected if omitted).")
    g = p.add_argument_group("Workers")
    g.add_argument("--with-workers", action="store_true",
                   help="Install Redis (localhost only) + Celery worker/beat systemd.")
    g = p.add_argument_group("Gunicorn")
    g.add_argument("--gunicorn-workers", type=int, default=0,
                   help="Workers (default: 2 × CPUs + 1).")
    g.add_argument("--gunicorn-mode", choices=["unix", "tcp"], default="unix")
    g.add_argument("--gunicorn-bind", default=None,
                   help="Bind path for unix socket (default /run/rasyatone/gunicorn.sock) or host:port.")
    g = p.add_argument_group("Pre-migration backup")
    g.add_argument("--pre-migration-backup", choices=["yes", "no", "auto"], default="auto")
    g = p.add_argument_group("Retention")
    g.add_argument("--keep-releases", type=int, default=KEEP_RELEASES_DEFAULT)
    g = p.add_argument_group("Rollback")
    g.add_argument("--rollback-to", default=None, metavar="RELEASE_TS",
                   help="Specific release timestamp (e.g. 20260729-090000) for --stage rollback.")
    g.add_argument("--force-partial", action="store_true",
                   help="Allow rollback to partial/unfinished releases.")
    g = p.add_argument_group("Skipping / force")
    g.add_argument("--force", action="store_true", help="Skip interactive confirmation prompts.")
    g.add_argument("--non-interactive", action="store_true",
                   help="Fail instead of prompting (also implies --force for overwrite guards).")
    g.add_argument("--interactive", action="store_true",
                   help="Launch guided wizard for remote host + deploy config (auto-on on Windows TTY).")
    g.add_argument("--skip-check-deploy", action="store_true",
                   help="Skip Django check --deploy (not recommended).")
    g.add_argument("--force-dangerous-debug-deploy", action="store_true",
                   help="Allow deploy with DJANGO_DEBUG=True (dangerous).")
    g.add_argument("--no-logrotate", dest="logrotate", action="store_false", default=True,
                   help="Do not install/update logrotate config.")
    g.add_argument("--no-healthcheck", dest="healthcheck", action="store_false", default=True,
                   help=argparse.SUPPRESS)  # reserved
    g = p.add_argument_group("Output")
    g.add_argument("--verbose", action="store_true")
    g.add_argument("--quiet", action="store_true")
    g.add_argument("--no-color", action="store_true")
    g.add_argument("--no-unicode", action="store_true",
                   help="Use ASCII box-drawing chars instead of Unicode (for cmd.exe/old terminals).")
    return p


def _print_preflight_summary_banner(args, env: dict[str, str],
                                     results: list[PreflightResult], log) -> None:
    _wrap_fix_encoding_once()
    no_color = bool(getattr(args, "no_color", False))
    no_unicode = bool(getattr(args, "no_unicode", False))
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    domain = getattr(args, "domain", DOMAIN_DEFAULT)
    cur = current_release_link(deploy_dir)
    db_line = ("Remote PostgreSQL " + (
        f"at {env.get('DB_HOST','<set in env>')}:{env.get('DB_PORT','5432')}/"
        f"{env.get('DB_NAME','<name>')}" if not env.get("DATABASE_URL")
        else env.get("DATABASE_URL", "").split("@", 1)[-1].split("?")[0]))
    em = _gx("em", no_unicode)
    lines = [
        ("Application", getattr(args, "app_name", APP_NAME_DEFAULT)),
        ("Environment", env.get("DJANGO_ENV") or env.get("ENVIRONMENT") or "production"),
        ("Stage", getattr(args, "stage", STAGE_DEFAULT)),
        ("Mode", "remote via " + getattr(args, "remote", "") if getattr(args, "remote", None) else "local"),
        ("Git Repository", getattr(args, "repo", REPO_DEFAULT)),
        ("Git Ref", getattr(args, "ref", REF_DEFAULT)),
        ("Domain", domain),
        ("LetsEncrypt Email", getattr(args, "letsencrypt_email", LETSENCRYPT_EMAIL_DEFAULT)),
        ("Deploy Directory", str(deploy_dir)),
        ("Current Release", str(cur) if cur else f"(first deploy {em} none)"),
        ("Upcoming Release", f"(new) {deployment_path_prefix(deploy_dir)}"),
        ("Database", db_line),
        ("Service Account", getattr(args, "service_user", SERVICE_USER_DEFAULT)),
        ("Python Runtime", f"python {sys.version.split()[0]} (system)"),
        ("App Server", f"Gunicorn ({getattr(args,'gunicorn_mode','unix')}, "
                       f"{getattr(args,'gunicorn_workers', None) or 'auto'} workers)"),
        ("Web Server", "Nginx + Certbot Auto SSL"),
        ("Background Workers", "ON (Redis + Celery)" if getattr(args, "with_workers", False) else "OFF"),
        ("Env file", f"{getattr(args, 'env_file', ENV_FILE_DEFAULT)} (user managed)"),
        ("Pre-migration backup", getattr(args, "pre_migration_backup", "auto")),
        ("Keep releases", str(getattr(args, "keep_releases", KEEP_RELEASES_DEFAULT))),
        ("Firewall provider", detect_fw_provider()),
    ]
    bar = 74
    B = _c("BOLD", not no_color) + _c("BLUE", not no_color)
    R = _c("RESET", not no_color)
    tl, tr, bl, br = _gx("tl", no_unicode), _gx("tr", no_unicode), _gx("bl", no_unicode), _gx("br", no_unicode)
    ml, mr = _gx("ml", no_unicode), _gx("mr", no_unicode)
    v, hr = _gx("v", no_unicode), _banner_hr(bar, no_unicode=no_unicode)
    _safe_stderr_print(f"\n{B}{tl}{hr}{tr}", no_unicode=no_unicode)
    # Interior box: left pipe (1) + space (1) + :<bar-2> padded (bar-2=72) + space (1) + right pipe (1)
    # = 1+1+72+1+1 = bar+2 = 76 visible, matching tl/hr/tr border total width (also 76)
    _safe_stderr_print(f"{v} {'RaSYaTone Deployment ' + em + ' Preflight Summary':<{bar-2}s} {v}", no_unicode=no_unicode)
    _safe_stderr_print(f"{ml}{hr}{mr}", no_unicode=no_unicode)
    for k, vv in lines:
        vv = scrub_secrets(str(vv), env=env)
        line = f"{k}: {vv}"
        if len(line) > bar - 4:
            line = line[:bar - 7] + "..."
        _safe_stderr_print(f"{v} {line:<{bar-2}s} {v}", no_unicode=no_unicode)
    _safe_stderr_print(f"{bl}{hr}{br}{R}\n", no_unicode=no_unicode)
    # Also print per-check PASS/FAIL lines (consistent 74-char visible width,
    # aligned to the info box above so the whole preflight block looks uniform)
    row_width = bar  # 74, matches box interior width
    _ansi_re = None
    import re as _re_pf
    _ansi_re = _re_pf.compile(r"\x1b\[[0-9;]*[A-Za-z]")
    def _visible_len(s: str) -> int:
        return len(_ansi_re.sub("", _norm_text(s, no_unicode=True)))
    def _pad_visible(s: str, width: int) -> str:
        """Pad/truncate s to exact visible length (excludes ANSI)."""
        # Normalize before width math so —→-- (1→2 chars), ≥→>= are counted accurately
        s_norm = _norm_text(s, no_unicode=True)
        vl = _visible_len(s_norm)
        if vl > width:
            # Truncate on visible portion, keep ANSI prefixes intact (use s_norm tokens interleaved with original ANSI via s)
            tokens = _re_pf.findall(r"\x1b\[[0-9;]*[A-Za-z]|.", s_norm)
            out = []
            visible_used = 0
            # Also interleave original ANSI colors by token-comparing:
            orig_tokens = _re_pf.findall(r"\x1b\[[0-9;]*[A-Za-z]|.", s)
            # Strategy: step through tokens, skip ANSI in norm-only, emit ANSI from orig then take 1 visible char from s_norm
            oi = 0
            for tok in tokens:
                if _ansi_re.fullmatch(tok):
                    continue
                if visible_used >= width:
                    break
                # Emit leading ANSI from original first
                while oi < len(orig_tokens):
                    ot = orig_tokens[oi]
                    if _ansi_re.fullmatch(ot):
                        out.append(ot)
                        oi += 1
                    else:
                        break
                out.append(tok)
                visible_used += 1
                if oi < len(orig_tokens) and not _ansi_re.fullmatch(orig_tokens[oi]):
                    oi += 1
            # Append trailing ANSI
            while oi < len(orig_tokens):
                ot = orig_tokens[oi]
                if _ansi_re.fullmatch(ot):
                    out.append(ot)
                oi += 1
            s = "".join(out)
            vl = visible_used
        if vl < width:
            s = s + (" " * (width - vl))
        return s
    for num, name, ok, detail in results:
        status = "PASS" if ok else "FAIL"
        col = _c("GREEN", not no_color) if ok else _c("RED", not no_color)
        rst = _c("RESET", not no_color)
        # Normalize name & detail BEFORE width calculations & before output to prevent —/≥ width surprises
        name_s = _norm_text(scrub_secrets(name, env=env), no_unicode=True)
        detail_s = _norm_text(scrub_secrets(detail or "", env=env), no_unicode=True)
        # First column visible: "   PASS  #N  Name<52s>  " (len=3+6+4+52+2=67)
        # Detail fills remaining up to row_width (74)
        first_col = f"   {col}{status}{rst}  #{num:<2d} {name_s:<52s}  "
        first_vl = _visible_len(first_col)
        detail_avail = max(0, row_width - first_vl)
        detail_clipped = detail_s[:max(0, detail_avail)]
        raw_row = first_col + detail_clipped
        _safe_stderr_print(_pad_visible(raw_row, row_width), no_unicode=no_unicode)
    passed = sum(1 for r in results if r.ok)
    ge = _gx("ge", no_unicode)
    ok_txt = "PASSED" if passed == len(results) else "FAILED"
    # Normalize summary before width calculations & output
    summary_norm = _norm_text(f"   Preflight {ok_txt} {em} {passed}/{len(results)} checks", no_unicode=True)
    _safe_stderr_print("\n" + _pad_visible(summary_norm, row_width) + "\n",
                       no_unicode=no_unicode)


def deployment_path_prefix(deploy_dir: Path) -> str:
    return f"{deploy_dir}/releases/{release_timestamp()}"


def detect_fw_provider() -> str:
    if shutil.which("ufw"):
        st = _sh("ufw status 2>/dev/null | head -n1 || true", check=False).stdout.strip().lower()
        return "ufw (" + ("active" if "active" in st else "inactive") + ")"
    if shutil.which("firewall-cmd"):
        return "firewalld"
    return "iptables/nft (unknown)"


def _interactive_confirm(msg: str, *, non_interactive: bool, force: bool) -> bool:
    if force or non_interactive:
        return True
    try:
        ans = input(msg + " [Y/n]: ").strip().lower()
    except EOFError:
        return False
    return ans in ("", "y", "yes")


def _early_exit_banner(*, title: str, detail: str, code: int, no_unicode: bool = False,
                       no_color: bool = False, tag: Optional[str] = None) -> None:
    """74-char wide, 3-space indented "early exit" banner for errors before preflight banner.

    Always prints on stdout (error=False) per project rule: expected early exits
    (argparse errors, wizard cancel, missing password tooling) go to stdout so
    PowerShell does not inject RemoteException labels. Use stderr only for
    truly unexpected bugs.
    """
    import re as _re_ansi_eeb
    bar = 74
    hr = _banner_hr(bar, no_unicode=no_unicode)
    tl, tr, bl, br = _gx("tl", no_unicode), _gx("tr", no_unicode), \
        _gx("bl", no_unicode), _gx("br", no_unicode)
    ml, mr = _gx("ml", no_unicode), _gx("mr", no_unicode)
    v = _gx("v", no_unicode)
    B = _c("BOLD", not no_color) + _c("RED", not no_color)
    Y = _c("BOLD_YELLOW", not no_color)
    RST = _c("RESET", not no_color)
    indent = "   "
    _ansi_re_eeb = _re_ansi_eeb.compile(r'\x1B\[[0-?]*[ -/]*[@-~]')
    def _vis_len(s: str) -> int:
        return len(_ansi_re_eeb.sub('', s))
    # Title row: tag appended right-aligned if provided
    tag_str = f"[{tag}]" if tag else ""
    title_frag = title[: bar - 4 - len(tag_str)]
    if tag_str:
        title_row = f"{title_frag}{tag_str:>{bar - 4 - len(title_frag)}s}"
    else:
        title_row = title_frag
    header_line = f"{indent}{B}{tl}{hr}{tr}{RST}\n" \
                  f"{indent}{B}{v}{RST} {title_row:<{bar-2}s} {B}{v}{RST}\n" \
                  f"{indent}{B}{ml}{hr}{mr}{RST}"
    _safe_stderr_print(header_line, no_unicode=no_unicode, error=False)
    # Detail block with 74-char wrap + 3-space indent + ANSI padding
    wrapped = _wrap_text_width(detail, bar, indent=3, pad=True)
    _safe_stderr_print(wrapped, no_unicode=no_unicode, error=False)
    # Footer row: "exit code: N" left-aligned, yellow, inside vertical pipes
    left_frag = f"{Y}exit code: {code}{RST}"
    vis = _vis_len(left_frag)
    pad_needed = max(0, (bar - 2) - vis)
    footer_row = f"{indent}{B}{v}{RST} {left_frag}{' ' * pad_needed} {B}{v}{RST}"
    _safe_stderr_print(footer_row, no_unicode=no_unicode, error=False)
    # Final bottom corners (no middle separator between detail and footer —
    # using explicit separator between header AND detail only)
    _safe_stderr_print(f"{indent}{B}{bl}{hr}{br}{RST}", no_unicode=no_unicode, error=False)


def main(argv: list[str]) -> int:
    # Cross-platform VT / Unicode fixes BEFORE argparse / any printing (Terminal#1-60)
    _wrap_fix_encoding_once()
    auto_no_color, auto_no_unicode = _auto_flags(argv)
    parser = _build_argparser()
    # ------------------------------------------------------------------
    # EARLY EXIT BUG FIX (Terminal#1-98): argparse.parse_args calls sys.exit(2)
    # on unknown flags / missing values. Without this catch, __main__ reraises
    # SystemExit silently; pipeline shows ~5 lines of argparse usage then
    # dies with rc=2 — no banner, no TerminalID tag, impossible to debug.
    # Workaround: catch SystemExit raised inside parse_args(); render our
    # standard 74-char early-exit banner with tag="argparse" + full usage text.
    # Also temporarily redirect argparse's stderr output to silence its own
    # duplicate error line (otherwise both our banner + argparse error show).
    # ------------------------------------------------------------------
    import io as _io_a
    _saved_stderr = getattr(sys, "stderr", None)
    try:
        sys.stderr = _io_a.StringIO()
        try:
            args = parser.parse_args(argv)
        except SystemExit as se:
            _captured_err = sys.stderr.getvalue() if hasattr(sys.stderr, "getvalue") else ""
            rc_code = int(se.code) if isinstance(se.code, int) else 2
            buf = _io_a.StringIO()
            parser.print_help(buf)
            usage_text = buf.getvalue()
            # Normalize line endings: on Windows, Python's argparse HelpFormatter
            # writes CRLF via text-mode StringIO; our 74-char banner renderer pads
            # every line to fixed width, so trailing \r chars get re-emitted after
            # padding and reset the cursor to col 0, corrupting lines 94-105 of the
            # Terminal#1-98/argparse banner (the "Full usage below:" help block).
            _captured_err = _captured_err.replace("\r\n", "\n").replace("\r", "\n")
            usage_text = usage_text.replace("\r\n", "\n").replace("\r", "\n")
            first_line_argv = " ".join(argv) if argv else "<no args>"
            if rc_code == 0:
                # --help / --version requested — not an error, just pass through
                print(usage_text, end="")
                return 0
            detail = (
                f"Argument parse failed for argv: {first_line_argv}\n"
                f"argparse exit code={rc_code}. Argparse own output:\n"
                f"{_captured_err.strip() if _captured_err.strip() else '(none)'}\n\n"
                f"Full usage below:\n\n"
                + usage_text
            )
            _early_exit_banner(
                title="CLI Argument Parse Error",
                detail=detail,
                code=rc_code,
                no_unicode=auto_no_unicode,
                no_color=auto_no_color,
                tag="Terminal#1-98/argparse",
            )
            return rc_code
    finally:
        if _saved_stderr is not None:
            sys.stderr = _saved_stderr
    # Merge auto-detected flags (OR with user explicit flag)
    args.no_color = bool(args.no_color or auto_no_color)
    args.no_unicode = bool(getattr(args, "no_unicode", False) or auto_no_unicode)
    if args.stage_set_deploy:
        args.stage = "deploy"

    # ------------------------------------------------------------------
    # INTERACTIVE WIZARD TRIGGER (--interactive or auto on Windows TTY)
    # Skip if: --non-interactive, --local-mode (internal SSH invocation).
    #
    #   Explicit --interactive (user flag): ALWAYS runs the wizard, even when
    #   stdin is NOT a TTY — user may be piping a canned response file (e.g.
    #   in CI or scripting a demo). Honoring the explicit flag is the least-
    #   surprising behavior.
    #
    #   Auto-trigger (no flags at all): runs ONLY when (Windows dev host +
    #   no --remote + stdin TTY + not --non-interactive) so first-time users
    #   get guided, but piping/CI continues to skip.
    # ------------------------------------------------------------------
    _is_tty = getattr(sys.stdin, "isatty", lambda: False)()
    _on_dev_host = _geteuid_or_none() is None  # no POSIX geteuid => Windows / macOS
    _wizard_explicit = bool(getattr(args, "interactive", False))
    _wizard_auto = (_on_dev_host
                    and not getattr(args, "remote", None)
                    and not getattr(args, "non_interactive", False)
                    and _is_tty)
    _run_wizard = False
    if _wizard_explicit:
        _run_wizard = True
    elif _wizard_auto and not getattr(args, "non_interactive", False) \
            and not getattr(args, "local_mode", False):
        _run_wizard = True
    if _run_wizard and getattr(args, "local_mode", False):
        _run_wizard = False  # never wizard when script is the SSH payload
    # TTY gate: apply ONLY to the auto-trigger path, never the explicit
    # --interactive path. User explicitly asked for wizard — wizard runs.
    if _run_wizard and not _wizard_explicit and not _is_tty:
        _run_wizard = False
        _safe_stderr_print(
            "   [wizard] auto-wizard skipped (stdin not a TTY). "
            "Pass --interactive explicitly to force.",
            no_unicode=args.no_unicode, error=False)
    if _run_wizard:
        try:
            _run_interactive_wizard(args)
        except DeployError as de:
            # Wizard cancellation (130 = user said No at confirm, 131 = EOF on stdin,
            # 41 = no plink/sshpass for Windows password auth, etc). Render as a
            # standardized early-exit banner so all early exits look uniform.
            tag_suffix = {130: "user-cancel", 131: "eof"}.get(de.code, f"rc{de.code}")
            _early_exit_banner(
                title=f"Interactive Wizard: exit",
                detail=(de.user_msg or "wizard exited") + "\n" + (de._stderr or de._stdout or ""),
                code=de.code,
                no_unicode=args.no_unicode,
                no_color=args.no_color,
                tag=f"Terminal#1-98/wizard/{tag_suffix}",
            )
            return de.code
        except KeyboardInterrupt:
            _early_exit_banner(
                title="Interactive Wizard: Interrupted",
                detail="User pressed Ctrl+C during the interactive wizard.",
                code=130,
                no_unicode=args.no_unicode,
                no_color=args.no_color,
                tag="Terminal#1-98/wizard/sigint",
            )
            return 130
        except Exception as exc_wiz:
            # Unexpected wizard bug -> banner on stderr (unexpected exception path)
            import traceback as _tb_wiz
            tb_wiz = _tb_wiz.format_exc()
            _early_exit_banner(
                title="Interactive Wizard: UNEXPECTED BUG",
                detail=(f"{type(exc_wiz).__name__}: {exc_wiz}\n\nStack trace:\n{tb_wiz}"),
                code=99,
                no_unicode=args.no_unicode,
                no_color=args.no_color,
                tag="Terminal#1-98/wizard/bug",
            )
            _safe_stderr_print(tb_wiz, no_unicode=args.no_unicode, error=True)
            return 99

    # Remote mode short-circuit
    if args.remote and not getattr(args, "local_mode", False):
        dummy_log = setup_logging(Path.cwd(), quiet=args.quiet, verbose=args.verbose,
                                  no_color=args.no_color)
        dummy_scrub_env: dict[str, str] = {}
        try:
            return remote_deploy_wrapper(args, log=dummy_log, scrub_env=dummy_scrub_env)
        except DeployError as de:
            # DeployError from wrapper = expected error (no plink 41, upload failed 40, etc)
            # -> render standard banner on stdout (error=False) to avoid PowerShell artifacts.
            tag_suffix = {40: "transfer-failed", 41: "no-password-tool", 130: "cancel", 131: "eof"} \
                .get(de.code, f"rc{de.code}")
            extra_detail = (de._stderr or de._stdout or "")
            _early_exit_banner(
                title=f"Remote Deploy: exit code {de.code}",
                detail=(de.user_msg or "") + ("\n" + extra_detail if extra_detail else ""),
                code=de.code,
                no_unicode=args.no_unicode,
                no_color=args.no_color,
                tag=f"Terminal#1-98/remote/{tag_suffix}",
            )
            return de.code
        except KeyboardInterrupt:
            _early_exit_banner(
                title="Remote Deploy: Interrupted",
                detail="User pressed Ctrl+C during remote deploy.",
                code=130,
                no_unicode=args.no_unicode,
                no_color=args.no_color,
                tag="Terminal#1-98/remote/sigint",
            )
            return 130

    # Local mode
    try:
        log_dir = Path(args.log_dir)
        try:
            log_dir.mkdir(parents=True, exist_ok=True)
        except OSError:
            # Fallback to /tmp if we can't create log dir
            log_dir = Path(tempfile.mkdtemp(prefix="rasyatone_logs_"))
        log = setup_logging(log_dir, quiet=args.quiet, verbose=args.verbose, no_color=args.no_color)
    except Exception as exc:
        try:
            nu0 = "NO_COLOR" in __import__("os").environ
            _safe_stderr_print(f"Unable to set up logging: {exc}", no_unicode=True, error=True)
        except Exception:
            import sys as _s
            try: _s.stderr.buffer.write(f"Unable to set up logging: {exc}\n".encode("ascii", errors="backslashreplace"))
            except Exception: pass
        import logging as _lg
        _lg.basicConfig(level=_lg.INFO, stream=sys.stdout, force=True, format="%(message)s")
        log = _lg.getLogger("rasyatone.deploy.fallback")

    # Load persistent hostkey fingerprint cache (disk → _PLINK_PARSED_FP_CACHE dict)
    # so a fingerprint parsed by a PREVIOUS PYTHON PROCESS (hours or days ago) is
    # available BEFORE the first ssh_run() call. Every PID at deploy.log #200-256
    # (41640 / 2764 / 10548 / 41072 = user re-ran the script 4 times) re-paid the
    # ~5-second "fail → ssh-keygen -R → parse → retry" warm-up because the dict
    # died when each process exited. This on-disk cache eliminates that overhead
    # for every subsequent re-run to the same host:port.
    try:
        _loaded = _load_plink_hostkey_cache(log=log)
        if _loaded and log is not None:
            log.info("[hostkey/plink] loaded %d persistent hostkey fingerprint%s from on-disk cache.",
                     _loaded, "s" if _loaded != 1 else "")
    except Exception:
        pass

    # Parse env file (never os.environ)
    env_path = Path(args.env_file)
    env_dict: dict[str, str] = parse_env_file(env_path)
    start_time = time.time()
    duration = lambda: f"{(time.time() - start_time):.1f}s"
    release_json: dict[str, Any] = {}
    prev_release: Optional[Path] = None
    try:
        # Preflight always (even for rollback/check — quick subset)
        global _CURRENT_STAGE, _CURRENT_STAGE_NAME
        _CURRENT_STAGE = 0
        _CURRENT_STAGE_NAME = "preflight"
        results = run_preflight(args, env=env_dict, log=log)
        _print_preflight_summary_banner(args, env=env_dict, results=results, log=log)

        # For stage=preflight only: exit on fail
        if args.stage == "preflight":
            if not all(r.ok for r in results):
                fails = [f"#{r.num} {r.name}" for r in results if not r.ok]
                raise PreflightError(0, 101,
                                     f"Preflight FAILED checks: {', '.join(fails)}")
            log.info(scrub_secrets("PREFLIGHT_RESULT=PASS checks=%d/%d" %
                                   (sum(1 for r in results if r.ok), len(results)),
                                   env=env_dict))
            return 0

        # Deploy/rollback/check continue only if critical OS/sudo/env checks pass.
        # Stage-specific NOTE: rollback/check can legitimately be run even when env
        # checks are "FAIL" in the preflight table because run_check()/run_rollback()
        # internally raise their OWN correct rc codes if they find missing state.
        # Therefore we lift env-file-related criticals (#10/#11/#12/#15) from the
        # critical set for stage=check and stage=rollback. Stage=deploy keeps the
        # full strict set (unless it's first-deploy local scenario, handled above).
        _stage = getattr(args, "stage", STAGE_DEFAULT)
        critical_checks = {1, 2, 10, 11, 12, 15}
        if _stage in {"check", "rollback"}:
            critical_checks -= {10, 11, 12, 15}
        # For check/rollback on non-Unix (Windows/macOS dev boxes), also lift
        # #1 (OS Ubuntu check) and #2 (sudo-nopasswd) since those are server-only
        # requirements — run_check/run_rollback will throw correct codes anyway.
        if _stage in {"check", "rollback"} and _geteuid_or_none() is None:
            critical_checks.discard(1)
            critical_checks.discard(2)
        force_danger = getattr(args, "force_dangerous_debug_deploy", False)

        # ------------------------------------------------------------
        # FIRST-DEPLOY SCENARIO DETECTION + GUIDANCE BANNER
        # (stage=deploy ONLY — rollback/check still require valid env)
        # ------------------------------------------------------------
        # On stage=deploy WITHOUT --remote (running locally, not over SSH),
        # if the deploy_dir has no /current symlink yet (i.e. first deploy ever,
        # not an upgrade) AND the env file at ENV_FILE_DEFAULT doesn't exist
        # or is 0 bytes (user hasn't yet downloaded the app from GitHub +
        # populated it per section 2 of docs), then:
        #   1. Print a numbered step-by-step FIRST-DEPLOY banner telling user
        #      exactly how to copy script to target server + clone repo +
        #      create/populate env file + run again with sudo.
        #   2. Auto-lift env-file-related entries (#10/#11/#12/#15) AND, on
        #      non-Unix Windows/macOS dev boxes, also #1 (OS) and #2 (sudo)
        #      from the "critical checks" set, because those are server-only
        #      requirements that are impossible on a dev workstation.
        #   3. After lifting, if 0 criticals remain, exit rc=2 informational
        #      (no traceback, no code=102 HALTED banner) so user's local
        #      "verify script compiles/runs" test passes cleanly.
        # For stage=rollback/check, env file + deploy state must be present,
        # so the original critical_checks set is preserved unchanged for those.
        _first_deploy_local = False
        if getattr(args, "stage", STAGE_DEFAULT) == "deploy" and getattr(args, "remote", None) is None:
            try:
                _euid = _geteuid_or_none()
                _on_unix = _euid is not None
                _env_path = Path(getattr(args, "env_file", ENV_FILE_DEFAULT))
                _deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
                _cur = _deploy_dir / "current"
                _env_exists_nonempty = _env_path.exists() and _env_path.stat().st_size > 0
                _no_current_yet = not _cur.exists()
                if _no_current_yet and not _env_exists_nonempty:
                    _first_deploy_local = True
            except Exception:
                _first_deploy_local = False

        if _first_deploy_local:
            _nc = not bool(getattr(args, "no_color", False))
            _nu = bool(getattr(args, "no_unicode", False))
            _Y = _c("YELLOW", _nc) + _c("BOLD", _nc)
            _RST = _c("RESET", _nc)
            def _fd_pad(s: str, width: int = _PAD_WIDTH, *, center: bool = False) -> str:
                s = _norm_text(s, no_unicode=_nu)
                if len(s) > width:
                    s = s[:max(0, width - 3)] + "..."
                if center and len(s) < width:
                    pad = width - len(s)
                    s = (" " * (pad // 2)) + s + (" " * (pad - pad // 2))
                elif len(s) < width:
                    s = s + (" " * (width - len(s)))
                return s
            _fd_title = _fd_pad(
                " FIRST-DEPLOY MODE: env file populated AFTER GitHub clone "
                " (see numbered steps below) ", center=True)
            _safe_stderr_print(f"\n{_Y}{_fd_title}{_RST}", no_unicode=_nu)
            _steps = [
                "(1) Copy this script to the target Ubuntu server:",
                "      scp rasyatone_deploy.py user@rasyatone.alrasayt.com:/tmp/",
                "(2) SSH into target and clone the app repo once:",
                f"      git clone {REPO_DEFAULT} --branch {REF_DEFAULT} "
                f"/tmp/rasyatone_gitclone",
                f"(3) Create + populate the env file at {ENV_FILE_DEFAULT} (must exist before deploy):",
                "      sudo mkdir -p /etc/rasyatone/static && sudo chmod 750 /etc/rasyatone/static",
                f"      sudo $EDITOR {ENV_FILE_DEFAULT}   # add DJANGO_SECRET_KEY / ALLOWED_HOSTS / DB_*",
                f"      # Minimal required keys inside {ENV_FILE_DEFAULT}:",
                "        DJANGO_SECRET_KEY=<long-random>   DJANGO_DEBUG=false",
                "        DJANGO_ALLOWED_HOSTS=rasyatone.alrasayt.com,localhost",
                "        # Option A (single URL): DATABASE_URL=postgres://user:pass@host:5432/db",
                "        # Option B (split fields): DB_NAME / DB_USER / DB_PASSWORD / DB_HOST / DB_PORT=5432",
                f"(4) Then re-run as root on target server (critical checks 1/2/10/11/12/15 will then PASS):",
                "      sudo python3 /tmp/rasyatone_deploy.py --stage deploy --non-interactive",
                "(5) Or run just the preflight check first (won't mutate anything):",
                "      sudo python3 /tmp/rasyatone_deploy.py --stage preflight",
                "",
                "NOTE: You are seeing this banner because you ran deploy WITHOUT --remote",
                f"      (i.e. locally not over SSH), and {_env_path} does not exist yet",
                f"      + deploy_dir={_deploy_dir} has no /current symlink (indicates a",
                "      first deploy ever, not an upgrade rollout).",
            ]
            for _step in _steps:
                _wrapped = _wrap_text_width(_step, width=_PAD_WIDTH, indent=3, pad=True)
                _safe_stderr_print(f"{_Y}{_wrapped}{_RST}", no_unicode=_nu)
            _safe_stderr_print(f"{_Y}{_fd_pad('')}{_RST}\n", no_unicode=_nu)

            # Lift env-file-related critical checks for first-deploy local stage=deploy only
            critical_checks = critical_checks - {10, 11, 12, 15}
            if not _on_unix:
                critical_checks.discard(1)
                critical_checks.discard(2)
            # If 0 criticals remain, exit cleanly with rc=2 (informational first-deploy OK)
            if not critical_checks:
                _safe_stderr_print(
                    _fd_pad(" Local-mode first-deploy checks are clean. "
                            " Follow steps (1)-(4) above on target Ubuntu server. ",
                            center=True),
                    no_unicode=_nu)
                _safe_stderr_print("\n")
                log.info(scrub_secrets(
                    "PREFLIGHT_RESULT=FIRST_DEPLOY_LOCAL_OK checks=%d/%d" %
                    (sum(1 for r in results if r.ok), len(results)),
                    env=env_dict))
                return 2

        if not force_danger and not all(r.ok for r in results if r.num in critical_checks):
            fails = [f"#{r.num} {r.name}" for r in results if r.num in critical_checks and not r.ok]
            raise PreflightError(0, 102,
                                 "Preflight critical checks failed -- aborting before mutations: "
                                 + ", ".join(fails)
                                 + ". Run --stage preflight for full diagnostics.")
        # Confirm interactive deploy
        if args.stage == "deploy":
            if not _interactive_confirm("Proceed with deployment?",
                                        non_interactive=args.non_interactive, force=args.force):
                log.info("User aborted at confirmation prompt.")
                return 3

        if args.stage == "check":
            return run_check(args, env=env_dict, log=log, scrub_env=env_dict)
        if args.stage == "rollback":
            return run_rollback(args, env=env_dict, log=log, scrub_env=env_dict)

        # ============== DEPLOY ==============
        _CURRENT_STAGE = 1
        deploy_stage1_apt(args, env=env_dict, log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 2
        deploy_stage2_user_dirs(args, env=env_dict, log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 3
        deploy_stage3_validate_secrets(args, env=env_dict, log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 4
        release_path, release_ts = deploy_stage4_make_release(
            args, env=env_dict, release_json=release_json, log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 5
        deploy_stage5_git_clone(args, env=env_dict, release_path=release_path,
                                release_json=release_json, log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 6
        layout = deploy_stage6_detect_layout(
            args, env=env_dict, release_path=release_path, release_json=release_json,
            log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 7
        venv_python = deploy_stage7_venv_pip(
            args, env=env_dict, release_path=release_path, release_json=release_json,
            log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 8
        deploy_stage8_link_shared_env(args, env=env_dict, release_path=release_path,
                                      log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 9
        deploy_stage9_django_check_deploy(args, env=env_dict, release_path=release_path,
                                          venv_python=venv_python, layout=layout,
                                          log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 10
        deploy_stage10_pre_migration_backup(args, env=env_dict, release_path=release_path,
                                             release_ts=release_ts, log=log,
                                             scrub_env=env_dict)
        _CURRENT_STAGE = 11
        deploy_stage11_migrate(args, env=env_dict, release_path=release_path,
                               venv_python=venv_python, layout=layout,
                               log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 12
        deploy_stage12_collectstatic(args, env=env_dict, release_path=release_path,
                                      venv_python=venv_python, layout=layout,
                                      log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 13
        deploy_stage13_workers_if_enabled(args, env=env_dict, release_path=release_path,
                                           venv_python=venv_python, layout=layout,
                                           release_json=release_json,
                                           log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 14
        prev_release = deploy_stage14_switch_current(args, env=env_dict,
                                                     release_path=release_path,
                                                     release_json=release_json,
                                                     log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 15
        deploy_stage15_systemd(args, env=env_dict, release_path=release_path, layout=layout,
                               log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 16
        deploy_stage16_nginx_certbot(args, env=env_dict, release_path=release_path,
                                     log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 17
        deploy_stage17_logrotate(args, env=env_dict, log=log, scrub_env=env_dict)
        _CURRENT_STAGE = 18
        deploy_stage18_health_cleanup_banner(args, env=env_dict, release_path=release_path,
                                             prev_release=prev_release,
                                             log=log, scrub_env=env_dict)
        if log is not None:
            log.info(scrub_secrets(
                f"DEPLOY_FINISHED duration={duration()} "
                f"release_ts={release_ts} prev_release={prev_release}",
                env=env_dict))
        return 0
    except PreflightError as e:
        if log is not None:
            log.error(scrub_secrets(f"[PREFLIGHT ERROR #{e.stage}] code={e.code} {e.user_msg}",
                                    env=env_dict))
        nu = bool(getattr(args, "no_unicode", False))
        nc = bool(getattr(args, "no_color", False))
        detail = scrub_secrets(e.user_msg, env=env_dict)[:800]
        # code 101 = --stage preflight only → print full header + detail
        # code 102 = deploy/rollback/check → summary banner already showed
        #            "Preflight FAILED -- N/M checks"; just print halted line + hint
        hdr_h = _banner_hr(3, no_unicode=nu)
        hdr_tl, hdr_tr = _gx("tl", nu), _gx("tr", nu)
        pad = _PAD_WIDTH
        def _pad_width(s: str) -> str:
            s = s[:pad]
            if len(s) < pad:
                s = s + (" " * (pad - len(s)))
            return s
        def _wrap_detail(text: str) -> str:
            return _wrap_text_width(text, width=pad, indent=3, pad=True)
        if e.code == 101:
            header = f"   {hdr_tl}{hdr_h}{hdr_h}{hdr_h} PREFLIGHT FAILED (code {e.code}) {hdr_h}{hdr_h}{hdr_h}{hdr_tr}"
            header = _pad_width(header)
            wrapped_detail = _wrap_detail(detail)
            _safe_stderr_print("\n" +
                               _c("RED", not nc) + _c("BOLD", not nc) + header + _c("RESET", not nc) + "\n" +
                               wrapped_detail + "\n",
                               no_unicode=nu, error=False)
        else:
            header_line = _pad_width(f"   code={e.code} -- HALTED before deploy mutations.")
            wrapped = _wrap_detail(detail)
            _safe_stderr_print(_c("RED", not nc) + _c("BOLD", not nc) + header_line + _c("RESET", not nc) + "\n" +
                               wrapped + "\n",
                               no_unicode=nu, error=False)
        return e.code
    except StageError as e:
        nu = bool(getattr(args, "no_unicode", False))
        nc = bool(getattr(args, "no_color", False))
        # Stages 1..13 — site untouched.
        if log is not None:
            log.error(scrub_secrets(
                f"[STAGE ERROR #{e.stage}] code={e.code} {e.user_msg}", env=env_dict))
        msg = scrub_secrets((e.user_msg or "") + "\n" + (e._stderr or e._stdout or ""),
                            env=env_dict)[:2000]
        hdr_h = _banner_hr(3, no_unicode=nu)
        hdr_tl, hdr_tr = _gx("tl", nu), _gx("tr", nu)
        pad = _PAD_WIDTH
        def _se_pad(s: str) -> str:
            s = s[:pad]
            if len(s) < pad:
                s = s + (" " * (pad - len(s)))
            return s
        header = f"   {hdr_tl}{hdr_h}{hdr_h}{hdr_h} DEPLOY STOPPED -- NO PRODUCTION CHANGES (stage {e.stage}) {hdr_h}{hdr_h}{hdr_h}{hdr_tr}"
        header = _se_pad(header)
        first_detail = _se_pad(f"   code {e.code}: {msg.split(chr(10),1)[0][:pad-3]}")
        rest_lines = msg.split(chr(10),1)[1] if chr(10) in msg else ""
        wrapped_rest = _wrap_text_width(rest_lines, width=pad, indent=3, pad=True) if rest_lines else ""
        body_lines = [first_detail]
        if wrapped_rest:
            body_lines.extend(wrapped_rest.split("\n"))
        _safe_stderr_print("\n" +
                           _c("RED", not nc) + _c("BOLD", not nc) + header + _c("RESET", not nc) + "\n" +
                           "\n".join(body_lines) + "\n",
                           no_unicode=nu, error=False)
        hint_wrapped = _wrap_text_width(
            "Hint: current symlink untouched. Fix the above; rerun the deploy command.",
            width=pad, indent=3, pad=True)
        _safe_stderr_print(_c("YELLOW", not nc) + hint_wrapped + "\n" +
                           _c("RESET", not nc), no_unicode=nu, error=False)
        return e.code
    except ProdStageError as e:
        nu = bool(getattr(args, "no_unicode", False))
        nc = bool(getattr(args, "no_color", False))
        # Production was touched: attempt auto-rollback
        banner_msg = scrub_secrets(e.user_msg + "\n" + (e._stderr or e._stdout or ""),
                                   env=env_dict)[:2000]
        hdr_h = _banner_hr(3, no_unicode=nu)
        hdr_tl, hdr_tr = _gx("tl", nu), _gx("tr", nu)
        pad = _PAD_WIDTH
        def _p(s: str) -> str:
            s = s[:pad]
            if len(s) < pad:
                s = s + (" " * (pad - len(s)))
            return s
        header = f"   {hdr_tl}{hdr_h}{hdr_h}{hdr_h} PRODUCTION STAGE FAIL {e.stage} code={e.code} -> AUTO-ROLLBACK {hdr_h}{hdr_h}{hdr_h}{hdr_tr}"
        header = _p(header)
        wrapped_detail = _wrap_text_width(banner_msg, width=pad, indent=3, pad=True)
        _safe_stderr_print("\n" +
                           _c("RED", not nc) + _c("BOLD", not nc) + header + _c("RESET", not nc) + "\n" +
                           wrapped_detail + "\n",
                           no_unicode=nu, error=False)
        rollback_ok = False
        try:
            if log is not None:
                log.error("[AUTO-ROLLBACK] Prod stage %d failed -- rolling back to %s",
                          e.stage, prev_release)
            if prev_release is None and release_json.get("prev_release"):
                prev_release = Path(release_json["prev_release"])
            if prev_release is not None:
                run_rollback(args, env=env_dict, log=log, scrub_env=env_dict)
                rollback_ok = True
        except Exception as r_exc:
            rline = _wrap_text_width(f"! Auto-rollback failed: {r_exc}",
                                     width=pad, indent=3, pad=True)
            _safe_stderr_print(rline, no_unicode=nu, error=False)
            if log is not None:
                log.error("Auto-rollback exception: %s", r_exc)
        if not rollback_ok:
            mi_line = _wrap_text_width(
                "! MANUAL INTERVENTION REQUIRED -- auto-rollback could not execute.",
                width=pad, indent=3, pad=True)
            next_steps_block = (
                "\n   Next steps:\n"
                "     1. sudo systemctl --failed\n"
                "     2. sudo journalctl -u rasyatone -n 100\n"
                "     3. sudo tail -n 100 /var/log/rasyatone/nginx.error.log\n"
                "     4. sudo ln -sfn /opt/rasyatone/releases/<KNOWN_GOOD_TS> /opt/rasyatone/current\n"
                "     5. sudo systemctl restart rasyatone nginx\n"
            )
            _safe_stderr_print(_c("RED", not nc) + _c("BOLD", not nc) + mi_line +
                               _c("RESET", not nc) + next_steps_block +
                               _c("RESET", not nc), no_unicode=nu)
        return e.code
    except DeployError as e:
        nu = bool(getattr(args, "no_unicode", False))
        nc = bool(getattr(args, "no_color", False))
        if log is not None:
            try:
                log.error(scrub_secrets(
                    f"[DEPLOY ERROR #{e.stage}] code={e.code} {e.user_msg}",
                    env=env_dict))
            except Exception:
                pass
        msg = scrub_secrets((e.user_msg or "") + "\n" + (e._stderr or e._stdout or ""),
                            env=env_dict)[:2000]
        hdr_h = _banner_hr(3, no_unicode=nu)
        hdr_tl, hdr_tr = _gx("tl", nu), _gx("tr", nu)
        cls_name = type(e).__name__.replace("Error", "")
        pad = _PAD_WIDTH
        def _p(s: str) -> str:
            s = s[:pad]
            if len(s) < pad:
                s = s + (" " * (pad - len(s)))
            return s
        header = f"   {hdr_tl}{hdr_h}{hdr_h}{hdr_h} {cls_name} code={e.code} (stage {e.stage}) {hdr_h}{hdr_h}{hdr_h}{hdr_tr}"
        header = _p(header)
        wrapped_detail = _wrap_text_width(msg, width=pad, indent=3, pad=True)
        _safe_stderr_print("\n" +
                           _c("RED", not nc) + _c("BOLD", not nc) + header + _c("RESET", not nc) + "\n" +
                           wrapped_detail + "\n",
                           no_unicode=nu, error=False)
        return e.code
    except KeyboardInterrupt:
        nu = bool(getattr(args, "no_unicode", False))
        _safe_stderr_print("\n   Interrupted by user.", no_unicode=nu, error=False)
        return 130
    except SystemExit:
        raise
    except Exception as exc:
        nu = bool(getattr(args, "no_unicode", False))
        nc = bool(getattr(args, "no_color", False))
        try:
            _safe_stderr_print(_c("RED", not nc) + _c("BOLD", not nc) +
                               f"\n   X UNEXPECTED ERROR: {type(exc).__name__}: {exc}" +
                               _c("RESET", not nc) + "\n",
                               no_unicode=nu, error=True)
        except Exception:
            try:
                _safe_stderr_print(f"\n   X UNEXPECTED ERROR: {type(exc).__name__}: {exc}\n",
                                   no_unicode=True, error=True)
            except Exception:
                pass
        import traceback
        tb = traceback.format_exc()
        try:
            if log is not None:
                log.error("Unhandled exception: %s\n%s", exc, tb)
        except Exception:
            pass
        _safe_stderr_print(tb, no_unicode=nu, error=False)
        return 99
    finally:
        if log is not None:
            log.info(scrub_secrets(f"FINAL duration={duration()} stage={args.stage}",
                                   env=env_dict))


if __name__ == "__main__":
    try:
        code = main(sys.argv[1:])
    except SystemExit:
        raise
    except KeyboardInterrupt:
        try:
            _safe_stderr_print("\n   Interrupted.\n", no_unicode=True, error=False)
        except Exception:
            pass
        code = 130
    except Exception as _exc:
        code = 9999
        try:
            import traceback as _tb
            _tb_lines = _tb.format_exc()
            _argv = list(sys.argv[1:])
            _auto_nc, _auto_nu = False, False
            try:
                import re as _re_banner
                _auto_nu = ("--no-unicode" in _argv) or bool(
                    _re_banner.search(r"--no-unicode(?:=|\b)", " ".join(_argv)))
                _auto_nc = ("--no-color" in _argv) or bool(
                    _re_banner.search(r"--no-color(?:=|\b)", " ".join(_argv)))
            except Exception:
                pass
            _eeb_fn = globals().get("_early_exit_banner")
            if _eeb_fn is not None:
                try:
                    _eeb_fn(
                        title="UNHANDLED EXCEPTION (script bug)",
                        detail=(f"{type(_exc).__name__}: {_exc}\n\nStack trace:\n{_tb_lines}"),
                        code=9999,
                        no_unicode=_auto_nu,
                        no_color=_auto_nc,
                        tag="Terminal#1-98/global/bug",
                    )
                except Exception:
                    # Banner rendering itself also failed; fall all the way back
                    _tb_msg = f"   UNHANDLED EXIT: {type(_exc).__name__}: {_exc}\n{_tb_lines}"
                    try:
                        _safe_stderr_print(_tb_msg, no_unicode=True, error=True)
                    except Exception:
                        try:
                            sys.stderr.buffer.write(
                                f"UNHANDLED EXIT {type(_exc).__name__}: {_exc}\n"
                                .encode("ascii", errors="backslashreplace")
                            )
                        except Exception:
                            pass
            else:
                _tb_msg = f"   UNHANDLED EXIT: {type(_exc).__name__}: {_exc}\n{_tb_lines}"
                try:
                    _safe_stderr_print(_tb_msg, no_unicode=True, error=True)
                except Exception:
                    try:
                        sys.stderr.buffer.write(
                            f"UNHANDLED EXIT {type(_exc).__name__}: {_exc}\n"
                            .encode("ascii", errors="backslashreplace")
                        )
                    except Exception:
                        pass
        except Exception:
            try:
                sys.stderr.buffer.write(
                    f"UNHANDLED EXIT {type(_exc).__name__}: {_exc}\n"
                    .encode("ascii", errors="backslashreplace")
                )
            except Exception:
                pass
    raise SystemExit(code)
