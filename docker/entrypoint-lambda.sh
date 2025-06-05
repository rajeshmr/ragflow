#!/usr/bin/env bash

set -e

# -----------------------------------------------------------------------------
# Usage and command-line argument parsing
# -----------------------------------------------------------------------------
function usage() {
    echo "Usage: $0 [--disable-webserver] [--disable-taskexecutor] [--consumer-no-beg=<num>] [--consumer-no-end=<num>] [--workers=<num>] [--host-id=<string>] [--enable-mcpserver]"
    echo
    echo "  --disable-webserver             Disables the web server (nginx + ragflow_server)."
    echo "  --disable-taskexecutor          Disables task executor workers."
    echo "  --enable-mcpserver              Enables the MCP server."
    echo "  --consumer-no-beg=<num>         Start range for consumers (if using range-based)."
    echo "  --consumer-no-end=<num>         End range for consumers (if using range-based)."
    echo "  --workers=<num>                 Number of task executors to run (if range is not used)."
    echo "  --host-id=<string>              Unique ID for the host (defaults to \`hostname\`)."
    echo
    echo "Examples:"
    echo "  $0 --disable-taskexecutor"
    echo "  $0 --disable-webserver --consumer-no-beg=0 --consumer-no-end=5"
    echo "  $0 --disable-webserver --workers=2 --host-id=myhost123"
    echo "  $0 --enable-mcpserver"
    exit 1
}

ENABLE_WEBSERVER=1 # Default to enable web server
ENABLE_TASKEXECUTOR=1  # Default to enable task executor
ENABLE_MCP_SERVER=0
CONSUMER_NO_BEG=0
CONSUMER_NO_END=0
WORKERS=1

MCP_HOST="127.0.0.1"
MCP_PORT=9382
MCP_BASE_URL="http://127.0.0.1:9380"
MCP_SCRIPT_PATH="/ragflow/mcp/server/server.py"
MCP_MODE="self-host"
MCP_HOST_API_KEY=""

# -----------------------------------------------------------------------------
# Host ID logic:
#   1. By default, use the system hostname if length <= 32
#   2. Otherwise, use the full MD5 hash of the hostname (32 hex chars)
# -----------------------------------------------------------------------------
CURRENT_HOSTNAME="$(hostname)"
if [ ${#CURRENT_HOSTNAME} -le 32 ]; then
  DEFAULT_HOST_ID="$CURRENT_HOSTNAME"
else
  DEFAULT_HOST_ID="$(echo -n "$CURRENT_HOSTNAME" | md5sum | cut -d ' ' -f 1)"
fi

HOST_ID="$DEFAULT_HOST_ID"

# Parse arguments
for arg in "$@"; do
  case $arg in
    --disable-webserver)
      ENABLE_WEBSERVER=0
      shift
      ;;
    --disable-taskexecutor)
      ENABLE_TASKEXECUTOR=0
      shift
      ;;
    --enable-mcpserver)
      ENABLE_MCP_SERVER=1
      shift
      ;;
    --mcp-host=*)
      MCP_HOST="${arg#*=}"
      shift
      ;;
    --mcp-port=*)
      MCP_PORT="${arg#*=}"
      shift
      ;;
    --mcp-base-url=*)
      MCP_BASE_URL="${arg#*=}"
      shift
      ;;
    --mcp-mode=*)
      MCP_MODE="${arg#*=}"
      shift
      ;;
    --mcp-host-api-key=*)
      MCP_HOST_API_KEY="${arg#*=}"
      shift
      ;;
    --mcp-script-path=*)
      MCP_SCRIPT_PATH="${arg#*=}"
      shift
      ;;
    --consumer-no-beg=*)
      CONSUMER_NO_BEG="${arg#*=}"
      shift
      ;;
    --consumer-no-end=*)
      CONSUMER_NO_END="${arg#*=}"
      shift
      ;;
    --workers=*)
      WORKERS="${arg#*=}"
      shift
      ;;
    --host-id=*)
      HOST_ID="${arg#*=}"
      shift
      ;;
    *)
      usage
      ;;
  esac
done

echo "$(date): Starting container initialization..."

# -----------------------------------------------------------------------------
# Replace env variables in the service_conf.yaml file
# -----------------------------------------------------------------------------
echo "$(date): Configuring service_conf.yaml..."

# Support both directory structures
if [ -f "/var/task/conf/service_conf.yaml.template" ]; then
    CONF_DIR="/var/task/conf"
elif [ -f "/ragflow/conf/service_conf.yaml.template" ]; then
    CONF_DIR="/ragflow/conf"
else
    echo "$(date): ERROR: service_conf.yaml.template not found in expected locations"
    exit 1
fi

