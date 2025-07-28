#!/bin/bash
# EDMP Platform Application Deployment Script
# This script can be run on the EC2 instance to deploy the platform manually

set -e

echo "Starting EDMP Platform deployment..."

# Get the public IP of this instance
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Your IP is: $PUBLIC_IP"

# Create the platform directory
mkdir -p ~/edmp-platform
cd ~/edmp-platform

# Create the docker-compose file with correct ports
cat > docker-compose-dev.yml << EOF
version: '2'
networks:
  prodnetwork:
    driver: bridge
volumes:
  registry-stuff:
    driver: local
services:
  kafka:
    image: spotify/kafka
    ports:
      - "2181:2181"
      - "9092:9092"
      - "7209:7209"
    environment:
      JMX_PORT: 7209
      ADVERTISED_HOST: $PUBLIC_IP
      ADVERTISED_PORT: 9092
    networks:
      - prodnetwork
  kafka-manager:
    image: sheepkiller/kafka-manager
    ports:
      - "9001:9000"
    environment:
      ZK_HOSTS: kafka:2181
    networks:
      - prodnetwork
    depends_on:
      - kafka

  registry:
    image: registry
    ports:
      - "5000:5000"
    networks:
      - prodnetwork
  sonar:
    image: sonarqube:9.0-community
    ports:
      - "9000:9000"
    environment:
      - SONARQUBE_JDBC_URL=jdbc:postgresql://sonardb:5432/sonar
    depends_on:
      - sonardb
    networks:
      - prodnetwork
  sonardb:
    image: postgres
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_USER=sonar
      - POSTGRES_PASSWORD=sonar
    networks:
      - prodnetwork
  edmp-monitoring:
    image: nginx:alpine
    ports:
      - "10001:80"
    networks:
      - prodnetwork
EOF

# Create Docker volume
docker volume create registry-stuff || true

# Deploy the platform
docker-compose -f docker-compose-dev.yml up -d

# Function to check if a service is ready
check_service() {
    local service_name=$1
    local host=$2
    local port=$3
    local max_retries=50
    local retry_count=0
    
    echo "Checking $service_name at $host:$port..."
    
    while [ $retry_count -lt $max_retries ]; do
        if curl -s --connect-timeout 5 --max-time 10 "$host:$port" > /dev/null 2>&1; then
            echo "✅ $service_name is ready!"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        echo "⏳ $service_name not ready yet (attempt $retry_count/$max_retries)..."
        sleep 5
    done
    
    echo "❌ $service_name failed to start after $max_retries attempts"
    return 1
}

# Function to check if a TCP port is open
check_port() {
    local service_name=$1
    local host=$2
    local port=$3
    local max_retries=30
    local retry_count=0
    
    echo "Checking $service_name TCP port at $host:$port..."
    
    while [ $retry_count -lt $max_retries ]; do
        if nc -z -w5 "$host" "$port" 2>/dev/null; then
            echo "✅ $service_name port is open!"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        echo "⏳ $service_name port not ready yet (attempt $retry_count/$max_retries)..."
        sleep 5
    done
    
    echo "❌ $service_name port failed to open after $max_retries attempts"
    return 1
}

# Wait for services to start with retry mechanism
echo "Waiting for services to start..."
echo "This may take a few minutes..."

# Check critical services
failed_services=()



# Check SonarQube
if ! check_service "SonarQube" "$PUBLIC_IP" "9000"; then
    failed_services+=("SonarQube")
fi

# Check Kafka Manager
if ! check_service "Kafka Manager" "$PUBLIC_IP" "9001"; then
    failed_services+=("Kafka Manager")
fi

# Check Monitoring
if ! check_service "Monitoring" "$PUBLIC_IP" "10001"; then
    failed_services+=("Monitoring")
fi

# Check Registry
if ! check_service "Registry" "$PUBLIC_IP" "5000"; then
    failed_services+=("Registry")
fi

# Check Kafka and Zookeeper ports
if ! check_port "Kafka" "$PUBLIC_IP" "9092"; then
    failed_services+=("Kafka")
fi

if ! check_port "Zookeeper" "$PUBLIC_IP" "2181"; then
    failed_services+=("Zookeeper")
fi

# Report results
if [ ${#failed_services[@]} -eq 0 ]; then
    echo ""
    echo "🎉 All services are ready!"
else
    echo ""
    echo "⚠️  Some services failed to start: ${failed_services[*]}"
    echo "You can check the logs with: docker-compose -f docker-compose-dev.yml logs"
fi

# Check service status
echo "Checking service status..."
docker-compose -f docker-compose-dev.yml ps

# Display service URLs
echo ""
echo "=============================================="
echo "🚀 EDMP Platform deployed successfully!"
echo "=============================================="
echo ""
echo "Service URLs:"
echo "SonarQube:      http://$PUBLIC_IP:9000"
echo "Kafka Manager:  http://$PUBLIC_IP:9001"
echo "Monitoring:     http://$PUBLIC_IP:10001"
echo "Registry:       http://$PUBLIC_IP:5000"
echo ""
echo "Kafka Bootstrap: $PUBLIC_IP:9092"
echo "Zookeeper:       $PUBLIC_IP:2181"
echo ""
echo "=============================================="
echo "Default Credentials:"
echo "SonarQube:  admin/admin"
echo "=============================================="