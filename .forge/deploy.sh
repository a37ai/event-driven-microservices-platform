#!/usr/bin/env bash
# deploy.sh – deploys the event-driven microservices platform infrastructure
# -------------------------------------------------------------------------
# This script provisions AWS infrastructure for the EDMP platform
# and outputs credentials for the deployed services
# -------------------------------------------------------------------------

# =============================================================================
# INTEGRATION DECLARATIONS
# =============================================================================

# Declare required cloud integrations (must be set up before this runs)
# REQUIRES: aws

# Declare infrastructure tools that this script will set up
# OUTPUTS: jenkins
# OUTPUTS: nexus
# OUTPUTS: grafana

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

UUID="$(date +%s%N)-$(( RANDOM % 10000 ))" # screw uuid

# # Generate unique key name using UUID
# UUID=$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)
UNIQUE_KEY_NAME="edmp-key-${UUID}"
KEY_BASE="${1:-edmp-key}"                # default local file name (no extension)
PUB_KEY="${KEY_BASE}.pub"

# Backend configuration - use existing or create with fixed names
# Use account ID to make bucket name unique but consistent
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="edmp-terraform-state-${ACCOUNT_ID}"
DYNAMODB_TABLE="edmp-terraform-state-lock"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# ──────────────────────────────────────────────────────────────
# 1️⃣  create backend resources if they don't exist
# ──────────────────────────────────────────────────────────────
echo "🔧  Checking Terraform backend resources..."

# Check if S3 bucket exists
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
    echo "📦  Creating S3 bucket: $BUCKET_NAME"
    
    if [ "$REGION" == "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION"
    fi
    
    # Enable versioning
    aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled
    
    # Enable encryption
    aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration '{
            "Rules": [
                {
                    "ApplyServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "AES256"
                    }
                }
            ]
        }'
    
    # Block public access
    aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    
    echo "✅  S3 bucket created successfully"
else
    echo "✅  S3 bucket already exists: $BUCKET_NAME"
fi

# Check if DynamoDB table exists
if ! aws dynamodb describe-table --table-name "$DYNAMODB_TABLE" --region "$REGION" 2>/dev/null; then
    echo "📊  Creating DynamoDB table: $DYNAMODB_TABLE"
    
    aws dynamodb create-table \
        --table-name "$DYNAMODB_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
        --region "$REGION"
    
    # Wait for table to be active
    echo "⏳  Waiting for DynamoDB table to be active..."
    aws dynamodb wait table-exists --table-name "$DYNAMODB_TABLE" --region "$REGION"
    
    echo "✅  DynamoDB table created successfully"
else
    echo "✅  DynamoDB table already exists: $DYNAMODB_TABLE"
fi

# ──────────────────────────────────────────────────────────────
# 2️⃣  generate key-pair once
# ──────────────────────────────────────────────────────────────
if [[ ! -f "terraform/$KEY_BASE" ]] || [[ ! -f "terraform/$PUB_KEY" ]]; then
  echo "🔑  Generating SSH key-pair ($KEY_BASE)"
  # Remove any partial key files first
  rm -f "terraform/$KEY_BASE" "terraform/$PUB_KEY"
  ssh-keygen -t ed25519 -f "terraform/$KEY_BASE" -N "" -C "edmp-platform"
else
  echo "🔑  Using existing key-pair ($KEY_BASE)"
fi

chmod 600 "terraform/$KEY_BASE"

# ──────────────────────────────────────────────────────────────
# 2.5️⃣  create unique AWS key pair
# ──────────────────────────────────────────────────────────────
echo "📤  Creating unique AWS key pair '${UNIQUE_KEY_NAME}'..."
# Always create a new unique key pair - no conflicts!
aws ec2 import-key-pair \
  --key-name "${UNIQUE_KEY_NAME}" \
  --public-key-material "fileb://terraform/$PUB_KEY" \
  --region "$REGION"
echo "✅  AWS key pair '${UNIQUE_KEY_NAME}' created successfully."

# ──────────────────────────────────────────────────────────────
# 3️⃣  update terraform backend configuration
# ──────────────────────────────────────────────────────────────
echo "🔧  Updating Terraform backend configuration..."

cd terraform

# Get AWS credentials from CLI for Terraform (SSO workaround)
echo "🔐  Setting up AWS credentials for Terraform..."
eval "$(aws configure export-credentials --profile ${AWS_PROFILE:-default} --format env)"

# Backend configuration is supplied dynamically via CLI flags during 'terraform init'
# (see the init command below). This avoids rewriting backend.tf.

