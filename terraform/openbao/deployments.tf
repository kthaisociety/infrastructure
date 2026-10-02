# kthaisociety/deployments' CI login. It manages projects' OpenBao side (modules/project-secrets there):
# their policies, their Dokploy provider tokens and their empty secret paths. Nothing else: not auth
# methods, admin policies, the token role or infrastructure/*, and never secret values.
#
# It can still read project secrets indirectly, by minting a dokploy-provider token with a project policy
# (docs/delivery-plan.md, "Two repos"); that's why its login is limited to deployments' production
# environment, which only runs on main.

resource "vault_policy" "deployments" {
  name   = "deployments"
  policy = <<-EOT
    # Project policies only.
    path "sys/policies/acl/dokploy-project-*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # Provider tokens, only through the dokploy-provider role (which only grants dokploy-project-*).
    path "auth/token/create/dokploy-provider" {
      capabilities = ["create", "update"]
    }
    path "auth/token/roles/dokploy-provider" {
      capabilities = ["read"]
    }
    # Reading, renewing and revoking those tokens by accessor (vault_token's refresh, renewal, destroy).
    path "auth/token/lookup-accessor" {
      capabilities = ["update"]
    }
    path "auth/token/renew-accessor" {
      capabilities = ["update"]
    }
    path "auth/token/revoke-accessor" {
      capabilities = ["update"]
    }

    # Empty secret paths: metadata only, never data.
    path "secret/metadata/*" {
      capabilities = ["create", "read", "update", "list"]
    }
    path "secret/metadata/infrastructure/*" {
      capabilities = ["deny"]
    }
    path "secret/data/*" {
      capabilities = ["deny"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "deployments_ci" {
  backend         = vault_jwt_auth_backend.github.path
  role_name       = "deployments-ci"
  role_type       = "jwt"
  user_claim      = "sub"
  bound_audiences = ["https://bao.kthais.com"]
  # kthaisociety/deployments' production environment (main only), immutable subject: owner and repo ids.
  # Check the form with: gh api repos/kthaisociety/deployments/actions/oidc/customization/sub
  bound_claims   = { sub = "repo:kthaisociety@57193069/deployments@1402092754:environment:production" }
  token_policies = [vault_policy.deployments.name]
  token_ttl      = 1800
  token_max_ttl  = 3600
}
