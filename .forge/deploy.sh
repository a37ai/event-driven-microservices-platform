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

# Verify AWS CLI is available
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI is not installed or not in PATH"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Generate a more unique identifier for concurrent executions
# Using nanoseconds + random + process ID for better uniqueness
UUID="$(date +%s%N)-$$-$(( RANDOM % 10000 ))"

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

# Verify key files exist before attempting import
if [[ ! -f "terraform/$KEY_BASE" ]] || [[ ! -f "terraform/$PUB_KEY" ]]; then
  echo "❌  ERROR: Key files not found after generation!"
  echo "    Expected: terraform/$KEY_BASE and terraform/$PUB_KEY"
  echo "    Current directory: $(pwd)"
  ls -la terraform/ | grep -E "(${KEY_BASE}|pub)" || echo "    No key files found"
  exit 1
fi

# Verify public key file is readable
if [[ ! -r "terraform/$PUB_KEY" ]]; then
  echo "❌  ERROR: Public key file is not readable: terraform/$PUB_KEY"
  ls -la "terraform/$PUB_KEY"
  exit 1
fi

# Debug info
echo "    Key files verified:"
echo "    - Private key: terraform/$KEY_BASE ($(stat -c %s terraform/$KEY_BASE 2>/dev/null || stat -f %z terraform/$KEY_BASE) bytes)"
echo "    - Public key: terraform/$PUB_KEY ($(stat -c %s terraform/$PUB_KEY 2>/dev/null || stat -f %z terraform/$PUB_KEY) bytes)"

# Always create a new unique key pair - no conflicts!
echo "    Importing public key to AWS..."
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

# Instance type fallbacks for better resilience
INSTANCE_TYPES=("t3.small" "t3.medium" "t2.medium" "t2.small" "t3.large")
TERRAFORM_SUCCESS=false

