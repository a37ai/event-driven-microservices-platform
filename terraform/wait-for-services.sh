#!/bin/bash
set -e

echo "Waiting for services to be ready..."

# Function to check if a service is responding
check_service() {
  local service_name=$1
  local url=$2
  local max_attempts=60
  local attempt=0
  
  echo "Checking $service_name at $url..."
  
  while [ $attempt -lt $max_attempts ]; do
    if curl -s -o /dev/null -w "%{http_code}" "$url" | grep -q "200\|302\|401"; then
      echo "✓ $service_name is ready!"
      return 0
    fi
    
    echo "  Attempt $((attempt + 1))/$max_attempts: $service_name not ready yet..."
    sleep 10
    attempt=$((attempt + 1))
  done
  
  echo "✗ $service_name failed to start after $max_attempts attempts"
  return 1
}

# Wait for Docker to be ready
echo "Waiting for Docker..."
while ! sudo docker ps >/dev/null 2>&1; do
  echo "  Docker not ready yet..."
  sleep 5
done
echo "✓ Docker is ready!"

# Check if docker-compose exists
if ! command -v docker-compose &> /dev/null; then
  echo "docker-compose not found, waiting for installation..."
  sleep 30
fi

# Check Docker containers
echo "Checking Docker containers..."
sudo docker ps

# Get the server IP
SERVER_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Server IP: $SERVER_IP"

# Check each service
check_service "Jenkins" "http://localhost:8080"
check_service "Nexus" "http://localhost:8081"
check_service "SonarQube" "http://localhost:9000"
check_service "Kafka Manager" "http://localhost:9001"
check_service "Spring Boot Admin" "http://localhost:10001"

echo "All services are ready!" 