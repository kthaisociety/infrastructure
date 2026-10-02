# kthaisociety/deployments' CI login. It mints each project's Dokploy provider token, through the
# dokploy-provider role, and does nothing else in OpenBao. In particular it can't write policies: a
# dokploy-project-* policy's contents decide what a token minted with it can read, so those policies,
# and the projects' empty secret paths, are written only by this repo (projects.tf).
#
# What it can still do: mint a token with any project's policy, and so read app secrets. That's inherent
# to wiring Dokploy's providers, and why the login is bound to deployments' production environment (main
# only) and its plan environment (PR plans, after a reviewer approves the run). It can't reach
# infrastructure/* (separate role and policy, main.tf) or anything admin.

resource "vault_policy" "deployments" {
  name   = "deployments"
  policy = <<-EOT
    # Provider tokens, only through dokploy-provider, which only grants existing dokploy-project-*
    # policies (written by kthaisociety/infrastructure).
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

    # Explicitly never: policies, other token roles, secrets.
    path "sys/policies/*" {
      capabilities = ["deny"]
    }
    path "auth/token/create/dokploy-provider-infrastructure" {
      capabilities = ["deny"]
    }
    path "secret/*" {
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
  # kthaisociety/deployments' production (main only) and plan (reviewer-approved PR plans) environments,
  # immutable subject: owner and repo ids. Check the form with:
  #   gh api repos/kthaisociety/deployments/actions/oidc/customization/sub
  bound_claims = {
    sub = join(",", [
      "repo:kthaisociety@57193069/deployments@1402092754:environment:production",
      "repo:kthaisociety@57193069/deployments@1402092754:environment:plan",
    ])
  }
  token_policies = [vault_policy.deployments.name]
  token_ttl      = 1800
  token_max_ttl  = 3600
}
