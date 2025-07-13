terraform {
  backend "s3" {
    # The bucket and DynamoDB lock table will be supplied at runtime by deploy.sh via
    #   terraform init -backend-config="bucket=<NAME>" -backend-config="dynamodb_table=<TABLE>"
    # This avoids rewriting this file and lets us generate unique names per deployment.
    key                  = "edmp/terraform.tfstate"
    region               = "us-west-1"
    encrypt              = true
    workspace_key_prefix = "edmp"
  }
}
