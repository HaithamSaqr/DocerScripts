# Falcon Cloud ERP Provisioner

One-shot provisioner for a complete Falcon Cloud ERP stack on a single Linux host with Docker.

Three modes:

| Mode | What gets installed |
|---|---|
| `full` | MSSQL container + DB restored from `FalconTemplate.bak` + Falcon API + Falcon Frontend |
| `app`  | Falcon API + Falcon Frontend only — connects to an existing external SQL Server |
| `sql`  | MSSQL container + DB restored from `FalconTemplate.bak` only (no Falcon app) |

Each client gets its own isolated stack under `/opt/<client>/` with its own Docker network — multiple clients run side-by-side on one host without conflict.

---

## Quick start

### Interactive (asks for everything)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/falconclouderp/run.sh)
```

### Full stack, non-interactive

```bash
FALCON_MODE=full \
FALCON_CLIENT=binmesaad \
FALCON_DB=binmesaad \
FALCON_PASSWORD='F@lcon@0401!@#@@ForFalconDbP@ss' \
FALCON_PORT=5780 \
FALCON_API_PORT=5011 \
FALCON_FRONT_PORT=5023 \
FALCON_API_URL='https://appapi.client.com/api' \
FALCON_YES=1 \
bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/falconclouderp/run.sh)
```

### App only (existing external SQL)

```bash
FALCON_MODE=app \
FALCON_CLIENT=binmesaad \
FALCON_SQL_HOST=213.199.62.187 \
FALCON_SQL_PORT=5778 \
FALCON_DB=FalconCloudERPDBDemo \
FALCON_SQL_USER=Falconsa \
FALCON_SQL_PASS='F@lcon@0401!@#@@ForFalconDbP@ss' \
FALCON_API_PORT=5011 \
FALCON_FRONT_PORT=5023 \
FALCON_API_URL='https://appapi.client.com/api' \
FALCON_YES=1 \
bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/falconclouderp/run.sh)
```

### SQL only (no Falcon app)

```bash
FALCON_MODE=sql \
FALCON_CLIENT=binmesaad \
FALCON_DB=binmesaad \
FALCON_PASSWORD='F@lcon@0401!@#@@ForFalconDbP@ss' \
FALCON_PORT=5780 \
FALCON_YES=1 \
bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/falconclouderp/run.sh)
```

---

## Inputs by mode

| Field | Flag | Env var | full | app | sql |
|---|---|---|:---:|:---:|:---:|
| Mode | `-m`, `--mode` | `FALCON_MODE` | ✓ | ✓ | ✓ |
| Client name | `-c`, `--client` | `FALCON_CLIENT` | ✓ | ✓ | ✓ |
| Database name | `-d`, `--db` | `FALCON_DB` | ✓ | ✓ | ✓ |
| SA password | `-p`, `--password` | `FALCON_PASSWORD` | ✓ | — | ✓ |
| SQL host port | `-P`, `--port` | `FALCON_PORT` | ✓ | — | ✓ |
| API host port | `--api-port` | `FALCON_API_PORT` | ✓ | ✓ | — |
| Frontend host port | `--front-port` | `FALCON_FRONT_PORT` | ✓ | ✓ | — |
| Public API URL | `--api-url` | `FALCON_API_URL` | ✓ | ✓ | — |
| External SQL host | `--sql-host` | `FALCON_SQL_HOST` | — | ✓ | — |
| External SQL port | `--sql-port` | `FALCON_SQL_PORT` | — | ✓ | — |
| External SQL login | `--sql-user` | `FALCON_SQL_USER` | — | ✓ | — |
| External SQL password | `--sql-pass` | `FALCON_SQL_PASS` | — | ✓ | — |
| Skip confirmation | `-y`, `--yes` | `FALCON_YES=1` | ✓ | ✓ | ✓ |

Anything not supplied is prompted interactively.

---

## What gets created on the host

```
/opt/<client>/
├── docker-compose.yml
├── sql/                          (full + sql modes only)
│   ├── data/                     <- <DBNAME>.mdf, <DBNAME>_log.ldf
│   ├── log/
│   └── backup/
│       └── FalconTemplate.bak
└── falconapp/                    (full + app modes only)
    ├── etc/                      <- mounted as /etc/falconapp in containers
    └── uploads/                  <- mounted as /app/wwwroot/uploads in API