TEMPLATE_FILE="${CONF_DIR}/service_conf.yaml.template"
CONF_FILE="${CONF_DIR}/service_conf.yaml"

rm -f "${CONF_FILE}"
while IFS= read -r line || [[ -n "$line" ]]; do
    eval "echo \"$line\"" >> "${CONF_FILE}"
done < "${TEMPLATE_FILE}"

echo "$(date): Configuration complete."

# Print the generated service configuration file
echo "$(date): Generated service_conf.yaml contents:"
echo "----------------------------------------"
cat "${CONF_FILE}"
echo "----------------------------------------"

# AWS Lambda uses API Gateway for HTTP request routing, nginx not needed
echo "$(date): Setting up environment for AWS Lambda/App Runner..."

export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu/"
echo "$(date): LD_LIBRARY_PATH set to $LD_LIBRARY_PATH"

PY=python3
echo "$(date): Using Python interpreter: $PY"

# Set default workers if not specified
if [[ -z "$WORKERS" || $WORKERS -lt 1 ]]; then
  WORKERS=1
  echo "$(date): Setting default worker count: $WORKERS"
else
  echo "$(date): Worker count set to: $WORKERS"
fi

# Display Python version and environment details
$PY --version
echo "$(date): Python path: $PYTHONPATH"
echo "$(date): Virtual env: $VIRTUAL_ENV"

# -----------------------------------------------------------------------------
# Connectivity check functions
# -----------------------------------------------------------------------------
echo "$(date): Performing connectivity checks for all components..."

# Function to check connection with timeout
check_connection() {
    local component=$1
    local check_cmd=$2
    local timeout=5

    echo "$(date): Checking $component connectivity..."
    timeout $timeout bash -c "$check_cmd" 2>/dev/null
    local status=$?

    if [ $status -eq 0 ]; then
        echo "$(date): ✅ $component connection successful"
        return 0
    elif [ $status -eq 124 ]; then
        echo "$(date): ❌ ERROR: $component connection timed out after ${timeout}s"
        return 1
    else
        echo "$(date): ❌ ERROR: Failed to connect to $component (exit code: $status)"
        return 1
    fi
}

# Extract connection details from service_conf.yaml
MYSQL_HOST=$(grep -A 3 "mysql" "${CONF_FILE}" | grep "host" | awk '{print $2}')
MYSQL_PORT=$(grep -A 3 "mysql" "${CONF_FILE}" | grep "port" | awk '{print $2}')
MYSQL_USER=$(grep -A 3 "mysql" "${CONF_FILE}" | grep "user" | awk '{print $2}')
MYSQL_PASSWORD=$(grep -A 3 "mysql" "${CONF_FILE}" | grep "password" | awk '{print $2}')

REDIS_HOST=$(grep -A 3 "redis" "${CONF_FILE}" | grep "host" | awk '{print $2}')
REDIS_PORT=$(grep -A 3 "redis" "${CONF_FILE}" | grep "port" | awk '{print $2}')

MINIO_HOST=$(grep -A 3 "minio" "${CONF_FILE}" | grep "endpoint" | awk '{print $2}' | sed 's|http://||g' | sed 's|https://||g' | cut -d':' -f1)
MINIO_PORT=$(grep -A 3 "minio" "${CONF_FILE}" | grep "endpoint" | awk '{print $2}' | sed 's|http://||g' | sed 's|https://||g' | grep -o ':[0-9]\+' | cut -d':' -f2)

ES_HOST=$(grep -A 3 "elasticsearch" "${CONF_FILE}" | grep "host" | awk '{print $2}')
ES_PORT=$(grep -A 3 "elasticsearch" "${CONF_FILE}" | grep "port" | awk '{print $2}')

# Initialize failure flag
connection_failure=0

# Check MySQL connection
if [ ! -z "$MYSQL_HOST" ] && [ ! -z "$MYSQL_PORT" ]; then
    check_cmd="echo 'SELECT 1;' | mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD --connect-timeout=5 2>&1 | grep -q '1'"
    check_connection "MySQL" "$check_cmd" || connection_failure=1
fi

# Check Redis connection
if [ ! -z "$REDIS_HOST" ] && [ ! -z "$REDIS_PORT" ]; then
    check_cmd="redis-cli -h $REDIS_HOST -p $REDIS_PORT ping | grep -q 'PONG'"
    check_connection "Redis" "$check_cmd" || connection_failure=1
fi

# Check MinIO connection
if [ ! -z "$MINIO_HOST" ] && [ ! -z "$MINIO_PORT" ]; then
    check_cmd="nc -z -w3 $MINIO_HOST $MINIO_PORT"
    check_connection "MinIO" "$check_cmd" || connection_failure=1
fi

