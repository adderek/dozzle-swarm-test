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
  if [ "$host" = "manager" ]; then
    # For the manager, use the local socket
    if ! docker -H unix:///var/run/docker.sock "$@"; then
      echo "ERROR: Command failed with status $?"
      return 1
    fi
  else
    # For workers, use TCP
    if ! DOCKER_HOST="tcp://$host:2375" docker "$@"; then
      echo "ERROR: Command failed with status $?"
      return 1
    fi
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
  
  echo "Waiting for $service on $host to be ready..."
  
  while [ $attempt -lt $max_attempts ]; do
    if [ "$host" = "manager" ]; then
      # For the manager, use the local socket
      if docker -H unix:///var/run/docker.sock info >/dev/null 2>&1; then
        echo "$service is ready!"
        return 0
      fi
    else
      # For workers, use TCP
      if DOCKER_HOST="tcp://$host:2375" docker info >/dev/null 2>&1; then
        echo "$service is ready!"
        return 0
      fi
    fi
    
    attempt=$((attempt + 1))
    echo "$service not ready yet, waiting... (attempt $attempt/$max_attempts)"
    sleep 2
  done
  
  echo "$service is not ready after $max_attempts attempts, giving up"
  return 1
}

# Main execution
main() {
  # Wait for manager Docker daemon to be ready
  wait_for_service "Manager Docker daemon" "manager"

  # List docker compose DIND containers
  docker -H unix:///var/run/docker.sock ps -a

  # FIXME: initialize swarm on the nodes, not on host

  # Initialize swarm on manager if not already initialized
  if ! docker -H unix:///var/run/docker.sock node ls &> /dev/null; then
    echo "Initializing new swarm on manager"
    
    # Get the manager container's IP address
    MANAGER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $MANAGER_CONTAINER)
    
    if [ -z "$MANAGER_IP" ]; then
      echo "ERROR: Could not get manager IP address"
      exit 1
    fi
    
    echo "Initializing swarm with manager IP: $MANAGER_IP"
    
    # Initialize the swarm with the manager's IP
    if ! docker -H unix:///var/run/docker.sock swarm init --advertise-addr $MANAGER_IP:2377; then
      echo "ERROR: Failed to initialize swarm on manager"
      exit 1
    fi
    
    echo "Swarm initialized successfully on manager ($MANAGER_IP)"
  else
    echo "Manager is already part of a swarm"
    
    # Get manager IP for joining workers
    MANAGER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $MANAGER_CONTAINER)
    if [ -z "$MANAGER_IP" ]; then
      echo "ERROR: Could not get manager IP address"
      exit 1
    fi
  fi
  
  echo "Using manager host: $MANAGER_IP"

  # Get join token
  echo ""
  echo "=== Getting join token from manager ==="
  JOIN_TOKEN=$(docker -H unix:///var/run/docker.sock swarm join-token -q worker 2>/dev/null)
  if [ -z "$JOIN_TOKEN" ]; then
    echo "ERROR: Failed to get join token"
    exit 1
  fi
  
  echo "Join token: $JOIN_TOKEN"

  # Join workers to the swarm
  for worker in $WORKER1_CONTAINER $WORKER2_CONTAINER $WORKER3_CONTAINER; do
    echo ""
    echo "=== Processing $worker ==="
    
    # Wait for worker Docker daemon to be ready
    wait_for_service "$worker Docker daemon" "$worker"
    
    # Check if worker is already in the swarm
    if DOCKER_HOST="tcp://$worker:2375" docker info 2>&1 | grep -q "Swarm: active"; then
      echo "$worker is already part of a swarm, skipping..."
      continue
    fi
    
    # Join worker to swarm
    echo "$worker joining swarm..."
    if ! DOCKER_HOST="tcp://$worker:2375" docker swarm join --token $JOIN_TOKEN $MANAGER_IP:2377; then
      echo "ERROR: Failed to join $worker to swarm"
      continue
    fi
    
    echo "Successfully joined $worker to swarm"
  done
  
  echo ""
  echo "=== Swarm setup complete ==="
  docker -H unix:///var/run/docker.sock node ls
}

# Start the main function
echo "=== Starting Swarm Setup ==="
main "$@"

# Exit with success if we reach this point
echo "Setup completed successfully"
exit 0
