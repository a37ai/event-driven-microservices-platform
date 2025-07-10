#!/bin/bash
# EDMP Platform Monitoring Script
# Run this on the EC2 instance to check platform status

echo "EDMP Platform Status:"
echo "===================="

# Check Docker daemon
if ! sudo systemctl is-active --quiet docker; then
    echo "❌ Docker service is not running"
    exit 1
else
    echo "✅ Docker service is running"
fi

# Check if project directory exists
if [ ! -d "$HOME/edmp-platform" ]; then
    echo "❌ Project directory not found. Platform may not be deployed."
    exit 1
fi

cd "$HOME/edmp-platform"

# Check if docker-compose file exists
if [ ! -f docker-compose-dev.yml ]; then
    echo "❌ docker-compose-dev.yml not found in project directory."
    exit 1
fi

# Check running containers
echo ""
echo "Running containers:"
docker-compose -f docker-compose-dev.yml ps

# Check system resources
echo ""
echo "System Resources:"
echo "CPU Usage: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)%"
echo "Memory Usage: $(free -m | awk '/^Mem:/{printf "%.1f%%\n", $3/$2*100}')"
echo "Disk Usage: $(df -h / | awk '/\//{print $5}')"

# Check service endpoints
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo ""
echo "Service Health Check:"
services=(
    "Jenkins:8080"
    "Nexus:8081"
    "SonarQube:9000"
    "Kafka Manager:9001"
    "Monitoring:10001"
    "Registry:5000"
)

for service in "${services[@]}"; do
    name=$(echo $service | cut -d':' -f1)
    port=$(echo $service | cut -d':' -f2)
    if nc -z localhost $port 2>/dev/null; then
        echo "✅ $name (port $port) is responding"
    else
        echo "❌ $name (port $port) is not responding"
    fi
done

echo ""
echo "Service URLs:"
echo "Jenkins:        http://$PUBLIC_IP:8080"
echo "Nexus:          http://$PUBLIC_IP:8081"
echo "SonarQube:      http://$PUBLIC_IP:9000"
echo "Kafka Manager:  http://$PUBLIC_IP:9001"
echo "Monitoring:     http://$PUBLIC_IP:10001"
echo "Registry:       http://$PUBLIC_IP:5000"