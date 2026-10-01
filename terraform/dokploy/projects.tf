# Every folder under terraform/projects/ with a project.yaml becomes a Dokploy project (modules/project),
# with a vault provider per environment whose token terraform/openbao made (modules/project-secrets).

data "terraform_remote_state" "openbao" {
  backend = "s3"
  config = {
    bucket    = "kthais-tfstate"
    key       = "openbao/terraform.tfstate"
    endpoints = { s3 = "https://objects.dc-sto1.glesys.net" }
    region    = "us-east-1"

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

# The GitHub App registered in Dokploy (Git > GitHub), which the UI-managed projects build with too.
data "dokploy_github_provider" "kthais" {
  id = "ivqvxxNcPOonG4ELSjWO4"
}

locals {
  projects = {
    for f in fileset(path.module, "../projects/*/project.yaml") :
    basename(dirname(f)) => yamldecode(file("${path.module}/${f}"))
  }
  # <project>-<environment> => {name, path, token}. A project merged in the same PR as its folder has no
  # token yet on the PR plan (terraform/openbao applies only on main, before this root).
  openbao_providers = try(data.terraform_remote_state.openbao.outputs.dokploy_providers, {})
}

module "project" {
  source   = "../modules/project"
  for_each = { for p, c in local.projects : p => c if try(c.type, "app") == "app" }

  config    = each.value
  github_id = data.dokploy_github_provider.kthais.id
  provider_tokens = {
    for e, _ in each.value.environments : e => try(local.openbao_providers["${each.key}-${e}"].token, "")
  }
}

# The infrastructure project's provider: the openbao-snapshots compose (runbook E2) reads
# secret/infrastructure/production through it.
resource "dokploy_vault_provider" "infrastructure" {
  name = "infrastructure-production"

  hashicorp = {
    url              = "http://openbao:8200"
    mount            = "secret"
    token_wo         = local.openbao_providers["infrastructure-production"].token
    token_wo_version = parseint(substr(sha256(local.openbao_providers["infrastructure-production"].token), 0, 8), 16)
  }
  assignments = [{
    project_id      = dokploy_project.infrastructure.id
    environment_ids = [dokploy_project.infrastructure.production_environment_id]
  }]
  verify_connection = true
}

output "projects" {
  description = "Per project: its Dokploy project id, and per environment the app's internal name and volumes."
  value = {
    for p, m in module.project : p => {
      project_id = m.project_id
      apps       = m.apps
    }
  }
}
