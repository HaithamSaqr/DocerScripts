#!/usr/bin/env bash
# Falcon MSSQL Container Provisioner
#
# Interactive (asks for everything):
#   bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/run.sh)
#
# One-shot with flags (no prompts):
#   bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/run.sh) \
#     --client escan_const --db escandb --password 'S0meStr0ng!Pass' --port 5779 --yes
#
# Or with env vars:
#   FALCON_CLIENT=escan_const FALCON_DB=escandb \
#   FALCON_PASSWORD='S0meStr0ng!Pass' FALCON_PORT=5779 FALCON_YES=1 \
#     bash <(curl -fsSL .../run.sh)
#
# Flags > env vars > interactive prompt.

set -euo pipefail

# ---------- configuration ----------
REPO_OWNER="${FALCON_REPO_OWNER:-HaithamSaqr}"
REPO_NAME="${FALCON_REPO_NAME:-DocerScripts}"
REPO_BRANCH="${FALCON_REPO_BRANCH:-sqlexpress25}"
TARBALL_URL="${FALCON_TARBALL_URL:-https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz}"
TEMPLATE_PATH_IN_REPO="${FALCON_TEMPLATE_PATH:-opt/FalconTemplate/sql}"
BACKUP_FILE_NAME="FalconTemplate.bak"
MSSQL_IMAGE="${FALCON_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2025-latest}"
MSSQL_PID="${FALCON_MSSQL_PID:-Express}"
WAIT_SECONDS="${FALCON_WAIT_SECONDS:-90}"

# ---------- CLI args ----------
CLI_CLIENT=""
CLI_DB=""
CLI_PASSWORD=""
CLI_PORT=""
ASSUME_YES="${FALCON_YES:-0}"

usage() {
    cat <<EOF
Usage: run.sh [options]

Options:
  -c, --client    NAME      Client name (container + folder name)
  -d, --db        NAME      Database name after restore
  -p, --password  SECRET    SA password (avoid shell history — prefer env var)
  -P, --port      PORT      Host port to expose (default: 5779)
  -y, --yes                 Skip the final confirmation prompt
  -h, --help                Show this help

Env vars (used when the matching flag is omitted):
  FALCON_CLIENT, FALCON_DB, FALCON_PASSWORD, FALCON_PORT, FALCON_YES
  FALCON_BACKUP_URL, FALCON_REPO_RAW_URL, FALCON_MSSQL_IMAGE,
  FALCON_MSSQL_PID, FALCON_WAIT_SECONDS

Example (fully non-interactive):
  ./run.sh -c escan_const -d escandb -p 'S0meStr0ng!Pass' -P 5779 -y
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--client)    CLI_CLIENT="$2";   shift 2 ;;
        -d|--db)        CLI_DB="$2";       shift 2 ;;
        -p|--password)  CLI_PASSWORD="$2"; shift 2 ;;
        -P|--port)      CLI_PORT="$2";     shift 2 ;;
        -y|--yes)       ASSUME_YES=1;      shift ;;
        -h|--help)      usage; exit 0 ;;
        --client=*)     CLI_CLIENT="${1#*=}";   shift ;;
        --db=*)         CLI_DB="${1#*=}";       shift ;;
        --password=*)   CLI_PASSWORD="${1#*=}"; shift ;;
        --port=*)       CLI_PORT="${1#*=}";     shift ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# Precedence: flag > env var > empty (will trigger prompt)
CLIENT_NAME="${CLI_CLIENT:-${FALCON_CLIENT:-}}"
DB_NAME="${CLI_DB:-${FALCON_DB:-}}"
SA_PASSWORD="${CLI_PASSWORD:-${FALCON_PASSWORD:-}}"
HOST_PORT="${CLI_PORT:-${FALCON_PORT:-}}"

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
command -v docker >/dev/null 2>&1 || die "docker is not installed. Install Docker first."
command -v curl   >/dev/null 2>&1 || die "curl is not installed."

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    die "docker compose (v2) or docker-compose is required."
fi

# ---------- interactive prompts ----------
echo -e "${C_BOLD}========================================${C_RESET}"
echo -e "${C_BOLD} Falcon MSSQL Provisioner${C_RESET}"
echo -e "${C_BOLD}========================================${C_RESET}"

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