```

Container naming (per client):

| Service | Container | Default host port |
|---|---|---|
| SQL Server | `<client>_sql` | 5779 → 1433 |
| Falcon API | `<client>_api` | 5011 → 5001 |
| Falcon Frontend | `<client>_front` | 5023 → 80 |

Network: `<client>_net` (bridge, isolated per client).

---

## Folder template lives in the repo

```
opt/FalconCloudERPTemplate/
├── sql/
│   ├── data/.gitkeep
│   ├── log/.gitkeep
│   └── backup/
│       ├── README.md
│       └── FalconTemplate.bak          ← committed to the repo
└── falconapp/
    ├── etc/.gitkeep
    └── uploads/.gitkeep
```

When `run.sh` runs it:

1. Downloads the whole branch as a tarball from `https://github.com/<owner>/<repo>/archive/refs/heads/<branch>.tar.gz`
2. Extracts it to a temp directory
3. Copies `opt/FalconCloudERPTemplate/sql/` to `/opt/<client>/sql/` (modes that need SQL)
4. Copies `opt/FalconCloudERPTemplate/falconapp/` to `/opt/<client>/falconapp/` (modes that need the app)
5. Generates `docker-compose.yml`, starts the containers, restores the database, creates the `Falconsa` login, smoke-checks the API/Frontend

### Updating the template backup

```bash
cp /path/to/new/FalconTemplate.bak opt/FalconCloudERPTemplate/sql/backup/FalconTemplate.bak
git add opt/FalconCloudERPTemplate/sql/backup/FalconTemplate.bak
git commit -m "Update FalconTemplate backup"
git push origin falconclouderp
```

If your `.bak` is over 100 MB use Git LFS:

```bash
git lfs install
git lfs track "*.bak"
git add .gitattributes opt/FalconCloudERPTemplate/sql/backup/FalconTemplate.bak
git commit -m "Track backup with LFS"
git push origin falconclouderp
```

---

## Upgrading an existing client (safe, with backups)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/falconclouderp/upgrade.sh) \
  -c binmesaad
```

What `upgrade.sh` does:

1. Detects which containers exist for the client
2. (Default) Backs up every user database to `/opt/<client>/sql/backup/<db>_pre_upgrade_<TS>.bak`
3. Snapshots `/opt/<client>/falconapp/` to `/opt/<client>/falconapp_snapshot_<TS>.tar.gz`
4. `docker compose pull` (downloads new images)
5. `docker compose up -d` for the targeted services only
6. Probes API and Frontend ports for an HTTP response

Selective upgrade (e.g. only the API):

```bash
bash <(curl -fsSL .../upgrade.sh) -c binmesaad --services api
```

Skip the SQL backup (NOT recommended — only when you've already backed up externally):

```bash
bash <(curl -fsSL .../upgrade.sh) -c binmesaad --skip-db-backup
```

---

## Connecting from outside

### From SSMS / SQL client (full or sql mode)

```
Server name           : <server-ip>,5779
Authentication        : SQL Server Authentication
Login                 : sa  (or Falconsa)
Password              : <sa password>
Trust server certificate : ✓
```

### From the Falcon API container to SQL (full mode)

The API connects internally over the Docker network using the service name:

```
Data Source=<client>_sql,1433;Initial Catalog=<db>;uid=Falconsa;password=<sa>;Trust Server Certificate=true;
```

### From the Falcon frontend to the API

`API_URL` env var on the frontend container. Defaults to `http://<host-ip>:<api-port>/api`. Override with `--api-url` or `FALCON_API_URL` (use HTTPS only if you have a reverse proxy in front like Nginx or Traefik).

---

## Webhooks

The API container is configured with three webhook endpoints; defaults match the existing Falcon production URLs:

| Variable | Default | Override env |
|---|---|---|
| `Webhooks__Whatsapp` | `https://app.falcon-v.com/api/WbWebhooks` | `FALCON_WEBHOOK_WHATSAPP` |
| `Webhooks__Salla` | `https://app.falcon-v.com/api/WbStoreWebhooks/salla` | `FALCON_WEBHOOK_SALLA` |
| `Webhooks__Zid` | `https://app.falcon-v.com/api/WbStoreWebhooks/zid` | `FALCON_WEBHOOK_ZID` |

---

## Operating a client