for INSTANCE_TYPE in "${INSTANCE_TYPES[@]}"; do
    echo "🔄  Attempting deployment with instance type: $INSTANCE_TYPE"
    
    if terraform apply -var="aws_region=${REGION}" -var="key_pair_name=${UNIQUE_KEY_NAME}" -var="instance_type=${INSTANCE_TYPE}" -auto-approve; then
        echo "✅  Deployment successful with instance type: $INSTANCE_TYPE"
        TERRAFORM_SUCCESS=true
        break
    else
        echo "❌  Failed with instance type: $INSTANCE_TYPE"
        # Get the last item in a POSIX-compliant way
        last_index=$(( ${#INSTANCE_TYPES[@]} - 1 ))
        if [ "$INSTANCE_TYPE" != "${INSTANCE_TYPES[$last_index]}" ]; then
            echo "🔄  Trying next instance type..."
            # Wait a bit before retrying
            sleep 5
        fi
    fi
done

if [ "$TERRAFORM_SUCCESS" = false ]; then
    echo "❌  All instance types failed. Deployment unsuccessful."
    exit 1
fi

# ──────────────────────────────────────────────────────────────
# 5️⃣  show connection info and output credentials
# ──────────────────────────────────────────────────────────────
INSTANCE_ID="$(terraform output -raw instance_id)"
IP="$(terraform output -raw public_ip)"

echo "⌛ Waiting for instance ($INSTANCE_ID) to be ready..."

# First wait for instance to be running
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

# Then wait for SSM agent to come online (can take 1-2 minutes)
echo "⏳ Waiting for SSM agent to come online..."
MAX_ATTEMPTS=30
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  if aws ssm describe-instance-information \
    --instance-information-filter-list "key=InstanceIds,valueSet=$INSTANCE_ID" \
    --region "$REGION" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text 2>/dev/null | grep -q "Online"; then
    echo "✅ SSM agent is online"
    break
  fi
  ATTEMPT=$((ATTEMPT + 1))
  echo "⏳ Waiting for SSM agent... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
  sleep 10
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
  echo "❌ SSM agent failed to come online"
  exit 1
fi

echo "⏳ Waiting for user-data script to complete..."

# Now check for user-data completion
ATTEMPTS=0
MAX_ATTEMPTS=60  # 10 minutes max
while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
  # Send command to check file
  # Note: SSM commands are automatically cleaned up by AWS after 30 days
  COMMAND_ID=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$INSTANCE_ID" \
    --parameters 'commands=["if [ -f /tmp/user-data-complete ]; then echo COMPLETE; else echo WAITING; fi"]' \
    --region "$REGION" \
    --query "Command.CommandId" \
    --output text 2>/dev/null)
  
  if [ -z "$COMMAND_ID" ]; then
    echo "⚠️  Failed to send SSM command, retrying..."
    sleep 10
    continue
  fi
  
  # Wait for command to finish
  sleep 5
  
  # Check command result
  OUTPUT=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --query "StandardOutputContent" \
    --output text 2>/dev/null || echo "WAITING")
  
  if [ "$OUTPUT" == "COMPLETE" ]; then
    echo "✅ User-data script has completed!"
    break
  fi
  
  ATTEMPTS=$((ATTEMPTS + 1))
  echo "⏳ Still waiting for user-data to complete... (attempt $ATTEMPTS/$MAX_ATTEMPTS)"
  sleep 10
done

if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
  echo "❌ User-data script did not complete in time"
  exit 1
fi
echo ""
echo "=============================================="
echo "🚀 Infrastructure deployed successfully!"
echo "📊 Instance deployed with type: $INSTANCE_TYPE"
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
echo "DEBUG: Using SSM to extract Jenkins credentials"

# Wait for Jenkins to be ready using SSM
echo "Waiting for Jenkins to be ready..."
MAX_JENKINS_ATTEMPTS=30
JENKINS_ATTEMPT=1

while [ $JENKINS_ATTEMPT -le $MAX_JENKINS_ATTEMPTS ]; do
    echo "DEBUG: Testing Jenkins connectivity via SSM - attempt $JENKINS_ATTEMPT"
    
    # Send SSM command to check Jenkins
    CHECK_CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters 'commands=["curl -s http://localhost:8080/login > /dev/null && echo READY || echo WAITING"]' \
        --region "$REGION" \
        --query "Command.CommandId" \
        --output text 2>/dev/null)
    
    if [ -n "$CHECK_CMD_ID" ]; then
        sleep 5
        CHECK_OUTPUT=$(aws ssm get-command-invocation \
            --command-id "$CHECK_CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --query "StandardOutputContent" \
            --output text 2>/dev/null || echo "WAITING")
        
        if [ "$CHECK_OUTPUT" == "READY" ]; then
            echo "✅ Jenkins is ready!"
            break
        fi
    fi
    
    echo "⏳ Jenkins not ready yet... (attempt $JENKINS_ATTEMPT/$MAX_JENKINS_ATTEMPTS)"
    sleep 10
    JENKINS_ATTEMPT=$((JENKINS_ATTEMPT + 1))
done

if [ $JENKINS_ATTEMPT -gt $MAX_JENKINS_ATTEMPTS ]; then
    echo "❌ Jenkins failed to start in time"
    JENKINS_URL_EXTRACTED=""
    JENKINS_USER_EXTRACTED=""
    JENKINS_API_TOKEN_EXTRACTED=""
else
    # Check if Jenkins is using configured password (setup wizard disabled)
    echo "DEBUG: Checking Jenkins configuration mode..."
    CONFIG_CHECK_CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters 'commands=["docker exec $(docker ps -q --filter '\''name=jenkins'\'' | head -1) env 2>/dev/null | grep -q runSetupWizard=false && echo CONFIGURED || echo STANDARD"]' \
        --region "$REGION" \
        --query "Command.CommandId" \
        --output text 2>/dev/null)
    
    if [ -n "$CONFIG_CHECK_CMD_ID" ]; then
        sleep 5
        CONFIG_MODE=$(aws ssm get-command-invocation \
            --command-id "$CONFIG_CHECK_CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --query "StandardOutputContent" \
            --output text 2>/dev/null | tr -d '\n' || echo "STANDARD")
        
        if [ "$CONFIG_MODE" == "CONFIGURED" ]; then
            echo "DEBUG: Jenkins is using pre-configured password"
            JENKINS_PASSWORD="admin123"
        else
            echo "DEBUG: Jenkins is using standard setup - extracting initial admin password..."
            PWD_CMD_ID=$(aws ssm send-command \
                --document-name "AWS-RunShellScript" \
                --instance-ids "$INSTANCE_ID" \
                --parameters 'commands=["docker exec $(docker ps -q --filter '\''name=jenkins'\'' | head -1) cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo admin"]' \
                --region "$REGION" \
                --query "Command.CommandId" \
                --output text 2>/dev/null)
            
            if [ -n "$PWD_CMD_ID" ]; then
                sleep 5
                JENKINS_PASSWORD=$(aws ssm get-command-invocation \
                    --command-id "$PWD_CMD_ID" \
                    --instance-id "$INSTANCE_ID" \
                    --region "$REGION" \
                    --query "StandardOutputContent" \
                    --output text 2>/dev/null | tr -d '\n' || echo "admin")
            else
                echo "⚠️  Failed to send SSM command for Jenkins password extraction"
                JENKINS_PASSWORD="admin"
            fi
        fi
    else
        echo "⚠️  Failed to check Jenkins configuration mode"
        JENKINS_PASSWORD="admin"
    fi
    
    echo "DEBUG: Jenkins password extracted: [hidden]"
    
    # Set extracted values
    JENKINS_URL_EXTRACTED="$JENKINS_URL"
    JENKINS_USER_EXTRACTED="admin"
    JENKINS_API_TOKEN_EXTRACTED="$JENKINS_PASSWORD"
fi

echo "Extracting Nexus credentials..."
echo "DEBUG: Using SSM to extract Nexus credentials"

# First check if Nexus is ready
echo "Checking Nexus availability..."
MAX_NEXUS_ATTEMPTS=30
NEXUS_ATTEMPT=1
NEXUS_READY=false

while [ $NEXUS_ATTEMPT -le $MAX_NEXUS_ATTEMPTS ]; do
    echo "DEBUG: Testing Nexus connectivity via SSM - attempt $NEXUS_ATTEMPT"
    
    NEXUS_CHECK_CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters 'commands=["curl -s http://localhost:8081/service/rest/v1/status > /dev/null && echo READY || echo WAITING"]' \
        --region "$REGION" \
        --query "Command.CommandId" \
        --output text 2>/dev/null)
    
    if [ -n "$NEXUS_CHECK_CMD_ID" ]; then
        sleep 5
        NEXUS_STATUS=$(aws ssm get-command-invocation \
            --command-id "$NEXUS_CHECK_CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --query "StandardOutputContent" \
            --output text 2>/dev/null || echo "WAITING")
        
        if [ "$NEXUS_STATUS" == "READY" ]; then
            echo "✅ Nexus is ready!"
            NEXUS_READY=true
            break
        fi
    fi
    
    echo "⏳ Nexus not ready yet... (attempt $NEXUS_ATTEMPT/$MAX_NEXUS_ATTEMPTS)"
    sleep 10
    NEXUS_ATTEMPT=$((NEXUS_ATTEMPT + 1))
done

if [ "$NEXUS_READY" = true ]; then
    # Extract Nexus password via SSM
    NEXUS_CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters 'commands=["docker exec $(docker ps -q --filter '\''name=nexus'\'' | head -1) cat /nexus-data/admin.password 2>/dev/null | tr -d '\''\n'\'' || echo extraction-failed"]' \
        --region "$REGION" \
        --query "Command.CommandId" \
        --output text 2>/dev/null)
else
    echo "❌ Nexus failed to become ready in time"
    NEXUS_CMD_ID=""
fi

if [ -n "$NEXUS_CMD_ID" ]; then
    sleep 5
    NEXUS_PASSWORD_EXTRACTED=$(aws ssm get-command-invocation \
        --command-id "$NEXUS_CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" \
        --query "StandardOutputContent" \
        --output text 2>/dev/null || echo "ssm-failed")
else
    NEXUS_PASSWORD_EXTRACTED="ssm-failed"
fi

echo "DEBUG: Nexus password result: [hidden]"

if [ "$NEXUS_PASSWORD_EXTRACTED" != "extraction-failed" ] && [ "$NEXUS_PASSWORD_EXTRACTED" != "ssm-failed" ]; then
    # Verify credentials work via SSM
    VERIFY_CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters "commands=[\"curl -u 'admin:${NEXUS_PASSWORD_EXTRACTED}' -s -o /dev/null -w '%{http_code}' http://localhost:8081/service/rest/v1/status\"]" \
        --region "$REGION" \
        --query "Command.CommandId" \
        --output text 2>/dev/null)
    
    if [ -n "$VERIFY_CMD_ID" ]; then
        sleep 5
        NEXUS_TEST=$(aws ssm get-command-invocation \
            --command-id "$VERIFY_CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --query "StandardOutputContent" \
            --output text 2>/dev/null || echo "000")
    else
        NEXUS_TEST="000"
    fi
    
    if [ "$NEXUS_TEST" = "200" ]; then
        echo "✅ Nexus credentials verified successfully"
        NEXUS_URL_EXTRACTED="$NEXUS_URL"
        NEXUS_USERNAME_EXTRACTED="admin"
    else
        echo "❌ Nexus credential verification failed"
        NEXUS_PASSWORD_EXTRACTED="verification-failed"
        NEXUS_URL_EXTRACTED=""
        NEXUS_USERNAME_EXTRACTED=""
    fi
else
    echo "❌ Nexus credential extraction failed"
    NEXUS_URL_EXTRACTED=""
    NEXUS_USERNAME_EXTRACTED=""
fi

echo "Extracting Grafana credentials..."
echo "DEBUG: Using SSM to extract Grafana credentials"

# First verify Grafana is accessible via SSM
echo "Checking Grafana availability..."
GRAFANA_CHECK_CMD_ID=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$INSTANCE_ID" \
    --parameters 'commands=["curl -u '\''admin:admin'\'' -s http://localhost:10001/api/user > /dev/null 2>&1 && echo ACCESSIBLE || echo NOT_ACCESSIBLE"]' \
    --region "$REGION" \
    --query "Command.CommandId" \
    --output text 2>/dev/null)

