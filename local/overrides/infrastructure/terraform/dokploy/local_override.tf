# Local only (kthais-local): this root, pointed at the local server instead of production. Copied into a
# fresh copy of the repo for every run, never into the repo itself. OpenTofu merges it over the root.

terraform {
  backend "local" {
    path = "/workspace/local/.state/tofu/infrastructure-dokploy.tfstate"
  }
}

provider "dokploy" {
  endpoint = "http://dokploy:3000"
}

# bao.kthais.com's stand-in. Browsers resolve *.localhost to this machine: https://bao.localhost:8443
# (Traefik's default certificate, as Let's Encrypt can't issue one here).
locals {
  openbao_host = "bao.localhost"
}
