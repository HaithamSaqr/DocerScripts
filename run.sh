#!/usr/bin/env bash
# Falcon Cloud ERP Provisioner
#
# Three modes:
#   full  : MSSQL + DB restore + Falcon API + Falcon Frontend
#   app   : Falcon API + Falcon Frontend only (connects to existing external SQL)
#   sql   : MSSQL + DB restore only (no Falcon app)
#
# Interactive (asks for everything):
#   bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/falconclouderp/run.sh)
#
# Non-interactive (full stack on one host):
#   FALCON_MODE=full \
#   FALCON_CLIENT=binmesaad FALCON_DB=binmesaad FALCON_PASSWORD='SaStr0ng!' \
#   FALCON_PORT=5780 FALCON_API_PORT=5011 FALCON_FRONT_PORT=5023 \
#   FALCON_API_URL='https://appapi.client.com/api' FALCON_YES=1 \
#     bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/falconclouderp/run.sh)
#
# Non-interactive (app only, external SQL):
#   FALCON_MODE=app \
#   FALCON_CLIENT=binmesaad \
#   FALCON_SQL_HOST=213.199.62.187 FALCON_SQL_PORT=5778 \
#   FALCON_DB=FalconCloudERPDBDemo FALCON_SQL_USER=Falconsa \
#   FALCON_SQL_PASS='AppPass!' \
#   FALCON_API_PORT=5011 FALCON_FRONT_PORT=5023 \
#   FALCON_API_URL='https://appapi.client.com/api' FALCON_YES=1 \
#     bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/falconclouderp/run.sh)
#
# Flags > env vars > interactive prompt.

set -euo pipefail

# ---------- configuration ----------
REPO_OWNER="${FALCON_REPO_OWNER:-HaithamSaqr}"
REPO_NAME="${FALCON_REPO_NAME:-DocerScripts}"
REPO_BRANCH="${FALCON_REPO_BRANCH:-falconclouderp}"
TARBALL_URL="${FALCON_TARBALL_URL:-https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz}"
TEMPLATE_PATH_IN_REPO="${FALCON_TEMPLATE_PATH:-opt/FalconCloudERPTemplate}"
BACKUP_FILE_NAME="FalconTemplate.bak"

MSSQL_IMAGE="${FALCON_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2025-latest}"
MSSQL_PID="${FALCON_MSSQL_PID:-Express}"
API_IMAGE="${FALCON_API_IMAGE:-haithamsakr/falconerpapi:latest}"
FRONT_IMAGE="${FALCON_FRONT_IMAGE:-haithamsakr/falconerpangular:latest}"

WAIT_SECONDS="${FALCON_WAIT_SECONDS:-90}"
APP_USER_NAME="${FALCON_APP_USER:-Falconsa}"

# Webhooks (defaults match the original stack; override per client if needed)
WEBHOOK_WHATSAPP="${FALCON_WEBHOOK_WHATSAPP:-https://app.falcon-v.com/api/WbWebhooks}"
WEBHOOK_SALLA="${FALCON_WEBHOOK_SALLA:-https://app.falcon-v.com/api/WbStoreWebhooks/salla}"
WEBHOOK_ZID="${FALCON_WEBHOOK_ZID:-https://app.falcon-v.com/api/WbStoreWebhooks/zid}"

# ---------- CLI args ----------
CLI_MODE=""
CLI_CLIENT=""
CLI_DB=""
CLI_PASSWORD=""
CLI_PORT=""
CLI_API_PORT=""
CLI_FRONT_PORT=""
CLI_API_URL=""
CLI_SQL_HOST=""
CLI_SQL_PORT=""
CLI_SQL_USER=""
CLI_SQL_PASS=""
ASSUME_YES="${FALCON_YES:-0}"

