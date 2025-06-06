#!/bin/bash

# Check if label argument is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <label>"
    echo "Example: $0 v1.0"
    exit 1
fi

# Store the label from argument
LABEL=$1

echo "Building and pushing Docker image with label: $LABEL"

# Build the Docker image
docker build --platform linux/amd64 --build-arg LIGHTEN=1 -f Dockerfile.worker -t ragflow-worker:$LABEL .

# Tag the image for ECR (FIXED: changed ragflow to ragflow-worker)
docker tag ragflow-worker:$LABEL 304975023707.dkr.ecr.us-east-1.amazonaws.com/ragflow-worker:$LABEL

# Push the image to ECR
docker push 304975023707.dkr.ecr.us-east-1.amazonaws.com/ragflow-worker:$LABEL

echo "Successfully built and pushed ragflow-worker:$LABEL to ECR"