[[ -z "$CLIENT_NAME" ]] && prompt_required CLIENT_NAME "Client name (used for container + folder name)"
[[ -z "$DB_NAME"     ]] && prompt_required DB_NAME     "Database name (target name after restore)"
[[ -z "$SA_PASSWORD" ]] && prompt_secret   SA_PASSWORD "SA password (min 8 chars, mixed complexity)"
[[ -z "$HOST_PORT"   ]] && prompt_required HOST_PORT   "Host port to expose (e.g. 5779)" "5779"

# sanitize client name to a safe identifier (letters, digits, underscore, dash)
SAFE_CLIENT="$(echo "$CLIENT_NAME" | tr -c 'A-Za-z0-9_-' '_' | sed 's/^_*//; s/_*$//')"
[[ -z "$SAFE_CLIENT" ]] && die "Client name became empty after sanitization."
[[ "$SAFE_CLIENT" != "$CLIENT_NAME" ]] && warn "Client name sanitized to: ${SAFE_CLIENT}"

CONTAINER_NAME="$SAFE_CLIENT"
BASE_DIR="/opt/${SAFE_CLIENT}"
DATA_DIR="${BASE_DIR}/sql/data"
LOG_DIR="${BASE_DIR}/sql/log"
BACKUP_DIR="${BASE_DIR}/sql/backup"

# ---------- confirmation ----------
echo
info "Summary:"
echo "  Container name : ${CONTAINER_NAME}"
echo "  Database name  : ${DB_NAME}"
echo "  Host port      : ${HOST_PORT} -> 1433"
echo "  Data dir       : ${DATA_DIR}"
echo "  Log dir        : ${LOG_DIR}"
echo "  Backup dir     : ${BACKUP_DIR}"
echo "  MSSQL image    : ${MSSQL_IMAGE}"
echo "  Edition (PID)  : ${MSSQL_PID}"
echo
if [[ "$ASSUME_YES" == "1" || "${ASSUME_YES,,}" == "true" || "${ASSUME_YES,,}" == "yes" ]]; then
    info "Auto-confirming (--yes)."
else
    read -r -p "Proceed? [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || die "Aborted."
fi

# ---------- materialize folder layout from repo tarball ----------
# The repo carries the canonical folder template at:
#   opt/FalconTemplate/sql/{data,log,backup}
# with FalconTemplate.bak already inside backup/. We download the whole branch
# as a tarball, extract it, and copy that subtree to /opt/<client>/sql/. The
# restore step later reads the backup from /var/opt/mssql/backup/ inside the
# container (which is bind-mounted to /opt/<client>/sql/backup/ on the host).
info "Downloading repo tarball: ${TARBALL_URL}"
TMP_REPO_ROOT="$(mktemp -d -t falcon_repo_XXXXXX)"
trap 'rm -rf "$TMP_REPO_ROOT"' EXIT

if ! curl -fL --progress-bar -o "${TMP_REPO_ROOT}/repo.tar.gz" "$TARBALL_URL"; then
    die "Failed to download tarball from ${TARBALL_URL}"
fi
# --strip-components=1 drops the top-level "<repo>-<branch>/" prefix
tar -xzf "${TMP_REPO_ROOT}/repo.tar.gz" -C "$TMP_REPO_ROOT" --strip-components=1 \
    || die "Failed to extract repo tarball."
ok "Repo extracted to ${TMP_REPO_ROOT}"

SOURCE_TEMPLATE="${TMP_REPO_ROOT}/${TEMPLATE_PATH_IN_REPO}"
[[ -d "$SOURCE_TEMPLATE" ]] || die "Template folder not found in repo at: ${TEMPLATE_PATH_IN_REPO}"

SOURCE_BACKUP="${SOURCE_TEMPLATE}/backup/${BACKUP_FILE_NAME}"
if [[ ! -f "$SOURCE_BACKUP" ]]; then
    die "Backup file is missing in the repo at: ${TEMPLATE_PATH_IN_REPO}/backup/${BACKUP_FILE_NAME}
