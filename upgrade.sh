#!/usr/bin/env bash
# Falcon Cloud ERP — Safe in-place upgrade
#
# Upgrades the Falcon API and/or Frontend (and optionally SQL) for an existing
# client without touching data. Backs up every user database and snapshots the
# falconapp/ folder before recreating containers, so a failed upgrade can be
# rolled back manually.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/DocerScripts/falconclouderp/upgrade.sh) -c <client>
#
# Non-interactive:
#   FALCON_CLIENT=binmesaad FALCON_PASSWORD='SaStr0ng!' FALCON_YES=1 \
#     bash <(curl -fsSL .../upgrade.sh)

set -euo pipefail

# ---------- CLI args ----------
CLI_CLIENT=""
CLI_PASSWORD=""
CLI_SERVICES=""
CLI_SKIP_DB_BACKUP=0
ASSUME_YES="${FALCON_YES:-0}"

usage() {
    cat <<EOF
Usage: upgrade.sh [options]

Options:
  -c, --client    NAME      Client name (matches /opt/<name>/)
  -p, --password  SECRET    SA password (only needed for SQL backup)
  -s, --services  LIST      Comma list to upgrade: api,front,sql (default: api,front)
      --skip-db-backup      Skip the SQL backup step (NOT recommended)
  -y, --yes                 Skip confirmation prompts
  -h, --help                Show this help

Env vars:
  FALCON_CLIENT, FALCON_PASSWORD, FALCON_SERVICES, FALCON_YES
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--client)         CLI_CLIENT="$2";   shift 2 ;;
        -p|--password)       CLI_PASSWORD="$2"; shift 2 ;;
        -s|--services)       CLI_SERVICES="$2"; shift 2 ;;
        --skip-db-backup)    CLI_SKIP_DB_BACKUP=1; shift ;;
        -y|--yes)            ASSUME_YES=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        --client=*)          CLI_CLIENT="${1#*=}";   shift ;;
        --password=*)        CLI_PASSWORD="${1#*=}"; shift ;;
        --services=*)        CLI_SERVICES="${1#*=}"; shift ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

CLIENT_NAME="${CLI_CLIENT:-${FALCON_CLIENT:-}}"
SA_PASSWORD="${CLI_PASSWORD:-${FALCON_PASSWORD:-}}"
SERVICES_RAW="${CLI_SERVICES:-${FALCON_SERVICES:-api,front}}"

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
command -v docker >/dev/null 2>&1 || die "docker is not installed."
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    die "docker compose (v2) or docker-compose is required."
fi

# ---------- client + paths ----------
if [[ -z "$CLIENT_NAME" ]]; then
    read -r -p "$(echo -e "${C_BOLD}Client name${C_RESET}: ")" CLIENT_NAME
    [[ -z "$CLIENT_NAME" ]] && die "Client name is required."
fi

BASE_DIR="/opt/${CLIENT_NAME}"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
[[ -d "$BASE_DIR" ]]    || die "Base dir not found: ${BASE_DIR}"
[[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: ${COMPOSE_FILE}"

SQL_CONTAINER="${CLIENT_NAME}_sql"
API_CONTAINER="${CLIENT_NAME}_api"
FRONT_CONTAINER="${CLIENT_NAME}_front"

# Detect which services exist
HAS_SQL=0;   sudo docker ps -a --format '{{.Names}}' | grep -qx "$SQL_CONTAINER"    && HAS_SQL=1
HAS_API=0;   sudo docker ps -a --format '{{.Names}}' | grep -qx "$API_CONTAINER"    && HAS_API=1
HAS_FRONT=0; sudo docker ps -a --format '{{.Names}}' | grep -qx "$FRONT_CONTAINER"  && HAS_FRONT=1

# Parse requested services
UPGRADE_SQL=0; UPGRADE_API=0; UPGRADE_FRONT=0
IFS=',' read -ra REQ <<< "$SERVICES_RAW"
for s in "${REQ[@]}"; do
    case "${s,,}" in
        sql)   UPGRADE_SQL=1 ;;
        api)   UPGRADE_API=1 ;;
        front) UPGRADE_FRONT=1 ;;
        ""|all) UPGRADE_SQL=1; UPGRADE_API=1; UPGRADE_FRONT=1 ;;
        *) warn "Unknown service '${s}' — ignored." ;;
    esac
done

