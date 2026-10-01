# OpenBao's own configuration: logins, policies, the KV mount and the token role for Dokploy's providers.
# Init, the first admins and CI's login were made by hand (runbook Part B) and are imported here, with
# the exact config they were made with, so the first plan changes nothing about them. The audit device
# is in the server config (terraform/dokploy/openbao.tf): OpenBao refuses to create one through the API.

import {
  to = vault_policy.terraform
  id = "terraform"
}

import {
  to = vault_jwt_auth_backend.github
  id = "jwt"
}

import {
  to = vault_jwt_auth_backend_role.infrastructure_ci
  id = "auth/jwt/role/infrastructure-ci"
}

import {
  to = vault_auth_backend.userpass
  id = "userpass"
}

# CI's policy. Everything, because CI is what configures OpenBao.
resource "vault_policy" "terraform" {
  name   = "terraform"
  policy = <<-EOT
    path "*" {
      capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
    }
  EOT
}

resource "vault_jwt_auth_backend" "github" {
  path               = "jwt"
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
  bound_issuer       = "https://token.actions.githubusercontent.com"
}

resource "vault_jwt_auth_backend_role" "infrastructure_ci" {
  backend         = vault_jwt_auth_backend.github.path
  role_name       = "infrastructure-ci"
  role_type       = "jwt"
  user_claim      = "sub"
  bound_audiences = ["https://bao.kthais.com"]
  # Only a job in this repo's `production` environment, which only runs on main.
  bound_claims   = { sub = "repo:kthaisociety/infrastructure:environment:production" }
  token_policies = ["terraform"]
  token_ttl      = 1800
  token_max_ttl  = 3600
}

# Break-glass login. Users are made by hand (runbook B3) with token_bound_cidrs=127.0.0.1/32, so their
# tokens only work from inside the container; Traefik also blocks /v1/auth/userpass.
resource "vault_auth_backend" "userpass" {
  type = "userpass"
  path = "userpass"
}

# App secrets: secret/<project>/<environment>, plus secret/shared/<name>/<environment> and
# secret/infrastructure/production (written only by OpenTofu, snapshots.tf).
resource "vault_mount" "secret" {
  path    = "secret"
  type    = "kv"
  options = { version = "2" }
}

# Tokens for Dokploy's vault providers (projects.tf). Orphans, so they outlive the CI login that made
# them; periodic, so an apply within 14 days of expiry renews them; and only ever holding a project policy.
resource "vault_token_auth_backend_role" "dokploy_provider" {
  role_name               = "dokploy-provider"
  orphan                  = true
  renewable               = true
  token_period            = 768 * 3600
  token_no_default_policy = true
  allowed_policies_glob   = ["dokploy-project-*"]
}

# People: Google sign-in (oidc.tf), or userpass from inside the container. Reads and writes app secrets,
# never infrastructure/*, and can manage userpass users only as infra-admins bound to the container.
resource "vault_policy" "infra_admin" {
  name   = "infra-admin"
  policy = <<-EOT
    path "secret/data/*" {
      capabilities = ["create", "read", "update", "patch", "delete", "list"]
    }
    path "secret/metadata/*" {
      capabilities = ["read", "list", "delete"]
    }
    path "secret/data/infrastructure/*" {
      capabilities = ["deny"]
    }
    path "secret/metadata/infrastructure/*" {
      capabilities = ["deny"]
    }

    path "auth/userpass/users/*" {
      capabilities        = ["create", "read", "update", "delete", "list"]
      required_parameters = ["token_bound_cidrs"]
      allowed_parameters = {
        "password"          = []
        "token_policies"    = ["infra-admin"]
        "token_bound_cidrs" = ["127.0.0.1/32"]
        "token_ttl"         = []
        "token_max_ttl"     = []
      }
    }
    path "auth/userpass/users/+/password" {
      capabilities = ["update"]
    }
  EOT
}
