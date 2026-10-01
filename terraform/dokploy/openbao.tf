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
    ui            = false
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

resource "dokploy_compose" "openbao" {
  name            = "openbao"
  description     = "Secrets manager. API only, at https://bao.kthais.com"
  environment_id  = dokploy_project.infrastructure.production_environment_id
  compose_type    = "docker-compose"
  app_name_prefix = "openbao"

  # Compose interpolates `$`; nothing below contains one. If something ever does, write `$$`.
  raw = {
    compose_file = yamlencode({
      services = {
        openbao = {
          image = local.openbao_image
          # The image's entrypoint writes BAO_LOCAL_CONFIG to its config directory, runs `bao server`
          # on it and drops root.
          command     = "server"
          restart     = "unless-stopped"
          environment = { BAO_LOCAL_CONFIG = jsonencode(local.openbao_config) }
          volumes = [
            "openbao-data:/openbao/file",
            "/etc/openbao/unseal.key:/openbao/unseal.key:ro",
          ]
          networks = {
            dokploy-network = { aliases = ["openbao"] }
          }
          # No `ports`: nothing is published on the host. Until it's initialized, no route either:
          # whoever calls sys/init first would own it.
          labels = var.openbao_public ? local.openbao_labels : ["traefik.enable=false"]
        }
      }
      networks = { dokploy-network = { external = true } }
      volumes  = { openbao-data = {} }
    })
  }
}
