# One project's Dokploy side, type `app`: the Dokploy project, per environment a vault provider and an
# application built from the project's repo, with its volumes. Env is the plain `env` from project.yaml
# plus a generated OpenBao reference per secret name, so no secret value is in git or state.
# Used by terraform/dokploy/projects.tf; the OpenBao side is modules/project-secrets.

terraform {
  required_providers {
    dokploy = {
      source = "vanillauys/dokploy"
    }
  }
}

locals {
  repo_owner = split("/", var.config.repo)[0]
  repo_name  = split("/", var.config.repo)[1]
  envs       = var.config.environments
  # Same names as modules/project-secrets: provider <project>-<env>, path <project>/<env>.
  provider_name = { for e, _ in local.envs : e => "${var.config.name}-${e}" }
  secret_path   = { for e, _ in local.envs : e => "${var.config.name}/${e}" }
}

resource "dokploy_project" "this" {
  name        = var.config.name
  description = "Managed by github.com/kthaisociety/infrastructure (terraform/projects/${var.config.name})"
}

# Dokploy makes `production` with the project; any other environment is made here.
resource "dokploy_environment" "this" {
  for_each   = { for e, _ in local.envs : e => e if e != "production" }
  project_id = dokploy_project.this.id
  name       = each.key
}

locals {
  environment_ids = {
    for e, _ in local.envs :
    e => e == "production" ? dokploy_project.this.production_environment_id : dokploy_environment.this[e].id
  }
}

# Lets this environment's app resolve ${{vault.<project>-<env>.…}} references, with a token that can read
# only this project's path and its shared paths (modules/project-secrets).
resource "dokploy_vault_provider" "this" {
  for_each = local.envs
  name     = local.provider_name[each.key]

  hashicorp = {
    url      = "http://openbao:8200"
    mount    = "secret"
    token_wo = var.provider_tokens[each.key]
    # A new token reaches Dokploy without anyone bumping a number.
    token_wo_version = parseint(substr(sha256(var.provider_tokens[each.key]), 0, 8), 16)
  }
  assignments = [{
    project_id      = dokploy_project.this.id
    environment_ids = [local.environment_ids[each.key]]
  }]
  # Fails the apply if Dokploy's server can't reach OpenBao or the token is wrong.
  verify_connection = true
}

locals {
  env_lines = {
    for e, c in local.envs : e => join("\n", concat(
      [for k in sort(keys(try(c.env, {}))) : "${k}=${c.env[k]}"],
      [for k in try(c.secrets, []) :
      "${k}=$${{vault.${local.provider_name[e]}.${local.secret_path[e]}:${k}}}"],
      flatten([for name, ks in try(c.shared, {}) : [for k in ks :
      "${k}=$${{vault.${local.provider_name[e]}.shared/${name}/${e}:${k}}}"]]),
    ))
  }
}

resource "dokploy_application" "this" {
  for_each        = local.envs
  name            = var.config.name
  app_name_prefix = "${var.config.name}-${each.key}"
  environment_id  = local.environment_ids[each.key]

  github = {
    github_id  = var.github_id
    owner      = local.repo_owner
    repository = local.repo_name
    branch     = try(each.value.branch, "main")
  }
  build = {
    type       = "dockerfile"
    dockerfile = try(each.value.dockerfile, "Dockerfile")
  }
  # Built by Dokploy's GitHub App on every push to the branch, as before (plan, Phase 8 moves this to CI).
  auto_deploy = true

  env = local.env_lines[each.key]
  # No .env file in the build context: resolved secrets would end up in the build's layers.
  create_env_file = false

  deploy_on_change = try(each.value.deploy, false)

  depends_on = [dokploy_vault_provider.this]
}

locals {
  volumes = merge([
    for e, c in local.envs : {
      for path, name in try(c.volumes, {}) : "${e}:${path}" => {
        env    = e
        path   = path
        volume = "${var.config.name}-${e}-${name}"
      }
    }
  ]...)
}

resource "dokploy_mount" "volume" {
  for_each     = local.volumes
  service_id   = dokploy_application.this[each.value.env].id
  service_type = "application"
  type         = "volume"
  volume_name  = each.value.volume
  mount_path   = each.value.path
}
