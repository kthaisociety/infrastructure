terraform {
  required_version = ">= 1.11"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }

  # Same bucket, credential and encryption as terraform/glesys (see its versions.tf).
  backend "s3" {
    bucket    = "kthais-tfstate"
    key       = "gcp/terraform.tfstate"
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

# CI signs in with its GitHub Actions OIDC token, as a read-only account on PRs and as another on main
# (docs/gcp.md, "How CI signs in"). There are no key files. No default project: every resource names
# its own.
provider "google" {}
