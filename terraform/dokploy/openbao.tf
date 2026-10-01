# OpenBao, the org's secrets manager: one node, Raft storage, auto-unsealed by a static key. Dokploy's
# server reads secrets from it at deploy time as http://openbao:8200; CI configures it through
# https://bao.kthais.com once that route is on. Steps and checks: docs/openbao-deploy.md.

resource "dokploy_project" "infrastructure" {
  name        = "infrastructure"
  description = "Org infrastructure services, managed by github.com/kthaisociety/infrastructure"
}

locals {
  openbao_image = "openbao/openbao:2.7.0"
  openbao_host  = "bao.kthais.com"

  openbao_config = {
    # The UI's only login is Google (terraform/openbao/oidc.tf).
    ui            = true
    disable_mlock = true
    api_addr      = "https://${local.openbao_host}"
    # Single node: nothing dials this, but Raft requires it.
    cluster_addr = "http://127.0.0.1:8201"
    storage = {
      raft = {
        path    = "/openbao/file"
        node_id = "openbao-1"
      }
    }
    # Plain HTTP on dokploy-network; Traefik terminates TLS. No x_forwarded_for settings, so OpenBao sees
    # Traefik's address, never a client-supplied one: admin tokens bound to 127.0.0.1 can't be used
    # through the public route.
    listener = {
      tcp = {
        address     = "0.0.0.0:8200"
        tls_disable = true
      }
    }
    # 32 random bytes placed on the host by hand (/etc/openbao/unseal.key, copy in 1Password). The key
    # id stays paired with the key for the life of the data.
    seal = {
      static = {
        current_key_id = "kthais-1"
        current_key    = "file:///openbao/unseal.key"
      }
    }
    # Every request and response, HMAC'd, to the container's log, which Dokploy shows. Here and not in
    # terraform/openbao: OpenBao refuses to create audit devices through the API (since 2.3.2).
    audit = [{
      file = {
        stdout = {
          description = "Audit log to the container's stdout."
          options     = { file_path = "stdout" }
        }
      }
    }]
  }

  # Only CI's login is public. Userpass (infra admins) and the root-recovery and init endpoints get a
  # 403 from Traefik; they still work from inside the container.
  openbao_blocked_paths = [
    "/v1/auth/userpass",
    "/v1/sys/generate-root",
    "/v1/sys/rekey",
    "/v1/sys/rotate/recovery",
    "/v1/sys/init",
  ]
  openbao_host_rule    = "Host(`${local.openbao_host}`)"
  openbao_blocked_rule = "${local.openbao_host_rule} && (${join(" || ", [for p in local.openbao_blocked_paths : "PathPrefix(`${p}`)"])})"

  openbao_labels = [
    "traefik.enable=true",
    "traefik.docker.network=dokploy-network",
    "traefik.http.services.bao.loadbalancer.server.port=8200",

    "traefik.http.routers.bao-web.rule=${local.openbao_host_rule}",
    "traefik.http.routers.bao-web.entrypoints=web",
    "traefik.http.routers.bao-web.middlewares=redirect-to-https@file",
    "traefik.http.routers.bao-web.service=bao",

    "traefik.http.routers.bao.rule=${local.openbao_host_rule}",
    "traefik.http.routers.bao.entrypoints=websecure",
    "traefik.http.routers.bao.tls.certresolver=letsencrypt",
    "traefik.http.routers.bao.middlewares=bao-ratelimit",
    "traefik.http.routers.bao.service=bao",
    "traefik.http.middlewares.bao-ratelimit.ratelimit.average=20",
    "traefik.http.middlewares.bao-ratelimit.ratelimit.burst=40",

    # Higher priority than `bao`, so these paths never reach OpenBao. An allowlist that allows nothing.
    "traefik.http.routers.bao-blocked.rule=${local.openbao_blocked_rule}",
    "traefik.http.routers.bao-blocked.priority=1000",
    "traefik.http.routers.bao-blocked.entrypoints=websecure",
    "traefik.http.routers.bao-blocked.tls.certresolver=letsencrypt",
    "traefik.http.routers.bao-blocked.middlewares=bao-deny",
    "traefik.http.routers.bao-blocked.service=bao",
    "traefik.http.middlewares.bao-deny.ipallowlist.sourcerange=127.0.0.1/32",
  ]
}

locals {
  # Traefik and Dokploy's server reach OpenBao on dokploy-network.
  openbao_network = var.openbao_initialized ? "dokploy-network" : "default"
}

resource "dokploy_compose" "openbao" {
  name            = "openbao"
  description     = "Secrets manager, at https://bao.kthais.com"
  environment_id  = dokploy_project.infrastructure.production_environment_id
  compose_type    = "docker-compose"
  app_name_prefix = "openbao"

  # Compose interpolates `$`; nothing below contains one. If something ever does, write `$$`.
  raw = {
    compose_file = yamlencode({
      services = {
        openbao = {
          image = local.openbao_image
          # The image's entrypoint writes BAO_LOCAL_CONFIG to its config directory and runs `bao server`
          # on it, as the image's `openbao` user (uid 100, gid 1000), never root.
          command     = "server"
          restart     = "unless-stopped"
          environment = { BAO_LOCAL_CONFIG = jsonencode(local.openbao_config) }
          volumes = [
            "openbao-data:/openbao/file",
            # Long syntax so a missing key fails the deploy, instead of Docker creating an empty
            # directory at that path.
            {
              type      = "bind"
              source    = "/etc/openbao/unseal.key"
              target    = "/openbao/unseal.key"
              read_only = true
              bind      = { create_host_path = false }
            },
          ]
          # Whoever calls sys/init first owns OpenBao. Until it's initialized it's on its own compose
          # network only, so no other container (every app on dokploy-network) can reach it; init
          # happens from inside the container. No `ports` either: nothing is published on the host.
          networks = { (local.openbao_network) = { aliases = ["openbao"] } }
          labels   = var.openbao_public ? local.openbao_labels : ["traefik.enable=false"]
        }
      }
      networks = { (local.openbao_network) = { external = var.openbao_initialized } }
      volumes  = { openbao-data = {} }
    })
  }

  lifecycle {
    precondition {
      condition     = var.openbao_initialized || !var.openbao_public
      error_message = "openbao_public needs openbao_initialized: never route to an uninitialized OpenBao."
    }
  }
}
