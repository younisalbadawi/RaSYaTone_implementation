# RaSYaTone Django/PostgreSQL Installer Runbook
  
This repository contains a single installer script: `install.sh`. It provisions and/or deploys a Django app backed by PostgreSQL and served via Gunicorn behind Nginx, with optional TLS from Let’s Encrypt (Certbot).
  
This runbook is written for:
- **System administrators** operating the target Linux host
- **Implementation engineers** maintaining the Django codebase and supporting deployments
  
---
  
## What The Installer Does
  
At a high level, the installer is designed to be **interactive**, **fail-fast**, and **self-diagnosing**.
  
- Installs and configures PostgreSQL (database role, database, connectivity checks).
- Installs system dependencies (Python tooling, Nginx, Certbot, etc.).
- Creates/uses a dedicated **non-root service account** to run Gunicorn (least privilege).
- Deploys the Django app (typically into an `/opt/...` directory), prepares a virtualenv, and installs Python dependencies.
- Runs Django migrations with **live progress** and bounded **auto-heal** for common migration failure patterns.
- Configures systemd to keep the app running across reboots.
- Configures Nginx as a reverse proxy (Option A: Gunicorn binds to `127.0.0.1` or a Unix socket; Nginx listens on `80/443`).
- Optionally configures HTTPS via Certbot and ensures auto-renew is enabled.
- Configures firewall rules for `80/tcp` and `443/tcp` (with verification and fallbacks).
- Prints a **post-install summary** and persists it into a log file next to the script for later reference.
  
---
  
## How To Run
  
### Interactive Menu (recommended)
  
Run without arguments:
  
```bash
bash install.sh
```
  
### Direct Mode (automation-friendly)
  
The script supports direct flags for running individual phases:
  
```bash
bash install.sh --precheck-db
bash install.sh --precheck-app
bash install.sh --install-db
bash install.sh --install-app
```
  
### Diagnostic Mode (no changes)
  
Use this to collect diagnostics when the site is down or the deploy looks suspicious:
  
```bash
bash install.sh --doctor
```
  
---
  
## Key Outputs For Admins (Paths)
  
Exact names may depend on values entered during prompts (service name, domain, install dir).
  
### Systemd
  
- Service unit: `/etc/systemd/system/<service>.service`
- Status: `systemctl status <service> --no-pager`
- Logs: `journalctl -u <service> -n 200 --no-pager`
  
### Nginx
  
- Site conf: `/etc/nginx/conf.d/<service>.conf`
- Test config: `nginx -t`
- Reload: `systemctl reload nginx`
- Logs:
  - `/var/log/nginx/access.log`
  - `/var/log/nginx/error.log`
  
The generated Nginx config includes proxy buffer tuning to prevent:
  
```
upstream sent too big header while reading response header from upstream
```
  
### Certbot / TLS
  
- Certificate path: `/etc/letsencrypt/live/<domain>/fullchain.pem`
- Renew dry run: `certbot renew --dry-run`
  
### Installer Summary Log (persistent)
  
The script appends a post-install report next to `install.sh`:
  
- `./rasyatone_post_install_summary.log`
  
This file is intended to be kept as an operational handoff artifact for administrators.
  
### Temporary Debug Logs
  
The installer intentionally saves short-lived logs under `/tmp` for troubleshooting failures (spinner/probe/pip failures), for example:
  
- `/tmp/rasyatone_spin_*.log`
- `/tmp/rasyatone_probe_*.log`
- `/tmp/rasyatone_pip_*.log`
  
If the installer fails, look for the newest `/tmp/rasyatone_*` logs first.
  
---
  
## Security Model
  
- **Gunicorn runs as a dedicated non-root service account** (default is typically `rasyatone_app_user`).
- System-level operations (packages, firewall, `/etc/*` config, systemd changes) require root/sudo.
- Prefer a deployment directory owned by the service account (commonly `/opt/<app>`), so `git` operations can run as the service user and avoid “dubious ownership” failures.
- When Nginx is enabled, Gunicorn should bind to **localhost** (`127.0.0.1`) or a **Unix socket**, so the app is not directly exposed to the internet.
  
---
  
## Operational Verification Checklist
  
Run these after deployment (or during incident response).
  
