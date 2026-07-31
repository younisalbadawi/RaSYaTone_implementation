import argparse
import getpass
import os
import platform
import re
import shutil
import shlex
import subprocess
import sys
import tempfile
import textwrap
from typing import Iterable, Mapping, Sequence


NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,62}$")
CIDR_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$")

LATEST_PG_MAJOR = 18
PG_MAJOR_COUNT = 5


def is_windows() -> bool:
    return sys.platform.startswith("win")


def is_admin_windows() -> bool:
    if not is_windows():
        return os.geteuid() == 0
    try:
        import ctypes

        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def which(cmd: str) -> str | None:
    return shutil.which(cmd)


def yes_no(prompt: str, default: bool = False) -> bool:
    suffix = " [Y/n] " if default else " [y/N] "
    while True:
        raw = input(prompt + suffix).strip().lower()
        if not raw:
            return default
        if raw in {"y", "yes"}:
            return True
        if raw in {"n", "no"}:
            return False
        print("Please answer y or n.")


def prompt_choice(title: str, options: Sequence[str]) -> int:
    if not options:
        raise ValueError("options must not be empty")
    print()
    print(title)
    for i, opt in enumerate(options, 1):
        print(f"  {i}. {opt}")
    while True:
        raw = input(f"Select 1-{len(options)}: ").strip()
        if raw.isdigit():
            idx = int(raw)
            if 1 <= idx <= len(options):
                return idx - 1
        print("Invalid selection.")


def default_postgres_majors() -> list[int]:
    latest = LATEST_PG_MAJOR
    return list(range(latest, latest - PG_MAJOR_COUNT, -1))


def prompt_postgres_major() -> int:
    majors = default_postgres_majors()
    options = [f"{m} (recommended)" if i == 0 else str(m) for i, m in enumerate(majors)]
    options.append("Other (enter manually)")
    idx = prompt_choice("Select PostgreSQL major version", options)
    if idx < len(majors):
        return majors[idx]
    while True:
        raw = input("PostgreSQL major version (e.g., 18): ").strip()
        if raw.isdigit() and 9 <= int(raw) <= 99:
            return int(raw)
        print("Invalid major version.")