usage() {
    cat <<EOF
Usage: run.sh [options]

Modes (--mode / FALCON_MODE):
  full   MSSQL + DB restore + Falcon API + Falcon Frontend (single host)
  app    Falcon API + Falcon Frontend (use existing external SQL)
  sql    MSSQL + DB restore only

Common options:
  -m, --mode       MODE     One of: full | app | sql
  -c, --client     NAME     Client name (used for container/folder prefix)
  -y, --yes                 Skip the final confirmation prompt
  -h, --help                Show this help

SQL options (full | sql):
  -d, --db         NAME     Database name to restore as
  -p, --password   SECRET   SA password
  -P, --port       PORT     Host port for SQL (default 5779)

App options (full | app):
      --api-port   PORT     Host port for Falcon API (default 5011)
      --front-port PORT     Host port for Falcon Frontend (default 5023)
      --api-url    URL      Public URL the frontend calls

External SQL (app mode only):
      --sql-host   HOST     External SQL hostname or IP
      --sql-port   PORT     External SQL TCP port
      --sql-user   USER     External SQL login
      --sql-pass   SECRET   External SQL password
                            (--db is reused for the database name)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)        CLI_MODE="$2";       shift 2 ;;
        -c|--client)      CLI_CLIENT="$2";     shift 2 ;;
        -d|--db)          CLI_DB="$2";         shift 2 ;;
        -p|--password)    CLI_PASSWORD="$2";   shift 2 ;;
        -P|--port)        CLI_PORT="$2";       shift 2 ;;
        --api-port)       CLI_API_PORT="$2";   shift 2 ;;
        --front-port)     CLI_FRONT_PORT="$2"; shift 2 ;;
        --api-url)        CLI_API_URL="$2";    shift 2 ;;
        --sql-host)       CLI_SQL_HOST="$2";   shift 2 ;;
        --sql-port)       CLI_SQL_PORT="$2";   shift 2 ;;
        --sql-user)       CLI_SQL_USER="$2";   shift 2 ;;
        --sql-pass)       CLI_SQL_PASS="$2";   shift 2 ;;
        -y|--yes)         ASSUME_YES=1;        shift ;;
        -h|--help)        usage; exit 0 ;;
        --mode=*)         CLI_MODE="${1#*=}";       shift ;;
        --client=*)       CLI_CLIENT="${1#*=}";     shift ;;
        --db=*)           CLI_DB="${1#*=}";         shift ;;
        --password=*)     CLI_PASSWORD="${1#*=}";   shift ;;
        --port=*)         CLI_PORT="${1#*=}";       shift ;;
        --api-port=*)     CLI_API_PORT="${1#*=}";   shift ;;
        --front-port=*)   CLI_FRONT_PORT="${1#*=}"; shift ;;
        --api-url=*)      CLI_API_URL="${1#*=}";    shift ;;
        --sql-host=*)     CLI_SQL_HOST="${1#*=}";   shift ;;
        --sql-port=*)     CLI_SQL_PORT="${1#*=}";   shift ;;
        --sql-user=*)     CLI_SQL_USER="${1#*=}";   shift ;;
        --sql-pass=*)     CLI_SQL_PASS="${1#*=}";   shift ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# Precedence: flag > env var > empty (will trigger prompt)
MODE="${CLI_MODE:-${FALCON_MODE:-}}"
CLIENT_NAME="${CLI_CLIENT:-${FALCON_CLIENT:-}}"
DB_NAME="${CLI_DB:-${FALCON_DB:-}}"
SA_PASSWORD="${CLI_PASSWORD:-${FALCON_PASSWORD:-}}"
SQL_HOST_PORT="${CLI_PORT:-${FALCON_PORT:-}}"
API_HOST_PORT="${CLI_API_PORT:-${FALCON_API_PORT:-}}"
FRONT_HOST_PORT="${CLI_FRONT_PORT:-${FALCON_FRONT_PORT:-}}"
API_PUBLIC_URL="${CLI_API_URL:-${FALCON_API_URL:-}}"
EXT_SQL_HOST="${CLI_SQL_HOST:-${FALCON_SQL_HOST:-}}"
EXT_SQL_PORT="${CLI_SQL_PORT:-${FALCON_SQL_PORT:-}}"
EXT_SQL_USER="${CLI_SQL_USER:-${FALCON_SQL_USER:-}}"
EXT_SQL_PASS="${CLI_SQL_PASS:-${FALCON_SQL_PASS:-}}"

