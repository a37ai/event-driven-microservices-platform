#!/bin/bash
set -e

# Grafana Credential Extraction Script
# Usage: ./get-grafana-credentials.sh <instance_ip> <ssh_key_path>

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

echo "Extracting Grafana credentials from $INSTANCE_IP..."

# Wait for Grafana to be ready
echo "Waiting for Grafana to be ready..."
MAX_ATTEMPTS=30
ATTEMPT=1
GRAFANA_URL="http://${INSTANCE_IP}:10001"

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    if curl -sf "${GRAFANA_URL}/api/health" >/dev/null 2>&1; then
        break
    fi
    echo "Attempt $ATTEMPT/$MAX_ATTEMPTS - Grafana not ready yet..."
    sleep 10
    ATTEMPT=$((ATTEMPT + 1))
done

if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    echo -e "${RED}Grafana failed to start within $(($MAX_ATTEMPTS * 10)) seconds${NC}"
    exit 1
fi

echo -e "${GREEN}Grafana is ready!${NC}"

# Verify default credentials work
echo "Verifying default credentials (admin/admin)..."
if curl -u "admin:admin" -sf "${GRAFANA_URL}/api/user" >/dev/null 2>&1; then
    echo -e "${GREEN}Default credentials verified!${NC}"
    
    # Generate Grafana API key using new service account method
    echo "Creating Grafana service account and token..."
    
    # First create a service account
    SA_RESPONSE=$(curl -u "admin:admin" -X POST "${GRAFANA_URL}/api/serviceaccounts" \
        -H "Content-Type: application/json" \
        -d '{"name":"deploy-script","role":"Admin","isDisabled":false}' \
        -s 2>/dev/null || echo "")
    
    if echo "$SA_RESPONSE" | grep -q '"id"'; then
        SA_ID=$(echo "$SA_RESPONSE" | grep -o '"id":[0-9]*' | cut -d':' -f2)
        echo "Service account created with ID: $SA_ID"
        
        # Now create a token for the service account
        TOKEN_RESPONSE=$(curl -u "admin:admin" -X POST "${GRAFANA_URL}/api/serviceaccounts/${SA_ID}/tokens" \
            -H "Content-Type: application/json" \
            -d '{"name":"deploy-token"}' \
            -s 2>/dev/null || echo "")
        
        if echo "$TOKEN_RESPONSE" | grep -q '"key"'; then
            GRAFANA_API_KEY=$(echo "$TOKEN_RESPONSE" | grep -o '"key":"[^"]*' | cut -d'"' -f4)
            echo -e "${GREEN}API key generated successfully!${NC}"
            
            # Verify API key works
            if curl -H "Authorization: Bearer $GRAFANA_API_KEY" -sf "${GRAFANA_URL}/api/user" >/dev/null 2>&1; then
                echo -e "${GREEN}API key verified successfully!${NC}"
            fi
        else
            echo -e "${YELLOW}Warning: Could not generate API token${NC}"
            echo -e "${YELLOW}Token Response: $TOKEN_RESPONSE${NC}"
            GRAFANA_API_KEY="use-admin-admin-$(date +%s)"
        fi
    else
        echo -e "${YELLOW}Warning: Could not create service account${NC}"
        echo -e "${YELLOW}SA Response: $SA_RESPONSE${NC}"
        GRAFANA_API_KEY="use-admin-admin-$(date +%s)"
    fi
else
    echo -e "${YELLOW}Warning: Default credentials (admin/admin) do not work${NC}"
    echo -e "${YELLOW}Please check Grafana configuration${NC}"
    GRAFANA_API_KEY="credentials-check-failed"
fi

# Additional check - see if we can get user info via SSH
echo "Getting additional Grafana information..."
GRAFANA_INFO=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ec2-user@${INSTANCE_IP} \
    "docker exec \$(docker ps -qf 'name=grafana') cat /etc/grafana/grafana.ini 2>/dev/null | grep -E '(admin_user|admin_password)' || echo 'config-not-found'")

if [ "$GRAFANA_INFO" != "config-not-found" ]; then
    echo "Grafana config info:"
    echo "$GRAFANA_INFO"
fi

# Output credentials in the required format
echo ""
echo "=== GRAFANA CREDENTIALS ==="
echo "GRAFANA_URL=${GRAFANA_URL}"
echo "GRAFANA_API_KEY=${GRAFANA_API_KEY}"
echo "=========================="

# Also output login credentials for reference
echo ""
echo "=== GRAFANA LOGIN INFO ==="
echo "URL: ${GRAFANA_URL}"
echo "Username: admin"
echo "Password: admin"
echo "=========================="