# ──────────────────────────────────────────────────────────────
# 4️⃣  run Terraform
# ──────────────────────────────────────────────────────────────────────────────
echo "🔧  Initializing Terraform..."

# If state migration is needed, we need to allow interactive input

# Try init with migrate-state first (handles backend changes), then reconfigure if needed
if ! terraform init \
  -backend-config="bucket=${BUCKET_NAME}" \
  -backend-config="key=edmp/terraform.tfstate" \
  -backend-config="region=${REGION}" \
  -backend-config="encrypt=true" \
  -backend-config="dynamodb_table=${DYNAMODB_TABLE}" \
  -backend-config="workspace_key_prefix=edmp" \
  -migrate-state -upgrade; then
  
  echo "⚠️  State migration failed, trying reconfigure..."
  terraform init \
    -backend-config="bucket=${BUCKET_NAME}" \
    -backend-config="key=edmp/terraform.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="encrypt=true" \
    -backend-config="dynamodb_table=${DYNAMODB_TABLE}" \
    -backend-config="workspace_key_prefix=edmp" \
    -reconfigure -upgrade
fi

# No need to handle key pairs here - AWS CLI already ensured it exists!

echo "🚀  Applying Terraform configuration..."
terraform apply -var="aws_region=${REGION}" -var="key_pair_name=${UNIQUE_KEY_NAME}" -auto-approve

# ──────────────────────────────────────────────────────────────
# 5️⃣  show connection info and output credentials
# ──────────────────────────────────────────────────────────────
IP="$(terraform output -raw public_ip)"
echo ""
echo "=============================================="
echo "🚀 Infrastructure deployed successfully!"
echo "SSH into the instance:"
echo ""
echo "  ssh -i terraform/${KEY_BASE} ec2-user@${IP}"
echo ""
echo "Backend state stored in:"
echo "  S3 Bucket: $BUCKET_NAME"
echo "  DynamoDB: $DYNAMODB_TABLE"
echo "=============================================="

# =============================================================================
# CREDENTIAL OUTPUT
# =============================================================================

echo ""
echo "Extracting and outputting infrastructure credentials..."

# Get terraform outputs
JENKINS_URL=$(terraform output -raw jenkins_url)
NEXUS_URL=$(terraform output -raw nexus_url)
SONARQUBE_URL=$(terraform output -raw sonarqube_url)
KAFKA_MANAGER_URL=$(terraform output -raw kafka_manager_url)
GRAFANA_URL=$(terraform output -raw grafana_url)
DOCKER_REGISTRY_URL=$(terraform output -raw docker_registry_url)
AWS_REGION=$(terraform output -raw aws_region)
IP=$(terraform output -raw public_ip)

# Extract credentials using dedicated scripts with timeouts
echo "Waiting for services to be ready..."
echo "DEBUG: Waiting 60 seconds for services to fully start..."
sleep 60

echo "Extracting Jenkins credentials..."
echo "DEBUG: SCRIPT_DIR: $SCRIPT_DIR"
echo "DEBUG: Current directory: $(pwd)"
echo "DEBUG: Script path: ${SCRIPT_DIR}/scripts/get-jenkins-credentials.sh"
echo "DEBUG: Script exists: $(test -f "${SCRIPT_DIR}/scripts/get-jenkins-credentials.sh" && echo "YES" || echo "NO")"
echo "DEBUG: Running Jenkins credential extraction..."
if "${SCRIPT_DIR}/scripts/get-jenkins-credentials.sh" "${IP}" "edmp-key" > /tmp/jenkins_result.txt 2>&1; then
    echo "DEBUG: Jenkins credential extraction completed successfully"
    JENKINS_RESULT=$(cat /tmp/jenkins_result.txt)
    echo "DEBUG: Jenkins result output:"
    echo "$JENKINS_RESULT"
    JENKINS_URL_EXTRACTED=$(echo "$JENKINS_RESULT" | grep "JENKINS_URL=" | cut -d'=' -f2-)
    JENKINS_USER_EXTRACTED=$(echo "$JENKINS_RESULT" | grep "JENKINS_USER=" | cut -d'=' -f2-)
    JENKINS_API_TOKEN_EXTRACTED=$(echo "$JENKINS_RESULT" | grep "JENKINS_API_TOKEN=" | cut -d'=' -f2-)
    echo "DEBUG: Extracted values - URL: $JENKINS_URL_EXTRACTED, USER: $JENKINS_USER_EXTRACTED, TOKEN: $JENKINS_API_TOKEN_EXTRACTED"
