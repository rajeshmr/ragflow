#!/bin/bash

# Process ID as an argument
if [ -z "$1" ]; then
  echo "Usage: $0 <process_id>"
  exit 1
fi

PROCESS_ID=$1

# Run the command in the background and output to stdout
python rag/svr/task_executor.py $PROCESS_ID

echo "Task executor started for process ID $PROCESS_ID. Logs are being sent to stdout."