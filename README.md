# tuf-infra

Infrastructure configuration for The Universal Forums production environment.

- `compose.yml`: Frontend, API, Thumbnail Worker, CDN, CDC, and Health containers
- `compose.canary.yml`: Isolated canary project; CDC is opt-in
- `systemd/`: Unit for managing the Compose stack with the server lifecycle
- `bin/`: Frontend and backend image deployment scripts
- `sudoers/`: Deployment permissions for the `tuf-deploy` account
- `config/`: Example server environment files
- `nginx/`: Root-owned Nginx snippets installed on the production host

Frontend and backend images are stored in GHCR. The server pulls and runs these images instead of building them locally. Host Nginx handles public HTTPS traffic, while MySQL, Redis, and Elasticsearch remain host services.

## Server layout

```text
/srv/tuf/
├── config/
│   ├── stack.env
│   ├── common.env
│   ├── redis.env
│   ├── storage.env
│   ├── api.env
│   ├── cdn.env
│   ├── cdc.env
│   ├── health.env
│   ├── thumbnail-worker.env
│   ├── canary/
│   │   ├── stack.env
│   │   └── ...
│   └── certs/elasticsearch.crt
├── data/
│   ├── cache/
│   ├── thumbnails/
│   ├── logs/
│   ├── cdn-temp/
│   ├── backups/
│   └── mapping-hashes/
└── infra/                 # checkout of this repository
```

`tuf-sync-infra` installs `thumbnail-worker.env` from its non-secret defaults when
the file is first introduced and adds `THUMBNAIL_RENDER_MODE=local` to an existing
API config. Switch the production API to `queue` only after the worker healthcheck
passes.

## Thumbnail worker rollout

Deploy a dual-mode backend image first while production still has
`THUMBNAIL_RENDER_MODE=local`. After this infra revision is synced, start and test
the worker without moving HTTP traffic to it:

```sh
sudo tuf-recreate thumbnail-worker
curl --fail http://127.0.0.1:3891/health
sudo docker compose --env-file /srv/tuf/config/stack.env \
  -f /srv/tuf/infra/compose.yml run --rm --no-deps thumbnail-worker \
  node dist/externalServices/thumbnailWorker/smoke.js
```

Only after both checks pass, set `THUMBNAIL_RENDER_MODE=queue` in
`/srv/tuf/config/api.env` and run `sudo tuf-recreate api`. Roll back without
stopping the worker by restoring `THUMBNAIL_RENDER_MODE=local` and recreating only
the API. HTTP render timeouts do not remove queued jobs or their spool inputs.

Environment values and credentials belong only in `/srv/tuf/config` and must not be committed to Git.

## MySQL roles

Containers use `network_mode: host` and connect to `127.0.0.1`. Do not use MySQL `root` as `DB_USER`. Five accounts, provisioned by `bin/tuf-provision-mysql-users`:

| Role | Config | Privileges |
| --- | --- | --- |
| API, migrate | `common.env` `DB_USER` | `ALL` on `DB_DATABASE` and `DB_LOGGING_DATABASE` |
| Dump / restore (API `BackupService` only) | `backup.env` `BACKUP_DB_USER` | Schema `ALL` plus `SET_USER_ID` and `SYSTEM_USER` (apply dump `DEFINER`) |
| CDN | `cdn.env` `DB_USER` (overrides common) | DML on those schemas |
| Health | `health.env` `DB_USER` (overrides common) | DML on `DB_DATABASE` (probes + latency samples) |
| CDC | `cdc.env` `CDC_DB_USER` | `REPLICATION SLAVE`/`CLIENT` + `SELECT` on `DB_DATABASE` |

`root@localhost` is socket-only (`sudo mysql`). After filling the five passwords, run:

```sh
sudo /srv/tuf/infra/bin/tuf-provision-mysql-users
```

then recreate the stack so containers reload env files.

## Keeping host infra in sync

Deploy entrypoints live in the host checkout at `/srv/tuf/infra/bin/*`.
GitHub Actions call those paths directly (for example
`sudo /srv/tuf/infra/bin/tuf-deploy-backend <sha>`). Copies under
`/usr/local/sbin` are thin `exec` wrappers only, so they cannot silently
drift from the checkout the way full script copies did.

After the `CI` workflow validates a push to `main` (or a `workflow_dispatch`
targeting `main`), its `sync-production` job runs only when repository variable
`PRODUCTION_DEPLOY_ENABLED` is exactly `true`. It SSHes as `tuf-deploy` and
runs the exact validated commit:

```sh
sudo /srv/tuf/infra/bin/tuf-sync-infra <git-sha>
```

That command:

- `git fetch` + detach `/srv/tuf/infra` to the exact SHA
- refreshes `/usr/local/sbin` wrappers, sudoers, and systemd units
- validates `compose.yml` against live `stack.env`
- reloads `tuf-stack.service` when it was already active
- leaves an inactive stack inactive; infra sync never enables or starts it
- restores the previous infra SHA and host wiring if validation or reload fails
- never overwrites `/srv/tuf/config/*.env`

## Auto-submission runtime configuration

The root-only `bin/tuf-configure-auto-submission` tool updates the six production
API values required by TUFReplay auto-submission. It accepts a one-time temporary
input file, validates every value, updates `/srv/tuf/config/api.env` atomically,
and restores the previous configuration if validation or Compose rendering fails.
It deliberately does not belong to the `tuf-deploy` sudo allowlist.

After this infra revision has been synced, run the workstation launcher:

```sh
bin/tuf-send-auto-submission-config --enable
```

