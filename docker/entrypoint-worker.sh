#!/bin/bash
set -e

echo "$(date): Starting worker container initialization..."

# replace env variables in the service_conf.yaml file
echo "$(date): Configuring service_conf.yaml..."
rm -rf /var/task/conf/service_conf.yaml
while IFS= read -r line || [[ -n "$line" ]]; do
    # Use eval to interpret the variable with default values
    eval "echo \"$line\"" >> /var/task/conf/service_conf.yaml
done < /var/task/conf/service_conf.yaml.template
echo "$(date): Configuration complete."

export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu/
echo "$(date): LD_LIBRARY_PATH set to $LD_LIBRARY_PATH"

PY=python3
echo "$(date): Using Python interpreter: $PY"

# Display Python version and environment details
$PY --version
echo "$(date): Python path: $PYTHONPATH"
echo "$(date): Virtual env: $VIRTUAL_ENV"

# Extract connection details from service_conf.yaml
MYSQL_HOST=$(grep -A 3 "mysql" /var/task/conf/service_conf.yaml | grep "host" | awk '{print $2}')
MYSQL_PORT=$(grep -A 3 "mysql" /var/task/conf/service_conf.yaml | grep "port" | awk '{print $2}')
MYSQL_USER=$(grep -A 3 "mysql" /var/task/conf/service_conf.yaml | grep "user" | awk '{print $2}')
MYSQL_PASSWORD=$(grep -A 3 "mysql" /var/task/conf/service_conf.yaml | grep "password" | awk '{print $2}')

REDIS_HOST=$(grep -A 3 "redis" /var/task/conf/service_conf.yaml | grep "host" | awk '{print $2}')
REDIS_PORT=$(grep -A 3 "redis" /var/task/conf/service_conf.yaml | grep "port" | awk '{print $2}')

MINIO_HOST=$(grep -A 3 "minio" /var/task/conf/service_conf.yaml | grep "endpoint" | awk '{print $2}' | sed 's|http://||g' | sed 's|https://||g' | cut -d':' -f1)
MINIO_PORT=$(grep -A 3 "minio" /var/task/conf/service_conf.yaml | grep "endpoint" | awk '{print $2}' | sed 's|http://||g' | sed 's|https://||g' | grep -o ':[0-9]\+' | cut -d':' -f2)

ES_HOST=$(grep -A 3 "elasticsearch" /var/task/conf/service_conf.yaml | grep "host" | awk '{print $2}')
ES_PORT=$(grep -A 3 "elasticsearch" /var/task/conf/service_conf.yaml | grep "port" | awk '{print $2}')

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

# We run with a hardcoded script path and timestamp, no need to check for arguments

# Get current Unix timestamp
TIMESTAMP=$(date +%s)

# Show what we're executing
echo "$(date): Running rag/svr/task_executor.py with arguments: $TIMESTAMP"

# Execute the task executor with Unix timestamp as argument
$PY /var/task/rag/svr/task_executor.py $TIMESTAMP
