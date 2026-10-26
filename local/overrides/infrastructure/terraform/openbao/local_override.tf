# Local only (kthais-local): this root, pointed at the local server instead of production. Copied into a
# fresh copy of the repo for every run, never into the repo itself. OpenTofu merges it over the root.

terraform {
  backend "local" {
    path = "/workspace/local/.state/tofu/infrastructure-openbao.tfstate"
  }
}

provider "vault" {
  address = "http://openbao:8200"
}

# GitHub's OIDC issuer can't sign for a local run, so the local signer (kthais-local's JWT key) takes its
# place. The roles are unchanged: infrastructure-ci and deployments-ci bind the same subjects as in
# production, and the signer puts those subjects in its tokens.
resource "vault_jwt_auth_backend" "github" {
  oidc_discovery_url = null
  bound_issuer       = "https://ci.kthais.localhost"
  # Trimmed: OpenBao stores the key without its trailing newline, and every plan would show it otherwise.
  jwt_validation_pubkeys = [trimspace(file("/workspace/local/.state/jwt/ci.pub.pem"))]
}

# terraform/glesys's state: the stand-in in local/mock/glesys.
data "terraform_remote_state" "glesys" {
  backend = "local"
  config = {
    path = "/workspace/local/.state/tofu/glesys.tfstate"
  }
}