def run_cmd(
    args: Sequence[str],
    *,
    env: Mapping[str, str] | None = None,
    check: bool = False,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    stdout = subprocess.PIPE if capture else None
    stderr = subprocess.PIPE if capture else None
    return subprocess.run(
        list(args),
        text=True,
        env=merged_env,
        stdout=stdout,
        stderr=stderr,
        check=check,
    )


def normalize_sql_literal(value: str) -> str:
    if "'" not in value:
        return value
    out: list[str] = []
    i = 0
    n = len(value)
    while i < n:
        ch = value[i]
        if ch == "'":
            out.append("''")
            i += 1
            while i < n and value[i] == "'":
                i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def normalize_sql_identifier(ident: str) -> str:
    return ident.replace('"', '""')


def build_role_sql(app_user: str, app_pass: str) -> str:
    u = normalize_sql_identifier(app_user)
    return f"""
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '{normalize_sql_literal(app_user)}') THEN
            CREATE ROLE "{u}" LOGIN PASSWORD '{normalize_sql_literal(app_pass)}' CREATEDB;
        ELSE
            ALTER ROLE "{u}" LOGIN PASSWORD '{normalize_sql_literal(app_pass)}' CREATEDB;
        END IF;
    END
    $$;
    """


def build_db_exists_sql(db_name: str) -> str:
    return f"SELECT 1 FROM pg_catalog.pg_database WHERE datname = '{normalize_sql_literal(db_name)}';"


def build_create_db_sql(db_name: str, app_user: str) -> str:
    d = normalize_sql_identifier(db_name)
    u = normalize_sql_identifier(app_user)
    return f'CREATE DATABASE "{d}" OWNER "{u}";'


def build_grant_sql(db_name: str, app_user: str, schema_name: str = "public") -> str:
    d = normalize_sql_identifier(db_name)
    u = normalize_sql_identifier(app_user)
    s = normalize_sql_identifier(schema_name)
    return (
        f'GRANT CONNECT, TEMPORARY ON DATABASE "{d}" TO "{u}";'
        f'GRANT ALL ON SCHEMA "{s}" TO "{u}";'
        f'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA "{s}" TO "{u}";'
        f'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA "{s}" TO "{u}";'
        f'GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA "{s}" TO "{u}";'
        f'GRANT ALL PRIVILEGES ON ALL TYPES IN SCHEMA "{s}" TO "{u}";'
        f'ALTER DEFAULT PRIVILEGES IN SCHEMA "{s}" GRANT ALL ON TABLES TO "{u}";'
        f'ALTER DEFAULT PRIVILEGES IN SCHEMA "{s}" GRANT ALL ON SEQUENCES TO "{u}";'
        f'ALTER DEFAULT PRIVILEGES IN SCHEMA "{s}" GRANT ALL ON FUNCTIONS TO "{u}";'
        f'ALTER DEFAULT PRIVILEGES IN SCHEMA "{s}" GRANT ALL ON TYPES TO "{u}";'
    )


def prompt_identifier(label: str, default: str | None = None) -> str:
    while True:
        raw = input(f"{label}{f' [{default}]' if default else ''}: ").strip()
        if not raw and default:
            raw = default
        if NAME_RE.match(raw):
            return raw
        print("Must match: [A-Za-z_][A-Za-z0-9_]{0,62}")


def prompt_port(default: int = 5432) -> int:
    while True:
        raw = input(f"Port [{default}]: ").strip()
        if not raw:
            return default
        if raw.isdigit() and 1 <= int(raw) <= 65535:
            return int(raw)
        print("Invalid port.")


def prompt_host(default: str = "localhost") -> str:
    while True:
        raw = input(f"Host (remote DNS/IP or localhost) [{default}]: ").strip()
        if not raw:
            return default
        if raw:
            return raw


def prompt_cidr(default: str = "0.0.0.0/0") -> str:
    while True:
        raw = input(f"Allowed CIDR [{default}]: ").strip()
        if not raw:
            raw = default
        if CIDR_RE.match(raw):
            ip, mask = raw.split("/", 1)
            parts = ip.split(".")
            if all(0 <= int(p) <= 255 for p in parts) and 0 <= int(mask) <= 32:
                return raw
        print("Invalid CIDR. Example: 10.0.0.0/24")


def prompt_auth_method(default: str = "scram-sha-256") -> str:
    options = ["scram-sha-256", "md5"]
    default = default if default in options else "scram-sha-256"
    print()
    print("Authentication method for remote connections:")
    for i, opt in enumerate(options, 1):
        suffix = " (default)" if opt == default else ""
        print(f"  {i}. {opt}{suffix}")
    while True:
        raw = input(f"Select 1-{len(options)} [{options.index(default) + 1}]: ").strip()
        if not raw:
            return default
        if raw.isdigit():
            idx = int(raw)
            if 1 <= idx <= len(options):
                return options[idx - 1]
        print("Invalid selection.")



def print_block(title: str, body: str) -> None:
    print()
    print(title)
    print("-" * len(title))
    print(textwrap.dedent(body).strip())


def format_tcp_ports(ports: Sequence[int]) -> str:
    return ", ".join(f"TCP/{p}" for p in ports)


def print_progress(step: int, total: int, label: str) -> None:
    print(f"[{step}/{total}] {label}")


def file_has_exact_line(path: str, needle: str) -> bool:
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.strip() == needle.strip():
                    return True
    except Exception:
        return False
    return False


def backup_file(path: str) -> str:
    backup_path = f"{path}.trae.bak"
    shutil.copy2(path, backup_path)
    return backup_path


def restore_file(backup_path: str, target_path: str) -> None:
    shutil.copy2(backup_path, target_path)


def detect_linux_pkg_manager() -> str | None:
    if which("apt-get"):
        return "apt"
    if which("dnf"):
        return "dnf"
    if which("yum"):
        return "yum"
    return None


def linux_install_postgres() -> None:
    mgr = detect_linux_pkg_manager()
    if not mgr:
        print_block(
            "Unsupported Linux",
            """
            Could not detect apt/dnf/yum.
            Install PostgreSQL using your distribution docs, then re-run this script for configuration.
            """,
        )
        return

    pg_major = prompt_postgres_major()
    needs_sudo = os.geteuid() != 0
    sudo = ["sudo"] if needs_sudo and which("sudo") else []

    if mgr == "apt":
        pgdg_list = "/etc/apt/sources.list.d/pgdg.list"
        keyring = "/usr/share/keyrings/postgresql.gpg"
        codename = ""
        try:
            if os.path.isfile("/etc/os-release"):
                with open("/etc/os-release", "r", encoding="utf-8", errors="ignore") as f:
                    for line in f:
                        if line.startswith("VERSION_CODENAME="):
                            codename = line.split("=", 1)[1].strip().strip('"')
                            break
        except Exception:
            codename = ""
        if not codename:
            codename = "stable"

        needs_repo = True
        try:
            if os.path.isfile(pgdg_list):
                with open(pgdg_list, "r", encoding="utf-8", errors="ignore") as f:
                    if "apt.postgresql.org" in f.read():
                        needs_repo = False
        except Exception:
            needs_repo = True

        cmds: list[list[str]] = []
        if needs_repo:
            cmds += [
                sudo + ["apt-get", "update"],
                sudo + ["apt-get", "install", "-y", "ca-certificates", "curl", "gnupg", "lsb-release"],
                sudo + ["bash", "-lc", f"install -d -m 0755 /usr/share/keyrings"],
                sudo
                + [
                    "bash",
                    "-lc",
                    f"test -f {shlex.quote(keyring)} || (curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | tee {shlex.quote(keyring)} >/dev/null)",
                ],
                sudo
                + [
                    "bash",
                    "-lc",
                    f'echo "deb [signed-by={keyring}] http://apt.postgresql.org/pub/repos/apt {codename}-pgdg main" | tee {shlex.quote(pgdg_list)} >/dev/null',
                ],
            ]
        cmds += [
            sudo + ["apt-get", "update"],
            sudo
            + [
                "apt-get",
                "install",
                "-y",
                f"postgresql-{pg_major}",
                f"postgresql-contrib-{pg_major}",
            ],
        ]
    else:
        cmds = [
            sudo + [mgr, "install", "-y", "postgresql-server", "postgresql-contrib"],
        ]

    print_block(
        "Plan",
        f"PostgreSQL major: {pg_major}\n\n" + "\n".join(" ".join(c) for c in cmds),
    )
    if not yes_no("Run these commands now?", default=True):
        return

    for c in cmds:
        p = run_cmd(c, check=False)
        if p.returncode != 0:
            print(f"Command failed ({p.returncode}): {' '.join(c)}")
            return

    if mgr in {"dnf", "yum"}:
        initdb_cmd = sudo + ["postgresql-setup", "--initdb"]
        print()
        print("Initializing database cluster:")
        print(" ".join(initdb_cmd))
        p = run_cmd(initdb_cmd, check=False)
        if p.returncode != 0:
            print(f"Initdb failed ({p.returncode}).")
            return

    start_cmds: list[list[str]] = []
    if which("systemctl"):
        start_cmds.append(sudo + ["systemctl", "enable", "--now", "postgresql"])
    elif which("service"):
        start_cmds.append(sudo + ["service", "postgresql", "start"])

    if start_cmds:
        print()
        print("Starting PostgreSQL service:")
        for c in start_cmds:
            print(" ".join(c))
            run_cmd(c, check=False)

    print_block(
        "Done",
        """
        PostgreSQL installation step completed (best-effort).
        Next: choose "Configure (create DB/user)" from the main menu.
        """,
    )


def windows_install_postgres() -> None:
    if not which("winget"):
        print_block(
            "winget not found",
            """
            This workflow is optimized for winget on Windows.

            Install winget by installing "App Installer" from Microsoft Store, then re-run.
            Manual fallback (official installer):
              https://www.postgresql.org/download/windows/
            """,
        )
        return

    candidates: list[str] = [
        "PostgreSQL.PostgreSQL",
        "EnterpriseDB.PostgreSQL",
    ]

    pg_major = prompt_postgres_major()

    print()
    print("Trying winget package IDs:")
    for c in candidates:
        print(f"  - {c}")

    if not yes_no("Proceed with winget install?", default=True):
        return

    if not is_admin_windows():
        print_block(
            "Admin rights recommended",
            """
            Installing PostgreSQL often requires Administrator privileges.
            If the install fails, re-run this script as Administrator.
            """,
        )

    def parse_winget_versions(output: str) -> list[str]:
        out: list[str] = []
        for line in output.splitlines():
            s = line.strip()
            if not s:
                continue
            if s.lower().startswith("version"):
                continue
            if re.fullmatch(r"[0-9][0-9A-Za-z.\-+]*", s):
                out.append(s)
        return out

    def version_key(v: str) -> tuple[int, ...]:
        nums = re.findall(r"\d+", v)
        return tuple(int(n) for n in nums[:4]) if nums else (0,)

    def resolve_winget_version(pkg_id: str, major: int) -> str | None:
        p = run_cmd(
            ["winget", "show", "-e", "--id", pkg_id, "--versions"],
            capture=True,
            check=False,
        )
        if p.returncode != 0:
            return None
        versions = parse_winget_versions((p.stdout or "") + "\n" + (p.stderr or ""))
        filtered = [v for v in versions if re.match(rf"^{major}\D|^{major}$", v)]
        if not filtered:
            filtered = [v for v in versions if v.startswith(f"{major}.")]
        if not filtered:
            return None
        return sorted(filtered, key=version_key, reverse=True)[0]

    for pkg_id in candidates:
        selected = resolve_winget_version(pkg_id, pg_major)
        args = [
            "winget",
            "install",
            "-e",
            "--id",
            pkg_id,
            "--accept-package-agreements",
            "--accept-source-agreements",
        ]
        if selected:
            args += ["--version", selected]
        p = run_cmd(
            args,
            check=False,
        )
        if p.returncode == 0:
            print_block(
                "Done",
                f"""
                PostgreSQL major requested: {pg_major}
                Installed via winget: {pkg_id}{f' (version {selected})' if selected else ''}

                If psql is still not detected, open a new terminal or re-login, then use:
                - Configure (create DB/user)
                - Verify
                """,
            )
            return

    print_block(
        "winget install failed",
        """
        winget could not install PostgreSQL with the known IDs.
        Use the official installer (EDB) and then re-run this script for configuration:
          https://www.postgresql.org/download/windows/
        """,
    )


def install_postgres() -> None:
    if is_windows():
        windows_install_postgres()
        return
    linux_install_postgres()


def ssh_base_args(host: str, port: int, user: str, identity_file: str | None) -> list[str]:
    args = [
        "ssh",
        "-p",
        str(port),
        "-o",
        "LogLevel=ERROR",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=3",
        "-o",
        "RequestTTY=no",
        "-T",
    ]
    if identity_file:
        args += ["-i", identity_file]
    args.append(f"{user}@{host}")
    return args


def _is_host_key_error(stderr_text: str) -> bool:
    t = stderr_text or ""
    needles = (
        "REMOTE HOST IDENTIFICATION HAS CHANGED",
        "Host key verification failed",
        "key does not match for",
        "Offending key",
        "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED",
    )
    return any(n in t for n in needles)


def _remove_host_key(host: str, port: int) -> None:
    """Run ssh-keygen -R for host and [host]:port variants. Never aborts."""
    targets: list[str] = []
    if host:
        targets.append(host)
    if port and port != 22:
        targets.append(f"[{host}]:{port}")
    else:
        targets.append(f"[{host}]:22")
    for target in targets:
        try:
            r = run_cmd(
                ["ssh-keygen", "-R", target],
                capture=True,
                check=False,
            )
            if r.returncode == 0:
                print(f"[hostkey] Removed stale entry: {target}")
            else:
                msg = (r.stderr or r.stdout or "").strip()
                if msg and "not found" not in msg.lower():
                    print(f"[hostkey] ssh-keygen -R {target}: {msg}")
        except (OSError, subprocess.SubprocessError) as exc:
            print(f"[hostkey] WARN: could not run ssh-keygen -R {target}: {exc}")


def ssh_run(
    *,
    host: str,
    port: int,
    user: str,
    identity_file: str | None,
    remote_command: str,
    capture: bool,
) -> subprocess.CompletedProcess[str]:
    base = ssh_base_args(host, port, user, identity_file)
    cmd = base + [remote_command]
    merged_env = os.environ.copy()
    stdout_pipe = subprocess.PIPE if capture else subprocess.PIPE
    stderr_pipe = subprocess.PIPE if capture else subprocess.PIPE

    def _run_once() -> subprocess.CompletedProcess[str]:
        p = subprocess.run(
            list(cmd),
            text=True,
            env=merged_env,
            stdout=stdout_pipe,
            stderr=stderr_pipe,
            check=False,
        )
        if not capture:
            if p.stdout:
                sys.stdout.write(p.stdout)
                sys.stdout.flush()
            if p.stderr:
                sys.stderr.write(p.stderr)
                sys.stderr.flush()
        return p

    result = _run_once()
    if (result.returncode != 0 or capture) and _is_host_key_error(result.stderr or ""):
        print()
        print("[hostkey] Detected stale SSH host key for remote host.")
        print(f"[hostkey] Running: ssh-keygen -R {host} -R [{host}]:{port}")
        _remove_host_key(host, port)
        print("[hostkey] Retrying SSH connection with fresh host keys...")
        result = _run_once()
    return result


def prompt_ssh_connection() -> tuple[str, int, str, str | None, bool]:
    host = prompt_host("server.example.com")
    ssh_port = prompt_port(22)
    ssh_user = input("SSH username [root]: ").strip() or "root"
    identity_raw = input("SSH identity file path (optional): ").strip()
    identity_file = identity_raw or None
    use_sudo = False if ssh_user == "root" else yes_no("Use sudo on remote host?", default=True)
    return host, ssh_port, ssh_user, identity_file, use_sudo


def detect_remote_linux_pkg_manager(
    *,
    host: str,
    port: int,
    user: str,
    identity_file: str | None,
) -> tuple[str | None, str]:
    cmd = (
        "if command -v apt-get >/dev/null 2>&1; then echo __PKG__=apt; "
        "elif command -v dnf >/dev/null 2>&1; then echo __PKG__=dnf; "
        "elif command -v yum >/dev/null 2>&1; then echo __PKG__=yum; "
        "else echo __PKG__=unknown; fi"
    )
    p = ssh_run(
        host=host,
        port=port,
        user=user,
        identity_file=identity_file,
        remote_command=f"sh -lc {shlex.quote(cmd)}",
        capture=True,
    )
    out = (p.stdout or "") + "\n" + (p.stderr or "")
    if p.returncode != 0:
        return None, out.strip()
    m = re.search(r"__PKG__=(apt|dnf|yum|unknown)", out)
    if not m:
        return None, out.strip()
    pkg = m.group(1)
    return (pkg if pkg in {"apt", "dnf", "yum"} else None), out.strip()


def remote_install_postgres_ssh() -> None:
    if not which("ssh"):
        print_block(
            "ssh not found",
            """
            OpenSSH client is required to install PostgreSQL on a remote Linux host.

            Windows:
              Settings -> Optional features -> Add a feature -> OpenSSH Client
            Linux:
              Install the 'openssh-client' package.
            """,
        )
        return

    host, ssh_port, ssh_user, identity_file, use_sudo = prompt_ssh_connection()
    pg_major = prompt_postgres_major()
    sudo = "sudo " if use_sudo else ""

    mgr, diag = detect_remote_linux_pkg_manager(
        host=host,
        port=ssh_port,
        user=ssh_user,
        identity_file=identity_file,
    )
    if not mgr:
        diag_block = "\nSSH diagnostic output:\n" + diag if diag else ""
        print_block(
            "Unsupported remote host",
            f"""
            Could not detect apt/dnf/yum on the remote machine, or SSH failed.
            Verify SSH connectivity and install PostgreSQL using your distribution docs.
            {diag_block}
            """,
        )
        return

    remote_script_lines: list[str] = []
    if mgr == "apt":
        remote_script_lines += [
            f'{sudo}bash -lc \'set -e; if [ -f /etc/apt/sources.list.d/pgdg.list ] && grep -q "apt.postgresql.org" /etc/apt/sources.list.d/pgdg.list; then exit 0; fi; apt-get update || {{ echo "apt-get update failed (prereqs)"; exit 1; }}; apt-get install -y ca-certificates curl gnupg lsb-release || {{ echo "apt-get install prereqs failed"; exit 2; }}; install -d -m 0755 /usr/share/keyrings || true; if [ ! -f /usr/share/keyrings/postgresql.gpg ]; then curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | tee /usr/share/keyrings/postgresql.gpg >/dev/null || {{ echo "Failed to download/install PGDG signing key"; exit 3; }}; fi; CODENAME="$(lsb_release -cs 2>/dev/null || true)"; if [ -z "$CODENAME" ] && [ -f /etc/os-release ]; then . /etc/os-release; CODENAME="$VERSION_CODENAME"; fi; echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt ${{CODENAME}}-pgdg main" | tee /etc/apt/sources.list.d/pgdg.list >/dev/null\'',
            f"{sudo}apt-get update || {{ echo 'apt-get update failed'; exit 4; }}",
            f"{sudo}apt-get install -y postgresql-{pg_major} postgresql-contrib-{pg_major} || {{ echo 'apt-get install postgresql-{pg_major} failed'; exit 5; }}",
            f"{sudo}systemctl enable --now postgresql || {sudo}service postgresql start || true",
        ]
    else:
        remote_script_lines += [
            f"{sudo}{mgr} install -y postgresql-server postgresql-contrib || {{ echo '{mgr} install postgresql-server failed'; exit 5; }}",
            f"{sudo}postgresql-setup --initdb || true",
            f"{sudo}systemctl enable --now postgresql || {sudo}service postgresql start || true",
        ]

    remote_script = "set -e; " + "; ".join(remote_script_lines)
    remote_commands_indented = textwrap.indent("\n".join(remote_script_lines), "  ")

    print_block(
        "Plan",
        f"""
        Target: {ssh_user}@{host}:{ssh_port}
        Package manager: {mgr}
        PostgreSQL major: {pg_major}

        Remote commands:
        {remote_commands_indented}

        Note: if you chose SSH password auth, SSH will prompt you in the terminal.
        """,
    )
    if not yes_no("Install PostgreSQL on the remote host now?", default=True):
        return

    p = ssh_run(
        host=host,
        port=ssh_port,
        user=ssh_user,
        identity_file=identity_file,
        remote_command=f"bash -lc {shlex.quote(remote_script)}",
        capture=False,
    )
    if p.returncode != 0:
        print_block("Failed", f"Remote installation failed with exit code {p.returncode}.")
        return

    print_block(
        "Done",
        """
        PostgreSQL installation on the remote host completed (best-effort).
        Next:
        - Use "Verify" from this script to test connectivity (host/port/user/password).
        - Use "Enable remote access (server)" on the server itself to edit config files,
          or tell me to add a remote-enabled version over SSH.
        """,
    )


REMOTE_FIREWALL_SETUP_SNIPPET = """
    ufw_port_allowed() {
      # $1 = numeric port; returns 0 if port/tcp is allowed (by port or service name)
      local p="$1"
      local out="$2"
      echo "$out" | grep -qE "(^|[[:space:]])${p}/tcp([[:space:]]|$)" && return 0
      local svc
      while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        echo "$out" | grep -qiE "(^|[[:space:]])${svc}([[:space:]]|$)" && return 0
      done < <(getent services "${p}/tcp" 2>/dev/null | awk '{print $1}')
      return 1
    }
    firewalld_port_allowed() {
      # $1 = numeric port; checks ports, services, and running+permanent rich rules
      local p="$1"
      local s
      $SUDO firewall-cmd --list-ports 2>/dev/null | grep -qw "${p}/tcp" && return 0
      $SUDO firewall-cmd --permanent --list-ports 2>/dev/null | grep -qw "${p}/tcp" && return 0
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        local pn
        pn="$(getent services "$s/tcp" 2>/dev/null | awk '{print $2}' | cut -d/ -f1)"
        [ "$pn" = "$p" ] && return 0
      done < <($SUDO firewall-cmd --list-services 2>/dev/null; $SUDO firewall-cmd --permanent --list-services 2>/dev/null)
      # Firewalld v0.9+ has --query-port (most robust):
      if $SUDO firewall-cmd --query-port "${p}/tcp" --permanent >/dev/null 2>&1; then return 0; fi
      if $SUDO firewall-cmd --query-port "${p}/tcp" >/dev/null 2>&1; then return 0; fi
      return 1
    }
    ensure_firewall_ports() {
      FW_CHANGED=0
      local was_enabled=0 was_active=0 ufw_out="" pn s
      if command -v ufw >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1; then
          $SUDO systemctl is-enabled ufw >/dev/null 2>&1 && was_enabled=1 || true
          $SUDO systemctl is-active ufw >/dev/null 2>&1 && was_active=1 || true
          if [ "$was_enabled" -eq 0 ]; then $SUDO systemctl enable ufw >/dev/null 2>&1 || true; FW_CHANGED=1; fi
          if [ "$was_active" -eq 0 ]; then $SUDO systemctl start ufw >/dev/null 2>&1 || true; FW_CHANGED=1; fi
        elif command -v service >/dev/null 2>&1; then
          $SUDO service ufw start >/dev/null 2>&1 || true
          FW_CHANGED=1
        fi
        ufw_out="$($SUDO ufw status 2>/dev/null || true)"
        if ! ufw_port_allowed "${SSH_PORT}" "$ufw_out"; then
          $SUDO ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true; FW_CHANGED=1
        fi
        if ! ufw_port_allowed "${PG_PORT}" "$ufw_out"; then
          $SUDO ufw allow "${PG_PORT}/tcp" >/dev/null 2>&1 || true; FW_CHANGED=1
        fi
        return 0
      fi

      if command -v firewall-cmd >/dev/null 2>&1; then
        was_enabled=0; was_active=0
        if command -v systemctl >/dev/null 2>&1; then
          $SUDO systemctl is-enabled firewalld >/dev/null 2>&1 && was_enabled=1 || true
          $SUDO systemctl is-active firewalld >/dev/null 2>&1 && was_active=1 || true
          if [ "$was_enabled" -eq 0 ]; then $SUDO systemctl enable firewalld >/dev/null 2>&1 || true; FW_CHANGED=1; fi
          if [ "$was_active" -eq 0 ]; then $SUDO systemctl start firewalld >/dev/null 2>&1 || true; FW_CHANGED=1; fi
        elif command -v service >/dev/null 2>&1; then
          $SUDO service firewalld start >/dev/null 2>&1 || true
          FW_CHANGED=1
        fi
        if ! firewalld_port_allowed "${SSH_PORT}"; then
          $SUDO firewall-cmd --add-port "${SSH_PORT}/tcp" --permanent >/dev/null 2>&1 || true; FW_CHANGED=1
        fi
        if ! firewalld_port_allowed "${PG_PORT}"; then
          $SUDO firewall-cmd --add-port "${PG_PORT}/tcp" --permanent >/dev/null 2>&1 || true; FW_CHANGED=1
        fi
        if [ "$FW_CHANGED" -eq 1 ]; then
          $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
        fi
        return 0
      fi
      return 0
    }
"""


REMOTE_CONFIG_FAILSAFE_SNIPPET = """
    CONFIG_BACKUP=""
    HBA_BACKUP=""
    rollback_remote_config() {
      set +e
      if [ -n "$CONFIG_BACKUP" ] && [ -f "$CONFIG_BACKUP" ]; then
        $SUDO cp "$CONFIG_BACKUP" "$CONFIG_FILE"
      fi
      if [ -n "$HBA_BACKUP" ] && [ -f "$HBA_BACKUP" ]; then
        $SUDO cp "$HBA_BACKUP" "$HBA_FILE"
      fi
      if [ -n "$CONFIG_BACKUP" ] || [ -n "$HBA_BACKUP" ]; then
        if command -v systemctl >/dev/null 2>&1; then
          $SUDO systemctl restart postgresql || true
        elif command -v service >/dev/null 2>&1; then
          $SUDO service postgresql restart || true
        elif command -v pg_ctl >/dev/null 2>&1 && [ -n "$DATA_DIR" ]; then
          as_postgres pg_ctl restart -D "$DATA_DIR" -m fast || true
        fi
      fi
    }

    backup_remote_config() {
      CONFIG_BACKUP="${CONFIG_FILE}.trae.bak"
      HBA_BACKUP="${HBA_FILE}.trae.bak"
      $SUDO cp "$CONFIG_FILE" "$CONFIG_BACKUP" || { echo "Backup failed for $CONFIG_FILE" >&2; exit 6; }
      $SUDO cp "$HBA_FILE" "$HBA_BACKUP" || { echo "Backup failed for $HBA_FILE" >&2; exit 6; }
    }
"""


def remote_full_setup_ssh() -> None:
    if not which("ssh"):
        print_block(
            "ssh not found",
            """
            OpenSSH client is required to configure a remote Linux host via SSH.

            Windows:
              Settings -> Optional features -> Add a feature -> OpenSSH Client
            Linux:
              Install the 'openssh-client' package.
            """,
        )
        return

    host, ssh_port, ssh_user, identity_file, use_sudo = prompt_ssh_connection()
    pg_major = prompt_postgres_major()
    db_name = prompt_identifier("Database name", default="app_db")
    app_user = prompt_identifier("App username", default="app_user")
    app_pass = getpass.getpass("App user password (leave blank to prompt later): ")
    if not app_pass:
        app_pass = getpass.getpass("App user password: ")

    listen_addresses = input("listen_addresses value [*]: ").strip() or "*"
    pg_port = prompt_port(5432)
    cidr = prompt_cidr("0.0.0.0/0")
    if cidr == "0.0.0.0/0":
        print_block(
            "Security warning",
            """
            You selected 0.0.0.0/0 (any IP).
            This exposes PostgreSQL to the internet if your network allows it.
            """,
        )
        if not yes_no("Proceed anyway?", default=False):
            return

    auth = prompt_auth_method("scram-sha-256")
    mgr, diag = detect_remote_linux_pkg_manager(
        host=host,
        port=ssh_port,
        user=ssh_user,
        identity_file=identity_file,
    )
    if not mgr:
        diag_block = "\nSSH diagnostic output:\n" + diag if diag else ""
        print_block(
            "Unsupported remote host",
            f"""
            Could not detect apt/dnf/yum on the remote machine, or SSH failed.
            Verify SSH connectivity and install PostgreSQL using your distribution docs.
            {diag_block}
            """,
        )
        return

    firewall_ports = [ssh_port, pg_port]
    print_block(
        "Plan",
        f"""
        Target (SSH): {ssh_user}@{host}:{ssh_port}
        Package manager: {mgr}
        PostgreSQL major: {pg_major}

        Steps to run:
        1. Ensure PGDG repo (apt only)
        2. Install PostgreSQL packages
        3. Start/restart PostgreSQL service
        4. Create/update role: {app_user}
        5. Create database: {db_name}
        6. Back up PostgreSQL config files
        7. Set listen_addresses = '{listen_addresses}'
        8. Add pg_hba.conf rule: host all all {cidr} {auth}
        9. Ensure firewall service is enabled/running when present
        10. Open firewall ports: {format_tcp_ports(firewall_ports)}
        11. Validate PostgreSQL health, else roll config changes back
        """,
    )
    if not yes_no("Run the full remote setup now?", default=True):
        return

    role_sql = " ".join(textwrap.dedent(build_role_sql(app_user, app_pass)).splitlines())
    role_exists_sql = f"SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '{normalize_sql_literal(app_user)}';"
    db_exists_sql = build_db_exists_sql(db_name)
    create_db_sql = build_create_db_sql(db_name, app_user)
    grant_sql = build_grant_sql(db_name, app_user)

    remote_script = f"""
    STEP=0
    TOTAL=9
    progress() {{
      STEP=$((STEP+1))
      echo "[$STEP/$TOTAL] $1"
    }}
    report() {{
      printf '%s\\t%s\\t%s\\n' "$1" "$2" "$3" >> "$REPORT_FILE" 2>/dev/null || true
    }}
    show_report() {{
      echo
      echo "Summary"
      echo "-------"
      printf '%-22s %-6s %s\\n' "Action" "Status" "Details"
      printf '%-22s %-6s %s\\n' "------" "------" "-------"
      if [ -n "$REPORT_FILE" ] && [ -f "$REPORT_FILE" ]; then
        cat "$REPORT_FILE" 2>/dev/null | while IFS=$'\\t' read -r a s d; do printf '%-22s %-6s %s\\n' "$a" "$s" "$d"; done
      fi
    }}
    REPORT_FILE="$(mktemp -p /tmp pg_full_setup_report.XXXXXX 2>/dev/null || echo /tmp/pg_full_setup_report.$$)"
    : > "$REPORT_FILE" 2>/dev/null || true
    trap 'show_report' EXIT
    set -e

    USE_SUDO={1 if use_sudo else 0}
    if [ "$USE_SUDO" -eq 1 ]; then
      if ! command -v sudo >/dev/null 2>&1; then
        report "PGDG repo"       "FAIL" "sudo not found on remote host (needed for privileged writes)"
        report "Install packages" "FAIL" "sudo not found on remote host (needed for package install)"
        report "Service"         "FAIL" "sudo not found on remote host (needed for service enable)"
        report "Role"            "FAIL" "sudo not found on remote host (needed for role creation)"
        report "Database"        "FAIL" "sudo not found on remote host (needed for database creation)"
        report "Grants"          "FAIL" "sudo not found on remote host (needed for grant application)"
        report "listen_addresses" "FAIL" "sudo not found on remote host (needed for postgresql.conf edits)"
        report "pg_hba rule"     "FAIL" "sudo not found on remote host (needed for pg_hba.conf edits)"
        report "Firewall"        "FAIL" "sudo not found on remote host (needed for firewall rules)"
        echo "sudo not found on remote host" >&2
        exit 4
      fi
      SUDO="sudo"
    else
      SUDO=""
    fi

    PKG_MGR={shlex.quote(mgr)}
    PG_MAJOR={int(pg_major)}
    pkg_installed() {{
      if [ "$PKG_MGR" = "apt" ]; then
        if dpkg-query -W -f='${{Status}}' "postgresql-$PG_MAJOR" 2>/dev/null | grep -q 'install ok installed'; then
          return 0
        else
          return 1
        fi
      fi
      if rpm -q postgresql-server >/dev/null 2>&1; then return 0; fi
      if rpm -q postgresql >/dev/null 2>&1; then return 0; fi
      return 1
    }}

    progress "Ensure PGDG repo"
    if [ "$PKG_MGR" = "apt" ]; then
      PGDG_FOUND=0
      if [ -f /etc/apt/sources.list.d/pgdg.list ] && $SUDO grep -q "apt.postgresql.org" /etc/apt/sources.list.d/pgdg.list; then PGDG_FOUND=1; fi
      if [ "$PGDG_FOUND" -eq 0 ] && [ -f /etc/apt/sources.list.d/pgdg.sources ] && $SUDO grep -q "apt.postgresql.org" /etc/apt/sources.list.d/pgdg.sources; then PGDG_FOUND=1; fi
      if [ "$PGDG_FOUND" -eq 0 ] && $SUDO grep -rq "apt.postgresql.org" /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null; then PGDG_FOUND=1; fi
      if [ "$PGDG_FOUND" -eq 1 ]; then
        report "PGDG repo" "SKIP" "already configured"
      else
        $SUDO apt-get update || {{ report "PGDG repo" "FAIL" "apt-get update failed"; echo "apt-get update failed" >&2; exit 9; }}
        $SUDO apt-get install -y ca-certificates curl gnupg lsb-release || {{ report "PGDG repo" "FAIL" "apt-get install prereqs failed"; echo "apt-get install ca-certificates/curl/gnupg/lsb-release failed" >&2; exit 9; }}
        $SUDO install -d -m 0755 /usr/share/keyrings || true
        if [ ! -f /usr/share/keyrings/postgresql.gpg ]; then
          curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | $SUDO gpg --dearmor -o /usr/share/keyrings/postgresql.gpg || {{ report "PGDG repo" "FAIL" "gpg key download failed"; echo "Failed to download/install PGDG signing key" >&2; exit 9; }}
        fi
        CODENAME="$(lsb_release -cs 2>/dev/null || true)"
        if [ -z "$CODENAME" ] && [ -f /etc/os-release ]; then
          . /etc/os-release
          CODENAME="$VERSION_CODENAME"
        fi
        echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt ${{CODENAME}}-pgdg main" | $SUDO tee /etc/apt/sources.list.d/pgdg.list >/dev/null || {{ report "PGDG repo" "FAIL" "could not write /etc/apt/sources.list.d/pgdg.list"; echo "Failed to write PGDG sources list" >&2; exit 9; }}
        report "PGDG repo" "DONE" "configured for ${{CODENAME}}-pgdg"
      fi
    else
      report "PGDG repo" "SKIP" "not applicable"
    fi

    progress "Install PostgreSQL packages"
    if pkg_installed; then
      report "Install packages" "SKIP" "postgresql-$PG_MAJOR already installed"
    else
      if [ "$PKG_MGR" = "apt" ]; then
        $SUDO apt-get update || {{ report "Install packages" "FAIL" "apt-get update failed"; echo "apt-get update failed" >&2; exit 9; }}
        $SUDO apt-get install -y "postgresql-$PG_MAJOR" "postgresql-contrib-$PG_MAJOR" || {{ report "Install packages" "FAIL" "apt-get install postgresql-$PG_MAJOR failed"; echo "apt-get install postgresql-$PG_MAJOR failed" >&2; exit 9; }}
      else
        $SUDO "$PKG_MGR" install -y postgresql-server postgresql-contrib || {{ report "Install packages" "FAIL" "$PKG_MGR install postgresql-server failed"; echo "$PKG_MGR install failed" >&2; exit 9; }}
        $SUDO postgresql-setup --initdb || true
      fi
      report "Install packages" "DONE" "installed postgresql-$PG_MAJOR"
    fi

    progress "Ensure PostgreSQL service"
    if command -v systemctl >/dev/null 2>&1; then
      STATUS="$($SUDO systemctl is-active postgresql 2>/dev/null || echo unknown)"
      if [ "$STATUS" = "active" ]; then
        report "Service" "SKIP" "systemctl is-active=$STATUS"
      else
        $SUDO systemctl enable --now postgresql || true
        report "Service" "DONE" "systemctl enable --now"
      fi
    elif command -v service >/dev/null 2>&1; then
      if $SUDO service postgresql status >/dev/null 2>&1; then
        report "Service" "SKIP" "service status ok"
      else
        $SUDO service postgresql start || true
        report "Service" "DONE" "service start"
      fi
    else
      report "Service" "SKIP" "unknown init system"
    fi

    as_postgres() {{
      if command -v sudo >/dev/null 2>&1; then
        sudo -u postgres "$@"
        return
      fi
      if command -v runuser >/dev/null 2>&1; then
        runuser -u postgres -- "$@"
        return
      fi
      if command -v su >/dev/null 2>&1; then
        local cmd=""
        for arg in "$@"; do
          cmd="$cmd $(printf "%q" "$arg")"
        done
        su - postgres -c "$cmd"
        return
      fi
      report "Role" "FAIL" "no method to run commands as postgres (sudo/runuser/su missing)"
      echo "No supported method to run commands as postgres (sudo/runuser/su missing)" >&2
      exit 5
    }}

    psqlq() {{
      as_postgres psql -At -d postgres -c "$1" 2>/dev/null || true
    }}

    progress "Role: {app_user}"
    ROLE_EXISTS="$(as_postgres psql -At -d postgres -c {shlex.quote(role_exists_sql)} 2>/dev/null | tr -d '\\r\\n' || true)"
    as_postgres psql -v ON_ERROR_STOP=1 -d postgres -c {shlex.quote(role_sql)} || {{ report "Role" "FAIL" "psql error applying role SQL"; echo "Failed to apply role SQL for {app_user}" >&2; exit 10; }}
    if [ "$ROLE_EXISTS" = "1" ]; then
      report "Role" "SKIP" "role '{app_user}' exists; password idempotently re-applied"
    else
      report "Role" "DONE" "created/updated"
    fi

    progress "Database: {db_name}"
    DB_EXISTS="$(as_postgres psql -At -d postgres -c {shlex.quote(db_exists_sql)} 2>/dev/null | tr -d '\\r\\n' || true)"
    if [ "$DB_EXISTS" != "1" ]; then
      as_postgres psql -v ON_ERROR_STOP=1 -d postgres -c {shlex.quote(create_db_sql)} || {{ report "Database" "FAIL" "psql error creating database"; echo "Failed to create database {db_name}" >&2; exit 10; }}
      report "Database" "DONE" "created"
    else
      report "Database" "SKIP" "db '{db_name}' already exists"
    fi

    APP_USER_VAR={shlex.quote(app_user)}
    DB_NAME_VAR={shlex.quote(db_name)}

    progress "Grants"
    GRANT_CHECK_SQL="SELECT CASE WHEN pg_catalog.has_database_privilege(:'app_user_v', :'db_name_v', 'CONNECT') AND pg_catalog.has_schema_privilege(:'app_user_v', 'public', 'USAGE') AND pg_catalog.has_schema_privilege(:'app_user_v', 'public', 'CREATE') THEN 1 ELSE 0 END;"
    GRANTS_OK="$(as_postgres psql -At -d "$DB_NAME_VAR" -v app_user_v="$APP_USER_VAR" -v db_name_v="$DB_NAME_VAR" -c "$GRANT_CHECK_SQL" 2>/dev/null | tr -d '\\r\\n' || true)"
    if [ "$GRANTS_OK" = "1" ]; then
      report "Grants" "SKIP" "privileges already in effect"
    else
      (as_postgres psql -v ON_ERROR_STOP=1 -d "$DB_NAME_VAR" -c {shlex.quote(grant_sql)} || as_postgres psql -v ON_ERROR_STOP=1 -d postgres -c {shlex.quote(grant_sql)}) || {{ report "Grants" "FAIL" "psql error applying grant SQL (target and fallback postgres both failed)"; echo "Failed to apply grant SQL for user={app_user} db={db_name}" >&2; exit 10; }}
      report "Grants" "DONE" "applied"
    fi

    CONFIG_FILE="$(psqlq "SHOW config_file;")"
    HBA_FILE="$(psqlq "SHOW hba_file;")"
    DATA_DIR="$(psqlq "SHOW data_directory;")"
    if [ -z "$CONFIG_FILE" ] || [ -z "$HBA_FILE" ]; then
      report "listen_addresses" "FAIL" "could not discover postgresql.conf/hba_file via SHOW; postgres may not be running"
      report "pg_hba rule" "SKIP" "skipped (config discovery failed)"
      echo "Could not discover PostgreSQL config paths (config_file='$CONFIG_FILE', hba_file='$HBA_FILE')" >&2
      exit 6
    fi

    LISTEN_ADDRESSES={shlex.quote(listen_addresses)}
    CIDR={shlex.quote(cidr)}
    AUTH={shlex.quote(auth)}
    SSH_PORT={int(ssh_port)}
    PG_PORT={int(pg_port)}
    {textwrap.dedent(REMOTE_CONFIG_FAILSAFE_SNIPPET).strip()}

    progress "Remote access config"
    RULE="host all all $CIDR $AUTH"
    CURRENT_LISTEN="$(psqlq "SHOW listen_addresses;" 2>/dev/null | tr -d '\\r\\n' || true)"
    NEED_LISTEN=0
    NEED_HBA=0
    if [ "$CURRENT_LISTEN" != "$LISTEN_ADDRESSES" ]; then NEED_LISTEN=1; fi
    if $SUDO grep -vE '^[[:space:]]*#' "$HBA_FILE" 2>/dev/null | tr -d '\\r' | grep -Fq -- "$RULE"; then NEED_HBA=0; else NEED_HBA=1; fi

    NEED_RESTART=0
    if [ "$NEED_LISTEN" -eq 0 ]; then
      report "listen_addresses" "SKIP" "already '$CURRENT_LISTEN'"
    fi
    if [ "$NEED_HBA" -eq 0 ]; then
      report "pg_hba rule" "SKIP" "already present: $RULE"
    fi

    if [ "$NEED_LISTEN" -eq 1 ] || [ "$NEED_HBA" -eq 1 ]; then
      backup_remote_config || {{ report "listen_addresses" "FAIL" "backup failed"; report "pg_hba rule" "SKIP" "backup failed (aborted)"; echo "backup_remote_config failed" >&2; exit 11; }}
      trap 'rollback_remote_config' ERR
      if [ "$NEED_LISTEN" -eq 1 ]; then
        if $SUDO test -f "$CONFIG_FILE"; then
          $SUDO sed -ri "s/^\\s*#?\\s*listen_addresses\\s*=.*/listen_addresses = '$LISTEN_ADDRESSES'/" "$CONFIG_FILE" || true
          if ! $SUDO grep -Eq "^\\s*#?\\s*listen_addresses\\s*=" "$CONFIG_FILE"; then
            echo "listen_addresses = '$LISTEN_ADDRESSES'" | $SUDO tee -a "$CONFIG_FILE" >/dev/null || {{ report "listen_addresses" "FAIL" "could not append to $CONFIG_FILE"; echo "Failed to append listen_addresses to $CONFIG_FILE" >&2; exit 7; }}
          fi
        else
          report "listen_addresses" "FAIL" "postgresql.conf missing: $CONFIG_FILE"
          if [ "$NEED_HBA" -eq 1 ]; then
            report "pg_hba rule" "SKIP" "aborted (postgresql.conf missing)"
          fi
          echo "postgresql.conf not found: $CONFIG_FILE" >&2
          exit 7
        fi
        report "listen_addresses" "DONE" "set to '$LISTEN_ADDRESSES'"
        NEED_RESTART=1
      fi

      if [ "$NEED_HBA" -eq 1 ]; then
        echo "$RULE" | $SUDO tee -a "$HBA_FILE" >/dev/null || {{ report "pg_hba rule" "FAIL" "could not append to $HBA_FILE"; echo "Failed to append pg_hba rule to $HBA_FILE" >&2; exit 7; }}
        report "pg_hba rule" "DONE" "added: $RULE"
        NEED_RESTART=1
      fi
    fi

    progress "Firewall ports"
    {textwrap.dedent(REMOTE_FIREWALL_SETUP_SNIPPET).strip()}
    FW_DONE=0
    if command -v ufw >/dev/null 2>&1; then
      UFW_OUT="$($SUDO ufw status 2>/dev/null || true)"
      if echo "$UFW_OUT" | grep -q "Status: active" && ufw_port_allowed "${{SSH_PORT}}" "$UFW_OUT" && ufw_port_allowed "${{PG_PORT}}" "$UFW_OUT"; then
        report "Firewall" "SKIP" "ufw active; allows ${{SSH_PORT}}/tcp (ssh) and ${{PG_PORT}}/tcp (pg)"
        FW_DONE=1
      fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
      if $SUDO firewall-cmd --state >/dev/null 2>&1; then
        if firewalld_port_allowed "${{SSH_PORT}}" && firewalld_port_allowed "${{PG_PORT}}"; then
          report "Firewall" "SKIP" "firewalld running; both ssh and pg ports allowed"
          FW_DONE=1
        fi
      fi
    fi

    if [ "$FW_DONE" -eq 0 ]; then
      ensure_firewall_ports || true
      if [ "$FW_CHANGED" -eq 0 ]; then
        report "Firewall" "SKIP" "verified after ensure; no new rules required"
      else
        report "Firewall" "DONE" "rules applied"
      fi
    fi

    progress "Restart/health"
    if [ "$NEED_RESTART" -eq 1 ]; then
      if command -v systemctl >/dev/null 2>&1; then
        $SUDO systemctl restart postgresql || true
      elif command -v service >/dev/null 2>&1; then
        $SUDO service postgresql restart || true
      elif command -v pg_ctl >/dev/null 2>&1; then
        as_postgres pg_ctl restart -D "$DATA_DIR" -m fast || true
      fi
      report "Restart" "DONE" "postgresql restarted"
      trap - ERR
    else
      report "Restart" "SKIP" "no config changes"
    fi

    HEALTH_OUT="$(as_postgres psql -At -d postgres -c "SELECT 1;" 2>/dev/null | tr -d '\\r\\n' || true)"
    if [ "$HEALTH_OUT" = "1" ]; then
      report "Health" "OK" "SELECT 1"
    else
      report "Health" "FAIL" "output='$HEALTH_OUT'"
      echo "Health check failed: expected '1' from postgres, got: '$HEALTH_OUT'" >&2
      exit 8
    fi

    echo "OK"
    """

    p = ssh_run(
        host=host,
        port=ssh_port,
        user=ssh_user,
        identity_file=identity_file,
        remote_command=f"bash -lc {shlex.quote(textwrap.dedent(remote_script).strip())}",
        capture=False,
    )
    if p.returncode != 0:
        print_block("Failed", f"Remote full setup failed with exit code {p.returncode}.")
        return

    audit_ok, audit_rows = remote_postgres_audit_ssh(
        host=host,
        port=ssh_port,
        user=ssh_user,
        identity_file=identity_file,
        expected_db=db_name,
        expected_role=app_user,
    )
    print_block("Audit", format_report_lines(audit_rows))
    if not audit_ok:
        print_block(
            "Failed verification",
            """
            The remote setup commands completed, but one or more validation checks did not pass.
            Review the audit output above before using this server.
            """,
        )
        return

    print_block(
        "Done",
        f"""
        Remote PostgreSQL setup completed on {host}.
        The script installed PostgreSQL, configured the database/user, enabled remote access,
        checked the firewall service state, and attempted to open {format_tcp_ports(firewall_ports)}.
        If PostgreSQL had failed its restart/health check, the script would have restored the previous config files.
        Next: use "Verify" with host {host} and port {pg_port} to test connectivity.
        """,
    )


def configure_db_user_local() -> None:
    psql = find_psql_path()
    if not psql:
        print_block(
            "psql not found",
            """
            PostgreSQL client 'psql' is required for automatic DB/user creation.
            Ensure PostgreSQL is installed and psql is on PATH, then re-run.
            """,
        )
        return

    print()
    print(f"Using psql: {psql}")

    host = prompt_host("localhost")
    port = prompt_port(5432)
    superuser = prompt_identifier("Superuser", default="postgres")

    use_password = yes_no("Use password authentication for superuser?", default=True)
    superpass = getpass.getpass("Superuser password: ") if use_password else ""

    db_name = prompt_identifier("Database name", default="app_db")
    app_user = prompt_identifier("App username", default="app_user")
    app_pass = getpass.getpass("App user password (leave blank to prompt later): ")
    if not app_pass:
        app_pass = getpass.getpass("App user password: ")

    role_sql = build_role_sql(app_user, app_pass)
    db_exists_sql = build_db_exists_sql(db_name)
    create_db_sql = build_create_db_sql(db_name, app_user)
    grant_sql = build_grant_sql(db_name, app_user)

    print_block(
        "Plan",
        f"""
        Create/Update role: {app_user}
        Create database:     {db_name}
        Host/Port:          {host}:{port}
        """,
    )
    if not yes_no("Apply these changes now?", default=True):
        return

    env: dict[str, str] = {}
    if use_password and superpass:
        env["PGPASSWORD"] = superpass

    base_cmd = [
        psql,
        "-h",
        host,
        "-p",
        str(port),
        "-U",
        superuser,
        "-d",
        "postgres",
        "-v",
        "ON_ERROR_STOP=1",
    ]
    summary: list[tuple[str, str]] = []
    total = 3
    step = 0

    step += 1
    print_progress(step, total, f"Role: {app_user}")
    role_exists_sql = f"SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '{normalize_sql_literal(app_user)}';"
    role_exists = run_cmd(base_cmd + ["-At", "-c", role_exists_sql], env=env, capture=True, check=False)
    role_present = role_exists.returncode == 0 and (role_exists.stdout or "").strip() == "1"
    update_role = True
    if role_present:
        update_role = yes_no(f'Role "{app_user}" already exists. Update password anyway?', default=False)
    if update_role:
        p = subprocess.run(
            base_cmd + ["-c", textwrap.dedent(role_sql)],
            text=True,
            env={**os.environ, **env},
        )
        if p.returncode != 0:
            print_block(
                "Failed",
                """
                Could not apply SQL via psql.
                Common causes:
                - Wrong password
                - pg_hba.conf does not allow password auth from this host
                - PostgreSQL service not running
                """,
            )
            return
        summary.append(("Role", "done"))
    else:
        summary.append(("Role", "skipped (already exists)"))

    step += 1
    print_progress(step, total, f"Database: {db_name}")
    exists = run_cmd(base_cmd + ["-At", "-c", db_exists_sql], env=env, capture=True, check=False)
    if exists.returncode != 0:
        print_block("Failed", "Could not check whether the database already exists.")
        return
    db_present = (exists.stdout or "").strip() == "1"
    if not db_present:
        createdb = run_cmd(base_cmd + ["-c", create_db_sql], env=env, check=False)
        if createdb.returncode != 0:
            print_block("Failed", "Could not create the database.")
            return
        summary.append(("Database", "done"))
    else:
        summary.append(("Database", "skipped (already exists)"))

    step += 1
    print_progress(step, total, f"Grant privileges: {db_name} -> {app_user}")
    grant = run_cmd(base_cmd + ["-c", grant_sql], env=env, check=False)
    if grant.returncode != 0:
        print_block("Failed", "Could not grant privileges on the database.")
        return
    summary.append(("Grants", "done"))

    print_block("Summary", format_report_lines(summary))

    print_block(
        "Done",
        """
        Database and user configured.
        Next: choose "Verify" to test connectivity.
        """,
    )


def find_psql_path() -> str | None:
    p = which("psql")
    if p:
        return p
    if is_windows():
        common_roots: list[str] = [
            os.environ.get("ProgramFiles", r"C:\Program Files"),
            os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
        ]
        for root in common_roots:
            if not root:
                continue
            base = os.path.join(root, "PostgreSQL")
            if not os.path.isdir(base):
                continue
            try:
                versions = sorted(
                    (d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d))),
                    reverse=True,
                )
            except Exception:
                continue
            for v in versions:
                candidate = os.path.join(base, v, "bin", "psql.exe")
                if os.path.isfile(candidate):
                    return candidate
    return None