# ---------- colors ----------
if [[ -t 1 ]]; then
    C_RESET="\033[0m"; C_BOLD="\033[1m"
    C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_RED="\033[31m"; C_CYAN="\033[36m"
else
    C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

info()  { echo -e "${C_CYAN}[i]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
error() { echo -e "${C_RED}[x]${C_RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

# ---------- preflight ----------
[[ $EUID -eq 0 ]] || warn "Not running as root. sudo will be used for privileged steps."
command -v docker >/dev/null 2>&1 || die "docker is not installed."
command -v curl   >/dev/null 2>&1 || die "curl is not installed."
command -v tar    >/dev/null 2>&1 || die "tar is not installed."

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    die "docker compose (v2) or docker-compose is required."
fi

# ---------- prompts ----------
echo -e "${C_BOLD}============================================${C_RESET}"
echo -e "${C_BOLD} Falcon Cloud ERP Provisioner${C_RESET}"
echo -e "${C_BOLD}============================================${C_RESET}"

prompt_required() {
    local var_name="$1" prompt_text="$2" default="${3:-}" value=""
    while [[ -z "$value" ]]; do
        if [[ -n "$default" ]]; then
            read -r -p "$(echo -e "${C_BOLD}${prompt_text}${C_RESET} [${default}]: ")" value
            value="${value:-$default}"
        else
            read -r -p "$(echo -e "${C_BOLD}${prompt_text}${C_RESET}: ")" value
        fi
        [[ -z "$value" ]] && warn "Value is required."
    done
    printf -v "$var_name" '%s' "$value"
}

prompt_secret() {
    local var_name="$1" prompt_text="$2" value=""
    while [[ -z "$value" ]]; do
        read -r -s -p "$(echo -e "${C_BOLD}${prompt_text}${C_RESET}: ")" value
        echo
        [[ -z "$value" ]] && warn "Password is required."
    done
    printf -v "$var_name" '%s' "$value"
}

# Mode selection
while [[ -z "$MODE" || ( "$MODE" != "full" && "$MODE" != "app" && "$MODE" != "sql" ) ]]; do
    [[ -n "$MODE" ]] && warn "Invalid mode '${MODE}'. Choose: full | app | sql"
    read -r -p "$(echo -e "${C_BOLD}Mode${C_RESET} [full | app | sql]: ")" MODE
done

# Client name is always required
[[ -z "$CLIENT_NAME" ]] && prompt_required CLIENT_NAME "Client name (container + folder prefix)"

# sanitize client name
SAFE_CLIENT="$(echo "$CLIENT_NAME" | tr -c 'A-Za-z0-9_-' '_' | sed 's/^_*//; s/_*$//')"
[[ -z "$SAFE_CLIENT" ]] && die "Client name became empty after sanitization."
[[ "$SAFE_CLIENT" != "$CLIENT_NAME" ]] && warn "Client name sanitized to: ${SAFE_CLIENT}"

# Mode-specific prompts
NEEDS_SQL=0
NEEDS_APP=0
case "$MODE" in
    full) NEEDS_SQL=1; NEEDS_APP=1 ;;
    sql)  NEEDS_SQL=1; NEEDS_APP=0 ;;
    app)  NEEDS_SQL=0; NEEDS_APP=1 ;;
esac

if [[ $NEEDS_SQL -eq 1 ]]; then
    [[ -z "$DB_NAME"        ]] && prompt_required DB_NAME        "Database name (target name after restore)" "$SAFE_CLIENT"
    [[ -z "$SA_PASSWORD"    ]] && prompt_secret   SA_PASSWORD    "SA password (min 8 chars, mixed complexity)"
    [[ -z "$SQL_HOST_PORT"  ]] && prompt_required SQL_HOST_PORT  "SQL host port" "5779"
fi