# Check Elasticsearch connection
if [ ! -z "$ES_HOST" ] && [ ! -z "$ES_PORT" ]; then
    check_cmd="curl --silent --max-time 3 http://$ES_HOST:$ES_PORT/_cluster/health | grep -q 'status'"
    check_connection "Elasticsearch" "$check_cmd" || connection_failure=1
fi

# Exit if any connection checks failed
if [ $connection_failure -eq 1 ]; then
    echo "$(date): ❌ ERROR: One or more component connectivity checks failed. Exiting with error code 1."
    exit 1
fi

echo "$(date): ✅ All component connectivity checks passed successfully."

# -----------------------------------------------------------------------------
# System diagnostics
# -----------------------------------------------------------------------------
echo "$(date): System information:"
echo "Memory:"
if command -v free &> /dev/null; then
    free -h
else
    echo "Memory info not available (free command not found)"
    cat /proc/meminfo 2>/dev/null || echo "Proc meminfo not available"
fi

echo "Disk:"
if command -v df &> /dev/null; then
    df -h
else
    echo "Disk info not available (df command not found)"
fi

echo "CPU:"
if command -v lscpu &> /dev/null; then
    lscpu | head -15
else
    echo "CPU info from /proc/cpuinfo:"
    cat /proc/cpuinfo 2>/dev/null || echo "Proc cpuinfo not available"
fi

# -----------------------------------------------------------------------------
# Function definitions
# -----------------------------------------------------------------------------
function task_exe() {
    local consumer_id="$1"
    local host_id="$2"

    JEMALLOC_PATH="$(pkg-config --variable=libdir jemalloc)/libjemalloc.so"
    while true; do
        echo "$(date): Starting task executor ${host_id}_${consumer_id}"
        LD_PRELOAD="$JEMALLOC_PATH" \
        "$PY" rag/svr/task_executor.py "${host_id}_${consumer_id}" 2>&1 | {
            while IFS= read -r line; do
                echo "$(date) [TASK-${consumer_id}] $line"
            done
        }
        echo "$(date): Task executor ${host_id}_${consumer_id} exited, restarting in 2 seconds..."
        sleep 2
    done
}

function start_mcp_server() {
    echo "$(date): Starting MCP Server on ${MCP_HOST}:${MCP_PORT} with base URL ${MCP_BASE_URL}..."
    "$PY" "${MCP_SCRIPT_PATH}" \
        --host="${MCP_HOST}" \
        --port="${MCP_PORT}" \
        --base_url="${MCP_BASE_URL}" \
        --mode="${MCP_MODE}" \
        --api_key="${MCP_HOST_API_KEY}" 2>&1 | {
            while IFS= read -r line; do
                echo "$(date) [MCP] $line"
            done
        } &
}

# -----------------------------------------------------------------------------
# Start components based on flags
# -----------------------------------------------------------------------------
echo "$(date): Starting main application components..."
echo "$(date): Python executable: $(which $PY)"

if [[ "${ENABLE_WEBSERVER}" -eq 1 ]]; then
    # For AWS Lambda/App Runner, skip nginx and use apprunner version
    echo "$(date): Starting ragflow_server_apprunner.py for AWS Lambda/App Runner..."

    # Use apprunner version for AWS Lambda compatibility
    APP_SCRIPT="api/ragflow_server_apprunner.py"
    if [ ! -f "$APP_SCRIPT" ]; then
        echo "$(date): WARNING: $APP_SCRIPT not found, falling back to api/ragflow_server.py"
        APP_SCRIPT="api/ragflow_server.py"
    fi

    while true; do
        echo "$(date): Starting $APP_SCRIPT"
        "$PY" "$APP_SCRIPT" 2>&1 | {
            while IFS= read -r line; do
                echo "$(date) [WEB] $line"
            done
        }
        echo "$(date): Web server exited with code $?, restarting in 2 seconds..."
        sleep 2
    done &
fi

if [[ "${ENABLE_MCP_SERVER}" -eq 1 ]]; then
    start_mcp_server
fi

if [[ "${ENABLE_TASKEXECUTOR}" -eq 1 ]]; then
    if [[ "${CONSUMER_NO_END}" -gt "${CONSUMER_NO_BEG}" ]]; then
        echo "$(date): Starting task executors on host '${HOST_ID}' for IDs in [${CONSUMER_NO_BEG}, ${CONSUMER_NO_END})..."
        for (( i=CONSUMER_NO_BEG; i<CONSUMER_NO_END; i++ ))
        do
          task_exe "${i}" "${HOST_ID}" &
        done
    else
        echo "$(date): Starting ${WORKERS} task executor(s) on host '${HOST_ID}'..."
        for (( i=0; i<WORKERS; i++ ))
        do
          task_exe "${i}" "${HOST_ID}" &
        done
    fi
fi

echo "$(date): All components started successfully"
wait