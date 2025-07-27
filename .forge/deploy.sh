#!/usr/bin/env bash
# deploy.sh – deploys the minimal event-driven microservices platform infrastructure
# -------------------------------------------------------------------------
# This script provisions AWS infrastructure for the EDMP platform (Registry + Grafana only)
# and outputs credentials for the deployed services
# -------------------------------------------------------------------------

# =============================================================================
# INTEGRATION DECLARATIONS
# =============================================================================

# Declare required cloud integrations (must be set up before this runs)
# REQUIRES: aws

# Declare infrastructure tools that this script will set up
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
# ──────────────────────────────────────────────────────────────
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
MAX_ATTEMPTS=100
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
GRAFANA_URL=$(terraform output -raw grafana_url)
DOCKER_REGISTRY_URL=$(terraform output -raw docker_registry_url)
AWS_REGION=$(terraform output -raw aws_region)
IP=$(terraform output -raw public_ip)

# Extract credentials using dedicated scripts with timeouts
echo "Waiting for services to be ready..."
echo "DEBUG: Waiting 30 seconds for services to fully start..."
sleep 30

echo "Extracting Grafana credentials..."
echo "DEBUG: Using SSM to extract Grafana credentials"

# First check if Grafana is ready
echo "Checking Grafana availability..."
MAX_GRAFANA_ATTEMPTS=30
GRAFANA_ATTEMPT=1
GRAFANA_READY=false

while [ $GRAFANA_ATTEMPT -le $MAX_GRAFANA_ATTEMPTS ]; do
    echo "DEBUG: Testing Grafana connectivity via SSM - attempt $GRAFANA_ATTEMPT"
    
    GRAFANA_CHECK_CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters 'commands=["curl -s http://localhost:10001/api/health > /dev/null && echo READY || echo WAITING"]' \
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
            --output text 2>/dev/null || echo "WAITING")
        
        if [ "$GRAFANA_STATUS" == "READY" ]; then
            echo "✅ Grafana is ready!"
            GRAFANA_READY=true
            break
        fi
    fi
    
    echo "⏳ Grafana not ready yet... (attempt $GRAFANA_ATTEMPT/$MAX_GRAFANA_ATTEMPTS)"
    sleep 10
    GRAFANA_ATTEMPT=$((GRAFANA_ATTEMPT + 1))
done

# Check if Registry is ready
echo "Checking Registry availability..."
MAX_REGISTRY_ATTEMPTS=30
REGISTRY_ATTEMPT=1
REGISTRY_READY=false

while [ $REGISTRY_ATTEMPT -le $MAX_REGISTRY_ATTEMPTS ]; do
    echo "DEBUG: Testing Registry connectivity via SSM - attempt $REGISTRY_ATTEMPT"
    
    REGISTRY_CHECK_CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters 'commands=["curl -s http://localhost:5000/v2/ > /dev/null && echo READY || echo WAITING"]' \
        --region "$REGION" \
        --query "Command.CommandId" \
        --output text 2>/dev/null)
    
    if [ -n "$REGISTRY_CHECK_CMD_ID" ]; then
        sleep 5
        REGISTRY_STATUS=$(aws ssm get-command-invocation \
            --command-id "$REGISTRY_CHECK_CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --query "StandardOutputContent" \
            --output text 2>/dev/null || echo "WAITING")
        
        if [ "$REGISTRY_STATUS" == "READY" ]; then
            echo "✅ Registry is ready!"
            REGISTRY_READY=true
            break
        fi
    fi
    
    echo "⏳ Registry not ready yet... (attempt $REGISTRY_ATTEMPT/$MAX_REGISTRY_ATTEMPTS)"
    sleep 10
    REGISTRY_ATTEMPT=$((REGISTRY_ATTEMPT + 1))
done

if [ "$GRAFANA_READY" = true ]; then
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

# Output credentials in the required format
echo ""
echo "=============================================="
echo "🚀 Minimal EDMP Platform Services:"
echo "=============================================="
echo ""
echo "DOCKER_REGISTRY_URL=${DOCKER_REGISTRY_URL}"
echo ""
echo "GRAFANA_URL=${GRAFANA_URL_EXTRACTED:-$GRAFANA_URL}"
echo "GRAFANA_API_KEY=${GRAFANA_API_KEY_EXTRACTED:-grafana-extraction-failed}"
echo ""
echo "AWS_REGION=${AWS_REGION}"
echo ""
echo "=============================================="
echo "Service status:"
if [ "$REGISTRY_READY" = true ]; then
    echo "✅ Registry: Running at $DOCKER_REGISTRY_URL"
else
    echo "❌ Registry: Not ready"
fi
if [ "$GRAFANA_READY" = true ]; then
    echo "✅ Grafana: Running at $GRAFANA_URL (admin/admin)"
else
    echo "❌ Grafana: Not ready"
fi
echo "=============================================="

# Save backend info for destroy script
cd ..
cat > .terraform-backend-info <<EOF
BUCKET_NAME=$BUCKET_NAME
DYNAMODB_TABLE=$DYNAMODB_TABLE
REGION=$REGION
KEY_PAIR_NAME=$UNIQUE_KEY_NAME
EOF