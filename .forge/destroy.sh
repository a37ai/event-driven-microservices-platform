#!/usr/bin/env bash
# destroy.sh – tears down the EDMP infrastructure deployed by deploy.sh
# -----------------------------------------------------------------------
# • Reads backend configuration from .terraform-backend-info
# • Executes terraform destroy -auto-approve
# • NEVER destroys the S3 bucket and DynamoDB table (state storage)
# • Leaves the local SSH key-pair in place (delete manually if desired)
#
# Usage:
#   $ ./destroy.sh
# -----------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

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
# 3️⃣  backend resources are NEVER deleted (they store terraform state)
# ──────────────────────────────────────────────────────────────
echo "ℹ️  Backend resources (S3 bucket and DynamoDB table) are preserved."
echo "    These contain your terraform state and should never be deleted."
echo "    S3 Bucket: $BUCKET_NAME"
echo "    DynamoDB: $DYNAMODB_TABLE"

# ──────────────────────────────────────────────────────────────
# 4️⃣  completion message
# ──────────────────────────────────────────────────────────────
echo ""
echo "✅  Terraform destroy complete."
echo "🔑  Local SSH key-pair left untouched:"
echo "    terraform/edmp-key      (private key)"
echo "    terraform/edmp-key.pub  (public key)"
echo "    Delete them manually if you no longer need SSH access."
echo ""
echo "⚠️  IMPORTANT: Backend state resources are preserved and should never be deleted."
echo "    They contain your terraform state and are required for future deployments."