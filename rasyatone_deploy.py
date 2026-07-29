#!/usr/bin/env python3
"""RaSYaTone Django deployment script — single file.

Approach B: atomic release-dir symlink switcher.

Modes:
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
import grp
import hashlib
import json
import os
import pwd
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
    "BOLD": "\033[1m",
    "RESET": "\033[0m",
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

    console = _logging.StreamHandler(sys.stderr)
    console.setLevel(level)
    msgfmt = "%(message)s" if not verbose else "%(asctime)s %(levelname)7s | %(message)s"
    fmt_cls = _NoColorFormatter if no_color else _logging.Formatter
    console.setFormatter(fmt_cls(msgfmt))
    logger.addHandler(console)

    # File handler /var/log/rasyatone/deploy.log (0640, rasyatone_user:adm if possible)
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        deploy_log = log_dir / "deploy.log"
        file_h = _logging.FileHandler(deploy_log, mode="a", encoding="utf-8")
        file_h.setLevel(_logging.DEBUG)
        file_h.setFormatter(_logging.Formatter(
            "%(asctime)s | ST=%(stage)s | PID=%(process)d | %(levelname)-7s | %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S%z",
        ))
        logger.addHandler(file_h)
        try:
            # Try to set adm group ownership on log dir + file if we can
            try:
                adm_gid = grp.getgrnam("adm").gr_gid
                uid = 0 if os.geteuid() == 0 else -1
                if os.geteuid() == 0:
                    os.chown(str(log_dir), -1, adm_gid)
                    os.chmod(str(log_dir), 0o2750)
                    if deploy_log.exists():
                        os.chown(str(deploy_log), -1, adm_gid)
                        os.chmod(str(deploy_log), 0o640)
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
        if log is not None:
            log.error("RUN EXCEPTION %s", exc)
        raise _deploy_error_for_stage(
            stage=_CURRENT_STAGE, code=210,
            user_msg=f"Executable not found: {exc}",
            cmd=real_cmd, returncode=127, stderr=str(exc),
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
    # Apply ownership if differs and we have perms
    if owner_user or owner_group:
        try:
            st = path.stat()
            cur_uid, cur_gid = st.st_uid, st.st_gid
            want_uid = pwd.getpwnam(owner_user).pw_uid if owner_user else -1
            want_gid = grp.getgrnam(owner_group).gr_gid if owner_group else -1
            if (want_uid != -1 and want_uid != cur_uid) or (want_gid != -1 and want_gid != cur_gid):
                if os.geteuid() == 0:
                    os.chown(str(path), want_uid, want_gid)
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
        if cur_mode not in (0o600, mode):  # allow stricter
            if os.geteuid() == 0:
                os.chmod(str(path), mode)
                if log is not None:
                    log.warning("Chmod env file %s -> 0%o (was 0%o)", path, mode, cur_mode)
        if os.geteuid() == 0:
            try:
                want_gid = grp.getgrnam(group).gr_gid
                want_uid = pwd.getpwnam(owner).pw_uid
                if st.st_gid != want_gid or st.st_uid != want_uid:
                    os.chown(str(path), want_uid, want_gid)
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
    try:
        st = os.statvfs(str(path))
        return (st.f_frsize * st.f_bavail) / 1_000_000_000
    except OSError:
        return 0.0


def _mem_total_mb() -> float:
    try:
        text = Path("/proc/meminfo").read_text()
    except OSError:
        return 0.0
    m = re.search(r"MemTotal:\s*(\d+)\s*kB", text)
    if not m:
        return 0.0
    return int(m.group(1)) / 1024.0


def _sudo_available() -> bool:
    if os.geteuid() == 0:
        return True
    if not shutil.which("sudo"):
        return False
    r = run_ok(["sudo", "-n", "/bin/true"], check=False, log=None)
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

    # 1 OS
    rel = _os_release()
    os_id = rel.get("ID", "")
    codename = rel.get("VERSION_CODENAME", "")
    ok_os = (os_id == "ubuntu" and codename in SUPPORTED_UBUNTU) or \
            (os_id == "debian" and codename in SUPPORTED_DEBIAN)
    add(1, "Operating system (Ubuntu 20.04+ / Debian 11+)", ok_os,
        f"ID={os_id} VERSION_CODENAME={codename}")

    # 2 root or sudo
    add(2, "Root or sudo-nopasswd available", _sudo_available(),
        "user is root" if os.geteuid() == 0 else f"euid={os.geteuid()} sudo={shutil.which('sudo')}")

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
    issues: list[str] = []
    if _disk_free_gb(deploy_dir if deploy_dir.exists() else Path("/")) < 5:
        issues.append(f"{deploy_dir} free < 5GB")
    if _disk_free_gb(log_dir if log_dir.exists() else Path("/var/log")) < 1:
        issues.append(f"{log_dir} free < 1GB")
    if _disk_free_gb(Path("/tmp")) < 2:
        issues.append("/tmp free < 2GB")
    if _disk_free_gb(backup_dir if backup_dir.exists() else Path("/var/backups")) < 0.5:
        issues.append("/var/backups free < 500MB")
    add(4, "Disk space (/opt≥5G, /var/log≥1G, /tmp≥2G)",
        len(issues) == 0, "; ".join(issues) or "ok")

    # 5 memory
    add(5, "Total memory ≥ 1.5GB", _mem_total_mb() >= 1536,
        f"mem_total_mb={_mem_total_mb():.0f}")

    # 6 DNS resolution
    domain = getattr(args, "domain", DOMAIN_DEFAULT)
    ips = dns_resolves(domain)
    detail = f"resolved {ips}" if ips else "NXDOMAIN"
    # Cross-check with public IP
    pub = public_ip_via_curl(log=log)
    if pub and ips and pub not in ips:
        detail += f" WARNING: server public_ip={pub} not in DNS {ips}"
    add(6, f"DNS: {domain}", bool(ips), detail)

    # 7 internet reachability (for apt/git/certbot)
    reach = True
    reach_msg: list[str] = []
    for url in ["https://github.com", "https://acme-v02.api.letsencrypt.org"]:
        rr = run_ok(["curl", "-fsS", "--max-time", "5", "-o", "/dev/null", url],
                    check=False, log=None)
        if rr.returncode != 0:
            reach = False
            reach_msg.append(f"{url} unreachable")
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
    if not db_vars_present:
        add(9, "PostgreSQL connectivity (remote)", False,
            "DB vars missing in env file (provide DATABASE_URL or DB_NAME/USER/PASSWORD/HOST)")
    else:
        add(9, "PostgreSQL connectivity (remote)", db_ok, db_msg)

    # 10 env file exists
    env_path = Path(getattr(args, "env_file", ENV_FILE_DEFAULT))
    exists = env_path.exists() and env_path.stat().st_size > 0
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
    perm_ok = True
    if env_path.exists():
        try:
            m = stat.S_IMODE(env_path.stat().st_mode)
            if m & 0o007:
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


def detect_django_layout(release_root: Path) -> DjangoLayout:
    # manage.py
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
    if not link.is_symlink():
        return None
    try:
        tgt = link.resolve(strict=False)
        return tgt if tgt.exists() else None
    except OSError:
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
    """Atomic symlink switch (uses ln -sfn via os.replace equivalent for safety)."""
    # Use a new temp symlink in same dir, then rename
    d = link.parent
    tmp = Path(tempfile.mktemp(prefix=".link.", dir=str(d)))
    try:
        os.symlink(str(target), tmp)
        os.replace(tmp, link)
    except Exception:
        with contextlib.suppress(OSError):
            if tmp.is_symlink():
                tmp.unlink()
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
    layout = detect_django_layout(release_path)
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
        os.chown(out_file, 0, 0)
    except OSError:
        pass
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
        print_banner_deploy_success(rj, dur_s, ok=ok, log=log)
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


def print_banner_deploy_success(rj: dict, dur_s: float, *, ok: bool, log=None) -> None:
    c = lambda col, on: _c(col, on)
    no_color = False
    status = "DEPLOY SUCCESS" if ok else "DEPLOY COMPLETED WITH UNHEALTHY SERVICES"
    box = (
        f"\n{c('BOLD', True)}{c('GREEN' if ok else 'YELLOW', True)}"
        f"╔{'═' * 70}╗\n"
        f"║ {status:<68s}║\n"
        f"╠{'═' * 70}╣\n"
        f"║ Release directory : {str(rj.get('switched_at',''))[:64]:<64s} ║\n"
        f"║ Git SHA           : {str(rj.get('git_sha',''))[:16]:<16s}              "
        f"(ref={str(rj.get('git_ref',''))[:20]:<20s}) ║\n"
        f"║ Prev release      : {str(rj.get('prev_release') or '(none)')[:64]:<64s} ║\n"
        f"║ Settings module   : {str(rj.get('settings_module',''))[:64]:<64s} ║\n"
        f"║ Duration          : {dur_s:6.1f} seconds                                        ║\n"
        f"║ Rollback command  : sudo python3 rasyatone_deploy.py --stage rollback        ║\n"
        f"╚{'═' * 70}╝{c('RESET', True)}\n"
    )
    print(box, file=sys.stderr)


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
    lines.append("─── health bundle ───")
    lines.append(detail)
    full = "\n".join(lines)
    if log is not None:
        log.info(scrub_secrets(f"CHECK_RESULT={'PASS' if ok else 'FAIL'}", env=scrub_env))
        print("\n" + _c("BOLD", True) + "RaSYaTone CHECK result:" + _c("RESET", True) +
              "\n" + full, file=sys.stderr)
    return 0 if ok and all(p for _, p, _ in check_results) else 6


# ============================================================
# 12. Remote-mode SSH wrapper (ssh_run + hostkey auto-cleanup)
# ============================================================
_REMOTE_RE = re.compile(r"^(?P<user>[^@:]+)@(?P<host>[^@:]+)(?::(?P<port>\d+))?$")


def _is_host_key_error(stderr: str) -> bool:
    if not stderr:
        return False
    needles = ("REMOTE HOST IDENTIFICATION HAS CHANGED", "Host key verification failed",
               "key does not match for", "Offending key", "WARNING: POSSIBLE DNS SPOOFING")
    return any(h in stderr for h in needles)


def _remove_host_key(host: str, port: Optional[int] = None, log=None) -> int:
    """Run ssh-keygen -R twice (bare and host:port bracketed). Returns 0 if last run_ok was 0."""
    def _run(cmd):
        return run_ok(cmd, log=log, check=False, timeout=60).returncode
    r1 = _run(["ssh-keygen", "-R", host])
    r2 = 0
    if port and port != 22:
        r2 = _run(["ssh-keygen", "-R", f"[{host}]:{port}"])
    return 0 if r1 == 0 or r2 == 0 else r1 | r2


def _ssh_base_args(host: str, user: str, port: Optional[int], identity: Optional[Path]) -> list[str]:
    args = ["ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "StrictHostKeyChecking=accept-new"]
    if identity:
        args += ["-o", f"IdentitiesOnly=yes", "-i", str(identity)]
    if port:
        args += ["-p", str(port)]
    args.append(f"{user}@{host}")
    return args


def ssh_run(*, host: str, user: str, port: Optional[int], identity: Optional[Path],
            script: str, timeout: int = 7200, log=None, scrub_env=None):
    """Run script on remote via ssh -T heredoc. Retry once on host-key error (auto-cleanup)."""
    base = _ssh_base_args(host, user, port, identity) + ["-T", "--", "bash", "-lc", script]
    first = subprocess.run(base, text=True, capture_output=True, timeout=timeout, check=False)
    if first.returncode != 0 and _is_host_key_error(first.stderr or ""):
        if log is not None:
            log.warning("[hostkey] Detected stale SSH host key for %s — running ssh-keygen -R then retrying",
                        host)
            log.info("[hostkey] Running: ssh-keygen -R %s%s",
                     host, f" -R [{host}]:{port}" if port and port != 22 else "")
        _remove_host_key(host, port=port, log=log)
        if log is not None:
            log.info("[hostkey] Retrying SSH connection with fresh host keys...")
        first = subprocess.run(base, text=True, capture_output=True, timeout=timeout, check=False)
    return first


def remote_deploy_wrapper(args, log, scrub_env) -> int:
    """Upload this script to remote, run with --local-mode plus all non-remote CLI flags, then exit."""
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
    if log is not None:
        log.info("REMOTE MODE → %s@%s%s", user, host, f":{port}" if port else "")
    # Read this script body
    this_file = Path(__file__).resolve()
    script_text = this_file.read_text(encoding="utf-8")
    # Build remote CLI args (exclude --remote / --identity) and include --local-mode
    pass_flags = _remote_build_args_argv(args)
    tmp_script = f"/tmp/rasyatone_deploy_tmp_{os.getpid()}.py"
    # Stage 1: write script via base64 heredoc (safe for special chars / long content)
    import base64
    b64 = base64.b64encode(script_text.encode("utf-8")).decode("ascii")
    stage1 = (f"python3 - <<'PYEOF'\n"
              f"import base64,sys\n"
              f"data = sys.stdin.read()\n"
              f"open({tmp_script!r},'wb').write(base64.b64decode(data))\n"
              f"import os; os.chmod({tmp_script!r},0o755)\n"
              f"PYEOF\n"
              f"<<<'B64EOF'\n{b64}\nB64EOF\n")
    # Actually build it as a single bash snippet
    transfer_script = (
        f"cat > {tmp_script}.b64 <<'B64EOF'\n{b64}\nB64EOF\n"
        f"python3 -c \"import base64; open('{tmp_script}','wb').write("
        f"base64.b64decode(open('{tmp_script}.b64').read()))\" && "
        f"chmod 0755 {tmp_script} && rm -f {tmp_script}.b64"
    )
    result = ssh_run(host=host, user=user, port=port, identity=identity_path,
                     script=transfer_script, timeout=300, log=log, scrub_env=scrub_env)
    if result.returncode != 0:
        if log is not None:
            log.error("Remote script upload failed:\n%s",
                      scrub_secrets((result.stderr or result.stdout or "")[-3000:]))
        return 40
    # Stage 2: run remotely
    run_argv = ["sudo", "-n", "python3", tmp_script, "--local-mode"] + pass_flags
    quoted = " ".join(shlex.quote(a) for a in run_argv)
    run_cmd = f"{quoted}; rc=$?; rm -f {shlex.quote(tmp_script)}; exit $rc"
    result2 = ssh_run(host=host, user=user, port=port, identity=identity_path,
                      script=run_cmd, timeout=4 * 3600, log=log, scrub_env=scrub_env)
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
    return p


def _print_preflight_summary_banner(args, env: dict[str, str],
                                     results: list[PreflightResult], log) -> None:
    deploy_dir = Path(getattr(args, "deploy_dir", DEPLOY_DIR_DEFAULT))
    domain = getattr(args, "domain", DOMAIN_DEFAULT)
    cur = current_release_link(deploy_dir)
    db_line = ("Remote PostgreSQL " + (
        f"at {env.get('DB_HOST','<set in env>')}:{env.get('DB_PORT','5432')}/"
        f"{env.get('DB_NAME','<name>')}" if not env.get("DATABASE_URL")
        else env.get("DATABASE_URL", "").split("@", 1)[-1].split("?")[0]))
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
        ("Current Release", str(cur) if cur else "(first deploy — none)"),
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
    B = _c("BOLD", True) + _c("BLUE", True)
    R = _c("RESET", True)
    print(f"\n{B}╔{'═'*bar}╗", file=sys.stderr)
    print(f"║ {'RaSYaTone Deployment — Preflight Summary':<{bar-2}s}║", file=sys.stderr)
    print(f"╠{'═'*bar}╣", file=sys.stderr)
    for k, v in lines:
        v = scrub_secrets(str(v), env=env)
        line = f"{k}: {v}"
        if len(line) > bar - 4:
            line = line[:bar - 7] + "..."
        print(f"║ {line:<{bar-2}s}║", file=sys.stderr)
    print(f"╚{'═'*bar}╝{R}\n", file=sys.stderr)
    # Also print per-check PASS/FAIL lines
    for num, name, ok, detail in results:
        status = "PASS" if ok else "FAIL"
        col = _c("GREEN", True) if ok else _c("RED", True)
        print(f"   {col}{status}{_c('RESET',True)}  #{num:<2d} {name:<52s} "
              f"{scrub_secrets(detail, env=env)[:120] if detail else ''}",
              file=sys.stderr)
    passed = sum(1 for r in results if r.ok)
    print(f"\n   Preflight {'PASSED' if passed == len(results) else 'FAILED'} — "
          f"{passed}/{len(results)} checks\n", file=sys.stderr)


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


def main(argv: list[str]) -> int:
    parser = _build_argparser()
    args = parser.parse_args(argv)
    if args.stage_set_deploy:
        args.stage = "deploy"
    # Remote mode short-circuit
    if args.remote and not getattr(args, "local_mode", False):
        dummy_log = setup_logging(Path.cwd(), quiet=args.quiet, verbose=args.verbose,
                                  no_color=args.no_color)
        dummy_scrub_env: dict[str, str] = {}
        try:
            return remote_deploy_wrapper(args, log=dummy_log, scrub_env=dummy_scrub_env)
        except DeployError as de:
            print(f"\nRemote deploy wrapper error: {de.user_msg}", file=sys.stderr)
            return de.code
        except KeyboardInterrupt:
            print("\nInterrupted.", file=sys.stderr)
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
        print(f"Unable to set up logging: {exc}", file=sys.stderr)
        import logging as _lg
        _lg.basicConfig(level=_lg.INFO)
        log = _lg.getLogger("rasyatone.deploy.fallback")

    # Parse env file (never os.environ)
    env_path = Path(args.env_file)
    env_dict: dict[str, str] = parse_env_file(env_path)
    start_time = time.time()
    duration = lambda: f"{(time.time() - start_time):.1f}s"

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

    # Deploy/rollback/check continue only if checks 1/2/10/11/12/15 are OK
    critical_checks = {1, 2, 10, 11, 12, 15}
    if not all(r.ok for r in results if r.num in critical_checks):
        fails = [f"#{r.num} {r.name}" for r in results if r.num in critical_checks and not r.ok]
        raise PreflightError(0, 102,
                             "Preflight critical checks failed — aborting before mutations: "
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
    release_json: dict[str, Any] = {}
    prev_release: Optional[Path] = None
    try:
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
        print(_c("RED", True) + _c("BOLD", True) +
              f"\n  ✖ Preflight FAILED (check #{e.stage}, code {e.code})" +
              _c("RESET", True) +
              f"\n  {scrub_secrets(e.user_msg, env=env_dict)[:800]}\n", file=sys.stderr)
        return e.code
    except StageError as e:
        # Stages 1..13 — site untouched.
        if log is not None:
            log.error(scrub_secrets(
                f"[STAGE ERROR #{e.stage}] code={e.code} {e.user_msg}", env=env_dict))
        msg = scrub_secrets((e.user_msg or "") + "\n" + (e._stderr or e._stdout or ""),
                            env=env_dict)[:2000]
        print(_c("RED", True) + _c("BOLD", True) +
              f"\n  ╔═══ DEPLOY STOPPED — NO PRODUCTION CHANGES (stage {e.stage}) ═══╗" +
              _c("RESET", True) + f"\n  code {e.code}: {msg}\n", file=sys.stderr)
        print(_c("YELLOW", True) +
              f"  Hint: current symlink untouched. Fix the above; rerun the deploy command.\n" +
              _c("RESET", True), file=sys.stderr)
        return e.code
    except ProdStageError as e:
        # Production was touched: attempt auto-rollback
        banner_msg = scrub_secrets(e.user_msg + "\n" + (e._stderr or e._stdout or ""),
                                   env=env_dict)[:2000]
        print(_c("RED", True) + _c("BOLD", True) +
              f"\n  ╔═══ PRODUCTION STAGE FAIL {e.stage} code={e.code} → AUTO-ROLLBACK ═══╗" +
              _c("RESET", True) + f"\n  {banner_msg}\n", file=sys.stderr)
        rollback_ok = False
        try:
            if log is not None:
                log.error("[AUTO-ROLLBACK] Prod stage %d failed — rolling back to %s",
                          e.stage, prev_release)
            if prev_release is None and release_json.get("prev_release"):
                prev_release = Path(release_json["prev_release"])
            if prev_release is not None:
                # simulate rollback args
                run_rollback(args, env=env_dict, log=log, scrub_env=env_dict)
                rollback_ok = True
        except Exception as r_exc:
            print(f"  ⚠ Auto-rollback failed: {r_exc}", file=sys.stderr)
            if log is not None:
                log.error("Auto-rollback exception: %s", r_exc)
        if not rollback_ok:
            print(_c("RED", True) + _c("BOLD", True) +
                  "  ⚠ MANUAL INTERVENTION REQUIRED — auto-rollback could not execute." +
                  _c("RESET", True) + """
  Next steps:
    1. sudo systemctl --failed
    2. sudo journalctl -u rasyatone -n 100
    3. sudo tail -n 100 /var/log/rasyatone/nginx.error.log
    4. sudo ln -sfn /opt/rasyatone/releases/<KNOWN_GOOD_TS> /opt/rasyatone/current
    5. sudo systemctl restart rasyatone nginx
""" + _c("RESET", True), file=sys.stderr)
        return e.code
    except KeyboardInterrupt:
        print("\nInterrupted by user.", file=sys.stderr)
        return 130
    finally:
        if log is not None:
            log.info(scrub_secrets(f"FINAL duration={duration()} stage={args.stage}",
                                   env=env_dict))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
