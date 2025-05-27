#!/bin/sh
# Waits for DIND containers to be ready
# Then joins them to the swarm
# Then runs dozzle setup

set -e

# Project name from environment or default to 'dozzle'
PROJECT_NAME=${COMPOSE_PROJECT_NAME:-dozzle}

# Container names and their hostnames
MANAGER_CONTAINER="${PROJECT_NAME}-manager-1"
MANAGER_HOST="manager"
WORKER1_CONTAINER="${PROJECT_NAME}-worker1-1"
WORKER1_HOST="worker1"
WORKER2_CONTAINER="${PROJECT_NAME}-worker2-1"
WORKER2_HOST="worker2"
WORKER3_CONTAINER="${PROJECT_NAME}-worker3-1"
WORKER3_HOST="worker3"

# Function to run a command on a container's Docker daemon
run_docker() {
  local host="$1"
  shift
  DOCKER_HOST="tcp://$host:2375" docker "$@"
}

# Function to run a command with error handling
run_command() {
  local description="$1"
  local host="$2"
  shift 2
  
  echo "=== $description ==="
  echo "Command on $host: $*"
  
  if ! run_docker "$host" "$@"; then
    echo "ERROR: Command failed with status $?"
    return 1
  fi
  
  echo "=== End of $description ==="
  return 0
}

# Wait for a service to be ready
wait_for_service() {
  local service="$1"
  local host="$2"
  local max_attempts=30
  local attempt=0
  
  echo "Waiting for $service on $host to be ready..."
  
  while [ $attempt -lt $max_attempts ]; do
    if run_docker "$host" info >/dev/null 2>&1; then
      echo "$service is ready!"
      return 0
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
  # Wait for all Docker daemons to be ready
  wait_for_service "Manager Docker daemon" "$MANAGER_HOST"
  wait_for_service "Worker1 Docker daemon" "$WORKER1_HOST"
  wait_for_service "Worker2 Docker daemon" "$WORKER2_HOST"
  wait_for_service "Worker3 Docker daemon" "$WORKER3_HOST"

  # List docker compose DIND containers
  echo "=== Docker containers ==="
  run_docker "$MANAGER_HOST" ps -a

  # Initialize swarm on manager if not already initialized
  if ! run_docker "$MANAGER_HOST" node ls &> /dev/null; then
    echo "Initializing new swarm on manager"
    
    # Get the manager's IP in the overlay network
    MANAGER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $MANAGER_CONTAINER)
    
    if [ -z "$MANAGER_IP" ]; then
      echo "ERROR: Could not get manager IP address"
      exit 1
    fi
    
    echo "Initializing swarm with manager IP: $MANAGER_IP"
    
    # Initialize the swarm with the manager's IP
    if ! run_command "Initializing Swarm on manager" "$MANAGER_HOST" \
         swarm init --advertise-addr "$MANAGER_IP:2377" --listen-addr "0.0.0.0:2377"; then
      echo "ERROR: Failed to initialize swarm on manager"
      exit 1
    fi
    
    # Get join tokens
    WORKER_TOKEN=$(run_docker "$MANAGER_HOST" swarm join-token -q worker)
    if [ -z "$WORKER_TOKEN" ]; then
      echo "ERROR: Failed to get worker join token"
      exit 1
    fi
    
    # Join worker nodes to the swarm
    for worker in "$WORKER1_HOST" "$WORKER2_HOST" "$WORKER3_HOST"; do
      WORKER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${PROJECT_NAME}-${worker}-1")
      echo "Joining $worker ($WORKER_IP) to the swarm..."
      
      if ! run_command "Joining $worker to swarm" "$worker" \
           swarm join --token "$WORKER_TOKEN" --advertise-addr "$WORKER_IP:2377" \
           --listen-addr "0.0.0.0:2377" "$MANAGER_IP:2377"; then
        echo "WARNING: Failed to join $worker to the swarm"
      fi
    done
    
    # Show swarm nodes
    echo "=== Swarm nodes ==="
    run_command "List swarm nodes" "$MANAGER_HOST" node ls
  else
    echo "Swarm already initialized on manager"
  fi
  
  echo "=== Swarm setup complete ==="
  echo "Manager IP: $MANAGER_IP"
  echo "To access the swarm manager:"
  echo "  export DOCKER_HOST=tcp://$MANAGER_IP:2375"
  echo "  docker node ls"
  
  # Show the final swarm status
  run_command "Final swarm status" "$MANAGER_HOST" node ls
}

# Start the main function
echo "=== Starting Swarm Setup ==="
main "$@"

# Exit with success if we reach this point
echo "Swarm setup completed successfully"

echo "Building example swarm-app..."
docker compose exec --workdir /swarm/app manager \
  ls -l
docker compose exec --workdir /swarm/app manager \
  docker build -t swarm-app .
docker compose exec manager \
  docker tag swarm-app 127.0.0.1:5000/swarm-app

echo "Deploying swarm..."
docker compose exec manager \
  docker stack deploy -c /swarm/docker-stack.yml dozzle

until run_docker "$MANAGER_HOST" stack ls | grep dozzle; do
  echo "Waiting for swarm to be deployed..."
  sleep 5
done 

echo "Pushing swarm-app:latest to local-docker-registry..."
docker compose exec manager \
  docker push 127.0.0.1:5000/swarm-app

echo "Scaling swarm-app to 2 replicas..."
# This should download the image
docker compose exec manager \
  docker service scale dozzle_app=2

exit 0