if [[ $NEEDS_APP -eq 1 ]]; then
    [[ -z "$API_HOST_PORT"   ]] && prompt_required API_HOST_PORT   "Falcon API host port"      "5011"
    [[ -z "$FRONT_HOST_PORT" ]] && prompt_required FRONT_HOST_PORT "Falcon Frontend host port" "5023"

    if [[ "$MODE" == "app" ]]; then
        [[ -z "$EXT_SQL_HOST" ]] && prompt_required EXT_SQL_HOST  "External SQL host (IP or DNS)"
        [[ -z "$EXT_SQL_PORT" ]] && prompt_required EXT_SQL_PORT  "External SQL port" "1433"
        [[ -z "$DB_NAME"      ]] && prompt_required DB_NAME       "External database name"
        [[ -z "$EXT_SQL_USER" ]] && prompt_required EXT_SQL_USER  "External SQL login" "$APP_USER_NAME"
        [[ -z "$EXT_SQL_PASS" ]] && prompt_secret   EXT_SQL_PASS  "External SQL password"
    fi

    # default API_URL — derived from primary host IP and api port
    if [[ -z "$API_PUBLIC_URL" ]]; then
        guess_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
        [[ -z "$guess_ip" ]] && guess_ip="<host>"
        prompt_required API_PUBLIC_URL "Public API URL the frontend will call" "http://${guess_ip}:${API_HOST_PORT}/api"
    fi
fi

# Derived names
SQL_CONTAINER="${SAFE_CLIENT}_sql"
API_CONTAINER="${SAFE_CLIENT}_api"
FRONT_CONTAINER="${SAFE_CLIENT}_front"
NETWORK_NAME="${SAFE_CLIENT}_net"
BASE_DIR="/opt/${SAFE_CLIENT}"
SQL_DATA_DIR="${BASE_DIR}/sql/data"
SQL_LOG_DIR="${BASE_DIR}/sql/log"
SQL_BACKUP_DIR="${BASE_DIR}/sql/backup"
APP_ETC_DIR="${BASE_DIR}/falconapp/etc"
APP_UPLOADS_DIR="${BASE_DIR}/falconapp/uploads"

# Connection string per mode
if [[ "$MODE" == "app" ]]; then
    CONN_DATA_SOURCE="${EXT_SQL_HOST},${EXT_SQL_PORT}"
    CONN_USER="$EXT_SQL_USER"
    CONN_PASS="$EXT_SQL_PASS"
else
    # full mode → API reaches SQL via Docker DNS (same compose network)
    CONN_DATA_SOURCE="${SQL_CONTAINER},1433"
    CONN_USER="$APP_USER_NAME"
    CONN_PASS="$SA_PASSWORD"
fi
CONNECTION_STRING="Data Source=${CONN_DATA_SOURCE};Initial Catalog=${DB_NAME};Integrated Security=false;Trust Server Certificate=true;uid=${CONN_USER};password=${CONN_PASS};"

# ---------- confirmation ----------
echo
info "Summary:"
echo "  Mode             : ${MODE}"
echo "  Client (prefix)  : ${SAFE_CLIENT}"
[[ $NEEDS_SQL -eq 1 ]] && {
    echo "  SQL container    : ${SQL_CONTAINER}"
    echo "  SQL host port    : ${SQL_HOST_PORT} -> 1433"
    echo "  DB name          : ${DB_NAME}"
}
[[ $NEEDS_APP -eq 1 ]] && {
    echo "  API container    : ${API_CONTAINER}   (port ${API_HOST_PORT} -> 5001)"
    echo "  Front container  : ${FRONT_CONTAINER} (port ${FRONT_HOST_PORT} -> 80)"
    echo "  API public URL   : ${API_PUBLIC_URL}"
}
[[ "$MODE" == "app" ]] && {
    echo "  External SQL     : ${EXT_SQL_HOST}:${EXT_SQL_PORT} / ${DB_NAME} (user: ${EXT_SQL_USER})"
}
echo "  Compose network  : ${NETWORK_NAME}"
echo "  Base dir         : ${BASE_DIR}"
echo
if [[ "$ASSUME_YES" == "1" || "${ASSUME_YES,,}" == "true" || "${ASSUME_YES,,}" == "yes" ]]; then
    info "Auto-confirming (--yes)."
