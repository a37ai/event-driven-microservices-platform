#!/usr/bin/env bash
# destroy.sh – tears down the EDMP infrastructure deployed by deploy.sh
# -----------------------------------------------------------------------
# • Reads backend configuration from .terraform-backend-info
# • Executes terraform destroy -auto-approve
# • Optionally destroys the S3 bucket and DynamoDB table
# • Leaves the local SSH key-pair in place (delete manually if desired)
#
# Usage:
#   $ ./destroy.sh [--clean-backend]     # --clean-backend removes S3/DynamoDB
# -----------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLEAN_BACKEND=false
if [[ "${1:-}" == "--clean-backend" ]]; then
    CLEAN_BACKEND=true
fi

# ──────────────────────────────────────────────────────────────
# 1️⃣  read backend configuration
# ──────────────────────────────────────────────────────────────
if [[ ! -f ".terraform-backend-info" ]]; then
    echo "❌  Backend info file not found. Run deploy.sh first."
    exit 1
fi

source .terraform-backend-info

echo "🔧  Using backend configuration:"
echo "    S3 Bucket: $BUCKET_NAME"
echo "    DynamoDB: $DYNAMODB_TABLE"
echo "    Region: $REGION"

# ──────────────────────────────────────────────────────────────
# 2️⃣  destroy terraform resources
# ──────────────────────────────────────────────────────────────
cd terraform

echo "⚠️  Destroying Terraform-managed resources..."
terraform init -upgrade -input=false >/dev/null
terraform destroy -auto-approve

# ──────────────────────────────────────────────────────────────
# 3️⃣  optionally clean up backend resources
# ──────────────────────────────────────────────────────────────
if [[ "$CLEAN_BACKEND" == "true" ]]; then
    echo "🧹  Cleaning up backend resources..."
    
    # Empty and delete S3 bucket
    echo "📦  Emptying S3 bucket: $BUCKET_NAME"
    aws s3 rm s3://"$BUCKET_NAME" --recursive --region "$REGION" 2>/dev/null || true
    
    echo "📦  Deleting S3 bucket: $BUCKET_NAME"
    aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null || true
    
    # Delete DynamoDB table
    echo "📊  Deleting DynamoDB table: $DYNAMODB_TABLE"
    aws dynamodb delete-table --table-name "$DYNAMODB_TABLE" --region "$REGION" 2>/dev/null || true
    
    echo "✅  Backend resources cleaned up"
    
    # Remove backend info file
    cd ..
    rm -f .terraform-backend-info
    rm -f terraform/backend.tf
else
    echo "ℹ️  Backend resources preserved. Use --clean-backend to remove them."
fi

# ──────────────────────────────────────────────────────────────
# 4️⃣  completion message
# ──────────────────────────────────────────────────────────────
echo ""
echo "✅  Terraform destroy complete."
echo "🔑  Local SSH key-pair left untouched:"
echo "    edmp-key      (private key)"
echo "    edmp-key.pub  (public key)"
echo "    Delete them manually if you no longer need SSH access."

if [[ "$CLEAN_BACKEND" == "false" ]]; then
    echo ""
    echo "💡  To completely remove all resources including backend state:"
    echo "    ./destroy.sh --clean-backend"
fi