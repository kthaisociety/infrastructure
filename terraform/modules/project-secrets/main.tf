# One project environment's side of OpenBao: the policy its Dokploy vault provider uses, that provider's
# token, and the (empty) path an admin fills in the UI. Used by terraform/openbao/projects.tf.

terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
  }
}

locals {
  path = "${var.project}/${var.environment}"
  name = "${var.project}-${var.environment}"
}

resource "vault_policy" "this" {
  name = "dokploy-project-${local.name}"
  policy = join("\n", concat(
    [<<-EOT
      path "${var.mount}/data/${local.path}" {
        capabilities = ["read"]
      }
      # Dokploy's env editor lists the keys for autocomplete.
      path "${var.mount}/metadata/${local.path}" {
        capabilities = ["read", "list"]
      }
      # Dokploy's connection test. The token has no default policy, so it gets only this from it.
      path "auth/token/lookup-self" {
        capabilities = ["read"]
      }
    EOT
    ],
    [for s in var.shared : <<-EOT
      path "${var.mount}/data/shared/${s}/${var.environment}" {
        capabilities = ["read"]
      }
    EOT
    ],
  ))
}

# Periodic orphan from the dokploy-provider role. Any apply within 14 days of expiry renews it, and the
# token string doesn't change on renewal, so Dokploy needs no update. The weekly scheduled apply keeps
# it alive when nothing else changes.
resource "vault_token" "this" {
  role_name         = var.token_role
  policies          = [vault_policy.this.name]
  no_default_policy = true
  renewable         = true
  renew_min_lease   = 14 * 24 * 3600
  renew_increment   = 768 * 3600
  display_name      = "dokploy-${local.name}"
}

# Makes the path exist, empty, so it shows in the UI to be filled: metadata only, no secret version.
# Never deleted by OpenTofu: removing a project folder must not destroy its secrets.
resource "vault_generic_endpoint" "path" {
  count                = var.create_path ? 1 : 0
  path                 = "${var.mount}/metadata/${local.path}"
  data_json            = jsonencode({ custom_metadata = { managed_by = "kthaisociety/infrastructure" } })
  ignore_absent_fields = true
  disable_delete       = true
}
