terraform {
  backend "s3" {
    bucket         = "edmp-terraform-state-permanent"
    key            = "edmp/terraform.tfstate"
    region         = "us-west-1"
    encrypt        = true
    dynamodb_table = "edmp-terraform-state-lock-permanent"
    workspace_key_prefix = "edmp"
  }
}