else
    read -r -p "Proceed? [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || die "Aborted."
fi

# ---------- materialize folder layout from repo tarball ----------
info "Downloading repo tarball: ${TARBALL_URL}"
TMP_REPO_ROOT="$(mktemp -d -t falcon_repo_XXXXXX)"
trap 'rm -rf "$TMP_REPO_ROOT"' EXIT

if ! curl -fL --progress-bar -o "${TMP_REPO_ROOT}/repo.tar.gz" "$TARBALL_URL"; then
    die "Failed to download tarball from ${TARBALL_URL}"
fi
tar -xzf "${TMP_REPO_ROOT}/repo.tar.gz" -C "$TMP_REPO_ROOT" --strip-components=1 \
    || die "Failed to extract repo tarball."
ok "Repo extracted to ${TMP_REPO_ROOT}"

SOURCE_TEMPLATE="${TMP_REPO_ROOT}/${TEMPLATE_PATH_IN_REPO}"
[[ -d "$SOURCE_TEMPLATE" ]] || die "Template folder not found in repo at: ${TEMPLATE_PATH_IN_REPO}"

# SQL template requirements (only when we provision SQL)
if [[ $NEEDS_SQL -eq 1 ]]; then
    SOURCE_BACKUP="${SOURCE_TEMPLATE}/sql/backup/${BACKUP_FILE_NAME}"
    [[ -f "$SOURCE_BACKUP" ]] || die "Backup file missing in repo: ${TEMPLATE_PATH_IN_REPO}/sql/backup/${BACKUP_FILE_NAME}"
    info "Template backup found ($(du -h "$SOURCE_BACKUP" | cut -f1))."
fi

info "Materializing ${BASE_DIR} from repo template ..."
sudo mkdir -p "$BASE_DIR"

# Copy sql/ subtree only if we need SQL
if [[ $NEEDS_SQL -eq 1 ]]; then
    if command -v rsync >/dev/null 2>&1; then
        sudo rsync -a --delete "${SOURCE_TEMPLATE}/sql/" "${BASE_DIR}/sql/"
    else
        sudo rm -rf "${BASE_DIR}/sql"
        sudo cp -r "${SOURCE_TEMPLATE}/sql" "${BASE_DIR}/sql"
    fi
    sudo rm -f "${BASE_DIR}/sql/data/.gitkeep" "${BASE_DIR}/sql/log/.gitkeep" \
               "${BASE_DIR}/sql/backup/README.md"
fi

# Copy falconapp/ subtree if we need the app
if [[ $NEEDS_APP -eq 1 ]]; then
    if command -v rsync >/dev/null 2>&1; then
        sudo rsync -a "${SOURCE_TEMPLATE}/falconapp/" "${BASE_DIR}/falconapp/"
    else
        sudo mkdir -p "${BASE_DIR}/falconapp"
        sudo cp -r "${SOURCE_TEMPLATE}/falconapp/." "${BASE_DIR}/falconapp/"
    fi
    sudo rm -f "${BASE_DIR}/falconapp/etc/.gitkeep" "${BASE_DIR}/falconapp/uploads/.gitkeep"
fi
ok "Folder structure materialized."

# ---------- write docker-compose.yml ----------
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
info "Writing ${COMPOSE_FILE} ..."