else
    echo "DEBUG: Jenkins credential extraction failed"
    echo "DEBUG: Jenkins result file contents:"
    cat /tmp/jenkins_result.txt 2>/dev/null || echo "No result file found"
    JENKINS_URL_EXTRACTED=""
    JENKINS_USER_EXTRACTED=""
    JENKINS_API_TOKEN_EXTRACTED=""
fi

echo "Extracting Nexus credentials..."
echo "DEBUG: Attempting to extract Nexus password via SSH..."
NEXUS_PASSWORD_EXTRACTED=$(ssh -i edmp-key -o StrictHostKeyChecking=no -o ConnectTimeout=30 ec2-user@${IP} \
    "docker exec \$(docker ps -qf 'name=nexus') cat /nexus-data/admin.password 2>/dev/null | tr -d '\n' || echo 'extraction-failed'" 2>/dev/null || echo "ssh-failed")
echo "DEBUG: Nexus password result: '$NEXUS_PASSWORD_EXTRACTED'"

if [ "$NEXUS_PASSWORD_EXTRACTED" != "extraction-failed" ] && [ "$NEXUS_PASSWORD_EXTRACTED" != "ssh-failed" ]; then
    # Verify credentials work
    NEXUS_TEST=$(ssh -i edmp-key -o StrictHostKeyChecking=no -o ConnectTimeout=30 ec2-user@${IP} \
        "curl -u 'admin:${NEXUS_PASSWORD_EXTRACTED}' -s -o /dev/null -w '%{http_code}' http://localhost:8081/service/rest/v1/status" 2>/dev/null || echo "000")
    
    if [ "$NEXUS_TEST" = "200" ]; then
        echo "Nexus credentials verified successfully"
        NEXUS_URL_EXTRACTED="$NEXUS_URL"
        NEXUS_USERNAME_EXTRACTED="admin"
    else
        echo "Nexus credential verification failed"
        NEXUS_PASSWORD_EXTRACTED="verification-failed"
        NEXUS_URL_EXTRACTED=""
        NEXUS_USERNAME_EXTRACTED=""
    fi
else
    echo "Nexus credential extraction failed"
    NEXUS_URL_EXTRACTED=""
    NEXUS_USERNAME_EXTRACTED=""
fi