# Can't upgrade what doesn't exist
[[ $UPGRADE_SQL   -eq 1 && $HAS_SQL   -eq 0 ]] && { warn "No SQL container for this client — skipping.";   UPGRADE_SQL=0; }
[[ $UPGRADE_API   -eq 1 && $HAS_API   -eq 0 ]] && { warn "No API container for this client — skipping.";   UPGRADE_API=0; }
[[ $UPGRADE_FRONT -eq 1 && $HAS_FRONT -eq 0 ]] && { warn "No frontend container for this client — skipping."; UPGRADE_FRONT=0; }

if [[ $UPGRADE_SQL -eq 0 && $UPGRADE_API -eq 0 && $UPGRADE_FRONT -eq 0 ]]; then
    die "Nothing to upgrade."
fi

# ---------- summary + confirm ----------
echo -e "${C_BOLD}============================================${C_RESET}"
echo -e "${C_BOLD} Falcon Cloud ERP — Upgrade${C_RESET}"
echo -e "${C_BOLD}============================================${C_RESET}"
info "Client      : ${CLIENT_NAME}"
info "Compose     : ${COMPOSE_FILE}"
TO_UPGRADE=""
[[ $UPGRADE_SQL   -eq 1 ]] && TO_UPGRADE+="sql "
[[ $UPGRADE_API   -eq 1 ]] && TO_UPGRADE+="api "
[[ $UPGRADE_FRONT -eq 1 ]] && TO_UPGRADE+="front "
info "To upgrade  : ${TO_UPGRADE}"
[[ $HAS_SQL -eq 1 && $CLI_SKIP_DB_BACKUP -eq 0 ]] && info "Will run SQL backup before upgrading."
[[ ( $HAS_API -eq 1 || $HAS_FRONT -eq 1 ) ]] && info "Will snapshot /opt/${CLIENT_NAME}/falconapp/ before upgrading."

if [[ "$ASSUME_YES" != "1" && "${ASSUME_YES,,}" != "true" && "${ASSUME_YES,,}" != "yes" ]]; then
    read -r -p "Proceed? [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || die "Aborted."
fi

TS="$(date +%Y%m%d_%H%M%S)"

