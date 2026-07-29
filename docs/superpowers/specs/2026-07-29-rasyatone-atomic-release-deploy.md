# RaSYaTone Django Deployment Script Design Spec

Author: Assistant <assistant@trae.ai>
Status: DRAFT (all 5 design sections user-approved; awaiting final user review before implementation)
Date: 2026-07-29
Project: RaSYaT_SpAcE_Solution → single-script production deployment, remote or local

- [1. Goals & Non-goals](#1-goals--non-goals)
- [2. Architecture (Approach B: Atomic release-dir symlink switch)](#2-architecture-approach-b-atomic-release-dir-symlink-switch)
  - [2.1 Production topology](#21-production-topology)
  - [2.2 Dual execution mode (local + remote SSH)](#22-dual-execution-mode-local--remote-ssh)
  - [2.3 Release directory structure](#23-release-directory-structure)
  - [2.4 Per-release virtual-environment strategy](#24-per-release-virtual-environment-strategy)
- [3. Inputs, CLI interface, Secrets file](#3-inputs-cli-interface-secrets-file)
  - [3.1 argparse CLI flags (defaults agreed in Q&A)](#31-argparse-cli-flags-defaults-agreed-in-qa)
  - [3.2 Remote SSH mode extra flags](#32-remote-ssh-mode-extra-flags)
  - [3.3 Environment file /etc/rasyatone/static/rasyatone.env — USER CREATES, script NEVER WRITES](#33-environment-file-etcrasyatonestaticrasyatonenv--user-creates-script-never-writes)
  - [3.4 Django layout auto-detection (no hardcoded package names)](#34-django-layout-auto-detection-no-hardcoded-package-names)
- [4. Preflight validation (16 checks, fail-fast; 0 changes applied if any fail)](#4-preflight-validation-16-checks-fail-fast-0-changes-applied-if-any-fail)
- [5. Idempotency matrix (25 resources — never recreated on repeat deploy)](#5-idempotency-matrix-25-resources--never-recreated-on-repeat-deploy)
- [6. Deploy pipeline (18 ordered stages) + stage failure semantics](#6-deploy-pipeline-18-ordered-stages--stage-failure-semantics)
- [7. Rollback stage + Check stage behavior](#7-rollback-stage--check-stage-behavior)
- [8. Error handling, logging, security hardening](#8-error-handling-logging-security-hardening)
  - [8.1 Error handling (DeployError hierarchy)](#81-error-handling-deployerror-hierarchy)
  - [8.2 Logging (console + deploy log, NEVER log secrets)](#82-logging-console--deploy-log-never-log-secrets)
  - [8.3 Security hardening (beyond idempotency / preflight)](#83-security-hardening-beyond-idempotency--preflight)
  - [8.4 Rollback semantics (deterministic, never auto-prune rollback targets)](#84-rollback-semantics-deterministic-never-auto-prune-rollback-targets)
- [9. Pre-flight summary & success/failure printouts](#9-pre-flight-summary--successfailure-printouts)
- [10. Spec self-review checklist (passed)](#10-spec-self-review-checklist-passed)

---

## 1. Goals & Non-goals

### Goals
1. Single-file production deployment script `rasyatone_deploy.py` next to existing [postgres_installer.py](file:///d:/Developments/PostgreSQL_installation/PostgreSQL_installation/postgres_installer.py). **Zero extra files required** (Python stdlib + argparse only).
2. Support **both local install (run on target server with sudo python3 …)** AND **remote install (dev machine → `--remote user@host[:port]` SSH heredoc pattern, reusing ssh_run + hostkey auto-cleanup from postgres_installer.py)**. Same script file in both cases.
3. Atomic deployments via release-directory symlink switching. Repeatable / idempotent: re-running deploy creates new timestamped release, old releases remain for rollback.
4. Never overwrite user secrets. Environment file `/etc/rasyatone/static/rasyatone.env` **is created by user only**. Script validates presence and permissions, never writes to it, never templates it.
5. Zero hardcoded values beyond the defaults agreed in Q&A; everything is CLI-overridable. Remote PostgreSQL: user provides DB_* in env file manually; script does NOT install PostgreSQL.
6. Idempotent throughout (25 resources), fail-fast at preflight (16 checks), automatic rollback on production-stage failure.
7. Optional Redis + Celery worker/beat systemd services via `--with-workers` flag.

### Non-goals (out of scope)
- **Not a web UI**. Pure CLI script.
- **Does not install/setup local PostgreSQL** (user confirmed remote DB already exists and they fill env manually).
- **Does not implement auto-rollback UI**, Slack/Discord/email notifications, CI/CD integration hooks. (Can add later.)
- **No multi-server / blue-green / load-balanced deployments** (single server only).
- **Does not manage Python versions via pyenv/deadsnakes PPA by default**; uses `python3` from apt or system, auto-picks newest installed python3.10+.

---

## 2. Architecture (Approach B: Atomic release-dir symlink switch)

### 2.1 Production topology

```
Internet (HTTPS/DNS :80/:443)
    ↓
 Nginx (Certbot LetsEncrypt SSL, certbot renew auto-timer, HTTP→HTTPS redirect, static/media direct serve, security headers)
    ↓  (reverse proxy via UNIX SOCKET — no open TCP port for Gunicorn)
 Gunicorn (rasyatone_user, systemd rasyatone.service with 2×CPU+1 workers, ProtectedSystem=strict, NoNewPrivileges=true, PrivateTmp=true)
    ↓  (reads env from /etc/rasyatone/static/rasyatone.env, chdir /opt/rasyatone/current)
 Django application (source in /opt/rasyatone/releases/<timestamp>, current → symlink)
    ↓  (via psycopg2/binary using DATABASE_URL)
 Remote PostgreSQL (user configured DB_* values)
  + (optional) --with-workers:
     Redis 127.0.0.1 only (protected-mode yes, bind localhost, supervised systemd)
        ↓
     Celery worker (rasyatone_user, rasyatone-celery.service)
     Celery beat   (rasyatone_user, rasyatone-celerybeat.service)
     (both read same env file)
```

### 2.2 Dual execution mode (local + remote SSH)

- **Default / local mode**: run `sudo python3 rasyatone_deploy.py --deploy` (or `--stage deploy`) **on the target server itself**. All file writes, apt installs, systemd, happen locally.
- **Remote mode**: if `--remote user@host[:port]` is provided from a **developer/operator machine (not the target)**, the script:
  1. Reuses the `ssh_run(host,port,user,identity,script)` + `_remove_host_key(host,port)` + `_is_host_key_error(stderr)` helpers already designed for postgres_installer.py.
  2. Uploads its own script body to `/tmp/rasyatone_deploy_tmp_<pid>.py` on the remote, injects a `--local-mode` hidden flag that forces remote to behave as local, plus passes all rendered argparse flags as CLI to the remote python invocation.
  3. Executes via `ssh -T user@host sudo -n python3 /tmp/rasyatone_deploy_tmp_<pid>.py --local-mode <all flags>`, streams stdout/stderr back. Cleans up tmp script on exit.
  4. All privileged operations happen on the remote target; developer machine never writes to production directly.

Remote mode supports `--identity` (SSH key path) and inherits the hostkey auto-cleanup (`ssh-keygen -R <host> -R "[<host>]:<port>"`) pattern from postgres_installer on first `Host key verification failed` error → auto retry once.

### 2.3 Release directory structure

Paths (user-confirmed defaults + env-file location modification from Section1 review):
```
/opt/rasyatone/                                   (deploy dir --deploy-dir default, rasyatone_user:rasyatone_user 0755)
├── releases/                                     (0755, never world-writable, adm group)
│   ├── 20260729-090000/
│   │   ├── release.json                          {git_sha, ref, repo, deployed_by, started_at, finished_at,
│   │                                                settings_module, wsgi_app, managepy_rel, app_name_slug,
│   │                                                pip_sha, prev_release, health_status}
│   │   ├── .env                  → /etc/rasyatone/static/rasyatone.env   (symlink, NEVER copy)
│   │   ├── media                 → /opt/rasyatone/shared/media           (symlink)
│   │   ├── logs                  → /opt/rasyatone/shared/logs            (symlink)
│   │   ├── staticfiles           → /opt/rasyatone/shared/staticfiles     (symlink)
│   │   ├── manage.py                                         (from git)
│   │   ├── <repo contents>
│   │   └── venv/                                             (per-release venv, Section 2.4)
│   ├── 20260728-173000/
│   ├── 20260727-110000/
│   ├── 20260726-220000/
│   └── 20260725-090000/        ← auto-pruned if newer than N releases (--keep-releases default 5)
├── shared/
│   ├── media/                   (02775 rasyatone_user:adm, sticky/sgid group so uploads group-writable Django)
│   ├── logs/                    (02750 rasyatone_user:adm)
│   └── staticfiles/             (0755 rasyatone_user:rasyatone_user, collectstatic target)
├── current          → /opt/rasyatone/releases/20260729-090000    ← atomic ln -sfn switch, STAGE 14
└── <optional>
    base_venv_template/           (clone cache; if present per-release venv copies this, then pip install delta)

/etc/rasyatone/
└── static/                       (0750 root:rasyatone_user)
    └── rasyatone.env             (0640 root:rasyatone_user — USER CREATES, script NEVER MODIFIES)

/var/log/rasyatone/               (0750 rasyatone_user:adm — deploy.log, gunicorn logs, nginx access/error, celery logs)

/var/backups/rasyatone/           (0700 root:root)
    └── pre-migration-YYYYmmdd-HHMMSS.dump     (pg_dump custom format compressed; keep 14 days)
```

### 2.4 Per-release virtual-environment strategy

Per release venv, NEVER shared mutable venv between releases to avoid "pip install today broke last-week's rollback" bugs.
Flow for each release:
1. Stage 7: `python3 -m venv /opt/rasyatone/releases/<ts>/venv` — `python3` resolved to newest `python3.{10,11,12,...}` available on PATH; minimum 3.10.
2. Upgrade pinned pip base: `./venv/bin/pip install --upgrade pip setuptools wheel`
3. Discover requirements file priority: `requirements.lock` > `requirements.prod.txt` > `requirements.txt`. If none → DEPLOY HALTED.
4. Install. If `requirements.lock` found → `pip install --require-hashes -r requirements.lock` (strict). Otherwise plain install (user warned).
5. Capture `pip list --format=json` → SHA256 → store in release.json.pip_sha.
6. Optional performance cache: if `/opt/rasyatone/shared/base_venv_template/` exists and SHA matches last deploy's pip_sha → use `cp -a` or `python -m venv --upgrade-deps --copies` clone to speed things up (user opt-in `--use-venv-cache` flag). Default OFF for simplicity.

---

## 3. Inputs, CLI interface, Secrets file

### 3.1 argparse CLI flags (defaults agreed in Q&A)

```
usage: rasyatone_deploy.py [--deploy]
                          [--stage preflight|deploy|rollback|check]
                          [--remote user@host[:port]] [--identity PATH]
                          [--repo URL] [--ref REF]
                          [--app-name NAME] [--service-user NAME]
                          [--deploy-dir DIR] [--log-dir DIR] [--config-dir DIR]
                          [--env-file PATH]
                          [--domain DOMAIN [--alias WWW.DOMAIN ...]]
                          [--letsencrypt-email younisalbadawi@alrasyat.com]
                          [--with-workers]
                          [--settings-module dotted.path]
                          [--wsgi-app dotted.path:callable]
                          [--managepy REL_PATH_IN_REPO]
                          [--gunicorn-workers N]
                          [--gunicorn-mode unix|tcp]
                          [--gunicorn-bind socket_path_or_127.0.0.1:PORT]
                          [--pre-migration-backup yes|no|auto]
                          [--keep-releases N]
                          [--logrotate yes|no]
                          [--healthcheck yes|no]
                          [--rollback-to RELEASE_TS]  (only for --stage rollback)
                          [--use-venv-cache] [--force] [--non-interactive]
                          [--skip-check-deploy] [--no-prebackup] [--force-dangerous-debug-deploy]
                          [--no-color] [--quiet] [--verbose]
                          [-h] [--version]

Defaults (ALL overridable):
  --repo https://github.com/younisalbadawi/RaSYaT_SpAcE_Solution.git
  --ref main
  --service-user rasyatone_user
  --deploy-dir /opt/rasyatone
  --config-dir /etc/rasyatone
  --env-file /etc/rasyatone/static/rasyatone.env
  --log-dir /var/log/rasyatone
  --domain rasyatone.alrasayt.com
  --letsencrypt-email younisalbadawi@alrasyat.com
  --pre-migration-backup auto   (run backup IF psql installed AND DB_* populated)
  --keep-releases 5
  --gunicorn-mode unix          (bind unix:/run/rasyatone/gunicorn.sock)
  --gunicorn-workers 2*nproc+1  (auto calc at runtime)
  --logrotate yes
  --healthcheck yes
  --stage deploy
```

Hidden flags (only mentioned in verbose help / error messages):
- `--force-dangerous-debug-deploy`: bypasses preflight check DJANGO_DEBUG != True
- `--skip-check-deploy`: bypasses Django `manage.py check --deploy` stage 9 gate
- `--local-mode`: set automatically by remote-mode wrapper when running on target

### 3.2 Remote SSH mode extra flags

- `--remote user@host[:port]` — user@host:port for SSH; if port omitted → 22
- `--identity /path/to/.ssh/id_ed25519` — optional, default uses ssh-agent / ~/.ssh/id_rsa/id_ed25519

Behavior: SSH hostkey auto-cleanup on first "Host key verification failed" error — identical pattern already in postgres_installer. Retry exactly once after `ssh-keygen -R <host> -R "[<host>]:<port>"`.

### 3.3 Environment file /etc/rasyatone/static/rasyatone.env — USER CREATES, script NEVER WRITES

(Per Section 2 user correction. The script **does not create or template this file**.)

Required keys (non-empty, validated in preflight; deploy fails if missing):

| Key | Stage = deploy requirement | Notes |
|---|---|---|
| DJANGO_SECRET_KEY | Mandatory | ≠ "CHANGE_ME*". Length ≥ 50 chars advised. |
| DJANGO_DEBUG | Must be False/0/no on stage = deploy | Preflight bypass only with `--force-dangerous-debug-deploy`. |
| DJANGO_ALLOWED_HOSTS | Mandatory | Includes domain and localhost. |
| DJANGO_CSRF_TRUSTED_ORIGINS | Mandatory if HTTPS (always) | `https://domain` |
| DATABASE_URL XOR (DB_NAME, DB_USER, DB_PASSWORD, DB_HOST, DB_PORT) | Mandatory | DATABASE_URL takes priority if set. Scheme `postgres*` or `postgresql*`. |

Recommended (not required):
- DJANGO_STATIC_ROOT, DJANGO_MEDIA_ROOT, DJANGO_LOG_DIR → default /opt/rasyatone/shared/{staticfiles,media,logs} if empty.
- (If --with-workers): REDIS_URL, CELERY_BROKER_URL, CELERY_RESULT_BACKEND, CELERY_WORKER_CONCURRENCY.
- (Optional): EMAIL_URL, AWS_*, any app-specific keys.

File permissions enforced in preflight stage check 10 + check 15:
- Exists. Not empty.
- `stat %a` ∈ {0600, 0640}. More permissive (e.g. 0644 world-read) → deploy fails interactive, warns non-interactive with remediation.
- Group must be `rasyatone_user` (or pre-user-creation → must be root; after user, chgrp rasyatone_user pre-stage-2).

**Security invariant**: env file is NEVER written by script, NEVER .source() into shell or parent process env, NEVER included in deploy.log.

### 3.4 Django layout auto-detection (no hardcoded package names)

(Per user Q5 "dynamic" answer — no settings/wsgi hardcoded.)

Auto-detection runs in Stage 6, after Git clone:
1. `find <release_root> -name manage.py -not -path '*/venv/*' -not -path '*/node_modules/*' | head -1` → MANAGEPY_REL (relative to release root).
2. Same with `wsgi.py` and `asgi.py`: wsgi wins by default. Constructs Python dotted path by stripping .py and substituting slashes.
3. Greps found `wsgi.py` / `manage.py` / `asgi.py` for `DJANGO_SETTINGS_MODULE = ` or `os.environ.setdefault("DJANGO_SETTINGS_MODULE", ...)` and extracts the default.
4. If CLI `--settings-module` / `--wsgi-app` / `--managepy` provided → OVERRIDES auto-detect.

All auto-detected values printed in Preflight summary before Stage 1 runs.

---

## 4. Preflight validation (16 checks, fail-fast; 0 changes applied if any fail)

Grouped. Fail = exit with explicit remediation message. PASS = go.

| Phase | # | Check | Stages applied | Fail remediation |
|---|---|---|---|---|
| A. Execution context | 1 | OS: Ubuntu ≥ 20.04 / Debian ≥ 11 (/etc/os-release). RHEL/CentOS/Alma → WARN + try yum/dnf fallback paths for apt commands. | ALL | Confirm distro. |
|  | 2 | Root or sudo-nopasswd: `whoami=root` OR `sudo -n /bin/true` succeeds. | ALL | Run with `sudo`; add NOPASSWD. |
|  | 3 | Ports available on `0.0.0.0` / TCP bind: 80, 443. (6379 if --with-workers.) If --gunicorn-mode=tcp → bind port. | deploy / rollback | Stop conflicting services. |
|  | 4 | Disk space free: `/opt` ≥ 5 GB, `/var/log` ≥ 1 GB, `/tmp` ≥ 2 GB, `/etc` ≥ 200 MB, `/var/backups` ≥ 500 MB (pre-migration backup). | deploy | Clear disk. |
|  | 5 | Total RAM ≥ 1.5 GB. Swap OK. Warn at 1.0 GB. | deploy | Add swap / RAM. |
| B. Network & DNS | 6 | DNS resolution: `getent ahostsv4 <--domain>` returns ≥ 1 IP. Auto-detect server public IP via `curl --max-time 5 -fsS https://api.ipify.org` and warn if domain A ≠ server public IP. | deploy / check | Fix A record, bypass via /etc/hosts for testing. |
|  | 7 | Internet reachability for apt + git + certbot: curl --max-time 5 -fsS github.com, acme-v02.api.letsencrypt.org (only when certbot auto path active). | deploy certbot=auto path | Egress / proxy fix. |
|  | 8 | Git repo reachable AND ref exists: `git ls-remote --exit-code <--repo> refs/heads/<ref> \|\| refs/tags/<ref>` → exit 0. | deploy / preflight | Upload deploy key; confirm ref. |
|  | 9 | Remote PostgreSQL reachable (when DB_* non-empty): use psql/subprocess `SELECT 1;` or psycopg2 if installed via venv after stage 7 (preflight uses minimal: `psql "conninfo" -c "SELECT 1;"`). | deploy / check | Add pg_hba / firewall, confirm DB_* vars. |
| C. Env & secrets | 10 | Env file: exists, non-empty, permissions ≤ 0640, owner/group sane. | ALL (strict for deploy) | Create file manually; chmod/chown. |
|  | 11 | Required env keys: DJANGO_SECRET_KEY (≠ CHANGE_ME*); DJANGO_DEBUG = False for deploy; DJANGO_ALLOWED_HOSTS non-empty. | deploy | Add keys to env file. |
|  | 12 | DB connectivity vars: DATABASE_URL non-empty AND scheme postgres* OR all 5 of {DB_NAME,DB_USER,DB_PASSWORD,DB_HOST,DB_PORT} non-empty. | deploy | Set DB vars in env. |
|  | 13 | Python ≥ 3.10 available: `python3` or `python3.10+` on PATH. | deploy | Install via apt python3.10. |
| D. No overwrite guard | 14 | Existing nginx vhost overwrite guard: if any site is already present (except default) AND would be shadowed by new server_name domain → INTERACTIVE prompt confirm or --force flag; non-interactive → FAIL. | deploy | --force; manual clean. |
|  | 15 | Env file permissiveness: if env file more permissive than 0640 → interactive prompt / non-interactive fail. | deploy | chmod 0640 file; chgrp rasyatone_user. |
| E. Preflight Summary | 16 | Print human-readable preflight summary table (App, Env, Ref, Domain, Dir, DB host Remote, Web Nginx+Certbot, Gunicorn mode/workers, Workers on/off, Email). Confirm user to continue at deploy (INTERACTIVE, --non-interactive bypass). After print: `Preflight PASSED — 16/16`. | ALL | — |

---

## 5. Idempotency matrix (25 resources — never recreated on repeat deploy)

Every resource has `_exists()` function and `_ensure()` is no-op when exists.

| # | Resource | exists() check | Mutation behavior |
|---|---|---|---|
| 1 | Linux user `rasyatone_user` | `id rasyatone_user` exit 0 | useradd --system --create-home (home=/opt/rasyatone/.home) --shell /usr/sbin/nologin only if missing |
| 2 | adm group membership for rasyatone_user | `groups rasyatone_user \| grep -q adm` | usermod -aG adm only if missing |
| 3 | Deploy dir /opt/rasyatone | `[ -d /opt/rasyatone ]` | mkdir -p 0755 rasyatone_user:rasyatone_user |
| 4 | Subdirs: releases/, shared/{media,logs,staticfiles} | `[ -d DIR ]` | mkdir -p, chown, chmod: shared/media=2775 (sgid group-writable Django uploads), staticfiles=0755, logs=2750 rasyatone_user:adm |
| 5 | Config dir /etc/rasyatone/static | `[ -d /etc/rasyatone/static ]` | mkdir -p 0750 root:rasyatone_user |
| 6 | env file /etc/rasyatone/static/rasyatone.env | See preflight 10/11/12 | NEVER WRITES. Validates only. |
| 7 | Log dir /var/log/rasyatone | `[ -d /var/log/rasyatone ]` | mkdir 0750 rasyatone_user:adm |
| 8 | Backup dir /var/backups/rasyatone | `[ -d /var/backups/rasyatone ]` | mkdir 0700 root:root |
| 9 | Release venv python executable | `[ -x $RELEASE/venv/bin/python ]` | Stage 7 create only if missing per-release |
| 10 | pip base stack (pip,setuptools,wheel) in venv | `$venv/pip show <pkg>` exit 0 | Always run (idempotent via pip internal) |
| 11 | requirements packages installed | pip internal db | pip install -r always run; hash enforcement when lock file present |
| 12 | Django migrations applied | Django `django_migrations` table | Always run `migrate --noinput` (Django idempotent via internal table) |
| 13 | staticfiles manifest hash match | `SHA($STATIC_ROOT/staticfiles.json) == SHA_last_deploy` | Skip collectstatic if manifests match; else run collectstatic --noinput --clear |
| 14 | current symlink | readlink current == target release | Atomic ln -sfn only if target diffs |
| 15 | systemd unit files (rasyatone.service; rasyatone-celery.service; rasyatone-celerybeat.service if --with-workers) | sha256(in_memor y_unit) == sha256(/etc/systemd/system/X) | Write file only if differs; then daemon-reload only when needed |
| 16 | systemd enable-on-boot (units, nginx, redis, certbot timer) | `systemctl is-enabled X == enabled` | `systemctl enable X` only if disabled |
| 17 | apt packages (nginx, certbot, python3-certbot-nginx, python3-pip-venv, python3-pip, git, curl, acl, postgresql-client, build-essential, python3-dev, libpq-dev, pkg-config; redis if workers) | `dpkg-query -W -f='${Status}' pkg 2>/dev/null | grep -q 'install ok installed'` | `apt-get install -y pkg` only if not installed |
| 18 | certbot PPA/sources auto-detection (not needed Ubuntu 22.04+) | `apt-cache policy certbot` shows candidate | Only add certbot PPA if package unavailable |
| 19 | ufw firewall allow 80/tcp 443/tcp OpenSSH (default ssh port 22 or --remote port) | `ufw status verbose \| grep -qw '<port>/tcp'` | `ufw allow <port>/tcp` only if not listed |
| 20 | firewalld services (http,https,ssh) permanent + running | `firewall-cmd --permanent --query-service=X` | firewall-cmd --add-service=X --permanent + --reload only if query=no |
| 21 | Nginx sites-available/rasyatone + sites-enabled symlink | sha256 compare rendered vs on-disk file + symlink test | Write only if differs. |
| 22 | LetsEncrypt cert for domain + certbot timer | `certbot certificates 2>/dev/null \| grep -A2 <domain>` → valid ≥ 7 days; `systemctl is-enabled certbot.timer = enabled` | Run certbot only if missing/expiring. Enable certbot.timer + `certbot renew --dry-run` test |
| 23 | logrotate config /etc/logrotate.d/rasyatone | sha256 compare | Write if differs or missing |
| 24 | Redis localhost-only bind (if --with-workers) | `grep -E '^bind\s' /etc/redis/redis.conf | grep -q '127.0.0.1'` AND `protected-mode yes` AND `supervised systemd` | sed -i only if config differs, then restart redis |
| 25 | current release.json → finished_at: entry | file exists + key present | write final stage 18 only after health pass + cleanup |

---

## 6. Deploy pipeline (18 ordered stages) + stage failure semantics

### 6.1 Stage order 1 → 18

**Stage 1: System packages installation**
1. `apt-get update` if apt cache (`/var/cache/apt/pkgcache.bin` mtime) > 24 h old.
2. Install apt packages list (#17 idempotency). Skip Redis here (install later 13 if --with-workers).
3. dpkg-query verify all "install ok installed" or fail.

**Stage 2: Service user + directories**
- create rasyatone_user (#1 idempotency).
- group adm membership (#2).
- mkdir -p deploy dir + subdirs (#3, #4, #5, #7, #8).
- validate env file perms again (#10/15 preflight re-check). chgrp rasyatone_user for env file if still owned by root (first-run case), but never chmod above 0640.

**Stage 3: Secrets validation (repeat — guards against preflight→deploy gap user edits)**
- Env file exists, required keys, DB vars, DJANGO_DEBUG=False deploy. FAIL → exit 2.

**Stage 4: Create release dir + release.json partial**
- RELEASE_TS = `$(date +%Y%m%d-%H%M%S)`. (Python `datetime.utcnow().strftime("%Y%m%d-%H%M%S")` actually to avoid TZ differences.)
- `/opt/rasyatone/releases/$RELEASE_TS/` mkdir 0755.
- Write initial release.json: {ref, repo, deployed_by, started_at, remote_or_local}.

**Stage 5: Git clone**
- Branch ref → `git clone --depth 50 --single-branch --branch ref repo DIR`.
- Tag / SHA (detached): `git clone --no-checkout repo DIR && git -C DIR checkout ref`.
- Capture GIT_SHA → `git rev-parse HEAD`; write into release.json.

**Stage 6: Django layout auto-detect**
Run find + grep. Populate SETTINGS_MODULE, WSGI_APP, MANAGEPY_REL, APP_NAME_SLUG → write release.json. CLI overrides win.

**Stage 7: Per-release venv + dependencies**
- python3 -m venv per Section 2.4.
- pip base upgrade.
- pip install requirements per idempotency step #10/#11.
- ensure psycopg2 or psycopg[binary] installed (if missing → auto-install); fail if both absent.
- pip list sha → release.json.

**Stage 8: Symlink shared + env into release**
Create symlinks: .env, media, logs, staticfiles (see Section 2.3).
Fail hard if env file /etc/rasyatone/static/rasyatone.env absent — explicit message.

**Stage 9: Django check --deploy (CRITICAL gate)**
```
run_ok([
   "sudo","-u","rasyatone_user","-E",
   "/opt/rasyatone/releases/$TS/venv/bin/python",
   f"/opt/rasyatone/releases/$TS/$MANAGEPY_REL",
   "check","--deploy","--fail-level=WARNING"
], env=env_dict_only_loaded_in_subprocess, sensitive=False)
```
FAIL → DEPLOY HALTED, print stderr. (Hidden `--skip-check-deploy` bypass.)

**Stage 10: Pre-migration PostgreSQL backup (yes/auto/no)**
- When auto: only if psql installed AND DB vars populated.
- When yes: always run, fail on backup failure.
- When no: skip.
- Backup command: `pg_dump --format=custom --compress=6 --file=/var/backups/rasyatone/pre-migration-$TS.dump --dbname=$DATABASE_URL` using PGPASSWORD injected ONLY via subprocess env dict (NEVER command line to avoid ps).
- Prune older than 14 days: `ls -1t dir/pre-migration-*.dump | tail -n +15 | xargs rm -f`.
- `chmod 0600 root:root` dump file immediately after write (#8 security).

**Stage 11: Django migrations**
```
run_ok(["sudo","-u","rasyatone_user","-E",
        VENV_PYTHON, MANAGEPY_ABS, "migrate", "--noinput"],
       env=env_dict).
```
FAIL → error. Do not proceed to stage 14.

**Stage 12: collectstatic**
```
run_ok(["sudo","-u","rasyatone_user","-E",
        VENV_PYTHON, MANAGEPY_ABS, "collectstatic","--noinput","--clear"],
       env=env_dict).
```
Idempotent via collectstatic's own manifest hash. Skip (by checking SHA of staticfiles.json) to speed up deploys if manifests match.

**Stage 13: Workers (only if --with-workers)**
- apt install redis-server (#17 idempotency).
- Redis localhost hardening (#24 idempotency). enable redis. restart.
- venv pip install celery[redis] if not in requirements (warn user to add it).
- Write /etc/systemd/system/rasyatone-celery.service:
  ```
  [Unit]
  Description=RaSYaTone Celery Worker
  After=network.target redis-server.service
  Requires=redis-server.service

  [Service]
  Type=simple
  User=rasyatone_user
  Group=rasyatone_user
  WorkingDirectory=/opt/rasyatone/current
  EnvironmentFile=/etc/rasyatone/static/rasyatone.env
  ExecStart=/opt/rasyatone/current/venv/bin/celery -A <app_name_slug>.celery_app:app worker --loglevel=info --concurrency=$CELERY_WORKER_CONCURRENCY
  Restart=on-failure
  RestartSec=10
  PrivateTmp=true
  NoNewPrivileges=true
  ProtectSystem=strict
  ReadWritePaths=/opt/rasyatone/shared /var/log/rasyatone /tmp
  ProtectHome=read-only

  [Install]
  WantedBy=multi-user.target
  ```
  (Celery app name dotted path auto-detected: find `celery.py` in repo, grep `Celery(` for app name.)
- Write rasyatone-celerybeat.service similarly with `celery beat -A ... --schedule=/opt/rasyatone/shared/celerybeat-schedule` (celerybeat schedule lives in shared so it's not reset on new release).
- systemd enable → start deferred to Stage 15 along with Gunicorn so they all use the newly-switched current symlink.

**Stage 14: Atomic current symlink switch [BEGIN production mutation stage]**
```
PREV_RELEASE=$(readlink -f /opt/rasyatone/current 2>/dev/null || echo "none")
ln -sfn /opt/rasyatone/releases/$RELEASE_TS /opt/rasyatone/current
```
Write PREV_RELEASE into release.json. Stage is atomic in the filesystem-rename sense — Nginx/Gunicorn see either old release or new, never half.

**Stage 15: Systemd units write + enable/restart (Gunicorn + workers if enabled)**
- Write `/etc/systemd/system/rasyatone.service` per Section 4 Stage 15 systemd text:
  - User=rasyatone_user, RuntimeDirectory=rasyatone, WorkingDirectory=/opt/rasyatone/current, EnvironmentFile=/etc/rasyatone/static/rasyatone.env
  - ExecStart: `current/venv/bin/gunicorn --pid /run/rasyatone/gunicorn.pid --bind unix:/run/rasyatone/gunicorn.sock --workers <W> --timeout 60 --max-requests 1000 --max-requests-jitter 100 <WSGI_APP>`
  - ExecReload: `/bin/kill -s HUP $MAINPID`
  - Restart=on-failure, RestartSec=5, PrivateTmp=true, NoNewPrivileges=true, ProtectSystem=strict, ReadWritePaths=/opt/rasyatone/shared /var/log/rasyatone /run/rasyatone, ProtectHome=read-only, KillMode=mixed, Type=notify (for --worker-class gthread/gevent later).
  - TCP-mode: replace bind with `--bind 127.0.0.1:PORT`.
- `systemctl daemon-reload` only when unit files changed (per idempotency #15 sha compare).
- `systemctl enable --now rasyatone.service`.
- Health check Gunicorn: `systemctl is-active --quiet rasyatone` → pass; else read `journalctl -u rasyatone --no-pager -n 60` and fail stage.
- If --with-workers → enable+start celery+beat, health is-active checks.

**Stage 16: Nginx + certbot**
- Write `/etc/nginx/sites-available/rasyatone` (see Section 4 Stage 16 nginx text):
  - HTTP 80 → redirect to HTTPS for domain
  - HTTPS 443 ssl http2; TLS 1.2/1.3; HSTS max-age=31536000 includeSubDomains; security headers X-Frame-Options: DENY; X-Content-Type-Options nosniff; Referrer-Policy strict-origin-when-cross-origin; client_max_body_size 25M; nginx logs into /var/log/rasyatone/nginx.*.log; static/media alias to shared; proxy headers (Host, X-Real-IP, XFF, XFP); proxy_pass to upstream unix socket backend.
  - Add default catch-all server block (listen 80/443 default_server) returning 444 for unknown host headers.
- symlink `sites-enabled/rasyatone`.
- Disable `000-default.conf` only if interactive confirm / `--force`.
- **CRITICAL gate**: `nginx -t` (syntax OK) → exit 0 before ANYTHING touches a running nginx. Fail → DEPLOY FAIL, do not reload. (Auto-rollback? No, because this stage touched Nginx.conf only which is reverted by not-reloading, but if Nginx already reloaded mid-config → auto rollback restores old config from backup.)
- `systemctl reload nginx`; if nginx not running → `systemctl enable --now nginx`.
- Open firewall ports HTTP/HTTPS/SSH per #19/#20 idempotency.
- Certbot install/renew guard: `certbot certificates` has cert AND valid ≥ 7 days → skip install, only dry-run test. ELSE:
  `certbot --nginx -n --agree-tos --redirect -m younisalbadawi@alrasyat.com` plus `-d <domain>` for each --alias.
- Enable certbot.timer auto-renew (idempotency #16).
- Run `certbot renew --dry-run` (WARN only if fails; deploy continues but user warned auto-renew probably broken).

**Stage 17: Logrotate configuration**
Write `/etc/logrotate.d/rasyatone` per Section 4 Stage 17. SHA-compare with existing file (idempotency #23). Overwrite only if differs. Verify syntax via `logrotate -d /etc/logrotate.d/rasyatone`. (Warn-only.)

**Stage 18: Health checks + Success mark + Release cleanup**
1. **Health 1: Gunicorn + Django alive** — curl via localhost with proper Host/SNI headers:
   ```bash
   curl -fsS --max-time 10 --resolve <domain>:443:127.0.0.1 https://<domain>/health/ 2>/dev/null ||
   curl -fsS --max-time 10 --header "Host: <domain>" http://127.0.0.1:80/ 2>/dev/null
   ```
   (Fall back to `/` if `/health/` endpoint 404 → WARN only.)
2. **Health 2: DB connectivity** — via Django dbshell: `echo "SELECT 1;" | VENV_PYTHON MANAGEPY dbshell -- -At` succeeds OR subprocess psql SELECT 1 succeeds → PASS.
3. **Health 3: Services running**: `systemctl is-active --quiet nginx` AND rasyatone AND (redis, celery, celerybeat if workers enabled).
4. (Optional --with-workers Health 4): `redis-cli ping` returns `PONG`.
5. Write final release.json entries: finished_at, health_status, health_url, health_detail.
6. **Release cleanup / auto-prune**:
   - List all release dirs ordered newest → oldest.
   - Never delete: index 0 (current), index 1 (prev_release), plus newest (N-2) entries by `--keep-releases` (default 5 → delete index ≥ 5 from end).
   - Always preserve PREV_RELEASE even if older than cutoff, unless `--force-prune-prev-release` passed (hidden).
7. Console final output: big `DEPLOY SUCCESS` banner → current → PREV → git_sha → duration → rollback hint command.
8. Log: `DEPLOY_RESULT=SUCCESS ...`

### 6.2 Stage failure semantics

- Stage failure handler (top-level try/except DeployError):

| Fail stage N in | Failure category | Production touched? | Action | Exit code |
|---|---|---|---|---|
| Preflight | PreflightError | NO | Print preflight check # + remediation. | 100 + N |
| 1..13 | StageError | NO (all mutations in new release dir) | Optional partial dir cleanup with --cleanup-on-fail (non-interactive default yes). Print big banner: Deploy stopped, site untouched. Suggestions: fix the underlying cause + rerun. | 200 + N |
| 14..18 | ProdStageError | YES (switched symlink OR systemd restarted OR nginx reload executed) | Automatic rollback to PREV_RELEASE (Section 7 rollback). Run health checks after rollback. Print banner: Auto-rollback completed with PASS/FAIL status. | 300 + N |

- All exits write final log line: `DEPLOY_RESULT=FAILED stage=N code=... reason=...` into deploy log.

---

## 7. Rollback stage + Check stage behavior

### 7.1 `--stage rollback`
- Input: if `--rollback-to <ts>` provided, use ts. Else read PREV_RELEASE from current release.json.
- Validate rollback target:
  1. dir exists.
  2. contains `venv/bin/python`.
  3. contains release.json with `finished_at` non-empty (means deploy completed successfully; never roll back to partial stage-1-13 failure unless `--force-partial` passed).
- Steps:
  1. Atomic `ln -sfn /opt/rasyatone/releases/$TARGET /opt/rasyatone/current`.
  2. `systemctl daemon-reload` (only if units format changed between versions — possible but rare; reload is free so always do it).
  3. Graceful: `systemctl reload rasyatone` (Gunicorn HUP; keeps in-flight requests). Wait 5 s; if not healthy, fall back to `systemctl restart rasyatone`.
  4. If --with-workers enabled: restart celery + celerybeat (they chdir /current → after restart pick up the new code).
  5. Nginx configuration: if the rollback target's release.json records different SHA nginx site-conf from the one currently on disk → restore previous nginx site config via backup (we keep copies under `/var/backups/rasyatone/nginx/`) + `nginx -t` + reload.
  6. Health #1-#3 Stage 18 checks → PASS: `ROLLBACK: SUCCESS`. FAIL: `ROLLBACK: FAILED` banner + journalctl -n 60 dump, exit non-zero.
  7. Log final result: `ROLLBACK_RESULT=SUCCESS ...`

### 7.2 `--stage check`
- Skip apt, user creation, deploy, mutation. Only runs:
  1. Preflight quick subset: #2 sudo, #10 env file exists, #13 python, #6 dns, #9 db reachable.
  2. Health #1 (curl /health/ or /), Health #2 (DB SELECT 1), Health #3 (services is-active).
  3. Report: per-check PASS/FAIL table. Status line: CHECK_RESULT=PASS/FAIL.

### 7.3 `--stage preflight`
Runs full 16 preflight checks (Section 4), prints 16/16 PASSED table, exits without any side effects.

---

## 8. Error handling, logging, security hardening

### 8.1 Error handling (DeployError hierarchy)

Python exceptions:
```python
class DeployError(Exception):
    stage: int; code: int; user_msg: str; cmd: Optional[list[str]]; returncode: Optional[int];
    stdout_redacted: Optional[str]; stderr_redacted: Optional[str];
class PreflightError(DeployError): pass
class StageError(DeployError): pass           # stages 1..13
class ProdStageError(DeployError): pass       # stages 14..18
```

Top-level:
```
try:
    match args.stage:
        case "preflight": run_preflight(args)
        case "deploy": run_deploy(args)
        case "rollback": run_rollback(args)
        case "check": run_check(args)
except PreflightError as exc:
    print(f"[PREFLIGHT FAILED @ #{exc.stage}] ...\nRemediation: ...")
    sys.exit(exc.code)
except StageError as exc:
    cleanup_on_fail(args)
    print("[DEPLOY STOPPED BEFORE SWITCHING current — site untouched]")
    sys.exit(exc.code)
except ProdStageError as exc:
    auto = do_rollback(args, prev=prev_release)
    print(f"[PROD STAGE FAIL @ #{exc.stage}] Auto rollback {auto.status}.")
    sys.exit(exc.code)
finally:
    final_log_line(args, status, duration)
```

Helper `run_ok(cmd, check=True, user=None, env=None, sensitive=False)`:
- prepends `sudo -u <user> -E` when user= given.
- redacts command from logs/outputs if sensitive=True.
- always captures stdout+stderr to deploy.log (with REDACT filter applied afterwards — see 8.2).
- raises appropriate sub-class of DeployError based on current global stage tracker.

### 8.2 Logging (console + deploy log, NEVER log secrets)

Dual logger:
1. Console logger (ColoredFormatter, INFO default; --verbose → DEBUG; --quiet → ERROR only; --no-color strips ANSI). Each stage: `[ 1/18] Stage 1: Installing system packages … OK (34.1s)`.
2. Deploy log handler: `/var/log/rasyatone/deploy.log`. Format `ISO8601_UTC | STAGE=$N | PID=$P | LEVEL | MSG`.
   - Permissions: dir 0750 rasyatone_user:adm, file 0640 rasyatone_user:adm, rotated via logrotate config we install.
   - Sensitive scrub filter applied BEFORE any write (both console + deploy log):
     - All env vars whose name matches regex `(SECRET|PASSWORD|PASSWD|TOKEN|API.?KEY|ACCESS.?KEY|PRIVATE.?KEY|CREDENTIAL|AUTH|SESSION|COOKIE|CLIENT.?SECRET|DSN)` → value replaced with `***`.
     - URLs matching `postgres(ql)?://[^:]+:[^@]+@` → password portion `***`.
     - Commands marked sensitive=True → replaced `<redacted command>`.
   - Deploy.log never written to local developer machine in remote mode — only written to target via the bash heredoc / remote script execution context.

Extra structured log markers:
```
DEPLOY_RUN_START ts= user= mode=local/remote stage=preflight|deploy|...
PREFLIGHT_CHECK_START #N name=
PREFLIGHT_CHECK_PASS #N
PREFLIGHT_CHECK_FAIL #N reason=
STAGE_START N
STAGE_END N status=OK|FAIL duration=s
HEALTH url=https://... status=PASS|FAIL detail=
DEPLOY_RESULT=SUCCESS|FAILED release_ts= git_sha= prev= health= duration=s
ROLLBACK_RESULT=SUCCESS|FAILED from= to= health= duration=s
CHECK_RESULT=PASS|FAIL
```

### 8.3 Security hardening (beyond idempotency / preflight)

1. Env file is read via custom parser only (never os.environ exposure): parse each line of env file into a private `_envdict` Python dict in-memory inside `run_ok()` only; NEVER added to parent `os.environ`; subprocess children get a **copy** of `os.environ` MINUS any keys already matching secret pattern PLUS the env dict — thus secrets are never visible to later subprocesses unless explicit.
2. Temp files for command buffers use `tempfile.NamedTemporaryFile(mode='w+b', dir='/tmp', prefix='rasyatone_', suffix='.tmp', delete=True, perm=0o600)`.
3. Gunicorn binds unix socket only by default — no open TCP Gunicorn port. Socket permissions via systemd: `RuntimeDirectoryMode=0750` + `UMask=0007` for rasyatone.service so socket file = 0660 rasyatone_user:rasyatone_group, only nginx (root + group) can proxy to it.
4. Systemd units (all 3) set `PrivateTmp=true`, `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=read-only`, `ReadWritePaths=` explicitly lists whitelisted writable dirs (shared, logs, run dirs). This is a defense-in-depth sandbox.
5. Redis (if enabled) strictly `bind 127.0.0.1 ::1`, protected-mode yes, supervised systemd; firewall 6379 closed; no password for socket-speed localhost but firewall is the boundary.
6. Nginx default_server returns 444 (empty reply) for Host headers ≠ our domain, preventing host-header cache-poison / host CSRF on Django.
7. Backup dump files: chmod 0600 root:root — rasyatone_user CANNOT read them (least privilege).
8. Django check --deploy stage 9 validates (and FAILS unless --skip-check-deploy):
   - DEBUG=False
   - ALLOWED_HOSTS set and nonempty
   - CSRF_TRUSTED_ORIGINS has HTTPS origin
   - SECRET_KEY non-empty AND length ≥ 32
   - DATABASES default configured
   - STATIC_ROOT and MEDIA_ROOT non-empty
   - SECURE_SSL_REDIRECT=True
   - SESSION_COOKIE_SECURE=True
   - CSRF_COOKIE_SECURE=True
   - SECURE_HSTS_SECONDS ≥ 15768000
   - SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

### 8.4 Rollback semantics (deterministic, never auto-prune rollback targets)

- Auto-prune rules: NEVER delete: (a) currently `current` symlink target, (b) PREV_RELEASE (previous rollback candidate saved in release.json), (c) at least 2 additional release dirs newer than PREV_RELEASE to guarantee 2nd-day rollback option. Default --keep-releases 5 ensures this.
- Auto rollback is ONLY triggered on ProdStageError (stage 14-18 failure). Preflight / StageError 1..13 = no production impact; do NOT run auto-rollback because current symlink is unchanged.
- If rollback itself fails → exit code set to 399 + prints big banner: `MANUAL INTERVENTION REQUIRED` with journalctl excerpts and checklist: (a) check `systemctl --failed`, (b) `journalctl -u rasyatone -n 100`, (c) nginx error log, (d) manually `ln -sfn /opt/rasyatone/releases/<KNOWN_GOOD_TS> current` then restart services.

---

## 9. Pre-flight summary & success/failure printouts

Preflight summary after pass, before Stage 1 (--non-interactive skips confirmation):
```
╔══════════════════════════════════════════════════════════════════════╗
║  RaSYaTone Deployment — Preflight Summary                           ║
╠══════════════════════════════════════════════════════════════════════╣
║  Application          : rasyatone (auto-detected or --app-name)     ║
║  Environment          : production (from DJANGO_ENV or default)     ║
║  Stage                : deploy                                      ║
║  Mode                 : local OR remote user@ip:port                ║
║  Git Repository       : https://github.com/younisalbadawi/RaSY…git  ║
║  Git Ref / SHA        : main / 7a3b2c9…                              ║
║  Domain               : rasyatone.alrasayt.com                      ║
║  LetsEncrypt Email    : younisalbadawi@alrasyat.com                  ║
║  Deploy Directory     : /opt/rasyatone                               ║
║  Current Release      : /opt/rasyatone/releases/20260728-…          ║
║  Upcoming Release     : /opt/rasyatone/releases/20260729-090000     ║
║  Database             : REMOTE postgres at <DB_HOST>:5432/<DB_NAME> ║
║  Service Account      : rasyatone_user                              ║
║  Python Runtime       : python 3.11                                 ║
║  App Server           : Gunicorn (unix socket, 9 workers = 2×4+1)   ║
║  Web Server           : Nginx + Certbot Auto SSL                    ║
║  Background Workers   : OFF OR ON (--with-workers → Redis+Celery)   ║
║  Env file             : /etc/rasyatone/static/rasyatone.env (OK)    ║
║  Django settings      : <auto-detected dotted path>                 ║
║  WSGI app             : <wsgi:application>                          ║
║  manage.py            : <rel path>                                  ║
║  Pre-migration backup : AUTO (yes/no)                               ║
║  Keep releases        : 5                                           ║
║  Firewall provider    : ufw OR firewalld                            ║
╚══════════════════════════════════════════════════════════════════════╝
 Preflight PASSED — 16/16 checks. Continue? [Y/n]:
```

Success / failure banners at end:
- DEPLOY SUCCESS → prints banner with rollback command hint.
- DEPLOY STOPPED → banner site untouched.
- AUTO-ROLLBACK COMPLETED → banner: status (pass/fail), current → prev, next steps advise.

---

## 10. Spec self-review checklist (passed)

Audited against Q&A answers, Section 1-5 user approvals, and contradictions:

- [x] Q1: Repo+main defaults, overridable
- [x] Q2: /opt/rasyatone/{releases,shared,current,venv}; user rasyatone_user; env /etc/rasyatone/static/rasyatone.env; logs /var/log/rasyatone (Section 1 user modification reflected — env file under static subdir confirmed in every place it's referenced: 2.3 paths, 3.3, Stage 8, systemd EnvironmentFile=, celery service, Gunicorn)
- [x] Q3: Domain rasyatone.alrasayt.com + Certbot auto SSL + email younisalbadawi@alrasyat.com (corrected from earlier alrasayt typo — Q3B user correction incorporated throughout section 3, Stage 16, preflight summary banner)
- [x] Q4A: PostgreSQL remote only, NO local install (user confirmed). All DB_* from env file
- [x] Q4B: Workers off by default, --with-workers flag installs Redis localhost 127.0.0.1-only + celery worker+beat systemd
- [x] Q5: Everything dynamic — Django settings/wsgi/manage.py auto-detected (Section 3.4, Stage 6) AND overridable CLI
- [x] Q6: Gunicorn socket + auto workers; Pre-migration backup AUTO default; logrotate & health default on with opt-out CLI
- [x] Q7: Filename `rasyatone_deploy.py`; default deploy action with optional `--stage preflight|deploy|rollback|check` overrides
- [x] Scope local + remote dual mode (Section 2.2, entire spec consistent)
- [x] Idempotency matrix 25 resources: complete coverage
- [x] Stage failure semantics correctly partition production-safe vs auto-rollback
- [x] Secrets NEVER logged: Section 8.2 scrub filter; Section 5.3 #1; env never os.environ'd
- [x] User's Section 2 correction: NO .env template written. Script validates existence but never writes env. Correct in #6 idempotency row, Preflight C, Stage 3.
- [x] All systemd units have the required hardening flags PrivateTmp, NoNewPrivileges, ProtectSystem strict; ReadWritePaths only needed dirs.
- [x] Rollback target auto-prune protection correct.
- [x] Nginx gate test `nginx -t` required before reload; certbot renew dry-run tested.
- [x] Preflight 16 checks all documented; fail remediation listed per check.

Self-review: Spec is internally consistent, matches Q&A answers exactly including all user corrections (env file path, email typo, no env template written, local+remote, release atomic B approach, Django dynamic layout, remote DB only). No contradictions found.
