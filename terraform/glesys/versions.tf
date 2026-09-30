terraform {
  required_version = ">= 1.11"

  required_providers {
    glesys = {
      source  = "glesys/glesys"
      version = "~> 0.18.0"
    }
  }

  # The tfstate instance and this bucket are created by hand once (see main.tf). Credentials come from
  # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY: the tfstate instance's hand-made CI credential.
  backend "s3" {
    bucket    = "kthais-tfstate"
    key       = "glesys/terraform.tfstate"
    endpoints = { s3 = "https://objects.dc-sto1.glesys.net" }
    region    = "us-east-1" # placeholder; GleSYS ignores it, but request signing needs one

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true

    # No locking: GleSYS ignores If-None-Match (tested 2026-09-30: a second conditional put succeeded),
    # so a lockfile wouldn't lock anything. CI's concurrency group keeps applies from overlapping, and
    # the bucket is versioned, so an overwritten state can be recovered.
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

# Reads GLESYS_USERID and GLESYS_TOKEN.
provider "glesys" {}
