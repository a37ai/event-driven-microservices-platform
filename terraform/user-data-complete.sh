#!/bin/bash
# Event-Driven Microservices Platform - Minimal EC2 Initialization (Registry + Grafana only)
# This script runs automatically on EC2 instance startup and deploys the platform

set -e

# Redirect all output to log file
exec > >(tee /var/log/user-data.log) 2>&1

echo "Starting minimal EDMP initialization (Registry + Grafana only)..."

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
docker pull registry:latest
docker pull grafana/grafana:latest

# Create necessary volumes
echo "Creating Docker volumes..."
docker volume create registry-stuff || true
docker volume create grafana-storage || true

# Get the public IP of this instance
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Your IP is: $PUBLIC_IP"

# Change to the platform directory
cd /home/ec2-user/edmp-platform

# Create the docker-compose file with only Registry and Grafana
echo "Creating docker-compose configuration..."
cat > docker-compose-dev.yml << EOF
version: '2'
networks:
  prodnetwork:
    driver: bridge
volumes:
  registry-stuff:
    driver: local
  grafana-storage:
    driver: local
services:
  registry:
    image: registry
    ports:
      - "5000:5000"
    networks:
      - prodnetwork
    volumes:
      - registry-stuff:/var/lib/registry
  grafana:
    image: grafana/grafana:latest
    ports:
      - "10001:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_SECURITY_ADMIN_USER=admin
    networks:
      - prodnetwork
    volumes:
      - grafana-storage:/var/lib/grafana
EOF

# Set ownership
chown ec2-user:ec2-user docker-compose-dev.yml

# Deploy the platform automatically
echo "Deploying minimal EDMP Platform..."
docker-compose -f docker-compose-dev.yml up -d

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 30

# Check service status
echo "Checking service status..."
docker-compose -f docker-compose-dev.yml ps

# Ensure all containers are running
echo "Verifying container health..."
docker ps -a

# Display service URLs
echo ""
echo "=============================================="
echo "🚀 Minimal EDMP Platform deployed successfully!"
echo "=============================================="
echo ""
echo "Services available at:"
echo "Registry: http://$PUBLIC_IP:5000"
echo "Grafana: http://$PUBLIC_IP:10001"
echo ""
echo "=============================================="
echo "Default Credentials:"
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

echo "✅ Minimal EDMP Platform initialization and deployment completed successfully!"
echo "User-data script completed at $(date)"

# Create completion marker for remote-exec provisioner
touch /tmp/user-data-complete

# Explicitly exit the script to ensure it terminates
echo "Exiting user-data script..."
exit 0