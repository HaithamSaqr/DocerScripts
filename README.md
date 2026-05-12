# Falcon MSSQL Provisioner

One-shot provisioner that:

1. Creates a per-client folder layout under `/opt/<client>/sql/{data,log,backup}`
2. Generates a `docker-compose.yml` for an MSSQL 2025 container named after the client
3. Boots the container, waits for SQL Server, and restores `FalconTemplate.bak` into a database with the name you choose

## One-line run from GitHub

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/run.sh)
```

The script will prompt for:

- **Client name** — used as container name and as the root folder under `/opt`
- **Database name** — the name the restored database will be registered as
- **SA password** — must satisfy MSSQL complexity rules
- **Host port** — exposed on the host, mapped to `1433` inside the container (default `5779`)

## Backup file

The script looks for the backup file in this order:

1. `./FalconTemplate.bak` in the current directory (use this when running locally)
2. `FALCON_BACKUP_URL` environment variable
3. `<FALCON_REPO_RAW_URL>/FalconTemplate.bak` (defaults to the raw URL of this repo)

For files larger than 100 MB, host the `.bak` outside the repo (e.g. a GitHub Release asset or object storage) and point `FALCON_BACKUP_URL` at it:

```bash
FALCON_BACKUP_URL="https://github.com/<user>/<repo>/releases/download/v1/FalconTemplate.bak" \
  bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/run.sh)
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
| `FALCON_REPO_RAW_URL` | `https://raw.githubusercontent.com/CHANGE_ME/CHANGE_ME/main` | Base URL when fetching the backup |
| `FALCON_BACKUP_URL` | `${FALCON_REPO_RAW_URL}/FalconTemplate.bak` | Full URL to the backup file |
| `FALCON_MSSQL_IMAGE` | `mcr.microsoft.com/mssql/server:2025-latest` | MSSQL container image |
| `FALCON_MSSQL_PID` | `Express` | MSSQL edition (`Express`, `Developer`, `Standard`, `Enterprise`) |
| `FALCON_WAIT_SECONDS` | `90` | Max seconds to wait for SQL Server readiness |

## Notes

- **Path remapping is automatic.** A backup taken on Windows hard-codes a path like `C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA\db.mdf`, which does not exist inside a Linux container — a naive `RESTORE` would fail with `operating system error 2 (The system cannot find the file specified)`. The script avoids this by reading `RESTORE FILELISTONLY` first, then building `MOVE N'<logical>' TO N'/var/opt/mssql/data/<DBNAME>.mdf'` clauses for every data and log file in the backup. It prints the full remap plan before executing the restore so you can see exactly what is happening.
- Multiple data files (if the source backup has more than one) are written as `<DBNAME>.mdf`, `<DBNAME>_2.ndf`, `<DBNAME>_3.ndf`, …
- Multiple log files (rare) are written as `<DBNAME>_log.ldf`, `<DBNAME>_log_2.ldf`, …
- FILESTREAM (type `S`) backups are rejected — FILESTREAM is not supported on Linux containers.
- Full-text catalog files (type `F`, deprecated since SQL Server 2008) are skipped with a warning.
- The restore uses `REPLACE`, so re-running with the same database name overwrites the existing one.
