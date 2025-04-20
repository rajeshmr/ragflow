#!/bin/bash
set -e

# Enable verbose logging if DEBUG is set
if [[ "$DEBUG" == "true" || "$VERBOSE" == "true" ]]; then
    set -x  # Print each command before executing
fi

echo "$(date): Starting container initialization..."

# replace env variables in the service_conf.yaml file
echo "$(date): Configuring service_conf.yaml..."
rm -rf /var/task/conf/service_conf.yaml
while IFS= read -r line || [[ -n "$line" ]]; do
    # Use eval to interpret the variable with default values
    eval "echo \"$line\"" >> /var/task/conf/service_conf.yaml
done < /var/task/conf/service_conf.yaml.template
echo "$(date): Configuration complete."

# Nginx was removed as it's not compatible with AWS Lambda environments
# AWS Lambda uses API Gateway for HTTP request routing
echo "$(date): Setting up environment..."

export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu/
echo "$(date): LD_LIBRARY_PATH set to $LD_LIBRARY_PATH"

PY=python3
echo "$(date): Using Python interpreter: $PY"

if [[ -z "$WS" || $WS -lt 1 ]]; then
  WS=1
  echo "$(date): Setting default worker count: $WS"
else
  echo "$(date): Worker count set to: $WS"
fi

# Display Python version and environment details
$PY --version
echo "$(date): Python path: $PYTHONPATH"
echo "$(date): Virtual env: $VIRTUAL_ENV"

# Uncomment to use task executor with jemalloc if needed
# function task_exe(){
#     JEMALLOC_PATH=$(pkg-config --variable=libdir jemalloc)/libjemalloc.so
#     while [ 1 -eq 1 ];do
#       echo "$(date): Starting task executor $1"
#       LD_PRELOAD=$JEMALLOC_PATH $PY rag/svr/task_executor.py $1;
#       echo "$(date): Task executor $1 exited, restarting..."
#       sleep 1
#     done
# }

# for ((i=0;i<WS;i++))
# do
#   echo "$(date): Launching task executor $i"
#   task_exe $i &
# done

echo "$(date): Starting main application loop"
echo "$(date): Python executable: $(which $PY)"
echo "$(date): Application file: api/ragflow_server_apprunner.py"

# Print system info
echo "$(date): System information:"
echo "Memory:"
free -h
echo "Disk:"
df -h
echo "CPU:"
lscpu | head -15

# Main application loop with error logging
while [ 1 -eq 1 ]; do
    echo "$(date): Starting ragflow_server_apprunner.py"
    
    # Run with output logging to stderr
    $PY api/ragflow_server_apprunner.py 2>&1 | { 
        while IFS= read -r line; do
            echo "$(date) [APP] $line"
        done
    }
    
    echo "$(date): Application exited with code $?, restarting in 2 seconds..."
    sleep 2
done

wait;