Commit your ${BACKUP_FILE_NAME} into the repo first:
  cp /path/to/${BACKUP_FILE_NAME} opt/FalconTemplate/sql/backup/
  git add opt/FalconTemplate/sql/backup/${BACKUP_FILE_NAME}
  git commit -m 'Add template backup'
  git push origin ${REPO_BRANCH}"
fi

BACKUP_SIZE_HUMAN="$(du -h "$SOURCE_BACKUP" | cut -f1)"
info "Template backup found (${BACKUP_SIZE_HUMAN})."

info "Materializing ${BASE_DIR}/sql/ from repo template ..."
sudo mkdir -p "$BASE_DIR"
# Copy the entire sql/ tree (data/, log/, backup/<bak>) preserving structure.
# We use rsync if available for clearer progress, falling back to cp -r.
if command -v rsync >/dev/null 2>&1; then
    sudo rsync -a --delete "${SOURCE_TEMPLATE}/" "${BASE_DIR}/sql/"
else
    sudo rm -rf "${BASE_DIR}/sql"
    sudo cp -r "${SOURCE_TEMPLATE}" "${BASE_DIR}/sql"
fi
# Strip the marker files git used to keep empty folders alive
sudo rm -f "${BASE_DIR}/sql/data/.gitkeep" "${BASE_DIR}/sql/log/.gitkeep" "${BASE_DIR}/sql/backup/README.md"
ok "Folder structure materialized with backup staged at ${BACKUP_DIR}/${BACKUP_FILE_NAME}"

# ---------- write docker-compose.yml ----------
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
info "Writing ${COMPOSE_FILE} ..."
sudo tee "$COMPOSE_FILE" >/dev/null <<EOF
version: '3.8'

services:
  ${CONTAINER_NAME}:
    image: ${MSSQL_IMAGE}
    container_name: ${CONTAINER_NAME}
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "${SA_PASSWORD}"
      MSSQL_PID: "${MSSQL_PID}"
    ports:
      - "${HOST_PORT}:1433"
    volumes:
      - ${DATA_DIR}:/var/opt/mssql/data
      - ${LOG_DIR}:/var/opt/mssql/log
      - ${BACKUP_DIR}:/var/opt/mssql/backup
    restart: unless-stopped
EOF
ok "Compose file written."

# ---------- ownership & permissions ----------
# mssql container runs as uid 10001 in modern images
info "Setting ownership and permissions on ${BASE_DIR}/sql ..."
sudo chown -R 10001:10001 "${BASE_DIR}/sql"
sudo chmod -R 770 "${BASE_DIR}/sql"
ok "Permissions set."

# ---------- start container ----------
info "Starting container ..."
( cd "$BASE_DIR" && sudo $COMPOSE_CMD up -d )
ok "Container started: ${CONTAINER_NAME}"

# ---------- wait for SQL Server readiness ----------
info "Waiting for SQL Server to become ready (timeout ${WAIT_SECONDS}s) ..."
SQLCMD_PATH=""
for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
    if sudo docker exec "$CONTAINER_NAME" test -x "$candidate" 2>/dev/null; then
        SQLCMD_PATH="$candidate"
        break
    fi
done
[[ -z "$SQLCMD_PATH" ]] && die "sqlcmd not found inside the container. Cannot continue with restore."

# sqlcmd 18+ enforces encryption; -C trusts the self-signed cert
SQLCMD_OPTS="-C -N -S localhost -U sa -P \"${SA_PASSWORD}\""
READY=0
for ((i=1; i<=WAIT_SECONDS; i++)); do
    if sudo docker exec "$CONTAINER_NAME" bash -c "$SQLCMD_PATH $SQLCMD_OPTS -Q 'SELECT 1' -h -1" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done
[[ $READY -eq 1 ]] || die "SQL Server did not become ready in ${WAIT_SECONDS}s. Check: docker logs ${CONTAINER_NAME}"
ok "SQL Server is ready."

# ---------- inspect backup file list, build MOVE clauses, restore ----------
# The backup retains the physical paths from the source server (often a Windows
# path like C:\Program Files\Microsoft SQL Server\...\DATA\db.mdf). On a Linux
# container that path does not exist, so RESTORE fails with OS error 2. We fix
# this by reading FILELISTONLY and emitting MOVE clauses that redirect every
# data and log file into /var/opt/mssql/data inside the container.
info "Inspecting backup file list (resolving original physical paths) ..."