# Build YAML in pieces depending on mode
{
    echo "version: '3.8'"
    echo
    echo "services:"

    if [[ $NEEDS_SQL -eq 1 ]]; then
        cat <<EOF
  ${SQL_CONTAINER}:
    image: ${MSSQL_IMAGE}
    container_name: ${SQL_CONTAINER}
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "${SA_PASSWORD}"
      MSSQL_PID: "${MSSQL_PID}"
    ports:
      - "${SQL_HOST_PORT}:1433"
    volumes:
      - ${SQL_DATA_DIR}:/var/opt/mssql/data
      - ${SQL_LOG_DIR}:/var/opt/mssql/log
      - ${SQL_BACKUP_DIR}:/var/opt/mssql/backup
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped

EOF
    fi

    if [[ $NEEDS_APP -eq 1 ]]; then
        # depends_on block only when we also own the local SQL container
        if [[ "$MODE" == "full" ]]; then
            DEPENDS_LINE=$'    depends_on:\n      - '"${SQL_CONTAINER}"
        else
            DEPENDS_LINE=""
        fi

        cat <<EOF
  ${API_CONTAINER}:
    image: ${API_IMAGE}
    container_name: ${API_CONTAINER}
    ports:
      - "${API_HOST_PORT}:5001"
    environment:
      ConnectionStrings__DefaultConnection: "${CONNECTION_STRING}"
      Webhooks__Whatsapp: "${WEBHOOK_WHATSAPP}"
      Webhooks__Salla: "${WEBHOOK_SALLA}"
      Webhooks__Zid: "${WEBHOOK_ZID}"
    volumes:
      - ${APP_ETC_DIR}:/etc/falconapp
      - ${APP_UPLOADS_DIR}:/app/wwwroot/uploads
    healthcheck:
      disable: true
${DEPENDS_LINE}
    networks:
      ${NETWORK_NAME}:
        aliases:
          - falconerpapi
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 512M

  ${FRONT_CONTAINER}:
    image: ${FRONT_IMAGE}
    container_name: ${FRONT_CONTAINER}
    ports:
      - "${FRONT_HOST_PORT}:80"
    environment:
      API_URL: "${API_PUBLIC_URL}"
    volumes:
      - ${APP_ETC_DIR}:/etc/falconapp
    depends_on:
      - ${API_CONTAINER}
    healthcheck:
      disable: true
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

EOF
    fi

    echo "networks:"
    echo "  ${NETWORK_NAME}:"
    echo "    driver: bridge"
} | sudo tee "$COMPOSE_FILE" >/dev/null

ok "Compose file written."

# ---------- ownership & permissions ----------
if [[ $NEEDS_SQL -eq 1 ]]; then
    info "Setting permissions on ${BASE_DIR}/sql ..."
    sudo chown -R 10001:10001 "${BASE_DIR}/sql"
    sudo chmod -R 770 "${BASE_DIR}/sql"
fi
if [[ $NEEDS_APP -eq 1 ]]; then
    info "Setting permissions on ${BASE_DIR}/falconapp ..."
    sudo mkdir -p "${APP_ETC_DIR}" "${APP_UPLOADS_DIR}"
    # API/front containers typically run as non-root uid 1000
    sudo chown -R 1000:1000 "${BASE_DIR}/falconapp"
    sudo chmod -R 775 "${BASE_DIR}/falconapp"
fi
ok "Permissions set."

# ---------- start containers ----------
info "Starting containers ..."
( cd "$BASE_DIR" && sudo $COMPOSE_CMD up -d )
ok "Containers started."