if [ -n "$GRAFANA_CHECK_CMD_ID" ]; then
    sleep 5
    GRAFANA_STATUS=$(aws ssm get-command-invocation \
        --command-id "$GRAFANA_CHECK_CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" \
        --query "StandardOutputContent" \
        --output text 2>/dev/null || echo "NOT_ACCESSIBLE")
else
    GRAFANA_STATUS="NOT_ACCESSIBLE"
fi

if [ "$GRAFANA_STATUS" == "ACCESSIBLE" ]; then
    echo "✅ Grafana is accessible, creating service account..."
    
    # Create service account via SSM
    SA_CREATE_CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters 'commands=["curl -u '\''admin:admin'\'' -X POST http://localhost:10001/api/serviceaccounts -H '\''Content-Type: application/json'\'' -d '\''{\"name\":\"deploy-script\",\"role\":\"Admin\",\"isDisabled\":false}'\'' -s 2>/dev/null"]' \
        --region "$REGION" \
        --query "Command.CommandId" \
        --output text 2>/dev/null)
    
    if [ -n "$SA_CREATE_CMD_ID" ]; then
        sleep 5
        SA_RESPONSE=$(aws ssm get-command-invocation \
            --command-id "$SA_CREATE_CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --query "StandardOutputContent" \
            --output text 2>/dev/null || echo "{}")
        
        # Extract service account ID
        SA_ID=$(echo "$SA_RESPONSE" | grep -o '"id":[0-9]*' | cut -d':' -f2)
        
        if [ -n "$SA_ID" ]; then
            echo "DEBUG: Service account created with ID: $SA_ID"
            
            # Create API token via SSM
            TOKEN_CREATE_CMD_ID=$(aws ssm send-command \
                --document-name "AWS-RunShellScript" \
                --instance-ids "$INSTANCE_ID" \
                --parameters "commands=[\"curl -u 'admin:admin' -X POST http://localhost:10001/api/serviceaccounts/${SA_ID}/tokens -H 'Content-Type: application/json' -d '{\\\"name\\\":\\\"deploy-token\\\"}' -s 2>/dev/null\"]" \
                --region "$REGION" \
                --query "Command.CommandId" \
                --output text 2>/dev/null)
            
            if [ -n "$TOKEN_CREATE_CMD_ID" ]; then
                sleep 5
                TOKEN_RESPONSE=$(aws ssm get-command-invocation \
                    --command-id "$TOKEN_CREATE_CMD_ID" \
                    --instance-id "$INSTANCE_ID" \
                    --region "$REGION" \
                    --query "StandardOutputContent" \
                    --output text 2>/dev/null || echo "{}")
                
                # Extract API key
                GRAFANA_API_KEY_EXTRACTED=$(echo "$TOKEN_RESPONSE" | grep -o '"key":"[^"]*' | cut -d'"' -f4)
                
                if [ -z "$GRAFANA_API_KEY_EXTRACTED" ]; then
                    echo "❌ Failed to extract API key from response"
                    GRAFANA_API_KEY_EXTRACTED="token-extraction-failed"
                else
                    echo "✅ Grafana API key extracted successfully"
                fi
            else
                echo "❌ Failed to create API token"
                GRAFANA_API_KEY_EXTRACTED="token-creation-failed"
            fi
        else
            echo "❌ Failed to extract service account ID"
            GRAFANA_API_KEY_EXTRACTED="service-account-creation-failed"
        fi
    else
        echo "❌ Failed to create service account"
        GRAFANA_API_KEY_EXTRACTED="service-account-creation-failed"
    fi
else
    echo "❌ Grafana is not accessible"
    GRAFANA_API_KEY_EXTRACTED="grafana-not-accessible"
fi

if [ "$GRAFANA_API_KEY_EXTRACTED" != "token-extraction-failed" ] && [ "$GRAFANA_API_KEY_EXTRACTED" != "token-creation-failed" ] && [ "$GRAFANA_API_KEY_EXTRACTED" != "service-account-creation-failed" ] && [ "$GRAFANA_API_KEY_EXTRACTED" != "grafana-not-accessible" ]; then
    echo "Grafana API key generated successfully"
    GRAFANA_URL_EXTRACTED="$GRAFANA_URL"
else
    echo "Grafana credential extraction failed: $GRAFANA_API_KEY_EXTRACTED"
    GRAFANA_URL_EXTRACTED=""
fi

# Fallback: Direct credential extraction if scripts failed
if [ -z "$JENKINS_API_TOKEN_EXTRACTED" ] || [ "$JENKINS_API_TOKEN_EXTRACTED" = "jenkins-extraction-failed" ]; then
    echo "Attempting fallback Jenkins credential extraction..."
    FALLBACK_JENKINS_CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters 'commands=["docker exec $(docker ps -q --filter '\''name=jenkins'\'' | head -1) cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo fallback-failed"]' \
        --region "$REGION" \
        --query "Command.CommandId" \
        --output text 2>/dev/null)
    
    if [ -n "$FALLBACK_JENKINS_CMD_ID" ]; then
        sleep 5
        JENKINS_PASSWORD_FALLBACK=$(aws ssm get-command-invocation \
            --command-id "$FALLBACK_JENKINS_CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --query "StandardOutputContent" \
            --output text 2>/dev/null | tr -d '\n' || echo "ssm-failed")
    else
        JENKINS_PASSWORD_FALLBACK="ssm-failed"
    fi
    
    if [ "$JENKINS_PASSWORD_FALLBACK" != "fallback-failed" ] && [ "$JENKINS_PASSWORD_FALLBACK" != "ssm-failed" ]; then
        JENKINS_API_TOKEN_EXTRACTED="password-${JENKINS_PASSWORD_FALLBACK}"
    fi
fi

if [ -z "$NEXUS_PASSWORD_EXTRACTED" ] || [ "$NEXUS_PASSWORD_EXTRACTED" = "nexus-extraction-failed" ]; then
    echo "Attempting fallback Nexus credential extraction..."
    FALLBACK_NEXUS_CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters 'commands=["docker exec $(docker ps -q --filter '\''name=nexus'\'' | head -1) cat /nexus-data/admin.password 2>/dev/null | tr -d '\''\n'\'' || echo fallback-failed"]' \
        --region "$REGION" \
        --query "Command.CommandId" \
        --output text 2>/dev/null)
    
    if [ -n "$FALLBACK_NEXUS_CMD_ID" ]; then
        sleep 5
        NEXUS_PASSWORD_FALLBACK=$(aws ssm get-command-invocation \
            --command-id "$FALLBACK_NEXUS_CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --query "StandardOutputContent" \
            --output text 2>/dev/null | tr -d '\n' || echo "ssm-failed")
    else
        NEXUS_PASSWORD_FALLBACK="ssm-failed"
    fi
    
    if [ "$NEXUS_PASSWORD_FALLBACK" != "fallback-failed" ] && [ "$NEXUS_PASSWORD_FALLBACK" != "ssm-failed" ]; then
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

echo "SONARQUBE_URL=${SONARQUBE_URL}"
echo "KAFKA_MANAGER_URL=${KAFKA_MANAGER_URL}"
echo "DOCKER_REGISTRY_URL=${DOCKER_REGISTRY_URL}"
echo "AWS_REGION=${AWS_REGION}"

# Save backend info for destroy script
cd ..
cat > .terraform-backend-info <<EOF
BUCKET_NAME=$BUCKET_NAME
DYNAMODB_TABLE=$DYNAMODB_TABLE
REGION=$REGION
KEY_PAIR_NAME=$UNIQUE_KEY_NAME
EOF
