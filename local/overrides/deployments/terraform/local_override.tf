# Local only (kthais-local): this root, pointed at the local server instead of production. Copied into a
# fresh copy of the repo for every run, never into the repo itself. OpenTofu merges it over versions.tf.

terraform {
  backend "local" {
    path = "/workspace/local/.state/tofu/deployments.tfstate"
  }
}

# On dokploy-network, by the name Dokploy's server uses too. The login is unchanged: the deployments-ci
# role, with a JWT the local signer makes for this repo's production environment.
provider "vault" {
  address = "http://openbao:8200"
}

provider "dokploy" {
  endpoint = "http://dokploy:3000"
}
