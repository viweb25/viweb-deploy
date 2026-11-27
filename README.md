# viweb-deploy

Everything needed to run Vision Studio in production on one cloud server (our Hostzop
VPS), and to ship new versions to it.

- `compose.yaml`: the production stack (web, api, worker, migrate, inference,
  training-worker, postgres, redis).
- `Caddyfile`: HTTPS, the React app, and the `/api` route to the backend.
- `versions.env`: **which build of each service is live.** Changing this file and
  merging it is how we release.
- `scripts/`: server setup, deploy, backup and release helpers.
- `.github/workflows/deploy.yml`: deploys automatically when `main` changes.

The app code lives in four other repositories. Each one builds its own Docker image in
GitHub Actions on every merge to `main`:

| Repository | Image | What it is |
|---|---|---|
| viweb-frontend | `ghcr.io/viweb25/viweb-frontend` | React app + Caddy web server |
| viweb-ai | `ghcr.io/viweb25/viweb-ai` | Business API (FastAPI) and Celery worker |
| viweb-db | `ghcr.io/viweb25/viweb-db` | Database migrations (Alembic) |
| viweb-inference | `ghcr.io/viweb25/viweb-inference` | YOLO inference API and training worker |

## How a change reaches production

```text
 feature branch ──PR──▶ CI (lint, tests, build) ──merge──▶ main
                                                            │
                                   CI builds image  ghcr.io/viweb25/<repo>:sha-<commit>
                                                            │
 weekly (or hotfix): scripts/release.sh pins the new tags in versions.env
                                                            │
                     PR in viweb-deploy ──review──▶ merge to main
                                                            │
             Deploy workflow: copy files to server ▶ scripts/deploy.sh on the server
                  1. pull images   2. back up database   3. run migrations
                  4. start new containers   5. check https://DOMAIN/health/live
```

Every image is tagged with the commit it was built from, so production always runs an
exact, known version of each repo, and a rollback is just the previous `versions.env`.

## One-time setup

You need: the server's root SSH access, a domain name, and admin rights on the GitHub
organisation.

### 1. Recommended server size

| Use | vCPU | RAM | Disk |
|---|---|---|---|
| Pilot (a few customers, CPU training) | 4 | 8 GB | 80 GB SSD |
| Growing (several trainings a day) | 8 | 16 GB | 160 GB SSD |

Training on CPU is slow. When customers train often, move `training-worker` to a
separate GPU server (it only needs the database and the two shared folders).

### 2. Create the deploy key (on your laptop)

```bash
ssh-keygen -t ed25519 -N "" -C github-actions-deploy -f viweb_deploy_key
```

This makes `viweb_deploy_key` (private: goes into GitHub) and `viweb_deploy_key.pub`
(public: goes onto the server). Do not commit either file.

### 3. Prepare the server

```bash
scp scripts/server-setup.sh root@SERVER_IP:/root/
ssh root@SERVER_IP "bash /root/server-setup.sh '$(cat viweb_deploy_key.pub)'"
```

The script installs Docker, creates a `deploy` user, turns on the firewall (only ports
22, 80 and 443), enables automatic security updates and fail2ban, creates `/opt/viweb`,
and schedules a nightly database backup.

Also add your own public key to `/home/deploy/.ssh/authorized_keys` so you can log in
as `deploy` to look at logs.

### 4. Point the domain

In your DNS provider, create an **A record** for the app hostname (for example
`app.yourcompany.com`) pointing at the server IP. Caddy requests the HTTPS certificate
on the first deploy, which only works once DNS points at the server.

### 5. Secrets on the server

```bash
ssh deploy@SERVER_IP
cd /opt/viweb
nano .env              # paste .env.example, then fill in DOMAIN, ACME_EMAIL, POSTGRES_PASSWORD
chmod 600 .env
openssl rand -hex 32   # use this as POSTGRES_PASSWORD
```

For workspace invitations and password recovery, set `SMTP_HOST`, `SMTP_FROM`, and
`SMTP_PORT` (default 587) in the server's `.env`. The API uses SMTP with STARTTLS.
Set `SMTP_USERNAME` and `SMTP_PASSWORD` when your relay requires authentication.
Use an approved sender for your relay. Links use the configured application domain.

