#!/bin/sh
set -e

# Project name from environment or default to 'dozzle'
PROJECT_NAME=${COMPOSE_PROJECT_NAME:-dozzle}

# Container names
MANAGER_CONTAINER="${PROJECT_NAME}-manager-1"
WORKER1_CONTAINER="${PROJECT_NAME}-worker1-1"
WORKER2_CONTAINER="${PROJECT_NAME}-worker2-1"
WORKER3_CONTAINER="${PROJECT_NAME}-worker3-1"

# Function to run a command with error handling
run_command() {
  local description="$1"
  local host="${2:-manager}"  # Default to manager if host not specified
  shift 2  # Remove first two arguments (description and host)
  
  echo "=== $description ==="
  echo "Command on $host: $*"
  
  # Set DOCKER_HOST based on the container
  if [ "$host" != "localhost" ]; then
    export DOCKER_HOST="tcp://$host:2375"
  else
    unset DOCKER_HOST
  fi
  
  if ! docker "$@"; then
    echo "ERROR: Command failed with status $?"
    return 1
  fi
  
  echo "=== End of $description ==="
  return 0
}

# Wait for a service to be ready
wait_for_service() {
  local service="$1"
  local host="${2:-manager}"  # Default to manager if host not specified
  shift 2  # Remove first two arguments (service and host)
  local max_attempts=30
  local attempt=0
  
  # Set DOCKER_HOST based on the container
  if [ "$host" != "localhost" ]; then
    export DOCKER_HOST="tcp://$host:2375"
  else
    unset DOCKER_HOST
  fi
  
  echo "Waiting for $service on $host to be ready..."
  until docker info >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ $attempt -ge $max_attempts ]; then
      echo "$service is not ready after $max_attempts attempts, giving up"
      return 1
    fi
    echo "$service not ready yet, waiting... (attempt $attempt/$max_attempts)"
    sleep 2
  done
  echo "$service is ready!"
  return 0
}

# Main execution
echo "=== Starting Swarm Setup ==="

# Check if manager is already in a swarm
echo "=== Checking if manager is already in a swarm ==="
if docker -H tcp://manager:2375 node ls >/dev/null 2>&1; then
  echo "Manager is already part of a swarm"
  MANAGER_IP="manager"
else
  echo "Initializing new swarm on manager"
  if ! docker -H tcp://manager:2375 swarm init --advertise-addr manager; then
    echo "ERROR: Failed to initialize swarm on manager"
    exit 1
  fi
  MANAGER_IP="manager"
fi

echo "Using manager host: $MANAGER_IP"


# Get join token for workers
echo ""
echo "=== Getting join token from manager ==="
JOIN_TOKEN=$(docker -H tcp://manager:2375 swarm join-token -q worker 2>/dev/null | tr -d '[:space:]')

if [ -z "$JOIN_TOKEN" ] || [ ${#JOIN_TOKEN} -lt 30 ]; then
  echo "ERROR: Failed to get valid join token from manager"
  docker exec -i "$MANAGER_CONTAINER" docker node ls
  exit 1
fi

echo "Join token: $JOIN_TOKEN"

# Add workers to the swarm
for worker in "$WORKER1_CONTAINER" "$WORKER2_CONTAINER" "$WORKER3_CONTAINER"; do
  echo ""
  echo "=== Processing $worker ==="
  
  # Wait for worker Docker daemon to be ready
  if ! wait_for_service "$worker Docker daemon" "$worker" info; then
    echo "WARNING: Failed to connect to $worker's Docker daemon, skipping..."
    continue
  fi
  
  # Check if worker is already in the swarm
  if docker -H tcp://$worker:2375 info 2>&1 | grep -q "Swarm: active"; then
    echo "$worker is already part of a swarm, skipping..."
    continue
  fi
  
  # Join worker to swarm
  echo "$worker joining swarm at $MANAGER_IP:2377..."
  MAX_RETRIES=3
  RETRY_COUNT=0
  
  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "Attempting to join worker to swarm at $MANAGER_IP:2377..."
    if docker -H tcp://$worker:2375 swarm join --advertise-addr "$worker" --token "$JOIN_TOKEN" "$MANAGER_IP:2377"; then
      echo "Successfully joined $worker to the swarm"
      break
    else
      RETRY_COUNT=$((RETRY_COUNT + 1))
      if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "WARNING: Failed to join $worker to the swarm after $MAX_RETRIES attempts"
      else
        echo "Retry $RETRY_COUNT/$MAX_RETRIES: Failed to join $worker to the swarm, retrying in 5 seconds..."
        sleep 5
      fi
    fi
  done
done

# Deploy Dozzle stack on the manager
echo ""
echo "=== Deploying Dozzle Stack ==="
if [ -f "/swarm/docker-stack.yml" ]; then
  echo "Found Dozzle stack configuration, deploying..."
  if DOCKER_HOST=tcp://manager:2375 docker stack deploy -c /swarm/docker-stack.yml dozzle; then
    echo "Dozzle stack deployed successfully!"
  else
    echo "WARNING: Failed to deploy Dozzle stack"
  fi
else
  echo "WARNING: Dozzle stack configuration not found at /swarm/docker-stack.yml"
fi

echo ""
echo "=== Swarm Setup Complete ==="
docker node ls

# If we have a manager IP, show the Dozzle URL
if [ -n "$MANAGER_IP" ]; then
  echo "Access Dozzle at: http://$MANAGER_IP:8080"
fi

echo ""
echo "=== Setup Complete ==="
docker node ls 2>/dev/null || echo "Not in swarm mode or not a manager node"