#!/bin/bash
set -e

# Jenkins Credential Extraction Script
# Usage: ./get-jenkins-credentials.sh <instance_ip> <ssh_key_path>

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

echo "Extracting Jenkins credentials from $INSTANCE_IP..."

# Wait for Jenkins to be ready
echo "Waiting for Jenkins to be ready..."
MAX_ATTEMPTS=30
ATTEMPT=1

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo "DEBUG: Testing Jenkins connectivity - attempt $ATTEMPT"
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ec2-user@${INSTANCE_IP} "curl -s http://localhost:8080/login > /dev/null" 2>/dev/null; then
        echo "DEBUG: Jenkins is responding!"
        break
    fi
    echo "DEBUG: Attempt $ATTEMPT/$MAX_ATTEMPTS - Jenkins not ready yet..."
    sleep 10
    ATTEMPT=$((ATTEMPT + 1))
done

if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    echo -e "${RED}DEBUG: Jenkins failed to start within $(($MAX_ATTEMPTS * 10)) seconds${NC}"
    exit 1
fi

# Get Jenkins initial admin password
echo "DEBUG: Getting Jenkins initial admin password..."
JENKINS_PASSWORD=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ec2-user@${INSTANCE_IP} \
    "docker exec \$(docker ps -qf 'name=jenkins') cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo 'not-found'")

echo "DEBUG: Initial password result: $JENKINS_PASSWORD"

if [ "$JENKINS_PASSWORD" = "not-found" ]; then
    echo -e "${YELLOW}DEBUG: Initial admin password not found - Jenkins may already be configured${NC}"
    echo "DEBUG: Attempting to use default credentials (admin:admin)..."
    JENKINS_PASSWORD="admin"
fi

echo "DEBUG: Final Jenkins Password: $JENKINS_PASSWORD"

# Setup Jenkins and generate API token
echo "DEBUG: Setting up Jenkins and generating API token..."
JENKINS_API_TOKEN=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ec2-user@${INSTANCE_IP} "
# First check if Jenkins is already set up
echo 'DEBUG: Step 1 - Checking if setup wizard needs to run' >&2
curl -c /tmp/jenkins-setup -s 'http://localhost:8080/' > /dev/null
CRUMB_SETUP=\$(curl -b /tmp/jenkins-setup -s 'http://localhost:8080/crumbIssuer/api/json' | grep -o '\"crumb\":\"[^\"]*\"' | cut -d'\"' -f4)

if [ -n \"\$CRUMB_SETUP\" ]; then
    # Try to complete setup wizard
    SETUP_RESULT=\$(curl -b /tmp/jenkins-setup -c /tmp/jenkins-setup -H \"Jenkins-Crumb: \$CRUMB_SETUP\" -X POST 'http://localhost:8080/setupWizard/completeInstall' --data-urlencode 'mode=SkipPlugins' -s 2>&1)
    echo \"DEBUG: Setup result: \$SETUP_RESULT\" >&2
fi

# Create admin user via script console
echo 'DEBUG: Step 2 - Creating admin user via script console' >&2
CRUMB_CREATE=\$(curl -b /tmp/jenkins-setup -s 'http://localhost:8080/crumbIssuer/api/json' | grep -o '\"crumb\":\"[^\"]*\"' | cut -d'\"' -f4)

if [ -n \"\$CRUMB_CREATE\" ]; then
    USER_CREATE_RESULT=\$(curl -b /tmp/jenkins-setup -H \"Jenkins-Crumb: \$CRUMB_CREATE\" \
      -X POST 'http://localhost:8080/scriptText' \
      --data-urlencode \"script=import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()

// Create security realm if it doesn't exist
def hudsonRealm = new HudsonPrivateSecurityRealm(false)
instance.setSecurityRealm(hudsonRealm)

// Create admin user
def user = hudsonRealm.createAccount('admin', 'admin')
user.save()

// Set authorization strategy
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

instance.save()

println 'Admin user created'\" -s 2>&1)
    echo \"DEBUG: User creation result: \$USER_CREATE_RESULT\" >&2
fi

# Generate API token
echo 'DEBUG: Step 3 - Generating API token' >&2
curl -u 'admin:admin' -c /tmp/jenkins-auth -s 'http://localhost:8080/' > /dev/null
CRUMB_TOKEN=\$(curl -u 'admin:admin' -b /tmp/jenkins-auth -s 'http://localhost:8080/crumbIssuer/api/json' | grep -o '\"crumb\":\"[^\"]*\"' | cut -d'\"' -f4)
echo \"DEBUG: Token generation crumb: \$CRUMB_TOKEN\" >&2

if [ -n \"\$CRUMB_TOKEN\" ]; then
    TOKEN=\$(curl -u 'admin:admin' -b /tmp/jenkins-auth -H \"Jenkins-Crumb: \$CRUMB_TOKEN\" \
      -X POST 'http://localhost:8080/scriptText' \
      --data-urlencode \"script=def user = jenkins.model.Jenkins.instance.getUser('admin')
def apiTokenProperty = user.getProperty(jenkins.security.ApiTokenProperty.class)
def result = apiTokenProperty.generateNewToken('deploy-token')
println result.plainValue\" -s 2>&1)
    
    # Check if token is valid (should be a hex string)
    if [[ \$TOKEN =~ ^[a-f0-9]{32,}$ ]]; then
        echo \"DEBUG: Successfully generated token: \$TOKEN\" >&2
        echo \"\$TOKEN\"
    else
        echo 'DEBUG: Token generation failed' >&2
        echo 'admin'
    fi
else
    echo 'DEBUG: Failed to get crumb for token generation' >&2
    echo 'admin'
fi

# Cleanup
rm -f /tmp/jenkins-setup /tmp/jenkins-auth >&2
")

echo "DEBUG: Jenkins API token result: '$JENKINS_API_TOKEN'"

if [ "$JENKINS_API_TOKEN" = "token-generation-failed" ] || [ "$JENKINS_API_TOKEN" = "crumb-refresh-failed" ] || [ "$JENKINS_API_TOKEN" = "initial-crumb-failed" ] || [ -z "$JENKINS_API_TOKEN" ]; then
    echo -e "${YELLOW}DEBUG: Token generation failed, falling back to password authentication${NC}"
    JENKINS_API_TOKEN="$JENKINS_PASSWORD"
else
    echo -e "${GREEN}DEBUG: Successfully generated Jenkins API token${NC}"
fi

echo "DEBUG: Final Jenkins API token: '$JENKINS_API_TOKEN'"

# Output credentials in the required format
echo ""
echo "=== JENKINS CREDENTIALS ==="
echo "JENKINS_URL=http://${INSTANCE_IP}:8080"
echo "JENKINS_USER=admin"
echo "JENKINS_API_TOKEN=${JENKINS_API_TOKEN}"
echo "=========================="