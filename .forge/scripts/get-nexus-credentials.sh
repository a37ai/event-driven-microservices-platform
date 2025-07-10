#!/bin/bash
set -e

# Nexus Credential Extraction Script
# Usage: ./get-nexus-credentials.sh <instance_ip> <ssh_key_path>

INSTANCE_IP=${1}
SSH_KEY=${2}

if [ -z "$INSTANCE_IP" ] || [ -z "$SSH_KEY" ]; then
    echo "Usage: $0 <instance_ip> <ssh_key_path>"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Extracting Nexus credentials from $INSTANCE_IP..."

# Wait for Nexus to be ready
echo "Waiting for Nexus to be ready..."
MAX_ATTEMPTS=60
ATTEMPT=1
NEXUS_URL="http://${INSTANCE_IP}:8081"

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    if curl -sf "${NEXUS_URL}/service/rest/v1/status" >/dev/null 2>&1; then
        break
    fi
    echo "Attempt $ATTEMPT/$MAX_ATTEMPTS - Nexus not ready yet..."
    sleep 10
    ATTEMPT=$((ATTEMPT + 1))
done

if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    echo -e "${RED}Nexus failed to start within $(($MAX_ATTEMPTS * 10)) seconds${NC}"
    exit 1
fi

echo -e "${GREEN}Nexus is ready!${NC}"

# Get Nexus admin password
echo "Getting Nexus admin password..."
NEXUS_PASSWORD=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ec2-user@${INSTANCE_IP} \
    "docker exec \$(docker ps -qf 'name=nexus') cat /nexus-data/admin.password 2>/dev/null | tr -d '\n' || echo 'not-found'")

if [ "$NEXUS_PASSWORD" = "not-found" ]; then
    echo -e "${RED}Failed to get Nexus admin password${NC}"
    # Try alternative path
    NEXUS_PASSWORD=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ec2-user@${INSTANCE_IP} \
        "docker exec \$(docker ps -qf 'name=nexus') find /opt/sonatype-work -name 'admin.password' -exec cat {} \; 2>/dev/null | tr -d '\n' || echo 'still-not-found'")
    
    if [ "$NEXUS_PASSWORD" = "still-not-found" ]; then
        echo -e "${YELLOW}Warning: Could not retrieve admin password automatically${NC}"
        echo -e "${YELLOW}Please SSH into the instance and check: docker exec \$(docker ps -qf 'name=nexus') cat /nexus-data/admin.password${NC}"
        NEXUS_PASSWORD="check-manually"
    fi
fi

# Verify credentials work
if [ "$NEXUS_PASSWORD" != "check-manually" ]; then
    echo "Verifying credentials..."
    if curl -u "admin:${NEXUS_PASSWORD}" -sf "${NEXUS_URL}/service/rest/v1/status" >/dev/null 2>&1; then
        echo -e "${GREEN}Credentials verified successfully!${NC}"
    else
        echo -e "${YELLOW}Warning: Credentials could not be verified${NC}"
    fi
fi

# Output credentials in the required format
echo ""
echo "=== NEXUS CREDENTIALS ==="
echo "NEXUS_URL=${NEXUS_URL}"
echo "NEXUS_USERNAME=admin"
echo "NEXUS_PASSWORD=${NEXUS_PASSWORD}"
echo "========================="