### 1) Processes and services
  
```bash
systemctl status <service> --no-pager
systemctl status nginx --no-pager
```
  
### 2) Listeners
  
```bash
ss -lntp | egrep ':(80|443)\b' || true
ss -lntp | egrep ':(8000|8001|8080|<gunicorn_port>)\b' || true
```
  
If using a Unix socket, check:
  
```bash
ls -la /run/<service>/ || true
```
  
### 3) Local HTTP checks
  
```bash
curl -I http://127.0.0.1/ || true
curl -I http://<domain>/ || true
curl -Ik https://<domain>/ || true
```
  
### 4) Nginx config validity
  
```bash
nginx -t
```
  
### 5) TLS certificate presence
  
```bash
test -f /etc/letsencrypt/live/<domain>/fullchain.pem && echo "TLS OK" || echo "TLS missing"
```
  
---
  
## Django Migration Auto-Heal Behavior (What It Fixes / What It Won’t)
  
The installer includes bounded retry logic and auto-heal for common failure patterns, including:
  
- **Broken migration graph** (`NodeNotFoundError` / missing dependency nodes)
- **Schema drift** such as missing columns (`UndefinedColumn` / `ProgrammingError`)
- **Missing tables** (`UndefinedTable`)
  
There are failure classes that the installer will **not** try to “solve” automatically because it is unsafe or requires code decisions. Most importantly:
  
- Adding a **non-nullable field without a default** (Django will refuse to auto-migrate safely). The installer will stop and require the engineer to fix the model/migration properly.
  
Implementation engineer guidance:
- Always keep migrations committed and coherent before running the installer on a server.
- If the installer reports a non-automatable migration error, fix it in the codebase (nullable/default/data migration), re-deploy, and re-run the app install step.
  
---
  
## Common Failure Modes And Where To Look
  
### 502 Bad Gateway
  
Likely causes:
- Gunicorn not running or binding to a different port/socket than Nginx expects
- Permissions issue on the Unix socket
- App crash during startup (check systemd logs)
  
Commands:
  
```bash
journalctl -u <service> -n 200 --no-pager
tail -n 200 /var/log/nginx/error.log
nginx -t
```
  
If Nginx error log shows:
  
```
upstream sent too big header while reading response header from upstream
```
  
The installer already includes proxy buffer directives in the generated Nginx config.
  
### HTTPS not working / 443 closed
  
Likely causes:
- Firewall backend not enabled, or rules not applied correctly
- Certbot didn’t issue a certificate (DNS doesn’t point to the server)
  
Commands:
  
```bash
ss -lntp | egrep ':(443)\b' || true
ufw status 2>/dev/null || true
firewall-cmd --list-ports 2>/dev/null || true
getent hosts <domain> || true
```
  
If DNS resolves to a different IP than the server, Certbot will fail until DNS is corrected.
  
### Deployment succeeds but app is broken
  
Check:
- systemd logs: `journalctl -u <service>`
- Django logs in the service output (stack traces, import errors)
- DB connectivity errors in installer diagnostics / post-install summary
  
---
  
## Routine Maintenance Commands (Admin-Friendly)
  
### Restart app
  
```bash
systemctl restart <service>
systemctl status <service> --no-pager
```
  
### Tail logs
  
```bash
journalctl -u <service> -f
tail -f /var/log/nginx/error.log
```
  
### Re-run doctor diagnostics
  
```bash
bash install.sh --doctor
```
  
### Certbot renewal check
  
```bash
certbot renew --dry-run
systemctl list-timers | grep certbot || true
```
  
---
  
## Engineer Notes: Safe Re-Deploy / Upgrade Procedure
  
Recommended approach for upgrades:
  
1. Ensure the target branch/tag is correct and migrations are committed.
2. Re-run the “app install” step via the installer (interactive menu or `--install-app`).
3. Validate:
   - migrations completed cleanly
   - systemd service is healthy
   - Nginx config is valid and reloaded
   - HTTPS is still valid (if enabled)
  
If an upgrade includes DB schema changes:
- Confirm `makemigrations` is already done in CI/dev and committed.
- Avoid generating migrations directly on production unless you are intentionally doing so and understand the implications.
  