Let the server pull private images: create a GitHub token (classic, scope
`read:packages` only) and run, as `deploy`:

```bash
docker login ghcr.io -u <your-github-username>   # paste the token as the password
```

### 6. GitHub settings

In **viweb-deploy → Settings → Secrets and variables → Actions**, add:

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | server IP |
| `DEPLOY_SSH_KEY` | contents of `viweb_deploy_key` (the private file) |
| `DEPLOY_KNOWN_HOSTS` | output of `ssh-keyscan -t ed25519 SERVER_IP` |

In **Settings → Environments**, create `production` and add required reviewers. Every
deploy then waits for one of them to approve it.

In each app repository, protect `main` (**Settings → Branches**): require a pull
request and require the `CI` check to pass. Nobody pushes straight to `main`.

### 7. First deploy

Run `scripts/release.sh` (next section) to pin real versions, merge that, or open
**Actions → Deploy → Run workflow**. Then open `https://<your domain>` and create the
first account.

## Weekly release

Releases go out once a week, for example every Tuesday morning.

```bash
git pull
scripts/release.sh                 # pins latest main of all four repos
git checkout -b release/$(date +%F)
git commit -am "Release $(date +%F)"
git push -u origin HEAD            # open a PR; the diff shows exactly what changes
```

Before merging, write in the PR what changed in each repo. Merge, approve the
`production` environment, and watch the Deploy run. It ends with "Deployed." when
`https://DOMAIN/health/live` answers.

**Hotfix** (any day): merge the fix in its repo, wait for its CI, then
`scripts/release.sh api` (or `frontend`, `db`, `inference`) to move only that service.

## Rollback

In GitHub, open the release PR and click **Revert**, then merge the revert PR. The
previous tags deploy again.

Database migrations only move forward. A rollback is safe only if the newer migration
is backward compatible: add columns and tables first; remove old ones in a later
release, after no running code uses them. See the handbook's database chapter.

A full restore (last resort, loses data written since the backup):

```bash
cd /opt/viweb
ls backups/
docker compose --env-file versions.env --env-file .env exec -T postgres \
  pg_restore --clean --if-exists -U viweb -d viweb < backups/db-YYYYMMDD-HHMMSS.dump
```

## Day-to-day operations

All commands run as `deploy` in `/opt/viweb`. Add this alias to `~/.bashrc`:

```bash
alias dc='docker compose --env-file versions.env --env-file .env'
```

| Task | Command |
|---|---|
| What's running | `dc ps` |
| Follow API logs | `dc logs -f --tail 100 api` |
| Training logs | `dc logs -f training-worker` |
| Restart one service | `dc restart api` |
| What was deployed when | `cat deployments.log` |
| Manual backup | `scripts/backup.sh` |
| Database shell | `dc exec postgres psql -U viweb viweb` |
| Disk usage | `df -h && docker system df` |

## Backups

- Nightly at 02:30 and before every deploy, `scripts/backup.sh` writes
  `backups/db-*.dump` and keeps 14 days.
- **These copies are on the same server.** If the server is lost, so are they. Copy
  them elsewhere every night, for example to object storage with `rclone`, or to
  another machine with `rsync`.
- Uploaded photos and trained models are in the Docker volumes `viweb_uploads` and
  `viweb_training-runs`. Back them up too, weekly at least:
  `docker run --rm -v viweb_uploads:/data -v $PWD/backups:/out alpine tar czf /out/uploads-$(date +%F).tgz -C /data .`
- Test a restore on a spare machine once a month. A backup you have never restored is
  not a backup.

## Security checklist

- [ ] Only ports 22, 80, 443 open (`ufw status`).
- [ ] Root login and password SSH disabled after your key works.
- [ ] `.env` is `chmod 600` and never committed.
- [ ] `POSTGRES_PASSWORD` is random (32+ hex characters).
- [ ] `main` is protected in all five repositories.
- [ ] The `production` environment requires approval.
- [ ] Backups are copied off the server and a restore was tested.
- [ ] Uptime monitoring checks `https://DOMAIN/health/live` (UptimeRobot, Better Stack
      or similar) and alerts the team.
