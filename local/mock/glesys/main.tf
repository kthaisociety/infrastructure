# Stands in for infrastructure's terraform/glesys locally: only the outputs other roots read
# (terraform/openbao's snapshots.tf reads openbao_snapshots).
# The same state encryption as the infrastructure roots, with their passphrase, as they decrypt it with
# their own.

terraform {
  required_version = ">= 1.11"

  backend "local" {
    path = "/workspace/local/.state/tofu/glesys.tfstate"
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

variable "state_passphrase" {
  type      = string
  sensitive = true
}

output "openbao_snapshots" {
  value = {
    access_key = "local-not-a-key"
    secret_key = "local-not-a-secret"
  }
  sensitive = true
}