# SET NOCOUNT ON suppresses the trailing "(N rows affected)" line.
# -W trims whitespace, -s '|' uses pipe as column separator, -h -1 removes headers.
FILELIST_RAW="$(sudo docker exec "$CONTAINER_NAME" bash -c \
    "$SQLCMD_PATH $SQLCMD_OPTS -Q \"SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK = N'/var/opt/mssql/backup/${BACKUP_FILE_NAME}'\" -W -s '|' -h -1" 2>&1)" \
    || die "RESTORE FILELISTONLY failed:\n${FILELIST_RAW}"

# Strip noise: blank lines, "rows affected" messages, separator dashes, and any
# line without enough pipe delimiters to be a real FILELISTONLY row.
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
    LOGICAL_NAME="$(echo "$LOGICAL_NAME"  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    PHYSICAL_NAME="$(echo "$PHYSICAL_NAME" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    TYPE="$(echo "$TYPE"                  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
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
        S)
            die "Backup contains a FILESTREAM container ('${LOGICAL_NAME}'). FILESTREAM is not supported on Linux containers. Restore aborted."
            ;;
        F)
            warn "Skipping full-text catalog file '${LOGICAL_NAME}' (full-text catalogs are deprecated and not auto-relocated)."
            continue
            ;;
        *)
            warn "Unknown file type '${TYPE}' for logical name '${LOGICAL_NAME}'. Skipping."
            continue
            ;;
    esac

    [[ -n "$MOVE_CLAUSES" ]] && MOVE_CLAUSES+=", "
    MOVE_CLAUSES+="MOVE N'${LOGICAL_NAME}' TO N'${NEW_PATH}'"
    PARSED_PREVIEW+=("  [${TYPE}] ${LOGICAL_NAME}  (was: ${PHYSICAL_NAME})  ->  ${NEW_PATH}")
done <<< "$FILELIST_OUT"

[[ -z "$MOVE_CLAUSES" ]] && die "Could not build any MOVE clauses. Raw output:\n${FILELIST_RAW}"
[[ $DATA_COUNT -eq 0 ]] && die "Backup has no data files. Refusing to restore."
[[ $LOG_COUNT  -eq 0 ]] && warn "Backup has no log file — proceeding, but verify the source is not corrupt."

info "Path remapping plan:"
for line in "${PARSED_PREVIEW[@]}"; do
    echo "$line"
done

info "Restoring database as [${DB_NAME}] ..."
RESTORE_SQL="RESTORE DATABASE [${DB_NAME}] FROM DISK = N'/var/opt/mssql/backup/${BACKUP_FILE_NAME}' WITH ${MOVE_CLAUSES}, REPLACE, RECOVERY, STATS = 10"
sudo docker exec "$CONTAINER_NAME" bash -c \
    "$SQLCMD_PATH $SQLCMD_OPTS -Q \"${RESTORE_SQL}\"" \
    || die "RESTORE failed. Review the SQL output above. The MOVE plan was:\n$(printf '%s\n' "${PARSED_PREVIEW[@]}")"
ok "Restore completed."

# ---------- verify ----------
info "Verifying database state ..."
sudo docker exec "$CONTAINER_NAME" bash -c \
    "$SQLCMD_PATH $SQLCMD_OPTS -Q \"SELECT name, state_desc FROM sys.databases WHERE name = N'${DB_NAME}'\""

# ---------- summary ----------
echo
echo -e "${C_GREEN}${C_BOLD}========================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD} Done${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}========================================${C_RESET}"
echo "Container : ${CONTAINER_NAME}"
echo "Database  : ${DB_NAME}"
echo "Host port : ${HOST_PORT}"
echo "Connect   : Server=<host>,${HOST_PORT}; User Id=sa; Database=${DB_NAME};"
echo "Logs      : sudo docker logs -f ${CONTAINER_NAME}"
echo "Stop      : (cd ${BASE_DIR} && sudo ${COMPOSE_CMD} down)"
echo "Start     : (cd ${BASE_DIR} && sudo ${COMPOSE_CMD} up -d)"
echo