# ---------- SQL: wait, restore, create app login ----------
if [[ $NEEDS_SQL -eq 1 ]]; then
    info "Waiting for SQL Server to become ready (timeout ${WAIT_SECONDS}s) ..."
    SQLCMD_PATH=""
    for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
        if sudo docker exec "$SQL_CONTAINER" test -x "$candidate" 2>/dev/null; then
            SQLCMD_PATH="$candidate"
            break
        fi
    done
    [[ -z "$SQLCMD_PATH" ]] && die "sqlcmd not found inside ${SQL_CONTAINER}."

    SQLCMD_OPTS="-C -N -S localhost -U sa -P \"${SA_PASSWORD}\""
    READY=0
    for ((i=1; i<=WAIT_SECONDS; i++)); do
        if sudo docker exec "$SQL_CONTAINER" bash -c "$SQLCMD_PATH $SQLCMD_OPTS -Q 'SELECT 1' -h -1" >/dev/null 2>&1; then
            READY=1; break
        fi
        sleep 1
    done
    [[ $READY -eq 1 ]] || die "SQL Server not ready in ${WAIT_SECONDS}s. Check: docker logs ${SQL_CONTAINER}"
    ok "SQL Server is ready."

    info "Inspecting backup file list (resolving original physical paths) ..."
    FILELIST_RAW="$(sudo docker exec "$SQL_CONTAINER" bash -c \
        "$SQLCMD_PATH $SQLCMD_OPTS -Q \"SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK = N'/var/opt/mssql/backup/${BACKUP_FILE_NAME}'\" -W -s '|' -h -1" 2>&1)" \
        || die "RESTORE FILELISTONLY failed:\n${FILELIST_RAW}"

    FILELIST_OUT="$(echo "$FILELIST_RAW" \
        | grep -v '^[[:space:]]*$' \
        | grep -vi 'rows affected' \
        | grep -vE '^-+(\||$)' \
        | awk -F'|' 'NF >= 7')"

    [[ -z "$FILELIST_OUT" ]] && die "RESTORE FILELISTONLY returned no usable rows. Raw output:\n${FILELIST_RAW}"

    MOVE_CLAUSES=""
    DATA_COUNT=0
    LOG_COUNT=0
    declare -a PARSED_PREVIEW=()

    while IFS='|' read -r LOGICAL_NAME PHYSICAL_NAME TYPE REST; do
        LOGICAL_NAME="$(echo "$LOGICAL_NAME"   | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        PHYSICAL_NAME="$(echo "$PHYSICAL_NAME" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        TYPE="$(echo "$TYPE"                   | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "$LOGICAL_NAME" || -z "$TYPE" ]] && continue
        case "$TYPE" in
            D)
                DATA_COUNT=$((DATA_COUNT+1))
                if [[ $DATA_COUNT -eq 1 ]]; then
                    NEW_PATH="/var/opt/mssql/data/${DB_NAME}.mdf"
                else
                    NEW_PATH="/var/opt/mssql/data/${DB_NAME}_${DATA_COUNT}.ndf"
                fi
                ;;
            L)
                LOG_COUNT=$((LOG_COUNT+1))
                if [[ $LOG_COUNT -eq 1 ]]; then
                    NEW_PATH="/var/opt/mssql/data/${DB_NAME}_log.ldf"
                else
                    NEW_PATH="/var/opt/mssql/data/${DB_NAME}_log_${LOG_COUNT}.ldf"
                fi
                ;;
            S) die "Backup contains FILESTREAM ('${LOGICAL_NAME}'). Not supported on Linux." ;;
            F) warn "Skipping full-text catalog file '${LOGICAL_NAME}'."; continue ;;
            *) warn "Unknown file type '${TYPE}'. Skipping."; continue ;;
        esac
        [[ -n "$MOVE_CLAUSES" ]] && MOVE_CLAUSES+=", "
        MOVE_CLAUSES+="MOVE N'${LOGICAL_NAME}' TO N'${NEW_PATH}'"
        PARSED_PREVIEW+=("  [${TYPE}] ${LOGICAL_NAME}  (was: ${PHYSICAL_NAME})  ->  ${NEW_PATH}")
    done <<< "$FILELIST_OUT"

    [[ -z "$MOVE_CLAUSES" ]] && die "No MOVE clauses built. Raw: ${FILELIST_RAW}"
    [[ $DATA_COUNT -eq 0 ]] && die "Backup has no data files."

    info "Path remapping plan:"
    for line in "${PARSED_PREVIEW[@]}"; do echo "$line"; done

    info "Restoring database as [${DB_NAME}] ..."
    RESTORE_SQL="RESTORE DATABASE [${DB_NAME}] FROM DISK = N'/var/opt/mssql/backup/${BACKUP_FILE_NAME}' WITH ${MOVE_CLAUSES}, REPLACE, RECOVERY, STATS = 10"
    sudo docker exec "$SQL_CONTAINER" bash -c \
        "$SQLCMD_PATH $SQLCMD_OPTS -Q \"${RESTORE_SQL}\"" \
        || die "RESTORE failed. Plan was:\n$(printf '%s\n' "${PARSED_PREVIEW[@]}")"
    ok "Restore completed."

    # Create application login (Falconsa by default) — matches the original connection string
    info "Creating application login [${APP_USER_NAME}] ..."
    CREATE_LOGIN_SQL="SET NOCOUNT ON; IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'${APP_USER_NAME}') CREATE LOGIN [${APP_USER_NAME}] WITH PASSWORD = N'${SA_PASSWORD}', CHECK_POLICY = OFF; USE [${DB_NAME}]; IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'${APP_USER_NAME}') CREATE USER [${APP_USER_NAME}] FOR LOGIN [${APP_USER_NAME}]; ALTER ROLE [db_owner] ADD MEMBER [${APP_USER_NAME}];"
    sudo docker exec "$SQL_CONTAINER" bash -c \
        "$SQLCMD_PATH $SQLCMD_OPTS -Q \"${CREATE_LOGIN_SQL}\"" \
        || warn "Could not create [${APP_USER_NAME}] — Falcon API may need [sa] credentials instead."

    info "Verifying database state ..."
    sudo docker exec "$SQL_CONTAINER" bash -c \
        "$SQLCMD_PATH $SQLCMD_OPTS -Q \"SELECT name, state_desc FROM sys.databases WHERE name = N'${DB_NAME}'\""
