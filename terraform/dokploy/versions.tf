terraform {
  required_version = ">= 1.11"

  required_providers {
    dokploy = {
      source = "vanillauys/dokploy"
      # 1.8 targets Dokploy v0.30.8, the version we run.
      version = "~> 1.8.0"
    }
  }

  # Same bucket, credential and encryption as terraform/glesys (see its versions.tf).
  backend "s3" {
    bucket    = "kthais-tfstate"
    key       = "dokploy/terraform.tfstate"
    endpoints = { s3 = "https://objects.dc-sto1.glesys.net" }
    region    = "us-east-1" # placeholder; GleSYS ignores it, but request signing needs one

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true

    use_lockfile = false
  }

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

# Reads DOKPLOY_API_KEY: the key of Dokploy's dedicated `terraform` admin user, made in the UI with rate
# limiting off (a rate-limited key answers 401 mid-apply).
provider "dokploy" {
  endpoint = "https://synapse.aisociety.se"
}
