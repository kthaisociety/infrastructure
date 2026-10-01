# What the snapshot compose (runbook E2) needs, at secret/infrastructure/production: a token that can take
# Raft snapshots, and the GleSYS credential for the openbao-snapshots bucket. Only OpenTofu writes this
# path; infra-admin can't read it. The infrastructure project's Dokploy provider reads it.

data "terraform_remote_state" "glesys" {
  backend = "s3"
  config = {
    bucket    = "kthais-tfstate"
    key       = "glesys/terraform.tfstate"
    endpoints = { s3 = "https://objects.dc-sto1.glesys.net" }
    region    = "us-east-1"

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

resource "vault_policy" "openbao_snapshots" {
  name   = "openbao-snapshots"
  policy = <<-EOT
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }
  EOT
}

# Periodic orphan, renewed by apply like the provider tokens.
resource "vault_token" "openbao_snapshots" {
  policies          = [vault_policy.openbao_snapshots.name]
  no_parent         = true
  no_default_policy = true
  period            = "768h"
  renewable         = true
  renew_min_lease   = 14 * 24 * 3600
  renew_increment   = 768 * 3600
  display_name      = "openbao-snapshots"
}

# The infrastructure project's policy and provider token; its path is written below, not left empty.
module "infrastructure_secrets" {
  source = "../modules/app-secrets"

  project     = "infrastructure"
  environment = "production"
  mount       = vault_mount.secret.path
  token_role  = vault_token_auth_backend_role.dokploy_provider.role_name
  create_path = false
}

locals {
  infrastructure_secrets = jsonencode({
    SNAPSHOT_TOKEN = vault_token.openbao_snapshots.client_token
    S3_ACCESS_KEY  = data.terraform_remote_state.glesys.outputs.openbao_snapshots.access_key
    S3_SECRET_KEY  = data.terraform_remote_state.glesys.outputs.openbao_snapshots.secret_key
  })
}

resource "vault_kv_secret_v2" "infrastructure" {
  mount        = vault_mount.secret.path
  name         = "infrastructure/production"
  data_json_wo = local.infrastructure_secrets
  # A new version whenever a value changes, without the values being in this resource's state.
  data_json_wo_version = parseint(substr(sha256(local.infrastructure_secrets), 0, 8), 16)
}
