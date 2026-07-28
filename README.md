# tuf-infra

Infrastructure configuration for The Universal Forums production environment.

- `compose.yml`: Frontend, API, CDN, CDC, and Health containers
- `compose.canary.yml`: Isolated canary project; CDC is opt-in
- `systemd/`: Unit for managing the Compose stack with the server lifecycle
- `bin/`: Frontend and backend image deployment scripts
- `sudoers/`: Deployment permissions for the `tuf-deploy` account
- `config/`: Example server environment files

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

Install Docker Engine and Compose once as root with `bin/tuf-install-docker`. The
script deliberately does not add `tuf-deploy` to the `docker` group; deployments
continue through the root-owned, sudo-allowlisted scripts.

`config/stack.env` must point `GOOGLE_APPLICATION_CREDENTIALS_SOURCE_PATH` at a
Google service-account JSON file. `tuf-init` installs it under
`/srv/tuf/config/secrets` with read access limited to root and the runtime GID.
Canary data is stored separately in `/srv/tuf-canary/data`.