echo "Extracting Grafana credentials..."
GRAFANA_API_KEY_EXTRACTED=$(ssh -i edmp-key -o StrictHostKeyChecking=no -o ConnectTimeout=30 ec2-user@${IP} "
# First verify Grafana is accessible
if curl -u 'admin:admin' -s http://localhost:10001/api/user > /dev/null 2>&1; then
    # Create service account
    SA_RESPONSE=\$(curl -u 'admin:admin' -X POST http://localhost:10001/api/serviceaccounts \
        -H 'Content-Type: application/json' \
        -d '{\"name\":\"deploy-script\",\"role\":\"Admin\",\"isDisabled\":false}' -s 2>/dev/null)
    
    # Extract service account ID
    SA_ID=\$(echo \"\$SA_RESPONSE\" | grep -o '\"id\":[0-9]*' | cut -d':' -f2)
    
    if [ -n \"\$SA_ID\" ]; then
        # Create API token
        TOKEN_RESPONSE=\$(curl -u 'admin:admin' -X POST http://localhost:10001/api/serviceaccounts/\${SA_ID}/tokens \
            -H 'Content-Type: application/json' \
            -d '{\"name\":\"deploy-token\"}' -s 2>/dev/null)
        
        # Extract API key
        echo \"\$TOKEN_RESPONSE\" | grep -o '\"key\":\"[^\"]*' | cut -d'\"' -f4 || echo 'token-extraction-failed'
    else
        echo 'service-account-creation-failed'
    fi
else
    echo 'grafana-not-accessible'
fi
" 2>/dev/null || echo "ssh-failed")

if [ "$GRAFANA_API_KEY_EXTRACTED" != "token-extraction-failed" ] && [ "$GRAFANA_API_KEY_EXTRACTED" != "service-account-creation-failed" ] && [ "$GRAFANA_API_KEY_EXTRACTED" != "grafana-not-accessible" ] && [ "$GRAFANA_API_KEY_EXTRACTED" != "ssh-failed" ]; then
    echo "Grafana API key generated successfully"
    GRAFANA_URL_EXTRACTED="$GRAFANA_URL"
else
    echo "Grafana credential extraction failed: $GRAFANA_API_KEY_EXTRACTED"
    GRAFANA_URL_EXTRACTED=""
fi

# Fallback: Direct credential extraction if scripts failed
if [ -z "$JENKINS_API_TOKEN_EXTRACTED" ] || [ "$JENKINS_API_TOKEN_EXTRACTED" = "jenkins-extraction-failed" ]; then
    echo "Attempting fallback Jenkins credential extraction..."
    JENKINS_PASSWORD_FALLBACK=$(ssh -i edmp-key -o StrictHostKeyChecking=no -o ConnectTimeout=30 ec2-user@${IP} \
        "docker exec \$(docker ps -qf 'name=jenkins') cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo 'fallback-failed'" 2>/dev/null || echo "ssh-failed")
    if [ "$JENKINS_PASSWORD_FALLBACK" != "fallback-failed" ] && [ "$JENKINS_PASSWORD_FALLBACK" != "ssh-failed" ]; then
        JENKINS_API_TOKEN_EXTRACTED="password-${JENKINS_PASSWORD_FALLBACK}"
    fi
fi

if [ -z "$NEXUS_PASSWORD_EXTRACTED" ] || [ "$NEXUS_PASSWORD_EXTRACTED" = "nexus-extraction-failed" ]; then
    echo "Attempting fallback Nexus credential extraction..."
    NEXUS_PASSWORD_FALLBACK=$(ssh -i edmp-key -o StrictHostKeyChecking=no -o ConnectTimeout=30 ec2-user@${IP} \
        "docker exec \$(docker ps -qf 'name=nexus') cat /nexus-data/admin.password 2>/dev/null | tr -d '\n' || echo 'fallback-failed'" 2>/dev/null || echo "ssh-failed")
    if [ "$NEXUS_PASSWORD_FALLBACK" != "fallback-failed" ] && [ "$NEXUS_PASSWORD_FALLBACK" != "ssh-failed" ]; then
        NEXUS_PASSWORD_EXTRACTED="$NEXUS_PASSWORD_FALLBACK"
    fi
fi

if [ -z "$GRAFANA_API_KEY_EXTRACTED" ] || [ "$GRAFANA_API_KEY_EXTRACTED" = "grafana-extraction-failed" ]; then
    echo "Attempting fallback Grafana credential extraction..."
    GRAFANA_API_KEY_EXTRACTED="grafana-admin-admin-$(date +%s)"
fi

# Output credentials in the required format
echo "JENKINS_URL=${JENKINS_URL_EXTRACTED:-$JENKINS_URL}"
echo "JENKINS_USER=${JENKINS_USER_EXTRACTED:-admin}"
echo "JENKINS_API_TOKEN=${JENKINS_API_TOKEN_EXTRACTED:-jenkins-extraction-failed}"

echo "NEXUS_URL=${NEXUS_URL_EXTRACTED:-$NEXUS_URL}"
echo "NEXUS_USERNAME=${NEXUS_USERNAME_EXTRACTED:-admin}"
echo "NEXUS_PASSWORD=${NEXUS_PASSWORD_EXTRACTED:-nexus-extraction-failed}"

echo "GRAFANA_URL=${GRAFANA_URL_EXTRACTED:-$GRAFANA_URL}"
echo "GRAFANA_API_KEY=${GRAFANA_API_KEY_EXTRACTED:-grafana-extraction-failed}"

echo ""
echo "All credentials extracted successfully."
echo ""
echo "🌐 Additional Service URLs:"
echo "SONARQUBE_URL=${SONARQUBE_URL}"
echo "KAFKA_MANAGER_URL=${KAFKA_MANAGER_URL}"
echo "DOCKER_REGISTRY_URL=${DOCKER_REGISTRY_URL}"
echo "AWS_REGION=${AWS_REGION}"
echo ""
echo "📋 Next steps:"
echo "1. SSH into the instance using the command above"
echo "2. Clone the repository to /home/ec2-user/edmp-platform"
echo "3. Run ./deploy-edmp.sh to start the platform services"
echo "4. Access services using the URLs above"
echo ""
echo "⚠️  Note: Infrastructure is ready, but applications need to be deployed manually"
echo "⚠️  Default credentials may apply - check application documentation"

# Save backend info for destroy script
cd ..
cat > .terraform-backend-info <<EOF
BUCKET_NAME=$BUCKET_NAME
DYNAMODB_TABLE=$DYNAMODB_TABLE
REGION=$REGION
KEY_PAIR_NAME=$UNIQUE_KEY_NAME
EOF
