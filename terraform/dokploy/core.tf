# Dokploy core: what every project shares.
#
# The backup destination for the production databases that kthaisociety/deployments' modules/project
# creates. That repo looks it up by name and gives each production Postgres a scheduled backup to it
# (docs/database-backups.md).

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

locals {
  database_backups_endpoint = "https://objects.dc-sto1.glesys.net"
  database_backups_key      = data.terraform_remote_state.glesys.outputs.database_backups
}

resource "dokploy_destination" "database_backups" {
  # deployments looks it up by this name: renaming it breaks every backup there.
  name          = "database-backups"
  provider_name = "Other"
  endpoint      = local.database_backups_endpoint
  # Made by hand in the database-backups instance: buckets aren't in the GleSYS API.
  bucket = "kthais-database-backups"
  region = "us-east-1" # placeholder; GleSYS ignores it, but request signing needs one

  # Kept out of this state. A new version whenever terraform/glesys replaces the credential.
  access_key_wo                = local.database_backups_key.access_key
  access_key_wo_version        = parseint(substr(sha256(local.database_backups_key.access_key), 0, 8), 16)
  secret_access_key_wo         = local.database_backups_key.secret_key
  secret_access_key_wo_version = parseint(substr(sha256(local.database_backups_key.secret_key), 0, 8), 16)

  # No verify_connection: when it fails, Dokploy's message has the rclone command in it, secret key
  # included, and the apply prints it to this public repo's Actions log. Test it in Dokploy instead
  # (docs/database-backups.md).
}