fi

# ---------- App smoke checks ----------
if [[ $NEEDS_APP -eq 1 ]]; then
    info "Waiting up to 60s for ${API_CONTAINER} to become reachable on host port ${API_HOST_PORT} ..."
    API_READY=0
    for i in $(seq 1 60); do
        # Any HTTP response (even 404) means the service is up
        code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://localhost:${API_HOST_PORT}/" 2>/dev/null || echo 000)"
        if [[ "$code" != "000" && "$code" != "" ]]; then
            API_READY=1; break
        fi
        sleep 1
    done
    [[ $API_READY -eq 1 ]] && ok "API responding on http://localhost:${API_HOST_PORT}/ (HTTP ${code})" \
                           || warn "API did not respond on http://localhost:${API_HOST_PORT}/. Check: sudo docker logs ${API_CONTAINER}"

    info "Waiting up to 30s for ${FRONT_CONTAINER} on host port ${FRONT_HOST_PORT} ..."
    FRONT_READY=0
    for i in $(seq 1 30); do
        fcode="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://localhost:${FRONT_HOST_PORT}/" 2>/dev/null || echo 000)"
        if [[ "$fcode" != "000" && "$fcode" != "" ]]; then
            FRONT_READY=1; break
        fi
        sleep 1
    done
    [[ $FRONT_READY -eq 1 ]] && ok "Frontend responding on http://localhost:${FRONT_HOST_PORT}/ (HTTP ${fcode})" \
                             || warn "Frontend did not respond. Check: sudo docker logs ${FRONT_CONTAINER}"
fi

# ---------- summary ----------
echo
echo -e "${C_GREEN}${C_BOLD}============================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD} Done — Falcon Cloud ERP (${MODE}) ready${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}============================================${C_RESET}"
echo "Client           : ${SAFE_CLIENT}"
echo "Base dir         : ${BASE_DIR}"
echo "Compose file     : ${COMPOSE_FILE}"
[[ $NEEDS_SQL -eq 1 ]] && {
    echo "SQL container    : ${SQL_CONTAINER}  (host port ${SQL_HOST_PORT})"
    echo "Database         : ${DB_NAME}  (login: sa OR ${APP_USER_NAME})"
}
[[ $NEEDS_APP -eq 1 ]] && {
    echo "API container    : ${API_CONTAINER}    (http://localhost:${API_HOST_PORT}/)"
    echo "Front container  : ${FRONT_CONTAINER}  (http://localhost:${FRONT_HOST_PORT}/)"
    echo "API public URL   : ${API_PUBLIC_URL}"
}
echo "Logs             : sudo docker logs -f <container>"
echo "Stop             : (cd ${BASE_DIR} && sudo ${COMPOSE_CMD} down)"
echo "Start            : (cd ${BASE_DIR} && sudo ${COMPOSE_CMD} up -d)"
echo "Upgrade app      : bash <(curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/upgrade.sh) -c ${SAFE_CLIENT}"
echo