It reads the two existing mutually authenticated tokens from the home server,
creates a mode-600 temporary input file on TUF, and opens an interactive SSH
session for the TUF administrator's sudo password. The input file is removed in
all cases. Omit `--enable` to configure the integration while keeping automatic
submissions disabled. Afterwards, dispatch the normal backend deployment workflow
to apply the configuration through the existing migration and service-reload path.

### Recovering an older host configuration

If the first `main` sync exits with runtime configuration errors, run this once
from an administrator workstation before retrying the GitHub Actions workflow:

```sh
bin/tuf-bootstrap-tuf-runtime-defaults
```

It prompts for the TUF sudo password and inserts only the documented non-secret
defaults required by the current infra schema. It does not replace any existing
value and does not reload or deploy a service.

If `PRODUCTION_DEPLOY_ENABLED` is unset/false, validation still runs but the
production sync job is skipped. Manual infra syncs use the same `CI` workflow
dispatch, so validation cannot be bypassed. The `tuf-infra` repo must also have
the same Tailscale + `TUF_DEPLOY_SSH_*` secrets as the app deploy workflows.

Production app deploy wrappers require `tuf-stack.service` to be both enabled
and active before they pull images, run migrations, or change image tags. They
exit with status `78` without changing production when the unit is not ready.
The wrappers update tags and run migrations, but reconcile long-running
containers only through `systemctl reload tuf-stack.service`. The unit validates
the runtime configuration and Compose model before every start and reload.

**One-time enablement** (root on the host), before the first Actions sync can
succeed — allowlist the checkout paths and install wrappers:

```sh
cd /srv/tuf/infra
git pull
visudo -cf sudoers/tuf-deploy
install -m 0440 -o root -g root sudoers/tuf-deploy /etc/sudoers.d/tuf-deploy
# Optional immediate wrapper refresh without waiting for Actions:
./bin/tuf-sync-infra "$(git rev-parse HEAD)"
```

Ensure `origin` for `/srv/tuf/infra` is fetchable as root (deploy key or
equivalent). The sync script fails loudly if fetch cannot see the requested SHA.

Until app repos pick up workflows that call `/srv/tuf/infra/bin/...`, you can
still deploy via the wrappers once `tuf-sync-infra` has rewritten
`/usr/local/sbin/tuf-deploy-*` to `exec` the checkout scripts.

Install Docker Engine and Compose once as root with `bin/tuf-install-docker`. The
script deliberately does not add `tuf-deploy` to the `docker` group; deployments
continue through the root-owned, sudo-allowlisted scripts.

## Image prune cron

SHA-tagged deploys leave old GHCR layers under containerd until pruned. Install a
daily cleanup that keeps the newest image plus two older tags per repo (for
rollback), and never removes tags referenced by running containers or
`stack.env` / canary `stack.env`:

```sh
sudo /srv/tuf/infra/bin/tuf-prune-images install-cron
```

That writes `/etc/cron.d/tuf-prune-images` (daily 03:17) and
`/usr/local/sbin/tuf-prune-images`. Run once immediately with
`sudo tuf-prune-images`. Override retention with
`TUF_PRUNE_KEEP_OLDER_TAGS` (default `2`).

`config/stack.env` must point `GOOGLE_APPLICATION_CREDENTIALS_SOURCE_PATH` at a
Google service-account JSON file. `tuf-init` installs it under
`/srv/tuf/config/secrets` with read access limited to root and the runtime GID.
Canary data is stored separately in `/srv/tuf-canary/data`.

## CI runner failover (self-hosted ↔ ubuntu-latest)

Workflows use `runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '["ubuntu-latest"]') }}`.
A timer on the production host probes the laptop over Tailscale and the GitHub
org runner API, then sets org variable `CI_RUNS_ON` to either
`["self-hosted","linux","tuf"]` or `["ubuntu-latest"]`.

One-time on **tuf-main-server** (after this repo is synced):

```sh
sudo cp /srv/tuf/infra/config/ci-runner-failover.env.example \
  /srv/tuf/config/ci-runner-failover.env
sudo chmod 600 /srv/tuf/config/ci-runner-failover.env
# edit GITHUB_TOKEN=… (org runners read + variables write)
sudo systemctl enable --now tuf-ci-runner-failover.timer
sudo systemctl start tuf-ci-runner-failover.service
journalctl -u tuf-ci-runner-failover.service -n 50 --no-pager
```

`tuf-sync-infra` installs the unit/timer and `/usr/local/sbin/tuf-ci-runner-failover`.

## Nginx CSP

The production CSP is stored in `nginx/tuf-csp.conf`. It permits the frontend to
connect to TUFHelperLite only on `127.0.0.1` ports `32145` through `32155`.
`tuf-init` installs that source snippet at `/usr/local/share/tuf/tuf-csp.conf`
so `/usr/local/sbin/tuf-install-nginx-csp` remains self-contained after installation.

Apply it from a trusted checkout as root:

```sh
sudo bin/tuf-install-nginx-csp
```

The installer requires exactly one existing `Content-Security-Policy` directive
in both `/etc/nginx/sites-available/tuforums.com` and
`/etc/nginx/sites-enabled/tuforums.com`. It backs up both files and the previous
snippet under `/var/backups/tuf/nginx-csp-<UTC timestamp>`, installs the managed
snippet, runs `nginx -t`, and reloads Nginx only after validation succeeds. A
failed validation restores the backup automatically.

To roll back a successful installation, copy the two saved site files (and the
saved snippet when present) from the reported backup directory to their original
paths. Remove `/etc/nginx/snippets/tuf-csp.conf` when the backup contains no
previous snippet, then run `nginx -t && systemctl reload nginx`.
