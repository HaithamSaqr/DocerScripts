# Falcon MSSQL Provisioner

One-shot provisioner that:

1. Creates a per-client folder layout under `/opt/<client>/sql/{data,log,backup}`
2. Generates a `docker-compose.yml` for an MSSQL 2025 container named after the client
3. Boots the container, waits for SQL Server, and restores `FalconTemplate.bak` into a database with the name you choose

## One-line run from GitHub

### Interactive (asks for every value)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/sqlexpress25/run.sh)
```

### Non-interactive (everything in one command — no prompts)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/sqlexpress25/run.sh) \
  --client escan_const --db escandb --password 'S0meStr0ng!Pass' --port 5779 --yes
```

Or using env vars (better — the password stays out of `history` and `ps`):

```bash
FALCON_CLIENT=escan_const \
FALCON_DB=escandb \
FALCON_PASSWORD='S0meStr0ng!Pass' \
FALCON_PORT=5779 \
FALCON_YES=1 \
  bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/sqlexpress25/run.sh)
```

### Inputs

The script prompts for any value not supplied via flag or env var:

| Prompt | Flag | Env var |
|---|---|---|
| Client name (container + `/opt/<x>` folder) | `-c`, `--client` | `FALCON_CLIENT` |
| Database name (after restore) | `-d`, `--db` | `FALCON_DB` |
| SA password (MSSQL complexity rules) | `-p`, `--password` | `FALCON_PASSWORD` |
| Host port mapped to container `1433` | `-P`, `--port` | `FALCON_PORT` |
| Skip the final confirmation prompt | `-y`, `--yes` | `FALCON_YES=1` |

## Backup file lives in the repo

The folder structure (and the backup itself) is committed to the repo at:

```
opt/FalconTemplate/sql/
├── data/.gitkeep         <- empty, materializes /opt/<client>/sql/data/
├── log/.gitkeep          <- empty, materializes /opt/<client>/sql/log/
└── backup/
    ├── README.md
    └── FalconTemplate.bak    <- you commit this
```

When `run.sh` runs, it:

1. Downloads the whole branch as a tarball from `https://github.com/<owner>/<repo>/archive/refs/heads/<branch>.tar.gz`
2. Extracts the tarball to a temp directory
3. Copies `opt/FalconTemplate/sql/` to `/opt/<client>/sql/` on the server
4. The `.bak` is already inside `/opt/<client>/sql/backup/` after the copy — no extra download needed
5. The container restore reads it from `/var/opt/mssql/backup/FalconTemplate.bak` via the bind mount

To update the template, replace the file in the repo and push:

```bash
cp /path/to/new/FalconTemplate.bak opt/FalconTemplate/sql/backup/FalconTemplate.bak
git add opt/FalconTemplate/sql/backup/FalconTemplate.bak
git commit -m "Update FalconTemplate backup"
git push origin sqlexpress25
```

### Size limit

GitHub rejects any single file over 100 MB unless tracked with Git LFS. If your `.bak` is larger:

```bash
git lfs install
git lfs track "*.bak"
git add .gitattributes opt/FalconTemplate/sql/backup/FalconTemplate.bak
git commit -m "Track backup with LFS"
git push origin sqlexpress25
```

## Requirements on the host

- Linux with `sudo`
- `docker` (Engine 20.10+) and `docker compose` v2 (or legacy `docker-compose`)
- `curl`
- Outbound network access to `mcr.microsoft.com` for the image pull

## What gets created

```
/opt/<client>/
├── docker-compose.yml
└── sql/
    ├── data/         <- <DBNAME>.mdf, <DBNAME>_log.ldf
    ├── log/
    └── backup/
        └── FalconTemplate.bak
```

Volume ownership is set to `10001:10001` (the uid the MSSQL container runs as) with mode `770`.

## Connecting

```
Server=<host>,<port>
User Id=sa
Password=<your sa password>
Database=<your db name>
TrustServerCertificate=true
```

## Operating the container later

```bash
# Tail logs
sudo docker logs -f <client>

# Stop
(cd /opt/<client> && sudo docker compose down)

# Start
(cd /opt/<client> && sudo docker compose up -d)
```

## Configurable environment variables

| Variable | Default | Purpose |
|---|---|---|
| `FALCON_REPO_OWNER`  | `HaithamSaqr`  | GitHub owner of the repo |
| `FALCON_REPO_NAME`   | `DocerScripts` | GitHub repo name |
| `FALCON_REPO_BRANCH` | `sqlexpress25` | Branch to pull the tarball from |
| `FALCON_TARBALL_URL` | `https://github.com/<owner>/<name>/archive/refs/heads/<branch>.tar.gz` | Override the full tarball URL (e.g. for a tag) |
| `FALCON_TEMPLATE_PATH` | `opt/FalconTemplate/sql` | Path inside the repo to copy to `/opt/<client>/sql/` |
| `FALCON_MSSQL_IMAGE` | `mcr.microsoft.com/mssql/server:2025-latest` | MSSQL container image |
| `FALCON_MSSQL_PID`   | `Express` | MSSQL edition (`Express`, `Developer`, `Standard`, `Enterprise`) |
| `FALCON_WAIT_SECONDS` | `90` | Max seconds to wait for SQL Server readiness |

## Notes

- **Path remapping is automatic.** A backup taken on Windows hard-codes a path like `C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA\db.mdf`, which does not exist inside a Linux container — a naive `RESTORE` would fail with `operating system error 2 (The system cannot find the file specified)`. The script avoids this by reading `RESTORE FILELISTONLY` first, then building `MOVE N'<logical>' TO N'/var/opt/mssql/data/<DBNAME>.mdf'` clauses for every data and log file in the backup. It prints the full remap plan before executing the restore so you can see exactly what is happening.
- Multiple data files (if the source backup has more than one) are written as `<DBNAME>.mdf`, `<DBNAME>_2.ndf`, `<DBNAME>_3.ndf`, …
- Multiple log files (rare) are written as `<DBNAME>_log.ldf`, `<DBNAME>_log_2.ldf`, …
- FILESTREAM (type `S`) backups are rejected — FILESTREAM is not supported on Linux containers.
- Full-text catalog files (type `F`, deprecated since SQL Server 2008) are skipped with a warning.
- The restore uses `REPLACE`, so re-running with the same database name overwrites the existing one.
