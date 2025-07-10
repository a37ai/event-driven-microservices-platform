#!/bin/bash
# Event-Driven Microservices Platform - Complete EC2 Initialization and Auto-Deploy Script
# This script runs automatically on EC2 instance startup and deploys the platform

set -e

# Redirect all output to log file
exec > >(tee /var/log/user-data.log) 2>&1

echo "Starting complete EDMP initialization and auto-deployment..."

# Update system packages
echo "Updating system packages..."
yum update -y

# Install required packages
echo "Installing required packages..."
yum install -y \
    docker \
    git \
    curl \
    wget \
    unzip \
    jq \
    htop \
    tree

# Install Docker Compose
echo "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Start and enable Docker service
echo "Starting Docker service..."
systemctl start docker
systemctl enable docker

# Add ec2-user to docker group
usermod -a -G docker ec2-user

# Set up Docker daemon configuration for better performance
echo "Configuring Docker daemon..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2"
}
EOF

# Restart Docker to apply configuration
systemctl restart docker

# Test Docker installation
echo "Testing Docker installation..."
docker --version
docker-compose --version

# Create necessary directories
mkdir -p /home/ec2-user/edmp-platform
chown -R ec2-user:ec2-user /home/ec2-user/edmp-platform

# Pre-pull Docker images to speed up deployment
echo "Pre-pulling Docker images..."
docker pull postgres:latest
docker pull registry:latest
docker pull nginx:alpine
docker pull spotify/kafka:latest
docker pull sheepkiller/kafka-manager:latest
docker pull sonatype/nexus3:latest
docker pull jenkins/jenkins:lts
docker pull sonarqube:9.0-community

# Create necessary volumes
echo "Creating Docker volumes..."
docker volume create registry-stuff || true

# Get the public IP of this instance
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Your IP is: $PUBLIC_IP"

# Change to the platform directory
cd /home/ec2-user/edmp-platform

# Create the docker-compose file with the exact format you specified
echo "Creating docker-compose configuration..."
echo "version: '2'
networks:
  prodnetwork:
    driver: bridge
volumes:
  registry-stuff:
    driver: local
  grafana-storage:
    driver: local
  jenkins_home:
    driver: local
services:
  kafka:
    image: spotify/kafka
    ports:
      - \"2181:2181\"
      - \"9092:9092\"
      - \"7209:7209\"
    environment:
      JMX_PORT: 7209
      ADVERTISED_HOST: $PUBLIC_IP
      ADVERTISED_PORT: 9092
    networks:
      - prodnetwork
  kafka-manager:
    image: sheepkiller/kafka-manager
    ports:
      - \"9001:9000\"
    environment:
      ZK_HOSTS: kafka:2181
    networks:
      - prodnetwork
    depends_on:
      - kafka
  nexus:
    image: sonatype/nexus3:latest
    ports:
      - \"8081:8081\"
    networks:
      - prodnetwork
  jenkins:
    image: jenkins/jenkins:lts
    ports:
      - \"8080:8080\"
    environment:
      - JAVA_OPTS=-Djenkins.install.runSetupWizard=false -Djenkins.security.csrf.protection=true
      - JENKINS_ADMIN_ID=admin
      - JENKINS_ADMIN_PASSWORD=admin123
    volumes:
      - jenkins_home:/var/jenkins_home
    networks:
      - prodnetwork
  registry:
    image: registry
    ports:
      - \"5000:5000\"
    networks:
      - prodnetwork
  sonar:
    image: sonarqube:9.0-community
    ports:
      - \"9000:9000\"
    environment:
      - SONARQUBE_JDBC_URL=jdbc:postgresql://sonardb:5432/sonar
    depends_on:
      - sonardb
    networks:
      - prodnetwork
  sonardb:
    image: postgres
    ports:
      - \"5432:5432\"
    environment:
      - POSTGRES_USER=sonar
      - POSTGRES_PASSWORD=sonar
    networks:
      - prodnetwork
  grafana:
    image: grafana/grafana:latest
    ports:
      - \"10001:3000\"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_SECURITY_ADMIN_USER=admin
    networks:
      - prodnetwork
    volumes:
      - grafana-storage:/var/lib/grafana" > docker-compose-dev.yml

# Set ownership
chown ec2-user:ec2-user docker-compose-dev.yml

# Deploy the platform automatically
echo "Deploying EDMP Platform..."
docker-compose -f docker-compose-dev.yml up -d

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 60

# Check service status
echo "Checking service status..."
docker-compose -f docker-compose-dev.yml ps

# Ensure all containers are running
echo "Verifying container health..."
docker ps -a

# Display service URLs
echo ""
echo "=============================================="
echo "🚀 EDMP Platform deployed successfully!"
echo "=============================================="
echo ""
echo "Services available at:"
echo "Jenkins: http://$PUBLIC_IP:8080"
echo "Nexus: http://$PUBLIC_IP:8081"
echo "SonarQube: http://$PUBLIC_IP:9000"
echo "Kafka Manager: http://$PUBLIC_IP:9001"
echo "Registry: http://$PUBLIC_IP:5000"
echo "Grafana: http://$PUBLIC_IP:10001"
echo ""
echo "Kafka Bootstrap: $PUBLIC_IP:9092"
echo "Zookeeper: $PUBLIC_IP:2181"
echo ""
echo "=============================================="
echo "Default Credentials:"
echo "Jenkins:    admin/[see initial password]"
echo "SonarQube:  admin/admin"
echo "Nexus:      admin/[see admin.password]"
echo "Grafana:    admin/admin"
echo "=============================================="

# Set up environment variables for ec2-user
echo "Setting up environment variables..."
cat >> /home/ec2-user/.bashrc << 'EOF'

# EDMP Platform Environment Variables
export EDMP_HOME="/home/ec2-user/edmp-platform"
export COMPOSE_PROJECT_NAME="edmp"
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

# Path additions
export PATH="/usr/local/bin:$PATH"

# Aliases for convenience
alias dc="docker-compose"
alias dps="docker ps"
alias dlogs="docker-compose logs -f"
alias dstop="docker-compose down"
alias dstart="docker-compose up -d"

# EDMP specific shortcuts
alias edmp-start="cd $EDMP_HOME && docker-compose -f docker-compose-dev.yml up -d"
alias edmp-stop="cd $EDMP_HOME && docker-compose -f docker-compose-dev.yml down"
alias edmp-logs="cd $EDMP_HOME && docker-compose -f docker-compose-dev.yml logs -f"
alias edmp-status="cd $EDMP_HOME && docker-compose -f docker-compose-dev.yml ps"
EOF

chown ec2-user:ec2-user /home/ec2-user/.bashrc

echo "✅ EDMP Platform initialization and deployment completed successfully!"
echo "User-data script completed at $(date)"

# Create completion marker for remote-exec provisioner
touch /tmp/user-data-complete

# Explicitly exit the script to ensure it terminates
echo "Exiting user-data script..."
exit 0