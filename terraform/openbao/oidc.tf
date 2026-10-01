# People's login: Google directly, through the UI at https://bao.kthais.com/ui or `bao login -method=oidc`.
# The client is in GCP project clean-healer-452020-n9, with an Internal consent screen, so only kthais.com
# accounts can get through Google at all; the role then allows only the listed addresses.

resource "vault_jwt_auth_backend" "oidc" {
  path                          = "oidc"
  type                          = "oidc"
  oidc_discovery_url            = "https://accounts.google.com"
  bound_issuer                  = "https://accounts.google.com"
  oidc_client_id                = var.openbao_oidc_client_id
  oidc_client_secret_wo         = var.openbao_oidc_client_secret
  oidc_client_secret_wo_version = 1 # bump when the client secret is rotated
  default_role                  = "infra-admin"
}

resource "vault_jwt_auth_backend_role" "infra_admin" {
  backend     = vault_jwt_auth_backend.oidc.path
  role_name   = "infra-admin"
  role_type   = "oidc"
  user_claim  = "email"
  oidc_scopes = ["openid", "email"]
  allowed_redirect_uris = [
    "https://bao.kthais.com/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback", # `bao login -method=oidc` from a laptop
  ]
  # A comma-separated string matches any one of the values. `hd` is only set for Workspace accounts.
  bound_claims = {
    hd    = "kthais.com"
    email = join(",", var.openbao_admin_emails)
  }
  token_policies = ["infra-admin"]
  token_ttl      = 3600
  token_max_ttl  = 3600
}
