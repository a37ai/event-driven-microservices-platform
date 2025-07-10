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
  nexus:
    image: sonatype/nexus3:latest
    ports:
      - "8081:8081"
    networks:
      - prodnetwork
  jenkins:
    image: jenkins/jenkins:lts
    ports:
      - "8080:8080"
    networks:
      - prodnetwork
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

# Wait for services to start
echo "Waiting for services to start..."
sleep 60

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
echo "Jenkins:        http://$PUBLIC_IP:8080"
echo "Nexus:          http://$PUBLIC_IP:8081"
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
echo "Jenkins:    admin/admin"
echo "SonarQube:  admin/admin"
echo "Nexus:      admin/admin123"
echo "=============================================="