# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Deployment configuration only — no application source. It is the Docker Compose stack that runs the Walls HR platform on a single host. Application images are pulled from ECR (`081653452993.dkr.ecr.us-east-1.amazonaws.com/wallstz/*`) and built elsewhere; this repo owns the compose file, the nginx edge config, TLS/certbot wiring, and the DB backup sidecar.

## Commands

There is no build/test/lint tooling. Everything is docker compose against [docker-compose.yaml](docker-compose.yaml):

```bash
# ECR login required before pulling app images
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin 081653452993.dkr.ecr.us-east-1.amazonaws.com

docker compose pull && docker compose up -d
docker compose up -d --build db_backup     # db_backup is the only locally-built image
docker compose logs -f <service>
docker compose ps
```

Validate nginx changes before they take effect — a bad config takes the whole edge down:

```bash
docker compose exec nginx-go nginx -t
docker compose exec nginx-go nginx -s reload   # nginx.conf is mounted read-only; reload, don't restart
```

Issue/renew certificates (certbot has no long-running command; run it one-off):

```bash
docker compose run --rm certbot certonly --webroot -w /var/www/certbot -d <domain>
docker compose run --rm certbot renew
docker compose exec nginx-go nginx -s reload   # always reload after renewal
```

Trigger a DB backup manually instead of waiting for cron:

```bash
docker compose exec db_backup /usr/local/bin/backup.sh
```

## Architecture

Two independent nginx instances, deliberately separate:

- **`nginx-go`** (ports 80/443) — the public edge. Config is the single monolithic [nginx.conf](nginx.conf) mounted over `/etc/nginx/nginx.conf`. Terminates TLS and virtual-hosts three domains onto upstreams named by **container name**, not service name:
  - `hr.walls.co.tz` → `walls_hr_terminal:4000` (Angular SSR frontend; has static-asset caching, `/ngsw-worker.js` no-cache, CSP header)
  - `hr.api.walls.co.tz` → `walls_hr_app:2400` (HR API; plus `/events` SSE with buffering fully disabled and `/ws` WebSocket upgrade)
  - `media.api.walls.co.tz` → `walls_media_app:1500` (uploads; 2G body limit, hour-long send timeouts)
- **`nginx`** (port 490) — phpMyAdmin only, separate [db_nginx/default.conf](db_nginx/default.conf), FastCGI to the `phpmyadmin` fpm container over a shared `phpmyadmin` volume.

`notification_app` (:1700) is on the network but not proxied — it is reached internally only.

All services share the `walls_net` bridge network and `expose` (not publish) their ports. Only nginx-go (80/443) and the phpMyAdmin nginx (490) are reachable from the host — mariadb is deliberately **not** published, so reach it via `docker compose exec mariadb mysql ...` or phpMyAdmin rather than a host-side client.

Startup ordering is healthcheck-gated: mariadb runs the image's `healthcheck.sh --connect --innodb_initialized`, and `hr_app`, `phpmyadmin`, `nginx`, and `db_backup` wait on `condition: service_healthy`. `nginx-go` depends on all three proxied app containers because [nginx.conf](nginx.conf) resolves upstreams by container name at config-load time — omit one and nginx-go exits with "host not found in upstream". Every long-running service is `restart: unless-stopped`; `certbot` intentionally is not, since it is invoked one-off.

Certbot and nginx-go share the `./certbot` directory from the host: `certbot/www` is the ACME webroot (each :80 vhost serves `/.well-known/acme-challenge/` from it before redirecting to https), and `certbot/conf` is letsencrypt's `/etc/letsencrypt` mounted into nginx as `/etc/nginx/ssl`, so cert paths in nginx.conf read `/etc/nginx/ssl/live/<domain>/`.

`db_backup` is a small Alpine image ([db_backup/Dockerfile](db_backup/Dockerfile)) running dcron. [entrypoint.sh](db_backup/entrypoint.sh) installs a crontab for 02:00 and 14:00 UTC (override with `BACKUP_CRON`); [backup.sh](db_backup/backup.sh) does `mysqldump --all-databases` and uploads gzipped to `s3://$S3_BUCKET/$S3_PREFIX/` as STANDARD_IA.

Two things to know before editing it. Alpine's `dcron` propagates the daemon's environment to cron jobs (unlike vixie-cron/cronie), which is why `backup.sh` sees the `env_file` credentials and the venv `PATH` without any extra plumbing — don't "fix" this by re-exporting env into the crontab. And backups fail *open*: crond stays up when a run fails, so the container keeps running. The `last_backup_success` marker file plus the compose healthcheck are what surface a silently failing backup — `docker compose ps` shows `db_backup` unhealthy after 13h without a successful run.

## Restoring a backup

```bash
aws s3 ls s3://$S3_BUCKET/mariadb-backups/
aws s3 cp s3://$S3_BUCKET/mariadb-backups/<file>.sql.gz .
gunzip -c <file>.sql.gz | docker compose exec -T mariadb mariadb -u root -p<password>
```

The dumps are `--all-databases`, which **includes the `mysql` system schema** — restoring one replaces the target server's users and grants with the source server's. The running server keeps its in-memory credentials until it restarts, then starts accepting the *dump's* root password instead of the target's. Plan for that when restoring onto a host whose DB password differs from the dump's, and update the root `.env` and `backup_config/.env` to match.

Note that the `mariadb:latest` server image no longer ships the `mysql`/`mysqldump` symlinks (use `mariadb`/`mariadb-dump` there); the Alpine `mariadb-client` package in the db_backup image still provides both names, which is what [backup.sh](db_backup/backup.sh) relies on.

## Configuration and secrets

Every `.env` is gitignored (`**/.env`); the per-service directories are committed with placeholder files (`hold.txt`, `consave.text`) purely to keep the directory in git. A working host needs these created by hand:

| File | Consumed by |
|---|---|
| `.env` (repo root) | mariadb — `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD` (also interpolated into the compose file) |
| `hr_config/.env` | `hr_app` |
| `hr_terminal_config/.env` | `hr_terminal_app` |
| `media_config/.env` | `media_app` |
| `notifications_config/.env` | `notification_app` |
| `backup_config/.env` | `db_backup` — see [backup_config/.env.example](backup_config/.env.example) |

`backup_config/.env` duplicates the MariaDB root credentials from the root `.env`; changing the DB password means changing both.

## Conventions worth knowing

- CORS is handled by the backend applications, not nginx. The `if ($request_method = 'OPTIONS')` preflight blocks in nginx.conf are commented out on purpose (see commits `32ea4f8` → `4c94414`) because they double-set headers the backends already emit. Don't re-enable them without confirming the backend stopped sending them.
- Rate-limit zones are defined once in the `http` block (`upload` 10r/m, `api` 100r/m, `stream` 30r/m) and applied per-location.
- MySQL is pinned to `+03:00` (EAT) via [mysql/conf.d/timezone.cnf](mysql/conf.d/timezone.cnf); backup cron times are UTC.
- The compose file has no top-level `version:` key — it targets the Compose spec (v2 CLI), which is what makes long-form `depends_on.condition` available. Don't re-add it.
