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
    return value.replace("'", "''")


def build_role_sql(app_user: str, app_pass: str) -> str:
    return f"""
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '{normalize_sql_literal(app_user)}') THEN
            CREATE ROLE "{app_user}" LOGIN PASSWORD '{normalize_sql_literal(app_pass)}';
        ELSE
            ALTER ROLE "{app_user}" LOGIN PASSWORD '{normalize_sql_literal(app_pass)}';
        END IF;
    END
    $$;
    """


def build_db_exists_sql(db_name: str) -> str:
    return f"SELECT 1 FROM pg_database WHERE datname = '{normalize_sql_literal(db_name)}';"


def build_create_db_sql(db_name: str, app_user: str) -> str:
    return f'CREATE DATABASE "{db_name}" OWNER "{app_user}";'


def build_grant_sql(db_name: str, app_user: str) -> str:
    return f'GRANT ALL PRIVILEGES ON DATABASE "{db_name}" TO "{app_user}";'


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

    needs_sudo = os.geteuid() != 0
    sudo = ["sudo"] if needs_sudo and which("sudo") else []

    if mgr == "apt":
        cmds: list[list[str]] = [
            sudo + ["apt-get", "update"],
            sudo + ["apt-get", "install", "-y", "postgresql", "postgresql-contrib"],
        ]
    else:
        cmds = [
            sudo + [mgr, "install", "-y", "postgresql-server", "postgresql-contrib"],
        ]

    print_block(
        "Plan",
        "\n".join(" ".join(c) for c in cmds),
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

    for pkg_id in candidates:
        p = run_cmd(
            [
                "winget",
                "install",
                "-e",
                "--id",
                pkg_id,
                "--accept-package-agreements",
                "--accept-source-agreements",
            ],
            check=False,
        )
        if p.returncode == 0:
            print_block(
                "Done",
                f"""
                Installed via winget: {pkg_id}

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
    args = ["ssh", "-p", str(port)]
    if identity_file:
        args += ["-i", identity_file]
    args.append(f"{user}@{host}")
    return args


def ssh_run(
    *,
    host: str,
    port: int,
    user: str,
    identity_file: str | None,
    remote_command: str,
    capture: bool,
) -> subprocess.CompletedProcess[str]:
    return run_cmd(ssh_base_args(host, port, user, identity_file) + [remote_command], capture=capture)


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
) -> str | None:
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
    if p.returncode != 0:
        return None
    out = (p.stdout or "") + "\n" + (p.stderr or "")
    m = re.search(r"__PKG__=(apt|dnf|yum|unknown)", out)
    if not m:
        return None
    pkg = m.group(1)
    return pkg if pkg in {"apt", "dnf", "yum"} else None


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
    sudo = "sudo " if use_sudo else ""

    mgr = detect_remote_linux_pkg_manager(
        host=host,
        port=ssh_port,
        user=ssh_user,
        identity_file=identity_file,
    )
    if not mgr:
        print_block(
            "Unsupported remote host",
            """
            Could not detect apt/dnf/yum on the remote machine, or SSH failed.
            Verify SSH connectivity and install PostgreSQL using your distribution docs.
            """,
        )
        return

    remote_script_lines: list[str] = []
    if mgr == "apt":
        remote_script_lines += [
            f"{sudo}apt-get update",
            f"{sudo}apt-get install -y postgresql postgresql-contrib",
            f"{sudo}systemctl enable --now postgresql || {sudo}service postgresql start || true",
        ]
    else:
        remote_script_lines += [
            f"{sudo}{mgr} install -y postgresql-server postgresql-contrib",
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

    exists = run_cmd(
        base_cmd + ["-At", "-c", db_exists_sql],
        env=env,
        capture=True,
        check=False,
    )
    if exists.returncode != 0:
        print_block("Failed", "Could not check whether the database already exists.")
        return

    if (exists.stdout or "").strip() != "1":
        createdb = run_cmd(
            base_cmd + ["-c", create_db_sql],
            env=env,
            check=False,
        )
        if createdb.returncode != 0:
            print_block("Failed", "Could not create the database.")
            return

    grant = run_cmd(
        base_cmd + ["-c", grant_sql],
        env=env,
        check=False,
    )
    if grant.returncode != 0:
        print_block("Failed", "Could not grant privileges on the database.")
        return

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
            out.append(f"listen_addresses = '{listen_addresses_value}'\n")
            changed = True
            continue
        out.append(line)

    if not changed:
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append(f"listen_addresses = '{listen_addresses_value}'\n")
        changed = True

    if changed:
        write_text_file_atomic(conf_path, "".join(out))
    return changed


def ensure_pg_hba_rule(hba_path: str, cidr: str, auth_method: str) -> bool:
    src = read_text_file(hba_path)
    rule = f"host all all {cidr} {auth_method}\n"
    normalized = "\n".join(l.rstrip("\r") for l in src.splitlines())

    if rule.strip() in normalized:
        return False

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


def restart_postgres(psql_path: str, data_directory: str | None) -> None:
    pg_ctl = find_pg_ctl_path(psql_path)
    if pg_ctl and data_directory:
        p = run_cmd([pg_ctl, "restart", "-D", data_directory, "-m", "fast"], check=False)
        if p.returncode == 0:
            return

    if not is_windows():
        needs_sudo = os.geteuid() != 0
        sudo = ["sudo"] if needs_sudo and which("sudo") else []
        if which("systemctl"):
            run_cmd(sudo + ["systemctl", "restart", "postgresql"], check=False)
        elif which("service"):
            run_cmd(sudo + ["service", "postgresql", "restart"], check=False)


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

    try:
        set_listen_addresses(config_file, listen_addresses)
        ensure_pg_hba_rule(hba_file, cidr, auth)
    except PermissionError:
        print_block(
            "Permission denied",
            """
            Could not modify PostgreSQL configuration files.
            Run this script with elevated permissions on the server and retry.
            """,
        )
        return

    apply_firewall_rules([port])
    restart_postgres(psql, data_dir)

    print_block(
        "Done",
        """
        Remote access configuration applied (best-effort).
        Next:
        - Ensure the target user has a strong password
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

        postgresql.conf: set listen_addresses = '{listen_addresses}'
        pg_hba.conf:     add host all all {cidr} {auth}
        firewall:        open {format_tcp_ports(firewall_ports)} (best-effort)
        restart:         restart PostgreSQL (best-effort)
        """,
    )
    if not yes_no("Apply these changes on the remote host now?", default=True):
        return

    remote_script = f"""
    set -e

    USE_SUDO={1 if use_sudo else 0}

    if [ "$USE_SUDO" -eq 1 ]; then
      if ! command -v sudo >/dev/null 2>&1; then
        echo "sudo not found on remote host"
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
      echo "No supported method to run commands as postgres (sudo/runuser/su missing)"
      exit 5
    }}

    psqlq() {{
      as_postgres psql -At -d postgres -c "$1"
    }}

    CONFIG_FILE="$(psqlq "SHOW config_file;")"
    HBA_FILE="$(psqlq "SHOW hba_file;")"
    DATA_DIR="$(psqlq "SHOW data_directory;")"

    if [ -z "$CONFIG_FILE" ] || [ -z "$HBA_FILE" ]; then
      echo "Could not discover PostgreSQL config paths"
      exit 6
    fi

    LISTEN_ADDRESSES={shlex.quote(listen_addresses)}
    CIDR={shlex.quote(cidr)}
    AUTH={shlex.quote(auth)}
    SSH_PORT={int(ssh_port)}
    PG_PORT={int(pg_port)}

    if $SUDO test -f "$CONFIG_FILE"; then
      $SUDO sed -ri "s/^\\s*#?\\s*listen_addresses\\s*=.*/listen_addresses = '$LISTEN_ADDRESSES'/" "$CONFIG_FILE" || true
      if ! $SUDO grep -Eq "^\\s*#?\\s*listen_addresses\\s*=" "$CONFIG_FILE"; then
        echo "listen_addresses = '$LISTEN_ADDRESSES'" | $SUDO tee -a "$CONFIG_FILE" >/dev/null
      fi
    else
      echo "postgresql.conf not found: $CONFIG_FILE"
      exit 7
    fi

    RULE="host all all $CIDR $AUTH"
    if ! $SUDO grep -Fxq "$RULE" "$HBA_FILE"; then
      echo "$RULE" | $SUDO tee -a "$HBA_FILE" >/dev/null
    fi

    if command -v ufw >/dev/null 2>&1; then
      $SUDO ufw allow "${{SSH_PORT}}/tcp" || true
      $SUDO ufw allow "${{PG_PORT}}/tcp" || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
      $SUDO firewall-cmd --add-port "${{SSH_PORT}}/tcp" --permanent || true
      $SUDO firewall-cmd --add-port "${{PG_PORT}}/tcp" --permanent || true
      $SUDO firewall-cmd --reload || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
      $SUDO systemctl restart postgresql || true
    elif command -v service >/dev/null 2>&1; then
      $SUDO service postgresql restart || true
    elif command -v pg_ctl >/dev/null 2>&1; then
      as_postgres pg_ctl restart -D "$DATA_DIR" -m fast || true
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

    print_block(
        "Done",
        """
        Remote access configuration applied on the remote host (best-effort).
        The script attempted to open both SSH and PostgreSQL in the server firewall.
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
    db_exists_sql = build_db_exists_sql(db_name)
    create_db_sql = build_create_db_sql(db_name, app_user)
    grant_sql = build_grant_sql(db_name, app_user)
    remote_script = f"""
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
      echo "No supported method to run commands as postgres (sudo/runuser/su missing)"
      exit 5
    }}

    as_postgres psql -v ON_ERROR_STOP=1 -d postgres -c {shlex.quote(role_sql)}

    DB_EXISTS="$(as_postgres psql -At -d postgres -c {shlex.quote(db_exists_sql)})"
    if [ "$DB_EXISTS" != "1" ]; then
      as_postgres psql -v ON_ERROR_STOP=1 -d postgres -c {shlex.quote(create_db_sql)}
    fi

    as_postgres psql -v ON_ERROR_STOP=1 -d postgres -c {shlex.quote(grant_sql)}
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
    psql = find_psql_path()
    if not psql:
        print_block(
            "psql not found",
            "Install PostgreSQL first (or add psql to PATH), then retry.",
        )
        return

    v = run_cmd([psql, "--version"], capture=True, check=False)
    print()
    if v.returncode == 0:
        print(v.stdout.strip())
    else:
        print("Could not run psql --version.")

    if not yes_no("Test a connection with credentials?", default=True):
        return

    host = prompt_host("localhost")
    port = prompt_port(5432)
    db = prompt_identifier("Database", default="postgres")
    user = prompt_identifier("User", default="postgres")
    use_password = yes_no("Use password?", default=True)
    pw = getpass.getpass("Password: ") if use_password else ""

    env: dict[str, str] = {}
    if use_password and pw:
        env["PGPASSWORD"] = pw

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
            "-c",
            "SELECT version();",
        ],
        env=env,
        check=False,
    )
    if p.returncode == 0:
        print_block("Success", "Connection OK.")
    else:
        print_block("Failed", "Connection test failed.")


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
                "Install PostgreSQL on remote host (SSH/Linux)",
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
            remote_install_postgres_ssh()
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
    if yes_no("Install PostgreSQL on a remote Linux host via SSH now?", default=False):
        remote_install_postgres_ssh()
    if yes_no("Configure DB/user now?", default=True):
        configure_db_user()
    if yes_no("Enable remote access now?", default=False):
        enable_remote_access()
    if yes_no("Verify now?", default=True):
        verify_installation()


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.no_menu:
        minimal_flow()
        return 0
    main_menu()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
