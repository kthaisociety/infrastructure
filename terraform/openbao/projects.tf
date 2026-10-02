# Every project in projects.yaml gets, per environment, a policy, a Dokploy provider token and an empty
# secret path (modules/project-secrets).

locals {
  projects = yamldecode(file("${path.module}/projects.yaml"))

  project_environments = merge([
    for p, cfg in local.projects : {
      for env in try(cfg.environments, ["staging", "production"]) : "${p}/${env}" => {
        project     = p
        environment = env
        shared      = try(cfg.shared, [])
      }
    }
  ]...)

  # Each shared secret path once, however many projects read it.
  shared_paths = toset(flatten([
    for pe in values(local.project_environments) : [for s in pe.shared : "shared/${s}/${pe.environment}"]
  ]))
}

module "project_secrets" {
  source   = "../modules/project-secrets"
  for_each = local.project_environments

  project     = each.value.project
  environment = each.value.environment
  shared      = each.value.shared
  mount       = vault_mount.secret.path
  token_role  = vault_token_auth_backend_role.dokploy_provider.role_name
}

# Same as modules/project-secrets' empty path: metadata only, never deleted by OpenTofu.
resource "vault_generic_endpoint" "shared_path" {
  for_each             = local.shared_paths
  path                 = "${vault_mount.secret.path}/metadata/${each.key}"
  data_json            = jsonencode({ custom_metadata = { managed_by = "kthaisociety/infrastructure" } })
  ignore_absent_fields = true
  disable_delete       = true
}
