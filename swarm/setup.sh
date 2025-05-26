#!/bin/sh
set -e

# Project name from environment or default to 'dozzle'
PROJECT_NAME=${COMPOSE_PROJECT_NAME:-dozzle}
# Use exact container names as seen in 'docker ps' output
MANAGER_CONTAINER="${PROJECT_NAME}-manager-1"
WORKER1_CONTAINER="${PROJECT_NAME}-worker1-1"
WORKER2_CONTAINER="${PROJECT_NAME}-worker2-1"
WORKER3_CONTAINER="${PROJECT_NAME}-worker3-1"

# Wait for a service to be ready
wait_for_service() {
  local service="$1"
  local cmd="$2"
  echo "Waiting for $service to be ready..."
  until eval "$cmd" >/dev/null 2>&1; do
    echo "$service not ready yet, waiting..."
    sleep 2
  done
  echo "$service is ready!"
}

# Initialize or join the swarm
initialize_swarm() {
  local max_attempts=5
  local attempt=1
  echo "Looking for manager container with name containing 'manager'..."
  # Get manager container ID by name
  echo "Searching for manager container with name: $MANAGER_CONTAINER"
  local manager_container=$(docker ps -q -f name=^${MANAGER_CONTAINER}$)
  
  if [ -z "$manager_container" ]; then
    echo "Available containers:"
    docker ps --format '{{.Names}}'
  fi

  if [ -z "$manager_container" ]; then
    echo "ERROR: Manager container not found!"
    return 1
  fi

  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt to initialize/join swarm..."
    
    # Check if already part of a swarm
    if docker exec -i $manager_container docker node ls >/dev/null 2>&1; then
      echo "Already part of a swarm, skipping initialization."
      return 0
    fi

    # Get the manager container's IP in the Docker network
    local manager_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $manager_container)
    
    if [ -z "$manager_ip" ]; then
      echo "Failed to get manager IP, attempt $attempt of $max_attempts..."
      sleep 5
      attempt=$((attempt + 1))
      continue
    fi

    echo "Initializing swarm on manager ($manager_container) with IP $manager_ip..."
    
    # Try to initialize swarm inside the manager container
    if docker exec -i $manager_container docker swarm init --advertise-addr $manager_ip; then
      echo "Successfully initialized swarm on manager"
      return 0
    else
      echo "Failed to initialize swarm, attempt $attempt of $max_attempts..."
      sleep 5
      attempt=$((attempt + 1))
    fi
  done

  echo "Failed to initialize or join swarm after $max_attempts attempts."
  echo "The setup will continue but the swarm might not be properly configured."
  return 1
}

# Main execution
echo "=== Starting Swarm Setup ==="

# Wait for manager to be ready
wait_for_service "manager" "docker info"

# Use manager container name for internal communication
echo "Using manager container: $MANAGER_CONTAINER"

# Initialize swarm on manager
if ! initialize_swarm; then
  echo "Failed to initialize swarm, but continuing with setup..."
fi

# Get join token for workers from the manager container
echo "Getting join token from manager container ($manager_container)..."
JOIN_TOKEN=$(docker exec -i $manager_container docker swarm join-token -q worker 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$JOIN_TOKEN" ]; then
  echo "Failed to get join token. Checking if manager is in swarm mode..."
  docker exec -i $manager_container docker info | grep -i swarm
  echo "Manager container logs:"
  docker logs $manager_container || true
  echo "WARNING: Failed to get join token from manager. Cannot add workers to the swarm."
  echo "Trying to get node status from manager..."
  docker exec -i $manager_container docker node ls || true
  echo "Manager container ID: $manager_container"
  echo "Manager container logs:"
  docker logs $manager_container || true
  exit 1
else
  echo "Successfully obtained join token from manager"
  echo "Successfully obtained join token for workers from manager $manager_container"
  
  # Add workers to the swarm
  for worker in $WORKER1_CONTAINER $WORKER2_CONTAINER $WORKER3_CONTAINER; do
    echo -e "\n=== Processing $worker ==="
    
    # Get worker container ID
    echo "Looking for worker container: $worker"
    WORKER_CONTAINER=$(docker ps -q -f name=^${worker}$)
    if [ -z "$WORKER_CONTAINER" ]; then
      echo "WARNING: Could not find container for $worker, skipping..."
      echo "Available containers:"
      docker ps --format '{{.Names}}'
      continue
    fi
    
    # Wait for worker Docker daemon
    if ! wait_for_service "$worker Docker daemon" "docker exec -i $WORKER_CONTAINER docker info" 2>/dev/null; then
      echo "WARNING: Failed to connect to $worker's Docker daemon, skipping..."
      continue
    fi
    
    # Check if worker is already in the swarm
    if docker exec -i $WORKER_CONTAINER docker info 2>&1 | grep -q "Swarm: active"; then
      echo "$worker is already part of a swarm, skipping..."
      continue
    fi
    
    # Get manager's IP in the container network
    MANAGER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $manager_container)
    if [ -z "$MANAGER_IP" ]; then
      echo "WARNING: Could not get manager IP, skipping $worker..."
      continue
    fi
    
    # Join worker to swarm
    echo "$worker joining swarm at $MANAGER_IP:2377..."
    MAX_RETRIES=3
    RETRY_COUNT=0
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
      if docker exec -i $WORKER_CONTAINER docker swarm join --token $JOIN_TOKEN $MANAGER_IP:2377; then
        echo "Successfully joined $worker to the swarm"
        break
      else
        RETRY_COUNT=$((RETRY_COUNT+1))
        if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
          echo "WARNING: Failed to join $worker to the swarm after $MAX_RETRIES attempts"
        else
          echo "Retry $RETRY_COUNT/$MAX_RETRIES: Failed to join $worker to the swarm, retrying in 5 seconds..."
          sleep 5
        fi
      fi
    done
  done
fi

# Deploy Dozzle stack if we're the manager
if docker node ls >/dev/null 2>&1; then
  echo -e "\n=== Deploying Dozzle Stack ==="
  if [ -f "/swarm/docker-stack.yml" ]; then
    echo "Found Dozzle stack configuration, deploying..."
    if docker stack deploy -c /swarm/docker-stack.yml dozzle; then
      echo "Dozzle stack deployed successfully!"
      echo "Access Dozzle at: http://$MANAGER_IP:8080"
    else
      echo "WARNING: Failed to deploy Dozzle stack"
    fi
  else
    echo "WARNING: Dozzle stack configuration not found at /swarm/docker-stack.yml"
  fi
else
  echo -e "\nNot a swarm manager, skipping Dozzle deployment."
fi

echo -e "\n=== Setup Complete ==="
docker node ls 2>/dev/null || echo "Not in swarm mode or not a manager node"