```bash
CLIENT=binmesaad

# Status
(cd /opt/$CLIENT && sudo docker compose ps)

# Tail logs
sudo docker logs -f ${CLIENT}_sql
sudo docker logs -f ${CLIENT}_api
sudo docker logs -f ${CLIENT}_front

# Stop the whole stack
(cd /opt/$CLIENT && sudo docker compose down)

# Start
(cd /opt/$CLIENT && sudo docker compose up -d)

# Destroy completely (WARNING: deletes data too)
(cd /opt/$CLIENT && sudo docker compose down -v)
sudo rm -rf /opt/$CLIENT
```

---

## Requirements on the host

- Linux with `sudo`
- `docker` (Engine 20.10+) and `docker compose` v2 (or legacy `docker-compose`)
- `curl`, `tar`
- Outbound network access to `mcr.microsoft.com` and `hub.docker.com` for image pulls
- Ports in the chosen range available on the host (SQL, API, Frontend)

---

## Configurable environment variables

| Variable | Default | Purpose |
|---|---|---|
| `FALCON_MODE` | _required_ | `full` \| `app` \| `sql` |
| `FALCON_CLIENT` | _required_ | Client name (container + folder prefix) |
| `FALCON_DB` | _required for sql/full_ | Database name |
| `FALCON_PASSWORD` | _required for sql/full_ | SA password |
| `FALCON_PORT` | `5779` | SQL host port |
| `FALCON_API_PORT` | `5011` | Falcon API host port |
| `FALCON_FRONT_PORT` | `5023` | Falcon Frontend host port |
| `FALCON_API_URL` | _prompted_ | Public URL the frontend calls |
| `FALCON_SQL_HOST` | _required for app_ | External SQL hostname or IP |
| `FALCON_SQL_PORT` | `1433` | External SQL TCP port |
| `FALCON_SQL_USER` | `Falconsa` | External SQL login |
| `FALCON_SQL_PASS` | _required for app_ | External SQL password |
| `FALCON_APP_USER` | `Falconsa` | Login created in the local DB after restore |
| `FALCON_WEBHOOK_WHATSAPP` | `https://app.falcon-v.com/api/WbWebhooks` | API webhook URL |
| `FALCON_WEBHOOK_SALLA` | `https://app.falcon-v.com/api/WbStoreWebhooks/salla` | API webhook URL |
| `FALCON_WEBHOOK_ZID` | `https://app.falcon-v.com/api/WbStoreWebhooks/zid` | API webhook URL |
| `FALCON_MSSQL_IMAGE` | `mcr.microsoft.com/mssql/server:2025-latest` | MSSQL image |
| `FALCON_API_IMAGE` | `haithamsakr/falconerpapi:latest` | Falcon API image |
| `FALCON_FRONT_IMAGE` | `haithamsakr/falconerpangular:latest` | Falcon Frontend image |
| `FALCON_MSSQL_PID` | `Express` | MSSQL edition |
| `FALCON_WAIT_SECONDS` | `90` | Max seconds to wait for SQL readiness |
| `FALCON_REPO_OWNER` | `HaithamSaqr` | GitHub owner |
| `FALCON_REPO_NAME` | `DocerScripts` | GitHub repo |
| `FALCON_REPO_BRANCH` | `falconclouderp` | Branch to pull the tarball from |
| `FALCON_TEMPLATE_PATH` | `opt/FalconCloudERPTemplate` | Path inside the repo to copy from |
| `FALCON_YES` | `0` | Skip the final confirmation prompt |

---

## Notes

- **Path remapping is automatic.** A backup taken on Windows hard-codes a path like `C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA\db.mdf`, which does not exist inside a Linux container. `run.sh` reads `RESTORE FILELISTONLY` first, then emits `MOVE N'<logical>' TO N'/var/opt/mssql/data/<DBNAME>.mdf'` clauses for every data and log file. The full remap plan is printed before the restore runs.
- **Multiple files**: data files are renamed to `<DBNAME>.mdf`, `<DBNAME>_2.ndf`, …; log files to `<DBNAME>_log.ldf`, `<DBNAME>_log_2.ldf`, …
- **FILESTREAM (type `S`) backups are rejected** — FILESTREAM is not supported on Linux containers.
- **Full-text catalog files (type `F`)** are skipped with a warning.
- The restore uses `REPLACE`, so re-running with the same database name overwrites the existing one.
- **Express edition cap**: 10 GB per database. If your template exceeds this, set `FALCON_MSSQL_PID=Developer`.
- The script automatically creates a SQL login named `Falconsa` (override with `FALCON_APP_USER`) that matches the connection string used by the Falcon API container. You can still connect as `sa` for administration.