def find_pg_ctl_path(psql_path: str) -> str | None:
    if is_windows():
        base = os.path.dirname(psql_path)
        candidate = os.path.join(base, "pg_ctl.exe")
        return candidate if os.path.isfile(candidate) else None
    return which("pg_ctl")


def psql_query(
    psql: str,
    *,
    host: str,
    port: int,
    user: str,
    db: str,
    password: str | None,
    sql: str,
) -> str | None:
    env: dict[str, str] = {}
    if password:
        env["PGPASSWORD"] = password
    p = run_cmd(
        [
            psql,
            "-h",
            host,
            "-p",
            str(port),
            "-U",
            user,
            "-d",
            db,
            "-v",
            "ON_ERROR_STOP=1",
            "-At",
            "-c",
            sql,
        ],
        env=env,
        capture=True,
        check=False,
    )
    if p.returncode != 0:
        return None
    return (p.stdout or "").strip()


def read_text_file(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def write_text_file_atomic(path: str, content: str) -> None:
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix="pg_", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(content)
        os.replace(tmp, path)
    finally:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except Exception:
            pass


def _extract_conf_value(line: str, key: str) -> str | None:
    m = re.match(rf"^\s*#?\s*{re.escape(key)}\s*=\s*(.+?)\s*$", line.rstrip("\r\n"))
    if not m:
        return None
    raw = m.group(1).strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {"'", '"'}:
        return raw[1:-1]
    return raw


def set_listen_addresses(conf_path: str, listen_addresses_value: str) -> bool:
    src = read_text_file(conf_path)
    lines = src.splitlines(True)
    out: list[str] = []
    changed = False

    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith("#"):
            uncommented = stripped[1:].lstrip()
            if re.match(r"^listen_addresses\s*=", uncommented):
                out.append(f"listen_addresses = '{listen_addresses_value}'\n")
                changed = True
                continue
        if re.match(r"^\s*listen_addresses\s*=", line):
            current = _extract_conf_value(line, "listen_addresses")
            if current != listen_addresses_value:
                out.append(f"listen_addresses = '{listen_addresses_value}'\n")
                changed = True
                continue
        out.append(line)

    if not changed:
        found_active = any(
            re.match(r"^\s*listen_addresses\s*=", ln)
            for ln in lines
        )
        if not found_active:
            if out and not out[-1].endswith("\n"):
                out[-1] += "\n"
            out.append(f"listen_addresses = '{listen_addresses_value}'\n")
            changed = True

    if changed:
        write_text_file_atomic(conf_path, "".join(out))
    return changed


def _pg_hba_rule_exists(hba_path: str, cidr: str, auth_method: str) -> bool:
    needle = f"host all all {cidr} {auth_method}"
    try:
        with open(hba_path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                stripped = line.lstrip()
                if stripped.startswith("#"):
                    continue
                if needle in stripped:
                    return True
    except Exception:
        return False
    return False


def ensure_pg_hba_rule(hba_path: str, cidr: str, auth_method: str) -> bool:
    if _pg_hba_rule_exists(hba_path, cidr, auth_method):
        return False

    src = read_text_file(hba_path)
    rule = f"host all all {cidr} {auth_method}\n"

    out = src
    if out and not out.endswith("\n"):
        out += "\n"
    out += rule
    write_text_file_atomic(hba_path, out)
    return True


def apply_firewall_rules(ports: Sequence[int]) -> None:
    unique_ports: list[int] = []
    for port in ports:
        if port not in unique_ports:
            unique_ports.append(port)

    if is_windows():
        if not is_admin_windows():
            print_block(
                "Windows Firewall",
                """
                Administrator privileges are required to add Windows Firewall rules.
                Run this script as Administrator if you want it to open the port automatically.
                """,
            )
            return
        for port in unique_ports:
            run_cmd(
                [
                    "netsh",
                    "advfirewall",
                    "firewall",
                    "add",
                    "rule",
                    f"name=PostgreSQL {port}",
                    "dir=in",
                    "action=allow",
                    "protocol=TCP",
                    f"localport={port}",
                ],
                check=False,
            )
        return

    needs_sudo = os.geteuid() != 0
    sudo = ["sudo"] if needs_sudo and which("sudo") else []

    if which("ufw"):
        for port in unique_ports:
            run_cmd(sudo + ["ufw", "allow", f"{port}/tcp"], check=False)
        return
    if which("firewall-cmd"):
        for port in unique_ports:
            run_cmd(sudo + ["firewall-cmd", "--add-port", f"{port}/tcp", "--permanent"], check=False)
        run_cmd(sudo + ["firewall-cmd", "--reload"], check=False)
        return


def is_firewall_port_allowed(port: int) -> bool | None:
    if is_windows():
        rule_name = f"PostgreSQL {port}"
        p = run_cmd(
            ["netsh", "advfirewall", "firewall", "show", "rule", f"name={rule_name}"],
            capture=True,
            check=False,
        )
        out = (p.stdout or "") + "\n" + (p.stderr or "")
        if "No rules match" in out:
            return False
        return p.returncode == 0

    needs_sudo = os.geteuid() != 0
    sudo = ["sudo"] if needs_sudo and which("sudo") else []

    if which("ufw"):
        p = run_cmd(sudo + ["ufw", "status"], capture=True, check=False)
        if p.returncode != 0:
            return None
        out = (p.stdout or "") + "\n" + (p.stderr or "")
        return f"{port}/tcp" in out

    if which("firewall-cmd"):
        p = run_cmd(sudo + ["firewall-cmd", "--list-ports"], capture=True, check=False)
        if p.returncode != 0:
            return None
        out = (p.stdout or "") + "\n" + (p.stderr or "")
        return f"{port}/tcp" in out

    return None


def format_report_lines(rows: Sequence[tuple[str, str]]) -> str:
    if not rows:
        return ""
    width = max(len(label) for label, _ in rows)
    return "\n".join(f"{label:<{width}} : {value}" for label, value in rows)


def local_postgres_audit(
    psql: str,
    *,
    host: str,
    port: int,
    user: str,
    db: str,
    password: str | None,
) -> tuple[bool, list[tuple[str, str]]]:
    version = run_cmd([psql, "--version"], capture=True, check=False)
    health = psql_query(psql, host=host, port=port, user=user, db=db, password=password, sql="SELECT 1;")
    current_user = psql_query(
        psql, host=host, port=port, user=user, db=db, password=password, sql="SELECT current_user;"
    )
    current_db = psql_query(
        psql, host=host, port=port, user=user, db=db, password=password, sql="SELECT current_database();"
    )
    db_exists = psql_query(
        psql,
        host=host,
        port=port,
        user=user,
        db=db,
        password=password,
        sql=f"SELECT 1 FROM pg_catalog.pg_database WHERE datname = '{normalize_sql_literal(db)}';",
    )
    role_exists = psql_query(
        psql,
        host=host,
        port=port,
        user=user,
        db=db,
        password=password,
        sql=f"SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '{normalize_sql_literal(user)}';",
    )
    config_file = psql_query(psql, host=host, port=port, user=user, db=db, password=password, sql="SHOW config_file;")
    hba_file = psql_query(psql, host=host, port=port, user=user, db=db, password=password, sql="SHOW hba_file;")
    data_dir = psql_query(
        psql, host=host, port=port, user=user, db=db, password=password, sql="SHOW data_directory;"
    )
    listen_addresses = psql_query(
        psql, host=host, port=port, user=user, db=db, password=password, sql="SHOW listen_addresses;"
    )
    server_port = psql_query(psql, host=host, port=port, user=user, db=db, password=password, sql="SHOW port;")
    server_version = psql_query(
        psql, host=host, port=port, user=user, db=db, password=password, sql="SHOW server_version;"
    )

    rows = [
        ("psql binary", (version.stdout or "").strip() if version.returncode == 0 else "not available"),
        ("connection", "ok" if health == "1" else "failed"),
        ("server version", server_version or "unknown"),
        ("current user", current_user or "unknown"),
        ("current database", current_db or "unknown"),
        ("role exists", "yes" if role_exists == "1" else "no"),
        ("database exists", "yes" if db_exists == "1" else "no"),
        ("listen_addresses", listen_addresses or "unknown"),
        ("server port", server_port or "unknown"),
        ("config_file", config_file or "unavailable"),
        ("hba_file", hba_file or "unavailable"),
        ("data_directory", data_dir or "unavailable"),
    ]
    ok = health == "1" and role_exists == "1" and db_exists == "1"
    return ok, rows


def remote_postgres_audit_ssh(
    *,
    host: str,
    port: int,
    user: str,
    identity_file: str | None,
    expected_db: str,
    expected_role: str,
) -> tuple[bool, list[tuple[str, str]]]:
    mgr, diag = detect_remote_linux_pkg_manager(host=host, port=port, user=user, identity_file=identity_file)
    if not mgr:
        diag_block = diag if diag else "failed to detect remote host details"
        return False, [("ssh/package manager", diag_block)]

    if mgr == "apt":
        pkg_check = "dpkg-query -W -f='${Status}' postgresql 2>/dev/null | grep -q 'install ok installed'"
    else:
        pkg_check = "rpm -q postgresql-server >/dev/null 2>&1 || rpm -q postgresql >/dev/null 2>&1"

    role_exists_sql = f"SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '{normalize_sql_literal(expected_role)}';"
    db_exists_sql = f"SELECT 1 FROM pg_catalog.pg_database WHERE datname = '{normalize_sql_literal(expected_db)}';"
    remote_script = f"""
    emit() {{
      printf '__AUDIT__%s=%s\\n' "$1" "$2"
    }}

    as_postgres() {{
      if command -v sudo >/dev/null 2>&1; then
        sudo -u postgres "$@"
        return
      fi
      if command -v runuser >/dev/null 2>&1; then
        runuser -u postgres -- "$@"
        return
      fi
      if command -v su >/dev/null 2>&1; then
        local cmd=""
        for arg in "$@"; do
          cmd="$cmd $(printf "%q" "$arg")"
        done
        su - postgres -c "$cmd"
        return
      fi
      return 1
    }}

    emit host {shlex.quote(host)}
    emit package_manager {shlex.quote(mgr)}
    if {pkg_check}; then emit package_installed yes; else emit package_installed no; fi
    if id postgres >/dev/null 2>&1; then emit postgres_os_user yes; else emit postgres_os_user no; fi
    if command -v psql >/dev/null 2>&1; then emit psql yes; else emit psql no; fi

    if command -v systemctl >/dev/null 2>&1; then
      emit service_enabled "$(systemctl is-enabled postgresql 2>/dev/null || echo unknown)"
      emit service_active "$(systemctl is-active postgresql 2>/dev/null || echo unknown)"
    else
      emit service_enabled unknown
      if command -v service >/dev/null 2>&1 && service postgresql status >/dev/null 2>&1; then
        emit service_active yes
      else
        emit service_active unknown
      fi
    fi

    emit health "$(as_postgres psql -At -d postgres -c "SELECT 1;" 2>/dev/null | tr -d '\\r\\n')"
    emit role_exists "$(as_postgres psql -At -d postgres -c {shlex.quote(role_exists_sql)} 2>/dev/null | tr -d '\\r\\n')"
    emit db_exists "$(as_postgres psql -At -d postgres -c {shlex.quote(db_exists_sql)} 2>/dev/null | tr -d '\\r\\n')"
    emit config_file "$(as_postgres psql -At -d postgres -c "SHOW config_file;" 2>/dev/null | tr -d '\\r')"
    emit hba_file "$(as_postgres psql -At -d postgres -c "SHOW hba_file;" 2>/dev/null | tr -d '\\r')"
    emit data_directory "$(as_postgres psql -At -d postgres -c "SHOW data_directory;" 2>/dev/null | tr -d '\\r')"
    emit listen_addresses "$(as_postgres psql -At -d postgres -c "SHOW listen_addresses;" 2>/dev/null | tr -d '\\r')"
    emit port "$(as_postgres psql -At -d postgres -c "SHOW port;" 2>/dev/null | tr -d '\\r')"
    emit server_version "$(as_postgres psql -At -d postgres -c "SHOW server_version;" 2>/dev/null | tr -d '\\r')"
    """

    p = ssh_run(
        host=host,
        port=port,
        user=user,
        identity_file=identity_file,
        remote_command=f"bash -lc {shlex.quote(textwrap.dedent(remote_script).strip())}",
        capture=True,
    )
    if p.returncode != 0:
        out = ((p.stdout or "") + "\n" + (p.stderr or "")).strip()
        return False, [("remote audit", out or "failed")]

    values: dict[str, str] = {}
    for line in ((p.stdout or "") + "\n" + (p.stderr or "")).splitlines():
        if line.startswith("__AUDIT__") and "=" in line:
            key, value = line[len("__AUDIT__") :].split("=", 1)
            values[key.strip()] = value.strip()

    rows = [
        ("host", values.get("host", host)),
        ("package manager", values.get("package_manager", mgr)),
        ("package installed", values.get("package_installed", "unknown")),
        ("postgres OS user", values.get("postgres_os_user", "unknown")),
        ("psql", values.get("psql", "unknown")),
        ("service enabled", values.get("service_enabled", "unknown")),
        ("service active", values.get("service_active", "unknown")),
        ("health", "ok" if values.get("health") == "1" else (values.get("health") or "failed")),
        ("role exists", "yes" if values.get("role_exists") == "1" else "no"),
        ("database exists", "yes" if values.get("db_exists") == "1" else "no"),
        ("server version", values.get("server_version", "unknown")),
        ("listen_addresses", values.get("listen_addresses", "unknown")),
        ("server port", values.get("port", "unknown")),
        ("config_file", values.get("config_file", "unavailable")),
        ("hba_file", values.get("hba_file", "unavailable")),
        ("data_directory", values.get("data_directory", "unavailable")),
    ]
    ok = (
        values.get("package_installed") == "yes"
        and values.get("postgres_os_user") == "yes"
        and values.get("psql") == "yes"
        and values.get("health") == "1"
        and values.get("role_exists") == "1"
        and values.get("db_exists") == "1"
    )
    return ok, rows


def restart_postgres(psql_path: str, data_directory: str | None) -> bool:
    pg_ctl = find_pg_ctl_path(psql_path)
    if pg_ctl and data_directory:
        p = run_cmd([pg_ctl, "restart", "-D", data_directory, "-m", "fast"], check=False)
        if p.returncode == 0:
            return True

    if not is_windows():
        needs_sudo = os.geteuid() != 0
        sudo = ["sudo"] if needs_sudo and which("sudo") else []
        if which("systemctl"):
            p = run_cmd(sudo + ["systemctl", "restart", "postgresql"], check=False)
            return p.returncode == 0
        elif which("service"):
            p = run_cmd(sudo + ["service", "postgresql", "restart"], check=False)
            return p.returncode == 0

    return False


def enable_remote_access_local() -> None:
    psql = find_psql_path()
    if not psql:
        print_block(
            "psql not found",
            """
            PostgreSQL client 'psql' is required for enabling remote access.
            Install PostgreSQL first (or add psql to PATH), then re-run.
            """,
        )
        return

    print()
    print(f"Using psql: {psql}")

    host = prompt_host("localhost")
    port = prompt_port(5432)
    superuser = prompt_identifier("Superuser", default="postgres")
    use_password = yes_no("Use password authentication for superuser?", default=True)
    superpass = getpass.getpass("Superuser password: ") if use_password else ""

    listen_addresses = input("listen_addresses value [*]: ").strip() or "*"
    cidr = prompt_cidr("0.0.0.0/0")

    if cidr == "0.0.0.0/0":
        print_block(
            "Security warning",
            """
            You selected 0.0.0.0/0 (any IP).
            This exposes PostgreSQL to the internet if your network allows it.
            """,
        )
        if not yes_no("Proceed anyway?", default=False):
            return

    auth = prompt_auth_method("scram-sha-256")

    config_file = psql_query(
        psql,
        host=host,
        port=port,
        user=superuser,
        db="postgres",
        password=superpass if use_password else None,
        sql="SHOW config_file;",
    )
    hba_file = psql_query(
        psql,
        host=host,
        port=port,
        user=superuser,
        db="postgres",
        password=superpass if use_password else None,
        sql="SHOW hba_file;",
    )
    data_dir = psql_query(
        psql,
        host=host,
        port=port,
        user=superuser,
        db="postgres",
        password=superpass if use_password else None,
        sql="SHOW data_directory;",
    )

    if not config_file or not hba_file:
        print_block(
            "Failed to discover config paths",
            """
            Could not read SHOW config_file / SHOW hba_file.
            Verify credentials and ensure your superuser can connect to the server.
            """,
        )
        return

    print_block(
        "Plan",
        f"""
        postgresql.conf: set listen_addresses = '{listen_addresses}'
        pg_hba.conf:     add host all all {cidr} {auth}
        firewall:        open {format_tcp_ports([port])} (best-effort)
        restart:         restart PostgreSQL (best-effort)

        config_file: {config_file}
        hba_file:    {hba_file}
        """,
    )
    if not yes_no("Apply these changes now?", default=True):
        return
    summary: list[tuple[str, str]] = []
    total = 4
    step = 0

    current_listen = psql_query(
        psql,
        host=host,
        port=port,
        user=superuser,
        db="postgres",
        password=superpass if use_password else None,
        sql="SHOW listen_addresses;",
    )
    rule_present = _pg_hba_rule_exists(hba_file, cidr, auth)
    firewall_allowed = is_firewall_port_allowed(port)

    if current_listen == listen_addresses and rule_present and firewall_allowed is True:
        summary.append(("listen_addresses", "skipped (already set)"))
        summary.append(("pg_hba.conf rule", "skipped (already present)"))
        summary.append((f"Firewall TCP/{port}", "skipped (already allowed)"))
        summary.append(("Restart/health", "skipped (no changes)"))
        print_block("Summary", format_report_lines(summary))
        print_block("Done", "No changes required.")
        return

    config_backup = ""
    hba_backup = ""
    changed = False

    step += 1
    print_progress(step, total, "postgresql.conf: listen_addresses")
    try:
        if current_listen != listen_addresses:
            config_backup = backup_file(config_file)
            set_result = set_listen_addresses(config_file, listen_addresses)
            changed = set_result or changed
            summary.append(("listen_addresses", "done" if set_result else "skipped (already set)"))
        else:
            summary.append(("listen_addresses", "skipped (already set)"))
    except PermissionError:
        print_block(
            "Permission denied",
            """
            Could not modify PostgreSQL configuration files.
            Run this script with elevated permissions on the server and retry.
            """,
        )
        return

    step += 1
    print_progress(step, total, "pg_hba.conf: rule")
    try:
        if not rule_present:
            hba_backup = backup_file(hba_file)
            rule_result = ensure_pg_hba_rule(hba_file, cidr, auth)
            changed = rule_result or changed
            if rule_result:
                summary.append(("pg_hba.conf rule", "done"))
            else:
                summary.append(("pg_hba.conf rule", "skipped (already present)"))
        else:
            summary.append(("pg_hba.conf rule", "skipped (already present)"))
    except PermissionError:
        if config_backup:
            restore_file(config_backup, config_file)
        print_block(
            "Permission denied",
            """
            Could not modify PostgreSQL configuration files.
            Run this script with elevated permissions on the server and retry.
            """,
        )
        return

    step += 1
    print_progress(step, total, f"Firewall TCP/{port}")
    if firewall_allowed is True:
        summary.append((f"Firewall TCP/{port}", "skipped (already allowed)"))
    else:
        apply_firewall_rules([port])
        summary.append((f"Firewall TCP/{port}", "done" if firewall_allowed is False else "attempted"))

    step += 1
    print_progress(step, total, "Restart/health")
    restart_ok = True
    if changed:
        restart_ok = restart_postgres(psql, data_dir)
    health_ok = bool(
        psql_query(
            psql,
            host=host,
            port=port,
            user=superuser,
            db="postgres",
            password=superpass if use_password else None,
            sql="SELECT 1;",
        )
    )
    if changed and (not restart_ok or not health_ok):
        if config_backup:
            restore_file(config_backup, config_file)
        if hba_backup:
            restore_file(hba_backup, hba_file)
        restart_postgres(psql, data_dir)
        print_block("Summary", format_report_lines(summary))
        print_block(
            "Failed safely",
            """
            PostgreSQL did not come back healthy after applying remote-access changes.
            The script restored the previous configuration files and restarted PostgreSQL.
            """,
        )
        return
    summary.append(("Restart/health", "done" if changed else "skipped (no changes)"))

    print_block("Summary", format_report_lines(summary))
    print_block(
        "Done",
        """
        Remote access configuration is ready.
        Next:
        - Verify network routing/security groups
        - Use "Verify" to test connectivity
        """,
    )


def enable_remote_access_ssh() -> None:
    if not which("ssh"):
        print_block(
            "ssh not found",
            """
            OpenSSH client is required to configure a remote Linux host via SSH.

            Windows:
              Settings -> Optional features -> Add a feature -> OpenSSH Client
            Linux:
              Install the 'openssh-client' package.
            """,
        )
        return

    host, ssh_port, ssh_user, identity_file, use_sudo = prompt_ssh_connection()

    listen_addresses = input("listen_addresses value [*]: ").strip() or "*"
    pg_port = prompt_port(5432)
    cidr = prompt_cidr("0.0.0.0/0")

    if cidr == "0.0.0.0/0":
        print_block(
            "Security warning",
            """
            You selected 0.0.0.0/0 (any IP).
            This exposes PostgreSQL to the internet if your network allows it.
            """,
        )
        if not yes_no("Proceed anyway?", default=False):
            return

    auth = prompt_auth_method("scram-sha-256")
    firewall_ports = [ssh_port, pg_port]

    print_block(
        "Plan",
        f"""
        Target (SSH): {ssh_user}@{host}:{ssh_port}

        backup:          create rollback copies of postgresql.conf and pg_hba.conf
        postgresql.conf: set listen_addresses = '{listen_addresses}'
        pg_hba.conf:     add host all all {cidr} {auth}
        firewall:        ensure service enabled/running, then open {format_tcp_ports(firewall_ports)} (best-effort)
        restart:         restart PostgreSQL and validate health, else restore backups
        """,
    )
    if not yes_no("Apply these changes on the remote host now?", default=True):
        return

    remote_script = f"""
    STEP=0
    TOTAL=4
    progress() {{
      STEP=$((STEP+1))
      echo "[$STEP/$TOTAL] $1"
    }}
    report() {{
      printf '%s\\t%s\\t%s\\n' "$1" "$2" "$3" >> "$REPORT_FILE" 2>/dev/null || true
    }}
    show_report() {{
      echo
      echo "Summary"
      echo "-------"
      printf '%-22s %-6s %s\\n' "Action" "Status" "Details"
      printf '%-22s %-6s %s\\n' "------" "------" "-------"
      if [ -n "$REPORT_FILE" ] && [ -f "$REPORT_FILE" ]; then
        cat "$REPORT_FILE" 2>/dev/null | while IFS=$'\\t' read -r a s d; do printf '%-22s %-6s %s\\n' "$a" "$s" "$d"; done
      fi
    }}
    REPORT_FILE="$(mktemp -p /tmp pg_remote_access_report.XXXXXX 2>/dev/null || echo /tmp/pg_remote_access_report.$$)"
    : > "$REPORT_FILE" 2>/dev/null || true
    trap 'show_report' EXIT
    set -e

    USE_SUDO={1 if use_sudo else 0}

    if [ "$USE_SUDO" -eq 1 ]; then
      if ! command -v sudo >/dev/null 2>&1; then
        report "listen_addresses" "FAIL" "sudo not found on remote host (needed for postgresql.conf edits)"
        report "pg_hba rule"     "FAIL" "sudo not found on remote host (needed for pg_hba.conf edits)"
        report "Firewall"        "FAIL" "sudo not found on remote host (needed for firewall rules)"
        report "Restart/health"  "FAIL" "sudo not found on remote host (needed for postgresql restart)"
        echo "sudo not found on remote host" >&2
        exit 4
      fi
      SUDO="sudo"
    else
      SUDO=""
    fi

    as_postgres() {{
      if command -v sudo >/dev/null 2>&1; then
        sudo -u postgres "$@"
        return
      fi
      if command -v runuser >/dev/null 2>&1; then
        runuser -u postgres -- "$@"
        return
      fi
      if command -v su >/dev/null 2>&1; then
        local cmd=""
        for arg in "$@"; do
          cmd="$cmd $(printf "%q" "$arg")"
        done
        su - postgres -c "$cmd"
        return
      fi
      report "listen_addresses" "FAIL" "no method to run commands as postgres (sudo/runuser/su missing)"
      echo "No supported method to run commands as postgres (sudo/runuser/su missing)" >&2
      exit 5
    }}

    psqlq() {{
      as_postgres psql -At -d postgres -c "$1" 2>/dev/null || true
    }}

    CONFIG_FILE="$(psqlq "SHOW config_file;")"
    HBA_FILE="$(psqlq "SHOW hba_file;")"
    DATA_DIR="$(psqlq "SHOW data_directory;")"

    if [ -z "$CONFIG_FILE" ] || [ -z "$HBA_FILE" ]; then
      report "listen_addresses" "FAIL" "could not discover postgresql.conf/hba_file via SHOW; postgres may not be running"
      report "pg_hba rule" "SKIP" "skipped (config discovery failed)"
      echo "Could not discover PostgreSQL config paths (config_file='$CONFIG_FILE', hba_file='$HBA_FILE')" >&2
      exit 6
    fi

    LISTEN_ADDRESSES={shlex.quote(listen_addresses)}
    CIDR={shlex.quote(cidr)}
    AUTH={shlex.quote(auth)}
    SSH_PORT={int(ssh_port)}
    PG_PORT={int(pg_port)}
    RULE="host all all $CIDR $AUTH"
    CURRENT_LISTEN="$(psqlq "SHOW listen_addresses;" 2>/dev/null | tr -d '\\r\\n' || true)"

    NEED_LISTEN=0
    NEED_HBA=0
    if [ "$CURRENT_LISTEN" != "$LISTEN_ADDRESSES" ]; then NEED_LISTEN=1; fi
    if $SUDO grep -vE '^[[:space:]]*#' "$HBA_FILE" 2>/dev/null | tr -d '\\r' | grep -Fq -- "$RULE"; then NEED_HBA=0; else NEED_HBA=1; fi
    NEED_RESTART=0

    progress "Remote access config"
    {textwrap.dedent(REMOTE_CONFIG_FAILSAFE_SNIPPET).strip()}
    if [ "$NEED_LISTEN" -eq 1 ] || [ "$NEED_HBA" -eq 1 ]; then
      backup_remote_config
      trap 'rollback_remote_config' ERR
      if [ "$NEED_LISTEN" -eq 1 ]; then
        if $SUDO test -f "$CONFIG_FILE"; then
          $SUDO sed -ri "s/^\\s*#?\\s*listen_addresses\\s*=.*/listen_addresses = '$LISTEN_ADDRESSES'/" "$CONFIG_FILE" || true
          if ! $SUDO grep -Eq "^\\s*#?\\s*listen_addresses\\s*=" "$CONFIG_FILE"; then
            echo "listen_addresses = '$LISTEN_ADDRESSES'" | $SUDO tee -a "$CONFIG_FILE" >/dev/null || {{ report "listen_addresses" "FAIL" "could not append to $CONFIG_FILE"; echo "Failed to append listen_addresses to $CONFIG_FILE" >&2; exit 7; }}
          fi
        else
          report "listen_addresses" "FAIL" "postgresql.conf missing: $CONFIG_FILE"
          echo "postgresql.conf not found: $CONFIG_FILE" >&2
          exit 7
        fi
        report "listen_addresses" "DONE" "set to '$LISTEN_ADDRESSES'"
        NEED_RESTART=1
      else
        report "listen_addresses" "SKIP" "already '$CURRENT_LISTEN'"
      fi

      if [ "$NEED_HBA" -eq 1 ]; then
        echo "$RULE" | $SUDO tee -a "$HBA_FILE" >/dev/null || {{ report "pg_hba rule" "FAIL" "could not append to $HBA_FILE"; echo "Failed to append pg_hba rule to $HBA_FILE" >&2; exit 7; }}
        report "pg_hba rule" "DONE" "added: $RULE"
        NEED_RESTART=1
      else
        report "pg_hba rule" "SKIP" "already present: $RULE"
      fi
    else
      report "listen_addresses" "SKIP" "already '$CURRENT_LISTEN'"
      report "pg_hba rule" "SKIP" "already present: $RULE"
    fi

    progress "Firewall ports"
    {textwrap.dedent(REMOTE_FIREWALL_SETUP_SNIPPET).strip()}
    FW_DONE=0
    if command -v ufw >/dev/null 2>&1; then
      UFW_OUT="$($SUDO ufw status 2>/dev/null || true)"
      if echo "$UFW_OUT" | grep -q "Status: active" && ufw_port_allowed "${{SSH_PORT}}" "$UFW_OUT" && ufw_port_allowed "${{PG_PORT}}" "$UFW_OUT"; then
        report "Firewall" "SKIP" "ufw active; allows ${{SSH_PORT}}/tcp (ssh) and ${{PG_PORT}}/tcp (pg)"
        FW_DONE=1
      fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
      if $SUDO firewall-cmd --state >/dev/null 2>&1; then
        if firewalld_port_allowed "${{SSH_PORT}}" && firewalld_port_allowed "${{PG_PORT}}"; then
          report "Firewall" "SKIP" "firewalld running; both ssh and pg ports allowed"
          FW_DONE=1
        fi
      fi
    fi
    if [ "$FW_DONE" -eq 0 ]; then
      ensure_firewall_ports || true
      if [ "$FW_CHANGED" -eq 0 ]; then
        report "Firewall" "SKIP" "verified after ensure; no new rules required"
      else
        report "Firewall" "DONE" "rules applied"
      fi
    fi

    progress "Restart/health"
    if [ "$NEED_RESTART" -eq 1 ]; then
      if command -v systemctl >/dev/null 2>&1; then
        $SUDO systemctl restart postgresql || true
      elif command -v service >/dev/null 2>&1; then
        $SUDO service postgresql restart || true
      elif command -v pg_ctl >/dev/null 2>&1; then
        as_postgres pg_ctl restart -D "$DATA_DIR" -m fast || true
      fi
      report "Restart" "DONE" "postgresql restarted"
      trap - ERR
    else
      report "Restart" "SKIP" "no config changes"
    fi

    HEALTH_OUT="$(as_postgres psql -At -d postgres -c "SELECT 1;" 2>/dev/null | tr -d '\\r\\n' || true)"
    if [ "$HEALTH_OUT" = "1" ]; then
      report "Health" "OK" "SELECT 1"
    else
      report "Health" "FAIL" "output='$HEALTH_OUT'"
      echo "Health check failed: expected '1' from postgres, got: '$HEALTH_OUT'" >&2
      exit 8
    fi

    echo "OK"
    """

    p = ssh_run(
        host=host,
        port=ssh_port,
        user=ssh_user,
        identity_file=identity_file,
        remote_command=f"bash -lc {shlex.quote(textwrap.dedent(remote_script).strip())}",
        capture=False,
    )
    if p.returncode != 0:
        print_block("Failed", f"Remote remote-access configuration failed with exit code {p.returncode}.")
        return

    audit_ok, audit_rows = remote_postgres_audit_ssh(
        host=host,
        port=ssh_port,
        user=ssh_user,
        identity_file=identity_file,
        expected_db="postgres",
        expected_role="postgres",
    )
    print_block("Audit", format_report_lines(audit_rows))
    if not audit_ok:
        print_block(
            "Failed verification",
            """
            Remote access changes were applied, but the server audit found one or more problems.
            Review the audit output above before using the server remotely.
            """,
        )
        return

    print_block(
        "Done",
        """
        Remote access configuration applied on the remote host.
        The script checked the firewall service and attempted to open both SSH and PostgreSQL.
        If PostgreSQL had failed its restart/health check, the script would have restored the previous config files.
        Next: use "Verify" and set Host to the server DNS/IP to test connectivity.
        """,
    )


def enable_remote_access() -> None:
    idx = prompt_choice(
        "Enable remote access target",
        [
            "This machine",
            "Remote Linux over SSH",
        ],
    )
    if idx == 0:
        enable_remote_access_local()
    else:
        enable_remote_access_ssh()


def configure_db_user_ssh() -> None:
    if not which("ssh"):
        print_block(
            "ssh not found",
            """
            OpenSSH client is required to configure a remote Linux host via SSH.

            Windows:
              Settings -> Optional features -> Add a feature -> OpenSSH Client
            Linux:
              Install the 'openssh-client' package.
            """,
        )
        return

    host, ssh_port, ssh_user, identity_file, _use_sudo = prompt_ssh_connection()

    db_name = prompt_identifier("Database name", default="app_db")
    app_user = prompt_identifier("App username", default="app_user")
    app_pass = getpass.getpass("App user password (leave blank to prompt later): ")
    if not app_pass:
        app_pass = getpass.getpass("App user password: ")

    role_sql = " ".join(textwrap.dedent(build_role_sql(app_user, app_pass)).splitlines())
    role_exists_sql = f"SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '{normalize_sql_literal(app_user)}';"
    db_exists_sql = build_db_exists_sql(db_name)
    create_db_sql = build_create_db_sql(db_name, app_user)
    grant_sql = build_grant_sql(db_name, app_user)
    remote_script = f"""
    STEP=0
    TOTAL=3
    progress() {{
      STEP=$((STEP+1))
      echo "[$STEP/$TOTAL] $1"
    }}
    report() {{
      printf '%s\\t%s\\t%s\\n' "$1" "$2" "$3" >> "$REPORT_FILE" 2>/dev/null || true
    }}
    show_report() {{
      echo
      echo "Summary"
      echo "-------"
      printf '%-18s %-6s %s\\n' "Action" "Status" "Details"
      printf '%-18s %-6s %s\\n' "------" "------" "-------"
      if [ -n "$REPORT_FILE" ] && [ -f "$REPORT_FILE" ]; then
        cat "$REPORT_FILE" 2>/dev/null | while IFS=$'\\t' read -r a s d; do printf '%-18s %-6s %s\\n' "$a" "$s" "$d"; done
      fi
    }}
    REPORT_FILE="$(mktemp -p /tmp pg_config_report.XXXXXX 2>/dev/null || echo /tmp/pg_config_report.$$)"
    : > "$REPORT_FILE" 2>/dev/null || true
    trap 'show_report' EXIT
    set -e

    as_postgres() {{
      if command -v sudo >/dev/null 2>&1; then
        sudo -u postgres "$@"
        return
      fi
      if command -v runuser >/dev/null 2>&1; then
        runuser -u postgres -- "$@"
        return
      fi
      if command -v su >/dev/null 2>&1; then
        local cmd=""
        for arg in "$@"; do
          cmd="$cmd $(printf "%q" "$arg")"
        done
        su - postgres -c "$cmd"
        return
      fi
      report "Role" "FAIL" "no method to run commands as postgres (sudo/runuser/su missing)"
      echo "No supported method to run commands as postgres (sudo/runuser/su missing)" >&2
      exit 5
    }}
    progress "Role: {app_user}"
    ROLE_EXISTS="$(as_postgres psql -At -d postgres -c {shlex.quote(role_exists_sql)} 2>/dev/null | tr -d '\\r\\n' || true)"
    as_postgres psql -v ON_ERROR_STOP=1 -d postgres -c {shlex.quote(role_sql)}
    if [ "$ROLE_EXISTS" = "1" ]; then
      report "Role" "SKIP" "role '{app_user}' exists; password idempotently re-applied"
    else
      report "Role" "DONE" "created/updated"
    fi

    progress "Database: {db_name}"
    DB_EXISTS="$(as_postgres psql -At -d postgres -c {shlex.quote(db_exists_sql)} 2>/dev/null | tr -d '\\r\\n' || true)"
    if [ "$DB_EXISTS" != "1" ]; then
      as_postgres psql -v ON_ERROR_STOP=1 -d postgres -c {shlex.quote(create_db_sql)}
      report "Database" "DONE" "created"
    else
      report "Database" "SKIP" "db '{db_name}' already exists"
    fi

    APP_USER_VAR2={shlex.quote(app_user)}
    DB_NAME_VAR2={shlex.quote(db_name)}

    progress "Grants"
    GRANT_CHECK_SQL2="SELECT CASE WHEN pg_catalog.has_database_privilege(:'app_user_v2', :'db_name_v2', 'CONNECT') AND pg_catalog.has_schema_privilege(:'app_user_v2', 'public', 'USAGE') AND pg_catalog.has_schema_privilege(:'app_user_v2', 'public', 'CREATE') THEN 1 ELSE 0 END;"
    GRANTS_OK2="$(as_postgres psql -At -d "$DB_NAME_VAR2" -v app_user_v2="$APP_USER_VAR2" -v db_name_v2="$DB_NAME_VAR2" -c "$GRANT_CHECK_SQL2" 2>/dev/null | tr -d '\\r\\n' || true)"
    if [ "$GRANTS_OK2" = "1" ]; then
      report "Grants" "SKIP" "privileges already in effect"
    else
      (as_postgres psql -v ON_ERROR_STOP=1 -d "$DB_NAME_VAR2" -c {shlex.quote(grant_sql)} || as_postgres psql -v ON_ERROR_STOP=1 -d postgres -c {shlex.quote(grant_sql)}) || {{ report "Grants" "FAIL" "psql error applying grant SQL (target and fallback postgres both failed)"; echo "Failed to apply grant SQL for user={app_user} db={db_name}" >&2; exit 10; }}
      report "Grants" "DONE" "applied"
    fi
    """

    print_block(
        "Plan",
        f"""
        Target (SSH): {ssh_user}@{host}:{ssh_port}
        Create/Update role: {app_user}
        Create database:     {db_name}
        """,
    )
    if not yes_no("Apply these changes on the remote host now?", default=True):
        return

    p = ssh_run(
        host=host,
        port=ssh_port,
        user=ssh_user,
        identity_file=identity_file,
        remote_command=f"bash -lc {shlex.quote(textwrap.dedent(remote_script).strip())}",
        capture=False,
    )
    if p.returncode != 0:
        print_block(
            "Failed",
            """
            Could not apply SQL over SSH on the remote host.
            Common causes:
            - PostgreSQL is not installed yet
            - The postgres OS user cannot run psql
            - SSH login succeeded but the remote command failed
            """,
        )
        return

    audit_ok, audit_rows = remote_postgres_audit_ssh(
        host=host,
        port=ssh_port,
        user=ssh_user,
        identity_file=identity_file,
        expected_db=db_name,
        expected_role=app_user,
    )
    print_block("Audit", format_report_lines(audit_rows))
    if not audit_ok:
        print_block(
            "Failed verification",
            """
            The database/user commands completed, but the remote audit could not confirm the expected state.
            Review the audit output above.
            """,
        )
        return

    print_block(
        "Done",
        """
        Database and user configured on the remote host.
        Next: choose "Verify" to test connectivity.
        """,
    )


def configure_db_user() -> None:
    idx = prompt_choice(
        "Configure database/user target",
        [
            "This machine or direct TCP connection",
            "Remote Linux over SSH",
        ],
    )
    if idx == 0:
        configure_db_user_local()
    else:
        configure_db_user_ssh()


def verify_installation() -> None:
    idx = prompt_choice(
        "Verify target",
        [
            "Direct PostgreSQL connection",
            "Remote Linux over SSH (server audit)",
        ],
    )
    if idx == 1:
        if not which("ssh"):
            print_block(
                "ssh not found",
                """
                OpenSSH client is required for the remote server audit.
                Install the OpenSSH client and retry.
                """,
            )
            return

        host, ssh_port, ssh_user, identity_file, _use_sudo = prompt_ssh_connection()
        db = prompt_identifier("Expected database", default="postgres")
        user = prompt_identifier("Expected role", default="postgres")
        audit_ok, audit_rows = remote_postgres_audit_ssh(
            host=host,
            port=ssh_port,
            user=ssh_user,
            identity_file=identity_file,
            expected_db=db,
            expected_role=user,
        )
        print_block("Audit", format_report_lines(audit_rows))
        if audit_ok:
            print_block("Success", "Remote server audit passed.")
        else:
            print_block("Failed", "Remote server audit found one or more problems.")
        return

    psql = find_psql_path()
    if not psql:
        print_block(
            "psql not found",
            "Install PostgreSQL first (or add psql to PATH), then retry.",
        )
        return

    host = prompt_host("localhost")
    port = prompt_port(5432)
    db = prompt_identifier("Database", default="postgres")
    user = prompt_identifier("User", default="postgres")
    use_password = yes_no("Use password?", default=True)
    pw = getpass.getpass("Password: ") if use_password else ""
    audit_ok, audit_rows = local_postgres_audit(
        psql,
        host=host,
        port=port,
        user=user,
        db=db,
        password=pw if use_password else None,
    )
    print_block("Audit", format_report_lines(audit_rows))
    if audit_ok:
        print_block("Success", "Connection and PostgreSQL checks passed.")
    else:
        print_block("Failed", "One or more PostgreSQL checks failed.")


def show_system_info() -> None:
    print_block(
        "System",
        f"""
        OS:       {platform.platform()}
        Python:   {sys.version.split()[0]}
        Admin:    {is_admin_windows() if is_windows() else (os.geteuid() == 0)}
        winget:   {'yes' if which('winget') else 'no'}
        psql:     {find_psql_path() or 'not found'}
        """,
    )


def main_menu() -> None:
    while True:
        idx = prompt_choice(
            "PostgreSQL Interactive Installer",
            [
                "System info",
                "Install PostgreSQL",
                "Remote PostgreSQL full setup (SSH/Linux)",
                "Configure (create DB/user)",
                "Enable remote access (server)",
                "Verify",
                "Exit",
            ],
        )
        if idx == 0:
            show_system_info()
        elif idx == 1:
            install_postgres()
        elif idx == 2:
            remote_full_setup_ssh()
        elif idx == 3:
            configure_db_user()
        elif idx == 4:
            enable_remote_access()
        elif idx == 5:
            verify_installation()
        else:
            return


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="postgres_installer.py",
        description="Interactive PostgreSQL installer/configurator (Windows + Linux).",
    )
    p.add_argument("--no-menu", action="store_true", help="Run a minimal flow and exit.")
    return p.parse_args(list(argv))


def minimal_flow() -> None:
    show_system_info()
    if yes_no("Install PostgreSQL now?", default=True):
        install_postgres()
    if yes_no("Run full PostgreSQL setup on a remote Linux host via SSH now?", default=False):
        remote_full_setup_ssh()
    if yes_no("Configure DB/user now?", default=True):
        configure_db_user()
    if yes_no("Enable remote access now?", default=False):
        enable_remote_access()
    if yes_no("Verify now?", default=True):
        verify_installation()


def main(argv: Sequence[str]) -> int:
    try:
        args = parse_args(argv)
        if args.no_menu:
            minimal_flow()
            return 0
        main_menu()
        return 0
    except KeyboardInterrupt:
        print_block("Cancelled", "Operation cancelled by user.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
