terraform {
  required_version = ">= 1.11"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }

  # Same bucket, credential and encryption as terraform/glesys (see its versions.tf).
  backend "s3" {
    bucket    = "kthais-tfstate"
    key       = "openbao/terraform.tfstate"
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
    # terraform/glesys's state, read for the snapshot credential. Same passphrase.
    remote_state_data_sources {
      default {
        method = method.aes_gcm.state
      }
    }
  }
}

# CI logs in with its GitHub Actions OIDC token (runbook B2): only a job in this repo's `production`
# environment gets one OpenBao accepts. skip_child_token: the login token is used as is, so resources
# that must outlive the run (provider tokens) are orphans from a token role, not children of it.
provider "vault" {
  address          = "https://bao.kthais.com"
  skip_child_token = true

  auth_login_jwt {
    role = "infrastructure-ci"
    jwt  = var.openbao_jwt
  }
}