# ---------- SQL backup ----------
if [[ $HAS_SQL -eq 1 && $CLI_SKIP_DB_BACKUP -eq 0 ]]; then
    if [[ -z "$SA_PASSWORD" ]]; then
        read -r -s -p "$(echo -e "${C_BOLD}SA password for SQL backup${C_RESET}: ")" SA_PASSWORD; echo
        [[ -z "$SA_PASSWORD" ]] && die "SA password required. Use --skip-db-backup to bypass (NOT recommended)."
    fi

    SQLCMD_PATH=""
    for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
        if sudo docker exec "$SQL_CONTAINER" test -x "$candidate" 2>/dev/null; then
            SQLCMD_PATH="$candidate"; break
        fi
    done
    [[ -z "$SQLCMD_PATH" ]] && die "sqlcmd not found in ${SQL_CONTAINER}."

    info "Listing user databases for backup ..."
    DBS_RAW="$(sudo docker exec "$SQL_CONTAINER" bash -c \
        "$SQLCMD_PATH -C -N -S localhost -U sa -P \"${SA_PASSWORD}\" -Q \"SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE'\" -h -1 -W")"
    USER_DBS=()
    while IFS= read -r line; do
        line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "$line" || "$line" == *"rows affected"* ]] && continue
        USER_DBS+=("$line")
    done <<< "$DBS_RAW"

    if [[ ${#USER_DBS[@]} -eq 0 ]]; then
        warn "No user databases found to back up."
    else
        for DB in "${USER_DBS[@]}"; do
            BAK_PATH="/var/opt/mssql/backup/${DB}_pre_upgrade_${TS}.bak"
            info "Backing up [${DB}] -> ${BAK_PATH} ..."
            sudo docker exec "$SQL_CONTAINER" bash -c \
                "$SQLCMD_PATH -C -N -S localhost -U sa -P \"${SA_PASSWORD}\" -Q \"BACKUP DATABASE [${DB}] TO DISK = N'${BAK_PATH}' WITH INIT, COMPRESSION, STATS = 10\"" \
                || die "Backup failed for [${DB}]."
        done
        ok "SQL backups stored in ${BASE_DIR}/sql/backup/"
    fi
fi

# ---------- falconapp snapshot ----------
if [[ $HAS_API -eq 1 || $HAS_FRONT -eq 1 ]]; then
    if [[ -d "${BASE_DIR}/falconapp" ]]; then
        SNAP="${BASE_DIR}/falconapp_snapshot_${TS}.tar.gz"
        info "Snapshotting falconapp/ -> ${SNAP} ..."
        sudo tar -czf "$SNAP" -C "$BASE_DIR" falconapp
        ok "Snapshot saved."
    fi
fi

# ---------- pull + recreate ----------
info "Pulling latest images ..."
( cd "$BASE_DIR" && sudo $COMPOSE_CMD pull )

RECREATE_LIST=()
[[ $UPGRADE_SQL   -eq 1 ]] && RECREATE_LIST+=("$SQL_CONTAINER")
[[ $UPGRADE_API   -eq 1 ]] && RECREATE_LIST+=("$API_CONTAINER")
[[ $UPGRADE_FRONT -eq 1 ]] && RECREATE_LIST+=("$FRONT_CONTAINER")

info "Recreating: ${RECREATE_LIST[*]} ..."
( cd "$BASE_DIR" && sudo $COMPOSE_CMD up -d "${RECREATE_LIST[@]}" )
ok "Containers recreated."

# ---------- smoke checks ----------
sleep 3
info "Container status:"
( cd "$BASE_DIR" && sudo $COMPOSE_CMD ps )

# Helper to find a host port from the compose file by matching "HOST:CONTAINER"
discover_port() {
    local container="$1" inside_port="$2"
    sudo awk -v c="${container}" -v p="${inside_port}" '
        $0 ~ "^[[:space:]]*"c":" { inside=1; next }
        inside && /^[[:space:]]*[a-zA-Z0-9_-]+:/ && $0 !~ "^[[:space:]]*"c":" { inside=0 }
        inside {
            if (match($0, "\"([0-9]+):"p"\"", a)) { print a[1]; exit }
        }
    ' "$COMPOSE_FILE"
}

if [[ $UPGRADE_API -eq 1 ]]; then
    API_PORT="$(discover_port "$API_CONTAINER" "5001")"
    if [[ -n "$API_PORT" ]]; then
        info "Probing API on http://localhost:${API_PORT}/ ..."
        for i in $(seq 1 60); do
            code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://localhost:${API_PORT}/" 2>/dev/null || echo 000)"
            if [[ "$code" != "000" && -n "$code" ]]; then
                ok "API responded HTTP ${code}"
                break
            fi
            sleep 1
            [[ $i -eq 60 ]] && warn "API did not respond. Check: sudo docker logs ${API_CONTAINER}"
        done
    fi
fi

if [[ $UPGRADE_FRONT -eq 1 ]]; then
    FRONT_PORT="$(discover_port "$FRONT_CONTAINER" "80")"
    if [[ -n "$FRONT_PORT" ]]; then
        info "Probing Frontend on http://localhost:${FRONT_PORT}/ ..."
        for i in $(seq 1 30); do
            fcode="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://localhost:${FRONT_PORT}/" 2>/dev/null || echo 000)"
            if [[ "$fcode" != "000" && -n "$fcode" ]]; then
                ok "Frontend responded HTTP ${fcode}"
                break
            fi
            sleep 1
            [[ $i -eq 30 ]] && warn "Frontend did not respond. Check: sudo docker logs ${FRONT_CONTAINER}"
        done
    fi
fi

# ---------- summary ----------
echo
echo -e "${C_GREEN}${C_BOLD}============================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD} Upgrade complete${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}============================================${C_RESET}"
echo "Client    : ${CLIENT_NAME}"
echo "Base dir  : ${BASE_DIR}"
if [[ $HAS_SQL -eq 1 && $CLI_SKIP_DB_BACKUP -eq 0 ]]; then
    echo "DB backups: ${BASE_DIR}/sql/backup/*_pre_upgrade_${TS}.bak"
fi
if [[ -f "${BASE_DIR}/falconapp_snapshot_${TS}.tar.gz" ]]; then
    echo "Snapshot  : ${BASE_DIR}/falconapp_snapshot_${TS}.tar.gz"
fi
echo
echo "Rollback (if needed):"
echo "  1) Stop:   (cd ${BASE_DIR} && sudo ${COMPOSE_CMD} down)"
echo "  2) Edit ${COMPOSE_FILE} — pin images to the previous tag"
echo "  3) Start:  (cd ${BASE_DIR} && sudo ${COMPOSE_CMD} up -d)"
echo "  4) If DB regressed:"
echo "     sudo docker exec ${SQL_CONTAINER} /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P '<pwd>' \\"
echo "        -Q \"RESTORE DATABASE [<db>] FROM DISK = N'/var/opt/mssql/backup/<db>_pre_upgrade_${TS}.bak' WITH REPLACE, RECOVERY\""
echo
