# tuf-infra

Infrastructure configuration for The Universal Forums production environment.

- `compose.yml`: Frontend, API, CDN, CDC, and Health containers
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

Environment values and credentials belong only in `/srv/tuf/config` and must not be committed to Git.

## Keeping host infra in sync

Deploy entrypoints live in the host checkout at `/srv/tuf/infra/bin/*`.
GitHub Actions call those paths directly (for example
`sudo /srv/tuf/infra/bin/tuf-deploy-backend <sha>`). Copies under
`/usr/local/sbin` are thin `exec` wrappers only, so they cannot silently
drift from the checkout the way full script copies did.

On each push to `main` (when repository variable `PRODUCTION_DEPLOY_ENABLED`
is exactly `true`), workflow `Sync production infra` SSHes as `tuf-deploy` and
runs:

```sh
sudo /srv/tuf/infra/bin/tuf-sync-infra <git-sha>
```

That command:

- `git fetch` + detach `/srv/tuf/infra` to the exact SHA
- refreshes `/usr/local/sbin` wrappers, sudoers, and systemd units
- validates `compose.yml` against live `stack.env`
- never overwrites `/srv/tuf/config/*.env`

If `PRODUCTION_DEPLOY_ENABLED` is unset/false, the workflow **fails** instead of
quietly succeeding with no host update. The `tuf-infra` repo must also have the
same Tailscale + `TUF_DEPLOY_SSH_*` secrets as the app deploy workflows.

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
