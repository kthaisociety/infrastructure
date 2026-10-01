# Every folder under terraform/projects/ with a project.yaml gets, per environment, a policy, a Dokploy
# provider token and an empty secret path (modules/app-secrets). terraform/dokploy reads the tokens.

locals {
  projects = {
    for f in fileset(path.module, "../projects/*/project.yaml") :
    basename(dirname(f)) => yamldecode(file("${path.module}/${f}"))
  }

  project_environments = merge([
    for p, cfg in local.projects : {
      for env, env_cfg in cfg.environments : "${p}-${env}" => {
        project     = p
        environment = env
        shared      = try(env_cfg.shared, [])
      }
    }
  ]...)

  # Each shared secret path once, however many projects read it.
  shared_paths = toset(flatten([
    for pe in values(local.project_environments) : [for s in pe.shared : "shared/${s}/${pe.environment}"]
  ]))
}

module "app_secrets" {
  source   = "../modules/app-secrets"
  for_each = local.project_environments

  project     = each.value.project
  environment = each.value.environment
  shared      = each.value.shared
  mount       = vault_mount.secret.path
  token_role  = vault_token_auth_backend_role.dokploy_provider.role_name
}

# Same as modules/app-secrets' empty path: metadata only, never deleted by OpenTofu.
resource "vault_generic_endpoint" "shared_path" {
  for_each             = local.shared_paths
  path                 = "${vault_mount.secret.path}/metadata/${each.key}"
  data_json            = jsonencode({ custom_metadata = { managed_by = "kthaisociety/infrastructure" } })
  ignore_absent_fields = true
  disable_delete       = true
}
