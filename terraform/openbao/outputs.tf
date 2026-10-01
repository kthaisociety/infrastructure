# Read by terraform/dokploy through terraform_remote_state, for each project's vault provider.

output "dokploy_providers" {
  description = "Per project environment (<project>-<environment>): the provider's name, the secret path and its token."
  value = merge(
    {
      for k, m in module.project_secrets : k => {
        name  = m.provider_name
        path  = m.path
        token = m.token
      }
    },
    {
      (module.infrastructure_secrets.provider_name) = {
        name  = module.infrastructure_secrets.provider_name
        path  = module.infrastructure_secrets.path
        token = module.infrastructure_secrets.token
      }
    },
  )
  sensitive = true
}
